param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
class CardsPilotExitWaitData {
  [int] $SignalAfterMilliseconds
  [int] $Calls
  [int] $Budget
  [bool] $ManagedExited = $true
  [bool] $NativeSignaled
  CardsPilotExitWaitData([int] $signalAfter) { $this.SignalAfterMilliseconds = $signalAfter }
  [void] RequireExited([int] $milliseconds) {
    $this.Calls++
    $this.Budget = $milliseconds
    if ($milliseconds -lt $this.SignalAfterMilliseconds) {
      throw [InvalidOperationException]::new('Original owned root is still live or its exit is unproved.')
    }
    $this.NativeSignaled = $true
  }
}
$entry = Join-Path $RepositoryRoot 'Tools\windows\CardsAcceptance.Live.ps1'
if (Test-Path -LiteralPath $entry) { . $entry }
$nodeId = '11111111-1111-4111-8111-111111111111'
$peerId = '22222222-2222-4222-8222-222222222222'
$project = 'D:\b71\pilot-contract-project'
function New-CardsContractGraph {
  return @{
    id = '33333333-3333-4333-8333-333333333333'
    project = @{ path = $project }
    nodes = @(
      @{ id = $nodeId; title = 'Pilot Goal'; loopType = 'goalBased'; backend = 'copilotCLI'; state = @{idle=@{}}
        modelTier = 'capable'; goal = @{ summary = 'Original goal' }; firstInstruction = 'Original instruction'
        sessionRestarts = 2; createdAt = 123; worktreeBinding = @{ branch = 'owned' }
        attachments = @(); createdBy = $null; subGraph = $null },
      @{ id = $peerId; title = 'Custody peer'; loopType = 'sketch'; backend = 'copilotCLI' }
    )
    edges = @(@{ id = '44444444-4444-4444-8444-444444444444'; from = $nodeId; to = $peerId })
  }
}
function Copy-CardsContractGraph($graph) {
  return ,(ConvertTo-Json -InputObject $graph -Depth 40 -Compress | ConvertFrom-Json -AsHashtable -NoEnumerate)
}
function Invoke-CardsContract([string] $id, [scriptblock] $test, [bool] $reject = $false) {
  $failure = $null
  try {
    $caught = $null
    try { & $test | Out-Null } catch { $caught = $_.Exception }
    if ($reject) {
      if ($caught -isnot [InvalidOperationException] -or $caught.Message -notmatch '^CARDS_PILOT_') {
        throw "Expected the actual fail-closed pilot diagnostic, got: $caught"
      }
    } elseif ($caught) { throw $caught }
  } catch { $failure = $_ }
  Write-Output ('UI_CASE_RESULT=' + ([ordered]@{
    id = $id; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = 1
    evidence = $(if ($failure) { $failure.ToString() } elseif ($id -ceq 'ui.cards-pilot.zip-source-boundary') {
      'Actual provider provenance and compiled API error controls; normal process-local registration; windowsCreated=0; desktopInputCalls=0'
    } else {
      'Actual static pilot predicates with deliberate graph/route data; nativeCalls=0'
    })
  } | ConvertTo-Json -Compress))
}
function Assert-CardsLiveActionInvocations([string] $source) {
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
  if ($errors.Count -ne 0) { throw [InvalidOperationException]::new('CARDS_PILOT_ACTION_INVOCATION: live gate does not parse') }
  $branches = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
      $node.Clauses[0].Item1.Extent.Text -ceq '$CycleHierarchyOnly'
  }, $true))
  if ($branches.Count -ne 1) { throw [InvalidOperationException]::new('CARDS_PILOT_ACTION_INVOCATION: expected one focused Cards slice') }
  foreach ($target in @('$mainInspect[0]', '$goalReply[0]', '$compositeReply[0]')) {
    $calls = @($branches[0].Clauses[0].Item2.FindAll({
      param($node)
      $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -ceq 'Invoke' -and
        $node.Expression -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Member.Value -ceq 'GetCurrentPattern' -and
        $node.Expression.Expression.Extent.Text -ceq $target
    }, $true))
    if ($calls.Count -ne 1) {
      throw [InvalidOperationException]::new("CARDS_PILOT_ACTION_INVOCATION: $target must invoke its actual action exactly once")
    }
  }
}
Invoke-CardsContract 'ui.cards-pilot.target-valid' {
  Assert-CardsPilotTarget (New-CardsContractGraph) $project $nodeId 'goalBased'
}
Invoke-CardsContract 'ui.cards-pilot.foreign-project' {
  Assert-CardsPilotTarget (New-CardsContractGraph) 'D:\foreign' $nodeId 'goalBased'
} $true
Invoke-CardsContract 'ui.cards-pilot.missing-target' {
  Assert-CardsPilotTarget (New-CardsContractGraph) $project $peerId 'goalBased'
} $true
Invoke-CardsContract 'ui.cards-pilot.duplicate-target' {
  $graph = New-CardsContractGraph
  $graph.nodes += $graph.nodes[0]
  Assert-CardsPilotTarget $graph $project $nodeId 'goalBased'
} $true
Invoke-CardsContract 'ui.cards-pilot.cancel-unchanged' {
  $graph = New-CardsContractGraph
  Assert-CardsPilotNoMutation $graph (Copy-CardsContractGraph $graph)
}
Invoke-CardsContract 'ui.cards-pilot.cancel-mutation-refused' {
  $before = New-CardsContractGraph
  $after = Copy-CardsContractGraph $before
  $after.nodes[0].title = 'Mutated'
  Assert-CardsPilotNoMutation $before $after
} $true
Invoke-CardsContract 'ui.cards-pilot.empty-refused' {
  Assert-CardsPilotNoMutation @{ nodes = @(); edges = @() } @{ nodes = @(); edges = @() }
} $true
Invoke-CardsContract 'ui.cards-pilot.missing-graph-refused' {
  Assert-CardsPilotNoMutation @{ edges = @() } @{ edges = @() }
} $true
Invoke-CardsContract 'ui.cards-pilot.timed-effect' {
  $before = New-CardsContractGraph
  $after = Copy-CardsContractGraph $before
  $after.nodes[0].loopType = 'timeBased'; $after.nodes[0].Remove('goal')
  $after.nodes[0].triggerPrompt = '/loop 1h Pilot task'
  Assert-CardsPilotRetype $before $after $nodeId 'timeBased' '/loop 1h Pilot task'
}
Invoke-CardsContract 'ui.cards-pilot.goal-effect' {
  $before = New-CardsContractGraph
  $before.nodes[0].loopType = 'timeBased'; $before.nodes[0].Remove('goal')
  $before.nodes[0].triggerPrompt = '/loop 1h Pilot task'
  $after = Copy-CardsContractGraph $before
  $after.nodes[0].loopType = 'goalBased'; $after.nodes[0].Remove('triggerPrompt')
  $after.nodes[0].goal = @{ summary = 'New goal'; pollIntervalSeconds = 60
    metricDirection = 'maximize'; skipsUnchangedWorkspace = $false }
  $after.nodes[0].state = @{running=@{}}
  Assert-CardsPilotRetype $before $after $nodeId 'goalBased' 'New goal'
  $after.nodes[0].state = @{idle=@{}}
  $caught=$null
  try { Assert-CardsPilotRetype $before $after $nodeId 'goalBased' 'New goal' } catch { $caught=$_.Exception }
  if ($null -eq $caught) { throw 'Goal retype must assert its actual source-defined running state, not initial fixture idle' }
}
Invoke-CardsContract 'ui.cards-pilot.custody-refused' {
  $before = New-CardsContractGraph
  $after = Copy-CardsContractGraph $before
  $after.nodes[0].loopType = 'timeBased'; $after.nodes[0].Remove('goal')
  $after.nodes[0].triggerPrompt = '/loop 1h Pilot task'; $after.nodes[0].backend = 'claudeCode'
  Assert-CardsPilotRetype $before $after $nodeId 'timeBased' '/loop 1h Pilot task'
} $true
Invoke-CardsContract 'ui.cards-pilot.topology-refused' {
  $before = New-CardsContractGraph
  $after = Copy-CardsContractGraph $before
  $after.nodes[0].loopType = 'timeBased'; $after.nodes[0].Remove('goal')
  $after.nodes[0].triggerPrompt = '/loop 1h Pilot task'; $after.edges = @()
  Assert-CardsPilotRetype $before $after $nodeId 'timeBased' '/loop 1h Pilot task'
} $true
Invoke-CardsContract 'ui.cards-pilot.pointer-valid' {
  $edgePlan=[pscustomobject]@{kind='cards-connected-edge-strict';caseCount=1
    desktopReservation=@{scope='one strict connected edge Edit/Cancel'}}
  Assert-CardsConnectedEdgePlan $edgePlan
  foreach($change in @(@{field='kind';value='cards-zip-pilot'},@{field='caseCount';value=2},
      @{field='pickerNavigationOnly';value=$true},@{field='nativeImportOnly';value=$true},
      @{field='nativeExportOnly';value=$true})){
    $invalid=$edgePlan|ConvertTo-Json|ConvertFrom-Json
    $invalid|Add-Member -NotePropertyName $change.field -NotePropertyValue $change.value -Force;$caught=$null
    try{Assert-CardsConnectedEdgePlan $invalid}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Strict edge plan admitted unrelated scope'}
  }
  $edgePoint=Get-CardsConnectedEdgePoint @(20,20,270,116) @(470,20,720,116) @(0,0,1000,500)
  if($edgePoint.x -ne 370 -or $edgePoint.y -ne 68){throw 'Strict edge did not use the single existing curve-midpoint prior art'}
  foreach($change in @(
      @{source=@(20,20,270,116);target=@(240,20,490,116);canvas=@(0,0,1000,500)},
      @{source=@(20,20,270,116);target=@(470,40,720,136);canvas=@(0,0,1000,500)},
      @{source=@(20,20,270,116);target=@(470,20,720,116);canvas=@(0,0,300,500)},
      @{source=@(20,20,20,116);target=@(470,20,720,116);canvas=@(0,0,1000,500)},
      @{source=@(20,20,[double]::NaN,116);target=@(470,20,720,116);canvas=@(0,0,1000,500)})){
    $caught=$null
    try{$null=Get-CardsConnectedEdgePoint $change.source $change.target $change.canvas}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Strict edge geometry admitted overlap/misalignment/clipping/invalid coordinate'}
  }
  $edgePrefill=@{processId=123;owner=100;window=300;class='GraphCodeSheetHost';contentClass='GraphCodeNativeForm';captionless=$true;title='Edit edge'
    elapsedMilliseconds=100;controlElapsedMilliseconds=10
    viewport=@{handle=310;parent=300;processId=123;controlId=0;class='GraphCodeSheetViewport';matches=1;runtime='viewport';sameReading=$true;owned=$true}
    content=@{handle=320;parent=310;processId=123;controlId=0;class='GraphCodeNativeForm';matches=1;runtime='content';sameReading=$true;owned=$true}
    source=@{handle=400;parent=320;processId=123;controlId=9100;class='Edit';owned=$true;readonly=$true;runtime='source';sameReading=$true;value=$nodeId}
    target=@{handle=500;parent=320;processId=123;controlId=9101;class='Edit';owned=$true;readonly=$true;runtime='target';sameReading=$true;value=$peerId}}
  Assert-CardsConnectedEdgePrefill $edgePrefill 123 100 $nodeId $peerId
  foreach($change in @(@{field='processId';value=124},@{field='owner';value=101},
      @{field='class';value='GraphCodeNativeForm'},@{field='contentClass';value='Other'},
      @{field='captionless';value=$false},@{field='title';value='Create or edit edge'},
      @{field='viewport.processId';value=124},@{field='viewport.parent';value=301},
      @{field='viewport.class';value='GraphCodeNativeForm'},@{field='viewport.matches';value=2},
      @{field='content.parent';value=300},@{field='content.processId';value=124},
      @{field='content.controlId';value=9100},@{field='content.class';value='GraphCodeSheetViewport'},
      @{field='content.matches';value=0},@{field='content.matches';value=2},
      @{field='content.runtime';value=''},@{field='content.sameReading';value=$false},
      @{field='content.owned';value=$false},@{field='source.parent';value=310},
      @{field='elapsedMilliseconds';value=10000},@{field='controlElapsedMilliseconds';value=5000},
      @{field='source.value';value=$peerId},@{field='target.value';value=$nodeId},
      @{field='source.processId';value=124},@{field='source.controlId';value=9101},
      @{field='source.class';value='ComboBox'},@{field='source.owned';value=$false},
      @{field='source.readonly';value=$false},
      @{field='source.runtime';value=''},@{field='source.sameReading';value=$false})){
    $invalid=Copy-CardsContractGraph $edgePrefill;$parts=$change.field.Split('.');$target=$invalid
    for($i=0;$i -lt $parts.Count-1;$i++){$target=$target[$parts[$i]]}
    $target[$parts[-1]]=$change.value;$caught=$null
    try{Assert-CardsConnectedEdgePrefill $invalid 123 100 $nodeId $peerId}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Strict edge prefill admitted wrong form/endpoint/owner/native field'}
  }
  $edgeCase=(Get-Command Invoke-CardsConnectedEdgeCase).ScriptBlock.ToString()
  $fragmentGate=Get-Content -Raw (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
  $gateTokens=$null;$gateErrors=$null
  $gateAst=[System.Management.Automation.Language.Parser]::ParseInput($fragmentGate,[ref]$gateTokens,[ref]$gateErrors)
  $chromeFunctions=@($gateAst.FindAll({param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $n.Name -ceq 'Test-UiaNativeRootChrome'},$true))
  if($gateErrors.Count -or $chromeFunctions.Count -ne 1){throw 'Exact native-root chrome predicate missing'}
  . ([scriptblock]::Create($chromeFunctions[0].Extent.Text))
  $chromeRoot=@{window=100;processId=123;nativeProcessId=123;owner=0;class='GraphCodeWindowsShell'
    automationId='graphcode-root';runtime='42,100';bounds=@(10,20,1290,840)}
  $titleChrome=@{automationId='TitleBar';processId=123;class='';role='ControlType.TitleBar'
    runtime='4,100,0';parentRuntime='42,100';parentWindow=100;nativeWindow=0;nativeProcessId=0;nativeClass=''
    isControlElement=$true;isContentElement=$false;bounds=@(18,28,1282,51)}
  $chromeRuntimes=@('app-projects','4,100,0','1,100,1234')
  $chromeIds=@('TitleBar','MenuBar')
  if(-not(Test-UiaNativeRootChrome $chromeRoot $titleChrome $chromeRuntimes $chromeIds)){
    throw 'Measured exact owned root/title-bar metadata refused'}
  $menuChrome=$titleChrome.Clone();$menuChrome.automationId='MenuBar';$menuChrome.role='ControlType.MenuBar'
  $menuChrome.runtime='1,100,1234';$menuChrome.bounds=@(18,51,1282,70)
  if(-not(Test-UiaNativeRootChrome $chromeRoot $menuChrome $chromeRuntimes $chromeIds)){
    throw 'Measured exact owned root/menu-bar metadata refused'}
  foreach($change in @(@{field='automationId';value='UnknownChrome'},@{field='processId';value=124},
      @{field='class';value='Edit'},@{field='role';value='ControlType.Button'},
      @{field='runtime';value='4,101,0'},@{field='runtime';value=''},
      @{field='parentRuntime';value='42,101'},@{field='parentWindow';value=101},
      @{field='nativeWindow';value=101},@{field='nativeProcessId';value=124},
      @{field='nativeClass';value='Edit'},@{field='isControlElement';value=$false},
      @{field='isContentElement';value=$true},@{field='bounds';value=@(0,20,100,40)},
      @{field='bounds';value=@(18,28,18,51)},@{field='bounds';value=@(18,[double]::NaN,1282,51)})){
    $invalid=$titleChrome.Clone();$invalid[$change.field]=$change.value
    if(Test-UiaNativeRootChrome $chromeRoot $invalid $chromeRuntimes $chromeIds){
      throw 'Native root chrome admitted wrong role/process/root/native identity/invalid geometry'}
  }
  foreach($change in @(@{field='processId';value=124},@{field='nativeProcessId';value=124},
      @{field='owner';value=101},@{field='window';value=0},@{field='class';value='Other'},
      @{field='automationId';value='graph'},@{field='runtime';value=''})){
    $invalid=$chromeRoot.Clone();$invalid[$change.field]=$change.value
    if(Test-UiaNativeRootChrome $invalid $titleChrome $chromeRuntimes $chromeIds){
      throw 'Native chrome admitted an unverified owned root'}
  }
  if((Test-UiaNativeRootChrome $chromeRoot $titleChrome @($chromeRuntimes+$titleChrome.runtime) $chromeIds) -or
      (Test-UiaNativeRootChrome $chromeRoot $titleChrome $chromeRuntimes @($chromeIds+'TitleBar'))){
    throw 'Duplicate native chrome identity/runtime admitted'}
  if(-not $fragmentGate.Contains('UIA_FRAGMENT_ROOT_UNEXPECTED_STRUCTURE=') -or
      -not $fragmentGate.Contains('$candidateIds = @("TitleBar", "MenuBar")') -or
      -not $fragmentGate.Contains('candidateProjectionLimit = 2') -or
      -not $fragmentGate.Contains('Require ($unexpectedIds.Count -eq 0)')){
    throw 'Root chrome contract must retain bounded known-ID metadata and strict rejection of unvalidated extras'
  }
  $rootDiagnosticStart=$fragmentGate.IndexOf('$diagnosticClock = [Diagnostics.Stopwatch]::StartNew()')
  $rootDiagnosticEnd=$fragmentGate.IndexOf('Require ($unexpectedIds.Count -eq 0)',$rootDiagnosticStart)
  $rootDiagnostic=$fragmentGate.Substring($rootDiagnosticStart,$rootDiagnosticEnd-$rootDiagnosticStart)
  if($rootDiagnostic -match '\.Current\.Name|\.Value|\.Invoke\(|::(Send|Click|Set|Focus|Activate)' -or
      -not $rootDiagnostic.Contains('Select-Object -First 2') -or
      -not $rootDiagnostic.Contains('$current.ProcessId -eq $rootProcessId') -or
      -not $rootDiagnostic.Contains("-ceq 'graphcode-root'") -or
      -not $rootDiagnostic.Contains('$diagnosticClock.ElapsedMilliseconds -lt 5000')){
    throw 'Unexpected-root metadata must preserve exact root/PID, bounded known candidates, privacy and original control budget'
  }
  if($edgeCase -match 'SendCommand|PostRightClickAt|PostKeyboard|SendKeyInput|ClickPopupMenuItem\(' -or
      -not $edgeCase.Contains('ClickPopupMenuItemStrict') -or
      -not $edgeCase.Contains('ClickOwnedScreenRectangle') -or
      -not $edgeCase.Contains('Assert-CardsPilotNoMutation') -or
      -not $edgeCase.Contains("Click-CardsPilotControl "+"$"+"process "+"$"+"modal 2")){
    throw 'Strict connected edge must use one native pointer menu and Cancel without command/key fallback'}
  Assert-CardsPilotPointer @{ HitTarget = $true; SameTopLevel = $true; VisibleEmpty = $false
    WindowAtPointProcessId = 42; ControlId = 1 } 42 1
  $sample=@{ processId=42; owner=100; root=200; rootProcessId=42; rootClass='#32770'
    control=300; controlProcessId=42; controlId=2; controlClass='Button'
    owned=$true; visible=$true; enabled=$true; hitViable=$true; sameReading=$true
    rootBounds=@(10,20,500,400); controlBounds=@(300,330,388,356) }
  if (-not (Test-CardsPickerCancelReady $sample $sample 42 100 200) -or
      (Test-CardsPickerCancelReady $null $sample 42 100 200)) {
    throw 'Picker readiness must require two matching positive native observations'
  }
  foreach ($change in @(
      @{rootBounds=@(296,45,786,425);controlBounds=@(586,355,674,381)},
      @{control=301},@{hitViable=$false},@{sameReading=$false},
      @{controlProcessId=99},@{root=201},@{controlClass='Edit'},
      @{enabled=$false},@{visible=$false},@{owned=$false})) {
    $changed=$sample.Clone()
    foreach($key in $change.Keys){$changed[$key]=$change[$key]}
    if (Test-CardsPickerCancelReady $sample $changed 42 100 200) {
      throw "Picker readiness admitted moving, recreated, covered or invalid native target: $($change|ConvertTo-Json -Compress)"
    }
  }
  if ((Get-CardsPickerCancelReadinessBudget 0) -ne 5000 -or
      (Get-CardsPickerCancelReadinessBudget 9999) -ne 1) {
    throw 'Picker readiness changed its original transaction/margin budget'
  }
  foreach($elapsed in @(-1,10000,15000)){
    $caught=$null
    try { Get-CardsPickerCancelReadinessBudget $elapsed | Out-Null } catch { $caught=$_.Exception }
    if($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_ZIP:*'){
      throw 'Picker readiness admitted an expired or invalid original budget'
    }
  }
  $poll=@{reads=0};$moved=$sample.Clone();$moved.controlBounds=@(301,330,389,356)
  $caught=$null
  try {
    Wait-CardsPilotState {
      $poll.reads++
      Test-CardsPickerCancelReady $sample $moved 42 100 200
    } 'controlled moving native Cancel readiness' 100 | Out-Null
  } catch { $caught=$_.Exception }
  if ($poll.reads -le 0 -or $caught.Message -cne 'CARDS_PILOT_TIMEOUT: controlled moving native Cancel readiness') {
    throw 'Existing readiness poll did not execute and time out without admitting movement'
  }
  $reader=(Get-Command Get-CardsPickerCancelSnapshot).ScriptBlock.ToString()
  $wait=(Get-Command Wait-CardsPickerCancelReady).ScriptBlock.ToString()
  $cases=(Get-Command Invoke-CardsCancelDriftCases).ScriptBlock.ToString()
  $click=(Get-Command Click-CardsPilotControl).ScriptBlock.ToString()
  if ($reader -match '::(Click|SendInput|SendKey|SendUnicode|SetCursor|Activate|Focus)' -or
      -not $reader.Contains("GetMethod('ResolvesToControl'") -or
      -not $wait.Contains('Get-CardsPickerCancelReadinessBudget $clock.ElapsedMilliseconds') -or
      $cases.IndexOf('Wait-CardsPickerCancelReady') -ge $cases.IndexOf('Click-CardsPilotControl $process $picker 2') -or
      -not $cases.Contains('Click-CardsPilotControl $process $picker 2 ([IntPtr]$ready.control)') -or
      -not $click.Contains('$expectedControl -eq [IntPtr]::Zero -or $control -eq $expectedControl') -or
      -not $click.Contains('[GraphCodeUiaGateState]::ClickScreenPoint($control)') -or
      -not $click.Contains('Assert-CardsPilotPointer $hit $process.Id $id')) {
    throw 'Picker readiness changed the input boundary, skipped retained identity or injected input'
  }
  Write-Host 'CARDS_PICKER_READINESS_CONTROLS=stable,first-sample,movement,recreation,occlusion,in-probe-drift,foreign-pid,root-change,class-change,disabled,hidden,ownership,deadline-boundaries,unchanged-strict-click'
}
Invoke-CardsContract 'ui.cards-pilot.pointer-foreign-refused' {
  Assert-CardsPilotPointer @{ HitTarget = $true; SameTopLevel = $true; VisibleEmpty = $false
    WindowAtPointProcessId = 99; ControlId = 1 } 42 1
} $true
Invoke-CardsContract 'ui.cards-pilot.pointer-missed-refused' {
  foreach ($hit in @($null,@{ HitTarget=$false; SameTopLevel=$true; VisibleEmpty=$false
      WindowAtPointProcessId=42; ControlId=1; Left=10; Top=20; Right=30; Bottom=40
      WindowAtPointText='excluded-owned-text'; RealChildText='excluded-owned-text' })) {
    $caught=$null
    try { Assert-CardsPilotPointer $hit 42 1 } catch { $caught=$_.Exception }
    if ($caught -isnot [InvalidOperationException] -or
        $caught.Message -notlike 'CARDS_PILOT_POINTER:*' -or
        -not $caught.Data.Contains('CardsPilotPointerReceipt')) {
      throw 'Pointer refusal lost its original error or sanitized raw receipt'
    }
    $receipt=$caught.Data['CardsPilotPointerReceipt']
    if ($receipt.expectedProcessId -ne 42 -or $receipt.expectedControlId -ne 1 -or
        $receipt.hitAvailable -ne ($null -ne $hit) -or
        ($receipt | ConvertTo-Json -Depth 4 -Compress).Contains('excluded-owned-text')) {
      throw 'Pointer refusal receipt changed identity or retained user text'
    }
  }
  $broken=[pscustomobject]@{HitTarget=$false;SameTopLevel=$true;VisibleEmpty=$false;WindowAtPointProcessId=42;ControlId=1}
  $broken | Add-Member -MemberType ScriptMethod -Name GetType -Force -Value { throw 'Controlled metadata failure' }
  $caught=$null
  try { Assert-CardsPilotPointer $broken 42 1 } catch { $caught=$_.Exception }
  if ($caught.Message -cne 'CARDS_PILOT_POINTER: exact owned native control hit required; no fallback' -or
      -not $caught.Data.Contains('CardsPilotPointerMetadataFailure')) {
    throw 'Metadata failure replaced the original strict pointer refusal'
  }
}
Invoke-CardsContract 'ui.cards-pilot.completion-positive' {
  Complete-CardsPilotOutcome $null @() 2 2
}
Invoke-CardsContract 'ui.cards-pilot.completion-empty-refused' {
  Complete-CardsPilotOutcome $null @() 2 0
} $true
Invoke-CardsContract 'ui.cards-pilot.cleanup-primary-preserved' {
  $primary = [InvalidOperationException]::new('Original native assertion')
  $cleanup = [IO.IOException]::new('Owned drain failed')
  $caught = $null
  try { Complete-CardsPilotOutcome $primary @($cleanup) 2 1 } catch { $caught = $_.Exception }
  if ($caught -isnot [AggregateException] -or $caught.InnerExceptions.Count -ne 2 -or
      -not [object]::ReferenceEquals($caught.InnerExceptions[0],$primary) -or
      -not [object]::ReferenceEquals($caught.InnerExceptions[1],$cleanup)) {
    throw 'Original assertion or cleanup error was masked'
  }
}
Invoke-CardsContract 'ui.cards-pilot.default-source-boundary' {
  $errors = $null
  $gate = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'),[ref]$null,[ref]$errors)
  if ($errors.Count) { throw 'Gate parse failed' }
  $calls = @($gate.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-CardsNativePilot'
  },$true))
  if ($calls.Count -ne 1) { throw 'Pilot dispatch has wrong shape' }
  $guard = $calls[0]
  while ($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
  if ($null -eq $guard -or $guard.Clauses[0].Item1.Extent.Text -cne
      '$cardsPilotEnvironment.Contains("GRAPHCODE_CARDS_NATIVE_ACCEPTANCE_PLAN")') {
    throw 'Default CI can enter pilot without explicit process-only plan'
  }
  $gateSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1') -Raw
  foreach ($name in @('Get-UiaSettingsVisibilityDecision','Wait-UiaSettingsControlVisible')) {
    $definition = $gate.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    },$true)
    if ($null -eq $definition) { throw "Owned Settings viewport oracle missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  $settingsFrame = @{
    identity=$true;matches=1;stable=$true;name='Mailroom';controlId=6205
    processId=123;parent=12;content=12;offscreen=$false
    bounds=@{left=20;top=80;right=120;bottom=110}
    viewport=@{left=0;top=0;right=200;bottom=100}
  }
  if ((Get-UiaSettingsVisibilityDecision $settingsFrame 123 6205 'Mailroom').ready) {
    throw 'Off-viewport Settings control passed without scrolling'
  }
  $settingsFrame.bounds.top=50; $settingsFrame.bounds.bottom=80
  if (-not (Get-UiaSettingsVisibilityDecision $settingsFrame 123 6205 'Mailroom').ready) {
    throw 'Exact visible owned Settings control was rejected'
  }
  if ((Get-UiaSettingsVisibilityDecision $null 123 6205 'Mailroom').ready) {
    throw 'Missing Settings control was accepted'
  }
  foreach ($negative in @('offscreen','duplicate','wrong-pid','wrong-parent','stale','wrong-id','wrong-name','wrong-owner')) {
    $changed=$settingsFrame | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable
    switch ($negative) {
      'offscreen' { $changed.offscreen=$true }
      'duplicate' { $changed.matches=2 }
      'wrong-pid' { $changed.processId=456 }
      'wrong-parent' { $changed.parent=11 }
      'stale' { $changed.stable=$false }
      'wrong-id' { $changed.controlId=6204 }
      'wrong-name' { $changed.name='Other control' }
      'wrong-owner' { $changed.identity=$false }
    }
    if ((Get-UiaSettingsVisibilityDecision $changed 123 6205 'Mailroom').ready) {
      throw "Invalid Settings viewport $negative was accepted"
    }
  }
  foreach ($scenario in @('scroll-reacquire','no-scroll','failed-wait','stale-after-scroll')) {
    & {
      $state=@{reads=0;scrolls=0}
      function Read-UiaSettingsControlSnapshot {
        param($dialog,$processId,$owner,$id,$name,$class,$contains)
        $state.reads++
        $frame=$settingsFrame | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable
        $frame.element=$state.reads
        if ($state.reads -eq 1 -or $scenario -ceq 'failed-wait') {
          $frame.bounds.top=110; $frame.bounds.bottom=140
        }
        if ($state.reads -gt 1 -and $scenario -ceq 'stale-after-scroll') { $frame.stable=$false }
        return $frame
      }
      function Invoke-UiaSettingsScroll {
        param($dialog,$delta)
        $state.scrolls++
        return $scenario -cne 'no-scroll'
      }
      function Start-Sleep { param($Milliseconds) }
      function Require { param($condition,$message) if (-not $condition) { throw $message } }
      $caught=$null; $visible=$null
      try { $visible=Wait-UiaSettingsControlVisible 10 123 5 6205 'Mailroom' } catch { $caught=$_ }
      if ($scenario -ceq 'scroll-reacquire') {
        if ($caught -or $visible -ne 2 -or $state.reads -ne 2 -or $state.scrolls -ne 1) {
          throw 'Settings scroll did not reacquire and verify the actual visible control'
        }
      } elseif (-not $caught) { throw "Settings $scenario was silently accepted" }
    }
  }
  if ($gateSource -notmatch 'WheelAt\(\$sheet,1,1,\$delta\)' -or
      $gateSource -notmatch 'Wait-UiaSettingsControlVisible \$productSettings' -or
      $gateSource -match "Select-Object -First 1\s*\r?\n\s*Require \(\`$null -ne \`$element\) `"Product Settings omitted") {
    throw 'Settings ordinary route bypasses bounded native scroll/reacquisition'
  }
  foreach ($target in @('$edgeFromValue','$edgeToValue','$canvasEdgeFromId','$canvasEdgeToId')) {
    $reads = @($gate.FindAll({
      param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq $target
    },$true))
    if ($reads.Count -ne 1 -or $reads[0].Right.Extent.Text -match '\.Current\.Name') {
      throw "Readonly endpoint $target is read from a semantic Name instead of its native/ValuePattern value"
    }
  }
  $endpointCalls = @($gate.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
      $node.GetCommandName() -ceq 'Read-UiaReadonlyEdgeEndpoints'
  },$true))
  if ($endpointCalls.Count -ne 2) { throw 'Both ordinary edge routes must use the strict readonly reader' }
  $endpointReader = $gate.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Read-UiaReadonlyEdgeEndpoints'
  },$true)
  if ($null -eq $endpointReader -or $endpointReader.Extent.Text -notmatch 'GraphCodeMultiProjectEditNative\]::Buffer\(\$handle,100\)' -or
      $endpointReader.Extent.Text -notmatch '\$pattern\.Current\.Value' -or
      $endpointReader.Extent.Text -match '\.Current\.Name') {
    throw 'Readonly endpoint reader must agree on native buffer and semantic ValuePattern without a Name fallback'
  }
  $endpointDecision = $gate.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Get-UiaReadonlyEndpointsDecision'
  },$true)
  if ($null -eq $endpointDecision) { throw 'Strict readonly endpoint decision missing' }
  . ([scriptblock]::Create($endpointDecision.Extent.Text))
  $endpointSnapshot = @{
    handle=10;processId=123;owner=5;class='GraphCodeSheetHost';title='Create or edit edge';captionless=$true
    viewport=@{handle=11;parent=10;processId=123;class='GraphCodeSheetViewport';matches=1;stable=$true;runtime='11';owned=$true}
    content=@{handle=12;parent=11;processId=123;class='GraphCodeNativeForm';matches=1;stable=$true;runtime='12';owned=$true}
    fields=@(
      @{handle=21;parent=12;processId=123;controlId=9100;class='Edit';matches=1;stable=$true;runtime='21';owned=$true
        readonly=$true;value=$nodeId;semanticValue=$nodeId;semanticProcessId=123;name='Source loop identity'},
      @{handle=22;parent=12;processId=123;controlId=9101;class='Edit';matches=1;stable=$true;runtime='22';owned=$true
        readonly=$true;value=$peerId;semanticValue=$peerId;semanticProcessId=123;name='Target loop identity'}
    )
  }
  if (-not (Get-UiaReadonlyEndpointsDecision $endpointSnapshot 123 5 'Create or edit edge' $nodeId $peerId).ready) {
    throw 'Correct native/semantic readonly values were rejected because their Names are labels'
  }
  foreach ($negative in @('missing','duplicate','wrong-id','wrong-pid','wrong-parent','wrong-sheet-owner',
      'writable','wrong-value','semantic-mismatch','stale','wrong-class')) {
    $changed = $endpointSnapshot | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    switch ($negative) {
      'missing' { $changed.fields = @($changed.fields[1]) }
      'duplicate' { $changed.fields[0].matches = 2 }
      'wrong-id' { $changed.fields[0].controlId = 9101 }
      'wrong-pid' { $changed.fields[0].processId = 456 }
      'wrong-parent' { $changed.fields[0].parent = 11 }
      'wrong-sheet-owner' { $changed.owner = 6 }
      'writable' { $changed.fields[0].readonly = $false }
      'wrong-value' { $changed.fields[0].value = $peerId; $changed.fields[0].semanticValue = $peerId }
      'semantic-mismatch' { $changed.fields[0].semanticValue = $peerId }
      'stale' { $changed.fields[0].stable = $false }
      'wrong-class' { $changed.fields[0].class = 'Static' }
    }
    if ((Get-UiaReadonlyEndpointsDecision $changed 123 5 'Create or edit edge' $nodeId $peerId).ready) {
      throw "Invalid readonly endpoint $negative was accepted"
    }
  }
  Assert-CardsLiveActionInvocations $gateSource
  foreach ($target in @('$mainInspect[0]', '$goalReply[0]', '$compositeReply[0]')) {
    $action = $target + '.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()'
    $mutated = $gateSource.Replace($action, $action.Replace('.Invoke()', '.GetType()'))
    if ($mutated -ceq $gateSource) { throw "Missing Cards action mutation target $target" }
    $caught = $null
    try { Assert-CardsLiveActionInvocations $mutated } catch { $caught = $_.Exception }
    if ($caught -isnot [InvalidOperationException] -or $caught.Message -notmatch '^CARDS_PILOT_ACTION_INVOCATION:') {
      throw "Missing actual Cards action $target passed its contract"
    }
  }
  foreach ($name in @('Get-CardsCompositeBackDecision','Get-CardsFixtureRestorationDecision','Get-MultiProjectAutomationId')) {
    $definition = $gate.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    },$true)
    if ($null -eq $definition) { throw "Missing breadcrumb contract function $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  $backId = Get-MultiProjectAutomationId 'composite-back' $peerId
  $back = @{automationId=$backId;name='Back to UIA project';processId=123;parentId='graph'}
  if (-not (Get-CardsCompositeBackDecision @($back) $backId 123).ready) { throw 'Exact parent breadcrumb was rejected' }
  foreach ($invalid in @(
      @{items=@()},
      @{items=@($null)},
      @{items=@($back,$back)},
      @{items=@(@{automationId=(Get-MultiProjectAutomationId 'composite-back' $nodeId);name=$back.name;processId=123;parentId='graph'})},
      @{items=@(@{automationId=$backId;name=$back.name;processId=123;parentId='loops'})})) {
    if ((Get-CardsCompositeBackDecision $invalid.items $backId 123).ready) {
      throw 'Missing/null/duplicate/foreign-parent breadcrumb was accepted'
    }
  }
  $restoreWait = $gate.Find({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
      $node.GetCommandName() -ceq 'Wait-ForGraphChildren' -and
      $node.Parent.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and
      $node.Parent.Parent.Left.Extent.Text -ceq '$restoredOriginal'
  },$true)
  if ($null -eq $restoreWait) { throw 'Original fixture restoration wait missing' }
  $restoreFilter = $restoreWait.CommandElements[-2].ScriptBlock.GetScriptBlock()
  $restoreUntil = $restoreWait.CommandElements[-1].ScriptBlock.GetScriptBlock()
  $replyCardIds = @('canvas-card-goal','canvas-card-composite')
  $originalChildren = @(
    @{Current=@{AutomationId=$replyCardIds[0];Name='UIA loop A'}},
    @{Current=@{AutomationId=$replyCardIds[1];Name='UIA loop B'}},
    @{Current=@{AutomationId='canvas-card-reclaim';Name='Reclaim'}},
    @{Current=@{AutomationId='canvas-card-keep';Name='Keep'}}
  )
  $restoredCards = @($originalChildren | Where-Object $restoreFilter)
  if ($restoredCards.Count -ne 2 -or -not (& $restoreUntil $restoredCards)) {
    throw 'Original fixture restoration mistakes Reclaim/Keep siblings for loop cards'
  }
  $baseline = @($originalChildren | ForEach-Object {
    @{automationId=$_.Current.AutomationId;name=$_.Current.Name;processId=123;parentId='graph';controlType='ControlType.Button'}
  })
  if (-not (Get-CardsFixtureRestorationDecision $baseline $baseline 123).ready) {
    throw 'Original graph with legitimate Reclaim/Keep siblings was rejected'
  }
  $wrongParent=@($baseline | ForEach-Object {$_.Clone()});$wrongParent[0].parentId='loops'
  $wrongRole=@($baseline | ForEach-Object {$_.Clone()});$wrongRole[0].controlType='ControlType.Text'
  $notRestored=@($baseline | ForEach-Object {$_.Clone()});$notRestored[0].name='Reply Goal'
  foreach ($invalid in @(
      @{items=@($baseline[0],$baseline[1],$baseline[2])},
      @{items=@($baseline[0],$baseline[1],$baseline[2],$baseline[2])},
      @{items=$wrongParent},@{items=$wrongRole},@{items=$notRestored},@{items=@($null)})) {
    if ((Get-CardsFixtureRestorationDecision $baseline $invalid.items 123).ready) {
      throw 'Missing/duplicate/foreign-parent/changed-role/unrestored graph-child snapshot was accepted'
    }
  }
}
Invoke-CardsContract 'ui.cards-pilot.production-environment-isolated' {
  $environment = @{
    GRAPHCODE_UIA_SUPERVISED_FOREGROUND = '1'; GRAPHCODE_UIA_TEST_HOOK = 'inherited'
    GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK = 'inherited'; ZMX_SESSION = 'foreign'
    GRAPHCODE_SUPPORT_DIR = $project; GRAPHCODE_SOCKET = '\\.\pipe\cards-contract'
  }
  $info = New-CardsPilotStartInfo 'owned-not-launched.exe' @() $environment $project
  foreach ($name in @('GRAPHCODE_UIA_SUPERVISED_FOREGROUND','GRAPHCODE_UIA_TEST_HOOK',
      'GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK','ZMX_SESSION')) {
    if ($info.Environment.ContainsKey($name)) { throw "Inherited production hook/session retained: $name" }
  }
  if ($info.Environment['GRAPHCODE_SUPPORT_DIR'] -cne $project -or
      $info.Environment['GRAPHCODE_SOCKET'] -cne '\\.\pipe\cards-contract') {
    throw 'Owned production support/socket isolation was lost'
  }
}
Invoke-CardsContract 'ui.cards-pilot.persisted-root-and-child-schema' {
  $support = Join-Path $ArtifactRoot 'retained-schema'
  $directory = Join-Path $support 'projects'
  [IO.Directory]::CreateDirectory($directory) | Out-Null
  $json = '{"project":{"name":"project","path":"D:/b71/c14/project"},"nodes":[{"loopType":"proactive","title":"PilotContainer","pilotState":"notPiloted","id":"0458DAF7-4C1C-45B7-B79B-48CB8810D9B9","subGraph":{"id":"ABBBA261-7FBE-47F9-B004-DADF2B294FE2","edges":[],"project":{"name":"PilotContainer","path":"PilotContainer-subgraph"},"nodes":[]}}],"id":"B08EDA9F-4122-4074-BB98-87F91F9338A2","edges":[]}'
  [IO.File]::WriteAllText((Join-Path $directory 'actual-schema.json'),$json,[Text.UTF8Encoding]::new($false))
  $root = Read-CardsPilotGraph $support 'D:\b71\c14\project'
  if ($null -eq $root -or $root.nodes.Count -ne 1 -or $root.nodes[0].title -cne 'PilotContainer' -or
      $root.nodes[0].pilotState -cne 'notPiloted') { throw 'Retained production root schema was not recognized' }
  $child = Read-CardsPilotGraph $support 'D:\b71\c14\project' '0458DAF7-4C1C-45B7-B79B-48CB8810D9B9'
  if ($null -eq $child -or $child.id -cne 'ABBBA261-7FBE-47F9-B004-DADF2B294FE2' -or
      $child.project.path -cne 'PilotContainer-subgraph') { throw 'Owned synthetic child identity was lost' }
  if ($null -ne (Read-CardsPilotGraph $support 'D:\b71\foreign\project')) {
    throw 'Foreign root project was admitted by canonicalization'
  }
  foreach ($negative in @('wrong-parent','wrong-child','missing-child','missing-pilot','enabled-pilot')) {
    $changed = $json | ConvertFrom-Json -AsHashtable
    switch ($negative) {
      'wrong-parent' { $changed.nodes[0].id = $peerId }
      'wrong-child' { $changed.nodes[0].subGraph.id = $peerId }
      'missing-child' { $changed.nodes[0].subGraph = $null }
      'missing-pilot' { $changed.nodes[0].Remove('pilotState') }
      'enabled-pilot' { $changed.nodes[0].pilotState = 'piloted' }
    }
    [IO.File]::WriteAllText((Join-Path $directory 'actual-schema.json'),
      ($changed | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    $caught = $null
    try {
      $null = Read-CardsPilotGraph $support 'D:\b71\c14\project' `
        '0458DAF7-4C1C-45B7-B79B-48CB8810D9B9' 'ABBBA261-7FBE-47F9-B004-DADF2B294FE2'
    } catch { $caught = $_.Exception }
    if ($null -eq $caught -or $caught.Message -notlike 'CARDS_PILOT_READBACK:*') {
      throw "Unsafe retained-schema case admitted: $negative"
    }
  }
  [IO.File]::WriteAllText((Join-Path $directory 'actual-schema.json'),'null',[Text.UTF8Encoding]::new($false))
  if ($null -ne (Read-CardsPilotGraph $support 'D:\b71\c14\project')) { throw 'Null root snapshot admitted' }
  $errors = [Collections.Generic.List[Exception]]::new()
  if (@($errors | ForEach-Object { $_.Message }).Count -ne 0) { throw 'Empty cleanup errors became null entry' }
  $real = [IO.IOException]::new('actual retained cleanup failure')
  $errors.Add($real)
  $encoded = @($errors | ForEach-Object { $_.Message })
  if ($encoded.Count -ne 1 -or $encoded[0] -cne $real.Message) { throw 'Real cleanup failure was hidden' }
}
Invoke-CardsContract 'ui.cards-pilot.private-job-and-overlapping-members' {
  $active = @{ total=1; active=1; expectedActive=1; rootIdentityVerified=$true; heldExitVerified=$false }
  $exited = @{ total=1; active=0; expectedActive=0; rootIdentityVerified=$true; heldExitVerified=$true }
  Assert-CardsPilotLeafAccounting $active
  Assert-CardsPilotLeafAccounting $exited
  $overlap = Assert-CardsPilotMembers @(26476,26476) @(26476)
  if ($overlap.rawCount -ne 2 -or $overlap.uniqueCount -ne 1) {
    throw 'Native membership overlap changed exact unique identity'
  }
  $null = Assert-CardsPilotMembers @() @() $false
  foreach ($case in @('foreign-member','wrong-root','missing-root','unknown-retired','unproved-exit','lost-authority')) {
    $caught = $null
    try {
      switch ($case) {
        'foreign-member' { $null = Assert-CardsPilotMembers @(26476,9999) @(26476) }
        'wrong-root' { $null = Assert-CardsPilotMembers @(26476) @(9999) }
        'missing-root' { $null = Assert-CardsPilotMembers @() @(26476) }
        'unknown-retired' { $bad=@{}+$exited; $bad.total=2; Assert-CardsPilotLeafAccounting $bad }
        'unproved-exit' { $bad=@{}+$exited; $bad.heldExitVerified=$false; Assert-CardsPilotLeafAccounting $bad }
        'lost-authority' { $bad=@{}+$active; $bad.rootIdentityVerified=$false; Assert-CardsPilotLeafAccounting $bad }
      }
    } catch { $caught = $_.Exception }
    if ($null -eq $caught -or $caught.Message -notlike 'CARDS_PILOT_ISOLATION:*') {
      throw "Unsafe private-job case admitted: $case"
    }
  }
}
Invoke-CardsContract 'ui.cards-pilot.protected-console-companion' {
    $trusted = @{ path=(Join-Path ([Environment]::SystemDirectory) 'conhost.exe'); sha256=('A'*64); signatureStatus='Valid'
      signerSubject='CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
      signerThumbprint=('B'*40) }
    $candidate = @{ pid=2; creationUtcTicks=200; job=5; name='conhost'; imagePath=$trusted.path
      sha256=$trusted.sha256; signatureStatus='Valid'; signerThumbprint=$trusted.signerThumbprint }
    Assert-CardsConsoleIdentity $candidate $trusted 1 100 5
    $leaf = @{ total=2; active=2; expectedActive=2; rootActiveCount=1; rootIdentityVerified=$true
      heldExitVerified=$false; observedCompanions=1 }
    Assert-CardsPilotLeafAccounting $leaf
    foreach ($case in @('wrong-path','wrong-name','wrong-hash','wrong-signature','wrong-signer',
        'foreign-job','wrong-creation','unseen-retired','third-child')) {
      $changed=@{}+$candidate; $changedLeaf=@{}+$leaf; $caught=$null
      try {
        switch ($case) {
          'wrong-path' { $changed.imagePath='C:\copied\conhost.exe' }
          'wrong-name' { $changed.name='powershell' }
          'wrong-hash' { $changed.sha256=('C'*64) }
          'wrong-signature' { $changed.signatureStatus='NotTrusted' }
          'wrong-signer' { $changed.signerThumbprint=('C'*40) }
          'foreign-job' { $changed.job=9 }
          'wrong-creation' { $changed.creationUtcTicks=50 }
          'unseen-retired' { $changedLeaf.observedCompanions=0; Assert-CardsPilotLeafAccounting $changedLeaf }
          'third-child' { $changedLeaf.observedCompanions=2; $changedLeaf.total=3; Assert-CardsPilotLeafAccounting $changedLeaf }
        }
        Assert-CardsConsoleIdentity $changed $trusted 1 100 5
      } catch { $caught=$_.Exception }
      if ($null -eq $caught -or $caught.Message -notlike 'CARDS_PILOT_ISOLATION:*') {
        throw "Unsafe console companion admitted: $case"
      }
    }
  }
Invoke-CardsContract 'ui.cards-pilot.precompleted-onboarding-readiness' {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  if ($errors.Count) { throw 'Pilot entry has parser errors' }
  $pilot=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-CardsNativePilot'},$true).Body.Extent.Text
  $marker=$pilot.IndexOf('Initialize-CardsPilotOnboarding $plan.root $plan.support',[StringComparison]::Ordinal)
  $launch=$pilot.IndexOf('$shellProcess = Start-ShellOwnedProcess',[StringComparison]::Ordinal)
  if ($marker -lt 0 -or $marker -ge $launch) {
    throw 'Fresh normal-production retype fixture omits its precompleted-onboarding prerequisite before GUI launch'
  }
  if ($pilot -notmatch 'CARDS_PILOT_FOREGROUND_REFUSAL' -or
      $pilot -notmatch 'DescribeTopLevelWindows' -or $pilot -notmatch 'throw \$foregroundFailure') {
    throw 'Pilot must retain owned refusal flags/modal identities and rethrow the original healthy guard failure'
  }
  $observation=$ast.Find({param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
      $node.Clauses[0].Item1.Extent.Text -ceq '$rootObservation' -and
      $node.Clauses[0].Item2.Extent.Text.Contains('Invoke-CardsRootObservation')
  },$true)
  if ($null -eq $observation -or
      -not $observation.ElseClause.Extent.Text.Contains('Wait-UiaSupervisedForeground') -or
      -not $observation.ElseClause.Extent.Text.Contains('cards pilot first input') -or
      -not $pilot.Contains("`$rootObservation -and `$plan.caseCount -eq 0")) {
    throw 'Explicit zero-case observation branch must precede and exclude original foreground/input acceptance'
  }
  $reader=$ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Invoke-CardsRootObservation'
  },$true)
  if ($null -eq $reader -or $reader.Body.Extent.Text -match
      'SendInput|Click-|SetFocus|Ensure-ShellForeground|InvokePattern|Wait-UiaSupervisedForeground') {
    throw 'Root observation must contain no native input or activation path'
  }
  $root=Join-Path $ArtifactRoot 'precompleted-onboarding'
  $support=Join-Path $root 'support'
  [IO.Directory]::CreateDirectory($support) | Out-Null
  $receipt=Initialize-CardsPilotOnboarding $root $support
  if ($receipt.context -cne 'precompleted-onboarding' -or
      (Get-Item -LiteralPath $receipt.marker).Length -ne 0) {
    throw 'Owned production onboarding marker/context differs from WindowsOnboarding.Store.markSeen'
  }
  $foreignDirectory=Join-Path $root 'foreign'
  [IO.Directory]::CreateDirectory($foreignDirectory) | Out-Null
  $foreignMarker=Join-Path $foreignDirectory 'onboarding-seen'
  [IO.File]::WriteAllText($foreignMarker,'retained-foreign-marker')
  foreach($foreign in @((Join-Path $root 'foreign'),(Join-Path $root '..\foreign-support'),
      (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.graphcode'))) {
    $caught=$null
    try { Initialize-CardsPilotOnboarding $root $foreign } catch { $caught=$_.Exception }
    if ($null -eq $caught -or $caught.Message -notlike 'CARDS_PILOT_READINESS:*') {
      throw 'A foreign support marker destination was accepted'
    }
    $caught=$null
    try { Initialize-CardsPilotOnboarding (Join-Path $root 'wrong-root') $support } catch { $caught=$_.Exception }
    if ($null -eq $caught -or $caught.Message -notlike 'CARDS_PILOT_READINESS:*') {
      throw 'A mismatched owned root was accepted'
    }
    if ([IO.File]::ReadAllText($foreignMarker) -cne 'retained-foreign-marker') {
      throw 'The preexisting foreign marker was touched'
    }
  }
  $caught=$null
  try { Initialize-CardsPilotOnboarding $root $support } catch { $caught=$_.Exception }
  if ($null -eq $caught) { throw 'An existing marker was overwritten in a purported fresh fixture' }
}
Invoke-CardsContract 'ui.cards-pilot.production-card-identity-binding' {
  $source=[IO.File]::ReadAllText($entry)
  $checkBinding={
    param([string] $candidate)
    if ($candidate.Contains("'canvas-card-' +") -or $candidate.Contains('.ToLowerInvariant()')) {
      throw 'Pilot invents UUID-based card AutomationIds instead of the existing production row-key identity'
    }
    foreach($required in @(
        'Get-MultiProjectAutomationId ''project-card'' $projectPath $nodeId',
        'Get-MultiProjectAutomationId ''project-card'' ([string]$persistedParent.project.path) $plan.containingComposite',
        'Get-MultiProjectAutomationId ''project-card'' ([string]$persistedParent.project.path) ([string]$goal[0].id)',
        '$rootGraph = Read-CardsPilotGraph $plan.support $plan.project',
        '$command $label ([string]$rootGraph.project.path)',
        'CARDS_PILOT_CANVAS_TARGET',
        "'exact production container card identity'")) {
      if (-not $candidate.Contains($required)) { throw "Missing production identity/scope binding: $required" }
    }
  }
  & $checkBinding $source
  $mutants=[ordered]@{
    'uuid-text'=$source.Replace('Get-MultiProjectAutomationId ''project-card'' $projectPath $nodeId',
      "'canvas-card-' + `$nodeId")
    'normalized-root'=$source.Replace('([string]$persistedParent.project.path)',
      '([IO.Path]::GetFullPath([string]$persistedParent.project.path))')
    'synthetic-child-path'=$source.Replace('([string]$persistedParent.project.path)',
      '([string]$seed.project.path)')
    'normalized-uuid'=$source.Replace('$projectPath $nodeId',
      '$projectPath $nodeId.ToLowerInvariant()')
  }
  foreach($name in $mutants.Keys) {
    if ($mutants[$name] -ceq $source) { throw "Identity mutation did not change its source input: $name" }
    $caught=$null
    try { & $checkBinding $mutants[$name] } catch { $caught=$_.Exception }
    if ($null -eq $caught) { throw "Unsafe production card identity binding admitted: $name" }
  }
  $producer=[IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\AccessibilityProvider.cpp'))
  if (-not $producer.Contains('return prefix + std::to_wstring(id_);')) {
    throw 'Production AutomationId producer changed; requalify the existing row-key helper'
  }
  $model=[IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\GraphModel.zig'))
  if (-not $model.Contains('graph.project = try cloneProject(allocator, project);')) {
    throw 'Child canvas no longer inherits the root project identity; requalify child card scope'
  }
}
Invoke-CardsContract 'ui.cards-pilot.strict-native-field-transaction' {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  $field=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Set-CardsPilotField'},$true).Body.Extent.Text
  foreach($forbidden in @('TypeEditTextById','SetEditTextById','::SetText(','::FocusControl(')) {
    if ($field.Contains($forbidden)) { throw "Strict field transaction permits legacy focus/text fallback: $forbidden" }
  }
  foreach($required in @('Click-CardsPilotControl','::FocusedControlInDialog(','::SelectAll(',
      '::SendKeyInput(','::SendUnicodeInput(','::Buffer(','CARDS_PILOT_NATIVE_FIELD',
      'typed[0] -eq $typed[1]','typed[1] -eq 2 * $text.Length','Wait-CardsPilotState')) {
    if (-not $field.Contains($required)) { throw "Missing owned native field transaction evidence: $required" }
  }
}
Invoke-CardsContract 'ui.cards-pilot.original-cli-exit-budget' {
  $root=[CardsPilotExitWaitData]::new(25)
  if (-not $root.ManagedExited -or $root.NativeSignaled) { throw 'Invalid pending-native data control' }
  Wait-CardsPilotCliOriginalExit $root 14950
  if (-not $root.NativeSignaled -or $root.Calls -ne 1 -or $root.Budget -ne 50) {
    throw 'Managed exit notification did not wait for original native exit within the remaining original budget'
  }
  foreach($elapsed in @(-1,15000,15001)) {
    $expired=[CardsPilotExitWaitData]::new(1); $caught=$null
    try { Wait-CardsPilotCliOriginalExit $expired $elapsed } catch { $caught=$_.Exception }
    if ($null -eq $caught -or $expired.Calls -ne 0 -or $expired.NativeSignaled) {
      throw 'Invalid or expired original CLI deadline accepted or extended'
    }
  }
  $unproved=[CardsPilotExitWaitData]::new(26); $caught=$null
  try { Wait-CardsPilotCliOriginalExit $unproved 14975 } catch { $caught=$_.Exception }
  if ($null -eq $caught -or $unproved.NativeSignaled -or $unproved.Calls -ne 1 -or $unproved.Budget -ne 25) {
    throw 'Unproved original native exit accepted'
  }
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  $collector=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Read-CardsPilotLaunchAccounting'},$true).Body.Extent.Text
  if ($collector.IndexOf('Wait-CardsPilotCliOriginalExit $run $cliClock.ElapsedMilliseconds') -lt 0 -or
      $collector.IndexOf('::WaitForEmpty($run.LaunchJob,$remaining)') -lt 0 -or
      $collector.IndexOf('Wait-CardsPilotCliOriginalExit') -ge $collector.IndexOf('::WaitForEmpty(') -or
      $collector.IndexOf('::WaitForEmpty(') -ge $collector.IndexOf('::Summary(') -or
      -not $collector.Contains('15000 - [int]$cliClock.ElapsedMilliseconds')) {
    throw 'Original native exit and private-job emptiness require the same remaining CLI clock before post-exit sampling'
  }
  $cli=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-CardsPilotCli'},$true).Body.Extent.Text
  if ($cli.IndexOf('[Diagnostics.Stopwatch]::StartNew()') -ge $cli.IndexOf('Start-ShellOwnedProcess') -or
      $cli -notmatch 'Read-CardsPilotLaunchAccounting \$runs\[0\] \$exitClock' -or
      $cli -notmatch '15000 - \[int\]\$exitClock.ElapsedMilliseconds') {
    throw 'CLI sampling must retain one original 15-second deadline through native exit and finalization'
  }
  if (-not $cli.Contains('Wait-CardsPilotState') -or
      $cli.Contains('while ($exitClock.ElapsedMilliseconds -lt 15000)')) {
    throw 'Use ordinary bounded observation, not a transient-child lifetime census'
  }
}
Invoke-CardsContract 'ui.cards-pilot.completed-cli-ownership-not-identity' {
  $completed=@{ completionKind='original-native-exit-empty-private-job-drained'
    total=3; active=0; expectedActive=0; rawMembers=@(); rootIdentityVerified=$true
    heldExitVerified=$true; privateJobEmptyBeforeFinalize=$true; readersDrained=$true
    observedCompanions=0; retiredUnobserved=2; retiredIdentityCoverage='UNOBSERVED' }
  Assert-CardsPilotLeafAccounting $completed
  foreach($field in @('heldExitVerified','privateJobEmptyBeforeFinalize','readersDrained','active','rawMembers')) {
    $bad=$completed.Clone()
    switch($field) {
      'active' { $bad.active=1 }
      'rawMembers' { $bad.rawMembers=@(987654) }
      default { $bad[$field]=$false }
    }
    $caught=$null
    try { Assert-CardsPilotLeafAccounting $bad } catch { $caught=$_.Exception }
    if ($null -eq $caught) { throw "Invalid completion authority admitted: $field" }
  }
  $parent=@{ pilotState='notPiloted'; subGraph=@{ nodes=@(
    @{state=@{idle=@{}}},@{state=@{idle=@{}}}) } }
  Assert-CardsPilotBackendFixture $parent
  foreach($field in @('parent','child')) {
    $bad=($parent | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable)
    if ($field -ceq 'parent') { $bad.pilotState='piloted' }
    else { $bad.subGraph.nodes[0].state=@{running=@{}} }
    $caught=$null
    try { Assert-CardsPilotBackendFixture $bad } catch { $caught=$_.Exception }
    if ($null -eq $caught) { throw "Unsafe backend fixture admitted: $field" }
  }
  $store=[IO.File]::ReadAllText((Join-Path $RepositoryRoot 'GraphcodeKit\Sources\GraphStore.swift'))
  if ($store -notmatch '(?s)let child = GraphStore\(\s*graph: subGraph,.*?onEnsureSession: nil,') {
    throw 'Child GraphStore backend launch prerequisite changed'
  }
  $source=[IO.File]::ReadAllText($entry)
  if (-not $source.Contains("Join-Path `$plan.support 'sessions'") -or
      -not $source.Contains("if (`$phase -ceq 'before-gui') { Assert-CardsPilotBackendFixture `$parents[0] }")) {
    throw 'Live barriers omit idle-child or zero-session-state backend prerequisite'
  }
  $childInit=[regex]::Match($store,'(?s)let child = GraphStore\((.*?)subGraphDepth: subGraphDepth \+ 1\)')
  if (-not $childInit.Success -or -not $childInit.Value.Contains('onEnsureSession: nil,') -or
      $childInit.Value.Contains('onResumeSession:') -or -not $store.Contains('node.state = .running') -or
      $store -notmatch '(?s)if known == \.absent \{\s*guard let onResumeSession else \{\s*ensureSession\(node\)') {
    throw 'Requalify source-defined Goal state versus nil-callback child backend launch'
  }
}
Invoke-CardsContract 'ui.cards-pilot.popup-pointer-preparation' {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  $menu=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Open-CardsPilotRetype'},$true).Body.Extent.Text
  foreach($required in @('CARDS_PILOT_MENU_ENTRY','CARDS_PILOT_MENU_REFUSAL',
      '::PopupMenuHandle(','DescribeTopLevelWindows','throw $menuFailure','nativeHit=$hit')) {
    if (-not $menu.Contains($required)) { throw "Missing owned popup preparation/refusal evidence: $required" }
  }
  if ($menu.Contains('::HoverPopupMenuItem(') -or
      $menu.Contains('::ClickPopupMenuItem(') -or $menu.Contains('::SelectPopup')) {
    throw 'Top-level popup must use one strict pointer-hover/click primitive, without submenu navigation or fallback'
  }
  $pilotSource = Get-Content -Raw -LiteralPath $entry
  foreach ($required in @('$failure.Exception.GetBaseException().Data',
      'CARDS_PILOT_NATIVE_POPUP_REFUSAL=', 'nativePopupFailure = $nativePopupFailure')) {
    if (-not $pilotSource.Contains($required)) { throw "Missing primary popup exception metadata preservation: $required" }
  }
  foreach ($required in @('CARDS_PILOT_OPEN_GROUP_RETURN=', 'open-group-refusal.json',
      'nativeHit=$groupHit', "'status'", 'throw $groupFailure')) {
    if (-not $pilotSource.Contains($required)) { throw "Missing owned Open Group effect/refusal evidence: $required" }
  }
  $opening=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Open-CardsPilotCardMenu'},$true)
  if ($null -eq $opening -or -not $opening.Body.Extent.Text.Contains('::ClickOwnedScreenRectangle(') -or
      -not $opening.Body.Extent.Text.Contains('Get-MultiProjectClippedRectangle') -or
      -not $opening.Body.Extent.Text.Contains('CARDS_PILOT_NATIVE_CONTEXT') -or
      -not $opening.Body.Extent.Text.Contains('$card.Current.Name -ceq $expectedTitle') -or
      $menu.Contains('Open-CanvasCardContextMenu')) {
    throw 'Strict pilot context opening must use the existing guarded real right-click, not posted mouse messages'
  }
}
function New-CardsZipContractData {
  $before = New-CardsContractGraph
  foreach ($node in $before.nodes) { $node.state=@{idle=@{}}; $node.sessionRestarts=0 }
  $before.nodes[1].createdBy=$nodeId
  $containerId = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
  $parent = @{
    id=$containerId; title='PilotContainer'; loopType='proactive'; pilotState='notPiloted'
    state=@{idle=@{}}; sessionRestarts=0; subGraph=(Copy-CardsContractGraph $before)
  }
  $rootGraph = @{ nodes=@($parent); edges=@() }
  $imported = Copy-CardsContractGraph $parent
  $imported.id='55555555-5555-4555-8555-555555555555'
  $imported.subGraph.id='66666666-6666-4666-8666-666666666666'
  $imported.subGraph.nodes[0].id='77777777-7777-4777-8777-777777777777'
  $imported.subGraph.nodes[1].id='88888888-8888-4888-8888-888888888888'
  $imported.subGraph.nodes[1].createdBy=$imported.subGraph.nodes[0].id
  $imported.subGraph.edges[0].id='99999999-9999-4999-8999-999999999999'
  $imported.subGraph.edges[0].from=$imported.subGraph.nodes[0].id
  $imported.subGraph.edges[0].to=$imported.subGraph.nodes[1].id
  $after = Copy-CardsContractGraph $before
  $after.nodes += $imported
  $after.edges += @{ id='BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'; from=$nodeId
    to=$imported.id; kind='spawn' }
  return @{ root=$rootGraph; before=$before; after=$after; containerId=$containerId }
}
Invoke-CardsContract 'ui.cards-pilot.zip-source-boundary' {
  $zipData=New-CardsZipContractData
  $null=& (Join-Path $PSScriptRoot 'CardsZipBundleContracts.ps1') `
    -RepositoryRoot $RepositoryRoot -ArtifactRoot $ArtifactRoot `
    -Graph $zipData.root -CompositeId $zipData.containerId
  $source = [IO.File]::ReadAllText($entry)
  foreach($required in @('cards-cancel-drift','Invoke-CardsCancelDriftCases',
      'Assert-CardsPilotRemovedTarget','zip-import-cancel','retype-context-drift')) {
    if(-not $source.Contains($required)) { throw "Missing bounded Cancel/drift acceptance: $required" }
  }
  $modePlan=[pscustomobject]@{kind='cards-cancel-drift';caseCount=1;modeDriftOnly=$true}
  if(-not (Test-CardsModeDriftOnly $modePlan)) { throw 'Distinct single mode-drift plan refused' }
  foreach($change in @(@{field='kind';value='cards-retype-pilot'},@{field='caseCount';value=2},
      @{field='modeDriftOnly';value=$false},@{field='modeDriftOnly';value='true'})) {
    $changed=$modePlan|ConvertTo-Json|ConvertFrom-Json
    $changed.($change.field)=$change.value
    if(Test-CardsModeDriftOnly $changed) { throw 'Invalid mode-drift plan admitted' }
  }
  $modeBefore=(New-CardsZipContractData).before
  $nestedMode=Copy-CardsContractGraph $modeBefore
  $nestedMode.project.path='PilotContainer-subgraph'
  $null=Assert-CardsPilotTarget $nestedMode ([string]$nestedMode.project.path) $nodeId 'goalBased'
  $caught=$null
  try { $null=Assert-CardsPilotTarget $nestedMode 'D:\owned-root-project' $nodeId 'goalBased' }
  catch { $caught=$_.Exception }
  if($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_TARGET:*'){
    throw 'Nested mode target must not be relabeled as the root project'
  }
  $modeAfter=Copy-CardsContractGraph $modeBefore
  $modeAfter.nodes[0].loopType='timeBased'
  $modeAfter.nodes[0].goal=$null
  $modeAfter.nodes[0].triggerPrompt='/loop 1h Deliberate owned fixture mode drift'
  $modeAfter.nodes[0].state=@{idle=@{}}
  $null=Assert-CardsPilotRetype $modeBefore $modeAfter $nodeId 'timeBased' $modeAfter.nodes[0].triggerPrompt
  $afterSubmit=Copy-CardsContractGraph $modeAfter
  Assert-CardsPilotNoMutation $modeAfter $afterSubmit
  foreach($mutation in @('original-goal','stale-task','peer-changed','edge-changed')) {
    $changed=Copy-CardsContractGraph $modeAfter
    switch($mutation) {
      'original-goal' { $changed=Copy-CardsContractGraph $modeBefore }
      'stale-task' { $changed.nodes[0].triggerPrompt='/loop 1h Stale task' }
      'peer-changed' { $changed.nodes[1].title='Changed peer' }
      'edge-changed' { $changed.edges=@() }
    }
    $caught=$null
    try { Assert-CardsPilotNoMutation $modeAfter $changed } catch { $caught=$_.Exception }
    if($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_MUTATION:*') {
      throw "Post-deliberate-mode-change baseline admitted mutation: $mutation"
    }
  }
  foreach($required in @('Invoke-CardsModeDriftCase','after-deliberate-cli-mode-drift',
      'Loop type change context changed. Nothing was submitted; reopen the loop menu.')) {
    if(-not $source.Contains($required)){throw "Distinct mode-drift source contract missing: $required"}
  }
  $modeBody=(Get-Command Invoke-CardsModeDriftCase).ScriptBlock.ToString()
  $position=0
  foreach($required in @(
      '$before=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId',
      '$null=Assert-CardsPilotTarget $before ([string]$before.project.path) $goalId ''goalBased''',
      '$goalRender=Read-CardsModeRender $process $root $window $window $cardId 25 158 112',
      'Open-CardsPilotRetype','Invoke-CardsPilotCli','Assert-CardsPilotRetype $before $changed',
      '$timedRender=Read-CardsModeRender $process $root $window $modal $cardId 201 133 0',
      'Click-CardsPilotControl $process $modal 1',
      'Loop type change context changed. Nothing was submitted; reopen the loop menu.',
      'Assert-CardsPilotNoMutation $changedParent','Assert-CardsPilotNoMutation $changed')) {
    $next=$modeBody.IndexOf($required,$position,[StringComparison]::Ordinal)
    if($next -lt 0){throw "Mode-drift input/render/baseline ordering missing: $required"}
    $position=$next+$required.Length
  }
  if($modeBody.Contains("'delete'") -or $modeBody.Contains('Invoke-CardsCancelDriftCases')) {
    throw 'Distinct stale-mode case must not delete or replay the removal case'
  }
  $render=(Get-Command Read-CardsModeRender).ScriptBlock.ToString()
  $renderCheck=Get-Command Assert-CardsModeRenderCheck -ErrorAction SilentlyContinue
  if($null -eq $renderCheck){throw 'Mode render refusal must retain bounded per-term numeric diagnostics'}
  foreach($term in @('rootPid','foregroundOwner','cardRuntime','cardGeometry','pixelsMatch','controlDeadline')) {
    $outcome=@{caught=$null}
    $diagnostic=@(& {
      try {
        Assert-CardsModeRenderCheck 'headless-negative' ([ordered]@{$term=$false}) `
          ([ordered]@{actual=@(25,158,112);expected=@(201,133,0);elapsedMilliseconds=5000;
            deadlineMilliseconds=5000;window=123;processId=456;cardBounds=@(1,2,251,98)})
      } catch {$outcome.caught=$_.Exception}
    } 6>&1)
    if($null -eq $outcome.caught -or
        $outcome.caught.Message -notlike "CARDS_PILOT_DRIFT: mode render headless-negative*${term}*"){
      throw "Mode render failure term not preserved: $term"
    }
    if($diagnostic.Count -ne 1 -or
        ([string]$diagnostic[0]) -notlike 'CARDS_MODE_RENDER_REFUSAL=*'){
      throw "Mode render refusal omitted bounded metadata: $term"
    }
    $retained=([string]$diagnostic[0]).Substring('CARDS_MODE_RENDER_REFUSAL='.Length)|ConvertFrom-Json
    if($retained.terms.$term -cne $false -or
        ($retained.metadata.actual -join ',') -cne '25,158,112' -or
        ($retained.metadata.expected -join ',') -cne '201,133,0' -or
        $retained.metadata.elapsedMilliseconds -ne 5000 -or
        $retained.metadata.deadlineMilliseconds -ne 5000 -or
        $retained.metadata.processId -ne 456 -or
        ($retained.metadata.cardBounds -join ',') -cne '1,2,251,98'){
      throw "Mode render refusal changed its actual/expected numeric terms: $term"
    }
  }
  Assert-CardsModeRenderCheck 'headless-positive' ([ordered]@{pixelsMatch=$true;controlDeadline=$true}) `
    ([ordered]@{elapsedMilliseconds=4999;deadlineMilliseconds=5000})
  if(-not $render.Contains('Assert-CardsModeRenderCheck') -or
      $render.IndexOf('$proof=[ordered]') -gt $render.IndexOf("'sample'")){
    throw 'Mode render bounded actual/expected sample must precede its refusing predicate'
  }
  foreach($required in @('WindowProcessId($window) -eq $process.Id',
      "WindowClass(`$window) -ceq 'GraphCodeWindowsShell'",
      'IsForegroundWindow($foreground)','WindowOwner($foreground) -eq $window',
      'IsCaptionlessSheet($foreground)','$card.Current.ProcessId -eq $process.Id',
      '$card.Current.AutomationId -ceq $cardId','[GraphCodeUiaAttribution]::PrintWindow($window,$hdc,2)',
      '@(-1,0,1)','$bitmap.GetPixel($x+$offset,$y)','$clock.ElapsedMilliseconds -lt 5000',
      '$_.r -ne $red -or $_.g -ne $green -or $_.b -ne $blue','capturedFiles=0')) {
    if(-not $render.Contains($required)){throw "Owned source-derived mode render guard missing: $required"}
  }
  if($render -match 'CopyFromScreen|\.Save\(|SendInput|DllImport|LibraryImport|SetForegroundWindow|SetValue') {
    throw 'Mode render read must reuse existing owned PrintWindow getter without files, screen capture or input'
  }
  $canvas=[IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\GraphCanvas.zig'))
  foreach($required in @(
      'if (std.mem.eql(u8, loop_type, "goalBased")) return 0x00709E19;',
      'if (std.mem.eql(u8, loop_type, "timeBased")) return 0x000085C9;',
      'bounds.left + scaledValue(11, zoom)',
      '.meta = rect(left, bounds.bottom - scaledValue(21, zoom), right, bounds.bottom - scaledValue(8, zoom))',
      'layout.meta.left + scaledValue(6, zoom)',
      'square_top + scaledValue(6, zoom)), loopTypeColor(node.loop_type)')) {
    if(-not $canvas.Contains($required)){throw "Mode-square geometry/color source changed: $required"}
  }
  $driftBefore=(New-CardsZipContractData).before
  $driftAfter=Copy-CardsContractGraph $driftBefore
  $driftAfter.nodes=@($driftAfter.nodes|Where-Object { $_.id -ine $nodeId })
  $driftAfter.edges=@()
  Assert-CardsPilotRemovedTarget $driftBefore $driftAfter $nodeId
  foreach($mutation in @('target-present','peer-changed','edge-retained')) {
    $changed=Copy-CardsContractGraph $driftAfter
    switch($mutation) {
      'target-present' { $changed.nodes+=$driftBefore.nodes[0] }
      'peer-changed' { $changed.nodes[0].title='Not the retained peer' }
      'edge-retained' { $changed.edges=$driftBefore.edges }
    }
    $caught=$null
    try { Assert-CardsPilotRemovedTarget $driftBefore $changed $nodeId } catch { $caught=$_.Exception }
    if($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_*') {
      throw "Captured-target mutation admitted: $mutation"
    }
  }
  if (-not $source.Contains('cards-zip-filename-observation') -or
      -not $source.Contains('zip-filename-cancel-observation') -or
      -not $source.Contains('hostMatchesOwnedPath')) {
    throw 'Missing explicitly labeled Cancel-only child/host filename observation'
  }
  $shapeReader=(Get-Command Get-CardsPickerControlShape).ScriptBlock.ToString()
  $filename=(Get-Command Set-CardsZipPath).ScriptBlock.ToString()
  $zipCases=(Get-Command Invoke-CardsZipCases).ScriptBlock.ToString()
  if(-not $zipCases.Contains('zip-import-picker-structure-cancel-observation')){
    throw 'Missing distinct bounded Open structure/strict-Cancel diagnosis without navigation, filename input or dispatch'}
  if(-not $zipCases.Contains('nativeExportOnly') -or
      -not $zipCases.Contains('Invoke-CardsZipExportCase')){
    throw 'Missing explicit single native export boundary; Cancel-only qualification must not dispatch Save'}
  $checkReader={
    param([string] $reader)
    if ($reader -match '::(Click|SendInput|SendKey|SendUnicode|SetCursor|Activate|Focus)' -or
        $reader -match '\.SetValue\(|\.Current\.(Value|Name)|\$current\.(Value|Name)|TextPattern|GetText\(' -or
        -not $reader.Contains('listContentsOmitted') -or
        -not $reader.Contains('folderContainmentEstablished=$false') -or
        -not $reader.Contains('$rows.Count -lt 96') -or
        -not $reader.Contains('$readClock.ElapsedMilliseconds -lt 5000')) {
      throw 'Picker structure reader changed its bounded, private, read-only contract'
    }
  }
  & $checkReader $shapeReader
  foreach($mutant in @(
      ($shapeReader+'; $current.Name'), ($shapeReader+'; $current.Value'),
      ($shapeReader+'; $provider.SetValue($path)'), ($shapeReader+'; [GraphCodeUiaGateState]::SendKeyInput()'),
      $shapeReader.Replace('$rows.Count -lt 96','$true'),
      $shapeReader.Replace('folderContainmentEstablished=$false','folderContainmentEstablished=$true'))) {
    $caught=$null
    try { & $checkReader $mutant } catch { $caught=$_.Exception }
    if ($null -eq $caught) { throw 'Structure source-negative control admitted text, input, unbounded traversal or invented containment' }
  }
  if (
      $filename.IndexOf('return Get-CardsPickerControlShape') -ge $filename.IndexOf('$value.SetValue($path)') -or
      -not $filename.Contains("Properties['pickerStructureOnly']") -or
      -not $zipCases.Contains('zip-picker-structure-cancel-observation') -or
      -not $zipCases.Contains('Click-CardsPilotControl $process $picker 2 ([IntPtr]$ready.control)')) {
    throw 'Picker structure observation edits fields, loses its no-Save return or bypasses exact native Cancel'
  }
  $addressGuard=(Get-Command Assert-CardsPickerAddressIdentity).ScriptBlock.ToString()
  $beforeChord=Get-CardsPickerInputDisposition 0 0 $true
  if (-not $beforeChord.policyInputBarrier -or $beforeChord.possiblyHeldModifierUnresolved -or
      $beforeChord.modifierEmissionDisposition -cne 'NOT_ATTEMPTED') {
    throw 'Pre-chord lookup failure was mislabeled as actual unresolved modifier emission'
  }
  foreach($counts in @(@(1,0),@(2,0),@(2,1))) {
    $pending=Get-CardsPickerInputDisposition $counts[0] $counts[1] $true
    if (-not $pending.policyInputBarrier -or -not $pending.possiblyHeldModifierUnresolved -or
        $pending.modifierEmissionDisposition -cne 'ATTEMPTED_UNRESOLVED') {
      throw 'Attempted/partial/unknown chord failed to retain the modifier/input barrier'
    }
  }
  $completeChord=Get-CardsPickerInputDisposition 2 2 $true
  if (-not $completeChord.policyInputBarrier -or $completeChord.possiblyHeldModifierUnresolved -or
      $completeChord.modifierEmissionDisposition -cne 'COMPLETE_BATCHES_ONLY') {
    throw 'Completed batches were confused with policy failure or universal keyboard state'
  }
  $unknownChord=Get-CardsPickerInputDisposition 1 0 $false
  if (-not $unknownChord.policyInputBarrier -or -not $unknownChord.possiblyHeldModifierUnresolved) {
    throw 'Unknown in-flight chord was released merely because no failure flag was supplied'
  }
  foreach($counts in @(@(-1,0),@(0,-1),@(0,1))) {
    $caught=$null
    try { $null=Get-CardsPickerInputDisposition $counts[0] $counts[1] $true } catch { $caught=$_.Exception }
    if($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_NAV:*') {
      throw 'Malformed input phase accounting was accepted'
    }
  }
  $address=@{
    expectedProcessId=123; rootProcessId=123; picker=300; expectedPicker=300
    rootClass='#32770'; rootRuntime='root'; expectedRootRuntime='root'; rootVisible=$true; rootEnabled=$true
    bandHandle=400; expectedBandHandle=400; bandId=41477; bandClass='Address Band Root'
    bandProcessId=123; bandNativeOwned=$true; bandRuntime='band'; expectedBandRuntime='band'
    editHandle=500; expectedEditHandle=500; editId=7; expectedEditId=7; editClass='Edit'
    editProcessId=123; editNativeOwned=$true; editRuntime='edit'; expectedEditRuntime='edit'
    focusedHandle=500; exactBandAncestor=$true; caseElapsed=1000; controlElapsed=100
    buffer='D:\owned\picker'; navigationEntered=$true
    bandNativeClass='Observed native class';expectedBandNativeClass='Observed native class'
  }
  Assert-CardsPickerAddressIdentity $address
  Assert-CardsPickerAddressEnter $address 'D:\owned\picker'
  foreach($change in @(
      @{field='rootProcessId';value=999},@{field='picker';value=301},@{field='rootRuntime';value='recreated-root'},
      @{field='rootVisible';value=$false},@{field='rootEnabled';value=$false},
      @{field='bandHandle';value=401},@{field='bandId';value=41478},@{field='bandClass';value='Edit'},
      @{field='bandProcessId';value=999},@{field='bandNativeOwned';value=$false},
      @{field='bandRuntime';value='recreated-band'},@{field='editHandle';value=501},
      @{field='bandNativeClass';value='Different native class'},@{field='expectedBandNativeClass';value=''},
      @{field='editId';value=8},@{field='editClass';value='ComboBox'},@{field='editProcessId';value=999},
      @{field='editNativeOwned';value=$false},@{field='editRuntime';value='recreated-edit'},
      @{field='focusedHandle';value=501},@{field='exactBandAncestor';value=$false},
      @{field='buffer';value='D:\foreign'},@{field='buffer';value='D:\owned\picker\extra'},
      @{field='caseElapsed';value=10000},@{field='controlElapsed';value=5000},
      @{field='caseElapsed';value=-1},@{field='controlElapsed';value=-1})) {
    $invalid=$address.Clone();$invalid[$change.field]=$change.value;$caught=$null
    try { Assert-CardsPickerAddressEnter $invalid 'D:\owned\picker' } catch { $caught=$_.Exception }
    if ($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_NAV:*') {
      throw "Address Enter guard admitted changed focus, ownership, ancestry, bytes or deadline: $($change.field)"
    }
  }
  if ((Get-CardsPickerNavigationBudget 9999 4999) -ne 1 -or
      (Get-CardsPickerNavigationBudget 0 0) -ne 5000) { throw 'Address control budget inflated an original deadline' }
  $rawShape=@{
    processId=123;picker=300;rootRuntimeBefore='root';rootRuntimeAfter='root';queuedNodesOmitted=$false
    controls=@(@{automationId='41477';class='Address Band Root';role='ControlType.Pane'
      controlId=41477;nativeWindow=400;nativeProcessId=123;processId=123;nativeRootOwned=$true
      nativeClass='Observed native class';runtime='band';isControlElement=$false})
  }
  $rawBand=Select-CardsPickerAddressBand $rawShape 123 ([IntPtr]300)
  if($rawBand.nativeWindow -ne 400 -or $rawBand.nativeClass -cne 'Observed native class'){
    throw 'Non-control raw address target or observed native-class meaning was lost'
  }
  foreach($field in @('automationId','class','role','controlId','nativeWindow','nativeProcessId',
      'processId','nativeRootOwned','nativeClass','runtime')) {
    $invalid=$rawShape.Clone();$candidate=$rawShape.controls[0].Clone()
    $candidate[$field]=switch($field){
      'automationId' {'41478'} 'class' {'Other'} 'role' {'ControlType.Edit'} 'controlId' {41478}
      'nativeWindow' {0} 'nativeProcessId' {999} 'processId' {999} 'nativeRootOwned' {$false}
      default {''}
    };$invalid.controls=@($candidate);$caught=$null
    try { $null=Select-CardsPickerAddressBand $invalid 123 ([IntPtr]300) } catch { $caught=$_.Exception }
    if($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_NAV:*'){
      throw "Raw lookup admitted wrong native/UIA identity: $field"
    }
  }
  foreach($change in @(@{field='controls';value=@()},@{field='controls';value=@($rawShape.controls[0],$rawShape.controls[0])},
      @{field='queuedNodesOmitted';value=$true},@{field='picker';value=301},
      @{field='processId';value=999},@{field='rootRuntimeAfter';value='recreated-root'})) {
    $invalid=$rawShape.Clone();$invalid[$change.field]=$change.value;$caught=$null
    try { $null=Select-CardsPickerAddressBand $invalid 123 ([IntPtr]300) } catch { $caught=$_.Exception }
    if($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_NAV:*'){
      throw "Raw lookup admitted truncated/recreated/absent/ambiguous scope: $($change.field)"
    }
  }
  $view=@{
    processId=123;expectedProcessId=123;nativeOwned=$true;viewClass='UIItemsView';runtime='view'
    hostClass='DUIListView';hostId=1121;hostNativeOwned=$true
    markerCount=1;markerProcessId=123;markerVisible=$true;markerRole='ControlType.ListItem';markerRuntime='marker'
    exactKnownMarker=$true;navigationEntered=$true;addressBuffer='D:\owned\picker'
  }
  Assert-CardsPickerFolderView $view 'D:\owned\picker'
  foreach($change in @(
      @{field='processId';value=999},@{field='nativeOwned';value=$false},
      @{field='viewClass';value='ForeignView'},@{field='runtime';value=''},
      @{field='hostClass';value='OtherHost'},@{field='hostId';value=1122},
      @{field='hostNativeOwned';value=$false},@{field='markerCount';value=0},
      @{field='markerCount';value=2},@{field='markerProcessId';value=999},
      @{field='markerVisible';value=$false},@{field='markerRole';value='ControlType.Button'},
      @{field='markerRuntime';value=''},@{field='exactKnownMarker';value=$false},
      @{field='navigationEntered';value=$false},@{field='addressBuffer';value='D:\foreign'})) {
    $invalid=$view.Clone();$invalid[$change.field]=$change.value;$caught=$null
    try { Assert-CardsPickerFolderView $invalid 'D:\owned\picker' } catch { $caught=$_.Exception }
    if ($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'CARDS_PILOT_NAV:*') {
      throw "Folder qualification admitted missing/foreign marker or address state: $($change.field)"
    }
  }
  $attempts=@{count=0};$caught=$null
  try { $null=Wait-CardsPilotState { $attempts.count++;return $null } 'headless missing own marker' 20 }
  catch { $caught=$_.Exception }
  if ($attempts.count -le 0 -or $null -eq $caught -or $caught.Message -notlike '*CARDS_PILOT_TIMEOUT:*') {
    throw 'Missing own marker did not execute the existing bounded poll and refuse'
  }
  $navigation=(Get-Command Invoke-CardsPickerNavigation).ScriptBlock.ToString()
  if(-not $navigation.Contains('Invoke-CardsPickerNativeFilename')){
    throw 'Missing explicitly gated native-primary filename route after actual owned-folder proof'}
  Assert-CardsPickerBareZipBasename 'cards-native-0123456789abcdef0123456789abcdef.zip'
  Assert-CardsPickerBareZipBasename 'loop.zip'
  foreach($badName in @('','..','..zip','a..zip','a\b.zip','a/b.zip','C:a.zip',
      ('a'+[char]0+'.zip'),'a.zip ','.zip','CON.zip','a*.zip','a.zip:stream')) {
    $caught=$null
    try { Assert-CardsPickerBareZipBasename $badName } catch { $caught=$_.Exception }
    if($caught -isnot [InvalidOperationException]){throw 'Native filename admitted a path, wildcard, device or ambiguous basename'}
  }
  $filenameShape=Copy-CardsContractGraph $rawShape
  $filenameShape.controls+=@(
    @{index=10;automationId='FileNameControlHost';class='AppControlHost';role='ControlType.ComboBox'
      nativeClass='ComboBox';controlId=0;nativeWindow=450;processId=123;nativeProcessId=123
      nativeRootOwned=$true;runtime='host'},
    @{index=11;parent=10;automationId='1001';class='Edit';role='ControlType.Edit'
      nativeClass='Edit';controlId=1001;nativeWindow=500;processId=123;nativeProcessId=123
      nativeRootOwned=$true;runtime='edit'})
  $selectedFilename=Select-CardsPickerNativeFilename $filenameShape 123 ([IntPtr]300)
  $openFilenameShape=Copy-CardsContractGraph $rawShape
  $openFilenameShape.controls+=@(
    @{index=10;parent=0;automationId='1148';class='ComboBoxEx32';role='ControlType.Pane'
      nativeClass='ComboBoxEx32';controlId=1148;nativeWindow=440;processId=123;nativeProcessId=123
      nativeRootOwned=$true;runtime='outer'},
    @{index=11;parent=10;automationId='1148';class='ComboBox';role='ControlType.ComboBox'
      nativeClass='ComboBox';controlId=1148;nativeWindow=450;processId=123;nativeProcessId=123
      nativeRootOwned=$true;runtime='host'},
    @{index=12;parent=11;automationId='1148';class='Edit';role='ControlType.Edit'
      nativeClass='Edit';controlId=1148;nativeWindow=500;processId=123;nativeProcessId=123
      nativeRootOwned=$true;runtime='edit'})
  $openFilename=Select-CardsPickerNativeFilename $openFilenameShape 123 ([IntPtr]300) -Importing
  if($openFilename.outer.nativeWindow -ne 440 -or $openFilename.host.nativeWindow -ne 450 -or
      $openFilename.edit.nativeWindow -ne 500 -or $openFilename.importing -ne $true){
    throw 'Open did not bind the measured exact 1148 outer/host/Edit chain'}
  foreach($mode in @('open-as-save','save-as-open')){
    $caught=$null
    try{
      if($mode -ceq 'open-as-save'){$null=Select-CardsPickerNativeFilename $openFilenameShape 123 ([IntPtr]300)}
      else{$null=Select-CardsPickerNativeFilename $filenameShape 123 ([IntPtr]300) -Importing}
    }catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Filename selector silently fell back between Open and Save'}
  }
  foreach($rowIndex in @(1,2,3)){
    foreach($change in @(@{field='automationId';value='1001'},@{field='controlId';value=1001},
        @{field='class';value='Other'},@{field='nativeClass';value='Other'},
        @{field='role';value='ControlType.Button'},@{field='parent';value=99},
        @{field='processId';value=124},@{field='nativeProcessId';value=124},
        @{field='nativeRootOwned';value=$false},@{field='nativeWindow';value=0},@{field='runtime';value=''})){
      $invalid=Copy-CardsContractGraph $openFilenameShape;$invalid.controls[$rowIndex][$change.field]=$change.value;$caught=$null
      try{$null=Select-CardsPickerNativeFilename $invalid 123 ([IntPtr]300) -Importing}catch{$caught=$_.Exception}
      if($caught -isnot [InvalidOperationException]){throw "Open filename chain admitted row$rowIndex/$($change.field)"}
    }
    $invalid=Copy-CardsContractGraph $openFilenameShape;$invalid.controls+=Copy-CardsContractGraph $invalid.controls[$rowIndex]
    $caught=$null;try{$null=Select-CardsPickerNativeFilename $invalid 123 ([IntPtr]300) -Importing}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open filename chain admitted duplicate outer/host/Edit'}
  }
  foreach($change in @(@{field='queuedNodesOmitted';value=$true},@{field='rootRuntimeAfter';value='recreated'})){
    $invalid=Copy-CardsContractGraph $openFilenameShape;$invalid[$change.field]=$change.value;$caught=$null
    try{$null=Select-CardsPickerNativeFilename $invalid 123 ([IntPtr]300) -Importing}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open filename selector admitted truncated or recreated root'}
  }
  $structurePlan=[pscustomobject]@{kind='cards-zip-filename-observation';caseCount=1
    pickerImportStructureOnly=$true;pickerStructureOnly=$true;pickerNavigationOnly=$false;pickerNativeFilenameOnly=$false}
  Assert-CardsPickerImportStructurePlan $structurePlan
  foreach($change in @(@{field='kind';value='cards-zip-pilot'},@{field='caseCount';value=3},
      @{field='pickerImportStructureOnly';value='true'},@{field='pickerStructureOnly';value=$false},
      @{field='pickerStructureOnly';value='true'},
      @{field='pickerNavigationOnly';value=$true},@{field='pickerNativeFilenameOnly';value=$true},
      @{field='pickerNativeFilenameReadbackOnly';value=$true},@{field='nativeImportOnly';value=$true},
      @{field='nativeExportOnly';value=$true})){
    $invalid=$structurePlan|ConvertTo-Json|ConvertFrom-Json
    $invalid|Add-Member -NotePropertyName $change.field -NotePropertyValue $change.value -Force;$caught=$null
    try{Assert-CardsPickerImportStructurePlan $invalid}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Import structure mode admitted transfer/navigation/filename scope or ambiguous plan'}
  }
  $privateShape=Copy-CardsContractGraph $filenameShape
  foreach($row in $privateShape.controls){$row.Name='foreign-private-name';$row.Value='foreign-private-value'}
  $structure=Select-CardsPickerFilenameStructure $privateShape 123 ([IntPtr]300)
  $serialized=$structure|ConvertTo-Json -Depth 10 -Compress
  if($structure.exactFilenameHostRawCount -ne 1 -or $structure.candidateCount -ne 2 -or
      $structure.filenameEdits -ne 0 -or $structure.transferEffects -ne 0 -or $structure.chordCalls -ne 0 -or
      $serialized.Contains('foreign-private') -or $serialized.Contains('"Name"') -or $serialized.Contains('"Value"')){
    throw 'Import structure projection leaked Name/Value or invented native input qualification'}
  foreach($count in @(0,2)){
    $candidateShape=Copy-CardsContractGraph $filenameShape
    $hostRow=$candidateShape.controls|Where-Object automationId -CEQ 'FileNameControlHost'
    $candidateShape.controls=@($candidateShape.controls|Where-Object automationId -CNE 'FileNameControlHost')
    for($i=0;$i -lt $count;$i++){$candidateShape.controls+=Copy-CardsContractGraph $hostRow}
    $projection=Select-CardsPickerFilenameStructure $candidateShape 123 ([IntPtr]300)
    if($projection.exactFilenameHostRawCount -ne $count){throw 'Import diagnostic concealed exact raw host absence/ambiguity'}
  }
  $foreignShape=Copy-CardsContractGraph $filenameShape;$foreignShape.controls[1].nativeProcessId=999;$caught=$null
  try{$null=Select-CardsPickerFilenameStructure $foreignShape 123 ([IntPtr]300)}catch{$caught=$_.Exception}
  if($caught -isnot [InvalidOperationException]){throw 'Import structure admitted changed native ownership'}
  if($selectedFilename.edit.nativeWindow -ne 500 -or $selectedFilename.host.nativeWindow -ne 450){
    throw 'Native filename did not bind the exact raw host/child'}
  foreach($change in @(@{field='parent';value=9},@{field='automationId';value='1002'},
      @{field='controlId';value=1002},@{field='class';value='ComboBox'},
      @{field='nativeClass';value='OtherEdit'},@{field='role';value='ControlType.Button'},
      @{field='processId';value=124},@{field='nativeProcessId';value=124},
      @{field='nativeRootOwned';value=$false},@{field='runtime';value=''})){
    $invalid=Copy-CardsContractGraph $filenameShape;$invalid.controls[2][$change.field]=$change.value;$caught=$null
    try{$null=Select-CardsPickerNativeFilename $invalid 123 ([IntPtr]300)}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Native filename raw selector admitted $($change.field)"}
  }
  foreach($change in @(@{field='class';value='Other'},@{field='nativeClass';value='Other'},
      @{field='role';value='ControlType.Edit'},@{field='controlId';value=1},
      @{field='nativeWindow';value=0},@{field='processId';value=124},
      @{field='nativeProcessId';value=124},@{field='nativeRootOwned';value=$false},@{field='runtime';value=''})){
    $invalid=Copy-CardsContractGraph $filenameShape;$invalid.controls[1][$change.field]=$change.value;$caught=$null
    try{$null=Select-CardsPickerNativeFilename $invalid 123 ([IntPtr]300)}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Native filename host selector admitted $($change.field)"}
  }
  foreach($mutation in @('no-child','duplicate-child','duplicate-host','truncated','recreated-root')){
    $invalid=Copy-CardsContractGraph $filenameShape
    switch($mutation){
      'no-child'{$invalid.controls=@($invalid.controls|Where-Object automationId -NE '1001')}
      'duplicate-child'{$invalid.controls+=@($invalid.controls[2])}
      'duplicate-host'{$invalid.controls+=@($invalid.controls[1])}
      'truncated'{$invalid.queuedNodesOmitted=$true}
      'recreated-root'{$invalid.rootRuntimeAfter='different'}
    }
    $caught=$null;try{$null=Select-CardsPickerNativeFilename $invalid 123 ([IntPtr]300)}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Native filename selector admitted $mutation"}
  }
  $fieldSample=@{processId=123;rootProcessId=123;controlProcessId=123;owner=100;root=300
    rootClass='#32770';control=500;controlId=1001;controlClass='Edit';owned=$true
    visible=$true;enabled=$true;hitViable=$true;sameReading=$true;rootBounds=@(0,0,500,500);controlBounds=@(10,10,110,30)}
  if(-not (Test-CardsPickerCancelReady $fieldSample $fieldSample 123 100 300 1001 'Edit') -or
      (Test-CardsPickerCancelReady $fieldSample $fieldSample 123 100 300)){
    throw 'Explicit filename geometry target changed default Cancel-only identity or refused the native Edit'}
  foreach($mutation in @('move','recreate','occluded','disabled','wrong-class')){
    $changed=$fieldSample.Clone()
    switch($mutation){
      'move'{$changed.controlBounds=@(11,10,111,30)}
      'recreate'{$changed.control=501}
      'occluded'{$changed.hitViable=$false}
      'disabled'{$changed.enabled=$false}
      'wrong-class'{$changed.controlClass='Button'}
    }
    if(Test-CardsPickerCancelReady $fieldSample $changed 123 100 300 1001 'Edit'){
      throw "Native filename readiness admitted $mutation"}
  }
  $filenameState=@{expectedProcessId=123;hostProcessId=123;processId=123;count=1;handle=500
    expectedHandle=500;controlId=1001;class='Edit';nativeClass='Edit';nativeProcessId=123;nativeOwned=$true
    runtime='edit';expectedRuntime='edit';hostRuntime='host';expectedHostRuntime='host'
    hostClass='AppControlHost';hostNativeClass='ComboBox';hostRole='ControlType.ComboBox';hostNativeOwned=$true;role='ControlType.Edit'
    picker=300;expectedPicker=300;rootProcessId=123;rootClass='#32770';rootRuntime='root'
    expectedRootRuntime='root';rootVisible=$true;rootEnabled=$true;focusedHandle=500
    buffer='cards-native-0123456789abcdef0123456789abcdef.zip'
    hostBuffer='cards-native-0123456789abcdef0123456789abcdef.zip'}
  Assert-CardsPickerNativeFilenameState $filenameState $true
  Assert-CardsPickerNativeFilenameValue $filenameState $filenameState.buffer
  $openFilenameState=Copy-CardsContractGraph $filenameState
  $openFilenameState.importing=$true;$openFilenameState.controlId=1148;$openFilenameState.hostClass='ComboBox'
  $openFilenameState.outer=@{nativeWindow=440;expectedHandle=440;class='ComboBoxEx32';nativeClass='ComboBoxEx32'
    role='ControlType.Pane';controlId=1148;processId=123;nativeProcessId=123;nativeOwned=$true
    nativeRootChild=$true;hostParentVerified=$true;runtime='outer';expectedRuntime='outer'}
  Assert-CardsPickerNativeFilenameState $openFilenameState $true
  $openFullSemantic=Get-CardsPickerFilenameReadbackMetadata $openFilenameState.buffer $openFilenameState.hostBuffer $openFilenameState.buffer $true $openFilenameState.buffer
  Assert-CardsPickerNativeFilenameValue $openFilenameState $openFilenameState.buffer $openFullSemantic
  $openEmptyNativeHost=Copy-CardsContractGraph $openFilenameState
  $openEmptyNativeHost.hostBuffer=''
  $openSemantic=Get-CardsPickerFilenameReadbackMetadata $openEmptyNativeHost.buffer '' $openEmptyNativeHost.buffer $true $openEmptyNativeHost.buffer
  if(-not (Test-CardsPickerNativeFilenameReady $openEmptyNativeHost $openEmptyNativeHost.buffer $openSemantic)){
    throw 'Measured Open native Edit and advertised host semantic full equality blocked by empty host WM_GETTEXT'}
  Assert-CardsPickerNativeFilenameValue $openEmptyNativeHost $openEmptyNativeHost.buffer $openSemantic
  foreach($value in @('','cards-',[IO.Path]::GetFileNameWithoutExtension($openEmptyNativeHost.buffer),'other.zip')){
    $invalid=Copy-CardsContractGraph $openEmptyNativeHost;$invalid.buffer=$value;$caught=$null
    $channels=Get-CardsPickerFilenameReadbackMetadata $value '' $value $true $openEmptyNativeHost.buffer
    try{Assert-CardsPickerNativeFilenameValue $invalid $openEmptyNativeHost.buffer $channels}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open empty/prefix/stem/foreign child was accepted as full basename'}
    $ready=$false
    try{$ready=Test-CardsPickerNativeFilenameReady $invalid $openEmptyNativeHost.buffer $channels}catch [InvalidOperationException]{}
    if($ready){throw 'Open native child partial/stem/foreign bytes became readiness success'}
  }
  foreach($field in @('uiaHostValueAvailable','uiaHostMatchesSuggested','uiaHostMatchesChild')){
    $invalid=[ordered]@{};foreach($key in $openSemantic.Keys){$invalid[$key]=$openSemantic[$key]}
    $invalid[$field]=$false;$caught=$null
    try{Assert-CardsPickerNativeFilenameValue $openEmptyNativeHost $openEmptyNativeHost.buffer $invalid}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open empty native host reader lost semantic authority guard'}
  }
  foreach($badValue in @('cards-','other.zip','cards-other.zip','D:\foreign.zip')){
    $invalid=Copy-CardsContractGraph $openEmptyNativeHost;$invalid.hostBuffer=$badValue;$caught=$null
    try{Assert-CardsPickerNativeFilenameValue $invalid $invalid.buffer $openSemantic}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open native host reader admitted unexpected nonempty text'}
    $caught=$null
    try{$null=Test-CardsPickerNativeFilenameReady $invalid $invalid.buffer $openSemantic}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open native host contradictory nonempty text was polled instead of refused'}
  }
  $saveEmptyNativeHost=Copy-CardsContractGraph $filenameState;$saveEmptyNativeHost.hostBuffer=''
  $caught=$null
  try{Assert-CardsPickerNativeFilenameValue $saveEmptyNativeHost $saveEmptyNativeHost.buffer $openSemantic}catch{$caught=$_.Exception}
  if($caught -isnot [InvalidOperationException] -or
      (Test-CardsPickerNativeFilenameReady $saveEmptyNativeHost $saveEmptyNativeHost.buffer $openSemantic)){
    throw 'Open semantic reader correction weakened Save all-three readback'}
  $caught=$null
  try{Assert-CardsPickerNativeFilenameValue $openEmptyNativeHost $openEmptyNativeHost.buffer}catch{$caught=$_.Exception}
  if($caught -isnot [InvalidOperationException]){throw 'Open filename success admitted missing semantic channel'}
  foreach($change in @(@{field='importing';value=$false},@{field='importing';value='true'},
      @{field='controlId';value=1001},@{field='hostClass';value='AppControlHost'},
      @{field='nativeOwned';value=$false},@{field='nativeProcessId';value=124},
      @{field='hostNativeOwned';value=$false},@{field='focusedHandle';value=501},
      @{field='rootRuntime';value='recreated'},@{field='runtime';value='recreated'},
      @{field='hostRuntime';value='recreated'},@{field='outer';value=$null})){
    $invalid=Copy-CardsContractGraph $openFilenameState;$invalid[$change.field]=$change.value;$caught=$null
    try{Assert-CardsPickerNativeFilenameState $invalid $true}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Open filename state admitted $($change.field)"}
  }
  foreach($change in @(@{field='nativeWindow';value=441},@{field='class';value='Other'},
      @{field='nativeClass';value='Other'},@{field='role';value='ControlType.ComboBox'},
      @{field='controlId';value=1001},@{field='processId';value=124},@{field='nativeProcessId';value=124},
      @{field='nativeOwned';value=$false},@{field='nativeRootChild';value=$false},
      @{field='hostParentVerified';value=$false},@{field='runtime';value='recreated'},@{field='expectedRuntime';value=''})){
    $invalid=Copy-CardsContractGraph $openFilenameState;$invalid.outer[$change.field]=$change.value;$caught=$null
    try{Assert-CardsPickerNativeFilenameState $invalid $true}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Open filename outer state admitted $($change.field)"}
  }
  $openFieldSample=Copy-CardsContractGraph $fieldSample;$openFieldSample.controlId=1148
  if(-not (Test-CardsPickerCancelReady $openFieldSample $openFieldSample 123 100 300 1148 'Edit') -or
      (Test-CardsPickerCancelReady $openFieldSample $openFieldSample 123 100 300 1001 'Edit') -or
      (Test-CardsPickerCancelReady $openFieldSample $openFieldSample 123 100 300)){
    throw 'Measured Open field widened default Save/Cancel pointer identities'}
  $nativeStateReader=(Get-Command Get-CardsPickerNativeFilenameState).ScriptBlock.ToString()
  $nativePrimary=(Get-Command Read-CardsNativePrimaryReady).ScriptBlock.ToString()
  foreach($required in @('RequireOwnedKeyboardInput','GetParent($outerElement)','GetParent($hostElement)',
      'ControlById($picker,1148)','ControlById($hostHandle,$editId)',
      '$binding.outer.runtime','$binding.rootRuntime','IsControlOwnedBy($picker,$outerHandle,1148)')){
    if(-not $nativeStateReader.Contains($required)){throw "Open live state lacks exact current ancestry/identity guard: $required"}
  }
  if(-not $nativePrimary.Contains('$native.importing -is [bool]') -or
      -not $nativePrimary.Contains('outer=$native.outer')){
    throw 'Pre-primary read lost explicit operation or original outer binding'}
  $readyChannels=Get-CardsPickerFilenameReadbackMetadata $filenameState.buffer $filenameState.hostBuffer $filenameState.buffer $true $filenameState.buffer
  $exportPlan=[pscustomobject]@{kind='cards-zip-pilot';caseCount=1;nativeExportOnly=$true
    pickerNavigationOnly=$true;pickerNativeFilenameOnly=$true
    nativeFilenameQualification=@{path='C:\owned\qualified.json';sha256=('A'*64)}
    bindings=@(@{path='C:\owned\qualified.json';sha256=('A'*64)})}
  $qualification=@{case='zip-picker-native-filename-cancel-qualification';actualQualifications=1;transferEffects=0
    ownedFolderView=$true;graphUnchanged=$true;markerCustodyVerified=$true;absentFullAndStemOutputs=4
    strictExportMenuAndCancel=$true;ownedJobCleanupVerified=$true;exactDpiRestoreVerified=$true
    sourceBindingsVerifiedAtEnd=1
    inputDisposition=@{chordCallsAttempted=2;chordCallsCompleted=2;possiblyHeldModifierUnresolved=$false;policyInputBarrier=$false}
    driver=@{gateExit=0;sourceUnchanged=$true;defaultProfilesUnchanged=$true;driverOwnedCleanup=$true;failure=$null;cleanupFailures=@()}
    nativeFilename=@{basename=$filenameState.buffer;initialSuggestedBasename='loop.zip';strictPointer=$true;exactFocus=$true
      childReadbackExact=$true;hostReadbackExact=$true;typedChannels=$readyChannels
      filenameEdits=1;readbackSamples=2;fullAndStemCandidatesAbsent=4
      clearEvents=2;typedEvents=98;enterEvents=0;inputReplays=0;transferEffects=0}}
  Assert-CardsNativeExportQualification $exportPlan $qualification
  $importPlan=[pscustomobject]@{kind='cards-zip-pilot';caseCount=1;nativeImportOnly=$true
    pickerNavigationOnly=$true;pickerNativeFilenameOnly=$true
    nativeImportArchive=@{sourcePath='C:\owned\source.zip';sha256=('C'*64)
      exportReceipt=@{path='C:\owned\export.json';sha256=('A'*64)}}
    bindings=@(@{path='C:\owned\export.json';sha256=('A'*64)},@{path='C:\owned\source.zip';sha256=('C'*64)})}
  $exportReceipt=@{actualTransfers=1;OpenImportActions=0;archivePath='C:\owned\source.zip';archiveSha256=('C'*64)
    ownedJobCleanupVerified=$true;exactDpiRestoreVerified=$true;sourceBindingsVerifiedAtEnd=1
    inputDisposition=$qualification.inputDisposition;driver=$qualification.driver
    case=@{case='zip-save-export';transferEffects=1;graphUnchanged=$true;alternateArchives=0
      retainedStagingDirectories=0;markerCustodyVerified=$true
      bundle=@{sha256=('C'*64);rootNodes=1;recursiveNodes=3;recursiveEdges=1;sessionTransplantEntries=0}}}
  Assert-CardsNativeImportQualification $importPlan $exportReceipt
  foreach($change in @(@{field='nativeImportOnly';value='true'},@{field='nativeImportOnly';value=$false},
      @{field='nativeExportOnly';value=$true},@{field='caseCount';value=3},@{field='kind';value='cards-zip-filename-observation'},
      @{field='bindings';value=@()},@{field='pickerNavigationOnly';value=$false},
      @{field='pickerNativeFilenameOnly';value=$false},@{field='pickerNativeFilenameReadbackOnly';value=$true})){
    $invalid=$importPlan|ConvertTo-Json -Depth 15|ConvertFrom-Json
    $invalid|Add-Member -NotePropertyName $change.field -NotePropertyValue $change.value -Force;$caught=$null
    try{Assert-CardsNativeImportQualification $invalid $exportReceipt}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Native Open admitted an ambiguous mode, missing binding or diagnostic-only plan'}
  }
  foreach($change in @(@{field='actualTransfers';value=0},@{field='OpenImportActions';value=1},
      @{field='archivePath';value='C:\other.zip'},@{field='archiveSha256';value=('D'*64)},
      @{field='case.case';value='zip-picker-cancel'},@{field='case.transferEffects';value=0},
      @{field='case.bundle.sha256';value=('D'*64)},@{field='case.bundle.recursiveNodes';value=2},
      @{field='case.bundle.recursiveEdges';value=0},@{field='case.bundle.sessionTransplantEntries';value=1},
      @{field='case.graphUnchanged';value=$false},@{field='case.alternateArchives';value=1},
      @{field='case.retainedStagingDirectories';value=1},@{field='case.markerCustodyVerified';value=$false},
      @{field='ownedJobCleanupVerified';value=$false},@{field='exactDpiRestoreVerified';value=$false},
      @{field='inputDisposition.possiblyHeldModifierUnresolved';value=$true},@{field='inputDisposition.policyInputBarrier';value=$true},
      @{field='driver.gateExit';value=1},@{field='driver.defaultProfilesUnchanged';value=$false})){
    $invalid=Copy-CardsContractGraph $exportReceipt;$parts=$change.field.Split('.');$target=$invalid
    for($i=0;$i -lt $parts.Count-1;$i++){$target=$target[$parts[$i]]};$target[$parts[-1]]=$change.value
    $caught=$null;try{Assert-CardsNativeImportQualification $importPlan $invalid}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Native Open admitted an unqualified archive: $($change.field)"}
  }
  foreach($change in @(@{field='kind';value='cards-zip-filename-observation'},@{field='caseCount';value=3},
      @{field='nativeExportOnly';value=$false},@{field='nativeExportOnly';value='true'},
      @{field='pickerNavigationOnly';value=$false},@{field='pickerNativeFilenameOnly';value=$false},
      @{field='pickerNativeFilenameReadbackOnly';value=$true},@{field='pickerStructureOnly';value=$true},
      @{field='bindings';value=@()},@{field='nativeFilenameQualification';value=@{path='C:\foreign.json';sha256=('A'*64)}})){
    $invalid=$exportPlan|ConvertTo-Json -Depth 15|ConvertFrom-Json
    $invalid|Add-Member -NotePropertyName $change.field -NotePropertyValue $change.value -Force
    $caught=$null;try{Assert-CardsNativeExportQualification $invalid $qualification}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Single native Save admitted plan/qualification drift: $($change.field)"}
  }
  foreach($change in @(@{field='case';value='zip-picker-native-filename-readback-cancel-observation'},
      @{field='actualQualifications';value=0},@{field='transferEffects';value=1},@{field='ownedFolderView';value=$false},
      @{field='graphUnchanged';value=$false},@{field='markerCustodyVerified';value=$false},
      @{field='absentFullAndStemOutputs';value=3},@{field='strictExportMenuAndCancel';value=$false},
      @{field='ownedJobCleanupVerified';value=$false},@{field='exactDpiRestoreVerified';value=$false},
      @{field='sourceBindingsVerifiedAtEnd';value=0},@{field='inputDisposition.chordCallsCompleted';value=1},
      @{field='inputDisposition.possiblyHeldModifierUnresolved';value=$true},@{field='inputDisposition.policyInputBarrier';value=$true},
      @{field='driver.gateExit';value=1},@{field='driver.sourceUnchanged';value=$false},
      @{field='driver.defaultProfilesUnchanged';value=$false},@{field='driver.driverOwnedCleanup';value=$false},
      @{field='driver.failure';value='failure'},@{field='driver.cleanupFailures';value=@('failure')},
      @{field='nativeFilename.basename';value='..\other.zip'},@{field='nativeFilename.initialSuggestedBasename';value='other.zip'},
      @{field='nativeFilename.exactFocus';value=$false},@{field='nativeFilename.childReadbackExact';value=$false},
      @{field='nativeFilename.hostReadbackExact';value=$false},@{field='nativeFilename.readbackSamples';value=0},
      @{field='nativeFilename.typedChannels.uiaHostMatchesSuggested';value=$false},
      @{field='nativeFilename.typedEvents';value=97},@{field='nativeFilename.enterEvents';value=2},
      @{field='nativeFilename.inputReplays';value=1})){
    $invalid=Copy-CardsContractGraph $qualification;$parts=$change.field.Split('.');$target=$invalid
    for($i=0;$i -lt $parts.Count-1;$i++){$target=$target[$parts[$i]]}
    $target[$parts[-1]]=$change.value
    $caught=$null;try{Assert-CardsNativeExportQualification $exportPlan $invalid}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Single native Save admitted incomplete prior qualification: $($change.field)"}
  }
  $exportObservation=@{processId=123;picker=300;folderContainmentEstablished=$true;markerView=$view
    nativeFilename=@{rootRuntime='root';control=500;runtime='edit';hostRuntime='host';basename=$filenameState.buffer
      inputReplays=0;enterEvents=0;fullAndStemCandidatesAbsent=4}}
  Assert-CardsNativeExportReady $exportObservation $filenameState $readyChannels $view 'D:\owned\picker' $filenameState.buffer
  foreach($change in @(@{field='focusedHandle';value=0},@{field='nativeOwned';value=$false},
      @{field='nativeProcessId';value=124},@{field='rootProcessId';value=124},
      @{field='runtime';value='recreated'},@{field='hostBuffer';value='wrong.zip'})){
    $invalid=$filenameState.Clone();$invalid[$change.field]=$change.value;$caught=$null
    try{Assert-CardsNativeExportReady $exportObservation $invalid $readyChannels $view 'D:\owned\picker' $filenameState.buffer}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Pre-Save native focus, identity or exact full-name readback was weakened'}
  }
  $saveSample=$fieldSample.Clone();$saveSample.controlId=1;$saveSample.controlClass='Button'
  if(-not (Test-CardsPickerCancelReady $saveSample $saveSample 123 100 300 1) -or
      (Test-CardsPickerCancelReady $saveSample $saveSample 123 100 300)){
    throw 'Save-button readiness lost explicit ID1 or changed the default Cancel ID2'}
  foreach($change in @(@{field='control';value=501},@{field='controlId';value=2},
      @{field='controlClass';value='Edit'},@{field='hitViable';value=$false},
      @{field='controlBounds';value=@(32,32,52,52)},@{field='rootProcessId';value=124})){
    $invalid=$saveSample.Clone();$invalid[$change.field]=$change.value
    if(Test-CardsPickerCancelReady $saveSample $invalid 123 100 300 1){
      throw 'Native Save readiness admitted recreation, movement, occlusion or wrong ID/PID/class'}
  }
  foreach($change in @(@{field='processId';value=124},@{field='picker';value=301},
      @{field='folderContainmentEstablished';value=$false},@{field='nativeFilename.rootRuntime';value='recreated'},
      @{field='nativeFilename.control';value=501},@{field='nativeFilename.runtime';value='recreated'},
      @{field='nativeFilename.hostRuntime';value='recreated'},@{field='nativeFilename.basename';value='other.zip'},
      @{field='nativeFilename.inputReplays';value=1},@{field='nativeFilename.enterEvents';value=2},
      @{field='nativeFilename.fullAndStemCandidatesAbsent';value=3})){
    $invalid=Copy-CardsContractGraph $exportObservation;$parts=$change.field.Split('.');$target=$invalid
    for($i=0;$i -lt $parts.Count-1;$i++){$target=$target[$parts[$i]]}
    $target[$parts[-1]]=$change.value
    $caught=$null
    try{Assert-CardsNativeExportReady $invalid $filenameState $readyChannels $view 'D:\owned\picker' $filenameState.buffer}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Pre-Save original observation drift was admitted: $($change.field)"}
  }
  $inputObservation=Copy-CardsContractGraph $exportObservation
  $inputObservation.nativeFilename.fullAndStemCandidatesAbsent=3
  $inputObservation.nativeFilename.ownedExistingArchiveVerified=$true
  $inputObservation.nativeFilename.importing=$true
  $inputObservation.nativeFilename.outer=Copy-CardsContractGraph $openFilenameState.outer
  Assert-CardsNativeExportReady $inputObservation $openFilenameState $readyChannels $view 'D:\owned\picker' $filenameState.buffer $true
  Assert-CardsNativeExportReady $inputObservation $openEmptyNativeHost $openSemantic $view 'D:\owned\picker' $filenameState.buffer $true
  foreach($change in @(@{field='importing';value=$false},@{field='outer.runtime';value='recreated'},
      @{field='outer.nativeWindow';value=441})){
    $invalid=Copy-CardsContractGraph $inputObservation;$parts=$change.field.Split('.');$target=$invalid.nativeFilename
    for($i=0;$i -lt $parts.Count-1;$i++){$target=$target[$parts[$i]]}
    $target[$parts[-1]]=$change.value;$caught=$null
    try{Assert-CardsNativeExportReady $invalid $openFilenameState $readyChannels $view 'D:\owned\picker' $filenameState.buffer $true}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open primary readiness lost original operation/outer identity'}
  }
  $caught=$null
  try{Assert-CardsNativeExportReady $inputObservation $filenameState $readyChannels $view 'D:\owned\picker' $filenameState.buffer $true}catch{$caught=$_.Exception}
  if($caught -isnot [InvalidOperationException]){throw 'Open primary readiness admitted the Save field state'}
  $inputObservation.nativeFilename.ownedExistingArchiveVerified=$false;$caught=$null
  try{Assert-CardsNativeExportReady $inputObservation $openFilenameState $readyChannels $view 'D:\owned\picker' $filenameState.buffer $true}catch{$caught=$_.Exception}
  if($caught -isnot [InvalidOperationException]){throw 'Open primary readiness lost existing archive custody authority'}
  foreach($change in @(@{field='runtime';value='new-view'},@{field='markerRuntime';value='new-marker'},
      @{field='processId';value=124},@{field='markerCount';value=0},@{field='markerCount';value=2},
      @{field='nativeOwned';value=$false},@{field='markerProcessId';value=124})){
    $invalid=$view.Clone();$invalid[$change.field]=$change.value;$caught=$null
    try{Assert-CardsNativeExportReady $exportObservation $filenameState $readyChannels $invalid 'D:\owned\picker' $filenameState.buffer}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Pre-Save current view changed: $($change.field)"}
  }
  foreach($field in @('uiaHostValueAvailable','uiaHostMatchesSuggested','uiaHostMatchesChild')){
    $invalid=[ordered]@{};foreach($key in $readyChannels.Keys){$invalid[$key]=$readyChannels[$key]}
    $invalid[$field]=$false;$caught=$null
    try{Assert-CardsNativeExportReady $exportObservation $filenameState $invalid $view 'D:\owned\picker' $filenameState.buffer}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Pre-Save semantic full-name authority was weakened'}
  }
  if(-not (Test-CardsPickerNativeFilenameReady $filenameState $filenameState.buffer $readyChannels)){
    throw 'Exact native and semantic wanted-name readback was not ready'}
  $prefixState=$filenameState.Clone();$prefixState.buffer='cards-';$prefixState.hostBuffer='cards-'
  $prefixChannels=Get-CardsPickerFilenameReadbackMetadata 'cards-' 'cards-' 'cards-' $true $filenameState.buffer
  if(Test-CardsPickerNativeFilenameReady $prefixState $filenameState.buffer $prefixChannels){
    throw 'A pending native prefix was accepted as the full requested basename'}
  $delayed=@{samples=0}
  $ready=Wait-CardsPilotState {
    $delayed.samples++
    $sample=if($delayed.samples -lt 3){$prefixState}else{$filenameState}
    $channels=if($delayed.samples -lt 3){$prefixChannels}else{$readyChannels}
    if(Test-CardsPickerNativeFilenameReady $sample $filenameState.buffer $channels){return $true};return $null
  } 'headless delayed native filename readback' 500
  if(-not $ready -or $delayed.samples -ne 3){throw 'Native filename readiness did not execute delayed read-only samples'}
  foreach($badValue in @('other.zip','D:\foreign.zip','cards-other.zip')){
    $invalid=$filenameState.Clone();$invalid.buffer=$badValue;$invalid.hostBuffer=$badValue;$caught=$null
    try{$null=Test-CardsPickerNativeFilenameReady $invalid $filenameState.buffer $readyChannels}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Native filename readiness tolerated unexpected non-prefix bytes'}
  }
  foreach($field in @('focusedHandle','handle','nativeProcessId','rootProcessId','expectedPicker','expectedRuntime')){
    $invalid=$prefixState.Clone();$invalid[$field]=0;$caught=$null
    try{$null=Test-CardsPickerNativeFilenameReady $invalid $filenameState.buffer $prefixChannels}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Pending readback hid native ownership/focus/recreation failure'}
  }
  $missingSemantic=[ordered]@{};foreach($key in $prefixChannels.Keys){$missingSemantic[$key]=$prefixChannels[$key]}
  $missingSemantic.uiaHostValueAvailable=$false;$caught=$null
  try{$null=Test-CardsPickerNativeFilenameReady $prefixState $filenameState.buffer $missingSemantic}catch{$caught=$_.Exception}
  if($caught -isnot [InvalidOperationException]){throw 'Pending readback concealed unavailable semantic authority'}
  $pending=@{samples=0};$caught=$null
  try{
    $null=Wait-CardsPilotState {
      $pending.samples++
      if(Test-CardsPickerNativeFilenameReady $prefixState $filenameState.buffer $prefixChannels){return $true};return $null
    } 'headless native filename incomplete readback' 20
  }catch{$caught=$_.Exception}
  if($pending.samples -le 0 -or $null -eq $caught -or $caught.Message -notlike '*CARDS_PILOT_TIMEOUT:*'){
    throw 'Incomplete native readback did not preserve the bounded timeout'}
  foreach($change in @(@{field='nativeClass';value='Other'},@{field='hostNativeClass';value='Other'},
      @{field='hostClass';value='Other'},@{field='hostRole';value='ControlType.Button'},@{field='hostNativeOwned';value=$false},
      @{field='focusedHandle';value=501},@{field='expectedHandle';value=501},
      @{field='nativeProcessId';value=124},@{field='rootProcessId';value=124},
      @{field='picker';value=301},@{field='rootRuntime';value='recreated'},
      @{field='rootClass';value='Other'},@{field='rootVisible';value=$false},
      @{field='rootEnabled';value=$false},@{field='role';value='ControlType.Button'},
      @{field='buffer';value='loop.zip'},@{field='hostBuffer';value='loop.zip'})){
    $invalid=$filenameState.Clone();$invalid[$change.field]=$change.value;$caught=$null
    try{Assert-CardsPickerNativeFilenameValue $invalid $filenameState.buffer}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Native filename value admitted $($change.field)"}
  }
  $openAddress=(Get-Command Open-CardsPickerAddress).ScriptBlock.ToString()
  $nativeFilename=(Get-Command Invoke-CardsPickerNativeFilename).ScriptBlock.ToString()
  if(-not $nativeFilename.Contains('hostReadbackExact=$typedMetadata.channels.nativeHostMatchesSuggested') -or
      -not $nativeFilename.Contains('semanticHostReadbackExact=$typedMetadata.channels.uiaHostMatchesSuggested')){
    throw 'Native filename receipt conflates native host WM_GETTEXT equality with semantic host equality'}
  $nativeExport=(Get-Command Invoke-CardsZipExportCase).ScriptBlock.ToString()
  $nativePrimary=(Get-Command Read-CardsNativePrimaryReady).ScriptBlock.ToString()
  $nativeImport=(Get-Command Invoke-CardsZipNativeImportCase).ScriptBlock.ToString()
  $nativePilot=(Get-Command Invoke-CardsNativePilot).ScriptBlock.ToString()
  $structureProjection=(Get-Command Select-CardsPickerFilenameStructure).ScriptBlock.ToString()
  if($nativePilot.IndexOf('Assert-CardsPickerImportStructurePlan') -gt $nativePilot.IndexOf('New-ShellProcessScope') -or
      -not $filename.Contains('return Select-CardsPickerFilenameStructure') -or
      $filename.IndexOf('return Select-CardsPickerFilenameStructure') -ge $filename.IndexOf('$value.SetValue($path)') -or
      $structureProjection -match '\.Name|\.Value|::(Send|Click|Set|Focus|Activate)' -or
      -not $structureProjection.Contains('Select-CardsPickerAddressBand')){
    throw 'Open structure mode lost pre-process guard, original bounded raw scope, no-value privacy or no-input return'}
  $nativeBranch=$zipCases.Substring($zipCases.IndexOf('if($nativeExportOnly){'),
    $zipCases.IndexOf('$walker =')-$zipCases.IndexOf('if($nativeExportOnly){'))
  if(-not $nativeBranch.Contains('return') -or
      $nativeBranch.Contains('Click-CardsPilotControl') -or
      -not $zipCases.Contains("if ($plan.kind -ceq 'cards-zip-filename-observation') { return }") -or
      $nativePilot.IndexOf('Assert-CardsNativeExportQualification') -gt $nativePilot.IndexOf('New-ShellProcessScope') -or
      -not $nativePrimary.Contains('Wait-CardsPickerCancelReady $process $window $picker $clock 1') -or
      -not $nativeExport.Contains('Click-CardsPilotControl $process $picker 1 ([IntPtr]$ready.control)') -or
      $nativeExport.IndexOf('Read-CardsNativePrimaryReady') -gt $nativeExport.IndexOf('Click-CardsPilotControl') -or
      -not $nativePrimary.Contains('Assert-CardsNativeExportReady') -or
      -not $nativePrimary.Contains('Assert-CardsPickerNativeFileScope') -or
      $nativeExport.Contains('SendKeyInput') -or $nativeExport.Contains('SendUnicodeInput') -or
      $nativeExport.Contains('ValuePattern') -and $nativeExport.Contains('.SetValue(') -or
      -not $nativeExport.Contains("StartsWith('.graphcode-card-export-'") -or
      -not $nativeExport.Contains("StartsWith('graphcode-export-'") -or
      -not $nativeExport.Contains('$archives.Count -eq 1') -or
      -not $nativeExport.Contains('$clock.ElapsedMilliseconds -lt 15000')){
    throw 'Single native export lost its separate return, pre-Save proof, unchanged strict pointer, no-input-readback or original deadline'}
  if(-not $zipCases.Contains('Invoke-CardsZipNativeImportCase') -or
      $nativePilot.IndexOf('Assert-CardsNativeImportQualification') -gt $nativePilot.IndexOf('New-ShellProcessScope') -or
      -not $nativeImport.Contains('Read-CardsNativePrimaryReady') -or
      -not $nativeImport.Contains('Click-CardsPilotControl $process $picker 1 ([IntPtr]$ready.control)') -or
      -not $nativeImport.Contains('$source.nodes[0]') -or
      -not $nativeImport.Contains('Assert-CardsPilotNoMutation $expectedRoot') -or
      -not $nativeImport.Contains('Assert-CardsPickerNativeFileScope') -or
      -not $nativeImport.Contains('$clock.ElapsedMilliseconds -lt 15000') -or
      $nativeImport -match '\.SetValue\(|SendKeyInput|SendUnicodeInput' -or
      $nativePrimary -match '\.SetValue\(|SendKeyInput|SendUnicodeInput|Click-CardsPilotControl'){
    throw 'Single native import lost original pointer/budget, pre-Open ownership/containment, target custody or source payload separation'}
  if(-not $nativeFilename.Contains("Properties['pickerNativeFilenameReadbackOnly']")){
    throw 'Missing distinct bounded native filename readback-only diagnosis before any clear/type'}
  $readback=Get-CardsPickerFilenameReadbackMetadata 'loop.zip' '' 'loop.zip' $true 'loop.zip'
  if(-not $readback.childMatchesSuggested -or -not $readback.nativeHostEmpty -or
      $readback.nativeHostMatchesSuggested -or -not $readback.uiaHostMatchesSuggested -or
      $readback.childLength -ne 8 -or $readback.nativeHostLength -ne 0){
    throw 'Filename readback metadata conflated native host text with child/provider value'}
  $fullChannels=Get-CardsPickerFilenameReadbackMetadata 'loop.zip' 'loop.zip' 'loop.zip' $true 'loop.zip'
  $stemChannels=Get-CardsPickerFilenameReadbackMetadata 'loop' 'loop' 'loop' $true 'loop.zip'
  if((Assert-CardsPickerInitialFilename 'loop.zip' 'loop.zip' 'loop.zip' $fullChannels) -cne 'fullSuggested' -or
      (Assert-CardsPickerInitialFilename 'loop' 'loop' 'loop.zip' $stemChannels) -cne 'sourceStem'){
    throw 'Initial filename does not accept only the full source suggestion or its exact measured stem'}
  foreach($values in @(@('other.zip','other.zip'),@('loop.zip.zip','loop.zip.zip'),
      @('LOOP','LOOP'),@('loop','loop.zip'),@('D:\own\loop.zip','D:\own\loop.zip'),
      @('',''),@('lo','lo'))){
    $channels=Get-CardsPickerFilenameReadbackMetadata $values[0] $values[1] $values[0] $true 'loop.zip'
    $caught=$null;try{$null=Assert-CardsPickerInitialFilename $values[0] $values[1] 'loop.zip' $channels}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Initial source alias accepted another name/path/case/truncation or host mismatch'}
  }
  foreach($change in @(@{field='uiaHostValueAvailable';value=$false},@{field='uiaHostMatchesChild';value=$false})){
    $channels=[ordered]@{};foreach($key in $stemChannels.Keys){$channels[$key]=$stemChannels[$key]}
    $channels[$change.field]=$change.value;$caught=$null
    try{$null=Assert-CardsPickerInitialFilename 'loop' 'loop' 'loop.zip' $channels}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Initial source alias dropped advertised host semantic agreement'}
  }
  $outputRoot=Join-Path $ArtifactRoot ('native-output-candidates-'+[Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($outputRoot)|Out-Null
  if((Assert-CardsPickerAbsentOutputs $outputRoot 'wanted.zip' 'loop.zip') -ne 4){
    throw 'Owned full/default/stem output set is incomplete'}
  foreach($name in @('wanted.zip','wanted','loop.zip','loop')){
    $candidate=Join-Path $outputRoot $name
    [IO.File]::WriteAllText($candidate,'owned negative fixture')
    try{
      $caught=$null;try{$null=Assert-CardsPickerAbsentOutputs $outputRoot 'wanted.zip' 'loop.zip'}catch{$caught=$_.Exception}
      if($caught -isnot [InvalidOperationException]){throw 'An existing potential output failed to block native filename/Save'}
    }finally{[IO.File]::Delete($candidate)}
  }
  foreach($badName in @('..\wanted.zip','D:\foreign.zip','loop.zip','a .zip')){
    $caught=$null;try{$null=Assert-CardsPickerAbsentOutputs $outputRoot $badName 'loop.zip'}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Output candidates admitted escape, alias collision or trailing-space ambiguity'}
  }
  $inputRoot=Join-Path $ArtifactRoot ('native-owned-input-'+[Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($inputRoot)|Out-Null
  $inputPath=Join-Path $inputRoot 'wanted.zip'
  [IO.File]::WriteAllText($inputPath,'known owned archive custody fixture, not a ZIP content test')
  $inputSha=(Get-FileHash $inputPath -Algorithm SHA256).Hash
  if((Assert-CardsPickerOwnedInput $inputRoot 'wanted.zip' 'loop.zip' $inputSha) -ne 3){
    throw 'Native input must prove one existing exact-hash file and three absent alternatives'}
  foreach($name in @('wanted','loop.zip','loop')){
    $path=Join-Path $inputRoot $name;[IO.File]::WriteAllText($path,'owned alternative negative')
    try{
      $caught=$null;try{$null=Assert-CardsPickerOwnedInput $inputRoot 'wanted.zip' 'loop.zip' $inputSha}catch{$caught=$_.Exception}
      if($caught -isnot [InvalidOperationException]){throw 'Native input accepted an ambiguous stem/default candidate'}
    }finally{[IO.File]::Delete($path)}
  }
  foreach($name in @('..\wanted.zip','C:\other.zip','loop.zip','a .zip')){
    $caught=$null;try{$null=Assert-CardsPickerOwnedInput $inputRoot $name 'loop.zip' $inputSha}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Native input accepted escape, name ambiguity or a missing file'}
  }
  foreach($text in @('','changed archive bytes')){
    [IO.File]::WriteAllText($inputPath,$text);$caught=$null
    try{$null=Assert-CardsPickerOwnedInput $inputRoot 'wanted.zip' 'loop.zip' $inputSha}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Native input accepted empty/replaced/changed archive bytes'}
  }
  [IO.File]::Delete($inputPath)
  [IO.Directory]::CreateDirectory($inputPath)|Out-Null
  try{
    $caught=$null;try{$null=Assert-CardsPickerOwnedInput $inputRoot 'wanted.zip' 'loop.zip' $inputSha}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Native input accepted a directory instead of the archive'}
  }finally{[IO.Directory]::Delete($inputPath)}
  foreach($initial in @('','wanted','wanted.zip')){
    $channels=Get-CardsPickerFilenameReadbackMetadata $initial $initial $initial $true 'wanted.zip'
    $null=Assert-CardsPickerInitialImportFilename $initial $initial 'wanted.zip' $channels
  }
  foreach($initial in @('foreign.zip','loop.zip','want','WANTED.ZIP','C:\private.zip')){
    $channels=Get-CardsPickerFilenameReadbackMetadata $initial $initial $initial $true 'wanted.zip';$caught=$null
    try{$null=Assert-CardsPickerInitialImportFilename $initial $initial 'wanted.zip' $channels}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open initial name guard accepted foreign/path/default/case/truncation'}
  }
  foreach($field in @('uiaHostValueAvailable','uiaHostMatchesChild')){
    $channels=Get-CardsPickerFilenameReadbackMetadata '' '' '' $true 'wanted.zip';$channels[$field]=$false;$caught=$null
    try{$null=Assert-CardsPickerInitialImportFilename '' '' 'wanted.zip' $channels}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw 'Open initial name lost independent semantic agreement'}
  }
  foreach($values in @(@('loop','loop','loop.zip'),@('D:\foreign\private.zip','foreign','private'),@('','',''))){
    $metadata=Get-CardsPickerFilenameReadbackMetadata $values[0] $values[1] $values[2] $true 'loop.zip'
    $serialized=$metadata|ConvertTo-Json -Compress
    foreach($property in $metadata.Keys){
      if($metadata[$property] -isnot [bool] -and $metadata[$property] -isnot [int]){
        throw 'Filename diagnostic exposed text instead of booleans/counts'}
    }
    if($serialized.Contains('D:\foreign') -or $serialized.Contains('private')){
      throw 'Filename diagnostic leaked unowned text'}
  }
  if($nativeFilename -match 'ValuePattern|\.SetValue\(|SetEditText|FocusControl|ActivateWindow|0x0D|0x4C' -or
      -not $nativeFilename.Contains('Assert-CardsPickerNativeFilenameValue $state $basename') -or
      -not $nativeFilename.Contains('::ClickScreenPoint($edit)') -or
      -not $nativeFilename.Contains('$typed[0] -eq 2*$basename.Length') -or
      -not $nativeFilename.Contains('original owned folder/view changed') -or
      -not $zipCases.Contains('zip-picker-native-filename-cancel-qualification') -or
      -not $nativeFilename.Contains("$"+"plan.initialSuggestedBasename -ceq 'loop.zip'")){
    throw 'Native-primary filename lost strict input/counts/own-view/readback/default-name bounds or injected Enter/setter/activation'}
  $appSource=[IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\App.zig'))
  if(-not $appSource.Contains('std.unicode.utf8ToUtf16LeStringLiteral("loop.zip")')){
    throw 'Native suggested basename requires source-derived requalification'}
  $rawLookup=$navigation.IndexOf('$shape=Get-CardsPickerControlShape $process $picker')
  $rawSelection=$navigation.IndexOf('$bandRow=Select-CardsPickerAddressBand')
  if($rawLookup -lt 0 -or $rawSelection -le $rawLookup -or
      -not $navigation.Substring($rawLookup,$rawSelection-$rawLookup).Contains('Get-CardsPickerNavigationBudget') -or
      -not $navigation.Contains('expectedBandNativeClass=$bandRow.nativeClass') -or
      $navigation.Contains('$bands=$dialog.FindAll')) {
    throw 'Address target bypassed the original bounded raw scope, observed native-class binding or expiry guard'
  }
  $checkChordPhases={
    param([string]$body)
    if ($body.IndexOf('$script:CardsPickerChordAttempts++') -lt 0 -or
        $body.IndexOf('$script:CardsPickerChordAttempts++') -gt $body.IndexOf('::SendKeyInput(') -or
        $body.IndexOf('$script:CardsPickerChordCompletions++') -lt $body.IndexOf('::SendKeyInput(') -or
        $body.Contains('finally')) { throw 'Chord phase counters can hide an attempted/unknown input call' }
  }
  & $checkChordPhases $openAddress
  foreach($mutant in @(
      $openAddress.Replace('$script:CardsPickerChordAttempts++',''),
      ('$script:CardsPickerChordCompletions++;'+$openAddress.Replace('$script:CardsPickerChordCompletions++','')),
      ($openAddress+'; finally { $script:CardsPickerChordCompletions++ }'))) {
    $caught=$null
    try { & $checkChordPhases $mutant } catch { $caught=$_.Exception }
    if ($null -eq $caught) { throw 'Chord phase source-negative control was admitted' }
  }
  foreach($required in @('beforeRawWalk','afterRawWalk','rawCandidates','nativeClass','isControlElement',
      'class=UIA.ClassName; nativeClass=GetClassName')) {
    if(-not $shapeReader.Contains($required)){throw "Missing bounded selector field-meaning/readiness evidence: $required"}
  }
  if ($navigation -match 'SetValue\(|SetEditText|FocusControl|ActivateWindow|::SendInput\(' -or
      -not $navigation.Contains('Assert-CardsPickerAddressEnter $submitted $ownPath') -or
      $navigation.IndexOf('Assert-CardsPickerAddressEnter $submitted $ownPath') -gt
        $navigation.IndexOf('$edit,0x0D,1') -or
      -not $navigation.Contains('Assert-CardsPickerFolderView $view $ownPath') -or
      -not $openAddress.Contains('$focus,0x4C,1,$true') -or
      -not $filename.Contains('return Invoke-CardsPickerNavigation') -or
      $filename.IndexOf('return Invoke-CardsPickerNavigation') -ge $filename.IndexOf('$value.SetValue($path)') -or
      -not $zipCases.Contains('zip-picker-navigation-cancel-qualification') -or
      -not $zipCases.Contains('$currentReady.control -eq $ready.control') -or
      -not $source.Contains("possiblyHeldModifierUnresolved")) {
    throw 'Navigation lost original guarded native input, before-Enter readback, Cancel-only boundary or unresolved-modifier barrier'
  }
  $expected='Exported the selected loop. Embedded descendants may not carry all memory or session history.'
  if (-not (Test-CardsZipTransferStatus $expected $expected) -or
      (Test-CardsZipTransferStatus 'Exporting loop to ZIP...' $expected)) {
    throw 'Normal transfer status predicate changed its completion/pending contract'
  }
  $caught=$null
  try {
    $null=Test-CardsZipTransferStatus `
      'Export commit did not report success (Win32 87). Check the destination. Export staging retained at private-test-path' $expected
  } catch { $caught=$_.Exception }
  if ($caught -isnot [InvalidOperationException] -or
      $caught.Message -notlike 'CARDS_PILOT_ZIP:*Win32 87*' -or
      $caught.Message.Contains('private-test-path') -or
      $caught.Data['NativeErrorCode'] -ne 87) {
    throw 'Explicit App commit error was timed out, obscured or leaked its staging path'
  }
  foreach ($required in @('cards-zip-pilot','Invoke-CardsZipCases','Assert-CardsZipFixture',
      'Assert-CardsZipImport','FileNameControlHost','ValuePattern','zip-picker-cancel',
      'zip-save-export','zip-open-import','graph-snapshot.json',
      'Windows MRU/recent state is outside the GraphCode profile fingerprint')) {
    if (-not $source.Contains($required)) { throw "Missing bounded ZIP slice source: $required" }
  }
  $picker=[IO.File]::ReadAllText((Join-Path $RepositoryRoot 'graphcode-windows\src\FilePicker.c'))
  if (-not $picker.Contains('FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR')) {
    throw 'Requalify the native ZIP picker options and MRU evidence limits'
  }
  if(-not $picker.Contains('SetDefaultExtension(dialog, L"zip")') -or -not $picker.Contains('FOS_STRICTFILETYPES')){
    throw 'Suggested-name display alias requires source-derived ZIP default extension and strict file type'}
  $gateState=[IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Ui\Production\GraphCodeUiaGateState.cs'))
  $loaderPath=Join-Path $RepositoryRoot 'Tools\windows\Import-CompiledValidationAssembly.ps1'
  $loaderAst=[Management.Automation.Language.Parser]::ParseFile($loaderPath,[ref]$null,[ref]$null)
  $provenance=$loaderAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -ceq 'Assert-CompiledUiaProviderProvenance'},$true)
  if ($null -eq $provenance) { throw 'Normal UIA initialization lacks explicit provider provenance controls' }
  . ([scriptblock]::Create($provenance.Extent.Text))
  $valid=@{ expectedPath='C:\owned\UIAutomationClientsideProviders.dll'
    loadedPath='C:\OWNED\UIAutomationClientSideProviders.dll'
    name='UIAutomationClientSideProviders'; version='10.0.0.0'; clientVersion='10.0.0.0'
    fileVersion='10.0.14'; clientFileVersion='10.0.14'; token='B77A5C561934E089'
    signature='Valid'; signer='CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    fileMvid='11111111-1111-4111-8111-111111111111'; loadedMvid='11111111-1111-4111-8111-111111111111'
    fileHash=('A'*64); loadedHash=('A'*64); reference=$false
    publicEntry='UIAutomationClientsideProviders.UIAutomationClientSideProviders' }
  Assert-CompiledUiaProviderProvenance $valid
  foreach ($mutation in @(
      @{field='loadedPath';value=''},@{field='loadedPath';value='C:\foreign\UIAutomationClientsideProviders.dll'},
      @{field='name';value='WindowsBase'},@{field='version';value='9.0.0.0'},
      @{field='fileVersion';value='10.0.13'},@{field='token';value='BAD'},
      @{field='signature';value='NotSigned'},@{field='signer';value='Untrusted'},
      @{field='loadedMvid';value='22222222-2222-4222-8222-222222222222'},
      @{field='loadedHash';value=('B'*64)},@{field='reference';value=$true},
      @{field='publicEntry';value=''})) {
    $invalid=$valid.Clone(); $invalid[$mutation.field]=$mutation.value; $caught=$null
    try { Assert-CompiledUiaProviderProvenance $invalid } catch { $caught=$_.Exception }
    if ($caught -isnot [InvalidOperationException] -or $caught.Message -notlike 'UIA provider provenance:*') {
      throw "Provider provenance did not retain an explicit error for $($mutation.field)"
    }
  }
  $readbackSource=(Get-Command Read-CardsPickerFilenameMetadata).ScriptBlock.ToString()
  $typedPollStart=$nativeFilename.IndexOf('$typedReady=Wait-CardsPilotState')
  $typedPollEnd=$nativeFilename.IndexOf('}finally{',$typedPollStart)
  if($typedPollStart -lt 0 -or $typedPollEnd -le $typedPollStart -or
      $nativeFilename.Substring($typedPollStart,$typedPollEnd-$typedPollStart) -match '::(Send|Click|Set|Focus|Activate)' -or
      -not $nativeFilename.Substring($typedPollStart,$typedPollEnd-$typedPollStart).Contains('Get-CardsPickerNavigationBudget') -or
      ([regex]::Matches($nativeFilename,'::SendUnicodeInput\(')).Count -ne 1){
    throw 'Typed readback readiness replays input or loses the original budget'}
  $readbackStart=$nativeFilename.IndexOf("Properties['pickerNativeFilenameReadbackOnly']")
  $firstSelection=$nativeFilename.IndexOf('::SelectAll(')
  if($readbackStart -lt 0 -or $firstSelection -le $readbackStart -or
      -not $nativeFilename.Substring($readbackStart,$firstSelection-$readbackStart).Contains('return [ordered]@{') -or
      -not $zipCases.Contains('zip-picker-native-filename-readback-cancel-observation') -or
      $readbackSource -match '\.SetValue\(|::(Send|Click|Set|Focus|Activate)' -or
      -not $readbackSource.Contains('GetSupportedPatterns()') -or
      -not $readbackSource.Contains('$value.Current.Value')){
    throw 'Readback-only diagnosis lost its no-clear/type return, private getter distinction or explicit diagnostic label'}
  if (-not $gateState.Contains('RegisterClientSideProviderAssembly(System.Reflection.AssemblyName assemblyName)') -or
      -not $gateState.Contains('System.Runtime.CompilerServices.MethodImplOptions.NoInlining')) {
    throw 'Normal UIA proxy registration requires a compiled non-dynamic caller for WPF stack inspection'
  }
  & (Join-Path $RepositoryRoot 'Tools\windows\Import-CompiledValidationAssembly.ps1') `
    -AssemblyPath $AssemblyPath -RequiredType 'GraphCodeUiaGateState' | Out-Null
  $method=[GraphCodeUiaGateState].GetMethod('RegisterClientSideProviderAssembly')
  if (-not $method.GetMethodImplementationFlags().HasFlag([Reflection.MethodImplAttributes]::NoInlining)) {
    throw 'The compiled proxy caller can be inlined back into a dynamic PowerShell frame'
  }
  foreach ($name in @($null,[Reflection.AssemblyName]::new('GraphCodeMissingClientProviders'),
      [System.Windows.Rect].Assembly.GetName())) {
    $caught=$null
    try { [GraphCodeUiaGateState]::RegisterClientSideProviderAssembly($name) }
    catch { $caught=$_.Exception.GetBaseException() }
    if ($null -eq $caught -or $caught -is [NullReferenceException]) {
      throw 'Missing/wrong proxy registration component was admitted or failed in a dynamic caller'
    }
    if ($null -eq $name -and $caught -isnot [ArgumentNullException]) {
      throw 'Null registration argument did not retain its actual argument error'
    }
  }
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$null,[ref]$null)
  $pilot=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -ceq 'Invoke-CardsNativePilot'},$true).Body.Extent.Text
  foreach ($required in @('$zipSlice -and $plan.caseCount -eq 3',
      '$plan.desktopReservation.announced -eq $true','one three-case ZIP batch',
      'Invoke-CardsZipCases','requestedCases = $plan.caseCount')) {
    if (-not $pilot.Contains($required)) { throw "Missing gated ZIP entry: $required" }
  }
  if ($pilot.IndexOf('$plan.desktopReservation.announced') -ge $pilot.IndexOf('Start-ShellOwnedProcess')) {
    throw 'ZIP reservation must be checked before native process creation'
  }
  $zip=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -ceq 'Invoke-CardsZipCases'},$true).Body.Extent.Text
  $observationExit=$zip.IndexOf("if (`$plan.kind -ceq 'cards-zip-filename-observation') { return }")
  if ($observationExit -lt 0 -or $observationExit -gt $zip.IndexOf('Click-CardsPilotControl $process $picker 1')) {
    throw 'Cancel-only filename observation can reach Save/transfer dispatch'
  }
  if ($zip.Contains('Invoke-CardsPilotRetypeCase') -or -not $zip.Contains('Read-CardsZipQuiescence') -or
      -not $zip.Contains('15000 - [int]$clock.ElapsedMilliseconds')) {
    throw 'ZIP slice must not replay retypes or create a new retirement deadline'
  }
  $filename=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -ceq 'Set-CardsZipPath'},$true).Body.Extent.Text
  if ($filename.Contains("AutomationIdProperty,'1001'") -or
      -not $filename.Contains('CARDS_PILOT_ZIP_FILENAME_SHAPE=') -or
      -not $filename.Contains('::IsControlOwnedBy($picker,$handle,1001)') -or
      -not $filename.Contains('::WindowProcessId($handle) -eq $process.Id') -or
      -not $filename.Contains('rawFilenameChildren') -or
      -not $filename.Contains('GetSupportedPatterns()') -or
      -not $filename.Contains('5000 - [int]$fieldClock.ElapsedMilliseconds') -or
      -not $filename.Contains('TryGetCurrentPattern') -or
      $filename.Contains('ControlTypeProperty,[System.Windows.Automation.ControlType]::Edit')) {
    throw 'Discover the unique Edit within the exact filename host; retain native control1001/root/PID checks and sanitized shape evidence'
  }
}
Invoke-CardsContract 'ui.cards-pilot.zip-filename-identity' {
  $valid=@{ expectedProcessId=100; hostProcessId=100; processId=100; count=1
    handle=200; controlId=1001; class='Edit'; nativeOwned=$true
    hostRuntime='1,2'; expectedHostRuntime='1,2'; runtime='3,4'; expectedRuntime='3,4' }
  Assert-CardsZipFilenameIdentity $valid
  foreach ($mutation in @(
      @{field='hostProcessId';value=101},@{field='processId';value=101},
      @{field='count';value=2},@{field='handle';value=0},
      @{field='controlId';value=1002},@{field='class';value='SearchBox'},
      @{field='nativeOwned';value=$false},@{field='runtime';value='3,5'},
      @{field='hostRuntime';value='1,5'},@{field='runtime';value=''})) {
    $snapshot=$valid.Clone(); $snapshot[$mutation.field]=$mutation.value; $caught=$null
    try { Assert-CardsZipFilenameIdentity $snapshot } catch { $caught=$_.Exception }
    if ($null -eq $caught -or $caught.Message -notlike 'CARDS_PILOT_ZIP:*') {
      throw "Invalid owned filename identity admitted: $($mutation.field)"
    }
  }
}
Invoke-CardsContract 'ui.cards-pilot.zip-fixture-valid' {
  $data=New-CardsZipContractData
  $null=Assert-CardsZipFixture $data.root $data.containerId
}
Invoke-CardsContract 'ui.cards-pilot.zip-bare-goal-refused' {
  $data=New-CardsZipContractData
  $data.root.nodes[0].loopType='goalBased'
  Assert-CardsZipFixture $data.root $data.containerId
} $true
Invoke-CardsContract 'ui.cards-pilot.zip-import-valid' {
  $data=New-CardsZipContractData
  $result=Assert-CardsZipImport $data.before $data.after $nodeId $data.containerId $data.root.nodes[0]
  if ($result.directNodes -ne 3 -or $result.directEdges -ne 2 -or
      $result.recursiveNodes -ne 5 -or $result.recursiveEdges -ne 3) {
    throw 'Nested Composite import must not be reported as a flat three-node graph'
  }
  $source=Copy-CardsContractGraph $data.root.nodes[0]
  $source.id='CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC'
  $source.subGraph.id='DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD'
  $source.subGraph.nodes[0].id='EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE'
  $source.subGraph.nodes[1].id='FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF'
  $source.subGraph.nodes[1].createdBy=$source.subGraph.nodes[0].id
  $source.subGraph.edges[0].id='12121212-1212-4212-8212-121212121212'
  $source.subGraph.edges[0].from=$source.subGraph.nodes[0].id
  $source.subGraph.edges[0].to=$source.subGraph.nodes[1].id
  $source.subGraph.nodes[0].goal.summary='Exact exported source goal'
  $data.after.nodes[2].subGraph.nodes[0].goal.summary='Exact exported source goal'
  $result=Assert-CardsZipImport $data.before $data.after $nodeId $data.containerId $source
  if($result.identityMapping[$source.id] -cne $data.after.nodes[2].id){
    throw 'Import proof confused a prior owned archive source with the fresh target container'}
  foreach($mutation in @('source-parent-reused','source-child-reused','target-payload-substituted','source-edge-changed')){
    $changed=Copy-CardsContractGraph $data.after
    switch($mutation){
      'source-parent-reused' {$changed.nodes[2].id=$source.id;$changed.edges[1].to=$source.id}
      'source-child-reused' {$changed.nodes[2].subGraph.nodes[0].id=$source.subGraph.nodes[0].id}
      'target-payload-substituted' {$changed.nodes[2].subGraph.nodes[0].goal.summary=$data.before.nodes[0].goal.summary}
      'source-edge-changed' {$changed.nodes[2].subGraph.edges[0].kind='wrong'}
    }
    $caught=$null
    try{$null=Assert-CardsZipImport $data.before $changed $nodeId $data.containerId $source}catch{$caught=$_.Exception}
    if($caught -isnot [InvalidOperationException]){throw "Distinct archive import lost source identity/payload/topology proof: $mutation"}
  }
}
Invoke-CardsContract 'ui.cards-pilot.zip-flat-import-refused' {
  $data=New-CardsZipContractData
  $data.after.nodes[2].subGraph=$null
  Assert-CardsZipImport $data.before $data.after $nodeId $data.containerId $data.root.nodes[0]
} $true
Invoke-CardsContract 'ui.cards-pilot.zip-stale-identity-refused' {
  $data=New-CardsZipContractData
  $data.after.nodes[2].subGraph.nodes[0].id=$nodeId
  Assert-CardsZipImport $data.before $data.after $nodeId $data.containerId $data.root.nodes[0]
} $true
Invoke-CardsContract 'ui.cards-pilot.zip-custody-refused' {
  foreach ($mutation in @('existing','nested','parent-payload')) {
    $data=New-CardsZipContractData
    switch ($mutation) {
      'existing' { $data.after.nodes[1].createdBy=$data.containerId }
      'nested' { $data.after.nodes[2].subGraph.nodes[1].createdBy=$nodeId }
      'parent-payload' { $data.after.nodes[2].title='Changed imported Composite' }
    }
    $caught=$null
    try {
      $null=Assert-CardsZipImport $data.before $data.after $nodeId $data.containerId $data.root.nodes[0]
    } catch { $caught=$_.Exception }
    if ($null -eq $caught -or $caught.Message -notlike 'CARDS_PILOT_ZIP:*') {
      throw "Changed ZIP custody/payload admitted: $mutation"
    }
  }
}
Invoke-CardsContract 'ui.cards-pilot.zip-spawn-scope-refused' {
  $data=New-CardsZipContractData
  $data.after.edges[1].from=$peerId
  Assert-CardsZipImport $data.before $data.after $nodeId $data.containerId $data.root.nodes[0]
} $true
function New-CardsZipQuiescenceData {
  return @{
    total=6; active=1; activeMembers=@(100); expectedMembers=@(100)
    heldRootMember=$true; rootActive=$true; expectedBirth=123; observedBirth=123
    statusComplete=$true; effectVerified=$true; drainError=$false
  }
}
Invoke-CardsContract 'ui.cards-pilot.zip-quiescence-higher-total' {
  $result=Assert-CardsZipQuiescence (New-CardsZipQuiescenceData)
  if ($result.proofKind -cne 'LIVEQUIESCENCE' -or $result.rawTotal -ne 6 -or
      $result.retiredIdentityCoverage -cne 'UNOBSERVED') {
    throw 'ZIP quiescence must retain raw history without claiming original-root completion'
  }
}
foreach ($case in @(
    @{id='unknown-active'; field='activeMembers'; value=@(100,999)},
    @{id='gui-exited'; field='rootActive'; value=$false},
    @{id='wrong-birth'; field='observedBirth'; value=124},
    @{id='lost-job'; field='heldRootMember'; value=$false},
    @{id='unfinished-status'; field='statusComplete'; value=$false},
    @{id='missing-effect'; field='effectVerified'; value=$false},
    @{id='nonempty-unclassified'; field='active'; value=2},
    @{id='drain-error'; field='drainError'; value=$true}
  )) {
  Invoke-CardsContract ('ui.cards-pilot.zip-quiescence-' + $case.id) {
    $snapshot=New-CardsZipQuiescenceData
    $snapshot[$case.field]=$case.value
    if ($case.id -ceq 'unknown-active') { $snapshot.active=2 }
    Assert-CardsZipQuiescence $snapshot
  } $true
}
