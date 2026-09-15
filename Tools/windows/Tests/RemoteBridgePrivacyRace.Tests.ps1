param(
  [ValidateRange(1, 1024)]
  [int] $AvailableProcessorCount = [Environment]::ProcessorCount
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) {
  throw "Python 3 was not found for the remote bridge race regression"
}

function Start-CapturedProcess(
  [string] $fileName,
  [string[]] $arguments,
  [hashtable] $environment = @{}
) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $fileName
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $arguments) {
    [void] $startInfo.ArgumentList.Add($argument)
  }
  foreach ($entry in $environment.GetEnumerator()) {
    $startInfo.Environment[$entry.Key] = $entry.Value
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void] $process.Start()
  return [pscustomobject]@{
    Process = $process
    Stdout = $process.StandardOutput.ReadToEndAsync()
    Stderr = $process.StandardError.ReadToEndAsync()
  }
}

$testPath = Join-Path $repoRoot "investigation\spikes\remote-bridge"
$remoteArguments = @(
  "-B",
  (Join-Path $testPath "run_tests.py")
)
$privacyArguments = @(
  "-NoProfile",
  "-File",
  (Join-Path $repoRoot "Tools\windows\validate.ps1"),
  "-Task",
  "privacy"
)

# Exercise coexistence without turning socket deadlines into a scheduler-starvation test.
$processorCount = [Math]::Max(1, $AvailableProcessorCount)
$remoteProcessCount = 1
$privacyProcessCount = [Math]::Min(24, [Math]::Max(4, $processorCount * 2))
Write-Host "Remote bridge privacy race: processors=$processorCount, remote=$remoteProcessCount, privacy=$privacyProcessCount"
$remoteProcesses = @(
  1..$remoteProcessCount | ForEach-Object {
    Start-CapturedProcess $python.Source $remoteArguments @{
      GRAPHCODE_REMOTE_BRIDGE_TEST_TIMEOUT_MULTIPLIER = "3"
    }
  }
)
$privacyProcesses = @(
  1..$privacyProcessCount | ForEach-Object {
    Start-CapturedProcess "pwsh.exe" $privacyArguments
  }
)

try {
  foreach ($entry in $remoteProcesses + $privacyProcesses) {
    $entry.Process.WaitForExit()
  }

  $remoteFailures = $remoteProcesses | Where-Object { $_.Process.ExitCode -ne 0 }
  if ($remoteFailures) {
    throw "Remote bridge test process failed during privacy race: $(
      @($remoteFailures | ForEach-Object {
        "pid=$($_.Process.Id), exit=$($_.Process.ExitCode), stdout=$($_.Stdout.Result), stderr=$($_.Stderr.Result)"
      }) -join "; "
    )"
  }
  $privacyFailures = $privacyProcesses | Where-Object { $_.Process.ExitCode -ne 0 }
  if ($privacyFailures) {
    throw "Privacy validation failed while remote tests ran concurrently: $(
      @($privacyFailures | ForEach-Object {
        "pid=$($_.Process.Id), exit=$($_.Process.ExitCode), stdout=$($_.Stdout.Result), stderr=$($_.Stderr.Result)"
      }) -join "; "
    )"
  }
} finally {
  foreach ($entry in $remoteProcesses + $privacyProcesses) {
    if (-not $entry.Process.HasExited) {
      $entry.Process.Kill()
    }
    $entry.Process.Dispose()
  }
}

Write-Host "RemoteBridgePrivacyRace.Tests.ps1: PASS"
exit 0
