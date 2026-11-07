param([Parameter(Mandatory)][string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path $ScratchRoot){throw 'Fresh scratch required.'}
$null=[IO.Directory]::CreateDirectory($ScratchRoot)
$path=Join-Path $PSScriptRoot '..\Invoke-UiCaptureWorker.ps1'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
if($errors.Count-ne0){throw 'Worker parse failed.'}
$definition=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and
    $n.Name-ceq'Assert-CapWireCreateAction'},$true)
if(-not$definition){throw 'Actual guard definition missing.'}
. ([scriptblock]::Create($definition.Extent.Text))
$results=[Collections.Generic.List[object]]::new()
function Write-CapTrace {param($Command,$Parameters)
    if($script:traceFailure){throw 'CONTROLLED_TRACE_FAILURE'}
    $script:trace.Add(@{command=$Command;parameters=$Parameters})
}
Add-Type -TypeDefinition @'
public class CreateProbe {
  public bool failCurrent;
  public CreateProbe Current { get { if(failCurrent) throw new System.InvalidOperationException("CONTROLLED_CURRENT_FAILURE"); return this; } }
  public CreateProbe State { get { return this; } }
  public string Name { get { return "Create"; } }
  public int ProcessId { get { return 7; } }
  public int NativeWindowHandle { get { return 123; } }
  public CreateType ControlType { get { return new CreateType(); } }
  public bool enabled, offscreen, fail;
  public int enabledReads, offscreenReads;
  public bool IsEnabled { get { enabledReads++; if(fail) throw new System.InvalidOperationException("CONTROLLED_PROPERTY_FAILURE"); return enabled; } }
  public bool IsOffscreen { get { offscreenReads++; return offscreen; } }
  public int[] GetRuntimeId() { return new int[] {1,123}; }
}
public class CreateType { public int Id = 50000; public string ProgrammaticName = "ControlType.Button"; }
'@
function New-Candidate([bool]$Enabled=$true,[bool]$Offscreen=$false,[bool]$Fail=$false){
    $element=[CreateProbe]::new()
    $element.enabled=$Enabled;$element.offscreen=$Offscreen;$element.fail=$Fail
    return $element
}
function Check([string]$Name,[scriptblock]$Action){
    $script:trace=[Collections.Generic.List[object]]::new()
    $script:traceFailure=$false
    try{&$Action;$results.Add(@{name=$Name;passed=$true})}
    catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}
}
function Assert([bool]$Value){if(-not$Value){throw 'Assertion failed.'}}
foreach($count in @(0,2)){
    Check "reject count$count without guard property reads" {
        $one=New-Candidate
        $items=@(for($i=0;$i-lt$count;$i++){$one})
        $failure=$null
        try{Assert-CapWireCreateAction -Creates $items}catch{$failure=$_}
        Assert ($null-ne$failure-and$one.Current.State.enabledReads-eq0-and$one.Current.State.offscreenReads-eq0)
        Assert ($script:trace[0].parameters.count-eq$count)
    }
}
Check 'one enabled onscreen candidate read exactly once and records type identity' {
    $one=New-Candidate
    Assert-CapWireCreateAction -Creates @($one)
    Assert ($one.Current.State.enabledReads-eq1-and$one.Current.State.offscreenReads-eq1)
    $facts=$script:trace[0].parameters.candidates|ConvertFrom-Json
    Assert ($facts.controlTypeId-eq50000-and$facts.nativeHandle-eq123-and$facts.name-ceq'Create')
}
Check 'disabled candidate refuses without offscreen or third state read' {
    $one=New-Candidate $false
    $failure=$null
    try{Assert-CapWireCreateAction -Creates @($one)}catch{$failure=$_}
    Assert ($null-ne$failure-and$one.Current.State.enabledReads-eq1-and$one.Current.State.offscreenReads-eq0)
}
Check 'offscreen candidate refuses with one read of each state' {
    $one=New-Candidate $true $true
    $failure=$null
    try{Assert-CapWireCreateAction -Creates @($one)}catch{$failure=$_}
    Assert ($null-ne$failure-and$one.Current.State.enabledReads-eq1-and$one.Current.State.offscreenReads-eq1)
}
Check 'property failure is preserved and evidence marked unavailable' {
    $one=New-Candidate $true $false $true
    $failure=$null
    try{Assert-CapWireCreateAction -Creates @($one)}catch{$failure=$_}
    if($null-eq$failure-or-not$failure.Exception.ToString().Contains('CONTROLLED_PROPERTY_FAILURE')){
        throw "Property primary not preserved: $($failure.Exception.ToString())"
    }
    $last=$script:trace[$script:trace.Count-1]
    Assert ($last.command-ceq'WireCreatePredicateFailure'-and$last.parameters.enabled-ceq'UNAVAILABLE_NOT_READ')
}
Check 'source keeps exact predicate and no additional FindAll in guard' {
    $text=[IO.File]::ReadAllText($path)
    Assert ($text.Contains("[Windows.Automation.AutomationElement]::NameProperty,'Create'")-and
        $text.Contains('[Windows.Automation.ControlType]::Button')-and
        $text.Contains('Assert-CapWireCreateAction -Creates $creates')-and
        $text.Contains('$c=$_.get_Current()')-and
        $definition.Extent.Text.Contains('$current=$element.get_Current()')-and
        $definition.Extent.Text.Contains("`$primary.Exception.Data['WireCreateTraceFailure']=`$_")-and
        $definition.Extent.Text.Contains('throw $primary')-and
        -not($definition.Extent.Text-match'FindAll|Start-Sleep|\.Invoke\('))
}
Check 'Current getter failure retains its primary instead of missing-property fallback' {
    $one=New-Candidate
    $one.failCurrent=$true
    $failure=$null
    try{Assert-CapWireCreateAction -Creates @($one)}catch{$failure=$_}
    Assert ($null-ne$failure-and$failure.Exception.ToString().Contains('CONTROLLED_CURRENT_FAILURE'))
}
Check 'trace failure is attached without replacing primary property error' {
    $one=New-Candidate $true $false $true
    $script:traceFailure=$true
    $failure=$null
    try{Assert-CapWireCreateAction -Creates @($one)}catch{$failure=$_}
    Assert ($null-ne$failure-and$failure.Exception.ToString().Contains('CONTROLLED_PROPERTY_FAILURE'))
    Assert ($failure.Exception.Data['WireCreateTraceFailure'].Exception.ToString().Contains('CONTROLLED_TRACE_FAILURE'))
}
$passed=@($results|Where-Object passed -EQ $true).Count
@{suite='WireCreateObservation';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeCalls=0;
    evidence='Actual extracted guard with controlled property getters; not runtime UIA evidence';cases=@($results)}|
    ConvertTo-Json -Depth 6|Set-Content (Join-Path $ScratchRoot 'report.json') -Encoding utf8NoBOM
@{suite='WireCreateObservation';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeCalls=0}|ConvertTo-Json -Compress
if($results.Count-ne9-or$passed-ne9){exit 1}
