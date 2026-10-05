[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Shell,
  [Parameter(Mandatory)][string] $Daemon,
  [Parameter(Mandatory)][string] $Cli,
  [Parameter(Mandatory)][string] $ScratchRoot
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ScrubbedStartupNative {
  public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, System.Text.StringBuilder value, int capacity);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
  public static IntPtr Find(uint processId, string className) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId || !IsWindowVisible(window)) return true;
      var actual = new System.Text.StringBuilder(128);
      GetClassName(window, actual, actual.Capacity);
      if (!String.Equals(actual.ToString(), className, StringComparison.Ordinal)) return true;
      result = window;
      return false;
    }, IntPtr.Zero);
    return result;
  }
  public static bool Escape(IntPtr window) {
    return PostMessage(window, 0x0100, (UIntPtr)0x1B, IntPtr.Zero) &&
      PostMessage(window, 0x0101, (UIntPtr)0x1B, IntPtr.Zero);
  }
  public static bool Command(IntPtr window, uint action) {
    return PostMessage(window, 0x0111, (UIntPtr)action, IntPtr.Zero);
  }
}
'@

$allowedKeys = @(
  "SystemRoot", "windir", "USERPROFILE", "LOCALAPPDATA", "APPDATA",
  "TEMP", "TMP", "ProgramData", "HOMEDRIVE", "HOMEPATH", "PATH"
)
$forbiddenPathFragments = @(
  ".graphcode-tools", "Visual Studio", "Windows Kits", "Swift"
)

function New-StartInfo([string] $file, [string] $root) {
  $profile = Join-Path $root "profile"
  $system32 = Join-Path $env:SystemRoot "System32"
  $powerShell = Join-Path $system32 "WindowsPowerShell\v1.0"
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $file
  $info.WorkingDirectory = Split-Path -Parent $file
  $info.UseShellExecute = $false
  $info.Environment.Clear()
  $values = [ordered]@{
    SystemRoot = $env:SystemRoot
    windir = $env:WINDIR
    USERPROFILE = $profile
    LOCALAPPDATA = Join-Path $profile "AppData\Local"
    APPDATA = Join-Path $profile "AppData\Roaming"
    TEMP = Join-Path $root "temp"
    TMP = Join-Path $root "temp"
    ProgramData = $env:ProgramData
    HOMEDRIVE = [IO.Path]::GetPathRoot($profile).TrimEnd("\")
    HOMEPATH = $profile.Substring([IO.Path]::GetPathRoot($profile).Length - 1)
    PATH = "$system32;$powerShell;$(Split-Path -Parent $file)"
  }
  foreach ($name in $values.Keys) { $info.Environment[$name] = [string]$values[$name] }
  return $info
}

function Wait-NativeWindow([int] $processId, [string] $className, [int] $seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
  do {
    $window = [ScrubbedStartupNative]::Find([uint32]$processId, $className)
    if ($window -ne [IntPtr]::Zero) { return $window }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  return [IntPtr]::Zero
}

function Wait-NativeWindowClosed([int] $processId, [string] $className, [int] $seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
  do {
    if ([ScrubbedStartupNative]::Find([uint32]$processId, $className) -eq [IntPtr]::Zero) {
      return $true
    }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  return $false
}

function Wait-File([string] $path, [int] $seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
  do {
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  return $false
}

function Invoke-ScrubbedCli([string] $name, [string] $root, [string] $support, [string[]] $arguments) {
  $cliInfo = New-StartInfo $Cli $root
  $cliInfo.Environment["GRAPHCODE_SUPPORT_DIR"] = $support
  foreach ($argument in $arguments) { [void]$cliInfo.ArgumentList.Add($argument) }
  $cliInfo.RedirectStandardOutput = $true
  $cliInfo.RedirectStandardError = $true
  $cliProcess = [Diagnostics.Process]::new()
  $cliProcess.StartInfo = $cliInfo
  try {
    if (-not $cliProcess.Start()) { throw "$name CLI '$($arguments[0])' could not start" }
    $stdout = $cliProcess.StandardOutput.ReadToEndAsync()
    $stderr = $cliProcess.StandardError.ReadToEndAsync()
    if (-not $cliProcess.WaitForExit(10000)) { throw "$name CLI '$($arguments[0])' timed out" }
    return [pscustomobject]@{
      ExitCode = $cliProcess.ExitCode
      Output = $stdout.GetAwaiter().GetResult()
      Error = $stderr.GetAwaiter().GetResult()
    }
  } finally {
    if (-not $cliProcess.HasExited) { $cliProcess.Kill() }
    $cliProcess.Dispose()
  }
}

function Wait-ProjectRow([int] $processId, [string] $projectName, [int] $seconds) {
  $processCondition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ProcessIdProperty, $processId)
  $rowCondition = [Windows.Automation.AndCondition]::new(
    [Windows.Automation.PropertyCondition]::new(
      [Windows.Automation.AutomationElement]::ControlTypeProperty,
      [Windows.Automation.ControlType]::ListItem),
    [Windows.Automation.PropertyCondition]::new(
      [Windows.Automation.AutomationElement]::NameProperty, $projectName))
  $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
  do {
    $window = [Windows.Automation.AutomationElement]::RootElement.FindFirst(
      [Windows.Automation.TreeScope]::Children, $processCondition)
    if ($window) {
      $row = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $rowCondition)
      if ($row -and $row.Current.AutomationId.StartsWith("open-project-", [StringComparison]::Ordinal)) {
        return $row.Current.AutomationId
      }
    }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  return $null
}

function Invoke-Case(
  [string] $name,
  [ValidateSet("escape", "skip", "complete", "marker", "project")]
  [string] $action
) {
  $root = Join-Path $ScratchRoot $name
  $profile = Join-Path $root "profile"
  $support = Join-Path $profile ".graphcode"
  New-Item -ItemType Directory -Force -Path `
    $support,(Join-Path $profile "AppData\Local"),(Join-Path $profile "AppData\Roaming"),(Join-Path $root "temp") |
    Out-Null
  if ($action -in @("marker", "project")) {
    Set-Content -LiteralPath (Join-Path $support "onboarding-seen") -Value "seen" -NoNewline
  }
  # A plain folder, not a Git repository: startup must not need Git on PATH.
  $projectPath = Join-Path $root "Core"
  $projectRow = $null
  if ($action -eq "project") {
    New-Item -ItemType Directory -Force -Path $projectPath | Out-Null
    Set-Content -LiteralPath (Join-Path $projectPath "README.md") -Value "fixture" -NoNewline
  }

  $daemonProcess = [Diagnostics.Process]::new()
  $daemonInfo = New-StartInfo $Daemon $root
  $daemonInfo.Environment["GRAPHCODE_SUPPORT_DIR"] = $support
  $daemonProcess.StartInfo = $daemonInfo
  $shellProcess = [Diagnostics.Process]::new()
  $shellProcess.StartInfo = New-StartInfo $Shell $root
  try {
    if (-not $daemonProcess.Start()) { throw "$name could not start the production daemon" }
    if ($action -eq "project") {
      # Register through the production daemon before the shell starts, as the
      # native folder picker does, so the shell restores a real daemon graph.
      $deadline = [DateTime]::UtcNow.AddSeconds(15)
      do {
        $status = Invoke-ScrubbedCli $name $root $support @("status", $projectPath)
        if ($status.ExitCode -eq 0) { break }
        Start-Sleep -Milliseconds 250
      } while ([DateTime]::UtcNow -lt $deadline)
      if ($status.ExitCode -ne 0) { throw "$name could not register the project: $($status.Error)" }
    }
    if (-not $shellProcess.Start()) { throw "$name could not start the production shell" }
    [void]$daemonProcess.Handle
    [void]$shellProcess.Handle
    $keys = @($shellProcess.StartInfo.Environment.Keys | Sort-Object)
    if (($keys -join "|") -cne (($allowedKeys | Sort-Object) -join "|")) {
      throw "$name environment keys differ: $($keys -join ',')"
    }
    foreach ($fragment in $forbiddenPathFragments) {
      if ($shellProcess.StartInfo.Environment["PATH"].IndexOf(
          $fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "$name PATH contains forbidden developer fragment '$fragment'"
      }
    }

    $onboarding = Wait-NativeWindow $shellProcess.Id "GraphCodeWindowsOnboarding" 10
    if ($action -notin @("marker", "project")) {
      if ($onboarding -eq [IntPtr]::Zero) { throw "$name onboarding was not shown" }
      switch ($action) {
        "escape" {
          if (-not [ScrubbedStartupNative]::Escape($onboarding)) {
            throw "$name onboarding rejected Escape"
          }
        }
        "skip" {
          if (-not [ScrubbedStartupNative]::Command($onboarding, 2)) {
            throw "$name onboarding rejected Skip"
          }
        }
        "complete" {
          foreach ($page in 1..4) {
            if (-not [ScrubbedStartupNative]::Command($onboarding, 4)) {
              throw "$name onboarding rejected primary action on page $page"
            }
            Start-Sleep -Milliseconds 50
          }
        }
      }
      if (-not (Wait-NativeWindowClosed $shellProcess.Id "GraphCodeWindowsOnboarding" 10)) {
        throw "$name onboarding did not close"
      }
    } elseif ($onboarding -ne [IntPtr]::Zero) {
      throw "$name onboarding was shown despite the marker"
    }

    $main = Wait-NativeWindow $shellProcess.Id "GraphCodeWindowsShell" 10
    $shellProcess.Refresh()
    $daemonProcess.Refresh()
    if ($main -eq [IntPtr]::Zero -or $shellProcess.HasExited -or $daemonProcess.HasExited) {
      throw "$name did not retain live shell/daemon after onboarding"
    }
    if ($action -eq "project") {
      $projectRow = Wait-ProjectRow $shellProcess.Id "Core" 20
      if (-not $projectRow) { throw "$name did not show the registered daemon project row" }
      $survivalDeadline = [DateTime]::UtcNow.AddSeconds(5)
      do {
        $shellProcess.Refresh()
        if ($shellProcess.HasExited) {
          throw "$name shell exited with 0x$($shellProcess.ExitCode.ToString('X8')) after showing the project"
        }
        Start-Sleep -Milliseconds 100
      } while ([DateTime]::UtcNow -lt $survivalDeadline)
    }
    $markerPath = Join-Path $support "onboarding-seen"
    if (-not (Wait-File $markerPath 10)) {
      throw "$name did not persist the onboarding marker"
    }
    $logPath = Join-Path $support "graphcode-windows.log"
    $log = if (Test-Path $logPath) { Get-Content $logPath -Raw } else { "" }
    if ($log -match 'event=fatal') { throw "$name logged a fatal startup event: $log" }

    $projects = Invoke-ScrubbedCli $name $root $support @("projects")
    if ($projects.ExitCode -ne 0) {
      throw "$name CLI endpoint rejected the request: $($projects.Error)"
    }
    $stdout = $projects.Output
    if ($action -eq "project" -and $stdout -notmatch "(?m)^Core\s") {
      throw "$name CLI does not list the registered project"
    }
    return [ordered]@{
      name = $name
      onboardingObserved = $onboarding -ne [IntPtr]::Zero
      action = $action
      mainWindow = $main.ToInt64()
      shellProcessId = $shellProcess.Id
      daemonProcessId = $daemonProcess.Id
      cliOutput = $stdout.Trim()
      projectRow = $projectRow
      environmentKeys = $keys
      fatalLogAbsent = $true
    }
  } finally {
    foreach ($process in @($shellProcess,$daemonProcess)) {
      if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        [void]$process.WaitForExit(10000)
      }
      if ($process) { $process.Dispose() }
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
}

New-Item -ItemType Directory -Force -Path $ScratchRoot | Out-Null
$results = @(
  Invoke-Case "first-run-escape" "escape"
  Invoke-Case "first-run-skip" "skip"
  Invoke-Case "first-run-complete" "complete"
  Invoke-Case "onboarding-marker" "marker"
  Invoke-Case "registered-project" "project"
)
if ($results.Count -ne 5) { throw "Scrubbed startup executed $($results.Count)/5 cases" }
Write-Output ("SCRUBBED_SHELL_STARTUP: PASS; executed=$($results.Count); " +
  "developerToolsExcluded=true; results=" + ($results | ConvertTo-Json -Compress -Depth 5))
