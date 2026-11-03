param([Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot, [string] $AssemblyPath)
. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$production = Join-Path $RepositoryRoot 'Tools\windows\validate.ps1'
foreach ($name in @('Invoke-ZigResolverProbe', 'Write-ZigResolverDiagnostic', 'Resolve-ZigVersion')) {
  . (Get-ProductionFunction $production $name)
}
$canary = 'ghp_PRIVATE_CANARY'
function RootProbeCommand([string] $operation) {
  if ($operation -eq 'throw') { throw [ComponentModel.Win32Exception]::new(5, $canary) }
  $global:LASTEXITCODE = -1073741502
  '0.15.2'
  Write-Error $canary -ErrorAction Continue
}
Test-RootCase 'probe.stdout-stderr-native-exit' {
  $result = Invoke-ZigResolverProbe 'RootProbeCommand' 'version'
  Assert-Root ($result.Output -ceq '0.15.2' -and $result.ExitCode -eq -1073741502 -and
    $result.ErrorText.Contains($canary) -and $null -eq $result.Failure) 'Real probe lost stream separation or native exit'
}
Test-RootCase 'probe.launch-failure-nullable-exit' {
  $global:LASTEXITCODE = 123
  $result = Invoke-ZigResolverProbe 'RootProbeCommand' 'throw'
  Assert-Root ($null -eq $result.ExitCode -and $null -ne $result.Failure) 'Launch failure reused a stale exit code'
}

$configured = 'C:\fixture\configured\zig.exe'
$pathCandidate = 'C:\fixture\path\zig.exe'
$discovered = 'C:\fixture\discovered\zig.exe'
$repoRoot = 'C:\fixture\repo'
$environmentName = 'GRAPHCODE_ROOT_ZIG_TEST'
$prior = [Environment]::GetEnvironmentVariable($environmentName)
$state = @{
  Exists = @{}; Probes = @{}
  Calls = [Collections.Generic.List[string]]::new()
  Lines = [Collections.Generic.List[string]]::new()
  Warnings = [Collections.Generic.List[string]]::new()
  WriterFails = $false; WarningFails = $false
}
function Get-Command($Name, $ErrorAction) { [pscustomobject]@{ Source = $pathCandidate } }
function Get-ChildItem($Path, [switch] $Recurse, $Filter, [switch] $File, $ErrorAction) {
  foreach ($value in @($configured, $discovered)) { [pscustomobject]@{ FullName = $value } }
}
function Test-Path($LiteralPath, $PathType, $ErrorAction) { $state.Exists[$LiteralPath] -eq $true }
function Resolve-Path($LiteralPath) { [pscustomobject]@{ Path = $LiteralPath } }
function Invoke-ZigResolverProbe([string] $candidate, [string] $operation) {
  $key = "$candidate|$operation"
  $state.Calls.Add($key)
  if (-not $state.Probes.ContainsKey($key)) { throw "Unplanned probe $key" }
  $state.Probes[$key]
}
function Write-Host($Object) {
  if ($state.WriterFails) { throw $canary }
  $state.Lines.Add([string]$Object)
}
function Write-Warning($Message, $WarningAction) {
  $state.Warnings.Add([string]$Message)
  if ($state.WarningFails) { throw $canary }
}
function New-RootProbe($Output, $Exit = 0, $ErrorText = '', $Failure = $null) {
  [pscustomobject]@{ Output = $Output; ExitCode = $Exit; ErrorText = $ErrorText; Failure = $Failure }
}
function Reset-RootResolver {
  $state.Calls.Clear()
  $state.Lines.Clear()
  $state.Warnings.Clear()
  $state.WriterFails = $false
  $state.WarningFails = $false
  $state.Exists = @{ $configured = $true; $pathCandidate = $true; $discovered = $true }
  $state.Probes = @{}
  foreach ($candidate in @($configured, $pathCandidate, $discovered)) {
    $state.Probes["$candidate|version"] = New-RootProbe '0.15.2'
    $state.Probes["$candidate|env"] = New-RootProbe '{"version":"0.15.2","lib_dir":"C:\\fixture\\lib"}'
  }
  [Environment]::SetEnvironmentVariable($environmentName, $configured)
}
function Read-RootDiagnostic([int] $Index = 0) {
  Assert-Root ($state.Lines.Count -gt $Index) 'Diagnostic was not emitted'
  $line = $state.Lines[$Index]
  Assert-Root ($line.StartsWith('ZIG_RESOLVER_DIAGNOSTIC ') -and $line.Length -lt 2500 -and
    $line -notmatch 'ghp_PRIVATE_CANARY|userinfo|GITHUB_TOKEN') 'Diagnostic tag, bounds, or secret redaction changed'
  $line.Substring('ZIG_RESOLVER_DIAGNOSTIC '.Length) | ConvertFrom-Json
}
try {
  Test-RootCase 'resolver.configured-success' {
    Reset-RootResolver
    $result = @(Resolve-ZigVersion '0.15.2' $environmentName)
    Assert-Root ($result.Count -eq 1 -and $result[0] -ceq $configured -and $state.Lines.Count -eq 0 -and
      ($state.Calls -join ',') -ceq "$configured|version,$configured|env") 'Configured success changed probes, return stream, or diagnostics'
  }
  Test-RootCase 'resolver.fallback-order-deduplication' {
    Reset-RootResolver
    $state.Exists[$configured] = $false
    $state.Probes["$pathCandidate|version"] = New-RootProbe '0.16.0'
    $result = @(Resolve-ZigVersion '0.15.2' $environmentName)
    Assert-Root ($result.Count -eq 1 -and $result[0] -ceq $discovered -and
      ($state.Calls -join ',') -ceq "$pathCandidate|version,$discovered|version,$discovered|env") 'Fallback order or candidate deduplication changed'
    $missing = Read-RootDiagnostic
    $mismatch = Read-RootDiagnostic 1
    Assert-Root (-not $missing.exists -and $null -eq $missing.version -and $missing.source -eq 'configured' -and
      $mismatch.source -eq 'PATH' -and $mismatch.version.observedVersion -eq '0.16.0' -and
      $null -eq $mismatch.env) 'Missing candidate or version mismatch evidence changed'
  }
  Test-RootCase 'resolver.native-exit-redacted-fallback' {
    Reset-RootResolver
    $state.Probes["$configured|version"] = New-RootProbe $canary -1073741502 $canary
    $result = Resolve-ZigVersion '0.15.2' $environmentName
    $diagnostic = Read-RootDiagnostic
    Assert-Root ($result -ceq $pathCandidate -and $diagnostic.version.exitCodeHex -eq '0xC0000142' -and
      $null -eq $diagnostic.version.observedVersion -and $diagnostic.version.stderr.reason -eq 'unclassified') `
      'Nonzero exit, fallback, or redaction changed'
  }
  foreach ($variant in @('invalid', 'json')) {
    $text = if ($variant -eq 'invalid') { "invalid $canary" } else {
      '{"version":"0.15.2","lib_dir":"C:\\fixture\\absent","env":{"GITHUB_TOKEN":"ghp_PRIVATE_CANARY"}}'
    }
    Test-RootCase "resolver.env-exit.$variant" {
      Reset-RootResolver
      $state.Probes["$configured|env"] = New-RootProbe $text 9 "error: unable to find zig installation directory $canary"
      $result = Resolve-ZigVersion '0.15.2' $environmentName
      $diagnostic = Read-RootDiagnostic
      Assert-Root ($result -ceq $pathCandidate -and $diagnostic.reason -eq 'env-exit' -and
        $diagnostic.env.exitCode -eq 9 -and $diagnostic.env.stderr.reason -eq 'unable to find zig installation directory') `
        'Env failure or safe known reason changed'
      if ($variant -eq 'invalid') {
        Assert-Root ($diagnostic.env.parse -eq 'metadata-unavailable') 'Invalid JSON metadata changed'
      } else {
        Assert-Root ($diagnostic.env.parse -eq 'parsed' -and $diagnostic.env.libDirectoryPresent -eq $false) 'Missing lib metadata changed'
      }
    }
    Test-RootCase "resolver.env-zero-not-new-gate.$variant" {
      Reset-RootResolver
      $state.Probes["$configured|env"] = New-RootProbe $text
      $result = Resolve-ZigVersion '0.15.2' $environmentName
      Assert-Root ($result -ceq $configured -and $state.Lines.Count -eq 0) 'Diagnostic metadata introduced a new acceptance gate'
    }
  }
  foreach ($operation in @('version', 'env')) {
    Test-RootCase "resolver.launch-exception.$operation" {
      Reset-RootResolver
      $errorRecord = [Management.Automation.ErrorRecord]::new(
        [Management.Automation.RuntimeException]::new($canary, [ComponentModel.Win32Exception]::new(5, $canary)),
        'Launch', [Management.Automation.ErrorCategory]::OpenError, $null)
      $state.Probes["$configured|$operation"] = New-RootProbe $null $null '' $errorRecord
      $failure = $null
      try { Resolve-ZigVersion '0.15.2' $environmentName | Out-Null } catch { $failure = $_ }
      $diagnostic = Read-RootDiagnostic
      $expectedCalls = if ($operation -eq 'version') { 1 } else { 2 }
      Assert-Root ($null -ne $failure -and $failure.ToString() -notmatch $canary -and
        $state.Calls.Count -eq $expectedCalls -and $diagnostic.reason -eq "$operation-exception" -and
        $null -eq $diagnostic.$operation.exitCode -and $diagnostic.$operation.nativeErrorCode -eq 5) `
        'Launch exception did not stop safely with nullable exit and native error'
    }
  }
  Test-RootCase 'resolver.writer-failure' {
    Reset-RootResolver
    $state.Probes["$configured|version"] = New-RootProbe '0.16.0'
    $state.WriterFails = $true
    $result = Resolve-ZigVersion '0.15.2' $environmentName
    Assert-Root ($result -ceq $pathCandidate -and $state.Warnings.Count -eq 1) 'Writer failure changed fallback'
  }
  Test-RootCase 'resolver.both-writers-fail' {
    Reset-RootResolver
    $state.Probes["$configured|version"] = New-RootProbe '0.16.0'
    $state.WriterFails = $true
    $state.WarningFails = $true
    $result = @(Resolve-ZigVersion '0.15.2' $environmentName)
    Assert-Root ($result.Count -eq 1 -and $result[0] -ceq $pathCandidate -and
      ($state.Calls -join ',') -ceq "$configured|version,$pathCandidate|version,$pathCandidate|env") 'Both writers changed selection'
  }
  Test-RootCase 'resolver.both-writers-original-missing-guard' {
    Reset-RootResolver
    $state.WriterFails = $true
    $state.WarningFails = $true
    $state.Exists.Clear()
    $failure = $null
    try { Resolve-ZigVersion '0.15.2' $environmentName | Out-Null } catch { $failure = $_ }
    Assert-Root ($null -ne $failure -and
      $failure.ToString() -ceq "Zig 0.15.2 is required for the pinned Windows provider; set $environmentName.") 'Diagnostics masked the missing Zig guard'
  }
  $unsafeVersions = [ordered]@{
    unicode = ([string][char]0x0661) + '.2.3'
    over_limit = '1.2.3+' + ('a' * 65)
  }
  foreach ($entry in $unsafeVersions.GetEnumerator()) {
    foreach ($operation in @('version', 'env')) {
      Test-RootCase "diagnostic.unsafe-version.$($entry.Key).$operation" {
        Reset-RootResolver
        $text = if ($operation -eq 'version') { $entry.Value } else { @{ version = $entry.Value } | ConvertTo-Json -Compress }
        $probe = New-RootProbe $text 1
        if ($operation -eq 'version') {
          Write-ZigResolverDiagnostic $configured 'configured' '0.15.2' $true 'version-exit' $probe $null
        } else {
          Write-ZigResolverDiagnostic $configured 'configured' '0.15.2' $true 'env-exit' (New-RootProbe '0.15.2') $probe
        }
        $diagnostic = Read-RootDiagnostic
        $summary = $diagnostic.$operation
        Assert-Root ($null -eq $summary.observedVersion -and
          $summary.stdout.bytes -eq [Text.Encoding]::UTF8.GetByteCount($text) -and
          $summary.stdout.sha256.Length -eq 64 -and -not $state.Lines[0].Contains($entry.Value)) 'Unsafe version was not reduced to exact byte count/hash'
      }
    }
  }
  $unsafeCandidates = [ordered]@{
    userinfo = 'https://userinfo@github.com/zig'
    secret = 'C:\ghp_PRIVATE_CANARY\zig.exe'
    over_limit = 'C:\' + ('x' * 520)
  }
  foreach ($entry in $unsafeCandidates.GetEnumerator()) {
    Test-RootCase "diagnostic.candidate.$($entry.Key)" {
      Reset-RootResolver
      Write-ZigResolverDiagnostic $entry.Value 'configured' '0.15.2' $true 'version-exit' (New-RootProbe ($canary * 2000) 1) $null
      $diagnostic = Read-RootDiagnostic
      Assert-Root ($diagnostic.candidate -ceq '[omitted]' -and $diagnostic.version.stdout.bytes -gt 16384) 'Candidate redaction or output cap changed'
    }
  }
} finally {
  [Environment]::SetEnvironmentVariable($environmentName, $prior)
}
Write-RootSummary 'host.zig-resolver'
