# win.ps1 - localize + drive a visible console window by title substring
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [string]$Text,
  [switch]$NoEnter,
  [switch]$ForegroundOnly
)

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinAPIx {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);

  public static List<IntPtr> Find(string sub) {
    var res = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (IsWindowVisible(h)) {
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, 512);
        if (sb.ToString().IndexOf(sub, StringComparison.OrdinalIgnoreCase) >= 0) res.Add(h);
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }
  public static string Title(IntPtr h) {
    var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString();
  }
  public static string ForeTitle() { return Title(GetForegroundWindow()); }
  public static IntPtr Fore() { return GetForegroundWindow(); }

  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

  public static void ForceForeground(IntPtr h) {
    IntPtr fg = GetForegroundWindow();
    uint dummy;
    uint fgTid = GetWindowThreadProcessId(fg, out dummy);
    uint myTid = GetCurrentThreadId();
    if (fgTid != myTid) AttachThreadInput(myTid, fgTid, true);
    keybd_event(0x12, 0, 0, IntPtr.Zero);      // ALT down
    ShowWindow(h, 9);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    keybd_event(0x12, 0, 2, IntPtr.Zero);      // ALT up
    if (fgTid != myTid) AttachThreadInput(myTid, fgTid, false);
  }
}
'@ -ErrorAction SilentlyContinue

$hits = [WinAPIx]::Find($Title)
if ($hits.Count -eq 0) { Write-Output "NO_WINDOW: $Title"; exit 2 }
$h = $hits[0]

if (-not $ForegroundOnly) {
  [WinAPIx]::ForceForeground($h)
  Start-Sleep -Milliseconds 450
}

$cur = [WinAPIx]::ForeTitle()
Write-Output "TARGET_HWND=$h"
Write-Output "FORE_TITLE=$cur"
if ($cur -notlike "*$Title*") {
  [WinAPIx]::ForceForeground($h)
  Start-Sleep -Milliseconds 600
  $cur = [WinAPIx]::ForeTitle()
  Write-Output "FORE_TITLE2=$cur"
  if ($cur -notlike "*$Title*") { Write-Output "NOT_FOREGROUND"; exit 3 }
}

if ($Text) {
  Import-Module D:\agent\ScreenReader\InputHelper.psm1 -DisableNameChecking
  Send-Hotkey '{ESC}'          # leave console select/pause mode if any; clears empty line otherwise
  Start-Sleep -Milliseconds 250
  Type-Text $Text -PasteWaitMs 1200
  Start-Sleep -Milliseconds 1200
  if (-not $NoEnter) { Send-Hotkey '{ENTER}' }
  Write-Output "SENT: $Text"
}
exit 0
