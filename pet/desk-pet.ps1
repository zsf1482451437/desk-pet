# Claude Code 桌宠：读 ~/.desk-pet/events.jsonl（由 hook/report.mjs 写入），在屏幕角落提醒会话状态。
# 需要决策 → 跳动 + 红色气泡 + 提示音，直到该会话继续或你点掉；完成 / 出错 → 气泡几秒后自动收起。
# 左键点南瓜：展开 / 收起列表；拖动：按住南瓜拖；右键：清空 / 退出。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\ClaudeDeskPet', [ref]$created)
if (-not $created) { exit }

$Dir = Join-Path $env:USERPROFILE '.desk-pet'
$File = Join-Path $Dir 'events.jsonl'
New-Item -ItemType Directory -Force $Dir | Out-Null

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight">
  <StackPanel x:Name="Root" HorizontalAlignment="Right">
    <Border x:Name="Bubble" Visibility="Collapsed" CornerRadius="12" Padding="12,9" Margin="0,0,0,6"
            MaxWidth="300" HorizontalAlignment="Right" Background="#F2FFFFFF" BorderThickness="2" BorderBrush="#FF8A3D">
      <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.25"/></Border.Effect>
      <StackPanel>
        <TextBlock x:Name="BubbleTitle" FontSize="13" FontWeight="Bold" Foreground="#3A2A1A" TextWrapping="Wrap"/>
        <TextBlock x:Name="BubbleText" FontSize="12" Foreground="#5A4A3A" TextWrapping="Wrap" Margin="0,3,0,0"/>
        <StackPanel x:Name="List" Margin="0,4,0,0"/>
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
      <Ellipse x:Name="Body" Width="52" Height="68" Margin="0,20,0,0" HorizontalAlignment="Center" VerticalAlignment="Top" Fill="#FF8A2A"/>
      <Canvas>
        <Polygon x:Name="EyeL" Points="30,44 38,52 22,52" Fill="#3A1A08"/>
        <Polygon x:Name="EyeR" Points="66,44 74,52 58,52" Fill="#3A1A08"/>
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
foreach ($n in 'Bubble', 'BubbleTitle', 'BubbleText', 'List', 'Pet', 'Hop', 'Glow', 'Body', 'EyeL', 'EyeR', 'Mouth', 'Badge', 'BadgeText') { $ui[$n] = $win.FindName($n) }

$brush = { param($hex) New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }

# ---------------------------------------------------------------- 状态
$waiting = [ordered]@{}           # session -> @{ project; text; ts }
$recent = New-Object System.Collections.ArrayList   # 最近完成 / 出错，最多 6 条
$script:offset = 0
$script:flashUntil = [datetime]::MinValue
$script:flashKind = ''
$script:listOpen = $false
if (Test-Path $File) { $script:offset = (Get-Item $File).Length }   # 启动前的旧事件不提醒

function Set-Face($mood) {
  switch ($mood) {
    'alert' { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M36,66 Q48,58 60,66 Q48,74 36,66'); $ui.Glow.Fill = & $brush '#AAFF3B30' }
    'done'  { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M30,62 Q48,80 66,62'); $ui.Glow.Fill = & $brush '#9934C759' }
    'error' { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M34,70 Q48,60 62,70'); $ui.Glow.Fill = & $brush '#998E5CF7' }
    default { $ui.Mouth.Data = [Windows.Media.Geometry]::Parse('M32,64 Q48,76 64,64'); $ui.Glow.Fill = & $brush '#00FF8A3D' }
  }
}

$hopAnim = New-Object Windows.Media.Animation.DoubleAnimation(0, -14, [TimeSpan]::FromMilliseconds(260))
$hopAnim.AutoReverse = $true
$hopAnim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$hopAnim.EasingFunction = New-Object Windows.Media.Animation.QuadraticEase
function Start-Hop { $ui.Hop.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $hopAnim) }
function Stop-Hop { $ui.Hop.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null); $ui.Hop.Y = 0 }

function Add-Row($text, $color, $session) {
  $tb = New-Object Windows.Controls.TextBlock
  $tb.Text = $text; $tb.FontSize = 12; $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,3,0,0'
  $tb.Foreground = & $brush $color
  if ($session) {
    $tb.Cursor = 'Hand'; $tb.ToolTip = '点一下：标记已处理'
    $tb.Tag = $session
    $tb.Add_MouseLeftButtonUp({ param($s, $e) $waiting.Remove($s.Tag); Render; $e.Handled = $true })
  }
  [void]$ui.List.Children.Add($tb)
}

function Render {
  $ui.List.Children.Clear()
  $n = $waiting.Count
  if ($n -gt 0) {
    $ui.Badge.Visibility = 'Visible'; $ui.BadgeText.Text = "$n"
    Set-Face 'alert'; Start-Hop
    $first = @($waiting.Values)[-1]
    $ui.Bubble.BorderBrush = & $brush '#E5322D'
    $ui.BubbleTitle.Text = "需要你决策 · $($first.project)" + $(if ($n -gt 1) { "（共 $n 个会话）" } else { '' })
    $ui.BubbleText.Text = $first.text
    $ui.Bubble.Visibility = 'Visible'
    if ($script:listOpen) { foreach ($k in @($waiting.Keys)) { $w = $waiting[$k]; Add-Row ("● $($w.project)：$($w.text)") '#B3261E' $k } }
    return
  }
  $ui.Badge.Visibility = 'Collapsed'; Stop-Hop
  if ([datetime]::Now -lt $script:flashUntil -and $recent.Count -gt 0) {
    $r = $recent[0]
    Set-Face $script:flashKind
    $ui.Bubble.BorderBrush = & $brush $(if ($script:flashKind -eq 'error') { '#8E5CF7' } else { '#34C759' })
    $ui.BubbleTitle.Text = $r.title
    $ui.BubbleText.Text = $r.text
    $ui.Bubble.Visibility = 'Visible'
  } elseif ($script:listOpen) {
    Set-Face 'idle'
    $ui.Bubble.BorderBrush = & $brush '#FF8A3D'
    $ui.BubbleTitle.Text = if ($recent.Count) { '最近动态' } else { '一切安静' }
    $ui.BubbleText.Text = ''
    foreach ($r in $recent) { Add-Row ("$($r.time)  $($r.title)") '#5A4A3A' $null }
    $ui.Bubble.Visibility = 'Visible'
  } else {
    Set-Face 'idle'; $ui.Bubble.Visibility = 'Collapsed'
  }
}

function Push-Recent($title, $text, $kind) {
  [void]$recent.Insert(0, @{ title = $title; text = $text; time = (Get-Date -Format 'HH:mm') })
  while ($recent.Count -gt 6) { $recent.RemoveAt($recent.Count - 1) }
  $script:flashKind = $kind
  $script:flashUntil = [datetime]::Now.AddSeconds(8)
}

function Handle($e) {
  $s = $e.session; $p = $e.project; $t = "$($e.text)"
  switch ($e.event) {
    'Notification' {
      $isNew = -not $waiting.Contains($s)
      $waiting.Remove($s); $waiting[$s] = @{ project = $p; text = $(if ($t) { $t } else { '在等你回复' }) }
      if ($isNew) { [System.Media.SystemSounds]::Exclamation.Play() }
    }
    'UserPromptSubmit' { $waiting.Remove($s) }
    'Stop' {
      $waiting.Remove($s)
      Push-Recent "完成 · $p" $(if ($t) { $t } else { '这一轮跑完了' }) 'done'
      [System.Media.SystemSounds]::Asterisk.Play()
    }
    'SubagentStop' { Push-Recent "子 agent 完成 · $p" $t 'done' }
    'PermissionDenied' { Push-Recent "权限被拒 · $p" ("$($e.tool) $t").Trim() 'error'; [System.Media.SystemSounds]::Hand.Play() }
    'StopFailure' { Push-Recent "出错停下 · $p" $t 'error'; [System.Media.SystemSounds]::Hand.Play() }
    'PostToolUseFailure' { Push-Recent "工具失败 · $p" ("$($e.tool) $t").Trim() 'error' }
  }
}

# ---------------------------------------------------------------- 读新事件
function Poll {
  if (-not (Test-Path $File)) { return }
  $len = (Get-Item $File).Length
  if ($len -lt $script:offset) { $script:offset = 0 }   # 文件被清空过
  if ($len -eq $script:offset) { return }
  $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
  try {
    [void]$fs.Seek($script:offset, 'Begin')
    $buf = New-Object byte[] ($len - $script:offset)
    $read = $fs.Read($buf, 0, $buf.Length)
  } finally { $fs.Close() }
  $chunk = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
  $cut = $chunk.LastIndexOf("`n")
  if ($cut -lt 0) { return }                              # 还没写完一整行
  $script:offset += [Text.Encoding]::UTF8.GetByteCount($chunk.Substring(0, $cut + 1))
  foreach ($line in $chunk.Substring(0, $cut).Split("`n")) {
    if (-not $line.Trim()) { continue }
    try { Handle ($line | ConvertFrom-Json) } catch { }
  }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({ Poll; Render })
$timer.Start()

# ---------------------------------------------------------------- 交互
$script:downAt = $null
$ui.Pet.Add_MouseLeftButtonDown({ param($s, $e) $script:downAt = $e.GetPosition($win); $win.DragMove() })
$ui.Pet.Add_MouseLeftButtonUp({
  param($s, $e)
  $now = $e.GetPosition($win)
  if ($script:downAt -and [Math]::Abs($now.X - $script:downAt.X) -lt 4 -and [Math]::Abs($now.Y - $script:downAt.Y) -lt 4) {
    $script:listOpen = -not $script:listOpen; $script:flashUntil = [datetime]::MinValue; Render
  }
})

$menu = New-Object Windows.Controls.ContextMenu
$miClear = New-Object Windows.Controls.MenuItem; $miClear.Header = '清空提醒'
$miClear.Add_Click({ $waiting.Clear(); $recent.Clear(); $script:flashUntil = [datetime]::MinValue; Render })
$miQuit = New-Object Windows.Controls.MenuItem; $miQuit.Header = '退出桌宠'
$miQuit.Add_Click({ $timer.Stop(); $win.Close() })
[void]$menu.Items.Add($miClear); [void]$menu.Items.Add($miQuit)
$ui.Pet.ContextMenu = $menu

# 气泡随内容变高时，保持南瓜贴在右下角
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

Set-Face 'idle'
[void]$win.ShowDialog()
$mutex.ReleaseMutex()
