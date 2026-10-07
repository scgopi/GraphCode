[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$app = Get-Content -LiteralPath (Join-Path $repoRoot "graphcode-windows\src\App.zig") -Raw
$main = Get-Content -LiteralPath (Join-Path $repoRoot "graphcode-windows\src\main.zig") -Raw
$build = Get-Content -LiteralPath (Join-Path $repoRoot "graphcode-windows\build.zig") -Raw
$package = Get-Content -LiteralPath (Join-Path $repoRoot "Tools\windows\package.ps1") -Raw
$provider = Get-Content -LiteralPath (Join-Path $repoRoot "graphcode-windows\src\AccessibilityProvider.cpp") -Raw
$checks = 0

function Require([bool] $condition, [string] $message) {
  if (-not $condition) { throw $message }
  $script:checks++
}

Require ($app.Contains("std.Thread.spawn(") -and
         $app.Contains("worktreeInspectionWorker") -and
         $app.Contains("finishWorktreeInspection")) `
  "RED: Worktrees inspection is not owned by a background worker with UI-thread completion"
Require ($app.Contains("worktreeReclaimWorker") -and
         $app.Contains("finishWorktreeReclaim")) `
  "RED: Worktrees reclaim is not owned by a background worker with UI-thread completion"
Require ($app.Contains('"Reading worktrees..."') -and
         $app.Contains('"worktree-loading"') -and
         $app.Contains("worktreeActivityBounds")) `
  "RED: asynchronous Worktrees loading is not visible in pixels and UIA"
Require ($app.Contains('test "Worktrees inspection action does not block the UI thread on provider work"')) `
  "RED: the real App inspection route has no bounded responsiveness regression"
Require ($app.Contains('test "Worktrees reclaim action returns before owned provider removal completes"')) `
  "RED: the real App reclaim route has no bounded responsiveness regression"
Require ($app -match '(?s)pub fn init\(allocator: std\.mem\.Allocator\).*?\.model = GraphModel\.Model\.init\(allocator\)') `
  "RED: production App initialization does not construct the graph model"
Require (-not $app.Contains("Worktrees are deferred for this preview")) `
  "RED: production still exposes the retired Worktrees preview deferral"
Require (-not $build.Contains("worktrees-deferred")) `
  "RED: the Windows build still permits compiling Worktrees out"
Require ($package.Contains('$worktreesDeferred = "false"')) `
  "RED: release packaging does not keep Worktrees available"
Require (-not $package.Contains('"-Dworktrees-deferred=')) `
  "RED: release packaging still passes the retired Worktrees deferral option"
Require ($main.Contains('try stdout.interface.print("available\n", .{});')) `
  "RED: the packaged product does not report Worktrees as available"
Require ($provider.Contains("worktreeFixedEnabledLocked") -and
         $provider.Contains("UIA_IsOffscreenPropertyId") -and
         $provider.Contains("id_ >= 7 && id_ <= 13")) `
  "RED: fixed Worktrees UIA actions still publish shared on-screen enabled controls"

Write-Host "Worktree asynchronous availability contracts: $checks passed"
