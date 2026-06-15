#!/usr/bin/env bun
import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { constants } from "node:fs"
import {
	access,
	chmod,
	copyFile,
	mkdir,
	readFile,
	stat,
	writeFile,
} from "node:fs/promises"
import { dirname, join, resolve } from "node:path"
import { homedir } from "node:os"

const defaultServerBin = join(
	homedir(),
	".supermemory",
	"bin",
	"supermemory-server",
)

const startupStartMarker = "(async()=>{if(XX2)"
const startupEndMarker = "})().catch"
const patchMarker =
	"setTimeout(()=>hX2().then(()=>{rw=process.memoryUsage.rss();Bj8()}).catch(console.error),250)"
const patchLabel = "[patch] background embedding warmup enabled"
const patchLabelCode = `console.log("${patchLabel}")`

const replacements: Array<[from: string, to: string]> = [
	["await mX2(Iz),await hX2();let r=", "await mX2(Iz);let r="],
	[
		"{app:v}=await Promise.resolve().then(()=>(mV2(),_c6))",
		"{app:v}=(mV2(),_c6)",
	],
	[
		"{cleanupExpiredCache:m}=await Promise.resolve().then(()=>(pV2(),Xc6))",
		"{cleanupExpiredCache:m}=(pV2(),Xc6)",
	],
	[
		"{retryStuckProcessingDocuments:z,retryStuckQueuedDocuments:p}=await Promise.resolve().then(()=>(zc6(),Is6))",
		"{retryStuckProcessingDocuments:z,retryStuckQueuedDocuments:p}=(zc6(),Is6)",
	],
	[
		"{logServiceStatus:f}=await Promise.resolve().then(()=>(lV2(),cc6))",
		"{logServiceStatus:f}=(lV2(),cc6)",
	],
	[
		"let{registry:O}=await Promise.resolve().then(()=>(nH2(),gk6));",
		"let{registry:O}=(nH2(),gk6);",
	],
	[
		'v.all("/api/rivet/*",(x)=>O.handler(x.req.raw))',
		'v.all("/api/rivet/*",x=>O.handler(x.req.raw))',
	],
	[
		'Bun.serve({fetch:(O)=>v.fetch(O,r),port:xh,hostname:"0.0.0.0"})',
		'Bun.serve({fetch:O=>v.fetch(O,r),port:xh,hostname:"0.0.0.0"})',
	],
	["}),Bj8(),GH2(", `}),${patchLabelCode},GH2(`],
	[
		'wR.default.schedule("0 */6 * * *",()=>ek8(zk8));let l=',
		'wR.default.schedule("0 */6 * * *",()=>ek8(zk8)),setTimeout(()=>hX2().then(()=>{rw=process.memoryUsage.rss();Bj8()}).catch(console.error),250);let l=',
	],
]

type State = "stock" | "patched" | "unsupported"

type ParsedArgs = {
	command: string
	positional: string[]
	flags: Map<string, string | true>
}

function usage(): string {
	return `Usage:
  bun bench-tooling/patch-server-binary.ts check [binary]
  bun bench-tooling/patch-server-binary.ts patch [input] [output] [--force] [--no-sign]
  bun bench-tooling/patch-server-binary.ts patch --in-place [binary] [--backup path] [--force]
  bun bench-tooling/patch-server-binary.ts restore <stock-binary> <target> [--force] [--sign]

Defaults:
  binary: ${defaultServerBin}
  output: <input>.patched-bg-warm

The patch is intentionally version-marker based. If the bundled startup code no
longer matches the server-v0.0.3 shape, it fails instead of guessing.
`
}

function parseArgs(argv: string[]): ParsedArgs {
	const [command = "", ...rest] = argv
	const positional: string[] = []
	const flags = new Map<string, string | true>()

	for (let index = 0; index < rest.length; index += 1) {
		const arg = rest[index]
		if (!arg.startsWith("--")) {
			positional.push(arg)
			continue
		}

		const key = arg.slice(2)
		if (["force", "in-place", "no-sign", "json", "sign"].includes(key)) {
			flags.set(key, true)
			continue
		}

		const value = rest[index + 1]
		if (!value || value.startsWith("--")) {
			throw new Error(`missing value for --${key}`)
		}
		flags.set(key, value)
		index += 1
	}

	return { command, positional, flags }
}

function flagPath(
	flags: Map<string, string | true>,
	key: string,
): string | null {
	const value = flags.get(key)
	return typeof value === "string" ? expandPath(value) : null
}

function expandPath(path: string): string {
	if (path === "~") return homedir()
	if (path.startsWith("~/")) return join(homedir(), path.slice(2))
	return resolve(path)
}

function sha256(buffer: Buffer): string {
	return createHash("sha256").update(buffer).digest("hex")
}

async function exists(path: string): Promise<boolean> {
	try {
		await access(path, constants.F_OK)
		return true
	} catch {
		return false
	}
}

function findStartupSpan(text: string): {
	start: number
	end: number
	span: string
} {
	const start = text.indexOf(startupStartMarker)
	if (start === -1) {
		throw new Error(`startup marker not found: ${startupStartMarker}`)
	}

	const secondStart = text.indexOf(
		startupStartMarker,
		start + startupStartMarker.length,
	)
	if (secondStart !== -1) {
		throw new Error(
			"startup marker matched more than once; refusing ambiguous patch",
		)
	}

	const end = text.indexOf(startupEndMarker, start)
	if (end === -1) {
		throw new Error(`startup end marker not found: ${startupEndMarker}`)
	}

	return { start, end, span: text.slice(start, end) }
}

function classifySpan(span: string): State {
	if (span.includes(patchMarker)) return "patched"
	if (
		span.includes("await mX2(Iz),await hX2();let r=") &&
		span.includes("}),Bj8(),GH2(")
	) {
		return "stock"
	}
	return "unsupported"
}

function buildPatchedSpan(stockSpan: string): string {
	let patched = stockSpan

	for (const [from, to] of replacements) {
		if (!patched.includes(from)) {
			throw new Error(`expected source fragment not found: ${from}`)
		}
		patched = patched.replace(from, to)
	}

	if (!patched.includes(patchMarker)) {
		throw new Error("patch marker was not inserted")
	}
	if (patched.includes("await mX2(Iz),await hX2();let r=")) {
		throw new Error("blocking embedding prewarm is still present after patch")
	}
	if (patched.length > stockSpan.length) {
		throw new Error(
			`patched startup span is ${patched.length - stockSpan.length} byte(s) too long`,
		)
	}

	return patched.padEnd(stockSpan.length, " ")
}

function addPatchLabel(span: string): { span: string; changed: boolean } {
	if (span.includes(patchLabel)) return { span, changed: false }

	const trimmedSpan = span.trimEnd()
	const labeled = trimmedSpan.replace("}),GH2(", `}),${patchLabelCode},GH2(`)
	if (labeled === trimmedSpan) {
		throw new Error(
			"patched startup span is missing the ready-display insertion point",
		)
	}
	if (labeled.length > span.length) {
		throw new Error(
			`labeled startup span is ${labeled.length - span.length} byte(s) too long`,
		)
	}

	return { span: labeled.padEnd(span.length, " "), changed: true }
}

function patchBuffer(input: Buffer): {
	output: Buffer
	before: State
	changed: boolean
} {
	const text = input.toString("latin1")
	const { start, end, span } = findStartupSpan(text)
	const before = classifySpan(span)

	if (before === "patched") {
		const labeled = addPatchLabel(span)
		const output = Buffer.from(
			text.slice(0, start) + labeled.span + text.slice(end),
			"latin1",
		)
		if (output.length !== input.length) {
			throw new Error(
				`binary length changed from ${input.length} to ${output.length}`,
			)
		}
		return { output, before, changed: labeled.changed }
	}
	if (before !== "stock") {
		throw new Error(
			"unsupported startup shape; this patcher only handles stock server-v0.0.3 markers",
		)
	}

	const patchedSpan = buildPatchedSpan(span)
	const output = Buffer.from(
		text.slice(0, start) + patchedSpan + text.slice(end),
		"latin1",
	)
	if (output.length !== input.length) {
		throw new Error(
			`binary length changed from ${input.length} to ${output.length}`,
		)
	}

	return { output, before, changed: true }
}

function maybeSign(path: string, noSign: boolean): string {
	if (noSign) return "skipped (--no-sign)"
	if (process.platform !== "darwin") return "skipped (not darwin)"

	const result = spawnSync("codesign", ["--force", "--sign", "-", path], {
		encoding: "utf8",
	})
	if (result.status !== 0) {
		throw new Error(
			`codesign failed for ${path}: ${result.stderr || result.stdout}`,
		)
	}
	return "adhoc"
}

async function writeExecutable(
	path: string,
	buffer: Buffer,
	modeSource: string,
): Promise<void> {
	await mkdir(dirname(path), { recursive: true })
	await writeFile(path, buffer)
	const inputMode = (await stat(modeSource)).mode
	await chmod(path, inputMode | 0o111)
}

async function checkCommand(args: ParsedArgs): Promise<void> {
	const input =
		flagPath(args.flags, "input") ??
		expandPath(args.positional[0] ?? defaultServerBin)
	const buffer = await readFile(input)
	const { span, start, end } = findStartupSpan(buffer.toString("latin1"))
	const state = classifySpan(span)
	const info = {
		path: input,
		state,
		patchLabel: span.includes(patchLabel),
		sha256: sha256(buffer),
		bytes: buffer.length,
		startupStart: start,
		startupLength: end - start,
	}

	if (args.flags.has("json")) {
		console.log(JSON.stringify(info, null, 2))
		return
	}

	console.log(`path=${info.path}`)
	console.log(`state=${info.state}`)
	console.log(`patch_label=${info.patchLabel ? "yes" : "no"}`)
	console.log(`sha256=${info.sha256}`)
	console.log(`bytes=${info.bytes}`)
	console.log(`startup_start=${info.startupStart}`)
	console.log(`startup_length=${info.startupLength}`)
}

async function patchCommand(args: ParsedArgs): Promise<void> {
	const input =
		flagPath(args.flags, "input") ??
		expandPath(args.positional[0] ?? defaultServerBin)
	const inPlace = args.flags.has("in-place")
	const output = inPlace
		? input
		: (flagPath(args.flags, "output") ??
			expandPath(args.positional[1] ?? `${input}.patched-bg-warm`))
	const force = args.flags.has("force")
	const noSign = args.flags.has("no-sign")

	if (input === output && !inPlace) {
		throw new Error(
			"input and output are the same; pass --in-place to patch in place",
		)
	}
	if (!inPlace && (await exists(output)) && !force) {
		throw new Error(
			`output already exists: ${output}. Pass --force to overwrite.`,
		)
	}

	const inputBuffer = await readFile(input)
	const { output: outputBuffer, before, changed } = patchBuffer(inputBuffer)

	let backup: string | null = null
	if (inPlace && before === "stock") {
		backup =
			flagPath(args.flags, "backup") ??
			`${input}.stock-${sha256(inputBuffer).slice(0, 8)}.bak`
		if (!(await exists(backup))) {
			await copyFile(input, backup)
		}
	}

	await writeExecutable(output, outputBuffer, input)
	const signature = maybeSign(output, noSign)

	console.log(`input=${input}`)
	console.log(`output=${output}`)
	console.log(`state_before=${before}`)
	console.log(`changed=${changed ? "yes" : "no"}`)
	if (backup) console.log(`backup=${backup}`)
	console.log(`sha256=${sha256(await readFile(output))}`)
	console.log(`signature=${signature}`)
}

async function restoreCommand(args: ParsedArgs): Promise<void> {
	const source =
		flagPath(args.flags, "input") ?? expandPath(args.positional[0] ?? "")
	const target =
		flagPath(args.flags, "output") ??
		expandPath(args.positional[1] ?? defaultServerBin)
	const force = args.flags.has("force")
	const sign = args.flags.has("sign")

	if (!source) throw new Error("restore requires a stock source binary")
	if ((await exists(target)) && !force) {
		throw new Error(
			`target already exists: ${target}. Pass --force to overwrite.`,
		)
	}

	await mkdir(dirname(target), { recursive: true })
	await copyFile(source, target)
	const inputMode = (await stat(source)).mode
	await chmod(target, inputMode | 0o111)
	const signature = sign ? maybeSign(target, false) : "preserved"

	console.log(`source=${source}`)
	console.log(`target=${target}`)
	console.log(`sha256=${sha256(await readFile(target))}`)
	console.log(`signature=${signature}`)
}

async function main(): Promise<void> {
	const args = parseArgs(process.argv.slice(2))

	if (
		!args.command ||
		args.command === "help" ||
		args.command === "--help" ||
		args.command === "-h"
	) {
		process.stdout.write(usage())
		return
	}

	if (args.command === "check") {
		await checkCommand(args)
		return
	}
	if (args.command === "patch") {
		await patchCommand(args)
		return
	}
	if (args.command === "restore") {
		await restoreCommand(args)
		return
	}

	throw new Error(`unknown command: ${args.command}`)
}

main().catch((error) => {
	console.error(error instanceof Error ? error.message : String(error))
	process.exit(1)
})
