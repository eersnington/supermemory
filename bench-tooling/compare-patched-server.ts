#!/usr/bin/env bun
import { spawn, spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { access, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { constants } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { homedir } from "node:os"

type RunCase = "stock" | "patched"

type CaseResult = {
	caseName: RunCase
	iteration: number
	runDir: string
	readyMs: number
	firstSearchMs: number
	firstSearchStatus: number
	peakRssMb: number | null
	postSearchIdleRssMb: number | null
	log: string
}

type Aggregate = {
	readyP50: number
	firstSearchP50: number
	peakRssP50: number | null
	postSearchIdleRssP50: number | null
}

type SerializableCaseResult = Omit<CaseResult, "log">

const defaultInstalledBin = join(
	homedir(),
	".supermemory",
	"bin",
	"supermemory-server",
)
const defaultStockBackup = join(
	homedir(),
	".supermemory",
	"bin",
	"supermemory-server.stock-5a5932a9.bak",
)
const patcherPath = resolve("bench-tooling/patch-server-binary.ts")

const runCount = positiveIntEnv("RUN_COUNT", 5)
const readySettleMs = nonNegativeIntEnv("READY_SETTLE_MS", 2000)
const readyTimeoutMs = positiveIntEnv("READY_TIMEOUT_MS", 45_000)
const sampleIntervalMs = positiveIntEnv("SAMPLE_INTERVAL_MS", 250)
const postSearchIdleMs = nonNegativeIntEnv("POST_SEARCH_IDLE_MS", 0)
const expectIdleRssWinMb = nonNegativeIntEnv("EXPECT_IDLE_RSS_WIN_MB", 0)
const expectPatchedIdleShutdown = boolEnv("EXPECT_PATCHED_IDLE_SHUTDOWN", false)
const sourceDataDir = resolvePath(
	process.env.SOURCE_DATA_DIR ?? join(homedir(), ".supermemory"),
)
const outRoot = resolvePath(
	process.env.OUT_ROOT ?? join(".memory-bench", "patch-compare"),
)

function usage(): string {
	return `Usage:
  bun bench-tooling/compare-patched-server.ts

Environment:
  STOCK_SERVER_BIN       Stock server binary. Defaults to the stock backup if present.
  SOURCE_DATA_DIR        Seed data directory. Defaults to ~/.supermemory.
  RUN_COUNT              Paired stock/patched iterations. Defaults to 5.
  READY_SETTLE_MS        Wait after HTTP ready before first search. Defaults to 2000.
  POST_SEARCH_IDLE_MS    Wait after first search before recording idle RSS. Defaults to 0.
  EXPECT_IDLE_RSS_WIN_MB Require patched post-search idle RSS p50 to beat stock by this many MB.
  EXPECT_PATCHED_IDLE_SHUTDOWN
                          Require patched logs to show embedding worker idle shutdown.
  OUT_ROOT               Output root. Defaults to .memory-bench/patch-compare.
`
}

function positiveIntEnv(name: string, fallback: number): number {
	const raw = process.env[name]
	if (!raw) return fallback
	const parsed = Number(raw)
	if (!Number.isInteger(parsed) || parsed <= 0) {
		throw new Error(`${name} must be a positive integer`)
	}
	return parsed
}

function nonNegativeIntEnv(name: string, fallback: number): number {
	const raw = process.env[name]
	if (!raw) return fallback
	const parsed = Number(raw)
	if (!Number.isInteger(parsed) || parsed < 0) {
		throw new Error(`${name} must be a non-negative integer`)
	}
	return parsed
}

function boolEnv(name: string, fallback: boolean): boolean {
	const raw = process.env[name]
	if (!raw) return fallback
	if (["1", "true", "yes"].includes(raw.toLowerCase())) return true
	if (["0", "false", "no"].includes(raw.toLowerCase())) return false
	throw new Error(`${name} must be true or false`)
}

function resolvePath(path: string): string {
	if (path === "~") return homedir()
	if (path.startsWith("~/")) return join(homedir(), path.slice(2))
	return resolve(path)
}

async function exists(path: string): Promise<boolean> {
	try {
		await access(path, constants.F_OK)
		return true
	} catch {
		return false
	}
}

function nowMs(): number {
	return Date.now()
}

function sha256(buffer: Buffer): string {
	return createHash("sha256").update(buffer).digest("hex")
}

function runCommand(command: string, args: string[]): string {
	const result = spawnSync(command, args, { encoding: "utf8" })
	if (result.status !== 0) {
		throw new Error(
			`command failed: ${command} ${args.join(" ")}\n${result.stderr || result.stdout}`,
		)
	}
	return result.stdout
}

async function readText(path: string): Promise<string> {
	try {
		return await readFile(path, "utf8")
	} catch {
		return ""
	}
}

async function resolveStockBinary(): Promise<string> {
	if (process.env.STOCK_SERVER_BIN)
		return resolvePath(process.env.STOCK_SERVER_BIN)
	if (await exists(defaultStockBackup)) return defaultStockBackup
	return defaultInstalledBin
}

function checkBinaryState(path: string): {
	state: string
	patchLabel: boolean
} {
	const output = runCommand("bun", [patcherPath, "check", path, "--json"])
	const parsed = JSON.parse(output)
	return { state: parsed.state, patchLabel: parsed.patchLabel }
}

function createPatchedBinary(stockBin: string, patchedBin: string): void {
	runCommand("bun", [patcherPath, "patch", stockBin, patchedBin, "--force"])
	runCommand(patchedBin, ["--version"])
	runCommand(patchedBin, ["--version"])
}

function randomPort(): number {
	return 19_000 + Math.floor(Math.random() * 20_000)
}

function childPids(pid: number): number[] {
	const result = spawnSync("pgrep", ["-P", String(pid)], { encoding: "utf8" })
	if (result.status !== 0) return []
	return result.stdout
		.trim()
		.split(/\s+/)
		.map((value) => Number(value))
		.filter((value) => Number.isInteger(value) && value > 0)
}

function processTreePids(rootPid: number): number[] {
	const seen = new Set<number>()
	const pending = [rootPid]
	while (pending.length > 0) {
		const pid = pending.pop()
		if (!pid || seen.has(pid)) continue
		seen.add(pid)
		pending.push(...childPids(pid))
	}
	return [...seen]
}

function pidRssKb(pid: number): number | null {
	const result = spawnSync("ps", ["-o", "rss=", "-p", String(pid)], {
		encoding: "utf8",
	})
	if (result.status !== 0) return null
	const kb = Number(result.stdout.trim())
	if (!Number.isFinite(kb) || kb <= 0) return null
	return kb
}

function rssMb(pid: number): number | null {
	let totalKb = 0
	for (const treePid of processTreePids(pid)) {
		const kb = pidRssKb(treePid)
		if (kb != null) totalKb += kb
	}
	return totalKb > 0 ? Math.round(totalKb / 1024) : null
}

async function waitForReady(port: number, processPid: number): Promise<number> {
	const start = nowMs()
	while (nowMs() - start < readyTimeoutMs) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/`)
			await response.text()
			if (response.ok) return nowMs() - start
		} catch {
			// Keep polling while the process is starting.
		}

		try {
			process.kill(processPid, 0)
		} catch {
			throw new Error(`server exited before HTTP ready on port ${port}`)
		}

		await Bun.sleep(100)
	}

	throw new Error(`server did not become ready within ${readyTimeoutMs}ms`)
}

async function readApiKey(dataDir: string): Promise<string | null> {
	const text = await readText(join(dataDir, "api-key"))
	return text.trim() || null
}

async function searchOnce(
	port: number,
	apiKey: string | null,
): Promise<{
	status: number
	latencyMs: number
}> {
	const start = nowMs()
	const headers: Record<string, string> = { "content-type": "application/json" }
	if (apiKey) headers.authorization = `Bearer ${apiKey}`

	const response = await fetch(`http://127.0.0.1:${port}/v3/search`, {
		method: "POST",
		headers,
		body: JSON.stringify({
			q: "patch comparison search",
			containerTag: "patch_compare",
		}),
	})
	await response.text()
	return { status: response.status, latencyMs: nowMs() - start }
}

async function prepareDataDir(dataDir: string): Promise<void> {
	await rm(dataDir, { recursive: true, force: true })
	if (await exists(sourceDataDir)) {
		await cp(sourceDataDir, dataDir, { recursive: true })
		return
	}
	await mkdir(dataDir, { recursive: true })
}

async function runCase(options: {
	caseName: RunCase
	iteration: number
	binary: string
	runRoot: string
}): Promise<CaseResult> {
	const runDir = join(
		options.runRoot,
		`${String(options.iteration).padStart(2, "0")}-${options.caseName}`,
	)
	const dataDir = join(runDir, "data")
	const logPath = join(runDir, "server.log")
	const metadataPath = join(runDir, "metadata.json")
	const port = randomPort()

	await mkdir(runDir, { recursive: true })
	await prepareDataDir(dataDir)

	const logFile = Bun.file(logPath)
	const writer = logFile.writer()
	let peakRssMb: number | null = null

	const child = spawn(options.binary, [], {
		stdio: ["ignore", "pipe", "pipe"],
		env: {
			...process.env,
			PORT: String(port),
			SUPERMEMORY_PORT: String(port),
			SUPERMEMORY_DATA_DIR: dataDir,
			SUPERMEMORY_VERBOSE: process.env.SUPERMEMORY_VERBOSE ?? "1",
			SUPERMEMORY_NO_OPEN: "1",
			SUPERMEMORY_NO_UPDATE_CHECK: "1",
		},
	})

	child.stdout.on("data", (chunk) => writer.write(chunk))
	child.stderr.on("data", (chunk) => writer.write(chunk))

	const sampler = setInterval(() => {
		if (!child.pid) return
		const sample = rssMb(child.pid)
		if (sample == null) return
		peakRssMb = Math.max(peakRssMb ?? 0, sample)
	}, sampleIntervalMs)

	try {
		if (!child.pid) throw new Error("server process did not expose a pid")
		const readyMs = await waitForReady(port, child.pid)
		await Bun.sleep(readySettleMs)
		const apiKey = await readApiKey(dataDir)
		const firstSearch = await searchOnce(port, apiKey)
		let postSearchIdleRssMb: number | null = null
		if (postSearchIdleMs > 0) {
			await Bun.sleep(postSearchIdleMs)
			postSearchIdleRssMb = child.pid ? rssMb(child.pid) : null
		}

		child.kill("SIGTERM")
		await new Promise((resolve) => child.once("close", resolve))
		clearInterval(sampler)
		await writer.end()

		const log = await readText(logPath)
		const result: CaseResult = {
			caseName: options.caseName,
			iteration: options.iteration,
			runDir,
			readyMs,
			firstSearchMs: firstSearch.latencyMs,
			firstSearchStatus: firstSearch.status,
			peakRssMb,
			postSearchIdleRssMb,
			log,
		}
		await writeFile(
			metadataPath,
			`${JSON.stringify(withoutLog(result), null, 2)}\n`,
		)
		return result
	} catch (error) {
		child.kill("SIGTERM")
		await new Promise((resolve) => child.once("close", resolve)).catch(() => {})
		clearInterval(sampler)
		await writer.end()
		throw error
	}
}

function p50(values: number[]): number {
	if (values.length === 0) throw new Error("cannot calculate p50 of empty list")
	const sorted = [...values].sort((a, b) => a - b)
	const middle = Math.floor(sorted.length / 2)
	if (sorted.length % 2 === 1) return sorted[middle]
	return Math.round((sorted[middle - 1] + sorted[middle]) / 2)
}

function aggregate(results: CaseResult[]): Aggregate {
	const rssValues = results
		.map((result) => result.peakRssMb)
		.filter((value): value is number => value != null)
	const postSearchIdleRssValues = results
		.map((result) => result.postSearchIdleRssMb)
		.filter((value): value is number => value != null)
	return {
		readyP50: p50(results.map((result) => result.readyMs)),
		firstSearchP50: p50(results.map((result) => result.firstSearchMs)),
		peakRssP50: rssValues.length ? p50(rssValues) : null,
		postSearchIdleRssP50: postSearchIdleRssValues.length
			? p50(postSearchIdleRssValues)
			: null,
	}
}

function withoutLog(result: CaseResult): SerializableCaseResult {
	const { log: _log, ...rest } = result
	return rest
}

function countOccurrences(text: string, needle: string): number {
	let count = 0
	let index = 0
	while (true) {
		const next = text.indexOf(needle, index)
		if (next === -1) return count
		count += 1
		index = next + needle.length
	}
}

function assertLogOrder(log: string, needles: string[], label: string): void {
	let cursor = -1
	for (const needle of needles) {
		const next = log.indexOf(needle, cursor + 1)
		if (next === -1) {
			throw new Error(`${label} log is missing expected marker: ${needle}`)
		}
		if (next <= cursor) {
			throw new Error(`${label} log markers are out of order at: ${needle}`)
		}
		cursor = next
	}
}

function assertLogContains(log: string, needle: string, label: string): void {
	if (!log.includes(needle)) throw new Error(`${label} log missing: ${needle}`)
}

function validateResults(
	stock: CaseResult[],
	patched: CaseResult[],
): {
	stockAggregate: Aggregate
	patchedAggregate: Aggregate
} {
	const stockAggregate = aggregate(stock)
	const patchedAggregate = aggregate(patched)

	if (
		patchedAggregate.readyP50 > stockAggregate.readyP50 - 500 &&
		patchedAggregate.readyP50 > stockAggregate.readyP50 * 0.75
	) {
		throw new Error(
			`patched ready p50 did not beat stock enough: stock=${stockAggregate.readyP50}ms patched=${patchedAggregate.readyP50}ms`,
		)
	}

	if (patchedAggregate.firstSearchP50 > stockAggregate.firstSearchP50 + 250) {
		throw new Error(
			`patched first-search p50 regressed too much: stock=${stockAggregate.firstSearchP50}ms patched=${patchedAggregate.firstSearchP50}ms`,
		)
	}

	if (expectIdleRssWinMb > 0) {
		if (
			stockAggregate.postSearchIdleRssP50 == null ||
			patchedAggregate.postSearchIdleRssP50 == null
		) {
			throw new Error(
				"cannot assert idle RSS win without post-search idle RSS samples",
			)
		}
		const idleRssWinMb =
			stockAggregate.postSearchIdleRssP50 -
			patchedAggregate.postSearchIdleRssP50
		if (idleRssWinMb < expectIdleRssWinMb) {
			throw new Error(
				`patched post-search idle RSS p50 did not beat stock by ${expectIdleRssWinMb}MB: stock=${stockAggregate.postSearchIdleRssP50}MB patched=${patchedAggregate.postSearchIdleRssP50}MB`,
			)
		}
	}

	for (const result of patched) {
		assertLogOrder(
			result.log,
			[
				"supermemory ready",
				"[patch] background embedding warmup enabled",
				"local embeddings",
				"[ingest] memory limit",
			],
			`patched iteration ${result.iteration}`,
		)
		if (
			countOccurrences(
				result.log,
				"local embeddings  Xenova/bge-base-en-v1.5",
			) > 1
		) {
			throw new Error(
				`patched iteration ${result.iteration} initialized local embeddings more than once`,
			)
		}
		assertLogContains(result.log, "Xenova/bge-base-en-v1.5", "patched")
		assertLogContains(result.log, "pool: 1 worker", "patched")
		assertLogContains(result.log, "2 concurrent", "patched")
		assertLogContains(result.log, "batch(es) of", "patched")
		assertLogContains(result.log, "8 on 1 worker", "patched")
		if (expectPatchedIdleShutdown) {
			assertLogContains(
				result.log,
				"[embeddings] shutting down 1 idle embedding worker(s)",
				"patched",
			)
		}
	}

	for (const result of stock) {
		assertLogOrder(
			result.log,
			["local embeddings", "supermemory ready"],
			`stock iteration ${result.iteration}`,
		)
		if (result.log.includes("[patch] background embedding warmup enabled")) {
			throw new Error(`stock iteration ${result.iteration} printed patch label`)
		}
	}

	for (const result of [...stock, ...patched]) {
		if (result.firstSearchStatus !== 200) {
			throw new Error(
				`${result.caseName} iteration ${result.iteration} first search returned HTTP ${result.firstSearchStatus}`,
			)
		}
	}

	return { stockAggregate, patchedAggregate }
}

function renderMarkdown(options: {
	runRoot: string
	stockBin: string
	patchedBin: string
	stockHash: string
	patchedHash: string
	stock: CaseResult[]
	patched: CaseResult[]
	stockAggregate: Aggregate
	patchedAggregate: Aggregate
}): string {
	const lines = [
		"# Patched Server Comparison",
		"",
		`Run root: \`${options.runRoot}\``,
		`Stock binary: \`${options.stockBin}\``,
		`Patched binary: \`${options.patchedBin}\``,
		`Stock sha256: \`${options.stockHash}\``,
		`Patched sha256: \`${options.patchedHash}\``,
		`Runs per case: \`${runCount}\``,
		`Ready settle: \`${readySettleMs}ms\``,
		`Post-search idle: \`${postSearchIdleMs}ms\``,
		"RSS scope: server process tree",
		"",
		"## Verdict",
		"",
		"PASS: patched binary met startup and behavior thresholds.",
		"",
		"## Aggregate",
		"",
		"| Case | Ready p50 | First Search p50 | Peak RSS p50 | Post-Search Idle RSS p50 |",
		"|---|---:|---:|---:|---:|",
		`| Stock | ${options.stockAggregate.readyP50} ms | ${options.stockAggregate.firstSearchP50} ms | ${options.stockAggregate.peakRssP50 ?? "n/a"} MB | ${options.stockAggregate.postSearchIdleRssP50 ?? "n/a"} MB |`,
		`| Patched | ${options.patchedAggregate.readyP50} ms | ${options.patchedAggregate.firstSearchP50} ms | ${options.patchedAggregate.peakRssP50 ?? "n/a"} MB | ${options.patchedAggregate.postSearchIdleRssP50 ?? "n/a"} MB |`,
		"",
		"## Individual Runs",
		"",
		"| Case | Iteration | Ready | First Search | Peak RSS | Post-Search Idle RSS | Run Dir |",
		"|---|---:|---:|---:|---:|---:|---|",
	]

	for (const result of [...options.stock, ...options.patched]) {
		lines.push(
			`| ${result.caseName} | ${result.iteration} | ${result.readyMs} ms | ${result.firstSearchMs} ms | ${result.peakRssMb ?? "n/a"} MB | ${result.postSearchIdleRssMb ?? "n/a"} MB | \`${result.runDir}\` |`,
		)
	}

	lines.push(
		"",
		"## Assertions",
		"",
		"- Patched ready p50 beats stock by at least 500ms or 25%.",
		"- Patched first search after settle is within 250ms of stock p50.",
		"- Patched startup logs include the patch label after readiness.",
		"- Patched startup loads local embeddings after readiness and records the ingest baseline after warmup.",
		"- Stock defaults for model, pool size, ingest concurrency, and batch size remain visible in patched logs.",
	)
	if (expectIdleRssWinMb > 0) {
		lines.push(
			`- Patched post-search idle RSS p50 beats stock by at least ${expectIdleRssWinMb}MB.`,
		)
	}
	if (expectPatchedIdleShutdown) {
		lines.push("- Patched logs show embedding worker idle shutdown.")
	}

	return `${lines.join("\n")}\n`
}

async function main(): Promise<void> {
	if (process.argv.includes("--help") || process.argv.includes("-h")) {
		process.stdout.write(usage())
		return
	}

	const runRoot = join(outRoot, new Date().toISOString().replace(/[:.]/g, "-"))
	await mkdir(runRoot, { recursive: true })

	const stockBin = await resolveStockBinary()
	const stockState = checkBinaryState(stockBin)
	if (stockState.state !== "stock") {
		throw new Error(
			`stock binary must be unpatched, got state=${stockState.state}: ${stockBin}`,
		)
	}
	const patchedBin = join(runRoot, "bin", "supermemory-server-patched")
	await mkdir(dirname(patchedBin), { recursive: true })
	createPatchedBinary(stockBin, patchedBin)

	const patchedState = checkBinaryState(patchedBin)
	if (patchedState.state !== "patched" || !patchedState.patchLabel) {
		throw new Error(
			`generated patched binary has unexpected state: state=${patchedState.state} label=${patchedState.patchLabel}`,
		)
	}

	const stockHash = sha256(await readFile(stockBin))
	const patchedHash = sha256(await readFile(patchedBin))
	const stock: CaseResult[] = []
	const patched: CaseResult[] = []

	for (let iteration = 1; iteration <= runCount; iteration += 1) {
		console.log(`Running stock iteration ${iteration}/${runCount}`)
		stock.push(
			await runCase({
				caseName: "stock",
				iteration,
				binary: stockBin,
				runRoot,
			}),
		)

		console.log(`Running patched iteration ${iteration}/${runCount}`)
		patched.push(
			await runCase({
				caseName: "patched",
				iteration,
				binary: patchedBin,
				runRoot,
			}),
		)
	}

	const aggregates = validateResults(stock, patched)
	const summary = renderMarkdown({
		runRoot,
		stockBin,
		patchedBin,
		stockHash,
		patchedHash,
		stock,
		patched,
		...aggregates,
	})
	await writeFile(join(runRoot, "summary.md"), summary)
	await writeFile(
		join(runRoot, "summary.json"),
		`${JSON.stringify(
			{
				stock: stock.map(withoutLog),
				patched: patched.map(withoutLog),
				...aggregates,
			},
			null,
			2,
		)}\n`,
	)
	console.log(summary)
}

main().catch((error) => {
	console.error(error instanceof Error ? error.message : String(error))
	process.exit(1)
})
