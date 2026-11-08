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
$modulePath=Join-Path $PSScriptRoot '..\UiCaptureDriver.psm1'
$moduleAst=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$null,[ref]$null)
$initialize=$moduleAst.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and
    $n.Name-ceq'Initialize-CapUiaClient'},$true)
if(-not$initialize){throw 'Actual client initializer missing.'}
# Substitute only the loader boundary; no runtime provider is registered by these tests.
$initializerText=$initialize.Extent.Text.Replace(
    "(Join-Path `$PSScriptRoot 'Import-CompiledValidationAssembly.ps1')",'Invoke-ControlledUiaLoader')
# Extracted scriptblocks have no file directory; retain the real module's source directory as data.
$initializerText=$initializerText.Replace('$PSScriptRoot',"'"+(Split-Path -Parent ([IO.Path]::GetFullPath($modulePath))).Replace("'","''")+"'")
. ([scriptblock]::Create($initializerText))
function Invoke-ControlledUiaLoader {param($AssemblyPath,$RequiredType)
    $script:loaderCalls++
    $script:loaderPath=$AssemblyPath
    if($script:loaderError){throw $script:loaderError}
    if($script:loaderWrongShape){return 'INVALID'}
    if($RequiredType-cne'GraphCodeUiaGateState'){throw 'Wrong required loader type.'}
    return [string].Assembly
}
function Reset-Loader {
    $script:loaderCalls=0;$script:loaderError=$null;$script:loaderWrongShape=$false
}
Check 'client uses existing guarded loader once and records successful identity' {
    Reset-Loader
    Initialize-CapUiaClient -AssemblyPath 'C:\controlled\current.dll'
    Assert ($script:loaderCalls-eq1-and$script:trace[0].command-ceq'CaptureUiaClientInitialized')
}
Check 'client missing assembly refuses before loader or success trace' {
    Reset-Loader
    $failure=$null
    try{Initialize-CapUiaClient -AssemblyPath ''}catch{$failure=$_}
    Assert ($null-ne$failure-and$script:loaderCalls-eq0-and$script:trace.Count-eq0)
}
Check 'client provenance or registration failure propagates primary without defaults' {
    Reset-Loader
    $script:loaderError=[InvalidOperationException]::new('CONTROLLED_PROVENANCE_OR_REGISTRATION_FAILURE')
    $failure=$null
    try{Initialize-CapUiaClient -AssemblyPath 'C:\controlled\current.dll'}catch{$failure=$_.Exception.GetBaseException()}
    Assert ([object]::ReferenceEquals($failure,$script:loaderError)-and$script:trace.Count-eq0)
}
Check 'client wrong loader output refuses before success trace' {
    Reset-Loader;$script:loaderWrongShape=$true;$failure=$null
    try{Initialize-CapUiaClient -AssemblyPath 'C:\controlled\current.dll'}catch{$failure=$_}
    Assert ($null-ne$failure-and$script:trace.Count-eq0)
}
Check 'client startup precedes UIA use on both live entry paths and keeps managed register-once guard' {
    $entry=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Invoke-MatchedActionSupplement.ps1'))
    $worker=[IO.File]::ReadAllText($path)
    $managed=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\ValidationRunner\Ui\Production\GraphCodeUiaGateState.cs'))
    Assert ($entry.Contains('if (-not $DryRun) {Initialize-CapUiaClient}')-and
        $entry.IndexOf('Initialize-CapUiaClient')-lt$entry.IndexOf('$boundWindows=@(Assert-CapActionWindowContext)')-and
        $worker.Contains('if (-not $rehearsal) {Initialize-CapUiaClient}')-and
        $managed.Contains('if (RegisteredClientSideProvider == assemblyName.FullName) return;')-and
        $managed.IndexOf('ClientSettings.RegisterClientSideProviderAssembly(assemblyName)')-lt
            $managed.IndexOf('RegisteredClientSideProvider = assemblyName.FullName;')-and
        -not($initialize.Extent.Text-match'Add-Type|RegisterClientSideProviderAssembly\('))
}
Check 'generic caller preserves explicit assembly across scrub and default selects canonical without build' {
    $present=[Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY')
    $saved=$env:GRAPHCODE_VALIDATION_ASSEMBLY
    try{
        if([Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY')){
            Remove-Item -LiteralPath Env:\GRAPHCODE_VALIDATION_ASSEMBLY
        }
        Reset-Loader
        Initialize-CapUiaClient
        Assert ($script:loaderCalls-eq1-and$script:loaderPath.EndsWith('ValidationRunner\bin\Release\net10.0-windows\ValidationRunner.dll'))
        $env:GRAPHCODE_VALIDATION_ASSEMBLY='C:\explicit\current.dll'
        Reset-Loader
        Initialize-CapUiaClient
        Assert ($script:loaderPath-ceq'C:\explicit\current.dll')
        $supervisor=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Invoke-UiCapture.ps1'))
        Assert ($supervisor.Contains("`$workerEnvironment['GRAPHCODE_VALIDATION_ASSEMBLY']=`$env:GRAPHCODE_VALIDATION_ASSEMBLY")-and
            $supervisor.Contains('-HoldStdin -Environment $workerEnvironment')-and
            -not($initialize.Extent.Text-match'Build-CompiledValidationRunner|Copy-Item'))
    }finally{
        if($present){$env:GRAPHCODE_VALIDATION_ASSEMBLY=$saved}
        elseif([Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY')){
            Remove-Item -LiteralPath Env:\GRAPHCODE_VALIDATION_ASSEMBLY
        }
    }
}
$passed=@($results|Where-Object passed -EQ $true).Count
@{suite='WireCreateObservation';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeCalls=0;
    evidence='Actual extracted guard with controlled property getters; not runtime UIA evidence';cases=@($results)}|
    ConvertTo-Json -Depth 6|Set-Content (Join-Path $ScratchRoot 'report.json') -Encoding utf8NoBOM
@{suite='WireCreateObservation';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeCalls=0}|ConvertTo-Json -Compress
if($results.Count-ne15-or$passed-ne15){exit 1}
