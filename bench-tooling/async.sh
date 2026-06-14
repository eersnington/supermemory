#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/.memory-bench/profile-matrix}"
RUN_COUNT="${RUN_COUNT:-5}"
SCENARIOS="${SCENARIOS:-balanced-30s-quick}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-60}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
RUN_VM_MAP="${RUN_VM_MAP:-0}"

usage() {
  cat <<'USAGE'
Usage:
  bench-tooling/async.sh

Starts bench-tooling/matrix.sh in the background with nohup, writes a
manifest immediately, and returns before OpenCode's command timeout can matter.

Useful environment:
  RUN_COUNT                 Runs for this chunk. Defaults to 5.
  SCENARIOS                 Comma-separated scenarios. Defaults to balanced-30s-quick.
  COOLDOWN_SECONDS          Wait between iterations. Defaults to 60.
  SAMPLE_INTERVAL_SECONDS   RSS sample interval. Defaults to 1.
  OUT_ROOT                  Output root. Defaults to .memory-bench/profile-matrix.

Collect completed chunks later with:
  bun bench-tooling/collect.ts <output-dir> <matrix-run-dir> [...]
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! [[ "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: RUN_COUNT must be a positive integer\n' >&2
  exit 1
fi

if ! [[ "$COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]; then
  printf 'error: COOLDOWN_SECONDS must be a non-negative integer\n' >&2
  exit 1
fi

mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
RUN_ROOT="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)-async"
LOG_PATH="$RUN_ROOT/async.log"
PID_PATH="$RUN_ROOT/async.pid"
MANIFEST_PATH="$RUN_ROOT/async.json"

mkdir -p "$RUN_ROOT"

nohup env \
  MATRIX_RUN_ROOT="$RUN_ROOT" \
  OUT_ROOT="$OUT_ROOT" \
  RUN_COUNT="$RUN_COUNT" \
  SCENARIOS="$SCENARIOS" \
  COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
  SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" \
  RUN_VM_MAP="$RUN_VM_MAP" \
  ADD_COUNT="${ADD_COUNT:-1}" \
  DOC_REPEAT_COUNT="${DOC_REPEAT_COUNT:-120}" \
  SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-$HOME/.supermemory}" \
  "$SCRIPT_DIR/matrix.sh" > "$LOG_PATH" 2>&1 < /dev/null &
PID="$!"
printf '%s\n' "$PID" > "$PID_PATH"

MANIFEST_PATH="$MANIFEST_PATH" \
PID="$PID" \
RUN_ROOT="$RUN_ROOT" \
LOG_PATH="$LOG_PATH" \
PID_PATH="$PID_PATH" \
RUN_COUNT="$RUN_COUNT" \
SCENARIOS="$SCENARIOS" \
COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" \
bun -e '
const manifest = {
  pid: Number(process.env.PID),
  startedAt: new Date().toISOString(),
  runRoot: process.env.RUN_ROOT,
  logPath: process.env.LOG_PATH,
  pidPath: process.env.PID_PATH,
  runsTsvPath: `${process.env.RUN_ROOT}/runs.tsv`,
  summaryPath: `${process.env.RUN_ROOT}/summary.md`,
  summaryJsonPath: `${process.env.RUN_ROOT}/summary.json`,
  runCount: Number(process.env.RUN_COUNT),
  scenarios: process.env.SCENARIOS,
  cooldownSeconds: Number(process.env.COOLDOWN_SECONDS),
  sampleIntervalSeconds: process.env.SAMPLE_INTERVAL_SECONDS,
};
await Bun.write(process.env.MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`);
'

printf 'Started async low-memory profile matrix.\n'
printf 'PID: %s\n' "$PID"
printf 'Run root: %s\n' "$RUN_ROOT"
printf 'Log: %s\n' "$LOG_PATH"
printf 'Partial summary: %s\n' "$RUN_ROOT/summary.md"
printf 'Structured manifest: %s\n' "$MANIFEST_PATH"
