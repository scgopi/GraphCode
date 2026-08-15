[CmdletBinding()]
param(
  [switch] $List
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$shellRoot = Join-Path $repoRoot "graphcode-windows"

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

foreach ($path in @(
    "build.zig",
    "build.zig.zon",
    "provider-pins.json",
    "package-metadata.json",
    "README.md",
    "src\main.zig",
    "src\App.zig",
    "src\MainWindow.zig",
    "src\DaemonClient.zig",
    "src\GraphModel.zig",
    "src\GraphCanvas.zig",
    "src\Sidebar.zig",
    "src\TerminalWorkspace.zig",
    "src\TerminalSurface.zig",
    "src\InputRouter.zig",
    "src\Accessibility.zig",
    "src\DesignTokens.zig",
    "src\Wire.zig",
    "fixtures\daemon-v2-hello.json",
    "fixtures\daemon-v2-list-projects.json",
    "fixtures\daemon-v2-subscribe.json",
    "fixtures\daemon-v2-graph-event.json",
    "fixtures\daemon-v2-presence-event.json",
    "fixtures\daemon-v1-list-projects.json"
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
  "858727af10cdf43d66cb3733cff58dc90ec4b3dd") "zmx pin changed"
Assert-Contract ($pins.winghostty.remoteUrl -eq
  "https://github.com/coneilen/winghostty.git") "Winghostty remote URL changed"
Assert-Contract ($pins.zmx.remoteUrl -eq
  "https://github.com/coneilen/zmx.git") "zmx remote URL changed"
Assert-Contract ($pins.localFallback.enabled) "local provider fallback is undocumented"

$source = (
  Get-ChildItem -LiteralPath (Join-Path $shellRoot "src") -Filter *.zig |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
) -join "`n"
foreach ($token in @(
    "CreateWindowExW",
    "GetMessageW",
    "TranslateMessage",
    "GetWindowLongPtrW",
    "CreateMutexW",
    "ERROR_ALREADY_EXISTS",
    "CreateFileW",
    "WaitNamedPipeW",
    "PeekNamedPipe",
    "ReadFile",
    "WriteFile",
    "supported_versions",
    "ProtocolMode",
    "v2Hello",
    "v2Request",
    "requestID",
    "resumeFrom",
    "subscription",
    "reconnecting",
    "graphChanged",
    "presence",
    "winghostty_host_initialize",
    "winghostty_host_create_surface_v2",
    "winghostty_surface_destroy",
    "winghostty_surface_set_focus",
    "zmx_path",
    "zmx",
    "child.cwd",
    "child.kill",
    "child.wait",
    "recreate",
    "active_surface",
    "DesignTokens",
    "graphCommand",
    "messageNode",
    "stopNode"
  )) {
  Assert-Contract ($source.Contains($token)) "source is missing: $token"
}
Assert-Contract (-not $source.Contains("GraphCode A\r\nsimultaneous output")) `
  "shell contains synthetic terminal output"
Assert-Contract (-not $source.Contains("GraphCode B\r\nsimultaneous output")) `
  "shell contains synthetic terminal output"

$metadata = Get-Content -LiteralPath (Join-Path $shellRoot "package-metadata.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($metadata.installer -eq $false) "installer metadata was added"
Assert-Contract ($metadata.executable -eq "graphcode-windows.exe") `
  "package metadata does not identify the shell"

Write-Output "Windows shell scaffold contract: PASS"
exit 0
