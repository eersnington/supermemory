#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/.memory-bench/profile-matrix}"
SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-$HOME/.supermemory}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-0.25}"
RUN_VM_MAP="${RUN_VM_MAP:-0}"
ADD_COUNT="${ADD_COUNT:-1}"
DOC_REPEAT_COUNT="${DOC_REPEAT_COUNT:-120}"
RUN_COUNT="${RUN_COUNT:-1}"
SCENARIOS="${SCENARIOS:-stock-30s,optimized-cold-30s,optimized-background-30s,optimized-blocking-30s}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-0}"
WRITE_PARTIAL_SUMMARY="${WRITE_PARTIAL_SUMMARY:-1}"
MATRIX_RUN_ROOT="${MATRIX_RUN_ROOT:-}"

usage() {
  cat <<'USAGE'
Usage:
  bench-tooling/matrix.sh

Runs a focused self-hosted binary memory/latency matrix using bench-tooling/bench.sh.
Outputs are written under .memory-bench/profile-matrix/<timestamp>/.

Environment:
  SOURCE_DATA_DIR              Seed data directory. Defaults to ~/.supermemory.
  SAMPLE_INTERVAL_SECONDS      RSS sample interval. Defaults to 0.25.
  RUN_COUNT                    Runs per scenario. Use 100 for release-quality averages.
  SCENARIOS                    Comma-separated scenario labels to run.
  COOLDOWN_SECONDS             Seconds to wait between repeated iterations. Defaults to 0.
  WRITE_PARTIAL_SUMMARY        Write summary.md/json after each completed iteration. Defaults to 1.
  MATRIX_RUN_ROOT              Fixed output directory for async/background runs.
  OUT_ROOT                     Output root. Defaults to .memory-bench/profile-matrix.
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

if [[ ! -x "$SCRIPT_DIR/bench.sh" ]]; then
  fail "missing executable benchmark harness at $SCRIPT_DIR/bench.sh"
fi

if ! [[ "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  fail "RUN_COUNT must be a positive integer"
fi

if ! [[ "$COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]; then
  fail "COOLDOWN_SECONDS must be a non-negative integer"
fi

mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
if [[ -n "$MATRIX_RUN_ROOT" ]]; then
  if [[ "$MATRIX_RUN_ROOT" == /* ]]; then
    RUN_ROOT="$MATRIX_RUN_ROOT"
  else
    RUN_ROOT="$OUT_ROOT/$MATRIX_RUN_ROOT"
  fi
else
  RUN_ROOT="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
fi
BENCH_ROOT="$RUN_ROOT/bench"
RUNS_TSV="$RUN_ROOT/runs.tsv"
SUMMARY_MD="$RUN_ROOT/summary.md"

mkdir -p "$RUN_ROOT" "$BENCH_ROOT"
printf 'label\titeration\trun_dir\tidle_seconds\tpost_search_idle_seconds\tpost_add_idle_seconds\twarm_after_ready\tenv\n' > "$RUNS_TSV"

write_summary() {
  SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" RUN_COUNT="$RUN_COUNT" bun "$SCRIPT_DIR/summary.ts" "$RUNS_TSV" "$SUMMARY_MD" "$RUN_ROOT"
}

should_run() {
  local label="$1"
  [[ ",$SCENARIOS," == *",$label,"* ]]
}

run_case() {
  local label="$1"
  local idle_seconds="$2"
  local post_search_idle_seconds="$3"
  local post_add_idle_seconds="$4"
  local warm_after_ready="$5"
  shift 5

  local output run_dir env_text iteration scenario_name
  env_text="$*"
  for iteration in $(seq 1 "$RUN_COUNT"); do
    scenario_name="$label"
    if (( RUN_COUNT > 1 )); then
      scenario_name="$label-r$iteration"
    fi

    printf 'Running %-24s iteration=%s/%s idle=%ss post_search=%ss post_add=%ss warm=%s\n' \
      "$label" "$iteration" "$RUN_COUNT" "$idle_seconds" "$post_search_idle_seconds" "$post_add_idle_seconds" "$warm_after_ready"

    output="$(
      BENCH_ROOT="$BENCH_ROOT" \
      SOURCE_DATA_DIR="$SOURCE_DATA_DIR" \
      SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" \
      RUN_VM_MAP="$RUN_VM_MAP" \
      ADD_COUNT="$ADD_COUNT" \
      DOC_REPEAT_COUNT="$DOC_REPEAT_COUNT" \
      IDLE_SECONDS="$idle_seconds" \
      POST_SEARCH_IDLE_SECONDS="$post_search_idle_seconds" \
      POST_ADD_IDLE_SECONDS="$post_add_idle_seconds" \
      WARM_AFTER_READY="$warm_after_ready" \
      "$SCRIPT_DIR/bench.sh" scenario "$scenario_name" "$@"
    )"
    run_dir="$(printf '%s\n' "$output" | tail -n 1)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$iteration" "$run_dir" "$idle_seconds" "$post_search_idle_seconds" "$post_add_idle_seconds" "$warm_after_ready" "$env_text" >> "$RUNS_TSV"

    if [[ "$WRITE_PARTIAL_SUMMARY" == "1" ]]; then
      write_summary >/dev/null || true
    fi

    if (( COOLDOWN_SECONDS > 0 && iteration < RUN_COUNT )); then
      printf 'Cooling down for %ss before next iteration\n' "$COOLDOWN_SECONDS"
      sleep "$COOLDOWN_SECONDS"
    fi
  done
}

OPTIMIZED_15_ENV=(
  SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1
  SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=15000
)

OPTIMIZED_30_ENV=(
  SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1
  SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000
)

if should_run stock-30s; then run_case stock-30s 20 40 40 0; fi
if should_run optimized-cold-30s; then run_case optimized-cold-30s 20 40 40 0 "${OPTIMIZED_30_ENV[@]}"; fi
if should_run optimized-background-30s; then run_case optimized-background-30s 20 40 40 background "${OPTIMIZED_30_ENV[@]}"; fi
if should_run optimized-blocking-30s; then run_case optimized-blocking-30s 20 40 40 blocking "${OPTIMIZED_30_ENV[@]}"; fi
if should_run optimized-30s; then run_case optimized-30s 20 40 40 blocking "${OPTIMIZED_30_ENV[@]}"; fi
if should_run baseline-default; then run_case baseline-default 12 30 30 0; fi
if should_run cold-15s; then run_case cold-15s 12 30 30 0 "${OPTIMIZED_15_ENV[@]}"; fi
if should_run balanced-15s-quick; then run_case balanced-15s-quick 8 30 30 1 "${OPTIMIZED_15_ENV[@]}"; fi
if should_run balanced-15s-late; then run_case balanced-15s-late 25 30 30 1 "${OPTIMIZED_15_ENV[@]}"; fi
if should_run balanced-30s-quick; then run_case balanced-30s-quick 20 40 40 1 "${OPTIMIZED_30_ENV[@]}"; fi

write_summary

printf 'Summary written to %s\n' "$SUMMARY_MD"
