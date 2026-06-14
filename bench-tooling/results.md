# Low-Memory Benchmark Results

This document explains the local self-hosted `supermemory-server` low-memory benchmark profile, how to run it, and how to interpret the current results.

## What Is Being Compared

| Area | Default server | Low-memory profile |
|---|---|---|
| Primary goal | Fast warm defaults and ingestion throughput | Lower startup/idle footprint without changing ingestion concurrency |
| Embedding startup | Prewarms local embeddings during startup | Skips startup prewarm |
| HTTP readiness | Can include more startup work | HTTP becomes ready before embedding work is forced |
| First search | Usually fast because embeddings are already warm | Fast after background warmup; slower if truly cold |
| Embedding idle timeout | Longer default idle window | `30000 ms` |
| Ingestion concurrency | `2` documents at a time | unchanged |
| Embedding batch size | `8` | `2` |
| Ingestion memory headroom | `1gb` above boot baseline | `1gb` above boot baseline |
| Bulk ingest speed | Baseline | Similar concurrency; smaller embedding batches may reduce peak throughput |
| Expected memory shape | More work is warm earlier and longer | Work is delayed, warmed in background, then released sooner after idle |

The benchmark profile keeps `SUPERMEMORY_EMBEDDING_RAM_LIMIT=1gb` and does not set `SUPERMEMORY_INGEST_CONCURRENCY`, so it does not change the server's default ingestion memory budget or document-level ingestion concurrency. This keeps the comparison focused on prewarm behavior, idle timeout, and embedding batch size.

## Profile Under Test

`bench-tooling/run.sh run-balanced` applies these defaults unless the variable is already set:

```sh
SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1
SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000
SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2
SUPERMEMORY_EMBEDDING_RAM_LIMIT=1gb
SUPERMEMORY_NO_OPEN=1
SUPERMEMORY_NO_UPDATE_CHECK=1
```

The balanced profile starts HTTP first, then runs one authenticated background search after readiness to load local embeddings. The goal is to preserve fast first real search latency while still allowing the embedding worker to shut down after an idle window.

## Benchmark Scenario

The main scenario is `balanced-30s-quick`:

| Phase | Duration | Purpose |
|---|---:|---|
| Ready idle | `20s` | Measure RSS after HTTP readiness and background warmup start |
| Post-search idle | `40s` | Allow the `30s` embedding idle timeout to fire after search |
| Post-add idle | `40s` | Allow memory used by add/ingestion work to settle |

The two `40s` idle windows are intentionally longer than `SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000`. Without those waits, the benchmark can measure latency and peak RSS, but it cannot show whether memory drops after idle.

## How to Run

Run the low-memory profile locally:

```sh
bun run bench:low-memory:run
```

Run a quick default-vs-profile measurement:

```sh
bun run bench:low-memory:measure
```

Run a 10-run parallel sample:

```sh
RUN_COUNT=10 PARALLEL_JOBS=10 SCENARIOS=balanced-30s-quick bun run bench:low-memory:parallel
```

Run a 100-run adaptive parallel benchmark:

```sh
RUN_COUNT=100 SCENARIOS=balanced-30s-quick bun run bench:low-memory:parallel
```

Run smaller async chunks and collect them later:

```sh
RUN_COUNT=5 SCENARIOS=balanced-30s-quick bun run bench:low-memory:async
```

```sh
bun run bench:low-memory:collect -- \
  .memory-bench/profile-matrix/combined-balanced-100 \
  .memory-bench/profile-matrix/*-async
```

Outputs are written under `.memory-bench/profile-matrix/<timestamp>/`. Structured results are in `summary.json`; human-readable tables are in `summary.md`.

## Latest 10-Run Parallel Result

Artifact: `.memory-bench/profile-matrix/20260615-023242-parallel/combined/summary.md`

Configuration:

| Setting | Value |
|---|---:|
| Total runs | `10` |
| Parallel workers | `10` |
| Runs per worker | `1` |
| Scenario | `balanced-30s-quick` |
| Ingestion memory headroom | `1gb` |
| Ingestion concurrency | default server setting |
| Embedding batch size | `2` |
| Sample interval | `1s` |

Aggregate cells use `avg / p50 / p95`.

| Metric | Result |
|---|---:|
| Ready latency | `3159 / 3453 / 3753 ms` |
| Peak RSS | `739 / 678 / 1103 MB` |
| Ready idle RSS last | `391 / 391 / 476 MB` |
| Ready idle RSS lowest min | `99 MB` |
| Post-search idle RSS last | `277 / 264 / 363 MB` |
| Post-search idle RSS lowest min | `223 MB` |
| Post-add idle RSS last | `310 / 327 / 347 MB` |
| Post-add idle RSS lowest min | `227 MB` |
| Background warmup latency | `3781 / 3827 / 5845 ms` |
| First real search latency | `69 / 68 / 97 ms` |
| Second search latency | `88 / 87 / 123 ms` |
| Shutdown crashes | `10/10` |

Interpretation:

- The profile kept first real search latency low after background warmup: p95 `97 ms`.
- RSS dropped substantially in the idle windows: post-add idle p50 `327 MB` and lowest observed min `227 MB`.
- Background warmup was slower under 10-way parallel pressure: p95 `5845 ms`.
- All runs still hit the known embedded Bun shutdown crash after SIGTERM. Request timings are usable, but shutdown reliability is not clean.

The 10-worker sample is a stress run. Parallelism reduces wall-clock benchmark time, but it also adds CPU, memory, and I/O contention. Use sequential or low-parallelism runs for cleaner release-quality numbers.

## Historical Calibration Runs

These older runs used smaller ingestion memory caps while tuning the profile. They are retained to explain why the current profile keeps the default `1gb` ingestion headroom.

Artifact: `.memory-bench/profile-matrix/20260614-232143/summary.md`

| Scenario | Ready | Peak RSS | Ready Idle Last/Min | Post Search Last/Min | Post Add Last/Min | Warmup | First Search | Second Search | Shutdown Crash |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Baseline default | `3097 ms` | `1197 MB` | `541 / 350 MB` | `478 / 390 MB` | `652 / 535 MB` | n/a | `93 ms` | `70 ms` | yes |
| Cold 15s, 256 MB cap | `1163 ms` | `1723 MB` | `724 / 608 MB` | `1550 / 1401 MB` | `1694 / 1560 MB` | n/a | `1247 ms` | `41 ms` | yes |
| Balanced 15s quick, 256 MB cap | `1152 ms` | `1696 MB` | `1598 / 1598 MB` | `1131 / 1131 MB` | `363 / 305 MB` | `1175 ms` | `47 ms` | `52 ms` | yes |
| Balanced 15s late, 256 MB cap | `1160 ms` | `1440 MB` | `815 / 815 MB` | `787 / 736 MB` | `359 / 286 MB` | `1213 ms` | `50 ms` | `49 ms` | yes |
| Balanced 30s quick, 256 MB cap | `1207 ms` | `1175 MB` | `664 / 526 MB` | `482 / 388 MB` | `672 / 555 MB` | `1348 ms` | `60 ms` | `73 ms` | yes |

The 256 MB cap was too tight for ingestion. It caused ingestion to pause because the server was already above the ingest memory budget in some runs. The current benchmark profile uses the default `1gb` headroom to avoid conflating the low-memory startup/idle behavior with a smaller ingestion budget.

## PGlite Probe

Artifact: `.memory-bench/pglite-initial-memory/20260614-235451/summary.md`

| Scenario | Exit | Peak RSS | Ready | Insert | Index | Query | Result |
|---|---:|---:|---:|---:|---:|---:|---|
| default | `0` | `1087 MB` | `891 ms` | `29 ms` | `9 ms` | `16 ms` | works |
| `initialMemory=128` | `0` | `1098 MB` | `911 ms` | `26 ms` | `10 ms` | `17 ms` | works |
| `initialMemory=128` + low Postgres config | `0` | `1048 MB` | `819 ms` | `27 ms` | `9 ms` | `17 ms` | works |
| `initialMemory=32/48/64/96` | `124` | `~132 MB` | n/a | n/a | n/a | n/a | fails with LinkError |

PGlite `@electric-sql/pglite@0.5.2` does not accept `initialMemory` below `128 MiB` with the shipped WASM module:

```txt
LinkError: Memory import env:memory provided a 'size' that is smaller than the module's declared 'initial' import memory size
```

The low Postgres config probe reduced isolated PGlite RSS by about `40-50 MB`. That needs product-path integration and measurement before it can be claimed for the server binary.

## Bun Runtime Probe

Artifact: `.memory-bench/bun-runtime-compare/20260614-235528/results.jsonl`

| Runtime | Probe | Exit | Elapsed | Peak RSS | Probe Output |
|---|---|---:|---:|---:|---|
| Embedded Bun `1.3.4` | worker smol | `0` | `1171 ms` | `62 MB` | `workerReadyMs=25`, `ping1000Ms=2` |
| Installed Bun `1.3.14` | worker smol | `0` | `1057 ms` | `67 MB` | `workerReadyMs=13`, `ping1000Ms=1` |
| Embedded Bun `1.3.4` | HTTP loopback | `0` | `1173 ms` | `35 MB` | `readyMs=14`, `fetch500Ms=47` |
| Installed Bun `1.3.14` | HTTP loopback | `0` | `1177 ms` | `36 MB` | `readyMs=6`, `fetch500Ms=38` |

The synthetic Bun probes show small latency improvements on `1.3.14`, not lower RSS. The actual self-hosted server binary embeds Bun `1.3.4`; testing the server on a newer Bun requires rebuilding the binary.

## Caveats

- RSS is noisy on macOS. Prefer aggregate `avg / p50 / p95` and idle-window `Last/Min` values over a single sample.
- Balanced warmup is a latency tradeoff, not a guaranteed active peak RSS reduction.
- The memory improvement being tested is mainly idle-shape behavior: HTTP readiness first, background warmup, and worker shutdown after idle.
- Parallel benchmarks are faster but can distort timings and RSS through resource contention.
- Every measured server run still crashed after SIGTERM on embedded Bun `1.3.4`. Request timings are valid; shutdown reliability remains a separate issue.
