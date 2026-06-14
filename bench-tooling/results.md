# Low-Memory Benchmark Results

**Artifact:** `.memory-bench/profile-matrix/20260615-030231-parallel/combined/summary.md` _(gitignored)_

**Command:**

```sh
RUN_COUNT=10 PARALLEL_JOBS=10 SCENARIOS=stock-30s,optimized-30s bun run bench:low-memory:parallel
```

---

## Configuration

| Setting | Value |
| :--- | ---: |
| Workers | `10` |
| Runs per scenario | `10` |
| Total scenario runs | `20` |
| Sample interval | `1s` |
| Ready idle | `20s` |
| Post-search idle | `40s` |
| Post-add idle | `40s` |

## Scenario Settings

| Scenario | Env | Background warmup |
| :--- | :--- | :--- |
| `stock-30s` | default | No |
| `optimized-30s` | `SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1`<br>`SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000` | Yes |

> **Note:** Aggregate cells show `avg / p50 / p95`. RSS idle columns also include the lowest observed min across runs.

---

## Aggregate Summary

### Timing (ms)

| Scenario | Ready avg | Ready p50 | Ready p95 | Warmup avg | Warmup p50 | Warmup p95 | 1st Search p50 | 2nd Search p50 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `stock-30s` | 5,925 | 5,677 | 8,297 | n/a | n/a | n/a | 107 | 107 |
| `optimized-30s` | 1,627 | 1,651 | 1,885 | 2,198 | 2,131 | 2,861 | 78 | 131 |

### Memory — Peak RSS (MB)

| Scenario | avg | p50 | p95 |
| :--- | ---: | ---: | ---: |
| `stock-30s` | 851 | 816 | 1,039 |
| `optimized-30s` | 1,165 | 1,071 | 1,602 |

### Memory — Idle RSS (MB) · avg / p50 / p95 · min

| Scenario | Ready Idle avg | Ready Idle p50 | Ready Idle p95 | Ready Idle min | Post-Search avg | Post-Search p50 | Post-Search p95 | Post-Search min | Post-Add avg | Post-Add p50 | Post-Add p95 | Post-Add min |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `stock-30s` | 301 | 284 | 415 | 97 | 261 | 280 | 374 | 97 | 267 | 260 | 313 | 212 |
| `optimized-30s` | 398 | 395 | 480 | 251 | 371 | 357 | 472 | 288 | 245 | 239 | 330 | 192 |

### Reliability

| Scenario | Runs | Shutdown Crashes |
| :--- | ---: | ---: |
| `stock-30s` | 10 | 10/10 |
| `optimized-30s` | 10 | 10/10 |

---

## Summary

| Result | Evidence |
| :--- | :--- |
| ✅ Startup readiness improved significantly | `optimized-30s` p50 ready: **1,651 ms** vs `stock-30s` p50 ready: **5,677 ms** |
| ❌ Peak RSS did not improve | `optimized-30s` p50 peak RSS: **1,071 MB** vs `stock-30s`: **816 MB** |
| ❌ Ready-idle and post-search idle RSS were higher in optimized | Ready-idle p50: **395 MB** (optimized) vs **284 MB** (stock); post-search p50: **357 MB** vs **280 MB** |
| ✅ Post-add settled RSS slightly lower in optimized | Post-add p50: **239 MB** (optimized) vs **260 MB** (stock) |
| ✅ First search latency improved after background warmup | First-search p50: **78 ms** (optimized) vs **107 ms** (stock) |
| ❌ Second search latency was worse in optimized | Second-search p50: **131 ms** (optimized) vs **107 ms** (stock) |
| ⚠️ Shutdown reliability unchanged | Both scenarios crashed on shutdown in **10/10** runs |

---

## Profiles

| Profile | Env | Warmup Behavior | Purpose |
| :--- | :--- | :--- | :--- |
| **Stock** | default | Embeddings prewarmed during normal startup | Baseline behavior for the self-hosted server |
| **Cold optimized** | `SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1`<br>`SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000` | No background warmup — first real embedding request pays cold-load cost | Measures the raw tradeoff of faster HTTP readiness vs. cold first-search latency. _Not included in this 10-worker result._ |
| **Balanced optimized** | `SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1`<br>`SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000` | Benchmark runs one authenticated background search after HTTP readiness | Moves embedding load out of the startup readiness path while trying to keep the first user-visible search warm. This is `optimized-30s` in this result. |

> This 10-worker run compares **Stock** (`stock-30s`) against **Balanced optimized** (`optimized-30s`). It does not set `SUPERMEMORY_INGEST_CONCURRENCY`, `SUPERMEMORY_EMBEDDING_RAM_LIMIT`, or `SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE` in the optimized scenario.

---

## Likely Explanation

The optimized profile wins on readiness because it skips embedding prewarm before the HTTP server becomes ready. The expensive embedding load still happens, but it is moved into the post-readiness background warmup window.

Peak RSS is higher for the optimized profile in this run because all 10 workers reach HTTP readiness quickly, then perform background embedding warmup at roughly the same time. That creates more overlap between server startup, PGlite/runtime memory, and embedding model load across workers. Stock startup is slower, so its embedding prewarm work is more staggered across the 10 workers.

Ready-idle RSS is not lower because the ready-idle phase starts after the optimized server is ready and after background warmup has begun. With a `20s` ready-idle window and a `30s` embedding idle timeout, the measurement often catches the optimized profile before the worker has fully idled out.

Post-add settled RSS is slightly lower in the optimized profile because the longer post-add idle window gives the `30s` embedding idle timeout enough time to release the worker after document work finishes.

The shutdown crashes are a separate runtime reliability issue. They happen after request timings are collected and affect both profiles equally in this run.

---

## Individual Runs

### `stock-30s`

| Run | Ready (ms) | Peak RSS (MB) | Ready Idle last (MB) | Ready Idle min (MB) | Post-Search last (MB) | Post-Search min (MB) | Post-Add last (MB) | Post-Add min (MB) | 1st Search (ms) | 2nd Search (ms) | Crash |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| 1 | 5,544 | 1,039 | 204 | 169 | 337 | 255 | 245 | 212 | 105 | 80 | ❌ |
| 2 | 7,476 | 703 | 403 | 338 | 142 | 142 | 305 | 305 | 81 | 123 | ❌ |
| 3 | 5,236 | 982 | 236 | 98 | 374 | 276 | 233 | 217 | 121 | 61 | ❌ |
| 4 | 4,702 | 1,016 | 236 | 97 | 278 | 264 | 260 | 218 | 133 | 63 | ❌ |
| 5 | 4,202 | 849 | 233 | 97 | 339 | 257 | 259 | 232 | 124 | 83 | ❌ |
| 6 | 8,297 | 735 | 371 | 324 | 97 | 97 | 256 | 256 | 80 | 179 | ❌ |
| 7 | 6,647 | 775 | 415 | 356 | 224 | 224 | 279 | 279 | 86 | 125 | ❌ |
| 8 | 5,253 | 863 | 279 | 279 | 282 | 279 | 233 | 233 | 108 | 100 | ❌ |
| 9 | 5,810 | 762 | 289 | 289 | 285 | 271 | 313 | 292 | 109 | 113 | ❌ |
| 10 | 6,079 | 783 | 346 | 342 | 254 | 254 | 284 | 273 | 101 | 139 | ❌ |

### `optimized-30s`

| Run | Ready (ms) | Peak RSS (MB) | Warmup (ms) | Ready Idle last (MB) | Ready Idle min (MB) | Post-Search last (MB) | Post-Search min (MB) | Post-Add last (MB) | Post-Add min (MB) | 1st Search (ms) | 2nd Search (ms) | Crash |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| 1 | 1,139 | 1,202 | 2,090 | 344 | 344 | 373 | 314 | 212 | 212 | 66 | 86 | ❌ |
| 2 | 1,758 | 1,012 | 2,861 | 354 | 354 | 288 | 288 | 220 | 198 | 83 | 178 | ❌ |
| 3 | 1,459 | 1,602 | 1,731 | 412 | 251 | 457 | 326 | 237 | 207 | 78 | 63 | ❌ |
| 4 | 1,885 | 1,587 | 2,013 | 480 | 269 | 472 | 318 | 241 | 192 | 78 | 75 | ❌ |
| 5 | 1,693 | 1,279 | 2,370 | 420 | 308 | 419 | 298 | 212 | 212 | 86 | 165 | ❌ |
| 6 | 1,774 | 1,101 | 2,633 | 373 | 373 | 341 | 290 | 330 | 217 | 91 | 142 | ❌ |
| 7 | 1,545 | 1,041 | 2,171 | 400 | 400 | 325 | 304 | 251 | 201 | 72 | 163 | ❌ |
| 8 | 1,609 | 1,004 | 1,997 | 389 | 382 | 372 | 332 | 241 | 234 | 88 | 110 | ❌ |
| 9 | 1,599 | 1,000 | 1,609 | 381 | 381 | 338 | 323 | 236 | 193 | 62 | 120 | ❌ |
| 10 | 1,804 | 820 | 2,502 | 422 | 422 | 328 | 328 | 266 | 204 | 74 | 199 | ❌ |
