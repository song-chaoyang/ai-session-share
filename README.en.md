# ai-session-share

**Share your live terminal session as a LAN web service — one command.**

Anyone on your LAN can open a link in a browser to **watch and keep working on** your session in real time —
including a running AI coding agent — with identical context, because everyone shares the *same* terminal.

[简体中文文档](README.md)

```bash
./install.sh -y      # install deps (tmux / ttyd / openssl / python3) once
./share.sh           # create tmux session → serve → print link → attach
```

Open `http://<LAN-IP>:7681` in a browser, enter the printed username/password, and you are operating the same
session as the local terminal. Note: modern browsers have **disabled auto-login via URL-embedded credentials**, so
type the username/password once — the browser remembers them per-site afterwards.

---

## Why · What problem it solves

You started a long-running task in a local terminal (an AI coding agent, a data export, debugging…), and mid-way
you want a colleague / your phone to **take over and continue** — not to read a summary and redo it.

There are two kinds of sharing to distinguish:

- **Read-only replay** (watch the process) — many mature options exist (Code-Cast, session export, GitHub Gist…).
- **Bidirectional continuation** (can operate) — **this repo does exactly this**, and it is **not bound to any AI
  tool**: it is generic terminal sharing, works for any process.

---

## Feature overview

| Feature · Capability | What you get |
|---|---|
| One-command LAN sharing | `./share.sh` / `share here`: any browser on the LAN opens your terminal live |
| Bidirectional by design | Browser users share the **same PTY** — they can operate, not just watch |
| Zero-token `/share_session` | Type the slash command inside atomcode / claude / codex → links returned **before the LLM runs** (`total_tokens: 0`) |
| Session-aware output | The link always matches the session you invoked it from — never another one |
| Managed sessions | `share new` — hub-hosted PTY, no tmux needed; process exit (e.g. `/exit`) **auto-ends** the web session |
| Session hub dashboard | `share hub start` (port 7690): monitor managed / Claude Code / atomcode / ttyd sessions |
| Continue in the browser | One click "🔄 在网页继续此会话" upgrades a read-only view into a bidirectional terminal (`claude --resume`) |
| MCP server | `list_sessions` / `spawn_session` / `send_input` / `read_output` / `kill_session` from any MCP client |
| Self-contained web terminal | xterm.js self-hosted (no external CDN); Tracking-Prevention / intranet isolation cannot break it |
| Auth by default | Basic Auth with a fresh random token per start (user `ai`); `SS_NO_AUTH=1` opt-out only for trusted LANs |

---

## Quick start

```bash
# 1. Install dependencies (macOS / Linux); also installs the `share` command, slash-command templates,
#    zero-token hooks, MCP registration and the SS_HUB_URL env var for detected AI tools
./install.sh -y

# 2. One command: ensure tmux session → start web service → print LAN link → enter session
./share.sh

# 3. Run your AI tool inside the session (atomcode / claude / any command) — the session is now shared
# 4. Open the printed link in any browser (computer / phone), enter the printed credentials once,
#    and keep operating the same session
```

If you are already working inside a tmux session (e.g. an AI tool is running), run **right inside that session**:

```bash
share here        # auto-detect the CURRENT tmux session and serve it
share stop        # stop the web service (tmux session is kept; `share here` restores it anytime)
```

> `./install.sh -y` installs a `share` command (`~/.local/bin/share`), so you can run `share here` from any
> directory inside any tmux session — no need to open another terminal or remember session names. Without it, the
> equivalent is `./share.sh here`.

### Use `/share_session` directly inside AI tools (zero token)

`./install.sh -y` **auto-detects installed AI tools** (atomcode / claude / codex) and symlinks a command template
into each tool's global commands directory. Instead of typing shell commands, just type the slash command in the
AI tool's conversation:

| AI tool | Type | Effect |
|---------|------|--------|
| atomcode | `/share_session` | Directly prints the access link + credentials (**zero token, no model call**) |
| claude | `/share_session` | Same |
| codex | `/prompts:share_session` | Same (codex custom commands use the `prompts:` prefix) |

**Zero-token principle.** `./install.sh -y` also registers a `UserPromptSubmit` hook for each tool. When you type
`/share_session`, the hook fires **before the model is invoked**, directly runs the share command and returns the
links via `{"decision":"block"}` — the LLM never participates (measured `total_tokens: 0`, `rounds: 0`).

The output is **session-aware** — it always corresponds to the session you invoked it from, never another one:

- running in a **managed session** (`share new`) → link to that session's bidirectional terminal; ends with the process;
- running **inside tmux** → the link opens your current tmux session, **bidirectional** (watch and operate);
- running Claude in a **plain terminal** (no tmux) → the hook **auto-resumes that exact session**
  (`claude --resume <sid>`) as a managed session, so the link opens a **bidirectional web terminal continuing the
  same conversation**; if spawning fails (or `SS_HOOK_VIEW_ONLY=1` is set) it falls back to the **live read-only
  web view** (`/t/<sid>`), whose page has a one-click "🔄 在网页继续此会话" button to upgrade to a bidirectional
  terminal on demand;
- anything else → the session-monitor dashboard listing every running session.

Behind the scenes a local **session hub** (`share hub start`, port 7690 by default) keeps monitoring every running
session — managed sessions, Claude Code sessions, atomcode activity, and running ttyd services — and serves those
live views.

Example — typing `/share_session` in atomcode directly shows:

```
局域网访问: http://192.168.1.100:7681
浏览器登录: 用户名 ai，密码 <random token>
```

Open it in a browser, enter the username/password once, and keep operating the **same** session. Stop with
`/share stop` or `share stop`. Re-run `./install.sh -y` to install the command + hook for tools added later; if a
tool has no hook registered (e.g. you deleted its config), the command template still tells the AI to run the
command directly and show the raw output.

---

## Managed sessions · lifecycle-bound sharing (no tmux)

`share new` runs a command (e.g. `claude`) in a **hub-managed PTY** — no multiplexer, no extra daemon:

```bash
share new claude          # spawn Claude → attach locally → print LAN link
share new --no-attach bash
share attach <id>         # re-attach a local terminal (closing it does NOT end the session)
share kill <id>           # force-end
```

- The browser terminal (`/w/<id>`) is fully **bidirectional** — you and every viewer share one PTY; late joiners
  see recent output (replay buffer) and window resizing is propagated to the process.
- **Lifecycle is bound to the session**: when the process exits (e.g. you run `/exit` in Claude), the web session
  ends **automatically** — no `stop` needed. Closing your local terminal does *not* end it.
- `/share_session` inside a managed session prints exactly that session's link.

`share hub stop` refuses while managed sessions are running (use `SS_FORCE=1` to override).

---

## MCP server — operate sessions from any AI client

`./install.sh -y` also registers an MCP server (`mcp_server.py`, stdlib-only stdio JSON-RPC) into every detected
MCP-capable AI client (claude / atomcode / codex). Inside any of them you can now **view and operate every shared
session directly from the conversation**:

| Tool | Effect |
|------|--------|
| `list_sessions` | List every active session with status (managed / ttyd / Claude / atomcode) |
| `session_status` | One managed session's details: cmd / pid / clients / link / output preview |
| `spawn_session` | Start a new managed session (e.g. `claude`) and get its web link |
| `send_input` | Send keyboard input to a session — same PTY as the web page / `share attach` |
| `read_output` | Read a session's recent output (configurable tail) |
| `kill_session` | Force-end a session (process-group TERM→KILL) |

Example — in any MCP client, just say *"list my sessions"* → the AI calls `list_sessions`; *"spawn a claude
session"* → you get the URL; *"send 'ls -la' to it"* → the input lands in the same terminal the browser shows.
Sessions end automatically when their process exits.

The dashboard endpoint is globally discoverable via the `SS_HUB_URL` environment variable (`./install.sh -y` adds
it to your shell rc); `SS_HUB_TOKEN` provides the auth fallback. `share sessions` prints the same global view in
the terminal.

---

## Session hub · dashboard

`share hub start` (auto-started by `/share_session` when needed) runs a local dashboard on port **7690** that
monitors everything:

- **managed sessions** — spawn from the dashboard or `share new`; process exit (e.g. `/exit`) auto-ends the web session;
- **Claude Code sessions** — every `~/.claude/projects/**/**.jsonl` session with live status and an auto-refreshing
  read-only web view (`/t/<session-id>`), rendered as chat bubbles with tool calls, plus a one-click
  "🔄 在网页继续此会话" button that spawns `claude --resume` as a bidirectional managed terminal;
- **atomcode activity** — latest datalog per project with raw-tail views;
- **shared ttyd services** — all running shares with ports and links.

The same Basic Auth (user `ai` + random token) protects the dashboard and its views.

---

## Architecture

```
Local machine                                     LAN devices
┌─────────────────────────────────────────────┐   ┌──────────────────┐
│  session hub (hub_server.py, port 7690)     │   │  Browser         │
│                                             │   │                  │
│  ┌───────────────────────────────────────┐  │   │  xterm.js        │
│  │ managed PTY sessions (share new)      │◄─┼───┤  bidirectional   │
│  │  one PTY shared by everyone;          │  │   │  /w/<id>         │
│  │  process exit → auto end              │  │   │                  │
│  ├───────────────────────────────────────┤  │   │  /t/<claude-id>  │
│  │ Claude Code session monitor           │◄─┼───┤  read-only view  │
│  │  ~/.claude/projects/**/*.jsonl        │  │   │  (+resume button)│
│  ├───────────────────────────────────────┤  │   │                  │
│  │ atomcode activity / ttyd service list │  │   │  dashboard /     │
│  │ xterm.js assets (self-hosted)         │  │   │  (5s refresh)    │
│  └───────────────────────────────────────┘  │   └──────────────────┘
│        ▲ fork & monitor                     │
│  ┌─────┴────────────────────────────────┐    │
│  │ share.sh entry: ttyd service (7681)  │    │   Browser on ttyd
│  │  tmux session shared (legacy mode)   │◄───┼──►  /w/ via ttyd WS
│  └──────────────────────────────────────┘    │
│  hooks/install_hooks.py  /share_session (zero token, session-aware)
│  mcp_register.py → MCP clients (claude/atomcode/codex)
└─────────────────────────────────────────────┘
```

Key files: `share.sh` (entry + all CLI logic) → `hub_server.py` (dashboard + managed-PTY hosting + programmatic
API, stdlib-only) / `hub_attach.py` (local attach client) / `mcp_server.py` (MCP server) / `hooks/`
(zero-token session-aware UserPromptSubmit hook) / `install.sh` (cross-platform dependency installer + command /
hook / MCP / env registration).

---

## Flow · how a share gets started and continued

**Flow 1 — one-command / zero-token share:**

```
you type /share_session (or run share here)
   │
   ▼
UserPromptSubmit hook fires BEFORE the model (atomcode/claude/codex)
   │  runs: share here | share new --resume | hub start
   ▼
share.sh resolves session & port → starts ttyd (7681) or hub-managed PTY
   │
   ▼
prints: LAN URL + username ai + random password  (no URL-embedded credentials)
   │
   ▼
colleague opens URL in a browser → enters credentials once
   │
   ▼
browser shares the SAME PTY/tmux as local terminal → bidirectional continue
```

**Flow 2 — plain-terminal Claude (no tmux) gets a bidirectional web session:**

```
/share_session in plain-terminal Claude
   │
   ▼
hook auto-spawns: share new --no-attach claude --resume <sid>
   │  (SS_HOOK_VIEW_ONLY=1 or failure → read-only view /t/<sid> instead)
   ▼
hub forks claude --resume in a managed PTY → /w/<id> bidirectional terminal
   │
   ▼
browser keeps operating the SAME conversation; process exit (/exit) auto-ends it
```

**Flow 3 — managed-session lifecycle:**

```
share new claude ──► hub forks claude in PTY (SS_MANAGED_ID set)
   │                     │
   ├─ share attach <id> ◄┘  local terminal joins the same PTY
   ├─ browser /w/<id>   ◄┘  web terminal joins the same PTY
   ▼
process exits (e.g. /exit inside Claude)
   ▼
reader thread sees EOF → session ended → web page shows "会话已结束"
   (retained 120s for inspection, then auto-cleaned)
```

---

## Command reference

| Command | Effect |
|---------|--------|
| `./share.sh` / `./share.sh start [name]` | One command: ensure tmux session → serve → print link → attach (default session `ai`) |
| `./share.sh serve [name]` | Serve an existing tmux session only (for another terminal while you're busy) |
| `./share.sh here [name]` | **One-click share inside a session**: auto-detect the current tmux session and serve it |
| `./share.sh stop [name]` | Stop the web service; the tmux session is kept |
| `./share.sh status [name]` | Show service/session status and credentials |
| `./share.sh url [name]` | Re-print the access link and credentials |
| `./share.sh new [--no-attach] <cmd...>` | Managed session (hub PTY, no tmux): spawn → print link → (attach) |
| `./share.sh attach <id>` | Re-attach a local terminal to a managed session |
| `./share.sh kill <id>` | Force-end a managed session |
| `./share.sh hub [action]` | Dashboard: `start`/`stop`/`status`/`url` (default `start`, port 7690) |
| `./share.sh sessions` | Global view of every active session (managed / ttyd / Claude / atomcode) |
| `./share.sh doctor` | Environment self-check (deps / ports / LAN IP) |
| `./share.sh help` | Help |

## Configuration (environment variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `SS_SESSION` | `ai` | Default tmux session name |
| `SS_PORT` | `7681` | Service port (explicit occupied → error; unset while occupied → auto-increment 7682/7683…) |
| `SS_HOST` | `0.0.0.0` | Listen address (usually unchanged) |
| `SS_HUB_PORT` | `7690` | Dashboard port |
| `SS_HUB_URL` | added to shell rc by install.sh | Global hub endpoint (`http://127.0.0.1:7690`) — any terminal / AI client discovers the dashboard via it |
| `SS_HUB_TOKEN` | — | Hub auth token via env (fallback when `hub.state` is unavailable) |
| `SS_STATE_DIR` | `~/.ai-session-share` | State directory (shared by share.sh / hook / hub); created with `0700` perms |
| `SS_NO_AUTH` | empty | Set `1` to disable login auth (**not recommended**) |

State files live in `~/.ai-session-share/` (local only, `0700`, never committed): `<session>.pid` /
`<session>.state` / `<session>.log`, plus `hub.pid` / `hub.state` / `hub.log` and cached `/assets/`.

---

## Security (please read)

**Link + password = the keys to your machine.** Anyone with the credentials can execute arbitrary commands in your
terminal (same as you operating it).

- Basic Auth is on by default: every `start/serve/here` generates a **random token** as the password (username is
  fixed as `ai`); the password is printed in the terminal — enter it in the browser.
- Recommended for trusted networks only (enterprise intranet / home Wi-Fi); run `./share.sh stop` when done.
- Do **not** use `SS_NO_AUTH=1` (only on a fully trusted network, and you know the consequences).
- **Never** expose ports 7681/7690 to the public internet (frp / router port-forwarding / ngrok) — that is
  publishing your terminal and your AI session transcripts.
- Tokens are stored in `~/.ai-session-share/*.state`, inside a `0700` directory; do not share that directory.
- **Modern browsers disable URL-embedded credentials** (`http://ai:password@IP:port` no longer auto-logs-in), so
  the tool never prints such links — type the username/password once and the browser remembers them per-site.
- **Passwordless login link** (dashboard / managed sessions / live views support it): `http://IP:port/path?key=password`
  — opening it logs in automatically and sets a 30-day cookie, so refreshes/navigation never ask again. This is a
  plain query parameter (not the blocked "URL-embedded credentials"), but **sharing this link is the same as
  sharing the password** — treat it accordingly and only use it on trusted networks. The legacy ttyd bridge
  (`/open/<port>`) doesn't support this and still needs the service's own username/password typed in.

---

## Advantages · why this instead of alternatives

| Solution | Sharing method | Bidirectional | Bound to a tool | Needs public network / cloud |
|----------|----------------|:---:|:---:|:---:|
| **This repo** | LAN link, browser direct | ✅ | No (generic) | No, pure LAN |
| tmate | Link relayed via tmate.io | ✅ | No | Yes (tmate.io) |
| Claude Code Remote Control | Official session URL / QR | ✅ | Claude Code only | Yes (Anthropic relay) |
| Code-Cast / session export | Read-only web replay | ❌ | Claude Code/Codex etc. | Yes (code-cast.dev) |

Key advantages:

1. **Generic, not AI-tool-bound** — works for any terminal process (AI agents, data exports, debugging); the
   AI-tool integrations (zero-token `/share_session`, MCP) are add-ons, not prerequisites.
2. **Truly bidirectional with identical context** — everyone shares the *same* PTY; late joiners see the replay,
   resizing propagates, and the browser can keep operating where the local terminal left off.
3. **Lifecycle that makes sense** — managed sessions auto-end when the process exits (`/exit`), so there is no
   forgotten orphan service; closing your local terminal does *not* kill the session.
4. **No public cloud, no relay** — works entirely on your LAN; nothing leaves the network (important for
   transcripts and tokens).
5. **Zero token for AI users** — `/share_session` fires a `UserPromptSubmit` hook *before* the model, returning
   links without consuming any reasoning tokens (measured `total_tokens: 0`).
6. **Session-aware output** — you always get the link to *your* session; plain-terminal Claude is auto-resumed as a
   managed session, and a read-only view can be upgraded to bidirectional with one click.
7. **Self-contained web terminal** — xterm.js is self-hosted (no external CDN), so Tracking Prevention and
   intranet isolation never break the terminal page.
8. **Stdlib-only** — `hub_server.py`, `mcp_server.py` and the hook use only the Python standard library; no
   npm/pip dependency tree to maintain.

---

## FAQ

**What if multiple people type at once?** Everyone shares one terminal; inputs compete (like tmate collaboration).
Best for "one driver, others watching/supplementing"; the browser always shows the live screen.

**Can a phone access it?** Yes. ttyd bundles xterm.js with a touch virtual keyboard — great for following long
tasks on a phone.

**Can I make it view-only?** This repo is bidirectional by design. For read-only, use `tmate` (built-in read-only
links), or share the token only with trusted people.

**I run Claude in a plain terminal (not tmux) — what does /share_session give me?** The hook **auto-resumes that
exact session** as a managed session (`claude --resume <session-id>`, spawned by the hub), so the link opens a
**bidirectional web terminal continuing the same conversation** — the browser can type into it right away, and it
ends when the resumed process exits. If the auto-spawn fails (or `SS_HOOK_VIEW_ONLY=1`), you still get the **live
read-only view** (`/t/<id>`, 2s refresh) whose page has a "🔄 在网页继续此会话" button to upgrade to a
bidirectional terminal on demand.

**Does exiting tmux / closing the terminal affect the service?** No. ttyd is an independent background process;
only `stop` closes it. Session data stays in tmux — `tmux attach -t ai` anytime.

**Port occupied?** `SS_PORT=9000 ./share.sh` (`doctor` checks port availability first).

**Browser says wrong password / can't log in?** The server auth chain is fine (no credentials always returns 401).
Common causes:
1. **Password changed after a service restart** — every `start/serve/here` regenerates the token, and browsers
   cache old credentials; use an **incognito window** or `./share.sh url` to reprint the current password.
2. Modern browsers have **disabled URL-embedded credentials** (`http://ai:password@IP:port` no longer
   auto-logs-in) — type the username/password into the browser's login box once; the browser caches them per-site,
   so later visits need no re-entry; re-print the current password anytime with `./share.sh url`.
3. Make sure you open the LAN IP printed in the terminal (same Wi-Fi); mobile data cannot reach it.

**Missing tmux/ttyd?** `./install.sh -y` (macOS uses brew; Linux uses apt/dnf/yum). Windows users can use WSL.

**Chinese garbled in the browser?** ttyd supports CJK; if your locale is non-UTF-8, run
`export LANG=en_US.UTF-8` in the session first.

---

## Development / testing

```bash
bash -n share.sh install.sh                          # shell syntax check
python3 -m py_compile hub_server.py hooks/*.py       # python syntax check
./share.sh doctor                                    # environment self-check
tests/test.sh                                        # full smoke test: deps / subcommands / real start-stop /
                                                     # hub / hook / WS write path / MCP / ports (79 checks)
```

Architecture: `share.sh` (entry + all logic) → depends on `tmux` (legacy mode), `ttyd` (WebSocket terminal),
`openssl` (token), `python3` (hub/MCP); `install.sh` (cross-platform dependency installer);
`hub_server.py` (dashboard + managed-PTY hosting + programmatic API, stdlib-only);
`hub_attach.py` (local attach client); `mcp_server.py` (MCP server for AI clients);
`commands/share_session.md` (slash-command template) + `hooks/` (zero-token session-aware UserPromptSubmit hook).

---

## License

MIT License — see [LICENSE](LICENSE).


