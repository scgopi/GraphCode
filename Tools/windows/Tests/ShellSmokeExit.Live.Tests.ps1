[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $AppPath,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $WinghosttyRoot,
  [Parameter(Mandatory)][string] $ZmxRoot,
  [Parameter(Mandatory)][string] $Zig0152,
  [Parameter(Mandatory)][string] $Zig0160,
  [ValidateSet('legacy-busy', 'owned-busy', 'legacy-success', 'owned-success', 'owned-unactivated', 'owned-no-focus')]
  [string] $Worker
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Import-Module (Join-Path $repoRoot 'Tools\windows\ShellProcessOwnership.psm1')

function New-FixtureStart([string] $File, [string[]] $Arguments) {
  $start = [Diagnostics.ProcessStartInfo]::new($File)
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  $start
}

$null = New-Item -ItemType Directory -Force -Path $ArtifactRoot
if ($Worker) {
  $env:GRAPHCODE_SUPPORT_DIR = Join-Path $ArtifactRoot 'support'
  $env:LOCALAPPDATA = Join-Path $ArtifactRoot 'local'
  $env:GRAPHCODE_WORKSPACE_LAYOUT = Join-Path $ArtifactRoot 'workspace.json'
  $env:TEMP = Join-Path $ArtifactRoot 'temp'
  $env:TMP = $env:TEMP
  $null = New-Item -ItemType Directory -Force -Path $env:GRAPHCODE_SUPPORT_DIR,$env:LOCALAPPDATA,$env:TEMP
  [IO.File]::WriteAllText((Join-Path $env:GRAPHCODE_SUPPORT_DIR 'onboarding-seen'), '')
  Remove-Item Env:\GRAPHCODE_SHELL_WORKSPACE_ACTIONS -ErrorAction SilentlyContinue
  if ($Worker -eq 'owned-no-focus') {
    $failure = $null
    try {
      & (Join-Path $repoRoot 'Tools\windows\windows-shell.ps1') `
        -WinghosttyRoot $WinghosttyRoot -ZmxRoot $ZmxRoot -Zig0152 $Zig0152 -Zig0160 $Zig0160 `
        -SkipBuild -UseStubDaemon -StubResponseDelayMilliseconds 150 -SkipTrayLive -Stress `
        -WorkspaceActions 'create,split,select,close,restart'
    } catch { $failure = $_ }
    if ($null -ne $failure -and (Test-ShellOwnershipUnproven $failure)) { throw $failure }
    if ($null -eq $failure -or
        $failure.Exception.Message -notmatch '(?s)exited with code 1: .*Smoke contract failed: scripted=true .*focus=false') {
      throw "Omitted-focus scenario did not refuse for its actual missing focus effect: $failure"
    }
    [IO.File]::WriteAllText((Join-Path $ArtifactRoot 'stderr.txt'), ($failure | Out-String))
    [ordered]@{ id = $Worker; exitCode = 1; stderrLength = $failure.Exception.Message.Length } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $ArtifactRoot 'result.json')
    exit 0
  }
  $pipe = 'graphcode-smoke-exit-' + [guid]::NewGuid().ToString('N')
  $result = Join-Path $ArtifactRoot 'daemon.json'
  $errorPath = Join-Path $ArtifactRoot 'stderr.txt'
  $scope = New-ShellProcessScope
  try {
    $stubStart = New-FixtureStart (Join-Path $PSHOME 'pwsh.exe') @(
      '-NoProfile', '-File', (Join-Path $repoRoot 'Tools\windows\Stub-Daemon.ps1'),
      '-PipeName', $pipe, '-ResultPath', $result, '-NonReading'
    )
    $null = Start-ShellOwnedProcess $scope $stubStart
    $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$pipe"
    $busy = $Worker.EndsWith('-busy', [StringComparison]::Ordinal) -or $Worker -eq 'owned-unactivated'
    if ($busy) {
      $env:GRAPHCODE_SHELL_REQUIRE_DAEMON = '1'
      $env:GRAPHCODE_SHELL_EXPECT_TRANSPORT_ERROR = '1'
    } else {
      Remove-Item Env:\GRAPHCODE_SHELL_REQUIRE_DAEMON -ErrorAction SilentlyContinue
      Remove-Item Env:\GRAPHCODE_SHELL_EXPECT_TRANSPORT_ERROR -ErrorAction SilentlyContinue
    }
    if ($Worker -eq 'owned-unactivated') { $env:GRAPHCODE_SHELL_WORKSPACE_ACTIONS = '1' }
    if ($Worker.StartsWith('legacy-', [StringComparison]::Ordinal)) {
      # The worker is already suspended-assigned to the caller's held job.
      $app = Start-Process -FilePath $AppPath -ArgumentList @('--smoke') -PassThru `
        -RedirectStandardError $errorPath
      [void] $app.Handle
      if (-not $app.WaitForExit(8000)) { throw "$Worker exceeded the original smoke deadline" }
      $app.WaitForExit()
      $app.Refresh()
      $stderr = [IO.File]::ReadAllText($errorPath)
    } else {
      $app = Start-ShellOwnedProcess $scope (New-FixtureStart $AppPath @('--smoke'))
      if (-not $app.WaitForExit(8000)) { throw "$Worker exceeded the original smoke deadline" }
      Complete-ShellOwnedProcess $scope $app
      $stderr = Read-ShellOwnedOutput $scope $app -StandardError
      [IO.File]::WriteAllText($errorPath, $stderr)
    }
    $exitCode = $app.ExitCode
    $daemon = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
    if (-not $daemon.busyObserved) { throw "$Worker did not exercise a nonreading daemon" }
    if ($busy) {
      if ($exitCode -eq 0 -or $stderr -notmatch '(?i)Smoke daemon status: .*daemon') {
        throw "$Worker failed smoke-exit contract: exit=$exitCode stderrLength=$($stderr.Length)"
      }
      if ($Worker -eq 'owned-unactivated' -and $stderr -notmatch 'Smoke contract failed: scripted=false') {
        throw 'Unactivated workspace scenario did not prove its requested actions remained unexecuted'
      }
    } elseif ($exitCode -ne 0) {
      throw "$Worker changed successful requested-exit behavior: exit=$exitCode"
    }
    [ordered]@{ id = $Worker; exitCode = $exitCode; stderrLength = $stderr.Length } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $ArtifactRoot 'result.json')
  } finally {
    Close-ShellProcessScope $scope
  }
  exit 0
}

$executed = 0
foreach ($case in @('legacy-busy', 'owned-busy', 'legacy-success', 'owned-success', 'owned-unactivated', 'owned-no-focus')) {
  $caseRoot = Join-Path $ArtifactRoot $case
  $null = New-Item -ItemType Directory -Force -Path $caseRoot
  $scope = New-ShellProcessScope
  try {
    $start = New-FixtureStart (Join-Path $PSHOME 'pwsh.exe') @(
      '-NoProfile', '-File', $PSCommandPath, '-AppPath', $AppPath,
      '-ArtifactRoot', $caseRoot, '-Worker', $case, '-WinghosttyRoot', $WinghosttyRoot,
      '-ZmxRoot', $ZmxRoot, '-Zig0152', $Zig0152, '-Zig0160', $Zig0160
    )
    $process = Start-ShellOwnedProcess $scope $start
    $workerDeadline = if ($case -eq 'owned-no-focus') { 45000 } else { 15000 }
    if (-not $process.WaitForExit($workerDeadline)) { throw "$case worker exceeded its owned deadline" }
    Complete-ShellOwnedProcess $scope $process
    [IO.File]::WriteAllText((Join-Path $caseRoot 'worker-stderr.txt'),
      (Read-ShellOwnedOutput $scope $process -StandardError))
    if ($process.ExitCode -ne 0) { throw "$case worker failed: exit=$($process.ExitCode); evidence=$caseRoot" }
    $row = Get-Content -LiteralPath (Join-Path $caseRoot 'result.json') -Raw | ConvertFrom-Json
    if ($row.id -cne $case) { throw "$case worker returned mismatched evidence" }
    $executed++
    Write-Host "SHELL_SMOKE_EXIT_CASE=$case EXIT=$($row.exitCode)"
  } finally {
    Close-ShellProcessScope $scope
  }
}
if ($executed -ne 6) { throw "Smoke exit fixture did not execute all six controls: $executed" }
Write-Host "SHELL_SMOKE_EXIT_CASES=$executed"
