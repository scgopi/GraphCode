[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

BeforeAll {
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$themePath = if ($env:GRAPHCODE_PALETTE_THEME_PATH) {
  $env:GRAPHCODE_PALETTE_THEME_PATH
} else {
  Join-Path $repoRoot "graphcode\Sources\Features\App\Theme.swift"
}
$attentionPath = if ($env:GRAPHCODE_PALETTE_ATTENTION_PATH) {
  $env:GRAPHCODE_PALETTE_ATTENTION_PATH
} else {
  Join-Path $repoRoot "graphcode\Sources\Features\Canvas\CanvasAttentionRail.swift"
}
$summaryPath = if ($env:GRAPHCODE_PALETTE_SUMMARY_PATH) {
  $env:GRAPHCODE_PALETTE_SUMMARY_PATH
} else {
  Join-Path $repoRoot "graphcode\Sources\Features\LoopWorkspace\LoopSummaryPresentation.swift"
}
$designTokensPath = if ($env:GRAPHCODE_PALETTE_DESIGN_TOKENS_PATH) {
  $env:GRAPHCODE_PALETTE_DESIGN_TOKENS_PATH
} else {
  Join-Path $repoRoot "graphcode-windows\src\DesignTokens.zig"
}

function Assert-Contract([bool] $Condition, [string] $Message) {
  if (-not $Condition) {
    throw "Palette parity contract: $Message"
  }
}

function ConvertTo-Rgb8Channel([double] $Channel) {
  # Match Test-CurrentThemeContract.ps1: round-half-up with a clamped 0...1 input.
  $clamped = [Math]::Max(0.0, [Math]::Min(1.0, $Channel))
  return [int] [Math]::Floor(($clamped * 255.0) + 0.5)
}

function Remove-SwiftComments([string] $Text, [string] $Path) {
  $lineStripped = ($Text -split "`r?`n" | ForEach-Object {
    $commentIndex = $_.IndexOf("//")
    if ($commentIndex -ge 0) { $_.Substring(0, $commentIndex) } else { $_ }
  }) -join "`n"
  $active = [regex]::Replace($lineStripped, "(?s)/\*.*?\*/", "")
  if ($active -match "/\*" -or $active -match "\*/") {
    throw "$Path contains an unsupported or unterminated block-comment delimiter"
  }
  return $active
}

function Get-SwiftColorExpressions([string] $Line, [string] $Path, [int] $LineNumber) {
  $number = "[0-9]+(?:\.[0-9]+)?"
  $patterns = @(
    "Color\s*\(\s*white\s*:\s*(?<white>$number)\s*\)",
    "Color\s*\(\s*red\s*:\s*(?<red>$number)\s*,\s*green\s*:\s*(?<green>$number)\s*,\s*blue\s*:\s*(?<blue>$number)\s*\)",
    "Color\s*\(\s*hex\s*:\s*(?:`"#?(?<hexString>[0-9A-Fa-f]{6})`"|0x(?<hexInteger>[0-9A-Fa-f]{6}))\s*\)",
    "Color\.(?<named>white|black)",
    "(?<![\w.])\.(?<shorthand>white|black)(?!\w)"
  )
  $combinedPattern = "(?:" + ($patterns -join "|") + ")"
  $colorMatches = [regex]::Matches($Line, $combinedPattern)
  if ($Line -match "Color\s*\(" -and $colorMatches.Count -eq 0) {
    throw "$Path line $LineNumber has an unsupported Color(...) expression"
  }

  $expressions = @()
  foreach ($match in $colorMatches) {
    $rgb = $null
    if ($match.Groups["white"].Success) {
      $channel = ConvertTo-Rgb8Channel ([double] $match.Groups["white"].Value)
      $rgb = @($channel, $channel, $channel)
    } elseif ($match.Groups["red"].Success) {
      $rgb = @(
        (ConvertTo-Rgb8Channel ([double] $match.Groups["red"].Value)),
        (ConvertTo-Rgb8Channel ([double] $match.Groups["green"].Value)),
        (ConvertTo-Rgb8Channel ([double] $match.Groups["blue"].Value))
      )
    } elseif ($match.Groups["hexString"].Success -or $match.Groups["hexInteger"].Success) {
      $hex = if ($match.Groups["hexString"].Success) {
        $match.Groups["hexString"].Value
      } else {
        $match.Groups["hexInteger"].Value
      }
      $rgb = @(
        [Convert]::ToInt32($hex.Substring(0, 2), 16),
        [Convert]::ToInt32($hex.Substring(2, 2), 16),
        [Convert]::ToInt32($hex.Substring(4, 2), 16)
      )
    } else {
      $channel = if ($match.Groups["named"].Success) {
        $match.Groups["named"].Value
      } else {
        $match.Groups["shorthand"].Value
      }
      $value = if ($channel -eq "white") { 255 } else { 0 }
      $rgb = @($value, $value, $value)
    }

    $suffixStart = $match.Index + $match.Length
    $suffix = $Line.Substring($suffixStart)
    $hasOpacity = $suffix -match "^\s*\.opacity\s*\("
    $expressions += [pscustomobject]@{
      Rgb = $rgb
      HasOpacity = $hasOpacity
      Text = $match.Value + $(if ($hasOpacity) { ".opacity(...)" } else { "" })
    }
  }
  if ($expressions.Count -gt 0) { return $expressions }
}

function Get-SwiftPaletteTokens([string] $Text, [string] $Path) {
  $active = Remove-SwiftComments $Text $Path
  $lines = $active -split "`n"
  $tokens = New-Object 'System.Collections.Generic.List[object]'
  $aliases = @{}
  $staticName = $null
  $staticLines = New-Object 'System.Collections.Generic.List[object]'
  $methodName = $null
  $caseName = $null
  $sourceName = [IO.Path]::GetFileNameWithoutExtension($Path)

  $flushStatic = {
    if ($null -eq $staticName) { return }
    $found = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $staticLines) {
      foreach ($expression in (Get-SwiftColorExpressions $entry.Text $Path $entry.Number)) {
        $found.Add($expression)
      }
    }
    for ($i = 0; $i -lt $found.Count; $i++) {
      $name = "$sourceName.$staticName"
      if ($found.Count -gt 1) { $name += ".stop$($i + 1)" }
      $tokens.Add([pscustomobject]@{
        Name = $name
        Rgb = $found[$i].Rgb
        HasOpacity = $found[$i].HasOpacity
        Source = $Path
      })
    }
  }

  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $lineNumber = $i + 1
    if ($line -match "^\s*(?:private\s+)?static\s+let\s+(\w+)") {
      & $flushStatic
      $staticName = $Matches[1]
      if ($line -match "^\s*(?:private\s+)?static\s+let\s+(\w+)\s*=\s*(\w+)\s*$") {
        $aliases[$Matches[1]] = $Matches[2]
      }
      $staticLines = New-Object 'System.Collections.Generic.List[object]'
    } elseif ($line -match "^\s*(?:private\s+)?static\s+func\s+(\w+)\b") {
      & $flushStatic
      $staticName = $null
      $staticLines = New-Object 'System.Collections.Generic.List[object]'
      $methodName = $Matches[1]
      $caseName = $null
    } elseif ($sourceName -eq "CanvasAttentionRail" -and $line -match "^\s*private\s+var\s+reviewButton\b") {
      & $flushStatic
      $staticName = $null
      $staticLines = New-Object 'System.Collections.Generic.List[object]'
      $methodName = "reviewButton"
      $caseName = $null
    } elseif ($line -match "^\s{2}\}\s*$") {
      $methodName = $null
      $caseName = $null
    } elseif ($line -match "^\s*case\s+(.+?)\s*:\s*(.*)$") {
      $labels = [regex]::Matches($Matches[1], "\.([A-Za-z_]\w*)") |
        ForEach-Object { $_.Groups[1].Value }
      if (@($labels).Count -gt 0) {
        $caseName = ($labels -join "_")
      }
    }

    if ($null -ne $staticName) {
      $staticLines.Add([pscustomobject]@{ Text = $line; Number = $lineNumber })
    } else {
      $expressions = @(Get-SwiftColorExpressions $line $Path $lineNumber)
      for ($j = 0; $j -lt $expressions.Count; $j++) {
        if ($sourceName -eq "LoopSummaryPresentation" -and $methodName -and $caseName) {
          $name = "$sourceName.$methodName.$caseName"
        } elseif ($sourceName -eq "CanvasAttentionRail" -and $methodName -eq "reviewButton") {
          $name = "$sourceName.$methodName.color$($j + 1)"
        } else {
          continue
        }
        $tokens.Add([pscustomobject]@{
          Name = $name
          Rgb = $expressions[$j].Rgb
          HasOpacity = $expressions[$j].HasOpacity
          Source = $Path
        })
      }
    }
  }
  & $flushStatic
  foreach ($aliasName in $aliases.Keys) {
    $targetName = "$sourceName.$($aliases[$aliasName])"
    $target = @($tokens | Where-Object { $_.Name -eq $targetName })
    if ($target.Count -eq 1) {
      $tokens.Add([pscustomobject]@{
        Name = "$sourceName.$aliasName"
        Rgb = $target[0].Rgb
        HasOpacity = $target[0].HasOpacity
        Source = $Path
      })
    } else {
      throw "$Path has an unresolved or ambiguous color alias: $sourceName.$aliasName -> $targetName"
    }
  }
  return $tokens.ToArray()
}

function Get-WindowsPaletteTokens([string] $Text, [string] $Path) {
  $active = ($Text -split "`r?`n" | ForEach-Object {
    $commentIndex = $_.IndexOf("//")
    if ($commentIndex -ge 0) { $_.Substring(0, $commentIndex) } else { $_ }
  }) -join "`n"
  $pattern = "pub\s+const\s+(?<name>\w+)\s*:\s*Color\s*=\s*(?<value>0x[0-9A-Fa-f]+|\w+)\s*;"
  $allColorDeclarations = [regex]::Matches($active, "pub\s+const\s+\w+\s*:\s*Color\s*=\s*[^;]+;")
  $recognizedColorDeclarations = [regex]::Matches($active, $pattern)
  Assert-Contract ($recognizedColorDeclarations.Count -eq $allColorDeclarations.Count) `
    "$Path contains a COLORREF constant with an unsupported initializer"
  $definitions = @{}
  foreach ($match in $recognizedColorDeclarations) {
    $name = $match.Groups["name"].Value
    Assert-Contract (-not $definitions.ContainsKey($name)) "$Path has duplicate Color constant $name"
    $definitions[$name] = $match.Groups["value"].Value
  }
  $tokens = New-Object 'System.Collections.Generic.List[object]'
  $resolved = @{}
  $remaining = @($definitions.Keys)
  while ($remaining.Count -gt 0) {
    $next = @()
    $progress = $false
    foreach ($name in $remaining) {
      $value = $definitions[$name]
      if ($value -match "^0x([0-9A-Fa-f]+)$") {
        $colorref = [Convert]::ToInt64($Matches[1], 16)
        $rgb = @(
          [int] ($colorref -band 0xFF),
          [int] (($colorref -shr 8) -band 0xFF),
          [int] (($colorref -shr 16) -band 0xFF)
        )
      } elseif ($resolved.ContainsKey($value)) {
        $rgb = @($resolved[$value])
      } else {
        $next += $name
        continue
      }
      $resolved[$name] = $rgb
      $tokens.Add([pscustomobject]@{ Name = $name; Rgb = $rgb; Source = $Path })
      $progress = $true
    }
    Assert-Contract $progress "$Path has an unresolved Color alias or cycle: $($next -join ', ')"
    $remaining = $next
  }
  return $tokens.ToArray()
}

$script:PaletteMapping = [ordered]@{
  "Theme.windowTone" = "window_tone"
  "Theme.canvasBackground" = "canvas_background"
  "Theme.canvasTone" = "canvas_tone"
  "Theme.canvasGridLine" = "canvas_grid_line"
  "Theme.folderGlyph" = "folder_glyph"
  "Theme.tabSelectedBackground" = "tab_selected_background"
  "Theme.controlGloss.stop1" = "control_gloss_top"
  "Theme.controlGloss.stop2" = "control_gloss_bottom"
  "Theme.controlGlossHovered.stop1" = "control_gloss_hovered_top"
  "Theme.controlGlossHovered.stop2" = "control_gloss_hovered_bottom"
  "Theme.loopCard.stop1" = "loop_card_top"
  "Theme.loopCard.stop2" = "loop_card_bottom"
  "Theme.loopCardAttention.stop1" = "loop_card_attention_top"
  "Theme.loopCardAttention.stop2" = "loop_card_attention_bottom"
  "Theme.loopBar.stop1" = "loop_bar_top"
  "Theme.loopBar.stop2" = "loop_bar_bottom"
  "Theme.workspaceRail" = "workspace_rail"
  "Theme.paneFocusTint" = "pane_focus_tint"
  "Theme.activityStrip" = "activity_strip"
  "Theme.sheet" = "sheet"
  "Theme.draftField" = "draft_field"
  "Theme.onboardingSheet" = "onboarding_sheet"
}

# Every parsed-but-unmapped source color is an explicit exception with its
# rendering reason. Adding or removing a parsed color requires updating this list.
$script:MacExceptions = @{
  "Theme.tabBarGloss.stop1" = "Gradient stop is a translucent material scrim on macOS and is pre-blended over Windows rail paint."
  "Theme.tabBarGloss.stop2" = "Gradient stop is a translucent material scrim on macOS and is pre-blended over Windows rail paint."
  "Theme.tabBarGloss.stop3" = "Gradient stop is a translucent material scrim on macOS and is pre-blended over Windows rail paint."
  "Theme.tabBarHighlight" = "White highlight is opacity-blended over the tab-bar surface; Windows stores the pre-blended result."
  "Theme.tabBarShadowLine" = "Black shadow is opacity-blended over the loop-bar surface; Windows stores the pre-blended result."
  "Theme.controlBorder" = "White border is opacity-blended over the control fill; Windows stores the pre-blended result."
  "Theme.loopCardBorder" = "White border is opacity-blended over the card fill; Windows stores the pre-blended result."
  "Theme.loopCardAttentionBorder" = "Attention border is opacity-blended over the attention-card fill; Windows stores the composite."
  "CanvasAttentionRail.reviewButton.color1" = "Button ink is opacity-independent here but has no matching Windows attention-rail palette token."
  "CanvasAttentionRail.tint" = "Attention tint is a macOS rail color; the Windows rail does not expose a corresponding tint token."
  "CanvasAttentionRail.ink" = "Attention ink is a macOS rail color; the Windows rail does not expose a corresponding ink token."
  "LoopSummaryPresentation.dot.reading" = "Reading state uses translucent system white, not a shared opaque Windows state-color token."
  "LoopSummaryPresentation.dot.editing" = "Editing state has no corresponding per-state Windows summary-dot token."
  "LoopSummaryPresentation.dot.thinking" = "Thinking state has no corresponding per-state Windows summary-dot token."
  "LoopSummaryPresentation.dot.found_done" = "Resolved state has no corresponding per-state Windows summary-dot token."
  "LoopSummaryPresentation.dot.asking" = "Asking state reuses attention amber; Windows has no equivalent summary-dot token."
  "LoopSummaryPresentation.ink.reading" = "Reading ink uses translucent system white, not a shared opaque Windows state-color token."
  "LoopSummaryPresentation.ink.editing" = "Editing ink has no corresponding per-state Windows summary-ink token."
  "LoopSummaryPresentation.ink.running" = "Running ink is opacity-blended; Windows stores no matching summary-ink token."
  "LoopSummaryPresentation.ink.thinking" = "Thinking ink has no corresponding per-state Windows summary-ink token."
  "LoopSummaryPresentation.ink.found_done" = "Resolved ink has no corresponding per-state Windows summary-ink token."
  "LoopSummaryPresentation.ink.asking" = "Asking ink has no corresponding per-state Windows summary-ink token."
  "LoopSummaryPresentation.blockFill.starting" = "Starting fill uses translucent system white over the state fill; Windows has no matching composite token."
  "LoopSummaryPresentation.blockBorder.starting" = "Starting border uses translucent system white over the state block; Windows has no matching composite token."
}

# Windows-only source values are likewise enumerated rather than silently skipped.
$script:WindowsExceptions = @{
  "loop_minimap_surface" = "Mirrors the private RailMinimap.surface (#16161a) in LoopWorkspaceRail.swift, which is not a Theme.swift token."
  "window_background" = "Windows retains an alpha byte as future-consumer documentation; macOS applies a glass scrim at runtime."
  "canvas_edge" = "Windows canvas edge contrast is a renderer-specific stroke, with no standalone Theme.swift source token."
  "canvas_selection" = "Windows selection paint is renderer-specific; macOS selection uses system-driven interaction styling."
  "unfocused_pane_veil" = "Windows retains alpha as documentation while macOS opacity is composited over live terminal content."
  "tab_bar_gloss_top" = "Windows token is a pre-blended gradient endpoint over workspace_rail, not the macOS translucent source stop."
  "tab_bar_gloss_bottom" = "Windows token is a pre-blended gradient endpoint over workspace_rail, not the macOS translucent source stop."
  "tab_bar_highlight" = "Windows token is the opacity-composited result over workspace_rail."
  "tab_bar_shadow_line" = "Windows token is the opacity-composited result over loop_bar_bottom."
  "control_border" = "Windows token is the opacity-composited control border, not the macOS white source color."
  "loop_card_border" = "Windows token is the opacity-composited border over the card; it is not the macOS white source."
  "loop_card_attention_border" = "Windows token is the opacity-composited attention border over the card."
  "dialog_panel" = "Windows legacy dialogs use a shared dark native palette; macOS dialogs use native material/system surfaces."
  "dialog_title_text" = "Windows legacy dialogs intentionally use light native title text; macOS uses native text styling."
  "dialog_body_text" = "Windows legacy dialogs intentionally use light native body text; macOS uses native text styling."
  "dialog_muted_text" = "Windows legacy dialogs intentionally use light muted text; macOS uses native secondary-label styling."
  "dialog_error_text" = "Windows legacy dialogs use a Win32 ingress-error color; macOS error presentation is outside these sources."
  "dialog_field_background" = "Windows legacy dialog fields use native Win32 paint; macOS fields use native material/system controls."
  "dialog_field_border" = "Windows legacy dialog fields use a Win32 border; macOS fields use native material/system controls."
}

function Test-PaletteInventory(
  [object[]] $MacTokens,
  [object[]] $WindowsTokens
) {
  Assert-Contract ($MacTokens.Count -gt 0) "no supported macOS color expressions were parsed"
  Assert-Contract ($WindowsTokens.Count -gt 0) "no literal Windows COLORREF constants were parsed"
  Assert-Contract ($script:PaletteMapping.Count -gt 0) "mapping table must not be empty"

  $macByName = @{}
  foreach ($token in $MacTokens) {
    Assert-Contract (-not $macByName.ContainsKey($token.Name)) "duplicate macOS palette token: $($token.Name)"
    $macByName[$token.Name] = $token
  }
  $windowsByName = @{}
  foreach ($token in $WindowsTokens) {
    Assert-Contract (-not $windowsByName.ContainsKey($token.Name)) "duplicate Windows COLORREF token: $($token.Name)"
    $windowsByName[$token.Name] = $token
  }

  $mappedMacNames = @{}
  foreach ($name in $script:PaletteMapping.Keys) {
    $mappedMacNames[$name] = $true
    Assert-Contract ($macByName.ContainsKey($name)) "mapped macOS token is missing: $name"
  }
  foreach ($name in $macByName.Keys) {
    Assert-Contract ($mappedMacNames.ContainsKey($name) -or $script:MacExceptions.ContainsKey($name)) `
      "parsed macOS token has no mapping or documented exception: $name"
  }
  foreach ($name in $script:MacExceptions.Keys) {
    Assert-Contract ($macByName.ContainsKey($name)) "documented macOS exception is no longer present: $name"
  }

  $mappedWindowsNames = @{}
  foreach ($name in $script:PaletteMapping.Values) {
    Assert-Contract (-not $mappedWindowsNames.ContainsKey($name)) "Windows token is mapped more than once: $name"
    $mappedWindowsNames[$name] = $true
    Assert-Contract ($windowsByName.ContainsKey($name)) "mapped Windows token is missing: $name"
  }
  foreach ($name in $windowsByName.Keys) {
    Assert-Contract ($mappedWindowsNames.ContainsKey($name) -or $script:WindowsExceptions.ContainsKey($name)) `
      "parsed Windows token has no mapping or documented exception: $name"
  }
  foreach ($name in $script:WindowsExceptions.Keys) {
    Assert-Contract ($windowsByName.ContainsKey($name)) "documented Windows exception is no longer present: $name"
  }

  foreach ($name in $script:MacExceptions.Keys) {
    Assert-Contract (-not [string]::IsNullOrWhiteSpace($script:MacExceptions[$name])) "missing reason for macOS exception $name"
  }
  foreach ($name in $script:WindowsExceptions.Keys) {
    Assert-Contract (-not [string]::IsNullOrWhiteSpace($script:WindowsExceptions[$name])) "missing reason for Windows exception $name"
  }

  $comparedPairs = 0
  foreach ($macName in $script:PaletteMapping.Keys) {
    $windowsName = $script:PaletteMapping[$macName]
    Assert-Contract ($macByName.ContainsKey($macName)) "mapped macOS token is missing: $macName"
    Assert-Contract ($windowsByName.ContainsKey($windowsName)) "mapped Windows token is missing: $windowsName"
    Assert-Contract (-not $macByName[$macName].HasOpacity) "mapped macOS token has an unaccounted opacity modifier: $macName"
    $macRgb = @($macByName[$macName].Rgb)
    $windowsRgb = @($windowsByName[$windowsName].Rgb)
    Assert-Contract (($macRgb -join ",") -eq ($windowsRgb -join ",")) (
      "$macName RGB($($macRgb -join ',')) differs from $windowsName COLORREF RGB($($windowsRgb -join ','))"
    )
    $comparedPairs++
  }

  Assert-Contract ($comparedPairs -gt 0 -and $comparedPairs -eq $script:PaletteMapping.Count) `
    "compared $comparedPairs pairs but mapping table contains $($script:PaletteMapping.Count)"
  Write-Host "Palette parity: compared $comparedPairs mapped token pairs."
  foreach ($name in $script:MacExceptions.Keys | Sort-Object) {
    Write-Host "Palette parity macOS exception: $name — $($script:MacExceptions[$name])"
  }
  foreach ($name in $script:WindowsExceptions.Keys | Sort-Object) {
    Write-Host "Palette parity Windows exception: $name — $($script:WindowsExceptions[$name])"
  }
}

foreach ($path in @($themePath, $attentionPath, $summaryPath, $designTokensPath)) {
  Assert-Contract (Test-Path -LiteralPath $path) "required palette source is missing: $path"
}

$macTokens = @()
foreach ($path in @($themePath, $attentionPath, $summaryPath)) {
  $text = Get-Content -LiteralPath $path -Raw
  $macTokens += @(Get-SwiftPaletteTokens $text $path)
}
$designTokensText = Get-Content -LiteralPath $designTokensPath -Raw
$windowsTokens = @(Get-WindowsPaletteTokens $designTokensText $designTokensPath)
}

Describe "Windows/macOS palette parity" {
  It "mirrors the private RailMinimap surface without drifting behind its exception" {
    $railPath = Join-Path $repoRoot "graphcode\Sources\Features\LoopWorkspace\LoopWorkspaceRail.swift"
    $railText = Get-Content -LiteralPath $railPath -Raw
    $minimap = [regex]::Match($railText, '(?s)private struct RailMinimap: View \{(.*?)\r?\n\}')
    Assert-Contract $minimap.Success "private RailMinimap source is missing"
    $surface = [regex]::Match($minimap.Groups[1].Value, 'private static let surface = (Color\([^\r\n]+?\))')
    Assert-Contract $surface.Success "private RailMinimap.surface color is missing"
    $mac = @(Get-SwiftColorExpressions $surface.Groups[1].Value $railPath 408)
    $windows = @($windowsTokens | Where-Object Name -eq "loop_minimap_surface")
    Assert-Contract ($mac.Count -eq 1 -and $windows.Count -eq 1) "minimap colors must be present and unambiguous"
    Assert-Contract (($mac[0].Rgb -join ",") -eq ($windows[0].Rgb -join ",")) "private minimap surface RGB differs across platforms"
    $literal = [regex]::Match($designTokensText, 'pub\s+const\s+loop_minimap_surface:\s*Color\s*=\s*(0x[0-9A-Fa-f]+)')
    Assert-Contract ($literal.Success -and [Convert]::ToUInt32($literal.Groups[1].Value.Substring(2), 16) -eq 0x001A1616) `
      "loop_minimap_surface must be exactly COLORREF 0x001A1616"
  }

  It "parses supported white, RGB, and hexadecimal literals with baseline quantization" {
    $white = @(Get-SwiftColorExpressions "Color(white: 0.118)" "fixture.swift" 1)
    $rgb = @(Get-SwiftColorExpressions "Color(red: 0.039, green: 0.518, blue: 1.0)" "fixture.swift" 2)
    $hexString = @(Get-SwiftColorExpressions 'Color(hex: "#0A84FF")' "fixture.swift" 3)
    $hexInteger = @(Get-SwiftColorExpressions "Color(hex: 0x0A84FF)" "fixture.swift" 4)
    Assert-Contract ($white.Count -eq 1 -and ($white[0].Rgb -join ",") -eq "30,30,30") `
      "Color(white:) did not use the visual-baseline 8-bit quantization"
    Assert-Contract ($rgb.Count -eq 1 -and ($rgb[0].Rgb -join ",") -eq "10,132,255") `
      "Color(red:green:blue:) channels were not quantized as expected"
    Assert-Contract ($hexString.Count -eq 1 -and ($hexString[0].Rgb -join ",") -eq "10,132,255") `
      "hex string color literal was not decoded as RGB"
    Assert-Contract ($hexInteger.Count -eq 1 -and ($hexInteger[0].Rgb -join ",") -eq "10,132,255") `
      "hex integer color literal was not decoded as RGB"
  }

  It "accounts for every parsed color and exactly compares mapped token pairs" {
    Test-PaletteInventory $macTokens $windowsTokens
  }

  It "rejects the historical pane-focus BGR channel swap" {
    $macFocus = @($macTokens | Where-Object { $_.Name -eq "Theme.paneFocusTint" })
    Assert-Contract ($macFocus.Count -eq 1) "pane-focus source color is missing or ambiguous"
    $rgb = @($macFocus[0].Rgb)
    $swappedColorref = (($rgb[0] -shl 16) -bor ($rgb[1] -shl 8) -bor $rgb[2])
    $swappedLiteral = "0x{0:X8}" -f $swappedColorref
    $tokenPattern = "(?m)(pub\s+const\s+pane_focus_tint:\s*Color\s*=\s*)0x[0-9A-Fa-f]+"
    $swappedText = [regex]::Replace(
      $designTokensText,
      $tokenPattern,
      '${1}' + $swappedLiteral,
      1
    )
    $swappedTokens = @(Get-WindowsPaletteTokens $swappedText $designTokensPath)
    $failure = $null
    try {
      Test-PaletteInventory $macTokens $swappedTokens
    } catch {
      $failure = $_.Exception.Message
    }
    Assert-Contract ($failure -like "*pane_focus_tint*") "channel-swap fixture did not fail the pane-focus comparison"
  }

  It "rejects a missing mapped token from either source" {
    $withoutMacToken = @($macTokens | Where-Object { $_.Name -ne "Theme.paneFocusTint" })
    $failure = $null
    try {
      Test-PaletteInventory $withoutMacToken $windowsTokens
    } catch {
      $failure = $_.Exception.Message
    }
    Assert-Contract ($failure -like "*mapped macOS token is missing: Theme.paneFocusTint*") `
      "missing macOS mapped token was not rejected"

    $withoutWindowsToken = @($windowsTokens | Where-Object { $_.Name -ne "pane_focus_tint" })
    $failure = $null
    try {
      Test-PaletteInventory $macTokens $withoutWindowsToken
    } catch {
      $failure = $_.Exception.Message
    }
    Assert-Contract ($failure -like "*mapped Windows token is missing: pane_focus_tint*") `
      "missing Windows mapped token was not rejected"
  }
}
