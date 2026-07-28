# Plan: Reduce AIX `getprocs()` Kernel Calls in sigar

## Overview

The Instana agent's sigar library generates ~4200 `getprocs()` syscalls per collection
interval on AIX (0.28% sys time, 33 ms total). Measured syscall trace for context:

| Syscall    | Count | Total time | Avg time |
|------------|-------|------------|----------|
| `getprocs` | 4,214 | 33.4 ms    | 0.008 ms |
| `getargs`  | 1,349 |  1.8 ms    | 0.001 ms |
| `getthrds` | 1,324 |  5.5 ms    | 0.004 ms |

`getprocs()` is the dominant cost. Two call sites in `src/os/aix/aix_sigar.c` are
responsible:

- **`sigar_os_proc_list_get()`** — enumerates all processes one at a time, one
  `getprocs()` call per process to build the PID list.
- **`sigar_getprocs()`** — per-PID info fetch used by proc_state, proc_mem, proc_cred,
  proc_time, proc_disk_io. Has a single-entry cache (`last_pid`/`last_getprocs`/`pinfo`)
  — every distinct PID is a miss, so each attribute query for a different PID costs a
  syscall. The ~3× ratio of `getprocs` to `getargs` calls confirms multiple attribute
  queries are issued per matched PID.

### Agent call pattern per cycle (N = processes on system, N' = matched subset)

```
1  × getprocs() loop  — build PID list (N syscalls today, one per process)
N' × getargs(pid)     — args for matched PIDs only (not all N — not the bottleneck)
N' × getprocs(pid)    — state per matched PID, ×3 due to single-entry cache misses
```

`getargs()` is intentionally not cached: the agent re-fetches args to detect process
identity changes (e.g. zombie detection), and the trace confirms it is not the bottleneck.

### Non-Goals
- No changes to other platforms (Linux, Solaris, Darwin, HP-UX, Win32).
- No changes to the public sigar API.
- No changes to `sigar_proc_port_get()` (low-frequency socket lookup, separate path).

---

## Sub-Task 1 — Batch `getprocs()` in `sigar_os_proc_list_get()`

**Status:** [ ] pending

### Intent
`getprocs()` accepts a `count` argument — it can return multiple `procsinfo` entries
per call. Currently it is called with `count=1`, meaning one kernel call per process.
Fetching in batches of 32 reduces the syscall count for list enumeration by ~32×.

### Expected Outcomes
- `sigar_os_proc_list_get()` calls `getprocs()` with a stack batch buffer of 32 entries.
- Total `getprocs()` calls during full-process enumeration drops from ~N to ~N/32.
- Functional output (the PID list) is identical.

### Todo List
1. In `sigar_os_proc_list_get()` (line 675 of `src/os/aix/aix_sigar.c`), replace the
   single `struct procsinfo info` local with a stack array
   `struct procsinfo infos[PROC_LIST_BATCH]` where `PROC_LIST_BATCH` is defined as 32.
2. Change the `getprocs()` call to request `PROC_LIST_BATCH` entries at once.
3. Loop over the returned entries (0..num-1) appending each `pi_pid` to `proclist`.
4. Terminate when `getprocs()` returns 0.

### Relevant Context
- Function: [`sigar_os_proc_list_get`](src/os/aix/aix_sigar.c:675)
- Uses `struct procsinfo` (not 64-bit variant) — consistent with existing code at that site.
- `SIGAR_PROC_LIST_GROW` must be called before each append; keep it inside the inner loop.

---

## Sub-Task 2 — Replace single-entry cache with multi-entry PID cache in `sigar_getprocs()`

**Status:** [ ] pending

### Intent
The current cache (`last_pid` + `last_getprocs` + single `pinfo` buffer) is a
**one-slot cache**: every distinct PID is a miss. The agent queries multiple attributes
(state, mem, cred, time, disk_io) per PID in sequence, then moves to the next PID,
evicting the previous entry immediately.

Replacing this with a `sigar_cache_t` keyed by PID — where each entry holds a
`procsinfo64` plus a fetch timestamp — eliminates redundant `getprocs()` calls across
the entire monitored PID set within the 2-second TTL window.

### Expected Outcomes
- `sigar_getprocs()` checks a `sigar_cache_t *pinfocache` for the PID first.
- On a hit with a fresh timestamp (within `SIGAR_LAST_PROC_EXPIRE` seconds), no
  `getprocs()` is issued.
- On a miss or expired entry, `getprocs()` is called and the result stored.
- `sigar->pinfo` is kept as a `struct procsinfo64 *` pointer, updated to point at the
  active cache entry's value after each fetch — all five callers require no changes.
- The old `last_pid`, `last_getprocs`, and `pinfo` fields in `sigar_t` are removed.

### Todo List
1. Add `typedef struct { time_t fetched; struct procsinfo64 info; } pinfo_cache_entry_t;`
   in `src/os/aix/aix_sigar.c` (file-local).
2. Replace `last_getprocs`, `last_pid`, and `struct procsinfo64 *pinfo` fields in
   `struct sigar_t` (`src/os/aix/sigar_os.h`) with `sigar_cache_t *pinfocache` and
   keep `struct procsinfo64 *pinfo` as a bare pointer (redirected after each fetch).
3. In `sigar_os_open()` (around line 198), initialise both `pinfocache = NULL` and
   `pinfo = NULL`.
4. In `sigar_os_close()`, replace `free(sigar->pinfo)` with
   `if (sigar->pinfocache) sigar_cache_destroy(sigar->pinfocache)`.
   (`pinfo` now points into the cache, so must not be freed directly.)
5. In `sigar_getprocs()`:
   a. Lazily initialise `pinfocache` using `sigar_expired_cache_new(128,
      5 * 1000, SIGAR_LAST_PROC_EXPIRE * 1000)` — 5 s cleanup period, 2 s entry expiry.
      The cache auto-rehashes to accommodate 1000+ PIDs.
   b. Look up the PID with `sigar_cache_find()`; if found and
      `(time(NULL) - entry->fetched) < SIGAR_LAST_PROC_EXPIRE`, point `sigar->pinfo`
      at `&entry->info` and return `SIGAR_OK`.
   c. On miss, call `sigar_cache_get()` to create/retrieve the entry, call `getprocs()`
      into a freshly `malloc`'d `pinfo_cache_entry_t` stored in `entry->value`, update
      `entry->fetched`, and set `sigar->pinfo = &((pinfo_cache_entry_t*)entry->value)->info`.

### Relevant Context
- Existing cache pattern: [`diskmap`](src/os/aix/sigar_os.h:63) and its lazy init in
  [`create_diskmap()`](src/os/aix/aix_sigar.c:1292).
- `sigar_expired_cache_new` / `sigar_cache_find` / `sigar_cache_get` in
  [`src/sigar_cache.c`](src/sigar_cache.c) and [`include/sigar_util.h`](include/sigar_util.h:188).
- `SIGAR_LAST_PROC_EXPIRE` = 2 seconds, [`include/sigar_private.h:152`](include/sigar_private.h:152).
- `PID_CACHE_CLEANUP_PERIOD` / `PID_CACHE_ENTRY_EXPIRE_PERIOD` (10 min / 20 min) used by
  `proc_cpu` and `proc_io` are intentionally **not** reused here — `pinfocache` data is
  short-lived and must be evicted aggressively to free `procsinfo64` structs for dead processes.
- All five callers of `sigar_getprocs()` access data via `sigar->pinfo` — no changes needed
  there as long as `sigar->pinfo` is kept correctly redirected.

---

## Sub-Task 3 — Add TTL guard to `sigar_proc_list_get()` (proc list caching)

**Status:** [ ] pending

### Intent
`sigar_proc_list_get(sigar, NULL)` resets `pids->number = 0` and re-enumerates all
processes on every call with no time guard. The agent can trigger this multiple times
per cycle (via `sigar_proc_stat_get` and PTQL queries). Adding a last-fetched timestamp
skips the re-enumeration when the list is still fresh.

### Expected Outcomes
- `sigar_proc_list_get(sigar, NULL)` returns the cached PID list immediately if called
  again within `SIGAR_LAST_PROC_EXPIRE` seconds.
- Explicit callers passing a non-NULL `proclist` are unaffected — they always get a fresh
  list, as today.
- This is a cross-platform change in `src/sigar.c`; it only touches the `NULL` (internal
  reuse) code path.

### Todo List
1. Add a `time_t last_proc_list` field to the `SIGAR_T_BASE` macro in
   `include/sigar_private.h` (alongside `pids`).
2. In `sigar_open()` in `src/sigar.c`, initialise `(*sigar)->last_proc_list = 0`
   alongside the other base-field initialisations.
3. In `sigar_proc_list_get()` in `src/sigar.c`, on the `proclist == NULL` branch:
   after confirming `sigar->pids` is non-NULL and `pids->number > 0`,
   check `(time(NULL) - sigar->last_proc_list) < SIGAR_LAST_PROC_EXPIRE`
   — if true, return `SIGAR_OK` immediately without calling `sigar_os_proc_list_get()`.
4. On a cache miss (expired or first call / empty list), call `sigar_os_proc_list_get()`
   as today, then set `sigar->last_proc_list = time(NULL)`.

### Relevant Context
- `sigar_proc_list_get` is at [`src/sigar.c:422`](src/sigar.c:422).
- `sigar_open` base-field init is at [`src/sigar.c:40`](src/sigar.c:40).
- `SIGAR_T_BASE` macro is at [`include/sigar_private.h:48`](include/sigar_private.h:48).
- Internal (`NULL`) callers: `sigar_proc_stat_get` ([`src/sigar.c:286`](src/sigar.c:286)),
  `ptql_pid_list_get` ([`src/sigar_ptql.c:1060`](src/sigar_ptql.c:1060)),
  `ptql_proc_list_get` ([`src/sigar_ptql.c:1856`](src/sigar_ptql.c:1856)).
- Safe: 2-second staleness is already the accepted budget for `sigar_getprocs()`.

