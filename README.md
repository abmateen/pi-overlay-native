# pi-overlay-native

A small native macOS overlay for [pi](https://github.com/earendil-works/pi) sessions.

It sits above other windows, captures keystrokes while focused, and sends the pending line to the terminal that is running `pi` when you press **Enter**.

The overlay itself is a native **Swift/AppKit** window, not a Tk window. It can
run in two ways: attach to an existing pi session (`tty` mode, started by the pi
extension) or own a headless pi session over pi's [RPC protocol](https://github.com/earendil-works/pi/blob/main/docs/rpc.md)
in a directory you pick (`self` mode, the default when launched on its own).

## What it looks like

The window is a light rounded card with a dark input area and a purple accent.
The top bar holds the profile pill, tabs, **＋**, and an icon cluster on the
right (terminal diagnostics, Response panel, hide, collapse, close). Under it
sit the status pill, folder/model dropdowns and the pi/ssh PID chip, then the
Sessions row and the large prompt card.

```text
[👤 daily ▾] [ ✓ pi-overlay-native × ] [ ● /tmp × ] [ ✓ api-server × ]  ＋      >_  ▤  👁  ▯  ⌄  ×
READY  │  [📁 pi-overlay-native ▾]  [DeepSeek V4.1 Flash ▾]  [pi 42165]
💬 Sessions  [fix markdown tables · Oct 24                    ▾]  ＋
┌────────────────────────────────────────────────────────────────────────┐
│ type…                                                                  │
│  🎤  🖼  📎                                              ⌘ ↵ Send   ✓ Done │
└────────────────────────────────────────────────────────────────────────┘
 ▸ Response  │  [Latest answer ▾]  💡                           ⧉   ⤓   ⤢
```

In tty mode the label row shows the target terminal and window title instead of
the folder/model controls.

### Compact textbox mode

The **▯** button in the top-right cluster hides the whole interface except one
capsule-shaped prompt on a transparent window: mic, text, `pi`/`ssh` pid, and
the Send/Cancel pill. Above the capsule's right end sit an **eye** button (hide
the overlay; reopen it from the menu-bar icon) and a **⤢** button that brings the
full overlay back. A small translucent caption above the capsule names the
profile and tab the prompt will go to (e.g. `localllm · pi-overlay-native`). The
capsule opens bottom-centre on the current screen, with a 28 pt gap above the
Dock/screen edge, and returns to the previous window frame when you restore.
Enter sends, Shift+Enter inserts a newline, Esc cancels the running turn, and
the pi sessions, tabs and prompt keep running normally.
Drag the transparent strip above the capsule (or the capsule background) to
move it.

- Typing is always enabled: the overlay only receives keys while its window is
  focused, so there is no separate capture/START toggle.
- The window is resizable: drag any edge or corner. The size is remembered
  between launches; on a fresh launch it opens at 900 × 695 pt (clamped to the
  screen), anchored to the bottom of the visible area. Extra height goes to the
  Response panel while it is open; otherwise the textbox grows with the window.
- The top-right icon cluster is **>_ diagnostics**, **▤ Response**, **👁 hide**,
  **▯ compact**, **⌄/⌃ collapse/restore** and **× close**. **⌄** shrinks the overlay to just the
  top bar (56 pt tall); **👁** hides the window — it keeps its size, position,
  prompt and running pi sessions, and comes back from **Show Overlay** in the
  menu-bar icon's menu; **×** closes the overlay. In self mode these live in the
  top bar, so they stay reachable while collapsed.
- `TTY /dev/ttys007` is the target terminal.
- In self mode, `📁 name ▾` is the working directory dropdown for the active
  tab (recent folders, **Choose Folder…**, Reveal in Finder, **Start/Restart pi**
  when the child is stopped, Close tab).
- `[model ▾]` lists the configured pi models as `provider/model` (the same
  reference pi's `--model` flag takes) and switches the active tab's RPC session
  with `set_model`. The provider's display name is in the item tooltip. The
  **↻** button beside it re-reads `get_available_models` (useful after changing
  provider configuration) and spins while the request is in flight.
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
- A **menu-bar status icon** (a bold π) mirrors all profiles: an orange π while
  any tab is processing, a green π when the most recent work completed, and a
  neutral template π when idle (it follows the menu-bar appearance). Its menu
  lists every profile with pending/completed
  counts plus each profile's tabs; pick a profile or tab to switch to it and
  show the overlay. Its **Show Overlay** item also brings back a hidden window,
  and it is installed in every mode so hiding is never a one-way trip.
- The terminal window title is shown next to the TTY.
- The large text area is a real text box: the caret, arrow keys, selection, mouse placement, undo, cut/copy/paste and word wrap are the native macOS ones.
- The bottom-right status shows **Processing** while the agent is running and **Done** in green when it settles.
- A collapsible **Response** section under the textbox renders the final assistant text as GitHub-flavored Markdown, including headings, tables, lists, code blocks, and emphasis. Thinking/reasoning is hidden by default (use the 💡 toggle). Provider errors, request timeouts and failed prompt commands are shown here too (as a **Request failed** block with the provider message) and in the prompt history; automatic retries show a **Request failed — retrying n/m** notice instead of leaving the panel blank. The rendered answer is selectable; Ctrl+C or Cmd+C copies the selection, or the whole response when nothing is selected. The **💡 thinking** toggle next to the prompt-history dropdown shows the model's visible reasoning: while a turn is generating it streams live under **Thinking**, followed by the partial answer under **Response**, and the finished turn keeps both.
- A **prompt history** dropdown beside the Response toggle lists the session's previous user prompts (newest first). Pick one to show the answer that followed it; **Latest answer** returns to the most recent turn. The list refreshes after each turn and when a session is loaded or switched. With no selection, the panel always shows the latest answer.

## Controls

| Key / control | Action |
|---|---|
| **Option + V** | Start / stop voice input |
| **Enter** | Send the pending line to the target TTY / pi session |
| **Shift + Enter** | Insert a line break instead of sending |
| **Esc** | Abort the running RPC turn (self mode) |
| **Ctrl + N** | Choose a folder and open (or switch to) a pi session there |
| **Ctrl + T** | New blank tab; choose its project directory |
| **Ctrl + W** | Close the active tab |
| **Cmd + 1…9** | Jump to the 1st…9th tab |
| **Model dropdown** | Switch the active tab's model without restarting pi |
| **↻ model refresh** | Reload the available model list from pi (next to the model dropdown) |
| **Sessions dropdown** | Resume a saved session from this folder in the active tab |
| **Connect to Remote Host…** | Folder dropdown → run `pi --mode rpc` on another machine over SSH (see [Remote sessions](#remote-sessions-ssh)) |
| **＋ next to Sessions** | Start a new conversation in the active tab (like `/new`) |
| **Prompt history dropdown** | Show the answer for a previous user prompt, or **Latest answer** |
| **Profile dropdown** | Switch, create, rename, or delete profiles; each profile owns its tab set |
| **Menu-bar icon** | Pending/completed status across profiles; **Show Overlay**, open a profile/tab, or quit |
| **Tab strip** | Switch between independent RPC sessions; **＋** opens a new tab |
| **Cmd + V** | Paste at the caret (leading/trailing newlines are trimmed) |
| **Cmd + C / X / A** | Copy, cut, select all in the pending line |
| **Cmd + Z / Shift + Cmd + Z** | Undo / redo edits in the pending line |
| **Speak button** 🎤 | Start/stop voice input (bottom-left inside the textbox; same as Option + V) |
| **Arrows / click / drag** | Move the caret, place it with the mouse, or select text |
| **Backspace** | Delete the character or selection before the caret |
| **▯ (compact)** | Shrink the overlay to a single rounded textbox on a transparent window; the **⤢** button above it restores the full UI |
| **⌄ / ⌃** in the top bar | Minimize the overlay to just the top bar / restore it |
| **👁 (hide)** | Hide the window only; reopen it with **Show Overlay** from the menu-bar icon |
| **>_ (diagnostics)** | Show the debug log, open `profiles.conf`, or open pi's agent folder |
| **Send / Cancel** (⌘ ↵) | Send the pending prompt (same as Return). While a turn is running the same pill becomes **■ Cancel** and aborts it (same as Esc) |
| **🖼 (image)** and **📎 (attach)** | Attach images to the next prompt, or insert file paths into it |
| **💡 (thinking)** | Show/hide visible reasoning for the current answer; streams live while the turn is generating |
| **Ctrl+C / Cmd+C in Response** | Copy the selected text from the rendered answer; with no selection, copy the whole response (including thinking when enabled) |
| **Response icons** | Copy the answer (with thinking when enabled), save it as Markdown, or expand/collapse the panel |
| **Notification click** | Brings the overlay back on the tab whose turn finished |
| **Cmd + M** | Same as **▾ / ▴** |
| **Drag edge or corner** | Resize the overlay; the size is remembered (the Response panel takes extra height while open) |
| **×** | Close the overlay |

The overlay receives keys only while it has focus; there is no separate capture
toggle. It is not a global keylogger.

### Slash commands

Typing `/` opens a small floating command list above the prompt card. For now
it contains the discoverable **skills**, the **MCP** command, `/name`, and
`/reload`:

- `/skill` or `/skill:` lists the available `skill:name` commands; keep typing
  to filter.
- `/mcp` runs pi's MCP command. Its status notifications are collected briefly
  and shown in a small **MCP** sheet (RPC mode prints status instead of
  opening the TUI manager).
- `/name [name]` renames the current session; with no argument it opens a small
  name sheet. The new name is stored through `set_session_name` and is used by
  the session store/listings.
- `/reload` restarts the active tab's pi RPC process, resuming the same session
  file, so extensions, skills, prompt templates, models and configuration are
  re-read. It is refused while a turn is running (`BUSY — CANNOT RELOAD`).
- Up/Down moves the selection, Tab or Return accepts, Esc closes the list.
  Selecting a skill inserts `/skill:name ` so arguments can be added; an
  exactly typed command runs immediately.
- The list is fetched from pi with `get_commands`, so it matches the extensions,
  prompt templates and skills loaded in the session. Other command types and
  built-in TUI commands are intentionally not listed yet.

While minimized, only the top bar is clickable: text keys are ignored, but tab
switching, **＋**, **⌄/⌃**, Ctrl+T/Ctrl+W, Ctrl+N and Cmd+M still work.

## Notifications

While the overlay is hidden, every finished turn posts a system notification:
the title is the tab's name (the folder it runs in) and the body is simply
"Update is available under the tab". No answer text is copied into the
notification — clicking it reopens the overlay on that tab (switching profile
first if the tab belongs to another one). Nothing is posted while the window is
visible, and hiding does not lose anything — the notification is only a way
back.

The first notification asks macOS for permission for **pi-overlay-native**. Allow it
once; if the prompt was dismissed, enable it later under **System Settings →
Notifications → pi-overlay-native**.

Notifications are posted by a small helper app, `PiOverlayNotifier.app`
(`notifier.swift`), because a process spawned by the pi extension is not
allowed to use UserNotifications itself. `make install-notifier` puts it in
`~/Applications` and registers it with LaunchServices; the overlay looks for it
there (then next to its own binary, then in `$PI_OVERLAY_NOTIFIER`). Without the
helper, hiding still works — only the notification is skipped, and the debug log
says so.

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
- Key-based SSH access to any remote host you want to use in a remote tab

## Build

```bash
make
```

This produces:

```text
pi-overlay-native
```

Notifications need the helper app, which has to live in a stable location for
macOS to let it ask for permission:

```bash
make install-notifier    # builds PiOverlayNotifier.app and installs it in ~/Applications
```

The Markdown response panel also needs:

```text
markdown-it.min.js
```

Keep it next to `pi-overlay-native`.

## Run manually

From a terminal:

```bash
./run_overlay.sh        # tty mode, targeting the current terminal
./pi-overlay-native    # self mode, launches its own pi session
```

`run_overlay.sh` uses the current TTY and starts the overlay in `tty` mode.

## Use as a pi extension

Load it directly:

```bash
pi --extension /absolute/path/to/pi-overlay-native/extension.ts
```

Or install it as a project extension:

```bash
mkdir -p .pi/extensions
cp /absolute/path/to/pi-overlay-native/extension.ts .pi/extensions/pi-overlay-native.ts
```

When installing the extension manually, copy both `pi-overlay-native` and `markdown-it.min.js` into the extension directory.

If the extension is copied away from the binary, set:

```bash
export PI_OVERLAY_BIN=/absolute/path/to/pi-overlay-native/pi-overlay-native
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
- starts `pi-overlay-native --mode tty --tty /dev/ttysXXX`,
- does **not detach** the child, so it inherits pi's controlling TTY,
- kills any old overlay for that TTY,
- stops the overlay on `session_shutdown`,
- adds a `/overlay` command to start/stop it manually.

It does **not** auto-start on session start.

## Self mode (default, RPC)

Running the binary with no mode argument starts its own pi process:

```bash
./pi-overlay-native                      # pi in the last used directory
./pi-overlay-native --dir ~/code/project # pi in a specific directory
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
  scale with the number of open tabs. A remote tab's child is `ssh`, which
  carries the same JSONL protocol to a `pi --mode rpc` on the other machine.

### Remote sessions (SSH)

A tab can drive pi on another machine instead of this Mac. pi's RPC protocol has
no socket, so the overlay runs

```text
ssh -T -o BatchMode=yes host -- sh -lc 'exec pi --mode rpc …'
```

as the tab's child. Its stdin/stdout are the remote pi's stdin/stdout, which is
exactly what a local tab already talks to. Everything about the session — pi's
configuration, `auth.json`, project `.pi` files, shell tools, working directory
and session store — stays on the remote machine.

Open one from the folder dropdown → **Connect to Remote Host…**. This is two
steps:

1. Enter a `~/.ssh/config` alias or `user@host` (optional `:port`) and press
   **Connect**. The overlay runs one SSH round trip (`pwd -P` + `command -v pi`)
   and reports auth/host-key/PATH problems before anything else happens.
2. A **folder browser** opens at the remote home (or the last folder used on
   that host). Double-click a folder or use **Enter** to go in, **↑ Up** to go
   back, and **Open Folder** to use the current directory. The path field at the
   top is always editable, so you can paste an absolute path or `~/…` directly
   (the `~` is expanded on the remote side, not on the Mac).

Remote folders are remembered in the dropdown with a ☁ and saved in
`profiles.conf` as

```text
ssh://user@host:2222/absolute/path	/absolute/path/to/session.jsonl
```

Tabs show `☁ name` in the tab strip, the window title includes `host:path`, and
the header PID is the local `ssh` client (the remote pi PID is not visible from
the Mac). The Sessions row is read from the remote
`~/.pi/agent/sessions/--<encoded-cwd>--/*.jsonl` store over a single batched SSH
call; the model dropdown, streaming status, Markdown response, prompt history,
session switching, `/new`, dialogs and abort all work unchanged.

Environment and credentials:

- The remote pi inherits the **remote** login shell's environment
  (`sh -lc`, or the executable in `PI_OVERLAY_REMOTE_SHELL`, e.g. `zsh`). It never
  receives the Mac's environment or provider keys.
- Credentials come from the remote `~/.pi/agent/auth.json` (run `/login` there)
  or from variables exported in the remote login profile (prefer `.zshenv` /
  `.zprofile`, which login shells read).
- SSH runs with `-T` (no pty, so stdout stays raw JSONL) and `BatchMode=yes` (no
  password prompts; a GUI app has no terminal). Accept a host key once in
  Terminal (`ssh host`) before using it here.
- SSH agent forwarding is **not** enabled. If the remote needs git-over-ssh,
  give it its own key rather than exposing the Mac's agent.

Tuning:

| Variable | Effect |
|---|---|
| `PI_OVERLAY_SSH` | ssh executable (default `/usr/bin/ssh`) |
| `PI_OVERLAY_REMOTE_SHELL` | remote shell used to load the login environment (default `sh`) |
| `PI_OVERLAY_REMOTE_PI` | absolute path to `pi` on the remote (skips the PATH lookup) |
| `PI_OVERLAY_SSH_CONTROL=0` | disable SSH connection sharing (`ControlMaster`) |

Remote limitations:

- The overlay cannot attach to a `pi --mode rpc` that is already running in a
  remote terminal. It starts its own remote RPC process and resumes the same
  session file; two front-ends on one session file behave like two local tabs.
- A dropped SSH connection ends that tab's remote pi (stdin EOF). Open the
  location again and pick the session in the Sessions row to continue.
- Remote entries in `profiles.conf` must use absolute paths; the connect sheet
  writes them that way. A hand-edited `~/…` remote path is kept but not started.
- The remote `pi` must be startable without prompts and already configured for
  its models and credentials.

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
  session switch. For remote tabs the same list is read from the remote host
  over SSH (see [Remote sessions](#remote-sessions-ssh)).

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
  active file). Without it, the newest session for the directory is resumed
  (local tabs; remote tabs start a new conversation unless pinned).
- Paths may use `~`. Blank lines and `#` comments are ignored.
- Remote tabs are written as `ssh://[user@]host[:port]/absolute/path` (for
  example `* ssh://me@192.168.1.21/srv/app`); the session column is the absolute
  path on that host. Plain paths are local tabs.
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
./pi-overlay-native --mode self-tui --dir ~/code/project
```

It launches `pi` in a new Terminal.app window and injects keystrokes with
AppleScript/System Events. Use it when you want pi's full TUI visible. It needs
Automation permission (and Accessibility for the fallback).

## Modes

The Swift binary supports:

```bash
# Launch and own a headless RPC pi session in a directory (default)
./pi-overlay-native --mode self --dir ~/code/project

# Launch a pi TUI in Terminal.app and inject keystrokes
./pi-overlay-native --mode self-tui --dir ~/code/project

# TIOCSTI injection into an existing TTY
./pi-overlay-native --mode tty --tty /dev/ttys007

# AppleScript do-script mode, useful when TIOCSTI is unavailable
./pi-overlay-native --mode terminal --tty /dev/ttys007

# Show keys without sending them
./pi-overlay-native --mode dry
```

`tty` mode requires the overlay process to share the target terminal's controlling TTY. The pi extension achieves that by spawning the overlay without detaching.

## Notes

- The app and binary are **pi-overlay-native**. Internal identifiers intentionally
  keep the older `pi-overlay` name — `~/.config/pi-overlay`, the
  `PI_OVERLAY_*` environment variables, the `com.abmateen.pi-overlay` bundle
  ID, and `PiOverlayNotifier.app` — so existing profiles, scripts and macOS
  permissions keep working.
- The original Tk prototype is kept in `legacy/tk_overlay.py` for reference. The supported implementation is the Swift app.
- In `tty` mode, status and final-response text are sent over a pipe (stdin).
- The window frame (size and position) is saved under the `PiOverlayWindow`
  autosave name, so resizing sticks. While the Response panel is open, the
  textbox keeps its normal height and any extra window height goes to the
  panel; when it is collapsed, the textbox takes the full area.
- In `self` mode, status and final-response text come from pi's RPC event stream on stdout and are not stored in `/tmp`.
- The overlay still writes a local debug log to `/tmp/pi-overlay-native.log` and `/tmp/tty_overlay_events.log` in some builds. These files are not sent anywhere.

## License

MIT
