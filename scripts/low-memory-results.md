# Low-Memory And Balanced Warmup Results

## Results Table

| Scenario | Ready Latency | Peak RSS | Ready-Idle Last | Post-Search Last | Post-Add Last | Warmup Search | First Real Search | What It Proves |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Baseline | `2859 ms` | `1182 MB` | `919 MB` | `1013 MB` | `1107 MB` | n/a | `91 ms` | Current binary blocks startup on embedding prewarm, so first search is fast. |
| Cold low-memory | `1154 ms` | `1404 MB` | `1020 MB` | `1404 MB` | `1344 MB` | n/a | `1026 ms` | Skipping prewarm makes HTTP ready fast, but first search pays model-load cost. |
| Balanced warmup | `1180 ms` | `1658 MB` | `1573 MB` | `1591 MB` | `1626 MB` | `940 ms` | `51 ms` | Post-ready background warmup keeps fast HTTP readiness and makes first real search fast if warmup completed. |

## Runtime Comparison Table

| Runtime | Probe | Exit Code | Elapsed | Peak RSS | Probe Output |
|---|---|---:|---:|---:|---|
| Embedded Bun `1.3.4` | Worker smol probe | `0` | `1179 ms` | `65 MB` | `workerReadyMs=10`, `ping1000Ms=1` |
| Installed Bun `1.3.14` | Worker smol probe | `0` | `1090 ms` | `68 MB` | `workerReadyMs=9`, `ping1000Ms=2` |
| Embedded Bun `1.3.4` | HTTP loopback probe | `0` | `1080 ms` | `35 MB` | `readyMs=1`, `fetch500Ms=36` |
| Installed Bun `1.3.14` | HTTP loopback probe | `0` | `1104 ms` | `36 MB` | `readyMs=1`, `fetch500Ms=33` |

## Baseline

The baseline starts the installed binary normally and measures how it behaves when embeddings are prewarmed before HTTP readiness.

```sh
scripts/sm-lowmem.sh measure-balanced
```

Internally the baseline benchmark runs the current binary with isolated copied data and no low-memory embedding overrides.

```sh
scripts/memory-bench.sh scenario sm-balanced-baseline
```

Result: HTTP readiness is slower, but first search is already warm.

## Cold Low-Memory

Cold low-memory starts HTTP quickly by skipping embedding prewarm.

```sh
SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 \
SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 \
SUPERMEMORY_INGEST_CONCURRENCY=1 \
SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2 \
scripts/memory-bench.sh scenario sm-balanced-cold
```

Result: HTTP readiness is fast, but first search is slow because it triggers embedding model load.

## Balanced Warmup

Balanced warmup keeps skip-prewarm enabled, waits for HTTP readiness, then sends a background warmup search before measuring the first real search.

```sh
WARM_AFTER_READY=1 \
SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 \
SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 \
SUPERMEMORY_INGEST_CONCURRENCY=1 \
SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2 \
scripts/memory-bench.sh scenario sm-balanced-warm
```

The wrapper command is:

```sh
scripts/sm-lowmem.sh run-balanced
```

Result: HTTP readiness stays close to cold low-memory, and first real search becomes fast because the embedding model was warmed in the background.

## What The Code Does

`scripts/memory-bench.sh` now supports post-ready warmup.

```sh
WARM_AFTER_READY="${WARM_AFTER_READY:-0}"

if [[ "$WARM_AFTER_READY" == "1" ]]; then
  printf 'background_warmup' > "$label_file"
  search_once "$port" "$api_key" "$run_dir/warmup-search.json" > "$run_dir/warmup-search.txt" &
  warmup_pid="$!"
  wait "$warmup_pid" || true
fi
```

`scripts/sm-lowmem.sh run-balanced` launches the server, waits for HTTP readiness, then sends the warmup search.

```sh
run_balanced() {
  apply_lowmem_defaults
  "$server_bin" &
  pid="$!"
  wait_for_http_ready "$port" "$pid"
  warm_search "$port" &
  wait "$pid"
}
```

The warmup request is a normal authenticated search that forces the same embedding path a real first search would use.

```sh
curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v3/search" \
  -H "Authorization: Bearer $api_key" \
  -H 'Content-Type: application/json' \
  -d '{"q":"supermemory local embedding warmup","containerTag":"__sm_warmup__"}'
```

`scripts/bun-runtime-compare.sh` compares the embedded Bun runtime with the installed Bun runtime.

```sh
BUN_BE_BUN=1 "$SERVER_BIN" --version
bun --version
```

It then runs the same worker and HTTP probes through both runtimes.

```sh
BUN_BE_BUN=1 "$SERVER_BIN" "$script"
"$LATEST_BUN" "$script"
```

## Conclusion

Balanced warmup is the useful runtime behavior change available without private server source. It moves embedding load out of the first real search path while preserving fast HTTP readiness. It does not reduce permanent RSS; it intentionally warms the embedding model earlier, so memory rises after startup.
