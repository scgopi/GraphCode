[CmdletBinding()]
param(
  [switch] $List,
  [switch] $WorkspaceTabSelectorOnly,
  [string] $ZigExecutable,
  # Hosted CI splits the executable sections across runners. Shard/ShardCount
  # select one part of a deterministic, complete partition; the defaults run
  # every section, exactly as a local run always has.
  [int] $Shard = 0,
  [int] $ShardCount = 1,
  [string] $SectionManifest,
  [switch] $PlanOnly
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

# The section catalog is derived from this script's own top-level
# `Invoke-Native "<name>"` calls, so a new section is sharded automatically and
# a shard can never silently omit one: the union of every shard's assignment is
# the catalog by construction, and each shard records what it executed.
function Get-ShellSectionCatalog([string] $path) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Windows shell contract: WindowsShell.Tests.ps1 must parse" }
  $calls = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq "Invoke-Native"
    }, $true))
  $names = [Collections.Generic.List[string]]::new()
  foreach ($call in $calls) {
    $nameElement = $call.CommandElements[1]
    if ($nameElement -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
      throw "Windows shell contract: Invoke-Native sections need a literal name: $($call.Extent.Text.Split("`n")[0])"
    }
    for ($parent = $call.Parent; $null -ne $parent; $parent = $parent.Parent) {
      if ($parent -is [Management.Automation.Language.CommandAst] -and
          $parent.GetCommandName() -eq "Invoke-Native") {
        throw "Windows shell contract: section '$($nameElement.Value)' is nested inside another section; shards schedule top-level sections only"
      }
    }
    if ($names.Contains($nameElement.Value)) {
      throw "Windows shell contract: duplicate section name '$($nameElement.Value)'"
    }
    $names.Add($nameElement.Value)
  }
  if ($names.Count -eq 0) { throw "Windows shell contract: no executable sections were found" }
  return , $names.ToArray()
}

# Measured hosted-runner seconds (windows-2022). Almost all of a heavy section is
# test execution (allocation-failure sweeps), not compilation, so the hints only
# balance the partition; they never decide whether a section runs.
$sectionCostHints = @{
  "Wire executable tests" = 56
  "Codespace ingress dialog executable tests" = 8
  "Forms and navigation executable tests" = 56
  "Native dialog message-loop executable tests" = 60
  "Context menu and gate fixture message executable tests" = 62
  "Frame buffer executable tests" = 56
  "Daemon client startup tests" = 59
  "Terminal VT preparation and memory tests" = 81
  "Graph model executable tests" = 57
  "Graph canvas executable tests" = 56
  "Worktree Git process regression tests" = 19
  "Template library executable tests" = 56
  "Custody child data-only executable tests" = 20
  "Workspace teardown executable tests" = 59
  "Sidebar executable tests" = 60
  "App shell executable tests" = 75
}
# Sections that consume zig-out\lib\ghostty-vt-static.lib must share a shard
# with the section that prepares it, and run after it (catalog order).
$sectionAffinity = @{
  "Terminal input queue tests" = "Terminal VT preparation and memory tests"
  "App shell executable tests" = "Terminal VT preparation and memory tests"
}

function Get-ShellSectionPlan([string[]] $catalog, [int] $count) {
  $groups = [ordered]@{}
  foreach ($name in $catalog) {
    $anchor = if ($sectionAffinity.ContainsKey($name)) { $sectionAffinity[$name] } else { $name }
    if ($catalog -notcontains $anchor) {
      throw "Windows shell contract: affinity anchor '$anchor' for '$name' is not a section"
    }
    if (-not $groups.Contains($anchor)) {
      $groups[$anchor] = [pscustomobject]@{
        Anchor = $anchor
        Order = [Array]::IndexOf($catalog, $anchor)
        Cost = 0
        Members = [Collections.Generic.List[string]]::new()
      }
    }
    $cost = if ($sectionCostHints.ContainsKey($name)) { $sectionCostHints[$name] } else { 3 }
    $groups[$anchor].Cost += $cost
    $groups[$anchor].Members.Add($name)
  }
  foreach ($name in @($sectionCostHints.Keys) + @($sectionAffinity.Keys) + @($sectionAffinity.Values)) {
    if ($catalog -notcontains $name) {
      throw "Windows shell contract: shard plan names a section that no longer exists: $name"
    }
  }
  $loads = [int[]]::new($count)
  $assignment = @{}
  foreach ($group in @($groups.Values | Sort-Object @{ Expression = "Cost"; Descending = $true }, Order)) {
    $target = 0
    for ($index = 1; $index -lt $count; $index++) {
      if ($loads[$index] -lt $loads[$target]) { $target = $index }
    }
    $loads[$target] += $group.Cost
    foreach ($member in $group.Members) { $assignment[$member] = $target }
  }
  [pscustomobject]@{ Assignment = $assignment; Loads = $loads }
}

if ($ShardCount -lt 1 -or $ShardCount -gt 8 -or $Shard -lt 0 -or $Shard -ge $ShardCount) {
  throw "Windows shell contract: shard $Shard of $ShardCount is not a valid selection"
}
$sectionCatalog = Get-ShellSectionCatalog $PSCommandPath
$sectionPlan = Get-ShellSectionPlan $sectionCatalog $ShardCount
$assignedSections = @($sectionCatalog | Where-Object { $sectionPlan.Assignment[$_] -eq $Shard })
$executedSections = [Collections.Generic.List[object]]::new()
if ($PlanOnly) {
  [ordered]@{
    shard = $Shard
    shardCount = $ShardCount
    catalog = $sectionCatalog
    assigned = $assignedSections
    estimatedSeconds = $sectionPlan.Loads[$Shard]
  } | ConvertTo-Json -Depth 4
  exit 0
}
Write-Host ("WINDOWS_SHELL_SECTION_SHARD shard=$Shard count=$ShardCount " +
  "sections=$($assignedSections.Count)/$($sectionCatalog.Count) " +
  "estimatedSeconds=$($sectionPlan.Loads[$Shard])")

function Assert-Contract([object] $condition, [string] $message) {
  $values = @($condition)
  if ($values.Count -ne 1 -or -not [bool] $values[0]) {
    throw "Windows shell contract: $message"
  }
}

function Assert-WorkspaceTabSelectors {
  $gatePath = Join-Path $repoRoot "Tools\windows\uia-live-gate.ps1"
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile(
    $gatePath, [ref]$tokens, [ref]$errors)
  Assert-Contract ($errors.Count -eq 0) "UIA live gate must parse"
  $predicates = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.BinaryExpressionAst] -and
        $node.Operator -eq [Management.Automation.Language.TokenKind]::Imatch -and
        $node.Left.Extent.Text -match '\.Current\.AutomationId$' -and
        $node.Right.Extent.Text -match 'workspace-tab-'
    }, $true))
  Assert-Contract ($predicates.Count -eq 7) `
    "expected seven actual-tab selectors in the UIA live gate, found $($predicates.Count)"

  $cases = @(
    @{ Label = "interleaved"; Ids = @("workspace-tab-0", "workspace-tab-close-0", "workspace-tab-1", "workspace-tab-close-1"); Expected = @("workspace-tab-0", "workspace-tab-1") },
    @{ Label = "close first"; Ids = @("workspace-tab-close-0", "workspace-tab-0", "workspace-tab-close-1", "workspace-tab-1"); Expected = @("workspace-tab-0", "workspace-tab-1") },
    @{ Label = "reversed"; Ids = @("workspace-tab-close-1", "workspace-tab-1", "workspace-tab-close-0", "workspace-tab-0"); Expected = @("workspace-tab-1", "workspace-tab-0") },
    @{ Label = "no closes"; Ids = @("workspace-tab-0", "workspace-tab-1"); Expected = @("workspace-tab-0", "workspace-tab-1") },
    @{ Label = "close only"; Ids = @("workspace-tab-close-0", "workspace-tab-close-1"); Expected = @() },
    @{ Label = "empty"; Ids = @(); Expected = @() },
    @{ Label = "split tab"; Ids = @("workspace-tab-close-0", "workspace-tab-0"); Expected = @("workspace-tab-0") }
  )
  foreach ($predicate in $predicates) {
    $selector = [scriptblock]::Create($predicate.Extent.Text)
    foreach ($case in $cases) {
      $children = @($case.Ids | ForEach-Object {
        [pscustomobject]@{ Current = [pscustomobject]@{
          AutomationId = $_
          Name = if ($_ -match 'close') { "Close tab" } elseif ($case.Label -eq "split tab") { "Split tab" } else { "Agent tab" }
        } }
      })
      $selected = @($children | Where-Object $selector | ForEach-Object { $_.Current.AutomationId })
      Assert-Contract (($selected -join "|") -ceq ($case.Expected -join "|")) `
        "UIA actual-tab selector $($predicate.Extent.StartLineNumber) selected wrong controls for $($case.Label): $($selected -join ',')"
    }
  }
  Write-Host "UIA actual-tab selector contract: 7 predicates, 7 fixtures passed"
}

Assert-WorkspaceTabSelectors
if ($WorkspaceTabSelectorOnly) { exit 0 }

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
$validationRunnerSource = Get-Content (Join-Path $repoRoot "Tools\windows\validate.ps1") -Raw
$scrubbedStartupSource = Get-Content `
  (Join-Path $repoRoot "Tools\windows\Tests\ScrubbedShellStartup.Live.Tests.ps1") -Raw
$allowedKeysBlock = [regex]::Match(
  $scrubbedStartupSource,
  '(?s)\$allowedKeys\s*=\s*@\((.*?)\)'
)
Assert-Contract ($validationRunnerSource -match
  '(?s)Pinned GraphCode Windows shell build and smoke.*?Scrubbed production shell startup.*?ScrubbedShellStartup\.Live\.Tests\.ps1.*?Native UI Automation live gate') `
  "Windows shell validation must run the scrubbed production startup gate before UIA"
Assert-Contract ($validationRunnerSource -match
  '(?s)Scrubbed production shell startup.*?& pwsh -NoProfile -File.*?ScrubbedShellStartup\.Live\.Tests\.ps1') `
  "scrubbed production startup must run in an isolated PowerShell process before UIA"
Assert-Contract $allowedKeysBlock.Success `
  "scrubbed production startup gate must declare an explicit environment allowlist"
$actualAllowedKeys = @(
  [regex]::Matches($allowedKeysBlock.Groups[1].Value, '"([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object
)
$expectedAllowedKeys = @(
  "APPDATA", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "PATH", "ProgramData",
  "SystemRoot", "TEMP", "TMP", "USERPROFILE", "windir"
) | Sort-Object
Assert-Contract (($actualAllowedKeys -join "|") -ceq ($expectedAllowedKeys -join "|")) `
  "scrubbed production startup gate must preserve the proven explicit environment allowlist"
Assert-Contract ($actualAllowedKeys -notcontains "USERNAME" -and
  $actualAllowedKeys -notcontains "USER" -and
  $scrubbedStartupSource -match 'developerToolsExcluded=true' -and
  $scrubbedStartupSource -match 'first-run-escape' -and
  $scrubbedStartupSource -match 'first-run-skip' -and
  $scrubbedStartupSource -match 'first-run-complete' -and
  $scrubbedStartupSource -match 'onboarding-marker' -and
  $scrubbedStartupSource -match 'event=fatal') `
  "scrubbed production startup gate must preserve the developer-free onboarding contract"
$daemonRoundTripSource = Get-Content (Join-Path $shellRoot "src\DaemonRoundTripTests.zig") -Raw
Assert-Contract ($scrubbedStartupSource -match 'Invoke-Case "registered-project" "project"' -and
  $scrubbedStartupSource -match 'Wait-ProjectRow' -and
  $scrubbedStartupSource -match '"status", \$projectPath' -and
  $scrubbedStartupSource -match 'executed \$\(\$results\.Count\)/5 cases' -and
  $daemonRoundTripSource -notmatch 'modelCompatibleFrame' -and
  $daemonRoundTripSource -match 'self\.model\.updateFromFrame\(frame\)') `
  "production daemon graph frames must reach the shell model unmodified and render a registered project"
Assert-Contract ($validationRunnerSource -match
  '(?s)Scrubbed production shell startup.*?Real daemon wire round trip.*?& pwsh -NoProfile -File.*?DaemonRoundTrip\.Live\.Tests\.ps1.*?Native UI Automation live gate' -and
  $daemonRoundTripSource -match 'DAEMON_OPEN_CANONICAL' -and
  $daemonRoundTripSource -match 'eqlIgnoreCase\(&token') `
  "Windows shell validation must exercise the production daemon wire contract, including canonical open replies"
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
  $appSource -match 'const use_gdiplus = !daemon_supervisor_test_hook and !uia_gate_hook;' -and
  $appSource -match 'if \(use_gdiplus\) GdiplusAA\.init\(\);' -and
  $appSource -match 'defer if \(use_gdiplus\) GdiplusAA\.deinit\(\);') `
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
  if ($sectionCatalog -notcontains $description) {
    throw "Windows shell contract: section '$description' is not in the derived catalog"
  }
  if ($sectionPlan.Assignment[$description] -ne $Shard) {
    Write-Host "--> $description (shard $($sectionPlan.Assignment[$description]) of $ShardCount)"
    return
  }
  Write-Host "==> $description"
  # A --test-filter that matches nothing still exits 0, so every `zig test` in a
  # section must report a positive passed count of its own.
  $expectedSummaries = [regex]::Matches($command.ToString(), '\$zig test ').Count
  $positiveSummaries = 0
  $started = [Diagnostics.Stopwatch]::StartNew()
  & $command *>&1 | ForEach-Object {
    $line = "$_"
    Write-Host $line
    if ($line -match '^All ([0-9]+) tests passed\.$' -or
        $line -match '^([0-9]+) passed; [0-9]+ skipped; 0 failed\.$') {
      if ([int64] $Matches[1] -gt 0) { $positiveSummaries++ }
    }
  }
  if ($LASTEXITCODE -ne 0) {
    throw "$description failed with exit code $LASTEXITCODE"
  }
  if ($positiveSummaries -lt $expectedSummaries) {
    throw "$description reported $positiveSummaries positive test summaries for $expectedSummaries zig test invocations"
  }
  $executedSections.Add([ordered]@{
    name = $description
    seconds = [Math]::Round($started.Elapsed.TotalSeconds, 1)
    zigTestInvocations = $expectedSummaries
    positiveSummaries = $positiveSummaries
  })
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
  "6286560d0aa3103e068b2b7afa81eac373d870c9") "Winghostty pin changed"
Assert-Contract ($pins.zmx.sha -eq
  "785b3fd15dcafd1882b495c831a10f98c201b908") "zmx pin changed"
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

$zmxSessionSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\ZmxSession.zig") -Raw
$terminalSurfaceSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\TerminalSurface.zig") -Raw
$workspaceTeardownSource = Get-Content -LiteralPath (Join-Path $shellRoot "src\WorkspaceTeardown.zig") -Raw
Assert-Contract ($zmxSessionSource -match '(?s)pub fn child\(.*?\.create_no_window = true;') `
  "zmx children must be created without a console window"
Assert-Contract ($terminalSurfaceSource -notmatch 'std\.process\.Child\.init\(' -and
  $workspaceTeardownSource -notmatch 'std\.process\.Child\.init\(' -and
  [regex]::Matches($terminalSurfaceSource, 'ZmxSession\.child\(').Count -eq 2 -and
  [regex]::Matches($workspaceTeardownSource, 'ZmxSession\.child\(').Count -eq 1) `
  "zmx attach, resize, and kill must spawn through ZmxSession.child so the GUI shell never opens a console window"

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
Invoke-Native "Edge creation captured draft and scope pure tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\EdgeCreationTests.zig -target x86_64-windows-msvc -lc -ladvapi32 "-I$include" --test-filter "edge creation"
  } finally { Pop-Location }
}
Invoke-Native "Edge editing data-only executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for edge editing tests."
  }
  Push-Location $shellRoot
  try {
    $output = @(& $zig test src\EdgeEditing.zig -target x86_64-windows-msvc `
      -lc -ladvapi32 "-I$include" --test-filter "edge editing:" 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0) { throw "Edge editing tests failed with exit code $exitCode" }
    Assert-Contract (($output -join "`n") -match 'All [1-9][0-9]* tests passed\.') `
      "edge editing filter must execute a positive test count"
  } finally { Pop-Location }
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
Invoke-Native "Sketch promotion executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\SketchPromotion.zig --test-filter 'sketch promotion' } finally { Pop-Location }
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
Invoke-Native "GDI+ asynchronous startup live test" {
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    throw "GRAPHCODE_WINGHOSTTY_ROOT is required for the GDI+ startup live test"
  }
  & (Join-Path $PSScriptRoot "GdiplusStartup.Live.Tests.ps1") `
    -ZigExecutable $zig `
    -WinghosttyRoot $winghosttyRoot
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
Invoke-Native "Daemon round-trip helper executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for daemon round-trip helper tests."
  }
  Push-Location $shellRoot
  try {
    $output = @(& $zig test src\DaemonRoundTripTests.zig `
      -target x86_64-windows-msvc -lc -ladvapi32 "-I$include" `
      --test-filter "daemon round-trip support helper" 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0) {
      throw "Daemon round-trip helper tests failed with exit code $exitCode"
    }
    $text = $output -join "`n"
    if ($text -notmatch '(?m)All\s+[1-9]\d*\s+tests?\s+passed') {
      throw "Daemon round-trip helper test did not report a positive executed test count"
    }
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
Invoke-Native "Zmx session identity executable tests" {
  Push-Location $shellRoot
  try {
    & $zig test src\ZmxSession.zig
    if ($LASTEXITCODE -ne 0) { throw "zmx session identity tests failed" }
    & $zig test src\LoopLaunchWait.zig
  } finally { Pop-Location }
}
Invoke-Native "Loop bar layout executable tests" {
  Push-Location $shellRoot
  try {
    & $zig test src\LoopBarLayout.zig
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
    & $zig test src\TerminalSurface.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 -ladvapi32 "-I$include" $terminalVtLib
  } finally { Pop-Location }
}
Invoke-Native "Windows clipboard encoding tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  $winghosttyLib = Join-Path $winghosttyRoot "zig-out\lib\winghostty-win32-host.lib"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for clipboard encoding tests."
  }
  if (-not (Test-Path -LiteralPath $winghosttyLib -PathType Leaf)) {
    throw "The pinned Winghostty host library is required for clipboard encoding tests."
  }
  Push-Location $shellRoot
  try {
    & $zig test src\Clipboard.zig -target x86_64-windows-msvc -lc -luser32 -lkernel32 `
      "-I$include" $winghosttyLib -lgdi32 -lopengl32 -limm32 -lole32 -loleaut32 `
      -luiautomationcore -lshell32 -ladvapi32 -lwinhttp
    if ($LASTEXITCODE -ne 0) { throw "clipboard encoding tests failed" }
  } finally { Pop-Location }
}
Invoke-Native "Graph model executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\GraphModel.zig } finally { Pop-Location }
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
Invoke-Native "Graph canvas executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
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
Invoke-Native "Worktree Git process regression tests" {
  & (Join-Path $PSScriptRoot "WorktreeGitProcess.Tests.ps1") -Zig $zig `
    -EvidenceDirectory (Join-Path $shellRoot (".zig-cache\worktree-process-" + [guid]::NewGuid().ToString("N"))) `
    -FixtureDirectory (Join-Path ([IO.Path]::GetTempPath()) ("graphcode-worktree-process-" + [guid]::NewGuid().ToString("N")))
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
Invoke-Native "Custody child data-only executable tests" {
  & (Join-Path $PSScriptRoot "CustodyChild.Tests.ps1") -ZigExecutable $zig
  if ($LASTEXITCODE -ne 0) { throw "Custody child tests failed with exit code $LASTEXITCODE" }
}
Invoke-Native "Windows shell diagnostics executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Diagnostics.zig } finally { Pop-Location }
}
Invoke-Native "Workspace lifecycle executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\WorkspaceLifecycle.zig } finally { Pop-Location }
}
Invoke-Native "Workspace manager data executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\WorkspaceManager.zig } finally { Pop-Location }
}
Invoke-Native "Workspace teardown executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) { $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration" }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WorkspaceTeardown.zig -target x86_64-windows-msvc -lc -ladvapi32 -lshell32 -lkernel32 "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Workspace manager form data executable tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) { $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration" }
  $include = Join-Path $winghosttyRoot "include"
  Push-Location $shellRoot
  try {
    & $zig test src\WorkspaceManagerForm.zig --test-filter "workspace manager" -target x86_64-windows-msvc -lc -luser32 -lgdi32 "-I$include"
  } finally { Pop-Location }
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
  $winghosttyLib = Join-Path $winghosttyRoot "zig-out\lib\winghostty-win32-host.lib"
  Assert-Contract (Test-Path -LiteralPath $winghosttyLib -PathType Leaf) `
    "Build the pinned Winghostty host library before App shell tests."
  Push-Location $shellRoot
  try {
    & $zig test src\App.zig src\AccessibilityProvider.cpp src\FilePicker.c $winghosttyLib `
      -DUNICODE -D_UNICODE -target x86_64-windows-msvc -lc `
      -luser32 -lgdi32 -lgdiplus -lmsimg32 -lopengl32 -lkernel32 -limm32 `
      -lole32 -loleaut32 -luiautomationcore -lshell32 -ladvapi32 -lwinhttp "-I$include" $terminalVtLib
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

$executedNames = @($executedSections | ForEach-Object { $_.name })
if (($executedNames -join "`n") -cne ($assignedSections -join "`n")) {
  throw "Windows shell contract: shard $Shard executed [$($executedNames -join ', ')] but was assigned [$($assignedSections -join ', ')]"
}
if ($SectionManifest) {
  $manifestDirectory = Split-Path -Parent $SectionManifest
  if ($manifestDirectory) { New-Item -ItemType Directory -Force $manifestDirectory | Out-Null }
  [ordered]@{
    schemaVersion = 1
    shard = $Shard
    shardCount = $ShardCount
    catalog = $sectionCatalog
    assigned = $assignedSections
    executed = @($executedSections)
    wiredTestFiles = $wiredTestFiles
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SectionManifest -Encoding utf8
}

Write-Output "Windows shell scaffold contract: PASS ($($wiredTestFiles.Count) source files wired; shard $Shard of $ShardCount executed $($executedNames.Count) of $($sectionCatalog.Count) sections)"
exit 0
