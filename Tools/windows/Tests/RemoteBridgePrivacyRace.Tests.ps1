$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) {
  throw "Python 3 was not found for the remote bridge race regression"
}

function Start-CapturedProcess([string] $fileName, [string[]] $arguments) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $fileName
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $arguments) {
    [void] $startInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void] $process.Start()
  return $process
}

$testPath = Join-Path $repoRoot "investigation\spikes\remote-bridge"
$remoteArguments = @(
  "-B",
  "-m",
  "unittest",
  "discover",
  "-s",
  $testPath,
  "-p",
  "test_*.py"
)
$privacyArguments = @(
  "-NoProfile",
  "-File",
  (Join-Path $repoRoot "Tools\windows\validate.ps1"),
  "-Task",
  "privacy"
)

$remoteProcesses = @(
  (Start-CapturedProcess $python.Source $remoteArguments),
  (Start-CapturedProcess $python.Source $remoteArguments),
  (Start-CapturedProcess $python.Source $remoteArguments)
)
$privacyProcesses = @(
  1..24 | ForEach-Object {
    Start-CapturedProcess "pwsh.exe" $privacyArguments
  }
)

try {
  foreach ($process in $remoteProcesses + $privacyProcesses) {
    $process.WaitForExit()
  }

  $remoteFailures = $remoteProcesses | Where-Object ExitCode -ne 0
  if ($remoteFailures) {
    throw "Remote bridge test process failed during privacy race."
  }
  $privacyFailures = $privacyProcesses | Where-Object ExitCode -ne 0
  if ($privacyFailures) {
    throw "Privacy validation failed while remote tests ran concurrently."
  }
} finally {
  foreach ($process in $remoteProcesses + $privacyProcesses) {
    if (-not $process.HasExited) {
      $process.Kill()
    }
    $process.Dispose()
  }
}

Write-Host "RemoteBridgePrivacyRace.Tests.ps1: PASS"
exit 0
