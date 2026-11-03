param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
& (Join-Path $RepositoryRoot 'Tools\windows\Import-CompiledValidationAssembly.ps1') `
  -AssemblyPath $AssemblyPath -RequiredType 'GraphCodeUiaGateState' | Out-Null
$source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
$results = [Collections.Generic.List[object]]::new()
function Assert-Functional([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}
function Invoke-Functional([string] $Id, [scriptblock] $Assertion, [int] $Count = 1) {
  $failure = $null
  try { & $Assertion } catch { $failure = $_ }
  $results.Add([ordered]@{
    id = $Id; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = $Count
    evidence = $(if ($failure) { $failure.ToString() } else { 'Current production PS function/AST with deliberate managed fixtures' })
  })
}
function Read-Function([string] $Name) {
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  Assert-Functional ($definitions.Count -eq 1) "Expected one actual production helper: $Name"
  return $definitions[0].Extent.Text
}
Invoke-Functional 'ui.root.source.line-5366' { Assert-Functional ($errors.Count -eq 0) 'UIA production source does not parse' }
Invoke-Functional 'ui.root.source.line-5553' { Assert-Functional ($errors.Count -eq 0) 'UIA startup source does not parse' }
Assert-Functional ($errors.Count -eq 0) 'Cannot import malformed production source'
foreach ($binding in @(
  @{ line = 5380; name = 'Test-MultiProjectSourceSupportedChromeId' },
  @{ line = 5407; name = 'Wait-MultiProjectWorkspaceMarkerPublication' },
  @{ line = 5457; name = 'Get-MultiProjectCardActivationRectangle' },
  @{ line = 5561; name = 'Get-SidebarNavigationSnapshot' },
  @{ line = 5569; name = 'Get-SidebarNavigationBoundsProof' },
  @{ line = 6853; name = 'Get-EdgeTextAttemptDecision' },
  @{ line = 6921; name = 'Wait-SketchGraphCard' },
  @{ line = 6939; name = 'Get-SketchCardAutomationId' },
  @{ line = 7136; name = 'Select-EdgeConnectorCardPair' }
)) {
  Invoke-Functional "ui.root.source.line-$($binding.line)" { $null = Read-Function $binding.name }
  . ([scriptblock]::Create((Read-Function $binding.name)))
}
. ([scriptblock]::Create((Read-Function 'New-SidebarNavigationCapture')))
. ([scriptblock]::Create((Read-Function 'Test-SketchPromotionSubmenuItems')))
function Test-MultiProjectAutomationPrefix([string] $value, [string] $prefix) {
  return $value.StartsWith($prefix, [StringComparison]::Ordinal)
}
Invoke-Functional 'ui.root.source.line-5392' {
  $checked = 0
  foreach ($id in @('wire-node-1000000000000000001', 'mark-entry-1000000000000000002',
      'overview-wire-node-1000000000000000003', 'overview-mark-entry-1000000000000000004')) {
    Assert-Functional (Test-MultiProjectSourceSupportedChromeId $id 'owned') "Stable recovery control rejected: $id"
    $checked++
  }
  Assert-Functional ($checked -eq 4) 'Stable recovery census did not execute four cases'
} 4
Invoke-Functional 'ui.root.source.line-5396' {
  Assert-Functional (-not (Test-MultiProjectSourceSupportedChromeId 'future-unknown-control-1000000000000000005' 'owned')) 'Unknown chrome accepted'
}
Invoke-Functional 'ui.root.source.line-5399' {
  Assert-Functional (-not (Test-MultiProjectSourceSupportedChromeId 'overview-wire-node-1000000000000000003' 'foreign')) 'Foreign chrome accepted'
}
Invoke-Functional 'ui.root.source.line-5410' {
  Assert-Functional ((Read-Function 'Wait-MultiProjectWorkspaceMarkerPublication') -notmatch 'Invoke-MultiProjectControl|PostOwned|ClickOwned|PostMouse|InvokePattern') `
    'Workspace-marker retry replays navigation or input'
}
Invoke-Functional 'ui.root.source.line-5432' {
  $clock = @{ Now = [DateTimeOffset]::Parse('2026-10-27T00:00:00Z') }
  $reads = @{ Count = 0 }
  $loopBarId = 'workspace-loop-bar-1000000000000000001'
  $toolbarId = 'workspace-toolbar-1000000000000000002'
  $observed = Wait-MultiProjectWorkspaceMarkerPublication {
    $reads.Count++
    if ($reads.Count -lt 3) { return @() }
    @([pscustomobject]@{ automationID = [pscustomobject]@{ value = $loopBarId }; ownership = 'owned'; observationReady = $true },
      [pscustomobject]@{ automationID = [pscustomobject]@{ value = $toolbarId }; ownership = 'owned'; observationReady = $true })
  } $loopBarId $toolbarId $clock.Now.AddSeconds(1) { $clock.Now } {
    param([int] $Milliseconds) $clock.Now = $clock.Now.AddMilliseconds($Milliseconds)
  }
  Assert-Functional ($observed.attempts -eq 3 -and $observed.loopBar -ceq $loopBarId -and $observed.toolbar -ceq $toolbarId) `
    'Delayed exact markers did not satisfy bounded reacquisition'
}
Invoke-Functional 'ui.root.source.line-5449' {
  $clock = @{ Now = [DateTimeOffset]::Parse('2026-10-27T00:00:00Z') }
  $failure = $null
  try {
    $null = Wait-MultiProjectWorkspaceMarkerPublication {
      @([pscustomobject]@{ automationID = [pscustomobject]@{ value = 'workspace-loop-bar-1999999999999999999' }; ownership = 'owned'; observationReady = $true })
    } 'workspace-loop-bar-1000000000000000001' 'workspace-toolbar-1000000000000000002' $clock.Now.AddMilliseconds(250) { $clock.Now } {
      param([int] $Milliseconds) $clock.Now = $clock.Now.AddMilliseconds($Milliseconds)
    }
  } catch { $failure = $_ }
  Assert-Functional ($failure -and $failure.Exception.Message -ceq 'MULTIPROJECT_WORKSPACE_MARKERS: exact owned loop bar and toolbar did not publish before the deadline') `
    'Unknown marker absence no longer fails closed'
}
Invoke-Functional 'ui.root.source.line-5462' {
  $rectangle = Get-MultiProjectCardActivationRectangle @(0.0, 0.0, 250.0, 96.0)
  Assert-Functional (($rectangle -join ',') -ceq '0,0,250,24') 'Card activation lost source-sized title strip'
}
Invoke-Functional 'ui.root.source.line-5470' {
  $rectangle = Get-MultiProjectCardActivationRectangle @(0.0, 0.0, 250.0, 96.0)
  $checked = 0
  foreach ($recovery in @(@(11.0, 31.0, 84.0, 51.0), @(90.0, 31.0, 176.0, 51.0))) {
    Assert-Functional (-not ($rectangle[0] -lt $recovery[2] -and $rectangle[2] -gt $recovery[0] -and
      $rectangle[1] -lt $recovery[3] -and $rectangle[3] -gt $recovery[1])) 'Activation overlaps a recovery control'
    $checked++
  }
  Assert-Functional ($checked -eq 2) 'Recovery intersection count changed'
} 2
Invoke-Functional 'ui.root.source.line-5477' {
  $failure = $null
  try { $null = Get-MultiProjectCardActivationRectangle @(0.0, 0.0, 0.0, 96.0) } catch { $failure = $_ }
  Assert-Functional ($failure -and $failure.Exception.Message -ceq 'MULTIPROJECT_BOUNDS: positive card rectangle required for activation') 'Invalid activation bounds accepted'
}
Invoke-Functional 'ui.root.source.line-5485' {
  Assert-Functional ((Read-Function 'Open-MultiProjectLoop').Contains('Get-MultiProjectCardActivationRectangle $row.card.bounds')) 'Live loop navigation clicks whole card'
}
Invoke-Functional 'ui.root.source.line-5580' {
  $null = Read-Function 'New-SidebarNavigationCapture'
  Assert-Functional ($source -match '\$sidebarCaptures\.Add\(\(New-SidebarNavigationCapture \$sidebarNavigationChildren\)\)') 'Sidebar retains mutable captures'
}
function New-SidebarElement([string] $Id, [string] $Name, [double] $Left, [double] $Top,
    [double] $Right, [double] $Bottom, [int] $Owner = 4242) {
  [pscustomobject]@{ Current = [pscustomobject]@{
    AutomationId = $Id; Name = $Name; ProcessId = $Owner
    BoundingRectangle = [pscustomobject]@{ Left = $Left; Top = $Top; Right = $Right; Bottom = $Bottom; Width = $Right - $Left; Height = $Bottom - $Top }
  } }
}
$sidebar = @(
  (New-SidebarElement 'overview-destination:graph' 'Graph' 12 20 220 52),
  (New-SidebarElement 'quick-chats-destination:quick-chats' 'Quick Chats' 12 56 220 88),
  (New-SidebarElement 'sidebar-section-1' 'Local Projects' 12 100 220 121),
  (New-SidebarElement 'open-project-1' 'UIA project' 12 121 220 153),
  (New-SidebarElement 'sidebar-section-2' 'Remote Repositories' 12 168 220 189),
  (New-SidebarElement 'open-project-2' 'Temporary remote' 12 192 220 224),
  (New-SidebarElement 'overview-destination' 'Graph' 12 17 220 49),
  (New-SidebarElement 'quick-chats-destination' 'Quick Chats' 12 53 220 85),
  (New-SidebarElement 'project-new-loop-1' 'New Loop' 174 17 198 49),
  (New-SidebarElement 'project-disclosure-2' 'Collapse project' 198 17 220 49),
  (New-SidebarElement 'quick-chat-new-3' 'New Chat' 174 53 198 85),
  (New-SidebarElement 'quick-chats-disclosure-4' 'Collapse Quick Chats' 198 53 220 85),
  (New-SidebarElement 'project-new-loop-5' 'New Loop' 174 121 198 153),
  (New-SidebarElement 'project-disclosure-6' 'Collapse project' 198 121 220 153)
)
$initial = @($sidebar | ForEach-Object {
  if ($_.Current.Name -in @('Remote Repositories', 'Temporary remote')) { New-SidebarElement $_.Current.AutomationId $_.Current.Name 0 0 0 0 } else { $_ }
})
$remote = @($sidebar | ForEach-Object {
  if ($_.Current.Name -in @('Remote Repositories', 'Temporary remote')) { $_ } else { New-SidebarElement $_.Current.AutomationId $_.Current.Name 0 0 0 0 }
})
Invoke-Functional 'ui.root.source.line-5632' {
  $snapshot = Get-SidebarNavigationSnapshot $sidebar
  Assert-Functional (($snapshot.destinationIds -join '|') -ceq 'overview-destination|quick-chats-destination' -and
    ($snapshot.destinationNames -join '|') -ceq 'Graph|Quick Chats' -and $snapshot.ownerNames.Count -eq 2 -and
    ($snapshot.ownerNames -join '|') -ceq 'UIA project|Temporary remote' -and
    ($snapshot.sectionNames -join '|') -ceq 'Local Projects|Remote Repositories' -and $snapshot.recentRowIds.Count -eq 0 -and
    $snapshot.rowBoundsValid -and $snapshot.controlsValid -and $snapshot.controlsChecked -eq 6) 'Sidebar baseline oracle differs'
}
Invoke-Functional 'ui.root.source.line-5659' {
  $mutable = @($sidebar | ForEach-Object {
    $b = $_.Current.BoundingRectangle
    New-SidebarElement $_.Current.AutomationId $_.Current.Name $b.Left $b.Top $b.Right $b.Bottom
  })
  $frozen = New-SidebarNavigationCapture $mutable
  foreach ($item in $mutable) {
    foreach ($name in @('Left', 'Top', 'Right', 'Bottom', 'Width', 'Height')) { $item.Current.BoundingRectangle.$name = 0 }
  }
  $proof = Get-SidebarNavigationBoundsProof @($frozen) 4242
  Assert-Functional ($proof.structureValid -and $proof.rowBoundsValid -and $proof.controlsValid) 'Sidebar capture retained mutable handles'
}
Invoke-Functional 'ui.root.source.line-5683' {
  $proof = Get-SidebarNavigationBoundsProof @([pscustomobject]@{ Children = $initial }, [pscustomobject]@{ Children = $remote }) 4242
  Assert-Functional ($proof.structureValid -and $proof.rowBoundsValid -and $proof.controlsValid -and
    $proof.rowsChecked -eq 6 -and $proof.controlsChecked -eq 6) 'DPI192 bounded captures rejected'
}
foreach ($test in @(
  @{ line = 5696; mode = 'missing' }, @{ line = 5713; mode = 'foreign' }, @{ line = 5724; mode = 'duplicate' }, @{ line = 5739; mode = 'wrong-order' }
)) {
  Invoke-Functional "ui.root.source.line-$($test.line)" {
    $first = $initial
    $second = $remote
    switch ($test.mode) {
      missing { $second = @($remote | Where-Object { $_.Current.AutomationId -ne 'open-project-2' }) }
      foreign { $second = @($remote | ForEach-Object {
        if ($_.Current.AutomationId -eq 'open-project-2') { New-SidebarElement $_.Current.AutomationId $_.Current.Name 12 192 220 224 9999 } else { $_ }
      }) }
      duplicate { $second = @($remote + (New-SidebarElement 'open-project-2' 'Temporary remote' 12 192 220 224)) }
      wrong-order {
        $first = @($initial | Where-Object { $_.Current.AutomationId -notin @('open-project-1', 'open-project-2') }) +
          @($initial | Where-Object { $_.Current.AutomationId -eq 'open-project-2' }) +
          @($initial | Where-Object { $_.Current.AutomationId -eq 'open-project-1' })
      }
    }
    $proof = Get-SidebarNavigationBoundsProof @([pscustomobject]@{ Children = $first }, [pscustomobject]@{ Children = $second }) 4242
    Assert-Functional (-not $proof.structureValid) "Sidebar accepted $($test.mode) owned row"
  }
}
Invoke-Functional 'ui.root.source.line-5752' {
  $snapshot = Get-SidebarNavigationSnapshot @($sidebar | Where-Object { $_.Current.AutomationId -notin @('open-project-1', 'project-new-loop-5', 'project-disclosure-6') })
  Assert-Functional (($snapshot.ownerNames -join '|') -ceq 'Temporary remote') 'Local owner collapse not isolated'
}
Invoke-Functional 'ui.root.source.line-5761' {
  $snapshot = Get-SidebarNavigationSnapshot @($sidebar | Where-Object { $_.Current.AutomationId -ne 'open-project-2' })
  Assert-Functional (($snapshot.ownerNames -join '|') -ceq 'UIA project') 'Remote owner collapse not isolated'
}
Invoke-Functional 'ui.root.source.line-5773' {
  $snapshot = Get-SidebarNavigationSnapshot @($sidebar | Where-Object { $_.Current.AutomationId -notin @('sidebar-section-2', 'open-project-2') })
  Assert-Functional (($snapshot.ownerNames -join '|') -ceq 'UIA project' -and
    ($snapshot.sectionNames -join '|') -ceq 'Local Projects' -and $snapshot.recentRowIds.Count -eq 0) 'Temporary owner survived restoration'
}
Invoke-Functional 'ui.root.source.line-5783' {
  $snapshot = Get-SidebarNavigationSnapshot @($sidebar + (New-SidebarElement 'project-row-recent' 'Recent folder' 12 228 220 260))
  Assert-Functional ($snapshot.recentRowIds.Count -eq 1) 'Unopened recent folder not detected'
}
Invoke-Functional 'ui.root.source.line-5792' {
  $clipped = @($sidebar | Where-Object { $_.Current.AutomationId -ne 'project-new-loop-5' }) +
    (New-SidebarElement 'project-new-loop-5' 'New Loop' 174 121 228 153)
  Assert-Functional (-not (Get-SidebarNavigationSnapshot $clipped).controlsValid) 'Control outside owner accepted'
}
Invoke-Functional 'ui.root.source.line-5807' {
  $reordered = @($sidebar | Where-Object { $_.Current.AutomationId -notin @('open-project-1', 'open-project-2') }) +
    @((New-SidebarElement 'open-project-2' 'Temporary remote' 12 124 220 156), (New-SidebarElement 'open-project-1' 'UIA project' 12 192 220 224))
  Assert-Functional (((Get-SidebarNavigationSnapshot $reordered).ownerNames -join '|') -ceq 'Temporary remote|UIA project') 'Owner order evidence lost'
}
Invoke-Functional 'ui.root.source.line-5812' {
  $sidebarIds = @(5632,5659,5683,5696,5713,5724,5739,5752,5761,5773,5783,5792,5807)
  $executed = @($results | Where-Object { $_.id -in @($sidebarIds | ForEach-Object { "ui.root.source.line-$_" }) })
  Assert-Functional ($executed.Count -eq 13) 'Sidebar fixture execution count changed'
} 13

$retrySource = Read-Function 'Get-EdgeTextAttemptDecision'
$retryDecisions = [Collections.Generic.List[string]]::new()
Invoke-Functional 'ui.root.source.line-6866' {
  $attempts = 0
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $attempts++
    $value = if ($attempts -eq 1) { '' } else { 'expected text' }
    $decision = Get-EdgeTextAttemptDecision $true $value 'expected text' $attempt 5
    $retryDecisions.Add($decision)
    if ($decision -eq 'complete') { break }
    Assert-Functional ($decision -eq 'retry') 'Unexpected text retry decision'
  }
  Assert-Functional ($attempts -eq 2 -and $value -ceq 'expected text') 'Stable empty text did not retry exactly once'
} 2
Invoke-Functional 'ui.root.source.line-6864' {
  Assert-Functional ($retryDecisions.Count -eq 2 -and ($retryDecisions -join ',') -ceq 'retry,complete') 'Unexpected text retry decision sequence'
}
Invoke-Functional 'ui.root.source.line-6870' {
  Assert-Functional ($retrySource -match '\$actual -ceq \$expected') 'Exact expected-text verification missing'
}
$mutatedRetry = $retrySource.Replace('if ($actual -ceq $expected) { return "complete" }', 'if ($stable) { return "complete" }')
Invoke-Functional 'ui.root.source.line-6877' {
  Assert-Functional ($mutatedRetry -cne $retrySource) 'Retry mutation anchor missing'
}
Invoke-Functional 'ui.root.source.line-6892' {
  $attempts = 0
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $attempts++
    $value = if ($attempts -eq 1) { '' } else { 'expected text' }
    $decision = & {
      . ([scriptblock]::Create($mutatedRetry))
      Get-EdgeTextAttemptDecision $true $value 'expected text' $attempt 5
    }
    if ($decision -eq 'complete') { break }
  }
  Assert-Functional (-not ($attempts -eq 2 -and $value -ceq 'expected text')) 'Exact-match mutant escaped regression'
}
Invoke-Functional 'ui.root.source.line-6905' {
  $attempts = 0
  $failure = $null
  try {
    for ($attempt = 1; $attempt -le 5; $attempt++) { $attempts++; $null = Get-EdgeTextAttemptDecision $true '' 'expected text' $attempt 5 }
  } catch { $failure = $_ }
  Assert-Functional ($attempts -eq 5 -and $failure -and $failure.Exception.Message -match 'attempts=5/5') 'Stable-wrong text did not exhaust exactly five attempts'
} 5
Invoke-Functional 'ui.root.source.line-6925' {
  $body = Read-Function 'Wait-SketchGraphCard'
  foreach ($pattern in @('\$baselineCount -gt 0', '\$lastTitleCount -eq 1 -and \$lastIdentityCount -eq 1',
      '\$expectedNodeId', '\$expectedAutomationId', '\$_.Current\.AutomationId -ceq \$expectedAutomationId', '\$graphSequence')) {
    Assert-Functional ($body -match $pattern) 'Custody card wait lost bounded unique identity proof'
  }
  Assert-Functional ($body -notmatch 'Invoke\(\)|PostRightClick|Actual Size') 'Custody wait performs an action'
}
Invoke-Functional 'ui.root.source.line-6958' {
  $checked = 0
  foreach ($expected in @(
    @('66666666-6666-4666-8666-000000000001', 'canvas-card-1213325934034940293'),
    @('66666666-6666-4666-8666-000000000002', 'canvas-card-1213322635500055660'),
    @('66666666-6666-4666-8666-000000000003', 'canvas-card-1213323735011683871'))) {
    Assert-Functional ((Get-SketchCardAutomationId $expected[0]) -ceq $expected[1]) 'Source-derived card identity differs'
    $checked++
  }
  Assert-Functional ($checked -eq 3) 'Sketch identity case count changed'
} 3
Invoke-Functional 'ui.root.source.line-6967' {
  $body = Read-Function 'Open-SketchNodeMenu'
  foreach ($pattern in @('\$cards\.Count -eq 1', '\$ExpectedCardId',
      '\$cards\[0\]\.Current\.AutomationId -ceq \$ExpectedCardId', 'Get-DirectChildren \$graph \$rawWalker')) {
    Assert-Functional ($body -match $pattern) 'Custody right-click bypasses fresh unique identity proof'
  }
}

function New-ConnectorCard([string] $Id, [string] $Name) {
  [pscustomobject]@{ Current = [pscustomobject]@{ AutomationId = $Id; Name = $Name } }
}
$connectorCases = @(
  @{ name = 'owned-pair'; source = 'source'; target = 'target'; expected = $true; cards = @(
    (New-ConnectorCard 'canvas-card-source' 'source'), (New-ConnectorCard 'canvas-card-target' 'target')) },
  @{ name = 'duplicate-source'; source = 'source'; target = 'target'; expected = $false; cards = @(
    (New-ConnectorCard 'canvas-card-source-a' 'source'), (New-ConnectorCard 'canvas-card-source-b' 'source'), (New-ConnectorCard 'canvas-card-target' 'target')) },
  @{ name = 'missing-source'; source = 'source'; target = 'target'; expected = $false; cards = @((New-ConnectorCard 'canvas-card-target' 'target')) },
  @{ name = 'missing-target'; source = 'source'; target = 'target'; expected = $false; cards = @(
    (New-ConnectorCard 'canvas-card-source' 'source'), (New-ConnectorCard 'button-target' 'target')) },
  @{ name = 'different-target-title'; source = 'source'; target = 'target'; expected = $false; cards = @(
    (New-ConnectorCard 'canvas-card-source' 'source'), (New-ConnectorCard 'canvas-card-target' 'other target')) },
  @{ name = 'duplicate-target'; source = 'source'; target = 'target'; expected = $false; cards = @(
    (New-ConnectorCard 'canvas-card-source' 'source'), (New-ConnectorCard 'canvas-card-target-a' 'target'), (New-ConnectorCard 'canvas-card-target-b' 'target')) },
  @{ name = 'same-endpoint'; source = 'same'; target = 'same'; expected = $false; cards = @((New-ConnectorCard 'canvas-card-same' 'same')) },
  @{ name = 'blank-title'; source = ' '; target = 'target'; expected = $false; cards = @(
    (New-ConnectorCard 'canvas-card-source' 'source'), (New-ConnectorCard 'canvas-card-target' 'target')) }
)
foreach ($test in $connectorCases) {
  Invoke-Functional "ui.connector.$($test.name)" {
    $failure = $null
    $pair = $null
    try { $pair = Select-EdgeConnectorCardPair $test.cards $test.source $test.target } catch { $failure = $_ }
    if ($test.expected) {
      Assert-Functional (-not $failure -and $pair.Source.Current.AutomationId -ceq 'canvas-card-source' -and
        $pair.Target.Current.AutomationId -ceq 'canvas-card-target') 'Named source/target pair differs'
    } else { Assert-Functional ($null -ne $failure) "Ambiguous connector pair accepted: $($test.name)" }
  }
}
Invoke-Functional 'ui.root.source.line-7235' {
  Assert-Functional (@($results | Where-Object { $_.id.StartsWith('ui.connector.', [StringComparison]::Ordinal) }).Count -eq 8) 'Connector fixture case count changed'
} 8
function New-PromotionItems {
  # Native menu captions deliberately use the production em dash.
  @(
    [pscustomobject]@{ Id = 0; Text = 'Keep the session, add a shape'; Enabled = $false; Separator = $false },
    [pscustomobject]@{ Id = 5116; Text = "Goal $([char]0x2014) asks for a done check"; Enabled = $true; Separator = $false },
    [pscustomobject]@{ Id = 5117; Text = "Turn $([char]0x2014) asks where to pause"; Enabled = $true; Separator = $false },
    [pscustomobject]@{ Id = 5118; Text = "Timed $([char]0x2014) asks for a cadence"; Enabled = $true; Separator = $false }
  )
}
foreach ($name in @('exact', 'extra-item', 'reordered', 'enabled-heading', 'disabled-action', 'wrong-caption', 'separator-heading')) {
  Invoke-Functional "ui.promotion.$name" {
    $items = @(New-PromotionItems)
    switch ($name) {
      extra-item { $items += [pscustomobject]@{ Id = 5120; Text = 'Unexpected'; Enabled = $true; Separator = $false } }
      reordered { $items = @($items[0], $items[2], $items[1], $items[3]) }
      enabled-heading { $items[0].Enabled = $true }
      disabled-action { $items[1].Enabled = $false }
      wrong-caption { $items[2].Text = "Turn $([char]0x2014) unexpected caption" }
      separator-heading { $items[0].Separator = $true }
    }
    Assert-Functional ([bool](Test-SketchPromotionSubmenuItems $items) -eq ($name -ceq 'exact')) "Promotion submenu oracle differs: $name"
  }
}
$nativeForms = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\NativeForms.zig'))
$nativeLabels = [regex]::Match($nativeForms, '(?s)const node_labels = \[_\]\[\]const u8\{(.*?)\};')
Invoke-Functional 'ui.root.source.line-7326' { Assert-Functional $nativeLabels.Success 'NativeForms node_labels table missing' }
$labelAssignments = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$nodeSheetFieldLabels'
}, $true))
Invoke-Functional 'ui.root.source.line-7337' {
  Assert-Functional ($labelAssignments.Count -eq 1 -and $labelAssignments[0].Right.Find({
    param($node) $node -is [Management.Automation.Language.HashtableAst]
  }, $true)) 'Production node creation label map missing'
}
Invoke-Functional 'ui.root.source.line-7344' {
  Assert-Functional ($nativeLabels.Success -and $labelAssignments.Count -eq 1) 'Label sources unavailable'
  $labels = @([regex]::Matches($nativeLabels.Groups[1].Value, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
  $hashAst = $labelAssignments[0].Right.Find({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true)
  $map = $hashAst.SafeGetValue()
  $checked = 0
  foreach ($id in @(9100,9102,9103,9104,9106,9107,9108,9109,9110,9111,9112,9113,9114)) {
    $expected = $labels[$id - 9100]
    Assert-Functional (-not [string]::IsNullOrWhiteSpace($expected) -and [string]$map[$id] -eq $expected) "Node creation label differs: $id"
    $checked++
  }
  Assert-Functional ($checked -eq 13) 'Node label count changed'
} 13

$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
[IO.File]::WriteAllText((Join-Path $ArtifactRoot 'ui-functional-results.json'), ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
