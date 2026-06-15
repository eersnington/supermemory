import { readFile, writeFile } from "node:fs/promises"

export type NumericStats = {
	count: number
	avg: number | null
	min: number | null
	max: number | null
	p50: number | null
	p95: number | null
}

export type RunRow = {
	label: string
	iteration: number
	dir: string
	idleSeconds: number
	postSearchIdleSeconds: number
	postAddIdleSeconds: number
	warmAfterReady: string
	envText: string
	readyMs: number | null
	peakMb: number | null
	readyIdleLastMb: number | null
	readyIdleMinMb: number | null
	postSearchLastMb: number | null
	postSearchMinMb: number | null
	postAddLastMb: number | null
	postAddMinMb: number | null
	warmupStatus: string | null
	warmupMs: number | null
	firstStatus: string | null
	firstMs: number | null
	secondStatus: string | null
	secondMs: number | null
	addStatus: string | null
	addMs: number | null
	crashedOnShutdown: boolean
}

export type ScenarioAggregate = {
	label: string
	runs: number
	crashes: number
	warmupSuccesses: number
	firstSearchSuccesses: number
	addSuccesses: number
	metrics: Record<string, NumericStats>
	envText: string
	idleWindows: string
	warmAfterReady: string
}

const CRASH_PATTERN = /panic\(main thread\)|oh no: Bun has crashed/

export function mean(values: number[]): number | null {
	if (values.length === 0) return null
	return values.reduce((sum, value) => sum + value, 0) / values.length
}

export function median(values: number[]): number | null {
	if (values.length === 0) return null
	const sorted = [...values].sort((a, b) => a - b)
	const middle = Math.floor(sorted.length / 2)
	if (sorted.length % 2 === 1) return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) / 2
}

export function percentile(
	values: number[],
	percentileValue: number,
): number | null {
	if (values.length === 0) return null
	if (percentileValue <= 0) return Math.min(...values)
	if (percentileValue >= 100) return Math.max(...values)
	const sorted = [...values].sort((a, b) => a - b)
	const index = Math.ceil((percentileValue / 100) * sorted.length) - 1
	return sorted[Math.max(0, Math.min(index, sorted.length - 1))]
}

export function numericStats(
	values: Array<number | null | undefined>,
): NumericStats {
	const finiteValues = values.filter((value): value is number =>
		Number.isFinite(value),
	)
	return {
		count: finiteValues.length,
		avg: mean(finiteValues),
		min: finiteValues.length ? Math.min(...finiteValues) : null,
		max: finiteValues.length ? Math.max(...finiteValues) : null,
		p50: median(finiteValues),
		p95: percentile(finiteValues, 95),
	}
}

function parseField(source: string, name: string): string | null {
	return new RegExp(`^${name}=(.*)$`, "m").exec(source)?.[1]?.trim() ?? null
}

function parseStatus(source: string): string | null {
	return /status=([^\s]+)/.exec(source)?.[1] ?? null
}

function parseLatency(source: string): number | null {
	const match = /latency_ms=(\d+)/.exec(source)
	return match ? Number(match[1]) : null
}

async function readText(path: string): Promise<string> {
	try {
		return await readFile(path, "utf8")
	} catch {
		return ""
	}
}

function parseTsvRows(source: string): Array<Record<string, string>> {
	const lines = source.trim().split("\n").filter(Boolean)
	if (lines.length === 0) return []
	const headers = lines[0].split("\t")
	return lines.slice(1).map((line) => {
		const values = line.split("\t")
		return Object.fromEntries(
			headers.map((header, index) => [header, values[index] ?? ""]),
		)
	})
}

export async function loadRunRows(runsPath: string): Promise<RunRow[]> {
	const runRecords = parseTsvRows(await readText(runsPath))
	const rows: RunRow[] = []

	for (const record of runRecords) {
		const dir = record.run_dir
		const summaryText = await readText(`${dir}/summary.json`)
		if (!summaryText) continue

		const summary = JSON.parse(summaryText)
		const metadata = await readText(`${dir}/metadata.txt`)
		const serverLog = await readText(`${dir}/server.log`)
		const warmup = await readText(`${dir}/warmup-search.txt`)
		const firstSearch = await readText(`${dir}/search-first.txt`)
		const secondSearch = await readText(`${dir}/search-second.txt`)
		const addDocument = await readText(`${dir}/add-document.txt`)

		rows.push({
			label: record.label,
			iteration: Number(record.iteration || "1"),
			dir,
			idleSeconds: Number(record.idle_seconds),
			postSearchIdleSeconds: Number(record.post_search_idle_seconds),
			postAddIdleSeconds: Number(record.post_add_idle_seconds),
			warmAfterReady: record.warm_after_ready,
			envText: record.env ?? "",
			readyMs: Number(parseField(metadata, "ready_latency_ms")),
			peakMb: summary.peak_rss_mb ?? null,
			readyIdleLastMb: summary.labels?.ready_idle?.last_rss_mb ?? null,
			readyIdleMinMb: summary.labels?.ready_idle?.min_rss_mb ?? null,
			postSearchLastMb: summary.labels?.post_search_idle?.last_rss_mb ?? null,
			postSearchMinMb: summary.labels?.post_search_idle?.min_rss_mb ?? null,
			postAddLastMb: summary.labels?.post_add_idle?.last_rss_mb ?? null,
			postAddMinMb: summary.labels?.post_add_idle?.min_rss_mb ?? null,
			warmupStatus: parseStatus(warmup),
			warmupMs: parseLatency(warmup),
			firstStatus: parseStatus(firstSearch),
			firstMs: parseLatency(firstSearch),
			secondStatus: parseStatus(secondSearch),
			secondMs: parseLatency(secondSearch),
			addStatus: parseStatus(addDocument),
			addMs: parseLatency(addDocument),
			crashedOnShutdown: CRASH_PATTERN.test(serverLog),
		})
	}

	return rows
}

export function aggregateRows(rows: RunRow[]): ScenarioAggregate[] {
	const byLabel = new Map<string, RunRow[]>()
	for (const row of rows) {
		const group = byLabel.get(row.label) ?? []
		group.push(row)
		byLabel.set(row.label, group)
	}

	return [...byLabel].map(([label, group]) => ({
		label,
		runs: group.length,
		crashes: group.filter((row) => row.crashedOnShutdown).length,
		warmupSuccesses: group.filter((row) => row.warmupStatus === "200").length,
		firstSearchSuccesses: group.filter((row) => row.firstStatus === "200")
			.length,
		addSuccesses: group.filter((row) => row.addStatus === "200").length,
		envText: group[0]?.envText ?? "",
		warmAfterReady: group[0]?.warmAfterReady ?? "n/a",
		idleWindows: group[0]
			? `ready ${group[0].idleSeconds}s, post-search ${group[0].postSearchIdleSeconds}s, post-add ${group[0].postAddIdleSeconds}s`
			: "n/a",
		metrics: {
			readyMs: numericStats(group.map((row) => row.readyMs)),
			peakMb: numericStats(group.map((row) => row.peakMb)),
			readyIdleLastMb: numericStats(group.map((row) => row.readyIdleLastMb)),
			readyIdleMinMb: numericStats(group.map((row) => row.readyIdleMinMb)),
			postSearchLastMb: numericStats(group.map((row) => row.postSearchLastMb)),
			postSearchMinMb: numericStats(group.map((row) => row.postSearchMinMb)),
			postAddLastMb: numericStats(group.map((row) => row.postAddLastMb)),
			postAddMinMb: numericStats(group.map((row) => row.postAddMinMb)),
			warmupMs: numericStats(group.map((row) => row.warmupMs)),
			firstMs: numericStats(group.map((row) => row.firstMs)),
			secondMs: numericStats(group.map((row) => row.secondMs)),
			addMs: numericStats(group.map((row) => row.addMs)),
		},
	}))
}

function formatNumber(value: number | null, suffix: string): string {
	return value == null || Number.isNaN(value)
		? "n/a"
		: `${Math.round(value)}${suffix}`
}

function formatStat(stats: NumericStats, suffix: string): string {
	if (stats.count === 0) return "n/a"
	return `${formatNumber(stats.avg, suffix)} / ${formatNumber(stats.p50, suffix)} / ${formatNumber(stats.p95, suffix)}`
}

function formatLastMin(
	last: NumericStats,
	min: NumericStats,
	suffix: string,
): string {
	if (last.count === 0 && min.count === 0) return "n/a"
	return `${formatStat(last, suffix)} ; min ${formatNumber(min.min, suffix)}`
}

function compactEnv(envText: string): string {
	if (!envText.trim()) return "default"
	return envText
		.split(/\s+/)
		.filter(Boolean)
		.map((entry) => entry.replace(/^SUPERMEMORY_/, ""))
		.join("<br>")
}

function formatSingle(value: number | null, suffix: string): string {
	return formatNumber(value, suffix)
}

function renderRunRow(row: RunRow): string {
	return [
		row.label,
		String(row.iteration),
		formatSingle(row.readyMs, " ms"),
		formatSingle(row.peakMb, " MB"),
		`${formatSingle(row.readyIdleLastMb, " MB")} / ${formatSingle(row.readyIdleMinMb, " MB")}`,
		`${formatSingle(row.postSearchLastMb, " MB")} / ${formatSingle(row.postSearchMinMb, " MB")}`,
		`${formatSingle(row.postAddLastMb, " MB")} / ${formatSingle(row.postAddMinMb, " MB")}`,
		row.warmupStatus
			? `${formatSingle(row.warmupMs, " ms")} (${row.warmupStatus})`
			: "n/a",
		`${formatSingle(row.firstMs, " ms")} (${row.firstStatus ?? "n/a"})`,
		`${formatSingle(row.secondMs, " ms")} (${row.secondStatus ?? "n/a"})`,
		row.crashedOnShutdown ? "yes" : "no",
	].join(" | ")
}

export function renderMarkdown(options: {
	runRoot: string
	sampleIntervalSeconds: string
	runCount: string
	rows: RunRow[]
	aggregates: ScenarioAggregate[]
}): string {
	let md = "# Low-Memory Profile Matrix\n\n"
	md += `Run root: \`${options.runRoot}\`\n\n`
	md += `Requested runs per scenario: \`${options.runCount}\`\n\n`
	md += `Sample interval: \`${options.sampleIntervalSeconds}\` seconds\n\n`
	md +=
		"Aggregate cells use `avg / p50 / p95`. RSS idle cells also show the lowest observed min sample across runs.\n\n"

	md += "## Aggregate Summary\n\n"
	md +=
		"| Scenario | Runs | Ready | Peak RSS | Ready Idle Last | Post Search Last | Post Add Last | Warmup | First Search | Second Search | Shutdown Crashes |\n"
	md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
	for (const aggregate of options.aggregates) {
		md += `| ${aggregate.label} | ${aggregate.runs} | ${formatStat(aggregate.metrics.readyMs, " ms")} | ${formatStat(aggregate.metrics.peakMb, " MB")} | ${formatLastMin(aggregate.metrics.readyIdleLastMb, aggregate.metrics.readyIdleMinMb, " MB")} | ${formatLastMin(aggregate.metrics.postSearchLastMb, aggregate.metrics.postSearchMinMb, " MB")} | ${formatLastMin(aggregate.metrics.postAddLastMb, aggregate.metrics.postAddMinMb, " MB")} | ${formatStat(aggregate.metrics.warmupMs, " ms")} | ${formatStat(aggregate.metrics.firstMs, " ms")} | ${formatStat(aggregate.metrics.secondMs, " ms")} | ${aggregate.crashes}/${aggregate.runs} |\n`
	}

	md += "\n## Scenario Settings\n\n"
	md += "| Scenario | Idle Windows | Warm After Ready | Env |\n"
	md += "|---|---|---|---|\n"
	for (const aggregate of options.aggregates) {
		md += `| ${aggregate.label} | ${aggregate.idleWindows} | ${aggregate.warmAfterReady} | ${compactEnv(aggregate.envText)} |\n`
	}

	if (options.rows.length <= 50) {
		md += "\n## Individual Runs\n\n"
		md +=
			"| Scenario | Iteration | Ready | Peak RSS | Ready Idle Last/Min | Post Search Last/Min | Post Add Last/Min | Warmup | First Search | Second Search | Shutdown Crash |\n"
		md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|\n"
		for (const row of options.rows) md += `| ${renderRunRow(row)} |\n`
	} else {
		md += "\n## Individual Runs\n\n"
		md += `Individual run metadata is in \`${options.runRoot}/runs.tsv\`. The markdown table is omitted because this run produced ${options.rows.length} rows.\n`
	}

	md += "\n## Notes\n\n"
	md +=
		"- Repeated runs are sequential, not parallel, to avoid cross-run memory interference.\n"
	md +=
		"- Use `RUN_COUNT=100` for the 100-run average requested for release-quality numbers.\n"
	md +=
		"- A shutdown crash after SIGTERM is recorded separately because it does not invalidate request timings but is still a runtime reliability issue.\n"
	return md
}

export async function writeSummary(
	runsPath: string,
	summaryPath: string,
	runRoot: string,
): Promise<void> {
	const rows = await loadRunRows(runsPath)
	const aggregates = aggregateRows(rows)
	const summary = { rows, aggregates }
	const markdown = renderMarkdown({
		runRoot,
		sampleIntervalSeconds: process.env.SAMPLE_INTERVAL_SECONDS ?? "",
		runCount: process.env.RUN_COUNT ?? "1",
		rows,
		aggregates,
	})
	await writeFile(summaryPath, markdown)
	await writeFile(
		summaryPath.replace(/\.md$/, ".json"),
		`${JSON.stringify(summary, null, 2)}\n`,
	)
	console.log(markdown)
}

if (import.meta.main) {
	const [runsPath, summaryPath, runRoot] = process.argv.slice(2)
	if (!runsPath || !summaryPath || !runRoot) {
		console.error(
			"usage: bun bench-tooling/summary.ts <runs.tsv> <summary.md> <run-root>",
		)
		process.exit(2)
	}
	await writeSummary(runsPath, summaryPath, runRoot)
}
