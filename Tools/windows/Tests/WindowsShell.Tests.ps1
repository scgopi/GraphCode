[CmdletBinding()]
param(
  [switch] $List,
  [string] $ZigExecutable
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$shellScript = Join-Path $repoRoot "Tools\windows\windows-shell.ps1"

if ($List) {
  @(
    "app-lifecycle",
    "daemon-reconnect",
    "protocol-correlation",
    "graph-decoding",
    "terminal-lifecycle",
    "two-surfaces",
    "cleanup"
  )
  exit 0
}

function Assert-Contract([object] $condition, [string] $message) {
  $values = @($condition)
  if ($values.Count -ne 1 -or -not [bool] $values[0]) {
    throw "Windows shell contract: $message"
  }
}

$shellSource = Get-Content $shellScript -Raw
$appSource = Get-Content (Join-Path $shellRoot "src\App.zig") -Raw
$mainWindowSource = Get-Content (Join-Path $shellRoot "src\MainWindow.zig") -Raw
$nativeFormsSource = Get-Content (Join-Path $shellRoot "src\NativeForms.zig") -Raw
$nativeDialogsSource = Get-Content (Join-Path $shellRoot "src\WindowsNativeDialogs.zig") -Raw
$productSettingsSource = Get-Content (Join-Path $shellRoot "src\WindowsProductSettings.zig") -Raw
$traySource = Get-Content (Join-Path $shellRoot "src\Tray.zig") -Raw
$win32Source = Get-Content (Join-Path $shellRoot "src\Win32.zig") -Raw
$inputSource = Get-Content (Join-Path $shellRoot "src\InputRouter.zig") -Raw
$stubSource = Get-Content (Join-Path $repoRoot "Tools\windows\Stub-Daemon.ps1") -Raw
$menuTimerBlock = [regex]::Match(
  $appSource,
  '(?s)else if \(wparam == MainWindow\.timer_id\) \{.*?const updated_connection_state'
).Value
Assert-Contract ($win32Source -match
  '(?s)pub fn opaquePointerFromInt.*?@setRuntimeSafety\(false\);.*?@ptrFromInt\(value\)' -and
  $win32Source -match 'pub fn messagePointer' -and
  $win32Source -match 'pub fn resourceIdentifier') `
  "external Win32 pointer-shaped integers must cross a runtime-safety-disabled boundary"
Assert-Contract ($appSource -notmatch '@ptrFromInt\(state\)' -and
  $appSource -notmatch 'suggested:\s*\*const c\.RECT\s*=\s*@ptrFromInt' -and
  $mainWindowSource -notmatch 'CREATESTRUCTW,\s*@ptrFromInt' -and
  $traySource -notmatch '@ptrFromInt\(@as\(usize,\s*event\)\)' -and
  $nativeDialogsSource -notmatch 'c\.HMENU\s*=\s*@ptrFromInt' -and
  $productSettingsSource -notmatch '@ptrFromInt\(backend_id\)' -and
  $productSettingsSource -notmatch 'else\s+@ptrFromInt\(id\)') `
  "Win32 handles and message pointers must use the explicit unsafe conversion helpers"
$windowSources = Get-ChildItem (Join-Path $shellRoot "src") -Filter "*.zig" -File |
  ForEach-Object { Get-Content $_.FullName -Raw }
Assert-Contract (($windowSources -join "`n") -notmatch
  'Load(?:Cursor|Icon)W\([^\r\n]*@ptrFromInt') `
  "Win32 integer resource identifiers must use the explicit unsafe conversion helper"
Assert-Contract ($appSource -match
  '(?s)pub fn checkForUpdates.*?requestUpdateCheck\(true\)' -and
  $appSource -match 'if \(!envFlag\("GRAPHCODE_UIA_UPDATE_AVAILABLE"\)\) self\.requestUpdateCheck\(false\)' -and
  $appSource -match 'shouldPresentOffer\(self\.update_user_initiated\)') `
  "explicit and background update checks must preserve their presentation intent"
Assert-Contract ($nativeFormsSource -match 'if \(active_state\) return error\.FormAlreadyOpen;' -and
  $nativeFormsSource -match 'pub fn isModalActive\(\) bool' -and
  $appSource -match 'UpdateOfferPresentation\.decide\(completed_offer, self\.update_offer_pending, NativeForms\.isModalActive\(\)\)') `
  "native forms must reject reentrancy and completed update offers must wait for the active modal"
Assert-Contract ($mainWindowSource -match 'pub const MenuRefresh = enum' -and
  $mainWindowSource -match 'if \(redrawsMenuBar\(refresh\)\) _ = c\.DrawMenuBar\(hwnd\);' -and
  $appSource -match '(?s)c\.WM_INITMENUPOPUP.*?updateNativeChrome\(\.popup_open\)' -and
  $menuTimerBlock -notmatch 'app\.updateNativeChrome') `
  "timer polling must not rebuild open popup menus or continuously redraw the menu bar"
Assert-Contract ($appSource -match 'SetMapMode\(hdc, c\.MM_ANISOTROPIC\)' -and
  $appSource -match 'SetWindowExtEx\(hdc, logical_right, logical_bottom' -and
  $appSource -match 'logicalCoordinate\(mouseX\(lparam\), app\.dpi\)' -and
  $appSource -match 'physicalCoordinate\(Tokens\.sidebar_width, self\.dpi\)') `
  "custom main-window painting, input, and child layout must share one DPI-scaled coordinate system"
Assert-Contract ($appSource -match
  'const uia_gate_hook = envFlag\("GRAPHCODE_UIA_GATE"\);' -and
  $appSource -match 'if \(!daemon_supervisor_test_hook and !uia_gate_hook\) GdiplusAA\.init\(\);') `
  "GDI+ helper-window startup must remain outside daemon-handoff and UIA automation hooks"
Assert-Contract ($appSource -match
  '(?s)app\.smoke_tick >= 16 and\s*app\.client\.connectionState\(\) == \.connected and\s*app\.currentProject\(\) != null and app\.model\.selected\(\) != null and\s*!app\.smoke_action_requested') `
  "smoke graph command must wait for connection and selection instead of a single tick"
Assert-Contract ($appSource -match
  '(?s)app\.smoke_action_requested = true;\s*app\.smoke_idle_ticks = 0;\s*app\.sendSelectedNode\(\);') `
  "a newly queued smoke command must prevent an idle exit in the same tick"
Assert-Contract ($appSource -match
  '(?s)smoke_tick >= 16 and !app\.smoke_input_requested.*?if \(app\.workspace\) \|workspace\| \{\s*app\.smoke_input_requested = true;') `
  "smoke input must wait for its workspace instead of consuming the one-shot action early"
Assert-Contract ($shellSource -match
  '(?s)\$inputDeadline = .*?AddSeconds\(8\).*?\$inputApp = Start-Process.*?\$attachReady.*?pwsh.*?Write-OwnedResourceMetrics "windows-shell:large-paste".*?WaitForExit\(\$remainingMilliseconds\)') `
  "large-paste sampling must observe the owned attach within the shared eight-second deadline"
Assert-Contract ($shellSource -match
  '(?s)while \(\[DateTime\]::UtcNow -lt \$inputDeadline.*?Write-OwnedResourceMetrics "windows-shell:large-paste".*?Start-Sleep -Milliseconds 50') `
  "large-paste metrics must sample the active workload rather than one startup instant"
Assert-Contract ($stubSource -match '\$bufferSize = if \(\$NonReading\) \{ 0 \} else \{ 64 \* 1024 \}' -and
  $stubSource -match '(?s)NamedPipeServerStream.*?\$bufferSize,\s*\$bufferSize') `
  "normal stub buffering must match production while non-reading mode retains backpressure"
Assert-Contract ($stubSource -match 'Start-Sleep -Milliseconds \$ResponseDelayMilliseconds') `
  "stub cannot exercise delayed request completion"
Assert-Contract ($shellSource -match '(?s)\$evidence = .*?STUB_DAEMON_EVIDENCE_JSON=.*?foreach \(\$property') `
  "stub protocol evidence is not emitted before validation can fail"
Assert-Contract ($shellSource -notmatch '\$env:GRAPHCODE_ZMX list') `
  "session tracking must not block on unrelated zmx namespaces"
& {
  $sessionPrefix = "gs-owned"
  $testSessionIds = @("11111111-1111-4111-8111-111111111111")
  $processFixtures = @(
    [pscustomobject]@{ ProcessId = 101; CommandLine = 'zmx.exe --daemon gs-owned-pane' },
    [pscustomobject]@{ ProcessId = 102; CommandLine = 'zmx.exe attach "11111111-1111-4111-8111-111111111111"' },
    [pscustomobject]@{ ProcessId = 103; CommandLine = 'zmx.exe --daemon gs-other-pane' },
    [pscustomobject]@{ ProcessId = 104; CommandLine = 'zmx.exe --daemon prefix-gs-owned-pane' },
    [pscustomobject]@{ ProcessId = 105; CommandLine = 'zmx.exe --daemon 11111111-1111-4111-8111-111111111111-suffix' },
    [pscustomobject]@{ ProcessId = 106; CommandLine = $null }
  )
  function Get-CimInstance { $processFixtures }
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput(
    $shellSource, [ref]$tokens, [ref]$errors)
  $function = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-ZmxSessionRecords"
    }, $true)
  . ([scriptblock]::Create($function.Extent.Text))
  $records = @(Get-ZmxSessionRecords)
  Assert-Contract (($records.Pid -join ",") -eq "101,102") `
    "session tracking included a foreign or partial-match process"
  Assert-Contract (($records.Name -join ",") -eq
    "gs-owned-pane,11111111-1111-4111-8111-111111111111") `
    "session tracking did not preserve exact owned names"
}
if ($shellSource -match '(?m)^\s*Write-OwnedResourceMetrics\s*$') {
  throw "Windows shell contract: empty resource metric phase"
}
Assert-Contract ($shellSource -match '(?s)\$inputApp\s*=\s*Start-Process.*?\$inputApp\.Id.*?Write-OwnedResourceMetrics "windows-shell:large-paste" @\(\$inputApp\.Id\)') `
  "large-paste metric is not tied to the recorded inputApp PID"
Assert-Contract ($shellSource -match '(?s)GraphCode Windows shell restart smoke.*?Invoke-ShellProcess \$arguments "windows-shell:restart"') `
  "restart snapshot is not assigned the restart phase"
$restartBlock = [regex]::Match($shellSource,
  '(?s)GraphCode Windows shell restart smoke.*?Invoke-ShellProcess \$arguments "windows-shell:restart".*?\r?\n\s*}')
Assert-Contract ($restartBlock.Success -and $restartBlock.Value -notmatch 'windows-shell:large-paste') `
  "restart path can satisfy large-paste phase"
Assert-Contract ($mainWindowSource -match 'Project Worktree Policy' -and
  $appSource -match '\.edit_worktree_policy => app\.handleAction\(\.edit_worktree_policy\)' -and
  $appSource -match 'NativeForms\.worktreePolicy') `
  "worktree policy editor is not reachable from the native shell"
Assert-Contract ($nativeFormsSource -match 'BS_AUTORADIOBUTTON' -and
  $nativeFormsSource -match 'Remove: automatically remove safe landed worktrees' -and
  $nativeFormsSource -match 'notice_size_gb' -and
  $nativeFormsSource -match 'notice_count') `
  "project settings does not expose resolve choices and notice thresholds"
Assert-Contract ($nativeFormsSource -match 'worktreeSweep' -and
  $nativeFormsSource -match 'SAFE TO REMOVE' -and
  $nativeFormsSource -match 'LOOK BEFORE REMOVING' -and
  $nativeFormsSource -match 'Remove Selected') `
  "dedicated Worktree Sweep sheet is missing its safety tiers or removal action"
Assert-Contract ($inputSource -match "ctrl and shift and key == 'I'.*inspect_worktrees") `
  "Inspect worktrees is not routed from Ctrl+Shift+I"

function Invoke-Native([string] $description, [scriptblock] $command) {
  Write-Host "==> $description"
  & $command
  if ($LASTEXITCODE -ne 0) {
    throw "$description failed with exit code $LASTEXITCODE"
  }
}

function Resolve-TestZig {
  if ($ZigExecutable -and (Test-Path -LiteralPath $ZigExecutable -PathType Leaf)) {
    return (Resolve-Path -LiteralPath $ZigExecutable).Path
  }
  $command = Get-Command zig.exe -ErrorAction SilentlyContinue
  if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
    & $command.Source env *> $null
    if ($LASTEXITCODE -eq 0) {
      return $command.Source
    }
  }
  throw "A working Zig executable is required for executable Windows shell tests."
}

foreach ($path in @(
    "build.zig",
    "build.zig.zon",
    "provider-pins.json",
    "package-metadata.json",
    "README.md",
    "src\main.zig",
    "src\Win32.zig",
    "src\App.zig",
    "src\Diagnostics.zig",
    "src\MainWindow.zig",
    "src\DaemonClient.zig",
    "src\GraphModel.zig",
    "src\GraphCanvas.zig",
    "src\CanvasLayoutStore.zig",
    "src\CanvasInput.zig",
    "src\Sidebar.zig",
    "src\TerminalWorkspace.zig",
    "src\TerminalSurface.zig",
    "src\WorkspaceLayout.zig",
    "src\InputRouter.zig",
    "src\Forms.zig",
    "src\NativeForms.zig",
    "src\ModalTeardown.zig",
    "src\UpdateOfferPresentation.zig",
    "src\WindowsOnboarding.zig",
    "src\WindowsProductSettings.zig",
    "src\Accessibility.zig",
    "src\DesignTokens.zig",
    "src\Wire.zig",
    "src\Codespaces.zig",
    "src\WindowsCodespaceDialog.zig",
    "src\FrameBuffer.zig",
    "..\Tools\windows\Stub-Daemon.ps1",
    "fixtures\daemon-v2-hello.json",
    "fixtures\daemon-v2-list-projects.json",
    "fixtures\daemon-v2-subscribe.json",
    "fixtures\daemon-v2-graph-event.json",
    "fixtures\daemon-v2-graph-reordered-edges.json",
    "fixtures\daemon-v2-presence-event.json",
    "fixtures\daemon-v2-graph-attention.json",
    "fixtures\daemon-v1-list-projects.json",
    "fixtures\daemon-v2-create-node.json",
    "fixtures\daemon-v2-create-edge.json",
    "fixtures\daemon-v2-delete-edge.json",
    "fixtures\daemon-v2-message-node.json",
    "fixtures\daemon-v2-stop-node.json",
    "fixtures\sidebar-recent-projects.json"
  )) {
  Assert-Contract (Test-Path -LiteralPath (Join-Path $shellRoot $path)) `
    "required scaffold file is missing: $path"
}

$pins = Get-Content -LiteralPath (Join-Path $shellRoot "provider-pins.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($pins.schemaVersion -eq 1) "provider pin schema is not 1"
Assert-Contract ($pins.winghostty.sha -eq
  "f5abc059e4ca58b376eb209313aca7784659c679") "Winghostty pin changed"
Assert-Contract ($pins.zmx.sha -eq
  "11e20c738b4ebd88031c7a01f1a9d938ee123234") "zmx pin changed"
Assert-Contract ($pins.winghostty.remoteUrl -eq
  "https://github.com/coneilen/winghostty.git") "Winghostty remote URL changed"
Assert-Contract ($pins.zmx.remoteUrl -eq
  "https://github.com/coneilen/zmx.git") "zmx remote URL changed"
Assert-Contract (-not $pins.localFallback.enabled) "local provider fallback remains enabled"
Assert-Contract (-not $pins.localFallback.remoteWorkflowBlocked) `
  "remote provider workflow remains blocked"

$metadata = Get-Content -LiteralPath (Join-Path $shellRoot "package-metadata.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($metadata.installer -eq $true) "installer metadata is not enabled"
Assert-Contract ($metadata.executable -eq "graphcode-windows.exe") `
  "package metadata does not identify the shell"

$hello = Get-Content -LiteralPath (Join-Path $shellRoot "fixtures\daemon-v2-hello.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($hello.version -eq 2) "v2 hello fixture has the wrong version"
Assert-Contract ($hello.supportedVersions -contains 1 -and $hello.supportedVersions -contains 2) `
  "v2 hello fixture does not advertise both protocol versions"
Assert-Contract ($hello.PSObject.Properties.Name -notcontains "subscription") `
  "all-project hello fixture must omit the subscription filter"

$subscribe = Get-Content `
  -LiteralPath (Join-Path $shellRoot "fixtures\daemon-v2-subscribe.json") -Raw |
  ConvertFrom-Json
Assert-Contract (@($subscribe.subscription.projectPaths).Count -eq 1) `
  "project subscription fixture does not contain exactly one project"

$create = Get-Content `
  -LiteralPath (Join-Path $shellRoot "fixtures\daemon-v2-create-node.json") -Raw |
  ConvertFrom-Json
$draft = $create.command.graphCommand.command.createNode._0
Assert-Contract ($draft.id -and $draft.title -and $draft.firstInstruction) `
  "create-node fixture is not a complete draft"
Assert-Contract ($draft.loopType -eq "turnBased" -and $draft.backend -eq "claudeCode") `
  "create-node fixture does not use a valid turn-based draft"
Assert-Contract ($draft.pausesBeforeWritesOnly -is [bool]) `
  "create-node fixture omitted pausesBeforeWritesOnly"

$message = Get-Content `
  -LiteralPath (Join-Path $shellRoot "fixtures\daemon-v2-message-node.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($message.command.graphCommand.command.messageNode._0 -and
  $message.command.graphCommand.command.messageNode.text -and
  $null -eq $message.command.graphCommand.command.messageNode.from) `
  "message-node fixture does not match Codable payload shape"

$stop = Get-Content `
  -LiteralPath (Join-Path $shellRoot "fixtures\daemon-v2-stop-node.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($stop.command.graphCommand.command.stopNode._0) `
  "stop-node fixture does not match Codable payload shape"

$mainWindowSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\MainWindow.zig") -Raw
$callbackIndex = $mainWindowSource.IndexOf("if (value.callback) |callback|")
$defaultIndex = $mainWindowSource.IndexOf(
  "result = c.DefWindowProcW(hwnd, message, wparam, lparam);",
  $callbackIndex
)
Assert-Contract ($callbackIndex -ge 0 -and $defaultIndex -gt $callbackIndex) `
  "window messages must reach GraphCode before DefWindowProc handles unclaimed messages"

$appSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\App.zig") -Raw
Assert-Contract ($appSource -match "GraphCanvas\.paint[\s\S]+workspace\.paintChrome\(hdc\)") `
  "WM_PAINT must render both the GraphCode canvas and terminal workspace chrome"
Assert-Contract ($appSource -match
  '(?s)c\.WM_ERASEBKGND\s*=>.*?result\.\*\s*=\s*1;.*?c\.WM_PAINT\s*=>.*?CreateCompatibleDC.*?CreateCompatibleBitmap.*?BitBlt') `
  "top-level painting must suppress background erase and present one buffered frame"
Assert-Contract ($appSource -match
  'TemplateLibrary\.load\(self\.allocator, path\) catch \|err\|' -and
  $appSource -match 'Diagnostics\.record\(self\.allocator, "error", message\)' -and
  $appSource -match '(?s)"Unable to load saved templates".*?NativeForms\.node') `
  "template failures must be logged and fall back to the plain New Loop form"

$codespaceDialogSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\WindowsCodespaceDialog.zig") -Raw
$codespaceClientSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\Codespaces.zig") -Raw
$graphModelSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\GraphModel.zig") -Raw

Assert-Contract ($mainWindowSource -match 'Add Codespace\.\.\.\\tCtrl\+Shift\+K') `
  "the Add Folder menu must offer codespace ingress next to the other repository sources"
Assert-Contract ($mainWindowSource -notmatch 'GetSubMenu\(add_folder, \d+\)') `
  "the recent folders submenu must be located, not indexed, so new ingress entries cannot retarget it"
Assert-Contract ($appSource -match 'codespace_repository => self\.addCodespaceRepository\(\)') `
  "the codespace command must reach the codespace ingress path"
Assert-Contract ($appSource -match 'Codespaces\.projectURI[\s\S]{0,400}sendOpenProject\(project_path\)') `
  "an accepted codespace must open as a codespace:// project through the existing daemon openProject call"
Assert-Contract ($graphModelSource -match 'startsWith\(u8, self\.path, "codespace://"\)') `
  "codespace projects must group with remote projects rather than as local filesystem paths"
Assert-Contract ($codespaceClientSource -match 'BatchMode=yes') `
  "codespace validation must never wait on an interactive ssh prompt"
Assert-Contract ($codespaceClientSource -match 'github_pat_' -and $codespaceClientSource -match 'fn sanitizeMessage') `
  "surfaced gh output must be redacted before it can reach a status line or log"
Assert-Contract ($codespaceClientSource -match 'gh auth refresh -h github\.com -s codespace') `
  "a missing codespace scope must tell the human the exact command that fixes it"
Assert-Contract ($codespaceDialogSource -match 'WM_CTLCOLORLISTBOX' -and $codespaceDialogSource -match 'WM_CTLCOLOREDIT') `
  "the codespace sheet must paint its list and fields dark like the rest of the shell"
Assert-Contract ($codespaceDialogSource -match 'IsDialogMessageW') `
  "the codespace sheet must remain keyboard navigable"

$zig = Resolve-TestZig
Invoke-Native "Accessibility contract executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Accessibility.zig } finally { Pop-Location }
}

Invoke-Native "Wire executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Wire.zig } finally { Pop-Location }
}
Invoke-Native "Codespace client executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Codespaces.zig } finally { Pop-Location }
}
Invoke-Native "Codespace ingress dialog executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WindowsCodespaceDialog.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Forms and navigation executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Forms.zig } finally { Pop-Location }
}
Invoke-Native "Win32 pointer conversion executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\Win32.zig -target x86_64-windows-msvc -lc "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Native dialog message-loop executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\NativeForms.zig -target x86_64-windows-msvc -lc -luser32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Update offer modal deferral executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\UpdateOfferPresentation.zig } finally { Pop-Location }
}
Invoke-Native "Context menu and gate fixture message executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\GraphContextMenu.zig -target x86_64-windows-msvc -lc -luser32 "-I$include"
    if ($LASTEXITCODE -ne 0) { return }
    & $zig test src\MainWindow.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 -ladvapi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Jump palette executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\JumpPalette.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Onboarding executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WindowsOnboarding.zig -target x86_64-windows-msvc `
      -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Product Settings executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-pinned"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WindowsProductSettings.zig -target x86_64-windows-msvc `
      -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Modal teardown executable tests" {
  $winghosttyRoot = $env:GRAPHCODE_WINGHOSTTY_ROOT
  if (-not $winghosttyRoot) {
    $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-pinned"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\ModalTeardown.zig -target x86_64-windows-msvc `
      -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Windows update feed executable tests" {
  $winghosttyRoot = $env:GRAPHCODE_WINGHOSTTY_ROOT
  if (-not $winghosttyRoot) {
    $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WindowsUpdates.zig -target x86_64-windows-msvc -lc -lwinhttp "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Windows update install executable tests" {
  $winghosttyRoot = $env:GRAPHCODE_WINGHOSTTY_ROOT
  if (-not $winghosttyRoot) {
    $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WindowsUpdateInstall.zig -target x86_64-windows-msvc -lc -lwinhttp "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Frame buffer executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\FrameBuffer.zig } finally { Pop-Location }
}
Invoke-Native "Daemon client startup tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for DaemonClient startup tests."
  }
  Push-Location $shellRoot
  try {
    & $zig test src\DaemonClient.zig -target x86_64-windows-msvc -lc -ladvapi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Daemon supervisor handoff tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for daemon supervisor handoff tests."
  }
  Push-Location $shellRoot
  try {
    & $zig test src\DaemonSupervisor.zig -target x86_64-windows-msvc `
      -lc -lkernel32 -ladvapi32 -lshell32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Workspace layout executable tests" {
  Push-Location $shellRoot
  try {
    & $zig test src\WorkspaceLayout.zig
    if ($LASTEXITCODE -ne 0) { throw "workspace layout tests failed" }
    & $zig test src\InputRouter.zig
  } finally { Pop-Location }
}
Invoke-Native "Terminal VT preparation and memory tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  $terminalVtLib = Join-Path $shellRoot "zig-out\lib\ghostty-vt-static.lib"
  Push-Location $shellRoot
  try {
    & $zig build prepare-terminal-vt "-Dwinghostty-dir=$winghosttyRoot"
    if ($LASTEXITCODE -ne 0) { throw "terminal VT preparation failed" }
    & $zig test src\TerminalVt.zig -target x86_64-windows-msvc -lc "-I$include" $terminalVtLib
  } finally { Pop-Location }
}
Invoke-Native "Terminal input queue tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  $terminalVtLib = Join-Path $shellRoot "zig-out\lib\ghostty-vt-static.lib"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for terminal input tests."
  }
  Push-Location $shellRoot
  try {
    & $zig test src\TerminalSurface.zig -target x86_64-windows-msvc -lc "-I$include" $terminalVtLib
  } finally { Pop-Location }
}
Invoke-Native "Graph model executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\GraphModel.zig } finally { Pop-Location }
}
Invoke-Native "Graph canvas executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  Invoke-Native "Graph canvas input executable tests" {
    $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
    $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
    if (-not $winghosttyRoot) {
      $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
    }
    $include = Join-Path $winghosttyRoot "include"
    Push-Location $shellRoot
    try {
      & $zig test src\CanvasInput.zig -target x86_64-windows-msvc -lc "-I$include"
    } finally { Pop-Location }
  }
  $include = Join-Path $winghosttyRoot "include"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for graph canvas tests."
  }
  Push-Location $shellRoot
  try {
    & $zig test src\GraphCanvas.zig -target x86_64-windows-msvc -lc "-I$include"
  } finally { Pop-Location }
}

Invoke-Native "Worktree status executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\WorktreeStatus.zig } finally { Pop-Location }
}
Invoke-Native "Draft attachments executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\DraftAttachments.zig } finally { Pop-Location }
}
Invoke-Native "Worktree dialog executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\WorktreeDialog.zig } finally { Pop-Location }
}
Invoke-Native "DPI scaling executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Dpi.zig } finally { Pop-Location }
}
Invoke-Native "Template library executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\TemplateLibrary.zig } finally { Pop-Location }
}
Invoke-Native "Windows shell diagnostics executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Diagnostics.zig } finally { Pop-Location }
}
Invoke-Native "Workspace lifecycle executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\WorkspaceLifecycle.zig } finally { Pop-Location }
}
Invoke-Native "Sidebar navigation executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Navigation.zig } finally { Pop-Location }
}
Invoke-Native "Workspace controls executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\WorkspaceControls.zig } finally { Pop-Location }
}
Invoke-Native "Sidebar executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\Sidebar.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Windows repository dialogs executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WindowsRepositoryDialogs.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "GDI gradient executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\GdiGradient.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "App font cache executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\AppFont.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "GDI+ antialiasing executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\GdiplusAA.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Update offer dialog executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\UpdateOfferDialog.zig -target x86_64-windows-msvc -lc -luser32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Update install dialog executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\UpdateInstallDialog.zig -target x86_64-windows-msvc -lc -lwinhttp -luser32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Native dialog field contract executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WindowsNativeDialogs.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "App shell executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  $terminalVtLib = Join-Path $shellRoot "zig-out\lib\ghostty-vt-static.lib"
  Push-Location $shellRoot
  try {
    & $zig test src\App.zig src\AccessibilityProvider.cpp `
      -target x86_64-windows-msvc -lc -luser32 -lgdi32 -ladvapi32 -loleaut32 -luiautomationcore -lwinhttp "-I$include" $terminalVtLib
  } finally { Pop-Location }
}

# Structural anti-drift guard (issue #424): every graphcode-windows\src\*.zig file
# that declares at least one `test "..."` block must actually be executed by one of
# the `zig test` invocations above. This check runs last, after every other
# invocation, so a real regression in an individual file's tests is reported before
# this contract-only failure short-circuits the run.
#
# The wired set is DERIVED from this script's own `zig test` invocations rather than
# from a hand-maintained list. A hand-maintained list is a second source of truth
# that can drift from the invocations it claims to describe: deleting an invocation
# while leaving its name in the list would silently stop executing those tests and
# still pass the guard -- exactly the regression #424 exists to prevent. Deriving the
# set from the invocations themselves makes the guard observe reality instead of a
# description of it, and removes the second place to forget when wiring a new file.
$guardScriptText = Get-Content -LiteralPath $PSCommandPath -Raw
$wiredTestFiles = @(
  ($guardScriptText -split "`r?`n") |
    Where-Object { $_ -match '\$zig test' } |
    ForEach-Object { [regex]::Matches($_, 'src\\([A-Za-z0-9_]+)\.zig') } |
    ForEach-Object { "$($_.Groups[1].Value).zig" }
) | Sort-Object -Unique
if ($wiredTestFiles.Count -eq 0) {
  throw "Windows shell contract: the anti-drift guard derived zero `zig test` invocations from $PSCommandPath, so it cannot verify anything (see issue #424)."
}
$missingTestFiles = @(
  Get-ChildItem -LiteralPath (Join-Path $shellRoot "src") -Filter "*.zig" -File |
    Where-Object {
      ((Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^test "') -and
        ($wiredTestFiles -notcontains $_.Name)
    } |
    ForEach-Object { $_.Name }
)
if ($missingTestFiles.Count -ne 0) {
  throw "Windows shell contract: the following src\*.zig files contain test blocks but are not wired into any zig test invocation in WindowsShell.Tests.ps1 (see issue #424): $($missingTestFiles -join ', ')"
}

Write-Output "Windows shell scaffold contract: PASS ($($wiredTestFiles.Count) source files executed)"
exit 0
