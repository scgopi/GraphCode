param([Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot, [string] $AssemblyPath)
. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$shell = Join-Path $RepositoryRoot 'Tools\windows\Tests\WindowsShell.Tests.ps1'
. (Get-ProductionFunction $shell 'Invoke-Native')
$sectionCatalog = @('Probe section')
$sectionPlan = [pscustomobject]@{ Assignment = @{ 'Probe section' = 0 } }
$Shard = 0
$ShardCount = 1
$executedSections = [Collections.Generic.List[object]]::new()
$summaries = [ordered]@{
  zero_all = 'All 0 tests passed.'
  failed = '0 passed; 0 skipped; 1 failed.'
  skipped_only = '0 passed; 2 skipped; 0 failed.'
}
foreach ($entry in $summaries.GetEnumerator()) {
  Test-RootCase "section.reject.$($entry.Key)" {
    $rejected = $false
    try {
      Invoke-Native 'Probe section' {
        # $zig test src\Probe.zig --test-filter unmatched
        $entry.Value
        $global:LASTEXITCODE = 0
      } 6> $null
    } catch { $rejected = $true }
    Assert-Root ($rejected -and $executedSections.Count -eq 0) 'Zero executed tests were recorded as passing'
  }
}
Test-RootCase 'section.positive-two-invocations' {
  Invoke-Native 'Probe section' {
    # $zig test src\Probe.zig
    # $zig test src\Second.zig
    'All 3 tests passed.'
    '2 passed; 1 skipped; 0 failed.'
    $global:LASTEXITCODE = 0
  } 6> $null
  Assert-Root ($executedSections.Count -eq 1 -and $executedSections[0].positiveSummaries -eq 2 -and
    $executedSections[0].zigTestInvocations -eq 2) 'Positive per-invocation evidence was not recorded'
}
Test-RootCase 'section.reject.missing-second-summary' {
  $rejected = $false
  try {
    Invoke-Native 'Probe section' {
      # $zig test src\Probe.zig
      # $zig test src\Second.zig
      'All 3 tests passed.'
      $global:LASTEXITCODE = 0
    } 6> $null
  } catch { $rejected = $true }
  Assert-Root ($rejected -and $executedSections.Count -eq 1) 'One summary satisfied two Zig invocations'
}
Test-RootCase 'section.reject.native-nonzero' {
  $rejected = $false
  try {
    Invoke-Native 'Probe section' {
      # $zig test src\Probe.zig
      'All 3 tests passed.'
      $global:LASTEXITCODE = 7
    } 6> $null
  } catch { $rejected = $true }
  Assert-Root ($rejected -and $executedSections.Count -eq 1) 'Nonzero exit was recorded as passing'
}

$plans = @()
foreach ($index in 0..2) {
  $plans += & $shell -PlanOnly -Shard $index -ShardCount 3 | Out-String | ConvertFrom-Json
}
$whole = & $shell -PlanOnly | Out-String | ConvertFrom-Json
$catalog = @($whole.catalog)
Test-RootCase 'plan.unsharded-catalog' {
  Assert-Root ($catalog.Count -ge 40 -and (@($whole.assigned) -join "`n") -ceq ($catalog -join "`n")) `
    'Unsharded catalog is empty, truncated, or reordered'
}
Test-RootCase 'plan.complete-disjoint-three-shards' {
  $assigned = @($plans | ForEach-Object { $_.assigned })
  Assert-Root ($assigned.Count -eq $catalog.Count -and @($assigned | Sort-Object -Unique).Count -eq $catalog.Count -and
    @($catalog | Where-Object { $assigned -cnotcontains $_ }).Count -eq 0 -and
    @($plans | Where-Object { @($_.assigned).Count -eq 0 }).Count -eq 0) 'Shard assignment lost completeness or disjointness'
}
Test-RootCase 'plan.workflow-agreement' {
  $text = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\windows-shell.yml') -Raw
  Assert-Root ($text -match '(?m)^\s+shard: \[0, 1, 2\]\s*$' -and
    $text -match '-ShellTestShardCount 3 ' -and
    $text -match 'Test-ShellSectionManifests\.ps1 -Directory \.ci-sections -ShardCount 3') 'Workflow and section shard counts disagree'
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('root-sections-' + [guid]::NewGuid().ToString('N'))
$verifier = Join-Path $RepositoryRoot 'Tools\windows\Test-ShellSectionManifests.ps1'
foreach ($kind in @('complete', 'missing-section', 'duplicate-section', 'zero-tests', 'skipped-assignment', 'missing-shard')) {
  Test-RootCase "manifest.$kind" {
    $manifests = @($plans | ForEach-Object {
      [pscustomobject]@{
        schemaVersion = 1; shard = $_.shard; shardCount = 3; catalog = @($_.catalog); assigned = @($_.assigned)
        executed = @($_.assigned | ForEach-Object {
          [pscustomobject]@{ name = $_; seconds = 1; zigTestInvocations = 1; positiveSummaries = 1 }
        })
      }
    })
    switch ($kind) {
      'missing-section' {
        $manifests[1].executed = @($manifests[1].executed | Select-Object -Skip 1)
        $manifests[1].assigned = @($manifests[1].assigned | Select-Object -Skip 1)
      }
      'duplicate-section' {
        $manifests[0].executed += @($manifests[1].executed[0])
        $manifests[0].assigned += @($manifests[1].assigned[0])
      }
      'zero-tests' { $manifests[2].executed[0].positiveSummaries = 0 }
      'skipped-assignment' { $manifests[2].executed = @($manifests[2].executed | Select-Object -SkipLast 1) }
      'missing-shard' { $manifests[2] = $null }
    }
    $directory = Join-Path $scratch $kind
    $null = New-Item -ItemType Directory -Path $directory -Force
    foreach ($manifest in $manifests) {
      if ($null -ne $manifest) {
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $directory "shard-$($manifest.shard).json")
      }
    }
    $accepted = $true
    try { & $verifier -Directory $directory -ShardCount 3 | Out-Null } catch { $accepted = $false }
    Assert-Root ($accepted -eq ($kind -eq 'complete')) "Manifest verifier changed its decision for $kind"
  }
}
Write-RootSummary 'host.shell-section-gate'
