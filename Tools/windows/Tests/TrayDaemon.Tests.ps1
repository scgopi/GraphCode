[CmdletBinding()]
param(
  [string] $Executable
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$app = Get-Content (Join-Path $root "graphcode-windows\src\App.zig") -Raw
$supervisor = Get-Content (Join-Path $root "graphcode-windows\src\DaemonSupervisor.zig") -Raw
$daemonMain = Get-Content (Join-Path $root "graphcoded\Sources\main.swift") -Raw
$tray = Get-Content (Join-Path $root "graphcode-windows\src\Tray.zig") -Raw
$package = Get-Content (Join-Path $root "Tools\windows\package.ps1") -Raw
$package += Get-Content (Join-Path $root "Tools\windows\PackageRuntime.ps1") -Raw

function Get-PeSubsystem([string] $path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
  if ([Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4) -ne "PE`0`0") {
    throw "not a PE image: $path"
  }
  $optionalOffset = $peOffset + 24
  return [BitConverter]::ToUInt16($bytes, $optionalOffset + 68)
}

if ($supervisor -notmatch "CREATE_NO_WINDOW") { throw "daemon launch must suppress console creation" }
if ($supervisor -notmatch "graphcoded\.exe") { throw "daemon launch must discover packaged sibling" }
if ($supervisor -notmatch "owned") { throw "daemon ownership state is missing" }
if ($supervisor -notmatch "OpenMutexW" -or $supervisor -notmatch "ERROR_SEM_TIMEOUT") {
  throw "daemon startup race coordination is missing"
}
if ($supervisor -notmatch "startup-ready" -or
    $supervisor -notmatch "acquireStartupReservation" -or
    $supervisor -notmatch "SetEvent") {
  throw "daemon startup reservation protocol is missing"
}
if ($supervisor -notmatch "OpenMutexW\(c\.SYNCHRONIZE" -or
    $supervisor -notmatch "WaitForSingleObject\(handle, timeout_ms\)" -or
    $supervisor -notmatch "acquireStartupReservationBounded") {
  throw "daemon startup reservation waiting and recovery are missing"
}
if ($supervisor -notmatch "failed startup competitor releases reservation for owned recovery") {
  throw "failed startup competitor recovery coverage is missing"
}
if ($supervisor -notmatch "SetEvent" -or $supervisor -notmatch "forceStop") {
  throw "graceful daemon shutdown fallback is missing"
}
if ($supervisor -notmatch "GRAPHCODE_DAEMON_STARTUP_EVENT") {
  throw "daemon startup reservation handoff is missing"
}
if ($supervisor -notmatch "GRAPHCODE_DAEMON_HANDOFF_READY_EVENT" -or
    $supervisor -notmatch "startup-child-ready" -or
    $supervisor -notmatch "waitForChildHandoff" -or
    $supervisor -notmatch "cleanupFailedStartup") {
  throw "parent must retain and clean the startup reservation through child handoff"
}
if ($daemonMain -notmatch "DaemonStartupHandoff" -or
    $daemonMain -notmatch "startupHandoff\.isParentHandoff" -or
    $daemonMain -notmatch "onPublished:" -or
    $daemonMain -notmatch "startupHandoff\.publish\(\)" -or
    $daemonMain -notmatch "recordActiveGeneration\(\)[\s\S]*?WindowsDaemonInstanceLock\(\)") {
  throw "child must skip the parent-held reservation and publish readiness after its lifetime lock"
}
$handoffLive = Join-Path $root "Tools\windows\Tests\DaemonHandoff.Live.Tests.ps1"
if (-not (Test-Path -LiteralPath $handoffLive)) {
  throw "concurrent two-shell handoff coverage is missing"
}
$handoffLiveText = Get-Content -LiteralPath $handoffLive -Raw
if ($handoffLiveText -notmatch "Concurrent shells did not spawn exactly one graphcoded child") {
  throw "concurrent two-shell handoff coverage is missing"
}
if ($handoffLiveText -notmatch "classificationDeadline" -or
    $handoffLiveText -notmatch "Assert-ShellsAlive" -or
    $handoffLiveText -notmatch "Get-HandoffDiagnostics") {
  throw "concurrent handoff test must use a diagnostic condition wait for ownership classification"
}
if ($handoffLiveText -match 'for \(\$i = 0; \$i -lt 80; \$i\+\+\) \{[\s\S]{0,400}Get-ShellSupervisorState \$owner\.Id') {
  throw "concurrent handoff test must not regress to short fixed ownership polling"
}
if ($app -notmatch "GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK" -or
    $app -notmatch "DaemonSupervisorState") {
  throw "concurrent handoff test observability is missing"
}
if ($app -notmatch "WM_CLOSE[\s\S]*?SW_HIDE") { throw "window close must hide to tray" }
if ($app -notmatch "command_open[\s\S]*?SW_SHOW" -or
    $app -notmatch "command_exit[\s\S]*?DestroyWindow") { throw "tray open/exit actions are missing" }
if ($app -notmatch "taskbar_created[\s\S]*?tray\.readd") { throw "TaskbarCreated recovery is missing" }
if ($tray -notmatch "Shell_NotifyIconW" -or
    $tray -notmatch "Open GraphCode" -or $tray -notmatch "Exit") { throw "tray shell contract is incomplete" }
if ($tray -notmatch "NIM_SETVERSION" -or
    $tray -notmatch "NOTIFYICON_VERSION_4" -or
    $tray -notmatch "icon_id") { throw "tray callback identity is incomplete" }
if ($tray -notmatch "TrackPopupMenu" -or
    $tray -notmatch "TPM_RIGHTBUTTON" -or
    $tray -notmatch "observeTestCallback" -or
    $app -notmatch "observeTestCallback[\s\S]*?showMenu") {
  throw "tray test observability must use the production callback and popup menu"
}
if ($app -notmatch "test_hook_message[\s\S]*?PostMessageW[\s\S]*?notify_message") {
  throw "tray live hook must relay through the production callback message"
}
if ($app -notmatch "callbackTargetsIcon" -or
    $app -notmatch "restoreShellWindow") { throw "tray callback routing is incomplete" }
$live = Get-Content (Join-Path $root "Tools\windows\Tests\TrayLive.Tests.ps1") -Raw
function Assert-TrayAdmissionBoundary([string] $source) {
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$parseErrors)
  if ($parseErrors.Count -or $source -notmatch '\[switch\]\s*\$AdmissionOnly') {
    throw "tray admission must be an explicit opt-in switch"
  }
  $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
  if ($main.Count -ne 1 -or $null -eq $main[0].Finally -or
      $main[0].Finally.Extent.Text -notmatch 'Stop-Process -Id \$process.Id' -or
      $main[0].Finally.Extent.Text -notmatch '(?s)if \(\$process\).*WaitForExit\(5000\).*TRAY_OWNED_CLEANUP=verified') {
    throw "tray admission must retain the normal owned cleanup finally"
  }
  $statements = @($main[0].Body.Statements)
  if ($statements[0].Extent.Text -cne '$previousDpiContext = [GraphCodeTrayLiveNative]::EnterPerMonitorV2()' -or
      $source -notmatch '(?s)preEntryContext = GetThreadDpiAwarenessContext\(\);\s*if \(preEntryContext == IntPtr.Zero\)\s*throw.*IntPtr previous = SetThreadDpiAwarenessContext\(new IntPtr\(-4\)\);.*if \(previous == IntPtr.Zero\)\s*throw.*AreDpiAwarenessContextsEqual.*RestoreDpiAwareness\(preEntryContext\);.*return preEntryContext;' -or
      $source -match 'return previous;|RestoreDpiAwareness\(previous\);' -or
      $source -notmatch '(?s)if \(restoreThread != captureThread\)\s*throw' -or
      $source -notmatch '(?s)void RestoreDpiAwareness\(IntPtr previous\).*SetThreadDpiAwarenessContext\(previous\);\s*int error = Marshal.GetLastWin32Error\(\);.*AreDpiAwarenessContextsEqual.*if \(result == IntPtr.Zero\).*throw.*if \(!equal\).*throw' -or
      $source -match 'SetProcessDpiAwareness|SetProcessDPIAware') {
    throw "tray geometry must admit thread-only PMv2 before launch and refuse failed context changes"
  }
  $cleanup = $main[0].Finally.Extent.Text
  if ($cleanup -notmatch '(?s)try.*Stop-Process.*catch\s*\{\s*\$cleanupFailure = \$_\s*\}.*try.*RestoreDpiAwareness\(\$previousDpiContext\)' -or
      $cleanup -notmatch '(?s)if \(\$null -ne \$primaryFailure\).*Write-Error -ErrorRecord \$_ -ErrorAction Continue' -or
      $main[0].Extent.Text -match 'Tray live executable tests: PASS' -or
      $ast.EndBlock.Statements[-1].Extent.Text -notmatch '(?s)^if \(\$trayAssertionsCompleted\).*Tray live executable tests: PASS') {
    throw "tray restoration must preserve primary failure and precede the full success marker"
  }
  $initial = @($statements | Where-Object { $_.Extent.Text -match '^\$trayRect = Wait-PhysicalTrayIcon \$hwnd "initial"$' })
  if ($initial.Count -ne 1) { throw "tray admission must retain the initial physical guard" }
  $index = [Array]::IndexOf($statements, $initial[0])
  $branch = $statements[$index + 1]
  if ($branch -isnot [Management.Automation.Language.IfStatementAst] -or
      $branch.Clauses.Count -ne 1 -or $null -ne $branch.ElseClause -or
      $branch.Clauses[0].Item1.Extent.Text -cne '$AdmissionOnly' -or
      $branch.Clauses[0].Item2.Extent.Text -notmatch 'Write-Output "TRAY_ADMISSION_MEASUREMENT=admitted"' -or
      $branch.Clauses[0].Item2.Statements.Count -ne 3 -or
      $branch.Clauses[0].Item2.Statements[0].Extent.Text -notmatch 'Write-TrayAdmissionGeometry.*-kind "MEASUREMENT"' -or
      $branch.Clauses[0].Item2.Statements[-1] -isnot [Management.Automation.Language.ReturnStatementAst] -or
      $statements[$index + 2].Extent.Text -notmatch '^\$racer = Start-Process') {
    throw "tray admission must return after the initial guard and before the unchanged default interaction"
  }
  $wait = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Wait-PhysicalTrayIcon'
  }, $true).Extent.Text
  if ($wait -notmatch '(?s)Assert-TrayIcon.*FindWindow.*MonitorFromPoint.*throw "Shell_NotifyIconGetRect returned coordinates outside every monitor".*GetDpiForWindow.*return \$rect' -or
      $wait -notmatch '(?s)if \(\$i -eq 29\) \{\s*Write-TrayAdmissionGeometry[^\r\n]*\s*throw\s*\}' -or
      $wait -notmatch '\$i -lt 30' -or $wait -notmatch 'Start-Sleep -Milliseconds 100') {
    throw "tray admission must preserve refusal propagation, guard order, and deadline"
  }
}
Assert-TrayAdmissionBoundary $live
$negativeSources = @(
  $live.Replace('[switch] $AdmissionOnly', '[bool] $AdmissionOnly = $true'),
  $live.Replace('if ($AdmissionOnly)', 'if ($true)'),
  $live.Replace('Stop-Process -Id $process.Id', 'Write-Output $process.Id'),
  $live.Replace('Write-Output "TRAY_ADMISSION_MEASUREMENT=admitted"', 'Write-Output "Tray live executable tests: PASS"'),
  $live.Replace('throw "Shell_NotifyIconGetRect returned coordinates outside every monitor"', 'return $rect'),
  $live.Replace('if (previous == IntPtr.Zero)', 'if (false)'),
  $live.Replace('if (result == IntPtr.Zero)', 'if (false)'),
  $live.Replace('[GraphCodeTrayLiveNative]::EnterPerMonitorV2()', '[IntPtr]::Zero'),
  $live.Replace('[GraphCodeTrayLiveNative]::RestoreDpiAwareness($previousDpiContext)', 'Write-Output $previousDpiContext'),
  $live.Replace('IntPtr result = SetThreadDpiAwarenessContext(previous);', 'IntPtr result = SetThreadDpiAwarenessContext(previous); GetThreadDpiAwarenessContext();'),
  $live.Replace('if (!equal)', 'if (false)'),
  $live.Replace('$trayAssertionsCompleted = $true', 'Write-Output "Tray live executable tests: PASS"'),
  $live.Replace('if (preEntryContext == IntPtr.Zero)', 'if (false)'),
  $live.Replace('return preEntryContext;', 'return previous;'),
  $live.Replace('if (restoreThread != captureThread)', 'if (false)')
)
foreach ($negative in $negativeSources) {
  $rejected = $false
  try { Assert-TrayAdmissionBoundary $negative } catch { $rejected = $true }
  if (-not $rejected) { throw "tray admission negative source control was accepted" }
}
$admissionCount = 1 + $negativeSources.Count
Write-Output "TRAY_ADMISSION_SOURCE_CONTRACTS=$admissionCount"
[ordered]@{
  suite = "TrayAdmission"
  executed = $admissionCount
  passed = $admissionCount
  failed = 0
  skipped = 0
} | ConvertTo-Json -Compress | Write-Output
if ($live -match "WM_COMMAND" -or
    $live -notmatch "GetMenuString" -or
    $live -notmatch "GetMenuItemID" -or
    $live -notmatch "GetMenuItemRect" -or
    $live -notmatch "SendInput") {
  throw "tray live context Exit must validate and activate the actual popup item without WM_COMMAND"
}
$mainWindow = Get-Content (Join-Path $root "graphcode-windows\src\MainWindow.zig") -Raw
if ($mainWindow -notmatch "AllowSetForegroundWindow") {
  throw "single-instance restore must grant the existing shell foreground permission"
}
if ($package -match 'Set-Content[^`r`n]*graphcode-windows\.exe') {
  throw "package must not generate a console launcher script"
}
if ($Executable) {
  if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "shell executable is missing" }
  if ((Get-PeSubsystem $Executable) -ne 2) { throw "shell executable is not PE GUI subsystem" }
}
Write-Output "Tray daemon contract tests: PASS"
