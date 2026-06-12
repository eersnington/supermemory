"use client"

import { useState } from "react"
import { cn } from "@lib/utils"
import { dmSansClassName } from "@/lib/fonts"
import { ArrowLeft, BookOpen, Mail, ChevronRight, Loader2 } from "lucide-react"
import { LogoFull } from "@ui/assets/Logo"
import { useAuth } from "@lib/auth-context"
import { useDigests, useDigest } from "@/hooks/use-digests"

interface DigestsViewProps {
	initialDigestId?: string | null
}

// Mirrors the email's feature → illustration mapping (served from /images/digest/).
const FEATURE_IMG: Record<string, string> = {
	connections: "feat-router.png",
	chat: "feat-memory.png",
	extension: "feat-retrieval.png",
	plugins: "feat-profiles.png",
	mcp: "feat-router.png",
	search: "feat-retrieval.png",
}

const BRAIN_IMG = "https://supermemory.ai/images/brain-head.png"

function formatIsoWeek(isoWeek: string): string {
	const match = isoWeek.match(/^(\d{4})-W(\d{2})$/)
	if (!match) return isoWeek
	const year = Number.parseInt(match[1] as string, 10)
	const week = Number.parseInt(match[2] as string, 10)
	const jan4 = new Date(year, 0, 4)
	const dow = jan4.getDay() || 7
	const start = new Date(jan4)
	start.setDate(jan4.getDate() - dow + 1 + (week - 1) * 7)
	const end = new Date(start)
	end.setDate(start.getDate() + 6)
	const months = [
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	]
	const sm = months[start.getMonth()] ?? ""
	const em = months[end.getMonth()] ?? ""
	return `Week of ${sm} ${start.getDate()}–${sm === em ? "" : `${em} `}${end.getDate()}, ${year}`
}

function DigestDetailPanel({
	digestId,
	onBack,
}: {
	digestId: string
	onBack: () => void
}) {
	const { data: digest, isLoading } = useDigest(digestId)
	const { user } = useAuth()
	const firstName = user?.name?.split(" ")[0] || "there"

	if (isLoading) {
		return (
			<div className="flex h-64 items-center justify-center">
				<Loader2 className="size-6 animate-spin text-[#4BA0FA]" />
			</div>
		)
	}

	if (!digest) {
		return (
			<div className="flex h-64 items-center justify-center text-sm text-fg-muted">
				Digest not found.
			</div>
		)
	}

	const { digestData } = digest

	return (
		<div className={cn("mx-auto w-full max-w-xl", dmSansClassName())}>
			<button
				type="button"
				onClick={onBack}
				className="mb-4 inline-flex items-center gap-1.5 text-sm text-fg-muted transition-colors hover:text-fg-secondary"
			>
				<ArrowLeft className="size-4" />
				All digests
			</button>

			<div className="overflow-hidden rounded-2xl border border-surface-border bg-surface-card">
				{/* Header band */}
				<div className="bg-[#4BA0FA]/[0.08] px-7 pb-7 pt-7 sm:px-8">
					<LogoFull className="h-[18px] w-auto text-fg-primary" />
					<h1 className="mt-7 text-[28px] font-extrabold leading-[1.12] tracking-tight text-fg-primary">
						Your week in Supermemory
					</h1>
					<p className="mt-1.5 text-sm text-fg-faint">
						{formatIsoWeek(digest.isoWeek)}
					</p>
				</div>

				{/* Greeting + intro, brain floated right */}
				<div className="px-7 pt-7 sm:px-8">
					{/* biome-ignore lint/a11y/useAltText: decorative */}
					<img
						src={BRAIN_IMG}
						alt=""
						width={74}
						height={111}
						className="float-right ml-5 mb-1.5 h-[111px] w-auto"
					/>
					<p className="mb-2 text-base font-bold text-fg-primary">
						Hey {firstName},
					</p>
					<p className="text-[15px] leading-relaxed text-fg-muted">
						{digestData.intro}
					</p>
					<div className="clear-both" />
				</div>

				{/* Body */}
				<div className="px-7 pb-8 pt-7 sm:px-8">
					<div className="mb-7 border-t border-surface-border" />

					{/* Highlights */}
					{digestData.highlights.length > 0 && (
						<>
							<p className="mb-5 text-[10px] font-bold uppercase tracking-[0.14em] text-fg-faint">
								This week's highlights
							</p>
							<div className="flex flex-col gap-7">
								{digestData.highlights.map((h, i) => (
									<div key={h.id} className="flex gap-3">
										<span className="w-7 shrink-0 pt-0.5 text-[11px] font-bold tracking-wider text-[#4BA0FA]">
											{String(i + 1).padStart(2, "0")}
										</span>
										<div>
											<p className="mb-1.5 text-base font-semibold leading-snug text-fg-primary">
												{h.title}
											</p>
											<p className="text-sm leading-relaxed text-fg-muted">
												{h.content}
											</p>
										</div>
									</div>
								))}
							</div>
						</>
					)}

					{/* Worth trying */}
					{digestData.featureRecommendations.length > 0 && (
						<>
							<div className="my-8 border-t border-surface-border" />
							<div className="rounded-2xl bg-[#4BA0FA]/[0.08] p-6">
								<p className="mb-5 text-[10px] font-bold uppercase tracking-[0.14em] text-[#4BA0FA]">
									Worth trying
								</p>
								<div className="flex flex-col">
									{digestData.featureRecommendations.map((r, i) => (
										<div key={r.feature}>
											{i > 0 && (
												<div className="my-4 border-t border-[#4BA0FA]/15" />
											)}
											<div className="flex gap-3.5">
												{/* biome-ignore lint/a11y/useAltText: decorative */}
												<img
													src={`/images/digest/${FEATURE_IMG[r.feature] ?? "feat-memory.png"}`}
													alt=""
													width={52}
													height={52}
													className="size-[52px] shrink-0"
												/>
												<div>
													<p className="mb-0.5 text-sm font-bold text-fg-primary">
														{r.headline}
													</p>
													<p className="text-[13px] leading-snug text-fg-muted">
														{r.body}{" "}
														<a
															href={r.ctaUrl}
															className="whitespace-nowrap font-semibold text-[#4BA0FA] hover:underline"
														>
															{r.ctaLabel} →
														</a>
													</p>
												</div>
											</div>
										</div>
									))}
								</div>
							</div>
						</>
					)}
				</div>
			</div>
		</div>
	)
}

export function DigestsView({ initialDigestId }: DigestsViewProps) {
	const [selectedId, setSelectedId] = useState<string | null>(
		initialDigestId ?? null,
	)
	const { data: digests, isLoading } = useDigests()

	if (selectedId) {
		return (
			<div className="mx-auto w-full max-w-2xl px-4 py-8">
				<DigestDetailPanel
					digestId={selectedId}
					onBack={() => setSelectedId(null)}
				/>
			</div>
		)
	}

	return (
		<div
			className={cn("mx-auto w-full max-w-2xl px-4 py-8", dmSansClassName())}
		>
			<div className="mb-6">
				<div className="mb-1 flex items-center gap-2">
					<Mail className="size-5 text-[#4BA0FA]" />
					<h1 className="text-xl font-semibold text-fg-primary">
						Weekly Digests
					</h1>
				</div>
				<p className="text-sm text-fg-muted">
					Your personalized weekly recap — delivered every Monday.
				</p>
			</div>

			{isLoading ? (
				<div className="flex h-48 items-center justify-center">
					<Loader2 className="size-6 animate-spin text-[#4BA0FA]" />
				</div>
			) : !digests || digests.length === 0 ? (
				<div className="flex flex-col items-center justify-center gap-3 rounded-2xl border border-surface-border bg-surface-card py-16 text-center">
					<Mail className="size-10 text-fg-muted opacity-40" />
					<p className="text-sm font-medium text-fg-secondary">
						No digests yet
					</p>
					<p className="max-w-xs text-xs text-fg-muted">
						Your first digest will arrive next Monday. Come back then to see
						your highlights and suggestions.
					</p>
				</div>
			) : (
				<div className="flex flex-col gap-2">
					{digests.map((digest) => (
						<button
							key={digest.id}
							type="button"
							onClick={() => setSelectedId(digest.id)}
							className="group flex w-full items-center gap-3 rounded-xl border border-surface-border bg-surface-card px-4 py-3.5 text-left transition-colors hover:bg-surface-hover"
						>
							<div className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-[#4BA0FA]/10 text-[#4BA0FA]">
								<BookOpen className="size-4" />
							</div>
							<div className="flex min-w-0 flex-1 flex-col gap-0.5">
								<p className="truncate text-sm font-semibold text-fg-primary">
									{digest.emailSubject ?? formatIsoWeek(digest.isoWeek)}
								</p>
								<p className="text-xs text-fg-muted">
									{formatIsoWeek(digest.isoWeek)} · {digest.highlightCount}{" "}
									highlights · {digest.memoryCount} memories
								</p>
							</div>
							<ChevronRight className="size-4 shrink-0 text-fg-muted transition-colors group-hover:text-fg-secondary" />
						</button>
					))}
				</div>
			)}
		</div>
	)
}
