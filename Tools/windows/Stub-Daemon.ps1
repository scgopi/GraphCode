[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PipeName,
  [Parameter(Mandatory)]
  [string] $ResultPath
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.Encoding]::UTF8
$seenRequests = [Collections.Generic.HashSet[string]]::new()
$seenResponses = [Collections.Generic.HashSet[string]]::new()
$connectionCount = 0
$subscriptionSeen = $false
$graphSent = $false
$seenCommands = [Collections.Generic.List[string]]::new()
$errorMessage = $null

$graphEvent = '{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"stub-graph","project":{"path":"graphcode://stub/project","name":"Stub project","remote":false},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Stub node A","loopType":"turnBased","state":"running","activity":"stub","presence":{"presence":"busy","confidence":"reported"}},{"id":"22222222-2222-4222-8222-222222222222","title":"Stub node B","loopType":"turnBased","state":"idle","activity":"stub","presence":{"presence":"idle","confidence":"reported"}}],"edges":[]}}}'
$recentProjects = '{"version":2,"kind":"response","requestID":"{0}","event":{"recentProjectsListed":[{"path":"graphcode://stub/project","name":"Stub project","remote":false}]}}'
$success = '{"version":2,"kind":"response","requestID":"{0}","success":true}'
$hello = '{"version":2,"kind":"hello","supportedVersions":[1,2],"selectedVersion":2}'

function Read-Exact([IO.Stream] $stream, [int] $length) {
  $buffer = [byte[]]::new($length)
  $offset = 0
  while ($offset -lt $length) {
    $read = $stream.Read($buffer, $offset, $length - $offset)
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

function Write-Result {
  $result = [ordered]@{
    protocolConnected = $connectionCount -gt 0
    correlatedRequests = $seenRequests.Count -ge 2 -and
      (@($seenRequests | Where-Object { -not $seenResponses.Contains($_) }).Count -eq 0)
    requestCount = $seenRequests.Count
    commands = @($seenCommands)
    error = $errorMessage
    subscriptionSeen = $subscriptionSeen
    reconnectObserved = $connectionCount -ge 2
    graphSent = $graphSent
  }
  $result | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -NoNewline
}

try {
  while ($connectionCount -lt 4) {
    $server = [IO.Pipes.NamedPipeServerStream]::new(
      $PipeName,
      [IO.Pipes.PipeDirection]::InOut,
      1,
      [IO.Pipes.PipeTransmissionMode]::Byte,
      [IO.Pipes.PipeOptions]::None
    )
    try {
      $server.WaitForConnection()
      $connectionCount++
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
        [void] $seenRequests.Add([string]$frame.requestID)
        $commandName = $frame.command.PSObject.Properties.Name | Select-Object -First 1
        if ($commandName) { $seenCommands.Add([string]$commandName) }
        $response = if ($commandName -eq "listRecentProjects") {
          $recentProjects.Replace("{0}", [string]$frame.requestID)
        } else {
          $success.Replace("{0}", [string]$frame.requestID)
        }
        if (-not (Send-Frame $server $response)) { break }
        [void] $seenResponses.Add([string]$frame.requestID)
        if ($commandName -eq "listRecentProjects" -and -not $graphSent) {
          if (-not (Send-Frame $server $graphEvent)) { break }
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
