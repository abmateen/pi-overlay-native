# pi-overlay-extension

A small native macOS overlay for [pi](https://github.com/earendil-works/pi) sessions.

It sits above other windows, captures keystrokes while focused, and sends the pending line to the terminal that is running `pi` when you press **Enter**.

The overlay itself is a native **Swift/AppKit** window, not a Tk window. It can
run in two ways: attach to an existing pi session (`tty` mode, started by the pi
extension) or own a headless pi session over pi's [RPC protocol](https://github.com/earendil-works/pi/blob/main/docs/rpc.md)
in a directory you pick (`self` mode, the default when launched on its own).

## What it looks like

```text
TTY /dev/ttys007                pi — my-session          ▾   ⤢   ×
🎤  type a command, then press Enter…
```

In self mode the TTY label is replaced by a directory dropdown, a model
dropdown, and the `pi` RPC child PID, with a row of saved sessions underneath:

```text
👤 daily ▾  [ pi-overlay-extension  × ] [ ● /tmp  × ] [ ✓ api-server  × ]     ＋   ▾   ⤢   ×
📁 pi-overlay-extension ▾   [DeepSeek V4.1 Flash ▾]   pi 42165
Sessions  [fix markdown tables · Oct 24             ▾]  ＋
🎤  type a command, then press Enter…
```

- Typing is always enabled: the overlay only receives keys while its window is
  focused, so there is no separate capture/START toggle.
- The window is resizable: drag any edge or corner. The size is remembered
  between launches. Extra height goes to the Response panel while it is open;
  otherwise the textbox grows with the window.
- **▾** collapses the overlay to just the tabs (32 pt tall) and **▴** restores
  it; **⤢** maximizes the window like the green zoom button (fills the screen,
  keeps the menu bar and Dock, and leaves overlay mode); **×** closes the
  overlay. Leaving maximize (via **⤡** or **▾**) returns to the compact default
  frame — wide enough for the textbox and answer panel — anchored to the bottom
  of the screen. Collapsing while maximized first re-activates overlay mode, so
  the collapsed strip and its restored size use that floating overlay geometry.
  In self mode these live in the tab strip, so they stay reachable while
  collapsed.
- `TTY /dev/ttys007` is the target terminal.
- In self mode, `📁 name ▾` is the working directory dropdown for the active
  tab (recent folders, **Choose Folder…**, Reveal in Finder, **Start/Restart pi**
  when the child is stopped, Close tab).
- `[model ▾]` lists the configured pi models as `provider/model` (the same
  reference pi's `--model` flag takes) and switches the active tab's RPC session
  with `set_model`. The provider's display name is in the item tooltip.
- `pi 42165` is the live RPC child PID for the active tab.
- The **Sessions** row is a dropdown listing the saved conversations for the
  active tab's directory, newest first. Entries show the session name (or the
  first user message) plus a timestamp; the current session is checked. Pick one
  to resume it in the active tab.
- The Chrome-style tab strip at the top shows one tab per independent pi RPC
  session. `●` means processing (red), `✓` done (green), `!` exited. **×** closes
  a tab and **＋** opens a new one.
- The **profile dropdown** is the first control in the tab strip: profiles are
  the parent of tabs. Switching profiles swaps the whole tab strip (each profile
  keeps its own ordered tabs, pinned sessions, and active tab). The outgoing
  profile's tabs are parked in memory and their pi children keep running, so a
  prompt started there finishes while you are in another profile; switching back
  shows the result. Its menu also has New/Rename/Delete Profile (deleting stops
  those children).
- A **menu-bar status icon** mirrors all profiles: an orange hourglass while any
  tab is processing, a green check when the most recent work completed, and a
  neutral terminal when idle. Its menu lists every profile with pending/completed
  counts plus each profile's tabs; pick a profile or tab to switch to it and show
  the overlay. Self mode only.
- The terminal window title is shown next to the TTY.
- The large text area wraps long lines and has a blinking caret.
- The bottom-right status shows **Processing** while the agent is running and **Done** in green when it settles.
- A collapsible **Response** section under the textbox renders the final assistant text as GitHub-flavored Markdown, including headings, tables, lists, code blocks, and emphasis. Thinking/reasoning blocks are excluded.
- A **prompt history** dropdown beside the Response toggle lists the session's previous user prompts (newest first). Pick one to show the answer that followed it; **Latest answer** returns to the most recent turn. The list refreshes after each turn and when a session is loaded or switched. With no selection, the panel always shows the latest answer.

## Controls

| Key / control | Action |
|---|---|
| **Option + V** | Start / stop voice input |
| **Enter** | Send the pending line to the target TTY / pi session |
| **Esc** | Abort the running RPC turn (self mode) |
| **Ctrl + N** | Choose a folder and open (or switch to) a pi session there |
| **Ctrl + T** | New blank tab; choose its project directory |
| **Ctrl + W** | Close the active tab |
| **Cmd + 1…9** | Jump to the 1st…9th tab |
| **Model dropdown** | Switch the active tab's model without restarting pi |
| **Sessions dropdown** | Resume a saved session from this folder in the active tab |
| **＋ next to Sessions** | Start a new conversation in the active tab (like `/new`) |
| **Prompt history dropdown** | Show the answer for a previous user prompt, or **Latest answer** |
| **Profile dropdown** | Switch, create, rename, or delete profiles; each profile owns its tab set |
| **Menu-bar icon** | Pending/completed status across profiles; open a profile/tab or quit |
| **Tab strip** | Switch between independent RPC sessions; **＋** opens a new tab |
| **Cmd + V** | Paste from clipboard |
| **Speak button** 🎤 | Start/stop voice input (bottom-left inside the textbox; same as Option + V) |
| **Backspace** | Edit the pending line |
| **▾ / ▴** in the tab strip | Minimize the overlay to just the tabs / restore it |
| **⤢ / ⤡** | Maximize to the screen's visible area (keeps the menu bar) / restore the overlay |
| **Cmd + M** | Same as **▾ / ▴** |
| **Drag edge or corner** | Resize the overlay; the size is remembered (the Response panel takes extra height while open) |
| **×** | Close the overlay |

The overlay receives keys only while it has focus; there is no separate capture
toggle. It is not a global keylogger.

While minimized, only the tab strip is clickable: text keys are ignored, but tab
switching, **＋**, **▾/▴**, Ctrl+T/Ctrl+W, Ctrl+N and Cmd+M still work.

## Voice input

Click the **Speak** button (microphone icon at the bottom-left inside the
textbox) or press **Option + V** to dictate into the overlay. The transcript
appends to the current pending line; press
**Enter** to send it.

The first use asks macOS for:

- **Microphone** access
- **Speech Recognition** access

If you deny them, enable them in **System Settings → Privacy & Security**.
On-device recognition is used when the installed speech recognizer supports it.

## Requirements

- macOS
- Xcode Command Line Tools (`swiftc`)
- `pi` installed
- A terminal session running `pi` (`tty` mode) or Terminal.app (`self-tui` mode)

## Build

```bash
make
```

This produces:

```text
tty_overlay_native
```

The Markdown response panel also needs:

```text
markdown-it.min.js
```

Keep it next to `tty_overlay_native`.

## Run manually

From a terminal:

```bash
./run_overlay.sh        # tty mode, targeting the current terminal
./tty_overlay_native    # self mode, launches its own pi session
```

`run_overlay.sh` uses the current TTY and starts the overlay in `tty` mode.

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

When installing the extension manually, copy both `tty_overlay_native` and `markdown-it.min.js` into the extension directory.

If the extension is copied away from the binary, set:

```bash
export PI_OVERLAY_BIN=/absolute/path/to/pi-overlay-extension/tty_overlay_native
```

The extension:

- streams newline-delimited JSON events to the overlay through the child process's **stdin**,
- sends `{"type":"status","value":"processing"|"done"}` on agent lifecycle,
- sends the final assistant text as `{"type":"response","text":"..."}`,
- sends the session's prompt/answer pairs as `{"type":"queries","items":[...]}`,
- seeds the response panel and prompt-history dropdown from the current session
  when the overlay starts or the session changes,
- keeps the overlay running when you switch conversations (only `quit` and
  `reload` stop it), and reseeds it on the next `session_start`,
- detects pi's TTY with `ps -o tty= -p <pi-pid>`,
- starts `tty_overlay_native --mode tty --tty /dev/ttysXXX`,
- does **not detach** the child, so it inherits pi's controlling TTY,
- kills any old overlay for that TTY,
- stops the overlay on `session_shutdown`,
- adds a `/overlay` command to start/stop it manually.

It does **not** auto-start on session start.

## Self mode (default, RPC)

Running the binary with no mode argument starts its own pi process:

```bash
./tty_overlay_native                      # pi in the last used directory
./tty_overlay_native --dir ~/code/project # pi in a specific directory
```

The initial directory is resolved from `--dir`, then `PI_OVERLAY_DIR`, then the
last directory used, then the overlay's working directory, then `$HOME`.

### How it works

Each tab spawns its own:

```text
pi --mode rpc
```

with that tab's selected directory as its working directory. Enter sends a
`prompt` command to the active tab's child over stdin. The overlay consumes that
child's JSONL event stream from stdout:

- `agent_start` → **Processing**
- `agent_settled` → **Done** + final Markdown response
- `message_end` → authoritative assistant text
- `get_entries` → active-branch prompt/answer pairs for the prompt-history dropdown
- `extension_ui_request` → confirm / select / input / editor dialogs
- `response(success: false)` → error status

The current model comes from `get_state`; the dropdown is populated from
`get_available_models` (labelled `provider/model`, since pi's `name` field is
sometimes padded with generated ids) and selecting an entry sends `set_model`.
Switching sessions also re-reads the model that session last used. The session,
conversation, and RPC child stay alive; the new model applies to subsequent
turns.

This means no Terminal window, no TIOCSTI, and no Automation or Accessibility
permission. Folder switching and session management happen entirely in the
overlay.

- **Ctrl+T** opens a blank tab and asks for a project directory; the RPC child
  starts only after a directory is selected.- **Ctrl+N** or the folder dropdown opens `NSOpenPanel`; choosing a folder
  focuses an existing tab for that directory or opens a new one.
- Each tab has its own RPC child, input buffer, model state, status, and
  dedicated Markdown response view. Switching tabs preserves all of that.
- The dropdown lists the last 10 directories. Re-selecting a directory that
  already has a tab just switches back to it.
- Use **Close tab** in the dropdown or **Ctrl+W** to stop that tab's RPC child.
  RPC children are also stopped when the overlay exits.
- All tabs are independent: one tab can be processing while another is idle or
  showing a previous result.
- Tabs belong to the active profile and are remembered in
  `~/.config/pi-overlay/profiles.conf` (see below) and restored on the next
  launch. Only the active tab starts a pi child at launch; the others start when
  you first select them. A restored tab resumes its pinned session, or the newest
  session for its directory, so the response panel and the prompt-history
  dropdown are populated with the previous questions immediately.
- pi is found via `PI_OVERLAY_PI`, common Homebrew paths, or the login shell's
  `PATH`.
- The RPC child inherits your login-shell environment, so provider keys exported
  from `.zprofile`/`.zshrc` and Homebrew's `PATH` work even when the overlay is
  launched from Finder.
- Each tab is a separate `pi --mode rpc` process; memory and provider usage
  scale with the number of open tabs.

### Saved sessions row

Under the header row, the overlay lists the saved pi sessions for the active
tab's directory:

- Read from pi's own store: `~/.pi/agent/sessions/--<encoded-cwd>--/*.jsonl`
  (honours `PI_CODING_AGENT_DIR` / `PI_CODING_AGENT_SESSION_DIR`).
- Newest first, capped at the 40 most recent files. Labels use the `/name`
  session title when set, otherwise the first user message; item tooltips have
  the full path and last-activity time.
- The popup shows the current session (checked in the menu). Picking another
  entry sends `switch_session` to that tab's RPC child and shows the resumed
  session's last assistant answer, so you can pick up where you left off.
- The **＋** button right after the popup starts a fresh conversation in the same
  tab and pi process (equivalent to `/new`). It is disabled while there is no
  live pi child and refused while a turn is running (`BUSY — CANNOT START NEW
  SESSION`).
- Switching is refused while a turn is running (`BUSY — CANNOT SWITCH`); abort
  with **Esc** first.
- The list is rescanned when you switch tabs, when a turn settles, and after a
  session switch.

### Profiles and remembered tabs

The overlay is organised like Chrome profiles: every tab belongs to exactly one
profile, and each profile keeps its own ordered tab set, pinned sessions, and
active tab. The **profile dropdown** at the start of the tab strip switches the
whole tab strip at once; its menu also has **New Profile…**, **Rename Profile…**,
and **Delete Profile…**.

Profiles are stored in a plain-text file next to the old tab file:

```text
~/.config/pi-overlay/profiles.conf
```

```text
# pi-overlay: profiles. Each [name] section lists its tabs.
# '*' marks the active tab; 'active' names the profile opened on launch.
active = daily

[daily]
* /Users/me/code/project-a	/Users/me/.pi/agent/sessions/--Users-me-code-project-a--/2026-01-01T10-00-00-000Z_abc.jsonl
  /Users/me/code/project-b

[work]
  /Users/me/code/project-c
```

- `active = name` selects the profile restored at launch. If the name is
  missing, the first profile is used.
- Each `[name]` section owns the tab lines that follow it.
- `*` marks the tab that was active; it is restored as the active tab.
- The optional tab-separated session file is the conversation the tab was last
  viewing (updated when you pick one in the Sessions row and when pi reports the
  active file). Without it, the newest session for the directory is resumed.
- Paths may use `~`. Blank lines and `#` comments are ignored.
- The file is rewritten whenever a profile's tab set or active tab changes.
- Directories that do not exist right now (unmounted volume, deleted project)
  are skipped at launch but kept in the profile so they come back.
- Symlinks are written through, so you can point `profiles.conf` at a dotfiles
  repo.
- Override the location with `PI_OVERLAY_PROFILES=/path/to/profiles.conf`
  (or set `XDG_CONFIG_HOME`).
- On first run, an existing `~/.config/pi-overlay/tabs.conf` (or the file named
  by `PI_OVERLAY_TABS`) is imported into a profile named `default`. After that
  `profiles.conf` is authoritative.
- `--dir` on the command line wins over the remembered tabs.
- Only the restored *active* tab spawns a `pi --mode rpc` child at launch; the
  others start lazily when selected, so restoring ten tabs does not start ten
  pi processes.

### Limitations

Because RPC is headless, the overlay is the pi UI:

- pi's TUI (tool transcript, diffs, keybindings, session browser) is not
  shown. The overlay shows per-tab status, the final assistant response, and a
  per-tab model dropdown.
- TUI-only extension features such as custom terminal components are degraded;
  supported dialogs are forwarded by the overlay.
- Project trust cannot be prompted in RPC mode. Pi uses a saved decision
  (`~/.pi/agent/trust.json`) or `defaultProjectTrust`; otherwise project
  `.pi` settings/extensions are skipped. Use a TUI session to run `/trust`, or
  use `--mode self-tui`.
- The overlay does not expose every pi CLI flag yet (`--model`, `--approve`,
  etc.). Set defaults in pi's configuration or the login environment.

## Self TUI mode (optional)

The previous Terminal-launcher backend is still available:

```bash
./tty_overlay_native --mode self-tui --dir ~/code/project
```

It launches `pi` in a new Terminal.app window and injects keystrokes with
AppleScript/System Events. Use it when you want pi's full TUI visible. It needs
Automation permission (and Accessibility for the fallback).

## Modes

The Swift binary supports:

```bash
# Launch and own a headless RPC pi session in a directory (default)
./tty_overlay_native --mode self --dir ~/code/project

# Launch a pi TUI in Terminal.app and inject keystrokes
./tty_overlay_native --mode self-tui --dir ~/code/project

# TIOCSTI injection into an existing TTY
./tty_overlay_native --mode tty --tty /dev/ttys007

# AppleScript do-script mode, useful when TIOCSTI is unavailable
./tty_overlay_native --mode terminal --tty /dev/ttys007

# Show keys without sending them
./tty_overlay_native --mode dry
```

`tty` mode requires the overlay process to share the target terminal's controlling TTY. The pi extension achieves that by spawning the overlay without detaching.

## Notes

- The original Tk prototype is kept in `legacy/tk_overlay.py` for reference. The supported implementation is the Swift app.
- In `tty` mode, status and final-response text are sent over a pipe (stdin).
- The window frame (size and position) is saved under the `PiOverlayWindow`
  autosave name, so resizing sticks. While the Response panel is open, the
  textbox keeps its normal height and any extra window height goes to the
  panel; when it is collapsed, the textbox takes the full area.
- In `self` mode, status and final-response text come from pi's RPC event stream on stdout and are not stored in `/tmp`.
- The overlay still writes a local debug log to `/tmp/tty_overlay_swift.log` and `/tmp/tty_overlay_events.log` in some builds. These files are not sent anywhere.

## License

MIT
