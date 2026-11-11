param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
function ConvertTo-SourceLineEndings([string] $Source) {
  return $Source.Replace("`r`n", "`n")
}
$uiRoot = Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Ui'
$activation = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\UiaWindowActivation.cs'))
$gate = [IO.File]::ReadAllText((Join-Path $uiRoot 'Production\GraphCodeUiaGateState.cs'))
$inputSource = ConvertTo-SourceLineEndings ([IO.File]::ReadAllText((Join-Path $uiRoot 'Production\UiaInputSafety.cs')))
$results = [Collections.Generic.List[object]]::new()

function Assert-UiContract([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}
function Invoke-SourceCase([string] $Id, [scriptblock] $Assertion) {
  $failure = $null
  try { & $Assertion } catch { $failure = $_ }
  $results.Add([ordered]@{
    id = $Id; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = 1
    evidence = $(if ($failure) { $failure.ToString() } else { 'Actual ordinary build-time production source; nativeCalls=0' })
  })
}
function Read-CSharpMethod([string] $Source, [string] $Signature) {
  $start = $Source.IndexOf($Signature, [StringComparison]::Ordinal)
  if ($start -lt 0) { throw "Production method missing: $Signature" }
  $brace = $Source.IndexOf('{', $start)
  $depth = 1
  $end = $brace + 1
  while ($end -lt $Source.Length -and $depth -gt 0) {
    if ($Source[$end] -eq '{') { $depth++ }
    if ($Source[$end] -eq '}') { $depth-- }
    $end++
  }
  if ($depth -ne 0) { throw "Production method has no closing brace: $Signature" }
  return $Source.Substring($start, $end - $start)
}
function Confirm-ActivationSource([string] $Gate, [string] $Component) {
  $gateText = [regex]::Replace($Gate, '\s+', ' ')
  $componentText = [regex]::Replace($Component, '\s+', ' ')
  $requiredComponent = @(
    'public interface IUiaWindowActivationOperations',
    'uint expectedProcessId = operations.WindowProcessId(window);',
    'if (window == IntPtr.Zero || !operations.IsRetainedProcessAlive(expectedProcessId))',
    'operations.ShowWindow(window, 9);',
    'operations.IsForegroundWindow(window) && operations.WindowProcessId(window) == expectedProcessId && operations.IsRetainedProcessAlive(expectedProcessId)',
    'broughtToTop.Succeeded, broughtToTop.Succeeded ? 0 : broughtToTop.Error',
    'foregroundSet.Succeeded, foregroundSet.Succeeded ? 0 : foregroundSet.Error, observed',
    'observedOwnedForeground={4}; no synthetic keys or input-queue attachment'
  )
  foreach ($needle in $requiredComponent) { if (-not $componentText.Contains($needle)) { return $false } }
  if ($componentText -match '\b(DllImport|LibraryImport|SendInput|keybd_event|AttachThreadInput|Marshal)\b') { return $false }
  foreach ($needle in @(
    'private sealed class WindowActivationOperations : GraphCode.Windows.IUiaWindowActivationOperations',
    'return GraphCodeUiaGateState.WindowProcessId(window);',
    'return GraphCodeUiaGateState.IsRetainedProcessAlive(processId);',
    'GraphCodeUiaGateState.ShowWindow(window, command);',
    'return GraphCodeUiaGateState.IsForegroundWindow(window);',
    'bool succeeded = GraphCodeUiaGateState.BringWindowToTop(window); int error = Marshal.GetLastWin32Error(); return new GraphCode.Windows.UiaActivationCallResult(succeeded, error);',
    'bool succeeded = GraphCodeUiaGateState.SetForegroundWindow(window); int error = Marshal.GetLastWin32Error(); return new GraphCode.Windows.UiaActivationCallResult(succeeded, error);',
    'return GraphCode.Windows.UiaWindowActivation.ActivateWindow( ActivationOperations, window, out LastActivationDiagnostic);'
  )) { if (-not $gateText.Contains($needle)) { return $false } }
  return $true
}
$activationCases = @(
  @{ name = 'actual'; gate = $gate; component = $activation; expected = $true },
  @{ name = 'unshared'; gate = $gate.Replace('GraphCode.Windows.UiaWindowActivation.ActivateWindow(', 'UnsharedActivation('); component = $activation; expected = $false },
  @{ name = 'missing-initial-owner'; gate = $gate; component = $activation.Replace('!operations.IsRetainedProcessAlive(expectedProcessId)', 'false'); expected = $false },
  @{ name = 'missing-fresh-owner'; gate = $gate; component = $activation.Replace('operations.IsRetainedProcessAlive(expectedProcessId);', 'true;'); expected = $false },
  @{ name = 'missing-restore'; gate = $gate; component = $activation.Replace('operations.ShowWindow(window, 9);', ''); expected = $false },
  @{ name = 'missing-native-error'; gate = $gate.Replace('int error = Marshal.GetLastWin32Error();', 'int error = 0;'); component = $activation; expected = $false }
)
foreach ($case in $activationCases) {
  Invoke-SourceCase "ui.activation.source.$($case.name)" {
    Assert-UiContract ((Confirm-ActivationSource $case.gate $case.component) -eq $case.expected) `
      'UIA activation source contract accepted an unshared, unowned or undiagnosed activation mutant'
  }
}

function Confirm-PopupSource([string] $Source) {
  try {
    $default = Read-CSharpMethod $Source 'public PopupItemHit ClickPopupMenuItem('
    $strict = Read-CSharpMethod $Source 'public PopupItemHit ClickPopupMenuItemStrict('
    $click = Read-CSharpMethod $Source 'private PopupItemHit ClickPopupMenuItemCore('
  } catch { return $false }
  if ([regex]::Matches($default, '\bClickPopupMenuItemCore\(').Count -ne 1 -or
      -not $default.Contains('return ClickPopupMenuItemCore(popup, owner, position, commandId, expectedProcessId, true);') -or
      [regex]::Matches($strict, '\bClickPopupMenuItemCore\(').Count -ne 1 -or
      -not $strict.Contains('var hit = ClickPopupMenuItemCore(popup, owner, position, commandId, expectedProcessId, false);') -or
      -not $strict.Contains('if (hit == null)') -or
      -not $strict.Contains('throw new InvalidOperationException("Strict popup target identity or geometry is invalid; no input was injected");') -or
      -not $strict.Contains('return hit;') -or
      ($default + $strict) -match '\b(SendInput|PostMessage|SetForegroundWindow|SetFocus|BringWindowToTop)\(') { return $false }
  if ([regex]::Matches($click, '\boperations\.SendInput\(').Count -ne 1 -or
      [regex]::Matches($click, 'RequireOwnedPopupForeground\(popup, owner, expectedProcessId\);').Count -ne 2 -or
      -not $click.Contains('int commandId, uint expectedProcessId, bool allowFallback)') -or
      $click -match '\b(SetForegroundWindow|SetFocus|BringWindowToTop)\(') { return $false }
  $offset = 0
  foreach ($needle in @(
    'if (!operations.GetCursorPos(out before))',
    'RequireOwnedPopupForeground(popup, owner, expectedProcessId);',
    'if (!operations.SetCursorPos(screenX, screenY))',
    'var inputs = new[]',
    'ScreenPoint cursorBeforeInput;',
    'if (!operations.GetCursorPos(out cursorBeforeInput) || cursorBeforeInput.X != screenX || cursorBeforeInput.Y != screenY)',
    'throw new InvalidOperationException("Popup input cursor changed; no mouse input was injected");',
    'uint inputOwnerProcessId = operations.WindowProcessId(owner);',
    'if (inputOwnerProcessId != expectedProcessId || !operations.IsRetainedProcessAlive(expectedProcessId))',
    'IntPtr foregroundBeforeInput = operations.GetForegroundWindow();',
    'IntPtr inputPointWindow = operations.WindowFromPoint(cursorBeforeInput);',
    'if (!IsOwnedPopupInput(',
    'operations.WindowProcessId(foregroundBeforeInput), operations.GetAncestor(foregroundBeforeInput, 2),',
    'operations.WindowProcessId(inputPointWindow), operations.GetAncestor(inputPointWindow, 2), operations.IsWindowVisible(popup)))',
    'throw new InvalidOperationException("Popup input ownership changed; no mouse input was injected");',
    'uint sent = operations.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));',
    'RequireOwnedPopupForeground(popup, owner, expectedProcessId);',
    'keyboardFallback =',
    'operations.PostMessage(popup, 0x0100, (UIntPtr)0x0D, IntPtr.Zero)'
  )) {
    $next = $click.IndexOf($needle, $offset, [StringComparison]::Ordinal)
    if ($next -lt 0) { return $false }
    $offset = $next + $needle.Length
  }
  return $true
}
$rootPopup = @((Get-Content (Join-Path $uiRoot 'source-assertions.json') -Raw | ConvertFrom-Json) |
  Where-Object id -CEQ 'ui.root.source.line-6520')
$rootAst = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $uiRoot 'UiRootSourceContracts.ps1'), [ref]$null, [ref]$null)
$rootEvaluator = @($rootAst.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-AssertionValue'
}, $true))
Assert-UiContract ($rootPopup.Count -eq 1 -and $rootEvaluator.Count -eq 1) `
  'Actual declarative popup predicate or evaluator is missing or duplicated'
$gateSource = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'))
$rootPopupResults = [Collections.Generic.List[bool]]::new()
function Confirm-RootPopupSource([string] $Source) {
  $rootResources = @{ gate = $gateSource; 'input-safety' = $Source }
  function Read-SourceResource([string] $Name) {
    if (-not $rootResources.ContainsKey($Name)) { throw "Unexpected popup predicate resource: $Name" }
    return $rootResources[$Name]
  }
  . ([scriptblock]::Create($rootEvaluator[0].Extent.Text))
  $accepted = -not (Get-AssertionValue $rootPopup[0].condition)
  $rootPopupResults.Add($accepted)
  return $accepted
}
$popupCases = @(
  @{ name = 'actual'; source = $inputSource; expected = $true },
  @{ name = 'bypass-guard'; source = $inputSource.Replace('if (!IsOwnedPopupInput(', 'if (false && !IsOwnedPopupInput('); expected = $false },
  @{ name = 'stale-foreground'; source = $inputSource.Replace('IntPtr foregroundBeforeInput = operations.GetForegroundWindow();', 'IntPtr foregroundBeforeInput = owner;'); expected = $false },
  @{ name = 'stale-cursor'; source = $inputSource.Replace('operations.WindowFromPoint(cursorBeforeInput)', 'operations.WindowFromPoint(new ScreenPoint { X = screenX, Y = screenY })'); expected = $false },
  @{ name = 'missing-held-owner-check'; source = $inputSource.Replace('if (inputOwnerProcessId != expectedProcessId || !operations.IsRetainedProcessAlive(expectedProcessId))', 'if (false)'); expected = $false },
  @{ name = 'missing-pre-cursor-guard'; source = [regex]::Replace($inputSource, '(?m)^    RequireOwnedPopupForeground\(popup, owner, expectedProcessId\);', '    ;'); expected = $false },
  @{ name = 'missing-pre-enter-guard'; source = $inputSource.Replace('      RequireOwnedPopupForeground(popup, owner, expectedProcessId);', '      ;'); expected = $false },
  @{ name = 'wrong-hit-root'; source = $inputSource.Replace('operations.GetAncestor(inputPointWindow, 2)', 'operations.GetAncestor(owner, 2)'); expected = $false },
  @{ name = 'extra-input'; source = $inputSource.Replace('uint sent = operations.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));', 'operations.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input))); uint sent = operations.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));'); expected = $false }
)
foreach ($case in $popupCases) {
  Invoke-SourceCase "ui.popup.source.$($case.name)" {
    Assert-UiContract ((Confirm-PopupSource $case.source) -eq $case.expected) `
      "Popup input safety contract: $($case.name) must fail closed before real input on foreign foreground or hit point"
    if ($case.name -ceq 'actual') {
      Assert-UiContract (Confirm-RootPopupSource $inputSource) `
        'Declarative popup oracle rejects the actual checked hilite reader'
      $closureObservation = "    if (receipt != null && !operations.IsWindowVisible(popup))`n" +
        '      ObserveInput("popup-closed", (uint)inputs.Length, sent);'
      $lfSource = $inputSource.Replace("`r`n", "`n")
      foreach ($checkoutSource in @($lfSource, $lfSource.Replace("`n", "`r`n"))) {
        $normalizedSource = ConvertTo-SourceLineEndings $checkoutSource
        Assert-UiContract ([regex]::Matches($normalizedSource, [regex]::Escape($closureObservation)).Count -eq 1) `
          'LF and CRLF checkouts must identify exactly one production closure observation'
        Assert-UiContract ((Confirm-PopupSource $normalizedSource) -and (Confirm-RootPopupSource $normalizedSource)) `
          'LF and CRLF checkouts must accept the actual checked popup source'
      }
      Assert-UiContract ([regex]::Matches($inputSource, [regex]::Escape($closureObservation)).Count -eq 1) `
        'Receipt boundary positive control must identify exactly one production closure observation'
      Assert-UiContract (Confirm-RootPopupSource $inputSource.Replace($closureObservation, '')) `
        'Declarative popup oracle must preserve the no-receipt positive case'
      $receiptMutations = @(
        '    if (!operations.IsWindowVisible(popup))' + "`n" + '      ObserveInput("popup-closed", (uint)inputs.Length, sent);'
        '    if (receipt != null)' + "`n" + '      ObserveInput("popup-closed", (uint)inputs.Length, sent);'
        $closureObservation.Replace('"popup-closed"', '"selected"')
        $closureObservation.Replace('inputs.Length, sent', 'inputs.Length, 0')
        $closureObservation + "`n" + '    operations.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));'
        $closureObservation + "`n" + '    operations.PostMessage(popup, 0x0100, (UIntPtr)0x0D, IntPtr.Zero);'
      )
      Assert-UiContract ($receiptMutations.Count -eq 6 -and
        @($receiptMutations | Sort-Object -Unique).Count -eq 6) `
        'Receipt boundary controls must exercise six distinct negative source mutations'
      foreach ($replacement in $receiptMutations) {
        Assert-UiContract ($replacement -cne $closureObservation) 'Receipt boundary mutation did not change production source'
        Assert-UiContract (-not (Confirm-RootPopupSource $inputSource.Replace($closureObservation, $replacement))) `
          'Declarative popup oracle accepted an ungated, misreported or input-emitting closure boundary'
      }
      $rootMutations = @(
        @{ from = 'bool ReadMenuHilite()'; to = 'bool UnboundMenuHilite()' },
        @{ from = 'rawMenuState = operations.GetMenuState(menu, (uint)position, 0x0400);'; to = 'rawMenuState = 0;' },
        @{ from = 'if (rawMenuState == UInt32.MaxValue)'; to = 'if (false)' },
        @{ from = 'if (rawMenuState == UInt32.MaxValue)'; to = 'if (rawMenuState == UInt32.MaxValue && false)' },
        @{ from = 'throw PopupStateFailure("Popup menu state unavailable; no further input was injected");'; to = ';' },
        @{ from = 'menuStateObserved = true;'; to = ';' },
        @{ from = 'menuStateObserved = true;'; to = 'menuStateObserved = true; bool early = (rawMenuState & 0x0080) != 0;' },
        @{ from = 'return (rawMenuState & 0x0080) != 0;'; to = 'return true;' },
        @{ from = 'hiliteAtEnterFallback = ReadMenuHilite();'; to = 'hiliteAtEnterFallback = true;' },
        @{ from = 'hiliteBeforeEnter = ReadMenuHilite();'; to = 'hiliteBeforeEnter = true;' },
        @{ from = 'operations.SendMessage(popup, 0x01E5, (UIntPtr)position, IntPtr.Zero);'; to = ';' },
        @{ from = 'if (!hiliteBeforeEnter)'; to = 'if (false)' },
        @{ from = 'if (!allowFallback)'; to = 'if (false)' },
        @{ from = 'if (!hiliteBeforeEnter)'; to = 'operations.PostMessage(popup, 0x0100, (UIntPtr)0x0D, IntPtr.Zero); if (!hiliteBeforeEnter)' },
        @{ from = '      RequireOwnedPopupForeground(popup, owner, expectedProcessId);'; to = '      operations.PostMessage(popup, 0x0100, (UIntPtr)0x0D, IntPtr.Zero); RequireOwnedPopupForeground(popup, owner, expectedProcessId);' },
        @{ from = '      RequireOwnedPopupForeground(popup, owner, expectedProcessId);'; to = '      ;' }
      )
      foreach ($mutation in $rootMutations) {
        Assert-UiContract ($inputSource.Contains($mutation.from)) 'Declarative popup mutation did not change production source'
        Assert-UiContract (-not (Confirm-RootPopupSource $inputSource.Replace($mutation.from, $mutation.to))) `
          'Declarative popup oracle accepted an unchecked, unselected, unhilited or unowned Enter fallback'
      }
      $helper = Read-CSharpMethod $inputSource 'bool ReadMenuHilite()'
      $unusedDecoy = $inputSource.Replace('ReadMenuHilite()', 'UncheckedMenuHilite()').
        Replace('if (rawMenuState == UInt32.MaxValue)', 'if (false)').
        Replace('bool UncheckedMenuHilite()', "$helper`n    bool UncheckedMenuHilite()")
      Assert-UiContract (-not (Confirm-RootPopupSource $unusedDecoy)) `
        'Declarative popup oracle accepted an unused checked helper while callers used an unchecked reader'
      Assert-UiContract ($rootPopupResults.Count -eq $rootMutations.Count + $receiptMutations.Count + 5 -and
        @($rootPopupResults | Where-Object { $_ }).Count -eq 4) `
        'Declarative popup positive and each source mutation did not execute exactly once'
      foreach ($mutation in @(
        @{ from = 'return ClickPopupMenuItemCore(popup, owner, position, commandId, expectedProcessId, true);'; to = 'return null;' },
        @{ from = 'var hit = ClickPopupMenuItemCore(popup, owner, position, commandId, expectedProcessId, false);'; to = 'var hit = ClickPopupMenuItemCore(popup, owner, position, commandId, expectedProcessId, true);' },
        @{ from = 'if (hit == null)'; to = 'if (false)' },
        @{ from = 'return hit;'; to = 'return ClickPopupMenuItemCore(popup, owner, position, commandId, expectedProcessId, false);' },
        @{ from = 'private PopupItemHit ClickPopupMenuItemCore('; to = 'private PopupItemHit UnsharedPopupCore(' }
      )) {
        Assert-UiContract ($inputSource.Contains($mutation.from)) 'Popup forwarding mutation did not change production source'
        Assert-UiContract (-not (Confirm-PopupSource $inputSource.Replace($mutation.from, $mutation.to))) `
          'Popup source contract accepted an unshared, fallback-enabled, non-refusing or replayed forwarding route'
      }
    }
  }
}
foreach ($result in $results | Where-Object { $_.id -ceq 'ui.popup.source.actual' -and $_.status -ceq 'Passed' }) {
  $result.evidence += "; actual declarative predicate/evaluator checks=$($rootPopupResults.Count), accepted=4, refused=$($rootPopupResults.Count - 4); LF and CRLF checkout controls=2"
}
Assert-UiContract ($activationCases.Count -eq 6 -and $popupCases.Count -eq 9 -and $results.Count -eq 15) `
  'Source guard case count changed'
$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
$report = Join-Path $ArtifactRoot 'ui-source-results.json'
[IO.File]::WriteAllText($report, ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
