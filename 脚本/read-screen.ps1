<#
.SYNOPSIS
  把屏幕内容转成「文字」，让 Codex 能读。

  为什么需要它：Codex 当前模型（deepseek-v4-flash）没有视觉能力，看不了截图。
  但本机有两个零安装的文字化通道：
    1) UIA（无障碍树）—— 直接读出窗口里每个控件/文字，还能拿到坐标，最准
    2) Windows 内置 OCR —— 把画面识别成文字，任何东西都能读，兜底

.EXAMPLE
  .\read-screen.ps1                     # auto：先试 UIA，文字太少再 OCR
  .\read-screen.ps1 -Mode uia           # 只要控件树（带坐标，适合"告诉我点哪"）
  .\read-screen.ps1 -Mode ocr           # 只要 OCR 文字
  .\read-screen.ps1 -Window chrome      # 只读某个窗口
  .\read-screen.ps1 -Window msedge -Mode ocr
#>
[CmdletBinding()]
param(
  [ValidateSet('auto','uia','ocr','both')]
  [string]$Mode = 'auto',
  [string]$Window,                      # 进程名，可省略 .exe
  [int]$MaxNodes = 3000,
  [switch]$Keep                         # 保留中间截图
)

$ErrorActionPreference = 'Stop'

# ── 工具函数 ────────────────────────────────────────────────────
# DPI 感知：必须在任何 GDI/窗口调用前设置，否则截图会被缩放（OCR 变糊），
# 且逻辑分辨率与 UIA 的物理坐标对不上。
if (-not ("DpiAwareR" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiAwareR {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@
}
if (-not [DpiAwareR]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][DpiAwareR]::SetProcessDPIAware() }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($op, $type) {
  $m = $script:asTaskGeneric.MakeGenericMethod($type)
  $t = $m.Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result
}

function Get-TargetProcess {
  param([string]$Name)
  if (-not $Name) { return $null }
  $n = $Name -replace '\.exe$', ''
  $p = Get-Process -Name $n -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { throw "找不到带窗口的进程: $n" }
  return $p
}

# ── 截图（原生分辨率，OCR 用） ──────────────────────────────────
function Save-Screenshot {
  param([object]$Proc, [string]$Path)
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  if (-not ("Win32Rect2" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Rect2 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@
  }
  if ($Proc) {
    $r = New-Object Win32Rect2+RECT
    [void][Win32Rect2]::GetWindowRect($Proc.MainWindowHandle, [ref]$r)
    $x = $r.Left; $y = $r.Top; $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  } else {
    $x = [DpiAwareR]::GetSystemMetrics(76); $y = [DpiAwareR]::GetSystemMetrics(77)
    $w = [DpiAwareR]::GetSystemMetrics(78); $h = [DpiAwareR]::GetSystemMetrics(79)
  }
  if ($w -le 0 -or $h -le 0) { throw "窗口尺寸非法: ${w}x${h}" }
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
  $g.Dispose()
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return @{ X = $x; Y = $y; W = $w; H = $h }
}

# ── 通道 1：UIA 控件树 ─────────────────────────────────────────
function Read-ByUia {
  param([object]$Proc, [int]$Limit)
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $AE = [System.Windows.Automation.AutomationElement]
  $root = $AE::RootElement
  if ($Proc) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $Proc.Id)
    $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
    if (-not $win) { return @() }
  } else {
    $win = $AE::FocusedElement
    # 往上找到顶层窗口
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    while ($true) {
      $parent = $walker.GetParent($win)
      if (-not $parent -or $parent -eq $root) { break }
      $win = $parent
    }
  }

  $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                      [System.Windows.Automation.Condition]::TrueCondition)
  $out = New-Object System.Collections.Generic.List[string]
  $count = 0
  foreach ($el in $all) {
    if ($count -ge $Limit) { break }
    $count++
    try {
      $name = $el.Current.Name
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $ct = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
      $r = $el.Current.BoundingRectangle
      $cx = [int]($r.X + $r.Width / 2); $cy = [int]($r.Y + $r.Height / 2)
      $enabled = if ($el.Current.IsEnabled) { '' } else { ' [禁用]' }
      $out.Add("[$ct]$enabled `"$name`"  @($cx,$cy)")
    } catch { }
  }
  return $out
}

# ── 通道 2：Windows OCR ────────────────────────────────────────
function Read-ByOcr {
  param([string]$ImagePath)
  [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
  [Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime] | Out-Null
  [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime] | Out-Null
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if (-not $engine) { throw "没有可用的 OCR 引擎（系统缺少语言包）" }
  try {
    $res = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $res.Lines) { $lines.Add($l.Text) }
    return @{ Text = ($lines -join "`n"); Count = $lines.Count; Lang = $engine.RecognizerLanguage.LanguageTag }
  } finally {
    # 必须显式释放，否则 PNG 被 WinRT 流占住删不掉
    if ($bmp) { $bmp.Dispose() }
    if ($decoder) { $decoder = $null }
    if ($stream) { $stream.Dispose() }
    if ($file) { $file = $null }
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
  }
}

# ── 主流程 ──────────────────────────────────────────────────────
$proc = Get-TargetProcess $Window
$target = if ($proc) { "$($proc.ProcessName) (PID $($proc.Id))" } else { '前台窗口' }
Write-Output "### 读屏目标: $target"

# 清理上一轮可能残留的 OCR 临时图（上一轮进程已退出，锁已释放）
$shotDir = Join-Path $PSScriptRoot "shots"
if (Test-Path -LiteralPath $shotDir) {
  Get-ChildItem -LiteralPath $shotDir -Filter ".ocr-tmp-*.png" -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

$uiaLines = $null
if ($Mode -in @('auto','uia','both')) {
  try { $uiaLines = Read-ByUia -Proc $proc -Limit $MaxNodes } catch { Write-Output ("### UIA 失败: " + $_.Exception.Message.Split([char]10)[0]) }
}

$needOcr = ($Mode -eq 'ocr') -or ($Mode -eq 'both')
if ($Mode -eq 'auto') {
  # UIA 拿到的有效文字行太少 → 走 OCR 兜底
  $chars = if ($uiaLines) { ($uiaLines -join '').Length } else { 0 }
  $needOcr = ($chars -lt 200)
}

if ($uiaLines -and ($Mode -in @('auto','uia','both'))) {
  Write-Output "### UIA 控件树（$($uiaLines.Count) 项）"
  if ($uiaLines.Count -eq 0) { Write-Output "(空)" } else { $uiaLines | ForEach-Object { Write-Output $_ } }
}

if ($needOcr) {
  $png = Join-Path $PSScriptRoot ("shots\.ocr-tmp-{0:HHmmss}.png" -f (Get-Date))
  $null = Save-Screenshot -Proc $proc -Path $png
  try {
    $r = Read-ByOcr -ImagePath $png
    Write-Output "### OCR 文字（$($r.Count) 行，引擎 $($r.Lang)）"
    Write-Output $r.Text
  } finally {
    if (-not $Keep) {
      Start-Sleep -Milliseconds 200
      Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $png) { Write-Output "### 提示：临时截图未能删除，可手动清理 $png" }
    }
  }
}
