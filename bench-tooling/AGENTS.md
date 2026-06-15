# Handoff: Supermemory Local Startup And Memory Goal

## Actual Goal

The goal is to improve the real local `supermemory-server` binary/source, not to keep tuning benchmark scripts.

The user wants `supermemory-server` local to:

- Feel faster on startup.
- Avoid memory leaks.
- Avoid being memory hungry.
- Preserve stock capability and stock workload behavior.
- Keep the same effective `1gb` ingest memory headroom.
- Keep the same ingest concurrency as stock.
- Keep the same local embedding model and embedding batch behavior as stock.

## Critical Clarification

`bench-tooling` is measurement instrumentation only. It does not make the product better by itself.

Do not treat `bench-tooling/results.md` as a scratchpad. It should contain clear benchmark results and explanations only.

The next agent should focus on finding or using the actual self-hosted server source/build for `~/.supermemory/bin/supermemory-server`. The source was not found in `/Users/eers/Development/supermemory`; the installed binary was inspected directly with `strings`.

## What Was Learned From Reading The Binary

The installed binary is:

```txt
~/.supermemory/bin/supermemory-server
Mach-O 64-bit executable arm64
```

The binary contains readable bundled JavaScript. The startup path extracted from the binary is effectively:

```txt
storage/db -> migrations -> provider setup -> await embedding prewarm -> app imports -> local identity/api key -> cron/Rivet -> Bun.serve -> READY -> ingest baseline/update/open/telemetry
```

The relevant prewarm function extracted from the binary:

```js
async function hX2() {
  if (
    process.env.SUPERMEMORY_SKIP_EMBEDDING_PREWARM === "true" ||
    process.env.SUPERMEMORY_SKIP_EMBEDDING_PREWARM === "1"
  ) {
    b4("[embeddings] skipping local embedding model prewarm");
    return;
  }

  await CQ6(mP0);
}
```

The startup IIFE awaits `hX2()` before `Bun.serve(...)`. Therefore stock startup blocks HTTP readiness on embedding prewarm.

With `SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1`, the binary skips prewarm and reaches HTTP ready earlier. The binary itself does not start a background warmup. Any post-ready warmup seen so far came from `bench-tooling` sending `/v3/search` after HTTP ready.

## Important Headroom Issue

The binary calls the ingest baseline logger/check after `Bun.serve`:

```txt
Bun.serve(...)
No6(...)  // prints ready
Bj8()    // captures/logs ingest memory baseline and 1gb headroom
```

In stock mode, embedding prewarm has already happened before this baseline is captured. That means the fixed embedding model footprint is included in the post-boot baseline.

In skip-prewarm mode, HTTP ready and the ingest baseline can happen before embeddings are loaded. If the embedding model loads later, that fixed model footprint may count against the `1gb` ingest headroom even though the env var is unchanged.

This means preserving stock `1gb` headroom is not just “do not set `SUPERMEMORY_EMBEDDING_RAM_LIMIT`.” The binary may need a code change to preserve the same effective baseline or separate fixed embedding footprint from ingest memory accounting.

## What Bench Tooling Currently Tests

The current repo contains benchmark tooling that starts the real installed binary and measures it.

Relevant files:

```txt
bench-tooling/bench.sh
bench-tooling/matrix.sh
bench-tooling/parallel.sh
bench-tooling/summary.ts
bench-tooling/soak.sh
bench-tooling/results.md
```

Current profiles added in tooling:

| Profile | Meaning |
|---|---|
| `stock-30s` | Stock binary behavior. Embeddings prewarm before HTTP ready. |
| `optimized-cold-30s` | Skip prewarm. No benchmark warmup. Measures true cold first-search cost. |
| `optimized-background-30s` | Skip prewarm. Benchmark sends warmup after ready but does not wait before `ready_idle`. Simulates post-ready warmup behavior. |
| `optimized-blocking-30s` | Skip prewarm. Benchmark sends warmup after ready and waits. This was the old `optimized-30s` behavior. |
| `optimized-30s` | Compatibility alias for `optimized-blocking-30s`. |

Warmup modes in `bench-tooling/bench.sh`:

| `WARM_AFTER_READY` | Meaning |
|---|---|
| `0` | No warmup request after HTTP ready. |
| `background` | Send warmup request after HTTP ready and continue measuring without waiting. |
| `blocking` or `1` | Send warmup request after HTTP ready and wait before continuing. |

`bench-tooling/soak.sh` was added to keep one server alive and repeat warm/search/add/idle cycles to detect RSS drift. It is a leak detection harness, not a product change.

## Latest Completed Result Context

`bench-tooling/results.md` currently documents a completed 10-worker run:

```sh
RUN_COUNT=10 PARALLEL_JOBS=10 SCENARIOS=stock-30s,optimized-30s bun run bench:low-memory:parallel
```

That run compares stock against `optimized-30s`, which now means blocking post-ready warmup.

Key result:

| Metric | Stock p50 | Optimized p50 |
|---|---:|---:|
| Ready | `5677 ms` | `1651 ms` |
| Peak RSS | `816 MB` | `1071 MB` |
| Ready idle RSS | `284 MB` | `395 MB` |
| Post-search idle RSS | `280 MB` | `357 MB` |
| Post-add idle RSS | `260 MB` | `239 MB` |
| First search | `107 ms` | `78 ms` |
| Second search | `107 ms` | `131 ms` |

Interpretation:

- The optimized profile proves faster HTTP readiness.
- It does not prove lower peak RSS.
- It does not prove generally lower idle RSS.
- The 10-worker run is a stress shape where warmups overlap heavily.
- Shutdown crashes happen in both stock and optimized after SIGTERM because embedded Bun `1.3.4` crashes on shutdown.

## What Needs To Be Done Next

The next agent should not continue random benchmark tuning. It should find or obtain the self-hosted server source/build and implement product-level changes.

Desired binary/source behavior:

```txt
storage/db -> migrations -> provider setup -> app imports -> local identity/api key -> cron/Rivet -> Bun.serve -> HTTP READY
                                                                                                         |
                                                                                                         v
                                                                                 server-owned non-blocking embedding warmup
```

Required product properties:

- HTTP ready should not block on local embedding model load.
- The binary, not the benchmark, should own post-ready background warmup.
- Background warmup and first real search/add should share one in-flight embedding initializer.
- There must not be duplicate concurrent model loads inside one server process.
- The effective stock `1gb` ingest headroom must be preserved.
- Ingest concurrency must remain stock default.
- Embedding batch size and model must remain stock default.
- The embedding worker/model should unload after idle timeout if that is the intended memory behavior.

## Measurement Plan After Product Changes

Use `bench-tooling` only as validation after binary/source changes.

Run single-process local UX comparison:

```sh
RUN_COUNT=10 PARALLEL_JOBS=1 SCENARIOS=stock-30s,optimized-cold-30s,optimized-background-30s,optimized-blocking-30s bun run bench:low-memory:parallel
```

Run 10-worker stress comparison:

```sh
RUN_COUNT=10 PARALLEL_JOBS=10 SCENARIOS=stock-30s,optimized-cold-30s,optimized-background-30s,optimized-blocking-30s bun run bench:low-memory:parallel
```

Run soak/leak validation with a real idle timeout window:

```sh
CYCLES=20 IDLE_SECONDS=40 bun run bench:low-memory:soak
```

Use the soak result to check whether post-idle RSS stabilizes or keeps climbing.

## Do Not Do

- Do not claim memory wins from startup-readiness wins.
- Do not use `bench-tooling/results.md` as a scratchpad.
- Do not lower ingest concurrency to make memory look better.
- Do not lower embedding batch size to make memory look better.
- Do not lower `SUPERMEMORY_EMBEDDING_RAM_LIMIT` to make memory look better.
- Do not confuse benchmark-triggered warmup with product-owned background warmup.
- Do not ignore the ingest baseline/headroom issue introduced by skipping prewarm.

## Current Repo State To Be Aware Of

Current modified/untracked files at time of handoff included:

```txt
bench-tooling/bench.sh
bench-tooling/matrix.sh
bench-tooling/summary.ts
bench-tooling/results.md
package.json
bench-tooling/soak.sh
```

Only benchmark tooling and documentation were changed in this repo. The actual installed binary was not modified.
