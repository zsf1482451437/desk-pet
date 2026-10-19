# Claude Code 桌宠：屏幕角落的小南瓜 + 会话面板。
# 会话列表以 `claude agents --json` 为准（每 5 秒后台刷新），钩子写的 ~/.desk-pet/events.jsonl 负责提示音和每个会话最后一句话的摘要；不跳动、不自动弹气泡。
# 南瓜右上角 = 未完成会话数；左键点南瓜弹出未完成会话列表（下方另列刚完成、未确认的），点任意一行跳到该会话；「我知道了」收起已完成的那一行，直到它又完成一轮。
# 按住南瓜拖动；右键：清空提醒 / 退出。文件须为 UTF-8 带 BOM（Windows PowerShell 5.1 才能读对中文）。
param([switch]$Open)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class PetWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
'@

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\ClaudeDeskPet', [ref]$created)
if (-not $created) { exit }

$Dir = Join-Path $env:USERPROFILE '.desk-pet'
$File = Join-Path $Dir 'events.jsonl'
$AckFile = Join-Path $Dir 'acks.json'
New-Item -ItemType Directory -Force $Dir | Out-Null
$Claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $Claude) { $Claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight">
  <StackPanel HorizontalAlignment="Right">
    <Border x:Name="Bubble" Visibility="Collapsed" CornerRadius="12" Padding="12,10" Margin="0,0,0,6"
            Width="380" HorizontalAlignment="Right" Background="#F7FFFFFF" BorderThickness="2" BorderBrush="#FF8A3D">
      <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.25"/></Border.Effect>
      <StackPanel>
        <TextBlock x:Name="BubbleTitle" FontSize="13" FontWeight="Bold" Foreground="#3A2A1A" TextWrapping="Wrap"/>
        <TextBlock x:Name="BubbleText" FontSize="12" Foreground="#5A4A3A" TextWrapping="Wrap" Margin="0,3,0,0"/>
        <ScrollViewer x:Name="Scroll" MaxHeight="440" VerticalScrollBarVisibility="Auto" Margin="0,4,0,0">
          <StackPanel x:Name="List"/>
        </ScrollViewer>
        <TextBlock x:Name="Footer" FontSize="11" Foreground="#8A7A6A" HorizontalAlignment="Right" Margin="0,6,0,0" Cursor="Hand"/>
      </StackPanel>
    </Border>
    <Grid x:Name="Pet" Width="96" Height="92" HorizontalAlignment="Right" Cursor="Hand" Background="Transparent">
      <Grid.RenderTransform><TranslateTransform x:Name="Hop" Y="0"/></Grid.RenderTransform>
      <Ellipse x:Name="Glow" Width="96" Height="80" VerticalAlignment="Bottom" Fill="#00FF8A3D">
        <Ellipse.Effect><BlurEffect Radius="14"/></Ellipse.Effect>
      </Ellipse>
      <Path Data="M46,16 C46,8 50,4 56,2 L58,6 C54,8 52,11 52,17 Z" Fill="#4E7A2E"/>
      <Ellipse Width="44" Height="64" Margin="8,22,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" Fill="#F07A1E"/>
      <Ellipse Width="44" Height="64" Margin="0,22,8,0" HorizontalAlignment="Right" VerticalAlignment="Top" Fill="#F07A1E"/>
      <Ellipse Width="52" Height="68" Margin="0,20,0,0" HorizontalAlignment="Center" VerticalAlignment="Top" Fill="#FF8A2A"/>
      <Canvas>
        <Polygon Points="30,44 38,52 22,52" Fill="#3A1A08"/>
        <Polygon Points="66,44 74,52 58,52" Fill="#3A1A08"/>
        <Path x:Name="Mouth" Data="M32,64 Q48,76 64,64" Stroke="#3A1A08" StrokeThickness="4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
      </Canvas>
      <Border x:Name="Badge" Visibility="Collapsed" Width="24" Height="24" CornerRadius="12" Background="#E5322D"
              HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,0,0">
        <TextBlock x:Name="BadgeText" Foreground="White" FontWeight="Bold" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Grid>
  </StackPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Bubble', 'BubbleTitle', 'BubbleText', 'Scroll', 'List', 'Footer', 'Pet', 'Hop', 'Glow', 'Mouth', 'Badge', 'BadgeText') { $ui[$n] = $win.FindName($n) }
function Brush($hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }

# ---------------------------------------------------------------- 状态
$STATES = @{
  blocked = @{ label = '需要你决策'; color = '#E5322D'; order = 0 }
  working = @{ label = '进行中'; color = '#2F7BEA'; order = 1 }
  done    = @{ label = '已完成'; color = '#2E9E4F'; order = 2 }
}
$script:agents = @()             # 最近一次 claude agents --json 的结果
$script:agentsOk = $false
$summary = @{}                   # sessionId -> @{ text; ts; event }
$acks = @{}                      # 会话 id -> 确认时的状态键
if (Test-Path $AckFile) { try { (Get-Content $AckFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | % { $acks[$_.Name] = $_.Value } } catch { } }
$script:offset = 0
if (Test-Path $File) { $script:offset = (Get-Item $File).Length }   # 启动前的旧事件不提醒
$script:open = [bool]$Open
$script:showAcked = $false
$script:flash = $null            # 即时提醒气泡 @{ title; text; kind; until }

function Save-Acks { try { ($acks | ConvertTo-Json -Compress) | Set-Content $AckFile -Encoding UTF8 } catch { } }
function State-Key($a) {
  $s = $summary[$a.sessionId]
  "$($a.state)|$(if ($s) { $s.ts } else { 0 })"
}
function Is-Acked($a) { $acks[$a.id] -eq (State-Key $a) }

# ---------------------------------------------------------------- 南瓜表情
function Set-Mood($mood) {
  switch ($mood) {
    'alert' { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M36,66 Q48,58 60,66 Q48,74 36,66'); $ui.Glow.Fill = Brush '#AAFF3B30' }
    'done'  { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M30,62 Q48,80 66,62'); $ui.Glow.Fill = Brush '#9934C759' }
    'error' { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M34,70 Q48,60 62,70'); $ui.Glow.Fill = Brush '#998E5CF7' }
    'busy'  { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M38,66 L58,66'); $ui.Glow.Fill = Brush '#552F7BEA' }
    default { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M32,64 Q48,76 64,64'); $ui.Glow.Fill = Brush '#00FF8A3D' }
  }
}

# ---------------------------------------------------------------- 跳转
# 网页版会话都在同一个「桌宠专用」Chrome 应用窗口里切换：独立的浏览器资料目录（首次要在里面登录 claude.ai），
# 只监听本机的调试端口；窗口在就通过 DevTools 协议让它跳到新地址并切到前台，不在就重新开一个。
$CdpPort = 9333
$ChromeProfile = Join-Path $Dir 'chrome-profile'
$Chrome = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
if (-not $Chrome) { $Chrome = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)' }

function Send-Cdp($wsUrl, $method, $params) {
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $cts = New-Object System.Threading.CancellationTokenSource 3000
  try {
    $ws.ConnectAsync([Uri]$wsUrl, $cts.Token).Wait()
    $msg = @{ id = 1; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 5
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
    $buf = New-Object byte[] 4096
    $rseg = New-Object System.ArraySegment[byte] -ArgumentList (, $buf)
    [void]$ws.ReceiveAsync($rseg, $cts.Token).Wait()
  } finally { try { $ws.Dispose() } catch { } }
}

function Focus-ClaudeWindow {
  # 专用窗口的进程命令行里带着我们的资料目录，找有主窗口的那个切到前台
  $procs = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$ChromeProfile*" }
  foreach ($cp in $procs) {
    $p = Get-Process -Id $cp.ProcessId -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
      if ([PetWin]::IsIconic($p.MainWindowHandle)) { [void][PetWin]::ShowWindow($p.MainWindowHandle, 9) }
      [void][PetWin]::SetForegroundWindow($p.MainWindowHandle)
      return
    }
  }
}

function Open-InClaudeWindow($url) {
  $targets = $null
  try { $targets = Invoke-RestMethod "http://127.0.0.1:$CdpPort/json" -TimeoutSec 2 } catch { }
  $page = @($targets) | Where-Object { $_.type -eq 'page' -and $_.url -like 'https://claude.ai/*' } | Select-Object -First 1
  if (-not $page) { $page = @($targets) | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 }
  if ($page -and $page.webSocketDebuggerUrl) {
    try {
      Send-Cdp $page.webSocketDebuggerUrl 'Page.navigate' @{ url = $url }
      Send-Cdp $page.webSocketDebuggerUrl 'Page.bringToFront' @{}
      Focus-ClaudeWindow
      return
    } catch { }
  }
  if (-not $Chrome) { Start-Process $url; return }   # 没装 Chrome：退回默认浏览器新标签
  Start-Process $Chrome -ArgumentList @("--user-data-dir=`"$ChromeProfile`"", "--remote-debugging-port=$CdpPort", '--no-first-run', '--no-default-browser-check', '--window-size=1280,900', "--app=$url")
}

function Jump($a) {
  try {
    if ($a.kind -eq 'background' -or -not $a.pid) {
      # 后台会话优先在浏览器打开网页版：~/.claude/jobs/<id>/state.json 的 bridgeSessionId 是 cse_xxx，
      # 网页地址是 https://claude.ai/code/session_xxx
      $stateFile = Join-Path $env:USERPROFILE ".claude\jobs\$($a.id)\state.json"
      if (Test-Path $stateFile) {
        $bridge = "$(([IO.File]::ReadAllText($stateFile, [Text.Encoding]::UTF8) | ConvertFrom-Json).bridgeSessionId)"
        if ($bridge -match '^cse_(\w+)$') {
          Open-InClaudeWindow "https://claude.ai/code/session_$($Matches[1])"
          return
        }
      }
      # 没连到网页的：开一个 PowerShell 窗口接入（← 回到 agent 视图，Ctrl+Z 回 shell，会话照常运行）
      Start-Process powershell.exe -ArgumentList @('-NoExit', '-Command', "& '$Claude' attach $($a.id)") -WorkingDirectory $(if (Test-Path $a.cwd) { $a.cwd } else { $env:USERPROFILE })
      return
    }
    # 交互式会话：沿父进程往上找第一个有窗口的（终端 / IDE），切到前台
    $id = [int]$a.pid
    for ($i = 0; $i -lt 8 -and $id; $i++) {
      $p = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
        if ([PetWin]::IsIconic($p.MainWindowHandle)) { [void][PetWin]::ShowWindow($p.MainWindowHandle, 9) }
        [void][PetWin]::SetForegroundWindow($p.MainWindowHandle)
        return
      }
      $id = (Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue).ParentProcessId
    }
  } catch { }
}

# ---------------------------------------------------------------- 面板
function New-Text($text, $size, $color, $bold) {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $text; $t.FontSize = $size; $t.Foreground = Brush $color; $t.TextWrapping = 'Wrap'
  if ($bold) { $t.FontWeight = 'Bold' }
  $t
}

function Add-Row($a, $withAck, $acked) {
  $st = $STATES["$($a.state)"]
  if (-not $st) { $st = @{ label = "$($a.state)"; color = '#8E5CF7'; order = 3 } }
  $s = $summary[$a.sessionId]

  $grid = New-Object Windows.Controls.Grid
  $grid.Margin = '0,4,0,4'
  $grid.Opacity = $(if ($acked) { 0.55 } else { 1 })
  $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
  $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = '*'
  $c3 = New-Object Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
  $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2); $grid.ColumnDefinitions.Add($c3)

  $dot = New-Object Windows.Shapes.Ellipse
  $dot.Width = 10; $dot.Height = 10; $dot.Fill = Brush $st.color; $dot.Margin = '0,4,8,0'; $dot.VerticalAlignment = 'Top'
  [Windows.Controls.Grid]::SetColumn($dot, 0); [void]$grid.Children.Add($dot)

  $mid = New-Object Windows.Controls.StackPanel
  $mid.Cursor = 'Hand'; $mid.Background = Brush '#00FFFFFF'; $mid.ToolTip = '点击跳到这个会话'; $mid.Tag = $a
  $head = New-Object Windows.Controls.TextBlock
  $head.TextWrapping = 'Wrap'
  $r1 = New-Object Windows.Documents.Run ($st.label + '  '); $r1.Foreground = Brush $st.color; $r1.FontWeight = 'Bold'; $r1.FontSize = 12
  $r2 = New-Object Windows.Documents.Run ("$($a.name)"); $r2.Foreground = Brush '#2A1E14'; $r2.FontWeight = 'Bold'; $r2.FontSize = 13
  $head.Inlines.Add($r1); $head.Inlines.Add($r2)
  [void]$mid.Children.Add($head)
  $proj = Split-Path $a.cwd -Leaf
  $line = $proj + $(if ($s -and $s.text) { ' · ' + $s.text } else { '' })
  [void]$mid.Children.Add((New-Text $line 11 '#6A5A4A' $false))
  $mid.Add_MouseLeftButtonUp({ param($sender, $e) Jump $sender.Tag; $e.Handled = $true })
  [Windows.Controls.Grid]::SetColumn($mid, 1); [void]$grid.Children.Add($mid)

  if ($withAck) {
    $btn = New-Object Windows.Controls.Button
    $btn.Content = '我知道了'; $btn.FontSize = 11; $btn.Padding = '8,2'; $btn.Margin = '8,0,0,0'
    $btn.VerticalAlignment = 'Top'; $btn.Cursor = 'Hand'; $btn.Tag = $a
    $btn.Background = Brush '#FFF3E8'; $btn.BorderBrush = Brush '#FFB27A'; $btn.Foreground = Brush '#8A4A14'
    $btn.Add_Click({ param($sender, $e) $acks[$sender.Tag.id] = (State-Key $sender.Tag); Save-Acks; Render })
    [Windows.Controls.Grid]::SetColumn($btn, 2); [void]$grid.Children.Add($btn)
  }
  [void]$ui.List.Children.Add($grid)
}

function Render {
  $list = @($script:agents | Sort-Object { $o = $STATES["$($_.state)"]; if ($o) { $o.order } else { 3 } }, { -[double]$_.startedAt })
  # 未完成 = 不是 done 的（需要你决策、进行中、其他）；已完成的只列还没点「我知道了」的
  $unfinished = @($list | Where-Object { $_.state -ne 'done' })
  $blocked = @($unfinished | Where-Object { $_.state -eq 'blocked' }).Count
  $doneNew = @($list | Where-Object { $_.state -eq 'done' -and -not (Is-Acked $_) })
  $doneAcked = @($list | Where-Object { $_.state -eq 'done' -and (Is-Acked $_) })

  # 角标 = 未完成会话数（有人等你决策时红色，否则蓝色）；不跳动、不自动弹气泡
  $ui.Badge.Visibility = $(if ($unfinished.Count) { 'Visible' } else { 'Collapsed' })
  $ui.BadgeText.Text = "$($unfinished.Count)"
  $ui.Badge.Background = Brush $(if ($blocked) { '#E5322D' } else { '#2F7BEA' })
  if ($blocked) { Set-Mood 'alert' }
  elseif ($unfinished.Count) { Set-Mood 'busy' }
  elseif ($doneNew.Count) { Set-Mood 'done' }
  else { Set-Mood 'idle' }

  $ui.List.Children.Clear()
  if (-not $script:open) { $ui.Bubble.Visibility = 'Collapsed'; return }
  $ui.Bubble.BorderBrush = Brush $(if ($blocked) { '#E5322D' } else { '#FF8A3D' })
  $ui.BubbleTitle.Text = "未完成会话 · $($unfinished.Count)" + $(if ($blocked) { "（$blocked 个在等你）" } else { '' })
  $ui.BubbleText.Text = $(if (-not $script:agentsOk) { '正在读取会话列表…' } elseif (-not $unfinished.Count) { '没有未完成的会话' } else { '' })
  $ui.BubbleText.Visibility = $(if ($ui.BubbleText.Text) { 'Visible' } else { 'Collapsed' })
  foreach ($a in $unfinished) { Add-Row $a $false $false }
  if ($doneNew.Count) {
    [void]$ui.List.Children.Add((New-Section "刚完成 · $($doneNew.Count)"))
    foreach ($a in $doneNew) { Add-Row $a $true $false }
  }
  if ($script:showAcked) { foreach ($a in $doneAcked) { Add-Row $a $false $true } }
  $ui.Footer.Text = $(if ($doneAcked.Count) { $(if ($script:showAcked) { '收起已知道的' } else { "显示已知道的（$($doneAcked.Count)）" }) } else { '' })
  $ui.Footer.Visibility = $(if ($ui.Footer.Text) { 'Visible' } else { 'Collapsed' })
  $ui.Bubble.Visibility = 'Visible'
}

function New-Section($text) {
  $t = New-Text $text 12 '#2E9E4F' $true
  $t.Margin = '0,10,0,2'
  $t
}
# ---------------------------------------------------------------- 钩子事件：即时提醒 + 摘要
function Name-Of($sessionId, $project) {
  $a = $script:agents | Where-Object { $_.sessionId -eq $sessionId } | Select-Object -First 1
  if ($a) { $a.name } else { $project }
}
function Handle($e) {
  $sid = $e.session; $t = "$($e.text)"
  $name = Name-Of $sid $e.project
  switch ($e.event) {
    'Notification' {
      $summary[$sid] = @{ text = $(if ($t) { $t } else { '在等你回复' }); ts = $e.ts }
      $script:flash = @{ title = "需要你决策 · $name"; text = $summary[$sid].text; kind = 'alert'; until = [datetime]::Now.AddSeconds(10) }
      [System.Media.SystemSounds]::Exclamation.Play()
    }
    'Stop' {
      $summary[$sid] = @{ text = $(if ($t) { $t } else { '这一轮跑完了' }); ts = $e.ts }
      $script:flash = @{ title = "完成 · $name"; text = $summary[$sid].text; kind = 'done'; until = [datetime]::Now.AddSeconds(8) }
      [System.Media.SystemSounds]::Asterisk.Play()
    }
    'SubagentStop' { $script:flash = @{ title = "子 agent 完成 · $name"; text = $t; kind = 'done'; until = [datetime]::Now.AddSeconds(6) } }
    'PermissionDenied' { $script:flash = @{ title = "权限被拒 · $name"; text = ("$($e.tool) $t").Trim(); kind = 'error'; until = [datetime]::Now.AddSeconds(8) }; [System.Media.SystemSounds]::Hand.Play() }
    'StopFailure' { $script:flash = @{ title = "出错停下 · $name"; text = $t; kind = 'error'; until = [datetime]::Now.AddSeconds(8) }; [System.Media.SystemSounds]::Hand.Play() }
    'PostToolUseFailure' { $script:flash = @{ title = "工具失败 · $name"; text = ("$($e.tool) $t").Trim(); kind = 'error'; until = [datetime]::Now.AddSeconds(5) } }
    'UserPromptSubmit' { $summary[$sid] = @{ text = '处理中…'; ts = $e.ts } }
  }
}

function Poll-Events {
  if (-not (Test-Path $File)) { return }
  $len = (Get-Item $File).Length
  if ($len -lt $script:offset) { $script:offset = 0 }
  if ($len -eq $script:offset) { return }
  $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
  try {
    [void]$fs.Seek($script:offset, 'Begin')
    $buf = New-Object byte[] ($len - $script:offset)
    $read = $fs.Read($buf, 0, $buf.Length)
  } finally { $fs.Close() }
  $chunk = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
  $cut = $chunk.LastIndexOf("`n")
  if ($cut -lt 0) { return }
  $script:offset += [Text.Encoding]::UTF8.GetByteCount($chunk.Substring(0, $cut + 1))
  foreach ($line in $chunk.Substring(0, $cut).Split("`n")) {
    if (-not $line.Trim()) { continue }
    try { Handle ($line | ConvertFrom-Json) } catch { }
  }
}

# ---------------------------------------------------------------- claude agents --json（异步，约 1 秒一次调用）
$script:agentTask = $null
$script:agentProc = $null
$script:nextAgents = [datetime]::MinValue
function Poll-Agents {
  if ($script:agentTask) {
    if (-not $script:agentTask.IsCompleted) { return }
    try {
      $out = $script:agentTask.Result
      $parsed = $out | ConvertFrom-Json
      $script:agents = @($parsed)
      $script:agentsOk = $true
      # 已经不在列表里的会话，它的「我知道了」记录就不用留了
      $ids = @($script:agents | % { $_.id })
      foreach ($k in @($acks.Keys)) { if ($ids -notcontains $k) { $acks.Remove($k) } }
    } catch { }
    try { $script:agentProc.Dispose() } catch { }
    $script:agentTask = $null
    $script:nextAgents = [datetime]::Now.AddSeconds(5)
    Render
    return
  }
  if ([datetime]::Now -lt $script:nextAgents) { return }
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo $Claude, 'agents --json'
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $script:agentProc = [Diagnostics.Process]::Start($psi)
    $script:agentTask = $script:agentProc.StandardOutput.ReadToEndAsync()
  } catch { $script:nextAgents = [datetime]::Now.AddSeconds(15) }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({ Poll-Events; Poll-Agents; Render })
$timer.Start()

# ---------------------------------------------------------------- 交互
# DragMove 会接管鼠标直到松开、吞掉 MouseLeftButtonUp，所以不能靠松开事件判断点击：
# 它返回时鼠标已松开，窗口没挪动（<4px）就算点击，弹出 / 收起列表
$ui.Pet.Add_MouseLeftButtonDown({
  param($s, $e)
  $x0 = $win.Left; $y0 = $win.Top
  try { $win.DragMove() } catch { }
  if ([Math]::Abs($win.Left - $x0) -lt 4 -and [Math]::Abs($win.Top - $y0) -lt 4) {
    $script:open = -not $script:open; $script:flash = $null; Render
  }
  $e.Handled = $true
})
$ui.Footer.Add_MouseLeftButtonUp({ $script:showAcked = -not $script:showAcked; Render })

$menu = New-Object Windows.Controls.ContextMenu
$miAll = New-Object Windows.Controls.MenuItem; $miAll.Header = '全部标记为知道了'
$miAll.Add_Click({ foreach ($a in $script:agents) { $acks[$a.id] = (State-Key $a) }; Save-Acks; $script:flash = $null; Render })
$miQuit = New-Object Windows.Controls.MenuItem; $miQuit.Header = '退出桌宠'
$miQuit.Add_Click({ $timer.Stop(); $win.Close() })
[void]$menu.Items.Add($miAll); [void]$menu.Items.Add($miQuit)
$ui.Pet.ContextMenu = $menu

# 面板随内容变高变宽时，南瓜保持贴在原来的右下角
$win.Add_SizeChanged({
  param($s, $e)
  if ($e.PreviousSize.Width -gt 0) {
    $win.Left -= ($e.NewSize.Width - $e.PreviousSize.Width)
    $win.Top -= ($e.NewSize.Height - $e.PreviousSize.Height)
  }
})
$win.Add_Loaded({
  $wa = [System.Windows.SystemParameters]::WorkArea
  $win.Left = $wa.Right - $win.ActualWidth - 24
  $win.Top = $wa.Bottom - $win.ActualHeight - 24
})

Set-Mood 'idle'
[void]$win.ShowDialog()
$mutex.ReleaseMutex()
