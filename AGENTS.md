# AGENTS.md

Read this before editing. It is a map of the code, not a tutorial on AppKit.

## What this project is

A native macOS overlay window for `pi` sessions. Two processes talk to each other:

- **`pi_overlay_native.swift`** — one file, ~9.4k lines, compiled straight with
  `swiftc -O` by `make`. No packages, no build step, no Auto Layout.
- **`extension.ts`** — a pi extension that runs *inside* the pi process and pipes
  newline-delimited JSON to the overlay's stdin.

The overlay can attach to a terminal that already runs pi (**tty mode**) or own a
headless `pi --mode rpc` child (**self mode**). Which one you are in decides where
every number comes from, so check the mode before you write anything.

## 60-second orientation

| You want to change | Look at |
|---|---|
| Anything visual (sizes, colours, fonts) | `enum Theme` (top of file) |
| Where a widget sits | `layoutViews()`; compact variant `layoutCompact(width:height:)` |
| A drawn widget | its `NSView` subclass `draw(_:)` near the top of the file |
| An RPC event or RPC response | `handleRpcEvent(_:tabID:session:)` |
| An event from the extension | `handleIPCEvent(_:)` + the `pi.on(...)` handlers in `extension.ts` |
| A pi RPC request | methods on `RpcSession` (`requestState()`, `requestModels()`, …) |
| The reasoning dropdown | `rebuildThinkingMenu()` and `thinkingLevelSelected(_:)`; a tty selection goes through `injectSlashCommand(_:)` |
| Per-tab state | `RpcTab` fields |
| Controller-wide state | `OverlayController` properties |
| How it is documented | `README.md` (the spec of record — mockup + Controls table) |

`OverlayController` is ~6k of the 9.4k lines. Everything below its declaration is
one class with `// MARK:` sections: Self mode sessions, Profiles, Menu bar status
item, Tabs, Saved sessions row, Prompt history, Reasoning effort, Footer numbers, Attachments and
response actions, Slash commands, Notifications, Compact textbox mode, layout,
Prompt box key handling.

`docs/` keeps the design history for the three subsystems (`remote-plan.md`,
`self-mode-plan.md`, `slash-command-palette-plan.md`) — read the one for the area you
are touching before changing its behaviour.

## The two data planes

**tty / extension mode** — the overlay is a separate process glued to a terminal.
It has no session object. Its only inputs are:

1. `TtyInjector` writing single chars to the controlling TTY (`TIOCSTI`), and
2. JSON lines on stdin, which only `extension.ts` writes.

`startIPCReader()` guards on `isatty(stdin)` so a manual launch does not swallow
the keyboard, then dispatches each line to `handleIPCEvent`. Event names currently
handled: `status`, `response`, `queries`, `usage`, `thinking`. Anything the extension knows but
the overlay cannot compute must arrive as a new event — `ctx.getContextUsage()` is
an *extension-context* API and cannot be called from the Swift side.

**self mode** — the overlay owns `pi --mode rpc`. Requests go out on the child's
stdin (`RpcSession.send`), events come back on stdout as JSONL. `RpcSession.onEvent`
routes to `handleRpcEvent`, which handles both stream events (`agent_start`,
`message_start`, `message_update`, `message_end`, `agent_settled`) and command
responses (`response` records whose `command` is `get_state`, `get_available_models`,
`get_session_stats`, …). Field names are documented upstream in pi's
`docs/rpc-commands.md`; treat that as the contract.

The rule that saves the most time: **RPC data is per tab (`RpcTab`), tty data is
controller-wide.** Write both, or your feature works in one mode and is empty in the
other (`RpcTab.thinkingLevel` / `eventThinkingLevel` is the current example).

## Layout: read this before touching frames

- `OverlayContainerView` is **not flipped**: `y` grows upward, so `y = 0` is the
  bottom edge. Views that flip themselves override `isFlipped` — `KeyTapeView`,
  `FooterView`, `CommandRowView`, `CommandPaletteView`,
  `CommandPaletteDocumentView` — and inside them `y` grows downward. Note that
  `FlippedTextView` is *not* flipped despite its name. Mixing the two is the usual
  cause of "it drew off screen".
- There is no Auto Layout. Every frame is computed in `layoutViews()` in one pass,
  bottom-up: `textY` (panel bottom) → `textHeight` → `responseRowY` → `keyY` →
  `keyHeight`, and top-down for the tab strip (`headerBase`, `headerRowY`,
  `sessionRowY`, `inputTop`). `textY` is the single anchor; changing it moves the
  panel, the response row, and the input card together.
- `baseMinSize`, `defaultWindowHeight`, `collapsedHeight`, `sessionRowExtra`,
  `responsePanelHeight`, and `keyTapeBaseHeight` are the shared constants. Change a
  height constant and check the four places that set `window.minSize`: `init`,
  `toggleMinimize()`, the compact exit path, and `setCompactChrome()`.
- Compact mode is a *different* layout (`layoutCompact`). A view that must not appear
  there has to be added to the `hiddenViews` array; `isMinimized` is a separate flag
  and is handled inside `layoutViews`.
- `syncResponsePanelHeight()` runs at the top of `layoutViews()`, so any frame you
  set can be recomputed by the window resize path.

## Adding a UI element

1. `Theme` — add the height/colour constant.
2. `OverlayController` — a stored property, created in `init` **before `super.init()`**
   and added to `container`.
3. `layoutViews()` — its frame, plus the `isHidden` line.
4. `layoutCompact()` — add it to `hiddenViews` if it should not appear there.
5. `baseMinSize` / `window.minSize` in `init` — grow the minimum if the element needs
   vertical space.
6. `renderPreview(to:)` — seed its data so the preview path exercises it.
7. `README.md` — mockup line, Controls table row, a section if it is user-visible.

## Verify without a GUI

`PI_OVERLAY_PREVIEW=/tmp/out.png ./pi-overlay-native --mode self` renders the window
to PNG and exits; nothing is shown on screen and no pi child is spawned. Knobs:
`PI_OVERLAY_PREVIEW_MIN`, `_RESPONSE`, `_PROCESSING`, `_COMPACT`, `_COMPACT_EXIT`,
`_COMMANDS`, `_THINKING`, `_ERROR`.

`renderPreview` **seeds a fake tab** with fixed values. If your feature reads live
state, either seed it there or the preview will show the seed and prove nothing.

If you cannot open the image, analyse it: crop the bottom strip, bucket pixels by
colour, and check the meter/text extents against the values you seeded. That is how
the footer was verified end to end.

For the stdin path, `debugLog` writes to `/tmp/pi-overlay-native.log`; that is the
cheapest way to see what actually arrived.

## Gotchas that cost time

- **Names already taken in the layout.** `thinkingWidth` is the response row's
  thinking-button width and `showThinking` is tab state, so the header-row reasoning
  control uses `reasoningWidth` / `showReasoning`. Reusing either is a redeclaration
  error, since the whole file is one scope.
- **`super.init()` ordering.** A computed property such as `baseMinSize` cannot be
  read before `super.init()` in `init`; use the literal or move the assignment.
- **Access levels.** `handleIPCEvent` and the layout helpers are `private`, so a
  test harness in the same file cannot call them without changing the access level.
- **JSON numbers are `NSNumber`.** `value as? Int` fails on `14.2`. Use `intValue()`
  / `doubleValue()` in the controller instead of casting.
- **pi can return nulls.** `contextUsage.tokens` and `percent` are null right after
  compaction, and `contextUsage` is absent when no model is selected. Render `—`
  rather than assuming a number.
- **Do not repaint on every token.** Streaming events arrive per delta. Gate redraws
  on a change signature (see `updateFooter()` / `footerSignature`), and throttle the
  extension's writes (`USAGE_THROTTLE_MS`) so the pipe is not flooded.
- **The extension child must not be detached**, or `TIOCSTI` loses pi's controlling
  TTY. Notifications must go through `PiOverlayNotifier.app` because macOS refuses
  `UserNotifications` for a process not launched as an app bundle.
- `killExisting()` in `extension.ts` pkills by the **legacy** binary name
  (`tty_overlay_native`), so renaming the binary breaks the "kill the old overlay"
  path.

## Conventions

- Swift: 4-space indent, `// MARK:` sections, comments explain *why* (the trade-off,
  the platform rule), not *what the line does*. One file stays one file. One file stays one file.
- `extension.ts`: tabs, no build step, no external packages.
- State is persisted through `DirectoryStore`, `TabStore`, `ProfileStore`
  (`profiles.conf`); add a field there only if it survives a restart.
- `README.md` is the spec: if a control or number is user-visible, it belongs in the
  mockup and the Controls table.
