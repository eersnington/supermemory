# Supermemory Server Binary Patch

This folder now contains the small tooling needed to patch and validate the local `supermemory-server` binary.

## Patch

The patch moves local embedding model warmup out of the HTTP readiness path:

```txt
stock:   migrations -> await embedding prewarm -> Bun.serve -> ready -> ingest baseline
patched: migrations -> Bun.serve -> ready -> patch label -> background embedding warmup -> ingest baseline
```

It does not change the embedding model, embedding batch size, ingest concurrency, or `SUPERMEMORY_EMBEDDING_RAM_LIMIT`.

The patched server prints this at startup:

```txt
[patch] background embedding warmup enabled
```

## Commands

```sh
bun run bench:patch:check ~/.supermemory/bin/supermemory-server
```

```sh
bun run bench:patch:apply ~/.supermemory/bin/supermemory-server.stock-5a5932a9.bak ~/.supermemory/bin/supermemory-server.patched
```

```sh
bun run bench:patch:restore ~/.supermemory/bin/supermemory-server.stock-5a5932a9.bak ~/.supermemory/bin/supermemory-server --force
```

```sh
RUN_COUNT=5 READY_SETTLE_MS=2000 bun run bench:patch:compare
```

## Validation

`compare-patched-server.ts` creates a patched binary from a stock binary, runs paired stock/patched server launches, and fails if:

- patched readiness does not beat stock readiness by threshold
- patched first search after the settle window regresses too much
- patched logs do not show the patch label after readiness
- patched logs do not preserve the stock model, worker, batch, and ingest defaults
