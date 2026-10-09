<#
InputHelper — 给 Codex 用的键鼠操控模块（读 + 点 + 输入）

配套：read-screen.ps1（命令行版读屏）
本模块把「看到」和「点到」合到一起，典型用法：

    Import-Module D:\agent\ScreenReader\InputHelper.psm1
    Click-Control -Name '登录' -Window msedge            # 按控件名点击（自动找坐标）
    Click-Control -Name '登录' -Window msedge -DryRun    # 只看会点哪，不动手

注意：
  * 这是**真实**操作你的鼠标键盘，会抢焦点，AI 操作时你别碰鼠标。
  * 本机 PowerShell 5.1 读 .ps1/.psm1 默认按 GBK，**本文件必须保持 UTF-8 with BOM**。
  * 非管理员进程点不动管理员权限的窗口（Windows UIPI 限制）。
#>

# ── 底层 P/Invoke ────────────────────────────────────────────────
if (-not ('DpiAware' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiAware {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@
}
# 必须在任何窗口/GDI 调用之前设置，否则 UIA 坐标（物理像素）和
# SetCursorPos / 屏幕尺寸（逻辑像素）对不上，点击会偏甚至被判越界。
# -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2；失败则退到旧 API。
if (-not [DpiAware]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
  [void][DpiAware]::SetProcessDPIAware()
}

if (-not ('NativeInput' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class NativeInput {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT  { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004, RIGHTDOWN = 0x0008, RIGHTUP = 0x0010, WHEEL = 0x0800;
}
'@
}

function Get-VirtualScreen {
  [pscustomobject]@{
    X = [DpiAware]::GetSystemMetrics(76)   # SM_XVIRTUALSCREEN
    Y = [DpiAware]::GetSystemMetrics(77)   # SM_YVIRTUALSCREEN
    W = [DpiAware]::GetSystemMetrics(78)   # SM_CXVIRTUALSCREEN
    H = [DpiAware]::GetSystemMetrics(79)   # SM_CYVIRTUALSCREEN
  }
}

# ── 鼠标 ────────────────────────────────────────────────────────

function Get-CursorPosition {
  <# 返回当前光标坐标 #>
  $p = New-Object NativeInput+POINT
  [void][NativeInput]::GetCursorPos([ref]$p)
  [pscustomobject]@{ X = $p.X; Y = $p.Y }
}

function Move-Cursor {
  <# 把光标移到 X,Y #>
  param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y)
  [void][NativeInput]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 60
}

function Invoke-MouseClick {
  <# 在 X,Y 处点击。默认左键单击 #>
  param(
    [Parameter(Mandatory)][int]$X,
    [Parameter(Mandatory)][int]$Y,
    [ValidateSet('Left','Right','Double')][string]$Button = 'Left',
    [switch]$DryRun
  )
  $vs = Get-VirtualScreen
  if ($X -lt $vs.X -or $Y -lt $vs.Y -or $X -gt ($vs.X + $vs.W) -or $Y -gt ($vs.Y + $vs.H)) {
    throw "坐标 ($X,$Y) 不在屏幕范围内 $($vs.W)x$($vs.H)"
  }
  if ($DryRun) { Write-Host ("DRYRUN click $Button at ($X,$Y)"); return }
  Move-Cursor -X $X -Y $Y
  switch ($Button) {
    'Left'   { [NativeInput]::mouse_event([NativeInput]::LEFTDOWN,0,0,0,[IntPtr]::Zero)
               [NativeInput]::mouse_event([NativeInput]::LEFTUP,0,0,0,[IntPtr]::Zero) }
    'Right'  { [NativeInput]::mouse_event([NativeInput]::RIGHTDOWN,0,0,0,[IntPtr]::Zero)
               [NativeInput]::mouse_event([NativeInput]::RIGHTUP,0,0,0,[IntPtr]::Zero) }
    'Double' { 1..2 | ForEach-Object {
                 [NativeInput]::mouse_event([NativeInput]::LEFTDOWN,0,0,0,[IntPtr]::Zero)
                 [NativeInput]::mouse_event([NativeInput]::LEFTUP,0,0,0,[IntPtr]::Zero)
                 Start-Sleep -Milliseconds 80 } }
  }
  Start-Sleep -Milliseconds 120
  Write-Host "clicked $Button at ($X,$Y)"
}

function Invoke-Scroll {
  <# 滚轮。正数向上，负数向下 #>
  param([int]$Amount = -3)
  $delta = [int]([Math]::Abs($Amount) * 120) * ($(if ($Amount -lt 0) { -1 } else { 1 }))
  $packed = [uint32]($delta -shl 16)
  [NativeInput]::mouse_event([NativeInput]::WHEEL, 0, 0, $packed, [IntPtr]::Zero)
  Write-Host "scrolled $Amount"
}

# ── 窗口 ────────────────────────────────────────────────────────

function Get-AppWindow {
  param([Parameter(Mandatory)][string]$Process)
  $n = $Process -replace '\.exe$', ''
  $p = Get-Process -Name $n -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { throw "找不到带窗口的进程: $n" }
  $r = New-Object NativeInput+RECT
  [void][NativeInput]::GetWindowRect($p.MainWindowHandle, [ref]$r)
  [pscustomobject]@{
    Process = $p.ProcessName; Id = $p.Id; Title = $p.MainWindowTitle
    Handle = $p.MainWindowHandle
    X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top
  }
}

function Set-AppWindow {
  <#
    .SYNOPSIS
      把窗口激活到前台。输入前必须先做，否则按键发给了别的窗口。

    Windows 有「前台锁」：后台进程调用 SetForegroundWindow 常常无效（实测 AppActivate 也返回 False）。
    所以这里按三级降级：标准 API → AttachThreadInput 绕过 → 直接点标题栏（最可靠）。
  #>
  param([Parameter(Mandatory)][string]$Process)
  $w = Get-AppWindow -Process $Process
  if ([NativeInput]::IsIconic($w.Handle)) { [void][NativeInput]::ShowWindow($w.Handle, 9) }   # SW_RESTORE

  # 1) 标准做法
  [void][NativeInput]::SetForegroundWindow($w.Handle)
  Start-Sleep -Milliseconds 250
  if ([NativeInput]::GetForegroundWindow() -eq $w.Handle) {
    Write-Host ("已激活(API): " + $w.Title); return $w
  }

  # 2) AttachThreadInput：把自己接到前台线程上，绕过前台锁
  $fg = [NativeInput]::GetForegroundWindow()
  $tid = [NativeInput]::GetWindowThreadProcessId($w.Handle, [IntPtr]::Zero)
  $fid = [NativeInput]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  if ($tid -and $fid -and $tid -ne $fid) {
    [void][NativeInput]::AttachThreadInput($fid, $tid, $true)
    [void][NativeInput]::SetForegroundWindow($w.Handle)
    [void][NativeInput]::AttachThreadInput($fid, $tid, $false)
    Start-Sleep -Milliseconds 250
    if ([NativeInput]::GetForegroundWindow() -eq $w.Handle) {
      Write-Host ("已激活(AttachThreadInput): " + $w.Title); return $w
    }
  }

  # 3) 兜底：点一下标题栏（实测最可靠）
  Invoke-MouseClick -X ([int]($w.X + $w.W / 2)) -Y ([int]($w.Y + 16)) | Out-Null
  Start-Sleep -Milliseconds 400
  if ([NativeInput]::GetForegroundWindow() -eq $w.Handle) {
    Write-Host ("已激活(点标题栏): " + $w.Title); return $w
  }
  Write-Warning "激活失败，按键可能发给了别的窗口；当前前台不是 $($w.Title)"
  return $w
}

# ── UIA 控件查找 ────────────────────────────────────────────────

function Get-ScreenControl {
  <#
    .SYNOPSIS
      从窗口的无障碍树里找控件，返回带名字/类型/坐标的对象。
    .EXAMPLE
      Get-ScreenControl -Window msedge -Name '登录'
      Get-ScreenControl -Window ChatGPT -Type Button | Select -First 10
  #>
  param(
    [Parameter(Mandatory)][string]$Window,
    [string]$Name,                                  # 正则匹配控件名
    [string]$Type,                                  # 控件类型，如 Button / Edit / Text
    [int]$MaxNodes = 3000
  )
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $AE = [System.Windows.Automation.AutomationElement]
  $win = Get-AppWindow -Process $Window
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, [int]$win.Id)
  $root = $AE::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
  if (-not $root) { throw "UIA 找不到窗口: $($win.Title)" }

  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                       [System.Windows.Automation.Condition]::TrueCondition)
  $result = New-Object System.Collections.Generic.List[object]
  $count = 0
  foreach ($el in $all) {
    if ($count -ge $MaxNodes) { break }
    $count++
    try {
      $n = $el.Current.Name
      if ([string]::IsNullOrWhiteSpace($n)) { continue }
      $ct = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
      if ($Type -and $ct -ne $Type) { continue }
      if ($Name -and $n -notmatch $Name) { continue }
      $r = $el.Current.BoundingRectangle
      if ($r.Width -le 0 -or $r.Height -le 0) { continue }   # 不可见
      $result.Add([pscustomobject]@{
        Name    = $n
        Type    = $ct
        Enabled = $el.Current.IsEnabled
        X       = [int]($r.X + $r.Width / 2)
        Y       = [int]($r.Y + $r.Height / 2)
        Rect    = "$([int]$r.X),$([int]$r.Y),$([int]$r.Width)x$([int]$r.Height)"
        Element = $el
      })
    } catch { }
  }
  return $result
}

function Click-Control {
  <#
    .SYNOPSIS
      按控件名找到它并点击中心的「杀手锏」函数。
    .EXAMPLE
      Click-Control -Name '登录' -Window msedge
      Click-Control -Name 'New chat' -Window ChatGPT -DryRun
      Click-Control -Name '关闭标签页' -Window msedge -Index 1
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Window,
    [string]$Type,
    [int]$Index = 0,          # 命中多个时取第几个
    [switch]$NoActivate,      # 默认会先把窗口激活
    [switch]$DryRun
  )
  $hits = @(Get-ScreenControl -Window $Window -Name $Name -Type $Type)
  if ($hits.Count -eq 0) { throw "没找到匹配 '$Name' 的控件" }
  if ($Index -ge $hits.Count) { throw "只找到 $($hits.Count) 个匹配，取不到第 $Index 个" }
  $t = $hits[$Index]
  Write-Host ("目标: [$($t.Type)] `"$($t.Name)`" @($($t.X),$($t.Y))  可选 $($hits.Count) 个")
  # -DryRun 必须零副作用：不激活、不动鼠标，只报出会点哪里
  if ($DryRun) {
    Write-Host ("DRYRUN click Left at ($($t.X),$($t.Y))  （未激活窗口、未移动鼠标）")
    return $t
  }
  if (-not $NoActivate) { [void](Set-AppWindow -Process $Window) }
  Invoke-MouseClick -X $t.X -Y $t.Y -DryRun:$DryRun
  return $t
}

# ── 键盘 ────────────────────────────────────────────────────────

function Send-Hotkey {
  <#
    .SYNOPSIS
      发送组合键。语法同 SendKeys：
        ^ = Ctrl   % = Alt   + = Shift
        ^c = Ctrl+C    %{TAB} = Alt+Tab    {ENTER} {TAB} {ESC} {F5} {DEL}
    .EXAMPLE
      Send-Hotkey '^c'
      Send-Hotkey '%{TAB}'
      Send-Hotkey '{ENTER}'
  #>
  param([Parameter(Mandatory)][string]$Keys, [switch]$DryRun)
  Add-Type -AssemblyName System.Windows.Forms
  if ($DryRun) { Write-Host "DRYRUN sendkeys $Keys"; return }
  [System.Windows.Forms.SendKeys]::SendWait($Keys)
  Start-Sleep -Milliseconds 120
  Write-Host "sent $Keys"
}

function Type-Text {
  <#
    .SYNOPSIS
      输入文本。

      默认走**剪贴板粘贴**（Ctrl+V）。原因：中文输入法会把 SendKeys 的字母当拼音转换，
      实测 `nmap -sV` 被变成 `你马屁-是V`。粘贴能彻底绕开输入法，而且中文也能输入。

      `-Method Keys` 走 SendKeys（逐字符 + 延时防丢字），会尝试关掉前台窗口的输入法；
      只有禁止粘贴的控件（密码框等）才需要用它。
    .EXAMPLE
      Type-Text 'nmap -sV 10.0.0.1'
      Type-Text 'whoami{ENTER}'
      Type-Text 'nmap -sV 10.0.0.1' -Method Keys
  #>
  param(
    [Parameter(Mandatory)][string]$Text,
    [ValidateSet('Paste','Keys')][string]$Method = 'Paste',
    [int]$PerCharDelayMs = 18,     # Keys 模式专用；默认值就是防丢字，别改成 0
    [int]$PasteWaitMs = 350,
    [switch]$DryRun
  )
  Add-Type -AssemblyName System.Windows.Forms
  if ($DryRun) { Write-Host "DRYRUN type $($Text.Length) chars via $Method"; return }

  if ($Method -eq 'Paste') {
    # 尽量还原用户原本的剪贴板（纯文本可还原；图片/文件还原不了，属已知限制）
    $saved = $null
    try { $saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }
    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds $PasteWaitMs
    if ($null -ne $saved) { try { Set-Clipboard -Value $saved } catch { } }
    Write-Host "pasted $($Text.Length) chars"
    return
  }

  # ── Keys 模式：先想办法关掉中文输入法，否则字母会被转成汉字 ──
  try { [void](Set-ImeMode -Disable) } catch { Write-Host "提示: 未能关闭输入法，可能打出汉字" }
  foreach ($ch in $Text.ToCharArray()) {
    [System.Windows.Forms.SendKeys]::SendWait($ch)
    if ($PerCharDelayMs -gt 0) { Start-Sleep -Milliseconds $PerCharDelayMs }
  }
  Start-Sleep -Milliseconds 120
  Write-Host "typed $($Text.Length) chars"
}

function Set-ImeMode {
  <#
    .SYNOPSIS
      把前台窗口切到英文键盘布局（或切回中文），给 Keys 模式兜底用。

      注意：现代中文输入法（微软拼音等）是 TSF 架构，传统的 IMM32
      `ImmSetConversionStatus` **对它无效**（实测切了还是打汉字）。
      所以这里主用 `WM_INPUTLANGCHANGEREQUEST` 把窗口的键盘布局换成 en-US。
    .EXAMPLE
      Set-ImeMode -Disable
  #>
  param([switch]$Disable, [switch]$Enable)
  if (-not ('ImeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ImeNative {
  [DllImport("imm32.dll")] public static extern IntPtr ImmGetContext(IntPtr hWnd);
  [DllImport("imm32.dll")] public static extern bool ImmReleaseContext(IntPtr hWnd, IntPtr hIMC);
  [DllImport("imm32.dll")] public static extern bool ImmGetConversionStatus(IntPtr hIMC, out int conv, out int sentence);
  [DllImport("imm32.dll")] public static extern bool ImmSetConversionStatus(IntPtr hIMC, int conv, int sentence);
  [DllImport("imm32.dll")] public static extern bool ImmSetOpenStatus(IntPtr hIMC, bool open);
  [DllImport("user32.dll")] public static extern IntPtr LoadKeyboardLayout(string klid, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint threadId);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public const int IME_CMODE_NATIVE = 0x0001;
  public const uint WM_INPUTLANGCHANGEREQUEST = 0x0050;
  public const uint KLF_ACTIVATE = 0x0001;
}
'@
  }
  $h = [ImeNative]::GetForegroundWindow()

  # 1) 主办法：把前台窗口的键盘布局换成 en-US（0x0409）
  if ($Disable) {
    $hkl = [ImeNative]::LoadKeyboardLayout('00000409', [ImeNative]::KLF_ACTIVATE)
    if ($hkl -ne [IntPtr]::Zero) {
      [void][ImeNative]::PostMessage($h, [ImeNative]::WM_INPUTLANGCHANGEREQUEST, [IntPtr]::Zero, $hkl)
      Start-Sleep -Milliseconds 250
      return $true
    }
  }

  # 2) 兜底：IMM32 转换状态（对 TSF 输入法多半无效，聊胜于无）
  $himc = [ImeNative]::ImmGetContext($h)
  if ($himc -eq [IntPtr]::Zero) { return $false }
  try {
    $conv = 0; $sent = 0
    [void][ImeNative]::ImmGetConversionStatus($himc, [ref]$conv, [ref]$sent)
    if ($Disable) { $conv = $conv -band (-bnot [ImeNative]::IME_CMODE_NATIVE) }
    else          { $conv = $conv -bor [ImeNative]::IME_CMODE_NATIVE }
    [void][ImeNative]::ImmSetConversionStatus($himc, $conv, $sent)
    [void][ImeNative]::ImmSetOpenStatus($himc, (-not $Disable))
    return $true
  } finally {
    [void][ImeNative]::ImmReleaseContext($h, $himc)
  }
}

function Paste-Text {
  <# 显式粘贴（Type-Text -Method Paste 的别名，语义更清楚） #>
  param([Parameter(Mandatory)][string]$Text, [switch]$DryRun)
  Type-Text -Text $Text -Method Paste -DryRun:$DryRun
}

# ── 读屏（本模块内的轻量版） ────────────────────────────────────

function Read-ScreenDump {
  <# 调用配套脚本读屏，返回纯文本行 #>
  param([ValidateSet('auto','uia','ocr','both')][string]$Mode = 'auto', [string]$Window)
  $script = Join-Path $PSScriptRoot 'read-screen.ps1'
  if (-not (Test-Path -LiteralPath $script)) { throw "找不到 $script" }
  $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Mode',$Mode)
  if ($Window) { $psArgs += @('-Window',$Window) }
  & powershell @psArgs
}

function Get-CurrentContext {
  <# 当前前台窗口是谁、光标在哪 —— 动手前先看这个 #>
  $vs = Get-VirtualScreen
  $fg = [NativeInput]::GetForegroundWindow()
  $title = (Get-Process | Where-Object { $_.MainWindowHandle -eq $fg } |
            Select-Object -First 1 -ExpandProperty MainWindowTitle)
  [pscustomobject]@{
    ForegroundTitle = $title
    Cursor = (Get-CursorPosition)
    Screen = "$($vs.W)x$($vs.H) @ ($($vs.X),$($vs.Y))"
  }
}

Export-ModuleMember -Function `
  Get-VirtualScreen, Get-CursorPosition, Move-Cursor, Invoke-MouseClick, Invoke-Scroll, `
  Get-AppWindow, Set-AppWindow, Get-ScreenControl, Click-Control, `
  Send-Hotkey, Type-Text, Paste-Text, Set-ImeMode, Read-ScreenDump, Get-CurrentContext
