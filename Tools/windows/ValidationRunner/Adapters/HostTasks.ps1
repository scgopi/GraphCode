[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][ValidateSet("inventory", "dry-run", "unknown", "untracked-format", "foreign-fixture")][string] $Contract
)

$ErrorActionPreference = "Stop"
$runner = Join-Path $RepositoryRoot "Tools\windows\validate.ps1"
$executed = 0

function Assert-HostTask([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw "Compiled host task contract: $Message" }
}

switch ($Contract) {
  "inventory" {
    $expected = @("swift-portable", "swift-contracts", "swift-production", "swift-paths",
      "swift-process", "swift-named-pipe", "remote-bridge", "remote-e2e", "swift-format",
      "visual-baseline", "tdd-evidence", "privacy", "terminal-gate", "windows-shell",
      "packaging", "hardening", "provider-build")
    $actual = @(& $runner -List)
    Assert-HostTask ($LASTEXITCODE -eq 0) "task listing failed"
    Assert-HostTask ($actual.Count -eq $expected.Count) "task count changed"
    foreach ($task in $expected) {
      Assert-HostTask (@($actual | Where-Object { $_ -ceq $task }).Count -eq 1) "missing or duplicated task $task"
      $executed++
    }
  }
  "dry-run" {
    $single = @(& $runner -Task swift-paths -DryRun)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $single.Count -eq 1 -and $single[0] -ceq "task=swift-paths") `
      "single-task dry run did not select exactly swift-paths"
    $executed++
    $provider = @(& $runner -Task provider-build -DryRun)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $provider.Count -eq 1 -and $provider[0] -ceq "task=provider-build") `
      "build-only dry run changed"
    $executed++
    $all = @(& $runner -Task all -DryRun)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $all.Count -eq 16 -and
      $all -cnotcontains "task=provider-build" -and $all -ccontains "task=terminal-gate") "all-task selection changed"
    $executed++
    $skipped = @(& $runner -Task all -SkipTask swift-paths -DryRun)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $skipped.Count -eq 15 -and
      $skipped -cnotcontains "task=swift-paths") "skip-task selection changed"
    $executed++
  }
  "unknown" {
    $failure = $null
    try { & $runner -Task not-a-task | Out-Null } catch { $failure = $_ }
    Assert-HostTask ($null -ne $failure -and
      $failure.Exception -is [Management.Automation.ParameterBindingException]) "unknown task did not fail parameter validation"
    $executed++
  }
  "untracked-format" {
    . (Join-Path $RepositoryRoot "Tools\windows\Tests\ValidationFixtureDirectory.ps1")
    $untrackedDirectory = Join-Path $RepositoryRoot "investigation\spikes\validation-runner-untracked"
    $untrackedFailure = $null
    $untrackedFixture = New-ValidationFixtureDirectory -Path $untrackedDirectory
    try {
      New-ValidationFixtureFile -Fixture $untrackedFixture -Name "Unformatted.swift" -Content "let value=1"
      $failure = $null
      try { & $runner -Task swift-format 2>&1 | ForEach-Object { Write-Host $_ } } catch { $failure = $_ }
      $expectedPrefix = "Swift formatting: " + (Join-Path $untrackedDirectory "Unformatted.swift") + " failed with exit code "
      Assert-HostTask ($null -ne $failure -and
        $failure.Exception.Message.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) `
        "untracked formatter did not report its actual formatting failure"
      $executed++
    } catch {
      $untrackedFailure = $_
      throw
    } finally {
      Remove-ValidationFixtureDirectory -Fixture $untrackedFixture -PrimaryError $untrackedFailure
    }
  }
  "foreign-fixture" {
    . (Join-Path $RepositoryRoot "Tools\windows\Tests\ValidationFixtureDirectory.ps1")
    $foreignJunction = Join-Path $RepositoryRoot `
      "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\OwnershipSentinel"
    $foreignFailure = $null
    $foreignFixture = New-ValidationFixtureDirectory -Path $foreignJunction
    try {
      & $runner -Task swift-format -DryRun | Out-Null
      Assert-HostTask ($LASTEXITCODE -eq 0) "foreign-fixture dry run failed"
      Assert-HostTask (Test-Path -LiteralPath $foreignJunction) "validation removed another task's resource"
      $executed++
    } catch {
      $foreignFailure = $_
      throw
    } finally {
      Remove-ValidationFixtureDirectory -Fixture $foreignFixture -PrimaryError $foreignFailure
    }
  }
}

Assert-HostTask ($executed -gt 0) "no cases ran"
[ordered]@{
  suite = "HostTasks.$Contract"
  executed = $executed
  passed = $executed
  failed = 0
  skipped = 0
} | ConvertTo-Json -Compress | Write-Output
