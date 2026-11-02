[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
$path = Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'
$source = [IO.File]::ReadAllText($path)
$ast = Read-OwnershipProductionAst $path
function Find-ProductionFunction([string] $Name) {
    $nodes = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true))
    Assert-Ownership ($nodes.Count -eq 1) "Complete actual production function missing: $Name"
    return $nodes[0]
}
Invoke-OwnershipCase 'peer-emission' {
    $phase = Find-ProductionFunction 'Invoke-MultiProjectRenamePhase'
    $calls = @($phase.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Write-MultiProjectPeerReceipt'
    }, $true))
    Assert-Ownership ($calls.Count -eq 1 -and
        $calls[0].Extent.Text -ceq 'Write-MultiProjectPeerReceipt (Read-DaemonCommandLog $peerPath) $afterUnchanged' -and
        $phase.Extent.Text.IndexOf($calls[0].Extent.Text) -lt $phase.Extent.Text.IndexOf('multi-project shell rejected Exit') -and
        $phase.Extent.Text.IndexOf($calls[0].Extent.Text) -gt $phase.Extent.Text.IndexOf('$finalOverview = Wait-MultiProjectObservation "overview"')) 'Complete peer receipt is not uniquely bound to final owned file before teardown.'
    foreach ($token in @('UIA_MULTIPROJECT_PEER_RECEIPT=', 'owned-stub-final-file-read', 'rawJson', 'utf8Sha256',
        'Assert-MultiProjectCompleteReport', 'WarningAction Stop')) {
        Assert-Ownership ($source.Contains($token)) "Actual peer receipt route missing $token"
    }
}
Complete-OwnershipFamily 'ownership.legacy.peer-emission' 1 @('source-only')
Invoke-OwnershipCase 'rename-submit' {
    $caller = Find-ProductionFunction 'Invoke-MultiProjectNativeRename'
    Assert-Ownership ($caller.Extent.Text.Contains('Invoke-MultiProjectRenameAction') -and
        -not $caller.Extent.Text.Contains('Sketch-Submit') -and -not $caller.Extent.Text.Contains('Sketch-Cancel')) 'Rename routes through the wrong native form family.'
    $dialogs = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\WindowsNativeDialogs.zig'))
    $forms = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\NativeForms.zig'))
    Assert-Ownership ($dialogs -match 'const ok_id = 9800;' -and $dialogs -match 'const cancel_id = 9808;' -and
        $dialogs -match '9904 \+ index \* 8' -and $forms -match 'const ok_id = 1;') 'Independently sourced native Rename/Sketch control goldens changed.'
    foreach ($token in @('function Invoke-MultiProjectRenameAction', 'function Read-MultiProjectRenameField',
        'function Test-MultiProjectRenameField', 'UIA_MULTIPROJECT_RENAME_NATIVE_TARGET=',
        'UIA_MULTIPROJECT_RENAME_NATIVE_FAILURE=', 'UIA_MULTIPROJECT_RENAME_NATIVE_ACTION=',
        '$buttonId = if ($Cancel) { 9808 } else { 9800 }', 'ClientBounds', 'WorkBounds', 'topOwner', 'rectState',
        'hitSamples', 'beforeInput', 'enterFallbackUsed = $false', 'actualPriorButton1ReturnEstablished = $false',
        'Get-MultiProjectRenameTitle $owner.title', '-expectedTitle $renameTitle',
        ('Only the name changes ' + [char]0x2014 + ' the loop keeps its session, its edges, and its work.'))) {
        Assert-Ownership ($source.Contains($token)) "Actual strict Rename route missing $token"
    }
}
Complete-OwnershipFamily 'ownership.legacy.rename-submit' 1 @('source-only')
Invoke-OwnershipCase 'fresh-capture' {
    foreach ($token in @('function Read-MultiProjectElementCache', 'function Read-MultiProjectOwnershipSnapshot',
        'function ConvertTo-MultiProjectPropertyState', 'function Confirm-MultiProjectOwnedSnapshot',
        'UIA_MULTIPROJECT_FRESH_OWNERSHIP=', 'UIA_MULTIPROJECT_CACHED_OWNERSHIP=', 'UIA_MULTIPROJECT_CAPTURE_VERIFY=',
        'UIA_MULTIPROJECT_CONTAINER_OWNERSHIP=', 'UIA_MULTIPROJECT_SNAPSHOT_DRIFT=', 'priorStablePID', 'priorIdentity',
        'semanticCauseEstablished', 'wholeObservationDiscarded', '::ProcessIdProperty, $true',
        '::AutomationIdProperty, $true', '::NotSupported', 'row identity, not a graph publication generation')) {
        Assert-Ownership ($source.Contains($token)) "Actual fresh ownership capture missing $token"
    }
    $observer = Find-ProductionFunction 'Get-MultiProjectObservation'
    Assert-Ownership ($observer.Extent.Text -notmatch '\.Current\.(Name|BoundingRectangle|AutomationId)' -and
        $observer.Extent.Text.Contains('verifiedOwnedSnapshotCount') -and $observer.Extent.Text.Contains('Confirm-MultiProjectOwnedSnapshot') -and
        $observer.Extent.Text.Contains('graph container ownership unavailable before child capture') -and
        $observer.Extent.Text.Contains('projects container ownership unavailable before child capture')) 'Actual observer bypasses fresh/cached ownership or whole-observation container verification.'
}
Complete-OwnershipFamily 'ownership.legacy.fresh-capture' 1 @('source-only')
if ($script:OwnershipAdapterFailed) { exit 1 }
