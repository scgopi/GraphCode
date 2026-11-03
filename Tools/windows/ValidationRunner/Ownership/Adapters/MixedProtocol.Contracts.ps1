[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
foreach ($file in @('Stub-Daemon.ps1', 'uia-live-gate.ps1')) {
    $ast = Read-OwnershipProductionAst (Join-Path $RepositoryRoot "Tools\windows\$file")
    $names = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            ($node.Name -like '*-MultiProject*' -or $node.Name -ceq 'ConvertTo-SketchCanonicalJson')
    }, $true) | ForEach-Object Name)
    . Import-OwnershipProductionFunctions $ast $names
}
$root = Join-Path $env:TEMP ('mixed-protocol-' + [guid]::NewGuid().ToString('N'))
$alpha = Join-Path $root 'Alpha'
$beta = Join-Path $root 'Beta'
$null = New-Item -ItemType Directory -Path $alpha, $beta
$alphaId = '11111111-1111-4111-8111-111111111111'
$betaId = '22222222-2222-4222-8222-222222222222'
$listId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$renameId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$token = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
function New-ProtocolBaseline {
    $peer = New-MultiProjectPeer $alpha $beta
    $list = [ordered]@{ version = 2; kind = 'request'; requestID = $listId; command = [ordered]@{ listRecentProjects = [ordered]@{} } }
    $reply = Invoke-MultiProjectRequest $peer $list
    Complete-MultiProjectResponse $peer $reply.response
    foreach ($path in @($alpha, $beta)) {
        Complete-MultiProjectPublication $peer (New-MultiProjectPublication $peer $path) 'initial' $listId
    }
    return $peer
}
function New-ProtocolRequest([string] $Title = 'Alpha renamed') {
    return [ordered]@{ version = 2; kind = 'request'; requestID = $renameId; command = [ordered]@{
        graphCommand = [ordered]@{ projectPath = $alpha; command = [ordered]@{
            renameNode = [ordered]@{ _0 = $alphaId; title = $Title }
        } }
    } }
}
function New-ProtocolControl {
    return [ordered]@{ token = $token; projectPath = $alpha; nodeID = $alphaId; title = 'Alpha interleaved'; selection = [ordered]@{
        projectPath = $beta; nodeID = $betaId; source = 'synthetic-client'
    } }
}
function Assert-ProtocolRejected([scriptblock] $Action, [string] $Prefix) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-Ownership ($failure -and $failure.Exception.Message.StartsWith($Prefix, [StringComparison]::Ordinal)) "Expected specific production protocol rejection $Prefix"
}
function Get-RenamedProtocolSnapshots([string] $Title = 'Alpha renamed') {
    $peer = New-ProtocolBaseline
    $before = Get-MultiProjectPeerSnapshot $peer
    $reply = Invoke-MultiProjectRequest $peer (New-ProtocolRequest $Title)
    Complete-MultiProjectResponse $peer $reply.response
    Complete-MultiProjectPublication $peer (New-MultiProjectPublication $peer $alpha) 'rename' $renameId
    return @{ before = $before; after = (Get-MultiProjectPeerSnapshot $peer) }
}
Invoke-OwnershipCase 'two-positive-owner-publications' {
    $snapshot = Get-MultiProjectPeerSnapshot (New-ProtocolBaseline)
    Assert-Ownership ($snapshot.requestCount -eq 1 -and $snapshot.responseCount -eq 1 -and $snapshot.graphSequence -eq 2 -and
        $snapshot.graphs.Count -eq 2 -and $snapshot.graphs[0].project.path -ceq $alpha -and $snapshot.graphs[1].project.path -ceq $beta -and
        $snapshot.graphs[0].nodes[0].id -ceq $alphaId -and $snapshot.graphs[1].nodes[0].id -ceq $betaId) 'Positive owner/UUID/count/sequence fixture changed.'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3353' 1 @('request-response-publication')
Invoke-OwnershipCase 'whole-correlated-rename' {
    $snapshots = Get-RenamedProtocolSnapshots
    Assert-Ownership ((Test-MultiProjectRenameReceipt $snapshots.before $snapshots.after $alpha $alphaId 'Alpha renamed') -and
        $snapshots.after.graphs[1].nodes[0].title -ceq 'Beta loop') 'Exact rename receipt was rejected or mutated Beta.'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3368' 1 @('request-response-publication')
Invoke-OwnershipCase 'one-shot-interleaved-event' {
    $peer = New-ProtocolBaseline
    $frame = Invoke-MultiProjectPublicationControl $peer (New-ProtocolControl)
    Complete-MultiProjectPublication $peer $frame 'control' $token
    $snapshot = Get-MultiProjectPeerSnapshot $peer
    Assert-Ownership ($snapshot.requestCount -eq 1 -and $snapshot.responseCount -eq 1 -and $snapshot.appliedCount -eq 0 -and
        $snapshot.graphSequence -eq 3 -and $snapshot.graphs[1].nodes[0].title -ceq 'Beta loop') 'Synthetic selection control invented requests or mutated another owner.'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3373' 1 @('request-response-publication')
Invoke-OwnershipCase 'unchanged-title-dispatch' {
    $snapshots = Get-RenamedProtocolSnapshots 'Alpha loop'
    Assert-Ownership (Test-MultiProjectRenameReceipt $snapshots.before $snapshots.after $alpha $alphaId 'Alpha loop') 'Unchanged-title dispatch was suppressed.'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3383' 1 @('request-response-publication')
foreach ($foreign in @($false, $true)) {
    Invoke-OwnershipCase "resume-foreign-$foreign" {
        $peer = New-ProtocolBaseline
        $before = ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $peer)
        $graphs = ConvertTo-MultiProjectCanonicalJson $peer.graphs
        $request = New-ProtocolRequest
        $request.command.graphCommand.command = [ordered]@{ resumeSession = [ordered]@{ _0 = $(if ($foreign) { $betaId } else { $alphaId }) } }
        if ($foreign) {
            Assert-ProtocolRejected { Invoke-MultiProjectRequest $peer $request } 'MULTIPROJECT_OWNER'
            Assert-Ownership ((ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $peer)) -ceq $before) 'Rejected foreign session mutated peer state.'
        } else {
            $reply = Invoke-MultiProjectRequest $peer $request
            Assert-Ownership ($reply.response.success -eq $true -and $null -eq $reply.publishPath -and $peer.applied.Count -eq 0 -and
                (ConvertTo-MultiProjectCanonicalJson $peer.graphs) -ceq $graphs) 'Resume acknowledgement changed the graph or launched a publication.'
        }
    }
    Complete-OwnershipFamily $(if ($foreign) { 'ownership.mixed-protocol.source-line-3908' } else { 'ownership.mixed-protocol.source-line-3897' }) 1 @('request-response-publication')
}
foreach ($mutation in @('owner', 'node', 'missing', 'extra', 'type', 'version', 'boolean', 'requestID', 'blank')) {
    Invoke-OwnershipCase $mutation {
        $peer = New-ProtocolBaseline
        $before = ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $peer)
        $request = New-ProtocolRequest
        $prefix = 'MULTIPROJECT_SCHEMA'
        switch ($mutation) {
            'owner' { $request.command.graphCommand.projectPath = $beta; $prefix = 'MULTIPROJECT_OWNER' }
            'node' { $request.command.graphCommand.command.renameNode._0 = $betaId; $prefix = 'MULTIPROJECT_OWNER' }
            'missing' { $request.command.graphCommand.command.renameNode.Remove('title') }
            'extra' { $request.command.graphCommand.command.renameNode.extra = 1 }
            'type' { $request.command.graphCommand.command.renameNode.title = 7; $prefix = 'MULTIPROJECT_TYPE' }
            'version' { $request.version = '2'; $prefix = 'MULTIPROJECT_TYPE' }
            'boolean' { $request.version = $true; $prefix = 'MULTIPROJECT_TYPE' }
            'requestID' { $request.requestID = 'bad'; $prefix = 'MULTIPROJECT_UUID' }
            'blank' { $request.command.graphCommand.command.renameNode.title = '  '; $prefix = 'MULTIPROJECT_TITLE' }
        }
        Assert-ProtocolRejected { Invoke-MultiProjectRequest $peer $request } $prefix
        Assert-Ownership ((ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $peer)) -ceq $before) 'Rejected request mutated peer state.'
    }
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3930' 9 @('request-response-publication')
foreach ($json in @('{', '{"x":1,"x":2}', '[]')) {
    Invoke-OwnershipCase $json { Assert-ProtocolRejected { ConvertFrom-MultiProjectJson $json } 'MULTIPROJECT_JSON' }
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3941' 3 @('request-response-publication')
Invoke-OwnershipCase 'duplicate-request' {
    $peer = New-ProtocolBaseline
    $null = Invoke-MultiProjectRequest $peer (New-ProtocolRequest)
    Assert-ProtocolRejected { Invoke-MultiProjectRequest $peer (New-ProtocolRequest) } 'MULTIPROJECT_DUPLICATE'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3943' 1 @('request-response-publication')
Invoke-OwnershipCase 'unanswered-publication' {
    $peer = New-ProtocolBaseline
    $null = Invoke-MultiProjectRequest $peer (New-ProtocolRequest)
    Assert-ProtocolRejected { Complete-MultiProjectPublication $peer (New-MultiProjectPublication $peer $alpha) 'rename' $renameId } 'MULTIPROJECT_UNANSWERED'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3948' 1 @('request-response-publication')
foreach ($mutation in @('owner', 'selection', 'extra', 'type', 'duplicate', 'second')) {
    Invoke-OwnershipCase $mutation {
        $peer = New-ProtocolBaseline
        $control = New-ProtocolControl
        $prefix = 'MULTIPROJECT_OWNER'
        switch ($mutation) {
            'owner' { $control.projectPath = $beta; $control.nodeID = $betaId }
            'selection' { $control.selection.nodeID = $alphaId; $prefix = 'MULTIPROJECT_SELECTION' }
            'extra' { $control.extra = 1; $prefix = 'MULTIPROJECT_SCHEMA' }
            'type' { $control.title = 7; $prefix = 'MULTIPROJECT_TYPE' }
            'duplicate' { $null = Invoke-MultiProjectPublicationControl $peer $control; $prefix = 'MULTIPROJECT_DUPLICATE' }
            'second' { $null = Invoke-MultiProjectPublicationControl $peer $control; $control.token = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; $prefix = 'MULTIPROJECT_ONE_SHOT' }
        }
        $before = ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $peer)
        Assert-ProtocolRejected { Invoke-MultiProjectPublicationControl $peer $control } $prefix
        Assert-Ownership ((ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $peer)) -ceq $before) 'Rejected control mutated peer state.'
    }
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3954' 6 @('request-response-publication')
foreach ($mutation in @('unknown', 'extra', 'type', 'duplicate')) {
    Invoke-OwnershipCase $mutation {
        $peer = New-ProtocolBaseline
        $response = (Invoke-MultiProjectRequest $peer (New-ProtocolRequest)).response
        $prefix = 'MULTIPROJECT_CORRELATION'
        switch ($mutation) {
            'unknown' { $response.requestID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' }
            'extra' { $response.extra = 1; $prefix = 'MULTIPROJECT_SCHEMA' }
            'type' { $response.success = 'true'; $prefix = 'MULTIPROJECT_TYPE' }
            'duplicate' { Complete-MultiProjectResponse $peer $response; $prefix = 'MULTIPROJECT_DUPLICATE' }
        }
        Assert-ProtocolRejected { Complete-MultiProjectResponse $peer $response } $prefix
    }
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3973' 4 @('request-response-publication')
foreach ($mutation in @('value', 'missing', 'type', 'extra', 'requestID', 'unanswered', 'sequence', 'publicationExtra', 'answerType', 'zero')) {
    Invoke-OwnershipCase $mutation {
        $snapshots = Get-RenamedProtocolSnapshots
        $after = Copy-MultiProjectValue $snapshots.after
        switch ($mutation) {
            'value' { $after.received[-1].frame.command.graphCommand.command.renameNode.title = 'wrong' }
            'missing' { $after.received[-1].frame.command.graphCommand.command.renameNode.Remove('title') }
            'type' { $after.appliedCount = '1' }
            'extra' { $after.received[-1].frame.command.graphCommand.extra = 1 }
            'requestID' { $after.answered[-1].requestID = $listId }
            'unanswered' { $after.unansweredRequests = @($renameId) }
            'sequence' { $after.publications[-1].frame.sequence = '3' }
            'publicationExtra' { $after.publications[-1].frame.extra = 1 }
            'answerType' { $after.answered[-1].response.success = 1 }
            'zero' { $after.publicationCount = 0 }
        }
        Assert-Ownership (-not (Test-MultiProjectRenameReceipt $snapshots.before $after $alpha $alphaId 'Alpha renamed')) 'Canonical receipt negative was accepted.'
    }
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3988' 10 @('receipt-negative-controls')
Invoke-OwnershipCase 'visible-intersection' {
    $clipped = Get-MultiProjectClippedRectangle @(100, 100, 400, 400) @(220, 34, 1200, 250)
    Assert-Ownership (($clipped -join ',') -ceq '220,100,400,250') 'Actual clipping did not retain the literal visible intersection.'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3889' 1 @('mixed-ui-policy')
Invoke-OwnershipCase 'offscreen-target-refused' {
    Assert-ProtocolRejected { Get-MultiProjectClippedRectangle @(0, 0, 50, 50) @(220, 34, 1200, 900) } 'MULTIPROJECT_BOUNDS'
}
Complete-OwnershipFamily 'ownership.mixed-protocol.source-line-3894' 1 @('mixed-ui-policy')
if ($script:OwnershipAdapterFailed) { exit 1 }
