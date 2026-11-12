# Plan: remote RPC sessions (over SSH)

> **Status:** R0–R3 implemented in `tty_overlay.swift` and documented in the README.
> R4 (attach to an already-running remote pi via a broker) is not implemented.
> Related: [`docs/self-mode-plan.md`](self-mode-plan.md), README "Self mode (default, RPC)".
>
> What shipped, relative to this plan: SSH runs as the tab's child process
> (`RemotePiSessionStore` handles only the short-lived listing/preflight calls),
> connecting is two steps (host, then a `RemoteFolderBrowser` sheet with an
> editable path field, Up/Enter/Open Folder), leading `~` is expanded on the
> remote side (single-quoted paths otherwise keep it literal), remote paths are
> resolved with `pwd -P` before a tab is created, remote tabs are stored in
> `profiles.conf` as `ssh://host/abs/path`, remote "resume latest" is skipped
> (pinned sessions only), and `RemotePi` adds `PI_OVERLAY_SSH`,
> `PI_OVERLAY_REMOTE_SHELL`, `PI_OVERLAY_REMOTE_PI`, and
> `PI_OVERLAY_SSH_CONTROL=0` knobs.
>
> Implementation note: ssh joins its remote arguments with spaces before the
> server executes them, so the script must be quoted *inside a single argv*
> (`RemotePi.remoteCommand`). Passing `[shell, "-lc", script]` separately loses
> the quoting and turns `sh -lc 'cd /path; pwd'` into `sh -lc cd /path; pwd`,
> which silently lands in the remote home directory.

## 1. Question

> I run `pi` (RPC) on a machine such as `192.168.1.21`. Can the overlay on my
> Mac open that session?

**Short answer: yes, with a caveat about what "that session" means.**

pi's RPC protocol is plain JSONL over a process's **stdin/stdout** — it has no
socket, port, or attach endpoint. Verified against the installed CLI:

```text
--mode <mode>   Output mode: text (default), json, or rpc
```

There is no `--rpc-socket`, `--listen`, or similar. So there are two different
problems hiding behind the question:

| Interpretation | Feasible? | Cost | Recommendation |
|---|---|---|---|
| **A. Overlay owns a remote pi** — spawn `ssh host pi --mode rpc`, drive it exactly like a local tab. Resume the same conversation from the remote session store. | Yes, cleanly | Small/medium: transport is already a subprocess; the work is de-localising paths, session store, and folder picking | **Recommended (v1)** |
| **B. Attach to an already-running remote `pi --mode rpc`** (started manually in a remote terminal) | Possible but needs a relay on the remote | Medium/large: persistent broker, lifecycle/ownership, auth, reconnection | **Optional later (R4)** |

Interpretation A still gives "the same session": sessions and history live on
the remote disk (`~/.pi/agent/sessions/...`), and `pi --session <path>` resumes
them. The overlay can list, resume, and continue that conversation; it just
owns a *new* front-end process on the remote instead of hijacking the old one.

A second remote session is only a problem for two writers on one session file;
pi's session store already tolerates that the same way two local overlay tabs
would.

### Why transport is the easy part

`RpcSession` already treats pi as a child process with pipes, and the parser
splits stdout on `LF` only. `ssh -T host …` makes remote stdio look exactly like
local stdio:

```text
overlay (Mac)                                    remote host 192.168.1.21
┌──────────────────────────────┐                 ┌──────────────────────────┐
│ RpcSession                   │   ssh (child)   │  login shell             │
│  stdin  ─────────────────────┼────────────────►│   exec pi --mode rpc     │
│  stdout ◄────────────────────┼─────────────────│      (cwd = remote dir)  │
│  stderr ◄────────────────────┼─────────────────│                          │
│  JSONL parse / events / UI   │                 │  ~/.pi/agent/sessions/…  │
└──────────────────────────────┘                 └──────────────────────────┘
        │  short-lived ssh calls (separate processes)
        └────────────────► session listing, `test -d`, `command -v pi`
```

`-T` is mandatory: no pty means no CR translation, no echo, no login banners on
stdout. The existing parser already skips non-JSON lines, which absorbs shell
noise; add debug logging for skipped lines.

## 2. What actually breaks today

Everything that touches the **local** filesystem:

| Current assumption | Location | Remote fix |
|---|---|---|
| `PiLauncher.resolvePiBinary()` finds a local `pi` | `PiLauncher` | Resolve per host: `ssh host 'zsh -lc "command -v pi"'`, cached |
| `Process` runs a local executable | `RpcSession` | Transport abstraction; SSH transport runs `/usr/bin/ssh` |
| `directory: URL` is a local path, validated with `FileManager` | `RpcTab`, `DirectoryStore` | `TabLocation` enum: `local(URL)` / `remote(host, path)`; validate with remote `test -d` |
| `NSOpenPanel` picks folders | `DirectoryStore`, `chooseDirectory()` | Remote path field + optional remote `ls` browser; recents keyed by `host:path` |
| `PiSessionStore` reads local `~/.pi/agent/sessions/--<cwd>--/*.jsonl` | `PiSessionStore` | `SessionStore` protocol; `RemoteSessionStore` via one batched `ssh … sh -s` script |
| Pinned session file checked with `FileManager.fileExists` | `startRpcSession` | Remote existence check (or trust pi + surface error) |
| `profiles.conf` stores bare local paths | `ProfileStore`, `TabStore` | `ssh://user@host:port/abs/path` URI in the existing path column (backward compatible) |
| Header shows local `pid` and a local folder name | `OverlayController` | Show `host · path`, `ssh <pid>`; window title `pi rpc · host:path` |
| env from the local login shell | `PiEnvironment.loginShell()` | Split: keep it for the local `ssh` client (it needs `HOME`, `PATH`, `SSH_AUTH_SOCK`), but let the remote pi get its own env from the remote login shell — see §4.1 |
| `FileHandle.write` on the main thread | `RpcSession.send` | Serial write queue per session; a stalled link must not freeze the AppKit run loop |

Things that already work unchanged over the transport: prompt/abort, event
stream and streaming text, `agent_settled`, Markdown response panel, model
dropdown (`get_available_models` / `set_model`), `switch_session` /
`new_session` (paths are opaque strings — they just happen to be remote now),
`get_entries` prompt history, extension-UI dialogs, image prompts (inline
base64, no path crossing).

## 3. Design

### 3.1 Transport

```swift
protocol RpcTransport: AnyObject {
    var isRunning: Bool { get }
    var pid: Int32 { get }
    func start(onStdout: @escaping (Data) -> Void,
               onStderr: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws
    func write(_ data: Data) throws
    func stop()
}
```

- `LocalProcessTransport` — today's `Process` + `Pipe` code, extracted.
- `SSHProcessTransport` — `Process("/usr/bin/ssh")` with:
  `-T`, `-o BatchMode=yes`, `-o ConnectTimeout=10`,
  `-o ServerAliveInterval=15 -o ServerAliveCountMax=3`,
  `-o ControlMaster=auto -o ControlPath=~/.ssh/pi-overlay-%C -o ControlPersist=10m`,
  `-p <port>`, then `host`, then the remote command.
- Remote command: `cd <dir> || exit 1; exec <pi> --mode rpc [--session <file>]`,
  every value `shellQuote`d; host/path reject `\n`, `\r`, NUL.
  Default shell wrapper `zsh -lc` (override `PI_OVERLAY_REMOTE_SHELL`) so the
  remote login env is used; do **not** forward local env or keys.
- Exit handling: `ssh` exit 255 = connection/auth failure → tab shows
  `SSH FAILED` + last stderr lines (`recentStderr()` already exists) instead of
  a mute "exited".
- Later `SocketTransport` (AF_UNIX) for the relay milestone; the protocol layer
  does not change.

### 3.2 Location model

```swift
enum TabLocation: Equatable {
    case local(URL)
    case remote(host: RemoteHost, path: String)   // path is absolute or ~/…
}
struct RemoteHost: Equatable { let name: String; let port: Int? }  // name = ssh alias or user@host
```

- `key` = `host:port:path` for dedupe / recents; `title` = last path component;
  `display` = `host · path`.
- `ProfilesStore` writes `ssh://user@host:port/abs/path`; plain paths still mean
  local, so existing files need no migration. Session pin uses the same scheme
  (or is interpreted relative to the tab's host when it is a bare path).
- Keep a `location.path` string and only convert to `URL` in local code paths.

### 3.3 Remote session store

One short-lived ssh per refresh (never reuse the RPC session's stdin):

```sh
# stdin = small sh script; prints one record per session file:
# <path>\t<mtime-epoch>\t<size>\n  followed by a bounded head/tail payload
dir="$PI_CODING_AGENT_SESSION_DIR"   # honour overrides, else ~/.pi/agent/sessions/--<enc>--
for f in $(ls -t "$dir"/*.jsonl 2>/dev/null | head -40); do … done
```

- Compute the encoded directory with the same rule as `PiSessionStore`
  (`/`→`-`, strip leading `/`, wrap in `--…--`), on the remote side.
- Emit name (last `session_info` in the tail) and preview (first user message in
  the head) the same way the local code does, but bounded: 32 KB tail / 32 KB
  head, ≤ 40 files, one round trip.
- Cache summaries by `(host, path, mtime, size)`; refresh on tab switch, on
  settle, and after `switch_session`.
- Fallback if the batched script fails (BusyBox/odd shell): `ssh host tail -c`
  for the newest 10 files.

### 3.4 UI

- Folder dropdown: current item + remote recents + **Connect to Remote Host…**.
  The sheet asks for host (free text or an `~/.ssh/config` alias) and remote
  directory; **Browse…** (v2) lists remote folders via `ssh … ls -p`.
- Tab strip / window title show a compact host chip for remote tabs
  (e.g. `☁ 192.168.1.21`) so local and remote tabs are not confusable.
- Error details: clicking the error status opens a small sheet with the last
  stderr lines (auth, host key, `cd: no such directory`, pi not found).
- Everything else (Sessions row, model dropdown, Response panel, prompt
  history, profiles) behaves identically.

## 4. Security

### 4.1 Remote environment and credentials

This section is only about **process bootstrap**: what environment `sshd` hands
to the remote `pi` when it execs it. Everything after that — settings and
`auth.json` discovery, project `.pi`, model catalog, shell tools, provider
calls — runs *inside* the remote pi process, in the remote cwd, with the remote
filesystem. The overlay never provisions any of it, and pi's `bash` tool spawns
`<shellPath|bash> -c <command>` with pi's process env rather than re-reading a
profile per call (`dist/core/tools/bash.js`), so the startup env is the whole
story.

Today `RpcSession` sets `process.environment = PiEnvironment.loginShell()`: it
runs `/bin/zsh -lc 'env -0'` **locally** and hands the captured environment to
the pi child. That exists because a Finder-launched app has a minimal `PATH`
and does not see `~/.zprofile`. It must not be copied to a remote tab.

```text
local tab   overlay ──(local login env)──► pi            uses Mac keys/PATH
remote tab  overlay ──(local env, local-only)──► ssh ──► remote shell ──► pi
                     ^ needed by the ssh client        ^ remote env, not the Mac's
```

Why not forward the Mac's environment:

1. **It would not work.** ssh only transmits variables listed in `SendEnv`
   (usually `LANG`, `LC_*`) and the server only accepts those in `AcceptEnv`, so
   `ANTHROPIC_API_KEY` and friends would not arrive.
2. **It would be wrong.** The remote pi should use the remote machine's
   credentials and configuration (`~/.pi/agent/auth.json`, remote `settings.json`,
   remote model catalog), not accounts that belong to the Mac user.
3. **It would leak secrets.** Forcing it with `-o SendEnv=…` would put the Mac's
   provider tokens on the wire and on a second host's process table.

So the SSH transport builds the command so the remote shell loads *its own*
environment:

```sh
ssh -T -o BatchMode=yes host -- zsh -lc 'cd "/srv/app" || exit 1; exec pi --mode rpc'
```

`ssh host <command>` normally runs a **non-interactive, non-login** shell, which
skips `~/.zprofile` (zsh) / `~/.bash_profile` (bash). Wrapping the command in an
explicit login shell (`-l`) restores the remote user's normal `PATH`, so `pi`
resolves the same way it does in their terminal. Override with
`PI_OVERLAY_REMOTE_SHELL` (e.g. `bash -lc`) for hosts that use another shell.

Caveat: for zsh, `zsh -lc` reads `.zshenv`, `.zprofile`, and `.zlogin`, not
`.zshrc` (interactive only) — the same limitation the local `PiEnvironment`
already has. Credentials are best kept in pi's own `~/.pi/agent/auth.json` from
`/login` on the remote; if a user relies on an API-key environment variable, put
it in `.zshenv`/`.zprofile` or set `PI_OVERLAY_REMOTE_ENV` to source a file
before `exec pi` (with that file's output redirected away from stdout).

### 4.2 "Never forward local keys" — two kinds of keys

- **Provider credentials (API keys / OAuth tokens).** Do not pass them with
  `SendEnv`/`SetEnv`; the remote pi reads `~/.pi/agent/auth.json` and the remote
  environment instead. Nothing secret from the Mac is transmitted.
- **SSH private keys.** Keep `ForwardAgent` **off** (the default) and never add
  `-A`. Agent forwarding would let the remote pi — and anything it shells out to,
  including a model-driven `git push` — use the Mac's keys to reach other hosts.
  If the remote needs git-over-ssh, it should hold its own key, or the user opts
  in per host (`PI_OVERLAY_REMOTE_FORWARD_AGENT=1`) with that risk understood.

The local `ssh` **client** still needs the Mac's own environment for
`HOME`/`PATH` and `SSH_AUTH_SOCK` when the overlay is launched from Finder; using
`PiEnvironment.loginShell()` for the `ssh` process is fine. That is the client
looking up its own keys, not handing them to the remote.

### 4.3 General

- Use OpenSSH as-is: `~/.ssh/config`, keys, agent. Never store passwords.
- `BatchMode=yes` is required — a GUI app has no tty, so an auth or host-key
  prompt would otherwise hang invisibly. Unknown host keys fail fast with a
  clear message telling the user to `ssh host` once in Terminal.
- No listener in v1. If the relay milestone happens: remote Unix socket
  (`0600`, user-owned) reached with `ssh -o StreamLocalBindUnlink=yes -L`, or a
  loopback-only TCP port with a per-host token. Never a public bind.
- Treat remote paths as untrusted input: always single-quote for the remote
  shell, reject newlines/NUL, never build a command by string concatenation
  without quoting.
- Credentials and project trust stay on the remote (`~/.pi/agent/trust.json`);
  the overlay never copies secrets or session content off the remote except the
  text it already renders.

## 5. Failure modes

| Case | Behaviour |
|---|---|
| Host unreachable / DNS failure | Tab status `SSH FAILED`, stderr excerpt, no spinner hang (`ConnectTimeout`) |
| Auth failure, no key | Fast failure; hint about `ssh host` / agent |
| Unknown host key | Fast failure; hint to accept once in Terminal |
| `pi` not on remote PATH | Preflight `command -v pi` at connect time; `PI NOT FOUND ON HOST` + optional `PI_OVERLAY_REMOTE_PI` |
| Remote dir missing | `cd` fails inside the remote command → explicit `DIR MISSING` |
| Network drops mid-turn | `ssh` exits, tab becomes `! exited`; no local crash; remote pi exits on stdin EOF; **Reconnect** resumes the pinned session |
| Slow link / large `get_entries` | Write queue keeps UI responsive; response panel may arrive late but ordering is preserved |
| Many tabs, same host | `ControlMaster` multiplexes one TCP connection (set `ControlPath` short enough for the macOS unix-socket limit) |
| Remote macOS vs Linux | Session script uses POSIX `sh` + `ls -t`; no GNU-only flags in the v1 path |

## 6. Milestones

| Phase | Scope | Outcome |
|---|---|---|
| **R0 — spike (≈30 min, no code)** | Create a `pi` wrapper script that runs `exec ssh -T host 'zsh -lc "exec pi --mode rpc \"$@\""' "$@"`; point `PI_OVERLAY_PI` at it. | Proves the whole transport premise with the current binary, including streaming, models, and session resume. Decide go/no-go here. |
| **R1 — transport + location** | `RpcTransport`, `SSHProcessTransport`, `TabLocation`, launch path, remote preflight, header/title, remote dir recents + connect sheet. | A remote tab can prompt, show streaming/Done, render Markdown, switch models, resume a session by passing a remote path through env/CLI. |
| **R2 — remote session store** | `SessionStore` protocol, batched remote listing/preview, `switch_session` + pinned session existence, refresh points. | Sessions row and prompt history are complete for remote tabs. |
| **R3 — polish** | `ssh://` in `profiles.conf`, `~/.ssh/config` alias suggestions, error sheet, ControlMaster path, reconnect action, README. | Remote tabs survive relaunch and are pleasant to diagnose. |
| **R4 — optional relay** | Small remote broker (`pi-overlay-relay`, Node/Bun) that owns a pi child, serves JSONL on a Unix socket, and survives client disconnects; overlay gets `SocketTransport` + attach UX. | "Attach to an already-running remote pi" and survive network drops. |

R0/R1 are independent of any pi change. R2 may alternatively be avoided if pi
gains an RPC command to list sessions for a project; a batched shell script is
fine until then.

## 7. Testing matrix

- `ssh -T host 'echo ok'` baseline; `ssh -T host 'command -v pi'`.
- Remote tab: prompt → `agent_start` → streaming → `agent_settled`; abort (Esc);
  model switch; `＋` new session; resume a session from the Sessions row.
- Session listing: 0, 1, and 40+ sessions; names vs first-message previews;
  unicode, spaces and `'` in paths; remote `PI_CODING_AGENT_DIR`/`sessionDir`.
- Failure injection: wrong host, wrong user, missing key, unknown host key,
  remote dir deleted, `pi` removed from PATH, kill `ssh` mid-turn, `SIGSTOP`
  ssh to simulate latency.
- Two tabs on one host → one TCP connection (`ssh -O check`), separate pi
  children; Ctrl+W kills only that `ssh`; quitting the overlay leaves no
  orphan `ssh`/remote `pi`.
- Regression: local tabs, local sessions, profiles restart, tty-mode extension
  (unchanged; TIOCSTI is inherently local-only).

## 8. Open decisions

1. **A vs B**: confirm that "open the remote session" means *resume the remote
   conversation through an overlay-owned RPC child* (A) rather than *hijack the
   exact running process* (B). B is deferred to R4 by this plan.
2. **Host configuration**: rely on `~/.ssh/config` aliases only, or also a small
   overlay-managed `hosts.conf`? (Plan: aliases first, optional file later.)
3. **Remote folder picking**: text field in v1, remote `ls` browser in R2/R3?
4. **profiles.conf syntax**: `ssh://…` URI in the existing column (plan) vs a
   new tab-separated field (breaks the current `path<TAB>session` shape).
5. **Relay milestone**: is disconnect survival / attach-to-running worth a
   remote broker, or is "reconnect resumes the session" enough?
6. **Network profile**: LAN only, VPN/Tailscale, or internet? Affects
   `ConnectTimeout`, keepalives, and whether `ControlPersist` is acceptable.
