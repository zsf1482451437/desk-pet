# desk-pet：Claude Code 桌宠

屏幕右下角的小南瓜，提醒本机所有 Claude Code 会话的状态：

| 状态 | 触发 | 表现 |
|---|---|---|
| 需要你决策 | `Notification`（等授权、等回复） | 红光、跳动、数字角标、提示音；直到该会话收到你的消息 / 跑完，或你点掉 |
| 完成 | `Stop` | 绿光笑脸，气泡显示这一轮最后一句回复，8 秒后收起 |
| 子 agent 完成 | `SubagentStop` | 同上，无提示音 |
| 出错 | `PermissionDenied`、`StopFailure`（有提示音）、`PostToolUseFailure`（无提示音） | 紫光，气泡 8 秒 |

`UserPromptSubmit` 只用来清掉该会话的「需要决策」。

## 组成

- `hook/report.mjs`：全局钩子（`~/.claude/settings.json` 的 `hooks`，`async`、node 直接执行）调用，把事件追加到 `~/.desk-pet/events.jsonl`。任何异常静默退出，不影响会话；`DESK_PET_DEBUG=1` 时把错误打到 stderr。
- `pet/desk-pet.ps1`：WPF 透明置顶窗口，每 0.7 秒读新事件。**文件必须是 UTF-8 带 BOM**，否则 Windows PowerShell 5.1 会把中文读乱。只允许一个实例。启动前的旧事件不提醒。
- `start-pet.cmd`：双击启动（无黑窗）。

## 操作

- 左键点南瓜：展开 / 收起列表（需要决策的会话逐条列出，点一条标记已处理；没有待决策时列最近 6 条动态）。
- 按住拖动：换位置。
- 右键：清空提醒 / 退出。

## 开机自启

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\desk-pet.lnk")
$s.TargetPath = 'D:\workspace\desk-pet\start-pet.cmd'; $s.WindowStyle = 7; $s.Save()
```

## 停用

删掉 `~/.claude/settings.json` 里 `hooks` 下这 7 项（或在 Claude Code 里 `/hooks` 逐个关），右键南瓜退出。
