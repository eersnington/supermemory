# Patched Server Benchmark Results

**Artifact:** `.memory-bench/patch-compare/2026-06-15T12-14-18-579Z/summary.md` _(gitignored)_

**Command:**

```sh
bun bench-tooling/compare-patched-server.ts
```

---

## Configuration

| Setting | Value |
| :--- | ---: |
| Runs per case | `5` |
| Ready settle before first search | `2000ms` |
| Stock binary | `~/.supermemory/bin/supermemory-server.stock-5a5932a9.bak` |
| Stock sha256 | `5a5932a9d9aa72239f61e6824b8f16d074c5752c9ee54f8ce366ea6b642e9395` |
| Patched binary | `.memory-bench/patch-compare/2026-06-15T12-14-18-579Z/bin/supermemory-server-patched` |
| Patched sha256 | `5b5ae3cf6ecec0c167979d50ae6ad2248ac853f73f5ffae3503375482784c85f` |

---

## Verdict

**PASS:** the patched binary met the startup and behavior thresholds.

The patch moved local embedding warmup out of the HTTP readiness path. It did not produce a meaningful memory win in this run.

---

## Aggregate Summary

| Case | Ready p50 | First Search p50 | Peak RSS p50 |
| :--- | ---: | ---: | ---: |
| Stock | 1,742 ms | 74 ms | 1,590 MB |
| Patched | 931 ms | 64 ms | 1,589 MB |

## Patch Impact

| Metric | Change |
| :--- | ---: |
| Ready p50 | 811 ms faster, 47% lower |
| First search p50 after settle | 10 ms faster |
| Peak RSS p50 | 1 MB lower |

---

## Summary

| Result | Evidence |
| :--- | :--- |
| Startup readiness improved significantly | Patched p50 ready: **931 ms** vs stock: **1,742 ms** |
| First search did not regress after warmup settle | Patched p50 first search: **64 ms** vs stock: **74 ms** |
| Peak RSS was effectively unchanged | Patched p50 peak RSS: **1,589 MB** vs stock: **1,590 MB** |
| Patch behavior was visible in logs | Patched logs included `[patch] background embedding warmup enabled` after readiness |
| Stock workload defaults were preserved | Patched logs still showed stock model, pool size, ingest concurrency, and batch size |

---

## Interpretation

Stock startup waits for local embedding prewarm before serving HTTP. The patched binary starts the HTTP server first, marks readiness, then warms local embeddings in the background.

Because first search was measured after a `2000ms` settle window, the background warmup had time to complete. A search sent immediately after readiness can still pay cold embedding load latency.

Peak RSS was unchanged, so this result should be read as a startup-readiness improvement, not a memory reduction.

---

## Individual Runs

| Iteration | Stock Ready | Patched Ready | Stock First Search | Patched First Search | Stock Peak RSS | Patched Peak RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2,062 ms | 936 ms | 74 ms | 64 ms | 1,590 MB | 1,581 MB |
| 2 | 1,740 ms | 831 ms | 85 ms | 55 ms | 1,590 MB | 1,596 MB |
| 3 | 1,743 ms | 830 ms | 58 ms | 64 ms | 1,553 MB | 1,589 MB |
| 4 | 1,742 ms | 933 ms | 77 ms | 75 ms | 1,604 MB | 1,576 MB |
| 5 | 1,741 ms | 931 ms | 69 ms | 88 ms | 1,552 MB | 1,604 MB |

---

## Assertions

- Patched ready p50 beats stock by at least `500ms` or `25%`.
- Patched first search after settle is within `250ms` of stock p50.
- Patched startup logs include the patch label after readiness.
- Patched startup loads local embeddings after readiness and records the ingest baseline after warmup.
- Stock defaults for model, pool size, ingest concurrency, and batch size remain visible in patched logs.
