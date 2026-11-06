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
    "unrepaired-focus-guards"
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
foreach ($name in @("Require", "Assert-UiaUnrepairedTerminalFocus", "Assert-UiaTerminalChallengeOutput")) {
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
Write-Output "Windows terminal gate contract: PASS"
exit 0
