[CmdletBinding()]
param(
  [switch] $List,
  [string] $ProductPinsPath,
  [string] $GatePinsPath
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$gateRoot = Join-Path $repoRoot "investigation\spikes\windows-terminal-gate"

if ($List) {
  @(
    "provider-pins",
    "graphcode-owned-host",
    "persistent-zmx",
    "lifecycle-contract",
    "unrepaired-focus-guards",
    "restored-terminal-route"
  )
  exit 0
}

function Assert-Contract([object] $condition, [string] $message) {
  $values = @($condition)
  if ($values.Count -ne 1 -or -not [bool] $values[0]) {
    throw "Windows terminal gate contract: $message"
  }
}

foreach ($path in @(
    "build.zig",
    "build.zig.zon",
    "src\main.zig",
    "provider-pins.json",
    "README.md",
    "..\..\..\Tools\windows\terminal-gate.ps1"
  )) {
  Assert-Contract (Test-Path -LiteralPath (Join-Path $gateRoot $path)) `
    "required gate file is missing: $path"
}

if (-not $ProductPinsPath) {
  $ProductPinsPath = Join-Path $repoRoot "graphcode-windows\provider-pins.json"
}
if (-not $GatePinsPath) {
  $GatePinsPath = Join-Path $gateRoot "provider-pins.json"
}
$pins = Get-Content -LiteralPath $GatePinsPath -Raw |
  ConvertFrom-Json
$productPins = Get-Content -LiteralPath $ProductPinsPath -Raw | ConvertFrom-Json
Assert-Contract ($productPins.schemaVersion -eq $pins.schemaVersion) "provider pin schemas differ"
foreach ($provider in @("winghostty", "zmx")) {
  $product = $productPins.$provider
  $gate = $pins.$provider
  Assert-Contract ($product -is [pscustomobject] -and $gate -is [pscustomobject]) `
    "provider pins differ: $provider"
  $fields = @(@($product.PSObject.Properties.Name) + @($gate.PSObject.Properties.Name)) |
    Sort-Object -Unique -CaseSensitive
  foreach ($field in $fields) {
    Assert-Contract (
      $product.PSObject.Properties.Name -ccontains $field -and
      $gate.PSObject.Properties.Name -ccontains $field -and
      $product.$field -is [string] -and $gate.$field -is [string] -and
      $product.$field -ceq $gate.$field
    ) "provider pins differ: $provider.$field"
  }
}
Assert-Contract ($pins.schemaVersion -eq 1) "provider pin schema is not 1"
Assert-Contract ($pins.winghostty.sha -eq
  "e0a5579f3b470bede72294d661282a391c502ace") "Winghostty SHA is not exact"
Assert-Contract ($pins.zmx.sha -eq
  "785b3fd15dcafd1882b495c831a10f98c201b908") "zmx SHA is not exact"
Assert-Contract ($pins.winghostty.remoteUrl -eq
  "https://github.com/coneilen/winghostty.git") "Winghostty remote URL is not stable"
Assert-Contract ($pins.zmx.remoteUrl -eq
  "https://github.com/coneilen/zmx.git") "zmx remote URL is not stable"
Assert-Contract (-not [bool] $pins.localFallback.enabled) "local fallback remains enabled"
Assert-Contract ($pins.localFallback.remoteWorkflowBlocked -eq $false) `
  "remote workflow scope remains blocked"
foreach ($localPath in @($pins.localFallback.paths)) {
  Assert-Contract ($localPath -notmatch "^[A-Za-z]:\\") `
    "provider metadata contains an environment-specific absolute path"
}

$source = Get-Content -LiteralPath (Join-Path $gateRoot "src\main.zig") -Raw
foreach ($token in @(
    "CreateWindowExW",
    "GetMessageW",
    "winghostty_host_initialize",
    "winghostty_host_create_surface_v2",
    "winghostty_surface_destroy",
    "winghostty_surface_set_focus",
    "winghostty_surface_notify_dpi_changed",
    "winghostty_surface_ime_update",
    "winghostty_surface_write_clipboard",
    "winghostty_surface_copy_accessibility_range",
    "winghostty_surface_render",
    "winghostty_surface_present",
    "winghostty_surface_set_terminal_cells",
    "feedTerminalCells",
    "terminal_cells",
    "lastRenderError",
    "zmx attach",
    "PeekNamedPipe",
    "readAttachOutput",
    "waitForInitialAttachOutput",
    "writeAttachInput",
    "child.stdin",
    "child.cwd",
    "waitAttachClient",
    "CreateProcessW",
    "recreateSurface",
    "destroyWinghosttySurface",
    "callbacksAfterDestroy",
    "sameSession",
    "app.active_surface = surfaceIndex"
  )) {
  Assert-Contract ($source.Contains($token)) "host source is missing: $token"
}
Assert-Contract (-not $source.Contains("GraphCode A\r\nsimultaneous output")) `
  "host still injects synthetic surface A terminal text"
Assert-Contract (-not $source.Contains("GraphCode B\r\nsimultaneous output")) `
  "host still injects synthetic surface B terminal text"
Assert-Contract (
  $source -match "(?s)app\.active_surface = surfaceIndex.*?for \(&app\.surfaces"
) "focus callback updates selection after exclusivity"
Assert-Contract (-not $source.Contains("sidebar")) "product sidebar leaked into the gate"
Assert-Contract (-not $source.Contains("canvas")) "product canvas leaked into the gate"
Assert-Contract (
  ([regex]::Matches($source, "winghostty_host_create_surface_v2")).Count -ge 2
) "host does not describe two complete surfaces"
Assert-Contract ($source.Contains("GetWindowLongPtrW")) `
  "top-level HWND does not own the window state"
Assert-Contract ($source.Contains("TranslateMessage")) `
  "top-level window does not own message translation"
Assert-Contract (
  $source -match "child\.cwd\s*=\s*app\.cwd"
) "zmx attach child does not inherit the gate working directory"
Assert-Contract ($source.Contains("attach-output-timeout")) `
  "zmx attach readiness does not have a bounded timeout"
Assert-Contract (-not $source.Contains("app.tick == 3")) `
  "typed input still depends on a fixed startup tick"
Assert-Contract (-not $source.Contains("app.tick == 6")) `
  "surface recreation still depends on a fixed startup tick"

$harness = Get-Content -LiteralPath (Join-Path $gateRoot "..\..\..\Tools\windows\terminal-gate.ps1") -Raw
foreach ($token in @(
    "zmx send",
    "history",
    "--vt",
    "Assert-ZmxSessionHealthy",
    "pwd",
    "same-session restart",
    "Assert-PinnedCleanWorktree",
    "status --porcelain",
    "Get-CimInstance",
    "Get-ZmxSessionProcessIds",
    "RedirectStandardOutput",
    "RedirectStandardError",
    "NewGuid",
    "GRAPHCODE_TERMINAL_SESSION_PREFIX",
    "ownedSessionNames",
    "GRAPHCODE_TERMINAL_GATE_INJECT_CLEANUP_FAILURE",
    "cleanup failed",
    "exit 0"
  )) {
  Assert-Contract ($harness.Contains($token)) `
    "smoke harness is missing persistent-session proof: $token"
}
Assert-Contract (-not $harness.Contains("& `$zmx list")) `
  "smoke harness still performs an unbounded zmx list"

$runner = Get-Content -LiteralPath (Join-Path $gateRoot "..\..\..\Tools\windows\validate.ps1") -Raw
foreach ($token in @(
    "terminal-gate.ps1",
    "Pinned Windows terminal gate build and smoke",
    "GRAPHCODE_WINGHOSTTY_ROOT",
    "provider worktrees unavailable",
    "real smoke is mandatory"
  )) {
  Assert-Contract ($runner.Contains($token)) `
    "validation runner is missing real-provider gate handling: $token"
}

$gatePath = Join-Path $repoRoot "Tools\windows\uia-live-gate.ps1"
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($gatePath, [ref]$tokens, [ref]$parseErrors)
Assert-Contract ($parseErrors.Count -eq 0) "UIA gate must parse before extracting headless guards"
foreach ($name in @("Require", "Assert-UiaUnrepairedTerminalFocus", "Assert-UiaTerminalChallengeOutput",
    "Read-UiaTerminalComputedMarker", "Resolve-UiaRestorationSessionMarkers",
    "Assert-UiaRestorationPeerCapability", "Get-UiaRestorationRemaining", "Invoke-UiaRestoredTerminalRoute",
    "Initialize-UiaRestorationSessions", "Close-UiaRestorationState", "Save-UiaRestorationPartialOutput",
    "Initialize-UiaRestorationProviderBinary")) {
  $functions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true))
  Assert-Contract ($functions.Count -eq 1) "expected one source-bound guard: $name"
  . ([scriptblock]::Create($functions[0].Extent.Text))
}

$script:guardCases = 0
function Test-Guard([string] $name, [scriptblock] $action, [string] $expectedError = "") {
  $failure = $null
  try { $null = & $action } catch { $failure = $_ }
  if ($expectedError) {
    Assert-Contract ($null -ne $failure -and $failure.Exception.Message.Contains($expectedError)) `
      "$name did not reject for the expected reason: $failure"
  } else {
    Assert-Contract ($null -eq $failure) "$name unexpectedly failed: $failure"
  }
  $script:guardCases++
}
function New-FocusSnapshot {
  [pscustomobject]@{
    foreground = $true; focusedProcessId = 42; focusedIdentity = "current-pane-1"
    panes = @(
      [pscustomobject]@{ identity = "current-pane-0"; processId = 42; parentProcessId = 42
        visible = $true; focused = $false },
      [pscustomobject]@{ identity = "current-pane-1"; processId = 42; parentProcessId = 42
        visible = $true; focused = $true }
    )
  }
}
Test-Guard "exclusive observed focus" {
  Assert-UiaUnrepairedTerminalFocus (New-FocusSnapshot) 42 "current-pane-1"
}
Test-Guard "empty roster" {
  $snapshot = New-FocusSnapshot; $snapshot.panes = @()
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
} "nontrivial pane topology"
Test-Guard "foreign foreground focus" {
  $snapshot = New-FocusSnapshot; $snapshot.focusedProcessId = 99
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
} "actual foreground focus"
Test-Guard "background window" {
  $snapshot = New-FocusSnapshot; $snapshot.foreground = $false
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
} "actual foreground focus"
Test-Guard "foreign provider" {
  $snapshot = New-FocusSnapshot; $snapshot.panes[0].processId = 99
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
} "foreign pane topology"
Test-Guard "foreign parent" {
  $snapshot = New-FocusSnapshot; $snapshot.panes[1].parentProcessId = 99
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
} "foreign pane topology"
Test-Guard "duplicate providers" {
  $snapshot = New-FocusSnapshot; $snapshot.panes[0].identity = "current-pane-1"
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
} "foreign pane topology"
Test-Guard "two focused providers" {
  $snapshot = New-FocusSnapshot; $snapshot.panes[0].focused = $true
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
} "exclusively own keyboard focus"
Test-Guard "stale selected identity" {
  Assert-UiaUnrepairedTerminalFocus (New-FocusSnapshot) 42 "previous-window-pane-1"
} "actual foreground focus"
Test-Guard "trivial first pane" {
  $snapshot = New-FocusSnapshot
  $snapshot.focusedIdentity = "current-pane-0"
  $snapshot.panes[0].focused = $true; $snapshot.panes[1].focused = $false
  Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-0"
} "nonzero selected pane"

$nonce = "0123456789abcdef01234567"
$before = @("pane zero", "cmd prompt")
$resultLine = "GC_${nonce}_1234_323"
Test-Guard "shell-computed output" {
  $observed = Assert-UiaTerminalChallengeOutput $before @("pane zero", $resultLine) 1 $nonce 323
  Assert-Contract ($observed -eq 1234) "challenge must return its parsed shell PID"
}
Test-Guard "echo is not output" {
  Assert-UiaTerminalChallengeOutput $before @("pane zero", "cmd /c echo $resultLine") 1 $nonce 323
} "shell-computed output line"
Test-Guard "empty output topology" {
  Assert-UiaTerminalChallengeOutput $before @() 1 $nonce 323
} "exact nonzero pane"
Test-Guard "first pane output" {
  Assert-UiaTerminalChallengeOutput $before @($resultLine, "cmd prompt") 0 $nonce 323
} "exact nonzero pane"
Test-Guard "foreign destination" {
  Assert-UiaTerminalChallengeOutput $before @($resultLine, $resultLine) 1 $nonce 323
} "nonselected pane"
Test-Guard "old nonce" {
  Assert-UiaTerminalChallengeOutput @("pane zero", $resultLine) @("pane zero", $resultLine) 1 $nonce 323
} "already present"
Test-Guard "wrong arithmetic" {
  Assert-UiaTerminalChallengeOutput $before @("pane zero", "GC_${nonce}_1234_322") 1 $nonce 323
} "arithmetic is invalid"
Test-Guard "duplicate output" {
  Assert-UiaTerminalChallengeOutput $before @("pane zero", "$resultLine`n$resultLine") 1 $nonce 323
} "exactly one"
Test-Guard "zero shell PID" {
  Assert-UiaTerminalChallengeOutput $before @("pane zero", "GC_${nonce}_0_323") 1 $nonce 323
} "shell-computed output line"
Test-Guard "overflow shell PID" {
  Assert-UiaTerminalChallengeOutput $before @("pane zero", "GC_${nonce}_9999999999999999999999_323") 1 $nonce 323
} "arithmetic is invalid"
Assert-Contract ($script:guardCases -eq 20) "expected 20 executed unrepaired terminal guard cases"
Write-Output "Unrepaired terminal input guards: PASS executed=$script:guardCases headless-only"

$script:routeCases = 0
function Test-Route([string] $name, [scriptblock] $action) {
  try { & $action } catch { throw "M2 headless orchestration case '$name': $_" }
  $script:routeCases++
}
Test-Route "canonical opt-in dispatch" {
  $dispatch = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
      $node.Clauses[0].Item1.Extent.Text -ceq '$RestoredTerminalInputOnly'
  }, $true))
  Assert-Contract ($dispatch.Count -eq 1 -and
    $dispatch[0].Extent.Text.Contains('Invoke-UiaRestoredTerminalRoute') -and
    $dispatch[0].Extent.Text.Contains('return') -and
    $dispatch[0].Extent.StartOffset -lt $ast.Extent.Text.IndexOf('$oldZmx =')) `
    "real opt-in must return before any default fixture environment or PID-reopen launch"
  $imports = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
      $node.Clauses[0].Item1.Extent.Text -ceq '-not $RestoredTerminalInputOnly' -and
      $node.Extent.Text.Contains("Import-Module -Name (Join-Path `$PSScriptRoot 'UiCaptureDriver.psm1')")
  }, $true))
  Assert-Contract ($imports.Count -eq 1) "default shared-helper import must not preload the real route's peer type"
  $preflight = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq "Assert-UiaRestorationPeerCapability"
  }, $true).Extent.Text
  Assert-Contract (
    $preflight.IndexOf('Initialize-CapUiaClient -AssemblyPath $validationAssemblyPath') -gt
      $preflight.IndexOf('Import-Module $module -ErrorAction Stop') -and
    $preflight.Contains('Require (-not ("CapNative" -as [type]))')
  ) "opt-in must initialize the current source-bound UIA proxy loader after its fresh module import"
}
Test-Route "unqualified peer bytes refuse before resources" {
  function Join-Path($Path, $ChildPath) { return "HEADLESS_MODULE_PATH" }
  function Get-FileHash($LiteralPath, $Algorithm) { return @{ Hash = "0" * 64 } }
  function New-UiaRestorationState { throw "UNEXPECTED_RESOURCE_CREATION" }
  $failure = $null
  try { Invoke-UiaRestoredTerminalRoute "shell" "daemon" "cli" "zmx" "root" } catch { $failure = $_ }
  Assert-Contract ($failure.Exception.Message.Contains("shared pipe-peer source differs from its qualified intake")) `
    "unqualified shared source bytes must still refuse before creating resources: $failure"
}
Test-Route "work deadline preserves reserve" {
  $state = @{ clock = @{ ElapsedMilliseconds = 1110000L } }
  $failure = $null
  try { Get-UiaRestorationRemaining $state } catch { $failure = $_ }
  Assert-Contract ($failure.Exception.Message.Contains("90-second cleanup reserve")) "work must not consume cleanup reserve"
  $state.clock.ElapsedMilliseconds = 1109999L
  Assert-Contract ((Get-UiaRestorationRemaining $state 5000) -eq 1) "remaining work timeout must clamp to original budget"
}
Test-Route "real route sequence and cleanup" {
  $script:steps = [Collections.Generic.List[string]]::new()
  function Assert-UiaRestorationPeerCapability { $script:steps.Add("preflight") }
  function New-UiaRestorationState {
    $script:steps.Add("state")
    return [pscustomobject]@{ daemon = "daemon"; root = "mock-root"; failure = $null }
  }
  function Start-UiaRestorationProcess { $script:steps.Add("daemon"); return "held-daemon" }
  function Confirm-UiaRestorationDaemonPeer { $script:steps.Add("peer"); return @{ scope = "observer" } }
  function Initialize-UiaRestorationSessions { $script:steps.Add("real-seeds") }
  function Open-UiaRestorationWorkspace($state, $stem) { $script:steps.Add($stem); return $stem }
  function Select-UiaRestorationInitialPane { $script:steps.Add("initial-user-selection") }
  function Close-UiaRestorationWindow($state, $app) { $script:steps.Add("close:$app") }
  function Invoke-UiaRestorationFreshInput { $script:steps.Add("unrepaired-guarded-input"); return @{ focusRepaired = $false } }
  function Close-UiaRestorationState { $script:steps.Add("zero-survivor-cleanup") }
  $result = Invoke-UiaRestoredTerminalRoute "shell" "daemon" "cli" "zmx" "root"
  Assert-Contract (($script:steps -join "|") -ceq
    "preflight|state|daemon|peer|real-seeds|first-shell|initial-user-selection|close:first-shell|reopened-shell|unrepaired-guarded-input|peer|close:reopened-shell|zero-survivor-cleanup") `
    "actual route must close original shell before reopening and guard input before a success result"
  Assert-Contract ($result.input.focusRepaired -eq $false) "route must preserve unrepaired-input evidence"
}
Test-Route "reopened focus refusal cleans and never reports success" {
  $script:steps = [Collections.Generic.List[string]]::new()
  function Assert-UiaRestorationPeerCapability {}
  function New-UiaRestorationState { return [pscustomobject]@{ daemon = "daemon"; failure = $null } }
  function Start-UiaRestorationProcess { return "held-daemon" }
  function Confirm-UiaRestorationDaemonPeer {}
  function Initialize-UiaRestorationSessions {}
  function Open-UiaRestorationWorkspace($state, $stem) { return $stem }
  function Select-UiaRestorationInitialPane { $script:steps.Add("initial-only-selection") }
  function Close-UiaRestorationWindow { $script:steps.Add("close") }
  function Invoke-UiaRestorationFreshInput {
    $snapshot = New-FocusSnapshot; $snapshot.foreground = $false
    Assert-UiaUnrepairedTerminalFocus $snapshot 42 "current-pane-1"
    $script:steps.Add("UNSAFE_INPUT")
  }
  function Close-UiaRestorationState($state) {
    Assert-Contract ($null -ne $state.failure) "original focus failure must survive cleanup"
    $script:steps.Add("cleanup")
  }
  $failure = $null; $result = $null
  try { $result = Invoke-UiaRestoredTerminalRoute "shell" "daemon" "cli" "zmx" "root" } catch { $failure = $_ }
  Assert-Contract ($null -eq $result -and $failure.Exception.Message.Contains("actual foreground focus") -and
    ($script:steps -join "|") -ceq "initial-only-selection|close|cleanup") `
    "focus refusal must not repair, inject, or produce a success-shaped result"
}
function New-MarkerFixture {
  $firstNonce = "111111111111111111111111"
  $secondNonce = "222222222222222222222222"
  [pscustomobject]@{
    state = @{ sessions = @("graphcode-FIRST", "graphcode-second")
      seeds = @(@{ session = "graphcode-FIRST"; nonce = $firstNonce },
        @{ session = "graphcode-second"; nonce = $secondNonce }) }
    snapshots = @(
      [pscustomobject]@{ processId = 42; parentProcessId = 42; identity = "provider-first"
        window = [IntPtr]201; windowClass = "WinghosttyEmbeddableSurface"; element = $null
        text = "GC_${firstNonce}_101_323"; visible = $true; focused = $false },
      [pscustomobject]@{ processId = 42; parentProcessId = 42; identity = "provider-second"
        window = [IntPtr]202; windowClass = "WinghosttyEmbeddableSurface"; element = $null
        text = "GC_${secondNonce}_102_323"; visible = $true; focused = $true }
    )
  }
}
Test-Route "content maps reordered providers, not screen order" {
  $fixture = New-MarkerFixture
  $mapped = @(Resolve-UiaRestorationSessionMarkers $fixture.state @($fixture.snapshots[1], $fixture.snapshots[0]) 42)
  Assert-Contract ($mapped.Count -eq 2 -and $mapped[0].identity -ceq "provider-first" -and
    $mapped[1].identity -ceq "provider-second" -and $mapped[1].seedWitnessPid -eq 102) `
    "exact computed content must bind providers back into persisted session order"
}
foreach ($case in @(
    @{ name = "foreign provider"; change = { $fixture.snapshots[1].processId = 99 }; error = "foreign, duplicated" },
    @{ name = "foreign parent"; change = { $fixture.snapshots[1].parentProcessId = 99 }; error = "foreign, duplicated" },
    @{ name = "duplicate HWND"; change = { $fixture.snapshots[1].window = [IntPtr]201 }; error = "foreign, duplicated" },
    @{ name = "duplicate runtime identity"; change = { $fixture.snapshots[1].identity = "provider-first" }; error = "foreign, duplicated" },
    @{ name = "duplicate session content"; change = { $fixture.snapshots[1].text = $fixture.snapshots[0].text }; error = "ambiguous or duplicated" },
    @{ name = "seed echo only"; change = { $fixture.snapshots[1].text = "echo " + $fixture.snapshots[1].text }; error = "shell-computed output line" },
    @{ name = "empty selector"; change = { $fixture.snapshots = @() }; error = "two distinct seeded sessions" },
    @{ name = "unpublished nonce"; change = { $fixture.snapshots[1].text = "cmd prompt" }; error = "not published yet" }
  )) {
  Test-Route $case.name {
    $fixture = New-MarkerFixture
    & $case.change
    $failure = $null
    try { Resolve-UiaRestorationSessionMarkers $fixture.state $fixture.snapshots 42 | Out-Null } catch { $failure = $_ }
    Assert-Contract ($null -ne $failure -and $failure.Exception.Message.Contains($case.error)) `
      "content binding must refuse $($case.name): $failure"
  }
}
Test-Route "only initial selection can set pane focus" {
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -match '^(?:.*-UiaRestoration|Invoke-UiaRestoredTerminalRoute)'
  }, $true))
  $setters = @($definitions | Where-Object { $_.Extent.Text.Contains('.SetFocus(') })
  Assert-Contract ($setters.Count -eq 1 -and $setters[0].Name -ceq "Select-UiaRestorationInitialPane") `
    "no restoration observer, reopened-window or input stage may repair pane focus"
  foreach ($definition in $definitions) {
    Assert-Contract ($definition.Extent.Text -notmatch 'AttachThreadInput|FocusControl|SetForegroundWindow|Start-UiaOwnedProcess|Start-MultiProjectOwnedProcess|Read-CapMatchedPanes|Invoke-CapMatchedTerminalInputChallenge') `
      "real route must not use legacy authority or repaired-focus proxies: $($definition.Name)"
  }
}
Test-Route "real launch environment is explicit and nonsynthetic" {
  $start = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Start-UiaRestorationProcess"
  }, $true).Extent.Text
  $stateSource = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "New-UiaRestorationState"
  }, $true).Extent.Text
  Assert-Contract ($start.Contains('$info.Environment.Clear()') -and $start.Contains('Start-ShellOwnedProcess') -and
    $start.Contains('$info.ArgumentList.Add($argument)') -and
    $stateSource -notmatch 'GRAPHCODE_UIA_|GRAPHCODE_GATE_CWD|GRAPHCODE_WORKSPACE_(LAYOUT|PROJECT)|ZMX_SESSION_PREFIX') `
    "the real route must explicitly omit inherited synthetic workspace flags and preserve argument boundaries"
}
Test-Route "seed and native input command shapes" {
  $seedSource = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Initialize-UiaRestorationSessions"
  }, $true).Extent.Text
  $inputSource = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Invoke-UiaRestorationFreshInput"
  }, $true).Extent.Text
  Assert-Contract ($seedSource.Contains('@("--daemon", $state.sessions[$index]') -and
    $seedSource.Contains('"/Q", "/K", $seedScript') -and $seedSource.Contains('@("projects", "--json")') -and
    $seedSource.Contains('focused = 0') -and -not $seedSource.Contains('focused = 1') -and
    $inputSource.Contains('Assert-UiaRestorationObservedFocus') -and
    $inputSource.Contains('SendUnicodeInput($app.window, $app.process.Id, $panes[1].window, $command)') -and
    $inputSource.Contains('SendKeyInput($app.window, $app.process.Id, $panes[1].window, 0x0D, 1)') -and
    $inputSource.Contains('Assert-UiaTerminalChallengeOutput')) `
    "actual route must seed computed content without target selection, then use exact owned guarded native input"
}
Test-Route "unknown cleanup retains original authority" {
  $cleanup = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Close-UiaRestorationState"
  }, $true).Extent.Text
  $hold = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Wait-UiaRestorationUnknown"
  }, $true).Extent.Text
  Assert-Contract ($cleanup.Contains('Close-ShellProcessScope $state.scope') -and
    $cleanup.Contains('Read-ShellOwnedOutput') -and $cleanup.Contains('@("stdout", "stderr")') -and
    $cleanup.Contains('M2CleanupFailure') -and $cleanup.Contains('Test-ShellOwnershipUnproven') -and
    $cleanup.Contains('Wait-UiaRestorationUnknown $state') -and $hold.Contains('[Threading.Timeout]::Infinite')) `
    "unknown teardown must preserve original failure and retain lifetime; raw streams stay independent"
}
Test-Route "actual seed adapter creates source-shaped artifacts without native launches" {
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ("m2-headless-" + [guid]::NewGuid().ToString("N"))
  Assert-Contract (-not (Test-Path -LiteralPath $scratch)) "headless scratch must be new"
  $null = New-Item -ItemType Directory -Path $scratch
  try {
    $script:seedCalls = [Collections.Generic.List[object]]::new()
    $node = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    $state = [pscustomobject]@{
      root = $scratch; project = Join-Path $scratch "M2Project"; projectDirectory = Join-Path $scratch "M2Project"
      support = Join-Path $scratch "support"; nodeId = ""; paneIds = @(); sessions = @(); seeds = @()
      layoutPath = ""; zmx = "mock-pinned-zmx"
    }
    function Invoke-UiaRestorationCli($state, $arguments, $stem) {
      $script:seedCalls.Add([pscustomobject]@{ stem = $stem; arguments = $arguments })
      switch ($stem) {
        "register-project" { return "M2Project (idle)" }
        "canonical-project" { return ConvertTo-Json -InputObject @(@{ name = "M2Project"; path = $state.project.Replace('\', '/') }) -Compress }
        "create-loop" { return "M2Project (idle)`n  $node  idle  sketch  M2Restore" }
        "stop-loop" { return "M2Project (idle)`n  $node  stopped  sketch  M2Restore" }
        default { throw "unexpected native CLI adapter: $stem" }
      }
    }
    function Start-UiaRestorationProcess($state, $file, $arguments, $stem) {
      $script:seedCalls.Add([pscustomobject]@{ stem = $stem; file = $file; arguments = $arguments })
      return "MOCK_HELD_ROOT_$stem"
    }
    function Assert-UiaRestorationHeldRoot {}
    function Invoke-UiaRestorationCommand($state, $file, $arguments, $stem) {
      $script:seedCalls.Add([pscustomobject]@{ stem = $stem; arguments = $arguments })
      return (($state.sessions | ForEach-Object { "name=$_`tpid=1" }) -join "`n")
    }
    Initialize-UiaRestorationSessions $state
    Assert-Contract (($script:seedCalls.stem -join "|") -ceq
      "register-project|canonical-project|create-loop|stop-loop|seed-0|seed-1|seed-list-1") `
      "actual seed adapter must use only the declared CLI and provider boundaries"
    Assert-Contract ($state.seeds.Count -eq 2 -and $state.sessions[0] -ceq "graphcode-$node" -and
      $state.project -ceq $state.projectDirectory.Replace('\', '/')) `
      "adapter must use actual canonical daemon path and exact session namespace"
    $layout = Get-Content -LiteralPath $state.layoutPath -Raw | ConvertFrom-Json
    Assert-Contract ($layout.schemaVersion -eq 2 -and $layout.tabs[0].focused -eq 0 -and
      $layout.tabs[0].panes[1].id -ceq $state.paneIds[1] -and
      (Get-Content -LiteralPath (Join-Path $state.support "terminal-layouts\shell-sessions\$($state.sessions[1])") -Raw) -ceq $node) `
      "prepared topology must match normal layout/ownership source without fabricating selected pane one"
    foreach ($index in 0..1) {
      $call = @($script:seedCalls | Where-Object { $_.stem -ceq "seed-$index" })[0]
      $scriptText = Get-Content -LiteralPath (Join-Path $scratch "seed-$index.cmd") -Raw
      Assert-Contract ($call.file -ceq "mock-pinned-zmx" -and $call.arguments[0] -ceq "--daemon" -and
        $call.arguments[1] -ceq $state.sessions[$index] -and $call.arguments[3] -ceq "/Q" -and
        $call.arguments[4] -ceq "/K" -and $scriptText.Contains('$v=17*19') -and
        $scriptText.Contains('$PID') -and $scriptText.Contains($state.seeds[$index].nonce)) `
        "each seed must execute its distinct computed marker through the declared pinned-provider argv"
    }
  } finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
Test-Route "actual unknown cleanup takes the lifetime hold branch" {
  Import-Module (Join-Path $PSScriptRoot "..\ShellProcessOwnership.psm1") -ErrorAction Stop
  $original = [InvalidOperationException]::new("original-input-refusal")
  $cleanupFailure = [InvalidOperationException]::new("owned-job-empty-unproved")
  $cleanupFailure.Data["GraphCodeValidationRootRetentionRequired"] = $true
  $state = @{ root = "mock-root"; scope = @{ Closed = $false }; launches = @(); expectedCleanup = $cleanupFailure
    failure = [Management.Automation.ErrorRecord]::new($original, "M2", "InvalidOperation", $null) }
  function Close-ShellProcessScope { throw $state.expectedCleanup }
  function Wait-UiaRestorationUnknown($state) {
    Assert-Contract (-not $state.scope.Closed -and
      [Object]::ReferenceEquals($state.failure.Exception.Data["M2CleanupFailure"], $state.expectedCleanup)) `
      "unknown cleanup must preserve the open scope and original/cleanup failures"
    throw "MOCK_UNKNOWN_HOLD_ENTERED"
  }
  $failure = $null
  try { Close-UiaRestorationState $state } catch { $failure = $_ }
  Assert-Contract ($failure.Exception.Message -ceq "MOCK_UNKNOWN_HOLD_ENTERED" -and
    $state.failure.Exception.Message -ceq "original-input-refusal") `
    "actual unknown branch must hold, not return success: observed=$failure original=$($state.failure.Exception.Message)"
}
Test-Route "session names remain case sensitive" {
  $fixture = New-MarkerFixture
  $fixture.state.sessions = @("graphcode-A", "graphcode-a")
  $fixture.state.seeds[0].session = "graphcode-A"
  $fixture.state.seeds[1].session = "graphcode-a"
  $mapped = @(Resolve-UiaRestorationSessionMarkers $fixture.state $fixture.snapshots 42)
  Assert-Contract ($mapped.Count -eq 2 -and $mapped[0].session -ceq "graphcode-A" -and
    $mapped[1].session -ceq "graphcode-a") "agent and shell case-sensitive namespaces must not coalesce"
}
Test-Route "success evidence is withheld until cleanup proves quiescence" {
  function Assert-UiaRestorationPeerCapability {}
  function New-UiaRestorationState { return [pscustomobject]@{ daemon = "daemon"; root = "mock-root"; failure = $null } }
  function Start-UiaRestorationProcess { return "held-daemon" }
  function Confirm-UiaRestorationDaemonPeer { return @{ scope = "observer" } }
  function Initialize-UiaRestorationSessions {}
  function Open-UiaRestorationWorkspace($state, $stem) { return $stem }
  function Select-UiaRestorationInitialPane {}
  function Close-UiaRestorationWindow {}
  function Invoke-UiaRestorationFreshInput { return @{ focusRepaired = $false } }
  function Close-UiaRestorationState { throw "CLEANUP_PROOF_REFUSED" }
  $emitted = [Collections.Generic.List[object]]::new()
  $failure = $null
  try {
    Invoke-UiaRestoredTerminalRoute "shell" "daemon" "cli" "zmx" "root" |
      ForEach-Object { $emitted.Add($_) }
  } catch { $failure = $_ }
  Assert-Contract ($emitted.Count -eq 0 -and $failure.Exception.Message -ceq "CLEANUP_PROOF_REFUSED") `
    "native evidence must not enter the output pipeline before successful cleanup: emitted=$($emitted.Count)"
}
Test-Route "partial raw streams remain separate without claiming EOF" {
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ("m2-partial-" + [guid]::NewGuid().ToString("N"))
  Assert-Contract (-not (Test-Path -LiteralPath $scratch)) "partial capture scratch must be new"
  $null = New-Item -ItemType Directory -Path (Join-Path $scratch "logs")
  try {
    $state = @{ root = $scratch; scope = "mock-scope"; launches = @(@{ process = "original-mock"; stem = "held" }) }
    function Receive-ShellOwnedOutput($scope, $process, $MaximumCharacters) {
      Assert-Contract ($scope -ceq "mock-scope" -and $process -ceq "original-mock" -and
        $MaximumCharacters -eq 65536) "partial output must retain original launch and independent cursor bounds"
      return [pscustomobject]@{ Output = "raw stdout`r`n tail "; Error = "raw stderr`n tail`t" }
    }
    Save-UiaRestorationPartialOutput $state @{ ElapsedMilliseconds = 1 }
    Assert-Contract (
      [IO.File]::ReadAllText((Join-Path $scratch "logs\held.stdout.partial.log")) -ceq "raw stdout`r`n tail " -and
      [IO.File]::ReadAllText((Join-Path $scratch "logs\held.stderr.partial.log")) -ceq "raw stderr`n tail`t"
    ) "partial raw output must not merge streams, normalize lines, or append success/EOF assertions"
  } finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
foreach ($foreignAdjacent in @($false, $true)) {
  Test-Route "Swift provider locator private copy foreign=$foreignAdjacent" {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("m2-provider-" + [guid]::NewGuid().ToString("N"))
    Assert-Contract (-not (Test-Path -LiteralPath $scratch)) "provider scratch must be new"
    $null = New-Item -ItemType Directory -Path (Join-Path $scratch "runtime")
    try {
      $state = @{ zmx = Join-Path $scratch "admitted-zmx.exe"; support = Join-Path $scratch "support"
        daemon = Join-Path $scratch "runtime\graphcoded.exe"; cli = Join-Path $scratch "runtime\graphcode.exe" }
      [IO.File]::WriteAllText($state.zmx, "HEADLESS_NONEXECUTABLE_PROVIDER_BYTES")
      if ($foreignAdjacent) {
        [IO.File]::WriteAllText((Join-Path $scratch "runtime\zmx.exe"), "FOREIGN_NONEXECUTABLE_BYTES")
        $failure = $null
        try { Initialize-UiaRestorationProviderBinary $state } catch { $failure = $_ }
        Assert-Contract ($failure.Exception.Message.Contains("adjacent Swift provider differs") -and
          -not (Test-Path -LiteralPath (Join-Path $state.support "bin\zmx.exe"))) `
          "normal Swift locator must not silently bind a foreign adjacent provider"
      } else {
        Initialize-UiaRestorationProviderBinary $state
        Assert-Contract ((Get-FileHash -LiteralPath (Join-Path $state.support "bin\zmx.exe")).Hash -ceq
          (Get-FileHash -LiteralPath $state.zmx).Hash) "private support-bin copy must preserve admitted bytes exactly"
      }
    } finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
  }
}
Assert-Contract ($script:routeCases -eq 25) "expected 25 executed headless route cases"
Write-Output "M2 route orchestration: PASS executed=$script:routeCases mock/source/managed-file-only"
Write-Output "Windows terminal gate contract: PASS"
exit 0
