[CmdletBinding()]
param(
  # Everything below is off by default and does not change any existing static
  # contract check or its exit code. -Live adds a real screenshot/pixel-sample
  # comparison against currentThemeContract.liveToleranceRegions; it requires
  # -AllowLaunch as an explicit second confirmation because it builds and launches
  # graphcode-windows.exe. Neither switch is exercised by CI or by this change --
  # a capture/UIA slot and a further go-ahead are required before this ever runs.
  [switch] $Live,
  [switch] $AllowLaunch,
  [string] $Zig0152 = "D:\zigpin\zig-x86_64-windows-0.15.2\zig.exe",
  [string] $WinghosttyRoot,
  [string] $ZmxRoot
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$manifestPath = Join-Path $repoRoot "investigation\visual-baseline\manifest.json"

function Assert-Contract([object] $condition, [string] $message) {
  $values = @($condition)
  if ($values.Count -ne 1 -or -not [bool] $values[0]) {
    throw "Visual baseline contract: $message"
  }
}

function Utc-Stamp([object] $value) {
  $date = if ($value -is [DateTime]) {
    $value.ToUniversalTime()
  } else {
    [DateTime]::Parse(
      [string] $value,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AdjustToUniversal)
  }
  $date.ToString(
    "yyyy-MM-dd'T'HH:mm:ss'Z'",
    [Globalization.CultureInfo]::InvariantCulture)
}

Assert-Contract (Test-Path -LiteralPath $manifestPath) `
  "manifest is missing at $manifestPath"

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Assert-Contract ($manifest.schemaVersion -eq 1) "schemaVersion must be 1"
Assert-Contract ($manifest.id -eq "graphcode.windows.visual-baseline") `
  "manifest id is not stable"
Assert-Contract ($manifest.baseCommit -eq "ece55b6") `
  "manifest must be based on CONTRACT_BASE ece55b6"
Assert-Contract ((Utc-Stamp $manifest.clock) -eq "2026-01-15T15:00:00Z") `
  "clock must be the fixed UTC fixture time"

$manifestText = Get-Content -LiteralPath $manifestPath -Raw
foreach ($pattern in @(
    "[A-Za-z]:\\",
    "(?i)GraphCode-worktrees",
    "(?i)(?:^|[\\/])Users[\\/]",
    "(?i)(?:^|[\\/])home[\\/]",
    "(?i)[\\/]private[\\/]"
  )) {
  Assert-Contract ($manifestText -notmatch $pattern) `
    "manifest contains an environment-specific path matching '$pattern'"
}

$sourceReferences = @($manifest.sourceReferences)
Assert-Contract ($sourceReferences.Count -ge 10) "public source references are incomplete"
foreach ($source in $sourceReferences) {
  Assert-Contract (Test-Path -LiteralPath (Join-Path $repoRoot $source)) `
    "source reference does not exist: $source"
}

foreach ($screenshot in @($manifest.screenshotSources)) {
  $path = Join-Path $repoRoot $screenshot.path
  Assert-Contract (Test-Path -LiteralPath $path) `
    "public screenshot source does not exist: $($screenshot.path)"
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  Assert-Contract ($hash -eq $screenshot.sha256) `
    "screenshot hash changed: $($screenshot.path)"
}

$requiredTokens = @(
  "Theme.windowTone",
  "Theme.windowBackground",
  "Theme.canvasBackground",
  "Theme.canvasTone",
  "Theme.canvasGridLine",
  "Theme.unfocusedPaneVeil",
  "Theme.terminalBackgroundOpacity",
  "Theme.workspaceRail",
  "Theme.paneFocusTint",
  "LoopCardView.Metrics.size",
  "LoopCardView.Metrics.radius",
  "LoopCardView.Metrics.stripe",
  "LoopWorkspaceRail.width",
  "PaneHeaderView.height",
  "CanvasAttentionRail.reviewShortcut"
)
$tokens = @($manifest.tokenContracts | ForEach-Object { $_.name })
foreach ($token in $requiredTokens) {
  Assert-Contract ($tokens -contains $token) "required token is missing: $token"
}

$requiredStates = @(
  "idle", "running", "awaitingInput", "blocked", "succeeded", "failed",
  "stalled", "waiting", "stopped"
)
$requiredTypes = @("goalBased", "timeBased", "turnBased", "composite")
Assert-Contract ($manifest.graph.id -eq "00000000-0000-4000-8000-000000000001") `
  "graph ID must be fixed"
Assert-Contract ($manifest.graph.project.path -eq "graphcode://fixtures/windows-visual-baseline") `
  "local fixture project path must be synthetic"
$nodes = @($manifest.graph.nodes)
Assert-Contract ($nodes.Count -eq 9) "the graph must contain nine fixed card states"
$nodeIDs = @($nodes | ForEach-Object { $_.id })
Assert-Contract (($nodeIDs | Sort-Object -Unique).Count -eq $nodeIDs.Count) `
  "graph node IDs must be unique"
foreach ($node in $nodes) {
  Assert-Contract ($node.id -match "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$") `
    "node ID is not a stable UUID: $($node.id)"
  Assert-Contract ($requiredStates -contains $node.state) `
    "unknown card state: $($node.state)"
  Assert-Contract ($requiredTypes -contains $node.type) `
    "unknown loop type: $($node.type)"
  Assert-Contract ((Utc-Stamp $node.createdAt) -match "Z$") `
    "node time must be UTC: $($node.id)"
  Assert-Contract (@($node.metricHistory).Count -ge 0) `
    "metric history must be present: $($node.id)"
}
foreach ($state in $requiredStates) {
  Assert-Contract (@($nodes | Where-Object state -eq $state).Count -eq 1) `
    "card state must appear exactly once: $state"
}
foreach ($type in $requiredTypes) {
  Assert-Contract (@($nodes | Where-Object type -eq $type).Count -ge 1) `
    "loop type is not represented: $type"
}

$expectedWords = @{
  idle = "SCHEDULED"
  running = "RUNNING"
  awaitingInput = "NEEDS YOU"
  blocked = "BLOCKED"
  succeeded = "DONE"
  failed = "FAILED"
  stalled = "STALLED"
  waiting = "WAITING"
  stopped = "STOPPED"
}
foreach ($node in $nodes) {
  Assert-Contract ($node.displayWord -eq $expectedWords[$node.state]) `
    "state word does not match LoopStateAppearance: $($node.id)"
  Assert-Contract ($node.PSObject.Properties.Name -contains "metricHistory") `
    "metrics must be explicit, even when empty: $($node.id)"
}
$metricNodes = @($nodes | Where-Object { @($_.metricHistory).Count -ge 2 })
Assert-Contract ($metricNodes.Count -ge 3) "fixed metric samples are incomplete"
foreach ($node in $metricNodes) {
  $values = @($node.metricHistory | ForEach-Object { $_.value })
  Assert-Contract ($values.Count -ge 2) "metric needs two fixed samples: $($node.id)"
  foreach ($sample in @($node.metricHistory)) {
    Assert-Contract ((Utc-Stamp $sample.recordedAt) -match "Z$") `
      "metric time must be UTC: $($node.id)"
  }
}

$rail = $manifest.canvas.attentionRail
Assert-Contract ($rail.count -eq 4) "attention rail count must be four"
Assert-Contract ($rail.reviewShortcut -eq "⌘⇧R") "attention shortcut changed"
Assert-Contract ($rail.oldestAge -eq "1h 30m") "attention clock is not deterministic"
$reasons = @("failed", "stalled", "awaitingInput", "blocked")
foreach ($reason in $reasons) {
  Assert-Contract (@($rail.items | Where-Object reason -eq $reason).Count -eq 1) `
    "attention rail is missing reason: $reason"
}

$remote = $manifest.sidebar.remoteIndicator
Assert-Contract ($remote.glyph -eq "network") "remote indicator must use network glyph"
$remoteProject = @($manifest.sidebar.rows | Where-Object { $_.remote -eq $true })
Assert-Contract ($remoteProject.Count -ge 1) "remote sidebar row is missing"
Assert-Contract (($remoteProject | Where-Object { $_.path -match "^ssh://fixture\.example/" }).Count -ge 1) `
  "remote fixture must use a public synthetic SSH path"
Assert-Contract ($manifest.workspace.remote -eq $true) "remote workspace state is missing"

Assert-Contract ($manifest.workspace.rail.visible -eq $true) "workspace rail is not covered"
Assert-Contract ($manifest.workspace.rail.width -eq 212) "workspace rail width changed"
$directions = @(
  $manifest.workspace.tabs |
    ForEach-Object { $_.root } |
    ForEach-Object {
      if ($_.kind -eq "split") {
        $_.direction
        $_.children | ForEach-Object { $_.direction }
      }
    }
)
Assert-Contract ($directions -contains "horizontal") "horizontal split fixture is missing"
Assert-Contract ($directions -contains "vertical") "vertical split fixture is missing"

$regions = @($manifest.regions)
$deterministicIDs = @($manifest.renderingBoundary.deterministicScreenshotRegions)
$liveIDs = @($manifest.renderingBoundary.liveWinghosttyFunctionalTests)
Assert-Contract ($deterministicIDs.Count -ge 6) "GraphCode screenshot regions are incomplete"
Assert-Contract ($liveIDs.Count -ge 2) "Winghostty functional boundary is incomplete"
Assert-Contract ((@($deterministicIDs | Where-Object { $liveIDs -contains $_ })).Count -eq 0) `
  "deterministic and live region sets must be disjoint"
foreach ($id in $deterministicIDs) {
  $region = @($regions | Where-Object id -eq $id)
  Assert-Contract ($region.Count -eq 1 -and $region[0].owner -eq "GraphCode" -and
    $region[0].kind -eq "deterministic") `
    "screenshot region is not GraphCode-owned: $id"
}
foreach ($id in $liveIDs) {
  $region = @($regions | Where-Object id -eq $id)
  Assert-Contract ($region.Count -eq 1 -and $region[0].owner -eq "Winghostty" -and
    $region[0].kind -eq "live-functional") `
    "live region is not Winghostty-owned: $id"
}

# --- DPI geometry: reproducible per-region control-metric checks ---------------
#
# The four DPI variants below are layout math, not literal screen pixels: this repo
# cannot deterministically rasterize a live Win32 window in CI (the terminal surface
# itself is explicitly out of scope for pixel comparison; see renderingBoundary
# above). Instead this reproduces graphcode-windows/src/Dpi.zig's exact
# scale()/rounding formula against the *real* control-metric constants read straight
# out of graphcode-windows/src/DesignTokens.zig, so a change to either the DPI math
# or a token's base pixel value is caught here without needing to build or run the
# Windows shell.
function Get-ScaledPixels([int] $value, [int] $dpi, [int] $baseDpi = 96) {
  # Mirrors Dpi.scale()'s @divTrunc((value * dpi + baseDpi / 2), baseDpi): truncating
  # (round-half-up for positive operands) integer division, not floating point.
  return [Math]::Truncate(($value * $dpi + [Math]::Truncate($baseDpi / 2)) / $baseDpi)
}
# Self-check against Dpi.zig's own fixed-point unit test cases (`scale(100, 120) ==
# 125`, `scale(100, 144) == 150`) so a mistaken reimplementation here fails loudly
# instead of silently validating the wrong formula.
Assert-Contract ((Get-ScaledPixels 100 96) -eq 100) "DPI scale reimplementation drifted from Dpi.zig at 96 DPI"
Assert-Contract ((Get-ScaledPixels 100 120) -eq 125) "DPI scale reimplementation drifted from Dpi.zig at 120 DPI"
Assert-Contract ((Get-ScaledPixels 100 144) -eq 150) "DPI scale reimplementation drifted from Dpi.zig at 144 DPI"

$designTokensPath = Join-Path $repoRoot "graphcode-windows\src\DesignTokens.zig"
Assert-Contract (Test-Path -LiteralPath $designTokensPath) `
  "DesignTokens.zig is missing: $designTokensPath"
$designTokensText = Get-Content -LiteralPath $designTokensPath -Raw
function Get-DesignToken([string] $name) {
  $match = [regex]::Match($designTokensText, "(?m)^pub const $([regex]::Escape($name)): i32 = (-?\d+);")
  Assert-Contract $match.Success "DesignTokens.zig no longer defines i32 constant: $name"
  return [int] $match.Groups[1].Value
}

$dpi = @($manifest.dpiVariants)
$expectedDpiByVariant = @{ "100" = 96; "125" = 120; "150" = 144; "200" = 192 }
foreach ($variantID in @("100", "125", "150", "200")) {
  Assert-Contract (@($dpi | Where-Object id -eq $variantID).Count -eq 1) `
    "DPI variant is missing: $variantID"
}
foreach ($variant in $dpi) {
  Assert-Contract ($variant.scale -gt 0) "DPI scale must be positive: $($variant.id)"
  Assert-Contract ($variant.viewport.width -gt 0 -and $variant.viewport.height -gt 0) `
    "DPI viewport must be positive: $($variant.id)"
  Assert-Contract ($variant.dpi -eq $expectedDpiByVariant[[string] $variant.id]) `
    "DPI variant does not use the real Windows per-monitor DPI value: $($variant.id)"
  Assert-Contract ([Math]::Abs(($variant.dpi / 96.0) - $variant.scale) -lt 0.0001) `
    "DPI variant scale is inconsistent with its raw dpi value: $($variant.id)"
}

$regionGeometry = @($manifest.regionGeometry)
Assert-Contract ($regionGeometry.Count -ge 4) "region geometry coverage is incomplete"
foreach ($entry in $regionGeometry) {
  Assert-Contract ($deterministicIDs -contains $entry.regionID) `
    "region geometry must target a GraphCode-owned deterministic region, not a live Winghostty region: $($entry.regionID)"
  Assert-Contract ($entry.token -match "^DesignTokens\.[A-Za-z_][A-Za-z0-9_]*$") `
    "region geometry token is not a DesignTokens constant reference: $($entry.token)"
  $tokenName = $entry.token -replace "^DesignTokens\.", ""
  $basePixels = Get-DesignToken $tokenName
  Assert-Contract ($basePixels -gt 0) "region geometry token must be a positive base metric: $($entry.token)"
  $previousPixels = 0
  foreach ($variant in $dpi) {
    $scaledPixels = Get-ScaledPixels $basePixels $variant.dpi
    Assert-Contract ($scaledPixels -ge $previousPixels) `
      "region geometry must not shrink as DPI increases: $($entry.token) at $($variant.id)%"
    $previousPixels = $scaledPixels
  }
  # 100% must reproduce the token's own base (96 DPI) pixel value exactly.
  Assert-Contract ((Get-ScaledPixels $basePixels 96) -eq $basePixels) `
    "region geometry 100% variant must equal the token's base pixel value: $($entry.token)"
}

foreach ($snapshot in @($manifest.terminalSnapshots)) {
  $path = Join-Path $repoRoot $snapshot.path
  Assert-Contract (Test-Path -LiteralPath $path) `
    "terminal snapshot does not exist: $($snapshot.path)"
  $text = Get-Content -LiteralPath $path -Raw
  Assert-Contract ($text.Trim().Length -gt 0) "terminal snapshot is empty: $($snapshot.id)"
  Assert-Contract ($text -notmatch "[A-Za-z]:\\" -and $text -notmatch "(?i)GraphCode-worktrees") `
    "terminal snapshot contains an environment-specific path: $($snapshot.id)"
}

# --- currentThemeContract: current-source color derivation, distinct from the -----
# --- frozen historical tokenContracts/baseCommit checked above. -------------------
#
# Two genuinely different kinds of checks follow, and they must not be conflated:
#   1. A static source-drift check (this section, always run, zero tolerance): does
#      graphcode/Sources/Features/App/Theme.swift, as it exists on disk right now in
#      this checkout, still produce exactly the RGB values recorded in
#      currentThemeContract? This must reject *any* incorrect/changed token.
#   2. A live pixel-tolerance check (further below, gated behind -Live -AllowLaunch,
#      never run by default): does a real captured screenshot pixel fall within a
#      small, source-justified tolerance of that same expected value? This
#      deliberately *accepts* colors inside its tolerance band, including plausible
#      near-miss colors -- that is a disclosed limitation of live pixel sampling, not
#      a second static-equality check, and it must never be tightened or special-cased
#      just to make a particular negative-control example fail.

function ConvertTo-Rgb8Channel([double] $channel) {
  # Round-half-up, matching currentThemeContract.roundingRule: floor(x*255+0.5).
  $clamped = [Math]::Max(0.0, [Math]::Min(1.0, $channel))
  return [int] [Math]::Floor(($clamped * 255.0) + 0.5)
}
Assert-Contract ((ConvertTo-Rgb8Channel 0.040) -eq 10) "rounding reimplementation drifted at 0.040"
Assert-Contract ((ConvertTo-Rgb8Channel 0.048) -eq 12) "rounding reimplementation drifted at 0.048"
Assert-Contract ((ConvertTo-Rgb8Channel 0.044) -eq 11) "rounding reimplementation drifted at 0.044"

function Get-ThemeSwiftTokenRgb([string] $themeText, [string] $tokenName) {
  # Matches `static let <tokenName> = Color(red: R, green: G, blue: B)`. Takes the
  # source text as a parameter (rather than reading a file itself) specifically so
  # tests can feed it a mutated copy and prove drift is actually detected, not just
  # assumed to fail "someday". Line-ending-agnostic: operates on whatever text is
  # passed in, never compares raw file bytes.
  $pattern = "static let $([regex]::Escape($tokenName))\s*=\s*Color\(red:\s*([0-9.]+),\s*green:\s*([0-9.]+),\s*blue:\s*([0-9.]+)\)"
  $match = [regex]::Match($themeText, $pattern)
  if (-not $match.Success) {
    throw "Theme.swift text no longer defines a Color(red:green:blue:) literal for: $tokenName"
  }
  return @(
    (ConvertTo-Rgb8Channel ([double] $match.Groups[1].Value)),
    (ConvertTo-Rgb8Channel ([double] $match.Groups[2].Value)),
    (ConvertTo-Rgb8Channel ([double] $match.Groups[3].Value))
  )
}

function ConvertFrom-Colorref([int] $colorref) {
  # Win32 COLORREF packs 0x00BBGGRR -- the reverse byte order of the 0x00RRGGBB a
  # hex literal like this superficially resembles. Getting this backwards would
  # silently compare swapped R/B channels, so this has its own worked-example
  # self-check immediately below rather than being trusted to "look right".
  $r = $colorref -band 0xFF
  $g = ($colorref -shr 8) -band 0xFF
  $b = ($colorref -shr 16) -band 0xFF
  return @($r, $g, $b)
}
# graphcode-windows/src/DesignTokens.zig's canvas_grid_line COLORREF, decoded, must
# equal the independently Theme.swift-traced RGB in currentThemeContract.crossChecks
# -- proving this helper's byte order is correct, not merely plausible.
$colorrefWorkedExample = ConvertFrom-Colorref 0x00161815
Assert-Contract (($colorrefWorkedExample -join ",") -eq "21,24,22") `
  "ConvertFrom-Colorref byte order is wrong: 0x00161815 must decode to RGB(21,24,22), got $($colorrefWorkedExample -join ',')"

function Test-ColorWithinTolerance([int[]] $actual, [int[]] $expected, [int] $tolerancePerChannel) {
  for ($channel = 0; $channel -lt 3; $channel++) {
    if ([Math]::Abs($actual[$channel] - $expected[$channel]) -gt $tolerancePerChannel) {
      return $false
    }
  }
  return $true
}
# Boundary self-check with synthetic values, not a "plausible" real color: a
# distance exactly equal to the tolerance must pass, and tolerance+1 must fail. A
# real near-miss color (e.g. a flat gray close to canvasTone's green tint) is
# deliberately *not* used here, because whether such a color passes or fails is
# exactly what the tolerance is meant to decide -- it is not a case the comparator
# itself can be graded against, and tightening the tolerance until a chosen
# real-world example fails would be reverse-engineering the test to fit a desired
# answer rather than validating the comparator.
$toleranceExpected = @(10, 12, 11)
Assert-Contract (Test-ColorWithinTolerance @(11, 12, 11) $toleranceExpected 1) `
  "tolerance boundary regressed: a distance of exactly the tolerance (1) must pass"
Assert-Contract (-not (Test-ColorWithinTolerance @(12, 12, 11) $toleranceExpected 1)) `
  "tolerance boundary regressed: a distance of tolerance+1 (2) must fail"

$themeSwiftPath = Join-Path $repoRoot "graphcode\Sources\Features\App\Theme.swift"
Assert-Contract (Test-Path -LiteralPath $themeSwiftPath) `
  "Theme.swift is missing: $themeSwiftPath"
# Re-derives from the actual current worktree file on disk, not a historical git
# blob/commit -- this must work in a shallow checkout with no dependency on any
# older commit object being fetchable, and it is what actually builds today, unlike
# a pinned historical revision.
$themeSwiftText = Get-Content -LiteralPath $themeSwiftPath -Raw
$currentThemeContract = $manifest.currentThemeContract
Assert-Contract ($null -ne $currentThemeContract) "currentThemeContract section is missing from the manifest"
Assert-Contract ($currentThemeContract.supersedes -eq "tokenContracts") `
  "currentThemeContract must declare it supersedes tokenContracts, not replace it"
foreach ($token in @($currentThemeContract.tokens)) {
  $shortName = $token.name -replace "^Theme\.", ""
  $derivedRgb = Get-ThemeSwiftTokenRgb $themeSwiftText $shortName
  $recordedRgb = @($token.rgb | ForEach-Object { [int] $_ })
  # Zero tolerance: this is the exact-equality source-drift check. Any real change
  # to Theme.swift's literal for this token -- including an accidental regression
  # back toward a historical value, or any other edit -- must fail here until
  # currentThemeContract is deliberately updated to match.
  Assert-Contract ((($derivedRgb -join ",")) -eq ($recordedRgb -join ",")) `
    ("currentThemeContract drift detected for $($token.name): Theme.swift ($themeSwiftPath, " +
     "line ~$($token.sourceLine)) now derives RGB($($derivedRgb -join ',')) but the manifest " +
     "still records RGB($($recordedRgb -join ',')). If this is an intentional design change, " +
     "update currentThemeContract's rgb/hex/swiftLiteral; otherwise this is a real regression.")
}
foreach ($crossCheck in @($currentThemeContract.crossChecks)) {
  $colorrefValue = [Convert]::ToInt32(($crossCheck.windowsColorref -replace "^0x", ""), 16)
  $decoded = ConvertFrom-Colorref $colorrefValue
  $expected = @($crossCheck.decodedRgb | ForEach-Object { [int] $_ })
  Assert-Contract ((($decoded -join ",")) -eq ($expected -join ",")) `
    "currentThemeContract crossCheck decoded incorrectly: $($crossCheck.windowsColorref) -> $($decoded -join ',') but manifest expects $($expected -join ',')"
}

# --- Gated live capture: off by default, requires -Live and -AllowLaunch together -
#
# Not exercised by this change and not run in CI. Reuses Tools\windows\windows-shell.ps1
# for build/launch (no parallel build/launch path); adds only the capture/compare
# step that tool does not perform. Requires an assigned capture/UIA slot before use.
if ($Live -and $AllowLaunch) {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  Add-Type -Namespace GraphCodeVisualBaseline -Name NativeMethods -MemberDefinition @'
    [DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr hWnd, out int processId);
    [DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

  function Assert-ForegroundWindowOwnedByProcess([System.Diagnostics.Process] $process) {
    $hwnd = [GraphCodeVisualBaseline.NativeMethods]::GetForegroundWindow()
    Assert-Contract ($hwnd -ne [IntPtr]::Zero) "no foreground window is present"
    $ownerPid = 0
    [void] [GraphCodeVisualBaseline.NativeMethods]::GetWindowThreadProcessId($hwnd, [ref] $ownerPid)
    Assert-Contract ($ownerPid -eq $process.Id) `
      "foreground window belongs to PID $ownerPid, not the launched graphcode-windows.exe (PID $($process.Id)) -- refusing to capture the wrong/covered app"
    Assert-Contract (-not [GraphCodeVisualBaseline.NativeMethods]::IsIconic($hwnd)) `
      "graphcode-windows.exe window is minimized -- refusing to capture"
    $rect = New-Object GraphCodeVisualBaseline.NativeMethods+RECT
    [void] [GraphCodeVisualBaseline.NativeMethods]::GetWindowRect($hwnd, [ref] $rect)
    Assert-Contract (($rect.Right - $rect.Left) -gt 0 -and ($rect.Bottom - $rect.Top) -gt 0) `
      "graphcode-windows.exe window has no visible extent -- refusing to capture"
    return $rect
  }

  function Get-ScreenPixel([int] $x, [int] $y) {
    $bitmap = New-Object System.Drawing.Bitmap 1, 1
    try {
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try { $graphics.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size 1, 1)) }
      finally { $graphics.Dispose() }
      $pixel = $bitmap.GetPixel(0, 0)
      return @([int] $pixel.R, [int] $pixel.G, [int] $pixel.B)
    } finally {
      $bitmap.Dispose()
    }
  }

  throw ("Live capture requires an assigned capture/UIA slot, a fixture-launch " +
    "recipe reusing windows-shell.ps1 -UseStubDaemon, and region-coordinate " +
    "derivation for canvas-interior-fill/canvas-grid-line before it can run for " +
    "real; the helper functions above are wired and self-contained but this batch " +
    "intentionally stops short of an actual launch without that slot and a " +
    "follow-up go-ahead.")
}

Write-Output "Visual baseline: PASS"
exit 0
