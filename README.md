# ai-session-share

**Share your live terminal session as a LAN web service — one command.**

**把本地终端会话共享成局域网 Web 服务——一条命令输出链接。**

Anyone on your LAN can open the link in a browser to **watch and keep working on** your session in real time (including a running AI coding agent), with identical context — because everyone shares the *same* tmux terminal.

局域网内任何人在浏览器打开链接,就能**实时查看并继续**你的会话(包括正在跑的 AI 工具),会话上下文天然一致——因为所有人共享的是**同一个** tmux 终端。

```bash
./install.sh -y      # install deps (tmux / ttyd / openssl) once · 一次性安装依赖
./share.sh           # start: create tmux session → serve → print link → attach · 一条命令:起服务 → 打印链接 → 进入会话
```

Open `http://<LAN-IP>:7681` in a browser, enter the printed username/password, and you are operating the same session as the local terminal.

浏览器打开 `http://<局域网IP>:7681`,输入终端里显示的账号密码,即可看到并操作你当前正在跑的会话。

---

## What problem does it solve · 它解决什么问题

You started a long-running task in a local terminal (AI coding agent, data export, debugging…), and mid-way you want a colleague / your phone to **take over and continue** — not to have them read a summary and redo it.

你在本地终端里跑了一个长任务(AI 编码助手、数据导出、调试排查……),中途想让同事/手机**接过来继续**,而不是把过程总结给他、让他重跑。

> Two kinds of sharing:
> 注意区分两类共享:
>
> - **Read-only replay** (watch the process) — many mature options exist (Code-Cast, session export, GitHub Gist…).
>   **只读回放**(看过程)——已有大量成熟方案(Code-Cast、会话导出、GitHub Gist 等)。
> - **Bidirectional continuation** (can operate) — this repo does exactly this, and it is **not bound to any AI tool**; it is generic terminal sharing.
>   **双向继续**(能操作)——本仓库做的就是这件事,且**不绑定任何 AI 工具**,通用终端共享。

---

## Quick start · 快速开始

```bash
# 1. Install dependencies (macOS / Linux), also installs the `share` command · 安装依赖,并自动安装 share 命令
./install.sh -y

# 2. One command: create/reuse tmux session → start web service → print LAN link → enter session
#    一条命令:创建/复用 tmux 会话 → 起 Web 服务 → 打印局域网链接 → 进入会话
./share.sh

# 3. Run your AI tool inside the session (atomcode / claude / any command); the session is now shared
#    在会话里运行你的 AI 工具(如 atomcode / claude / 任意命令),会话即被共享
# 4. Open the printed link in any browser (computer / phone), enter the printed credentials, and keep operating the same session
#    浏览器(电脑/手机均可)访问输出的链接,输入打印的账号密码,即可继续操作同一会话
```

If you are already working inside a tmux session (e.g. an AI tool is running), run **right inside that session**:

如果已经在 tmux 会话里干活了(比如 AI 工具正在跑),**直接在会话里**执行:

```bash
share here        # auto-detect the CURRENT tmux session and serve it · 自动识别"当前所在的" tmux 会话并起服务
share stop        # stop the web service (session kept) · 停止 Web 服务(会话保留,可再 share here 恢复)
```

> `./install.sh -y` installs a `share` command (`~/.local/bin/share`) so you can run `share here`
> from any directory, in any tmux session — no need to open another terminal or remember session names.
> Without it, the equivalent is `./share.sh here`.
>
> `./install.sh -y` 会把入口安装为 `share` 命令(`~/.local/bin/share`),之后在任意目录、任意 tmux 会话内都能直接
> `share here` 共享当前会话,无需另开终端、无需记会话名。若未安装 share 命令,等价写法是 `./share.sh here`。

### Use `/share_session` directly inside AI tools (zero token) · 在 AI 工具里直接 `/share_session`(零 token)

`./install.sh -y` **auto-detects installed AI tools** (atomcode / claude / codex) and symlinks a command template
into each tool's global commands directory. You no longer need to type shell commands — just type the slash
command in the AI tool's conversation:

`./install.sh -y` 会**自动检测本机已安装的 AI 工具**(atomcode / claude / codex),把共享命令模板软链到各工具的
全局命令目录。之后**不用敲 shell 命令**,直接在 AI 工具的对话里输入:

| AI tool · AI 工具 | Type · 输入 | Effect · 效果 |
|---------|------|------|
| atomcode | `/share_session` | Directly prints the access link + credentials (**zero token, no model call**) · 直接输出访问链接、账号密码(**零 token,不经模型**) |
| claude | `/share_session` | Same · 同上 |
| codex | `/prompts:share_session` | Same (codex custom commands use the `prompts:` prefix) · 同上(codex 的自定义命令带 `prompts:` 前缀) |

> **Zero-token principle · 零 token 原理**: `./install.sh -y` also registers a `UserPromptSubmit` hook for each tool.
> When you type `/share_session`, the hook fires **before the model is invoked**, directly runs `share here`, and
> returns the links via `{"decision":"block"}` — the LLM never participates (measured `total_tokens: 0`, `rounds: 0`).
> The output is **session-aware** — it always corresponds to the session you invoked it from, never another one:
>
> - running **inside tmux** → the link opens your current tmux session, **bidirectional** (watch and operate);
> - running Claude in a **plain terminal** (no tmux) → the link opens the **live web view of that exact Claude session**
>   (read-only, real-time refresh), plus a hint for getting a bidirectional terminal;
> - anything else → the session-monitor dashboard listing every running session.
>
> `./install.sh -y` 同时会给各工具注册一个 `UserPromptSubmit` hook。输入 `/share_session` 时,hook 在**模型介入前**
> 直接执行共享命令并把链接通过 `{"decision":"block"}` 原样返回给用户——LLM 完全不参与(实测 `total_tokens: 0` / `rounds: 0`),
> 不消耗任何推理 token。输出是**会话感知**的——永远对应你调用它的那个会话,不会打印无关会话的链接:
>
> - 在 **tmux 会话内**运行 → 链接打开的就是当前 tmux 会话,**双向可操作**;
> - 在**普通终端**(未用 tmux)运行 Claude → 链接打开的是**这个 Claude 会话的实时网页视图**(只读、实时刷新),
>   并附上如何获得双向终端的提示;
> - 其他情况 → 会话监控面板首页(列出所有运行中的会话)。
>
> Behind the scenes a local **session hub** (`share hub start`, port 7690 by default) keeps monitoring every running
> session — tmux sessions, Claude Code sessions, atomcode activity — and serves those live views.
> 背后由本机常驻的**会话监控面板**(`share hub start`,默认端口 7690)支撑:持续监控所有运行中的会话
> ——tmux 会话、Claude Code 会话、atomcode 活动——并承载上述实时视图。
>
> Example — typing `/share_session` in atomcode directly shows:
> 例如在 atomcode 里输入 `/share_session`,会直接看到:
> `局域网访问: http://10.254.51.121:7681` / `一键登录: http://ai:密码@10.254.51.121:7681`.
> Open it in a browser to keep operating the **same** session. Stop with `/share stop` or `share stop`.
> Re-run `./install.sh -y` to install the command + hook for tools added later.
> If a tool has no hook registered (e.g. you deleted the config), the command template still tells the AI to
> run the command directly and show the raw output.
>
> 浏览器打开即可继续操作**同一个**会话。停止共享用 `/share stop` 或 `share stop`。重新运行 `./install.sh -y`
> 即可为后来安装的工具补装命令与 hook。若某工具未注册 hook(比如手动删除过配置),命令模板仍会提示 AI 直接执行并原样展示输出。

---

## Session hub · 会话监控面板

`share hub start` (auto-started by `/share_session` when needed) runs a local dashboard on port **7690**:

`share hub start`(`/share_session` 需要时会自动拉起)在 **7690** 端口起一个本机监控面板:

- **tmux sessions** — listed with one-click "共享此会话" buttons; already-shared ones show direct links;
  **tmux 会话** — 列表 + 一键"共享此会话"按钮,已共享的直接给链接;
- **Claude Code sessions** — every `~/.claude/projects/**/**.jsonl` session with live status, auto-refreshing
  read-only web view (`/t/<session-id>`), rendered as chat with tool calls;
  **Claude Code 会话** — 监控所有会话文件与活跃状态,提供自动刷新的只读网页视图(`/t/<会话id>`),按对话气泡渲染、含工具调用;
- **atomcode activity** — latest datalog per project with raw-tail views;
  **atomcode 活动** — 各项目最新日志与原始尾部视图;
- **shared ttyd services** — all running shares with ports and links.
  **共享中的 ttyd 服务** — 所有在跑的共享及其端口与链接。

The same Basic Auth (user `ai` + random token) protects the dashboard and its views.
面板与其视图使用与终端共享相同的 Basic Auth(用户名 `ai` + 随机 token)。

---

## How it works · 工作原理

```
本机 Local machine                    局域网其他设备 LAN device
┌─────────────────────────┐        ┌──────────────────┐
│  tmux 会话(session)      │        │  浏览器 Browser    │
│  ├─ 你(本机 attach)       │        │  xterm.js 终端     │
│  └─ ttyd 进程 ──WebSocket┼────────┤  输入/输出双向      │
└─────────────────────────┘        └──────────────────┘
        ▲ Everyone sees/operates the SAME tmux terminal · 所有人看到/操作的是同一个 tmux 终端

┌─────────────────────────┐        ┌──────────────────┐
│  会话监控面板(hub)        │        │  浏览器 Browser    │
│  ├─ tmux 会话列表         │        │  仪表盘(5s 刷新)   │
│  ├─ Claude 会话 jsonl ────┼────────┤  实时会话视图(只读) │
│  └─ atomcode 活动日志     │        │                  │
└─────────────────────────┘        └──────────────────┘
        ▲ hub (port 7690) monitors every running session · 面板监控所有运行中的会话
```

- **tmux** holds the real session: you and every browser user attach to the *same* session, so context is naturally identical.
  **tmux** 持有真正的会话:你、浏览器用户都 attach 到同一个会话,上下文天然一致;
- **ttyd** exposes that session as a WebSocket terminal (xterm.js); browsers need nothing installed.
  **ttyd** 把该会话暴露成 WebSocket 终端(xterm.js),浏览器无需装任何东西;
- **hub** (`hub_server.py`, stdlib-only) is the always-on dashboard: it monitors tmux sessions (with one-click
  "share this session" buttons), Claude Code sessions (rendered as live web views), atomcode activity, and all
  running ttyd services. `/share_session` in a plain-terminal Claude links straight into its live view.
  **hub**(`hub_server.py`,仅标准库)是常驻监控面板:监控 tmux 会话(可一键"共享此会话")、Claude Code 会话
  (渲染为实时网页视图)、atomcode 活动与所有在跑的 ttyd 服务;普通终端里的 Claude 执行 `/share_session`
  就直接给出该会话实时视图的链接;
- The service runs in the background: detaching from tmux / closing the terminal does **not** stop sharing; only `stop` does.
  服务跑在后台,你退出 tmux / 关掉终端都**不会**中断共享,`stop` 才真正关闭。

> **Why tmux? · 为什么需要 tmux?** `ttyd bash` spawns a *fresh, independent* shell per browser connection —
> two users would each get their own terminal, unable to continue each other's work. `ttyd tmux new -A -s <name>`
> makes every connection attach to the **same** session, which is exactly what "other users continue the target
> session" means — and browser users never need to know tmux exists.
>
> `ttyd bash` 每次连接都会启动一个**全新独立**的 shell——两个用户各开各的终端,无法"继续同一会话"。
> `ttyd tmux new -A -s <name>` 让所有连接 attach 到**同一个**会话,这正是"其他用户在目标 session 下继续会话"
> 的实现机制;而浏览器用户全程感知不到 tmux 的存在。

---

## Command reference · 命令参考

| Command · 命令 | Effect · 作用 |
|------|------|
| `./share.sh` / `./share.sh start [name]` | One command: ensure tmux session → serve → print link → attach (default session `ai`) · 一条命令:确保 tmux 会话 → 起 Web 服务 → 打印链接 → 进入会话(默认会话名 `ai`) |
| `./share.sh serve [name]` | Serve an existing tmux session only (for another terminal while you're busy) · 只起 Web 服务,共享一个已有 tmux 会话(适合已在会话里干活时另开终端调用) |
| `./share.sh here [name]` | **One-click share inside a session**: auto-detect the current tmux session and serve it · **会话内一键共享**:自动识别当前所在的 tmux 会话并起服务(无需另开终端、无需记会话名) |
| `./share.sh stop [name]` | Stop the web service; tmux session is kept · 停止 Web 服务,tmux 会话保留 |
| `./share.sh status [name]` | Show service/session status and credentials · 查看服务/会话状态与认证信息 |
| `./share.sh url [name]` | Re-print the access link and credentials · 重新打印访问链接与账号密码 |
| `./share.sh hub [action]` | Session-monitor dashboard: `start`/`stop`/`status`/`url` (default `start`, port 7690) · 会话监控面板:启动/停止/状态/链接 |
| `./share.sh doctor` | Environment self-check (deps / ports / LAN IP) · 环境自检(依赖/端口/局域网 IP) |
| `./share.sh help` | Help · 帮助 |

## Configuration (environment variables) · 配置(环境变量)

| Variable · 变量 | Default · 默认 | Description · 说明 |
|------|------|------|
| `SS_SESSION` | `ai` | Default tmux session name · 默认 tmux 会话名 |
| `SS_PORT` | `7681` | Service port (occupied → error; unset while multiple shares run → auto-increment 7682/7683…) · 服务端口(显式指定被占时报错;未指定且被占时自动顺延) |
| `SS_HOST` | `0.0.0.0` | Listen address (usually unchanged) · 监听地址(一般不用改) |
| `SS_HUB_PORT` | `7690` | Session-hub dashboard port · 会话监控面板端口 |
| `SS_STATE_DIR` | `~/.ai-session-share` | State directory (used by share.sh / hook / hub together) · 状态目录(share.sh/hook/hub 共用) |
| `SS_NO_AUTH` | empty · 空 | Set `1` to disable login auth (**not recommended**) · 设 `1` 关闭登录认证(**不推荐**,见下) |

State files live in `~/.ai-session-share/` (local only, not committed): `<session>.pid` / `<session>.state` / `<session>.log`
and `hub.pid` / `hub.state` / `hub.log` for the dashboard.
状态文件位于 `~/.ai-session-share/`(本机自用,不入库):`<session>.pid` / `<session>.state` / `<session>.log`,
面板另有 `hub.pid` / `hub.state` / `hub.log`。

---

## Security (please read) · 安全(务必阅读)

**Link + password = the keys to your machine.** Anyone with the credentials can execute arbitrary commands in
your terminal (same as you operating it).
**链接 + 密码 = 你机器的钥匙。** 拿到凭证的任何人可以在你的终端里执行任意命令(等同你本人在操作)。

- Basic Auth is on by default: every `start/serve` generates a **random token** as the password (username is fixed as `ai`); the password is printed in the terminal — enter it in the browser.
  默认开启 Basic Auth:每次 `start/serve` 生成**随机 token** 作为密码(用户名固定 `ai`),密码会打印在终端里,浏览器访问时输入即可;
- Recommended for trusted networks only (enterprise intranet / home Wi-Fi); run `./share.sh stop` when done.
  建议仅在企业内网 / 家庭可信网络使用;用完执行 `./share.sh stop`;
- Do **not** use `SS_NO_AUTH=1` (only on a fully trusted network, and you know the consequences).
  不要用 `SS_NO_AUTH=1`(仅限完全可信网络且你清楚后果);
- **Never** expose ports 7681/7690 to the public internet (frp / router port-forwarding / ngrok) — that is publishing your terminal and your AI session transcripts.
  **不要**把端口 7681/7690 转发到公网(frp / 路由器端口映射 / ngrok),等于把终端与 AI 会话内容公开;
- Tokens are stored in `~/.ai-session-share/*.state` (0700 directory); do not share that directory.
  token 存于 `~/.ai-session-share/*.state`(本机 700 权限目录),勿分享该目录。

---

## FAQ · 常见问题

**What if multiple people type at once? · 多人同时输入会怎样?**
Everyone shares one terminal; inputs compete (like tmate collaboration). Best for "one driver, others watching/supplementing"; the browser always shows the live screen.
所有人共享同一个终端,输入会互相竞争(和 tmate 多人协作一样)。适合"一人主导、他人旁观/补充"的场景;浏览器端默认看到的就是当前实时画面。

**Can a phone access it? · 手机能访问吗?**
Yes. ttyd bundles xterm.js with a touch virtual keyboard — great for following long tasks on a phone.
可以。ttyd 内置 xterm.js,触屏虚拟键盘可用,适合手机跟进长任务。

**Can I make it view-only? · 想只读观看(不让对方操作)?**
This repo is bidirectional by design. For read-only, use `tmate` (built-in read-only links), or share the token only with trusted people.
本仓库是双向共享。只读场景可用 `tmate`(自带 read-only 链接),或把本仓库的 token 只发给可信的人。

**I run Claude in a plain terminal (not tmux) — what does /share_session give me? · 不在 tmux 里跑 Claude,/share_session 给我什么?**
You get the **live web view of that exact Claude session** (read-only, 2s refresh) — perfect for watching from a
phone / another desk. To let the browser **type into** the session, Claude must run inside tmux: `share start`
(enter tmux) then run `claude --resume <session-id>` there, and `/share_session` again — now the link is a
full bidirectional terminal.
得到的是**该 Claude 会话的实时网页视图**(只读、2s 刷新)——手机/同事旁观足够了。要让浏览器能**直接输入**,
Claude 必须跑在 tmux 里:`share start` 进入 tmux 后运行 `claude --resume <会话id>`,再执行一次 `/share_session`——
这次链接就是可双向操作的完整终端。

**Does exiting tmux / closing the terminal affect the service? · 退出 tmux / 关终端会影响服务吗?**
No. ttyd is an independent background process; only `stop` closes it. Session data stays in tmux — `tmux attach -t ai` anytime.
不会。ttyd 是独立后台进程,`stop` 才关闭;会话数据在 tmux 里,随时 `tmux attach -t ai` 回来。

**Port occupied? · 端口被占用怎么办?**
`SS_PORT=9000 ./share.sh` (`doctor` checks port availability first).
`SS_PORT=9000 ./share.sh`(`doctor` 会先检查端口占用)。

**Browser says wrong password / can't log in? · 浏览器提示密码错误/登录不上?**
The server auth chain is fine (no credentials always returns 401). Common causes:
服务端认证链路是正常的(无凭据必返回 401)。常见原因是:
1. **Password changed after a service restart** — every `start/serve/here` regenerates the token, and browsers cache old credentials; use an **incognito window** or `./share.sh url` to reprint the current password.
   **服务重启后密码变了**——每次 `start/serve/here` 都会重新生成 token,浏览器常缓存旧密码;请换**无痕窗口**,或用 `./share.sh url` 重新打印当前密码;
2. Typing a 32-char password is error-prone — copy the printed **one-click login link** (`http://ai:password@IP:port`) instead.
   手输 32 位密码容易看错——直接复制终端里打印的**一键登录链接**(`http://ai:密码@IP:端口`),点开即用,无需手输;
3. Make sure you open the LAN IP printed in the terminal (same Wi-Fi); mobile data cannot reach it.
   确认访问的是终端里打印的局域网 IP(同一 Wi-Fi 下),手机用流量访问会打不开。

**Missing tmux/ttyd? · 没有 tmux/ttyd 怎么办?**
`./install.sh -y` (macOS uses brew; Linux uses apt/dnf/yum). Windows users can use WSL.
`./install.sh -y`(macOS 走 brew,Linux 走 apt/dnf/yum)。Windows 用户可用 WSL。

**Chinese garbled in the browser? · 浏览器端中文乱码?**
ttyd supports CJK; if your locale is non-UTF-8, run `export LANG=en_US.UTF-8` in the session first.
ttyd 支持 CJK;若本地 locale 非 UTF-8,先在会话里 `export LANG=en_US.UTF-8`。

---

## Comparison with other solutions · 与其他方案对比

| Solution · 方案 | Sharing method · 共享方式 | Bidirectional · 双向操作 | Bound to a tool · 绑定工具 | Needs public network / cloud · 是否需要公网/云 |
|------|----------|:---:|:---:|:---:|
| **This repo (ttyd + tmux) · 本仓库** | LAN link, browser direct · 局域网链接,浏览器直连 | ✅ | No (generic) · 无(通用终端) | No, pure LAN · 否,纯局域网 |
| tmate | Link relayed via tmate.io · 经 tmate.io 中转的链接 | ✅ | No · 无 | Yes (tmate.io) · 是 |
| Claude Code Remote Control | Official session URL / QR · 官方会话 URL / 二维码 | ✅ | Claude Code only · 仅 Claude Code | Yes (Anthropic relay) · 是(Anthropic 中转) |
| Code-Cast / session export · 会话导出 | Read-only web replay · 只读网页回放 | ❌ | Claude Code/Codex etc. | Yes (code-cast.dev) · 是 |

---

## Development / testing · 开发 / 测试

```bash
bash -n share.sh install.sh        # syntax check · 语法检查
python3 -m py_compile hub_server.py hooks/*.py   # python syntax check · Python 语法检查
./share.sh doctor                  # environment self-check · 环境自检
./share.sh status                  # service status · 服务状态
tests/test.sh                      # smoke test: deps / subcommands / real start-stop / hub / hook / ports · 冒烟测试(依赖/子命令/真实起停/面板/hook/端口)
```

Architecture · 架构: `share.sh` (entry + all logic · 入口+全部逻辑) → depends on `tmux` (session holder · 会话持有),
`ttyd` (WebSocket terminal), `openssl` (token generation), `python3` (hub); `install.sh` (cross-platform dependency installer · 跨平台依赖安装);
`hub_server.py` (session-monitor dashboard + Claude live views · 会话监控面板 + Claude 实时视图);
`commands/share_session.md` (slash-command template · 斜杠命令模板) + `hooks/` (zero-token session-aware UserPromptSubmit hook · 零 token 会话感知 hook).

## License · 许可

MIT License · MIT 许可,见 [LICENSE](LICENSE)。
