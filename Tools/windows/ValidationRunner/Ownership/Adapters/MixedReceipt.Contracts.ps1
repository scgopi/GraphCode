[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
$gate = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
$names = @($gate.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        ($node.Name -like '*-MultiProject*' -or $node.Name -ceq 'ConvertTo-SketchCanonicalJson')
}, $true) | ForEach-Object Name)
. Import-OwnershipProductionFunctions $gate $names
$bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\Fixtures\accepted-peer-91dc.json'))
$expectedHash = '361883611D172E3A884A3F6CBCD5918EBACB94F531DDDF921627B5E36A706241'
Assert-Ownership ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ceq $expectedHash) 'Accepted data-only peer fixture changed.'
$fixture = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
function New-ReceiptReport { return ConvertFrom-MultiProjectReceiptJson $fixture }
function Assert-ReceiptRejected([scriptblock] $Action) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-Ownership ($failure -and $failure.Exception.Message.StartsWith('MULTIPROJECT_PEER_RECEIPT:', [StringComparison]::Ordinal)) 'Actual complete receipt validator did not specifically reject invalid evidence.'
}
Invoke-OwnershipCase 'accepted-whole-file' {
    $report = New-ReceiptReport
    $records = @(Write-MultiProjectPeerReceipt $fixture $report.multiProjectPeer 6>&1)
    $information = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] })
    Assert-Ownership ($information.Count -eq 1) 'Whole accepted peer file did not produce exactly one receipt.'
    $receipt = Read-MultiProjectPeerReceipt ([string]$information[0].MessageData)
    Assert-Ownership ($receipt.utf8Sha256 -ceq $expectedHash -and $receipt.rawJson -ceq $fixture -and
        $receipt.report.protocolConnected -and $receipt.report.correlatedRequests -and
        $receipt.report.multiProjectPeer.received.Count -eq 11 -and $receipt.report.multiProjectPeer.answered.Count -eq 11 -and
        $receipt.report.multiProjectPeer.applied.Count -eq 2 -and $receipt.report.multiProjectPeer.publications.Count -eq 7 -and
        $receipt.report.multiProjectPeer.controls.Count -eq 1) 'Actual receipt lost original bytes, custody, complete correlations or peer state.'
}
Complete-OwnershipFamily 'ownership.mixed-receipt.source-line-2411' 1 @('accepted-91dc-fixture-not-product-runtime')
function New-ReceiptWithResume {
    $report = New-ReceiptReport
    $peer = $report.multiProjectPeer
    $owner = $peer.graphs[1]
    $id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    $response = [ordered]@{ version = 2; kind = 'response'; requestID = $id; success = $true }
    $frame = [ordered]@{ version = 2; kind = 'request'; requestID = $id; command = [ordered]@{
        graphCommand = [ordered]@{ projectPath = $owner.project.path; command = [ordered]@{
            resumeSession = [ordered]@{ _0 = $owner.nodes[0].id }
        } }
    } }
    $peer.received += [ordered]@{ requestID = $id; frame = $frame; expectedResponse = $response }
    $peer.answered += [ordered]@{ requestID = $id; response = $response }
    $peer.receivedCount++; $peer.requestCount++; $peer.responseCount++
    $report.requestCount++; $report.responseCount++
    $report.commands += 'graphCommand'
    return $report
}
Invoke-OwnershipCase 'correlated-nonmutating-session' {
    $report = New-ReceiptWithResume
    Assert-MultiProjectCompleteReport $report
    Assert-Ownership ($report.multiProjectPeer.applied.Count -eq 2) 'Resume acknowledgement changed rename accounting.'
}
Complete-OwnershipFamily 'ownership.mixed-receipt.source-line-2439' 1 @('request-response-publication')
Invoke-OwnershipCase 'foreign-session-owner' {
    $report = New-ReceiptWithResume
    $report.multiProjectPeer.received[-1].frame.command.graphCommand.command.resumeSession._0 = $report.multiProjectPeer.graphs[0].nodes[0].id
    Assert-ReceiptRejected { Assert-MultiProjectCompleteReport $report }
}
Complete-OwnershipFamily 'ownership.mixed-receipt.source-line-2445' 1 @('request-response-publication')
$mutations = @(
    'missing-top', 'unknown-top', 'disconnected', 'correlation-false', 'global-error', 'global-unanswered',
    'root-count', 'connection-type', 'graph-not-sent', 'missing-peer', 'unknown-peer', 'count-type', 'count-missing',
    'unanswered', 'empty-requests', 'request-duplicate', 'request-id', 'request-kind-type', 'request-extra',
    'unknown-verb', 'wrong-owner', 'wrong-node', 'rename-title-type', 'missing-expectation',
    'answer-duplicate', 'answer-missing', 'answer-id', 'answer-kind', 'answer-success', 'answer-type', 'quick-chat-extra',
    'application-owner', 'application-node', 'application-title', 'application-before', 'application-duplicate',
    'publication-sequence', 'publication-kind-type', 'publication-owner', 'publication-title', 'publication-correlation',
    'publication-duplicate', 'unknown-cause', 'control-owner', 'control-selection', 'control-token',
    'graph-missing', 'graph-duplicate', 'graph-title', 'graph-id', 'graph-depth-loss'
)
foreach ($mutation in $mutations) {
    Invoke-OwnershipCase $mutation {
        $report = New-ReceiptReport
        $peer = $report.multiProjectPeer
        switch ($mutation) {
            'missing-top' { $report.Remove('protocolConnected') }
            'unknown-top' { $report.unexpected = $true }
            'disconnected' { $report.protocolConnected = $false }
            'correlation-false' { $report.correlatedRequests = $false }
            'global-error' { $report.error = 'actual error' }
            'global-unanswered' { $report.unansweredRequests = @('unanswered') }
            'root-count' { $report.requestCount++ }
            'connection-type' { $report.connectionCount = '2' }
            'graph-not-sent' { $report.graphSent = $false }
            'missing-peer' { $report.multiProjectPeer = $null }
            'unknown-peer' { $peer.unexpected = $true }
            'count-type' { $peer.requestCount = '11' }
            'count-missing' { $peer.Remove('receivedCount') }
            'unanswered' { $peer.unansweredRequests = @($peer.received[0].requestID) }
            'empty-requests' { $peer.received = @() }
            'request-duplicate' { $peer.received[1] = $peer.received[0] }
            'request-id' { $peer.received[0].frame.requestID = 'wrong' }
            'request-kind-type' { $peer.received[0].frame.kind = $true }
            'request-extra' { $peer.received[0].frame.extra = 1 }
            'unknown-verb' { $peer.received[0].frame.command = @{ unknown = @{} } }
            'wrong-owner' { $peer.received[-1].frame.command.graphCommand.projectPath = $peer.graphs[1].project.path }
            'wrong-node' { $peer.received[-1].frame.command.graphCommand.command.renameNode._0 = $peer.graphs[1].nodes[0].id }
            'rename-title-type' { $peer.received[-1].frame.command.graphCommand.command.renameNode.title = 7 }
            'missing-expectation' { $peer.received[-1].expectedResponse = $null }
            'answer-duplicate' { $peer.answered[1] = $peer.answered[0] }
            'answer-missing' { $peer.answered = @($peer.answered[0]) }
            'answer-id' { $peer.answered[-1].response.requestID = $peer.answered[0].requestID }
            'answer-kind' { $peer.answered[-1].response.kind = 'event' }
            'answer-success' { $peer.answered[-1].response.success = $false }
            'answer-type' { $peer.answered[-1].response.success = 'true' }
            'quick-chat-extra' { $peer.answered[1].response.event.quickChatsListed[0].unknown = 1 }
            'application-owner' { $peer.applied[0].projectPath = $peer.graphs[1].project.path }
            'application-node' { $peer.applied[0].nodeID = $peer.graphs[1].nodes[0].id }
            'application-title' { $peer.applied[0].title = 'Not applied' }
            'application-before' { $peer.applied[0].beforeTitle = 'Not prior' }
            'application-duplicate' { $peer.applied[1] = $peer.applied[0] }
            'publication-sequence' { $peer.publications[-1].frame.sequence = 99 }
            'publication-kind-type' { $peer.publications[-1].frame.kind = $true }
            'publication-owner' { $peer.publications[-1].frame.event.graphChanged.project.path = $peer.graphs[1].project.path }
            'publication-title' { $peer.publications[-1].frame.event.graphChanged.nodes[0].title = 'Not published' }
            'publication-correlation' { $peer.publications[-1].correlationID = $peer.received[0].requestID }
            'publication-duplicate' { $peer.publications[-1] = $peer.publications[-2] }
            'unknown-cause' { $peer.publications[-1].cause = 'unknown' }
            'control-owner' { $peer.controls[0].projectPath = $peer.graphs[1].project.path }
            'control-selection' { $peer.controls[0].selection.nodeID = $peer.graphs[0].nodes[0].id }
            'control-token' { $peer.controls[0].token = $peer.received[0].requestID }
            'graph-missing' { $peer.graphs = @($peer.graphs[0]) }
            'graph-duplicate' { $peer.graphs[1] = $peer.graphs[0] }
            'graph-title' { $peer.graphs[0].nodes[0].title = 'Not final' }
            'graph-id' { $peer.graphs[0].id = 'bad' }
            'graph-depth-loss' { $peer.graphs[0].nodes[0].presence = '@{presence=idle}' }
        }
        Assert-ReceiptRejected { New-MultiProjectPeerReceipt (ConvertTo-Json -InputObject $report -Depth 16 -Compress) }
    }
}
Complete-OwnershipFamily 'ownership.mixed-receipt.source-line-2460' 51 @('receipt-negative-controls')
foreach ($mutation in @('no-record', 'duplicate-record', 'bad-json', 'duplicate-property', 'bad-hash',
    'byte-count', 'report-mismatch', 'schema', 'provenance', 'json-depth', 'settled-mismatch')) {
    Invoke-OwnershipCase $mutation {
        $receipt = New-MultiProjectPeerReceipt $fixture
        $line = 'UIA_MULTIPROJECT_PEER_RECEIPT=' + (ConvertTo-Json -InputObject $receipt -Depth 16 -Compress)
        Assert-ReceiptRejected {
            switch ($mutation) {
                'no-record' { Read-MultiProjectPeerReceipt 'native job succeeded without retained peer' }
                'duplicate-record' { Read-MultiProjectPeerReceipt ($line + "`n" + $line) }
                'bad-json' { Read-MultiProjectPeerReceipt 'UIA_MULTIPROJECT_PEER_RECEIPT={bad' }
                'duplicate-property' { Read-MultiProjectPeerReceipt 'UIA_MULTIPROJECT_PEER_RECEIPT={"x":1,"x":2}' }
                'bad-hash' { $receipt.utf8Sha256 = 'bad'; Assert-MultiProjectPeerReceipt $receipt }
                'byte-count' { $receipt.utf8ByteCount++; Assert-MultiProjectPeerReceipt $receipt }
                'report-mismatch' { $receipt.report.protocolConnected = $false; Assert-MultiProjectPeerReceipt $receipt }
                'schema' { $receipt.schemaVersion = '1'; Assert-MultiProjectPeerReceipt $receipt }
                'provenance' { $receipt.provenance = 'expected fixture'; Assert-MultiProjectPeerReceipt $receipt }
                'json-depth' { Read-MultiProjectPeerReceipt ('UIA_MULTIPROJECT_PEER_RECEIPT=' +
                    (ConvertTo-Json -InputObject $receipt -Depth 2 -Compress -WarningAction SilentlyContinue)) }
                'settled-mismatch' {
                    $peer = (New-ReceiptReport).multiProjectPeer
                    $peer.graphSequence++
                    Write-MultiProjectPeerReceipt $fixture $peer
                }
            }
        }
    }
}
Complete-OwnershipFamily 'ownership.mixed-receipt.source-line-2520' 11 @('receipt-negative-controls')
if ($script:OwnershipAdapterFailed) { exit 1 }
