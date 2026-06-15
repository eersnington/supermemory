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

## Inspecting A Binary

Use a `SERVER_BIN` variable so the workflow is not tied to any machine-specific path:

```sh
SERVER_BIN=/path/to/supermemory-server
```

Confirm that it is the expected executable and record its identity:

```sh
file "$SERVER_BIN"
shasum -a 256 "$SERVER_BIN"
"$SERVER_BIN" --version
```

If the binary was built as a Bun standalone executable, `BUN_BE_BUN=1` can show the embedded Bun runtime version:

```sh
BUN_BE_BUN=1 "$SERVER_BIN" --version
```

Search the readable bundled JavaScript for startup and embedding markers:

```sh
strings -a "$SERVER_BIN" | rg -n "SUPERMEMORY_SKIP_EMBEDDING_PREWARM|async function hX2|Bun\.serve|supermemory ready|\[ingest\] memory limit|local embeddings|Xenova/bge-base-en-v1\.5"
```

Extract focused text windows around important markers without dumping the whole binary:

```sh
node <<'JS' "$SERVER_BIN" "async function hX2" "Bun.serve" "function Bj8" "async function CQ6"
const fs = require("node:fs")
const [binary, ...needles] = process.argv.slice(2)
const text = fs.readFileSync(binary).toString("latin1")

for (const needle of needles) {
  const index = text.indexOf(needle)
  console.log(`\n--- ${needle} @ ${index} ---`)
  if (index === -1) continue
  console.log(text.slice(Math.max(0, index - 2000), index + 5000))
}
JS
```

Extract the bundled startup IIFE that this patcher edits:

```sh
node <<'JS' "$SERVER_BIN"
const fs = require("node:fs")
const binary = process.argv[2]
const text = fs.readFileSync(binary).toString("latin1")
const start = text.indexOf("(async()=>{if(XX2)")
const end = text.indexOf("})().catch", start)

if (start === -1 || end === -1) {
  throw new Error("startup span not found; this binary shape is unsupported")
}

const startup = text.slice(start, end)
console.log(JSON.stringify({ start, end, length: startup.length }, null, 2))
console.log(startup)
JS
```

Check whether the binary is stock, patched, or unsupported with the patcher:

```sh
bun run bench:patch:check "$SERVER_BIN"
```

Markers to verify manually:

```txt
stock startup contains:
  await mX2(Iz),await hX2();let r=
  ... Bun.serve(...) ... No6(...) ... Bj8()

patched startup contains:
  await mX2(Iz);let r=
  [patch] background embedding warmup enabled
  setTimeout(()=>hX2().then(()=>{rw=process.memoryUsage.rss();Bj8()}).catch(console.error),250)
```

When inspecting logs from a real run, expected ordering is:

```txt
stock:
  local embeddings
  supermemory ready
  [ingest] memory limit

patched:
  supermemory ready
  [patch] background embedding warmup enabled
  local embeddings
  [ingest] memory limit
```

## Validation

`compare-patched-server.ts` creates a patched binary from a stock binary, runs paired stock/patched server launches, and fails if:

- patched readiness does not beat stock readiness by threshold
- patched first search after the settle window regresses too much
- patched logs do not show the patch label after readiness
- patched logs do not preserve the stock model, worker, batch, and ingest defaults
