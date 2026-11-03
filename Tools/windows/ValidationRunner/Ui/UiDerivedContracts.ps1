param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
$bindings = & (Join-Path $RepositoryRoot 'Tools\windows\Import-CompiledValidationAssembly.ps1') `
  -AssemblyPath $AssemblyPath -RequiredType 'GraphCodeUiaGateState'
$source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'))
$nativeSource = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Ui\Production\GraphCodeUiaGateState.cs'))
$activationSource = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\UiaWindowActivation.cs'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Actual UIA gate does not parse' }
$results = [Collections.Generic.List[object]]::new()
function Assert-Derived([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}
function Invoke-Derived([string] $Id, [scriptblock] $Assertion) {
  $failure = $null
  try { & $Assertion } catch { $failure = $_ }
  $results.Add([ordered]@{
    id = $Id; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = 1
    evidence = $(if ($failure) { $failure.ToString() } else { 'Exact current production PS/source/compiled binding derived contract' })
  })
}
function Read-Function([string] $Name) {
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  Assert-Derived ($definitions.Count -eq 1) "Expected one actual production helper: $Name"
  return $definitions[0].Extent.Text
}
function Get-Region([string] $Text, [string] $Start, [string] $End) {
  $begin = $Text.IndexOf($Start, [StringComparison]::Ordinal)
  $finish = if ($begin -ge 0) { $Text.IndexOf($End, $begin, [StringComparison]::Ordinal) } else { -1 }
  Assert-Derived ($begin -ge 0 -and $finish -gt $begin) "Production region boundary missing: $Start"
  return $Text.Substring($begin, $finish - $begin)
}
function Confirm-Order([string] $Text, [string[]] $Needles) {
  $offset = 0
  foreach ($needle in $Needles) {
    $next = $Text.IndexOf($needle, $offset, [StringComparison]::Ordinal)
    if ($next -lt 0) { return $false }
    $offset = $next + $needle.Length
  }
  return $true
}
function Assert-ContainsAll([string] $Text, [string[]] $Needles) {
  Assert-Derived ($Needles.Count -gt 0) 'Source requirement list is empty'
  foreach ($needle in $Needles) { Assert-Derived ($Text.Contains($needle)) "Production contract missing literal: $needle" }
}
$caption = $null
Invoke-Derived 'ui.root.source.line-5501' {
  $script:caption = Get-Region $source '$laneProjectId = Get-MultiProjectAutomationId "overview-project" $fixtureProjectPath' `
    '$surfaceActionPatterns["quick-chats-destination"].Invoke()'
}
Invoke-Derived 'ui.root.source.line-5514' {
  Assert-Derived ($null -ne $caption) 'Caption region unavailable'
  Assert-ContainsAll $caption @('$captions = @($children | Where-Object', '$_.Current.AutomationId -ceq $laneProjectId',
    'lane caption snapshot must expose exactly one project caption', 'lane caption snapshot must not expose an uninspected worktree chip',
    'CaptionBounds = $caption', 'OpenX = [int][Math]::Round(($caption.Left + $caption.Right) / 2)', 'UIA_LANE_NO_WORKTREE_CHIP_EVIDENCE=')
}
Invoke-Derived 'ui.root.source.line-5524' {
  Assert-Derived ($null -ne $caption) 'Caption region unavailable'
  foreach ($obsolete in @('Worktrees not inspected', '$laneOpenNoticeOffset', '$laneWorktreesNoticeOffset',
      '$laneActionsRightNoticeOffset', 'overview lane Worktrees click')) {
    Assert-Derived (-not $caption.Contains($obsolete)) "Obsolete caption contract retained: $obsolete"
  }
}
Invoke-Derived 'ui.root.source.line-5537' {
  $diagnostic = $source.LastIndexOf('Get-UiaPrelaunchDiagnostics', [StringComparison]::Ordinal)
  $launch = $source.IndexOf('$process = Start-UiaOwnedProcess $Shell', [StringComparison]::Ordinal)
  Assert-Derived ($diagnostic -ge 0 -and $launch -ge 0 -and $diagnostic -lt $launch) 'Prelaunch diagnostics occur after shell launch'
  foreach ($pattern in @('GetCurrentWindowStationName|WindowStation', 'GetCurrentDesktopName|DesktopName', 'desktopHeap', 'sessionId')) {
    Assert-Derived ($source -match $pattern) 'Prelaunch diagnostics omit host evidence'
  }
}
Invoke-Derived 'ui.root.source.line-5897' {
  Assert-Derived ($null -ne $bindings.GetType('GraphCodeUiaHostInfo', $false)) 'Production host-info type missing'
}
Invoke-Derived 'ui.root.source.line-5905' {
  $hostInfo = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Ui\Production\GraphCodeUiaHostInfo.cs'))
  Assert-Derived ($hostInfo.Contains('public static class GraphCodeUiaHostInfo') -and
    $source.Contains('"GraphCodeUiaHostInfo"') -and $source.Contains('Import-CompiledValidationAssembly.ps1')) 'Ordinary host-info source is not required by production consumer'
}
Invoke-Derived 'ui.root.source.line-5914' {
  Assert-Derived ([GraphCodeUiaHostInfo]::CurrentSessionId() -is [uint32]) 'Current Windows session type is not UInt32'
}
foreach ($name in @('Protect-UiaStartupDiagnosticText', 'Get-UiaStartupDiagnosticValue', 'Get-UiaPrelaunchDiagnostics')) {
  . ([scriptblock]::Create((Read-Function $name)))
}
$hostContext = Get-UiaPrelaunchDiagnostics
foreach ($id in @('ui.root.source.line-5918', 'ui.host-info.diagnostics')) {
  Invoke-Derived $id {
    Assert-Derived ($hostContext.sessionId.state -eq 'available' -and $hostContext.currentProcessId -eq $PID -and
      $hostContext.desktopHeap.state -eq 'usage_unavailable') 'Host diagnostics lost explicit session or heap state'
  }
}
function Confirm-Ingress([string] $Gate, [string] $Native) {
  $method = [regex]::Match($Native, '(?s)public static bool SendCommand\(IntPtr window, uint command\)\s*\{(?<body>.*?)\n\s*\}')
  $body = [regex]::Replace($method.Groups['body'].Value, '\s+', ' ').Trim()
  $expected = 'if (window == IntPtr.Zero) return false; UIntPtr result; return SendMessageTimeout( window, 0x0111, (UIntPtr)command, IntPtr.Zero, 0x0001 | 0x0002, 5000, out result ) != IntPtr.Zero;'
  if (-not $method.Success -or $body -cne $expected) { return $false }
  try { $region = Get-Region $Gate 'foreach ($ingress in @(' 'foreach ($nativeForm in @(' } catch { return $false }
  return (Confirm-Order $region @('action=submit-invalid phase=before', '[GraphCodeUiaGateState]::SendCommand(', 'action=submit-invalid phase=after')) -and
    (Confirm-Order $region @('action=validation-enumeration phase=before', '$validationContent = @(', '.FindAll(', 'action=validation-enumeration phase=after')) -and
    (Confirm-Order $region @('[GraphCodeUiaGateState]::PostClose(', 'action=close-wait phase=before', 'Wait-UiaOwnedSheetGoneByContentClass', 'action=close-wait phase=after'))
}
Invoke-Derived 'ui.root.source.line-6057' {
  Assert-Derived (Confirm-Ingress $source $nativeSource) 'Actual ingress source lost bounded attribution'
  Assert-Derived (-not (Confirm-Ingress $source ($nativeSource.Replace('return SendMessageTimeout(', 'if (false) return SendMessageTimeout(')))) 'Dead bounded call mutant accepted'
  Assert-Derived (-not (Confirm-Ingress ($source.Replace('action=submit-invalid phase=after', 'action=submit-invalid phase=before')) $nativeSource)) 'Reordered ingress marker mutant accepted'
}
function Confirm-SheetRetry([string] $Gate) {
  try { $body = Get-Region $Gate 'function Wait-UiaOwnedSheetByContentClass(' 'function Wait-UiaOwnedSheetGoneByContentClass(' } catch { return $false }
  return [regex]::Matches($body, '(?s)if \(Test-MultiProjectOwnedSheetIdentity \$identity \$processId \$owner\s*`\s*[\r\n]+\s*\$expectedHostTitle \$contentClass\) \{\s*return \$element\s*\}').Count -eq 1 -and
    [regex]::Matches($body, 'return \$element').Count -eq 1 -and $body -match 'Get-UiaOwnedSheetIdentity \$element' -and
    $body -match 'UIA_OWNED_SHEET_RETRY' -and $body -match 'Start-Sleep -Milliseconds 50' -and
    $body -match '\$watch\.ElapsedMilliseconds -lt \$timeoutMilliseconds' -and $body -notmatch 'Assert-UiaOwnedSheet \$element'
}
Invoke-Derived 'ui.root.source.line-6093' {
  Assert-Derived (Confirm-SheetRetry $source) 'Actual owned-sheet retry proof failed'
  $mutant = [regex]::Replace($source,
    '(?s)if \(Test-MultiProjectOwnedSheetIdentity \$identity \$processId \$owner\s*`\s*[\r\n]+\s*\$expectedHostTitle \$contentClass\) \{\s*return \$element\s*\}',
    'if ($true) { $null = $element }; return $element', 1)
  Assert-Derived (-not (Confirm-SheetRetry $mutant)) 'Unconditional owned-sheet return mutant accepted'
}
function Confirm-DeleteContext([string] $Gate) {
  try { $region = Get-Region $Gate '$deleteLoopTitle =' 'Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 21))' } catch { return $false }
  $region = [regex]::Replace($region, '\s+', ' ').Trim()
  if ($region -match 'SendCommand\(\$shellWindow,\s*5103\)') { return $false }
  return Confirm-Order $region @(
    '$deleteTarget = Find-FragmentByIdWithRetry $root $renameGraphIdentity $rawWalker', '$deleteTargetSelection.Select()',
    'Require $deleteTargetSelection.Current.IsSelected', 'UIA_DELETE_LOOP_TARGET',
    '$deleteLoopPopup = Open-CanvasCardContextMenu $process $root $shellWindow ` $renameGraphIdentity $rawWalker "Delete Loop"',
    '$deleteLoopItems = @(Get-PopupMenuItems $deleteLoopPopup)',
    '$_.Id -eq 5103 -and $_.Enabled', 'Require ($null -ne $deleteLoopItem)',
    '$deleteLoopPopup, $shellWindow, [int]$deleteLoopItem.Position, [int]$deleteLoopItem.Id', 'Require ($null -ne $deleteLoopClick)',
    'UIA_DELETE_LOOP_MENU', '"GraphCodeWindowsDialogContent" $deleteLoopTitle "Delete Loop custom sheet"',
    '[IntPtr]$deleteLoopDialog.Current.NativeWindowHandle, 9808',
    'Wait-UiaOwnedSheetGoneByContentClass $process.Id $shellWindow ` "GraphCodeWindowsDialogContent") "Delete Loop custom sheet remained open after Cancel"')
}
Invoke-Derived 'ui.root.source.line-6157' {
  $helper = [regex]::Replace((Read-Function 'Open-CanvasCardContextMenu'), '\s+', ' ')
  Assert-Derived (Confirm-Order $helper @(
    'Require (Ensure-ShellForeground $ownerWindow', '$card = Find-FragmentByIdWithRetry $root $automationId $walker',
    '$card.Current.AutomationId -ceq $automationId', '$card.Current.ProcessId -eq $process.Id -and -not $card.Current.IsOffscreen',
    '$canvas = Find-FragmentByIdWithRetry $root "graph" $walker', '$bounds = $card.Current.BoundingRectangle',
    '$canvasBounds = $canvas.Current.BoundingRectangle', '[double]::IsNaN($_) -or [double]::IsInfinity($_)',
    '$visible = Get-MultiProjectClippedRectangle $cardRect $canvasRect',
    '[GraphCodeUiaGateState]::PostOwnedScreenPoint($ownerWindow, $x, $y, $true)',
    '$popup = Wait-ForPopupMenu $process $ownerWindow $label', 'Require ($popup -ne [IntPtr]::Zero)', 'return $popup')) `
    'Actual owned stable-card context helper lost foreground/identity/geometry/popup proof'
  Assert-Derived (Confirm-DeleteContext $source) 'Actual Delete context proof failed'
  $mutants = @(
    @('Open-CanvasCardContextMenu $process $root $shellWindow', '[GraphCodeUiaGateState]::SendCommand($shellWindow, 5103)'),
    @('Require ($null -ne $deleteLoopItem)', '$null = ($null -ne $deleteLoopItem)'),
    @('$deleteLoopPopup, $shellWindow, [int]$deleteLoopItem.Position, [int]$deleteLoopItem.Id', '$deleteLoopPopup, $shellWindow, 0, 5103'),
    @('[IntPtr]$deleteLoopDialog.Current.NativeWindowHandle, 9808', '[IntPtr]$deleteLoopDialog.Current.NativeWindowHandle, 7'),
    @('Wait-UiaOwnedSheetGoneByContentClass $process.Id $shellWindow', 'Wait-UiaOwnedSheetGoneDisabled $process.Id $shellWindow')
  )
  $checked = 0
  foreach ($mutant in $mutants) {
    Assert-Derived ($source.Contains($mutant[0])) 'Delete context mutation anchor missing'
    Assert-Derived (-not (Confirm-DeleteContext ($source.Replace($mutant[0], $mutant[1])))) 'Delete context mutant accepted'
    $checked++
  }
  Assert-Derived ($checked -eq 5) 'Delete context mutation count changed'
}
Invoke-Derived 'ui.root.source.line-6182' {
  foreach ($pattern in @('UIA_RENAME_DISPATCH', 'UIA_RENAME_INPUT', 'UIA_RENAME_OUTCOME', 'SetEditTextById',
      'Native Title edit control \(id 9904\)', 'Goal summary edit control \(id 9100\)', 'Update node dialog did not open',
      'Update node cancellation left the dialog open', 'UIA_UPDATE_NODE_SUBMIT_STATE', 'UIA_UPDATE_NODE_DISPATCH',
      'UIA_DELETE_LOOP_SHEET_EVIDENCE=', 'cancelId = 9808', 'deleteId = 9800')) {
    Assert-Derived ($source -match $pattern) 'Rename/Delete/Edit Details source proof missing'
  }
  Assert-Derived ($source.Contains("Delete $([char]0x201c)UIA loop A$([char]0x201d)?") -and
    $source.Contains("Its terminal session is ended and every edge touching it is removed. This can't be undone.")) 'Exact Delete copy missing'
}
foreach ($group in @(
  @{ line = 6276; required = @('Test-MultiProjectRenameReceipt', 'Get-MultiProjectClippedRectangle', 'ClickOwnedScreenRectangle',
    'PostOwnedScreenPoint', '[int] $maximumAttempts = 100', 'postedFallback = $postedFallback', 'rightClickFallback = $rightClickFallback',
    'SetTextMessage', '$api.PSObject.Methods["SetText"]', 'messageFallbacks', 'LastFocusPostedFallback', 'LastFocusControlFallback',
    'renameButtonFallback', 'Wait-MultiProjectPeerSettled', 'Sketch-Field 9904 "rename stable immediately before submit"',
    'Invoke-MultiProjectTypeText 9904 $typedTitle $inputEvidence', 'source = "live-uia"', 'beforeSelection', 'afterSelection',
    'Windows unchanged-title rename was incorrectly treated as a no-op', 'observedOwnerCount', 'observedCardCount',
    'projectBounds', 'sidebarBounds', 'source-derived, not a UIA caption') },
  @{ line = 6292; required = @('Test-MultiProjectObservedRoster $surface $fragmentProjection $owners $selectedOwner $multiProcess.Id',
    'totalObservedCardCount', 'totalObservedProjectRowCount', 'expectedMatchedOwners', 'unexpectedCardIds', 'unexpectedProjectIds',
    'foreignProjectFragmentCount', 'static Graph destination is not an ordinary project row') },
  @{ line = 6298; required = @('Get-MultiProjectExpectedCanvasRoster', 'Get-MultiProjectCaptionGeometry', 'expectedNodeCardCount',
    'expectedProjectCaptionCount', 'projectCaptionCount', 'canvasFragmentClasses', 'overview-project', 'project-caption',
    'workspace navigation was not requested',
    'Get-MultiProjectCaptionGeometry $overview.canvasBounds $row.card.bounds (@($overview.canvasFragmentClasses | Where-Object { $_.classification -ceq "project-caption" -and $_.projectPath -ceq $owner.path })[0].bounds)') },
  @{ line = 6305; required = @('$pixelWidth = $card[2] - $card[0]', '$pixelHeight = $card[3] - $card[1]',
    '$scaleSource = if ([Math]::Abs($pixelHeight - 96) -le 1)', '$pixelWidth / 250', '$normalizedHeight = $pixelHeight / $scale',
    '$heightTolerance = if ($scaleSource -ceq "card-width-rounded" -and $scale -lt 1)', '[Math]::Max(1, $pixelWidth - 1) + 0.01',
    'scaleSource = $scaleSource', 'normalizedHeight = $normalizedHeight', 'heightTolerance = $heightTolerance') }
)) {
  Invoke-Derived "ui.root.source.line-$($group.line)" {
    foreach ($required in $group.required) {
      if ($required -ceq 'SetTextMessage') {
        Assert-Derived ($bindings.GetType('GraphCodeMultiProjectEditNative', $false) -ne $null -and
          $source.Contains('"GraphCodeMultiProjectEditNative"')) 'Production consumer does not require the compiled edit component'
        Assert-ContainsAll ([IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Host\Production\GraphCodeMultiProjectEditNative.cs'))) @($required)
      } else { Assert-ContainsAll $source @($required) }
    }
  }
}
Invoke-Derived 'ui.root.source.line-6314' {
  $body = Read-Function 'Get-MultiProjectObservation'
  Assert-Derived (-not $body.Contains('.StartsWith(') -and -not $body.Contains('$projectSelected -eq $selected')) 'Observer accepts prefixes or obsolete selection'
  Assert-ContainsAll $body @('Test-MultiProjectMetadataBatch', 'unresolvedMetadataCount',
    'Test-MultiProjectOwnerSelection $surface $owner $selectedOwner $projectSelected $loopSelected')
  Assert-ContainsAll $source @('UIA_MULTIPROJECT_METADATA_REACQUIRE=')
}
Invoke-Derived 'ui.root.source.line-6326' {
  Assert-ContainsAll $source @('function Complete-MultiProjectCapture', 'function Wait-MultiProjectCapture',
    'function Initialize-MultiProjectProcessJob', 'StandaloneProcessJob', 'rootStartUtcTicks', 'targetStartUtcTicks',
    'if (-not $capture.rootProcess.WaitForExit($remaining))', 'MULTIPROJECT_CAPTURE_DRAIN', 'MULTIPROJECT_CAPTURE_TEARDOWN=',
    'MultiProjectTeardown:', 'WaitAll', 'ownedJobEmpty', '$null = Complete-MultiProjectCapture $child $logDirectory 5000 $primaryError')
  $streamAssembly = & (Join-Path $RepositoryRoot 'Tools\windows\Import-CompiledValidationAssembly.ps1') `
    -AssemblyPath $AssemblyPath -RequiredType 'GraphCode.Validation.Ownership.UiaOwnedStreamCapture'
  Assert-Derived ([object]::ReferenceEquals($bindings, $streamAssembly)) 'Capture uses a foreign stream component'
  Assert-ContainsAll ([IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Ownership\UiaOwnedStreamCapture.cs'))) @('while ((count = await reader.ReadAsync', 'return text.ToString();')
}
Invoke-Derived 'ui.root.source.line-6352' {
  Assert-ContainsAll $activationSource @('public interface IUiaWindowActivationOperations',
    'operations.ShowWindow(window, 9);', 'operations.IsForegroundWindow(window)',
    'operations.WindowProcessId(window) == expectedProcessId', 'operations.IsRetainedProcessAlive(expectedProcessId)',
    'broughtToTop.Succeeded ? 0 : broughtToTop.Error', 'foregroundSet.Succeeded ? 0 : foregroundSet.Error',
    'no synthetic keys or input-queue attachment')
  Assert-Derived ($activationSource -notmatch '\b(DllImport|LibraryImport|SendInput|keybd_event|AttachThreadInput|Marshal)\b' -and
    [regex]::Matches($nativeSource, 'int error = Marshal.GetLastWin32Error\(\);').Count -eq 2) 'Activation native errors or synthetic-input boundary changed'
}
function Confirm-Settings([string] $Gate) {
  try {
    $body = Get-Region $Gate '$backendFocus = Retain-FocusWithRetry' 'Require ([GraphCodeUiaGateState]::PostCommand($settingsShellWindow, 0x5002))'
  } catch { return $false }
  return Confirm-Order ([regex]::Replace($body, '\s+', ' ').Trim()) @(
    '$backendFocus = Retain-FocusWithRetry', 'Require ($null -ne $backendFocus.Focused)',
    'Require ([GraphCodeUiaGateState]::IsForegroundWindow($settingsWindow))',
    'Product Settings window lost foreground ownership before accepting backend focus',
    'PostKeyboard( [IntPtr]$backendButton.Current.NativeWindowHandle, 0x0D', 'Require ($remainingSettings -eq $settingsHandle)',
    '$savedSettings.defaultBackend -eq "copilotCLI"', '$savedSettings.gateSentinel -eq "preserve"',
    '$savedSettingsBytes = [IO.File]::ReadAllBytes($settingsPath)', 'PostKeyboard( [IntPtr]$backendButton.Current.NativeWindowHandle, 0x1B',
    'Wait-UiaOwnedSheetGoneByContentClass $settingsProcess.Id $settingsShellWindow', '"GraphCodeProductSettings"',
    '[Convert]::ToBase64String($savedSettingsBytes)', 'Escape changed already-persisted Product Settings')
}
Invoke-Derived 'ui.root.source.line-6412' {
  Assert-Derived (Confirm-Settings $source) 'Actual immediate settings contract failed'
  Assert-Derived (-not (Confirm-Settings ($source.Replace('Require ([GraphCodeUiaGateState]::IsForegroundWindow($settingsWindow))',
    '$null = [GraphCodeUiaGateState]::IsForegroundWindow($settingsWindow)')))) 'Missing foreground mutant accepted'
  Assert-Derived (-not (Confirm-Settings ($source.Replace('Require ($remainingSettings -eq $settingsHandle)', '$null = ($remainingSettings -eq $settingsHandle)')))) 'Closing Return mutant accepted'
}
Invoke-Derived 'ui.root.source.line-6467' {
  $app = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\App.zig'))
  foreach ($pattern in @('fn showUiaContextMenu', 'MainWindow\.wm_uia_context_menu => \{', '(?s)wparam == MainWindow\.menu_watchdog_timer_id.*?c\.EndMenu\(\)')) {
    Assert-Derived ($app -match $pattern) 'Actual App context menu/watchdog contract missing'
  }
}
Invoke-Derived 'ui.root.source.line-6591' {
  $history = @(
    [pscustomobject]@{ requestID = 'create-request'; command = '{"projectPath":"graphcode://stub/project","command":{"createNode":{"_0":{"id":"11111111-1111-4111-8111-111111111111","title":"UIA created timed loop","loopType":"timeBased","triggerPrompt":"Summarize new commits","heartbeatIntervalSeconds":3600,"backend":"copilotCLI","modelTier":"capable"}}}}' },
    [pscustomobject]@{ requestID = 'outcome-request'; command = '{"projectPath":"graphcode://stub/project","command":{"openNode":{"_0":"11111111-1111-4111-8111-111111111111"}}}' }
  )
  $retained = @($history | Where-Object requestID -CEQ 'create-request')
  $command = $retained[0].command | ConvertFrom-Json
  Assert-Derived ($retained.Count -eq 1 -and [string]$command.projectPath -ceq 'graphcode://stub/project' -and
    [string]$command.command.createNode._0.triggerPrompt -ceq 'Summarize new commits' -and
    [double]$command.command.createNode._0.heartbeatIntervalSeconds -eq 3600) 'Retained request history selected wrong command'
}
Invoke-Derived 'ui.root.source.line-6654' {
  $needles = @(
    '$custodyMenuClick = Sketch-ClickMenu $custodyParent 5119', '$custodyCancel = Sketch-Cancel "New Child"',
    '$custodyParent = Open-SketchNodeMenu $renameFinalTitle', '$custodyTurnTile = Assert-SketchControl 9600',
    'Sketch-Type 9104 $custodyFirstInstruction', '$null = Sketch-Combo 9112 1 "Claude Code"',
    '$custodyInstructionAfterBackend = Sketch-Field 9104',
    '(Edge-GraphCount $custodyAfter) -eq (Edge-GraphCount $custodyBefore) + 2',
    '$custodyNewCommands = @($custodyAfter.receivedGraphCommands |', '$custodyExpectedOutcome = [ordered]@{',
    '$custodyOutcomes = @($custodyNewCommands | Where-Object {', '[string]$custodyOutcomes[0].requestID -cne $custodyRequest -and',
    '@($custodyAfter.unansweredRequests) -notcontains [string]$custodyOutcomes[0].requestID -and',
    '$custodyRenderWait = Wait-SketchGraphCard', '$custodyWorkspaceId = Get-MultiProjectAutomationId "workspace-loop-bar" $custodyId',
    '$custodyWorkspace = Wait-ForGraphChildren $renameRoot $rawWalker',
    '$custodyShowGraph.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()',
    '$custodyGraphReturn = Wait-ForGraphChildren $renameRoot $rawWalker', '$custodyRendered = Open-SketchNodeMenu "UIA custody child"')
  Assert-Derived (Confirm-Order $source $needles) 'Custody reopen/type/backend/unique request/render order changed'
  Assert-Derived ([regex]::Matches($source, [regex]::Escape('$custodyTurnTile = Assert-SketchControl 9600')).Count -eq 1) 'Custody Turn tile selected more than once'
}
Invoke-Derived 'ui.root.source.line-6754' {
  Assert-Derived ($nativeSource.Contains('public static class GraphCodeUiaGateState') -and
    $bindings.GetType('GraphCodeUiaGateState', $false)) 'Complete ordinary production gate helper missing'
}
Invoke-Derived 'ui.root.source.line-6770' {
  $type = $bindings.GetType('GraphCodeUiaGateState', $true)
  $calls = @([regex]::Matches($source, '\[GraphCodeUiaGateState\]::(?<member>[\w]+)') |
    ForEach-Object { $_.Groups['member'].Value } | Sort-Object -Unique)
  Assert-Derived ($calls.Count -gt 0) 'No actual production gate member calls found'
  foreach ($name in $calls) {
    Assert-Derived ($type.GetMember($name, [Reflection.BindingFlags]'Public,Static').Count -gt 0) "Actual production gate calls undefined compiled member: $name"
  }
}
Invoke-Derived 'ui.root.source.line-7027' {
  Assert-Derived (Confirm-Order $source @('UIA_COMPOSITE_NAVIGATION_EVIDENCE=',
    '$connectorActual = Find-FragmentByIdWithRetry $root "actual-size" $rawWalker',
    '$connectorActual.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()',
    '$root = Wait-ForRootReconnect $process @($rawWalker, $controlWalker)', 'Get-DynamicProjectCardCapture $_',
    '$connectorDecision = Get-ConnectorDragSnapshotDecision')) 'Connector evidence does not freeze after normalization/reconnect'
  foreach ($pattern in @('\[GraphCodeUiaGateState\]::ClientScreenBounds\(\$shellWindow\)', 'FindVisibleOwnedSheetByContentClass\(',
      'UIA_CONNECTOR_DRAG_EVIDENCE=', 'coordinateSpace = "physical-screen"', 'targetCenterVisible = \$connectorDecision\.targetCenterVisible',
      '\[GraphCodeUiaGateState\]::PostMouseDragMoveAt\(', '\$visibleTargetBounds = @\(')) {
    Assert-Derived ($source -match $pattern) 'Connector physical-screen/clipped target contract missing'
  }
}
$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
[IO.File]::WriteAllText((Join-Path $ArtifactRoot 'ui-derived-results.json'), ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
