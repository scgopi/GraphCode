[CmdletBinding()]
param(
  [switch] $List,
  [string] $ZigExecutable
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
    "src\FrameBuffer.zig",
    "..\Tools\windows\Stub-Daemon.ps1",
    "fixtures\daemon-v2-hello.json",
    "fixtures\daemon-v2-list-projects.json",
    "fixtures\daemon-v2-subscribe.json",
    "fixtures\daemon-v2-graph-event.json",
    "fixtures\daemon-v2-presence-event.json",
    "fixtures\daemon-v1-list-projects.json",
    "fixtures\daemon-v2-create-node.json",
    "fixtures\daemon-v2-message-node.json",
    "fixtures\daemon-v2-stop-node.json"
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

$metadata = Get-Content -LiteralPath (Join-Path $shellRoot "package-metadata.json") -Raw |
  ConvertFrom-Json
Assert-Contract ($metadata.installer -eq $false) "installer metadata was added"
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

$zig = Resolve-TestZig
Invoke-Native "Wire executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\Wire.zig } finally { Pop-Location }
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
Invoke-Native "Terminal input queue tests" {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $include = Join-Path $winghosttyRoot "include"
  if (-not (Test-Path -LiteralPath $include -PathType Container)) {
    throw "Winghostty headers are required for terminal input tests."
  }
  Push-Location $shellRoot
  try {
    & $zig test src\TerminalSurface.zig -target x86_64-windows-msvc -lc "-I$include"
  } finally { Pop-Location }
}
Invoke-Native "Graph model executable tests" {
  Push-Location $shellRoot
  try { & $zig test src\GraphModel.zig } finally { Pop-Location }
}

Write-Output "Windows shell scaffold contract: PASS"
exit 0
