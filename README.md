# pi-overlay-extension

A small native macOS overlay for [pi](https://github.com/earendil-works/pi) sessions.

It sits above other windows, captures keystrokes while focused, and sends the pending line to the terminal that is running `pi` when you press **Enter**.

The overlay itself is a native **Swift/AppKit** window, not a Tk window. A small pi extension starts and stops it with the session.

## What it looks like

```text
CAPTURE ON     TTY /dev/ttys007     pi — my-session     START  ×
type a command, then press Enter…
```

- `CAPTURE ON/OFF` shows capture state.
- `TTY /dev/ttys007` is the target terminal.
- The terminal window title is shown next to the TTY.
- The large text area wraps long lines and has a blinking caret.
- The bottom-right status shows **Processing** while the agent is running and **Done** in green when it settles.

## Controls

| Key / control | Action |
|---|---|
| **Option + Space** | Start / stop capture |
| **Option + V** | Start / stop voice input |
| **Enter** | Send the pending line to the target TTY |
| **Backspace** | Edit the pending line |
| **START** | Start / stop capture |
| **×** | Close the overlay |

The overlay captures keys only while it has focus. It is not a global keylogger.

## Voice input

Click **MIC** or press **Option + V** to dictate into the overlay. The transcript
appends to the current pending line; press **Enter** to send it.

The first use asks macOS for:

- **Microphone** access
- **Speech Recognition** access

If you deny them, enable them in **System Settings → Privacy & Security**.
On-device recognition is used when the installed speech recognizer supports it.

## Requirements

- macOS
- Xcode Command Line Tools (`swiftc`)
- A terminal session running `pi`

## Build

```bash
make
```

This produces:

```text
tty_overlay_native
```

## Run manually

From a terminal:

```bash
./run_overlay.sh
```

This uses the current TTY and starts the overlay in `tty` mode.

## Use as a pi extension

Load it directly:

```bash
pi --extension /absolute/path/to/pi-overlay-extension/extension.ts
```

Or install it as a project extension:

```bash
mkdir -p .pi/extensions
cp /absolute/path/to/pi-overlay-extension/extension.ts .pi/extensions/tty-overlay.ts
```

If the extension is copied away from the binary, set:

```bash
export PI_OVERLAY_BIN=/absolute/path/to/pi-overlay-extension/tty_overlay_native
```

The extension:

- writes `/tmp/pi-overlay-<tty>.status` on `agent_start` / `agent_settled`,
- detects pi's TTY with `ps -o tty= -p <pi-pid>`,
- starts `tty_overlay_native --mode tty --tty /dev/ttysXXX`,
- does **not detach** the child, so it inherits pi's controlling TTY,
- kills any old overlay for that TTY,
- stops the overlay on `session_shutdown`,
- adds a `/overlay` command to start/stop it manually.

It does **not** auto-start on session start.

## Modes

The Swift binary supports:

```bash
# TIOCSTI injection into an existing TTY
./tty_overlay_native --mode tty --tty /dev/ttys007

# AppleScript do-script mode, useful when TIOCSTI is unavailable
./tty_overlay_native --mode terminal --tty /dev/ttys007

# Show keys without sending them
./tty_overlay_native --mode dry
```

`tty` mode requires the overlay process to share the target terminal's controlling TTY. The pi extension achieves that by spawning the overlay without detaching.

## Why Option+Space?

macOS does not deliver a standalone key event for a bare **Option** press to this overlay. It does deliver `Option + Space` as a normal key event, so that is used as the toggle chord.

## Notes

- The original Tk prototype is kept in `legacy/tk_overlay.py` for reference. The supported implementation is the Swift app.
- The overlay writes a local debug log to `/tmp/tty_overlay_swift.log` and `/tmp/tty_overlay_events.log` in some builds. These files are not sent anywhere.

## License

MIT
