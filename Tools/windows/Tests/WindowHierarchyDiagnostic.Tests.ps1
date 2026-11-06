[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $ScratchRoot){throw 'Fresh diagnostic test scratch is required.'}
$null=[IO.Directory]::CreateDirectory($ScratchRoot)
$path=Join-Path $PSScriptRoot '..\UiCaptureDriver.psm1'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
if($errors.Count-ne0){throw 'Actual module source must parse.'}
$assignment=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]-and
    $node.Left.Extent.Text-ceq'$nativeSource'},$false))
if($assignment.Count-ne1){throw 'Actual native source assignment missing/ambiguous.'}
$literal=@($assignment[0].Right.FindAll({param($node)$node-is[Management.Automation.Language.StringConstantExpressionAst]},$true))
if($literal.Count-ne1){throw 'Native source must be one actual literal.'}
$source=$literal[0].Value
$start=$source.IndexOf('if (SendMessageTimeoutW(window, 0x000D,')
$end=$source.IndexOf('NativeRect bounds;',$start)
if($start-lt0-or$end-le$start){throw 'Actual window text failure region missing.'}
$region=$source.Substring($start,$end-$start)
$condition='== IntPtr.Zero)'
$body=$region.Substring($region.IndexOf($condition)+$condition.Length).Trim()
if($body.StartsWith('{')){$body=$body.Substring(1,$body.Length-2).Trim()}
$body=$body.Replace('int nativeError = Marshal.GetLastWin32Error();','')
# Only the native-error value is controlled; the actual production throw/data block runs unchanged.
$fixture=@"
using System;
using System.Text;
public static class WindowCensusFailureFixture {
  public static void Throw(long handle, uint pid, uint thread, string className, int nativeError) {
    var window = new IntPtr(handle);
    var cls = new StringBuilder(className);
    $body
  }
}
"@
Add-Type -TypeDefinition $fixture
$results=[Collections.Generic.List[object]]::new()
function Check([string]$CaseName,[scriptblock]$Action){
    try{& $Action;$results.Add(@{name=$CaseName;passed=$true})}
    catch{$results.Add(@{name=$CaseName;passed=$false;error=$_.Exception.Message});Write-Host "FAIL $CaseName : $($_.Exception.Message)"}
}
function Assert-True([bool]$Value){if(-not$Value){throw 'Diagnostic assertion failed.'}}
Check 'actual throw construction preserves existing message and scalar native facts' {
    $caught=$null
    try{[WindowCensusFailureFixture]::Throw(71960082,17088,1234,'GraphCodeSheetHost',1460)}catch{$caught=$_.Exception.GetBaseException()}
    Assert-True ($caught-is[InvalidOperationException]-and$caught.Message-ceq'Window census text query failed/timed out for HWND 71960082')
    $facts=$caught.Data['WindowTextQueryFailure']
    Assert-True ($null-ne$facts-and$facts.Handle-eq71960082-and$facts.ProcessId-eq17088-and
        $facts.ThreadId-eq1234-and$facts.ClassName-ceq'GraphCodeSheetHost'-and$facts.Win32Error-eq1460)
    Assert-True ((@($facts.PSObject.Properties.Name|Sort-Object)-join',')-ceq'ClassName,Handle,ProcessId,ThreadId,Win32Error')
}
Check 'zero native error retained without inventing timeout cause' {
    $caught=$null
    try{[WindowCensusFailureFixture]::Throw(1,2,3,'STATIC',0)}catch{$caught=$_.Exception.GetBaseException()}
    Assert-True ($null-ne$caught.Data['WindowTextQueryFailure']-and$caught.Data['WindowTextQueryFailure'].Win32Error-eq0)
}
Check 'source keeps one original50ms query and PID filtering before text' {
    Assert-True ($region.Contains('name, 2, 50, out textResult)')-and
        [regex]::Matches($region,'SendMessageTimeoutW\(').Count-eq1)
    $method=$source.Substring($source.IndexOf('public static CapWindowNode[] WindowHierarchy('))
    Assert-True ($method.IndexOf('if (pid != expectedPid) return true;')-lt$method.IndexOf('SendMessageTimeoutW('))
    Assert-True (-not($body-match'GetWindowText|GetAncestor|GetWindow\(|GetDlgCtrlID|GetCapture|Thread.Sleep|Sleep\('))
}
Check 'source retains received thread return and immediately captures existing last-error cache' {
    Assert-True ($source.Contains('uint thread = GetWindowThreadProcessId(window, out pid);')-and
        $region-match'(?s)== IntPtr.Zero\)\s*\{\s*int nativeError = Marshal.GetLastWin32Error\(\);')
}
Check 'source forwards only closed scalar failure facts without changing rethrow' {
    $text=[IO.File]::ReadAllText($path)
    $begin=$text.IndexOf('function Get-CapOwnedWindowHierarchy {')
    $finish=$text.IndexOf('function Get-CapDirectChildren {',$begin)
    $helper=$text.Substring($begin,$finish-$begin)
    Assert-True ($helper.Contains("failedWindow=(`$cause.Data['WindowTextQueryFailure']|ConvertTo-Json -Depth 3 -Compress)")-and
        $helper.Contains("observedRows=(`$cause.Data['ObservedRows']|ConvertTo-Json -Depth 10 -Compress)")-and
        $helper-match'(?s)OwnedWindowCensusFailure.*?\}\s*throw')
}
$passed=@($results|Where-Object passed -EQ $true).Count
@{suite='WindowHierarchyDiagnostic';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0
    nativeCalls=0;evidence='Actual extracted managed throw/data construction plus source contracts; not native fault behavior';cases=@($results)}|
    ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $ScratchRoot 'report.json') -Encoding utf8NoBOM
@{suite='WindowHierarchyDiagnostic';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeCalls=0}|ConvertTo-Json -Compress
if($results.Count-ne5-or$passed-ne5){exit 1}
