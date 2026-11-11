# Plan: `self` mode + directory picker (`Ctrl+N`)

> **Status:** M1a and M1b implemented (`tty_overlay.swift`, `Info.plist`, README).
> M2 was replaced by the RPC backend: `--mode self` now spawns `pi --mode rpc`
> and drives status/response directly from the JSONL event stream. The Terminal
> launcher remains available as `--mode self-tui`.

## 1. Goal

Make the overlay usable as a standalone app:

- Launching `tty_overlay_native` **without** `--mode` starts a pi process itself,
  in a directory the user picks. That becomes `--mode self`.
- The overlay header gets a **directory dropdown** (current dir + recents +
  "Choose Folder…").
- **Ctrl+N** opens a native folder chooser (`NSOpenPanel`), then opens a pi
  session in the chosen directory.
- Existing `--mode tty` integration (pi extension) keeps working exactly as-is.

Non-goals for this change: embedding a terminal emulator in the overlay,
Windows/Linux support, replacing the pi TUI.

## 2. Interpretation of "self"

"`tty`" means *the overlay injects into a pi session that already exists in
some terminal's TTY*. "`self`" means *the overlay owns the pi session*: it
launches `pi` in a directory, remembers that session, and targets it.

Because a GUI-launched overlay does not share the new terminal's controlling
TTY, TIOCSTI is not available for those sessions. `self` mode therefore needs
its own injection path (AppleScript into Terminal.app, with TIOCSTI as a
best-effort fast path when it *does* share the TTY).

Two sub-phases:

| Phase | Capability |
|---|---|
| **M1** | Launch pi in a chosen directory, dropdown + Ctrl+N, input injection works, session switching |
| **M2** | Superseded: `--mode self` now uses pi's RPC protocol directly. `--mode self-tui` keeps the Terminal launcher. |

M1 is independently useful; M2 restores feature parity with `tty` mode.

## 3. UX spec

### 3.1 Mode / CLI

```
tty_overlay_native                       -> self (changed)
tty_overlay_native --mode self           -> self
tty_overlay_native --mode self --dir ~/x -> self, initial dir ~/x
tty_overlay_native --mode tty --tty ...  -> unchanged (extension path)
tty_overlay_native --mode dry            -> unchanged debug mode
```

Initial directory resolution order:

1. `--dir <path>` / `--dir=<path>`
2. `PI_OVERLAY_DIR`
3. last directory used (UserDefaults)
4. current working directory of the overlay process
5. `$HOME`

### 3.2 Header

Self mode header row:

```
CAPTURE OFF   [ repo-name ▾ ]   TTY /dev/ttys012   [MIC] [START] [×]
```

- The dropdown title = last path component of the active directory, tooltip =
  full path. Width flexes; truncate middle.
- Menu contents:
  - ✓ active directory
  - separator
  - recent directories (max 10, missing ones pruned lazily)
  - separator
  - **Choose Folder…   ⌃N**
  - **Reveal in Finder**
  - **Close pi session** (closes the Terminal window the overlay created)
- In `tty` / `dry` mode the dropdown is hidden and the old TTY + window-title
  labels are used, so existing users see no change.

### 3.3 Keys

| Key | Action |
|---|---|
| **Ctrl+N** | Folder chooser → launch/switch to a pi session in that dir |
| **Ctrl+Shift+N** (optional) | Same, but always starts a *new* session even if one exists for that dir |
| Enter / Option+Space / Cmd+V | unchanged |

`Ctrl+N` is handled before the `guard isCapturing`, so it works whether or not
capture is on. Reserve it: it must never be appended to `rawText`.

### 3.4 Switching sessions

- Sessions are kept alive (the Terminal window stays open). Selecting a
  directory creates a session only if none exists for that real path,
  otherwise it just retargets.
- The overlay's `injector` becomes the new session's injector; `ttyPath`,
  `targetLabel` and status reset.
- Closing the overlay leaves pi sessions running (data safety). The menu item
  "Close pi session" explicitly closes the Terminal window the overlay opened.
- On app quit, leave sessions running; only close if
  `PI_OVERLAY_CLOSE_ON_QUIT=1` (opt-in).

## 4. Architecture

```text
        Ctrl+N / dropdown
               │
               ▼
      DirectoryStore  ──────► UserDefaults (lastDir, recents)
               │
               ▼
         PiLauncher ─────────► Terminal.app (AppleScript do script)
               │                     │
               │◄──── tty + window id┘
               ▼
        SessionRegistry [URL: PiSession]
               │
               ▼
      activeInjector.send(text)
       1. TtyInjector        (if overlay shares controlling TTY)
       2. TerminalInjector   (AppleScript do script into that tab)
       3. AppleScriptInjector(System Events keystroke)
```

M2 adds:

```text
pi session (with overlay extension)
        │  NDJSON over AF_UNIX SOCK_STREAM
        ▼
overlay socket server  ->  handleIPCEvent(status/response)
```

## 5. File-by-file changes

### 5.1 `tty_overlay.swift`

#### a. Mode + argument parsing (lines 34–40, 1053–1081)

```swift
enum Mode {
    case dry
    case tty
    case apple
    case terminal
    case selfHost          // "self"; `self` is a Swift keyword
}

func parseArgs() -> (Mode, String?, String?)   // (mode, ttyPath, directory)
```

- Change default `var mode: Mode = .selfHost`.
- Parse `--mode self` (also accept `self-host` internally if desired).
- Parse `--dir` / `--dir=`.
- Keep `tty` fallback to `controllingTTY()`.
- Log the resolved directory.

#### b. `DirectoryStore` (new, ~60 lines)

- `lastDirectory: URL?`, `recents: [URL]` in `UserDefaults.standard`
  (bundle id `com.abmateen.pi-overlay`).
- `func resolveInitialDirectory(cliDir: String?) -> URL`
- `func addRecent(_ url: URL)` — dedupe by resolved path, cap 10, drop
  nonexistent entries when reading.
- `func normalize(_ raw: String) -> URL?` — expand `~`, standardize, verify
  `isDirectory`.

#### c. `PiLauncher` + `PiSession` (new, ~150 lines)

```swift
struct PiSession {
    let directory: URL
    var ttyPath: String?
    let terminalWindowId: String?   // AppleScript id of Terminal window
    let tabIndex: Int?
    let startedAt: Date
}

final class PiLauncher {
    func resolvePiBinary() -> String?   // cached
    func launch(in directory: URL,
                socketPath: String?,
                completion: @escaping (Result<PiSession, Error>) -> Void)
    func close(_ session: PiSession)
}
```

- **Resolve pi binary**: `Process` running
  `/bin/zsh -lc 'command -v pi'` (GUI apps get a minimal `PATH`), then
  `PI_OVERLAY_PI`, `/opt/homebrew/bin/pi`, `/usr/local/bin/pi`,
  `~/.local/bin/pi`.
- **Launch** via `NSAppleScript`:

  ```applescript
  tell application "Terminal"
      activate
      set newTab to do script "cd '…' && exec '…/pi'"
      return {id of front window, tty of newTab}
  end tell
  ```

  - Shell-quote the directory and binary (single quotes + `'\''`), then
    AppleScript-quote (`\` and `"`, strip newlines). Directory names with
    spaces/quotes are the main risk here — cover them in tests.
  - `do script` without `in` opens a new window, which is what we want.
  - If `tty of newTab` is empty initially, retry 5× 100 ms.
- If Terminal.app automation is denied / fails, fall back to
  `Process` + `/usr/bin/open -a Terminal <dir>` and record the session with
  `ttyPath == nil`; input then goes through System Events keystroke.
- M2 only: prefix the command with
  `PI_OVERLAY_SOCKET=… PI_OVERLAY_SELF=1` and, if needed,
  `--extension <abs path to extension.ts>`.

#### d. Injector abstraction

Existing `TtyInjector`, `AppleScriptInjector`, `terminalInjector` stay.
Add a small selector:

```swift
enum InjectorKind { case tty(TtyInjector), terminal(AppleScriptInjector), keystroke(AppleScriptInjector) }

func injector(for session: PiSession) -> InjectorKind?
```

Selection at send time:

1. If `session.ttyPath == controllingTTY()`, use `TtyInjector` (no permissions).
2. Else if we launched the Terminal window, use `sendTerminalScript(text)`
   (Automation permission once).
3. Else `sendText` + `sendKey(36)` via System Events (Accessibility permission).

Fix the existing `.apple` branch while here: it currently sends only Return and
never sends `chunk`; self mode must send `chunk` + Return.

#### e. `OverlayController` UI (init ~427, `layoutViews` ~740)

- Add `let directoryPopup: NSPopUpButton` (hidden unless `.selfHost`).
- Add `private let launcher = PiLauncher()`,
  `private let directories = DirectoryStore()`,
  `private var sessions: [String: PiSession] = [:]`,
  `private var activeDirectory: URL`.
- In `.selfHost`, `ttyPath` is nil at init; `injector` fields become optional
  and are rebuilt when a session is activated. Keep the `let` fields for
  `tty` mode and add `var activeInjector` for self mode.
- `window.title` = `"pi · <dir>"` in self mode.
- `rebuildDirectoryMenu()`: clear, add active + recents + actions; each item
  carries `representedObject`/`tag` with the path; use
  `NSMenuItem.target/action`.
- `@objc chooseDirectory()`:

  ```swift
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.canCreateDirectories = true
  panel.prompt = "Open pi here"
  panel.directoryURL = activeDirectory
  NSApp.activate(ignoringOtherApps: true)
  panel.beginSheetModal(for: window) { response in … }
  ```

  On `.OK`: `switchSession(to: url)`.
- `switchSession(to:)`: normalize → look up registry → if absent call
  `launcher.launch` → on success store, `directories.addRecent`, update labels,
  popup, `isCapturing` stays as-is (do **not** silently inject the pending
  line into a different session; clear `rawText`/`tape` on switch).
- On first launch (`.selfHost`), call `switchSession` in
  `applicationDidFinishLaunching` / after window setup, using the initial dir.
- `layoutViews`: replace the fixed `targetLabel`/`terminalTitleLabel` frames
  with the popup when self mode; widen/shrink responsively.
- `toggleCapture`: if self mode and no active session yet, launch first,
  then open injector; on injection failure show `SEND ERROR` and try the next
  backend before giving up.
- `closeApp` / `windowWillClose`: close injector fds as today; do not terminate
  sessions.

#### f. Key handling (`handleKeyDown`, ~902)

Insert before `guard isCapturing`:

```swift
if event.modifierFlags.contains(.control),
   event.charactersIgnoringModifiers?.lowercased() == "n" {
    chooseDirectory()
    return
}
```

(Use `keyCode == 45` as a fallback check; don't rely only on characters when
Control changes them.)

#### g. M2: status/response socket

- `OverlayIPCServer` (new, ~100 lines): create `AF_UNIX` `SOCK_STREAM` at
  `~/Library/Application Support/pi-overlay/<uid>-<pid>.sock`, `listen`,
  accept on a background queue, read NDJSON, dispatch to `handleIPCEvent` on
  main. Delete stale socket on start/exit; `chmod 0600`.
- Keep the existing stdin reader for the extension-spawned `tty` mode.
- Pass `PI_OVERLAY_SOCKET` (and `PI_OVERLAY_SELF=1`) to the launched shell.

### 5.2 `extension.ts`

- On load, if `process.env.PI_OVERLAY_SOCKET` is set:
  - do **not** spawn an overlay for the session;
  - connect to the socket (`node:net`), send `agent_start` / `message_end` /
    `agent_settled` as the same NDJSON events the stdin channel uses;
  - `/overlay` still spawns a tty overlay for this session (manual override),
    but must not loop if already connected.
- Existing default path unchanged: `spawn(binary, ["--mode","tty","--tty",tty])`.
- Add a short reconnect/backoff (socket may not be up yet when pi starts).
- Document env vars in README.

### 5.3 `Info.plist`

- Add `NSAppleEventsUsageDescription` ("Opens pi in a Terminal window and
  sends your prompt to it.") so the Automation prompt has a reason string.
- No new frameworks needed: AppKit, Foundation, Darwin cover everything.
  (`NSOpenPanel` is AppKit.)

### 5.4 `README.md`

- Modes table: `self` is the default; no-arg launch starts pi in a folder.
- Controls table: Ctrl+N.
- New "Self mode" section: folder dropdown, recents, Terminal.app requirement,
  Automation/Accessibility permission notes, behavior on quit.
- Note the changed default (`--mode dry` must now be explicit).
- M2 env vars.

### 5.5 `run_overlay.sh`

- Unchanged (it always passes `--mode tty`). Optionally add
  `--dir "$PWD"` for a self-mode variant or a `run_self.sh`.

## 6. Failure modes and handling

| Case | Behavior |
|---|---|
| `pi` not on PATH | Banner `PI NOT FOUND` + menu item "Set pi binary…" (M1 optional: just env `PI_OVERLAY_PI`) |
| Terminal.app not installed / automation denied | Fall back to System Events; if that fails, `AUTOMATION DENIED` with System Settings hint |
| Directory deleted between menu build and click | Prune recent, show `DIRECTORY MISSING`, keep current session |
| Directory with spaces/quotes/newlines | Rejected for newlines; quoting tested for spaces/quotes |
| TIOCSTI returns `EPERM` | Silently use the AppleScript backend, don't disable capture |
| Duplicate launch for same dir | Reuse existing session (unless Ctrl+Shift+N) |
| Overlay exits | Sessions keep running; no orphan overlay processes |
| Two overlays running | Socket path includes pid; Terminal session targeting stays per-overlay |

## 7. Testing

**Build:** `make` must stay warning-free; `swiftc -O` unchanged.

**Manual matrix**

1. `./tty_overlay_native` (no args) → self mode, pi starts in `$HOME`/last dir.
2. `--mode self --dir "/tmp/a b/c"` → correct cwd, quoting intact.
3. `--mode tty --tty /dev/ttysXXX` → old behavior byte-for-byte (extension).
4. `--mode dry` → old debug behavior.
5. Ctrl+N with capture on **and** off → panel opens, text is not polluted.
6. Choose a folder → new Terminal window, pi runs there, injection lands on
   Enter.
7. Re-select a recent folder → focus existing session, no second window.
8. Cancel panel → no state change.
9. Move/delete a recent folder → pruned, error shown, current session intact.
10. Deny Automation → graceful fallback + status message.
11. Quit overlay → pi sessions survive; `Close pi session` closes the right
    window, not an unrelated one.
12. M2: `PI_OVERLAY_SOCKET` session shows Processing/Done and Markdown response.

**Regression:** pi extension start/stop, `/overlay`, `agent_start`/`settled`,
Option+Space, Cmd+V, voice, response panel resize.

## 8. Milestones

1. **M1a** — Mode enum/default/`--dir`, `DirectoryStore`, `PiLauncher`,
   initial launch. (No UI selector yet: Ctrl+N only.)
2. **M1b** — Header dropdown + recents + `switchSession` + session registry,
   injector selection/failure fallback, README.
3. **M2** — Unix-socket IPC server + `extension.ts` client, status/response in
   self sessions, docs.
4. **M3 (optional)** — Multiple session list in the dropdown, iTerm2 support,
   tmux/PTY backend for permission-free injection, remember window position.

## 9. Decisions to confirm

1. **Terminal.app vs embedded PTY**: plan launches Terminal.app. An embedded
   PTY would allow permission-free injection but needs a terminal renderer and
   would lose pi's TUI unless we render it. Confirm Terminal.app is acceptable.
2. **Keep sessions alive on switch/quit**: plan says yes. If you prefer
   "one session at a time", `switchSession` kills the previous Terminal window.
3. **Ctrl+N semantics**: "open/reuse session in folder" (plan) vs "always new
   session". Ctrl+Shift+N is the planned escape hatch.
4. **M2 required now?** Without it, self mode has input but no Processing/Done
   badge or Markdown response. M1 can ship first if that's acceptable.
