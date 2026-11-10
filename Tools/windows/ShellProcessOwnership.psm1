Set-StrictMode -Version Latest
$script:CompiledOwnershipAssemblyPath = $null
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
# ShellProcessOwnership.Tests.ps1 also exercises controlled native suspended
# launches and job/root/reader teardown; it is not a product walkthrough.

function Initialize-ShellProcessOwnership {
  $assemblyPath = $env:GRAPHCODE_VALIDATION_ASSEMBLY
  if (-not $assemblyPath) {
    if (-not $script:CompiledOwnershipAssemblyPath) {
      $script:CompiledOwnershipAssemblyPath = & (Join-Path $PSScriptRoot "Build-CompiledValidationRunner.ps1")
    }
    $assemblyPath = $script:CompiledOwnershipAssemblyPath
  }
  foreach ($requiredType in @("ShellOwnedLaunch", "GraphCode.Validation.Ownership.StandaloneProcessJob")) {
    & (Join-Path $PSScriptRoot "Import-CompiledValidationAssembly.ps1") `
      -AssemblyPath $assemblyPath -RequiredType $requiredType | Out-Null
  }
}

function Invoke-ShellJob([string] $Operation, [IntPtr] $Job = [IntPtr]::Zero,
    [IntPtr] $Handle = [IntPtr]::Zero, [ValidateRange(0, 5000)][int] $TimeoutMilliseconds = 5000) {
  switch ($Operation) {
    "Create" { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Create() }
    "Assign" { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Assign($Job, $Handle) }
    "Contains" { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Contains($Job, $Handle) }
    "Terminate" { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Terminate($Job) }
    "Wait" { [GraphCode.Validation.Ownership.StandaloneProcessJob]::WaitForEmpty($Job, $TimeoutMilliseconds) }
    "Active" { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($Job) }
    "Close" { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Close($Job) }
    default { throw "Unknown owned-job operation: $Operation" }
  }
}

function New-ShellSuspendedLaunch([Diagnostics.ProcessStartInfo] $StartInfo,
    [IO.TextWriter] $StandardOutputWriter, [IO.TextWriter] $StandardErrorWriter) {
  [ShellOwnedLaunch]::Suspended($StartInfo, $StandardOutputWriter, $StandardErrorWriter)
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

function Write-ShellOwnershipFirstFailure([Exception] $Exception,
    [Management.Automation.ErrorRecord] $FailureRecord = $null,
    [Management.Automation.ErrorRecord] $SecondaryCleanupFailureRecord = $null) {
  if (-not [Environment]::GetEnvironmentVariables().Contains("GRAPHCODE_VALIDATION_ROOT")) {
    throw "First-failure diagnostic root is unavailable"
  }
  $configured = [Environment]::GetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT")
  if (-not $configured -or -not [IO.Path]::IsPathFullyQualified($configured)) {
    throw "First-failure diagnostic root is not an absolute directory"
  }
  $root = [IO.Path]::GetFullPath($configured)
  $directory = Get-Item -LiteralPath $root -Force -ErrorAction Stop
  if (-not $directory.PSIsContainer) { throw "First-failure diagnostic root is not a directory" }
  while ($directory) {
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "First-failure diagnostic root has a reparse ancestor"
    }
    $directory = $directory.Parent
  }
  $chain = [Collections.Generic.List[object]]::new()
  $pending=[Collections.Generic.Queue[object]]::new()
  $pending.Enqueue(@{exception=$Exception;path='primary'})
  if($SecondaryCleanupFailureRecord){
    $pending.Enqueue(@{exception=$SecondaryCleanupFailureRecord.Exception;path='secondaryCleanup'})
  }
  $innerOmitted=$false
  while($pending.Count -gt 0 -and $chain.Count -lt 16) {
    $entry=$pending.Dequeue()
    $current=$entry.exception
    $operands=[ordered]@{}
    foreach($key in @("NativeErrorCode", "NativeResult", "FailedOwnershipPredicate", "CallSite")){
      if($current.Data.Contains($key)){
        $value=$current.Data[$key]
        if($null -eq $value -or $value -is [string] -or $value -is [bool] -or
            $value -is [int] -or $value -is [long] -or $value -is [uint32]){
          $operands[$key]=$value
        }
      }
    }
    $chain.Add([ordered]@{
      path=$entry.path;type = $current.GetType().FullName; message = $current.Message
      stackTrace = $current.StackTrace
      exceptionHResult = $current.HResult
      availableFailureOperands=$operands
      nativeErrorAvailable = ($current -is [ComponentModel.Win32Exception])
      nativeErrorCode = $(if ($current -is [ComponentModel.Win32Exception]) { $current.NativeErrorCode } else { $null })
    })
    if($current -is [AggregateException]){
      for($index=0;$index -lt $current.InnerExceptions.Count;$index++){
        if($pending.Count+$chain.Count -ge 16){$innerOmitted=$true;break}
        $pending.Enqueue(@{exception=$current.InnerExceptions[$index];path="$($entry.path).$index"})
      }
    }elseif($current.InnerException){
      if($pending.Count+$chain.Count -lt 16){
        $pending.Enqueue(@{exception=$current.InnerException;path="$($entry.path).inner"})
      }else{$innerOmitted=$true}
    }
  }
  $available=$chain[0].availableFailureOperands
  $payload=[ordered]@{
    exceptionType=$Exception.GetType().FullName;exceptionMessage=$Exception.Message
    errorRecordAvailable=($null -ne $FailureRecord)
    errorRecordType=$(if($FailureRecord){$FailureRecord.GetType().FullName}else{$null})
    fullyQualifiedErrorId=$(if($FailureRecord){$FailureRecord.FullyQualifiedErrorId}else{$null})
    scriptStackTrace=$(if($FailureRecord){$FailureRecord.ScriptStackTrace}else{$null})
    positionMessage=$(if($FailureRecord -and $FailureRecord.InvocationInfo){$FailureRecord.InvocationInfo.PositionMessage}else{$null})
    primaryRecordExceptionType=$(if($FailureRecord){$FailureRecord.Exception.GetType().FullName}else{$null})
    primaryRecordExceptionMessage=$(if($FailureRecord){$FailureRecord.Exception.Message}else{$null})
    secondaryCleanupAvailable=($null -ne $SecondaryCleanupFailureRecord)
    secondaryCleanup=$(if($SecondaryCleanupFailureRecord){[ordered]@{
      label='ACTUAL_SECONDARY_CLEANUP_ERROR_NOT_PRIMARY'
      errorRecordType=$SecondaryCleanupFailureRecord.GetType().FullName
      exceptionType=$SecondaryCleanupFailureRecord.Exception.GetType().FullName
      exceptionMessage=$SecondaryCleanupFailureRecord.Exception.Message
      scriptStackTrace=$SecondaryCleanupFailureRecord.ScriptStackTrace
      fullyQualifiedErrorId=$SecondaryCleanupFailureRecord.FullyQualifiedErrorId
      positionMessage=$(if($SecondaryCleanupFailureRecord.InvocationInfo){$SecondaryCleanupFailureRecord.InvocationInfo.PositionMessage}else{$null})
    }}else{$null})
    exceptionChain=$chain.ToArray();innerChainTruncated=($innerOmitted -or $pending.Count -gt 0)
    availableFailureOperands=$available
    ownershipPredicateAvailable=$available.Contains("FailedOwnershipPredicate")
    nativeResultAvailable=$available.Contains("NativeResult")
    diagnosis="AVAILABLE_ORIGINAL_ERROR_ONLY_NO_NEW_NATIVE_PROBE_OR_IDENTITY_INFERENCE"
  }
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($payload|ConvertTo-Json -Depth 8))
  if($bytes.Length -gt 65536){throw "First-failure projection exceeds 65536 bytes; original ErrorRecord remains in memory"}
  $stream=[IO.File]::Open((Join-Path $root "ownership-first-failure.json"),
    [IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

function Set-ShellOwnershipUnproven([Exception] $Exception, [string[]] $RetainedRoots = @(),
    [Management.Automation.ErrorRecord] $FailureRecord = $null,
    [Management.Automation.ErrorRecord] $SecondaryCleanupFailureRecord = $null) {
  $Exception.Data["GraphCodeValidationRootRetentionRequired"] = $true
  $roots = @($RetainedRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
  $Exception.Data["GraphCodeValidationRetainedRoots"] = $roots
  if($FailureRecord -and -not $Exception.Data.Contains("GraphCodeValidationOriginalFailureRecord")){
    $Exception.Data["GraphCodeValidationOriginalFailureRecord"]=$FailureRecord
  }
  if($SecondaryCleanupFailureRecord -and -not $Exception.Data.Contains("GraphCodeValidationOriginalCleanupFailureRecord")){
    $Exception.Data["GraphCodeValidationOriginalCleanupFailureRecord"]=$SecondaryCleanupFailureRecord
  }
  try{Write-ShellOwnershipFirstFailure $Exception $FailureRecord $SecondaryCleanupFailureRecord}
  catch{$Exception.Data["GraphCodeValidationFirstFailureDiagnosticFailure"]=$_}
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

function Start-ShellOwnedProcess($Scope, [Diagnostics.ProcessStartInfo] $StartInfo,
    [IO.TextWriter] $StandardOutputWriter, [IO.TextWriter] $StandardErrorWriter) {
  if ($Scope.Closed) { throw "Owned shell scope is closed" }
  try {
    $run = New-ShellSuspendedLaunch $StartInfo `
      -StandardOutputWriter $StandardOutputWriter -StandardErrorWriter $StandardErrorWriter
  } catch {
    if (Test-ShellOwnershipUnproven $_) {
      throw (Set-ShellOwnershipUnproven $_.Exception -FailureRecord $_)
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
        "Owned launch failed: $($primary.Exception.Message); OWNED_CLEANUP_UNPROVEN: $($_.Exception.Message)", $primary.Exception)) `
        -FailureRecord $primary -SecondaryCleanupFailureRecord $_)
    }
    if (Test-ShellOwnershipUnproven $primary) {
      throw (Set-ShellOwnershipUnproven $primary.Exception -FailureRecord $primary)
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
    throw (Set-ShellOwnershipUnproven $_.Exception -FailureRecord $_)
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
    throw (Set-ShellOwnershipUnproven $_.Exception -FailureRecord $_)
  }
}

function Complete-ShellLaunch($Run, [Nullable[int]] $TimeoutMilliseconds) {
  if ($Run.Finalized) { return }
  $clock = [Diagnostics.Stopwatch]::StartNew()
  try {
    $Run.RequireExited()
    if ($Run.LaunchJob -ne [IntPtr]::Zero -and -not $Run.LaunchJobClosed) {
      Invoke-ShellJob "Terminate" $Run.LaunchJob
      $remaining = if ($null -eq $TimeoutMilliseconds) { 5000 } else {
        [Math]::Max(0, [int]$TimeoutMilliseconds - [int]$clock.ElapsedMilliseconds)
      }
      Invoke-ShellJob "Wait" $Run.LaunchJob -TimeoutMilliseconds $remaining
      if ((Invoke-ShellJob "Active" $Run.LaunchJob) -ne 0) {
        throw "OWNED_CLEANUP_UNPROVEN: private launch job not empty"
      }
    }
    if ($null -eq $TimeoutMilliseconds) { $Run.Drain() }
    else { $Run.Drain([Math]::Max(0, [int]$TimeoutMilliseconds - [int]$clock.ElapsedMilliseconds)) }
    if ($Run.LaunchJob -ne [IntPtr]::Zero -and -not $Run.LaunchJobClosed) {
      Invoke-ShellJob "Close" $Run.LaunchJob
      $Run.LaunchJobClosed = $true
    }
    $Run.Finalized = $true
  } catch {
    throw (Set-ShellOwnershipUnproven $_.Exception -FailureRecord $_)
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

function Close-ShellProcessScope($Scope, [ValidateRange(0, 5000)][int] $TimeoutMilliseconds = 5000) {
  if ($Scope.Closed) { return }
  $exitClock = [Diagnostics.Stopwatch]::StartNew()
  try {
    Invoke-ShellJob "Terminate" $Scope.Job
    Invoke-ShellJob "Wait" $Scope.Job -TimeoutMilliseconds ([Math]::Max(0, $TimeoutMilliseconds - [int]$exitClock.ElapsedMilliseconds))
    if ((Invoke-ShellJob "Active" $Scope.Job) -ne 0) { throw "OWNED_CLEANUP_UNPROVEN: job not empty" }
    # Job accounting can reach zero before the original process objects signal.
    # Prove every held root within the same termination deadline before closing any.
    foreach ($run in $Scope.Runs) {
      if ($run.Finalized) { continue }
      if (-not $run.ScopeAssigned) { $run.Stop() }
      $run.RequireExited([Math]::Max(0, $TimeoutMilliseconds - [int]$exitClock.ElapsedMilliseconds))
    }
    foreach ($run in $Scope.Runs) {
      Complete-ShellLaunch $run -TimeoutMilliseconds ([Math]::Max(0, $TimeoutMilliseconds - [int]$exitClock.ElapsedMilliseconds))
      $run.Close()
    }
    foreach ($member in $Scope.Members) { $member.Dispose() }
    Invoke-ShellJob "Close" $Scope.Job
    $Scope.Closed = $true
    Write-Host "SHELL_OWNED_JOB_CLEANUP=verified active=0 launches=$($Scope.Runs.Count)"
  } catch {
    throw (Set-ShellOwnershipUnproven $_.Exception -FailureRecord $_)
  }
}

Export-ModuleMember -Function New-ShellProcessScope, Start-ShellOwnedProcess,
  Get-ShellOwnedMember, Stop-ShellOwnedProcess, Read-ShellOwnedOutput, Close-ShellProcessScope,
  Complete-ShellOwnedProcess, Receive-ShellOwnedOutput,
  Test-ShellOwnershipUnproven, Set-ShellOwnershipUnproven
