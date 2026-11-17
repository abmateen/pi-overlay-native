import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const EXT_DIR = path.dirname(fileURLToPath(import.meta.url));
const BINARY_NAME = "pi-overlay-native";
const LEGACY_BINARY_NAMES = ["pi-oui", "pi-overlay", "tty_overlay_native"];

let overlay: ChildProcess | null = null;
let overlayTty: string | null = null;
let lastAssistantText = "";

// Footer numbers (context usage + token rate), sent to the overlay as `usage`.
const USAGE_THROTTLE_MS = 400;
let usageTimer: ReturnType<typeof setTimeout> | null = null;
let lastUsageSentAt = 0;
let messageStartedAt = 0;
let lastTokensPerSecond: number | null = null;
// Providers report usage in the final chunk, so during a turn the only rate that
// can move is the estimate from the characters that have actually streamed.
let streamedChars = 0;
let lastEstimatedTokensPerSecond: number | null = null;

function currentTTY(): string | null {
	try {
		const tty = execFileSync(
			"ps",
			["-o", "tty=", "-p", String(process.pid)],
			{ encoding: "utf8" },
		).trim();

		if (!tty || tty === "??" || tty === "TT") return null;
		return tty.startsWith("/dev/") ? tty : `/dev/${tty}`;
	} catch {
		return null;
	}
}

function resolveBinary(ctx: ExtensionContext): string | null {
	const candidates = [
		process.env.PI_OVERLAY_BIN,
		path.join(EXT_DIR, BINARY_NAME),
		...LEGACY_BINARY_NAMES.map((name) => path.join(EXT_DIR, name)),
		path.join(EXT_DIR, "build", BINARY_NAME),
		...LEGACY_BINARY_NAMES.map((name) => path.join(EXT_DIR, "build", name)),
		path.join(ctx.cwd, BINARY_NAME),
		...LEGACY_BINARY_NAMES.map((name) => path.join(ctx.cwd, name)),
	].filter((value): value is string => Boolean(value));

	return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

function sendEvent(event: unknown): void {
	const stdin = overlay?.stdin;
	if (!stdin || stdin.destroyed) return;
	try {
		stdin.write(JSON.stringify(event) + "\n");
	} catch {
		// overlay may have exited; status/response updates are best-effort
	}
}

function textFromContent(content: unknown): string {
	if (typeof content === "string") return content.trim();
	if (!Array.isArray(content)) return "";
	return content
		.map((block) => {
			if (
				block &&
				typeof block === "object" &&
				(block as { type?: string }).type === "text" &&
				typeof (block as { text?: string }).text === "string"
			) {
				return (block as { text: string }).text;
			}
			return "";
		})
		.join("")
		.trim();
}

/** Last assistant answer on the active branch, for populating the overlay on load. */
function lastAssistantFromSession(ctx: ExtensionContext): string {
	try {
		const entries = ctx.sessionManager.getBranch();
		for (let i = entries.length - 1; i >= 0; i--) {
			const entry = entries[i];
			if (entry.type !== "message" || entry.message.role !== "assistant") continue;
			const text = textFromContent(entry.message.content);
			if (text) return text;
		}
	} catch {
		// session manager may not be readable mid-switch
	}
	return "";
}

interface OverlayQuery {
	id: string;
	prompt: string;
	answer: string;
}

/** Pairs each user prompt on the active branch with the answer that followed. */
function queriesFromSession(ctx: ExtensionContext): OverlayQuery[] {
	let entries: ReturnType<ExtensionContext["sessionManager"]["getBranch"]>;
	try {
		entries = ctx.sessionManager.getBranch();
	} catch {
		return [];
	}

	const queries: OverlayQuery[] = [];
	let current: OverlayQuery | undefined;

	for (let i = 0; i < entries.length; i++) {
		const entry = entries[i];
		if (entry.type !== "message") continue;
		const message = entry.message;

		if (message.role === "user") {
			const prompt = textFromContent(message.content);
			const stamp = (message as { timestamp?: number }).timestamp;
			current = {
				id: stamp !== undefined ? String(stamp) : `user-${i}`,
				prompt: prompt || "(image prompt)",
				answer: "",
			};
			queries.push(current);
		} else if (message.role === "assistant" && current) {
			const answer = textFromContent(message.content);
			if (answer) current.answer = answer;
		}
	}

	return queries;
}

function sendQueries(ctx: ExtensionContext): void {
	sendEvent({ type: "queries", items: queriesFromSession(ctx) });
}

// pi's canonical level order; a model can only ever shrink this list.
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/**
 * Mirror of pi's `getSupportedThinkingLevels()`: a `null` in the model's map means
 * the model cannot express that level, an absent key means the default applies.
 * A non-reasoning model supports `off` only, which is what makes the overlay's
 * dropdown read as a label instead of a chooser.
 */
function thinkingLevels(ctx: ExtensionContext): string[] {
	const model = ctx.model;
	if (!model) return [...THINKING_LEVELS];
	if (!model.reasoning) return ["off"];
	const map = model.thinkingLevelMap as Record<string, string | null> | undefined;
	if (!map) return [...THINKING_LEVELS];
	return THINKING_LEVELS.filter((level) => map[level] !== null);
}

/**
 * The reasoning dropdown. The overlay can only mirror this state: in tty mode it
 * has no command channel back into pi, so a selection comes back as a typed
 * `/thinking` command and this event closes the loop.
 */
function sendThinking(pi: ExtensionAPI, ctx: ExtensionContext): void {
	// Ask for the effective level, not the one the overlay last picked: pi clamps it
	// to the model, so the two can disagree.
	sendEvent({ type: "thinking", level: pi.getThinkingLevel(), levels: thinkingLevels(ctx) });
}

/**
 * `message_end` fires before pi appends the message to the session, so defer
 * the read by a tick to include the prompt or answer that just finished.
 */
function queueQueries(ctx: ExtensionContext): void {
	setTimeout(() => sendQueries(ctx), 0);
}

/**
 * Footer numbers for the overlay: current context window usage and the output
 * token rate for the turn that is streaming (or the last one while idle).
 * `getContextUsage()` is pi's own estimate, the same one its terminal footer
 * and `/session` use.
 */
function sendUsage(ctx: ExtensionContext, force: boolean): void {
	if (usageTimer) {
		if (!force) return;
		clearTimeout(usageTimer);
		usageTimer = null;
	}

	const wait = USAGE_THROTTLE_MS - (Date.now() - lastUsageSentAt);
	if (!force && wait > 0) {
		// Keep the streamed numbers moving without writing one line per token.
		usageTimer = setTimeout(() => {
			usageTimer = null;
			sendUsage(ctx, true);
		}, wait);
		return;
	}

	lastUsageSentAt = Date.now();
	const usage = ctx.getContextUsage();
	sendEvent({
		type: "usage",
		contextTokens: usage?.tokens ?? null,
		contextWindow: usage?.contextWindow ?? 0,
		tokensPerSecond: lastTokensPerSecond,
		estimatedTokensPerSecond: lastEstimatedTokensPerSecond,
	});
}

/**
 * Character counts, not a tokenizer: good enough to move the footer, not good
 * enough to bill for. The footer draws an estimate as `≈` so it is not read as
 * the provider's own usage.
 */
function noteStreamDelta(assistantMessageEvent: unknown): void {
	const event = assistantMessageEvent as { type?: string; delta?: string };
	if (event?.type !== "text_delta" && event?.type !== "thinking_delta") return;
	if (typeof event.delta !== "string" || !messageStartedAt) return;

	streamedChars += event.delta.length;
	const elapsed = (Date.now() - messageStartedAt) / 1000;
	if (elapsed <= 0.2) return;

	const rate = streamedChars / 4 / elapsed;
	// Only accept a move that changes the displayed digits.
	if (rate.toFixed(1) === (lastEstimatedTokensPerSecond ?? -1).toFixed(1)) return;
	lastEstimatedTokensPerSecond = rate;
}

/** Output tokens / seconds for the assistant message that is streaming. */
function trackRate(message: unknown): void {
	if (!message || typeof message !== "object") return;
	if ((message as { role?: string }).role !== "assistant") return;

	const usage = (message as { usage?: { output?: number } }).usage;
	const output = usage?.output ?? 0;
	if (output <= 0) return;

	if (!messageStartedAt) messageStartedAt = Date.now();
	const elapsed = (Date.now() - messageStartedAt) / 1000;
	if (elapsed > 0.2) lastTokensPerSecond = output / elapsed;
}

function resetUsage(): void {
	messageStartedAt = 0;
	lastTokensPerSecond = null;
	streamedChars = 0;
	lastEstimatedTokensPerSecond = null;
}

function killExisting(ttyPath: string): void {
	// Match every historical binary name, current one included: an overlay left
	// behind by an earlier build is still the window the user sees, and it would
	// never be replaced otherwise (one stale window per pi start, stacked).
	for (const name of [BINARY_NAME, ...LEGACY_BINARY_NAMES]) {
		try {
			execFileSync("pkill", ["-f", `[${name[0]}]${name.slice(1)} .*--tty ${ttyPath}`], {
				stdio: "ignore",
			});
		} catch {
			// no existing process is fine
		}
	}
}

function stopOverlay(): void {
	if (usageTimer) {
		clearTimeout(usageTimer);
		usageTimer = null;
	}
	if (overlay && !overlay.killed) {
		try {
			overlay.kill("SIGTERM");
		} catch {
			// ignore
		}
	}
	overlay = null;
	overlayTty = null;
}

function startOverlay(ctx: ExtensionContext): boolean {
	const ttyPath = currentTTY();
	if (!ttyPath) {
		ctx.ui.notify("TTY overlay: could not detect the current terminal TTY.", "warning");
		return false;
	}

	const binary = resolveBinary(ctx);
	if (!binary) {
		ctx.ui.notify(
			`TTY overlay binary not found. Run "make" in ${EXT_DIR}, or set PI_OVERLAY_BIN.`,
			"error",
		);
		return false;
	}

	killExisting(ttyPath);
	stopOverlay();

	try {
		// Do not detach: the child must inherit pi's session/controlling TTY
		// so TIOCSTI can inject into the pi prompt.
		const child = spawn(binary, ["--mode", "tty", "--tty", ttyPath], {
			cwd: path.dirname(binary),
			stdio: ["pipe", "ignore", "ignore"],
		});
		child.unref();

		child.on("error", (error) => {
			ctx.ui.notify(`TTY overlay failed to start: ${error.message}`, "error");
		});
		child.on("exit", () => {
			if (overlay === child) {
				overlay = null;
				overlayTty = null;
			}
		});

		overlay = child;
		overlayTty = ttyPath;

		// Populate the response panel and prompt history from the current
		// session right away.
		lastAssistantText = lastAssistantFromSession(ctx);
		if (lastAssistantText) {
			sendEvent({ type: "response", text: lastAssistantText });
		}
		sendQueries(ctx);

		ctx.ui.notify(`TTY overlay started for ${ttyPath}.`, "info");
		return true;
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		ctx.ui.notify(`TTY overlay failed to start: ${message}`, "error");
		return false;
	}
}

export default function (pi: ExtensionAPI) {
	pi.registerCommand("overlay", {
		description: "Start or stop the native TTY overlay",
		handler: async (_args, ctx) => {
			if (process.platform !== "darwin") {
				ctx.ui.notify("TTY overlay is macOS-only.", "warning");
				return;
			}

			if (overlay && !overlay.killed) {
				stopOverlay();
				ctx.ui.notify("TTY overlay stopped.", "info");
				return;
			}

			startOverlay(ctx);
		},
	});

	pi.on("session_start", (_event, ctx) => {
		lastAssistantText = lastAssistantFromSession(ctx);
		sendEvent({ type: "response", text: lastAssistantText });
		sendQueries(ctx);
		// A new conversation has its own context usage and token rate.
		resetUsage();
		sendUsage(ctx, true);
		sendThinking(pi, ctx);
	});

	/** New assistant message: start the clock for the live token rate. */
	pi.on("message_start", (event, ctx) => {
		if ((event.message as { role?: string }).role === "assistant") {
			messageStartedAt = Date.now();
			lastTokensPerSecond = null;
			// A new assistant message is a new rate window.
			streamedChars = 0;
			lastEstimatedTokensPerSecond = null;
		}
		sendUsage(ctx, false);
	});

	/** Streaming usage is cumulative for the response, so it also gives the rate. */
	pi.on("message_update", (event, ctx) => {
		trackRate(event.message);
		noteStreamDelta(event.assistantMessageEvent);
		sendUsage(ctx, false);
	});

	pi.on("message_end", (event, ctx) => {
		if (event.message.role === "assistant") {
			lastAssistantText = textFromContent(event.message.content);
			trackRate(event.message);
		}
		// Show a new prompt in the dropdown as soon as it is persisted.
		// Answers can wait for agent_settled, which sends a fresh list.
		if (event.message.role === "user") {
			queueQueries(ctx);
		}
		// The footer numbers come from the same usage record.
		sendUsage(ctx, true);
	});

	pi.on("agent_start", (_event, ctx) => {
		lastAssistantText = "";
		resetUsage();
		sendEvent({ type: "status", value: "processing" });
		sendUsage(ctx, true);
	});

	pi.on("agent_settled", (_event, ctx) => {
		sendEvent({ type: "status", value: "done" });
		sendEvent({ type: "response", text: lastAssistantText });
		sendQueries(ctx);
		// pi's own estimate is the number that drives compaction, so refresh the
		// footer from it once the turn has settled.
		sendUsage(ctx, true);
	});

	// The context window and the level list both belong to the model.
	pi.on("model_select", (_event, ctx) => {
		sendUsage(ctx, true);
		sendThinking(pi, ctx);
	});

	pi.on("thinking_level_select", (_event, ctx) => sendThinking(pi, ctx));

	/**
	 * Compaction happens in the terminal, not in the overlay, so this is the only
	 * way the overlay learns about it in tty mode. Usage is null right after a
	 * compaction, so the event carries the pre-compaction count and the meter waits
	 * for the next usage event.
	 */
	pi.on("session_compact", (event, ctx) => {
		sendEvent({ type: "compact", tokensBefore: event.compactionEntry.tokensBefore, reason: event.reason });
		// A compaction is a new rate window: the streamed characters it discarded must
		// not keep inflating the estimate.
		resetUsage();
		sendUsage(ctx, true);
	});

	pi.on("session_shutdown", (event) => {
		// The overlay belongs to the terminal, not to one conversation. Keep it
		// alive across new/resume/fork so the next session_start can reseed it.
		if (event.reason === "quit" || event.reason === "reload") {
			stopOverlay();
		}
	});
}
