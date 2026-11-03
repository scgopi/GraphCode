[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
. Import-OwnershipCaptureFunctions $RepositoryRoot $AssemblyPath
$stub = Join-Path $RepositoryRoot 'Tools\windows\Stub-Daemon.ps1'
$stubAst = Read-OwnershipProductionAst $stub
. Import-OwnershipProductionFunctions $stubAst @('Assert-MultiProjectJsonProperties', 'ConvertFrom-MultiProjectJson')
$root = Join-Path $env:TEMP ('actual-mixed-pipe-' + [guid]::NewGuid().ToString('N'))
$alpha = Join-Path $root 'Alpha'
$beta = Join-Path $root 'Beta'
$null = New-Item -ItemType Directory -Path $alpha, $beta
$alphaId = '11111111-1111-4111-8111-111111111111'
$betaId = '22222222-2222-4222-8222-222222222222'
$listId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$renameId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$token = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$capture = $null
$client = $null
$primary = $null
function Send-PipeFrame($Frame) {
    $json = ConvertTo-Json -InputObject $Frame -Depth 16 -Compress
    $deadline = [GraphCode.Validation.Ownership.Deadline]::new([TimeSpan]::FromSeconds(5))
    [GraphCode.Validation.Ownership.PipeFrames]::WriteAsync($client, $json, $deadline, 7,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
function Read-PipeFrame {
    $deadline = [GraphCode.Validation.Ownership.Deadline]::new([TimeSpan]::FromSeconds(5))
    $document = [GraphCode.Validation.Ownership.PipeFrames]::ReadAsync($client, $deadline,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    if ($null -eq $document) { throw 'Actual owned pipe ended before an expected frame.' }
    try { return ConvertFrom-MultiProjectJson $document.RootElement.GetRawText() }
    finally { $document.Dispose() }
}
function Start-ProtocolPeer([string] $Pipe, [string] $Result, [switch] $Multi) {
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $stub, '-PipeName', $Pipe, '-ResultPath', $Result)
    if ($Multi) {
        $arguments += @('-SeedMultiProjects', '-ProjectAPath', $alpha, '-ProjectBPath', $beta, '-PublicationControlPath', $control)
    }
    return Start-MultiProjectOwnedProcess -file (Join-Path $PSHOME 'pwsh.exe') -arguments $arguments `
        -environment @{ TEMP = $root; TMP = $root } -stem 'actual-peer' `
        -jobSourcePath (Join-Path $RepositoryRoot 'Tools\windows\Tests\Packaging.Standalone.Tests.ps1')
}
try {
    $pipe = 'graphcode-compiled-mixed-' + [guid]::NewGuid().ToString('N')
    $control = Join-Path $root 'publish.json'
    $capture = Start-ProtocolPeer $pipe (Join-Path $root 'peer.json') -Multi
    $client = [IO.Pipes.NamedPipeClientStream]::new('.', $pipe, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $client.Connect(5000)
    Send-PipeFrame ([ordered]@{ version = 2; kind = 'hello'; supportedVersions = @(1, 2) })
    $hello = Read-PipeFrame
    Invoke-OwnershipCase 'real-hello' {
        Assert-Ownership ($hello.selectedVersion -eq 2) 'Actual owned stub did not negotiate v2.'
    }
    Complete-OwnershipFamily 'ownership.mixed-pipe.source-line-4053' 1 @('owned-real-pipes')
    Send-PipeFrame ([ordered]@{ version = 2; kind = 'request'; requestID = $listId; command = [ordered]@{ listRecentProjects = [ordered]@{} } })
    $response = Read-PipeFrame
    $first = Read-PipeFrame
    $second = Read-PipeFrame
    Invoke-OwnershipCase 'fragmented-two-owner-frames' {
        Assert-Ownership ($response.requestID -ceq $listId -and $first.sequence -eq 1 -and $second.sequence -eq 2 -and
            $first.event.graphChanged.project.path -ceq $alpha -and $second.event.graphChanged.project.path -ceq $beta) 'Actual fragmented wire owner/sequence frames differ.'
    }
    Complete-OwnershipFamily 'ownership.mixed-pipe.source-line-4056' 1 @('owned-real-pipes')
    Send-PipeFrame ([ordered]@{ version = 2; kind = 'request'; requestID = $renameId; command = [ordered]@{
        graphCommand = [ordered]@{ projectPath = $alpha; command = [ordered]@{ renameNode = [ordered]@{ _0 = $alphaId; title = 'Alpha renamed' } } }
    } })
    $response = Read-PipeFrame
    $publication = Read-PipeFrame
    Invoke-OwnershipCase 'real-rename-application' {
        Assert-Ownership ($response.requestID -ceq $renameId -and $publication.sequence -eq 3 -and
            $publication.event.graphChanged.nodes[0].title -ceq 'Alpha renamed') 'Actual rename application/response/publication differs.'
    }
    Complete-OwnershipFamily 'ownership.mixed-pipe.source-line-4063' 1 @('owned-real-pipes')
    $publicationControl = [ordered]@{ token = $token; projectPath = $alpha; nodeID = $alphaId; title = 'Alpha interleaved'; selection = [ordered]@{
        projectPath = $beta; nodeID = $betaId; source = 'synthetic-client'
    } }
    [IO.File]::WriteAllText(($control + '.pending'), (ConvertTo-Json -InputObject $publicationControl -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move(($control + '.pending'), $control)
    $publication = Read-PipeFrame
    Invoke-OwnershipCase 'idle-file-controlled-publication' {
        Assert-Ownership ($publication.sequence -eq 4 -and $publication.event.graphChanged.project.path -ceq $alpha -and
            $publication.event.graphChanged.nodes[0].title -ceq 'Alpha interleaved') 'Actual idle owned pipe did not publish the interleaved Alpha control.'
    }
    Complete-OwnershipFamily 'ownership.mixed-pipe.source-line-4072' 1 @('owned-real-pipes')
    $client.Dispose()
    $client = $null
    $null = Complete-MultiProjectCapture $capture $root 5000
    $capture = $null
    $pipe = 'graphcode-compiled-default-' + [guid]::NewGuid().ToString('N')
    $capture = Start-ProtocolPeer $pipe (Join-Path $root 'default-peer.json')
    $client = [IO.Pipes.NamedPipeClientStream]::new('.', $pipe, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $client.Connect(5000)
    Send-PipeFrame ([ordered]@{ version = 2; kind = 'hello'; supportedVersions = @(1, 2) })
    $hello = Read-PipeFrame
    Send-PipeFrame ([ordered]@{ version = 2; kind = 'request'; requestID = $listId; command = [ordered]@{ listRecentProjects = [ordered]@{} } })
    $response = Read-PipeFrame
    $publication = Read-PipeFrame
    Invoke-OwnershipCase 'real-default-fixture-unchanged' {
        Assert-Ownership ($hello.selectedVersion -eq 2 -and $response.requestID -ceq $listId -and
            $response.event.recentProjectsListed.Count -eq 1 -and $publication.sequence -eq 1 -and
            $publication.event.graphChanged.project.path -ceq 'graphcode://stub/project' -and
            $publication.event.graphChanged.nodes.Count -eq 2 -and
            $publication.event.graphChanged.nodes[0].id -ceq $alphaId -and $publication.event.graphChanged.nodes[0].title -ceq 'Stub node A' -and
            $publication.event.graphChanged.nodes[1].id -ceq $betaId -and $publication.event.graphChanged.nodes[1].title -ceq 'Stub node B') 'The actual unchanged one-project/two-node default fixture changed.'
    }
    Complete-OwnershipFamily 'ownership.mixed-pipe.source-line-4093' 1 @('owned-real-pipes')
} catch {
    $primary = $_
    throw
} finally {
    if ($client) { $client.Dispose() }
    if ($capture) { $null = Complete-MultiProjectCapture $capture $root 5000 $primary }
}
if ($script:OwnershipAdapterFailed) { exit 1 }
