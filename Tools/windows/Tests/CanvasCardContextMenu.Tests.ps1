BeforeAll {
  $gatePath = Join-Path $PSScriptRoot "..\uia-live-gate.ps1"
  $appPath = Join-Path $PSScriptRoot "..\..\..\graphcode-windows\src\App.zig"
  $source = Get-Content -LiteralPath $gatePath -Raw
  $ast = [Management.Automation.Language.Parser]::ParseFile($gatePath, [ref]$null, [ref]$null)
  $definition = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq "Open-CanvasCardContextMenu"
  }, $true)
  $clip = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq "Get-MultiProjectClippedRectangle"
  }, $true)
  . ([scriptblock]::Create($clip.Extent.Text))
  if (-not ("CanvasCardContextProbe" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class CanvasCardContextProbe {
  public static string[] Nodes;
  public static int FixedIndex;
  public static string Target;
  public static int Clicks;
  public static bool Covered;
  public static bool PostContextMenu(IntPtr owner, uint kind) {
    Target = Nodes[FixedIndex];
    Clicks++;
    return true;
  }
  public static bool PostOwnedScreenPoint(IntPtr owner, int x, int y, bool rightClick) {
    Clicks++;
    if (Covered) return false;
    Target = x >= 100 && x < 200 && y >= 100 && y < 200 ? "card-a" : "other";
    return rightClick;
  }
}
'@
  }
  if ($definition) {
    # Substitute only the native boundary; execute the actual gate helper body.
    . ([scriptblock]::Create($definition.Extent.Text.Replace(
      "[GraphCodeUiaGateState]", "[CanvasCardContextProbe]")))
  } else {
    $app = Get-Content -LiteralPath $appPath -Raw
    $indexMatch = [regex]::Match($app, '3 => return self\.showNodeContextMenu\((\d+),')
    if (-not $indexMatch.Success) { throw "Expected source-bound legacy menu target" }
    [CanvasCardContextProbe]::FixedIndex = [int]$indexMatch.Groups[1].Value
    $start = $source.IndexOf('  Require (Ensure-ShellForeground $shellWindow "Delete Loop context menu")')
    $end = $source.IndexOf('  $deleteLoopItems =', $start)
    if ($start -lt 0 -or $end -le $start) { throw "Legacy Delete acquisition block not found" }
    $script:legacyAcquisition = $source.Substring($start, $end - $start).Replace(
      "[GraphCodeUiaGateState]", "[CanvasCardContextProbe]")
    function Open-CanvasCardContextMenu($process, $root, $ownerWindow, $automationId, $walker, $label) {
      $shellWindow = $ownerWindow
      & ([scriptblock]::Create($script:legacyAcquisition + "`nreturn `$deleteLoopPopup"))
    }
  }
  function Require($condition, $message) { if (-not $condition) { throw $message } }
  function Ensure-ShellForeground {}
  function Find-FragmentByIdWithRetry($root, $automationId, $walker) {}
  function Wait-ForPopupMenu {}
}

Describe "Stable canvas card context menu (managed mocks only)" {
  BeforeEach {
    [CanvasCardContextProbe]::Target = ""
    [CanvasCardContextProbe]::Clicks = 0
    [CanvasCardContextProbe]::Covered = $false
    [CanvasCardContextProbe]::Nodes = @("card-a", "card-b")
    $script:card = [pscustomobject]@{ Current = [pscustomobject]@{
      AutomationId = "card-a"; ProcessId = 42; IsOffscreen = $false
      BoundingRectangle = [pscustomobject]@{ Left = 100.0; Top = 100.0; Right = 200.0; Bottom = 200.0 }
    } }
    $script:graph = [pscustomobject]@{ Current = [pscustomobject]@{
      BoundingRectangle = [pscustomobject]@{ Left = 0.0; Top = 0.0; Right = 500.0; Bottom = 500.0 }
    } }
    Mock Find-FragmentByIdWithRetry {
      param($root, $automationId)
      if ($automationId -eq "graph") { return $script:graph }
      return $script:card
    }
    Mock Ensure-ShellForeground { $true }
    Mock Wait-ForPopupMenu { [IntPtr]123 }
  }
  It "targets the stable selected identity with <order> model order" -TestCases @(
    @{ order = "original"; nodes = @("card-a", "card-b") }
    @{ order = "reordered"; nodes = @("card-b", "card-a") }
  ) {
    param($nodes)
    [CanvasCardContextProbe]::Nodes = $nodes
    $null = Open-CanvasCardContextMenu ([pscustomobject]@{ Id = 42 }) $null ([IntPtr]1) "card-a" $null "Delete Loop"
    [CanvasCardContextProbe]::Target | Should -BeExactly "card-a"
  }
  It "refuses <problem> before requesting native input" -TestCases @(
    @{ problem = "missing card" }, @{ problem = "identity drift" }, @{ problem = "foreign process" }
    @{ problem = "offscreen card" }, @{ problem = "empty bounds" }, @{ problem = "outside canvas" }
    @{ problem = "nonfinite bounds" }, @{ problem = "missing graph" }, @{ problem = "lost foreground" }
    @{ problem = "no interior pixel" }
  ) {
    param($problem)
    switch ($problem) {
      "missing card" { $script:card = $null }
      "identity drift" { $script:card.Current.AutomationId = "card-b" }
      "foreign process" { $script:card.Current.ProcessId = 99 }
      "offscreen card" { $script:card.Current.IsOffscreen = $true }
      "empty bounds" { $script:card.Current.BoundingRectangle.Right = 100.0 }
      "outside canvas" { $script:graph.Current.BoundingRectangle.Right = 50.0 }
      "nonfinite bounds" { $script:card.Current.BoundingRectangle.Left = [double]::NaN }
      "missing graph" { $script:graph = $null }
      "lost foreground" { Mock Ensure-ShellForeground { $false } }
      "no interior pixel" {
        $script:card.Current.BoundingRectangle.Left = 100.1
        $script:card.Current.BoundingRectangle.Right = 100.4
      }
    }
    { Open-CanvasCardContextMenu ([pscustomobject]@{ Id = 42 }) $null ([IntPtr]1) "card-a" $null "Delete Loop" } |
      Should -Throw
    [CanvasCardContextProbe]::Clicks | Should -Be 0
    Should -Invoke Wait-ForPopupMenu -Times 0 -Exactly
  }
  It "targets the visible intersection of a partially clipped stable card" {
    $script:graph.Current.BoundingRectangle.Right = 170.0
    $null = Open-CanvasCardContextMenu ([pscustomobject]@{ Id = 42 }) $null ([IntPtr]1) "card-a" $null "Delete Loop"
    [CanvasCardContextProbe]::Target | Should -BeExactly "card-a"
  }
  It "does not fall back to a fixed-index hook when the owned point is covered" {
    [CanvasCardContextProbe]::Covered = $true
    { Open-CanvasCardContextMenu ([pscustomobject]@{ Id = 42 }) $null ([IntPtr]1) "card-a" $null "Delete Loop" } |
      Should -Throw
    [CanvasCardContextProbe]::Target | Should -BeExactly ""
    [CanvasCardContextProbe]::Clicks | Should -Be 1
    Should -Invoke Wait-ForPopupMenu -Times 0 -Exactly
  }
  It "does not report success when the native popup never appears" {
    Mock Wait-ForPopupMenu { [IntPtr]::Zero }
    { Open-CanvasCardContextMenu ([pscustomobject]@{ Id = 42 }) $null ([IntPtr]1) "card-a" $null "Delete Loop" } |
      Should -Throw
  }
  It "wires the actual Delete acquisition to the stable-card helper" {
    $source | Should -Match '\$deleteLoopPopup = Open-CanvasCardContextMenu \$process \$root \$shellWindow'
    $source | Should -Not -Match 'PostContextMenu\(\$shellWindow, 3\)\)\s*`\s*"Delete Loop'
  }
}
