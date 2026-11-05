param([Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot, [string] $AssemblyPath)
. (Join-Path $PSScriptRoot '..\CiContracts\AdapterSupport.ps1')
$production = Join-Path $RepositoryRoot 'Tools\windows\Tests\Hardening.Tests.ps1'
foreach ($name in @('Find-Bytes', 'Get-HighOutputDiagnostics', 'Get-HighOutputPayloadText')) {
  . (Get-ProductionFunction $production $name)
}

Test-RootCase 'diagnostics.positions-and-bounds' {
  $bytes = [Text.Encoding]::ASCII.GetBytes('START' + ('A' * 1024) + 'END')
  $actual = Get-HighOutputDiagnostics $bytes 'START' 'END'
  Assert-Root ($actual.capturedBytes -eq 1032 -and $actual.startOffset -eq 0 -and
    $actual.endOffset -eq 1029 -and $actual.prefix.Length -eq 512 -and $actual.suffix.Length -eq 512) `
    'Captured byte count, marker offsets, or bounded excerpts changed'
}
Test-RootCase 'diagnostics.end-without-start' {
  $actual = Get-HighOutputDiagnostics ([Text.Encoding]::ASCII.GetBytes('END')) 'START' 'END'
  Assert-Root ($actual.startOffset -eq -1 -and $actual.endOffset -eq 0) 'Missing start hid the end marker'
}
Test-RootCase 'diagnostics.empty-capture' {
  $actual = Get-HighOutputDiagnostics ([byte[]]::new(0)) 'START' 'END'
  Assert-Root ($actual.capturedBytes -eq 0 -and $actual.startOffset -eq -1 -and
    $actual.endOffset -eq -1 -and $actual.prefix -ceq '' -and $actual.suffix -ceq '') 'Empty capture changed'
}
$esc = [string][char]27
$complete = [ordered]@{
  plain = 'STARTAAAAEND'
  csi = "ST${esc}[0mARTAA${esc}[31mAAEN${esc}[0mD"
  wrapped = "STA`r`nRTAAAAE`r`nND"
  osc_bell = "START${esc}]0;END$([char]7)AAAAEND"
  osc_st_inside = "ST${esc}]0;title${esc}\ARTAAAAEND"
  osc_st_outside = "${esc}]0;before${esc}\STARTAAAAEND${esc}]0;after${esc}\"
}
foreach ($entry in $complete.GetEnumerator()) {
  Test-RootCase "payload.complete.$($entry.Key)" {
    $actual = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($entry.Value)) 'START' 'END'
    Assert-Root ($actual -ceq 'AAAA') 'Terminal framing corrupted completion payload'
  }
}
$incomplete = [ordered]@{
  empty = ''; missing_end = 'STARTAAAA'; missing_start = 'AAAAEND'
  reversed = 'ENDSTARTAAAA'; unterminated_osc = "${esc}]0;STARTAAAAEND"
}
foreach ($entry in $incomplete.GetEnumerator()) {
  Test-RootCase "payload.pending.$($entry.Key)" {
    $actual = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($entry.Value)) 'START' 'END'
    Assert-Root ($null -eq $actual) 'Incomplete markers were accepted'
  }
}
Test-RootCase 'payload.completed-empty' {
  $actual = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes('STARTEND')) 'START' 'END'
  Assert-Root ($null -ne $actual -and $actual -ceq '') 'Empty completion was confused with pending output'
}
Write-RootSummary 'host.hardening-source-and-diagnostics'
