#!/usr/bin/env bash
set -euo pipefail

SERVER_BIN="${SERVER_BIN:-$HOME/.supermemory/bin/supermemory-server}"
BENCH_ROOT="${BENCH_ROOT:-.memory-bench}"
SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-.supermemory}"
PORT_BASE="${PORT_BASE:-17667}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-90}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
IDLE_SECONDS="${IDLE_SECONDS:-20}"
POST_SEARCH_IDLE_SECONDS="${POST_SEARCH_IDLE_SECONDS:-8}"
POST_ADD_IDLE_SECONDS="${POST_ADD_IDLE_SECONDS:-8}"
ADD_COUNT="${ADD_COUNT:-1}"
DOC_REPEAT_COUNT="${DOC_REPEAT_COUNT:-120}"
WARM_AFTER_READY="${WARM_AFTER_READY:-0}"
RUN_VM_MAP="${RUN_VM_MAP:-1}"

usage() {
  cat <<'USAGE'
Usage:
  bench-tooling/bench.sh scenario <name> [KEY=VALUE ...]
  bench-tooling/bench.sh suite

Examples:
  bench-tooling/bench.sh scenario baseline SUPERMEMORY_VERBOSE=1
  bench-tooling/bench.sh scenario idle-15s SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=15000
  ADD_COUNT=20 DOC_REPEAT_COUNT=300 bench-tooling/bench.sh scenario add-20-large
  WARM_AFTER_READY=1 bench-tooling/bench.sh scenario balanced-warm SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1
  bench-tooling/bench.sh suite

Outputs are written to .memory-bench/runs/<timestamp>-<name>/.
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

command_name="$1"
shift

mkdir -p "$BENCH_ROOT/runs"
BENCH_ROOT="$(cd "$BENCH_ROOT" && pwd -P)"
SERVER_BIN="$(cd "$(dirname "$SERVER_BIN")" && pwd -P)/$(basename "$SERVER_BIN")"
if [[ -d "$SOURCE_DATA_DIR" ]]; then
  SOURCE_DATA_DIR="$(cd "$SOURCE_DATA_DIR" && pwd -P)"
fi

timestamp() {
  date +%Y%m%d-%H%M%S
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

rss_kb() {
  local pid="$1"
  ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '
}

vsz_kb() {
  local pid="$1"
  ps -o vsz= -p "$pid" 2>/dev/null | tr -d ' '
}

process_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

wait_for_ready() {
  local port="$1"
  local log_file="$2"
  local started_at
  started_at="$(date +%s)"

  while true; do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
      return 0
    fi

    if rg -q "listening on http://localhost:$port|fatal during startup|No model provider API key configured|Cancelled by user" "$log_file" 2>/dev/null; then
      if rg -q "listening on http://localhost:$port" "$log_file" 2>/dev/null; then
        return 0
      fi
      return 1
    fi

    if (( $(date +%s) - started_at > READY_TIMEOUT_SECONDS )); then
      return 1
    fi

    sleep 0.25
  done
}

copy_seed_data() {
  local data_dir="$1"
  if [[ -d "$SOURCE_DATA_DIR" ]]; then
    cp -R "$SOURCE_DATA_DIR" "$data_dir"
  else
    mkdir -p "$data_dir"
  fi
}

read_api_key() {
  local data_dir="$1"
  local key_file="$data_dir/api-key"
  if [[ -f "$key_file" ]]; then
    tr -d '\r\n' < "$key_file"
  fi
}

sample_loop() {
  local pid="$1"
  local output_file="$2"
  local label_file="$3"
  printf 'epoch_ms,label,rss_kb,vsz_kb\n' > "$output_file"
  while process_alive "$pid"; do
    local label
    label="$(tr -d '\n' < "$label_file" 2>/dev/null || true)"
    printf '%s,%s,%s,%s\n' "$(now_ms)" "${label:-unknown}" "$(rss_kb "$pid")" "$(vsz_kb "$pid")" >> "$output_file"
    sleep "$SAMPLE_INTERVAL_SECONDS"
  done
}

search_once() {
  local port="$1"
  local api_key="$2"
  local output_file="$3"
  local start_ms end_ms status
  start_ms="$(now_ms)"
  if [[ -n "$api_key" ]]; then
    status="$(curl -sS -o "$output_file" -w '%{http_code}' "http://127.0.0.1:$port/v3/search" \
      -H "Authorization: Bearer $api_key" \
      -H 'Content-Type: application/json' \
      -d '{"q":"memory benchmark search","containerTag":"memory_bench"}' || true)"
  else
    status="no_api_key"
    printf '{"error":"api key unavailable"}\n' > "$output_file"
  fi
  end_ms="$(now_ms)"
  printf 'status=%s latency_ms=%s\n' "$status" "$((end_ms - start_ms))"
}

add_document() {
  local port="$1"
  local api_key="$2"
  local output_file="$3"
  local body_file="$4"
  local start_ms end_ms status
  start_ms="$(now_ms)"
  if [[ -n "$api_key" ]]; then
    status="$(curl -sS -o "$output_file" -w '%{http_code}' "http://127.0.0.1:$port/v3/documents" \
      -H "Authorization: Bearer $api_key" \
      -H 'Content-Type: application/json' \
      --data-binary "@$body_file" || true)"
  else
    status="no_api_key"
    printf '{"error":"api key unavailable"}\n' > "$output_file"
  fi
  end_ms="$(now_ms)"
  printf 'status=%s latency_ms=%s\n' "$status" "$((end_ms - start_ms))"
}

write_long_doc_body() {
  local output_file="$1"
  local repeated="This benchmark document repeats distinctive content about memory pressure, pglite snapshots, embeddings, and search correctness. "
  local content=""
  for _ in $(seq 1 "$DOC_REPEAT_COUNT"); do
    content+="$repeated"
  done
  CONTENT="$content" bun -e 'const content = process.env.CONTENT; await Bun.write(process.argv[1], JSON.stringify({ content, containerTag: "memory_bench", customId: "memory-bench-" + Date.now() }))' "$output_file"
}

summarize_samples() {
  local samples_file="$1"
  local output_file="$2"
  bun -e '
const file = process.argv[1];
const rows = (await Bun.file(file).text()).trim().split("\n").slice(1).filter(Boolean).map((line) => {
  const [epoch_ms, label, rss_kb, vsz_kb] = line.split(",");
  return { epoch_ms: Number(epoch_ms), label, rss_kb: Number(rss_kb), vsz_kb: Number(vsz_kb) };
}).filter((row) => Number.isFinite(row.rss_kb));
const byLabel = new Map();
for (const row of rows) {
  const existing = byLabel.get(row.label) ?? { samples: 0, peak_rss_kb: 0, last_rss_kb: 0, min_rss_kb: Number.POSITIVE_INFINITY };
  existing.samples += 1;
  existing.peak_rss_kb = Math.max(existing.peak_rss_kb, row.rss_kb);
  existing.min_rss_kb = Math.min(existing.min_rss_kb, row.rss_kb);
  existing.last_rss_kb = row.rss_kb;
  byLabel.set(row.label, existing);
}
const summary = {
  samples: rows.length,
  peak_rss_mb: rows.length ? Math.round(Math.max(...rows.map((row) => row.rss_kb)) / 1024) : null,
  last_rss_mb: rows.length ? Math.round(rows.at(-1).rss_kb / 1024) : null,
  labels: Object.fromEntries([...byLabel].map(([label, value]) => [label, {
    samples: value.samples,
    peak_rss_mb: Math.round(value.peak_rss_kb / 1024),
    min_rss_mb: Math.round(value.min_rss_kb / 1024),
    last_rss_mb: Math.round(value.last_rss_kb / 1024),
  }])),
};
await Bun.write(process.argv[2], JSON.stringify(summary, null, 2));
' "$samples_file" "$output_file"
}

run_scenario() {
  local name="$1"
  shift

  local run_dir="$BENCH_ROOT/runs/$(timestamp)-$name"
  local data_dir="$run_dir/data"
  local log_file="$run_dir/server.log"
  local label_file="$run_dir/phase.txt"
  local samples_file="$run_dir/samples.csv"
  local metadata_file="$run_dir/metadata.txt"
  local env_file="$run_dir/env.txt"
  local port
  port="$((PORT_BASE + RANDOM % 1000))"

  mkdir -p "$run_dir"
  copy_seed_data "$data_dir"
  printf 'booting' > "$label_file"

  {
    printf 'name=%s\n' "$name"
    printf 'port=%s\n' "$port"
    printf 'server_bin=%s\n' "$SERVER_BIN"
    printf 'data_dir=%s\n' "$data_dir"
    printf 'source_data_dir=%s\n' "$SOURCE_DATA_DIR"
    printf 'started_at=%s\n' "$(date -Iseconds)"
  } > "$metadata_file"

  printf '%s\n' "$@" > "$env_file"

  local pid sampler_pid
  (
    cd "$run_dir"
    exec env PORT="$port" SUPERMEMORY_PORT="$port" SUPERMEMORY_DATA_DIR="$data_dir" SUPERMEMORY_VERBOSE="${SUPERMEMORY_VERBOSE:-1}" SUPERMEMORY_NO_OPEN="1" SUPERMEMORY_NO_UPDATE_CHECK="1" "$@" "$SERVER_BIN"
  ) > "$log_file" 2>&1 &
  pid="$!"

  sample_loop "$pid" "$samples_file" "$label_file" &
  sampler_pid="$!"

  local ready_start ready_end ready_status
  ready_start="$(now_ms)"
  if wait_for_ready "$port" "$log_file"; then
    ready_status="ready"
  else
    ready_status="not_ready"
  fi
  ready_end="$(now_ms)"
  printf 'ready_status=%s\nready_latency_ms=%s\n' "$ready_status" "$((ready_end - ready_start))" >> "$metadata_file"

  if [[ "$ready_status" != "ready" ]]; then
    printf 'failed' > "$label_file"
    if process_alive "$pid"; then kill "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    summarize_samples "$samples_file" "$run_dir/summary.json" || true
    printf '%s\n' "$run_dir"
    return 1
  fi

  local api_key
  api_key="$(read_api_key "$data_dir" || true)"
  if [[ -n "$api_key" ]]; then
    printf 'api_key_available=yes\n' >> "$metadata_file"
  else
    printf 'api_key_available=no\n' >> "$metadata_file"
  fi

  if [[ "$RUN_VM_MAP" == "1" && "$(uname -s)" == "Darwin" ]]; then
    vmmap -summary "$pid" > "$run_dir/vmmap-ready.txt" 2>&1 || true
  fi

  if [[ "$WARM_AFTER_READY" == "1" ]]; then
    printf 'background_warmup' > "$label_file"
    search_once "$port" "$api_key" "$run_dir/warmup-search.json" > "$run_dir/warmup-search.txt" &
    warmup_pid="$!"
    wait "$warmup_pid" || true
  fi

  printf 'ready_idle' > "$label_file"
  sleep "$IDLE_SECONDS"

  printf 'first_search' > "$label_file"
  search_once "$port" "$api_key" "$run_dir/search-first.json" > "$run_dir/search-first.txt"

  printf 'post_search_idle' > "$label_file"
  sleep "$POST_SEARCH_IDLE_SECONDS"

  printf 'second_search' > "$label_file"
  search_once "$port" "$api_key" "$run_dir/search-second.json" > "$run_dir/search-second.txt"

  printf 'add_document' > "$label_file"
  : > "$run_dir/add-document.txt"
  for add_index in $(seq 1 "$ADD_COUNT"); do
    write_long_doc_body "$run_dir/add-body-$add_index.json"
    add_document "$port" "$api_key" "$run_dir/add-response-$add_index.json" "$run_dir/add-body-$add_index.json" >> "$run_dir/add-document.txt"
  done

  printf 'post_add_idle' > "$label_file"
  sleep "$POST_ADD_IDLE_SECONDS"

  if [[ "$RUN_VM_MAP" == "1" && "$(uname -s)" == "Darwin" ]]; then
    vmmap -summary "$pid" > "$run_dir/vmmap-final.txt" 2>&1 || true
  fi

  printf 'shutdown' > "$label_file"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true

  summarize_samples "$samples_file" "$run_dir/summary.json"
  printf 'finished_at=%s\n' "$(date -Iseconds)" >> "$metadata_file"
  printf '%s\n' "$run_dir"
}

run_suite() {
  local results_file="$BENCH_ROOT/runs/$(timestamp)-suite.txt"
  : > "$results_file"
  run_scenario baseline >> "$results_file" || true
  run_scenario skip-prewarm SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 >> "$results_file" || true
  run_scenario idle-15s SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=15000 >> "$results_file" || true
  run_scenario idle-30s SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 >> "$results_file" || true
  run_scenario recycle-1 SUPERMEMORY_LOCAL_EMBEDDING_MAX_BATCHES_BEFORE_RECYCLE=1 >> "$results_file" || true
  run_scenario skip-prewarm-idle-30s SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 >> "$results_file" || true
  printf '%s\n' "$results_file"
}

case "$command_name" in
  scenario)
    if [[ $# -lt 1 ]]; then
      usage
      exit 2
    fi
    name="$1"
    shift
    run_scenario "$name" "$@"
    ;;
  suite)
    run_suite
    ;;
  *)
    usage
    exit 2
    ;;
esac
