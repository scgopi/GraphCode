[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
$gate = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
. Import-OwnershipProductionFunctions $gate @('Invoke-MultiProjectTypeText', 'Get-MultiProjectRetentionError', 'Get-EdgeTextAttemptDecision')
Invoke-OwnershipCase 'actual-caller-five-records-before-fifth-guard' {
    $caller = $gate.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-MultiProjectNativeRename'
    }, $true)
    $assignment = $caller.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Extent.Text.StartsWith('$null = Invoke-MultiProjectTypeText 9904 $typedTitle $inputEvidence -typeSource', [StringComparison]::Ordinal)
    }, $true)
    Assert-Ownership ($null -ne $assignment) 'Actual streaming Rename caller binding missing.'
    $state = @{ calls = 0; primary = $null }
    function Invoke-MultiProjectSequencedEdit {
        param($modal, $processId, $prefill, $text)
        $state.calls++
        foreach ($attempt in 1..5) {
            Write-Host "UIA_EDGE_TEXT_STABLE id=9904 attempt=$attempt after='' expected='$text' inputAttempted=False textSent=0/0"
            $null = Get-EdgeTextAttemptDecision $true '' $text $attempt 5
        }
    }
    $typedTitle = '   '; $modal = [IntPtr]42; $multiProcess = [pscustomobject]@{ Id = 4242 }; $prefill = 'Alpha renamed'
    $inputEvidence = [Collections.Generic.List[string]]::new()
    $records = @(& {
        try { . ([scriptblock]::Create($assignment.Extent.Text)) } catch { $state.primary = $_ }
    } 6>&1)
    $attempts = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] -and
        ([string]$_.MessageData).StartsWith('UIA_EDGE_TEXT_STABLE ', [StringComparison]::Ordinal) })
    Assert-Ownership ($state.calls -eq 1 -and $attempts.Count -eq 5 -and $inputEvidence.Count -eq 5 -and
        $state.primary.Exception.Message -ceq "edge text mismatch attempts=5/5 expected='   ' observed=''") 'Actual caller replayed input, lost produced records, or changed the fifth guard.'
}
Complete-OwnershipFamily 'ownership.mixed-stream.source-line-2193' 1 @('powershell-streams-error-identity')
foreach ($scenario in @('focus-not-acquired', 'native-false-clear-only', 'native-false-full-six-empty',
    'partial-counts', 'stale-control', 'native-error', 'exact-three-spaces')) {
    Invoke-OwnershipCase $scenario {
        . Import-OwnershipProductionFunctions $gate @('Require', 'Edge-TypeText', 'Get-EdgeTextAttemptDecision') @{
            '[GraphCodeUiaGateState]::' = '$transport.'
        }
        $transport = [pscustomobject]@{
            scenario = $scenario; buffer = ''; focus = [IntPtr]::Zero; calls = 0
            LastEditClearExpected = [uint32]0; LastEditClearSent = [uint32]0
            LastEditTextExpected = [uint32]0; LastEditTextSent = [uint32]0
        }
        $transport | Add-Member ScriptMethod EditTextById { param($window, $id) $this.buffer }
        $transport | Add-Member ScriptMethod ControlById {
            param($window, $id)
            if ($this.scenario -ceq 'stale-control') { return [IntPtr]::Zero }
            return [IntPtr]$id
        }
        $transport | Add-Member ScriptMethod WindowBounds { param($window) @(10, 20, 510, 44) }
        $transport | Add-Member ScriptMethod IsControlOwnedBy { param($window, $control, $id) $control -eq [IntPtr]$id }
        $transport | Add-Member ScriptMethod HasVisibleBounds { param($control) $control -ne [IntPtr]::Zero }
        $transport | Add-Member ScriptMethod WindowIsVisible { param($window) $true }
        $transport | Add-Member ScriptMethod WindowTextOf { param($window) ('Rename ' + [char]0x201c + 'Alpha renamed' + [char]0x201d) }
        $transport | Add-Member ScriptMethod WindowProcessId { param($window) 4242 }
        $transport | Add-Member ScriptMethod ControlIdOf { param($window) [int]$window.ToInt64() }
        $transport | Add-Member ScriptMethod FocusedControlInDialog { param($window) $this.focus }
        $transport | Add-Member ScriptMethod FocusControl { param($window, $control) $this.focus = $control; $true }
        $transport | Add-Member ScriptMethod TypeEditTextById {
            param($window, $id, $text)
            $this.calls++
            if ($this.scenario -ceq 'native-error') { throw 'controlled original native adapter error' }
            $this.LastEditClearExpected = [uint32]2; $this.LastEditClearSent = [uint32]2
            $this.LastEditTextExpected = [uint32]0; $this.LastEditTextSent = [uint32]0
            if ($this.scenario -ceq 'partial-counts') { $this.LastEditClearSent = [uint32]1; return $false }
            if ($this.scenario -in @('native-false-full-six-empty', 'exact-three-spaces')) {
                $this.LastEditTextExpected = [uint32]6; $this.LastEditTextSent = [uint32]6
            }
            if ($this.scenario -ceq 'exact-three-spaces') { $this.buffer = $text; return $true }
            return $false
        }
        function Ensure-ShellForeground { param($window, $label) $scenario -cne 'focus-not-acquired' }
        function Start-Sleep { param($Milliseconds) }
        $renameProcess = [pscustomobject]@{ Id = 4242 }
        $renameProcess | Add-Member ScriptMethod WaitForInputIdle { param($timeout) $true }
        $script:edgeWorkflowWindow = [IntPtr]42
        $script:edgeWorkflowTitle = 'Rename ' + [char]0x201c + 'Alpha renamed' + [char]0x201d
        $evidence = [Collections.Generic.List[string]]::new()
        $state = @{ sourceCalls = 0; primary = $null }
        $records = @(& {
            try {
                $null = Invoke-MultiProjectTypeText 9904 '   ' $evidence -typeSource {
                    param($id, $text) $state.sourceCalls++; Edge-TypeText $id $text
                }
            } catch { $state.primary = $_ }
        } 6>&1)
        $attempts = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] -and
            ([string]$_.MessageData).StartsWith('UIA_EDGE_TEXT_STABLE ', [StringComparison]::Ordinal) })
        Assert-Ownership ($state.sourceCalls -eq 1) 'Stream collector replayed the actual native helper.'
        switch ($scenario) {
            'exact-three-spaces' {
                Assert-Ownership ($attempts.Count -eq 1 -and $evidence.Count -eq 1 -and $transport.calls -eq 1 -and
                    -not $state.primary -and $transport.buffer -ceq '   ') 'Exact whitespace was coerced or the input source repeated.'
            }
            { $_ -in @('focus-not-acquired', 'native-false-clear-only', 'native-false-full-six-empty') } {
                Assert-Ownership ($attempts.Count -eq 5 -and $evidence.Count -eq 5 -and
                    $state.primary.Exception.Message -ceq "edge text mismatch attempts=5/5 expected='   ' observed=''" -and
                    $transport.calls -eq $(if ($scenario -ceq 'focus-not-acquired') { 0 } else { 5 })) 'Fifth guard or actual input/produced evidence counts changed.'
                if ($scenario -ceq 'native-false-clear-only') {
                    Assert-Ownership (([string]$attempts[-1].MessageData).Contains('textSent=0/0') -and
                        ([string]$attempts[-1].MessageData).Contains('inputCountsFull=True')) 'Clear-only input availability was mislabeled.'
                }
            }
            'partial-counts' {
                Assert-Ownership ($attempts.Count -eq 0 -and $transport.calls -eq 1 -and
                    $state.primary.Exception.Message.Contains('SendInput count mismatch')) 'Partial count primary was weakened.'
            }
            'stale-control' {
                Assert-Ownership ($attempts.Count -eq 0 -and $transport.calls -eq 0 -and
                    $state.primary.Exception.Message.Contains('unavailable after layout wait')) 'Stale control guard was bypassed.'
            }
            'native-error' {
                Assert-Ownership ($attempts.Count -eq 0 -and $transport.calls -eq 1 -and
                    $state.primary.Exception.ToString().Contains('controlled original native adapter error')) 'Native failure was replaced or input replayed.'
            }
        }
    }
}
Complete-OwnershipFamily 'ownership.mixed-stream.source-line-2221' 7 @('powershell-streams-error-identity')
foreach ($mode in @('source-primary', 'source-plus-sink', 'sink-only')) {
    Invoke-OwnershipCase $mode {
        $state = @{ calls = 0; produced = 0; sinks = 0; failure = $null }
        $evidence = [Collections.Generic.List[string]]::new()
        $null = @(& {
            try {
                $null = Invoke-MultiProjectTypeText 9904 '   ' $evidence -typeSource {
                    param($id, $text)
                    $state.calls++
                    foreach ($attempt in 1..5) {
                        $state.produced++
                        Write-Host "UIA_EDGE_TEXT_STABLE id=$id attempt=$attempt textSent=0/0"
                        Assert-Ownership ($state.sinks -eq $state.produced) 'Record was not forwarded synchronously before the next source step.'
                    }
                    if ($mode -cne 'sink-only') { throw 'controlled unchanged primary' }
                } -recordSink {
                    param($message)
                    $state.sinks++
                    if ($mode -cne 'source-primary') { throw 'controlled retention sink failure' }
                    Write-Host $message
                }
            } catch { $state.failure = $_ }
        } 6>&1)
        Assert-Ownership ($state.calls -eq 1 -and $state.produced -eq 5 -and $state.sinks -eq 5 -and
            $evidence.Count -eq 5 -and $state.failure) 'Source/sink failures replayed or lost produced evidence.'
        if ($mode -ceq 'sink-only') {
            Assert-Ownership ($state.failure.Exception.Message.StartsWith('MULTIPROJECT_INPUT_RETENTION:', [StringComparison]::Ordinal)) 'A sink-only failure returned success.'
        } else {
            Assert-Ownership ($state.failure.Exception.Message -ceq 'controlled unchanged primary') 'The primary failure changed.'
            if ($mode -ceq 'source-plus-sink') {
                Assert-Ownership (@($state.failure.Exception.Data['MultiProjectInputRetention']).Count -eq 5) 'Secondary retention failures were lost.'
            }
        }
    }
}
Complete-OwnershipFamily 'ownership.mixed-stream.source-line-2305' 3 @('powershell-streams-error-identity')
Invoke-OwnershipCase 'exact-primary-exception-object' {
    $original = [InvalidOperationException]::new('exact original exception')
    $state = @{ calls = 0; failure = $null }
    $evidence = [Collections.Generic.List[string]]::new()
    try {
        $null = Invoke-MultiProjectTypeText 9904 '   ' $evidence -typeSource {
            param($id, $text)
            $state.calls++
            Write-Host 'UIA_EDGE_TEXT_STABLE id=9904 attempt=1 textSent=0/0'
            throw $original
        }
    } catch { $state.failure = $_ }
    Assert-Ownership ($state.calls -eq 1 -and [Object]::ReferenceEquals($state.failure.Exception, $original) -and $evidence.Count -eq 1) 'The identical original exception was not retained.'
}
Complete-OwnershipFamily 'ownership.mixed-stream.source-line-2342' 1 @('powershell-streams-error-identity')
foreach ($faults in @('attempt', 'summary', 'attempt-summary', 'attempt-warning', 'summary-warning', 'attempt-summary-warning')) {
    Invoke-OwnershipCase $faults {
        $original = [InvalidOperationException]::new('original fifth/native primary')
        $state = @{ calls = 0; records = 0; summaries = 0; warnings = 0; failure = $null }
        $evidence = [Collections.Generic.List[string]]::new()
        try {
            $null = Invoke-MultiProjectTypeText 9904 '   ' $evidence -typeSource {
                param($id, $text)
                $state.calls++
                foreach ($attempt in 1..5) { Write-Host "UIA_EDGE_TEXT_STABLE id=9904 attempt=$attempt textSent=0/0" }
                throw $original
            } -recordSink {
                param($message)
                $state.records++
                if ($faults.Contains('attempt')) { throw [IO.IOException]::new('attempt writer IO') }
                Write-Host $message
            } -failureSink {
                param($message)
                $state.summaries++
                if ($faults.Contains('summary')) { throw [IO.IOException]::new('summary writer IO') }
                Write-Host $message
            } -warningSink {
                param($message)
                $state.warnings++
                if ($faults.Contains('warning')) { throw [IO.IOException]::new('warning writer IO') }
            }
        } catch { $state.failure = $_ }
        $secondary = @($state.failure.Exception.Data['MultiProjectInputRetention'])
        $expected = $(if ($faults.Contains('attempt')) { 5 } else { 0 }) +
            $(if ($faults.Contains('summary')) { 1 } else { 0 }) + $(if ($faults.Contains('warning')) { 1 } else { 0 })
        Assert-Ownership ([Object]::ReferenceEquals($state.failure.Exception, $original) -and
            $state.failure.Exception.Message -ceq 'original fifth/native primary' -and $state.calls -eq 1 -and
            $state.records -eq 5 -and $state.summaries -eq 1 -and $state.warnings -eq 1 -and $evidence.Count -eq 5 -and
            $secondary.Count -eq $expected) 'Production catch lost primary identity, typed diagnostics, attempt records or replayed source.'
        foreach ($error in $secondary) {
            Assert-Ownership ($error.operation -in @('attempt-record', 'failure-summary', 'warning') -and
                $error.errorType -ceq 'System.IO.IOException' -and $error.hresult -is [int] -and
                $error.message.Contains('writer IO')) 'Secondary writer failure lost its operation/type/HResult/message.'
        }
    }
}
Complete-OwnershipFamily 'ownership.mixed-stream.source-line-2359' 6 @('powershell-streams-error-identity')
if ($script:OwnershipAdapterFailed) { exit 1 }
