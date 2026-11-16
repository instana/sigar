# Windows process info cache plan

## Overview

Commit 70da3eb added a per-PID cache (`pinfocache`, TTL `SIGAR_PINFO_CACHE_EXPIRE` = 5s) on AIX. It avoids one kernel call per process when `sigar_proc_stat_get` loops over every PID ([`src/sigar.c`](src/sigar.c:279)).

Windows has the same problem. [`get_proc_info()`](src/os/win32/win32_sigar.c:1370) reads the whole `HKEY_PERFORMANCE_DATA` "Process" object through `RegQueryValueEx` ([`get_perf_object_inst`](src/os/win32/win32_sigar.c:180)) for every PID. The existing single-slot cache `sigar->pinfo` only helps repeated calls for the **same** PID within 2s. While walking all instances it extracts only the requested PID and throws the rest away. That makes N processes cost N full registry snapshots.

**Is a similar fix possible on Windows? Yes.** One registry read already contains every process's name, ppid, priority, threads, handles, memory, page faults and I/O bytes. It is enough to keep all instances from a single read and serve later lookups from a per-PID cache.

Note: Windows `state` is hardcoded to `'R'` ([line 1462](src/os/win32/win32_sigar.c:1462)). The cost is therefore entirely the registry read, not a per-state query.

**Approach (confirmed with user):** a per-PID `sigar_cache_t` (AIX style) with a 5s TTL, filled for all processes from one registry read. The existing `sigar_proc_fd_get` force-refresh behaviour is kept.

## Sub-Tasks

### 1. Add the per-PID cache to the Windows `sigar_t`
- **Intent:** Provide storage for the full-process snapshot, replacing the single-slot `sigar->pinfo`.
- **Expected Outcomes:** `sigar_t` has a `pinfocache` and a snapshot timestamp. The cache is created lazily and destroyed in `sigar_os_close`. Nothing else changes in behaviour yet.
- **Todo List:**
  - [x] In `sigar_os.h` add `sigar_cache_t *pinfocache`, a snapshot time field (`time_t`), and `#define SIGAR_PINFO_CACHE_EXPIRE 5` (same value as AIX).
  - [x] Keep `sigar_win32_pinfo_t` as the cached value type. Its `pid` and `mtime` fields can be reused.
  - [x] In `sigar_os_open` init `pinfocache = NULL` and the snapshot time to 0. Remove the `pinfo.pid = -1` init if `sigar->pinfo` goes away.
  - [x] In `sigar_os_close` call `sigar_cache_destroy(sigar->pinfocache)`. The default `free_value` frees entries.
- **Relevant Context:** [`src/os/win32/sigar_os.h`](src/os/win32/sigar_os.h:309) (`sigar_win32_pinfo_t`), [`sigar_os.h:547`](src/os/win32/sigar_os.h:547) (`struct sigar_t`), [`win32_sigar.c:512-629`](src/os/win32/win32_sigar.c:512) (open/close). AIX reference: [`src/os/aix/sigar_os.h:54-69`](src/os/aix/sigar_os.h:54), [`aix_sigar.c:169-213`](src/os/aix/aix_sigar.c:169). Cache API: [`include/sigar_util.h:188-199`](include/sigar_util.h:188).
- **Status:** `[x] done`

### 2. Make `get_proc_info` fill the cache for all processes from one registry read
- **Intent:** Pay the registry cost once per TTL window instead of once per PID.
- **Expected Outcomes:**
  - The first `sigar_proc_state_get`, `sigar_proc_mem_get` or `sigar_proc_cumulative_disk_io_get` call reads the perf data once and stores every process instance in the cache.
  - Later calls for any PID within 5s do no registry read.
  - `sigar_proc_state_get`, `sigar_proc_mem_get` and `sigar_proc_cumulative_disk_io_get` copy from the cached entry. Output is unchanged.
- **Todo List:**
  - [x] Split `get_proc_info` into two parts: a "refresh snapshot" step and a "lookup PID" step.
    - Refresh: `get_process_object`, build the counter offset table, then loop over all instances. For each instance create or update the cache entry keyed by PID, using the same field extraction as today.
    - Lookup: `sigar_cache_find` the PID and check the snapshot age against `SIGAR_PINFO_CACHE_EXPIRE`.
  - [x] Run `sigar_perform_cleanup_if_necessary` before taking any entry pointer, as AIX does ([`aix_sigar.c:762`](src/os/aix/aix_sigar.c:762)).
  - [x] Decide how to handle a PID that is absent from a fresh snapshot (a process started within the TTL). Proposed rule: if the snapshot was not taken during this call, refresh once and re-lookup. Otherwise return `SIGAR_NO_SUCH_PROCESS`. This keeps current correctness for new PIDs without a per-call read for dead PIDs.
  - [x] Have callers read from the returned cache entry, not `sigar->pinfo`. Update `sigar_proc_mem_get`, `sigar_proc_cumulative_disk_io_get`, `sigar_proc_state_get` and `sigar_proc_fd_get`.
  - [x] Skip PID 0 and anything else the current loop skips. Preserve the existing `SIGAR_W2A` name conversion.
- **Relevant Context:** [`win32_sigar.c:1370-1480`](src/os/win32/win32_sigar.c:1370) (`get_proc_info`), [`1174-1209`](src/os/win32/win32_sigar.c:1174) (mem and disk io), [`1348-1368`](src/os/win32/win32_sigar.c:1348) (state), `PERF_VAL` macro at [line 117](src/os/win32/win32_sigar.c:117), AIX reference [`aix_sigar.c:748-806`](src/os/aix/aix_sigar.c:748) (`sigar_getprocs`).
- **Status:** `[x] done`

### 3. Keep the force-refresh in `sigar_proc_fd_get`
- **Intent:** Preserve current semantics. `sigar_proc_fd_get` sets `pinfo->pid = -1` today to force a fresh handle count.
- **Expected Outcomes:** `sigar_proc_fd_get` still returns an up-to-date handle count. It does this by invalidating the snapshot time, or by passing a force flag to the refresh step, before the lookup. The handle count comes from the cache entry.
- **Todo List:**
  - [x] Replace the `pinfo->pid = -1` hack ([line 1649](src/os/win32/win32_sigar.c:1649)) with an explicit force-refresh.
  - [x] Check that this does not defeat caching for the other callers. One force refresh repopulates the whole cache, which is acceptable.
- **Relevant Context:** [`win32_sigar.c:1643-1657`](src/os/win32/win32_sigar.c:1643).
- **Status:** `[x] done`

### 4. Prime the cache from the process-list path
- **Intent:** The user asked to prime the cache from the proc list, as AIX does in `sigar_os_proc_list_get`.
- **Expected Outcomes:**
  - `sigar_proc_list_get_perf`, the fallback path that already reads the perf object, fills the cache using the shared refresh logic. The `sigar_proc_stat_get` loop then needs no further registry reads.
  - The normal `EnumProcesses` path is unchanged. The first `sigar_proc_state_get` call in the loop fills the cache for all PIDs.
- **Todo List:**
  - [x] Reuse the Task 2 refresh step in `sigar_proc_list_get_perf`.
  - [x] Do **not** add a registry read to the `EnumProcesses` path. It returns PIDs only, and adding the read would slow callers that only want a list.
  - [x] Note that `sigar_os_proc_list_get` reuses `sigar->perfbuf` for `EnumProcesses`. The cache holds copied values, so this is safe. Do not cache pointers into `perfbuf`.
- **Relevant Context:** [`win32_sigar.c:1056-1161`](src/os/win32/win32_sigar.c:1056), AIX reference [`aix_sigar.c:686-746`](src/os/aix/aix_sigar.c:686).
- **Status:** `[x] done`

### 5. Verify
- **Intent:** Confirm the cache cuts registry reads and does not change results.
- **Expected Outcomes:** A Windows build succeeds. Process stat, state, mem, fd and disk-io results match pre-change behaviour. A `sigar_proc_stat_get` run shows one registry read per refresh window.
- **Todo List:**
  - [ ] Build the Windows DLL as described in `README.md` ("Building Windows 32bit & 64bit DLLs"). This needs a Windows host.
  - [ ] Check for existing tests that exercise Windows proc functions. None have been found yet, so search `bindings/` and `src/` before writing any.
  - [ ] Manually compare `sigar_proc_state_get` and `sigar_proc_stat_get` output before and after on the same host.
  - [x] Check that memory is freed on `sigar_os_close` and on cache expiry (valgrind/ASAN is not available on Windows, so use a code review of the free path).
- **Relevant Context:** [`README.md`](README.md:15).
- **Status:** `[-] in progress (Windows build, tests search and before/after comparison remain)`

## Risks and Trade-offs
- **Staleness:** mem, handles and disk io may now be up to 5s old (previously 2s, for the same PID only). AIX accepts the same trade-off. If this is unacceptable, use `SIGAR_LAST_PROC_EXPIRE` (2s) instead.
- **Counter semantics:** the I/O counters are read as `DWORD` through `PERF_VAL`. This is existing behaviour and out of scope.
- **Thread safety:** the existing single `sigar->pinfo` was not thread-safe either. Callers share one `sigar_t` the same way as before.
- **No Windows build or test environment is available here.** The change cannot be compiled or run on this Linux host.
