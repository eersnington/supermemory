# Patched Server Benchmark Results

**Artifact:** `.memory-bench/patch-compare/2026-06-15T21-06-21-591Z/summary.md` _(gitignored)_

**Command:**

```sh
RUN_COUNT=5 READY_SETTLE_MS=2000 POST_SEARCH_IDLE_MS=35000 bun bench-tooling/compare-patched-server.ts
```

---

## Configuration

| Setting | Value |
| :--- | ---: |
| Runs per case | `5` |
| Ready settle before first search | `2000ms` |
| Post-search idle before RSS sample | `35000ms` |
| RSS scope | server process tree |
| Stock binary | `~/.supermemory/bin/supermemory-server.stock-5a5932a9.bak` |
| Stock sha256 | `5a5932a9d9aa72239f61e6824b8f16d074c5752c9ee54f8ce366ea6b642e9395` |
| Patched binary | `.memory-bench/patch-compare/2026-06-15T21-06-21-591Z/bin/supermemory-server-patched` |
| Patched sha256 | `5b5ae3cf6ecec0c167979d50ae6ad2248ac853f73f5ffae3503375482784c85f` |

---

## Verdict

**PASS:** the patched binary met the startup and behavior thresholds.

No stable memory win was found in this run. The patch should be read as a startup-readiness improvement, not an RSS reduction.

---

## Aggregate Summary

| Case | Ready p50 | First Search p50 | Peak RSS p50 | Post-Search Idle RSS p50 |
| :--- | ---: | ---: | ---: | ---: |
| Stock | 2,870 ms | 63 ms | 1,568 MB | 734 MB |
| Patched | 1,450 ms | 76 ms | 1,576 MB | 836 MB |

## Patch Impact

| Metric | Change |
| :--- | ---: |
| Ready p50 | 1,420 ms faster, 49% lower |
| First search p50 after settle | 13 ms slower |
| Peak RSS p50 | 8 MB higher |
| Post-search idle RSS p50 | 102 MB higher |

---

## Summary

| Result | Evidence |
| :--- | :--- |
| Startup readiness improved significantly | Patched p50 ready: **1,450 ms** vs stock: **2,870 ms** |
| First search stayed within the allowed threshold | Patched p50 first search: **76 ms** vs stock: **63 ms** |
| Peak RSS did not improve | Patched p50 peak RSS: **1,576 MB** vs stock: **1,568 MB** |
| Post-search idle RSS did not improve | Patched p50 idle RSS: **836 MB** vs stock: **734 MB** |
| Patch behavior was visible in logs | Patched logs included `[patch] background embedding warmup enabled` after readiness |
| Stock workload defaults were preserved | Patched logs still showed stock model, pool size, ingest concurrency, and batch size |

---

## Interpretation

Stock startup waits for local embedding prewarm before serving HTTP. The patched binary starts the HTTP server first, marks readiness, then warms local embeddings in the background.

Because first search was measured after a `2000ms` settle window, the background warmup had time to complete in the p50 case. A search sent immediately after readiness can still pay cold embedding load latency.

RSS is measured across the server process tree. Under that measurement, the startup-only patch did not reduce memory. Experimental idle-shutdown and GC variants were not kept because they did not produce a stable p50 memory win while preserving the behavioral assertions.

---

## Individual Runs

| Iteration | Stock Ready | Patched Ready | Stock First Search | Patched First Search | Stock Peak RSS | Patched Peak RSS | Stock Idle RSS | Patched Idle RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2,277 ms | 1,447 ms | 63 ms | 79 ms | 1,165 MB | 1,576 MB | 466 MB | 744 MB |
| 2 | 2,772 ms | 1,463 ms | 59 ms | 75 ms | 1,481 MB | 1,460 MB | 400 MB | 836 MB |
| 3 | 2,876 ms | 1,450 ms | 64 ms | 76 ms | 1,595 MB | 1,406 MB | 786 MB | 1,051 MB |
| 4 | 2,870 ms | 1,449 ms | 62 ms | 103 ms | 1,580 MB | 1,682 MB | 734 MB | 1,159 MB |
| 5 | 3,085 ms | 1,548 ms | 80 ms | 71 ms | 1,568 MB | 1,601 MB | 1,044 MB | 622 MB |

---

## Assertions

- Patched ready p50 beats stock by at least `500ms` or `25%`.
- Patched first search after settle is within `250ms` of stock p50.
- Patched startup logs include the patch label after readiness.
- Patched startup loads local embeddings after readiness and records the ingest baseline after warmup.
- Stock defaults for model, pool size, ingest concurrency, and batch size remain visible in patched logs.
