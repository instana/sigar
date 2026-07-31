# Plan: Reduce AIX `getprocs()` / `getthrds()` Kernel Calls in sigar

## Overview

The Instana agent's sigar library generates excessive kernel syscalls per collection
interval on AIX. Measured syscall trace for context (before any changes):

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
  proc_time, proc_disk_io. Had a single-entry cache (`last_pid`/`last_getprocs`/`pinfo`)
  — every distinct PID was a miss, so each attribute query for a different PID cost a
  syscall. The ~3× ratio of `getprocs` to `getargs` calls confirmed multiple attribute
  queries were issued per matched PID.

### Agent call pattern per cycle (N = processes on system, N' = matched subset)

Before changes:
```
1  × getprocs() loop  — build PID list (N syscalls, one per process)
N' × getargs(pid)     — args for matched PIDs only
N' × getprocs(pid)    — state per matched PID, ×3 due to single-entry cache misses
N  × getthrds(pid)    — processor affinity, called for every PID in getProcStat loop
```

After Sub-Tasks 1–3:
```
~N/32 × getprocs() loop   — batch enumeration (TTL-guarded, ~6 calls for 178 procs)
N'    × getargs(pid)       — unchanged (intentionally not cached)
N'    × getprocs(pid)      — pinfocache misses only (≤1 per PID per 2s TTL window)
N     × getthrds(pid)      — still uncached (see Sub-Task 4)
```

`getargs()` is intentionally not cached: the agent re-fetches args to detect process
identity changes (e.g. zombie detection), and the trace confirms it is not the bottleneck.

### Root cause of remaining `getthrds` calls — `getProcStat()` running every second

`sigar.getProcStat()` (Java) calls `sigar_proc_stat_get()` → `sigar_proc_list_get(NULL)`
→ loops over every PID calling `sigar_proc_state_get()`. That function calls both
`sigar_getprocs()` (cached after Sub-Task 2) **and** `getthrds()` (completely uncached).

At 1 Hz × 178 processes = **178 `getthrds` syscalls per second** with no caching at all.
The truss confirms this pattern across every observed cycle:

| Cycle   | batch getprocs (32) | getprocs(1) per-PID | getargs | getthrds |
|---------|--------------------:|--------------------:|--------:|---------:|
| t ~ 0s  | 6                   | 3 (new procs only)  | 0       | 178      |
| t ~ 1s  | 6                   | 178 (cold cache)    | 179     | 179      |
| t ~ 4s  | 6                   | 103 (partial miss)  | 0       | 178      |
| t ~ 6s  | 12 (two sweeps)     | 178+8               | 178+178 | 356      |

The t~6s double sweep is two concurrent Java collection threads (PTQL sensor + getProcStat)
each triggering a full `sigar_proc_state_get()` loop. The batch `getprocs` TTL guard
prevents double re-enumeration of the PID list itself, but `getthrds` fires per-PID in
each thread independently.

### Non-Goals
- No changes to other platforms (Linux, Solaris, Darwin, HP-UX, Win32).
- No changes to the public sigar API.
- No changes to `sigar_proc_port_get()` (low-frequency socket lookup, separate path).

---

## Sub-Task 1 — Batch `getprocs()` in `sigar_os_proc_list_get()`

**Status:** [x] done

### Intent
`getprocs()` accepts a `count` argument — it can return multiple `procsinfo` entries
per call. Was called with `count=1`, meaning one kernel call per process.
Batching at 32 reduces the syscall count for list enumeration by ~32×.

### Implemented
- `sigar_os_proc_list_get()` now uses a stack array `struct procsinfo infos[PROC_LIST_BATCH]`
  with `PROC_LIST_BATCH = 32`.
- Confirmed in truss: `getprocs(..., 32) = 32` × 5 then `= 18` for 178 processes = 6 calls.

### Relevant Context
- Function: [`sigar_os_proc_list_get`](src/os/aix/aix_sigar.c:677)

---

## Sub-Task 2 — Replace single-entry cache with multi-entry PID cache in `sigar_getprocs()`

**Status:** [x] done

### Intent
The old cache (`last_pid` + `last_getprocs` + single `pinfo` buffer) was a one-slot
cache: every distinct PID was a miss. Replaced with `sigar_cache_t *pinfocache` keyed
by PID, where each entry holds `pinfo_cache_entry_t { time_t fetched; int valid;
struct procsinfo64 info; }` with TTL = `SIGAR_LAST_PROC_EXPIRE` (2s).

### Implemented
- `pinfo_cache_entry_t` typedef in [`src/os/aix/aix_sigar.c:701`](src/os/aix/aix_sigar.c:701).
- `sigar_getprocs()` lazily initialises `pinfocache` with `sigar_expired_cache_new(128, 5000, SIGAR_LAST_PROC_EXPIRE*1000)`.
- On hit + fresh TTL: returns cached `pinfo` pointer without a `getprocs()` call.
- On miss: allocates `pinfo_cache_entry_t`, calls `getprocs()`, stores result.
- `sigar->pinfo` stays as a `procsinfo64 *` redirected after each lookup — all five
  callers unchanged.
- Cleanup runs before any pointer dereference to avoid dangling entries.
- Confirmed in truss: t~1s cycle shows 178 `getprocs(1)` (cold cache); subsequent
  cycle within TTL shows 0–103 misses depending on elapsed time.

### Relevant Context
- [`sigar_getprocs`](src/os/aix/aix_sigar.c:707)
- `pinfocache` field in [`src/os/aix/sigar_os.h`](src/os/aix/sigar_os.h)

---

## Sub-Task 3 — Add TTL guard to `sigar_proc_list_get()` (proc list caching)

**Status:** [x] done

### Intent
`sigar_proc_list_get(sigar, NULL)` previously reset `pids->number = 0` and re-enumerated
all processes on every call. The agent triggers this multiple times per cycle (via
`sigar_proc_stat_get` and PTQL queries). The TTL guard skips re-enumeration when the
list is still fresh.

### Implemented
- `time_t last_proc_list` field added to `SIGAR_T_BASE` in `include/sigar_private.h`.
- Initialised to `0` in `sigar_open()` ([`src/sigar.c:58`](src/sigar.c:58)).
- Guard in `sigar_proc_list_get()` ([`src/sigar.c:432`](src/sigar.c:432)):
  if `pids->number > 0` and `(time(NULL) - last_proc_list) <= SIGAR_LAST_PROC_EXPIRE`,
  returns immediately.
- `last_proc_list` is updated after a successful `sigar_os_proc_list_get()` call.
- Confirmed in truss: only one batch enumeration sweep per `SIGAR_LAST_PROC_EXPIRE` window
  for the `NULL`-path callers (`sigar_proc_stat_get`, `ptql_pid_list_get`,
  `ptql_proc_list_get`).

### Relevant Context
- [`sigar_proc_list_get`](src/sigar.c:423)
- Internal callers: `sigar_proc_stat_get` ([`src/sigar.c:287`](src/sigar.c:287)),
  `ptql_pid_list_get` ([`src/sigar_ptql.c:1060`](src/sigar_ptql.c:1060)),
  `ptql_proc_list_get` ([`src/sigar_ptql.c:1856`](src/sigar_ptql.c:1856)).

---

## Sub-Task 4 — Cache `getthrds()` result inside `pinfo_cache_entry_t`

**Status:** [ ] pending

### Intent

`sigar_proc_state_get()` calls `getthrds(pid, &thrinfo, ...)` unconditionally on every
invocation to obtain `thrinfo.ti_affinity` (processor affinity). This call is completely
outside the `pinfocache` and is therefore re-issued every time `sigar_proc_state_get()`
is called for any PID — including every invocation of `sigar_proc_stat_get()`.

`sigar.getProcStat()` runs every second and iterates all N processes, generating **N
`getthrds` syscalls per second** with zero caching benefit. On the observed system
(N=178) this is 178 `getthrds/s` = ~0.7 ms/s wasted.

Processor affinity changes extremely rarely (only when a process is explicitly pinned
to a CPU). Caching it for the same TTL as `pinfocache` (2s) is correct and safe.

### Expected Outcomes
- `getthrds()` is called at most once per PID per `SIGAR_LAST_PROC_EXPIRE` window.
- `sigar_proc_stat_get()` running at 1 Hz costs **0 `getthrds` calls** on the second
  and subsequent calls within the same TTL window.
- The two-sweep pattern at t~6s (two Java threads) also benefits: second sweep hits
  cached affinity for all PIDs populated by the first sweep.

### Todo List

1. **Extend `pinfo_cache_entry_t`** in [`src/os/aix/aix_sigar.c:701`](src/os/aix/aix_sigar.c:701) to add:
   ```c
   int processor;        /* cached ti_affinity; SIGAR_FIELD_NOTIMPL if getthrds failed */
   int processor_valid;  /* 0 = not yet fetched for this cache entry, 1 = fetched */
   ```

2. **In `sigar_proc_state_get()`** at [`src/os/aix/aix_sigar.c:847`](src/os/aix/aix_sigar.c:847):
   - After `sigar_getprocs()` succeeds, look up the same cache entry:
     `pinfo_cache_entry_t *pce = entry->value` (the same entry `sigar_getprocs` just returned).
   - If `pce->processor_valid`, use `pce->processor` directly — skip `getthrds()`.
   - Otherwise call `getthrds()` as today, store the result in `pce->processor`, set
     `pce->processor_valid = 1`.

3. **Reset `processor_valid = 0`** whenever a cache entry is refreshed (i.e., in the
   `getprocs()` call branch of `sigar_getprocs()` where `pce->fetched` is updated) so
   that a fresh `getprocs()` fetch also re-fetches `getthrds()` for that PID.

### Access pattern for the cache entry in `sigar_proc_state_get()`

`sigar_getprocs()` already sets `sigar->pinfo = &pce->info` before returning. The
`pce` pointer itself is reachable via the same `sigar_cache_find()` call — or more
simply, by storing the current `pce` in a static/local that `sigar_proc_state_get()`
can use. The cleanest approach is to expose the `pce` pointer via a second field in
`sigar_t`, e.g. `pinfo_cache_entry_t *pinfo_entry`, set alongside `pinfo` inside
`sigar_getprocs()`. `sigar_proc_state_get()` reads `sigar->pinfo_entry` after the
`sigar_getprocs()` call succeeds.

### Relevant Context
- `getthrds()` call site: [`src/os/aix/aix_sigar.c:859`](src/os/aix/aix_sigar.c:859)
- `pinfo_cache_entry_t` definition: [`src/os/aix/aix_sigar.c:701`](src/os/aix/aix_sigar.c:701)
- `sigar_getprocs()` sets `sigar->pinfo`: [`src/os/aix/aix_sigar.c:730`](src/os/aix/aix_sigar.c:730) and `:758`
- `SIGAR_FIELD_NOTIMPL` is the sentinel used when `getthrds()` fails (returns != 1).
- `processor_valid` must be reset to 0 alongside `pce->valid = 0` when `fetched` is
  refreshed, so a stale entry that gets a new `getprocs()` also re-issues `getthrds()`.

---

## Sub-Task 5 — Investigate double batch-enumeration at t~6s (two concurrent threads)

**Status:** [ ] pending (investigation / observation only — may be resolved by Sub-Task 4)

### Observation

At t~6s the truss shows **two separate batch sweep groups**:
- First: buffer `0x...AF380` (= `sigar->pids`, the NULL-path cache) — fired by `getProcStat`.
- Second: buffer `0x...24E0` (different allocation) — fired 0.18s later by a concurrent
  Java collection thread (PTQL sensor or a second `sigar_proc_list_get` with a non-NULL
  proclist).

The second sweep bypasses the TTL guard because it arrives with a different `sigar_t`
instance (different buffer address = different JVM thread using its own sigar handle), or
arrives through the non-NULL `proclist` path that always calls `sigar_os_proc_list_get`.

After the second batch sweep there are **no `getprocs(1)` per-PID calls** but **178
`getthrds`** — confirming `pinfocache` is fully warm (batch sweep doesn't touch it) but
`getthrds` is still uncached. Fixing Sub-Task 4 eliminates this cost.

### If the second sweep is a separate `sigar_t` instance
Each Java thread gets its own `sigar_t` handle with its own `pinfocache` and
`last_proc_list`. Sub-Task 4 helps (each thread independently caches `getthrds` results)
but both still pay the batch enumeration cost. The only fix for that is to ensure each
`sigar_t` reuses its own TTL guard — which Sub-Tasks 2 and 3 already provide per-instance.

### If the second sweep is the same `sigar_t` with a non-NULL proclist
The non-NULL path in `sigar_proc_list_get()` unconditionally calls `sigar_os_proc_list_get`.
This is by design (the caller wants a fresh list). No action needed unless the agent
can be changed to always use the NULL path.
