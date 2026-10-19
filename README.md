# desk-pet：Claude Code 桌宠

屏幕右下角的小南瓜，盯着本机所有 Claude Code 会话。

## 面板

左键点南瓜展开：列出所有活跃会话（来自 `claude agents --json`，每 5 秒后台刷新），按「需要你决策 → 进行中 → 已完成 → 其他」排序，每行显示会话名、所在目录、最后一句话的摘要。

- **点一行**：跳到该会话。后台会话开一个 PowerShell 窗口运行 `claude attach <id>`（← 回 agent 视图，Ctrl+Z 回 shell，关窗口不影响会话）；交互式会话沿父进程找到终端 / IDE 窗口切到前台。
- **我知道了**：收起这一行，记在 `~/.desk-pet/acks.json`（重启不丢）；该会话状态变了或又完成一轮时自动重新出现。底部「显示已知道的」可展开查看。
- 右键南瓜：全部标记为知道了 / 退出。按住南瓜拖动换位置。

## 南瓜表情

| 南瓜 | 条件 |
|---|---|
| 红光 + 跳动 + 角标 | 有会话需要你决策（角标 = 个数，「我知道了」后不计） |
| 绿光笑脸 | 有新完成、还没点「我知道了」的会话 |
| 蓝光平嘴 | 有会话在进行中 |
| 紫光 | 刚收到出错（几秒） |

钩子事件还会即时弹气泡：需要决策（提示音，10 秒）、完成（提示音，8 秒）、子 agent 完成、权限被拒 / 出错停下（提示音）、工具失败（无声）。

## 组成

- `hook/report.mjs`：全局钩子（`~/.claude/settings.json` 的 `hooks`：Notification、Stop、SubagentStop、UserPromptSubmit、PermissionDenied、StopFailure、PostToolUseFailure，都是 `async`、node 直接执行）调用，把事件追加到 `~/.desk-pet/events.jsonl`，Stop 时顺带取这一轮最后一段回复当摘要。异常静默退出；`DESK_PET_DEBUG=1` 打印原因。
- `pet/desk-pet.ps1`：WPF 透明置顶窗口。**必须是 UTF-8 带 BOM**，否则 Windows PowerShell 5.1 会把中文读乱。只允许一个实例；启动前的旧事件不提醒。`-Open` 参数启动时直接展开面板（测试用）。
- `start-pet.cmd`：双击启动（无黑窗）。

## 开机自启

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\desk-pet.lnk")
$s.TargetPath = 'D:\workspace\desk-pet\start-pet.cmd'; $s.WindowStyle = 7; $s.Save()
```

## 测试要点

- 截图要带 CaptureBlt（透明窗口是分层窗口，普通 CopyFromScreen 截不到）。
- 「我知道了」可用 UI Automation 的 InvokePattern 触发，不动鼠标。
- PowerShell 5.1 的 `ConvertFrom-Json` 把 JSON 数组当一个对象输出，管道过滤前要先 `| % { $_ }` 展开。

## 停用

删掉 `~/.claude/settings.json` 里 `hooks` 下这 7 项（或 `/hooks` 逐个关），右键南瓜退出。
