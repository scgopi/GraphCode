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
  if ($windowsWorkflow -notmatch "(?s)full-pinned:.*bootstrap\.ps1.*validate\.ps1 -Task all.*Hardening\.Tests\.ps1 -Environment") {
    throw "RED: full-pinned Windows CI does not run real hardening after provider setup"
  }
  if ($windowsWorkflow -notmatch "GRAPHCODE_HARDENING_TARGET") {
    throw "RED: full-pinned Windows CI does not provide an owned environment harness"
  }
  $hardeningSource = Get-Content (Join-Path $PSScriptRoot "Hardening.Tests.ps1") -Raw
  foreach ($stage in @("real zmx/ConPTY terminal matrix", "real GraphCode shell matrix")) {
    if ($hardeningSource -notmatch ([regex]::Escape($stage) + ' failed \(exit=\$LASTEXITCODE; hex=')) {
      throw "Hardening stage failure omits the native exit code: $stage"
    }
  }
  & {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
      $hardeningSource, [ref]$tokens, [ref]$errors)
    foreach ($name in @("Find-Bytes", "Get-HighOutputDiagnostics", "Get-HighOutputPayloadText")) {
      $function = $ast.Find({
          param($node)
          $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
        }, $true)
      if (-not $function) { throw "RED: high-output diagnostics helper is missing: $name" }
      . ([scriptblock]::Create($function.Extent.Text))
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes("START" + ("A" * 1024) + "END")
    $diagnostics = Get-HighOutputDiagnostics $bytes "START" "END"
    if ($diagnostics.capturedBytes -ne $bytes.Length -or
        $diagnostics.startOffset -ne 0 -or $diagnostics.endOffset -ne 1029 -or
        $diagnostics.prefix.Length -ne 512 -or $diagnostics.suffix.Length -ne 512) {
      throw "High-output diagnostics lost marker positions or exceeded transcript bounds"
    }
    $partial = Get-HighOutputDiagnostics ([Text.Encoding]::ASCII.GetBytes("END")) "START" "END"
    if ($partial.startOffset -ne -1 -or $partial.endOffset -ne 0) {
      throw "High-output diagnostics hide an end marker when the start marker is missing"
    }
    $empty = Get-HighOutputDiagnostics ([byte[]]::new(0)) "START" "END"
    if ($empty.capturedBytes -ne 0 -or $empty.startOffset -ne -1 -or
        $empty.endOffset -ne -1 -or $empty.prefix -ne "" -or $empty.suffix -ne "") {
      throw "High-output diagnostics cannot report an empty capture"
    }
    $escape = [string][char]27
    $captures = @(
      "STARTAAAAEND",
      "ST${escape}[0mARTAA${escape}[31mAAEN${escape}[0mD",
      "STA`r`nRTAAAAE`r`nND",
      "START${escape}]0;END$([char]7)AAAAEND",
      "ST${escape}]0;title${escape}\ARTAAAAEND",
      "${escape}]0;before${escape}\STARTAAAAEND${escape}]0;after${escape}\"
    )
    foreach ($capture in $captures) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($payload -cne "AAAA") {
        throw "RED: high-output completion must survive terminal framing inside markers"
      }
    }
    foreach ($capture in @("", "STARTAAAA", "AAAAEND", "ENDSTARTAAAA",
        "${escape}]0;STARTAAAAEND")) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($null -ne $payload) { throw "Incomplete or reversed output markers were accepted" }
    }
    $emptyPayload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes("STARTEND")) "START" "END"
    if ($null -eq $emptyPayload -or $emptyPayload -cne "") {
      throw "Empty completed output must reach the length/hash checks, not look pending"
    }
  }
  if ($hardeningSource -notmatch
      '(?s)if \(-not \$completed\).*?Get-HighOutputDiagnostics.*?HARDENING_OUTPUT_DIAGNOSTICS_JSON=.*?Assert-True \$completed') {
    throw "RED: real high-output failure omits bounded transcript diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)if \(\$LASTEXITCODE -ne 0\) \{\s*\$output \| Write-Output\s*throw "hardening repeated run') {
    throw "RED: failed repeated hardening discards its child diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)\$shellVersion\s*=\s*\(& \$shell --version.*?-Version \$shellVersion') {
    throw "RED: post-release hardening does not preserve the built shell version"
  }
  $windowsShellWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-shell.yml") -Raw
  $windowsPortWorkflow = Get-Content `
    (Join-Path $repoRoot ".github\workflows\windows-port-validation.yml") -Raw
  foreach ($workflow in @($windowsWorkflow, $windowsShellWorkflow, $windowsPortWorkflow)) {
    if ($workflow -notmatch
        "compnerd/gha-setup-swift@397094e75494a93fa8d81db0268dbc8f5d6cf7c6" -or
        $workflow -notmatch "swift-version: swift-6\.3\.3-release" -or
        $workflow -notmatch "swift-build: 6\.3\.3-RELEASE") {
      throw "RED: pinned Windows CI does not install Swift 6.3.3 without WinGet"
    }
  }
  if ($windowsShellWorkflow -notmatch "bootstrap\.ps1") {
    throw "RED: Windows shell CI does not bootstrap exact dependencies"
  }
  if ($windowsShellWorkflow -notmatch "validate\.ps1 -Task windows-shell -SkipTrayLive" -or
      $windowsPortWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "Hardening\.Tests\.ps1 -Environment -SkipTrayLive") {
    throw "RED: hosted Windows CI does not explicitly declare unsupported interactive or WSL fixtures"
  }
  if ($windowsShellWorkflow -notmatch '(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 -Task windows-shell\b') {
    throw "RED: Windows shell CI does not invoke the shell task containing live UI Automation"
  }
  $runnerSource = Get-Content $runner -Raw
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*& .*?Packaging\.Signing\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run signed catalog integrity contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*& .*?Packaging\.Rollback\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run rollback preservation contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*& .*?Packaging\.Standalone\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run standalone setup contracts"
  }
  foreach ($contract in @("Packaging.ScriptSigning.Tests.ps1", "Packaging.Scheduler.Tests.ps1")) {
    if ($runnerSource -notmatch ('(?s)"packaging" \{\s*& .*?' + [regex]::Escape($contract) + '.*?Packaging\.Tests\.ps1')) {
      throw "RED: packaging validation does not run $contract"
    }
  }
  if ($runnerSource -notmatch '(?s)"terminal-gate" \{\s*& .*?ProviderPins\.Tests\.ps1.*?TerminalGate\.Tests\.ps1') {
    throw "RED: terminal validation does not run provider pin no-divergence contracts"
  }
  foreach ($source in @($runnerSource, $hardeningSource)) {
    if ($source -notmatch '-StubResponseDelayMilliseconds 150') {
      throw "RED: shell validation does not exercise delayed correlated responses"
    }
  }
  if ($runnerSource -notmatch '(?s)Pinned GraphCode Windows shell build and smoke.*?Native UI Automation live gate.*?uia-live-gate\.ps1') {
    throw "RED: Windows shell validation does not execute the UI Automation live gate"
  }
  $uiaLiveGateSource = Get-Content (Join-Path $repoRoot "Tools\windows\uia-live-gate.ps1") -Raw
  if ($uiaLiveGateSource -notmatch 'AttachThreadInput' -or
  $uiaLiveGateSource -notmatch 'keybd_event\(0x12, 0, 0, UIntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch 'SetActiveWindow\(window\)' -or
  $uiaLiveGateSource -notmatch 'PostMessage\(window, 0x0101, \(UIntPtr\)key, IntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch '\[DllImport\("kernel32\.dll"\)\]\s*private static extern uint GetCurrentThreadId' -or
      $uiaLiveGateSource -notmatch 'IsForegroundWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch 'UIA_FOCUS_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch '(?s)function Hide-TestProviderZmxWindows.*?\[string\]\$_\.ExecutablePath\)\s+-eq\s+\$providerZmx.*?HideProcessWindows.*?HideWindow\(\$foreground\)' -or
      $uiaLiveGateSource -notmatch 'function Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Test-FocusedElementIdentity \$candidate \$element \$expectedAutomationId' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::ActivateWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch '\$element\.SetFocus\(\)' -or
      $uiaLiveGateSource -notmatch 'Retain-FocusWithRetry \$shellWindow \$safeFocusRow \$safeRowId "before-retention"' -or
      $uiaLiveGateSource -notmatch '\$backendFocus = Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Product Settings backend control could not retain foreground focus' -or
      $uiaLiveGateSource -notmatch '\$cancelFocus = Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Product Settings model control could not retain foreground focus') {
    throw "RED: UIA live gate does not prove foreground ownership before accepting row focus"
  }
  $shellTests = Get-Content (Join-Path $PSScriptRoot "WindowsShell.Tests.ps1") -Raw
  if ($shellTests -notmatch '(?s)Windows update feed executable tests.*?zig test src\\WindowsUpdates\.zig.*?-lwinhttp') {
    throw "RED: Windows shell validation does not run the native updater tests"
  }
  if ($runnerSource -notmatch '\$SkipWslRemoteE2E' -or
      $runnerSource -notmatch '"--skip-local-wsl"') {
    throw "RED: hosted validation cannot explicitly isolate unavailable local WSL fixtures"
  }
  $privacyRaceSource = Get-Content `
    (Join-Path $repoRoot "Tools\windows\Tests\RemoteBridgePrivacyRace.Tests.ps1") -Raw
  if ($privacyRaceSource -notmatch '\$AvailableProcessorCount = \[Environment\]::ProcessorCount' -or
      $privacyRaceSource -notmatch '\$remoteProcessCount = 1' -or
      $privacyRaceSource -notmatch '\[Math\]::Min\(24, \[Math\]::Max\(4, \$processorCount \* 2\)\)' -or
      $privacyRaceSource -notmatch 'GRAPHCODE_REMOTE_BRIDGE_TEST_TIMEOUT_MULTIPLIER = "3"') {
    throw "RED: remote bridge privacy race does not scale bounded concurrency to runner capacity"
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
  $requiredWorkflows = [ordered]@{
    "macos-shared-regression.yml" = $macWorkflow
    "windows-shell.yml" = $windowsShellWorkflow
    "windows-port-validation.yml" = $windowsPortWorkflow
    "windows-hardening.yml" = $windowsWorkflow
  }
  foreach ($entry in $requiredWorkflows.GetEnumerator()) {
    $trigger = [regex]::Match(
      $entry.Value,
      '(?ms)^  pull_request:(?<settings>.*?)(?=^[^\s#]|^  [A-Za-z_][A-Za-z0-9_-]*:|\z)')
    $settings = [regex]::Replace($trigger.Groups["settings"].Value, '(?m)#.*$', '').Trim()
    if (-not $trigger.Success -or $settings -notin @("", "{}")) {
      throw "RED: $($entry.Key) must report required checks for every PR, including documentation-only changes"
    }
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
