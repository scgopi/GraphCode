BeforeDiscovery {
  Import-Module (Join-Path $PSScriptRoot "..\ShellProcessOwnership.psm1") -Force
}

BeforeAll {
  $repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
  $hadValidationAssembly = [Environment]::GetEnvironmentVariables("Process").Contains("GRAPHCODE_VALIDATION_ASSEMBLY")
  $savedValidationAssembly = $env:GRAPHCODE_VALIDATION_ASSEMBLY
  if (-not $hadValidationAssembly) {
    $env:GRAPHCODE_VALIDATION_ASSEMBLY = & (Join-Path $PSScriptRoot "..\Build-CompiledValidationRunner.ps1")
  }
  $shellPath = Join-Path $repo "Tools\windows\windows-shell.ps1"
  $hadValidationRoot = [Environment]::GetEnvironmentVariables().Contains("GRAPHCODE_VALIDATION_ROOT")
  $savedValidationRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT")
  Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT -ErrorAction SilentlyContinue
  [Environment]::GetEnvironmentVariables().Contains("GRAPHCODE_VALIDATION_ROOT") | Should -BeFalse
}

AfterAll {
  if ($hadValidationAssembly) { $env:GRAPHCODE_VALIDATION_ASSEMBLY = $savedValidationAssembly }
  else { Remove-Item Env:\GRAPHCODE_VALIDATION_ASSEMBLY -ErrorAction SilentlyContinue }
  if ($hadValidationRoot) {
    [Environment]::SetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT", $savedValidationRoot, "Process")
  } else {
    Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT -ErrorAction SilentlyContinue
  }
}

Describe "Owned shell scope mock-only lifecycle" {
  InModuleScope ShellProcessOwnership {
    BeforeEach {
      $script:events = [Collections.Generic.List[string]]::new()
      $script:process = [Diagnostics.Process]::new()
      $script:run = [pscustomobject]@{ Process = $script:process; Handle = [IntPtr]123 }
      $script:run | Add-Member ScriptMethod Resume { $script:events.Add("resume") }
      $script:run | Add-Member ScriptMethod Stop { $script:events.Add("stop-held") }
      $script:run | Add-Member ScriptMethod Close { $script:events.Add("close-launch") }
      $script:run | Add-Member ScriptMethod RequireExited { $script:events.Add("root-exited") }
      $script:run | Add-Member ScriptMethod Drain { $script:events.Add("drain") }
      $script:run | Add-Member NoteProperty LaunchJob ([IntPtr]567)
      $script:run | Add-Member NoteProperty ScopeAssigned $true
      $script:run | Add-Member NoteProperty LaunchAssigned $true
      $script:run | Add-Member NoteProperty Finalized $false
      $script:run | Add-Member NoteProperty LaunchJobClosed $false
      $script:nextJob = 345
      Mock Initialize-ShellProcessOwnership {}
      Mock New-ShellSuspendedLaunch { $script:events.Add("suspended"); $script:run }
      Mock Invoke-ShellJob {
        param($Operation)
        $script:events.Add($Operation)
        switch ($Operation) {
          "Create" { $script:nextJob += 111; [IntPtr]$script:nextJob }
          "Contains" { $true }
          "Active" { 0 }
        }
      }
      Mock Write-Host {}
      $script:scope = New-ShellProcessScope
      $script:events.Clear()
    }
    AfterEach { $script:process.Dispose() }

    It "assigns the suspended launch before releasing any target code" {
      $actual = Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new())
      [object]::ReferenceEquals($actual, $script:process) | Should -BeTrue
      ($script:events -join ",") | Should -Be "suspended,Assign,Create,Assign,resume"
      $script:scope.Runs.Count | Should -Be 1
    }
    It "retains and stops only the suspended original when assignment fails" {
      Mock Invoke-ShellJob { throw "assignment refused" } -ParameterFilter { $Operation -eq "Assign" }
      { Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new()) } |
        Should -Throw "*assignment refused*"
      ($script:events -join ",") | Should -Be "suspended,stop-held"
      $script:scope.Runs.Count | Should -Be 1
    }
    It "does not start a target in a closed scope" {
      $script:scope.Closed = $true
      { Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new()) } |
        Should -Throw "*closed*"
      Should -Invoke New-ShellSuspendedLaunch -Times 0 -Exactly
    }
    It "retains the owned launch and stops it when thread release fails" {
      $script:run | Add-Member ScriptMethod Resume { throw "resume refused" } -Force
      { Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new()) } |
        Should -Throw "*resume refused*"
      ($script:events -join ",") | Should -Be "suspended,Assign,Create,Assign,stop-held"
      $script:scope.Runs.Count | Should -Be 1
    }
    It "propagates a changed-suspension retention tag after stopping the original launch" {
      $script:run | Add-Member ScriptMethod Resume {
        $error = [InvalidOperationException]::new("suspension changed")
        $error.Data["GraphCodeValidationRootRetentionRequired"] = $true
        throw $error
      } -Force
      $failure = $null
      try { Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new()) } catch { $failure = $_ }
      $failure | Should -Not -BeNullOrEmpty
      Test-ShellOwnershipUnproven $failure | Should -BeTrue
      $script:events | Should -Contain "stop-held"
    }
    It "propagates pre-return native cleanup uncertainty without inventing a launch record" {
      Mock New-ShellSuspendedLaunch {
        $error = [InvalidOperationException]::new("native cleanup unproved")
        $error.Data["GraphCodeValidationRootRetentionRequired"] = $true
        throw $error
      }
      $failure = $null
      try { Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new()) } catch { $failure = $_ }
      Test-ShellOwnershipUnproven $failure | Should -BeTrue
      $script:scope.Runs.Count | Should -Be 0
      $script:events | Should -Not -Contain "Assign"
    }
    It "retains the original assignment and cleanup records at the actual Start Stop catch" -Tag "FirstFailureDiagnostic" {
      $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
      New-Item -ItemType Directory -Path $root | Out-Null
      $env:GRAPHCODE_VALIDATION_ROOT = $root
      try {
        $script:assignFailure = [ComponentModel.Win32Exception]::new(5, "primary assignment")
        $script:assignFailure.Data["NativeResult"] = [uint32]11
        $script:stopFailure = [ComponentModel.Win32Exception]::new(6, "secondary stop")
        $script:stopFailure.Data["NativeResult"] = [uint32]22
        Mock Invoke-ShellJob { throw $script:assignFailure } -ParameterFilter { $Operation -eq "Assign" }
        $script:run | Add-Member ScriptMethod Stop { throw $script:stopFailure } -Force
        $failure = $null
        try { Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new()) } catch { $failure = $_ }
        $failure.Exception | Should -BeOfType ([InvalidOperationException])
        [object]::ReferenceEquals($failure.Exception.InnerException, $script:assignFailure) | Should -BeTrue
        $evidence = Get-Content (Join-Path $root "ownership-first-failure.json") -Raw | ConvertFrom-Json
        $first = @($evidence.exceptionChain | Where-Object { $_.path -like "primary*" -and $_.nativeErrorAvailable -and $_.nativeErrorCode -eq 5 })
        $second = @($evidence.exceptionChain | Where-Object { $_.path -like "secondaryCleanup*" -and $_.nativeErrorAvailable -and $_.nativeErrorCode -eq 6 })
        $first.Count | Should -Be 1
        $second.Count | Should -Be 1
        $first[0].availableFailureOperands.NativeResult | Should -Be 11
        $second[0].availableFailureOperands.NativeResult | Should -Be 22
        $evidence.scriptStackTrace | Should -Not -BeExactly $evidence.secondaryCleanup.scriptStackTrace
        $evidence.secondaryCleanupAvailable | Should -BeTrue
        $script:scope.Runs.Count | Should -Be 1
        Should -Invoke Invoke-ShellJob -Times 1 -Exactly -ParameterFilter { $Operation -eq "Assign" }
      } finally {
        Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT -ErrorAction SilentlyContinue
      }
    }
    It "refuses a newly reopened or stale PID object" {
      $script:scope.Runs.Add($script:run)
      $other = [Diagnostics.Process]::new()
      try {
        { Stop-ShellOwnedProcess $script:scope $other } | Should -Throw "*UNATTESTED_PROCESS*"
        $script:events.Count | Should -Be 0
      } finally { $other.Dispose() }
    }
    It "uses the retained native launch even after its managed Process is disposed" {
      $script:scope.Runs.Add($script:run)
      $script:process.Dispose()
      Stop-ShellOwnedProcess $script:scope $script:process
      ($script:events -join ",") | Should -Be "Contains,stop-held"
    }
    It "refuses a lost job-membership attestation without termination" {
      $script:scope.Runs.Add($script:run)
      Mock Invoke-ShellJob { $false } -ParameterFilter { $Operation -eq "Contains" }
      { Stop-ShellOwnedProcess $script:scope $script:process } | Should -Throw "*UNATTESTED_PROCESS*"
      $script:events | Should -Not -Contain "stop-held"
    }
    It "waits for an empty job before closing launch and job handles" {
      $script:scope.Runs.Add($script:run)
      Close-ShellProcessScope $script:scope
      ($script:events -join ",") | Should -Be "Terminate,Wait,Active,root-exited,root-exited,Terminate,Wait,Active,drain,Close,close-launch,Close"
      $script:scope.Closed | Should -BeTrue
      Should -Invoke Write-Host -Times 1 -Exactly
    }
    It "does not release handles or claim success when the job remains active" {
      $script:scope.Runs.Add($script:run)
      Mock Invoke-ShellJob { 1 } -ParameterFilter { $Operation -eq "Active" }
      { Close-ShellProcessScope $script:scope } | Should -Throw "*OWNED_CLEANUP_UNPROVEN*"
      $script:scope.Closed | Should -BeFalse
      $script:events | Should -Not -Contain "close-launch"
      Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like "SHELL_OWNED_JOB_CLEANUP=*" }
    }
    It "shares the original scope termination deadline across all held-root waits" {
      $script:budgets = [Collections.Generic.List[int]]::new()
      $script:run | Add-Member ScriptMethod RequireExited {
        param($milliseconds)
        if ($null -ne $milliseconds) {
          $script:budgets.Add($milliseconds)
          [Threading.Thread]::Sleep(60)
        }
      } -Force
      $other = [pscustomobject]@{
        Process = $script:process; ScopeAssigned = $true; Finalized = $false
        LaunchJob = [IntPtr]678; LaunchJobClosed = $false
      }
      $other | Add-Member ScriptMethod RequireExited {
        param($milliseconds)
        if ($null -ne $milliseconds) { $script:budgets.Add($milliseconds) }
      }
      $other | Add-Member ScriptMethod Drain {}
      $other | Add-Member ScriptMethod Close {}
      $script:scope.Runs.Add($script:run)
      $script:scope.Runs.Add($other)
      Close-ShellProcessScope $script:scope
      $script:budgets.Count | Should -Be 2
      $script:budgets[0] | Should -BeGreaterThan 0
      $script:budgets[0] | Should -BeLessOrEqual 5000
      $script:budgets[1] | Should -BeLessThan $script:budgets[0]
      $script:scope.Closed | Should -BeTrue
    }
    It "does not drain or release authority when the bounded held-root wait refuses" {
      $script:run | Add-Member ScriptMethod RequireExited {
        param($milliseconds)
        $script:events.Add("held-root-wait:$milliseconds")
        throw "controlled held root did not signal within its original deadline"
      } -Force
      $script:scope.Runs.Add($script:run)
      $failure = $null
      try { Close-ShellProcessScope $script:scope } catch { $failure = $_ }
      Test-ShellOwnershipUnproven $failure | Should -BeTrue
      $script:scope.Closed | Should -BeFalse
      $script:run.Finalized | Should -BeFalse
      $script:events | Should -Not -Contain "drain"
      $script:events | Should -Not -Contain "Close"
      $script:events | Should -Not -Contain "close-launch"
    }
    It "proves every original root before closing a previously signalled sibling" {
      $other = [pscustomobject]@{ Process = $script:process; ScopeAssigned = $true; Finalized = $false }
      $other | Add-Member ScriptMethod RequireExited { param($milliseconds) throw "later held root is unproved" }
      $script:scope.Runs.Add($script:run)
      $script:scope.Runs.Add($other)
      { Close-ShellProcessScope $script:scope } | Should -Throw "*later held root is unproved*"
      $script:scope.Closed | Should -BeFalse
      $script:run.Finalized | Should -BeFalse
      $script:events | Should -Not -Contain "drain"
      $script:events | Should -Not -Contain "Close"
      $script:events | Should -Not -Contain "close-launch"
    }
    It "does not claim cleanup when output drainage fails" {
      $script:run | Add-Member ScriptMethod Drain { throw "output EOF unproved" } -Force
      $script:scope.Runs.Add($script:run)
      { Close-ShellProcessScope $script:scope } | Should -Throw "*EOF unproved*"
      $script:scope.Closed | Should -BeFalse
      Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like "SHELL_OWNED_JOB_CLEANUP=*" }
    }
    It "does not report success when native job termination fails" {
      Mock Invoke-ShellJob { throw "termination refused" } -ParameterFilter { $Operation -eq "Terminate" }
      { Close-ShellProcessScope $script:scope } | Should -Throw "*termination refused*"
      $script:scope.Closed | Should -BeFalse
      Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like "SHELL_OWNED_JOB_CLEANUP=*" }
    }
    It "does not reopen a candidate after the scope has closed" {
      $script:scope.Closed = $true
      { Get-ShellOwnedMember $script:scope 99999999 } | Should -Throw "*scope is closed*"
      $script:events.Count | Should -Be 0
    }
    It "refuses an unfinalized output read without waiting for inherited pipe EOF" -Tag PipeFinalization {
      $script:task = [pscustomobject]@{}
      $script:task | Add-Member ScriptMethod Wait { $script:events.Add("EOF-wait"); throw "descendant pipe still open" }
      $script:run | Add-Member NoteProperty Output $script:task
      $script:scope.Runs.Add($script:run)
      { Read-ShellOwnedOutput $script:scope $script:process } | Should -Throw "*explicit launch finalization*"
      $script:events | Should -Not -Contain "EOF-wait"
    }
    It "finalizes only one private launch job before draining its inherited pipes" {
      $script:scope.Runs.Add($script:run)
      Complete-ShellOwnedProcess $script:scope $script:process
      ($script:events -join ",") | Should -Be "root-exited,Terminate,Wait,Active,drain,Close"
      $script:run.Finalized | Should -BeTrue
      Should -Invoke Invoke-ShellJob -Times 0 -Exactly -ParameterFilter {
        $Operation -eq "Terminate" -and $Job -eq [IntPtr]456
      }
      Should -Invoke Invoke-ShellJob -Times 1 -Exactly -ParameterFilter {
        $Operation -eq "Terminate" -and $Job -eq [IntPtr]567
      }
      $script:events | Should -Not -Contain "close-launch"
      Complete-ShellOwnedProcess $script:scope $script:process
      Should -Invoke Invoke-ShellJob -Times 1 -Exactly -ParameterFilter { $Operation -eq "Terminate" }
    }
    It "refuses finalization of a still-live root without terminating any job" {
      $script:run | Add-Member ScriptMethod RequireExited { throw "original root is still live" } -Force
      $script:scope.Runs.Add($script:run)
      { Complete-ShellOwnedProcess $script:scope $script:process } | Should -Throw "*still live*"
      Should -Invoke Invoke-ShellJob -Times 0 -Exactly -ParameterFilter { $Operation -eq "Terminate" }
      $script:run.Finalized | Should -BeFalse
    }
    It "retains the launch when its private job remains active" {
      $script:scope.Runs.Add($script:run)
      Mock Invoke-ShellJob { 1 } -ParameterFilter { $Operation -eq "Active" }
      $failure = $null
      try { Complete-ShellOwnedProcess $script:scope $script:process } catch { $failure = $_ }
      Test-ShellOwnershipUnproven $failure | Should -BeTrue
      $script:run.Finalized | Should -BeFalse
      $script:events | Should -Not -Contain "drain"
      $script:events | Should -Not -Contain "Close"
    }
    It "propagates EOF uncertainty after private-job emptiness without releasing handles" {
      $script:scope.Runs.Add($script:run)
      $script:run | Add-Member ScriptMethod Drain { throw "inherited pipe EOF unproved" } -Force
      $failure = $null
      try { Complete-ShellOwnedProcess $script:scope $script:process } catch { $failure = $_ }
      Test-ShellOwnershipUnproven $failure | Should -BeTrue
      $script:run.Finalized | Should -BeFalse
      $script:events | Should -Not -Contain "Close"
      $script:events | Should -Not -Contain "close-launch"
    }
    It "cleans a partially assigned suspended launch through its original handle" {
      $script:run.ScopeAssigned = $false
      $script:run.LaunchAssigned = $false
      $script:run.LaunchJob = [IntPtr]::Zero
      $script:scope.Runs.Add($script:run)
      Close-ShellProcessScope $script:scope
      $script:events | Should -Contain "stop-held"
      $script:run.Finalized | Should -BeTrue
      $script:scope.Closed | Should -BeTrue
    }
    It "closes a partially finalized scope idempotently without re-finalizing completed jobs" {
      $script:scope.Runs.Add($script:run)
      Complete-ShellOwnedProcess $script:scope $script:process
      $script:events.Clear()
      Close-ShellProcessScope $script:scope
      ($script:events -join ",") | Should -Be "Terminate,Wait,Active,close-launch,Close"
      $script:events.Clear()
      Close-ShellProcessScope $script:scope
      $script:events.Count | Should -Be 0
    }
    It "leaves a concurrently live sibling launch untouched during explicit finalization" {
      $other = [Diagnostics.Process]::new()
      try {
        $sibling = [pscustomobject]@{ Process = $other; LaunchJob = [IntPtr]678; Finalized = $false }
        $sibling | Add-Member ScriptMethod RequireExited { throw "sibling root is still live" }
        $script:scope.Runs.Add($script:run)
        $script:scope.Runs.Add($sibling)
        Complete-ShellOwnedProcess $script:scope $script:process
        $sibling.Finalized | Should -BeFalse
        Should -Invoke Invoke-ShellJob -Times 0 -Exactly -ParameterFilter {
          $Operation -eq "Terminate" -and $Job -ne [IntPtr]567
        }
      } finally { $other.Dispose() }
    }
    It "cleans a retained private job whose suspended launch assignment failed" {
      Mock Invoke-ShellJob { throw "private assignment refused" } -ParameterFilter {
        $Operation -eq "Assign" -and $Job -eq [IntPtr]567
      }
      { Start-ShellOwnedProcess $script:scope ([Diagnostics.ProcessStartInfo]::new()) } |
        Should -Throw "*private assignment refused*"
      $script:run.ScopeAssigned | Should -BeTrue
      $script:run.LaunchAssigned | Should -BeFalse
      $script:events | Should -Not -Contain "resume"
      Close-ShellProcessScope $script:scope
      $script:run.Finalized | Should -BeTrue
      $script:run.LaunchJobClosed | Should -BeTrue
      $script:scope.Closed | Should -BeTrue
    }
    It "returns complete stdout and stderr only after explicit finalization" {
      $script:run | Add-Member NoteProperty Output ([Threading.Tasks.Task]::FromResult[string]("stdout"))
      $script:run | Add-Member NoteProperty Error ([Threading.Tasks.Task]::FromResult[string]("stderr"))
      $script:scope.Runs.Add($script:run)
      Complete-ShellOwnedProcess $script:scope $script:process
      Read-ShellOwnedOutput $script:scope $script:process | Should -BeExactly "stdout"
      Read-ShellOwnedOutput $script:scope $script:process -StandardError | Should -BeExactly "stderr"
    }
    It "receives bounded incremental text without finalizing a live launch" -Tag IncrementalOutput {
      $script:run | Add-Member ScriptMethod TakeOutput { param($maximum) "out:$maximum" }
      $script:run | Add-Member ScriptMethod TakeError { param($maximum) "err:$maximum" }
      $script:scope.Runs.Add($script:run)
      $chunk = Receive-ShellOwnedOutput $script:scope $script:process -MaximumCharacters 8
      $chunk.Output | Should -BeExactly "out:8"
      $chunk.Error | Should -BeExactly "err:8"
      $script:run.Finalized | Should -BeFalse
      $script:events.Count | Should -Be 0
    }
    It "refuses incremental reads through a different process object" {
      $script:scope.Runs.Add($script:run)
      $other = [Diagnostics.Process]::new()
      try {
        { Receive-ShellOwnedOutput $script:scope $other } | Should -Throw "*original launch record*"
        $script:events.Count | Should -Be 0
      } finally { $other.Dispose() }
    }
    It "rejects invalid incremental batch limits before accessing any stream or job" {
      $script:scope.Runs.Add($script:run)
      { Receive-ShellOwnedOutput $script:scope $script:process -MaximumCharacters 1 } | Should -Throw
      { Receive-ShellOwnedOutput $script:scope $script:process -MaximumCharacters 65537 } | Should -Throw
      $script:events.Count | Should -Be 0
    }
    It "propagates incremental pump faults without returning success-shaped chunks" {
      $script:run | Add-Member ScriptMethod TakeOutput { throw [IO.IOException]::new("stdout pump failed") }
      $script:run | Add-Member ScriptMethod TakeError { throw "stderr must not be accessed" }
      $script:scope.Runs.Add($script:run)
      $failure = $null
      try { Receive-ShellOwnedOutput $script:scope $script:process } catch { $failure = $_ }
      $failure.Exception.Message | Should -Match "stdout pump failed"
      Test-ShellOwnershipUnproven $failure | Should -BeTrue
      $script:events.Count | Should -Be 0
    }
  }
}

Describe "Original held-root signalling after real native job termination" {
  It "closes actual shared-helper scopes only after all original root objects signal and both readers reach EOF" {
    $assemblyPath = $env:GRAPHCODE_VALIDATION_ASSEMBLY
    $executable = [IO.Path]::ChangeExtension($assemblyPath, '.exe')
    Test-Path -LiteralPath $executable -PathType Leaf | Should -BeTrue
    $executed = 0
    foreach ($iteration in 1..10) {
      $scope = New-ShellProcessScope
      try {
        foreach ($index in 1..4) {
          $start = [Diagnostics.ProcessStartInfo]::new($executable)
          $start.UseShellExecute = $false
          $start.CreateNoWindow = $true
          $start.RedirectStandardOutput = $true
          $start.RedirectStandardError = $true
          foreach ($argument in @('--ownership-fixture', 'shell-scope-child', $TestDrive)) {
            $start.ArgumentList.Add($argument)
          }
          $null = Start-ShellOwnedProcess $scope $start
        }
        $ready = [Collections.Generic.HashSet[int]]::new()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($ready.Count -ne 4) {
          foreach ($run in $scope.Runs) {
            if ($ready.Contains($run.Process.Id)) { continue }
            $chunk = Receive-ShellOwnedOutput $scope $run.Process
            if ($chunk.Output.Contains('shell-scope-ready')) { $null = $ready.Add($run.Process.Id) }
          }
          if ($clock.ElapsedMilliseconds -gt 5000) { throw 'Controlled held roots did not all become ready.' }
          [Threading.Thread]::Sleep(5)
        }
        Close-ShellProcessScope $scope
        $scope.Closed | Should -BeTrue
        foreach ($run in $scope.Runs) {
          $run.Finalized | Should -BeTrue
          $run.LaunchJobClosed | Should -BeTrue
          $run.Handle | Should -Be ([IntPtr]::Zero)
          $run.Output.IsCompletedSuccessfully | Should -BeTrue
          $run.Error.IsCompletedSuccessfully | Should -BeTrue
          $run.Output.Result | Should -Match 'shell-scope-ready'
          $run.Error.Result | Should -Match 'shell-scope-stderr'
          $executed++
        }
        Close-ShellProcessScope $scope
      } finally {
        if (-not $scope.Closed) {
          try { Close-ShellProcessScope $scope } catch {
            try { [Console]::Out.WriteLine('GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven'); [Console]::Out.Flush() }
            finally { [Threading.Thread]::Sleep([Threading.Timeout]::Infinite) }
          }
        }
      }
    }
    $executed | Should -Be 40
    Write-Host "SHELL_SCOPE_NATIVE_EXECUTED=40 PASSED=40 FAILED=0 scopes=10"
  }
}

Describe "Incremental capture before EOF (managed reader only)" {
  BeforeAll {
    InModuleScope ShellProcessOwnership { Initialize-ShellProcessOwnership }
    $captureType = ("ShellOwnedLaunch" -as [type]).GetNestedType("OutputCapture", [Reflection.BindingFlags]::NonPublic)
    & (Join-Path $PSScriptRoot "..\Import-CompiledValidationAssembly.ps1") `
      -AssemblyPath $env:GRAPHCODE_VALIDATION_ASSEMBLY `
      -RequiredType "GraphCode.Validation.TestFixtures.ControlledOutputReader" | Out-Null
    $readerType = [GraphCode.Validation.TestFixtures.ControlledOutputReader]
    $writerType = [GraphCode.Validation.TestFixtures.FailingForwardWriter]
  }
  BeforeEach {
    $expectReaderFault = $false
    $text = "a" + [char]::ConvertFromUtf32(0x1F600) + "b"
    $reader = [Activator]::CreateInstance($readerType, [object[]]@($text))
    $capture = [Activator]::CreateInstance($captureType, [object[]]@($reader))
  }
  AfterEach {
    [void] $reader.End.TrySetResult(0)
    try {
      if (-not $capture.Completion.Wait(5000)) { throw "Managed capture did not stop" }
    } catch {
      if (-not $expectReaderFault -or -not $capture.Completion.IsFaulted) { throw }
    }
    $reader.Dispose()
  }
  It "forwards bounded characters before EOF without splitting surrogate pairs or losing final text" {
    $capture.Completion.IsCompleted | Should -BeFalse
    $capture.Take(2) | Should -BeExactly "a"
    $capture.Take(2) | Should -BeExactly ([char]::ConvertFromUtf32(0x1F600))
    $capture.Take(2) | Should -BeExactly "b"
    $capture.Take(2) | Should -BeExactly ""
    ($null -eq $capture.Take(2)) | Should -BeFalse
    $capture.Completion.IsCompleted | Should -BeFalse
    [void] $reader.End.TrySetResult(0)
    $capture.Completion.Wait(5000) | Should -BeTrue
    $capture.Completion.GetAwaiter().GetResult() | Should -BeExactly $text
  }
  It "surfaces a reader fault instead of reporting an empty successful stream" {
    $expectReaderFault = $true
    [void] $reader.End.TrySetException([IO.IOException]::new("managed reader failed"))
    { $capture.Completion.Wait(5000) } | Should -Throw "*managed reader failed*"
    { $capture.Take(8) } | Should -Throw "*managed reader failed*"
  }
  It "enforces the same hard character bounds in the actual managed capture" {
    { $capture.Take(1) } | Should -Throw
    { $capture.Take(65537) } | Should -Throw
    $capture.Take(4) | Should -BeExactly $text
  }
  It "preserves text that arrives between empty non-EOF polls" {
    $capture.Take(4) | Should -BeExactly $text
    $capture.Take(4) | Should -BeExactly ""
    $capture.Completion.IsCompleted | Should -BeFalse
    $reader.Tail = "later"
    [void] $reader.End.TrySetResult(5)
    $received = ""
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($received.Length -lt 5 -and $clock.ElapsedMilliseconds -lt 5000) {
      $chunk = $capture.Take(2)
      $chunk.Length | Should -BeLessOrEqual 2
      $received += $chunk
      [Threading.Thread]::Sleep(1)
    }
    $received | Should -BeExactly "later"
    $capture.Completion.IsCompleted | Should -BeFalse
    [void] $reader.End.TrySetResult(0)
    $capture.Completion.Wait(5000) | Should -BeTrue
    $capture.Completion.GetAwaiter().GetResult() | Should -BeExactly ($text + "later")
  }
  It "forwards exactly the 65536-character ceiling and retains the complete capture" {
    $large = "x" * 70000
    $largeReader = [Activator]::CreateInstance($readerType, [object[]]@($large))
    $largeCapture = [Activator]::CreateInstance($captureType, [object[]]@($largeReader))
    try {
      $largeCapture.Take(65536).Length | Should -Be 65536
      $largeCapture.Take(65536).Length | Should -Be 4464
      $largeCapture.Take(65536) | Should -BeExactly ""
      $largeCapture.Completion.IsCompleted | Should -BeFalse
      [void] $largeReader.End.TrySetResult(0)
      $largeCapture.Completion.Wait(5000) | Should -BeTrue
      $largeCapture.Completion.GetAwaiter().GetResult() | Should -BeExactly $large
    } finally {
      [void] $largeReader.End.TrySetResult(0)
      if (-not $largeCapture.Completion.Wait(5000)) { throw "Large managed capture did not stop" }
      $largeReader.Dispose()
    }
  }
  It "redirected=<redirected>: forwards only inherited-style streams before EOF" -TestCases @(
    @{ redirected = $false }, @{ redirected = $true }
  ) {
    param($redirected)
    $sink = [IO.StringWriter]::new()
    $select = ("ShellOwnedLaunch" -as [type]).GetMethod("ForwardWriter",
      [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic)
    $forward = $select.Invoke($null, [object[]]@($redirected, $sink))
    $liveReader = [Activator]::CreateInstance($readerType, [object[]]@($text))
    $liveCapture = [Activator]::CreateInstance($captureType, [object[]]@($liveReader, $forward))
    try {
      $liveCapture.Completion.IsCompleted | Should -BeFalse
      $sink.ToString() | Should -BeExactly $(if ($redirected) { "" } else { $text })
      $liveCapture.Take(4) | Should -BeExactly $text
      [void] $liveReader.End.TrySetResult(0)
      $liveCapture.Completion.Wait(5000) | Should -BeTrue
      $liveCapture.Completion.GetAwaiter().GetResult() | Should -BeExactly $text
      $sink.ToString() | Should -BeExactly $(if ($redirected) { "" } else { $text })
    } finally {
      [void] $liveReader.End.TrySetResult(0)
      if (-not $liveCapture.Completion.Wait(5000)) { throw "Live-forward capture did not stop" }
      $liveReader.Dispose()
      $sink.Dispose()
    }
  }
  It "flushFailure=<flushFailure>: surfaces forwarding sink failures in the capture task" -TestCases @(
    @{ flushFailure = $false }, @{ flushFailure = $true }
  ) {
    param($flushFailure)
    $sink = [Activator]::CreateInstance($writerType)
    $sink.FailFlush = $flushFailure
    $liveReader = [Activator]::CreateInstance($readerType, [object[]]@($text))
    $liveCapture = [Activator]::CreateInstance($captureType, [object[]]@($liveReader, $sink))
    try {
      $expected = if ($flushFailure) { "*forward flush failed*" } else { "*forward write failed*" }
      { $liveCapture.Completion.Wait(5000) } | Should -Throw $expected
      { $liveCapture.Take(4) } | Should -Throw $expected
    } finally {
      [void] $liveReader.End.TrySetResult(0)
      $liveReader.Dispose()
      $sink.Dispose()
    }
  }
  It "preserves UTF-8 forwarding when a surrogate pair crosses pump read boundaries" -Tag ForwardUnicode {
    $large = ("x" * 4095) + [char]::ConvertFromUtf32(0x1F600) + "b"
    $bytes = [IO.MemoryStream]::new()
    $sink = [IO.StreamWriter]::new($bytes, [Text.UTF8Encoding]::new($false), 1024, $true)
    $sink.AutoFlush = $true
    $liveReader = [Activator]::CreateInstance($readerType, [object[]]@($large))
    $liveCapture = [Activator]::CreateInstance($captureType, [object[]]@($liveReader, $sink))
    try {
      [void] $liveReader.End.TrySetResult(0)
      $liveCapture.Completion.Wait(5000) | Should -BeTrue
      $liveCapture.Completion.GetAwaiter().GetResult() | Should -BeExactly $large
      $forwarded = [Text.UTF8Encoding]::new($false, $true).GetString($bytes.ToArray())
      ($forwarded -ceq $large) | Should -BeTrue -Because "forwarding must not flush half a surrogate pair"
    } finally {
      [void] $liveReader.End.TrySetResult(0)
      if (-not $liveCapture.Completion.Wait(5000)) { throw "UTF-8 forwarding capture did not stop" }
      $liveReader.Dispose()
      $sink.Dispose()
      $bytes.Dispose()
    }
  }
}

Describe "Ownership source wiring (not native execution)" {
  It "selects live forwarding independently for originally unredirected stdout and stderr" -Tag ForwardPolicy {
    InModuleScope ShellProcessOwnership { Initialize-ShellProcessOwnership }
    $select = ("ShellOwnedLaunch" -as [type]).GetMethod("ForwardWriter",
      [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic)
    $select | Should -Not -BeNullOrEmpty
    $sink = [IO.StringWriter]::new()
    try {
      ($null -eq $select.Invoke($null, [object[]]@($true, $sink))) | Should -BeTrue
      [object]::ReferenceEquals($sink, $select.Invoke($null, [object[]]@($false, $sink))) | Should -BeTrue
    } finally { $sink.Dispose() }
    $native = Get-Content -LiteralPath (Join-Path $repo "Tools\windows\ShellOwnedProcess.cs") -Raw
    $native | Should -Match 'ForwardWriter\(info.RedirectStandardOutput, Console.Out\)'
    $native | Should -Match 'ForwardWriter\(info.RedirectStandardError, Console.Error\)'
  }
  It "preserves each smoke caller's original per-stream capture intent" {
    $ast = [Management.Automation.Language.Parser]::ParseFile($shellPath, [ref]$null, [ref]$null)
    $function = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Start-SmokeProcess"
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    $repoRoot = $repo
    Mock Get-Command { [pscustomobject]@{ Source = "D:\synthetic.exe" } }
    Mock Start-ShellOwnedProcess { param($Scope, $StartInfo) $script:observedStart = $StartInfo }
    foreach ($case in @(
      @{ output = $false; error = $false },
      @{ output = $true; error = $false },
      @{ output = $false; error = $true },
      @{ output = $true; error = $true }
    )) {
      Start-SmokeProcess "synthetic" @() -scope ([pscustomobject]@{}) `
        -CaptureOutput:$case.output -CaptureError:$case.error
      $script:observedStart.RedirectStandardOutput | Should -Be $case.output
      $script:observedStart.RedirectStandardError | Should -Be $case.error
      $script:observedStart.WindowStyle | Should -Be ([Diagnostics.ProcessWindowStyle]::Normal)
    }
    $text = Get-Content -LiteralPath $shellPath -Raw
    $text | Should -Match '\$versionProcess = Start-SmokeProcess \$app @\("--version"\) -CaptureOutput -CaptureError'
    $text | Should -Match '\$busyApp = Start-SmokeProcess \$app @\("--smoke"\) -CaptureError'
    $text | Should -Match '\$inputApp = Start-SmokeProcess \$app @\("--smoke"\) -CaptureError'
  }
  It "samples surviving bare-name descendants before finalization and reads only afterwards" {
    $text = Get-Content -LiteralPath $shellPath -Raw
    $text | Should -Match '(?s)\$process.WaitForExit\(\).*?& \$sample\s+Record-TestOwnedSessions\s+Complete-ShellOwnedProcess \$bareProcessScope \$process\s+\$stderr = Read-ShellOwnedOutput \$bareProcessScope \$process -StandardError'
  }
  It "inherits the current directory for default or empty settings and preserves explicit directories" -Tag WorkingDirectory {
    $native = Get-Content -LiteralPath (Join-Path $repo "Tools\windows\ShellOwnedProcess.cs") -Raw
    $argument = [regex]::Match($native, 'environment, (.*?), ref startup, out created')
    $argument.Success | Should -BeTrue
    $argument.Groups[1].Value | Should -BeExactly "SelectWorkingDirectory(info)"
    $selector = "ShellOwnedLaunch" -as [type]
    $default = [Diagnostics.ProcessStartInfo]::new()
    $default.WorkingDirectory | Should -BeExactly ""
    ($null -eq $selector::SelectWorkingDirectory($default)) | Should -BeTrue
    $default.WorkingDirectory = ""
    ($null -eq $selector::SelectWorkingDirectory($default)) | Should -BeTrue
    $default.WorkingDirectory = "D:\explicit directory\"
    $selector::SelectWorkingDirectory($default) | Should -BeExactly "D:\explicit directory\"
  }
  It "compiles the existing job mechanism and suspended-launch interop without invoking native APIs" {
    InModuleScope ShellProcessOwnership { Initialize-ShellProcessOwnership }
    "ShellOwnedLaunch" -as [type] | Should -Not -BeNullOrEmpty
  }
  It "removes CIM-derived and named zmx termination from both reachable scripts" {
    foreach ($path in @($shellPath, (Join-Path $repo "Tools\windows\Tests\DaemonHandoff.Live.Tests.ps1"))) {
      $text = Get-Content -LiteralPath $path -Raw
      $text | Should -Not -Match 'Stop-Process|\.Kill\(|kill --force'
      $text | Should -Match 'Close-ShellProcessScope'
      $text | Should -Match 'UNATTESTED_SURVIVORS|Assert-NoOrphanShellProcesses'
    }
  }
  It "requires held job membership before retaining a CIM-discovered handoff candidate" {
    $text = Get-Content -LiteralPath (Join-Path $repo "Tools\windows\Tests\DaemonHandoff.Live.Tests.ps1") -Raw
    $text | Should -Match 'Get-ShellOwnedMember \$processScope \$children\[0\]\.ProcessId'
    $module = Get-Content -LiteralPath (Join-Path $repo "Tools\windows\ShellProcessOwnership.psm1") -Raw
    $module | Should -Match '(?s)function Get-ShellOwnedMember.*?Contains.*?Members.Add'
  }
  It "preserves both registered large-paste sampling contracts with the owned launcher" {
    $shellSource = Get-Content -LiteralPath $shellPath -Raw
    $path = Join-Path $repo "Tools\windows\Tests\WindowsShell.Tests.ps1"
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    $errors.Count | Should -Be 0
    $commands = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq "Assert-Contract" -and
        ($node.Extent.Text.Contains("large-paste sampling") -or
         $node.Extent.Text.Contains("large-paste metric is not tied"))
    }, $true))
    $commands.Count | Should -Be 2
    function Assert-Contract($condition, $message) {
      if (-not $condition) { throw $message }
    }
    foreach ($command in $commands) { & ([scriptblock]::Create($command.Extent.Text)) }
  }
  It "requires original/managed generation comparison and an explicit inherited handle list" {
    $native = Get-Content -LiteralPath (Join-Path $repo "Tools\windows\ShellOwnedProcess.cs") -Raw
    $native | Should -Match 'nativeCreated != managedCreated'
    $native | Should -Match 'new IntPtr\(0x20002\)'
    $native | Should -Match 'uint flags = 0x4'
  }
  It "preserves empty, spaced, quoted and trailing-backslash arguments without native execution" {
    $quote = ("ShellOwnedLaunch" -as [type]).GetMethod("Quote",
      [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic)
    $fixtures = @(
      @{ value = ""; expected = '""' },
      @{ value = "plain"; expected = '"plain"' },
      @{ value = "two words"; expected = '"two words"' },
      @{ value = 'a"b'; expected = '"a\"b"' },
      @{ value = 'D:\two words\'; expected = '"D:\two words\\"' }
    )
    foreach ($fixture in $fixtures) {
      $quote.Invoke($null, [object[]]@($fixture.value)) | Should -BeExactly $fixture.expected
    }
    $fixtures.Count | Should -Be 5
  }
}

Describe "Shell cleanup never promotes advisory process observations" {
  It "refuses a disposed launch PID and a same-session CIM impostor without terminating either" {
    $source = Get-Content -LiteralPath $shellPath -Raw
    $legacy = [regex]::Match($source,
      '(?s)if \(\$env:GRAPHCODE_ZMX -and \(Test-Path -LiteralPath \$env:GRAPHCODE_ZMX\)\) \{.*?\r?\n  \}')
    if (-not $legacy.Success) {
      $source | Should -Match 'Close-ShellProcessScope'
      $source | Should -Not -Match 'Stop-Process'
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
      $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq "Assert-NoOrphanShellProcesses"
      }, $true)
      . ([scriptblock]::Create($function.Extent.Text))
      function Test-TestSessionProcess { $true }
      Mock Get-CimInstance { [pscustomobject]@{ ProcessId = 202; CommandLine = "forged-session" } }
      Mock Stop-Process {}
      { Assert-NoOrphanShellProcesses } | Should -Throw "*UNATTESTED_SURVIVORS*"
      Should -Invoke Stop-Process -Times 0 -Exactly
      return
    }

    $ownedProcessIds = [Collections.Generic.HashSet[int]]::new()
    [void]$ownedProcessIds.Add(101)
    $ownedSessionNames = @()
    $saved = $env:GRAPHCODE_ZMX
    $env:GRAPHCODE_ZMX = "synthetic-zmx"
    Mock Test-Path { $true }
    Mock Get-Process { [pscustomobject]@{ Id = 101 } }
    Mock Get-CimInstance { [pscustomobject]@{ Name = "zmx.exe"; ProcessId = 202 } }
    Mock Stop-Process {}
    function Get-ProcessTreeIds { @(101) }
    function Test-TestSessionProcess { $true }
    try {
      & ([scriptblock]::Create($legacy.Value))
      Should -Invoke Stop-Process -Times 0 -Exactly
    } finally {
      $env:GRAPHCODE_ZMX = $saved
    }
  }
}

Describe "Handoff teardown refuses unattested image matches" {
  It "<case>: only verified owned-job cleanup can release support files" -TestCases @(
    @{ case = "same-path impostor"; hasSurvivor = $true },
    @{ case = "normal owned cleanup"; hasSurvivor = $false }
  ) {
    param($hasSurvivor)
    $path = Join-Path $repo "Tools\windows\Tests\DaemonHandoff.Live.Tests.ps1"
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    $errors.Count | Should -Be 0
    $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    $processScope = [pscustomobject]@{ Closed = $false }
    $daemonExecutable = "D:\synthetic-handoff\graphcoded.exe"
    $supportDirectory = "D:\synthetic-handoff\support"
    $supportCreated = $true
    $primaryFailure = $null
    function Close-ShellProcessScope { $processScope.Closed = $true }
    Mock Get-CimInstance {
      if ($hasSurvivor) { [pscustomobject]@{
        Name = "graphcoded.exe"; ProcessId = 303; ExecutablePath = "D:\synthetic-handoff\graphcoded.exe"
      } }
    }

    Mock Stop-Process {}
    Mock Remove-Item {}
    Mock Write-Host {}
    Mock Write-Host {} -ModuleName ShellProcessOwnership
    $body = ($main.Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"
    if ($hasSurvivor) {
      { & ([scriptblock]::Create($body)) } | Should -Throw "*UNATTESTED_SURVIVORS*"
      Should -Invoke Remove-Item -Times 0 -Exactly
    } else {
      & ([scriptblock]::Create($body))
      Should -Invoke Remove-Item -Times 1 -Exactly
    }
    $processScope.Closed | Should -BeTrue
    Should -Invoke Stop-Process -Times 0 -Exactly
  }
}

Describe "Late bare-stage cleanup preserves earlier failures (mock only)" {
  It "<boundary> preserves primary failure and <kind> cleanup evidence" -Tag LateCleanup -TestCases @(
    @{ boundary = "outer"; kind = "tagged" },
    @{ boundary = "outer"; kind = "CIM" },
    @{ boundary = "bare"; kind = "tagged" },
    @{ boundary = "bare"; kind = "CIM" },
    @{ boundary = "outer"; kind = "earlier tagged" },
    @{ boundary = "bare"; kind = "earlier tagged" }
  ) {
    param($boundary, $kind)
    $ast = [Management.Automation.Language.Parser]::ParseFile($shellPath, [ref]$null, [ref]$null)
    $helper = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "New-ShellCleanupFailure"
    }, $true)
    if ($helper) { . ([scriptblock]::Create($helper.Extent.Text)) }
    if ($boundary -eq "bare") {
      $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq "Invoke-BareNameZmxShell"
      }, $true)
      $main = @($function.Body.EndBlock.Statements |
        Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    } else {
      $main = @($ast.EndBlock.Statements |
        Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    }
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    $observedRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $observedRoot | Out-Null
    $primary = [InvalidOperationException]::new("first failure")
    $late = [InvalidOperationException]::new("late $kind refusal")
    if ($kind -eq "tagged") {
      $late.Data["GraphCodeValidationRootRetentionRequired"] = $true
      $late.Data["GraphCodeValidationRetainedRoots"] = @($observedRoot)
    }
    if ($kind -eq "earlier tagged") {
      $primary.Data["GraphCodeValidationRootRetentionRequired"] = $true
      $primary.Data["GraphCodeValidationRetainedRoots"] = @($observedRoot)
    }
    function Remove-BareNameZmxStage {}
    function Assert-NoOrphanShellProcesses {}
    Mock Remove-BareNameZmxStage { throw $late }
    Mock Close-ShellProcessScope { param($scope) $scope.Closed = $true }
    Mock Assert-NoOrphanShellProcesses {}
    Mock Remove-Item {}
    Mock Get-ChildItem {}
    Mock Write-Host {}
    Mock Write-Host {} -ModuleName ShellProcessOwnership
    $failure = $null
    try {
      & {
        foreach ($variable in @($main.Finally.FindAll({
          param($node)
          $node -is [Management.Automation.Language.VariableExpressionAst] -and
            -not $node.VariablePath.IsDriveQualified
        }, $true).VariablePath.UserPath | Sort-Object -Unique)) {
          if ($variable -notin @("_", "null", "true", "false")) { Set-Variable $variable $null }
        }
        $primaryFailure = [Management.Automation.ErrorRecord]::new($primary, "primary", "NotSpecified", $null)
        $barePrimaryFailure = $primaryFailure
        $processScope = [pscustomobject]@{ Closed = $false }
        $bareProcessScope = [pscustomobject]@{ Closed = $false }
        $stubSessionHosts = @{}
        $shellRoot = $root
        $workspaceLayoutBase = "D:\synthetic-layout.json"
        $bareZmxStage = $root
        $bareZmxProject = $root
        $smokeZmxDir = "$root\smoke"
        $bareStubResult = "$root\bare-stub.json"
        $stubResult = "$root\stub.json"
        $busyResult = "$root\busy.json"
        $busyError = "$root\busy.err"
        $inputError = "$root\input.err"
        $body = ($main.Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"
        & ([scriptblock]::Create($body))
      }
    } catch { $failure = $_ }
    $failure | Should -Not -BeNullOrEmpty
    $expected = if ($kind -eq "earlier tagged") { "Earlier ownership refusal" } else { "late" }
    $failure.Exception.Message | Should -Match "^Shell failed: first failure; cleanup unproved: .*$expected"
    [object]::ReferenceEquals($failure.Exception.InnerException, $primary) | Should -BeTrue
    Test-ShellOwnershipUnproven $failure | Should -BeTrue
    $failure.Exception.Data["GraphCodeValidationRetainedRoots"] | Should -Contain $root
    if ($kind -ne "CIM") {
      $failure.Exception.Data["GraphCodeValidationRetainedRoots"] | Should -Contain $observedRoot
    }
    Should -Invoke Remove-BareNameZmxStage -Times $(if ($kind -eq "earlier tagged") { 0 } else { 1 }) -Exactly
    Should -Invoke Close-ShellProcessScope -Times $(if ($boundary -eq "outer") { 2 } else { 1 }) -Exactly
    Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { $PesterBoundParameters.ContainsKey("LiteralPath") }
    Remove-Item -LiteralPath "$root\filter-positive-control"
    Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters.ContainsKey("LiteralPath") }
  }
}

Describe "Ownership-unproven root retention contract (filesystem only)" {
  BeforeEach {
    $hadRoot = [Environment]::GetEnvironmentVariables().Contains("GRAPHCODE_VALIDATION_ROOT")
    $savedRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT")
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:GRAPHCODE_VALIDATION_ROOT = $root
    Mock Write-Host {} -ModuleName ShellProcessOwnership
  }
  AfterEach {
    if ($hadRoot) {
      [Environment]::SetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT", $savedRoot, "Process")
    } else {
      Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT -ErrorAction SilentlyContinue
    }
    [Environment]::GetEnvironmentVariables().Contains("GRAPHCODE_VALIDATION_ROOT") | Should -Be $hadRoot
    if ($hadRoot) {
      [Environment]::GetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT") | Should -BeExactly $savedRoot
    }
  }
  It "publishes a bounded CreateNew UTF-8 receipt and an actual retained-root list" {
    $error = Set-ShellOwnershipUnproven ([InvalidOperationException]::new("unattested survivor")) @($root, "$root\absent")
    $error.Data["GraphCodeValidationRootRetentionRequired"] | Should -BeTrue
    @($error.Data["GraphCodeValidationRetainedRoots"]).Count | Should -Be 1
    $receipt = Join-Path $root "ownership-unproven.json"
    $bytes = [IO.File]::ReadAllBytes($receipt)
    $bytes.Length | Should -BeLessOrEqual 4096
    $payload = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
    $payload.schemaVersion | Should -Be 1
    $payload.validationRoot | Should -BeExactly ([IO.Path]::GetFullPath($root))
    $payload.reason | Should -BeExactly "ownership_unproven"
    Should -Invoke Write-Host -ModuleName ShellProcessOwnership -Times 1 -Exactly -ParameterFilter {
      $Object -eq "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven"
    }
  }
  It "preserves an existing receipt and still flags a receipt-write failure" {
    $receipt = Join-Path $root "ownership-unproven.json"
    [IO.File]::WriteAllText($receipt, "first retained evidence")
    $before = (Get-FileHash -LiteralPath $receipt).Hash
    $error = Set-ShellOwnershipUnproven ([InvalidOperationException]::new("unattested survivor"))
    (Get-FileHash -LiteralPath $receipt).Hash | Should -BeExactly $before
    $error.Data["GraphCodeValidationRetentionReceiptFailure"] | Should -Not -BeNullOrEmpty
    $error.Data["GraphCodeValidationRootRetentionRequired"] | Should -BeTrue
    Should -Invoke Write-Host -ModuleName ShellProcessOwnership -Times 1 -Exactly -ParameterFilter {
      $Object -eq "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven"
    }
  }
  It "flags standalone same-process failures even when no validation root is configured" {
    Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT -ErrorAction SilentlyContinue
    [Environment]::GetEnvironmentVariables().Contains("GRAPHCODE_VALIDATION_ROOT") | Should -BeFalse
    $error = Set-ShellOwnershipUnproven ([InvalidOperationException]::new("unattested survivor")) @($root)
    Test-ShellOwnershipUnproven $error | Should -BeTrue
    Test-Path (Join-Path $root "ownership-unproven.json") | Should -BeFalse
  }
  It "refuses a configured file root without suppressing the retention signal" {
    $file = Join-Path $root "not-a-directory"
    [IO.File]::WriteAllText($file, "preserve")
    $env:GRAPHCODE_VALIDATION_ROOT = $file
    $error = Set-ShellOwnershipUnproven ([InvalidOperationException]::new("unattested survivor"))
    $error.Data["GraphCodeValidationRetentionReceiptFailure"] | Should -Not -BeNullOrEmpty
    $error.Data["GraphCodeValidationRootRetentionRequired"] | Should -BeTrue
    [IO.File]::ReadAllText($file) | Should -BeExactly "preserve"
  }
  It "preserves the tagged primary when diagnostic transport fails: <case>" -TestCases @(
    @{ case = "sentinel"; failSentinel = $true; failReceiptDiagnostic = $false; blockedRoot = $false; absentRoot = $false; failures = 1 }
    @{ case = "receipt diagnostic"; failSentinel = $false; failReceiptDiagnostic = $true; blockedRoot = $true; absentRoot = $false; failures = 1 }
    @{ case = "both channels"; failSentinel = $true; failReceiptDiagnostic = $true; blockedRoot = $true; absentRoot = $false; failures = 2 }
    @{ case = "standalone sentinel"; failSentinel = $true; failReceiptDiagnostic = $false; blockedRoot = $false; absentRoot = $true; failures = 1 }
  ) {
    param($failSentinel, $failReceiptDiagnostic, $blockedRoot, $absentRoot, $failures)
    if ($failSentinel) {
      Mock Write-Host { throw [IO.IOException]::new("sentinel transport failed") } -ModuleName ShellProcessOwnership -ParameterFilter {
        $Object -eq "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven"
      }
    }
    if ($failReceiptDiagnostic) {
      Mock Write-Host { throw [IO.IOException]::new("receipt diagnostic transport failed") } -ModuleName ShellProcessOwnership -ParameterFilter {
        $Object -like "SHELL_RETENTION_RECEIPT_UNPROVEN=*"
      }
    }
    if ($blockedRoot) {
      $file = Join-Path $root "blocked-root"
      [IO.File]::WriteAllText($file, "preserve")
      $env:GRAPHCODE_VALIDATION_ROOT = $file
    } elseif ($absentRoot) {
      Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT
    }
    $primary = [InvalidOperationException]::new("unattested survivor")
    $returned = Set-ShellOwnershipUnproven $primary @($root)
    [object]::ReferenceEquals($returned, $primary) | Should -BeTrue
    Test-ShellOwnershipUnproven $returned | Should -BeTrue
    $returned.Message | Should -BeExactly "unattested survivor"
    $returned.Data["GraphCodeValidationRetainedRoots"] | Should -Contain $root
    @($returned.Data["GraphCodeValidationRetentionDiagnosticFailures"]).Count | Should -Be $failures
    foreach ($failure in $returned.Data["GraphCodeValidationRetentionDiagnosticFailures"]) {
      $failure | Should -BeOfType ([IO.IOException])
      $failure.Message | Should -BeLike "*transport failed"
    }
    if ($blockedRoot) {
      $returned.Data["GraphCodeValidationRetentionReceiptFailure"] | Should -Not -BeNullOrEmpty
      [IO.File]::ReadAllText($file) | Should -BeExactly "preserve"
    }
    $receipt = Join-Path $root "ownership-unproven.json"
    (Test-Path -LiteralPath $receipt) | Should -Be (-not $blockedRoot -and -not $absentRoot)
    if (-not $blockedRoot -and -not $absentRoot) {
      (Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json).reason | Should -BeExactly "ownership_unproven"
    }
  }
  It "recognizes the Boolean tag through a native-method exception wrapper" {
    $inner = [InvalidOperationException]::new("unattested survivor")
    $inner.Data["GraphCodeValidationRootRetentionRequired"] = $true
    $outer = [InvalidOperationException]::new("wrapper", $inner)
    Test-ShellOwnershipUnproven $outer | Should -BeTrue
    $inner.Data["GraphCodeValidationRootRetentionRequired"] = "true"
    Test-ShellOwnershipUnproven $outer | Should -BeFalse
  }
  It "flushes first-failure evidence before the sentinel while preserving the actual ErrorRecord" -Tag "FirstFailureDiagnostic" {
    $exception = [ComponentModel.Win32Exception]::new(5, "controlled native refusal")
    $exception.Data["NativeResult"] = [uint32]4294967295
    try { throw $exception } catch { $original = $_ }
    Mock Write-Host {
      Test-Path (Join-Path $env:GRAPHCODE_VALIDATION_ROOT "ownership-first-failure.json") | Should -BeTrue
    } -ModuleName ShellProcessOwnership -ParameterFilter {
      $Object -eq "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven"
    }
    $returned = Set-ShellOwnershipUnproven $exception -FailureRecord $original
    [object]::ReferenceEquals($returned, $exception) | Should -BeTrue
    [object]::ReferenceEquals($returned.Data["GraphCodeValidationOriginalFailureRecord"], $original) | Should -BeTrue
    $evidence = Get-Content (Join-Path $root "ownership-first-failure.json") -Raw | ConvertFrom-Json
    $evidence.errorRecordAvailable | Should -BeTrue
    $evidence.exceptionChain[0].nativeErrorCode | Should -Be 5
    $evidence.availableFailureOperands.NativeResult | Should -Be 4294967295
    $evidence.scriptStackTrace | Should -BeExactly $original.ScriptStackTrace
    (Get-Content (Join-Path $root "ownership-unproven.json") -Raw | ConvertFrom-Json).reason | Should -BeExactly "ownership_unproven"
  }
  It "never overwrites the immutable first failure or replaces its primary on write refusal" -Tag "FirstFailureDiagnostic" {
    $path = Join-Path $root "ownership-first-failure.json"
    [IO.File]::WriteAllText($path, "original failure evidence")
    $before = (Get-FileHash $path).Hash
    $primary = [InvalidOperationException]::new("keep this primary")
    try { throw $primary } catch { $original = $_ }
    $returned = Set-ShellOwnershipUnproven $primary -FailureRecord $original
    [object]::ReferenceEquals($returned, $primary) | Should -BeTrue
    (Get-FileHash $path).Hash | Should -BeExactly $before
    $returned.Data["GraphCodeValidationFirstFailureDiagnosticFailure"] | Should -BeOfType ([Management.Automation.ErrorRecord])
    Test-Path (Join-Path $root "ownership-unproven.json") | Should -BeTrue
    Test-ShellOwnershipUnproven $returned | Should -BeTrue
  }
  It "reports absent records and native operands as unavailable without invented zeros" -Tag "FirstFailureDiagnostic" {
    $returned = Set-ShellOwnershipUnproven ([InvalidOperationException]::new("no native result"))
    $evidence = Get-Content (Join-Path $root "ownership-first-failure.json") -Raw | ConvertFrom-Json
    $evidence.errorRecordAvailable | Should -BeFalse
    $evidence.scriptStackTrace | Should -BeNullOrEmpty
    $evidence.nativeResultAvailable | Should -BeFalse
    $evidence.ownershipPredicateAvailable | Should -BeFalse
    $evidence.exceptionChain[0].nativeErrorCode | Should -BeNullOrEmpty
    $evidence.secondaryCleanupAvailable | Should -BeFalse
  }
  It "preserves all available aggregate branches and signed COM HRESULTs" -Tag "FirstFailureDiagnostic" {
    $primary = [AggregateException]::new("both branches", [Exception[]]@(
      [InvalidOperationException]::new("primary branch"),
      [Runtime.InteropServices.COMException]::new("cleanup branch", -2147467259)))
    $returned = Set-ShellOwnershipUnproven $primary
    [object]::ReferenceEquals($returned, $primary) | Should -BeTrue
    $evidence = Get-Content (Join-Path $root "ownership-first-failure.json") -Raw | ConvertFrom-Json
    $evidence.exceptionChain.Count | Should -Be 3
    $evidence.exceptionChain[1].message | Should -BeExactly "primary branch"
    $evidence.exceptionChain[2].message | Should -BeExactly "cleanup branch"
    $evidence.exceptionChain[2].exceptionHResult | Should -Be -2147467259
    $evidence.exceptionChain[2].nativeErrorAvailable | Should -BeFalse
    $evidence.innerChainTruncated | Should -BeFalse
  }
  It "preserves distinct primary and secondary cleanup records, stacks and native results" -Tag "FirstFailureDiagnostic" {
    function Invoke-PrimaryFailure { throw [ComponentModel.Win32Exception]::new(5, "primary assignment") }
    function Invoke-CleanupFailure { throw [ComponentModel.Win32Exception]::new(6, "secondary stop") }
    try { Invoke-PrimaryFailure } catch { $original = $_ }
    try { Invoke-CleanupFailure } catch { $cleanup = $_ }
    $original.Exception.Data["NativeResult"] = [uint32]11
    $cleanup.Exception.Data["NativeResult"] = [uint32]22
    $primary = [InvalidOperationException]::new("unchanged wrapper", $original.Exception)
    $returned = Set-ShellOwnershipUnproven $primary -FailureRecord $original -SecondaryCleanupFailureRecord $cleanup
    [object]::ReferenceEquals($returned, $primary) | Should -BeTrue
    [object]::ReferenceEquals($returned.InnerException, $original.Exception) | Should -BeTrue
    [object]::ReferenceEquals($returned.Data["GraphCodeValidationOriginalCleanupFailureRecord"], $cleanup) | Should -BeTrue
    $evidence = Get-Content (Join-Path $root "ownership-first-failure.json") -Raw | ConvertFrom-Json
    $evidence.primaryRecordExceptionMessage | Should -BeExactly "primary assignment"
    $evidence.secondaryCleanup.exceptionMessage | Should -BeExactly "secondary stop"
    $evidence.secondaryCleanup.label | Should -BeExactly "ACTUAL_SECONDARY_CLEANUP_ERROR_NOT_PRIMARY"
    $evidence.scriptStackTrace | Should -Not -BeExactly $evidence.secondaryCleanup.scriptStackTrace
    $first = @($evidence.exceptionChain | Where-Object path -CEQ "primary.inner")
    $second = @($evidence.exceptionChain | Where-Object path -CEQ "secondaryCleanup")
    $first.Count | Should -Be 1
    $second.Count | Should -Be 1
    $first[0].nativeErrorCode | Should -Be 5
    $second[0].nativeErrorCode | Should -Be 6
    $first[0].availableFailureOperands.NativeResult | Should -Be 11
    $second[0].availableFailureOperands.NativeResult | Should -Be 22
  }
  It "refuses oversized projection without replacing the primary or suppressing retention" -Tag "FirstFailureDiagnostic" {
    $primary = [InvalidOperationException]::new(("x" * 70000))
    $returned = Set-ShellOwnershipUnproven $primary
    [object]::ReferenceEquals($returned, $primary) | Should -BeTrue
    $returned.Data["GraphCodeValidationFirstFailureDiagnosticFailure"] | Should -Not -BeNullOrEmpty
    Test-Path (Join-Path $root "ownership-first-failure.json") | Should -BeFalse
    Test-Path (Join-Path $root "ownership-unproven.json") | Should -BeTrue
    Test-ShellOwnershipUnproven $returned | Should -BeTrue
  }
}
