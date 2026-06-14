#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/.memory-bench/profile-matrix}"
RUN_COUNT="${RUN_COUNT:-100}"
SCENARIOS="${SCENARIOS:-balanced-30s-quick}"
PARALLEL_JOBS="${PARALLEL_JOBS:-auto}"
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-4}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-0}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
RUN_VM_MAP="${RUN_VM_MAP:-0}"

usage() {
  cat <<'USAGE'
Usage:
  bench-tooling/parallel.sh

Starts an adaptive parallel low-memory benchmark in the background and returns
immediately. It splits RUN_COUNT across multiple matrix workers, then collects
the worker summaries when all workers finish.

Environment:
  RUN_COUNT                 Total runs across all workers. Defaults to 100.
  SCENARIOS                 Comma-separated scenarios. Defaults to balanced-30s-quick.
  PARALLEL_JOBS             auto or explicit worker count. Defaults to auto.
  MAX_PARALLEL_JOBS         Upper cap when PARALLEL_JOBS=auto. Defaults to 4.
  COOLDOWN_SECONDS          Per-worker delay between iterations. Defaults to 0.
  SAMPLE_INTERVAL_SECONDS   RSS sample interval. Defaults to 1.
  OUT_ROOT                  Output root. Defaults to .memory-bench/profile-matrix.

Auto sizing is intentionally conservative. On a 16 GB / 10-core Mac it selects
2 workers, not 5+, because each worker launches a full server process.
USAGE
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! [[ "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  fail "RUN_COUNT must be a positive integer"
fi

if ! [[ "$MAX_PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  fail "MAX_PARALLEL_JOBS must be a positive integer"
fi

if ! [[ "$COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]; then
  fail "COOLDOWN_SECONDS must be a non-negative integer"
fi

system_memory_bytes() {
  sysctl -n hw.memsize 2>/dev/null || printf '0\n'
}

logical_cpu_count() {
  sysctl -n hw.logicalcpu 2>/dev/null || printf '1\n'
}

auto_jobs() {
  local mem_bytes logical_cpu mem_jobs cpu_jobs jobs
  mem_bytes="$(system_memory_bytes)"
  logical_cpu="$(logical_cpu_count)"

  # Roughly one full-server benchmark worker per 8 GB and per 4 logical CPUs.
  mem_jobs=$(( mem_bytes / 8589934592 ))
  cpu_jobs=$(( logical_cpu / 4 ))
  if (( mem_jobs < 1 )); then mem_jobs=1; fi
  if (( cpu_jobs < 1 )); then cpu_jobs=1; fi

  jobs="$mem_jobs"
  if (( cpu_jobs < jobs )); then jobs="$cpu_jobs"; fi
  if (( MAX_PARALLEL_JOBS < jobs )); then jobs="$MAX_PARALLEL_JOBS"; fi
  if (( RUN_COUNT < jobs )); then jobs="$RUN_COUNT"; fi
  printf '%s\n' "$jobs"
}

selected_jobs() {
  if [[ "$PARALLEL_JOBS" == "auto" ]]; then
    auto_jobs
    return
  fi
  if ! [[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    fail "PARALLEL_JOBS must be auto or a positive integer"
  fi
  if (( PARALLEL_JOBS > RUN_COUNT )); then
    printf '%s\n' "$RUN_COUNT"
  else
    printf '%s\n' "$PARALLEL_JOBS"
  fi
}

write_manifest() {
  local manifest_path="$1"
  local pid="$2"
  local run_root="$3"
  local jobs="$4"
  MANIFEST_PATH="$manifest_path" \
  PID="$pid" \
  RUN_ROOT="$run_root" \
  RUN_COUNT="$RUN_COUNT" \
  SCENARIOS="$SCENARIOS" \
  PARALLEL_JOBS_SELECTED="$jobs" \
  PARALLEL_JOBS_REQUESTED="$PARALLEL_JOBS" \
  MAX_PARALLEL_JOBS="$MAX_PARALLEL_JOBS" \
  COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
  SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" \
  HW_MEM_BYTES="$(system_memory_bytes)" \
  HW_LOGICAL_CPU="$(logical_cpu_count)" \
  bun -e '
const runRoot = process.env.RUN_ROOT;
const manifest = {
  pid: Number(process.env.PID),
  startedAt: new Date().toISOString(),
  runRoot,
  logPath: `${runRoot}/parallel.log`,
  pidPath: `${runRoot}/parallel.pid`,
  workersPath: `${runRoot}/workers.tsv`,
  combinedSummaryPath: `${runRoot}/combined/summary.md`,
  combinedSummaryJsonPath: `${runRoot}/combined/summary.json`,
  runCount: Number(process.env.RUN_COUNT),
  scenarios: process.env.SCENARIOS,
  parallelJobs: Number(process.env.PARALLEL_JOBS_SELECTED),
  parallelJobsRequested: process.env.PARALLEL_JOBS_REQUESTED,
  maxParallelJobs: Number(process.env.MAX_PARALLEL_JOBS),
  cooldownSeconds: Number(process.env.COOLDOWN_SECONDS),
  sampleIntervalSeconds: process.env.SAMPLE_INTERVAL_SECONDS,
  hardware: {
    memoryBytes: Number(process.env.HW_MEM_BYTES),
    logicalCpu: Number(process.env.HW_LOGICAL_CPU),
  },
};
await Bun.write(process.env.MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`);
'
}

run_coordinator() {
  local run_root="$1"
  local jobs="$2"
  local workers_file="$run_root/workers.tsv"
  local pids=()

  printf 'worker\tpid\trun_count\trun_root\tlog_path\n' > "$workers_file"

  local base_count remainder worker worker_count worker_root worker_log worker_pid port_base
  base_count=$(( RUN_COUNT / jobs ))
  remainder=$(( RUN_COUNT % jobs ))

  for worker in $(seq 1 "$jobs"); do
    worker_count="$base_count"
    if (( worker <= remainder )); then
      worker_count=$(( worker_count + 1 ))
    fi

    worker_root="$run_root/worker-$worker"
    worker_log="$run_root/worker-$worker.log"
    port_base=$(( 17667 + worker * 1000 ))
    mkdir -p "$worker_root"

    env \
      MATRIX_RUN_ROOT="$worker_root" \
      OUT_ROOT="$run_root" \
      RUN_COUNT="$worker_count" \
      SCENARIOS="$SCENARIOS" \
      COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
      SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" \
      RUN_VM_MAP="$RUN_VM_MAP" \
      ADD_COUNT="${ADD_COUNT:-1}" \
      DOC_REPEAT_COUNT="${DOC_REPEAT_COUNT:-120}" \
      SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-$HOME/.supermemory}" \
      PORT_BASE="$port_base" \
      "$SCRIPT_DIR/matrix.sh" > "$worker_log" 2>&1 &
    worker_pid="$!"
    pids+=("$worker_pid")
    printf '%s\t%s\t%s\t%s\t%s\n' "$worker" "$worker_pid" "$worker_count" "$worker_root" "$worker_log" >> "$workers_file"
  done

  local exit_code=0 collect_inputs=()
  for worker_pid in "${pids[@]}"; do
    if ! wait "$worker_pid"; then
      exit_code=1
    fi
  done

  for worker in $(seq 1 "$jobs"); do
    collect_inputs+=("$run_root/worker-$worker")
  done
  bun "$SCRIPT_DIR/collect.ts" "$run_root/combined" "${collect_inputs[@]}" || exit_code=1
  printf 'finished_at=%s\nexit_code=%s\n' "$(date -Iseconds)" "$exit_code" > "$run_root/parallel-status.txt"
  return "$exit_code"
}

if [[ "${1:-}" == "__coordinator" ]]; then
  shift
  run_coordinator "$@"
  exit $?
fi

if pgrep -f "bench-tooling/(matrix|bench)\.sh|supermemory-server" >/dev/null 2>&1; then
  fail "benchmark/server process is already running; stop it before launching a parallel run"
fi

jobs="$(selected_jobs)"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
RUN_ROOT="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)-parallel"
LOG_PATH="$RUN_ROOT/parallel.log"
PID_PATH="$RUN_ROOT/parallel.pid"
MANIFEST_PATH="$RUN_ROOT/parallel.json"

mkdir -p "$RUN_ROOT"

nohup env \
  RUN_COUNT="$RUN_COUNT" \
  SCENARIOS="$SCENARIOS" \
  COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
  SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" \
  RUN_VM_MAP="$RUN_VM_MAP" \
  ADD_COUNT="${ADD_COUNT:-1}" \
  DOC_REPEAT_COUNT="${DOC_REPEAT_COUNT:-120}" \
  SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-$HOME/.supermemory}" \
  "$SCRIPT_DIR/parallel.sh" __coordinator "$RUN_ROOT" "$jobs" > "$LOG_PATH" 2>&1 < /dev/null &
PID="$!"
printf '%s\n' "$PID" > "$PID_PATH"
write_manifest "$MANIFEST_PATH" "$PID" "$RUN_ROOT" "$jobs"

printf 'Started adaptive parallel low-memory benchmark.\n'
printf 'PID: %s\n' "$PID"
printf 'Workers: %s\n' "$jobs"
printf 'Run root: %s\n' "$RUN_ROOT"
printf 'Log: %s\n' "$LOG_PATH"
printf 'Worker table: %s\n' "$RUN_ROOT/workers.tsv"
printf 'Combined summary when finished: %s\n' "$RUN_ROOT/combined/summary.md"
printf 'Structured manifest: %s\n' "$MANIFEST_PATH"
