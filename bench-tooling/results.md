# Low-Memory Profile Results

## How to Run

Run the recommended low-memory profile locally:

```sh
bun run bench:low-memory:run
```

Run a quick measurement comparing default startup against the recommended profile:

```sh
bun run bench:low-memory:measure
```

Run a safe async benchmark chunk that survives short shell/OpenCode timeouts:

```sh
RUN_COUNT=5 SCENARIOS=balanced-30s-quick bun run bench:low-memory:async
```

Collect completed async chunks into one aggregate result:

```sh
bun run bench:low-memory:collect -- \
  .memory-bench/profile-matrix/combined-balanced-100 \
  .memory-bench/profile-matrix/*-async
```

Run the full low-memory matrix directly only on an isolated machine:

```sh
RUN_COUNT=100 SCENARIOS=balanced-30s-quick bun run bench:low-memory:matrix
```

Run an adaptive parallel 100-run benchmark on a workstation:

```sh
RUN_COUNT=100 SCENARIOS=balanced-30s-quick bun run bench:low-memory:parallel
```

On a 16 GB / 10-core Mac this defaults to 2 workers. Override with `PARALLEL_JOBS=1`, `PARALLEL_JOBS=2`, or another explicit value if needed.

Use chunks on a workstation when you want the lowest risk. Chunking preserves progress and avoids OpenCode command timeouts, but it does not reduce each individual run's peak memory.

## Recommended Profile

Use `bench-tooling/run.sh run-balanced`. It now applies this profile unless a variable is already set:

```sh
SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1
SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000
SUPERMEMORY_INGEST_CONCURRENCY=1
SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2
SUPERMEMORY_EMBEDDING_RAM_LIMIT=512mb
SUPERMEMORY_NO_OPEN=1
SUPERMEMORY_NO_UPDATE_CHECK=1
```

This profile starts HTTP before loading the embedding model, runs one authenticated background search after readiness to warm embeddings, keeps the worker hot briefly for fast search, then lets memory drop after idle.

## Best Measured Run

Run artifact: `.memory-bench/profile-matrix/manual-512/runs/20260614-235640-balanced-30s-512`

| Scenario | Ready | Peak RSS | Ready Idle Last/Min | Post Search Last/Min | Post Add Last/Min | Warmup Search | First Real Search | Second Search | Ingest Paused | Shutdown Crash |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| Balanced 30s, 512 MB ingest cap | `1710 ms` | `1178 MB` | `332 / 332 MB` | `492 / 333 MB` | `328 / 261 MB` | `1290 ms` | `92 ms` | `65 ms` | no | yes |

This was the best practical tradeoff in the local measurements: startup stayed fast, first real search stayed near baseline latency, post-idle RSS dropped substantially, and ingestion completed without the pause seen under a 256 MB ingest cap.

## Profile Matrix

Run artifact: `.memory-bench/profile-matrix/20260614-232143/summary.md`

| Scenario | Ready | Peak RSS | Ready Idle Last/Min | Post Search Last/Min | Post Add Last/Min | Warmup | First Search | Second Search | Shutdown Crash |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Baseline default | `3097 ms` | `1197 MB` | `541 / 350 MB` | `478 / 390 MB` | `652 / 535 MB` | n/a | `93 ms` | `70 ms` | yes |
| Cold 15s, 256 MB cap | `1163 ms` | `1723 MB` | `724 / 608 MB` | `1550 / 1401 MB` | `1694 / 1560 MB` | n/a | `1247 ms` | `41 ms` | yes |
| Balanced 15s quick, 256 MB cap | `1152 ms` | `1696 MB` | `1598 / 1598 MB` | `1131 / 1131 MB` | `363 / 305 MB` | `1175 ms` | `47 ms` | `52 ms` | yes |
| Balanced 15s late, 256 MB cap | `1160 ms` | `1440 MB` | `815 / 815 MB` | `787 / 736 MB` | `359 / 286 MB` | `1213 ms` | `50 ms` | `49 ms` | yes |
| Balanced 30s quick, 256 MB cap | `1207 ms` | `1175 MB` | `664 / 526 MB` | `482 / 388 MB` | `672 / 555 MB` | `1348 ms` | `60 ms` | `73 ms` | yes |

The 256 MB ingest cap was too tight in the cold run: the server logged ingestion as paused because it was already above the ingest memory budget. The 512 MB targeted run avoided that while keeping similar peak RSS and lower post-idle RSS.

## PGlite Probe

Run artifact: `.memory-bench/pglite-initial-memory/20260614-235451/summary.md`

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

The low Postgres config probe shaved about `40-50 MB` in isolation, but the self-hosted server source is not present in this checkout, so that needs source-side integration and measurement before it can be claimed for the binary.

## Bun Runtime Probe

Run artifact: `.memory-bench/bun-runtime-compare/20260614-235528/results.jsonl`

| Runtime | Probe | Exit | Elapsed | Peak RSS | Probe Output |
|---|---|---:|---:|---:|---|
| Embedded Bun `1.3.4` | worker smol | `0` | `1171 ms` | `62 MB` | `workerReadyMs=25`, `ping1000Ms=2` |
| Installed Bun `1.3.14` | worker smol | `0` | `1057 ms` | `67 MB` | `workerReadyMs=13`, `ping1000Ms=1` |
| Embedded Bun `1.3.4` | HTTP loopback | `0` | `1173 ms` | `35 MB` | `readyMs=14`, `fetch500Ms=47` |
| Installed Bun `1.3.14` | HTTP loopback | `0` | `1177 ms` | `36 MB` | `readyMs=6`, `fetch500Ms=38` |

The synthetic Bun probes show small latency improvements on `1.3.14`, not lower RSS. The actual self-hosted server cannot be tested on newer Bun here because the installed server is a standalone binary embedding Bun `1.3.4`; replacing the runtime requires rebuilding the server from source.

## Caveats

- Every measured server run still crashed after SIGTERM on embedded Bun `1.3.4`. Request timings are valid, but shutdown reliability is not clean.
- RSS is noisy on macOS. Use `Last/Min` over longer idle windows instead of a single sample.
- Balanced warmup is a latency tradeoff, not a permanent-memory reduction. The memory win comes from idle timeout and ingestion limiting after active work finishes.
- The self-hosted server source is not in this checkout, so PGlite constructor/config changes were tested with an isolated PGlite probe, not inside the product binary.

## Rerun Commands

```sh
bench-tooling/matrix.sh
bench-tooling/probes/pglite.sh
bench-tooling/probes/bun-runtime.sh
```

For OpenCode or other shells with short command timeouts, launch matrix chunks in the background. The async launcher returns immediately, writes `async.json` with the PID and paths, and the matrix writes partial `summary.md`/`summary.json` after each completed iteration:

```sh
RUN_COUNT=5 SCENARIOS=balanced-30s-quick bench-tooling/async.sh
```

The same command through `package.json` is:

```sh
RUN_COUNT=5 SCENARIOS=balanced-30s-quick bun run bench:low-memory:async
```

Repeat chunks until the combined row count reaches the target. Then collect them into one structurally readable result:

```sh
bun bench-tooling/collect.ts \
  .memory-bench/profile-matrix/combined-balanced-100 \
  .memory-bench/profile-matrix/*-async
```

Or through `package.json`:

```sh
bun run bench:low-memory:collect -- \
  .memory-bench/profile-matrix/combined-balanced-100 \
  .memory-bench/profile-matrix/*-async
```

The collector writes `runs.tsv`, `summary.md`, and `summary.json` in the output directory. Use small chunks plus `COOLDOWN_SECONDS=60` or higher on a workstation; chunking preserves progress but does not lower each individual run's peak memory.

For the recommended 512 MB profile directly:

```sh
BENCH_ROOT=.memory-bench/profile-matrix/manual-512 \
SOURCE_DATA_DIR="$HOME/.supermemory" \
SAMPLE_INTERVAL_SECONDS=0.25 \
RUN_VM_MAP=0 \
IDLE_SECONDS=20 \
POST_SEARCH_IDLE_SECONDS=40 \
POST_ADD_IDLE_SECONDS=40 \
WARM_AFTER_READY=1 \
bench-tooling/bench.sh scenario balanced-30s-512 \
  SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 \
  SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 \
  SUPERMEMORY_INGEST_CONCURRENCY=1 \
  SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2 \
  SUPERMEMORY_EMBEDDING_RAM_LIMIT=512mb
```
