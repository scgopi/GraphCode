#requires -Version 7
# Drives a REAL built graphcoded.exe over its named pipe in a scratch profile and asserts the
# readProjectGraph wire contract. Writes the normalized frame transcript to -Out.
# Never touches the real profile/daemon: pipe, support dir, USERPROFILE and TEMP are private.
param(
  [Parameter(Mandatory)][string]$Daemon,
  [Parameter(Mandatory)][string]$Out,
  [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) 'gc-readgraph-wire')
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'ReadProjectGraph.FramePump.cs')
$run = Join-Path $ScratchRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
$support = Join-Path $run 'support'; $profileDir = Join-Path $run 'profile'; $tmp = Join-Path $run 'temp'
$projA = Join-Path $run 'projA'; $projB = Join-Path $run 'projB'
New-Item -ItemType Directory -Force $support, $profileDir, $tmp, $projA, $projB | Out-Null
$evName = "Local\gc-readgraph-wire-$PID"
$ev = [Threading.EventWaitHandle]::new($false, 'ManualReset', $evName)
$pipeName = 'gc-readgraph-' + [guid]::NewGuid().ToString('N')
$si = [Diagnostics.ProcessStartInfo]::new($Daemon)
$si.UseShellExecute = $false; $si.CreateNoWindow = $true; $si.RedirectStandardOutput = $true
foreach ($n in 'GRAPHCODE_SOCKET', 'GRAPHCODE_DAEMON_PIPE') { [void]$si.Environment.Remove($n) }
$si.Environment['GRAPHCODE_SOCKET'] = "\\.\pipe\$pipeName"
$si.Environment['USERPROFILE'] = $profileDir; $si.Environment['GRAPHCODE_SUPPORT_DIR'] = $support
$si.Environment['TEMP'] = $tmp; $si.Environment['TMP'] = $tmp
$si.Environment['GRAPHCODE_DAEMON_SHUTDOWN_EVENT'] = $evName
$p = [Diagnostics.Process]::Start($si)

$norm = @(
  @($run, 'RUNDIR'), @(($run -replace '\\', '/'), 'RUNDIR'), @(($run -replace '\\', '\\'), 'RUNDIR'),
  @(($run -replace '\\', '\/'), 'RUNDIR'), @(($run -replace '\\', '/' -replace '/', '\/'), 'RUNDIR'))
$log = New-Object Collections.Generic.List[string]
function Lg([string]$s) {
  foreach ($n in $script:norm) { $s = $s.Replace($n[0], $n[1]) }
  $s = [regex]::Replace($s, '"lastOpenedAt":[0-9.]+', '"lastOpenedAt":0')
  $script:log.Add($s)
}
$failures = New-Object Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) { Lg("CHECK $(if ($ok) { 'ok' } else { 'FAILED' }): $what"); if (-not $ok) { $script:failures.Add($what) } }

$cl = $null
Lg("daemon sha256=$((Get-FileHash $Daemon -Algorithm SHA256).Hash)")
try {
  Start-Sleep -Seconds 2
  $cl = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, 'InOut', 'None')
  $cl.Connect(10000)
  $pump = [FramePump]::new($cl)
  $script:rid = 0
  function Rid { $script:rid++; return ('10000000-0000-4000-8000-{0:D12}' -f $script:rid) }
  function Exchange([string]$label, [string]$json) {
    $script:pump.Send($json); Lg(">> [$label] $json")
    $frames = @()
    while ($true) {
      $s = $script:pump.Next(1500); if ($null -eq $s) { break }
      Lg("<< [$label] $s"); $frames += ($s | ConvertFrom-Json)
    }
    Lg("-- [$label] frames: $($frames.Count)")
    return , $frames
  }
  function Cmd([string]$label, [string]$name, [string]$path) {
    $id = Rid
    $body = '{"version":2,"kind":"request","requestID":"' + $id + '","command":{"' + $name + '":{"path":' + (ConvertTo-Json $path -Compress) + '}}}'
    return [pscustomobject]@{ Id = $id; Frames = (Exchange $label $body) }
  }
  function SupportState { (Get-ChildItem $support -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($support.Length)) $($_.Length) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }) -join '|' }
  function IsError($r) { $r.Frames.Count -eq 1 -and $r.Frames[0].kind -eq 'error' -and $r.Frames[0].requestID -eq $r.Id -and $r.Frames[0].error.code -eq 'requestFailed' }

  [void](Exchange 'hello' '{"version":2,"kind":"hello","supportedVersions":[1,2],"clientID":"00000000-0000-4000-8000-0000000000a1"}')
  $pa = $projA -replace '\\', '/'

  $r = Cmd 'read-before-open' 'readProjectGraph' $pa
  Check (IsError $r) 'read before open: exactly one error frame carrying the request id'

  $r = Cmd 'open' 'openProject' $projA
  Check ($r.Frames.Count -eq 2 -and $r.Frames[0].kind -eq 'event' -and $r.Frames[1].kind -eq 'response' -and $r.Frames[1].requestID -eq $r.Id) 'openProject baseline: event then correlated response'

  $before = SupportState
  $r = Cmd 'read-open' 'readProjectGraph' $pa
  Check ($r.Frames.Count -eq 1 -and $r.Frames[0].kind -eq 'response' -and $r.Frames[0].requestID -eq $r.Id -and $null -ne $r.Frames[0].event.graphChanged -and $null -eq $r.Frames[0].sequence) 'joined local project: exactly one response, exact request id, no sequence, no event frame'

  Start-Sleep -Milliseconds 500
  Check ((SupportState) -eq $before) 'a successful read leaves the support directory byte-identical'

  $r = Cmd 'read-noncanonical' 'readProjectGraph' $projA
  Check (IsError $r) 'non-canonical spelling is refused, not redirected'

  $r = Cmd 'read-never-opened' 'readProjectGraph' $projB
  Check (IsError $r) 'never-opened project is refused'

  $id = Rid; $r = [pscustomobject]@{ Id = $id; Frames = (Exchange 'join-global' ('{"version":2,"kind":"request","requestID":"' + $id + '","command":{"openGlobalGraph":{}}}')) }
  Check ($r.Frames.Count -ge 1) 'global graph joined (baseline frames)'

  $r = Cmd 'join-remote' 'openProject' 'ssh://host/repository'
  Start-Sleep -Milliseconds 500
  $beforeRefusals = SupportState
  $r = Cmd 'read-global' 'readProjectGraph' 'graphcode://global'
  Check (IsError $r) 'global graph refused after joining it'
  $r = Cmd 'read-remote' 'readProjectGraph' 'ssh://host/repository'
  Check (IsError $r) 'remote project refused after joining it'

  Start-Sleep -Milliseconds 500
  Check ((SupportState) -eq $beforeRefusals) 'refused reads (global, remote) leave the support directory byte-identical'

  $r = Cmd 'unknown-command' 'readProjectGraphTypo' $pa
  Check ($r.Frames.Count -eq 1 -and $r.Frames[0].kind -eq 'error' -and $r.Frames[0].requestID -eq $r.Id -and $r.Frames[0].error.code -eq 'malformedEnvelope') 'unknown command answers with an error carrying the request id'

  $r = Cmd 'close' 'closeProject' $pa
  $r = Cmd 'read-after-close' 'readProjectGraph' $pa
  Check (IsError $r) 'read after close is refused'
  $r = Cmd 'read-after-close-again' 'readProjectGraph' $pa
  Check (IsError $r) 'project is still not reopened by a refused read'
  Check ($pump.Closed -eq $false) 'connection stays healthy throughout'
} finally {
  if ($cl) { $cl.Dispose() }
  [void]$ev.Set()
  if (-not $p.WaitForExit(10000)) { $p.Kill() }
  Lg("daemon exit=$($p.ExitCode)")
  New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
  [IO.File]::WriteAllLines($Out, $log)
}
if ($failures.Count -gt 0) { throw "wire contract failures: $($failures -join '; ')" }
Write-Host "readProjectGraph wire contract ok ($($log.Count) lines)"
