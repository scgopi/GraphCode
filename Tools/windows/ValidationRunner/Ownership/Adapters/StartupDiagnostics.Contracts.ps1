[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath 'GraphCodeUiaHostInfo'
$gate = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
$names = @(
    'Protect-UiaStartupDiagnosticText', 'Get-UiaStartupDiagnosticValue', 'Get-UiaStartupFileDiagnostic',
    'Get-UiaStartupImageHash', 'Write-UiaStartupFailureDiagnostic', 'Get-UiaPrelaunchDiagnostics',
    'Get-UiaOwnedProcessDescendants', 'Stop-UiaOwnedProcessTrees', 'New-UiaOwnershipFailure',
    'Initialize-MultiProjectProcessJob', 'Initialize-UiaOwnedStreamCapture',
    'Start-MultiProjectOwnedProcess', 'Complete-MultiProjectCapture'
)
foreach ($name in $names) {
    Invoke-OwnershipCase $name {
        $definitions = @($gate.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true))
        Assert-Ownership ($definitions.Count -eq 1) "Required complete production startup helper missing or ambiguous: $name"
    }
}
Complete-OwnershipFamily 'ownership.ui-startup.helpers' 13 @('source-only')
. Import-OwnershipProductionFunctions $gate $names
$root = Join-Path $ArtifactRoot ('startup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$path = Join-Path $root 'capture.log'
[IO.File]::WriteAllText($path, "loader failed`npassword=private-canary`n")
Invoke-OwnershipCase 'redacted-log' {
    $diagnostic = Get-UiaStartupFileDiagnostic $path 'logs\shell-stderr.log'
    Assert-Ownership ($diagnostic.state -ceq 'available' -and $diagnostic.content -match 'loader failed' -and
        $diagnostic.content -notmatch 'private-canary' -and $diagnostic.readBytes -eq $diagnostic.lengthBytes) 'Actual startup file diagnostic lost output, redaction or full-read proof.'
}
Complete-OwnershipFamily 'ownership.ui-startup.redacted-log' 1
Invoke-OwnershipCase 'truncated-log' {
    $diagnostic = Get-UiaStartupFileDiagnostic $path 'logs\shell-stderr.log' 8
    Assert-Ownership ($diagnostic.state -ceq 'truncated' -and $diagnostic.readBytes -eq 8 -and
        $diagnostic.lengthBytes -gt 8) 'Actual diagnostic read exceeded or failed to report the eight-byte bound.'
}
Complete-OwnershipFamily 'ownership.ui-startup.truncated-log' 1
Invoke-OwnershipCase 'missing-log' {
    $diagnostic = Get-UiaStartupFileDiagnostic (Join-Path $root 'missing.log') 'logs\missing.log'
    Assert-Ownership ($diagnostic.state -ceq 'missing') 'Actual missing log was misclassified as empty or available.'
}
Complete-OwnershipFamily 'ownership.ui-startup.missing-log' 1
Invoke-OwnershipCase 'retained-report' {
    $logs = Join-Path $root 'logs'
    $support = Join-Path $root 'support'
    $null = New-Item -ItemType Directory -Path $logs, $support
    [IO.File]::WriteAllText((Join-Path $logs 'shell-stderr.log'), "loader failed`npassword=stderr-canary`n")
    [IO.File]::WriteAllText((Join-Path $logs 'shell-stdout.log'), 'child output captured')
    [IO.File]::WriteAllText((Join-Path $support 'graphcode-windows.log'), "app initialization failed`nsecret=app-canary`n")
    $self = Get-Process -Id $PID
    try { Write-UiaStartupFailureDiagnostic $self 0 $path $root $logs $support }
    finally { $self.Dispose() }
    $report = Get-Content -LiteralPath (Join-Path $logs 'startup-failure.json') -Raw | ConvertFrom-Json
    Assert-Ownership ($report.stderr.content -match 'loader failed' -and $report.stdout.content -match 'child output captured' -and
        $report.applicationLog.content -match 'app initialization failed' -and $report.stderr.content -notmatch 'stderr-canary' -and
        $report.applicationLog.content -notmatch 'app-canary') 'Actual retained report lost independent stderr/stdout/app logs or exposed canaries.'
}
Complete-OwnershipFamily 'ownership.ui-startup.retained-report' 1
Invoke-OwnershipCase 'pid-reuse' {
    $created = [datetime]::new(2026, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
    function Get-CimInstance {
        @(
            [pscustomobject]@{ ProcessId = 624; ParentProcessId = 7416; Name = 'conhost.exe'; ExecutablePath = ''; CreationDate = $created }
            [pscustomobject]@{ ProcessId = 700; ParentProcessId = 624; Name = 'child.exe'; ExecutablePath = ''; CreationDate = $created.AddSeconds(5) }
            [pscustomobject]@{ ProcessId = 636; ParentProcessId = 624; Name = 'csrss.exe'; ExecutablePath = ''; CreationDate = $created.AddHours(-3) }
            [pscustomobject]@{ ProcessId = 732; ParentProcessId = 636; Name = 'wininit.exe'; ExecutablePath = ''; CreationDate = $created.AddHours(-2) }
        )
    }
    function Stop-Process { throw 'Advisory traversal must not terminate anything.' }
    function Get-Process { throw 'Advisory traversal must not reopen an observed PID.' }
    $names = @(Get-UiaOwnedProcessDescendants @(624) | ForEach-Object Name)
    Assert-Ownership (($names -join ',') -ceq 'child.exe') 'Advisory traversal adopted a process predating its reused parent generation.'
}
Complete-OwnershipFamily 'ownership.ui-process-tree.pid-reuse' 1
if ($script:OwnershipAdapterFailed) { exit 1 }
