param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath,
  [switch] $ImportOnly
)
$ErrorActionPreference = 'Stop'
$script:MixedWindowsRoot = Join-Path $RepositoryRoot 'Tools\windows'
$validationAssemblyPath = $AssemblyPath
$mixedAssembly = & (Join-Path $script:MixedWindowsRoot 'Import-CompiledValidationAssembly.ps1') `
  -AssemblyPath $AssemblyPath -RequiredType 'GraphCodeUiaGateState'
foreach ($frameworkFile in @('WindowsBase.dll', 'UIAutomationTypes.dll', 'UIAutomationClient.dll')) {
  $null = [Reflection.Assembly]::LoadFrom((Join-Path $PSHOME $frameworkFile))
}
$script:MixedCases = [Collections.Generic.List[object]]::new()
$gateSource = [IO.File]::ReadAllText((Join-Path $script:MixedWindowsRoot 'uia-live-gate.ps1'))
$gateAst = $null
foreach ($productionPath in @('Stub-Daemon.ps1', 'uia-live-gate.ps1')) {
  $parseErrors = $null
  $productionAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $script:MixedWindowsRoot $productionPath), [ref]$null, [ref]$parseErrors)
  if ($parseErrors.Count) { throw "Production source does not parse: $productionPath" }
  if ($productionPath -ceq 'uia-live-gate.ps1') { $gateAst = $productionAst }
  foreach ($definition in $productionAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      ($node.Name -like '*-MultiProject*' -or $node.Name -cin @(
        'ConvertTo-SketchCanonicalJson', 'Test-RetryableUiaError', 'Test-UpdateBannerClickTarget',
        'Get-DynamicProjectCardSnapshotDecision', 'Get-ConnectorDragSnapshotDecision',
        'Get-WorkspaceTabMountDecision', 'Get-UiaSelectionEventDecision'))
  }, $true)) {
    # Keep the actual helper's file-backed loader rooted at its production directory.
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', '$script:MixedWindowsRoot')))
  }
}
function Assert-Mixed([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}
function Reject-Mixed([scriptblock] $Action, [string] $Prefix) {
  try { $null = & $Action } catch {
    Assert-Mixed ($_.Exception.Message.StartsWith($Prefix, [StringComparison]::Ordinal)) "Wrong rejection: $($_.Exception.Message)"
    return $_
  }
  throw [InvalidOperationException]::new("Expected actual $Prefix rejection")
}
function Invoke-Mixed([int] $Line, [string] $Name, [scriptblock] $Action) {
  $failure = $null
  try { $null = & $Action 6>&1 } catch { $failure = $_ }
  $script:MixedCases.Add([ordered]@{
    line = $Line; name = $Name; passed = ($null -eq $failure)
    failure = $(if ($failure) { $failure.ToString() } else { $null })
  })
}
function Complete-Mixed([Collections.IDictionary] $Expected, [string[]] $Groups) {
  $failed = $false
  foreach ($entry in $Expected.GetEnumerator()) {
    $line = $entry.Key
    $expectedCount = $entry.Value
    $observed = @($script:MixedCases | Where-Object line -EQ ([int]$line))
    $failures = @($observed | Where-Object { -not $_.passed })
    $status = if ($observed.Count -eq 0) { 'Incomplete' }
      elseif ($observed.Count -ne $expectedCount -or $failures.Count) { 'Failed' } else { 'Passed' }
    if ($status -cne 'Passed') { $failed = $true }
    $row = [ordered]@{
      id = "ownership.mixed-ui.source-line-$line"; status = $status; executedCount = $observed.Count
      evidence = (ConvertTo-Json -InputObject ([ordered]@{
        source = 'Tools/windows/Tests/ValidationRunner.Tests.ps1'; invocationLine = [int]$line
        expectedExpandedCount = $expectedCount; cases = $observed
        productionInputs = 'Current production gate and compiled bindings'; nativeProductCalls = 0
      }) -Depth 14 -Compress)
      groups = $Groups
    }
    Write-Output ('OWNERSHIP_CASE_RESULT=' + ($row | ConvertTo-Json -Depth 16 -Compress))
  }
  foreach ($case in $script:MixedCases) {
    if (-not $Expected.Contains([int]$case.line)) { throw "Unregistered mixed invocation line: $($case.line)" }
  }
  if ($failed) { exit 1 }
}
function New-MixedMetadata($Before, $Identity, $After=$null, [switch]$Unavailable) {
  $state=@{before=$Before;after=$(if($null -eq $After){$Before}else{$After});id=$Identity;unavailable=[bool]$Unavailable;reads=0;order=[Collections.Generic.List[string]]::new()}
  $current=[pscustomobject]@{State=$state}
  $current|Add-Member ScriptProperty ProcessId {$this.State.order.Add('PID');$this.State.reads++;if($this.State.reads -eq 1){$this.State.before}else{$this.State.after}}
  $current|Add-Member ScriptProperty AutomationId {$this.State.order.Add('ID');if($this.State.unavailable){throw [Runtime.InteropServices.COMException]::new('controlled stale UIA metadata',[int]0x80040201)};$this.State.id}
  $current|Add-Member ScriptProperty Name {$this.State.order.Add('FORBIDDEN_NAME');throw 'Foreign or unresolved Name must not be read'}
  return [pscustomobject]@{Current=$current;State=$state}
}
function New-MixedCaptureState($PidValue=4242,$Identity='canvas-card-1983941480823304696') {
  @{pid=$PidValue;id=$Identity;runtime=@(3,42,17);name='Alpha loop';rect=[System.Windows.Rect]::new(248,118,220,86);error=$null}
}
function New-MixedCapture($States) {
  $element=[pscustomobject]@{states=$States;calls=0;order=[Collections.Generic.List[string]]::new()}
  $element|Add-Member ScriptMethod Capture {
    param([bool]$IncludeContent)
    $state=$this.states[$this.calls];$this.calls++;$this.order.Add($(if($IncludeContent){'CONTENT_CACHE'}else{'OWNERSHIP_CACHE'}))
    if($state.error){throw $state.error}
    $cache=[pscustomobject]@{state=$state;order=$this.order;content=$IncludeContent}
    $cache|Add-Member ScriptMethod GetCachedPropertyValue {
      param($property,[bool]$IgnoreDefault)
      if(-not $IgnoreDefault){throw 'Cache must request ignoreDefaultValue=true'}
      if($property -eq [System.Windows.Automation.AutomationElement]::ProcessIdProperty){$this.order.Add('PID');return $this.state.pid}
      if($property -eq [System.Windows.Automation.AutomationElement]::AutomationIdProperty){$this.order.Add('ID');return $this.state.id}
      if(-not $this.content){throw 'Ownership cache cannot expose content'}
      if($property -eq [System.Windows.Automation.AutomationElement]::BoundingRectangleProperty){$this.order.Add('BOUNDS');return $this.state.rect}
      if($property -eq [System.Windows.Automation.AutomationElement]::NameProperty){$this.order.Add('NAME');return $this.state.name}
      throw 'Unexpected cached property'
    }
    $cache|Add-Member ScriptMethod GetRuntimeId {$this.order.Add('RUNTIME');return ,$this.state.runtime}
    return $cache
  }
  return $element
}

if ($ImportOnly) { return }
$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
$a = '11111111-1111-4111-8111-111111111111'
$b = '22222222-2222-4222-8222-222222222222'
$alpha = Join-Path $ArtifactRoot 'Alpha'
$beta = Join-Path $ArtifactRoot 'Beta'
function New-MixedTab([string] $Id, [string] $Name, [bool] $Selected) {
  [ordered]@{ automationId = $Id; name = $Name; selected = $Selected }
}
$initial = New-MixedTab 'workspace-tab-initial' 'Goal' $true
$new = New-MixedTab 'workspace-tab-new' 'Shell' $true
$initialOff = New-MixedTab 'workspace-tab-initial' 'Goal' $false
$newOff = New-MixedTab 'workspace-tab-new' 'Shell' $false
Invoke-Mixed 1724 'narrow-mounted-tabs' {
  $d = Get-WorkspaceTabMountDecision @($initial) @($new) @($initialOff,$new) @($initial,$newOff) @($initialOff,$new)
  Assert-Mixed ($d.ready -and $d.overflowObserved -and $d.initialId -ceq 'workspace-tab-initial' -and $d.newId -ceq 'workspace-tab-new') 'Narrow mounted-tab roundtrip differs'
}
Invoke-Mixed 1733 'wide-mounted-tabs' {
  $d = Get-WorkspaceTabMountDecision @($initial) @($initialOff,$new) @($initialOff,$new) @($initial,$newOff) @($initialOff,$new)
  Assert-Mixed ($d.ready -and -not $d.overflowObserved) 'Wide mounted-tab roundtrip differs'
}
foreach ($test in @(
  @{ name='same-id'; after=@(New-MixedTab 'workspace-tab-initial' 'Shell' $true); mounted=@($initialOff,$new); first=@($initial,$newOff); second=@($initialOff,$new); failure='new-tab' },
  @{ name='missing-mounted-initial'; after=@($new); mounted=@($new); first=@($initial,$newOff); second=@($initialOff,$new); failure='mounted-pair' },
  @{ name='renamed-mounted-initial'; after=@($new); mounted=@((New-MixedTab 'workspace-tab-initial' 'Agent' $false),$new); first=@($initial,$newOff); second=@($initialOff,$new); failure='mounted-pair' },
  @{ name='initial-switch-did-not-select'; after=@($new); mounted=@($initialOff,$new); first=@($initialOff,$new); second=@($initialOff,$new); failure='initial-switch' },
  @{ name='new-switch-changed-id'; after=@($new); mounted=@($initialOff,$new); first=@($initial,$newOff); second=@($initialOff,(New-MixedTab 'workspace-tab-replaced' 'Shell' $true)); failure='new-switch' },
  @{ name='duplicate-mounted-selection'; after=@($new); mounted=@($initial,$new); first=@($initial,$newOff); second=@($initialOff,$new); failure='mounted-pair' }
)) {
  Invoke-Mixed 1749 $test.name {
    $d = Get-WorkspaceTabMountDecision @($initial) @($test.after) @($test.mounted) @($test.first) @($test.second)
    Assert-Mixed (-not $d.ready -and $d.failure -ceq $test.failure) 'Permanent mounted-tab failure changed'
  }
}
Invoke-Mixed 1757 'stable-selection-source' {
  Assert-Mixed (Get-UiaSelectionEventDecision 1 'worktree-row-safe' '42,7,9' 'worktree-row-safe' '42,7,9').ready 'Stable event rejected'
}
foreach ($test in @(
  @{name='zero';count=0;id='worktree-row-safe';runtime='42,7,9';failure='zero-events'},
  @{name='duplicate';count=2;id='worktree-row-safe';runtime='42,7,9';failure='duplicate-events'},
  @{name='wrong-element';count=1;id='worktree-row-foreign';runtime='42,7,9';failure='wrong-automation-id'},
  @{name='wrong-generation';count=1;id='worktree-row-safe';runtime='42,7,10';failure='wrong-runtime-id'}
)) {
  Invoke-Mixed 1769 $test.name {
    $d = Get-UiaSelectionEventDecision $test.count $test.id $test.runtime 'worktree-row-safe' '42,7,9'
    Assert-Mixed (-not $d.ready -and $d.failure -ceq $test.failure) 'Selection refusal changed'
  }
}
Invoke-Mixed 1777 'narrow-lane-and-real-pan' {
  $g = Get-MultiProjectLaneGeometry @(220,34,1028,900) @(382,134,632,230)
  Assert-Mixed (($g.band -join ',') -ceq '300,96,1822,250' -and ($g.open -join ',') -ceq '1690,106,1746,126') 'Compact Mac lane differs'
  $null = Reject-Mixed { Get-MultiProjectClippedRectangle $g.open @(220,34,1028,900) } 'MULTIPROJECT_BOUNDS'
  $g = Get-MultiProjectLaneGeometry @(220,34,1028,900) @(-390,134,-140,230)
  $worktrees = @(($g.band[2]-72),106,($g.band[2]-18),126)
  $clipped = Get-MultiProjectClippedRectangle $worktrees @(220,34,1028,900)
  Assert-Mixed (($worktrees -join ',') -ceq '978,106,1032,126' -and ($clipped -join ',') -ceq '978,106,1028,126') 'Narrow Worktrees clipping hidden'
}
Invoke-Mixed 1789 'wide-lane-and-dpi' {
  $g = Get-MultiProjectLaneGeometry @(220,34,1200,900) @(382,134,632,230)
  $scaled = Get-MultiProjectLaneGeometry @(330,51,1542,1350) @(573,201,948,345)
  Assert-Mixed (($g.band -join ',') -ceq '300,96,1822,250' -and ($scaled.band -join ',') -ceq '450,144,2733,375' -and
    ($scaled.open -join ',') -ceq '2535,159,2619,189') 'Lane width or once-only scaling differs'
  $negative = Get-MultiProjectLaneGeometry @(358,215,1402,942) @(19,315,268,411) @(1032,287,1318,307)
  Assert-Mixed ($negative.scale -eq 1 -and ($negative.open -join ',') -ceq '1326,287,1382,307') 'Horizontal pan corrupts anchor'
  for ($i=0;$i -lt 4;$i++) { Assert-Mixed ([Math]::Abs($negative.summary[$i]-@(1032,287,1318,307)[$i]) -le 1) 'Summary exceeds one-pixel budget' }
}
Invoke-Mixed 1804 'rounded-fitted-card' {
  $g = Get-MultiProjectLaneGeometry @(228,85,1036,780) @(390,185,500,227)
  Assert-Mixed ($g.scale -eq 0.44 -and $g.scaleSource -ceq 'card-width-rounded' -and
    [Math]::Abs($g.normalizedHeight-95.45454545454545) -lt $g.heightTolerance) 'Fitted rounding budget lost'
}
Invoke-Mixed 1811 'obsolete-or-clipped-card-refused' {
  foreach ($card in @(@(262,118,482,204),@(19,210,268,306),@(19,315,268,400),@(19,315,267,411))) {
    $canvas = if ($card[0] -eq 262) { @(220,34,1200,900) } else { @(358,215,1402,942) }
    $null = Reject-Mixed { Get-MultiProjectLaneGeometry $canvas $card } 'MULTIPROJECT_BOUNDS'
  }
}
Invoke-Mixed 1818 'obsolete-lane-floor-refused' {
  $g=Get-MultiProjectLaneGeometry @(220,34,1028,900) @(382,134,632,230)
  Assert-Mixed (($g.band -join ',') -cne '244,72,1004,248' -and ($g.open -join ',') -cne '872,82,928,102') 'Old floor accepted'
}
$leftQuote=[char]0x201c;$rightQuote=[char]0x201d
$exactRename="Rename $leftQuote" + "Alpha renamed$rightQuote"
Invoke-Mixed 1824 'exact-unicode-rename-title' {
  $title=Get-MultiProjectRenameTitle 'Alpha renamed'
  Assert-Mixed ($title -ceq $exactRename -and (Test-MultiProjectRenameTitle $title $title)) 'Exact dynamic Rename title drifted'
}
foreach($title in @('Rename Loop','Rename "Alpha renamed"',"$exactRename extra","Rename $leftQuote$rightQuote",("Rename $leftQuote"+"Alpha`nrenamed$rightQuote"))) {
  Invoke-Mixed 1837 $title { Assert-Mixed (-not (Test-MultiProjectRenameTitle $title $exactRename)) 'Malformed exact Rename title accepted' }
}
Invoke-Mixed 1843 'bounded-rename-fallback' { Assert-Mixed (Test-MultiProjectRenameTitle ("Rename $leftQuote"+"Owned loop$rightQuote")) 'Valid bounded fallback rejected' }
foreach($title in @('Rename Loop',"Rename $leftQuote$rightQuote",("Rename $leftQuote"+"nested $leftQuote"+"quote$rightQuote$rightQuote"),("Rename $leftQuote"+('x'*513)+$rightQuote))) {
  Invoke-Mixed 1854 "malformed-length-$($title.Length)" { Assert-Mixed (-not (Test-MultiProjectRenameTitle $title)) 'Bounded Rename fallback widened' }
}
$sheet=[ordered]@{processId=4242;handle=[long]42;owner=[long]7;className='GraphCodeSheetHost';title=("Delete "+$leftQuote+'Alpha renamed'+$rightQuote+'?');contentClass='GraphCodeWindowsDialogContent';visible=$true;captionless=$true}
Invoke-Mixed 1870 'owned-captionless-delete-sheet' {
  Assert-Mixed (Test-MultiProjectOwnedSheetIdentity $sheet 4242 ([IntPtr]7) $sheet.title 'GraphCodeWindowsDialogContent') 'Exact owned sheet rejected'
}
foreach($mutation in @('pid','owner','class','title','content','hidden','captioned','zero-handle')) {
  Invoke-Mixed 1879 $mutation {
    $candidate=[ordered]@{};foreach($key in $sheet.Keys){$candidate[$key]=$sheet[$key]}
    switch($mutation){pid{$candidate.processId=7777} owner{$candidate.owner=[long]8} class{$candidate.className='#32770'} title{$candidate.title='Delete Loop'}
      content{$candidate.contentClass='GraphCodeNativeForm'} hidden{$candidate.visible=$false} captioned{$candidate.captionless=$false} zero-handle{$candidate.handle=[long]0}}
    Assert-Mixed (-not (Test-MultiProjectOwnedSheetIdentity $candidate 4242 ([IntPtr]7) $sheet.title 'GraphCodeWindowsDialogContent')) 'Invalid sheet identity accepted'
  }
}
$banner=[ordered]@{processId=4242;automationId='sidebar-update-banner-83fd6a5f429785e1';name='Update available';controlType='ControlType.Button';enabled=$true;left=208.0;top=704.0;right=412.0;bottom=754.0}
Invoke-Mixed 1917 'owned-banner-after-Later' { Assert-Mixed (Test-UpdateBannerClickTarget $banner 4242 ([IntPtr]42) ([IntPtr]42) 4242 'Update offer deferred') 'Owned update banner rejected' }
foreach($mutation in @('process','window','focus','status')) {
  Invoke-Mixed 1924 $mutation {
    $candidate=[ordered]@{};foreach($key in $banner.Keys){$candidate[$key]=$banner[$key]}
    $foreground=[IntPtr]42;$focused=4242;$status='Update offer deferred'
    switch($mutation){process{$candidate.processId=7777} window{$foreground=[IntPtr]43} focus{$focused=7777} status{$status='Update available'}}
    Assert-Mixed (-not (Test-UpdateBannerClickTarget $candidate 4242 ([IntPtr]42) $foreground $focused $status)) 'Foreign or stale banner accepted'
  }
}
Invoke-Mixed 1951 'actual-caption-assignment' {
  $assignments=@($gateAst.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq 'laneOpenScreenX'},$true))
  $obsolete=@($gateAst.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq 'laneWorktreesScreenX'},$true))
  Assert-Mixed ($assignments.Count -eq 1 -and $obsolete.Count -eq 0) 'Caption assignment missing/ambiguous or obsolete click retained'
  $assignment=[scriptblock]::Create('param($laneSnapshot) '+$assignments[0].Extent.Text+';return $laneOpenScreenX')
  foreach($x in @(614,866,1013)){Assert-Mixed ((& $assignment ([pscustomobject]@{OpenX=$x})) -eq $x) 'Actual caption assignment ignored exported snapshot'}
}

# Remaining policy families use literal source-derived identities and geometry,
# never a local copy of the production predicates.
$workspaceOwner=@{path='A';node=$a;name='Alpha';title='Alpha loop'}
$rosterOwners=@($workspaceOwner,@{path='B';node=$b;name='Beta';title='Beta loop'})
function New-MixedWorkspace {
  [ordered]@{loopBars=@([ordered]@{automationId='workspace-loop-bar-1320898360543276851';name='Selected loop workspace';processId=4242;bounds=@(220,34,1200,80)})
    toolbars=@([ordered]@{automationId='workspace-toolbar-2086745613872223135';name='Alpha';processId=4242;bounds=@(8,1,280,33)});foreignWorkspaceFragmentCount=0}
}
function New-MixedRoster {
  [ordered]@{
    projectRows=@([ordered]@{automationId='open-project-1737218920896369762';name='Alpha';processId=4242;bounds=@(12,100,232,126)},
      [ordered]@{automationId='open-project-1737217821384741551';name='Beta';processId=4242;bounds=@(12,148,232,174)})
    cards=@([ordered]@{automationId='canvas-card-1331915895917204893';name='Alpha, 1 loop';processId=4242;bounds=@(318,106,1804,126)},
      [ordered]@{automationId='canvas-card-1929002346198335884';name='Alpha loop';processId=4242;bounds=@(382,134,632,230)},
      [ordered]@{automationId='canvas-card-1331912597382320260';name='Beta, 1 loop';processId=4242;bounds=@(318,284,1804,304)},
      [ordered]@{automationId='canvas-card-1616358459734844849';name='Beta loop';processId=4242;bounds=@(382,312,632,408)})
    foreignCardFragmentCount=0;foreignProjectFragmentCount=0;canvasBounds=@(220,34,1200,900)
  }
}
Invoke-Mixed 3392 'owner-surface-hash' {
  $ids=@((Get-MultiProjectAutomationId loop $alpha $a),(Get-MultiProjectAutomationId project-card $alpha $a),
    (Get-MultiProjectAutomationId overview-card $alpha $a),(Get-MultiProjectAutomationId overview-card $beta $b))
  Assert-Mixed (@($ids|Sort-Object -Unique).Count -eq 4 -and (Get-MultiProjectAutomationId project-card 'graphcode://stub/project' $a) -ceq 'canvas-card-1510499067760483540') 'Owner/surface hashes or FNV golden differ'
}
$retainedAlpha='D:\a\_temp\gu-239af6fb60ce40b5b2846baf38b9a9d7\mp\Alpha'
$retainedBeta='D:\a\_temp\gu-239af6fb60ce40b5b2846baf38b9a9d7\mp\Beta'
$retainedOwners=@(@{path=$retainedAlpha;name='Alpha';node=$a;title='Alpha loop'},@{path=$retainedBeta;name='Beta';node=$b;title='Beta loop'})
Invoke-Mixed 3423 'retained-identities-current-compact-geometry' {
  $p=[ordered]@{projectRows=@(
    [ordered]@{automationId='open-project-1729193928419568695';name='Alpha';processId=3140;bounds=@(20,222,240,248)},
    [ordered]@{automationId='open-project-2225278778924952707';name='Beta';processId=3140;bounds=@(20,308,240,334)})
    cards=@([ordered]@{automationId=Get-MultiProjectAutomationId overview-project $retainedAlpha;name='Alpha, 1 loop';processId=3140;bounds=@(246,133,1754,153)},
      [ordered]@{automationId='canvas-card-1662987038540838399';name='Alpha loop';processId=3140;bounds=@(270,169,490,255)},
      [ordered]@{automationId=Get-MultiProjectAutomationId overview-project $retainedBeta;name='Beta, 1 loop';processId=3140;bounds=@(246,329,1754,349)},
      [ordered]@{automationId='canvas-card-1884655564485847249';name='Beta loop';processId=3140;bounds=@(270,365,490,451)})
    foreignCardFragmentCount=0;foreignProjectFragmentCount=0;canvasBounds=@(228,85,1036,780)}
  Assert-Mixed (-not (Test-MultiProjectObservedRoster overview $p $retainedOwners $null 3140)) 'Historical dimensions accepted'
  $compact=Copy-MultiProjectValue $p
  $compact.cards[0].bounds=@(326,157,1812,177);$compact.cards[1].bounds=@(390,185,640,281);$compact.cards[2].bounds=@(326,335,1812,355);$compact.cards[3].bounds=@(390,363,640,459)
  Assert-Mixed (Test-MultiProjectObservedRoster overview $compact $retainedOwners $null 3140) 'Current compact roster rejected'
  $p.cards[0].bounds=@(37,308,1226,324);$p.cards[1].bounds=@(88,330,288,406);$p.cards[2].bounds=@(37,450,1226,466);$p.cards[3].bounds=@(88,472,288,548)
  Assert-Mixed (Test-MultiProjectObservedRoster overview $p $retainedOwners $null 3140) '80-percent rounded roster rejected'
}
Invoke-Mixed 3443 'caption-and-notice-hash-goldens' {
  foreach($g in @(@('overview-project','A','1331915895917204893'),@('overview-project','B','1331912597382320260'),
    @('overview-worktree-notice','A','1294898434078301384'),@('overview-worktree-notice','B','1294901732613186017'),
    @('overview-worktree-notice',$retainedAlpha,'1669006899659070917'),@('overview-worktree-notice',$retainedBeta,'1518601899186967385'))) {
    Assert-Mixed ((Get-MultiProjectAutomationId $g[0] $g[1]) -ceq ('canvas-card-'+$g[2])) 'Caption/notice golden differs'
  }
}
Invoke-Mixed 3458 'workspace-prefix-hash-goldens' {
  foreach($g in @(@('workspace-loop-bar',$a,'1320898360543276851'),@('workspace-loop-bar',$b,'2044737300313126929'),
    @('workspace-toolbar','A','2086745613872223135'),@('workspace-toolbar','B','2086746713383851346'))) {
    Assert-Mixed ((Get-MultiProjectAutomationId $g[0] $g[1]) -ceq ($g[0]+'-'+$g[2])) 'Workspace prefix/hash golden differs'
  }
}
Invoke-Mixed 3469 'unknown-kind-refused' {$null=Reject-Mixed {Get-MultiProjectAutomationId unsupported-marker A $a} 'MULTIPROJECT_KIND'}
Invoke-Mixed 3482 'owned-workspace-markers' {Assert-Mixed (Test-MultiProjectObservedSurface workspace $true (New-MixedWorkspace) $workspaceOwner 4242) 'Exact workspace rejected'}
Invoke-Mixed 3487 'restart-is-not-owner-marker' {
  $metadata=Get-MultiProjectFragmentMetadata (New-MixedMetadata 4242 'workspace-restart-session-2140902926206787169') 4242
  Assert-Mixed ($metadata.observationReady -and -not (Test-MultiProjectObservedSurface workspace $true ([ordered]@{loopBars=@();toolbars=@();foreignWorkspaceFragmentCount=0}) $workspaceOwner 4242)) 'Restart chrome replaced owner markers'
}
foreach($mutation in @('project-only','missing-loop','missing-toolbar','wrong-prefix','wrong-node','wrong-project','wrong-pid','pid-type','loop-name','toolbar-name','loop-duplicate','toolbar-duplicate','bounds-empty','bounds-type','bounds-zero','selection-unmatched','foreign-marker-count')) {
  Invoke-Mixed 3497 $mutation {
    $p=New-MixedWorkspace;$selected=$true
    switch($mutation){
      project-only{$p.loopBars=@();$p.toolbars=@()} missing-loop{$p.loopBars=@()} missing-toolbar{$p.toolbars=@()}
      wrong-prefix{$p.loopBars[0].automationId='canvas-card-1320898360543276851'} wrong-node{$p.loopBars[0].automationId='workspace-loop-bar-2044737300313126929'}
      wrong-project{$p.toolbars[0].automationId='workspace-toolbar-2086746713383851346'} wrong-pid{$p.toolbars[0].processId=7777} pid-type{$p.loopBars[0].processId='4242'}
      loop-name{$p.loopBars[0].name='Alpha loop'} toolbar-name{$p.toolbars[0].name='Alpha loop'} loop-duplicate{$p.loopBars=@($p.loopBars[0],$p.loopBars[0])}
      toolbar-duplicate{$p.toolbars=@($p.toolbars[0],$p.toolbars[0])} bounds-empty{$p.loopBars[0].bounds=@()} bounds-type{$p.toolbars[0].bounds[0]='8'}
      bounds-zero{$p.loopBars[0].bounds=@(220,34,220,80)} selection-unmatched{$selected=$false} foreign-marker-count{$p.foreignWorkspaceFragmentCount=1}}
    Assert-Mixed (-not (Test-MultiProjectObservedSurface workspace $selected $p $workspaceOwner 4242)) 'Wrong workspace marker projection accepted'
  }
}
Invoke-Mixed 3524 'project-refuses-workspace-chrome' {Assert-Mixed (-not (Test-MultiProjectObservedSurface project $true (New-MixedWorkspace) $workspaceOwner 4242)) 'Project accepted workspace chrome'}
foreach($test in @(
  @{line=3530;surface='project';owner=0;project=$true;loop=$true;expected=$true},
  @{line=3535;surface='project';owner=1;project=$false;loop=$false;expected=$true},
  @{line=3540;surface='workspace';owner=0;project=$false;loop=$true;expected=$true},
  @{line=3545;surface='overview';owner=0;project=$false;loop=$true;expected=$true},
  @{line=3550;surface='quick_chats';owner=0;project=$false;loop=$true;expected=$true},
  @{line=3555;surface='workspace';owner=0;project=$true;loop=$true;expected=$false},
  @{line=3560;surface='project';owner=0;project=$false;loop=$true;expected=$false},
  @{line=3565;surface='overview';owner=0;project=$true;loop=$true;expected=$false},
  @{line=3570;surface='quick_chats';owner=0;project=$true;loop=$true;expected=$false},
  @{line=3575;surface='workspace';owner=0;project=$false;loop=$false;expected=$false}
)) {
  Invoke-Mixed $test.line $test.surface {Assert-Mixed ((Test-MultiProjectOwnerSelection $test.surface $rosterOwners[$test.owner] $workspaceOwner $test.project $test.loop) -eq $test.expected) 'Owner/loop selection boundary changed'}
}
Invoke-Mixed 3596 'complete-two-owner-four-fragment-roster' {Assert-Mixed (Test-MultiProjectObservedRoster overview (New-MixedRoster) $rosterOwners $null 4242) 'Complete roster rejected'}
Invoke-Mixed 3601 'obsolete-node-dimensions-refused' {
  $p=New-MixedRoster;$p.cards[1].bounds=@(262,118,482,204)
  Assert-Mixed (-not (Test-MultiProjectObservedRoster overview $p $rosterOwners $null 4242)) 'Historical dimensions accepted'
}
Invoke-Mixed 3608 'obsolete-caption-positions-refused' {
  $p=New-MixedRoster;$p.canvasBounds=@(220,34,1028,900)
  foreach($positions in @(@(@(578,82,864,102),@(578,278,864,298)),@(@(624,82,910,102),@(624,278,910,298)))) {
    $p.cards[0].bounds=$positions[0];$p.cards[2].bounds=$positions[1]
    Assert-Mixed (-not (Test-MultiProjectObservedRoster overview $p $rosterOwners $null 4242)) 'Obsolete caption grid accepted'
  }
  $p.cards[0].bounds=@(318,106,1804,126);$p.cards[2].bounds=@(318,284,1804,304)
  Assert-Mixed (Test-MultiProjectObservedRoster overview $p $rosterOwners $null 4242) 'Producer-derived captions rejected'
}

# Metadata and cached-content fixtures are deliberate data transports. Their
# methods contain no ownership/geometry policy or native UI invocation.
$captureReader={param($element,[bool]$content)$element.Capture($content)}
$capturePrior=@{ownership='owned';finalPID=@{value=4242};automationID=@{value='canvas-card-1983941480823304696'}}
Invoke-Mixed 3625 'fresh-owned-content-does-not-hide-missing-peer' {
  $mock=New-MixedCapture @((New-MixedCaptureState),(New-MixedCaptureState),(New-MixedCaptureState))
  $e=Get-MultiProjectElementEvidence $mock 4242 $capturePrior 'mixed/missing-peer' $captureReader
  $p=New-MixedRoster;$p.cards=@($p.cards[0],$p.cards[1],$p.cards[2])
  Assert-Mixed ($e.processId -eq 4242 -and -not (Test-MultiProjectObservedRoster overview $p $rosterOwners $null 4242)) 'Fresh ownership hid missing peer'
}
Invoke-Mixed 3635 'selected-project-roster-and-physical-connector-snapshots' {
  $p=New-MixedRoster;$p.cards=@([ordered]@{automationId='canvas-card-1983941480823304696';name='Alpha loop';processId=4242;bounds=@(248,118,468,204)})
  Assert-Mixed (Test-MultiProjectObservedRoster project $p $rosterOwners $workspaceOwner 4242) 'Project roster rejected'
  Assert-Mixed (Test-MultiProjectObservedSurface project $true ([ordered]@{loopBars=@();toolbars=@();foreignWorkspaceFragmentCount=0}) $workspaceOwner 4242) 'Project-only marker shape rejected'
  $expected=@([ordered]@{automationId='canvas-card-1983941480823304696';name='UIA loop A'},[ordered]@{automationId='canvas-card-1983940381311676485';name='UIA loop B'})
  $dynamic=@([ordered]@{automationId=$expected[0].automationId;name=$expected[0].name;processId=4242;bounds=@(496,236,936,408)},
    [ordered]@{automationId=$expected[1].automationId;name=$expected[1].name;processId=4242;bounds=@(976,236,1416,408)})
  $graph=@(440,68,2400,1300)
  Assert-Mixed (Get-DynamicProjectCardSnapshotDecision project $dynamic $expected 4242 $graph).ready 'DPI192 project snapshot rejected'
  $empty=Copy-MultiProjectValue $dynamic;$empty[1].bounds=@(0,0,0,0)
  $d=Get-DynamicProjectCardSnapshotDecision project $empty $expected 4242 $graph
  Assert-Mixed (-not $d.ready -and $d.failure -ceq 'bounds-empty' -and $d.cards[1].automationId -ceq $expected[1].automationId) 'Empty bounds did not fail exactly'
  foreach($mutation in @('missing','foreign','duplicate','order','wrong-surface','outside-viewport','overlap')) {
    $candidate=Copy-MultiProjectValue $dynamic;$surface='project'
    switch($mutation){missing{$candidate=@($candidate[0])} foreign{$candidate[1].processId=7777} duplicate{$candidate[1].automationId=$candidate[0].automationId}
      order{$candidate=@($candidate[1],$candidate[0])} wrong-surface{$surface='overview'} outside-viewport{$candidate[1].bounds=@(2600,236,3040,408)} overlap{$candidate[1].bounds=@(700,236,1140,408)}}
    Assert-Mixed (-not (Get-DynamicProjectCardSnapshotDecision $surface $candidate $expected 4242 $graph).ready) "Dynamic snapshot accepted $mutation"
  }
  $connectorGraph=@(600,312,1414,858);$client=@(147,196,1427,967)
  $fitted=@([ordered]@{automationId=$expected[0].automationId;name=$expected[0].name;processId=4242;bounds=@(600,552,790,630)},
    [ordered]@{automationId=$expected[1].automationId;name=$expected[1].name;processId=4242;bounds=@(908,552,1114,630)})
  $d=Get-ConnectorDragSnapshotDecision $fitted $expected 4242 $connectorGraph $client $false
  Assert-Mixed ($d.ready -and ($d.sourcePoint -join ',') -ceq '790,591' -and ($d.targetPoint -join ',') -ceq '1011,591' -and
    $d.targetCenterVisible -and $d.sourceCardId -ceq $expected[0].automationId -and $d.targetCardId -ceq $expected[1].automationId) 'Fitted physical connector plan differs'
  $cutoff=Copy-MultiProjectValue $fitted;$cutoff[0].bounds=@(488,365,988,557);$cutoff[1].bounds=@(1264,365,1764,557)
  $d=Get-ConnectorDragSnapshotDecision $cutoff $expected 4242 $connectorGraph $client $false
  Assert-Mixed ($d.ready -and ($d.targetCenter -join ',') -ceq '1514,461' -and -not $d.targetCenterVisible -and
    ($d.targetPoint -join ',') -ceq '1339,461') 'Actual Size cutoff did not use visible card intersection'
  foreach($mutation in @('wrong-connector','wrong-target','wrong-process','logical-card-space','logical-client-space','preexisting-dialog')) {
    $candidate=Copy-MultiProjectValue $fitted;$candidateClient=@($client);$dialog=$false
    switch($mutation){wrong-connector{$candidate[0].automationId='canvas-card-wrong-source'} wrong-target{$candidate[1].name='Wrong target'}
      wrong-process{$candidate[1].processId=7777} logical-card-space{$candidate[0].bounds=@(248,118,468,204);$candidate[1].bounds=@(488,118,708,204)}
      logical-client-space{$candidateClient=@(0,0,640,410)} preexisting-dialog{$dialog=$true}}
    Assert-Mixed (-not (Get-ConnectorDragSnapshotDecision $candidate $expected 4242 $connectorGraph $candidateClient $dialog).ready) "Connector accepted $mutation"
  }
}
foreach($mutation in @('extra-card','extra-project','duplicate-card','duplicate-project','foreign-card-pid','foreign-project-pid','foreign-card-count','foreign-project-count')) {
  Invoke-Mixed 3732 $mutation {
    $p=New-MixedRoster
    switch($mutation){
      extra-card{$p.cards += [ordered]@{automationId='canvas-card-1999999999999999999';name='Unexpected cached loop';processId=4242;bounds=@(508,118,728,204)}}
      extra-project{$p.projectRows += [ordered]@{automationId='open-project-1999999999999999999';name='Unexpected project';processId=4242;bounds=@(12,196,232,222)}}
      duplicate-card{$p.cards += $p.cards[0]} duplicate-project{$p.projectRows += $p.projectRows[0]}
      foreign-card-pid{$p.cards[0].processId=7777} foreign-project-pid{$p.projectRows[0].processId=7777}
      foreign-card-count{$p.foreignCardFragmentCount=1} foreign-project-count{$p.foreignProjectFragmentCount=1}}
    Assert-Mixed (-not (Test-MultiProjectObservedRoster overview $p $rosterOwners $null 4242)) 'Extra/duplicate/foreign roster fragment hidden'
  }
}
Invoke-Mixed 3755 'four-fragments-two-nodes-two-captions' {
  $expected=Get-MultiProjectExpectedCanvasRoster overview $rosterOwners $null
  Assert-Mixed ($expected.Count -eq 4 -and @($expected|Where-Object classification -CEQ node).Count -eq 2 -and
    @($expected|Where-Object classification -CEQ project-caption).Count -eq 2 -and $expected[0].projectPath -ceq 'A' -and
    $null -eq $expected[0].nodeID -and $expected[0].identityKind -ceq 'overview-project') 'Complete caption/node taxonomy collapsed'
}
Invoke-Mixed 3763 'caption-geometry-separate-from-node' {
  $g=Get-MultiProjectCaptionGeometry @(228,85,1036,780) @(390,185,640,281) @(326,157,1812,177)
  Assert-Mixed (($g.caption -join ',') -ceq '326,157,1812,177') 'Source project caption differs'
}
foreach($mutation in @('two-nodes-unknown','unknown-caption','duplicate-caption','wrong-caption-owner','wrong-caption-pid','wrong-caption-name','wrong-caption-bounds','caption-as-node-bounds','hidden-chrome')) {
  Invoke-Mixed 3771 $mutation {
    $p=New-MixedRoster
    switch($mutation){
      two-nodes-unknown{$p.cards=@($p.cards[1],$p.cards[3],[ordered]@{automationId='canvas-card-1999999999999999999';name='Unknown loop';processId=4242;bounds=@(508,118,728,204)})}
      unknown-caption{$p.cards[0].automationId='canvas-card-1999999999999999999'} duplicate-caption{$p.cards += $p.cards[0]}
      wrong-caption-owner{$p.cards[0].automationId='canvas-card-1331912597382320260'} wrong-caption-pid{$p.cards[0].processId=7777}
      wrong-caption-name{$p.cards[0].name='Last inspected'} wrong-caption-bounds{$p.cards[0].bounds=@(750,278,1036,298)}
      caption-as-node-bounds{$p.cards[1].bounds=$p.cards[0].bounds} hidden-chrome{$p.cards=@($p.cards[1],$p.cards[3])}}
    Assert-Mixed (-not (Test-MultiProjectObservedRoster overview $p $rosterOwners $null 4242)) 'Classified roster hid unknown/wrong-owner/caption fragments'
  }
}
Invoke-Mixed 3792 'literal-lane-and-once-scaled-dpi' {
  $g=Get-MultiProjectLaneGeometry @(220,34,1200,900) @(382,134,632,230)
  $scaled=Get-MultiProjectLaneGeometry @(330,51,1800,1350) @(573,201,948,345)
  Assert-Mixed (($g.band -join ',') -ceq '300,96,1822,250' -and ($g.open -join ',') -ceq '1690,106,1746,126' -and
    ($scaled.open -join ',') -ceq '2535,159,2619,189') 'Literal lane bounds or DPI scaling differs'
}
$overviewIds=@('overview-card:fixture:a','overview-card:fixture:b')
$projectIds=@('project-card:fixture:a','project-card:fixture:b')
$laneNames=@('UIA loop A','UIA loop B')
function New-MixedLaneCards([string[]]$Ids,[double[]]$First,[double[]]$Second) {
  @([pscustomobject]@{automationId=$Ids[0];name=$laneNames[0];bounds=$First},[pscustomobject]@{automationId=$Ids[1];name=$laneNames[1];bounds=$Second})
}
Invoke-Mixed 3816 'DPI192-fitted-destination-normalization' {
  $overview=Get-MultiProjectNormalizedLaneGeometry (New-MixedLaneCards $overviewIds @(100,100,290,178) @(408,100,614,178)) $overviewIds $laneNames @(100,0,1200,900) 250 96
  $project=Get-MultiProjectNormalizedLaneGeometry (New-MixedLaneCards $projectIds @(120,100,324,184) @(450,100,670,184)) $projectIds $laneNames @(120,0,1200,900) 250 96
  $comparison=Compare-MultiProjectNormalizedLaneGeometry $project $overview
  Assert-Mixed (($overview.ObservedPixelWidths -join ',') -ceq '190,206' -and ($overview.ObservedPixelHeights -join ',') -ceq '78,78' -and
    $overview.HorizontalClipping[0] -ceq 'left' -and $overview.HorizontalClipping[1] -ceq 'none' -and $comparison.equal) 'Fitted lane source geometry lost'
}
foreach($mutation in @('wrong-source-width','wrong-source-height','wrong-observed-width','wrong-observed-height','wrong-order','overlap','foreign','missing','outside-viewport','both-clipped','no-full-peer')) {
  Invoke-Mixed 3846 $mutation {
    $ids=@($overviewIds);$width=250;$height=96;$first=@(100,100,290,178);$second=@(350,100,540,178);$viewport=@(0,0,1200,900)
    switch($mutation){
      wrong-source-width{$width=249} wrong-source-height{$height=95} wrong-observed-width{$second=@(350,100,520,178)}
      wrong-observed-height{$second=@(350,100,540,160)} wrong-order{$ids=@($overviewIds[1],$overviewIds[0])}
      overlap{$second=@(250,100,440,178)} foreign{$ids=@($overviewIds[0],'overview-card:foreign:b')}
      outside-viewport{$first=@(-1,100,189,178)}
      both-clipped{$first=@(0,100,190,178);$second=@(306,100,500,178);$viewport=@(0,0,500,900)}
      no-full-peer{$first=@(0,100,206,178);$second=@(294,100,500,178);$viewport=@(0,0,500,900)}}
    $cards=if($mutation -ceq 'missing'){@([pscustomobject]@{automationId=$overviewIds[0];name=$laneNames[0];bounds=$first})}else{New-MixedLaneCards $ids $first $second}
    $null=Reject-Mixed {Get-MultiProjectNormalizedLaneGeometry $cards $overviewIds $laneNames $viewport $width $height} 'MULTIPROJECT_BOUNDS'
  }
}
$expected=[ordered]@{
  1724=1;1733=1;1749=6;1757=1;1769=4;1777=1;1789=1;1804=1;1811=1;1818=1;1824=1;1837=5;1843=1;1854=4;1870=1;1879=8;1917=1;1924=4;1951=1
  3392=1;3423=1;3443=1;3458=1;3469=1;3482=1;3487=1;3497=17;3524=1;3530=1;3535=1;3540=1;3545=1;3550=1;3555=1;3560=1;3565=1;3570=1;3575=1
  3596=1;3601=1;3608=1;3625=1;3635=1;3732=8;3755=1;3763=1;3771=9;3792=1;3816=1;3846=11
}
Complete-Mixed $expected @('mixed-ui','geometry-selection-roster','source-correspondence')
