# Low-Memory Benchmark Results

Artifact: `.memory-bench/profile-matrix/20260615-030231-parallel/combined/summary.md` (gitignored)

Command:

```sh
RUN_COUNT=10 PARALLEL_JOBS=10 SCENARIOS=stock-30s,optimized-30s bun run bench:low-memory:parallel
```

Configuration:

| Setting | Value |
|---|---:|
| Workers | `10` |
| Runs per scenario | `10` |
| Total scenario runs | `20` |
| Sample interval | `1s` |
| Ready idle | `20s` |
| Post-search idle | `40s` |
| Post-add idle | `40s` |

Scenario settings:

| Scenario | Env | Background warmup |
|---|---|---|
| `stock-30s` | default | no |
| `optimized-30s` | `SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1`, `SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000` | yes |

Aggregate cells use `avg / p50 / p95`. RSS idle cells also show the lowest observed min sample across runs.

## Aggregate Summary

| Scenario | Runs | Ready | Peak RSS | Ready Idle Last | Post Search Last | Post Add Last | Warmup | First Search | Second Search | Shutdown Crashes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| stock-30s | 10 | 5925 ms / 5677 ms / 8297 ms | 851 MB / 816 MB / 1039 MB | 301 MB / 284 MB / 415 MB ; min 97 MB | 261 MB / 280 MB / 374 MB ; min 97 MB | 267 MB / 260 MB / 313 MB ; min 212 MB | n/a | 105 ms / 107 ms / 133 ms | 107 ms / 107 ms / 179 ms | 10/10 |
| optimized-30s | 10 | 1627 ms / 1651 ms / 1885 ms | 1165 MB / 1071 MB / 1602 MB | 398 MB / 395 MB / 480 MB ; min 251 MB | 371 MB / 357 MB / 472 MB ; min 288 MB | 245 MB / 239 MB / 330 MB ; min 192 MB | 2198 ms / 2131 ms / 2861 ms | 78 ms / 78 ms / 91 ms | 130 ms / 131 ms / 199 ms | 10/10 |

## Summary

| Result | Evidence |
|---|---|
| Startup readiness improved significantly. | `optimized-30s` p50 ready was `1651 ms`; `stock-30s` p50 ready was `5677 ms`. |
| Peak RSS did not improve. | `optimized-30s` p50 peak RSS was `1071 MB`; `stock-30s` p50 peak RSS was `816 MB`. |
| Ready-idle and post-search idle RSS were higher in the optimized profile. | Ready-idle p50 was `395 MB` optimized vs `284 MB` stock; post-search p50 was `357 MB` optimized vs `280 MB` stock. |
| Post-add settled RSS was slightly lower in the optimized profile. | Post-add p50 was `239 MB` optimized vs `260 MB` stock. |
| First search latency improved after background warmup. | First-search p50 was `78 ms` optimized vs `107 ms` stock. |
| Second search latency was worse in the optimized profile. | Second-search p50 was `131 ms` optimized vs `107 ms` stock. |
| Shutdown reliability was unchanged. | Both scenarios crashed on shutdown in `10/10` runs. |

## Three Profiles

| Profile | Env | Warmup behavior | Purpose |
|---|---|---|---|
| Stock | default | Embeddings are prewarmed during normal startup. | Baseline behavior for the self-hosted server. |
| Cold optimized | `SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1`, `SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000` | No benchmark background warmup. The first real embedding request pays cold-load cost. | Measures the raw tradeoff of faster HTTP readiness versus cold first-search latency. Not included in this 10-worker result. |
| Balanced optimized | `SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1`, `SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000` | The benchmark runs one authenticated background search after HTTP readiness. | Moves embedding load out of the startup readiness path while trying to keep the first user-visible search warm. This is `optimized-30s` in this result. |

This 10-worker run compares Stock (`stock-30s`) against Balanced optimized (`optimized-30s`). It does not set `SUPERMEMORY_INGEST_CONCURRENCY`, `SUPERMEMORY_EMBEDDING_RAM_LIMIT`, or `SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE` in the optimized scenario.

## Likely Explanation

The optimized profile wins on readiness because it skips embedding prewarm before the HTTP server becomes ready. The expensive embedding load still happens, but it is moved into the post-readiness background warmup window.

Peak RSS is higher for the optimized profile in this run because all 10 workers reach HTTP readiness quickly, then perform background embedding warmup at roughly the same time. That creates more overlap between server startup, PGlite/runtime memory, and embedding model load across workers. Stock startup is slower, so its embedding prewarm work is more staggered across the 10 workers.

Ready-idle RSS is not lower because the ready-idle phase starts after the optimized server is ready and after background warmup has begun. With a `20s` ready-idle window and a `30s` embedding idle timeout, the measurement often catches the optimized profile before the worker has fully idled out.

Post-add settled RSS is slightly lower in the optimized profile because the longer post-add idle window gives the `30s` embedding idle timeout enough time to release the worker after document work finishes.

The shutdown crashes are a separate runtime reliability issue. They happen after request timings are collected and affect both profiles equally in this run.

## Individual Runs

| Scenario | Ready | Peak RSS | Ready Idle Last/Min | Post Search Last/Min | Post Add Last/Min | Warmup | First Search | Second Search | Shutdown Crash |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| stock-30s | 5544 ms | 1039 MB | 204 MB / 169 MB | 337 MB / 255 MB | 245 MB / 212 MB | n/a | 105 ms (200) | 80 ms (200) | yes |
| optimized-30s | 1139 ms | 1202 MB | 344 MB / 344 MB | 373 MB / 314 MB | 212 MB / 212 MB | 2090 ms (200) | 66 ms (200) | 86 ms (200) | yes |
| stock-30s | 7476 ms | 703 MB | 403 MB / 338 MB | 142 MB / 142 MB | 305 MB / 305 MB | n/a | 81 ms (200) | 123 ms (200) | yes |
| optimized-30s | 1758 ms | 1012 MB | 354 MB / 354 MB | 288 MB / 288 MB | 220 MB / 198 MB | 2861 ms (200) | 83 ms (200) | 178 ms (200) | yes |
| stock-30s | 5236 ms | 982 MB | 236 MB / 98 MB | 374 MB / 276 MB | 233 MB / 217 MB | n/a | 121 ms (200) | 61 ms (200) | yes |
| optimized-30s | 1459 ms | 1602 MB | 412 MB / 251 MB | 457 MB / 326 MB | 237 MB / 207 MB | 1731 ms (200) | 78 ms (200) | 63 ms (200) | yes |
| stock-30s | 4702 ms | 1016 MB | 236 MB / 97 MB | 278 MB / 264 MB | 260 MB / 218 MB | n/a | 133 ms (200) | 63 ms (200) | yes |
| optimized-30s | 1885 ms | 1587 MB | 480 MB / 269 MB | 472 MB / 318 MB | 241 MB / 192 MB | 2013 ms (200) | 78 ms (200) | 75 ms (200) | yes |
| stock-30s | 4202 ms | 849 MB | 233 MB / 97 MB | 339 MB / 257 MB | 259 MB / 232 MB | n/a | 124 ms (200) | 83 ms (200) | yes |
| optimized-30s | 1693 ms | 1279 MB | 420 MB / 308 MB | 419 MB / 298 MB | 212 MB / 212 MB | 2370 ms (200) | 86 ms (200) | 165 ms (200) | yes |
| stock-30s | 8297 ms | 735 MB | 371 MB / 324 MB | 97 MB / 97 MB | 256 MB / 256 MB | n/a | 80 ms (200) | 179 ms (200) | yes |
| optimized-30s | 1774 ms | 1101 MB | 373 MB / 373 MB | 341 MB / 290 MB | 330 MB / 217 MB | 2633 ms (200) | 91 ms (200) | 142 ms (200) | yes |
| stock-30s | 6647 ms | 775 MB | 415 MB / 356 MB | 224 MB / 224 MB | 279 MB / 279 MB | n/a | 86 ms (200) | 125 ms (200) | yes |
| optimized-30s | 1545 ms | 1041 MB | 400 MB / 400 MB | 325 MB / 304 MB | 251 MB / 201 MB | 2171 ms (200) | 72 ms (200) | 163 ms (200) | yes |
| stock-30s | 5253 ms | 863 MB | 279 MB / 279 MB | 282 MB / 279 MB | 233 MB / 233 MB | n/a | 108 ms (200) | 100 ms (200) | yes |
| optimized-30s | 1609 ms | 1004 MB | 389 MB / 382 MB | 372 MB / 332 MB | 241 MB / 234 MB | 1997 ms (200) | 88 ms (200) | 110 ms (200) | yes |
| stock-30s | 5810 ms | 762 MB | 289 MB / 289 MB | 285 MB / 271 MB | 313 MB / 292 MB | n/a | 109 ms (200) | 113 ms (200) | yes |
| optimized-30s | 1599 ms | 1000 MB | 381 MB / 381 MB | 338 MB / 323 MB | 236 MB / 193 MB | 1609 ms (200) | 62 ms (200) | 120 ms (200) | yes |
| stock-30s | 6079 ms | 783 MB | 346 MB / 342 MB | 254 MB / 254 MB | 284 MB / 273 MB | n/a | 101 ms (200) | 139 ms (200) | yes |
| optimized-30s | 1804 ms | 820 MB | 422 MB / 422 MB | 328 MB / 328 MB | 266 MB / 204 MB | 2502 ms (200) | 74 ms (200) | 199 ms (200) | yes |
