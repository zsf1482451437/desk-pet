# Claude Code 桌宠：屏幕角落的小火箭 + 会话面板。
# 会话列表以 `claude agents --json` 为准（面板展开时每 5 秒刷新；收起时每 60 秒，另在会话状态变化的钩子事件后 2 秒刷新——每次调用要起一个约 300 MB 的 claude 进程），
# 钩子写的 ~/.desk-pet/events.jsonl 负责提示音、每个会话最后一句话的摘要，以及触发刷新；不自动弹气泡。
# 火箭右上角 = 未完成会话数；左键点火箭弹出未完成会话列表（下方另列刚完成、未确认的），点任意一行跳到该会话；「我知道了」收起已完成的那一行，直到它又完成一轮；
# 未完成的行可「标记完成」，该会话有新提醒或新输入时重新出现。点击火箭或鼠标靠近时火箭发射一次。
# 按住火箭拖动；右键：清空提醒 / 退出。文件须为 UTF-8 带 BOM（Windows PowerShell 5.1 才能读对中文）。
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
    <Border x:Name="Bubble" Visibility="Collapsed" CornerRadius="12" Padding="12,10" Margin="0,0,0,-36"
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
    <!-- 上方 44px 留空给发射时飞出去的那一段（透明区不接收点击） -->
    <Grid Width="96" Height="136" HorizontalAlignment="Right">
      <Grid x:Name="Pet" Height="92" VerticalAlignment="Bottom" Cursor="Hand" Background="Transparent">
        <Ellipse x:Name="Glow" Width="80" Height="80" VerticalAlignment="Bottom" Fill="#00FF8A3D">
          <Ellipse.Effect><BlurEffect Radius="14"/></Ellipse.Effect>
        </Ellipse>
        <Canvas x:Name="Ship">
          <Canvas.RenderTransform>
            <TransformGroup>
              <ScaleTransform x:Name="Bump" CenterX="48" CenterY="46"/>
              <TranslateTransform x:Name="Fly"/>
            </TransformGroup>
          </Canvas.RenderTransform>
          <Canvas>
            <Canvas.RenderTransform><ScaleTransform x:Name="Flame" CenterX="48" CenterY="66" ScaleX="1" ScaleY="0"/></Canvas.RenderTransform>
            <Path Data="M41,66 Q48,96 55,66 Z" Fill="#FF8A2A"/>
            <Path Data="M44.5,66 Q48,84 51.5,66 Z" Fill="#FFE15A"/>
          </Canvas>
          <Path Data="M36,48 L25,66 L36,61 Z" Fill="#E5322D" Stroke="#2B2B3A" StrokeThickness="1.5" StrokeLineJoin="Round"/>
          <Path Data="M60,48 L71,66 L60,61 Z" Fill="#E5322D" Stroke="#2B2B3A" StrokeThickness="1.5" StrokeLineJoin="Round"/>
          <Rectangle Canvas.Left="42" Canvas.Top="61" Width="12" Height="5" Fill="#6A6A7A"/>
          <Path Data="M48,4 C56,12 60,22 60,32 L60,62 L36,62 L36,32 C36,22 40,12 48,4 Z" Fill="#F4F4F8" Stroke="#2B2B3A" StrokeThickness="2" StrokeLineJoin="Round"/>
          <Path Data="M48,4 C53,9 56.5,15 58.3,22 L37.7,22 C39.5,15 43,9 48,4 Z" Fill="#E5322D"/>
          <Ellipse Canvas.Left="41" Canvas.Top="30" Width="14" Height="14" Fill="#5BC0F8" Stroke="#2B2B3A" StrokeThickness="2"/>
          <Rectangle Canvas.Left="47" Canvas.Top="52" Width="2" Height="10" Fill="#D0D0DA"/>
        </Canvas>
        <Border x:Name="Badge" Visibility="Collapsed" Width="24" Height="24" CornerRadius="12" Background="#E5322D"
                HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,4,6,0">
          <TextBlock x:Name="BadgeText" Foreground="White" FontWeight="Bold" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>
    </Grid>
  </StackPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Bubble', 'BubbleTitle', 'BubbleText', 'Scroll', 'List', 'Footer', 'Pet', 'Glow', 'Ship', 'Bump', 'Fly', 'Flame', 'Badge', 'BadgeText') { $ui[$n] = $win.FindName($n) }
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
# 手动「标记完成」的未完成会话：只要状态没变就当已完成；该会话又来了新提醒或新一轮输入时撤销（见 Handle）
function Is-Dismissed($a) { $a.state -ne 'done' -and $acks[$a.id] -eq "dismiss|$($a.state)" }

# ---------------------------------------------------------------- 火箭：光晕表示状态，点击或鼠标靠近时发射
function Set-Mood($mood) {
  $ui.Glow.Fill = Brush $(switch ($mood) { 'alert' { '#AAFF3B30' } 'done' { '#9934C759' } 'busy' { '#552F7BEA' } default { '#00FF8A3D' } })
}

function Keys($prop, $frames) {
  $an = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  foreach ($f in $frames) {
    $k = New-Object Windows.Media.Animation.EasingDoubleKeyFrame $f[1], ([Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($f[0])))
    if ($f[2]) { $k.EasingFunction = New-Object Windows.Media.Animation.QuadraticEase -Property @{ EasingMode = $f[2] } }
    [void]$an.KeyFrames.Add($k)
  }
  $an.FillBehavior = 'Stop'
  $an
}
$script:launchUntil = [datetime]::MinValue
function Launch {
  if ([datetime]::Now -lt $script:launchUntil) { return }
  $script:launchUntil = [datetime]::Now.AddMilliseconds(1700)
  # 点火抖动 0.3s → 加速升空并淡出 → 原位弹回
  $ui.Fly.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (Keys X @(@(0, 0), @(50, -2), @(100, 2), @(150, -2), @(200, 2), @(250, -1), @(300, 0))))
  $ui.Fly.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Keys Y @(@(0, 0), @(300, 2), @(950, -150, 'EaseIn'), @(1250, -150), @(1251, 0), @(1650, 0))))
  $ui.Flame.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (Keys S @(@(0, 0), @(200, 1), @(950, 1.6), @(1100, 0))))
  $ui.Ship.BeginAnimation([Windows.UIElement]::OpacityProperty, (Keys O @(@(0, 1), @(700, 1), @(950, 0), @(1250, 0), @(1450, 1))))
  foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) {
    $ui.Bump.BeginAnimation($p, (Keys B @(@(0, 1), @(1251, 1), @(1252, 0.5), @(1500, 1.12, 'EaseOut'), @(1650, 1))))
  }
}

# ---------------------------------------------------------------- 跳转
# 后台会话：把浏览器里已经开着的 Claude 标签页切到前台（不切换会话）。用 Windows UI 自动化读 Chrome 的标签栏，
# 不需要插件或调试端口；有多个 Claude 标签时优先标题里带会话名的。一个都没开时在默认浏览器打开 claude.ai/code。
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
function Activate-ClaudeTab($sessionName) {
  $root = [Windows.Automation.AutomationElement]::RootElement
  $isTab = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
  $browserPids = @(Get-Process chrome, msedge -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  $best = $null; $bestWin = $null
  foreach ($w in $root.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)) {
    if ($browserPids -notcontains $w.Current.ProcessId) { continue }
    foreach ($tab in $w.FindAll([Windows.Automation.TreeScope]::Descendants, $isTab)) {
      $n = $tab.Current.Name
      if ($n -notmatch 'Claude') { continue }
      if (-not $best -or ($sessionName -and $n -like "*$sessionName*")) { $best = $tab; $bestWin = $w }
      if ($sessionName -and $n -like "*$sessionName*") { break }
    }
  }
  if (-not $best) { Start-Process 'https://claude.ai/code'; return }
  try { $best.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch {
    try { $best.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { }
  }
  $h = [IntPtr]$bestWin.Current.NativeWindowHandle
  if ([PetWin]::IsIconic($h)) { [void][PetWin]::ShowWindow($h, 9) }
  [void][PetWin]::SetForegroundWindow($h)
}

function Jump($a) {
  try {
    if ($a.kind -eq 'background' -or -not $a.pid) { Activate-ClaudeTab $a.name; return }
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

function Add-Row($a, $withAck, $acked, $withDismiss) {
  $st = $STATES["$($a.state)"]
  if (-not $st) { $st = @{ label = "$($a.state)"; color = '#8E5CF7'; order = 3 } }
  if (Is-Dismissed $a) { $st = @{ label = '已标记完成'; color = $STATES.done.color } }
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
  if ($withDismiss) {
    $btn = New-Object Windows.Controls.Button
    $btn.Content = '标记完成'; $btn.FontSize = 11; $btn.Padding = '8,2'; $btn.Margin = '8,0,0,0'
    $btn.VerticalAlignment = 'Top'; $btn.Cursor = 'Hand'; $btn.Tag = $a; $btn.ToolTip = '不再算作未完成；这个会话有新动静时会重新出现'
    [Windows.Automation.AutomationProperties]::SetName($btn, "标记完成 $($a.name)")
    $btn.Background = Brush '#EEF7F0'; $btn.BorderBrush = Brush '#8FD1A0'; $btn.Foreground = Brush '#1F6E36'
    $btn.Add_Click({ param($sender, $e) $acks[$sender.Tag.id] = "dismiss|$($sender.Tag.state)"; Save-Acks; Render })
    [Windows.Controls.Grid]::SetColumn($btn, 2); [void]$grid.Children.Add($btn)
  }
  [void]$ui.List.Children.Add($grid)
}

function Render {
  $list = @($script:agents | Sort-Object { $o = $STATES["$($_.state)"]; if ($o) { $o.order } else { 3 } }, { -[double]$_.startedAt })
  # 未完成 = 不是 done 的（需要你决策、进行中、其他）；已完成的只列还没点「我知道了」的
  $unfinished = @($list | Where-Object { $_.state -ne 'done' -and -not (Is-Dismissed $_) })
  $blocked = @($unfinished | Where-Object { $_.state -eq 'blocked' }).Count
  $doneNew = @($list | Where-Object { $_.state -eq 'done' -and -not (Is-Acked $_) })
  $doneAcked = @($list | Where-Object { ($_.state -eq 'done' -and (Is-Acked $_)) -or (Is-Dismissed $_) })

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
  foreach ($a in $unfinished) { Add-Row $a $false $false $true }
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
  if ($e.event -in 'Notification', 'UserPromptSubmit') {
    $a = $script:agents | Where-Object { $_.sessionId -eq $sid } | Select-Object -First 1
    if ($a -and "$($acks[$a.id])".StartsWith('dismiss|')) { $acks.Remove($a.id); Save-Acks }
  }
  # 会话状态会变的事件：稍后刷新列表，角标和光晕跟上。子 agent 结束、工具失败不改会话状态，不刷新
  if ($e.event -in $STATE_EVENTS) { Refresh-AgentsSoon $AGENTS_AFTER_EVENT_SEC }
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
# 每次调用起一个约 300 MB 的 claude 进程，所以只在需要时调：面板展开时 5 秒一次；收起时只看角标和光晕，
# 它们的变化几乎都伴随钩子事件（提交输入、等你决策、一轮结束、出错停下），事件后 2 秒刷新，另每 60 秒兜底（会话关掉等没有事件的变化）。
$AGENTS_OPEN_SEC = 5
$AGENTS_IDLE_SEC = 60
$AGENTS_AFTER_EVENT_SEC = 2
$STATE_EVENTS = 'UserPromptSubmit', 'Notification', 'Stop', 'StopFailure'
$script:agentTask = $null
$script:agentProc = $null
$script:nextAgents = [datetime]::MinValue
# 把下次刷新提前到 $sec 秒后（只提前，不推后）；正在调用时等它结束，结束后按面板开合重新排
function Refresh-AgentsSoon($sec) {
  $t = [datetime]::Now.AddSeconds($sec)
  if ($t -lt $script:nextAgents) { $script:nextAgents = $t }
}
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
    $script:nextAgents = [datetime]::Now.AddSeconds($(if ($script:open) { $AGENTS_OPEN_SEC } else { $AGENTS_IDLE_SEC }))
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
    $script:open = -not $script:open; $script:flash = $null; Render; Launch
    # 收起时最多 60 秒刷新一次，点开时列表可能是旧的：马上刷新
    if ($script:open) { Refresh-AgentsSoon 0 }
  }
  $e.Handled = $true
})

# 鼠标从远处进到火箭约 110 像素以内时发射一次（窗口外的鼠标收不到事件，只能轮询光标位置）
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class PetCursor {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
}
'@
$script:near = $true
$nearTimer = New-Object Windows.Threading.DispatcherTimer
$nearTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$nearTimer.Add_Tick({
  try {
    $c = $ui.Pet.PointToScreen((New-Object Windows.Point 48, 46))
    $p = New-Object PetCursor+POINT; [void][PetCursor]::GetCursorPos([ref]$p)
    $near = [Math]::Sqrt([Math]::Pow($p.X - $c.X, 2) + [Math]::Pow($p.Y - $c.Y, 2)) -lt 110
    if ($near -and -not $script:near) { Launch }
    $script:near = $near
  } catch { }
})
$nearTimer.Start()
$ui.Footer.Add_MouseLeftButtonUp({ $script:showAcked = -not $script:showAcked; Render })

$menu = New-Object Windows.Controls.ContextMenu
$miAll = New-Object Windows.Controls.MenuItem; $miAll.Header = '全部标记为知道了'
$miAll.Add_Click({ foreach ($a in $script:agents) { $acks[$a.id] = (State-Key $a) }; Save-Acks; $script:flash = $null; Render })
$miQuit = New-Object Windows.Controls.MenuItem; $miQuit.Header = '退出桌宠'
$miQuit.Add_Click({ $timer.Stop(); $nearTimer.Stop(); $win.Close() })
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
