[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][ValidateSet("inventory", "dry-run", "unknown", "untracked-format", "foreign-fixture", "missing-providers")][string] $Contract
)

$ErrorActionPreference = "Stop"
$runner = Join-Path $RepositoryRoot "Tools\windows\validate.ps1"
$pwsh = [Environment]::ProcessPath
$executed = 0
$toolchain = $null

function Assert-HostTask([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw "Compiled host task contract: $Message" }
}

function Assert-DryRunBeforeEffects([string] $Source) {
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$errors)
  Assert-HostTask ($errors.Count -eq 0) "dry-run producer does not parse"
  $functions = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Invoke-Task"
    }, $true))
  Assert-HostTask ($functions.Count -eq 1) "task dispatcher missing or duplicated"
  $first = $functions[0].Body.EndBlock.Statements[0]
  Assert-HostTask ($first -is [Management.Automation.Language.IfStatementAst] -and
    $first.Clauses.Count -eq 1 -and $first.Clauses[0].Item1.Extent.Text -ceq '$DryRun') `
    "dry-run does not precede task effects"
  $body = $first.Clauses[0].Item2
  Assert-HostTask ($body.Statements[-1] -is [Management.Automation.Language.ReturnStatementAst]) "dry-run falls through to execution"
  $effects = @($body.FindAll({
      param($node)
      ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cne "Write-Output") -or
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -or
        $node -is [Management.Automation.Language.FileRedirectionAst]
    }, $true))
  Assert-HostTask ($effects.Count -eq 0) "dry-run performs an invocation, file write, or task action"
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
    $source = [IO.File]::ReadAllText($runner)
    Assert-DryRunBeforeEffects $source
    $executed++
    $mutations = @(
      $source.Replace('function Invoke-Task([string] $name) {',
        'function Invoke-Task([string] $name) { Invoke-Native "unexpected build" {}'),
      $source.Replace('if ($DryRun) {', 'if ($DryRun) { [IO.File]::WriteAllText("unexpected", "effect");')
    )
    foreach ($mutation in $mutations) {
      Assert-HostTask ($mutation -cne $source) "ineffective dry-run negative control"
      $refused = $false
      try { Assert-DryRunBeforeEffects $mutation } catch { $refused = $true }
      Assert-HostTask $refused "dry-run source admitted a build/write negative control"
      $executed++
    }
    $single = @(& $pwsh -NoLogo -NoProfile -NonInteractive -File $runner -Task swift-paths -DryRun)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $single.Count -eq 1 -and $single[0] -ceq "task=swift-paths") `
      "single-task dry run did not select exactly swift-paths"
    $executed++
    $provider = @(& $pwsh -NoLogo -NoProfile -NonInteractive -File $runner -Task provider-build -DryRun)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $provider.Count -eq 1 -and $provider[0] -ceq "task=provider-build") `
      "build-only dry run changed"
    $executed++
    $all = @(& $pwsh -NoLogo -NoProfile -NonInteractive -File $runner -Task all -DryRun)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $all.Count -eq 16 -and
      $all -cnotcontains "task=provider-build" -and $all -ccontains "task=terminal-gate") "all-task selection changed"
    $executed++
    $skipped = @(& $pwsh -NoLogo -NoProfile -NonInteractive -File $runner -Task all -SkipTask swift-paths -DryRun)
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
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$errors)
    Assert-HostTask ($errors.Count -eq 0) "validation source does not parse"
    foreach ($name in @("Resolve-SwiftExecutable", "Initialize-SwiftEnvironment")) {
      $definitions = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true))
      Assert-HostTask ($definitions.Count -eq 1) "missing or duplicated actual toolchain helper: $name"
      . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $SwiftExecutable = $env:GRAPHCODE_SWIFT633
    $toolchain = Resolve-SwiftExecutable
    Initialize-SwiftEnvironment $toolchain
    $version = @(& $toolchain --version 2>&1)
    Assert-HostTask ($LASTEXITCODE -eq 0 -and $version.Count -gt 0 -and
      [string]$version[0] -cmatch '^Swift version 6\.3\.3(?: \(|$)') "real formatter control requires pinned Swift 6.3.3"
    . (Join-Path $RepositoryRoot "Tools\windows\Tests\ValidationFixtureDirectory.ps1")
    $untrackedDirectory = Join-Path $RepositoryRoot "investigation\spikes\validation-runner-untracked"
    $untrackedFailure = $null
    $untrackedFixture = New-ValidationFixtureDirectory -Path $untrackedDirectory
    try {
      New-ValidationFixtureFile -Fixture $untrackedFixture -Name "Unformatted.swift" -Content "let value=1"
      $failure = $null
      try { & $runner -Task swift-format -SwiftExecutable $toolchain 2>&1 | ForEach-Object { Write-Host $_ } } catch { $failure = $_ }
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
      & $pwsh -NoLogo -NoProfile -NonInteractive -File $runner -Task swift-format -DryRun | Out-Null
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
  "missing-providers" {
    $absent = Join-Path ([IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid().ToString("N"))
    Assert-HostTask (-not (Test-Path -LiteralPath $absent)) "missing-provider fixture already exists"
    $env:GRAPHCODE_WINGHOSTTY_ROOT = Join-Path $absent "winghostty"
    $env:GRAPHCODE_ZMX_ROOT = Join-Path $absent "zmx"
    $output = @(& ([Environment]::ProcessPath) -NoLogo -NoProfile -NonInteractive -File $runner `
        -Task terminal-gate 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    Assert-HostTask ($exitCode -ne 0 -and ($output -join "`n").Contains(
      "Windows terminal gate provider worktrees unavailable; real smoke is mandatory.")) `
      "terminal-gate did not refuse the actual missing pinned providers"
    $executed++
  }
}

Assert-HostTask ($executed -gt 0) "no cases ran"
[ordered]@{
  suite = "HostTasks.$Contract"
  executed = $executed
  passed = $executed
  failed = 0
  skipped = 0
  toolchain = $toolchain
} | ConvertTo-Json -Compress | Write-Output
