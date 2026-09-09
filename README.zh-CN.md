# ai-session-share

**把本地终端会话共享成局域网 Web 服务——一条命令输出链接。**

局域网内任何人在浏览器打开链接,就能**实时查看并继续**你的会话(包括正在跑的 AI 编码助手),会话上下文天然一致——
因为所有人共享的是**同一个**终端。

[English documentation (English)](README.md)

```bash
./install.sh -y      # 一次性安装依赖 (tmux / ttyd / openssl / python3)
./share.sh           # 一条命令:起服务 → 打印链接 → 进入会话
```

浏览器打开 `http://<局域网IP>:7681`,输入终端里打印的账号密码,即可看到并操作你当前正在跑的会话。
注意:现代浏览器已**禁用"URL 内嵌账号密码"自动登录**,手动输入一次账号密码即可,浏览器会记住,之后访问免输。

---

## 它解决什么问题

你在本地终端里跑了一个长任务(AI 编码助手、数据导出、调试排查……),中途想让同事/手机**接过来继续**,而不是把过程总结给他、让他重跑。

这里要区分两类共享:

- **只读回放**(看过程)——已有大量成熟方案(Code-Cast、会话导出、GitHub Gist 等)。
- **双向继续**(能操作)——**本仓库做的就是这件事**,且**不绑定任何 AI 工具**:它是通用终端共享,任何进程都能用。

---

## 功能一览

| 功能 | 说明 |
|---|---|
| 一条命令局域网共享 | `./share.sh` / `share here`:局域网内任意浏览器实时打开你的终端 |
| 天生双向 | 浏览器用户与本地共享**同一个 PTY**,能操作而不只是观看 |
| 零 token 的 `/share_session` | 在 atomcode / claude / codex 里输入斜杠命令 → **模型介入前**直接返回链接(实测 `total_tokens: 0`) |
| 会话感知输出 | 链接永远对应你调用它的那个会话,绝不打印无关会话 |
| 托管会话 | `share new` — 面板自管 PTY,无需 tmux;进程退出(如 `/exit`)**自动结束**网页会话 |
| 会话监控面板 | `share hub start`(默认端口 7690):监控托管 / Claude Code / atomcode / ttyd 会话 |
| 网页端继续会话 | 一键"🔄 在网页继续此会话"把只读视图升级为双向终端(`claude --resume`) |
| MCP 服务器 | 任何 MCP 客户端可直接 `list_sessions` / `spawn_session` / `send_input` / `read_output` / `kill_session` |
| 终端页自包含 | xterm.js 自托管(零外部 CDN),Tracking Prevention / 内网隔离都弄不坏终端页 |
| 默认开启认证 | Basic Auth + 每次启动随机 token(用户名 `ai`);`SS_NO_AUTH=1` 仅限完全可信网络 |

---

## 快速开始

```bash
# 1. 安装依赖(macOS / Linux);同时为检测到的 AI 工具安装 share 命令、斜杠命令模板、
#    零 token hook、MCP 注册与 SS_HUB_URL 环境变量
./install.sh -y

# 2. 一条命令:创建/复用 tmux 会话 → 起 Web 服务 → 打印局域网链接 → 进入会话
./share.sh

# 3. 在会话里运行你的 AI 工具(atomcode / claude / 任意命令)——会话即被共享
# 4. 浏览器(电脑/手机均可)访问输出的链接,输入打印的账号密码一次,即可继续操作同一会话
```

如果已经在 tmux 会话里干活了(比如 AI 工具正在跑),**直接在会话里**执行:

```bash
share here        # 自动识别"当前所在的" tmux 会话并起服务
share stop        # 停止 Web 服务(tmux 会话保留,可随时 share here 恢复)
```

> `./install.sh -y` 会把入口安装为 `share` 命令(`~/.local/bin/share`),之后在任意目录、任意 tmux 会话内都能
> 直接 `share here` 共享当前会话,无需另开终端、无需记会话名。若未安装 share 命令,等价写法是 `./share.sh here`。

### 在 AI 工具里直接 `/share_session`(零 token)

`./install.sh -y` 会**自动检测本机已安装的 AI 工具**(atomcode / claude / codex),把共享命令模板软链到各工具的
全局命令目录。之后**不用敲 shell 命令**,直接在 AI 工具的对话里输入:

| AI 工具 | 输入 | 效果 |
|---------|------|------|
| atomcode | `/share_session` | 直接输出访问链接、账号密码(**零 token,不经模型**) |
| claude | `/share_session` | 同上 |
| codex | `/prompts:share_session` | 同上(codex 的自定义命令带 `prompts:` 前缀) |

**零 token 原理。** `./install.sh -y` 同时会给各工具注册一个 `UserPromptSubmit` hook。输入 `/share_session` 时,
hook 在**模型介入前**直接执行共享命令,并把链接通过 `{"decision":"block"}` 原样返回给用户——LLM 完全不参与
(实测 `total_tokens: 0` / `rounds: 0`),不消耗任何推理 token。

输出是**会话感知**的——永远对应你调用它的那个会话,不会打印无关会话的链接:

- 在**托管会话**(`share new`)内运行 → 输出该会话的双向终端链接,随进程结束而结束;
- 在 **tmux 会话内**运行 → 链接打开的就是当前 tmux 会话,**双向可操作**;
- 在**普通终端**(未用 tmux)运行 Claude → hook 会用 `claude --resume <会话id>` **自动把该会话续为托管会话**,
  链接打开的是延续同一对话的**双向网页终端**;若启动失败(或设 `SS_HOOK_VIEW_ONLY=1`)则退回该会话的
  **只读实时视图**(`/t/<会话id>`,页面上有"🔄 在网页继续此会话"按钮,点击即转为双向终端);
- 其他情况 → 会话监控面板首页(列出所有运行中的会话)。

背后由本机常驻的**会话监控面板**(`share hub start`,默认端口 7690)支撑:持续监控所有运行中的会话——托管会话、
Claude Code 会话、atomcode 活动、在跑的 ttyd 服务——并承载上述实时视图。

例如在 atomcode 里输入 `/share_session`,会直接看到:

```
局域网访问: http://192.168.1.100:7681
浏览器登录: 用户名 ai，密码 <随机token>
```

浏览器打开,输入一次账号密码,即可继续操作**同一个**会话。停止共享用 `/share stop` 或 `share stop`。
重新运行 `./install.sh -y` 即可为后来安装的工具补装命令与 hook;若某工具未注册 hook(比如手动删除过配置),
命令模板仍会提示 AI 直接执行并原样展示输出。

---

## 托管会话(生命周期绑定,无需 tmux)

`share new` 把命令(如 `claude`)跑在**面板自管的 PTY** 里——无需多路复用器与额外守护进程:

```bash
share new claude          # 启动 Claude → 本机进入 → 打印局域网链接
share new --no-attach bash
share attach <id>         # 本机终端再次连接(关闭终端不会结束会话)
share kill <id>           # 强制结束
```

- 网页终端(`/w/<id>`)完全**双向**——你与所有观看者共用同一个 PTY;晚打开的也能看到最近输出(回放缓存),
  窗口尺寸变化会同步给进程。
- **生命周期与会话绑定**:进程退出(如在 Claude 里执行 `/exit`)后网页会话**自动结束**,无需任何 `stop`;
  关闭本机终端*不会*结束会话。
- 在托管会话里执行 `/share_session`,输出的就是该会话的链接。

还有托管会话在运行时 `share hub stop` 会拒绝执行(确认可用 `SS_FORCE=1`)。

---

## MCP 服务器(多 AI 客户端操作会话)

`./install.sh -y` 同时会把 MCP 服务器(`mcp_server.py`,纯标准库 stdio JSON-RPC)注册进检测到的每个支持 MCP 的
AI 客户端(claude / atomcode / codex)。之后在任意客户端里**直接在对话中查看与操作所有共享会话**:

| 工具 | 作用 |
|------|------|
| `list_sessions` | 列出所有活动会话与状态(托管 / ttyd / Claude / atomcode) |
| `session_status` | 单个托管会话详情:命令 / PID / 连接 / 链接 / 输出预览 |
| `spawn_session` | 新建托管会话(如 `claude`)并返回网页链接 |
| `send_input` | 向会话发送键盘输入(与网页/本机同一条 PTY) |
| `read_output` | 读取会话最近输出(可指定字节数) |
| `kill_session` | 强制结束会话(进程组 TERM→KILL 升级) |

例如在任意 MCP 客户端里直接说:*"列出我的会话"* → AI 调 `list_sessions`;*"开一个 claude 会话"* → 返回链接;
*"往里面输入 ls -la"* → 输入落在浏览器看到的同一个终端里。会话进程退出后自动结束。

面板端点通过 `SS_HUB_URL` 环境变量全局可发现(`./install.sh -y` 自动写入 shell rc);`SS_HUB_TOKEN` 提供认证兜底。
`share sessions` 在终端里输出同样的全局会话视图。

---

## 会话监控面板(hub)

`share hub start`(`/share_session` 需要时会自动拉起)在 **7690** 端口起一个本机监控面板,监控所有会话:

- **托管会话** — 面板或 `share new` 创建;进程退出(如 `/exit`)后网页会话自动结束;
- **Claude Code 会话** — 监控 `~/.claude/projects/**/**.jsonl` 会话文件与活跃状态,提供自动刷新的只读网页视图
  (`/t/<会话id>`),按对话气泡渲染、含工具调用,并有"🔄 在网页继续此会话"按钮——一键以 `claude --resume`
  起成双向托管终端;
- **atomcode 活动** — 各项目最新日志与原始尾部视图;
- **共享中的 ttyd 服务** — 所有在跑的共享及其端口与链接。

面板与其视图使用与终端共享相同的 Basic Auth(用户名 `ai` + 随机 token)。

---

## 架构图

```
本机 Local machine                                    局域网设备 LAN devices
┌─────────────────────────────────────────────┐   ┌──────────────────┐
│ 会话监控面板(hub_server.py,端口 7690)         │   │  浏览器 Browser   │
│  ┌───────────────────────────────────────┐  │   │                  │
│  │ 托管会话(share new,自管 PTY)            │◄─┼───┤ xterm.js 双向     │
│  │  你+所有浏览器共用同一 PTY;进程退出→自动结束 │  │   /w/<id>         │
│  ├───────────────────────────────────────┤  │   │                  │
│  │ Claude Code 会话监控                    │◄─┼───┤ /t/<claude-id>   │
│  │  ~/.claude/projects/**/*.jsonl         │  │   │ 只读视图          │
│  ├───────────────────────────────────────┤  │   │ (+继续会话按钮)    │
│  │ atomcode 活动 / ttyd 服务清单           │  │   │                  │
│  │ xterm.js 组件(自托管)                  │  │   │ 仪表盘 /(5s 刷新)  │
│  └───────────────────────────────────────┘  │   └──────────────────┘
│        ▲ fork 并监控                         │
│  ┌─────┴────────────────────────────────┐   │
│  │ share.sh 入口:ttyd 服务(7681)          │   │   浏览器直连 ttyd
│  │  tmux 会话共享(旧模式)                 │◄──┼───►  WebSocket 双向
│  └──────────────────────────────────────┘   │
│  hooks/install_hooks.py  /share_session(零 token,会话感知)
│  mcp_register.py → MCP 客户端(claude/atomcode/codex)
└─────────────────────────────────────────────┘
```

关键文件:`share.sh`(入口+全部 CLI 逻辑)→ `hub_server.py`(面板 + 托管 PTY + 程序化 API,纯标准库)/
`hub_attach.py`(本机连接客户端)/ `mcp_server.py`(MCP 服务器)/ `hooks/`(零 token 会话感知 UserPromptSubmit hook)/
`install.sh`(跨平台依赖安装 + 命令/hook/MCP/环境变量注册)。

---

## 流程图

**流程 1 — 一条命令 / 零 token 共享:**

```
输入 /share_session(或运行 share here)
   │
   ▼
UserPromptSubmit hook 在模型介入前触发(atomcode/claude/codex)
   │  执行: share here | share new --resume | hub start
   ▼
share.sh 解析会话与端口 → 启动 ttyd(7681)或面板托管 PTY
   │
   ▼
打印:局域网链接 + 用户名 ai + 随机密码(无内嵌凭据链接)
   │
   ▼
同事浏览器打开链接 → 输入一次账号密码
   │
   ▼
浏览器与本地终端共享同一 PTY/tmux → 双向继续
```

**流程 2 — 普通终端里的 Claude(无 tmux)获得双向网页会话:**

```
在普通终端 Claude 里输入 /share_session
   │
   ▼
hook 自动执行:share new --no-attach claude --resume <会话id>
   │  (设 SS_HOOK_VIEW_ONLY=1 或启动失败 → 退回只读视图 /t/<sid>)
   ▼
面板 fork claude --resume 到托管 PTY → /w/<id> 双向终端
   │
   ▼
浏览器继续操作同一对话;进程退出(/exit)后自动结束
```

**流程 3 — 托管会话生命周期:**

```
share new claude ──► 面板在 PTY 中 fork claude(设置 SS_MANAGED_ID)
   │                     │
   ├─ share attach <id> ◄┘  本机终端加入同一 PTY
   ├─ 浏览器 /w/<id>   ◄┘  网页终端加入同一 PTY
   ▼
进程退出(如在 Claude 里执行 /exit)
   ▼
读线程看到 EOF → 会话结束 → 网页显示"会话已结束"
   (保留 120s 供查看,随后自动清理)
```

---

## 命令参考

| 命令 | 作用 |
|------|------|
| `./share.sh` / `./share.sh start [name]` | 一条命令:确保 tmux 会话 → 起 Web 服务 → 打印链接 → 进入会话(默认会话名 `ai`) |
| `./share.sh serve [name]` | 只起 Web 服务,共享一个已有 tmux 会话(适合已在会话里干活时另开终端调用) |
| `./share.sh here [name]` | **会话内一键共享**:自动识别当前所在的 tmux 会话并起服务 |
| `./share.sh stop [name]` | 停止 Web 服务;tmux 会话保留 |
| `./share.sh status [name]` | 查看服务/会话状态与认证信息 |
| `./share.sh url [name]` | 重新打印访问链接与账号密码 |
| `./share.sh new [--no-attach] <命令...>` | 托管会话(面板 PTY,无需 tmux):起服务 → 打印链接 →(进入) |
| `./share.sh attach <id>` | 本机终端再次连接到托管会话 |
| `./share.sh kill <id>` | 强制结束托管会话 |
| `./share.sh hub [action]` | 会话监控面板:`start`/`stop`/`status`/`url`(默认 `start`,端口 7690) |
| `./share.sh sessions` | 全局查看所有活动中的会话与状态(托管 / ttyd / Claude / atomcode) |
| `./share.sh doctor` | 环境自检(依赖/端口/局域网 IP) |
| `./share.sh help` | 帮助 |

## 配置(环境变量)

| 变量 | 默认 | 说明 |
|------|------|------|
| `SS_SESSION` | `ai` | 默认 tmux 会话名 |
| `SS_PORT` | `7681` | 服务端口(显式指定被占时报错;未指定且被占时自动顺延 7682/7683…) |
| `SS_HOST` | `0.0.0.0` | 监听地址(一般不用改) |
| `SS_HUB_PORT` | `7690` | 会话监控面板端口 |
| `SS_HUB_URL` | install.sh 自动写入 shell rc | 全局面板地址(`http://127.0.0.1:7690`)——任意终端/AI 客户端据此发现监控面板 |
| `SS_HUB_TOKEN` | — | 面板认证 token 的环境变量兜底(hub.state 不可用时) |
| `SS_STATE_DIR` | `~/.ai-session-share` | 状态目录(share.sh/hook/hub 共用);创建时设为 `0700` 权限 |
| `SS_NO_AUTH` | 空 | 设 `1` 关闭登录认证(**不推荐**) |

状态文件位于 `~/.ai-session-share/`(本机自用,`0700`,不入库):`<session>.pid` / `<session>.state` /
`<session>.log`,面板另有 `hub.pid` / `hub.state` / `hub.log` 与缓存的 `/assets/`。

---

## 安全(务必阅读)

**链接 + 密码 = 你机器的钥匙。** 拿到凭证的任何人可以在你的终端里执行任意命令(等同你本人在操作)。

- 默认开启 Basic Auth:每次 `start/serve/here` 生成**随机 token** 作为密码(用户名固定 `ai`),密码会打印在终端里,
  浏览器访问时输入即可;
- 建议仅在企业内网 / 家庭可信网络使用;用完执行 `./share.sh stop`;
- 不要用 `SS_NO_AUTH=1`(仅限完全可信网络且你清楚后果);
- **不要**把端口 7681/7690 转发到公网(frp / 路由器端口映射 / ngrok),等于把终端与 AI 会话内容公开;
- token 存于 `~/.ai-session-share/*.state`(目录权限 `0700`),勿分享该目录;
- **现代浏览器已禁用 URL 内嵌账号密码自动登录**(`http://ai:密码@IP:端口` 不再生效),工具因此从不打印此类链接——
  在浏览器登录框输入一次账号密码,浏览器会按站点记住,之后访问免输;
- **免密登录链接**(面板/托管会话/实时视图页支持):`http://IP:端口/路径?key=密码`,打开即自动登录并写入 30 天
  cookie,之后刷新/跳转都不用再输密码。原理是普通查询参数(不是被浏览器拦截的"URL 内嵌凭据"),但**分享这个
  链接等于分享密码**,请像对待密码一样对待它,仅在可信网络内使用。旧式 ttyd(`/open/<port>`)不支持此机制,
  仍需手动输入该服务自己的账号密码。

---

## 优势分析 · 为什么用这个而不是别的

| 方案 | 共享方式 | 双向操作 | 绑定工具 | 需要公网/云 |
|------|----------|:---:|:---:|:---:|
| **本仓库** | 局域网链接,浏览器直连 | ✅ | 无(通用) | 否,纯局域网 |
| tmate | 经 tmate.io 中转的链接 | ✅ | 无 | 是(tmate.io) |
| Claude Code Remote Control | 官方会话 URL / 二维码 | ✅ | 仅 Claude Code | 是(Anthropic 中转) |
| Code-Cast / 会话导出 | 只读网页回放 | ❌ | Claude Code/Codex 等 | 是(code-cast.dev) |

核心优势:

1. **通用、不绑定 AI 工具** — 任何终端进程都能共享(AI 编码助手、数据导出、调试排查);AI 工具集成(零 token
   `/share_session`、MCP)是加分项而非前提。
2. **真正的双向 + 上下文一致** — 所有人共享*同一个* PTY;晚到的观看者能看到回放,尺寸变化会传播,浏览器能接着
   本地终端断掉的地方继续操作。
3. **合理到位的生命周期** — 托管会话在进程退出(`/exit`)时自动结束,不会残留无人管的孤儿服务;关掉本地终端
   *不会*杀掉会话。
4. **无公网、无中转** — 全程在局域网内完成,任何数据不出网(对会话记录与 token 尤其重要)。
5. **AI 用户零 token** — `/share_session` 在模型介入前由 `UserPromptSubmit` hook 触发,直接返回链接,不消耗
   任何推理 token(实测 `total_tokens: 0`)。
6. **会话感知输出** — 永远拿到*你自己的*会话链接;普通终端里的 Claude 会被自动续为托管会话,只读视图也能一键
   升级为双向终端。
7. **终端页自包含** — xterm.js 自托管(零外部 CDN),Tracking Prevention 与内网隔离都不会弄坏终端页。
8. **纯标准库** — `hub_server.py`、`mcp_server.py` 与 hook 只用 Python 标准库,没有 npm/pip 依赖树要维护。

---

## FAQ · 常见问题

**多人同时输入会怎样?** 所有人共享同一个终端,输入会互相竞争(和 tmate 多人协作一样)。适合"一人主导、他人旁观/
补充"的场景;浏览器端默认看到的就是当前实时画面。

**手机能访问吗?** 可以。ttyd 内置 xterm.js,触屏虚拟键盘可用,适合手机跟进长任务。

**想只读观看(不让对方操作)?** 本仓库是双向共享。只读场景可用 `tmate`(自带 read-only 链接),或把 token 只发给
可信的人。

**不在 tmux 里跑 Claude,/share_session 给我什么?** hook 会用 `claude --resume <会话id>` **自动把该会话续为托管
会话**(由面板拉起),链接打开的是延续同一对话的**双向网页终端**——浏览器可直接输入,续跑进程退出后共享自动结束。
若自动拉起失败(或设 `SS_HOOK_VIEW_ONLY=1`),仍会得到该会话的**只读实时视图**(`/t/<id>`,2s 刷新),页面上的
"🔄 在网页继续此会话"按钮可随时一键转为双向终端。

**退出 tmux / 关终端会影响服务吗?** 不会。ttyd 是独立后台进程,`stop` 才关闭;会话数据在 tmux 里,随时
`tmux attach -t ai` 回来。

**端口被占用怎么办?** `SS_PORT=9000 ./share.sh`(`doctor` 会先检查端口占用)。

**浏览器提示密码错误/登录不上?** 服务端认证链路是正常的(无凭据必返回 401)。常见原因是:
1. **服务重启后密码变了**——每次 `start/serve/here` 都会重新生成 token,浏览器常缓存旧密码;请换**无痕窗口**,
   或用 `./share.sh url` 重新打印当前密码;
2. 现代浏览器已**禁用 URL 内嵌账号密码自动登录**(`http://ai:密码@IP:端口` 不再生效)——请在浏览器的登录框输入
   一次账号密码,浏览器会按站点记住,之后访问免输;随时可用 `./share.sh url` 重新打印当前密码;
3. 确认访问的是终端里打印的局域网 IP(同一 Wi-Fi 下),手机用流量访问会打不开。

**没有 tmux/ttyd 怎么办?** `./install.sh -y`(macOS 走 brew,Linux 走 apt/dnf/yum)。Windows 用户可用 WSL。

**浏览器端中文乱码?** ttyd 支持 CJK;若本地 locale 非 UTF-8,先在会话里 `export LANG=en_US.UTF-8`。

---

## 开发 / 测试

```bash
bash -n share.sh install.sh                          # shell 语法检查
python3 -m py_compile hub_server.py hooks/*.py       # python 语法检查
./share.sh doctor                                    # 环境自检
tests/test.sh                                        # 完整冒烟测试:依赖/子命令/真实起停/面板/hook/
                                                     # WS 写入链路/MCP/端口(79 项检查)
```

架构:`share.sh`(入口+全部逻辑)→ 依赖 `tmux`(旧模式)、`ttyd`(WebSocket 终端)、`openssl`(token)、`python3`
(hub/MCP);`install.sh`(跨平台依赖安装);`hub_server.py`(面板 + 托管 PTY + 程序化 API,纯标准库);
`hub_attach.py`(本机连接客户端);`mcp_server.py`(多 AI 客户端 MCP 服务器);
`commands/share_session.md`(斜杠命令模板)+ `hooks/`(零 token 会话感知 UserPromptSubmit hook)。

---

## 许可

MIT License,见 [LICENSE](LICENSE)。

