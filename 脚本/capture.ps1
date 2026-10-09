<#
.SYNOPSIS
  截屏给 Codex 看。支持全屏 / 指定窗口 / 指定区域，可自动缩放以省 token。

.EXAMPLE
  # 全屏（默认缩放到 1600 宽）
  .\capture.ps1

  # 只截 Chrome 窗口
  .\capture.ps1 -Window chrome

  # 截指定区域
  .\capture.ps1 -Region 0,0,1280,720

  # 不缩放，原尺寸
  .\capture.ps1 -Scale 1
#>
[CmdletBinding()]
param(
  [string]$Out,
  [string]$Window,                       # 进程名（可省略 .exe），截该进程主窗口
  [int[]]$Region,                        # x,y,w,h
  [double]$Scale = 0,                    # 0 = 自动（超 1600 宽就缩），1 = 原始尺寸
  [int]$MaxWidth = 1600
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# DPI 感知：截图按物理像素抓，避免被系统缩放成模糊小图
if (-not ("DpiAwareC" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiAwareC {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@
}
if (-not [DpiAwareC]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][DpiAwareC]::SetProcessDPIAware() }

if (-not ("Win32Rect" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Rect {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
}

# ── 决定截取范围 ────────────────────────────────────────────────
$rect = $null
$label = "fullscreen"

if ($Window) {
  $name = $Window -replace '\.exe$', ''
  $proc = Get-Process -Name $name -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $proc) { Write-Error "找不到带窗口的进程: $name"; exit 2 }
  $r = New-Object Win32Rect+RECT
  if (-not [Win32Rect]::GetWindowRect($proc.MainWindowHandle, [ref]$r)) {
    Write-Error "拿不到窗口尺寸: $name"; exit 2
  }
  $rect = @{ X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top }
  $label = "window:$($proc.ProcessName)"
}
elseif ($Region -and $Region.Count -eq 4) {
  $rect = @{ X = $Region[0]; Y = $Region[1]; W = $Region[2]; H = $Region[3] }
  $label = "region:$($Region -join ',')"
}
else {
  $rect = @{ X = [DpiAwareC]::GetSystemMetrics(76); Y = [DpiAwareC]::GetSystemMetrics(77)
             W = [DpiAwareC]::GetSystemMetrics(78); H = [DpiAwareC]::GetSystemMetrics(79) }
  $label = "fullscreen:$($rect.W)x$($rect.H)"
}

if ($rect.W -le 0 -or $rect.H -le 0) { Write-Error "截取范围非法: $($rect.W)x$($rect.H)"; exit 2 }

# ── 抓图 ────────────────────────────────────────────────────────
$src = New-Object System.Drawing.Bitmap $rect.W, $rect.H
$g = [System.Drawing.Graphics]::FromImage($src)
$g.CopyFromScreen($rect.X, $rect.Y, 0, 0, $src.Size)
$g.Dispose()

# ── 缩放 ────────────────────────────────────────────────────────
$factor = if ($Scale -gt 0) { $Scale } elseif ($rect.W -gt $MaxWidth) { $MaxWidth / $rect.W } else { 1 }
if ($factor -ne 1) {
  $tw = [int][Math]::Round($rect.W * $factor)
  $th = [int][Math]::Round($rect.H * $factor)
  $dst = New-Object System.Drawing.Bitmap $tw, $th
  $g2 = [System.Drawing.Graphics]::FromImage($dst)
  $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g2.DrawImage($src, 0, 0, $tw, $th)
  $g2.Dispose()
  $src.Dispose()
  $src = $dst
}

# ── 保存 ────────────────────────────────────────────────────────
if (-not $Out) {
  $dir = Join-Path $PSScriptRoot "shots"
  $Out = Join-Path $dir ("screen-{0:yyyyMMdd-HHmmss}.png" -f (Get-Date))
}
$parent = Split-Path -Parent $Out
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$src.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$size = (Get-Item -LiteralPath $Out).Length
$outW = $src.Width
$outH = $src.Height
$src.Dispose()

Write-Output ("SAVED " + $Out)
Write-Output ("SOURCE " + $label + "  ->  " + $outW + "x" + $outH + "  " + [math]::Round($size/1KB,1) + " KB")
