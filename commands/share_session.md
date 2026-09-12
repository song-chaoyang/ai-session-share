---
description: 把当前终端会话共享为局域网 Web 服务,输出访问链接与账号密码(可选参数 mcp 额外输出 MCP 配置)
---

把当前终端会话共享成局域网 Web 服务,让局域网内其他人用浏览器实时查看并继续操作这个会话(与本机共用同一个终端,上下文一致;生命周期与会话进程绑定,进程退出后网页会话自动结束)。

用户输入的参数(原样透传给 hook 识别):$ARGUMENTS

本命令可选参数(追加在命令后,例如 `/share_session mcp`):

- `mcp`:在共享链接之外,**额外输出 MCP 客户端配置**(默认带鉴权 token)——任意支持 MCP 的 AI 客户端粘贴该配置后,就能在对话里直接 list/spawn/send/read/kill 本机会话;
- 不带参数:仅输出共享链接与账号密码(默认行为)。

系统已安装 UserPromptSubmit hook:本命令会由 hook 在模型介入前直接执行并返回结果(不消耗推理 token)。收到本模板时:

1. 如果对话中已经出现了 hook 返回的链接与账号密码,直接原样转达给用户,不要再执行命令、不要解释、不要推理;
2. 如果没有任何 hook 输出(比如本机未安装 hook),则**直接执行**以下命令,并把输出**原样**展示给用户,不要总结、不要补充说明:

```bash
share hub start || ~/.local/bin/share hub start
```

如果用户带了 `mcp` 参数(且 hook 未输出 MCP 配置),改为执行:

```bash
share mcp config || ~/.local/bin/share mcp config
```

说明:hook 的默认行为是自动把当前 Claude 会话续为托管会话(`claude --resume`,双向网页终端);若 hook 未生效,告诉用户在 AI 工具里重新输入 `/share_session` 或手动执行 `share new claude --resume <会话id>`。

需要展示给用户的信息(来自命令输出):

1. 局域网访问链接(输出里的每一行 `http://IP:端口`);
2. 浏览器登录用的用户名和密码(现代浏览器已禁用 URL 内嵌凭据自动登录,不要输出 `http://用户名:密码@IP:端口` 形式的链接,让用户手动输入一次账号密码即可);
3. 若用户带 `mcp` 参数:原样展示输出里的 MCP 配置 JSON(含鉴权 token,提醒用户仅分享给可信环境)。

如果命令提示找不到 `share`,告诉用户:先进入项目目录运行 `./install.sh -y` 安装。结束某个共享会话用 `share kill <托管会话id>`,停止监控面板用 `share hub stop`。
