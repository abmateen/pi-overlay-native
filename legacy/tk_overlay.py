#!/usr/bin/env python3
"""
tty_overlay.py — transparent, always-on-top key overlay for a TTY.

What it does
------------
A borderless, translucent Tkinter window sits above other windows. When the
overlay is focused and capture is ON, keystrokes are forwarded to one of these
backends. A key tape at the bottom shows every key as it is sent:

  --mode tty   Inject bytes into an existing TTY with TIOCSTI.
               This is the "send to active terminal" mode. On macOS/Linux,
               TIOCSTI may be blocked by the OS or by terminal permissions.
               If it fails, use --mode pty or --mode dry.

  --mode pty   Spawn a private shell in a PTY and show its output in the
               overlay. This always works and gives you a real terminal,
               but it is a *new* shell, not the terminal that launched it.

  --mode dry   Only log the keys. No terminal is touched.

Safety
------
* Capture starts OFF. Press F8 or click "Start capture" to enable it.
* Keys are captured only while the overlay window has focus. It is not a
  global keylogger.
* Ctrl+Shift+Q quits. F8 toggles capture.
* The overlay is visibly bordered, shows its target, and echoes keys.
* No OS title bar: drag the custom header to move it; use the × button to quit.

Examples
--------
  python3 tty_overlay.py --list
  python3 tty_overlay.py --check /dev/ttys007
  python3 tty_overlay.py --mode tty --tty /dev/ttys007
  python3 tty_overlay.py --mode pty
  python3 tty_overlay.py --mode dry
  python3 tty_overlay.py --mode dry --opacity 0.5

If you run the overlay from a different terminal, target the pi/TUI terminal
explicitly, e.g. --tty /dev/ttys007.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import platform
import queue
import re
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
import tkinter as tk
from tkinter import font as tkfont
from tkinter import scrolledtext


# ---------------------------------------------------------------------------
# TTY injection
# ---------------------------------------------------------------------------

# TIOCSTI = _IOW('t', 114, char)
# Darwin: 0x80017472, Linux: 0x5412
TIOCSTI = 0x80017472 if sys.platform == "darwin" else 0x5412


class BackendError(RuntimeError):
    pass


def controlling_tty() -> str | None:
    """Return the actual controlling TTY path, or None."""
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None
    try:
        return os.ttyname(fd)
    except OSError:
        return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


class TtyBackend:
    """Inject bytes into an existing TTY using TIOCSTI."""

    def __init__(self, path: str):
        self.path = path
        try:
            self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        except OSError as exc:
            raise BackendError(f"cannot open {path}: {exc}") from exc

        if not os.isatty(self.fd):
            os.close(self.fd)
            raise BackendError(f"{path} is not a TTY")

        # TIOCSTI on macOS requires the target to be this process's
        # controlling terminal. It also fails in the background unless
        # SIGTTOU is ignored (the kernel otherwise sends SIGTTOU).
        try:
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        except (ValueError, OSError):
            pass

        own_tty = controlling_tty()
        if own_tty != path:
            os.close(self.fd)
            raise BackendError(
                f"{path} is not this process's controlling TTY "
                f"(this process controls {own_tty or 'no TTY'}).\n"
                "TIOCSTI only works on the caller's own controlling terminal.\n"
                "Run the overlay from that terminal in the background, e.g.:\n"
                f"  python3 tty_overlay.py --mode tty --tty {path} &\n"
                "or use --mode pty for a private shell."
            )

        try:
            foreground_pgrp = os.tcgetpgrp(self.fd)
        except OSError:
            foreground_pgrp = None

        if foreground_pgrp == os.getpgrp():
            os.close(self.fd)
            raise BackendError(
                "This overlay is the foreground process on that TTY, so "
                "injected keys would loop back into the overlay.\n"
                "Run it in the background instead:\n"
                f"  python3 tty_overlay.py --mode tty --tty {path} &"
            )

    def send(self, data: bytes) -> None:
        if not data:
            return
        for byte in data:
            try:
                fcntl.ioctl(self.fd, TIOCSTI, bytes([byte]))
            except OSError as exc:
                if exc.errno in (errno.EPERM, errno.EACCES):
                    raise BackendError(
                        "TIOCSTI was denied by the OS. "
                        "Use --mode pty, or run the overlay from the same "
                        "terminal session with the right permissions."
                    ) from exc
                raise BackendError(f"TIOCSTI failed: {exc}") from exc

    def close(self) -> None:
        try:
            os.close(self.fd)
        except OSError:
            pass


class PtyBackend:
    """Spawn a shell in a private PTY and bridge bytes to it."""

    ANSI_RE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")

    def __init__(self, shell: str | None = None):
        import pty

        self.shell = shell or os.environ.get("SHELL") or "/bin/zsh"
        self.master, slave = pty.openpty()

        try:
            fcntl.ioctl(
                self.master,
                termios.TIOCSWINSZ,
                struct.pack("HHHH", 30, 110, 0, 0),
            )
        except OSError:
            pass

        self.pid = os.fork()
        if self.pid == 0:
            # Child: become session leader, attach the slave as controlling TTY.
            try:
                os.close(self.master)
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                os.dup2(slave, 0)
                os.dup2(slave, 1)
                os.dup2(slave, 2)
                if slave > 2:
                    os.close(slave)
                os.execvp(self.shell, [self.shell, "-l"])
            except Exception:
                os._exit(127)

        os.close(slave)
        self.output: queue.Queue[bytes] = queue.Queue()
        self._closed = False
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self) -> None:
        while not self._closed:
            try:
                data = os.read(self.master, 4096)
            except OSError:
                break
            if not data:
                break
            self.output.put(data)

    def send(self, data: bytes) -> None:
        if not data or self._closed:
            return
        try:
            os.write(self.master, data)
        except OSError as exc:
            raise BackendError(f"PTY write failed: {exc}") from exc

    def read_available(self) -> bytes:
        chunks = []
        while True:
            try:
                chunks.append(self.output.get_nowait())
            except queue.Empty:
                break
        return b"".join(chunks)

    def clean_output(self, data: bytes) -> str:
        data = self.ANSI_RE.sub(b"", data)
        return data.decode("utf-8", errors="replace")

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            os.kill(self.pid, signal.SIGHUP)
        except OSError:
            pass
        try:
            os.close(self.master)
        except OSError:
            pass


class DryBackend:
    """Log keys without touching a terminal."""

    def __init__(self):
        self.buffer = bytearray()

    def send(self, data: bytes) -> None:
        self.buffer.extend(data)

    def close(self) -> None:
        pass


# ---------------------------------------------------------------------------
# Key translation
# ---------------------------------------------------------------------------

SPECIAL_KEYS = {
    "Return": b"\r",
    "KP_Enter": b"\r",
    "BackSpace": b"\x7f",
    "Tab": b"\t",
    "Escape": b"\x1b",
    "Up": b"\x1b[A",
    "Down": b"\x1b[B",
    "Right": b"\x1b[C",
    "Left": b"\x1b[D",
    "Home": b"\x1b[H",
    "End": b"\x1b[F",
    "Prior": b"\x1b[5~",   # PageUp
    "Next": b"\x1b[6~",    # PageDown
    "Insert": b"\x1b[2~",
    "Delete": b"\x1b[3~",
    "F1": b"\x1bOP",
    "F2": b"\x1bOQ",
    "F3": b"\x1bOR",
    "F4": b"\x1bOS",
    "F5": b"\x1b[15~",
    "F6": b"\x1b[17~",
    "F7": b"\x1b[18~",
    "F8": b"\x1b[19~",
    "F9": b"\x1b[20~",
    "F10": b"\x1b[21~",
    "F11": b"\x1b[23~",
    "F12": b"\x1b[24~",
}

MODIFIER_KEYS = {
    "Shift_L", "Shift_R",
    "Control_L", "Control_R",
    "Alt_L", "Alt_R",
    "Meta_L", "Meta_R",
    "Super_L", "Super_R",
    "Caps_Lock", "Num_Lock",
    "ISO_Level3_Shift",
}


def key_to_bytes(event: tk.Event) -> bytes:
    """Translate a Tk key event into the bytes a terminal would receive."""
    keysym = event.keysym

    if keysym in MODIFIER_KEYS:
        return b""
    if keysym in SPECIAL_KEYS:
        return SPECIAL_KEYS[keysym]

    char = event.char
    if char:
        # Ctrl+letter normally arrives here as a control character.
        return char.encode("utf-8", errors="replace")

    return b""


def pretty_key(event: tk.Event, data: bytes) -> str:
    """Human-readable label for the keystroke tape."""
    ks = event.keysym
    if ks in ("Return", "KP_Enter"):
        return "⏎"
    if ks == "BackSpace":
        return "⌫"
    if ks == "Tab":
        return "⇥"
    if ks == "Escape":
        return "⎋"
    if ks == "space":
        return "␠"
    if ks == "Up":
        return "↑"
    if ks == "Down":
        return "↓"
    if ks == "Left":
        return "←"
    if ks == "Right":
        return "→"
    if ks in ("Prior",):
        return "⇞"
    if ks in ("Next",):
        return "⇟"
    if ks == "Delete":
        return "⌦"
    if ks == "Home":
        return "↖"
    if ks == "End":
        return "↘"
    if ks.startswith("F") and ks[1:].isdigit():
        return ks

    if len(data) == 1:
        b = data[0]
        if b == 0x03:
            return "^C"
        if b == 0x04:
            return "^D"
        if b == 0x1A:
            return "^Z"
        if b == 0x0C:
            return "^L"
        if 1 <= b <= 26:
            return "^" + chr(ord("A") + b - 1)

    try:
        ch = data.decode("utf-8")
    except UnicodeDecodeError:
        return repr(data)

    if ch == " ":
        return "␠"
    if ch == "\n":
        return "⏎"
    return ch


# ---------------------------------------------------------------------------
# Overlay UI
# ---------------------------------------------------------------------------

class Overlay:
    def __init__(self, backend, target_label: str, output_mode: str, opacity: float, borderless: bool = True):
        self.backend = backend
        self.output_mode = output_mode
        self.capture = False
        self.auto_start = True
        self.sent_bytes = 0
        self._last_activate = 0.0
        self._key_color = None
        self.last_error = ""
        self.pty_tail = ""

        self.root = tk.Tk()
        self.root.title("TTY Overlay")
        self.root.configure(bg="#f8fafc")

        # Borderless by default: no OS title bar. The custom status line is
        # the drag handle. --titlebar restores a normal window for debugging.
        if borderless:
            try:
                self.root.overrideredirect(True)
            except tk.TclError:
                pass

        self.root.update_idletasks()
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        x = max(20, (sw - 820) // 2)
        y = max(80, (sh - 136) // 2)
        self.root.geometry(f"820x160+{x}+{y}")
        self.root.minsize(560, 140)

        try:
            self.root.attributes("-topmost", True)
        except tk.TclError:
            pass
        try:
            self.root.attributes("-alpha", max(0.25, min(1.0, opacity)))
        except tk.TclError:
            pass

        self._build_ui(target_label)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.bind_all("<KeyPress>", self.on_key)
        self.root.after(40, self.poll_output)
        self.root.after(250, self._focus)
        self.root.bind("<FocusIn>", lambda e: (self._log_event("FocusIn", e), self.root.after(80, self._check_focus)))
        self.root.bind("<FocusOut>", lambda e: (self._log_event("FocusOut", e), self.root.after(80, self._check_focus)))
        self.root.after(700, self._check_focus)
        if os.environ.get("TTY_OVERLAY_DEBUG"):
            self.root.after(1000, self._debug_dump)
            self.root.after(1500, self._log_snapshot)

    def _debug_dump(self) -> None:
        print("DEBUG geometry", self.root.winfo_geometry(), flush=True)
        print("DEBUG viewable", self.root.winfo_viewable(), flush=True)
        print("DEBUG status", self.status.winfo_ismapped(), self.status.winfo_width(),
              self.status.winfo_height(), repr(self.status_var.get()), flush=True)
        print("DEBUG key", self.key_entry.winfo_ismapped(), self.key_entry.winfo_width(),
              self.key_entry.winfo_height(), repr(self.key_var.get()), flush=True)
        try:
            print("DEBUG alpha", self.root.attributes("-alpha"), flush=True)
        except tk.TclError:
            pass

    def _log_snapshot(self) -> None:
        if not os.environ.get("TTY_OVERLAY_DEBUG"):
            return
        try:
            with open("/tmp/tty_overlay_events.log", "a") as fh:
                fh.write(
                    f"SNAP t={time.time():.3f} "
                    f"entry.get={self.key_entry.get()!r} "
                    f"key_var={self.key_var.get()!r} "
                    f"hist={self.key_history!r} "
                    f"capture={self.capture} "
                    f"focus={self.root.focus_get()!r} "
                    f"canvas_mapped={self.key_canvas.winfo_ismapped()} "
                    f"canvas_size={self.key_canvas.winfo_width()}x{self.key_canvas.winfo_height()}\n"
                )
        except Exception:
            pass
        self.root.after(1500, self._log_snapshot)

    # -- UI ---------------------------------------------------------------
    def _build_ui(self, target_label: str) -> None:
        bg = "#f8fafc"
        panel = "#eef4ff"
        ink = "#0d1526"
        muted = "#475569"
        faint = "#94a3b8"
        line = "#2563eb"
        blue = "#2563eb"
        green = "#16a34a"
        amber = "#d97706"
        red = "#dc2626"

        self.colors = dict(
            bg=bg, panel=panel, ink=ink, muted=muted, faint=faint,
            line=line, blue=blue, green=green, amber=amber, red=red,
        )

        outer = tk.Frame(self.root, bg=bg, highlightthickness=2,
                         highlightbackground="#35557f")
        outer.pack(fill="both", expand=True)

        # Thin accent line makes the overlay visible even at low opacity.
        self.accent = tk.Frame(outer, bg=blue, height=2)
        self.accent.pack(fill="x", side="top")

        # ---- line 1: status / target / controls -------------------------
        line1 = tk.Frame(outer, bg=panel, height=48)
        line1.pack(fill="x", side="top")
        line1.pack_propagate(False)

        self.dot = tk.Label(
            line1, text="●", bg=panel, fg=amber,
            font=("Helvetica", 11), padx=0,
        )
        self.dot.pack(side="left", padx=(14, 7))

        self.status_var = tk.StringVar(value="CAPTURE OFF")
        self.status = tk.Label(
            line1, textvariable=self.status_var, bg=panel, fg=amber,
            font=("Helvetica", 10, "bold"),
        )
        self.status.pack(side="left")

        self.target_var = tk.StringVar(value=target_label)
        target = tk.Label(
            line1, textvariable=self.target_var, bg=panel, fg=muted,
            font=("Menlo", 9), padx=0,
        )
        target.pack(side="left", padx=(14, 0))

        close_btn = tk.Button(
            line1, text="×", command=self.close,
            bg=panel, fg=faint, activebackground="#dbeafe",
            activeforeground=ink, relief="flat", bd=0,
            font=("Helvetica", 14, "bold"), padx=8, pady=0,
            highlightthickness=0,
        )
        close_btn.pack(side="right", padx=(2, 8))

        self.toggle_btn = tk.Button(
            line1, text="START", command=self.toggle_capture,
            bg="#dbeafe", fg=blue, activebackground="#bfdbfe",
            activeforeground=blue, relief="flat", bd=0,
            font=("Helvetica", 9, "bold"), padx=9, pady=2,
            highlightthickness=0,
        )
        self.toggle_btn.pack(side="right", padx=6)

        self.bytes_var = tk.StringVar(value="0 B")
        bytes_label = tk.Label(
            line1, textvariable=self.bytes_var, bg=panel, fg=faint,
            font=("Menlo", 9), padx=0,
        )
        bytes_label.pack(side="right", padx=(0, 10))

        # ---- line 2: the keystroke tape --------------------------------
        self.key_frame = tk.Frame(outer, bg=bg)
        self.key_frame.pack(fill="both", expand=True)

        keys_tag = tk.Label(
            self.key_frame, text="KEYS", bg=bg, fg=faint,
            font=("Helvetica", 8, "bold"), padx=14,
        )
        keys_tag.pack(side="left")

        self.key_var = tk.StringVar(value="click START (or F8), then type")

        # Hidden, focusable entry. It exists only so Tk gives us keyboard
        # focus; all visible text is drawn on a Canvas below it.
        self.key_entry = tk.Entry(
            self.key_frame, textvariable=self.key_var, bg=bg, fg=bg,
            bd=0, highlightthickness=0, insertbackground=bg,
            width=1,
        )
        self.key_entry.place(x=-1000, y=-1000, width=1, height=1)

        # The visible text layer: dark canvas + bright monospaced text so it
        # cannot be mistaken for part of the window background.
        self.key_canvas = tk.Canvas(
            self.key_frame,
            bg="#0b1220",
            bd=1,
            highlightthickness=2,
            highlightbackground="#2563eb",
            height=80,
        )
        self.key_canvas.pack(side="left", fill="both", expand=True, pady=(0, 10))

        self.key_history: list[str] = []

        # The key line itself is the focusable textbox.
        self.key_entry.bind("<Button-1>", lambda _e: self._focus())
        self.key_entry.bind("<Enter>", lambda _e: self._focus())
        self.key_canvas.bind("<Button-1>", lambda _e: self._focus())
        self.key_canvas.bind("<Enter>", lambda _e: self._focus())

        # Click anywhere in the window to focus it.
        outer.bind("<Button-1>", lambda _e: self._focus())

        # Drag the status line to move the overlay.
        for widget in (line1, self.dot, self.status, target):
            widget.bind("<ButtonPress-1>", self._start_drag)
            widget.bind("<B1-Motion>", self._drag)

        # Clicking the key tape focuses the overlay.
        for widget in (self.key_frame, keys_tag, self.key_entry):
            widget.bind("<Button-1>", lambda _e: self._focus())

        self._drag_x = 0
        self._drag_y = 0
        self._update_capture_ui()

    def _start_drag(self, event: tk.Event) -> None:
        self._focus()
        self._drag_x = event.x_root - self.root.winfo_x()
        self._drag_y = event.y_root - self.root.winfo_y()

    def _drag(self, event: tk.Event) -> None:
        x = event.x_root - self._drag_x
        y = event.y_root - self._drag_y
        self.root.geometry(f"+{x}+{y}")

    def _focus(self) -> None:
        self._activate_app()
        self.root.after(100, self._apply_focus)

    # -- Activation / focus helpers --------------------------------------
    def _activate_app(self, force: bool = False) -> None:
        """Make this process the frontmost application on macOS."""
        now = time.time()
        if force or (now - self._last_activate) > 0.8:
            self._last_activate = now
            try:
                subprocess.Popen(
                    ["osascript", "-e", 'tell application "Python" to activate'],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass

    def _apply_focus(self) -> None:
        try:
            self.root.lift()
            self.root.focus_force()
            self.key_entry.focus_force()
        except tk.TclError:
            pass

    def _log_event(self, label: str, event=None) -> None:
        if not os.environ.get("TTY_OVERLAY_DEBUG"):
            return
        try:
            with open("/tmp/tty_overlay_events.log", "a") as fh:
                fh.write(
                    f"{label} t={time.time():.3f} "
                    f"keysym={getattr(event,'keysym',None)} "
                    f"char={getattr(event,'char',None)!r} "
                    f"state={getattr(event,'state',None)} "
                    f"focus={self.root.focus_get()!r}\n"
                )
        except Exception:
            pass

    # -- Visible key text -------------------------------------------------
    def _render_key_text(self, color=None) -> None:
        if color is None:
            color = self._key_color
        self._key_color = color
        try:
            self.key_canvas.delete("all")
            self.key_canvas.create_text(
                12, 40,
                text=self.key_var.get(),
                anchor="w",
                font=("Menlo", 16, "bold"),
                fill=color,
            )
        except tk.TclError:
            pass

    # -- Capture ----------------------------------------------------------
    def toggle_capture(self) -> None:
        self.capture = not self.capture
        self.auto_start = self.capture
        try:
            self.key_entry.delete(0, "end")
        except tk.TclError:
            pass
        self._update_capture_ui()
        if self.capture:
            self._focus()

    def _check_focus(self) -> None:
        """Start capture when the overlay is focused; stop when it is not."""
        try:
            focused = self.root.focus_get()
        except (KeyError, tk.TclError):
            focused = None

        if focused is None:
            if self.capture:
                self.capture = False
                self._update_capture_ui()
            self.auto_start = True
        elif self.auto_start and not self.capture:
            self.capture = True
            self._update_capture_ui()

    def _key_text(self) -> str:
        if self.capture:
            if self.key_history:
                return "  ".join(self.key_history[-32:]) + "  ▌"
            return "type…  ▌"
        if self.key_history:
            return "  ".join(self.key_history[-32:])
        return "click START (or F8), then type"

    def _update_capture_ui(self) -> None:
        if self.capture:
            self.status_var.set("CAPTURE ON")
            self.status.configure(fg=self.colors["green"])
            self.dot.configure(fg=self.colors["green"])
            self.accent.configure(bg=self.colors["green"])
            self.toggle_btn.configure(text="STOP", bg="#dcfce7", fg=self.colors["green"])
            self._render_key_text("#4ade80")
        else:
            self.status_var.set("CAPTURE OFF")
            self.status.configure(fg=self.colors["amber"])
            self.dot.configure(fg=self.colors["amber"])
            self.accent.configure(bg=self.colors["amber"])
            self.toggle_btn.configure(text="START", bg="#dbeafe", fg=self.colors["blue"])
            self._render_key_text("#c7d2e5")

        self.key_var.set(self._key_text())

    def _set_error(self, message: str) -> None:
        self.last_error = message
        self.capture = False
        self._update_capture_ui()
        self.status_var.set("ERROR")
        self.status.configure(fg=self.colors["red"])
        self.dot.configure(fg=self.colors["red"])
        self.accent.configure(bg=self.colors["red"])
        self.key_var.set(message[:100])
        self.key_entry.configure(fg=self.colors["red"])

    def on_key(self, event: tk.Event) -> str | None:
        self._log_event("Key", event)
        # Global quit: Ctrl+Shift+Q
        ctrl = bool(event.state & 0x4)
        shift = bool(event.state & 0x1)
        if ctrl and shift and event.keysym.lower() == "q":
            self.close()
            return "break"

        if event.keysym == "F8":
            self.toggle_capture()
            return "break"

        if not self.capture:
            return None

        data = key_to_bytes(event)
        if not data:
            return "break"

        try:
            self.backend.send(data)
            self.sent_bytes += len(data)

            label = pretty_key(event, data)
            self.key_history.append(label)
            if len(self.key_history) > 48:
                self.key_history = self.key_history[-48:]

            self.key_var.set(self._key_text())
            self._render_key_text("#4ade80")
            self.bytes_var.set(f"{self.sent_bytes} B")
        except BackendError as exc:
            self._set_error(str(exc))
        return "break"

    # -- PTY output -------------------------------------------------------
    def poll_output(self) -> None:
        if isinstance(self.backend, PtyBackend):
            data = self.backend.read_available()
            if data:
                text = self.backend.clean_output(data).strip()
                if text:
                    # Keep the last non-empty line, for the compact footer.
                    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
                    if lines:
                        self.pty_tail = lines[-1][-90:]
                        if not self.capture and not self.key_history:
                            self.key_var.set(self.pty_tail)
                            self._render_key_text("#c7d2e5")
        self.root.after(40, self.poll_output)

    # -- Close ------------------------------------------------------------
    def close(self) -> None:
        try:
            self.backend.close()
        finally:
            try:
                self.root.destroy()
            except tk.TclError:
                pass


# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

def detect_tty() -> str | None:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            if stream.isatty():
                return os.ttyname(stream.fileno())
        except OSError:
            pass
    return os.environ.get("TTY")


def list_ttys() -> None:
    print("TTYs with login shells / pi:")
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,tty=,comm="],
            capture_output=True, text=True, check=True,
        ).stdout
    except Exception as exc:
        print(f"ps failed: {exc}")
        return

    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3:
            continue
        pid, tty, comm = parts
        if tty == "??":
            continue
        comm = comm.strip()
        if comm in ("pi", "login", "-zsh", "zsh", "bash", "-bash"):
            print(f"  {tty:10s} pid={pid:>7s}  {comm}")

    current = detect_tty()
    print()
    print(f"current detected TTY: {current or '(none — not launched from a terminal)'}")


def check_tty(path: str) -> None:
    print(f"TTY: {path}")
    try:
        st = os.stat(path)
        print(f"  exists: yes   owner uid: {st.st_uid}   mode: {oct(st.st_mode & 0o777)}")
    except OSError as exc:
        print(f"  exists: no ({exc})")
        return

    try:
        fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    except OSError as exc:
        print(f"  open: no ({exc})")
        return

    try:
        print(f"  isatty: {os.isatty(fd)}")
        print(f"  writable: {os.access(path, os.W_OK)}")
        print()
        print("TIOCSTI may still be denied by the OS or the terminal's session.")
        print("If --mode tty fails, use --mode pty (private shell) or --mode dry.")
    finally:
        os.close(fd)


def resolve_tty(value: str) -> str:
    if value and value != "auto":
        return value
    tty = detect_tty()
    if tty:
        return tty
    raise SystemExit(
        "No TTY detected. Pass one explicitly, for example:\n"
        "  python3 tty_overlay.py --tty /dev/ttys007\n"
        "Run `python3 tty_overlay.py --list` to see available TTYs."
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transparent always-on-top key overlay for a TTY.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--mode", choices=("tty", "pty", "dry"), default="tty",
                        help="tty = TIOCSTI into an existing TTY; pty = private shell; dry = log only")
    parser.add_argument("--tty", default="auto",
                        help="TTY path for --mode tty, or 'auto' (default)")
    parser.add_argument("--shell", default=None,
                        help="shell for --mode pty (default: $SHELL)")
    parser.add_argument("--opacity", type=float, default=0.92,
                        help="window opacity 0.25–1.0 (default 0.92)")
    parser.add_argument("--titlebar", action="store_true",
                        help="show a normal OS title bar (useful for debugging visibility)")
    parser.add_argument("--list", action="store_true",
                        help="list TTYs with login shells / pi and exit")
    parser.add_argument("--check", default=None, metavar="TTY",
                        help="check whether a TTY is openable/writable and exit")
    args = parser.parse_args()

    if args.list:
        list_ttys()
        return

    if args.check:
        check_tty(args.check)
        return

    if args.mode == "tty":
        tty = resolve_tty(args.tty)
        try:
            backend = TtyBackend(tty)
        except BackendError as exc:
            raise SystemExit(
                f"{exc}\n\n"
                "Use --mode pty for a private shell, or --mode dry to test the overlay."
            )
        label = f"TTY  {tty}"
        output_mode = "tty"
    elif args.mode == "pty":
        backend = PtyBackend(shell=args.shell)
        label = f"PTY  private shell: {backend.shell}"
        output_mode = "pty"
    else:
        backend = DryBackend()
        label = "DRY RUN  no terminal attached"
        output_mode = "dry"

    Overlay(backend, label, output_mode, args.opacity, borderless=not args.titlebar).root.mainloop()


if __name__ == "__main__":
    main()
