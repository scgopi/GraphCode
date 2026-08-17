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
if (-not (Test-Path -LiteralPath $handoffLive) -or
    (Get-Content -LiteralPath $handoffLive -Raw) -notmatch
      "Concurrent shells did not spawn exactly one graphcoded child") {
  throw "concurrent two-shell handoff coverage is missing"
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
