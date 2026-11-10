import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const EXT_DIR = path.dirname(fileURLToPath(import.meta.url));
const BINARY_NAME = "tty_overlay_native";

let overlay: ChildProcess | null = null;
let overlayTty: string | null = null;

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
		path.join(EXT_DIR, "build", BINARY_NAME),
		path.join(ctx.cwd, BINARY_NAME),
	].filter((value): value is string => Boolean(value));

	return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

function statusPath(ttyPath: string): string {
	return `/tmp/pi-overlay-${path.basename(ttyPath)}.status`;
}

function setAgentStatus(ttyPath: string | null, status: "processing" | "done" | "idle"): void {
	if (!ttyPath) return;
	const file = statusPath(ttyPath);
	try {
		if (status === "idle") {
			unlinkSync(file);
		} else {
			writeFileSync(file, status, "utf8");
		}
	} catch {
		// status updates are best-effort
	}
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
	setAgentStatus(overlayTty, "idle");
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
	setAgentStatus(ttyPath, "idle");

	try {
		// Do not detach: the child must inherit pi's session/controlling TTY
		// so TIOCSTI can inject into the pi prompt.
		const child = spawn(binary, ["--mode", "tty", "--tty", ttyPath], {
			cwd: path.dirname(binary),
			stdio: "ignore",
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

	pi.on("agent_start", () => {
		setAgentStatus(overlayTty, "processing");
	});

	pi.on("agent_settled", () => {
		setAgentStatus(overlayTty, "done");
	});

	pi.on("session_shutdown", () => {
		stopOverlay();
	});
}
