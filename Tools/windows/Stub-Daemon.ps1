[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PipeName,
  [Parameter(Mandatory)]
  [string] $ResultPath,
  [ValidateRange(0, 1000)]
  [int] $ResponseDelayMilliseconds = 0,
  [switch] $NonReading,
  [string] $NodeAId = "",
  [string] $NodeBId = "",
  [string] $NodeATitle = "Stub node A",
  [string] $NodeBTitle = "Stub node B",
  # Apply renameNode, createNode, createEdge and updateEdge to the stub's own graph and
  # publish the result as a new graphChanged event, so a caller can observe what
  # a daemon that accepted the command would send back.
  [switch] $ApplyGraphCommands,
  [switch] $SeedSketches,
  [switch] $SeedMultiProjects,
  [string] $ProjectAPath = "",
  [string] $ProjectBPath = "",
  [string] $PublicationControlPath = ""
)

$ErrorActionPreference = "Stop"
function Copy-MultiProjectValue($value) {
  return ,(ConvertTo-Json -InputObject $value -Depth 32 -Compress |
    ConvertFrom-Json -AsHashtable -NoEnumerate)
}

function ConvertTo-MultiProjectCanonicalJson($value) {
  if ($null -eq $value) { return "null" }
  if ($value -is [Collections.IDictionary]) {
    $keys = [string[]]@($value.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $fields = foreach ($key in $keys) {
      (ConvertTo-Json -InputObject $key -Compress) + ":" + (ConvertTo-MultiProjectCanonicalJson $value[$key])
    }
    return "{" + ($fields -join ",") + "}"
  }
  if ($value -is [array]) {
    $items = foreach ($item in $value) { ConvertTo-MultiProjectCanonicalJson $item }
    return "[" + ($items -join ",") + "]"
  }
  return ConvertTo-Json -InputObject $value -Compress
}

function Assert-MultiProjectObject($value, [string[]] $keys, [string] $label) {
  if ($value -isnot [Collections.IDictionary] -or $value.Count -ne $keys.Count) {
    throw "MULTIPROJECT_SCHEMA: $label has the wrong object shape"
  }
  foreach ($key in $value.Keys) {
    if ($keys -cnotcontains $key) { throw "MULTIPROJECT_SCHEMA: $label unexpected field $key" }
  }
}

function Assert-MultiProjectUuid($value, [string] $label) {
  if ($value -isnot [string]) { throw "MULTIPROJECT_TYPE: $label must be a string" }
  if ($value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
    throw "MULTIPROJECT_UUID: $label must be a lowercase version-4 UUID"
  }
}

function Assert-MultiProjectJsonProperties([System.Text.Json.JsonElement] $element) {
  if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $element.EnumerateObject()) {
      if (-not $names.Add($property.Name)) { throw "MULTIPROJECT_JSON: duplicate field $($property.Name)" }
      Assert-MultiProjectJsonProperties $property.Value
    }
  } elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
    foreach ($item in $element.EnumerateArray()) { Assert-MultiProjectJsonProperties $item }
  }
}

function ConvertFrom-MultiProjectJson([string] $json) {
  $document = $null
  try {
    try { $document = [System.Text.Json.JsonDocument]::Parse($json) }
    catch [System.Text.Json.JsonException] { throw "MULTIPROJECT_JSON: malformed JSON" }
    if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
      throw "MULTIPROJECT_JSON: root must be an object"
    }
    Assert-MultiProjectJsonProperties $document.RootElement
    return ConvertFrom-Json -InputObject $json -AsHashtable -Depth 32
  } finally {
    if ($null -ne $document) { $document.Dispose() }
  }
}

function New-MultiProjectPeer([string] $alphaPath, [string] $betaPath) {
  foreach ($path in @($alphaPath, $betaPath)) {
    if (-not [IO.Path]::IsPathFullyQualified($path) -or [IO.Path]::GetFullPath($path) -cne $path -or
        -not [IO.Directory]::Exists($path) -or (Test-Path -LiteralPath (Join-Path $path ".git"))) {
      throw "MULTIPROJECT_FIXTURE: require exact existing ordinary-folder paths"
    }
  }
  if ([string]::Equals($alphaPath, $betaPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "MULTIPROJECT_FIXTURE: owners must be different folders"
  }
  $graphs = @(
    [ordered]@{
      id = "aaaaaaaa-1111-4111-8111-111111111111"
      project = [ordered]@{ path = $alphaPath; name = "Alpha"; remote = $false }
      nodes = @([ordered]@{ id = "11111111-1111-4111-8111-111111111111"; title = "Alpha loop"
        loopType = "turnBased"; state = "idle"; activity = "stub"
        presence = [ordered]@{ presence = "idle"; confidence = "reported" } })
      edges = @()
    },
    [ordered]@{
      id = "bbbbbbbb-2222-4222-8222-222222222222"
      project = [ordered]@{ path = $betaPath; name = "Beta"; remote = $false }
      nodes = @([ordered]@{ id = "22222222-2222-4222-8222-222222222222"; title = "Beta loop"
        loopType = "turnBased"; state = "idle"; activity = "stub"
        presence = [ordered]@{ presence = "idle"; confidence = "reported" } })
      edges = @()
    }
  )
  return [ordered]@{
    graphs = $graphs; sequence = 0
    received = [Collections.Generic.List[object]]::new()
    applied = [Collections.Generic.List[object]]::new()
    answered = [Collections.Generic.List[object]]::new()
    publications = [Collections.Generic.List[object]]::new()
    controls = [Collections.Generic.List[object]]::new()
  }
}

function Find-MultiProjectGraph($peer, $path, $nodeId = $null) {
  if ($path -isnot [string]) { throw "MULTIPROJECT_TYPE: projectPath must be a string" }
  $matches = @($peer.graphs | Where-Object { $_.project.path -ceq $path })
  if ($matches.Count -ne 1 -or ($null -ne $nodeId -and $matches[0].nodes[0].id -cne $nodeId)) {
    throw "MULTIPROJECT_OWNER: wrong exact project/node owner"
  }
  return $matches[0]
}

function Invoke-MultiProjectRequest($peer, $frame) {
  Assert-MultiProjectObject $frame @("version", "kind", "requestID", "command") "request"
  if (($frame.version -isnot [int] -and $frame.version -isnot [long]) -or $frame.kind -isnot [string]) {
    throw "MULTIPROJECT_TYPE: version/kind types differ"
  }
  if ($frame.version -ne 2 -or $frame.kind -cne "request") { throw "MULTIPROJECT_SCHEMA: expected v2 request" }
  Assert-MultiProjectUuid $frame.requestID "requestID"
  if (@($peer.received | Where-Object { $_.requestID -ceq $frame.requestID }).Count -ne 0) {
    throw "MULTIPROJECT_DUPLICATE: requestID already received"
  }
  if ($frame.command -isnot [Collections.IDictionary] -or $frame.command.Count -ne 1) {
    throw "MULTIPROJECT_SCHEMA: expected one command"
  }
  $verb = @($frame.command.Keys)[0]
  $response = $null
  $owner = $null
  $rename = $null
  if ($verb -ceq "graphCommand") {
    $command = $frame.command.graphCommand
    Assert-MultiProjectObject $command @("projectPath", "command") "graphCommand"
    if ($command.command -is [Collections.IDictionary] -and
        @($command.command.Keys) -ccontains "resumeSession") {
      Assert-MultiProjectObject $command.command @("resumeSession") "graphCommand.command"
      $resume = $command.command.resumeSession
      Assert-MultiProjectObject $resume @("_0") "resumeSession"
      Assert-MultiProjectUuid $resume._0 "nodeID"
      $owner = Find-MultiProjectGraph $peer $command.projectPath $resume._0
    } else {
      Assert-MultiProjectObject $command.command @("renameNode") "graphCommand.command"
      $rename = $command.command.renameNode
      Assert-MultiProjectObject $rename @("_0", "title") "renameNode"
      Assert-MultiProjectUuid $rename._0 "nodeID"
      if ($rename.title -isnot [string]) { throw "MULTIPROJECT_TYPE: title must be a string" }
      if ([string]::IsNullOrWhiteSpace($rename.title)) { throw "MULTIPROJECT_TITLE: title cannot be blank" }
      $owner = Find-MultiProjectGraph $peer $command.projectPath $rename._0
    }
    $response = [ordered]@{ version = 2; kind = "response"; requestID = $frame.requestID; success = $true }
  } elseif ($verb -ceq "listRecentProjects") {
    Assert-MultiProjectObject $frame.command.listRecentProjects @() "listRecentProjects"
    $response = [ordered]@{ version = 2; kind = "response"; requestID = $frame.requestID
      event = [ordered]@{ recentProjectsListed = @($peer.graphs | ForEach-Object { Copy-MultiProjectValue $_.project }) } }
  } elseif ($verb -cin @("listQuickChats", "restoreOpenProjects", "openGlobalGraph")) {
    Assert-MultiProjectObject $frame.command[$verb] @() $verb
  } elseif ($verb -ceq "openProject") {
    Assert-MultiProjectObject $frame.command.openProject @("path") "openProject"
    $null = Find-MultiProjectGraph $peer $frame.command.openProject.path
  } else {
    throw "MULTIPROJECT_SCHEMA: unsupported opt-in command $verb"
  }
  $peer.received.Add([ordered]@{ requestID = $frame.requestID; frame = Copy-MultiProjectValue $frame
    expectedResponse = Copy-MultiProjectValue $response })
  if ($null -ne $rename) {
    $peer.applied.Add([ordered]@{ requestID = $frame.requestID; projectPath = $owner.project.path
      nodeID = $rename._0; beforeTitle = $owner.nodes[0].title; title = $rename.title })
    $owner.nodes[0].title = $rename.title
  }
  return [ordered]@{ response = $response; publishPath = if ($null -ne $rename) { $owner.project.path } else { $null } }
}

function Complete-MultiProjectResponse($peer, $response) {
  $keys = if (@($response.Keys) -ccontains "event") { @("version", "kind", "requestID", "event") } else { @("version", "kind", "requestID", "success") }
  Assert-MultiProjectObject $response $keys "response"
  if (($response.version -isnot [int] -and $response.version -isnot [long]) -or $response.version -ne 2 -or
      $response.kind -cne "response" -or ((@($response.Keys) -ccontains "success") -and $response.success -isnot [bool])) {
    throw "MULTIPROJECT_TYPE: response version/kind/success types differ"
  }
  Assert-MultiProjectUuid $response.requestID "response.requestID"
  $received = @($peer.received | Where-Object { $_.requestID -ceq $response.requestID })
  if ($received.Count -ne 1) { throw "MULTIPROJECT_CORRELATION: response has no unique request" }
  if (@($peer.answered | Where-Object { $_.requestID -ceq $response.requestID }).Count -ne 0) {
    throw "MULTIPROJECT_DUPLICATE: request already answered"
  }
  if ($null -ne $received[0].expectedResponse -and
      (ConvertTo-MultiProjectCanonicalJson $received[0].expectedResponse) -cne
      (ConvertTo-MultiProjectCanonicalJson $response)) {
    throw "MULTIPROJECT_CORRELATION: reply differs from expected typed response"
  }
  $peer.answered.Add([ordered]@{ requestID = $response.requestID; response = Copy-MultiProjectValue $response })
}

function New-MultiProjectPublication($peer, [string] $path) {
  $graph = Find-MultiProjectGraph $peer $path
  return [ordered]@{ version = 2; kind = "event"; sequence = $peer.sequence + 1
    event = [ordered]@{ graphChanged = Copy-MultiProjectValue $graph } }
}

function Complete-MultiProjectPublication($peer, $frame, [string] $cause, [string] $correlationId) {
  $expected = New-MultiProjectPublication $peer $frame.event.graphChanged.project.path
  if ((ConvertTo-MultiProjectCanonicalJson $expected) -cne (ConvertTo-MultiProjectCanonicalJson $frame)) {
    throw "MULTIPROJECT_SEQUENCE: publication differs from exact next graph frame"
  }
  if ($cause -cne "control" -and @($peer.answered | Where-Object { $_.requestID -ceq $correlationId }).Count -ne 1) {
    throw "MULTIPROJECT_UNANSWERED: publication precedes correlated response"
  }
  $peer.sequence = $frame.sequence
  $peer.publications.Add([ordered]@{ cause = $cause; correlationID = $correlationId; frame = Copy-MultiProjectValue $frame })
}

function Get-MultiProjectPeerSnapshot($peer) {
  return [ordered]@{
    receivedCount = $peer.received.Count; requestCount = $peer.received.Count
    responseCount = $peer.answered.Count; appliedCount = $peer.applied.Count
    publicationCount = $peer.publications.Count; graphSequence = $peer.sequence
    received = Copy-MultiProjectValue $peer.received.ToArray()
    applied = Copy-MultiProjectValue $peer.applied.ToArray()
    answered = Copy-MultiProjectValue $peer.answered.ToArray()
    publications = Copy-MultiProjectValue $peer.publications.ToArray()
    controls = Copy-MultiProjectValue $peer.controls.ToArray()
    graphs = Copy-MultiProjectValue $peer.graphs
    unansweredRequests = @($peer.received | Where-Object {
      $id = $_.requestID
      @($peer.answered | Where-Object { $_.requestID -ceq $id }).Count -ne 1
    } | ForEach-Object { $_.requestID })
  }
}

function Invoke-MultiProjectPublicationControl($peer, $control) {
  Assert-MultiProjectObject $control @("token", "projectPath", "nodeID", "title", "selection") "publication control"
  Assert-MultiProjectUuid $control.token "control.token"
  Assert-MultiProjectUuid $control.nodeID "control.nodeID"
  if (@($peer.controls | Where-Object { $_.token -ceq $control.token }).Count -ne 0) {
    throw "MULTIPROJECT_DUPLICATE: control token already used"
  }
  if ($peer.controls.Count -ne 0) { throw "MULTIPROJECT_ONE_SHOT: Alpha control was already applied" }
  $graph = Find-MultiProjectGraph $peer $control.projectPath $control.nodeID
  if ($graph.project.path -cne $peer.graphs[0].project.path) { throw "MULTIPROJECT_OWNER: control must target Alpha" }
  if ($control.title -isnot [string]) { throw "MULTIPROJECT_TYPE: control title must be a string" }
  if ([string]::IsNullOrWhiteSpace($control.title)) { throw "MULTIPROJECT_TITLE: control title cannot be blank" }
  Assert-MultiProjectObject $control.selection @("projectPath", "nodeID", "source") "selected Beta"
  if ($control.selection.projectPath -cne $peer.graphs[1].project.path -or
      $control.selection.nodeID -cne $peer.graphs[1].nodes[0].id -or
      $control.selection.source -cnotin @("live-uia", "synthetic-client")) {
    throw "MULTIPROJECT_SELECTION: expected exact observed Beta identity"
  }
  $snapshot = Get-MultiProjectPeerSnapshot $peer
  if ($snapshot.requestCount -le 0 -or $snapshot.responseCount -ne $snapshot.requestCount -or
      $snapshot.unansweredRequests.Count -ne 0 -or $snapshot.publicationCount -lt 2) {
    throw "MULTIPROJECT_UNANSWERED: require positive settled request/publication baseline"
  }
  foreach ($owner in $peer.graphs) {
    if (@($peer.publications | Where-Object { $_.cause -ceq "initial" -and
        $_.frame.event.graphChanged.project.path -ceq $owner.project.path }).Count -lt 1) {
      throw "MULTIPROJECT_PREREQUISITE: both owners must be published before interleaving"
    }
  }
  $beforeTitle = $graph.nodes[0].title
  $graph.nodes[0].title = $control.title
  $peer.controls.Add([ordered]@{ token = $control.token; projectPath = $control.projectPath
    nodeID = $control.nodeID; beforeTitle = $beforeTitle; title = $control.title
    selection = Copy-MultiProjectValue $control.selection })
  return New-MultiProjectPublication $peer $control.projectPath
}

$multiProjectPeer = if ($SeedMultiProjects) { New-MultiProjectPeer $ProjectAPath $ProjectBPath } else { $null }
$multiProjectControlVersion = $null
if ($SeedMultiProjects -and ($SeedSketches -or $NonReading -or [string]::IsNullOrWhiteSpace($PublicationControlPath))) {
  throw "MULTIPROJECT_FIXTURE: use a dedicated opt-in peer and publication control path"
}
$utf8 = [Text.Encoding]::UTF8
$seenRequests = [Collections.Generic.HashSet[string]]::new()
$seenResponses = [Collections.Generic.HashSet[string]]::new()
$requestCommands = @{}
$connectionCount = 0
$subscriptionSeen = $false
$graphSent = $false
$busyObserved = $false
$seenCommands = [Collections.Generic.List[string]]::new()
$errorMessage = $null

$nodeA = if ($NodeAId) { $NodeAId } elseif ($env:GRAPHCODE_STUB_NODE_A) { $env:GRAPHCODE_STUB_NODE_A } else { "11111111-1111-4111-8111-111111111111" }
$nodeB = if ($NodeBId) { $NodeBId } elseif ($env:GRAPHCODE_STUB_NODE_B) { $env:GRAPHCODE_STUB_NODE_B } else { "22222222-2222-4222-8222-222222222222" }
$nodeTitles = [ordered]@{ $nodeA = $NodeATitle; $nodeB = $NodeBTitle }
$nodeStates = @{ $nodeA = @("running", "busy"); $nodeB = @("idle", "idle") }
$graphSequence = 1
$appliedRenames = [Collections.Generic.List[string]]::new()
# Only nodes created through an applied createNode carry entries here; seeded
# nodes keep their historical turnBased shape with no backend/model fields.
$nodeLoopTypes = @{}
$nodeExtraFields = @{}
$nodePromotionFields = @{}
$appliedCreates = [Collections.Generic.List[string]]::new()
$appliedCreateRequests = [Collections.Generic.List[string]]::new()
$edges = [Collections.Generic.List[object]]::new()
$appliedEdgeCreates = [Collections.Generic.List[string]]::new()
$appliedEdgeUpdates = [Collections.Generic.List[string]]::new()
$appliedEdgeCreateRequests = [Collections.Generic.List[string]]::new()
$appliedEdgeUpdateRequests = [Collections.Generic.List[string]]::new()
$appliedPromotions = [Collections.Generic.List[string]]::new()
$appliedPromotionRequests = [Collections.Generic.List[string]]::new()
$receivedGraphCommands = [Collections.Generic.List[object]]::new()
if ($SeedSketches) {
  $nodeExtraFields[$nodeA] = ',"backend":"copilotCLI"'
}

function ConvertTo-StubJsonText([string] $value) {
  return $value.Replace('\', '\\').Replace('"', '\"')
}

function New-StubGraphEvent {
  $nodes = foreach ($id in @($nodeTitles.Keys)) {
    $state = $nodeStates[$id]
    $loopType = if ($nodeLoopTypes.ContainsKey($id)) { [string]$nodeLoopTypes[$id] } else { "turnBased" }
    $extra = if ($nodeExtraFields.ContainsKey($id)) { [string]$nodeExtraFields[$id] } else { "" }
    $promotionExtra = if ($nodePromotionFields.ContainsKey($id)) { [string]$nodePromotionFields[$id] } else { "" }
    '{"id":"' + $id + '","title":"' + (ConvertTo-StubJsonText ([string]$nodeTitles[$id])) +
      '","loopType":"' + (ConvertTo-StubJsonText $loopType) + '"' + $extra + $promotionExtra + ',"state":"' + $state[0] +
      '","activity":"stub","presence":{"presence":"' + $state[1] + '","confidence":"reported"}}'
  }
  $edgeJson = @($edges | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress })
  return '{"version":2,"kind":"event","sequence":' + $graphSequence +
    ',"event":{"graphChanged":{"id":"stub-graph","project":{"path":"graphcode://stub/project",' +
    '"name":"Stub project","remote":false},"nodes":[' + ($nodes -join ",") + '],"edges":[' + ($edgeJson -join ",") + ']}}}'
}
$recentProjects = '{"version":2,"kind":"response","requestID":"{0}","event":{"recentProjectsListed":[{"path":"graphcode://stub/project","name":"Stub project","remote":false}]}}'
$quickChats = '{"version":2,"kind":"response","requestID":"{0}","event":{"quickChatsListed":[{"id":"33333333-3333-4333-8333-333333333333","title":"Stub quick chat","backend":"claudeCode","createdAt":0,"activity":{"sequence":1,"text":"ready","presence":{"presence":"idle","confidence":"reported"}}},{"id":"44444444-4444-4444-8444-444444444444","title":"Review notes","backend":"copilot","createdAt":1,"activity":null}]}}'
$success = '{"version":2,"kind":"response","requestID":"{0}","success":true}'
$hello = '{"version":2,"kind":"hello","supportedVersions":[1,2],"selectedVersion":2}'

function Read-Exact([IO.Stream] $stream, [int] $length) {
  $buffer = [byte[]]::new($length)
  $offset = 0
  while ($offset -lt $length) {
    if ($SeedMultiProjects) {
      $readTask = $stream.ReadAsync($buffer, $offset, $length - $offset)
      for ($wait = 0; -not $readTask.Wait(50); $wait++) {
        Invoke-MultiProjectControlPump $stream
        if ($wait -ge 3600) { throw "MULTIPROJECT_TIMEOUT: idle peer exceeded three minutes" }
      }
      $read = $readTask.GetAwaiter().GetResult()
    } else {
      $read = $stream.Read($buffer, $offset, $length - $offset)
    }
    if ($read -le 0) { return $null }
    $offset += $read
  }
  return $buffer
}

function Send-Frame([IO.Stream] $stream, [string] $json, [switch] $Fragment) {
  $payload = $utf8.GetBytes($json)
  $length = $payload.Length
  $header = [byte[]] @(
    [byte](($length -shr 24) -band 0xff),
    [byte](($length -shr 16) -band 0xff),
    [byte](($length -shr 8) -band 0xff),
    [byte]($length -band 0xff)
  )
  try {
    if ($Fragment) {
      $stream.Write($header, 0, 2)
      $stream.Flush()
      Start-Sleep -Milliseconds 20
      $stream.Write($header, 2, 2)
      $stream.Flush()
      for ($offset = 0; $offset -lt $payload.Length; $offset += 7) {
        $count = [Math]::Min(7, $payload.Length - $offset)
        $stream.Write($payload, $offset, $count)
        $stream.Flush()
        Start-Sleep -Milliseconds 5
      }
      return $true
    }
    $frame = [byte[]]::new(4 + $payload.Length)
    [Array]::Copy($header, 0, $frame, 0, 4)
    [Array]::Copy($payload, 0, $frame, 4, $payload.Length)
    $stream.Write($frame, 0, $frame.Length)
    $stream.Flush()
    return $true
  } catch [IO.IOException] {
    $script:errorMessage = $_.Exception.Message
    return $false
  } catch [System.Exception] {
    $script:errorMessage = $_.Exception.Message
    return $false
  }
}

function Send-MultiProjectPublication([IO.Stream] $stream, $frame, [string] $cause, [string] $correlationId) {
  if (-not (Send-Frame $stream ($frame | ConvertTo-Json -Depth 16 -Compress))) {
    throw "MULTIPROJECT_PUBLICATION: graph frame was not written: $errorMessage"
  }
  Complete-MultiProjectPublication $multiProjectPeer $frame $cause $correlationId
}

function Invoke-MultiProjectControlPump([IO.Stream] $stream) {
  if (-not (Test-Path -LiteralPath $PublicationControlPath)) { return }
  $version = (Get-Item -LiteralPath $PublicationControlPath).LastWriteTimeUtc.Ticks
  if ($version -eq $script:multiProjectControlVersion) { return }
  $control = ConvertFrom-MultiProjectJson (Get-Content -LiteralPath $PublicationControlPath -Raw)
  $frame = Invoke-MultiProjectPublicationControl $multiProjectPeer $control
  Send-MultiProjectPublication $stream $frame "control" $control.token
  $script:multiProjectControlVersion = $version
  Write-Result
}

function Get-StubResultWriteWin32Error([System.Exception] $exception) {
  for ($current = $exception; $null -ne $current; $current = $current.InnerException) {
    if ($current -is [IO.IOException]) {
      $nativeCode = [int]($current.HResult -band 0xFFFF)
      if ($nativeCode -in @(32, 33)) { return $nativeCode }
    }
  }
  return 0
}

function Write-StubResultFile([string] $path, [string] $json) {
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    try {
      Set-Content -LiteralPath $path -Value $json -NoNewline -ErrorAction Stop
      return ($attempt + 1)
    } catch [IO.IOException] {
      $exception = $_.Exception
      $nativeCode = Get-StubResultWriteWin32Error $exception
      $cause = "{0}; HResult=0x{1:X8}; native={2}; {3}" -f `
        $exception.GetType().FullName, $exception.HResult, $nativeCode, $exception.Message
      if ($nativeCode -notin @(32, 33)) {
        Write-Host "STUB_RESULT_WRITE_FAILURE attempt=$($attempt + 1)/40 cause=$cause"
        throw
      }
      if ($attempt -eq 39) {
        Write-Host "STUB_RESULT_WRITE_EXHAUSTED attempt=40/40 cause=$cause"
        throw
      }
      Write-Host "STUB_RESULT_WRITE_RETRY attempt=$($attempt + 1)/40 cause=$cause"
      Start-Sleep -Milliseconds 25
    }
  }
}

function Write-Result {
  $graphNodes = @(
    foreach ($id in $nodeTitles.Keys) {
      $extra = if ($nodeExtraFields.ContainsKey($id)) { [string]$nodeExtraFields[$id] } else { "" }
      $createdBy = $null
      if ($extra -match '"createdBy":"([^"]+)"') { $createdBy = $Matches[1] }
      [ordered]@{
        id = [string]$id
        title = [string]$nodeTitles[$id]
        loopType = if ($nodeLoopTypes.ContainsKey($id)) { [string]$nodeLoopTypes[$id] } else { "turnBased" }
        createdBy = $createdBy
      }
    }
  )
  $result = [ordered]@{
    protocolConnected = $connectionCount -gt 0
    correlatedRequests = $seenRequests.Count -ge 2 -and
      (@($seenRequests | Where-Object { -not $seenResponses.Contains($_) }).Count -eq 0)
    connectionCount = $connectionCount
    requestCount = $seenRequests.Count
    responseCount = $seenResponses.Count
    unansweredRequests = @($seenRequests | Where-Object { -not $seenResponses.Contains($_) })
    unansweredCommands = @($seenRequests | Where-Object {
        -not $seenResponses.Contains($_)
      } | ForEach-Object { $requestCommands[$_] })
    commands = @($seenCommands)
    error = $errorMessage
    subscriptionSeen = $subscriptionSeen
    reconnectObserved = $connectionCount -ge 2
    graphSent = $graphSent
    busyObserved = $busyObserved
    appliedRenames = @($appliedRenames)
    appliedCreates = @($appliedCreates)
    appliedCreateRequests = @($appliedCreateRequests)
    appliedEdgeCreates = @($appliedEdgeCreates)
    appliedEdgeUpdates = @($appliedEdgeUpdates)
    appliedEdgeCreateRequests = @($appliedEdgeCreateRequests)
    appliedEdgeUpdateRequests = @($appliedEdgeUpdateRequests)
    appliedPromotions = @($appliedPromotions)
    appliedPromotionRequests = @($appliedPromotionRequests)
    receivedGraphCommands = @($receivedGraphCommands)
    graphNodes = $graphNodes
    edges = @($edges)
    graphSequence = $graphSequence
  }
  if ($SeedMultiProjects) {
    $result.multiProjectPeer = Get-MultiProjectPeerSnapshot $multiProjectPeer
    $json = $result | ConvertTo-Json -Depth 16 -Compress
  } else {
    $json = $result | ConvertTo-Json -Compress
  }
  $null = Write-StubResultFile $ResultPath $json
}

try {
  while ($connectionCount -lt 32) {
    $bufferSize = if ($NonReading) { 0 } else { 64 * 1024 }
    $server = [IO.Pipes.NamedPipeServerStream]::new(
      $PipeName,
      [IO.Pipes.PipeDirection]::InOut,
      1,
      [IO.Pipes.PipeTransmissionMode]::Byte,
      $(if ($SeedMultiProjects) { [IO.Pipes.PipeOptions]::Asynchronous } else { [IO.Pipes.PipeOptions]::None }),
      $bufferSize,
      $bufferSize
    )
    try {
      $server.WaitForConnection()
      $connectionCount++
      $graphSentOnConnection = $false
      if ($NonReading) {
        $busyObserved = $true
        Write-Result
        Start-Sleep -Seconds 10
        continue
      }
      while ($server.IsConnected) {
        $header = Read-Exact $server 4
        if ($null -eq $header) { break }
        $length = ([int]$header[0] -shl 24) -bor
          ([int]$header[1] -shl 16) -bor
          ([int]$header[2] -shl 8) -bor [int]$header[3]
        if ($length -lt 0 -or $length -gt 2097152) { break }
        $payload = Read-Exact $server $length
        if ($null -eq $payload) { break }
        $frame = $utf8.GetString($payload) | ConvertFrom-Json
        if ($frame.kind -eq "hello") {
          if ($frame.subscription -and @($frame.subscription.projectPaths).Count -gt 0) {
            $subscriptionSeen = $true
          }
          if (-not (Send-Frame $server $hello)) { break }
          continue
        }
        if ($frame.kind -ne "request" -or [string]::IsNullOrEmpty($frame.requestID)) {
          break
        }
        $multiProjectPending = if ($SeedMultiProjects) {
          Invoke-MultiProjectRequest $multiProjectPeer (ConvertFrom-MultiProjectJson ($utf8.GetString($payload)))
        } else { $null }
        [void] $seenRequests.Add([string]$frame.requestID)
        $commandName = $frame.command.PSObject.Properties.Name | Select-Object -First 1
        $requestCommands[[string]$frame.requestID] = [string]$commandName
        if ($commandName) { $seenCommands.Add([string]$commandName) }
        if ($commandName -eq "graphCommand") {
          $receivedGraphCommands.Add([ordered]@{
            requestID = [string]$frame.requestID
            command = ($frame.command.graphCommand | ConvertTo-Json -Depth 16 -Compress)
          })
        }
        $renameApplied = $false
        $createApplied = $false
        $edgeApplied = $false
        $promotionApplied = $false
        if ($ApplyGraphCommands -and $commandName -eq "graphCommand" -and -not $SeedMultiProjects) {
          $rename = $frame.command.graphCommand.command.renameNode
          if ($null -ne $rename) {
            $renameTarget = [string]$rename._0
            if ($nodeTitles.Contains($renameTarget)) {
              $nodeTitles[$renameTarget] = [string]$rename.title
              $appliedRenames.Add($renameTarget + "=" + [string]$rename.title)
              $renameApplied = $true
            }
          }
          # Apply exactly the createNode the shell sent: its own id, title, loop
          # type, backend, model tier and custody parent. Nothing is defaulted or invented; a
          # create without an id or with a duplicate id is not applied.
          $create = $frame.command.graphCommand.command.createNode._0
          if ($null -ne $create) {
            $createId = [string]$create.id
            if (-not [string]::IsNullOrEmpty($createId) -and -not $nodeTitles.Contains($createId)) {
              $nodeTitles[$createId] = [string]$create.title
              $nodeStates[$createId] = @("idle", "idle")
              $nodeLoopTypes[$createId] = [string]$create.loopType
              $extraFields = ""
              foreach ($field in @("backend", "modelTier", "triggerPrompt", "createdBy")) {
                $fieldValue = $create.$field
                if ($null -ne $fieldValue) {
                  $extraFields += ',"' + $field + '":"' + (ConvertTo-StubJsonText ([string]$fieldValue)) + '"'
                }
              }
              $nodeExtraFields[$createId] = $extraFields
              $appliedCreates.Add(($createId, [string]$create.title, [string]$create.loopType,
                [string]$create.backend, [string]$create.modelTier, [string]$create.triggerPrompt) -join "|")
              $appliedCreateRequests.Add([string]$frame.requestID)
              $createApplied = $true
              if ($SeedSketches -and $appliedCreates.Count -eq 1) {
                for ($index = 1; $index -le 3; $index++) {
                  $id = "66666666-6666-4666-8666-{0:x12}" -f $index
                  $nodeTitles[$id] = "UIA sketch $index"
                  $nodeStates[$id] = @("idle", "idle")
                  $nodeLoopTypes[$id] = "sketch"
                  $nodeExtraFields[$id] = ',"backend":"copilotCLI","firstInstruction":"Continue sketch work"'
                }
              }
            }
          }
          $promotion = $frame.command.graphCommand.command.promoteNode
          if ($null -ne $promotion) {
            $promotionId = [string]$promotion._0
            $variant = @($promotion.promotion.PSObject.Properties.Name)
            if ([string]$frame.command.graphCommand.projectPath -cne "graphcode://stub/project" -or
                -not $nodeTitles.Contains($promotionId) -or
                [string]$nodeLoopTypes[$promotionId] -cne "sketch" -or
                $variant.Count -ne 1 -or
                $variant[0] -cnotin @("goal", "turn", "timed") -or
                $null -ne $promotion.promotedBy) {
              throw "stub rejected invalid promoteNode request $($frame.requestID)"
            }
            $targetType = switch ($variant[0]) {
              "goal" { "goalBased" }
              "turn" { "turnBased" }
              "timed" { "timeBased" }
            }
            switch ($variant[0]) {
              "goal" {
                $decision = $promotion.promotion.goal._0
                if ($null -eq $decision -or [string]::IsNullOrWhiteSpace([string]$decision.summary) -or
                    [int]$decision.pollIntervalSeconds -le 0 -or
                    [string]$decision.metricDirection -notin @("maximize", "minimize")) {
                  throw "stub rejected invalid goal promotion request $($frame.requestID)"
                }
                $summaryJson = ConvertTo-Json -InputObject ([string]$decision.summary) -Compress
                $directionJson = ConvertTo-Json -InputObject ([string]$decision.metricDirection) -Compress
                $skip = if ($decision.skipsUnchangedWorkspace) { "true" } else { "false" }
                $nodePromotionFields[$promotionId] = ',"goal":{"summary":' + $summaryJson +
                  ',"pollIntervalSeconds":' + [int]$decision.pollIntervalSeconds +
                  ',"metricDirection":' + $directionJson +
                  ',"skipsUnchangedWorkspace":' + $skip + '}'
              }
              "turn" {
                $pause = $promotion.promotion.turn.pausesBeforeWritesOnly
                if ($pause -isnot [bool]) {
                  throw "stub rejected invalid turn promotion request $($frame.requestID)"
                }
                $pauseJson = if ($pause) { "true" } else { "false" }
                $nodePromotionFields[$promotionId] = ',"pausesBeforeWritesOnly":' + $pauseJson
              }
              "timed" {
                $triggerJson = ConvertTo-Json -InputObject ([string]$promotion.promotion.timed.triggerPrompt) -Compress
                if ([string]::IsNullOrWhiteSpace([string]$promotion.promotion.timed.triggerPrompt)) {
                  throw "stub rejected invalid timed promotion request $($frame.requestID)"
                }
                $nodePromotionFields[$promotionId] = ',"triggerPrompt":' + $triggerJson
              }
            }
            $nodeLoopTypes[$promotionId] = $targetType
            $appliedPromotions.Add("$promotionId|$targetType")
            $appliedPromotionRequests.Add([string]$frame.requestID)
            $promotionApplied = $true
          }
          $createEdge = $frame.command.graphCommand.command.createEdge
          if ($null -ne $createEdge) {
            if ([string]$frame.command.graphCommand.projectPath -cne "graphcode://stub/project" -or
                -not $nodeTitles.Contains([string]$createEdge.from) -or
                -not $nodeTitles.Contains([string]$createEdge.to) -or
                [string]$createEdge.from -ceq [string]$createEdge.to -or
                $null -eq $createEdge.spec -or
                [string]$createEdge.spec.kind -notin @("handoff", "message", "spawn") -or
                [string]$createEdge.spec.condition -notin @("always", "onSuccess", "onFailure") -or
                $null -eq $createEdge.spec.payloadTransform) {
              throw "stub rejected invalid createEdge request $($frame.requestID)"
            }
            $edgeId = "55555555-5555-4555-8555-{0:x12}" -f ($edges.Count + 1)
            $edge = [ordered]@{
              id = $edgeId
              from = [string]$createEdge.from
              to = [string]$createEdge.to
              kind = [string]$createEdge.spec.kind
              condition = [string]$createEdge.spec.condition
              fireCount = 0
              payloadTransform = $createEdge.spec.payloadTransform
              cycleGuard = $createEdge.spec.cycleGuard
              spawnTargetProjectPath = $createEdge.spec.spawnTargetProjectPath
            }
            $edges.Add($edge)
            $appliedEdgeCreates.Add($edgeId)
            $appliedEdgeCreateRequests.Add([string]$frame.requestID)
            $edgeApplied = $true
          }
          $updateEdge = $frame.command.graphCommand.command.updateEdge
          if ($null -ne $updateEdge) {
            $matches = @($edges | Where-Object { $_.id -ceq [string]$updateEdge.id })
            if ([string]$frame.command.graphCommand.projectPath -cne "graphcode://stub/project" -or
                $matches.Count -ne 1 -or
                $matches[0].from -cne [string]$updateEdge.from -or
                $matches[0].to -cne [string]$updateEdge.to -or
                $null -eq $updateEdge.expectedSpec -or $null -eq $updateEdge.spec -or
                [string]$updateEdge.spec.kind -notin @("handoff", "message", "spawn") -or
                [string]$updateEdge.spec.condition -notin @("always", "onSuccess", "onFailure") -or
                $null -eq $updateEdge.spec.payloadTransform) {
              throw "stub rejected stale updateEdge identity $($frame.requestID)"
            }
            $current = $matches[0]
            $currentSpec = [ordered]@{
              kind = $current.kind; condition = $current.condition
              payloadTransform = $current.payloadTransform; cycleGuard = $current.cycleGuard
              spawnTargetProjectPath = $current.spawnTargetProjectPath
            }
            foreach ($field in @("kind", "condition", "payloadTransform", "cycleGuard", "spawnTargetProjectPath")) {
              $before = ConvertTo-Json -InputObject $currentSpec[$field] -Depth 8 -Compress
              $expected = ConvertTo-Json -InputObject $updateEdge.expectedSpec.$field -Depth 8 -Compress
              if ($before -cne $expected) {
                throw "stub rejected stale updateEdge expectedSpec.$field $($frame.requestID): current=$before expected=$expected"
              }
            }
            $current.kind = [string]$updateEdge.spec.kind
            $current.condition = [string]$updateEdge.spec.condition
            $current.payloadTransform = $updateEdge.spec.payloadTransform
            $current.cycleGuard = $updateEdge.spec.cycleGuard
            $current.spawnTargetProjectPath = $updateEdge.spec.spawnTargetProjectPath
            $appliedEdgeUpdates.Add([string]$current.id)
            $appliedEdgeUpdateRequests.Add([string]$frame.requestID)
            $edgeApplied = $true
          }
        }
        $response = if ($commandName -eq "listRecentProjects") {
          $recentProjects.Replace("{0}", [string]$frame.requestID)
        } elseif ($commandName -eq "listQuickChats") {
          $quickChats.Replace("{0}", [string]$frame.requestID)
        } else {
          $success.Replace("{0}", [string]$frame.requestID)
        }
        if ($SeedMultiProjects -and $null -ne $multiProjectPending.response) {
          $response = $multiProjectPending.response | ConvertTo-Json -Depth 16 -Compress
        }
        if ($ResponseDelayMilliseconds -gt 0) {
          Start-Sleep -Milliseconds $ResponseDelayMilliseconds
        }
        if (-not (Send-Frame $server $response)) { break }
        if ($SeedMultiProjects) {
          Complete-MultiProjectResponse $multiProjectPeer (ConvertFrom-MultiProjectJson $response)
          if ($commandName -eq "listRecentProjects" -and -not $graphSentOnConnection) {
            foreach ($owner in $multiProjectPeer.graphs) {
              Send-MultiProjectPublication $server (New-MultiProjectPublication $multiProjectPeer $owner.project.path) "initial" $frame.requestID
            }
            $graphSent = $true
            $graphSentOnConnection = $true
          } elseif ($null -ne $multiProjectPending.publishPath) {
            Send-MultiProjectPublication $server (New-MultiProjectPublication $multiProjectPeer $multiProjectPending.publishPath) "rename" $frame.requestID
          }
        }
        [void] $seenResponses.Add([string]$frame.requestID)
        if ($commandName -eq "listRecentProjects" -and -not $graphSentOnConnection -and -not $SeedMultiProjects) {
          if (-not (Send-Frame $server (New-StubGraphEvent))) { break }
          $graphSent = $true
          $graphSentOnConnection = $true
        }
        if ($renameApplied -or $createApplied -or $edgeApplied -or $promotionApplied) {
          $graphSequence++
          if (-not (Send-Frame $server (New-StubGraphEvent))) { break }
          $graphSent = $true
        }
        Write-Result
      }
    } finally {
      $server.Dispose()
    }
    Write-Result
  }
} finally {
  if ($Error.Count -gt 0) {
    $errorMessage = ($Error[0] | Out-String).Trim()
  }
  Write-Result
}
