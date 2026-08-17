[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$app = Get-Content (Join-Path $root "graphcode-windows\src\App.zig") -Raw
$supervisor = Get-Content (Join-Path $root "graphcode-windows\src\DaemonSupervisor.zig") -Raw
$tray = Get-Content (Join-Path $root "graphcode-windows\src\Tray.zig") -Raw
$package = Get-Content (Join-Path $root "Tools\windows\package.ps1") -Raw

if ($supervisor -notmatch "CREATE_NO_WINDOW") { throw "daemon launch must suppress console creation" }
if ($supervisor -notmatch "graphcoded\.exe") { throw "daemon launch must discover packaged sibling" }
if ($supervisor -notmatch "owned") { throw "daemon ownership state is missing" }
if ($app -notmatch "WM_CLOSE[\s\S]*?SW_HIDE") { throw "window close must hide to tray" }
if ($app -notmatch "Tray\.command_open[\s\S]*?SW_SHOW" -or
    $app -notmatch "Tray\.command_exit[\s\S]*?DestroyWindow") { throw "tray open/exit actions are missing" }
if ($app -notmatch "Tray\.taskbar_created[\s\S]*?tray\.readd") { throw "TaskbarCreated recovery is missing" }
if ($tray -notmatch "Shell_NotifyIconW" -or
    $tray -notmatch "Open GraphCode" -or $tray -notmatch "Exit") { throw "tray shell contract is incomplete" }
if ($package -match 'Set-Content[^`r`n]*graphcode-windows\.exe') {
  throw "package must not generate a console launcher script"
}
Write-Output "Tray daemon contract tests: PASS"
