param(
  [double]$XRatio = 0.742,
  [double]$YRatio = 0.447
)

$logPath = Join-Path $PSScriptRoot "icbc-launch.log"

function Write-Log {
  param([string]$Message)
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
  Add-Content -LiteralPath $logPath -Value "[$timestamp] [focus] $Message" -Encoding UTF8
}

Write-Log "focus-account.ps1 started. XRatio=$XRatio YRatio=$YRatio"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class MouseTools {
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int x, int y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
}
"@

Add-Type -AssemblyName System.Windows.Forms

$edge = Get-Process msedge -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 } |
  Sort-Object StartTime -Descending |
  Select-Object -First 1

if ($edge) {
  Write-Log "Found Edge window. Id=$($edge.Id) Handle=$($edge.MainWindowHandle) Title=$($edge.MainWindowTitle)"
  [MouseTools]::ShowWindow($edge.MainWindowHandle, 3) | Out-Null
  Start-Sleep -Milliseconds 300
  $foregroundResult = [MouseTools]::SetForegroundWindow($edge.MainWindowHandle)
  Write-Log "SetForegroundWindow result: $foregroundResult"
  Start-Sleep -Milliseconds 700
} else {
  Write-Log "No Edge window with MainWindowHandle found."
}

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$x = [int]($bounds.Width * $XRatio)
$y = [int]($bounds.Height * $YRatio)

Write-Log "Primary screen bounds: X=$($bounds.X) Y=$($bounds.Y) Width=$($bounds.Width) Height=$($bounds.Height)"
Write-Log "Calculated click point: X=$x Y=$y"
[MouseTools]::SetCursorPos($x, $y) | Out-Null
Write-Log "Cursor moved."
Start-Sleep -Milliseconds 250
[MouseTools]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Write-Log "Mouse down sent."
Start-Sleep -Milliseconds 120
[MouseTools]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Write-Log "Mouse up sent."
