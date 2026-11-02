param([Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot, [string] $AssemblyPath)
. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$runner = Join-Path $RepositoryRoot 'Tools\windows\validate.ps1'
$expected = @(& $runner -List)
$observed = [Collections.Generic.List[string]]::new()

function Assert-PartitionParts([string[]] $Lines) {
  $shell = @($Lines | Where-Object { $_ -like 'task=windows-shell *' })
  Assert-Root (@($shell | Where-Object { $_ -match 'part=(all|integration) ' }).Count -gt 0) 'No shell integration coverage'
  $complete = $false
  foreach ($count in @($shell | ForEach-Object {
    if ($_ -notmatch 'part=(all|unit|integration) shard=(\d+)/(\d+)') { throw 'Malformed shell dry-run evidence' }
    if ($Matches[1] -ne 'integration') { [int]$Matches[3] }
  } | Sort-Object -Unique)) {
    $seen = @($shell | ForEach-Object {
      if ($_ -match "part=(all|unit) shard=(\d+)/$count(?: |$)") { [int]$Matches[2] }
    } | Sort-Object -Unique)
    if ($count -gt 0 -and $seen.Count -eq $count -and ($seen -join ',') -ceq ((0..($count - 1)) -join ',')) {
      $complete = $true
    }
  }
  Assert-Root $complete 'No complete shell unit shard partition'
  $packaging = @($Lines | Where-Object { $_ -like 'task=packaging *' } | ForEach-Object { ($_ -split 'part=')[1] })
  Assert-Root ($packaging -contains 'all' -or ($packaging -contains 'contracts' -and $packaging -contains 'real')) 'Missing packaging part'
}

foreach ($file in @('windows-shell.yml', 'windows-port-validation.yml', 'windows-hardening.yml')) {
  $source = (Get-Content -LiteralPath (Join-Path $RepositoryRoot ".github\workflows\$file") -Raw).Replace("`r`n", "`n")
  $jobsAt = [regex]::Match($source, '(?m)^jobs:\s*$')
  if (-not $jobsAt.Success) { throw "Missing jobs mapping: $file" }
  $body = $source.Substring($jobsAt.Index + $jobsAt.Length)
  $heads = [regex]::Matches($body, '(?m)^  ([A-Za-z0-9_-]+):[ \t]*$')
  foreach ($index in 0..($heads.Count - 1)) {
    $end = if ($index + 1 -lt $heads.Count) { $heads[$index + 1].Index } else { $body.Length }
    $job = $body.Substring($heads[$index].Index, $end - $heads[$index].Index)
    if ($job -match '(?m)^    if:.*github\.event_name ==') { continue }
    $shards = @('')
    $matrix = [regex]::Match($job, '(?m)^\s+shard:\s*\[([0-9, ]+)\]')
    if ($matrix.Success) { $shards = @($matrix.Groups[1].Value -split ',\s*') }
    $runs = [regex]::Matches($job, '(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 (.+)$')
    $ordinal = 0
    foreach ($run in $runs) {
      foreach ($shard in $shards) {
        $id = "workflow.$file.$($heads[$index].Groups[1].Value).$ordinal.$shard".TrimEnd('.')
        Test-RootCase $id {
          $text = $run.Groups[1].Value.Trim().Replace('${{ matrix.shard }}', $shard)
          Assert-Root (-not $text.Contains('${{')) 'Unsupported expression in workflow validation arguments'
          $tokens = @($text -split '\s+')
          $arguments = @{ DryRun = $true }
          for ($position = 0; $position -lt $tokens.Count; $position++) {
            $name = $tokens[$position].TrimStart('-')
            switch ($name) {
              { $_ -in @('SkipTrayLive', 'SkipWslRemoteE2E') } { $arguments[$name] = $true }
              { $_ -in @('Task', 'SkipTask') } { $arguments[$name] = @($tokens[++$position] -split ',') }
              { $_ -in @('ShellPart', 'ShellTestShard', 'ShellTestShardCount', 'ShellTestManifest', 'PackagingPart') } {
                $arguments[$name] = $tokens[++$position]
              }
              default { throw "Unsupported dry-run parameter: $name" }
            }
          }
          $output = @(& $runner @arguments)
          $lines = @($output | Where-Object { "$_" -match '^task=' })
          Assert-Root ($lines.Count -gt 0) 'Workflow dry-run executed no tasks'
          foreach ($line in $lines) { $observed.Add("$line") }
        }
      }
      $ordinal++
    }
  }
}
Test-RootCase 'coverage.all-listed-tasks' {
  Assert-Root ($expected.Count -gt 0 -and $observed.Count -gt 0) 'No task inventory or dry-run output'
  $covered = @($observed | ForEach-Object { ($_ -split ' ')[0].Substring(5) } | Sort-Object -Unique)
  $missing = @($expected | Where-Object { $covered -cnotcontains $_ })
  Assert-Root ($missing.Count -eq 0) "Missing PR tasks: $($missing -join ', ')"
}
Test-RootCase 'coverage.all-parts' { Assert-PartitionParts $observed.ToArray() }
$fixture = @(
  'task=windows-shell part=unit shard=0/3', 'task=windows-shell part=unit shard=1/3',
  'task=windows-shell part=unit shard=2/3', 'task=windows-shell part=integration shard=0/1',
  'task=packaging part=contracts', 'task=packaging part=real'
)
foreach ($kind in @('complete', 'missing-integration', 'missing-unit-shard', 'missing-packaging-real')) {
  Test-RootCase "control.$kind" {
    $lines = switch ($kind) {
      'complete' { $fixture }
      'missing-integration' { $fixture | Where-Object { $_ -notmatch 'part=integration' } }
      'missing-unit-shard' { $fixture | Where-Object { $_ -notmatch 'shard=2/3' } }
      'missing-packaging-real' { $fixture | Where-Object { $_ -cne 'task=packaging part=real' } }
    }
    $accepted = $true
    try { Assert-PartitionParts @($lines) } catch { $accepted = $false }
    Assert-Root ($accepted -eq ($kind -eq 'complete')) "Partition guard accepted $kind"
  }
}
Write-RootSummary 'host.ci-partition'
