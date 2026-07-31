# Plan: Reduce AIX `getprocs()` / `getthrds()` / `getargs()` Kernel Calls in sigar

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

**Status:** [x] done

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

### Implemented
- `pinfo_cache_entry_t` extended with `int processor` and `int processor_valid` fields
  at [`src/os/aix/aix_sigar.c:701`](src/os/aix/aix_sigar.c:701).
- `processor_valid = 0` initialised on new entry allocation and reset on every
  `getprocs()` refresh (alongside `valid = 0` and `fetched` update).
- `sigar_t` gains a `void *pinfo_entry` field ([`src/os/aix/sigar_os.h:56`](src/os/aix/sigar_os.h:56))
  set to the `pinfo_cache_entry_t *` by `sigar_getprocs()` on both hit and miss paths.
- `sigar_proc_state_get()` casts `sigar->pinfo_entry` back to `pinfo_cache_entry_t *`
  and branches: cache hit → use `pce->processor` directly; miss → call `getthrds()`,
  store result, set `processor_valid = 1`.
- `pce` guard (`if (pce)`) handles the theoretical case where `pinfo_entry` is NULL
  (e.g., if `sigar_getprocs()` returned an error path — should not happen since status
  is checked first, but defensive).

### Expected truss result
- First call per PID per TTL window: 1 `getthrds` (same as before).
- All subsequent calls within the TTL window: **0 `getthrds`**.
- `getProcStat()` at 1 Hz: only the first cycle pays N `getthrds`; all subsequent
  cycles within the 2s TTL window pay 0.
- Double-sweep at t~6s (two threads): second thread hits cached `processor_valid`
  for all PIDs already populated by the first thread — 0 additional `getthrds`.

---

## Sub-Task 5 — Double batch-enumeration at t~6s (two concurrent threads)

**Status:** [x] resolved by Sub-Task 4 (getthrds cost eliminated; batch sweeps remain but are cheap)

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

---

## Sub-Task 6 — Increase `pinfocache` TTL to reduce steady-state `getprocs(1)` misses

**Status:** [x] done

### Problem
With 1200 processes and `SIGAR_LAST_PROC_EXPIRE = 2s`, the steady-state cache miss rate
is 1200/2 = **600 getprocs(1)/s**. Confirmed by the "after" measurement: 34154/60s ≈ 569/s.
Each miss also resets `processor_valid = 0`, causing a paired `getthrds` call, so
32587/60s ≈ 543/s `getthrds` — matching the miss rate exactly.

The proc list TTL must stay at 2s (correctness: stale PID lists cause missed new processes).
The per-PID `procsinfo64` cache can safely use a longer TTL — 5s is already the standard
used by `proc_cpu` and `proc_io` cache entries.

### Implemented
- Added `SIGAR_PINFO_CACHE_EXPIRE = 5` (seconds) to [`src/os/aix/sigar_os.h`](src/os/aix/sigar_os.h:65),
  decoupled from `SIGAR_LAST_PROC_EXPIRE`.
- `sigar_expired_cache_new()` initialisation updated to use `SIGAR_PINFO_CACHE_EXPIRE * 1000`
  for entry TTL and `(SIGAR_PINFO_CACHE_EXPIRE + 3) * 1000` for cleanup period.
- TTL check in `sigar_getprocs()` updated to compare against `SIGAR_PINFO_CACHE_EXPIRE`.

### Expected impact
- Steady-state misses: 1200/5 = **240/s** (down from 600/s, –60%).
- Paired `getthrds` miss calls drop by same ratio.

---

## Sub-Task 7 — Skip `getargs` for zombie/dead processes using pinfocache

**Status:** [x] done

### Problem
After Sub-Task 3 (proc list TTL), PTQL `Args.*` scans run faster and call `getargs` for
every PID in the shared cached list — including all 500 zombie/dead processes. The kernel
`getargs` call on a zombie/dead PID always fails (returns error), but costs a syscall
anyway. With 500 such PIDs and ~0.5 PTQL-Args scans/s, this is ~250 wasted `getargs/s`.

The `pinfocache` already holds `pi_state` for every PID that has been queried via
`sigar_getprocs()`. `SZOMB` and `SIDL` processes have no argument vector.

### Implemented
- In `sigar_os_proc_args_get()` at [`src/os/aix/aix_sigar.c:910`](src/os/aix/aix_sigar.c:910):
  before calling the kernel `getargs`, check `pinfocache` for the PID. If a fresh
  (`<= SIGAR_PINFO_CACHE_EXPIRE`) valid entry exists with `pi_state == SZOMB` or
  `pi_state == SIDL`, return `ESRCH` immediately — same error the kernel would return.
- The guard is skipped when `pinfocache == NULL` (first call before any `sigar_getprocs`)
  or when the entry is absent/stale — in those cases the kernel call proceeds as normal.

### Expected impact
- ~500 zombie/dead PIDs × ~0.5 PTQL-Args scans/s = ~250 `getargs` syscalls/s eliminated.
- `getargs` error count drops significantly (errors were the zombie/dead failures).
- No change to behaviour for live processes.
- **Limitation:** the pre-check only fires after `pinfocache` has been populated for a PID
  (i.e. after the first `sigar_getprocs()` or batch sweep for that PID). Before Sub-Task 8
  the cache was cold until `sigar_proc_stat_get` ran its loop. Sub-Task 8 ensures the
  batch sweep pre-warms the cache, so the zombie check is effective from the first PTQL scan.

---

## Sub-Task 8 — Prime `pinfocache` from the batch enumeration sweep

**Status:** [x] done

### Problem
`sigar_proc_stat_get()` calls `sigar_proc_list_get(NULL)` → `sigar_os_proc_list_get()`,
which uses `getprocs(count=32)` to read `procsinfo64` data for all N processes. That data
was immediately discarded — only `pi_pid` was extracted. Then the subsequent loop called
`sigar_proc_state_get()` for every PID, which called `sigar_getprocs()` → `getprocs(count=1)`
for every PID, re-fetching the same kernel data a second time.

This was the dominant remaining `getprocs` cost: **N per-PID `getprocs(1)` calls every
time the proc list TTL expired** (every 2s → N/2 per second). With N=1200: 600/s.

### Root cause
`sigar_os_proc_list_get` used `struct procsinfo` (the 32-bit variant) for the batch buffer,
while `pinfocache` stores `struct procsinfo64`. The data was incompatible, so the batch
results could not be stored in the cache.

### Implemented
- **Switched batch buffer** in `sigar_os_proc_list_get` from `struct procsinfo infos[32]`
  to `struct procsinfo64 infos[32]` — `getprocs` accepts both, selecting the struct via
  the `sizeof` argument. No change to syscall count or semantics.
- **Populate `pinfocache` during the sweep**: for each batch entry, call
  `sigar_cache_get()` for that PID and write the `procsinfo64` data into the entry,
  setting `fetched = now`, `valid = 1`. Fresh entries (still within `SIGAR_PINFO_CACHE_EXPIRE`)
  are skipped — a more recent per-PID fetch is never overwritten by the batch.
  `processor_valid` is reset to 0 on write (affinity will be re-fetched by `getthrds` on
  next `sigar_proc_state_get` for that PID).
- **`pinfocache` lazily initialised** inside `sigar_os_proc_list_get` as well, so the
  batch sweep can populate it even before `sigar_getprocs()` is first called.
- `pinfo_cache_entry_t` typedef moved above `sigar_os_proc_list_get` to resolve the
  forward reference.

### Expected impact
- After the batch sweep, every `sigar_getprocs(pid)` call for the enumerated PIDs is a
  **cache hit** — zero `getprocs(count=1)` calls fire in the subsequent loop.
- The entire `sigar_proc_stat_get()` costs ~6 batch `getprocs` calls (for N=1200) instead
  of 6 batch + 1200 per-PID calls.
- At steady state: only batch sweeps remain (~3 batch-getprocs/s at 2s proc list TTL),
  replacing the previous ~600 per-PID `getprocs(1)/s`.
- Sub-Task 7 zombie skip now works from the **first** PTQL scan, not just after the
  `sigar_proc_stat_get` loop has run, because the batch sweep pre-populates `pi_state`.

### Relevant context
- `sigar_os_proc_list_get`: [`src/os/aix/aix_sigar.c:677`](src/os/aix/aix_sigar.c:677)
- `pinfo_cache_entry_t` typedef: [`src/os/aix/aix_sigar.c:675`](src/os/aix/aix_sigar.c:675)
- `SIGAR_PINFO_CACHE_EXPIRE`: [`src/os/aix/sigar_os.h:65`](src/os/aix/sigar_os.h:65)

---

## Sub-Task 9 — Skip `getthrds()` via `SIGAR_SKIP_PROC_AFFINITY` env var

**Status:** [x] done

### Problem

`getthrds()` is called by `sigar_proc_state_get()` solely to populate `procstate->processor`
(CPU affinity via `ti_affinity`). This field maps to `ProcState.getProcessor()` in Java.
The field is not used by the Instana agent. At N=1200 processes and a 5s TTL, the cold-miss
rate is still 1200/5 = **240 `getthrds`/s**. Each cold miss also resets `processor_valid = 0`
which paired with the TTL expiry causes unavoidable steady-state cost even with Sub-Task 4
caching in place.

### Implemented

- `int skip_proc_affinity` added to `SIGAR_T_BASE` in
  [`include/sigar_private.h`](include/sigar_private.h).
- Set at startup in `sigar_open()` ([`src/sigar.c`](src/sigar.c)):
  ```c
  (*sigar)->skip_proc_affinity = getenv("SIGAR_ENABLE_PROC_AFFINITY") ? 0 : 1;
  ```
  Absent = 1 (default on — skipping is the default). Set `SIGAR_ENABLE_PROC_AFFINITY=1`
  to restore the full `getthrds` lookup.
- Guard in `sigar_proc_state_get()` ([`src/os/aix/aix_sigar.c`](src/os/aix/aix_sigar.c)):
  if `skip_proc_affinity` is set, `procstate->processor` is immediately set to
  `SIGAR_FIELD_NOTIMPL` and the entire `getthrds` / cache-write block is skipped.
  The Sub-Task 4 `processor_valid` cache path is unchanged when the env var is set.

### Expected impact (default, env var absent)

- **Zero `getthrds` syscalls** from any `sigar_proc_state_get()` call.
- `ProcState.getProcessor()` returns `SIGAR_FIELD_NOTIMPL` (same as a failed `getthrds`).
- Thread count (`procstate->threads` / `ProcState.getThreads()`) is unaffected — it comes
  from `pinfo->pi_thcount` (part of `procsinfo64`, in `pinfocache`).

### Non-impact

- All other fields of `sigar_proc_state_t` are unaffected.
- No change to any platform other than AIX (flag is in `SIGAR_T_BASE` but only
  `sigar_proc_state_get` on AIX references it, since `getthrds` is AIX-only).
