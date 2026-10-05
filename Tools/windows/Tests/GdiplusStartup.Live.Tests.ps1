[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $ZigExecutable,
  [Parameter(Mandatory)][string] $WinghosttyRoot,
  [string] $ScratchRoot = (Join-Path $env:TEMP "graphcode-gdiplus-startup")
)

$ErrorActionPreference = "Stop"

if (-not ("GraphCodeGdiplusStartupNative" -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class GraphCodeGdiplusStartupNative {
  public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder value, int capacity);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);

  public static IntPtr Find(uint processId, string className) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId || !IsWindowVisible(window)) return true;
      var actual = new StringBuilder(128);
      GetClassName(window, actual, actual.Capacity);
      if (!String.Equals(actual.ToString(), className, StringComparison.Ordinal)) return true;
      result = window;
      return false;
    }, IntPtr.Zero);
    return result;
  }
}
'@
}

$shellRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\graphcode-windows")
$scratch = [IO.Path]::GetFullPath($ScratchRoot)
$bin = Join-Path $scratch "bin"
$profile = Join-Path $scratch "profile"
$temp = Join-Path $scratch "temp"
$executable = Join-Path $bin "gdiplus-startup-live.exe"
if (Test-Path -LiteralPath $scratch) {
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
New-Item -ItemType Directory -Force -Path `
  $bin,$profile,(Join-Path $profile "AppData\Local"),(Join-Path $profile "AppData\Roaming"),$temp |
  Out-Null

$include = Join-Path $WinghosttyRoot "include"
Push-Location $shellRoot
try {
  & $ZigExecutable build-exe src\GdiplusStartupLiveRunner.zig `
    -target x86_64-windows-msvc -OReleaseSafe -lc `
    -luser32 -lgdi32 -lgdiplus "-I$include" "-femit-bin=$executable"
  if ($LASTEXITCODE -ne 0) {
    throw "GDI+ startup live runner build failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

$system32 = Join-Path $env:SystemRoot "System32"
$powerShell = Join-Path $system32 "WindowsPowerShell\v1.0"
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $executable
$start.WorkingDirectory = $bin
$start.UseShellExecute = $false
$start.Environment.Clear()
$values = [ordered]@{
  SystemRoot = $env:SystemRoot
  windir = $env:WINDIR
  USERPROFILE = $profile
  LOCALAPPDATA = Join-Path $profile "AppData\Local"
  APPDATA = Join-Path $profile "AppData\Roaming"
  TEMP = $temp
  TMP = $temp
  ProgramData = $env:ProgramData
  HOMEDRIVE = [IO.Path]::GetPathRoot($profile).TrimEnd("\")
  HOMEPATH = $profile.Substring([IO.Path]::GetPathRoot($profile).Length - 1)
  PATH = "$system32;$powerShell;$bin"
}
foreach ($name in $values.Keys) { $start.Environment[$name] = [string]$values[$name] }

$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$observations = 0
$window = [IntPtr]::Zero
try {
  if (-not $process.Start()) { throw "GDI+ startup live runner did not start" }
  [void]$process.Handle
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $observations++
    $process.Refresh()
    if ($process.HasExited) {
      throw ("GDI+ startup live runner exited before creating a native window: " +
        "exitCode=$($process.ExitCode); observations=$observations")
    }
    $window = [GraphCodeGdiplusStartupNative]::Find(
      [uint32]$process.Id,
      "GraphCodeGdiplusStartupTest"
    )
    if ($window -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)

  if ($observations -le 0) { throw "GDI+ startup live runner made zero observations" }
  if ($window -eq [IntPtr]::Zero) {
    throw ("GDI+ startup live runner remained alive but no native window appeared: " +
      "observations=$observations; environmentKeys=$(
        @($start.Environment.Keys | Sort-Object) -join ',')")
  }
  Write-Output ("GDIPLUS_STARTUP_LIVE: PASS; executed=1; observations=$observations; " +
    "window=$($window.ToInt64()); environmentKeys=$(
      @($start.Environment.Keys | Sort-Object) -join ',')")
} finally {
  if ($process -and -not $process.HasExited) {
    Stop-Process -Id $process.Id -Force
    [void]$process.WaitForExit(10000)
  }
  if ($process) { $process.Dispose() }
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
