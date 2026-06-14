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

usage() {
  cat <<'USAGE'
Usage:
  scripts/low-memory-profile-matrix.sh

Runs a focused self-hosted binary memory/latency matrix using scripts/memory-bench.sh.
Outputs are written under .memory-bench/profile-matrix/<timestamp>/.

Environment:
  SOURCE_DATA_DIR              Seed data directory. Defaults to ~/.supermemory.
  SAMPLE_INTERVAL_SECONDS      RSS sample interval. Defaults to 0.25.
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

if [[ ! -x "$REPO_ROOT/scripts/memory-bench.sh" ]]; then
  fail "missing executable benchmark harness at $REPO_ROOT/scripts/memory-bench.sh"
fi

mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
RUN_ROOT="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
BENCH_ROOT="$RUN_ROOT/bench"
RUNS_TSV="$RUN_ROOT/runs.tsv"
SUMMARY_MD="$RUN_ROOT/summary.md"

mkdir -p "$BENCH_ROOT"
printf 'label\trun_dir\tidle_seconds\tpost_search_idle_seconds\tpost_add_idle_seconds\twarm_after_ready\tenv\n' > "$RUNS_TSV"

run_case() {
  local label="$1"
  local idle_seconds="$2"
  local post_search_idle_seconds="$3"
  local post_add_idle_seconds="$4"
  local warm_after_ready="$5"
  shift 5

  printf 'Running %-24s idle=%ss post_search=%ss post_add=%ss warm=%s\n' \
    "$label" "$idle_seconds" "$post_search_idle_seconds" "$post_add_idle_seconds" "$warm_after_ready"

  local output run_dir env_text
  env_text="$*"
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
    "$REPO_ROOT/scripts/memory-bench.sh" scenario "$label" "$@"
  )"
  run_dir="$(printf '%s\n' "$output" | tail -n 1)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$run_dir" "$idle_seconds" "$post_search_idle_seconds" "$post_add_idle_seconds" "$warm_after_ready" "$env_text" >> "$RUNS_TSV"
}

LOWMEM_15_ENV=(
  SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1
  SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=15000
  SUPERMEMORY_INGEST_CONCURRENCY=1
  SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2
  SUPERMEMORY_EMBEDDING_RAM_LIMIT=512mb
)

LOWMEM_30_ENV=(
  SUPERMEMORY_SKIP_EMBEDDING_PREWARM=1
  SUPERMEMORY_LOCAL_EMBEDDING_IDLE_TIMEOUT_MS=30000
  SUPERMEMORY_INGEST_CONCURRENCY=1
  SUPERMEMORY_LOCAL_EMBEDDING_BATCH_SIZE=2
  SUPERMEMORY_EMBEDDING_RAM_LIMIT=512mb
)

run_case baseline-default 12 30 30 0
run_case cold-15s 12 30 30 0 "${LOWMEM_15_ENV[@]}"
run_case balanced-15s-quick 8 30 30 1 "${LOWMEM_15_ENV[@]}"
run_case balanced-15s-late 25 30 30 1 "${LOWMEM_15_ENV[@]}"
run_case balanced-30s-quick 20 40 40 1 "${LOWMEM_30_ENV[@]}"

SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" bun -e '
const [runsPath, summaryPath, runRoot] = process.argv.slice(1);

async function text(path) {
  try { return await Bun.file(path).text(); } catch { return ""; }
}

function field(source, name) {
  return new RegExp(`^${name}=(.*)$`, "m").exec(source)?.[1]?.trim() ?? null;
}

function status(source) {
  return /status=([^\s]+)/.exec(source)?.[1] ?? null;
}

function latency(source) {
  const match = /latency_ms=(\d+)/.exec(source);
  return match ? Number(match[1]) : null;
}

function mb(value) {
  return value == null || Number.isNaN(value) ? "n/a" : `${Math.round(value)} MB`;
}

function ms(value) {
  return value == null || Number.isNaN(value) ? "n/a" : `${Math.round(value)} ms`;
}

function compactEnv(envText) {
  if (!envText.trim()) return "default";
  return envText
    .split(/\s+/)
    .filter(Boolean)
    .map((entry) => entry.replace(/^SUPERMEMORY_/, ""))
    .join("<br>");
}

const lines = (await text(runsPath)).trim().split("\n").slice(1).filter(Boolean);
const rows = [];
for (const line of lines) {
  const [label, dir, idleSeconds, postSearchIdleSeconds, postAddIdleSeconds, warmAfterReady, envText = ""] = line.split("\t");
  const summary = await Bun.file(`${dir}/summary.json`).json();
  const metadata = await text(`${dir}/metadata.txt`);
  const serverLog = await text(`${dir}/server.log`);
  const warmup = await text(`${dir}/warmup-search.txt`);
  const firstSearch = await text(`${dir}/search-first.txt`);
  const secondSearch = await text(`${dir}/search-second.txt`);
  const addDocument = await text(`${dir}/add-document.txt`);
  rows.push({
    label,
    dir,
    idleSeconds: Number(idleSeconds),
    postSearchIdleSeconds: Number(postSearchIdleSeconds),
    postAddIdleSeconds: Number(postAddIdleSeconds),
    warmAfterReady,
    envText,
    readyMs: Number(field(metadata, "ready_latency_ms")),
    peakMb: summary.peak_rss_mb ?? null,
    readyIdleLastMb: summary.labels?.ready_idle?.last_rss_mb ?? null,
    readyIdleMinMb: summary.labels?.ready_idle?.min_rss_mb ?? null,
    postSearchLastMb: summary.labels?.post_search_idle?.last_rss_mb ?? null,
    postSearchMinMb: summary.labels?.post_search_idle?.min_rss_mb ?? null,
    postAddLastMb: summary.labels?.post_add_idle?.last_rss_mb ?? null,
    postAddMinMb: summary.labels?.post_add_idle?.min_rss_mb ?? null,
    warmupStatus: status(warmup),
    warmupMs: latency(warmup),
    firstStatus: status(firstSearch),
    firstMs: latency(firstSearch),
    secondStatus: status(secondSearch),
    secondMs: latency(secondSearch),
    addStatus: status(addDocument),
    addMs: latency(addDocument),
    crashedOnShutdown: /panic\(main thread\)|oh no: Bun has crashed/.test(serverLog),
  });
}

const headers = [
  "Scenario",
  "Ready",
  "Peak RSS",
  "Ready Idle Last/Min",
  "Post Search Last/Min",
  "Post Add Last/Min",
  "Warmup",
  "First Search",
  "Second Search",
  "Shutdown Crash",
];

function rowToMarkdown(row) {
  return [
    row.label,
    ms(row.readyMs),
    mb(row.peakMb),
    `${mb(row.readyIdleLastMb)} / ${mb(row.readyIdleMinMb)}`,
    `${mb(row.postSearchLastMb)} / ${mb(row.postSearchMinMb)}`,
    `${mb(row.postAddLastMb)} / ${mb(row.postAddMinMb)}`,
    row.warmupStatus ? `${ms(row.warmupMs)} (${row.warmupStatus})` : "n/a",
    `${ms(row.firstMs)} (${row.firstStatus ?? "n/a"})`,
    `${ms(row.secondMs)} (${row.secondStatus ?? "n/a"})`,
    row.crashedOnShutdown ? "yes" : "no",
  ];
}

let md = "# Low-Memory Profile Matrix\n\n";
md += `Run root: \`${runRoot}\`\n\n`;
md += `Sample interval: \`${process.env.SAMPLE_INTERVAL_SECONDS ?? ""}\` seconds\n\n`;
md += `RSS cells with \`Last/Min\` show whether memory dropped during the idle window.\n\n`;
md += `| ${headers.join(" | ")} |\n`;
md += `| ${headers.map(() => "---").join(" | ")} |\n`;
for (const row of rows) md += `| ${rowToMarkdown(row).join(" | ")} |\n`;

md += "\n## Scenario Settings\n\n";
md += "| Scenario | Idle Windows | Warm After Ready | Env | Run Dir |\n";
md += "|---|---:|---:|---|---|\n";
for (const row of rows) {
  md += `| ${row.label} | ready ${row.idleSeconds}s, post-search ${row.postSearchIdleSeconds}s, post-add ${row.postAddIdleSeconds}s | ${row.warmAfterReady} | ${compactEnv(row.envText)} | \`${row.dir}\` |\n`;
}

md += "\n## Notes\n\n";
md += "- Balanced quick scenarios test whether the first real search stays fast when it arrives before the embedding idle timeout.\n";
md += "- Balanced late scenarios test whether memory can drop before the first real search, and whether that makes the first real search cold again.\n";
md += "- A shutdown crash after SIGTERM is recorded separately because it does not invalidate request timings but is still a runtime reliability issue.\n";

await Bun.write(summaryPath, md);
console.log(md);
' "$RUNS_TSV" "$SUMMARY_MD" "$RUN_ROOT"

printf 'Summary written to %s\n' "$SUMMARY_MD"
