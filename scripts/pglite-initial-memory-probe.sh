#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/.memory-bench/pglite-initial-memory}"
PGLITE_VERSION="${PGLITE_VERSION:-0.5.2}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-0.1}"
ROWS="${ROWS:-3000}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-2048}"
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-5}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/pglite-initial-memory-probe.sh

Installs @electric-sql/pglite in an isolated .memory-bench workspace and tests
PGlite initialMemory/postgresql.conf variants under the same Bun runtime.

Environment:
  PGLITE_VERSION              Defaults to 0.5.2.
  ROWS                        Rows inserted per probe. Defaults to 3000.
  PAYLOAD_BYTES               Text payload bytes per row. Defaults to 2048.
  SAMPLE_INTERVAL_SECONDS     RSS sample interval. Defaults to 0.1.
  PROBE_TIMEOUT_SECONDS       Per-case timeout. Defaults to 5.
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

if ! command -v bun >/dev/null 2>&1; then
  fail "bun is required"
fi

mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
RUN_ROOT="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
WORK_DIR="$RUN_ROOT/work"
mkdir -p "$WORK_DIR"

cat > "$WORK_DIR/package.json" <<EOF
{"type":"module","dependencies":{"@electric-sql/pglite":"$PGLITE_VERSION"}}
EOF

printf 'Installing @electric-sql/pglite@%s in %s\n' "$PGLITE_VERSION" "$WORK_DIR"
bun install --cwd "$WORK_DIR"

cat > "$WORK_DIR/probe.ts" <<'TS'
import { PGlite } from "@electric-sql/pglite";

const startedAt = performance.now();
const label = process.env.PROBE_LABEL ?? "probe";
const initialMemoryMb = Number(process.env.PGLITE_INITIAL_MEMORY_MB ?? "0");
const configName = process.env.PGLITE_CONFIG ?? "default";
const rows = Number(process.env.ROWS ?? "3000");
const payloadBytes = Number(process.env.PAYLOAD_BYTES ?? "2048");
const dataDir = process.env.PGLITE_DATA_DIR;

const options: ConstructorParameters<typeof PGlite>[0] = {
  dataDir,
};

if (initialMemoryMb > 0) {
  options.initialMemory = initialMemoryMb * 1024 * 1024;
}

if (configName === "lowconf") {
  options.postgresqlconf = [
    "shared_buffers=1MB",
    "work_mem=1MB",
    "maintenance_work_mem=16MB",
    "temp_buffers=1MB",
  ];
}

const db = new PGlite(options);
await db.waitReady;
const readyAt = performance.now();

await db.exec("CREATE TABLE IF NOT EXISTS docs (id serial primary key, content text not null, created_at timestamptz default now())");
await db.exec("TRUNCATE docs");
await db.query("INSERT INTO docs (content) SELECT repeat('memory-pressure-payload-', $1) FROM generate_series(1, $2)", [
  Math.max(1, Math.ceil(payloadBytes / "memory-pressure-payload-".length)),
  rows,
]);
const insertAt = performance.now();

await db.exec("CREATE INDEX docs_content_len_idx ON docs ((length(content)))");
const indexAt = performance.now();

const count = await db.query<{ count: string; total_bytes: string }>(
  "SELECT count(*)::text as count, sum(length(content))::text as total_bytes FROM docs WHERE content LIKE '%payload%'",
);
await db.query("SELECT id, length(content) FROM docs ORDER BY length(content) DESC, id LIMIT 25");
const queryAt = performance.now();

await db.close();
const closedAt = performance.now();

console.log(JSON.stringify({
  label,
  bunVersion: Bun.version,
  pgliteVersion: process.env.PGLITE_VERSION,
  initialMemoryMb: initialMemoryMb || "default",
  configName,
  rows,
  payloadBytes,
  readyMs: Math.round(readyAt - startedAt),
  insertMs: Math.round(insertAt - readyAt),
  indexMs: Math.round(indexAt - insertAt),
  queryMs: Math.round(queryAt - indexAt),
  closeMs: Math.round(closedAt - queryAt),
  totalMs: Math.round(closedAt - startedAt),
  count: count.rows[0],
}));
TS

rss_kb() {
  ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

run_probe() {
  local label="$1"
  local initial_memory_mb="$2"
  local config_name="$3"
  local data_dir="$RUN_ROOT/data/$label"
  local log_file="$RUN_ROOT/$label.log"
  local samples_file="$RUN_ROOT/$label-samples.csv"
  local started_at ended_at pid sampler_pid exit_code current_rss_kb deadline stat_line rss_summary peak_rss_kb last_rss_kb

  mkdir -p "$data_dir"
  printf 'epoch_ms,rss_kb\n' > "$samples_file"
  printf 'Running %-18s initialMemory=%s config=%s\n' "$label" "$initial_memory_mb" "$config_name"

  started_at="$(now_ms)"
  (
    cd "$WORK_DIR"
    exec env \
    PROBE_LABEL="$label" \
    PGLITE_VERSION="$PGLITE_VERSION" \
    PGLITE_INITIAL_MEMORY_MB="$initial_memory_mb" \
    PGLITE_CONFIG="$config_name" \
    PGLITE_DATA_DIR="$data_dir" \
    ROWS="$ROWS" \
    PAYLOAD_BYTES="$PAYLOAD_BYTES" \
    bun probe.ts
  ) > "$log_file" 2>&1 &
  pid="$!"

  while kill -0 "$pid" 2>/dev/null; do
    current_rss_kb="$(rss_kb "$pid")"
    if [[ -n "$current_rss_kb" ]]; then
      printf '%s,%s\n' "$(now_ms)" "$current_rss_kb" >> "$samples_file"
    fi
    sleep "$SAMPLE_INTERVAL_SECONDS"
  done &
  sampler_pid="$!"

  deadline=$((SECONDS + PROBE_TIMEOUT_SECONDS))
  exit_code=""
  while kill -0 "$pid" 2>/dev/null; do
    stat_line="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$stat_line" == Z* ]]; then
      break
    fi
    if (( SECONDS >= deadline )); then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
      exit_code=124
      break
    fi
    sleep 0.1
  done

  if [[ -z "$exit_code" ]]; then
    if wait "$pid"; then
      exit_code=0
    else
      exit_code="$?"
    fi
  else
    wait "$pid" 2>/dev/null || true
  fi
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  ended_at="$(now_ms)"

  rss_summary="$(bun -e '
const rows = (await Bun.file(process.argv[1]).text()).trim().split("\n").slice(1).filter(Boolean).map((line) => Number(line.split(",")[1])).filter(Number.isFinite);
const peak = rows.length ? Math.max(...rows) : 0;
const last = rows.length ? rows.at(-1) : 0;
console.log(`${peak} ${last}`);
' "$samples_file")"
  peak_rss_kb="${rss_summary%% *}"
  last_rss_kb="${rss_summary##* }"

  printf '{"label":"%s","initialMemoryMb":"%s","config":"%s","exitCode":%s,"elapsedMs":%s,"peakRssMb":%s,"lastRssMb":%s,"log":"%s","samples":"%s"}\n' \
    "$label" \
    "$initial_memory_mb" \
    "$config_name" \
    "$exit_code" \
    "$((ended_at - started_at))" \
    "$(( (peak_rss_kb + 512) / 1024 ))" \
    "$(( (last_rss_kb + 512) / 1024 ))" \
    "$log_file" \
    "$samples_file" >> "$RUN_ROOT/results.jsonl"
}

: > "$RUN_ROOT/results.jsonl"
run_probe default default default
run_probe mem32 32 default
run_probe mem48 48 default
run_probe mem64 64 default
run_probe mem96 96 default
run_probe mem128 128 default
run_probe mem128-lowconf 128 lowconf
run_probe mem64-lowconf 64 lowconf

bun -e '
const [runRoot] = process.argv.slice(1);
const resultsText = await Bun.file(`${runRoot}/results.jsonl`).text();
const results = resultsText.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));

async function text(path) { try { return await Bun.file(path).text(); } catch { return ""; } }
function ms(value) { return value == null ? "n/a" : `${Math.round(value)} ms`; }
function mb(value) { return value == null ? "n/a" : `${Math.round(value)} MB`; }

const rows = [];
for (const result of results) {
  const log = await text(result.log);
  let probe = null;
  try { probe = JSON.parse(log.trim().split("\n").at(-1)); } catch {}
  rows.push({ ...result, probe, logText: log });
}

let md = "# PGlite Initial Memory Probe\n\n";
md += `Run root: \`${runRoot}\`\n\n`;
md += "| Scenario | Exit | Peak RSS | Elapsed | Ready | Insert | Index | Query | Close | Probe Output |\n";
md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|\n";
for (const row of rows) {
  const probe = row.probe;
  md += `| ${row.label} | ${row.exitCode} | ${mb(row.peakRssMb)} | ${ms(row.elapsedMs)} | ${ms(probe?.readyMs)} | ${ms(probe?.insertMs)} | ${ms(probe?.indexMs)} | ${ms(probe?.queryMs)} | ${ms(probe?.closeMs)} | ${probe ? `initial=${probe.initialMemoryMb}, config=${probe.configName}, rows=${probe.rows}` : row.logText.replace(/\n/g, "<br>")} |\n`;
}
md += "\n## Notes\n\n";
md += "- This probe tests PGlite itself, not the proprietary self-hosted server path.\n";
md += "- It exercises persistent filesystem storage, table insert, expression index creation, and read query. It does not include pgvector or the encrypted snapshot layer.\n";

await Bun.write(`${runRoot}/summary.md`, md);
console.log(md);
' "$RUN_ROOT"

printf 'Summary written to %s/summary.md\n' "$RUN_ROOT"
