param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
. (Join-Path $PSScriptRoot 'MixedPolicyContracts.ps1') -RepositoryRoot $RepositoryRoot `
  -ArtifactRoot $ArtifactRoot -AssemblyPath $AssemblyPath -ImportOnly
$renameClick = (New-MultiProjectRenameNativeApi).PSObject.Methods['Click'].Script
$focusMouse = (New-MultiProjectEditNativeApi).PSObject.Methods['FocusMouse'].Script
Assert-Mixed ($focusMouse.ToString().Contains('$this.FocusControl($modal,$edit)') -and
  $focusMouse.ToString() -notmatch '\[GraphCode[^\]]*\]::' -and
  $renameClick.ToString() -notmatch '\[GraphCode[^\]]*\]::') `
  'Production policy contains a non-injectable native operation; no mixed fake payload may execute'
function New-MixedRename {
  $controls=@{}
  foreach($id in @(9800,9808,9904)){
    $controls["$id"]=@{handle=[IntPtr]$id;processId=4242;id=$id;root=[IntPtr]42;visible=$true;enabled=$true;bounds=@(300,300,380,328)}
  }
  $controls['9904'].bounds=@(30,100,500,124)
  $api=[pscustomobject]@{
    state=@{modalPID=4242;title=("Rename "+[char]0x201c+'Alpha renamed'+[char]0x201d);visible=$true;enabled=$true
      client=@(10,40,600,400);work=@(0,0,1920,1080);foreground=$true;buffer='  Alpha renamed  ';secondBuffer='  Alpha renamed  '
      controls=$controls;hitRoot=[IntPtr]42;hitPID=4242;hitChild=[IntPtr]9800;late=$null;inputSent=2;inputExpected=2}
    inputCalls=0;bufferReads=0;hitReads=0;ExpectedTitle='';order=[Collections.Generic.List[string]]::new();requested=[Collections.Generic.List[int]]::new()
  }
  $api|Add-Member ScriptMethod ProcessId {param($window)$this.order.Add("PID:$window");if($window -eq [IntPtr]42){return $this.state.modalPID};return $this.state.controls["$window"].processId}
  $api|Add-Member ScriptMethod Title {param($window)$this.order.Add("TITLE:$window");return $this.state.title}
  $api|Add-Member ScriptMethod Visible {param($window)if($window -eq [IntPtr]42){return $this.state.visible};return $this.state.controls["$window"].visible}
  $api|Add-Member ScriptMethod Enabled {param($window)if($window -eq [IntPtr]42){return $this.state.enabled};return $this.state.controls["$window"].enabled}
  $api|Add-Member ScriptMethod Root {param($window)return $this.state.controls["$window"].root}
  $api|Add-Member ScriptMethod Control {
    param($window,$id)$this.requested.Add($id);$this.order.Add("CONTROL:$id")
    if(-not $this.state.controls.ContainsKey("$id")){return [IntPtr]::Zero};return $this.state.controls["$id"].handle
  }
  $api|Add-Member ScriptMethod ControlId {param($window)return $this.state.controls["$window"].id}
  $api|Add-Member ScriptMethod Bounds {param($window)return $this.state.controls["$window"].bounds}
  $api|Add-Member ScriptMethod ClientBounds {
    param($window)if($this.state.ContainsKey('staleClient') -and $this.state.staleClient){throw [ComponentModel.Win32Exception]::new(6,'controlled stale native client')};return $this.state.client
  }
  $api|Add-Member ScriptMethod WorkBounds {param($window)return $this.state.work}
  $api|Add-Member ScriptMethod Foreground {param($window)return $this.state.foreground}
  $api|Add-Member ScriptMethod Buffer {param($window,$id)$this.order.Add("BUFFER:$id");$this.bufferReads++;if($this.bufferReads -eq 1){return $this.state.buffer};return $this.state.secondBuffer}
  $api|Add-Member ScriptMethod Pause {if($this.state.late){& $this.state.late $this.state}}
  $api|Add-Member ScriptMethod Hit {
    param($window,$x,$y)$this.hitReads++
    if($this.state.ContainsKey('finalDrift') -and $this.hitReads -eq 2){& $this.state.finalDrift $this.state}
    $child=if($this.state.ContainsKey('coveredFirst') -and $this.state.coveredFirst -and $this.hitReads -eq 1){[IntPtr]9904}else{$this.state.hitChild}
    return @{root=$this.state.hitRoot;processId=$this.state.hitPID;child=$child}
  }
  $api|Add-Member ScriptMethod SendMouse {
    param($window,$point)$this.order.Add('INPUT:mouse');$this.inputCalls++
    return ,@($point[0],$point[1],($point[0]+1),($point[1]+1),$point[0],$point[1],$this.state.inputSent,$this.state.inputExpected)
  }
  $api|Add-Member ScriptMethod Click $renameClick
  return $api
}
function New-MixedEdit {
  $api=New-MixedRename
  $api|Add-Member NoteProperty Now ([long]0)
  $api|Add-Member NoteProperty LastFocusControlFallback $false
  $api|Add-Member NoteProperty LastFocusPostedFallback $false
  $api|Add-Member NoteProperty PhaseState @{
    buffer='Alpha renamed';selection=@(0,0);focus=[IntPtr]::Zero;clearCalls=0;unicodeCalls=0;deleteProcessed=$false
    clearPending=$false;observes=0;deleteDelay=3;focusClicks=0;focusPending=$false;focusObserves=0;focusDelay=1;focusSent=2
    neverFocus=$false;neverClear=$false;finalWrong=$false;clearSent=2;unicodeShort=$false;prefillReads=0;emptyReads=0;rebound=$false}
  $api.state.hitChild=[IntPtr]9904
  $api|Add-Member NoteProperty PhaseOrder ([Collections.Generic.List[string]]::new())
  $api|Add-Member ScriptMethod Clock {return $this.Now}
  $api|Add-Member ScriptMethod FocusInsertion {
    param($modal,$point)$this.PhaseOrder.Add('focus-insert');$this.PhaseState.focusClicks++;$this.PhaseState.focusPending=$true
    return ,@($point[0],$point[1],($point[0]+1),($point[1]+1),$point[0],$point[1],$this.PhaseState.focusSent,2)
  }
  $api|Add-Member ScriptMethod FocusMouse $focusMouse
  $api|Add-Member ScriptMethod FocusControl {
    param($modal,$edit)
    if(-not $this.PhaseState.ContainsKey('focusControlCalls')){$this.PhaseState.focusControlCalls=0}
    $this.PhaseState.focusControlCalls++
    if($this.PhaseState.ContainsKey('focusControlError')){throw $this.PhaseState.focusControlError}
    if($this.PhaseState.ContainsKey('focusControlResult')){return $this.PhaseState.focusControlResult}
    return $true
  }
  $api|Add-Member ScriptMethod FocusHandle {param($modal)return $this.PhaseState.focus}
  $api|Add-Member ScriptMethod EditBuffer {
    param($edit,$remaining)$this.PhaseState.prefillReads++
    if($this.PhaseState.buffer -ceq ''){$this.PhaseState.emptyReads++;if($this.PhaseState.rebound -and $this.PhaseState.emptyReads -eq 4){$this.PhaseState.buffer='Rebound'}}
    return $this.PhaseState.buffer
  }
  $api|Add-Member ScriptMethod Selection {param($edit,$remaining)return ,$this.PhaseState.selection}
  $api|Add-Member ScriptMethod SelectAll {
    param($edit,$remaining)$this.PhaseOrder.Add('select')
    $this.PhaseState.selection=if($this.PhaseState.ContainsKey('badSelection')){$this.PhaseState.badSelection}else{@(0,$this.PhaseState.buffer.Length)}
  }
  $api|Add-Member ScriptMethod Delete {$this.PhaseOrder.Add('clear-enqueue');$this.PhaseState.clearCalls++;$this.PhaseState.clearPending=$true;return ,@($this.PhaseState.clearSent,2)}
  $api|Add-Member ScriptMethod Unicode {
    param($text)
    if(-not $this.PhaseState.deleteProcessed -or $this.PhaseState.clearPending -or $this.PhaseState.buffer -cne '' -or $this.PhaseState.clearCalls -ne 1){throw 'Unicode before actual inert Delete transition'}
    $this.PhaseOrder.Add('unicode-enqueue');$this.PhaseState.unicodeCalls++
    $this.PhaseState.buffer=if($this.PhaseState.finalWrong){'lpha renamed'}else{$text}
    if($this.PhaseState.ContainsKey('unicodeDrift')){& $this.PhaseState.unicodeDrift $this}
    $count=2*$text.Length;$sent=if($this.PhaseState.unicodeShort){$count-1}else{$count};return ,@($sent,$count)
  }
  $api|Add-Member ScriptMethod Observe {
    param($remaining)$this.Now += [Math]::Min(25,$remaining);$this.PhaseState.observes++
    if($this.PhaseState.focusPending){
      $this.PhaseState.focusObserves++
      if(-not $this.PhaseState.neverFocus -and $this.PhaseState.focusObserves -ge $this.PhaseState.focusDelay){
        $this.PhaseState.focus=[IntPtr]9904;$this.PhaseState.focusPending=$false;$this.PhaseOrder.Add('focus-observed')
      }
    }
    if($this.PhaseState.clearPending -and -not $this.PhaseState.neverClear -and $this.PhaseState.observes -ge $this.PhaseState.deleteDelay){
      $this.PhaseState.buffer='';$this.PhaseState.selection=@(0,0);$this.PhaseState.clearPending=$false
      $this.PhaseState.deleteProcessed=$true;$this.PhaseOrder.Add('clear-processed')
      if($this.PhaseState.ContainsKey('clearDrift')){& $this.PhaseState.clearDrift $this}
    }
  }
  return $api
}
foreach($target in @('   ','Alpha renamed','  Alpha renamed  ')){
  Invoke-Mixed 2706 "exact-target-$($target.Length)" {
    $api=New-MixedEdit;$evidence=[Collections.Generic.List[string]]::new();$calls=@{count=0}
    $null=Invoke-MultiProjectTypeText 9904 $target $evidence -typeSource {
      param($id,$text)$calls.count++
      Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 'Alpha renamed' $text -nativeApi $api
    }
    Assert-Mixed ($calls.count -eq 1 -and $api.PhaseState.clearCalls -eq 1 -and $api.PhaseState.unicodeCalls -eq 1 -and
      ($api.PhaseOrder -join '|') -ceq 'focus-insert|focus-observed|select|clear-enqueue|clear-processed|unicode-enqueue' -and
      $api.PhaseState.focusClicks -eq 1 -and $api.PhaseState.buffer -ceq $target -and $api.Now -lt 5000 -and
      $evidence.Count -eq 1 -and $evidence[0].Contains('clearSent=2/2') -and
      $evidence[0].Contains("textSent=$([int](2*$target.Length))/$([int](2*$target.Length))")) 'Sequenced edit phase/count/target proof changed'
  }
}
Invoke-Mixed 2724 'actual-FocusMouse-owned-edit' {
  $api=New-MixedEdit;$null=$api.FocusMouse([IntPtr]42,[IntPtr]9904,@(100,110),4242,[long]0)
  Assert-Mixed ($api.PhaseState.focusClicks -eq 1 -and $api.hitReads -eq 1 -and $api.state.hitRoot -eq [IntPtr]42 -and $api.state.hitPID -eq 4242) 'Actual FocusMouse ownership guard changed'
}
foreach($mutation in @('background','foreign-root')){
  Invoke-Mixed 2732 $mutation {
    $api=New-MixedEdit;if($mutation -ceq 'background'){$api.state.hitChild=[IntPtr]9890}else{$api.state.hitRoot=[IntPtr]99}
    $failure=$null;try{$null=$api.FocusMouse([IntPtr]42,[IntPtr]9904,@(100,110),4242,[long]0)}catch{$failure=$_}
    Assert-Mixed ($failure -and $failure.Exception.ToString().Contains('MULTIPROJECT_EDIT_FOCUS:') -and $api.PhaseState.focusClicks -eq 0) 'Viewport miss became input target'
  }
}
Invoke-Mixed 2742 'already-focused-no-focus-input' {
  $api=New-MixedEdit;$api.PhaseState.focus=[IntPtr]9904
  $null=Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 'Alpha renamed' 'Alpha renamed' -nativeApi $api
  Assert-Mixed ($api.PhaseState.focusClicks -eq 0 -and $api.PhaseState.clearCalls -eq 1 -and $api.PhaseState.unicodeCalls -eq 1 -and
    ($api.PhaseOrder -join '|') -ceq 'select|clear-enqueue|clear-processed|unicode-enqueue') 'Already-owned focus inserted mouse'
}
foreach($mutation in @('focus-short','focus-occluded','focus-foreign-hit','focus-outside','focus-timeout','focus-post-owner','focus-switched','before-mouse-deadline','last-selection-deadline','last-selection-owner')){
  Invoke-Mixed 2751 $mutation {
    $api=New-MixedEdit
    switch($mutation){
      focus-short{$api.PhaseState.focusSent=1} focus-occluded{$api.state.hitChild=[IntPtr]9800} focus-foreign-hit{$api.state.hitPID=7777}
      focus-outside{$api.state.controls['9904'].bounds=@(700,700,900,724)} focus-timeout{$api.PhaseState.neverFocus=$true}
      focus-post-owner{$api|Add-Member ScriptMethod FocusInsertion {param($modal,$point)$this.PhaseState.focusClicks++;$this.state.controls['9904'].processId=7777;return ,@($point[0],$point[1],($point[0]+1),($point[1]+1),$point[0],$point[1],2,2)} -Force}
      focus-switched{$api.PhaseState.clearDrift={param($a)$a.PhaseState.focus=[IntPtr]9800}}
      before-mouse-deadline{$api|Add-Member ScriptMethod Hit {param($modal,$x,$y)$this.Now=5000;return @{root=[IntPtr]42;child=[IntPtr]9904;processId=4242}} -Force}
      last-selection-deadline{$api|Add-Member ScriptMethod Selection {param($edit,$remaining)if($this.PhaseState.emptyReads -ge 4){$this.Now=5000};return ,$this.PhaseState.selection} -Force}
      last-selection-owner{$api|Add-Member ScriptMethod Selection {param($edit,$remaining)if($this.PhaseState.emptyReads -ge 4){$this.state.controls['9904'].processId=7777};return ,$this.PhaseState.selection} -Force}}
    $failure=$null;try{$null=Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 'Alpha renamed' 'Alpha renamed' -nativeApi $api}catch{$failure=$_}
    Assert-Mixed ($failure -and $api.PhaseState.focusClicks -le 1 -and $api.PhaseState.clearCalls -le 1 -and $api.PhaseState.unicodeCalls -eq 0) 'Focus/deadline failure added or replayed input'
    if($mutation -ceq 'before-mouse-deadline'){Assert-Mixed ($api.PhaseState.focusClicks -eq 0) 'Expired mouse deadline allowed focus insertion'}
  }
}
foreach($mutation in @('both-foreign','both-zero','both-type','id-wrong','title-wrong','foreground-false','hit-wrong','title-deadline')){
  Invoke-Mixed 2785 $mutation {
    $api=New-MixedEdit
    switch($mutation){
      both-foreign{$api.state.modalPID=7777;$api.state.controls['9904'].processId=7777}
      both-zero{$api.state.modalPID=0;$api.state.controls['9904'].processId=0}
      both-type{$api.state.modalPID='4242';$api.state.controls['9904'].processId='4242'}
      id-wrong{$api.state.controls['9904'].id=9800} title-wrong{$api.state.title='Different dialog'} foreground-false{$api.state.foreground=$false}
      hit-wrong{$api.state.hitChild=[IntPtr]9800} title-deadline{$api|Add-Member ScriptMethod Title {param($modal,$remaining)$this.order.Add("TITLE:$modal");$this.Now=5000;return ("Rename "+[char]0x201c+'Alpha renamed'+[char]0x201d)} -Force}}
    $failure=$null;try{$null=$api.FocusMouse([IntPtr]42,[IntPtr]9904,@(100,110),4242,[long]0)}catch{$failure=$_}
    Assert-Mixed ($failure -and $api.PhaseState.focusClicks -eq 0) 'Actual focus primitive adopted foreign PID or late budget'
    if($mutation -cin @('both-foreign','both-zero','both-type')){Assert-Mixed (-not ($api.order -contains 'TITLE:42')) 'Foreign modal title read before PID guard'}
  }
}
foreach($mutation in @('empty-initial','mismatch-prefill','selection-short','selection-offset','selection-type','never-clear','empty-rebound','clear-short','unicode-short','final-wrong','focus-deadline','initial-foreign','initial-control','initial-hidden','initial-disabled','initial-foreground','clear-foreign','clear-focus','preunicode-control','final-owner','final-focus','selection-nonzero-empty')){
  Invoke-Mixed 2808 $mutation {
    $api=New-MixedEdit
    switch($mutation){
      empty-initial{$api.PhaseState.buffer='';$api.PhaseState.clearPending=$true} mismatch-prefill{$api.PhaseState.buffer='Other title'}
      selection-short{$api.PhaseState.badSelection=@(0,12)} selection-offset{$api.PhaseState.badSelection=@(1,13)} selection-type{$api.PhaseState.badSelection=@('0',13)}
      never-clear{$api.PhaseState.neverClear=$true} empty-rebound{$api.PhaseState.rebound=$true} clear-short{$api.PhaseState.clearSent=1}
      unicode-short{$api.PhaseState.unicodeShort=$true} final-wrong{$api.PhaseState.finalWrong=$true} focus-deadline{$api.PhaseState.neverFocus=$true}
      initial-foreign{$api.state.controls['9904'].processId=7777} initial-control{$api.state.controls['9904'].id=9105}
      initial-hidden{$api.state.controls['9904'].visible=$false} initial-disabled{$api.state.controls['9904'].enabled=$false} initial-foreground{$api.state.foreground=$false}
      clear-foreign{$api.PhaseState.clearDrift={param($a)$a.state.controls['9904'].processId=7777}} clear-focus{$api.PhaseState.clearDrift={param($a)$a.PhaseState.focus=[IntPtr]9800}}
      preunicode-control{$api.PhaseState.clearDrift={param($a)$a.state.controls['9904'].id=9105}}
      final-owner{$api.PhaseState.unicodeDrift={param($a)$a.state.controls['9904'].root=[IntPtr]99}} final-focus{$api.PhaseState.unicodeDrift={param($a)$a.PhaseState.focus=[IntPtr]9800}}
      selection-nonzero-empty{$api.PhaseState.clearDrift={param($a)$a.PhaseState.selection=@(1,1)}}}
    $failure=$null;try{$null=Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 'Alpha renamed' 'Alpha renamed' -nativeApi $api}catch{$failure=$_}
    Assert-Mixed ($failure -and $failure.Exception.Message.StartsWith('MULTIPROJECT_EDIT_',[StringComparison]::Ordinal) -and
      $api.PhaseState.clearCalls -le 1 -and $api.PhaseState.unicodeCalls -le 1) 'Sequenced guard lost exact refusal or replayed batch'
    $unicode=if($mutation -cin @('unicode-short','final-wrong','final-owner','final-focus')){1}else{0}
    Assert-Mixed ($api.PhaseState.unicodeCalls -eq $unicode) 'Rejected prefill/ownership/clear allowed Unicode'
    if($mutation -ceq 'empty-initial'){Assert-Mixed ($api.PhaseState.clearCalls -eq 0 -and $api.PhaseState.observes -eq 0) 'Initial empty buffer invented transition acknowledgement'}
  }
}
Invoke-Mixed 2845 'compiled-edit-native-declaration-only' {
  $api=New-MultiProjectEditNativeApi
  Assert-Mixed ($mixedAssembly.GetType('GraphCodeMultiProjectEditNative',$false) -ne $null -and $null -ne $api.PSObject.Methods['Selection']) 'Current file-backed edit declaration unavailable'
}
Invoke-Mixed 2850 'empty-prefill-refused-before-input' {
  $api=New-MixedEdit;$failure=$null
  try{$null=Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 '' '   ' -nativeApi $api}catch{$failure=$_}
  Assert-Mixed ($failure -and $api.PhaseState.focusClicks -eq 0 -and $api.PhaseState.clearCalls -eq 0 -and $api.PhaseState.unicodeCalls -eq 0) 'Unknown empty prefill admitted transition'
}
Invoke-Mixed 2857 'diagnostic-failure-retains-primary' {
  $api=New-MixedEdit;$api.PhaseState.buffer='';$failure=$null
  try{$null=Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 'Alpha renamed' '   ' -nativeApi $api -phaseSink {param($message)throw [IO.IOException]::new('phase refusal writer failed')}}catch{$failure=$_}
  $secondary=$failure.Exception.Data['MultiProjectEditDiagnostic']
  Assert-Mixed ($failure.Exception.Message -ceq 'MULTIPROJECT_EDIT_PREFILL: fresh buffer differs from known nonempty prefill' -and
    $secondary.errorType -ceq 'System.IO.IOException' -and $secondary.operation -ceq 'sequenced-edit-refusal' -and
    $api.PhaseState.focusClicks -eq 0 -and $api.PhaseState.unicodeCalls -eq 0) 'Diagnostic writer replaced exact primary or sent input'
}
$renameText='  Alpha renamed  '
$renameProof=@('UIA_EDGE_TEXT_STABLE id=9904 inputAttempted=True inputCountsFull=True clearSent=2/2 textSent=34/34')
foreach($cancelRoute in @($false,$true)){
  Invoke-Mixed 2871 "actual-caller-cancel-$cancelRoute" {
    $api=New-MixedRename;if($cancelRoute){$api.state.hitChild=[IntPtr]9808}
    function New-MultiProjectRenameNativeApi {return $api}
    $caller=@($gateAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-MultiProjectNativeRename'},$true))
    Assert-Mixed ($caller.Count -eq 1) 'Actual Rename caller missing or ambiguous'
    $statements=@($caller[0].FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$action'},$true))
    Assert-Mixed ($statements.Count -eq 1) 'Actual caller action assignment missing or ambiguous'
    $modal=[IntPtr]42;$multiProcess=[pscustomobject]@{Id=4242};$typedTitle=$renameText;$Cancel=$cancelRoute
    $renameTitle=Get-MultiProjectRenameTitle 'Alpha renamed'
    $inputEvidence=[Collections.Generic.List[string]]::new();$inputEvidence.Add($renameProof[0])
    . ([scriptblock]::Create($statements[0].Extent.Text))
    $button=if($cancelRoute){9808}else{9800}
    Assert-Mixed ($action.buttonId -eq $button -and $action.sent -eq 2 -and $action.expected -eq 2 -and
      $api.inputCalls -eq 1 -and -not ($api.requested -contains 1) -and $api.requested -contains 9904 -and
      $action.nativeTarget.observed.button.controlId -eq $button -and $action.nativeTarget.observed.button.topOwner -eq 42 -and
      ($api.order -join '|').StartsWith('PID:42|TITLE:42|CONTROL:',[StringComparison]::Ordinal)) 'Actual caller uses legacy button or input before owned target capture'
  }
}
Invoke-Mixed 2897 'actual-button-client-work-clipping' {
  $api=New-MixedRename;$api.state.controls['9800'].bounds=@(580,380,680,430)
  $action=Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api
  Assert-Mixed (($action.clippedBounds -join ',') -ceq '580,380,600,400' -and
    $action.point[0] -ge 580 -and $action.point[0] -lt 600 -and $action.point[1] -ge 380 -and $action.point[1] -lt 400) 'Rename point ignores actual client/work clipping'
}
Invoke-Mixed 2906 'uncovered-owned-point-without-covering-captions' {
  $api=New-MixedRename;$api.state.coveredFirst=$true
  $action=Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api
  Assert-Mixed ($action.nativeTarget.hitSamples.Count -eq 2 -and -not $action.nativeTarget.hitSamples[0].hitTarget -and
    $action.nativeTarget.hitSamples[1].hitTarget -and $api.inputCalls -eq 1) 'Covered point clicked or uncovered target not measured'
}
foreach($mutation in @(
  'missing-button','zero-handle','invalid-handle','hidden-button','disabled-button','wrong-id','id-type','foreign-button','pid-zero','pid-type',
  'wrong-top-owner','owner-type','missing-edit','foreign-edit','wrong-edit-id','edit-disabled','modal-foreign','modal-zero','modal-pid-type','wrong-title',
  'title-type','modal-hidden','modal-disabled','visibility-type','bounds-missing','bounds-zero','bounds-negative-width','bounds-type','bounds-nan','outside-client',
  'outside-work','client-zero','work-invalid','foreground-false','foreground-type','buffer-wrong','buffer-changing','buffer-type','proof-empty','proof-wrong-id',
  'proof-short','proof-clear-short','proof-not-attempted','fully-occluded','foreign-hit','hit-pid-type','hit-root-wrong','hit-child-type','late-hidden',
  'late-disabled','late-foreign','late-id-drift','late-owner-drift','late-bounds-drift','late-modal-foreign','late-title-drift','late-client-drift','late-work-drift','late-foreground'
)){
  Invoke-Mixed 2924 $mutation {
    $api=New-MixedRename;$proof=@($renameProof);$button=$api.state.controls['9800']
    switch($mutation){
      missing-button{$api.state.controls.Remove('9800')} zero-handle{$button.handle=[IntPtr]::Zero} invalid-handle{$button.handle='9800'}
      hidden-button{$button.visible=$false} disabled-button{$button.enabled=$false} wrong-id{$button.id=1} id-type{$button.id='9800'}
      foreign-button{$button.processId=7777} pid-zero{$button.processId=0} pid-type{$button.processId='4242'}
      wrong-top-owner{$button.root=[IntPtr]99} owner-type{$button.root='42'} missing-edit{$api.state.controls.Remove('9904')}
      foreign-edit{$api.state.controls['9904'].processId=7777} wrong-edit-id{$api.state.controls['9904'].id=9105} edit-disabled{$api.state.controls['9904'].enabled=$false}
      modal-foreign{$api.state.modalPID=7777} modal-zero{$api.state.modalPID=0} modal-pid-type{$api.state.modalPID='4242'} wrong-title{$api.state.title='New Loop'}
      title-type{$api.state.title=1} modal-hidden{$api.state.visible=$false} modal-disabled{$api.state.enabled=$false} visibility-type{$button.visible='True'}
      bounds-missing{$button.bounds=@()} bounds-zero{$button.bounds=@(300,300,300,328)} bounds-negative-width{$button.bounds=@(300,300,299,328)}
      bounds-type{$button.bounds[0]='300'} bounds-nan{$button.bounds[0]=[double]::NaN} outside-client{$button.bounds=@(700,700,780,728)}
      outside-work{$api.state.work=@(0,0,200,200)} client-zero{$api.state.client=@(10,40,10,400)} work-invalid{$api.state.work[0]='0'}
      foreground-false{$api.state.foreground=$false} foreground-type{$api.state.foreground='True'}
      buffer-wrong{$api.state.buffer='Wrong';$api.state.secondBuffer='Wrong'} buffer-changing{$api.state.secondBuffer='Changed'} buffer-type{$api.state.buffer=1}
      proof-empty{$proof=@()} proof-wrong-id{$proof[0]=$proof[0].Replace('id=9904','id=9105')} proof-short{$proof[0]=$proof[0].Replace('34/34','33/34')}
      proof-clear-short{$proof[0]=$proof[0].Replace('2/2','1/2')} proof-not-attempted{$proof[0]=$proof[0].Replace('inputAttempted=True','inputAttempted=False')}
      fully-occluded{$api.state.hitChild=[IntPtr]9904} foreign-hit{$api.state.hitPID=7777} hit-pid-type{$api.state.hitPID='4242'}
      hit-root-wrong{$api.state.hitRoot=[IntPtr]99} hit-child-type{$api.state.hitChild='9800'}
      late-hidden{$api.state.late={param($s)$s.controls['9800'].visible=$false}} late-disabled{$api.state.late={param($s)$s.controls['9800'].enabled=$false}}
      late-foreign{$api.state.late={param($s)$s.controls['9800'].processId=7777}} late-id-drift{$api.state.late={param($s)$s.controls['9800'].id=1}}
      late-owner-drift{$api.state.late={param($s)$s.controls['9800'].root=[IntPtr]99}} late-bounds-drift{$api.state.late={param($s)$s.controls['9800'].bounds=@(310,300,390,328)}}
      late-modal-foreign{$api.state.late={param($s)$s.modalPID=7777}} late-title-drift{$api.state.late={param($s)$s.title='New Loop'}}
      late-client-drift{$api.state.late={param($s)$s.client=@(10,40,590,400)}} late-work-drift{$api.state.late={param($s)$s.work=@(0,0,1900,1080)}}
      late-foreground{$api.state.late={param($s)$s.foreground=$false}}}
    $prefix=if($mutation -cin @('outside-client','outside-work')){'MULTIPROJECT_BOUNDS:'}else{'MULTIPROJECT_RENAME_GUARD:'}
    $records=@(& {$null=Reject-Mixed {Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $proof -nativeApi $api} $prefix} 6>&1)
    $diagnostics=@($records|Where-Object {$_ -is [Management.Automation.InformationRecord] -and ([string]$_.MessageData).StartsWith('UIA_MULTIPROJECT_RENAME_NATIVE_TARGET=',[StringComparison]::Ordinal)}|
      ForEach-Object {([string]$_.MessageData).Substring('UIA_MULTIPROJECT_RENAME_NATIVE_TARGET='.Length)|ConvertFrom-Json})
    Assert-Mixed ($api.inputCalls -eq 0 -and -not ($api.order|Where-Object {$_.StartsWith('INPUT:')}) -and
      $diagnostics.Count -gt 0 -and $diagnostics[0].expected.buttonId -eq 9800 -and -not $diagnostics[0].inputAttempted) 'Refused Rename guard sent input or lost actual typed diagnostic'
    if($mutation -cin @('modal-foreign','modal-zero','modal-pid-type')){Assert-Mixed (-not ($api.order -contains 'TITLE:42') -and $api.requested.Count -eq 0) 'Foreign modal content read'}
    if($mutation -cin @('missing-button','zero-handle')){Assert-Mixed ($diagnostics[0].observed.button.handle -eq 0 -and $null -eq $diagnostics[0].observed.button.controlId) 'Missing actual target fields invented'}
  }
}
foreach($mutation in @('short-count','typed-count')){
  Invoke-Mixed 3013 $mutation {
    $api=New-MixedRename;$api.state.inputSent=if($mutation -ceq 'short-count'){1}else{'2'}
    $null=Reject-Mixed {Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api} 'MULTIPROJECT_RENAME_INPUT:'
    Assert-Mixed ($api.inputCalls -eq 1) 'Incomplete input replayed'
  }
}
foreach($mutation in @('foreign-button','wrong-title','covered-point')){
  Invoke-Mixed 3024 $mutation {
    $api=New-MixedRename
    $api.state.finalDrift=switch($mutation){foreign-button{{param($s)$s.controls['9800'].processId=7777}} wrong-title{{param($s)$s.title='Different modal'}} covered-point{{param($s)$s.hitChild=[IntPtr]9904}}}
    $failure=$null;try{$null=Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api}catch{$failure=$_}
    Assert-Mixed ($failure -and $failure.Exception.ToString().Contains('native target changed immediately before input') -and
      $api.inputCalls -eq 0 -and $api.hitReads -eq 2) 'Production Click entered primitive input after final target drift'
  }
}
Invoke-Mixed 3040 'stale-native-read-primary-and-unavailable-fields' {
  $api=New-MixedRename;$api.state.staleClient=$true;$seen=@{failure=$null}
  $records=@(& {
    try{$null=Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api}catch{$seen.failure=$_}
  } 6>&1)
  Assert-Mixed ($seen.failure -and $seen.failure.Exception.ToString().Contains('controlled stale native client')) 'Primary stale error replaced'
  $failures=@($records|Where-Object {$_ -is [Management.Automation.InformationRecord] -and ([string]$_.MessageData).StartsWith('UIA_MULTIPROJECT_RENAME_NATIVE_FAILURE=',[StringComparison]::Ordinal)}|
    ForEach-Object {([string]$_.MessageData).Substring('UIA_MULTIPROJECT_RENAME_NATIVE_FAILURE='.Length)|ConvertFrom-Json})
  Assert-Mixed ($api.inputCalls -eq 0 -and $failures.Count -eq 1 -and $failures[0].failure.errorType -ceq 'System.ComponentModel.Win32Exception' -and
    $failures[0].failure.nativeErrorCode -eq 6 -and -not $failures[0].inputAttempted -and $null -eq $failures[0].observed.button) 'Stale error lost typed availability metadata or sent input'
}
Invoke-Mixed 3057 'compiled-rename-binding-without-invocation' {
  $api=New-MultiProjectRenameNativeApi
  Assert-Mixed ($mixedAssembly.GetType('GraphCodeMultiProjectRenameNative',$false) -ne $null -and
    $null -ne $api.PSObject.Methods['ClientBounds'] -and $null -ne $api.PSObject.Methods['Hit']) 'Current file-backed Rename adapter unavailable'
}
$captureReader={param($element,[bool]$content)$element.Capture($content)}
$capturePrior=@{ownership='owned';finalPID=@{value=4242};automationID=@{value='canvas-card-1983941480823304696'}}
Invoke-Mixed 3129 'fresh-owned-before-content-and-after' {
  $mock=New-MixedCapture @((New-MixedCaptureState),(New-MixedCaptureState),(New-MixedCaptureState))
  $e=Get-MultiProjectElementEvidence $mock 4242 $capturePrior 'mixed/owned' $captureReader
  Assert-Mixed ($e.processId -eq 4242 -and $e.automationId -ceq $capturePrior.automationID.value -and $e.name -ceq 'Alpha loop' -and
    ($e.bounds -join ',') -ceq '248,118,468,204' -and
    ($mock.order -join '|') -ceq 'OWNERSHIP_CACHE|PID|ID|RUNTIME|CONTENT_CACHE|PID|ID|RUNTIME|BOUNDS|NAME|OWNERSHIP_CACHE|PID|ID|RUNTIME') 'Fresh cached ownership/content ordering or output shape changed'
}
Invoke-Mixed 3138 'unsupported-is-not-zero-default' {
  $unsupported=Read-MultiProjectOwnershipSnapshot (New-MixedCapture @((New-MixedCaptureState ([System.Windows.Automation.AutomationElement]::NotSupported)))) $captureReader
  $zero=Read-MultiProjectOwnershipSnapshot (New-MixedCapture @((New-MixedCaptureState 0))) $captureReader
  Assert-Mixed ($unsupported.pidState.state -ceq 'unsupported' -and $null -eq $unsupported.processId -and
    $zero.pidState.state -ceq 'zero' -and $zero.processId -eq 0 -and $unsupported.state -ceq 'unavailable' -and $zero.state -ceq 'unavailable') 'Unsupported/default ownership states conflated'
}
foreach($mutation in @(
  'fresh-zero','fresh-null-pid','fresh-unsupported-pid','fresh-pid-type','fresh-foreign','fresh-null-id','fresh-empty-id','fresh-id-type','fresh-id-drift',
  'fresh-null-runtime','fresh-runtime-type','fresh-retired','prior-owner-changed','prior-pid-changed',
  'content-foreign','content-zero','content-unsupported','content-id-drift','content-runtime-drift',
  'after-foreign','after-zero','after-id-drift','after-runtime-drift','after-retired','name-type','name-unsupported','bounds-null','bounds-zero','bounds-empty'
)){
  Invoke-Mixed 3154 $mutation {
    $states=@((New-MixedCaptureState),(New-MixedCaptureState),(New-MixedCaptureState))
    $prior=@{ownership='owned';finalPID=@{value=4242};automationID=@{value=$capturePrior.automationID.value}}
    switch($mutation){
      fresh-zero{$states[0].pid=0} fresh-null-pid{$states[0].pid=$null} fresh-unsupported-pid{$states[0].pid=[System.Windows.Automation.AutomationElement]::NotSupported}
      fresh-pid-type{$states[0].pid='4242'} fresh-foreign{$states[0].pid=7777} fresh-null-id{$states[0].id=$null} fresh-empty-id{$states[0].id=''}
      fresh-id-type{$states[0].id=7} fresh-id-drift{$states[0].id='canvas-card-unknown'} fresh-null-runtime{$states[0].runtime=@()} fresh-runtime-type{$states[0].runtime=@('3',42,17)}
      fresh-retired{$states[0].error=[Runtime.InteropServices.COMException]::new('controlled retirement',[int]0x80040201)}
      prior-owner-changed{$prior.ownership='changed'} prior-pid-changed{$prior.finalPID.value=7777}
      content-foreign{$states[1].pid=7777} content-zero{$states[1].pid=0} content-unsupported{$states[1].pid=[System.Windows.Automation.AutomationElement]::NotSupported}
      content-id-drift{$states[1].id='canvas-card-unknown'} content-runtime-drift{$states[1].runtime=@(3,42,99)}
      after-foreign{$states[2].pid=7777} after-zero{$states[2].pid=0} after-id-drift{$states[2].id='canvas-card-unknown'}
      after-runtime-drift{$states[2].runtime=@(3,42,99)} after-retired{$states[2].error=[Runtime.InteropServices.COMException]::new('controlled retirement',[int]0x80040201)}
      name-type{$states[1].name=7} name-unsupported{$states[1].name=[System.Windows.Automation.AutomationElement]::NotSupported}
      bounds-null{$states[1].rect=$null} bounds-zero{$states[1].rect=[System.Windows.Rect]::new(248,118,0,86)} bounds-empty{$states[1].rect=[System.Windows.Rect]::Empty}}
    $mock=New-MixedCapture $states
    $prefix=if($mutation -cin @('fresh-foreign','content-foreign','after-foreign')){'MULTIPROJECT_PRIVACY:'}else{'MULTIPROJECT_METADATA:'}
    $null=Reject-Mixed {Get-MultiProjectElementEvidence $mock 4242 $prior "mixed/$mutation" $captureReader} $prefix
    $contentAllowed=$mutation.StartsWith('after-',[StringComparison]::Ordinal) -or $mutation.StartsWith('name-',[StringComparison]::Ordinal) -or $mutation.StartsWith('bounds-',[StringComparison]::Ordinal)
    Assert-Mixed (($mock.order -contains 'NAME') -eq $contentAllowed -and ($mock.order -contains 'BOUNDS') -eq $contentAllowed) 'Content sampled before fresh ownership/runtime guard'
    if($mutation.StartsWith('fresh-',[StringComparison]::Ordinal) -or $mutation.StartsWith('prior-',[StringComparison]::Ordinal)){
      Assert-Mixed (-not ($mock.order -contains 'CONTENT_CACHE')) 'Content cache requested before positive owned preflight'
    }
  }
}
Invoke-Mixed 3202 'unknown-cache-error-keeps-primary' {
  $state=New-MixedCaptureState;$state.error=[InvalidOperationException]::new('controlled unexpected cache error')
  $mock=New-MixedCapture @($state);$failure=$null
  try{$null=Read-MultiProjectOwnershipSnapshot $mock $captureReader}catch{$failure=$_}
  Assert-Mixed ($failure -and $failure.Exception.ToString().Contains('controlled unexpected cache error') -and -not ($mock.order -contains 'NAME')) 'Unknown cache error swallowed or content sampled'
}
Invoke-Mixed 3214 'retirement-exact-typed-availability' {
  $state=New-MixedCaptureState;$state.error=[Runtime.InteropServices.COMException]::new('controlled retirement',[int]0x80040201)
  $mock=New-MixedCapture @($state);$snapshot=Read-MultiProjectOwnershipSnapshot $mock $captureReader
  Assert-Mixed ($snapshot.state -ceq 'unavailable' -and $snapshot.pidState.state -ceq 'unavailable' -and
    $snapshot.errorType -ceq 'System.Runtime.InteropServices.COMException' -and $snapshot.hresult -eq [int]0x80040201 -and
    ($mock.order -join '|') -ceq 'OWNERSHIP_CACHE') 'Retirement lost exact typed diagnostic'
}
Invoke-Mixed 3224 'unrelated-COM-failure-is-not-retirement' {
  $state=New-MixedCaptureState;$state.error=[Runtime.InteropServices.COMException]::new('controlled unexpected COM',[int]0x80004005)
  $mock=New-MixedCapture @($state);$failure=$null
  try{$null=Read-MultiProjectOwnershipSnapshot $mock $captureReader}catch{$failure=$_}
  Assert-Mixed ($failure -and $failure.Exception.ToString().Contains('controlled unexpected COM') -and $mock.calls -eq 1 -and -not ($mock.order -contains 'NAME')) 'Unknown COM converted to unavailable fallback'
}
foreach($scenario in @('transient','persistent','positive-foreign')){
  Invoke-Mixed 3237 $scenario {
    $multiProcess=[pscustomobject]@{Id=4242}
    $observationState=@{attempts=0;sleeps=0;scenario=$scenario}
    function Start-Sleep {param([int]$Milliseconds)$observationState.sleeps++}
    function Get-MultiProjectObservation {
      param([string]$surface,$selectedOwner)$observationState.attempts++
      $state=New-MixedCaptureState
      if($observationState.scenario -ceq 'positive-foreign'){$state.pid=7777}
      elseif($observationState.scenario -ceq 'persistent' -or $observationState.attempts -eq 1){$state.pid=0}
      $mock=New-MixedCapture @($state,(New-MixedCaptureState),(New-MixedCaptureState))
      $e=Get-MultiProjectElementEvidence $mock 4242 $capturePrior 'mixed/whole-observation' $captureReader
      return @{matched=$true;requestedSurface=$surface;evidence=$e}
    }
    if($scenario -ceq 'transient'){
      $observation=Wait-MultiProjectObservation overview
      Assert-Mixed ($observation.matched -and $observationState.attempts -eq 2 -and $observationState.sleeps -eq 1) 'Transient whole capture not reacquired exactly once'
    }else{
      $prefix=if($scenario -ceq 'positive-foreign'){'MULTIPROJECT_PRIVACY:'}else{'MULTIPROJECT_METADATA:'}
      $null=Reject-Mixed {Wait-MultiProjectObservation overview} $prefix
      $expected=if($scenario -ceq 'positive-foreign'){1}else{100}
      Assert-Mixed ($observationState.attempts -eq $expected -and $observationState.sleeps -eq ($expected-1)) 'Foreign capture retried or persistent ambiguity escaped exact attempt bound'
    }
  }
}
Invoke-Mixed 3268 'whole-capture-rejects-runtime-replacement' {
  $snapshots=[Collections.Generic.List[object]]::new()
  $mock=New-MixedCapture @((New-MixedCaptureState),(New-MixedCaptureState),(New-MixedCaptureState))
  $null=Get-MultiProjectElementEvidence $mock 4242 $capturePrior 'mixed/collection' $captureReader $snapshots
  Assert-Mixed ($snapshots.Count -eq 1) 'Verified snapshot was not registered'
  $changed=New-MixedCaptureState;$changed.runtime=@(3,42,99)
  $after=Read-MultiProjectOwnershipSnapshot (New-MixedCapture @($changed)) $captureReader
  $null=Reject-Mixed {Confirm-MultiProjectOwnedSnapshot $snapshots[0].snapshot $after 4242 'mixed/whole-observation'} 'MULTIPROJECT_METADATA:'
}
Invoke-Mixed 3278 'prefix-does-not-coerce-unavailable-ID' {
  Assert-Mixed (-not (Test-MultiProjectAutomationPrefix $null workspace-loop-bar-) -and -not (Test-MultiProjectAutomationPrefix 7 canvas-card-)) 'Unavailable/wrong typed IDs became prefix matches'
}
Invoke-Mixed 3283 'metadata-PID-first-and-again' {
  $mock=New-MixedMetadata 4242 'canvas-card-1983941480823304696'
  $m=Get-MultiProjectFragmentMetadata $mock 4242
  Assert-Mixed ($m.observationReady -and $m.ownership -ceq 'owned' -and $m.automationID.state -ceq 'available' -and $m.family -ceq 'canvas-fragment' -and
    ($mock.State.order -join '|') -ceq 'PID|ID|PID') 'Owned metadata shape or PID ordering differs'
}
Invoke-Mixed 3291 'static-source-chrome-classification' {
  $m=Get-MultiProjectFragmentMetadata (New-MixedMetadata 4242 actual-size) 4242
  Assert-Mixed ($m.observationReady -and $m.family -ceq 'source-supported-chrome') 'Known static chrome rejected'
}
Invoke-Mixed 3296 'owned-restart-in-complete-batch' {
  $mock=New-MixedMetadata 4242 'workspace-restart-session-2140902926206787169'
  $m=Get-MultiProjectFragmentMetadata $mock 4242
  Assert-Mixed ($m.observationReady -and $m.ownership -ceq 'owned' -and $m.family -ceq 'source-supported-chrome' -and
    (Test-MultiProjectMetadataBatch @($m)) -and ($mock.State.order -join '|') -ceq 'PID|ID|PID') 'Owned numeric restart chrome lost exact identity/metadata proof'
}
foreach($test in @(
  @{name='foreign restart';pid=7777;after=7777;id='workspace-restart-session-2140902926206787169'},
  @{name='changed restart owner';pid=4242;after=7777;id='workspace-restart-session-2140902926206787169'},
  @{name='missing restart PID';pid=0;after=0;id='workspace-restart-session-2140902926206787169'},
  @{name='missing restart ID';pid=4242;after=4242;id=$null},@{name='invalid typed restart ID';pid=4242;after=4242;id=7},
  @{name='empty restart suffix';pid=4242;after=4242;id='workspace-restart-session-'},
  @{name='nonnumeric restart suffix';pid=4242;after=4242;id='workspace-restart-session-foreign'},
  @{name='restart extra suffix';pid=4242;after=4242;id='workspace-restart-session-2140902926206787169-extra'}
)){
  Invoke-Mixed 3314 $test.name {
    $mock=New-MixedMetadata $test.pid $test.id $test.after;$m=Get-MultiProjectFragmentMetadata $mock 4242
    Assert-Mixed (-not $m.observationReady -and -not (Test-MultiProjectMetadataBatch @($m)) -and -not ($mock.State.order -contains 'FORBIDDEN_NAME')) 'Restart taxonomy accepted unresolved/foreign identity'
  }
}
foreach($test in @(
  @{name='null native candidate';pid=0;id=$null;after=0;state='unavailable';owner='unavailable'},
  @{name='foreign null ID';pid=7777;id=$null;after=7777;state='unavailable';owner='foreign'},
  @{name='empty owned ID';pid=4242;id='';after=4242;state='empty';owner='owned'},
  @{name='invalid typed ID';pid=4242;id=7;after=4242;state='invalid';owner='owned'},
  @{name='unavailable stale ID';pid=4242;id='unused';after=4242;state='unavailable';owner='owned';unavailable=$true},
  @{name='changed ownership';pid=4242;id='canvas-card-1983941480823304696';after=7777;state='available';owner='changed'},
  @{name='unknown native-boundary ID';pid=7777;id='native-boundary';after=7777;state='available';owner='foreign'}
)){
  Invoke-Mixed 3331 $test.name {
    $mock=New-MixedMetadata $test.pid $test.id $test.after -Unavailable:($test.ContainsKey('unavailable') -and $test.unavailable)
    $m=Get-MultiProjectFragmentMetadata $mock 4242
    Assert-Mixed (-not $m.observationReady -and $m.automationID.state -ceq $test.state -and $m.ownership -ceq $test.owner -and
      -not (Test-MultiProjectMetadataBatch @($m)) -and -not ($mock.State.order -contains 'FORBIDDEN_NAME') -and $m.proofLimit.Length -gt 0) 'Unresolved/stale metadata silently dropped or foreign Name read'
  }
}
Invoke-Mixed 3341 'foreign-semantic-fragment-remains-counted' {
  $mock=New-MixedMetadata 7777 'canvas-card-1983941480823304696';$m=Get-MultiProjectFragmentMetadata $mock 4242
  Assert-Mixed ($m.observationReady -and $m.ownership -ceq 'foreign' -and
    (Test-MultiProjectAutomationPrefix $m.automationID.value canvas-card-) -and -not ($mock.State.order -contains 'FORBIDDEN_NAME')) 'Foreign semantic metadata lost before PID-only classification'
  $actual=@([ordered]@{automationId=$m.automationID.value;name='Owned fixture placeholder';processId=7777;bounds=@(248,118,468,204)})
  Assert-Mixed (-not (Test-MultiProjectFragmentRoster $actual @([ordered]@{automationId='canvas-card-1983941480823304696';name='Owned fixture placeholder'}) 4242)) 'Wrong PID semantic fragment accepted'
}
$expected=[ordered]@{
  2706=3;2724=1;2732=2;2742=1;2751=10;2785=8;2808=22;2845=1;2850=1;2857=1;2871=2;2897=1;2906=1;2924=59;3013=2;3024=3;3040=1;3057=1
  3129=1;3138=1;3154=29;3202=1;3214=1;3224=1;3237=3;3268=1;3278=1;3283=1;3291=1;3296=1;3314=8;3331=7;3341=1
}
Complete-Mixed $expected @('mixed-ui','mixed-ui-policy','native-phase-refusal','fresh-metadata','powershell-errorrecord')
$controlFailed=$false
foreach($control in @('false','throw')){
  $failure=$null
  try{
    $api=New-MixedEdit
    if($control -ceq 'false'){$api.PhaseState.focusControlResult=$false}
    else{$api.PhaseState.focusControlError=[IO.IOException]::new('controlled focus primitive failure')}
    $caught=$null
    try{$null=$api.FocusMouse([IntPtr]42,[IntPtr]9904,@(100,110),4242,[long]0)}catch{$caught=$_}
    Assert-Mixed ($caught -and $api.PhaseState.focusControlCalls -eq 1 -and $api.PhaseState.focusClicks -eq 1 -and
      $api.PhaseState.clearCalls -eq 0 -and $api.PhaseState.unicodeCalls -eq 0) 'Focus primitive failure was swallowed or followed by key input'
    if($control -ceq 'false'){
      Assert-Mixed ($caught.Exception.ToString().Contains('MULTIPROJECT_EDIT_FOCUS: direct control focus fallback failed') -and
        -not $api.LastFocusControlFallback) 'False focus primitive lost actual fallback refusal'
    }else{
      Assert-Mixed ($caught.Exception.GetBaseException() -is [IO.IOException] -and
        $caught.Exception.GetBaseException().Message -ceq 'controlled focus primitive failure') 'Focus primitive throw replaced exact primary error'
    }
  }catch{$failure=$_;$controlFailed=$true}
  $row=[ordered]@{
    id="ownership.mixed-ui.focus-control-$control";status=$(if($failure){'Failed'}else{'Passed'});executedCount=1
    evidence=$(if($failure){$failure.ToString()}else{'Actual production FocusMouse primitive false/throw refusal; no clear/Unicode; test-only operation transport'})
    groups=@('mixed-ui','mixed-ui-policy','focus-control-boundary','powershell-errorrecord')
  }
  $json=$row|ConvertTo-Json -Compress -Depth 8 -EscapeHandling EscapeNonAscii
  $document=[System.Text.Json.JsonDocument]::Parse([string]$json);$document.Dispose()
  Write-Output ('OWNERSHIP_CASE_RESULT='+$json)
}
if($controlFailed){exit 1}
