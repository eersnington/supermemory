#!/usr/bin/env bash
set -euo pipefail

SERVER_BIN="${SUPERMEMORY_SERVER_BIN:-$HOME/.supermemory/bin/supermemory-server}"
LATEST_BUN="${BUN_BIN:-$(command -v bun)}"
OUT_ROOT="${OUT_ROOT:-.memory-bench/bun-runtime-compare}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-0.1}"
PROBE_HOLD_MS="${PROBE_HOLD_MS:-1000}"

usage() {
  cat <<'USAGE'
Usage:
  bench-tooling/probes/bun-runtime.sh

Compares the Bun runtime embedded in the installed supermemory-server binary
against the currently installed bun CLI on focused probes.

Environment:
  SUPERMEMORY_SERVER_BIN   Path to the existing standalone binary.
  BUN_BIN                  Path to the latest bun CLI. Defaults to command -v bun.
  OUT_ROOT                 Output directory. Defaults to .memory-bench/bun-runtime-compare.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [[ ! -x "$SERVER_BIN" ]]; then
  fail "embedded Bun source binary is not executable at $SERVER_BIN"
fi

if [[ ! -x "$LATEST_BUN" ]]; then
  fail "latest bun CLI is not executable at $LATEST_BUN"
fi

mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
RUN_DIR="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

rss_kb() {
  ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
}

write_probes() {
  cat > "$RUN_DIR/worker-probe.ts" <<'TS'
const startedAt = performance.now();
const worker = new Worker(new URL("./worker-probe-worker.ts", import.meta.url).href, {
  ref: false,
  smol: true,
});

let messages = 0;
const ready = await new Promise<number>((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("worker ready timeout")), 10_000);
  worker.addEventListener("message", (event) => {
    if (event.data?.tag === "ready") {
      clearTimeout(timeout);
      resolve(performance.now());
    }
  });
});

const pingStarted = performance.now();
const done = new Promise<number>((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("worker ping timeout")), 10_000);
  worker.addEventListener("message", (event) => {
    if (event.data?.tag === "pong") {
      messages += 1;
      if (messages === 1000) {
        clearTimeout(timeout);
        resolve(performance.now());
      }
    }
  });
});

for (let i = 0; i < 1000; i += 1) {
  worker.postMessage({ tag: "ping", i, text: "simple primitive message" });
}

const pingFinished = await done;
await new Promise((resolve) => setTimeout(resolve, Number(process.env.PROBE_HOLD_MS ?? "1000")));
worker.terminate();

console.log(JSON.stringify({
  probe: "worker-smol",
  bunVersion: Bun.version,
  workerReadyMs: Math.round(ready - startedAt),
  ping1000Ms: Math.round(pingFinished - pingStarted),
}));
TS

  cat > "$RUN_DIR/worker-probe-worker.ts" <<'TS'
declare const self: Worker;

const retained = new Array(250_000).fill(0).map((_, index) => `warm-${index}`);
postMessage({ tag: "ready", retained: retained.length });

self.addEventListener("message", (event: MessageEvent) => {
  if (event.data?.tag === "ping") {
    postMessage({ tag: "pong", i: event.data.i });
  }
});
TS

  cat > "$RUN_DIR/http-probe.ts" <<'TS'
const startedAt = performance.now();
const server = Bun.serve({
  port: 0,
  fetch() {
    return new Response("ok");
  },
});

const readyAt = performance.now();
const url = `http://127.0.0.1:${server.port}/`;
const fetchStarted = performance.now();

for (let i = 0; i < 500; i += 1) {
  const response = await fetch(url);
  if (response.status !== 200) throw new Error(`unexpected status ${response.status}`);
  await response.text();
}

const fetchFinished = performance.now();
await new Promise((resolve) => setTimeout(resolve, Number(process.env.PROBE_HOLD_MS ?? "1000")));
server.stop(true);

console.log(JSON.stringify({
  probe: "http-loopback",
  bunVersion: Bun.version,
  readyMs: Math.round(readyAt - startedAt),
  fetch500Ms: Math.round(fetchFinished - fetchStarted),
}));
TS
}

run_and_sample() {
  local label="$1"
  local runtime="$2"
  local script="$3"
  local log_file="$RUN_DIR/$label-$(basename "$script" .ts).log"
  local samples_file="$RUN_DIR/$label-$(basename "$script" .ts)-samples.csv"
  local started_at ended_at pid peak_rss_kb last_rss_kb exit_code

  printf 'epoch_ms,rss_kb\n' > "$samples_file"
  started_at="$(now_ms)"
  if [[ "$label" == "embedded-1.3.4" ]]; then
    PROBE_HOLD_MS="$PROBE_HOLD_MS" BUN_BE_BUN=1 "$runtime" "$script" > "$log_file" 2>&1 &
  else
    PROBE_HOLD_MS="$PROBE_HOLD_MS" "$runtime" "$script" > "$log_file" 2>&1 &
  fi
  pid="$!"

  peak_rss_kb=0
  last_rss_kb=0
  while kill -0 "$pid" 2>/dev/null; do
    current_rss_kb="$(rss_kb "$pid")"
    if [[ -n "$current_rss_kb" ]]; then
      last_rss_kb="$current_rss_kb"
      if (( current_rss_kb > peak_rss_kb )); then
        peak_rss_kb="$current_rss_kb"
      fi
      printf '%s,%s\n' "$(now_ms)" "$current_rss_kb" >> "$samples_file"
    fi
    sleep "$SAMPLE_INTERVAL_SECONDS"
  done

  if wait "$pid"; then
    exit_code=0
  else
    exit_code="$?"
  fi
  ended_at="$(now_ms)"
  printf '{"label":"%s","script":"%s","exitCode":%s,"elapsedMs":%s,"peakRssMb":%s,"lastRssMb":%s,"log":"%s"}\n' \
    "$label" \
    "$(basename "$script")" \
    "$exit_code" \
    "$((ended_at - started_at))" \
    "$(( (peak_rss_kb + 512) / 1024 ))" \
    "$(( (last_rss_kb + 512) / 1024 ))" \
    "$log_file"
}

write_probes

EMBEDDED_VERSION="$(BUN_BE_BUN=1 "$SERVER_BIN" --version)"
LATEST_VERSION="$($LATEST_BUN --version)"

printf 'Embedded Bun: %s (%s)\n' "$EMBEDDED_VERSION" "$SERVER_BIN"
printf 'Latest Bun:   %s (%s)\n' "$LATEST_VERSION" "$LATEST_BUN"
printf 'Run dir:      %s\n\n' "$RUN_DIR"

: > "$RUN_DIR/results.jsonl"
for script in "$RUN_DIR/worker-probe.ts" "$RUN_DIR/http-probe.ts"; do
  run_and_sample "embedded-1.3.4" "$SERVER_BIN" "$script" | tee -a "$RUN_DIR/results.jsonl"
  run_and_sample "latest-$LATEST_VERSION" "$LATEST_BUN" "$script" | tee -a "$RUN_DIR/results.jsonl"
done

printf '\nProbe output:\n'
for log in "$RUN_DIR"/*.log; do
  printf '%s: ' "$(basename "$log")"
  tr '\n' ' ' < "$log"
  printf '\n'
done
