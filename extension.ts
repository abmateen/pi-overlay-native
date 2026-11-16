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

/**
 * `message_end` fires before pi appends the message to the session, so defer
 * the read by a tick to include the prompt or answer that just finished.
 */
function queueQueries(ctx: ExtensionContext): void {
	setTimeout(() => sendQueries(ctx), 0);
}

function killExisting(ttyPath: string): void {
	try {
		execFileSync("pkill", ["-f", `[t]ty_overlay_native .*--tty ${ttyPath}`], {
			stdio: "ignore",
		});
	} catch {
		// no existing process is fine
	}
}

function stopOverlay(): void {
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
	});

	pi.on("message_end", (event, ctx) => {
		if (event.message.role === "assistant") {
			lastAssistantText = textFromContent(event.message.content);
		}
		// Show a new prompt in the dropdown as soon as it is persisted.
		// Answers can wait for agent_settled, which sends a fresh list.
		if (event.message.role === "user") {
			queueQueries(ctx);
		}
	});

	pi.on("agent_start", () => {
		lastAssistantText = "";
		sendEvent({ type: "status", value: "processing" });
	});

	pi.on("agent_settled", (_event, ctx) => {
		sendEvent({ type: "status", value: "done" });
		sendEvent({ type: "response", text: lastAssistantText });
		sendQueries(ctx);
	});

	pi.on("session_shutdown", (event) => {
		// The overlay belongs to the terminal, not to one conversation. Keep it
		// alive across new/resume/fork so the next session_start can reseed it.
		if (event.reason === "quit" || event.reason === "reload") {
			stopOverlay();
		}
	});
}
