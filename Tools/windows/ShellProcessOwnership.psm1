Set-StrictMode -Version Latest
# Targets start suspended, join a private non-breakaway job, then resume. CIM
# observations are never admitted into this scope; disposed managed objects do
# not release the native launch handles retained until verified job teardown.
# Complete-ShellOwnedProcess must follow root exit and survivor sampling. It
# empties only that launch's private job before requiring both pipe EOFs;
# output reads refuse unfinished launches, and scope cleanup handles failures.
# Receive-ShellOwnedOutput forwards buffered characters without implying EOF.
# It has independent per-stream cursors; Read still returns the full capture.
# One incremental caller may take 2..65536 UTF-16 units per stream per call.
# Empty batches are not EOF; batch bounds do not cap full-capture storage.
# False redirection flags tee that stream live while retaining capture; true
# flags stay quiet. Child stdio still uses pipes/NUL, not console equivalence.
# Failed diagnostic transports remain attached to the original tagged exception;
# a failed sentinel does not prevent the independent receipt attempt.
# ShellProcessOwnership.Tests.ps1 covers mocks, receipt files and compilation
# only. Actual suspended launch/job containment still requires native validation.

function Initialize-ShellProcessOwnership {
  if ("ShellOwnedLaunch" -as [type]) { return }
  $path = Join-Path $PSScriptRoot "UiCaptureDriver.psm1"
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors.Count) { throw "Owned shell job source does not parse" }
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value.Contains("public static class CapProcessJob")
  }, $true))
  if ($definitions.Count -ne 1) { throw "Owned shell requires exactly one existing CapProcessJob definition" }
  if (-not ("CapProcessJob" -as [type])) { Add-Type -TypeDefinition $definitions[0].Value }
  $source = "using System; using System.ComponentModel; using System.Diagnostics; using System.Runtime.InteropServices;`n" +
    "using System.IO; using System.Text; using System.Threading.Tasks; using System.Linq;`n" +
    (Get-Content -LiteralPath (Join-Path $PSScriptRoot "ShellOwnedProcess.cs") -Raw)
  Add-Type -TypeDefinition $source
}

function Invoke-ShellJob([string] $Operation, [IntPtr] $Job = [IntPtr]::Zero,
    [IntPtr] $Handle = [IntPtr]::Zero) {
  switch ($Operation) {
    "Create" { [CapProcessJob]::Create() }
    "Assign" { [CapProcessJob]::Assign($Job, $Handle) }
    "Contains" { [CapProcessJob]::Contains($Job, $Handle) }
    "Terminate" { [CapProcessJob]::Terminate($Job) }
    "Wait" { [CapProcessJob]::WaitForEmpty($Job, 5000) }
    "Active" { [CapProcessJob]::Active($Job) }
    "Close" { [CapProcessJob]::Close($Job) }
    default { throw "Unknown owned-job operation: $Operation" }
  }
}

function New-ShellSuspendedLaunch([Diagnostics.ProcessStartInfo] $StartInfo) {
  [ShellOwnedLaunch]::Suspended($StartInfo)
}

function Test-ShellOwnershipUnproven($Failure) {
  $exception = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
  while ($exception) {
    if ($exception.Data["GraphCodeValidationRootRetentionRequired"] -is [bool] -and
        $exception.Data["GraphCodeValidationRootRetentionRequired"]) { return $true }
    $exception = $exception.InnerException
  }
  return $false
}

function Write-ShellOwnershipDiagnostic([Exception] $Exception, [string] $Message) {
  try {
    Write-Host $Message -ErrorAction Stop
  } catch {
    $failure = $_.Exception
    $previous = @($Exception.Data["GraphCodeValidationRetentionDiagnosticFailures"] |
      Where-Object { $null -ne $_ })
    $Exception.Data["GraphCodeValidationRetentionDiagnosticFailures"] = $previous + $failure
  }
}

function Set-ShellOwnershipUnproven([Exception] $Exception, [string[]] $RetainedRoots = @()) {
  $Exception.Data["GraphCodeValidationRootRetentionRequired"] = $true
  $roots = @($RetainedRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
  $Exception.Data["GraphCodeValidationRetainedRoots"] = $roots
  Write-ShellOwnershipDiagnostic $Exception "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven"
  if ([Environment]::GetEnvironmentVariables().Contains("GRAPHCODE_VALIDATION_ROOT")) {
    $stream = $null
    try {
      $configured = [Environment]::GetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT")
      if (-not $configured -or -not [IO.Path]::IsPathFullyQualified($configured)) {
        throw "Validation retention root is not an absolute directory"
      }
      $root = [IO.Path]::GetFullPath($configured)
      $directory = Get-Item -LiteralPath $root -Force -ErrorAction Stop
      if (-not $directory.PSIsContainer) { throw "Validation retention root is not a directory" }
      while ($directory) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
          throw "Validation retention root has a reparse ancestor"
        }
        $directory = $directory.Parent
      }
      $payload = [ordered]@{ schemaVersion = 1; validationRoot = $root; reason = "ownership_unproven" }
      $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($payload | ConvertTo-Json -Compress))
      if ($bytes.Length -gt 4096) { throw "Validation retention receipt exceeds 4096 bytes" }
      $stream = [IO.File]::Open((Join-Path $root "ownership-unproven.json"),
        [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } catch {
      $Exception.Data["GraphCodeValidationRetentionReceiptFailure"] = $_.Exception.Message
      Write-ShellOwnershipDiagnostic $Exception "SHELL_RETENTION_RECEIPT_UNPROVEN=$($_.Exception.Message)"
    } finally {
      if ($stream) { $stream.Dispose() }
    }
  }
  return $Exception
}

function New-ShellProcessScope {
  Initialize-ShellProcessOwnership
  [pscustomobject]@{
    Job = Invoke-ShellJob "Create"
    Runs = [Collections.Generic.List[object]]::new()
    Members = [Collections.Generic.List[Diagnostics.Process]]::new()
    Closed = $false
  }
}

function Start-ShellOwnedProcess($Scope, [Diagnostics.ProcessStartInfo] $StartInfo) {
  if ($Scope.Closed) { throw "Owned shell scope is closed" }
  try { $run = New-ShellSuspendedLaunch $StartInfo } catch {
    if (Test-ShellOwnershipUnproven $_) {
      throw (Set-ShellOwnershipUnproven $_.Exception)
    }
    throw
  }
  $run | Add-Member -NotePropertyMembers @{
    LaunchJob = [IntPtr]::Zero; ScopeAssigned = $false; LaunchAssigned = $false
    Finalized = $false; LaunchJobClosed = $false
  } -Force
  $Scope.Runs.Add($run)
  try {
    Invoke-ShellJob "Assign" $Scope.Job $run.Handle
    $run.ScopeAssigned = $true
    $run.LaunchJob = Invoke-ShellJob "Create"
    Invoke-ShellJob "Assign" $run.LaunchJob $run.Handle
    $run.LaunchAssigned = $true
    $run.Resume()
    return $run.Process
  } catch {
    # This handle came from CreateProcess; no target code ran before assignment.
    $primary = $_
    try { $run.Stop() } catch {
      throw (Set-ShellOwnershipUnproven ([InvalidOperationException]::new(
        "Owned launch failed: $($primary.Exception.Message); OWNED_CLEANUP_UNPROVEN: $($_.Exception.Message)", $primary.Exception)))
    }
    if (Test-ShellOwnershipUnproven $primary) {
      throw (Set-ShellOwnershipUnproven $primary.Exception)
    }
    throw $primary
  }
}

function Get-ShellOwnedMember($Scope, [int] $ProcessId) {
  if ($Scope.Closed) { throw "UNATTESTED_PROCESS: owned shell scope is closed" }
  $process = $null
  try {
    $process = [Diagnostics.Process]::GetProcessById($ProcessId)
    if ($Scope.Closed -or -not (Invoke-ShellJob "Contains" $Scope.Job $process.Handle)) {
      throw "UNATTESTED_PROCESS: pid=$ProcessId is not a retained job member"
    }
    $Scope.Members.Add($process)
    return $process
  } catch {
    if ($process) { $process.Dispose() }
    throw (Set-ShellOwnershipUnproven $_.Exception)
  }
}

function Stop-ShellOwnedProcess($Scope, [Diagnostics.Process] $Process) {
  $runs = @($Scope.Runs | Where-Object { [object]::ReferenceEquals($_.Process, $Process) })
  if ($Scope.Closed -or $runs.Count -ne 1) {
    throw (Set-ShellOwnershipUnproven ([InvalidOperationException]::new(
      "UNATTESTED_PROCESS: termination requires the original launch record")))
  }
  if (-not (Invoke-ShellJob "Contains" $Scope.Job $runs[0].Handle)) {
    throw (Set-ShellOwnershipUnproven ([InvalidOperationException]::new(
      "UNATTESTED_PROCESS: retained launch is not in its owned job")))
  }
  $runs[0].Stop()
}

function Read-ShellOwnedOutput($Scope, [Diagnostics.Process] $Process, [switch] $StandardError) {
  $runs = @($Scope.Runs | Where-Object { [object]::ReferenceEquals($_.Process, $Process) })
  if ($runs.Count -ne 1) { throw "Owned output requires the original launch record" }
  if (-not $runs[0].Finalized) { throw "Owned output requires explicit launch finalization after survivor sampling" }
  $task = if ($StandardError) { $runs[0].Error } else { $runs[0].Output }
  if (-not $task.Wait(5000)) { throw "Owned output EOF is unproved" }
  $task.GetAwaiter().GetResult()
}

function Receive-ShellOwnedOutput($Scope, [Diagnostics.Process] $Process,
    [ValidateRange(2, 65536)][int] $MaximumCharacters = 65536) {
  $runs = @($Scope.Runs | Where-Object { [object]::ReferenceEquals($_.Process, $Process) })
  if ($Scope.Closed -or $runs.Count -ne 1) {
    throw (Set-ShellOwnershipUnproven ([InvalidOperationException]::new(
      "Owned incremental output requires an open scope and the original launch record")))
  }
  try {
    [pscustomobject]@{
      Output = $runs[0].TakeOutput($MaximumCharacters)
      Error = $runs[0].TakeError($MaximumCharacters)
    }
  } catch {
    throw (Set-ShellOwnershipUnproven $_.Exception)
  }
}

function Complete-ShellLaunch($Run) {
  if ($Run.Finalized) { return }
  try {
    $Run.RequireExited()
    if ($Run.LaunchJob -ne [IntPtr]::Zero -and -not $Run.LaunchJobClosed) {
      Invoke-ShellJob "Terminate" $Run.LaunchJob
      Invoke-ShellJob "Wait" $Run.LaunchJob
      if ((Invoke-ShellJob "Active" $Run.LaunchJob) -ne 0) {
        throw "OWNED_CLEANUP_UNPROVEN: private launch job not empty"
      }
    }
    $Run.Drain()
    if ($Run.LaunchJob -ne [IntPtr]::Zero -and -not $Run.LaunchJobClosed) {
      Invoke-ShellJob "Close" $Run.LaunchJob
      $Run.LaunchJobClosed = $true
    }
    $Run.Finalized = $true
  } catch {
    throw (Set-ShellOwnershipUnproven $_.Exception)
  }
}

function Complete-ShellOwnedProcess($Scope, [Diagnostics.Process] $Process) {
  $runs = @($Scope.Runs | Where-Object { [object]::ReferenceEquals($_.Process, $Process) })
  if ($runs.Count -ne 1) {
    throw (Set-ShellOwnershipUnproven ([InvalidOperationException]::new(
      "UNATTESTED_PROCESS: finalization requires the original launch record")))
  }
  if ($runs[0].Finalized) { return }
  if ($Scope.Closed -or -not $runs[0].LaunchAssigned) {
    throw (Set-ShellOwnershipUnproven ([InvalidOperationException]::new(
      "Owned launch finalization requires an open scope and its assigned private job")))
  }
  Complete-ShellLaunch $runs[0]
}

function Close-ShellProcessScope($Scope) {
  if ($Scope.Closed) { return }
  try {
    Invoke-ShellJob "Terminate" $Scope.Job
    Invoke-ShellJob "Wait" $Scope.Job
    if ((Invoke-ShellJob "Active" $Scope.Job) -ne 0) { throw "OWNED_CLEANUP_UNPROVEN: job not empty" }
    foreach ($run in $Scope.Runs) {
      if (-not $run.ScopeAssigned) { $run.Stop() }
      Complete-ShellLaunch $run
      $run.Close()
    }
    foreach ($member in $Scope.Members) { $member.Dispose() }
    Invoke-ShellJob "Close" $Scope.Job
    $Scope.Closed = $true
    Write-Host "SHELL_OWNED_JOB_CLEANUP=verified active=0 launches=$($Scope.Runs.Count)"
  } catch {
    throw (Set-ShellOwnershipUnproven $_.Exception)
  }
}

Export-ModuleMember -Function New-ShellProcessScope, Start-ShellOwnedProcess,
  Get-ShellOwnedMember, Stop-ShellOwnedProcess, Read-ShellOwnedOutput, Close-ShellProcessScope,
  Complete-ShellOwnedProcess, Receive-ShellOwnedOutput,
  Test-ShellOwnershipUnproven, Set-ShellOwnershipUnproven
