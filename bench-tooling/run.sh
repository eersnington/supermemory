#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SERVER_BIN_DEFAULT="$HOME/.supermemory/bin/supermemory-server"
INSTALL_TARGET_DEFAULT="$HOME/.local/bin/sm-lowmem"

usage() {
  cat <<'USAGE'
Usage:
  bench-tooling/run.sh run
  bench-tooling/run.sh run-balanced
  bench-tooling/run.sh measure
  bench-tooling/run.sh measure-balanced
  bench-tooling/run.sh install

Environment:
  SUPERMEMORY_SERVER_BIN   Path to supermemory-server binary.
  SUPERMEMORY_PORT         Port used by the server in run mode.
  SUPERMEMORY_DATA_DIR     Data directory used by the server in run mode.
  SUPERMEMORY_EMBEDDING_RAM_LIMIT
                          Ingest memory headroom. Defaults to 1gb in this profile.
  SOURCE_DATA_DIR          Seed data directory for measure mode. Defaults to ~/.supermemory.
  IDLE_SECONDS             Ready-idle sampling time for measure mode.

This script does not patch or modify the binary. It launches the current binary
with a low-memory profile, or measures that profile against the default binary.
USAGE
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

resolve_server_bin() {
  local candidate="${SUPERMEMORY_SERVER_BIN:-$SERVER_BIN_DEFAULT}"
  if [[ ! -x "$candidate" ]]; then
    fail "supermemory-server binary is not executable at $candidate. Set SUPERMEMORY_SERVER_BIN to override."
  fi
  printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" "$(basename "$candidate")"
}

set_default_env() {
  local key="$1"
  local value="$2"
  if [[ -z "${!key:-}" ]]; then
    export "$key=$value"
  fi
}

apply_lowmem_defaults() {
  set_default_env SUPERMEMORY_SKIP_EMBEDDING_PREWARM 1
  set_default_env SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS 30000
  set_default_env SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE 2
  set_default_env SUPERMEMORY_EMBEDDING_RAM_LIMIT 1gb
  set_default_env SUPERMEMORY_NO_OPEN 1
  set_default_env SUPERMEMORY_NO_UPDATE_CHECK 1
}

print_profile() {
  cat <<EOF
supermemory low-memory profile

Applied defaults unless already set:
  SUPERMEMORY_SKIP_EMBEDDING_PREWARM=${SUPERMEMORY_SKIP_EMBEDDING_PREWARM:-}
  SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=${SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS:-}
  SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=${SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE:-}
  SUPERMEMORY_EMBEDDING_RAM_LIMIT=${SUPERMEMORY_EMBEDDING_RAM_LIMIT:-}
  SUPERMEMORY_NO_OPEN=${SUPERMEMORY_NO_OPEN:-}
  SUPERMEMORY_NO_UPDATE_CHECK=${SUPERMEMORY_NO_UPDATE_CHECK:-}

Tradeoff: first search/add that needs embeddings may pay cached model load latency.
EOF
}

run_server() {
  local server_bin
  server_bin="$(resolve_server_bin)"
  apply_lowmem_defaults
  print_profile
  exec "$server_bin"
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

wait_for_http_ready() {
  local port="$1"
  local pid="$2"
  local timeout_seconds="${READY_TIMEOUT_SECONDS:-90}"
  local started_at
  started_at="$(date +%s)"

  while true; do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi

    if (( $(date +%s) - started_at > timeout_seconds )); then
      return 1
    fi

    sleep 0.25
  done
}

api_key_file_for_run() {
  if [[ -n "${SUPERMEMORY_DATA_DIR:-}" && -f "$SUPERMEMORY_DATA_DIR/api-key" ]]; then
    printf '%s\n' "$SUPERMEMORY_DATA_DIR/api-key"
    return 0
  fi

  if [[ -f ".supermemory/api-key" ]]; then
    printf '%s\n' ".supermemory/api-key"
    return 0
  fi

  if [[ -f "$HOME/.supermemory/api-key" ]]; then
    printf '%s\n' "$HOME/.supermemory/api-key"
    return 0
  fi

  return 1
}

warm_search() {
  local port="$1"
  local api_key_file
  if ! api_key_file="$(api_key_file_for_run)"; then
    printf 'warning: no api-key file found; skipping background embedding warmup\n' >&2
    return 0
  fi

  local api_key start_ms end_ms status
  api_key="$(tr -d '\r\n' < "$api_key_file")"
  start_ms="$(now_ms)"
  status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v3/search" \
    -H "Authorization: Bearer $api_key" \
    -H 'Content-Type: application/json' \
    -d '{"q":"supermemory local embedding warmup","containerTag":"__sm_warmup__"}' || true)"
  end_ms="$(now_ms)"
  printf 'background warmup search status=%s latency_ms=%s\n' "$status" "$((end_ms - start_ms))"
}

run_balanced() {
  local server_bin port ready_start ready_end pid
  server_bin="$(resolve_server_bin)"
  apply_lowmem_defaults
  port="${SUPERMEMORY_PORT:-${PORT:-6767}}"

  print_profile
  printf '\nBalanced mode: HTTP starts first, then a background warmup search loads embeddings.\n'

  "$server_bin" &
  pid="$!"

  ready_start="$(now_ms)"
  if ! wait_for_http_ready "$port" "$pid"; then
    printf 'error: server did not become HTTP-ready on port %s\n' "$port" >&2
    wait "$pid" 2>/dev/null || true
    exit 1
  fi
  ready_end="$(now_ms)"
  printf 'HTTP ready latency: %sms\n' "$((ready_end - ready_start))"

  warm_search "$port" &
  warmup_pid="$!"

  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' INT TERM
  wait "$warmup_pid" 2>/dev/null || true
  wait "$pid"
}

latest_run_dir() {
  local scenario_name="$1"
  local run_dir
  run_dir="$(ls -td "$REPO_ROOT/.memory-bench/runs"/*-"$scenario_name" 2>/dev/null | head -n 1 || true)"
  if [[ -z "$run_dir" ]]; then
    fail "could not find benchmark run directory for scenario $scenario_name"
  fi
  printf '%s\n' "$run_dir"
}

run_bench_scenario() {
  local scenario_name="$1"
  shift
  SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-$HOME/.supermemory}" \
    RUN_VM_MAP="${RUN_VM_MAP:-0}" \
    IDLE_SECONDS="${IDLE_SECONDS:-18}" \
    POST_SEARCH_IDLE_SECONDS="${POST_SEARCH_IDLE_SECONDS:-8}" \
    POST_ADD_IDLE_SECONDS="${POST_ADD_IDLE_SECONDS:-8}" \
    "$SCRIPT_DIR/bench.sh" scenario "$scenario_name" "$@"
}

summarize_measurement() {
  local baseline_dir="$1"
  local lowmem_dir="$2"
  bun -e '
const [baselineDir, lowmemDir] = process.argv.slice(1);

async function readText(path) {
  try { return await Bun.file(path).text(); } catch { return ""; }
}

function field(text, name) {
  const match = new RegExp(`^${name}=(.*)$`, "m").exec(text);
  return match?.[1]?.trim() ?? null;
}

function latency(text) {
  const match = /latency_ms=(\d+)/.exec(text);
  return match ? Number(match[1]) : null;
}

function status(text) {
  const match = /status=([^\s]+)/.exec(text);
  return match?.[1] ?? null;
}

function pctDelta(base, next) {
  if (!Number.isFinite(base) || !Number.isFinite(next) || base === 0) return null;
  return ((next - base) / base) * 100;
}

function fmt(value, suffix = "") {
  if (value === null || value === undefined || Number.isNaN(value)) return "n/a";
  if (typeof value === "number") return `${Math.round(value)}${suffix}`;
  return String(value);
}

function fmtPct(value) {
  if (value === null || value === undefined || Number.isNaN(value)) return "n/a";
  const rounded = Math.round(value * 10) / 10;
  return `${rounded > 0 ? "+" : ""}${rounded}%`;
}

async function collect(dir) {
  const summary = await Bun.file(`${dir}/summary.json`).json();
  const metadata = await readText(`${dir}/metadata.txt`);
  const firstSearch = await readText(`${dir}/search-first.txt`);
  const addDocument = await readText(`${dir}/add-document.txt`);
  return {
    dir,
    readyMs: Number(field(metadata, "ready_latency_ms")),
    peakMb: summary.peak_rss_mb ?? null,
    lastMb: summary.last_rss_mb ?? null,
    readyIdleLastMb: summary.labels?.ready_idle?.last_rss_mb ?? null,
    postSearchLastMb: summary.labels?.post_search_idle?.last_rss_mb ?? null,
    postAddLastMb: summary.labels?.post_add_idle?.last_rss_mb ?? null,
    firstSearchStatus: status(firstSearch),
    firstSearchMs: latency(firstSearch),
    addStatus: status(addDocument),
    addMs: latency(addDocument),
  };
}

const baseline = await collect(baselineDir);
const lowmem = await collect(lowmemDir);
const readyDelta = pctDelta(baseline.readyMs, lowmem.readyMs);
const peakDelta = pctDelta(baseline.peakMb, lowmem.peakMb);
const readyIdleDelta = pctDelta(baseline.readyIdleLastMb, lowmem.readyIdleLastMb);
const firstSearchDeltaMs = Number.isFinite(baseline.firstSearchMs) && Number.isFinite(lowmem.firstSearchMs)
  ? lowmem.firstSearchMs - baseline.firstSearchMs
  : null;

let verdict;
if (Number.isFinite(readyIdleDelta) && readyIdleDelta <= -10) {
  verdict = "Useful local ready-idle RSS reduction measured. Keep the first-search latency cost in mind.";
} else if (Number.isFinite(readyDelta) && readyDelta < 0) {
  verdict = "Startup readiness improved, but ready-idle RSS did not reliably improve in this run.";
} else {
  verdict = "No reliable local memory win measured in this run. Use the default binary unless you need the ingest-spike safeguards.";
}

console.log(`supermemory low-memory measurement\n`);
console.log(`Baseline:`);
console.log(`  ready latency:      ${fmt(baseline.readyMs, " ms")}`);
console.log(`  peak RSS:           ${fmt(baseline.peakMb, " MB")}`);
console.log(`  ready-idle last:    ${fmt(baseline.readyIdleLastMb, " MB")}`);
console.log(`  post-search last:   ${fmt(baseline.postSearchLastMb, " MB")}`);
console.log(`  post-add last:      ${fmt(baseline.postAddLastMb, " MB")}`);
console.log(`  first search:       ${fmt(baseline.firstSearchMs, " ms")} (${baseline.firstSearchStatus ?? "n/a"})`);
console.log(`  add document:       ${fmt(baseline.addMs, " ms")} (${baseline.addStatus ?? "n/a"})\n`);

console.log(`Low-memory profile:`);
console.log(`  ready latency:      ${fmt(lowmem.readyMs, " ms")}`);
console.log(`  peak RSS:           ${fmt(lowmem.peakMb, " MB")}`);
console.log(`  ready-idle last:    ${fmt(lowmem.readyIdleLastMb, " MB")}`);
console.log(`  post-search last:   ${fmt(lowmem.postSearchLastMb, " MB")}`);
console.log(`  post-add last:      ${fmt(lowmem.postAddLastMb, " MB")}`);
console.log(`  first search:       ${fmt(lowmem.firstSearchMs, " ms")} (${lowmem.firstSearchStatus ?? "n/a"})`);
console.log(`  add document:       ${fmt(lowmem.addMs, " ms")} (${lowmem.addStatus ?? "n/a"})\n`);

console.log(`Deltas:`);
console.log(`  ready latency:      ${fmtPct(readyDelta)}`);
console.log(`  peak RSS:           ${fmtPct(peakDelta)}`);
console.log(`  ready-idle RSS:     ${fmtPct(readyIdleDelta)}`);
console.log(`  first search cost:  ${firstSearchDeltaMs === null ? "n/a" : `${firstSearchDeltaMs >= 0 ? "+" : ""}${firstSearchDeltaMs} ms`}\n`);

console.log(`Verdict:`);
console.log(`  ${verdict}\n`);
console.log(`Run directories:`);
console.log(`  Baseline:           ${baseline.dir}`);
console.log(`  Low-memory:         ${lowmem.dir}`);
' "$baseline_dir" "$lowmem_dir"
}

run_measurement() {
  if [[ ! -x "$SCRIPT_DIR/bench.sh" ]]; then
    fail "missing executable benchmark harness at $SCRIPT_DIR/bench.sh"
  fi

  printf 'Running baseline benchmark...\n'
  local baseline_output baseline_dir
  baseline_output="$(run_bench_scenario sm-lowmem-baseline)"
  baseline_dir="$(printf '%s\n' "$baseline_output" | tail -n 1)"

  printf 'Running low-memory benchmark...\n'
  local lowmem_output lowmem_dir
  lowmem_output="$(run_bench_scenario sm-lowmem-profile \
    SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 \
    SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 \
    SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2 \
    SUPERMEMORY_EMBEDDING_RAM_LIMIT=1gb)"
  lowmem_dir="$(printf '%s\n' "$lowmem_output" | tail -n 1)"

  printf '\n'
  summarize_measurement "$baseline_dir" "$lowmem_dir"
}

summarize_balanced_measurement() {
  local baseline_dir="$1"
  local cold_dir="$2"
  local balanced_dir="$3"
  bun -e '
const [baselineDir, coldDir, balancedDir] = process.argv.slice(1);

async function text(path) { try { return await Bun.file(path).text(); } catch { return ""; } }
function field(source, name) { return new RegExp(`^${name}=(.*)$`, "m").exec(source)?.[1]?.trim() ?? null; }
function latency(source) { const match = /latency_ms=(\d+)/.exec(source); return match ? Number(match[1]) : null; }
function pct(base, next) { return Number.isFinite(base) && Number.isFinite(next) && base !== 0 ? ((next - base) / base) * 100 : null; }
function fmt(value, suffix = "") { return value == null || Number.isNaN(value) ? "n/a" : `${Math.round(value)}${suffix}`; }
function fmtPct(value) { return value == null || Number.isNaN(value) ? "n/a" : `${value > 0 ? "+" : ""}${Math.round(value * 10) / 10}%`; }

async function collect(label, dir) {
  const summary = await Bun.file(`${dir}/summary.json`).json();
  const metadata = await text(`${dir}/metadata.txt`);
  const firstSearch = await text(`${dir}/search-first.txt`);
  const warmupSearch = await text(`${dir}/warmup-search.txt`);
  return {
    label,
    dir,
    readyMs: Number(field(metadata, "ready_latency_ms")),
    peakMb: summary.peak_rss_mb ?? null,
    readyIdleLastMb: summary.labels?.ready_idle?.last_rss_mb ?? null,
    postSearchLastMb: summary.labels?.post_search_idle?.last_rss_mb ?? null,
    postAddLastMb: summary.labels?.post_add_idle?.last_rss_mb ?? null,
    warmupMs: latency(warmupSearch),
    firstSearchMs: latency(firstSearch),
  };
}

const baseline = await collect("Baseline", baselineDir);
const cold = await collect("Cold low-memory", coldDir);
const balanced = await collect("Balanced warmup", balancedDir);
const rows = [baseline, cold, balanced];

console.log("supermemory balanced warmup measurement\n");
for (const row of rows) {
  console.log(`${row.label}:`);
  console.log(`  ready latency:      ${fmt(row.readyMs, " ms")}`);
  console.log(`  peak RSS:           ${fmt(row.peakMb, " MB")}`);
  console.log(`  ready-idle last:    ${fmt(row.readyIdleLastMb, " MB")}`);
  console.log(`  post-search last:   ${fmt(row.postSearchLastMb, " MB")}`);
  console.log(`  post-add last:      ${fmt(row.postAddLastMb, " MB")}`);
  console.log(`  warmup search:      ${fmt(row.warmupMs, " ms")}`);
  console.log(`  first real search:  ${fmt(row.firstSearchMs, " ms")}\n`);
}

console.log("Deltas vs baseline:");
for (const row of [cold, balanced]) {
  const firstSearchCost = Number.isFinite(row.firstSearchMs) && Number.isFinite(baseline.firstSearchMs)
    ? row.firstSearchMs - baseline.firstSearchMs
    : null;
  console.log(`  ${row.label}:`);
  console.log(`    ready latency:    ${fmtPct(pct(baseline.readyMs, row.readyMs))}`);
  console.log(`    peak RSS:         ${fmtPct(pct(baseline.peakMb, row.peakMb))}`);
  console.log(`    ready-idle RSS:   ${fmtPct(pct(baseline.readyIdleLastMb, row.readyIdleLastMb))}`);
  console.log(`    first search:     ${firstSearchCost == null ? "n/a" : `${firstSearchCost >= 0 ? "+" : ""}${firstSearchCost} ms`}`);
}

const balancedSearchCost = Number.isFinite(balanced.firstSearchMs) && Number.isFinite(baseline.firstSearchMs)
  ? balanced.firstSearchMs - baseline.firstSearchMs
  : null;
let verdict = "Balanced warmup should be judged by first real search after warmup, not by pre-warm idle RSS.";
if (balancedSearchCost != null && balancedSearchCost <= 200 && balanced.readyMs < baseline.readyMs) {
  verdict = "Balanced warmup preserved fast HTTP readiness and made first real search close to baseline in this run.";
} else if (balanced.readyMs < baseline.readyMs) {
  verdict = "Balanced warmup improved HTTP readiness, but first real search was not close to baseline in this run.";
}
console.log(`\nVerdict:\n  ${verdict}\n`);
console.log("Run directories:");
for (const row of rows) console.log(`  ${row.label}: ${row.dir}`);
' "$baseline_dir" "$cold_dir" "$balanced_dir"
}

run_balanced_measurement() {
  if [[ ! -x "$SCRIPT_DIR/bench.sh" ]]; then
    fail "missing executable benchmark harness at $SCRIPT_DIR/bench.sh"
  fi

  printf 'Running baseline benchmark...\n'
  local baseline_output baseline_dir
  baseline_output="$(run_bench_scenario sm-balanced-baseline)"
  baseline_dir="$(printf '%s\n' "$baseline_output" | tail -n 1)"

  printf 'Running cold low-memory benchmark...\n'
  local cold_output cold_dir
  cold_output="$(run_bench_scenario sm-balanced-cold \
    SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 \
    SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 \
    SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2 \
    SUPERMEMORY_EMBEDDING_RAM_LIMIT=1gb)"
  cold_dir="$(printf '%s\n' "$cold_output" | tail -n 1)"

  printf 'Running balanced warmup benchmark...\n'
  local balanced_output balanced_dir
  balanced_output="$(WARM_AFTER_READY=1 run_bench_scenario sm-balanced-warm \
    SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1 \
    SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000 \
    SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2 \
    SUPERMEMORY_EMBEDDING_RAM_LIMIT=1gb)"
  balanced_dir="$(printf '%s\n' "$balanced_output" | tail -n 1)"

  printf '\n'
  summarize_balanced_measurement "$baseline_dir" "$cold_dir" "$balanced_dir"
}

install_wrapper() {
  local target="${INSTALL_TARGET:-$INSTALL_TARGET_DEFAULT}"
  local target_dir
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"
  cat > "$target" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/run.sh" "\$@"
EOF
  chmod +x "$target"
  printf 'Installed wrapper: %s\n' "$target"
  printf 'Try: %s measure-balanced\n' "$target"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

case "$1" in
  run)
    shift
    if [[ $# -ne 0 ]]; then usage; exit 2; fi
    run_server
    ;;
  run-balanced)
    shift
    if [[ $# -ne 0 ]]; then usage; exit 2; fi
    run_balanced
    ;;
  measure)
    shift
    if [[ $# -ne 0 ]]; then usage; exit 2; fi
    run_measurement
    ;;
  measure-balanced)
    shift
    if [[ $# -ne 0 ]]; then usage; exit 2; fi
    run_balanced_measurement
    ;;
  install)
    shift
    if [[ $# -ne 0 ]]; then usage; exit 2; fi
    install_wrapper
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
