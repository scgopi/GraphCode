param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
$uiRoot = Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Ui'
$activation = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\UiaWindowActivation.cs'))
$gate = [IO.File]::ReadAllText((Join-Path $uiRoot 'Production\GraphCodeUiaGateState.cs'))
$inputSource = [IO.File]::ReadAllText((Join-Path $uiRoot 'Production\UiaInputSafety.cs'))
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
  try { $click = Read-CSharpMethod $Source 'public PopupItemHit ClickPopupMenuItem(' } catch { return $false }
  if ([regex]::Matches($click, '\boperations\.SendInput\(').Count -ne 1 -or
      [regex]::Matches($click, 'RequireOwnedPopupForeground\(popup, owner, expectedProcessId\);').Count -ne 2 -or
      -not $click.Contains('int commandId, uint expectedProcessId)') -or
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
  }
}
Assert-UiContract ($activationCases.Count -eq 6 -and $popupCases.Count -eq 9 -and $results.Count -eq 15) `
  'Source guard case count changed'
$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
$report = Join-Path $ArtifactRoot 'ui-source-results.json'
[IO.File]::WriteAllText($report, ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
