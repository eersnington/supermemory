import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises"
import { basename, join, resolve } from "node:path"
import {
	aggregateRows,
	loadRunRows,
	renderMarkdown,
	type RunRow,
} from "./summary"

const RUNS_HEADER =
	"label\titeration\trun_dir\tidle_seconds\tpost_search_idle_seconds\tpost_add_idle_seconds\twarm_after_ready\tenv"

type SourceRuns = {
	input: string
	runsPath: string
	rowCount: number
}

async function exists(path: string): Promise<boolean> {
	try {
		await stat(path)
		return true
	} catch {
		return false
	}
}

async function discoverRunsFiles(input: string): Promise<string[]> {
	const inputPath = resolve(input)
	if (!(await exists(inputPath))) {
		throw new Error(`Input does not exist: ${input}`)
	}

	const inputStat = await stat(inputPath)
	if (!inputStat.isDirectory()) {
		if (basename(inputPath) !== "runs.tsv") {
			throw new Error(
				`Expected a matrix run directory or runs.tsv file, got: ${input}`,
			)
		}
		return [inputPath]
	}

	const directRunsPath = join(inputPath, "runs.tsv")
	if (await exists(directRunsPath)) return [directRunsPath]

	const entries = await readdir(inputPath, { withFileTypes: true })
	const childRunsPaths: string[] = []
	for (const entry of entries) {
		if (!entry.isDirectory()) continue
		const childRunsPath = join(inputPath, entry.name, "runs.tsv")
		if (await exists(childRunsPath)) childRunsPaths.push(childRunsPath)
	}

	if (childRunsPaths.length === 0) {
		throw new Error(`No runs.tsv files found in: ${input}`)
	}

	return childRunsPaths.sort()
}

function rowsFromRunsTsv(source: string): string[] {
	const lines = source.trim().split(/\r?\n/).filter(Boolean)
	if (lines.length === 0) return []
	if (lines[0] !== RUNS_HEADER) {
		throw new Error(`Unexpected runs.tsv header: ${lines[0]}`)
	}
	return lines.slice(1)
}

function sourceMarkdown(sources: SourceRuns[]): string {
	let md = "\n## Source Chunks\n\n"
	md += "| Runs TSV | Rows |\n"
	md += "|---|---:|\n"
	for (const source of sources) {
		md += `| \`${source.runsPath}\` | ${source.rowCount} |\n`
	}
	return md
}

export async function collectLowMemoryRuns(options: {
	outputDir: string
	inputs: string[]
}): Promise<{
	outputDir: string
	sources: SourceRuns[]
	rows: Awaited<ReturnType<typeof loadRunRows>>
	aggregates: ReturnType<typeof aggregateRows>
}> {
	if (options.inputs.length === 0) {
		throw new Error(
			"At least one matrix run directory or runs.tsv file is required",
		)
	}

	const outputDir = resolve(options.outputDir)
	await mkdir(outputDir, { recursive: true })

	const discovered = await Promise.all(options.inputs.map(discoverRunsFiles))
	const runsPaths = [...new Set(discovered.flat())].sort()

	const sources: SourceRuns[] = []
	const combinedRows: string[] = []
	const rows: RunRow[] = []
	for (const runsPath of runsPaths) {
		const source = await readFile(runsPath, "utf8")
		const tsvRows = rowsFromRunsTsv(source)
		combinedRows.push(...tsvRows)
		const loadedRows = await loadRunRows(runsPath)
		rows.push(...loadedRows)
		sources.push({ input: runsPath, runsPath, rowCount: tsvRows.length })
	}

	const aggregates = aggregateRows(rows)
	const combinedRunsPath = join(outputDir, "runs.tsv")
	const summaryPath = join(outputDir, "summary.md")
	const summaryJsonPath = join(outputDir, "summary.json")

	await writeFile(
		combinedRunsPath,
		`${RUNS_HEADER}\n${combinedRows.join("\n")}\n`,
	)

	const markdown = `${renderMarkdown({
		runRoot: outputDir,
		sampleIntervalSeconds:
			process.env.SAMPLE_INTERVAL_SECONDS ?? "mixed/see source chunks",
		runCount: "combined chunks",
		rows,
		aggregates,
	})}${sourceMarkdown(sources)}`

	await writeFile(summaryPath, markdown)
	await writeFile(
		summaryJsonPath,
		`${JSON.stringify(
			{
				generatedAt: new Date().toISOString(),
				outputDir,
				combinedRunsPath,
				sources,
				rows,
				aggregates,
			},
			null,
			2,
		)}\n`,
	)

	return { outputDir, sources, rows, aggregates }
}

if (import.meta.main) {
	const [outputDir, ...inputs] = process.argv.slice(2)
	if (!outputDir || inputs.length === 0) {
		console.error(
			"usage: bun bench-tooling/collect.ts <output-dir> <matrix-run-dir-or-runs.tsv> [...]",
		)
		process.exit(2)
	}

	try {
		const result = await collectLowMemoryRuns({ outputDir, inputs })
		console.log(
			`Collected ${result.rows.length} runs from ${result.sources.length} source chunk(s).`,
		)
		console.log(`Summary written to ${join(resolve(outputDir), "summary.md")}`)
	} catch (error) {
		console.error(error instanceof Error ? error.message : String(error))
		process.exit(1)
	}
}
