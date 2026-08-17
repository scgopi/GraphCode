[CmdletBinding()]
param(
  [string] $Executable
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$app = Get-Content (Join-Path $root "graphcode-windows\src\App.zig") -Raw
$supervisor = Get-Content (Join-Path $root "graphcode-windows\src\DaemonSupervisor.zig") -Raw
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
if ($supervisor -notmatch "SetEvent" -or $supervisor -notmatch "forceStop") {
  throw "graceful daemon shutdown fallback is missing"
}
if ($app -notmatch "WM_CLOSE[\s\S]*?SW_HIDE") { throw "window close must hide to tray" }
if ($app -notmatch "command_open[\s\S]*?SW_SHOW" -or
    $app -notmatch "command_exit[\s\S]*?DestroyWindow") { throw "tray open/exit actions are missing" }
if ($app -notmatch "taskbar_created[\s\S]*?tray\.readd") { throw "TaskbarCreated recovery is missing" }
if ($tray -notmatch "Shell_NotifyIconW" -or
    $tray -notmatch "Open GraphCode" -or $tray -notmatch "Exit") { throw "tray shell contract is incomplete" }
if ($package -match 'Set-Content[^`r`n]*graphcode-windows\.exe') {
  throw "package must not generate a console launcher script"
}
if ($Executable) {
  if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "shell executable is missing" }
  if ((Get-PeSubsystem $Executable) -ne 2) { throw "shell executable is not PE GUI subsystem" }
}
Write-Output "Tray daemon contract tests: PASS"
