$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "..\validate.ps1"
if (-not (Test-Path $runner)) {
  throw "RED: validation runner does not exist at $runner"
}

$tasks = & $runner -List
$expected = @(
  "swift-portable",
  "swift-contracts",
  "swift-production",
  "swift-paths",
  "swift-process",
  "swift-named-pipe",
  "remote-bridge",
  "remote-e2e",
  "swift-format",
  "visual-baseline",
  "tdd-evidence",
  "privacy",
  "terminal-gate",
  "windows-shell",
  "packaging",
  "hardening"
)
foreach ($task in $expected) {
  if ($tasks -notcontains $task) {
    throw "Validation task '$task' is missing"
  }
}

$dryRun = & $runner -Task swift-paths -DryRun
if ($LASTEXITCODE -ne 0) {
  throw "Dry run failed with exit code $LASTEXITCODE"
}
if (($dryRun -join "`n") -notmatch "swift-paths") {
  throw "Dry run did not name the selected task"
}

$pwsh = (Get-Process -Id $PID).Path
& $pwsh -NoProfile -File $runner -Task not-a-task *> $null
if ($LASTEXITCODE -eq 0) {
  throw "An unknown validation task succeeded"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$untrackedDirectory = Join-Path $repoRoot "investigation\spikes\validation-runner-untracked"
New-Item -ItemType Directory -Force $untrackedDirectory | Out-Null
try {
  "let value=1" | Set-Content (Join-Path $untrackedDirectory "Unformatted.swift")
  & $pwsh -NoProfile -File $runner -Task swift-format *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "An unformatted untracked Swift source was ignored"
  }
} finally {
  Remove-Item -LiteralPath $untrackedDirectory -Recurse -Force
}

$foreignJunction = Join-Path $repoRoot `
  "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\OwnershipSentinel"
New-Item -ItemType Directory -Force $foreignJunction | Out-Null
try {
  & $runner -Task swift-format -DryRun *> $null
  if (-not (Test-Path $foreignJunction)) {
    throw "A validation task removed resources owned by another task"
  }

  $windowsWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-hardening.yml") -Raw
  if ($windowsWorkflow -notmatch "(?s)full-pinned:.*GRAPHCODE_ZMX_ROOT.*validate\.ps1 -Task all.*Hardening\.Tests\.ps1 -Environment") {
    throw "RED: full-pinned Windows CI does not run real hardening after provider setup"
  }
  if ($windowsWorkflow -notmatch "GRAPHCODE_HARDENING_TARGET") {
    throw "RED: full-pinned Windows CI does not provide an owned environment harness"
  }
  $windowsShellWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-shell.yml") -Raw
  if ($windowsShellWorkflow -notmatch "Tools/windows/uia-live-gate\.ps1") {
    throw "RED: Windows shell CI does not include the UI Automation live gate"
  }
  $runnerSource = Get-Content $runner -Raw
  if ($runnerSource -notmatch '(?s)Pinned GraphCode Windows shell build and smoke.*?Native UI Automation live gate.*?uia-live-gate\.ps1') {
    throw "RED: Windows shell validation does not execute the UI Automation live gate"
  }
  if ($windowsWorkflow -notmatch "(?s)environment:.*Hardening\.Tests\.ps1 -Environment -SchemaOnly") {
    throw "RED: environment CI does not invoke the exact schema-only hardening contract"
  }
  $macWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\macos-shared-regression.yml") -Raw
  if ($macWorkflow -notmatch "brew install mise" -or
      $macWorkflow -notmatch "mise install" -or
      $macWorkflow -notmatch "mise exec -- make test") {
    throw "RED: macOS CI does not install and execute pinned mise.toml tools"
  }
} finally {
  Remove-Item -LiteralPath $foreignJunction -Recurse -Force -ErrorAction SilentlyContinue
}

$oldWinghosttyRoot = [Environment]::GetEnvironmentVariable(
  "GRAPHCODE_WINGHOSTTY_ROOT"
)
$oldZmxRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX_ROOT")
try {
  $env:GRAPHCODE_WINGHOSTTY_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-winghostty-provider"
  $env:GRAPHCODE_ZMX_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-zmx-provider"
  & $pwsh -NoProfile -File $runner -Task terminal-gate *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "terminal-gate passed without its pinned providers"
  }
} finally {
  if ($null -eq $oldWinghosttyRoot) {
    Remove-Item Env:GRAPHCODE_WINGHOSTTY_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_WINGHOSTTY_ROOT = $oldWinghosttyRoot
  }
  if ($null -eq $oldZmxRoot) {
    Remove-Item Env:GRAPHCODE_ZMX_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_ZMX_ROOT = $oldZmxRoot
  }
}

Write-Host "ValidationRunner.Tests.ps1: PASS"
exit 0
