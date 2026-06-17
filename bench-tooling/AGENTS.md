# Supermemory Server Binary Patch Tooling

This folder is intentionally narrow. Do not rebuild the old benchmark matrix here.

## Goal

Maintain a small, repeatable workflow for:

- patching the released local `supermemory-server` binary
- restoring a stock binary
- comparing stock vs patched startup behavior with a real local server

## Patch Behavior

The patch changes startup order only:

```txt
stock:   migrations -> await embedding prewarm -> Bun.serve -> ready -> ingest baseline
patched: migrations -> Bun.serve -> ready -> patch label -> background embedding warmup -> ingest baseline
```

The patched binary prints:

```txt
[patch] background embedding warmup enabled
```

Do not change stock defaults to make benchmarks look better:

- keep `Xenova/bge-base-en-v1.5`
- keep embedding batch behavior
- keep ingest concurrency
- keep `SUPERMEMORY_EMBEDDING_RAM_LIMIT` headroom
- keep local embedding idle-timeout and native-worker shutdown behavior unless a process-tree RSS benchmark proves a stable win

## Files

```txt
patch-server-binary.ts       patch/check/restore binary tool
compare-patched-server.ts    focused real-binary stock-vs-patched validation
README.md                    operator docs
```

`probes/` contains unrelated focused runtime probes. Leave it alone unless the task is specifically about those probes.

## Validation

Use:

```sh
RUN_COUNT=5 READY_SETTLE_MS=2000 bun run bench:patch:compare
```

For memory checks, use process-tree RSS with an idle window:

```sh
RUN_COUNT=5 READY_SETTLE_MS=2000 POST_SEARCH_IDLE_MS=35000 bun run bench:patch:compare
```

The comparison should fail if patched startup is not materially faster, if first search regresses after the settle window, or if logs show the patch changed stock workload defaults.

Only set `EXPECT_IDLE_RSS_WIN_MB` when testing a deliberate memory optimization. Do not keep a binary behavior change unless it passes the startup/search/log assertions and shows a stable p50 RSS win.

## Binary Inspection

Use path-independent inspection commands. Set a `SERVER_BIN` variable first:

```sh
SERVER_BIN=/path/to/supermemory-server
```

Then inspect the binary identity and bundled startup code:

```sh
file "$SERVER_BIN"
shasum -a 256 "$SERVER_BIN"
"$SERVER_BIN" --version
strings -a "$SERVER_BIN" | rg -n "SUPERMEMORY_SKIP_EMBEDDING_PREWARM|async function hX2|Bun\.serve|\[ingest\] memory limit|local embeddings"
```

For the exact startup span this patcher edits, use the `Inspecting A Binary` section in `README.md`. Do not hardcode local machine paths in docs or commands.
