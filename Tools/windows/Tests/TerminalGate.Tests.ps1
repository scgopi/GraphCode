[CmdletBinding()]
param(
  [switch] $List
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$gateRoot = Join-Path $repoRoot "investigation\spikes\windows-terminal-gate"

if ($List) {
  @(
    "provider-pins",
    "graphcode-owned-host",
    "persistent-zmx",
    "lifecycle-contract"
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

$pins = Get-Content -LiteralPath (Join-Path $gateRoot "provider-pins.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($pins.schemaVersion -eq 1) "provider pin schema is not 1"
Assert-Contract ($pins.winghostty.sha -eq
  "f5abc059e4ca58b376eb209313aca7784659c679") "Winghostty SHA is not exact"
Assert-Contract ($pins.zmx.sha -eq
  "858727af10cdf43d66cb3733cff58dc90ec4b3dd") "zmx SHA is not exact"
Assert-Contract ($pins.winghostty.remoteUrl -eq
  "https://github.com/coneilen/winghostty.git") "Winghostty remote URL is not stable"
Assert-Contract ($pins.zmx.remoteUrl -eq
  "https://github.com/coneilen/zmx.git") "zmx remote URL is not stable"
Assert-Contract ([bool] $pins.localFallback.enabled) "local fallback is not documented"
Assert-Contract ($pins.localFallback.remoteWorkflowBlocked -eq $true) `
  "remote workflow scope blocker is not recorded"
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
    "writeAttachInput",
    "child.stdin",
    "waitAttachClient",
    "CreateProcessW",
    "recreateSurface",
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

$harness = Get-Content -LiteralPath (Join-Path $gateRoot "..\..\..\Tools\windows\terminal-gate.ps1") -Raw
foreach ($token in @(
    "zmx send",
    "history",
    "--vt",
    "same-session restart",
    "Assert-PinnedCleanWorktree",
    "status --porcelain",
    "exit 0"
  )) {
  Assert-Contract ($harness.Contains($token)) `
    "smoke harness is missing persistent-session proof: $token"
}

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

Write-Output "Windows terminal gate contract: PASS"
exit 0
