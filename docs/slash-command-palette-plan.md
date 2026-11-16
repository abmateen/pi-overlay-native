# Plan: `/` command palette in the overlay

> **Status:** first slice implemented. The palette currently lists
> `skill:*` commands, `mcp`, and the overlay-native `/name` (session rename)
> and `/reload` (restart the RPC child); other discoverable commands, built-ins
> and argument completions are not included yet.
> Related: README "Use as a pi extension", `docs/self-mode-plan.md`, `docs/remote-plan.md`.

## 1. Short answer

**Yes — for the self/RPC backend (local and remote).** pi exposes the exact
discoverable command list over RPC:

```json
{"type": "get_commands"}
```

and runs them through the normal prompt path:

```json
{"type": "prompt", "message": "/fix-tests some args"}
```

That gives the overlay names, descriptions, source kinds and source metadata.
The one important gap: **built-in TUI commands are not in `get_commands`** and,
per pi's docs, they *would not execute if sent through `prompt`*. The palette
therefore has to be a mix of:

1. **Discoverable commands** — extension commands, prompt templates and skills
   from `get_commands`. These are exact and safe to list/send.
2. **Overlay-native built-ins** — `/new`, `/model`, `/thinking`, `/compact`,
   `/name`, `/copy`, `/session`, `/export`, `/clone`, … implemented by the
   overlay through existing UI or RPC commands.
3. **TUI-only built-ins** — `/settings`, `/login`, `/tree`, `/share`, … either
   omitted or shown disabled with an "open pi's TUI" hint.

The palette UI itself is straightforward AppKit work: a floating list anchored
to the prompt card, driven by the existing `NSTextView` delegate and
`handlePromptKeyDown`.

## 2. What pi actually provides

`get_commands` response (abridged):

```json
{"success": true, "data": {"commands": [
  {"name": "fix-tests", "description": "Fix failing tests", "source": "prompt",
   "sourceInfo": {"path": "...", "scope": "project", "origin": "top-level"}},
  {"name": "my-command", "description": "…", "source": "extension"},
  {"name": "skill:release", "description": "…", "source": "skill"}
]}}
```

- `source` is `extension`, `prompt` or `skill`.
- No argument hints/completions are exposed for these.
- Built-ins are a separate static list (`settings`, `model`, `thinking`, `new`,
  `resume`, `compact`, `name`, `session`, `export`, `import`, `copy`, `fork`,
  `clone`, `tree`, `trust`, `reload`, `hotkeys`, `changelog`, `share`, `bug`,
  `login`, `logout`, `scoped-models`, `quit`). Some have argument hints
  (`/model <provider/model>`, `/thinking <level>`, …).

## 3. Recommended scope

### v1 — palette for discoverable commands (high value, low risk)

- Fetch with `get_commands` per tab after the RPC session starts.
- Show a filtered list while the input starts with `/` and has no space yet.
- Selecting a row inserts `/name ` (or executes `/name` immediately when the
  command takes no arguments) through the existing prompt path.
- No built-ins in v1. This already matches the dynamic part of pi's menu
  (extensions, templates, skills).

### v2 — overlay-native built-ins

Add a curated list that maps to things the overlay can actually do:

| Command | Overlay action |
|---|---|
| `/new` | existing `newSession()` (`new_session`) |
| `/model [provider/model]` | open model menu, or `set_model` when an argument is given |
| `/thinking [level]` | `set_thinking_level`; submenu from `get_available_thinking_levels` |
| `/compact [instructions]` | `compact` RPC with `customInstructions` |
| `/name [name]` | `set_session_name`; `NSAlert` prompt when omitted |
| `/copy` | copy the current answer (same as the copy icon) |
| `/session` | `get_session_stats` and show a small sheet |
| `/export [path]` | `export_html` with `NSSavePanel`; JSONL by copying the session file |
| `/clone` | `clone` RPC |
| `/resume` | focus/open the existing Sessions dropdown |
| `/quit` | close the overlay (with confirmation) — decide |

Not implementable through RPC without new UI: `/settings`, `/login`,
`/logout`, `/scoped-models`, `/tree`, `/fork` (needs a message chooser),
`/import`, `/trust`, `/share`, `/bug`, `/changelog`, `/hotkeys`, `/reload`.
For these, either hide them or show them disabled with a tooltip
"Available in pi's TUI".

### v3 — argument hints and completions

- Built-ins can carry their `argumentHint` (static).
- `/model ` can list models from `get_available_models`; `/thinking ` from
  `get_available_thinking_levels`.
- Extension/template argument completions are not available over RPC; leave
  the argument free-form.

## 4. UI design

```text
┌─ prompt card ────────────────────────────────────────────────┐
│ type…                                                        │
└──────────────────────────────────────────────────────────────┘
┌─ commands ───────────────────────────────────────────────────┐
│ /fix-tests      Fix failing tests              project · prompt│
│ /release        Create a release               extension     │
│ /skill:review   Review the current change      skill         │
└──────────────────────────────────────────────────────────────┘
```

- A floating `CommandPaletteView` (layer-backed `NSView` + `NSTableView` or a
  simple stack of row views) anchored to the **top edge of the prompt card**,
  so it never covers the text being typed.
- Width matches the prompt card. Max height ~260 pt with scrolling.
- Rows: `/name`, description, a small source badge (`builtin`, `extension`,
  `prompt`, `skill`) and, for built-ins, the argument hint in muted text.
- Selected row uses the accent-soft background and accent text; mouse hover
  highlights; click or double-click accepts.
- Uses the same `Theme` tokens as the rest of the overlay; corner radius 12,
  hairline border, card shadow.
- Empty state ("No matching commands") and a footer hint
  `↑↓ navigate   Tab/↵ insert   Esc dismiss`.
- Compact capsule mode: v1 hides the palette in compact mode. v2 can either
  grow the compact window upward by the palette height while open (restoring
  it afterwards) or show a child `NSPanel` above the capsule.

## 5. Data flow

### Swift types

```swift
struct PiCommand {
    enum Source: String { case builtin, extension, prompt, skill }
    let name: String                 // without the leading slash
    let description: String
    let source: Source
    let argumentHint: String?
    let sourceInfo: String?          // scope/path tooltip
    let action: BuiltinAction?       // non-nil for overlay-native built-ins
}
```

### RPC

- Add `RpcSession.requestCommands()` → `{"type":"get_commands"}`.
- Handle `response(command: "get_commands")` in `handleRpcEvent`:
  parse `data.commands`, store `tab.commands`, merge the built-in list, refresh
  an open palette.
- Refresh points:
  - after the RPC session starts (with `get_state`/`get_available_models`);
  - when a tab is activated and its command list is empty or older than a few
    minutes;
  - after a session switch/new session (resources are session-scoped);
  - optionally on every palette open with a short cache.
- Remote tabs use the same command over SSH; nothing special.

### Existing integration points

- `KeyTapeView.textDidChange` → `promptTextChanged(_:)` in the controller:
  detect a leading `/`, extract the first token, filter/open/close the palette.
- `handlePromptKeyDown(_:)`: intercept Up/Down/Tab/Return/Esc **only while the
  palette is visible**; otherwise keep the current behavior.
- `handlePromptKeyEquivalent(_:)`: Cmd+V etc. remain untouched.
- `layoutViews()`: position the palette above the prompt card; hide it when
  minimized/compact.
- `RpcTab`: add `commands: [PiCommand]`, `commandsLoadedAt: Date?`.

## 6. Keyboard and text behavior

| Key | Palette open | Palette closed |
|---|---|---|
| `↑` / `↓` | move selection | native caret movement |
| `Tab` | accept selected command (insert `/name ` or execute) | native tab |
| `Return` | accept/execute selected command | send prompt |
| `Esc` | close palette | cancel running turn (existing) |
| `Shift+Return` | newline (close palette) | newline |
| Mouse | hover selects, click accepts | — |

Rules:

- Trigger only when the **first non-whitespace character of the input is `/`**
  and there is no newline yet. A `/` in the middle of a prompt is just text.
- The filter is the text after `/` up to the first space, case-insensitive.
  Match command names first, then descriptions. Hide once a space is typed
  (v1); v3 can keep argument completions.
- Backspacing to just `/` re-opens the full list.
- Accepting a command:
  - **No argument hint / no-arg built-in:** run it immediately.
  - **Argument hint or discoverable command:** put `/name ` in the input and
    focus for arguments; Return then sends it.
- Do not send the raw fragment while the palette is open and a row is
  highlighted.

## 7. Execution

- **Discoverable commands:** send `/name args` via the existing `sendPrompt`
  path. pi handles extension commands immediately and expands templates and
  skills before queueing. `streamingBehavior` rules are unchanged.
- **Built-ins:** run the mapped overlay action; never send TUI-only built-ins
  through `prompt`.
- **Errors:** a failed command should use the new `showAssistantFailure`
  plumbing (provider errors already do), and `/` command responses that report
  `success:false` should appear in the Response panel with the command name.
- **While processing:** the palette can still be opened, but executing a
  command follows pi's existing rules (extension commands run immediately;
  prompts queue as follow-up). Show the same Cancel behavior.

## 8. Edge cases

| Case | Behavior |
|---|---|
| `/` typed inside a multi-line prompt | no palette |
| IME/composition active | do not intercept; let the text system finish |
| Unknown command + Return | send as a normal prompt; pi reports the unknown command |
| Command list not loaded yet | show "Loading commands…" or just send the raw text |
| Session switch | clear and re-fetch commands |
| Remote host | same RPC call over SSH; no extra UI |
| tty/extension mode | palette unavailable until the extension protocol carries a command list |
| Compact mode | hidden in v1; floating palette/grow-window in v2 |
| Many commands | scroll, max height, filter first |
| Duplicate names (extension vs template) | group or suffix the source badge; keep pi's order |
| Long descriptions | truncate tail, tooltip with full text |

## 9. Why tty mode is out of scope for v1

The overlay extension (`extension.ts`) runs inside pi but has no documented API
to enumerate registered commands. The RPC `get_commands` endpoint exists only
for a session the overlay owns. Supporting tty mode would need either:

- a new extension-side event that sends the command list over the existing
  stdin/socket channel, or
- reading pi's prompt-template/skill directories and guessing extension
  commands (fragile; misses runtime-registered commands).

Keep v1 to self/RPC mode, matching the thinking toggle.

## 10. Milestones

1. **M1 — RPC list + insert.**
   `get_commands`, `PiCommand`, `tab.commands`, palette UI, filtering,
   Up/Down/Tab/Return/Esc, insert/send. No built-ins.
2. **M2 — overlay-native built-ins.**
   `/new`, `/model`, `/thinking`, `/compact`, `/name`, `/copy`, `/session`,
   `/export`, `/clone`, `/resume`, source badges, argument hints.
3. **M3 — polish.**
   `/model` and `/thinking` argument completions, source tooltips/scope,
   refresh-on-open, compact-mode palette, disabled TUI-only entries with a
   "TUI only" hint, README/Controls update.

## 11. Decisions to confirm

1. **Built-ins:** include a curated runnable subset (recommended), or mirror
   pi's entire list with TUI-only entries disabled?
2. **Accept behavior:** execute no-arg commands immediately, insert argument
   commands for editing (recommended), or always insert?
3. **Compact mode:** hide the palette in v1 (recommended) or expand the compact
   window upward while it is open?
4. **tty mode:** defer until the extension protocol can send command lists?
5. **Filtering:** prefix/substring (simple) vs fuzzy matching like pi's menu?
6. **Refresh:** per session start + tab activation, or fetch each time the
   palette opens?

## 12. Testing matrix

- `get_commands` with 0 commands, 1 command, 50+ commands.
- Extension command, prompt template, skill (`skill:name`), duplicate names.
- Filter by prefix, substring, description; backspace to `/`.
- Up/Down wrap-around; Tab vs Return; Esc closes before aborting a turn.
- Argument commands: `/model ollama-cloud/...`, `/thinking high`,
  `/compact focus on tests`, `/name my session`.
- Unknown command → normal prompt error path.
- Remote tab over SSH (command list and execution).
- Session switch/new session refreshes the list.
- Compact mode: palette hidden or floats correctly.
- Regression: Enter still sends normal prompts; Shift+Enter newline;
  history/thinking/response toggles unaffected.
