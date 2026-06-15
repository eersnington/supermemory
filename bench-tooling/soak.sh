#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

SERVER_BIN="${SERVER_BIN:-$HOME/.supermemory/bin/supermemory-server}"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/.memory-bench/soak}"
SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-$HOME/.supermemory}"
PORT_BASE="${PORT_BASE:-19667}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-90}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
CYCLES="${CYCLES:-20}"
IDLE_SECONDS="${IDLE_SECONDS:-40}"
DOC_REPEAT_COUNT="${DOC_REPEAT_COUNT:-120}"

usage() {
  cat <<'USAGE'
Usage:
  bench-tooling/soak.sh [KEY=VALUE ...]

Runs one server through repeated warm/search/add/idle cycles and records RSS after
each phase. Defaults to the optimized local profile.

Environment:
  CYCLES                    Number of cycles. Defaults to 20.
  IDLE_SECONDS              Idle wait after add/search. Defaults to 40.
  DOC_REPEAT_COUNT          Repeated text units in each added document. Defaults to 120.
  SOURCE_DATA_DIR           Seed data directory. Defaults to ~/.supermemory.
  SAMPLE_INTERVAL_SECONDS   RSS sample interval. Defaults to 1.
  OUT_ROOT                  Output root. Defaults to .memory-bench/soak.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! [[ "$CYCLES" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: CYCLES must be a positive integer\n' >&2
  exit 1
fi

if ! [[ "$IDLE_SECONDS" =~ ^[0-9]+$ ]]; then
  printf 'error: IDLE_SECONDS must be a non-negative integer\n' >&2
  exit 1
fi

set_default_env() {
  local key="$1"
  local value="$2"
  if [[ -z "${!key:-}" ]]; then
    export "$key=$value"
  fi
}

apply_default_profile() {
  set_default_env SUPERMEMORY_SKIP_EMBEDDING_PREWARM 1
  set_default_env SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS 30000
}

apply_default_profile

SERVER_BIN="$(cd "$(dirname "$SERVER_BIN")" && pwd -P)/$(basename "$SERVER_BIN")"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
RUN_ROOT="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
DATA_DIR="$RUN_ROOT/data"
LOG_FILE="$RUN_ROOT/server.log"
PHASE_FILE="$RUN_ROOT/phase.txt"
SAMPLES_FILE="$RUN_ROOT/samples.csv"
CYCLES_TSV="$RUN_ROOT/cycles.tsv"
METADATA_FILE="$RUN_ROOT/metadata.txt"
ENV_FILE="$RUN_ROOT/env.txt"
PORT="$((PORT_BASE + RANDOM % 1000))"

mkdir -p "$RUN_ROOT"
if [[ -d "$SOURCE_DATA_DIR" ]]; then
  cp -R "$SOURCE_DATA_DIR" "$DATA_DIR"
else
  mkdir -p "$DATA_DIR"
fi

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

rss_mb() {
  local pid="$1"
  local rss_kb
  rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [[ -z "$rss_kb" ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "$(( (rss_kb + 512) / 1024 ))"
}

process_alive() {
  kill -0 "$1" 2>/dev/null
}

sample_loop() {
  local pid="$1"
  printf 'epoch_ms,label,rss_kb\n' > "$SAMPLES_FILE"
  while process_alive "$pid"; do
    local label
    label="$(tr -d '\n' < "$PHASE_FILE" 2>/dev/null || true)"
    printf '%s,%s,%s\n' "$(now_ms)" "${label:-unknown}" "$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')" >> "$SAMPLES_FILE"
    sleep "$SAMPLE_INTERVAL_SECONDS"
  done
}

wait_for_ready() {
  local pid="$1"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
      return 0
    fi
    if ! process_alive "$pid"; then
      return 1
    fi
    if (( $(date +%s) - started_at > READY_TIMEOUT_SECONDS )); then
      return 1
    fi
    sleep 0.25
  done
}

read_api_key() {
  local key_file="$DATA_DIR/api-key"
  if [[ -f "$key_file" ]]; then
    tr -d '\r\n' < "$key_file"
  fi
}

search_once() {
  local api_key="$1"
  local output_file="$2"
  local start_ms end_ms status
  start_ms="$(now_ms)"
  if [[ -n "$api_key" ]]; then
    status="$(curl -sS -o "$output_file" -w '%{http_code}' "http://127.0.0.1:$PORT/v3/search" \
      -H "Authorization: Bearer $api_key" \
      -H 'Content-Type: application/json' \
      -d '{"q":"memory soak search","containerTag":"memory_soak"}' || true)"
  else
    status="no_api_key"
    printf '{"error":"api key unavailable"}\n' > "$output_file"
  fi
  end_ms="$(now_ms)"
  printf 'status=%s latency_ms=%s\n' "$status" "$((end_ms - start_ms))"
}

write_doc_body() {
  local output_file="$1"
  local cycle="$2"
  local repeated="This soak document repeats content about memory pressure, embeddings, and idle release. "
  local content=""
  for _ in $(seq 1 "$DOC_REPEAT_COUNT"); do
    content+="$repeated"
  done
  CONTENT="$content" CYCLE="$cycle" bun -e 'const content = process.env.CONTENT; const cycle = process.env.CYCLE; await Bun.write(process.argv[1], JSON.stringify({ content, containerTag: "memory_soak", customId: `memory-soak-${cycle}-${Date.now()}` }))' "$output_file"
}

add_document() {
  local api_key="$1"
  local body_file="$2"
  local output_file="$3"
  local start_ms end_ms status
  start_ms="$(now_ms)"
  if [[ -n "$api_key" ]]; then
    status="$(curl -sS -o "$output_file" -w '%{http_code}' "http://127.0.0.1:$PORT/v3/documents" \
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

summarize() {
  RUN_ROOT="$RUN_ROOT" bun -e '
const root = process.env.RUN_ROOT;
const text = await Bun.file(`${root}/cycles.tsv`).text();
const rows = text.trim().split("\n").slice(1).filter(Boolean).map((line) => {
  const [cycle, afterReady, afterWarmup, afterSearch, afterAdd, afterIdle] = line.split("\t").map(Number);
  return { cycle, afterReady, afterWarmup, afterSearch, afterAdd, afterIdle };
});
const first = rows[0];
const last = rows.at(-1);
const idleDelta = first && last ? last.afterIdle - first.afterIdle : null;
const idleDeltaPct = first && last && first.afterIdle > 0 ? (idleDelta / first.afterIdle) * 100 : null;
let md = `# Low-Memory Soak Result\n\nRun root: \`${root}\`\n\n`;
md += `Cycles: \`${rows.length}\`\n\n`;
md += `Final idle delta: \`${idleDelta ?? "n/a"} MB\``;
if (idleDeltaPct !== null) md += ` (${idleDeltaPct >= 0 ? "+" : ""}${idleDeltaPct.toFixed(1)}%)`;
md += `\n\n| Cycle | After Ready | After Warmup | After Search | After Add | After Idle |\n`;
md += `|---:|---:|---:|---:|---:|---:|\n`;
for (const row of rows) {
  md += `| ${row.cycle} | ${row.afterReady} MB | ${row.afterWarmup} MB | ${row.afterSearch} MB | ${row.afterAdd} MB | ${row.afterIdle} MB |\n`;
}
await Bun.write(`${root}/summary.md`, md);
await Bun.write(`${root}/summary.json`, `${JSON.stringify({ cycles: rows.length, first, last, idleDeltaMb: idleDelta, idleDeltaPct }, null, 2)}\n`);
'
}

printf 'booting' > "$PHASE_FILE"
{
  printf 'SUPERMEMORY_SKIP_EMBEDDING_PREWARM=%s\n' "${SUPERMEMORY_SKIP_EMBEDDING_PREWARM:-}"
  printf 'SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=%s\n' "${SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS:-}"
  printf '%s\n' "$@"
} > "$ENV_FILE"
printf 'run_root=%s\nport=%s\ncycles=%s\nidle_seconds=%s\n' "$RUN_ROOT" "$PORT" "$CYCLES" "$IDLE_SECONDS" > "$METADATA_FILE"

(
  cd "$RUN_ROOT"
  exec env PORT="$PORT" SUPERMEMORY_PORT="$PORT" SUPERMEMORY_DATA_DIR="$DATA_DIR" SUPERMEMORY_VERBOSE="${SUPERMEMORY_VERBOSE:-1}" SUPERMEMORY_NO_OPEN="1" SUPERMEMORY_NO_UPDATE_CHECK="1" "$@" "$SERVER_BIN"
) > "$LOG_FILE" 2>&1 &
pid="$!"

sample_loop "$pid" &
sampler_pid="$!"

ready_start="$(now_ms)"
if ! wait_for_ready "$pid"; then
  printf 'failed\n' > "$PHASE_FILE"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  printf 'error: server did not become ready; see %s\n' "$LOG_FILE" >&2
  exit 1
fi
ready_end="$(now_ms)"
printf 'ready_latency_ms=%s\n' "$((ready_end - ready_start))" >> "$METADATA_FILE"

api_key="$(read_api_key || true)"
printf 'cycle\tafter_ready_mb\tafter_warmup_mb\tafter_search_mb\tafter_add_mb\tafter_idle_mb\n' > "$CYCLES_TSV"

for cycle in $(seq 1 "$CYCLES"); do
  printf 'cycle_%s_ready\n' "$cycle" > "$PHASE_FILE"
  after_ready="$(rss_mb "$pid")"

  printf 'cycle_%s_warmup\n' "$cycle" > "$PHASE_FILE"
  search_once "$api_key" "$RUN_ROOT/warmup-$cycle.json" > "$RUN_ROOT/warmup-$cycle.txt"
  after_warmup="$(rss_mb "$pid")"

  printf 'cycle_%s_search\n' "$cycle" > "$PHASE_FILE"
  search_once "$api_key" "$RUN_ROOT/search-$cycle.json" > "$RUN_ROOT/search-$cycle.txt"
  after_search="$(rss_mb "$pid")"

  printf 'cycle_%s_add\n' "$cycle" > "$PHASE_FILE"
  write_doc_body "$RUN_ROOT/add-body-$cycle.json" "$cycle"
  add_document "$api_key" "$RUN_ROOT/add-body-$cycle.json" "$RUN_ROOT/add-response-$cycle.json" > "$RUN_ROOT/add-$cycle.txt"
  after_add="$(rss_mb "$pid")"

  printf 'cycle_%s_idle\n' "$cycle" > "$PHASE_FILE"
  sleep "$IDLE_SECONDS"
  after_idle="$(rss_mb "$pid")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cycle" "$after_ready" "$after_warmup" "$after_search" "$after_add" "$after_idle" >> "$CYCLES_TSV"
done

printf 'shutdown' > "$PHASE_FILE"
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
summarize

printf 'Summary written to %s\n' "$RUN_ROOT/summary.md"
