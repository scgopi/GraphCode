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
$end=$source.IndexOf('        }',$source.IndexOf('throw error;',$start))+'        }'.Length
if($start-lt0-or$end-le$start){throw 'Actual window text failure region missing.'}
$region=$source.Substring($start,$end-$start)
$condition='== IntPtr.Zero)'
$body=$region.Substring($region.IndexOf($condition)+$condition.Length).Trim()
if($body.StartsWith('{')){$body=$body.Substring(1,$body.Length-2).Trim()}
$body=$body.Replace('int nativeError = Marshal.GetLastWin32Error();','')
# Native observations are controlled; the actual production throw/data block runs unchanged.
$fixture=@"
using System;
using System.Text;
public static class WindowCensusFailureFixture {
  private struct NativeRect { public int Left, Top, Right, Bottom; }
  public static void Throw(long handle, uint pid, uint thread, string className, int nativeError) {
    var window = new IntPtr(handle);
    var cls = new StringBuilder(className);
    long parent = 555, owner = 666;
    bool visible = false, enabled = true;
    var bounds = new NativeRect { Left=-10, Top=20, Right=300, Bottom=400 };
    _ = parent; _ = owner; _ = visible; _ = enabled; _ = bounds;
    $body
  }
}
"@
Add-Type -TypeDefinition $fixture
$nodeStart=$source.IndexOf('public sealed class CapWindowNode {')
$nodeEnd=$source.IndexOf('public sealed class CapPointerReceipt {',$nodeStart)
$selectionStart=$source.IndexOf('public static CapWindowNode[] SelectWindowFamily(')
$ancestryStart=$source.IndexOf('public static void AssertWindowAncestry(')
if($ancestryStart-ge0){$selectionStart=$ancestryStart}
$selectionEnd=$source.IndexOf('public static CapWindowNode[] WindowHierarchy(')
$selection=if($selectionStart-ge0){$source.Substring($selectionStart,$selectionEnd-$selectionStart)}else{''}
Add-Type -TypeDefinition ("using System;`n"+$source.Substring($nodeStart,$nodeEnd-$nodeStart)+
    "`npublic static class WindowFamilySelectionFixture {`n"+$selection+"`n}")
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
        $facts.ThreadId-eq1234-and$facts.ClassName-ceq'GraphCodeSheetHost'-and$facts.Win32Error-eq1460-and
        $facts.Parent-eq555-and$facts.Owner-eq666-and$facts.Visible-eq$false-and$facts.Enabled-eq$true-and
        $facts.Left-eq-10-and$facts.Top-eq20-and$facts.Right-eq300-and$facts.Bottom-eq400)
    Assert-True ((@($facts.PSObject.Properties.Name|Sort-Object)-join',')-ceq'Bottom,ClassName,Enabled,Handle,Left,Owner,Parent,ProcessId,Right,ThreadId,Top,Visible,Win32Error')
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
    $method=$method.Substring(0,$method.IndexOf('public static int[] ConvertPointerScreen'))
    Assert-True ($method.Contains('WindowHierarchy(IntPtr rootWindow, int expectedPid)')-and
        $method.IndexOf('SelectWindowFamily(')-lt$method.IndexOf('SendMessageTimeoutW(')-and
        $method.IndexOf('foreach (var node in family)')-lt$method.IndexOf('SendMessageTimeoutW(')-and
        $method.Contains('if (pid != expectedPid) throw')-and
        $method.Contains('if (rootWindow == IntPtr.Zero || expectedPid <= 0)'))
    foreach($query in @('GetWindowRect(window, out bounds)','GetAncestor(window, 1)','GetWindow(window, 4)',
        'IsWindowVisible(window)','IsWindowEnabled(window)')){
        Assert-True ([regex]::Matches($method,[regex]::Escape($query)).Count-eq1-and
            $method.IndexOf($query)-lt$method.IndexOf('SendMessageTimeoutW('))
    }
    Assert-True ($method.Contains('Parent=parent, Owner=owner')-and
        $method.Contains('Visible=visible, Enabled=enabled')-and
        $method-match'(?s)var liveTopology = ReadTopology\(window, pid\);\s*AssertWindowAncestry\(node, liveTopology\);\s*long parent = liveTopology.Parent, owner = liveTopology.Owner;\s*UIntPtr textResult;\s*if \(SendMessageTimeoutW')
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
        $helper.Contains("ancestryChange=(`$cause.Data['WindowAncestryFailure']|ConvertTo-Json -Depth 3 -Compress)")-and
        $helper.Contains("observedRows=(`$cause.Data['ObservedRows']|ConvertTo-Json -Depth 10 -Compress)")-and
        $helper.Contains('[CapNative]::WindowHierarchy($RootHandle,$ProcessIdentity.Pid)')-and
        $helper-match'(?s)OwnedWindowCensusFailure.*?\}\s*throw')
    $directory=Split-Path -Parent $path
    $entryText=[IO.File]::ReadAllText((Join-Path $directory 'Invoke-MatchedActionSupplement.ps1'))
    Assert-True ($entryText.Contains('[switch]$WireCensusDiagnostic')-and
        $entryText.Contains('-FirstCensusDiagnostic:$WireCensusDiagnostic')-and
        $entryText.Contains("'DIAGNOSTIC_NOT_W1_ACCEPTANCE'")-and
        $entryText.Contains('$wireCensusDiagnosticMode=$WireCensusDiagnostic.IsPresent')-and
        $entryText.Contains('$null -ne $receipt -or $actionSupplementReceipts.Count -ne 0 -or $images.Count -ne 0'))
    $entryAst=[Management.Automation.Language.Parser]::ParseInput($entryText,[ref]$null,[ref]$null)
    $refusal=$entryAst.Find({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and
        $n.Clauses[0].Item1.Extent.Text-ceq'$WireCensusDiagnostic -and (-not $FunctionalWireOnly -or $DryRun)'},$true)
    Assert-True ($null-ne$refusal)
    foreach($options in @(@($false,$false),@($true,$true))){
        $WireCensusDiagnostic=$true;$FunctionalWireOnly=$options[0];$DryRun=$options[1]
        $refused=$false
        try{& ([scriptblock]::Create($refusal.Extent.Text))}catch{$refused=$_.Exception.Message-ceq'Wire census diagnostic requires FunctionalWireOnly and refuses DryRun.'}
        Assert-True $refused
    }
    $WireCensusDiagnostic=$true;$FunctionalWireOnly=$true;$DryRun=$false
    & ([scriptblock]::Create($refusal.Extent.Text))
    $statusStatements=@($entryAst.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and
        $n.Left.Extent.Text-cin@('$successfulStatus','$terminalOutcome')},$true))
    Assert-True ($statusStatements.Count-eq2)
    foreach($diagnostic in @($false,$true)){
        $WireCensusDiagnostic=$diagnostic;$primaryFailure=$null;$cleanupFailures=@();$independent=@()
        foreach($statement in $statusStatements){. ([scriptblock]::Create($statement.Extent.Text))}
        Assert-True ($terminalOutcome-ceq$(if($diagnostic){'DIAGNOSTIC_NOT_W1_ACCEPTANCE'}else{'COMPLETE'}))
        $primaryFailure='Controlled failure'
        . ([scriptblock]::Create($statusStatements[1].Extent.Text))
        Assert-True ($terminalOutcome-ceq'FAILED')
        $primaryFailure=$null;$cleanupFailures=@('Controlled cleanup failure')
        . ([scriptblock]::Create($statusStatements[1].Extent.Text))
        Assert-True ($terminalOutcome-ceq'FAILED')
    }
    $workerText=[IO.File]::ReadAllText((Join-Path $directory 'Invoke-UiCaptureWorker.ps1'))
    $workerAst=[Management.Automation.Language.Parser]::ParseInput($workerText,[ref]$null,[ref]$null)
    $wire=$workerAst.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and
        $n.Name-ceq'Invoke-CapWireCompletionSupplement'},$true)
    $branch=$wire.Find({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and
        $n.Clauses[0].Item1.Extent.Text-ceq'$FirstCensusDiagnostic'},$true)
    Assert-True ($null-ne$branch-and$branch.Extent.StartOffset-lt$workerText.IndexOf('$sheet=Resolve-CapOwnedSheet -Rows $hierarchy'))
    Assert-True ([regex]::Matches($branch.Extent.Text,'Read-CapWireWindowObservation').Count-eq1-and
        -not($branch.Extent.Text-match'Resolve-CapOwnedSheet|Read-UiaReadonlyEdgeEndpoints|Start-Sleep|GetCurrentPattern'))
    $wireTry=@($wire.Body.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.TryStatementAst]})
    Assert-True ($wireTry.Count-eq1-and$wireTry[0].Body.Extent.StartOffset-lt$branch.Extent.StartOffset-and
        $wireTry[0].Finally.Extent.Text.Contains('Close-CapGraphCodeApp -AppRun $app')-and
        $wireTry[0].Finally.Extent.Text.Contains('Stop-CapManagedProcess -Identity $stub.Identity')-and
        $wireTry[0].Finally.Extent.Text.Contains('if (-not $primary -and $wireCleanupErrors.Count -gt 0)'))
    function Read-CapWireWindowObservation {param($AppRun,$Stage)
        $script:diagnosticReads++
        if($script:diagnosticError){throw $script:diagnosticError}
        return [pscustomobject]@{Handle=123}
    }
    function Write-CapTrace {param($Command,$Parameters)}
    $app=[pscustomobject]@{Window=123};$FirstCensusDiagnostic=$true
    $script:diagnosticReads=0;$script:diagnosticError=$null;$cleanup=0
    $transaction=[scriptblock]::Create($branch.Extent.Text+"`nthrow 'Diagnostic crossed first-census boundary.'")
    try{& $transaction}finally{$cleanup++}
    Assert-True ($script:diagnosticReads-eq1-and$cleanup-eq1)
    try{[WindowCensusFailureFixture]::Throw(71960082,17088,1234,'ComboLBox',1460)}
    catch{$script:diagnosticError=$_.Exception.GetBaseException()}
    $caught=$null
    try{& $transaction}catch{$caught=$_.Exception}finally{$cleanup++}
    Assert-True ([object]::ReferenceEquals($caught,$script:diagnosticError)-and
        $script:diagnosticReads-eq2-and$cleanup-eq2-and$caught.Data['WindowTextQueryFailure'].Owner-eq666-and
        @($caught.Data['WindowTextQueryFailure'].PSObject.Properties).Count-eq13)
    $FirstCensusDiagnostic=$false;$script:diagnosticError=$null
    & ([scriptblock]::Create($branch.Extent.Text+"`n`$script:defaultContinued=`$true"))
    Assert-True ($script:defaultContinued-and$script:diagnosticReads-eq2)
}
function Scope-Node([long]$Handle,[long]$Parent=0,[long]$Owner=0,[int]$ProcessId=7,[bool]$Visible=$true){
    $node=[CapWindowNode]::new()
    $node.Handle=$Handle;$node.Parent=$Parent;$node.Owner=$Owner;$node.ProcessId=$ProcessId
    $node.Visible=$Visible;$node.Enabled=$false;$node.ClassName='ArbitraryClass'
    return $node
}
function Select-Scope($Rows,[long[]]$Tops,[long]$Root=1){
    return ,@([WindowFamilySelectionFixture]::SelectWindowFamily([CapWindowNode[]]$Rows,$Tops,$Root,7))
}
Check 'scope keeps exact root without inspecting its external parent' {
    $actual=Select-Scope @((Scope-Node 1 65548)) @(1)
    Assert-True ($actual.Count-eq1-and$actual[0].Handle-eq1)
}
Check 'scope keeps hidden disabled child and grandchild' {
    $actual=Select-Scope @((Scope-Node 1),(Scope-Node 2 1 0 7 $false),(Scope-Node 3 2 0 7 $false)) @(1,2)
    Assert-True (($actual.Handle-join',')-ceq'1,2,3')
}
Check 'scope retains owned host viewport native form and scrim' {
    $actual=Select-Scope @((Scope-Node 1),(Scope-Node 2 0 1),(Scope-Node 3 2),(Scope-Node 4 3),
        (Scope-Node 5 0 1 7 $false)) @(1,2,5)
    Assert-True (($actual.Handle-join',')-ceq'1,2,3,4,5')
}
Check 'scope retains nested owned modal and its hidden child' {
    $actual=Select-Scope @((Scope-Node 1),(Scope-Node 2 0 1),(Scope-Node 3 0 2),
        (Scope-Node 4 3 0 7 $false)) @(1,2,3)
    Assert-True (($actual.Handle-join',')-ceq'1,2,3,4')
}
Check 'scope classification does not depend on enumeration order' {
    $actual=Select-Scope @((Scope-Node 4 3),(Scope-Node 3 0 2),(Scope-Node 2 0 1),(Scope-Node 1)) @(3,1,2)
    Assert-True ((@($actual.Handle|Sort-Object)-join',')-ceq'1,2,3,4')
}
Check 'scope excludes positively unrelated families regardless of visibility or class' {
    $related=Scope-Node 2 1 0 7 $false;$related.ClassName='ComboLBox'
    $other=Scope-Node 8 65548 0 7 $true;$other.ClassName='ComboLBox'
    $actual=Select-Scope @((Scope-Node 1),$related,$other,(Scope-Node 9 0 8 7 $false),(Scope-Node 10 9)) @(1,8,9)
    Assert-True (($actual.Handle-join',')-ceq'1,2')
}
foreach($fault in @('zero-root','missing-root','duplicate-root','conflicting-duplicate','owner-cycle',
    'parent-cycle','missing-owner','missing-parent','foreign-descendant','foreign-root')){
    Check "scope refuses $fault" {
        $rows=@((Scope-Node 1),(Scope-Node 2 1));$tops=@(1L);$root=1L
        switch($fault){
            'zero-root' {$root=0L}
            'missing-root' {$rows=@((Scope-Node 2));$tops=@(2L)}
            'duplicate-root' {$rows+=$rows[0]}
            'conflicting-duplicate' {$rows+=(Scope-Node 2 99)}
            'owner-cycle' {$rows+=@((Scope-Node 3 0 4),(Scope-Node 4 0 3));$tops+=@(3L,4L)}
            'parent-cycle' {$rows[1].Parent=3;$rows+=(Scope-Node 3 2)}
            'missing-owner' {$rows+=(Scope-Node 3 0 99);$tops+=3L}
            'missing-parent' {$rows[1].Parent=99}
            'foreign-descendant' {$rows[1].ProcessId=8}
            'foreign-root' {$rows[0].ProcessId=8}
        }
        $caught=$null
        try{Select-Scope $rows $tops $root|Out-Null}catch{$caught=$_.Exception.GetBaseException()}
        Assert-True ($caught-is[InvalidOperationException]-and$caught.Message.StartsWith('Window family:'))
        if($fault-ceq'owner-cycle'){
            $rows=@((Scope-Node 1 0 2),(Scope-Node 2 0 1));$caught=$null
            try{Select-Scope $rows @(1,2)|Out-Null}catch{$caught=$_.Exception.GetBaseException()}
            Assert-True ($caught-is[InvalidOperationException]-and$caught.Message-ceq'Window family: cyclic ownership.')
            $rows=@((Scope-Node 1 0 2),(Scope-Node 2 1));$caught=$null
            try{Select-Scope $rows @(1,2)|Out-Null}catch{$caught=$_.Exception.GetBaseException()}
            Assert-True ($caught-is[InvalidOperationException]-and$caught.Message-ceq'Window family: cyclic ancestry.')
        }
    }
}
Check 'live ancestry accepts stable identity and relationships' {
    $expected=Scope-Node 2 1
    $observed=Scope-Node 2 1
    [WindowFamilySelectionFixture]::AssertWindowAncestry($expected,$observed)
    Assert-True ($observed.Parent-eq1-and$observed.Owner-eq0)
}
foreach($field in @('Parent','Owner','Handle','ProcessId')){
    Check "live ancestry refuses changed $field with observed scalar evidence" {
        $expected=Scope-Node 2 1
        $observed=Scope-Node 2 1
        $observed.$field=99
        $caught=$null
        try{[WindowFamilySelectionFixture]::AssertWindowAncestry($expected,$observed)}
        catch{$caught=$_.Exception.GetBaseException()}
        Assert-True ($caught-is[InvalidOperationException]-and$caught.Message-ceq'Window family: selected ancestry changed.')
        $facts=$caught.Data['WindowAncestryFailure']
        Assert-True ($facts.$field-eq99-and$facts.ExpectedParent-eq1-and$facts.ExpectedOwner-eq0-and
            $facts.ExpectedHandle-eq2-and$facts.ExpectedProcessId-eq7-and
            (@($facts.PSObject.Properties.Name|Sort-Object)-join',')-ceq'ExpectedHandle,ExpectedOwner,ExpectedParent,ExpectedProcessId,Handle,Owner,Parent,ProcessId')
    }
}
$passed=@($results|Where-Object passed -EQ $true).Count
@{suite='WindowHierarchyDiagnostic';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0
    nativeCalls=0;evidence='Actual extracted managed throw/data construction plus source contracts; not native fault behavior';cases=@($results)}|
    ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $ScratchRoot 'report.json') -Encoding utf8NoBOM
@{suite='WindowHierarchyDiagnostic';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeCalls=0}|ConvertTo-Json -Compress
if($results.Count-ne26-or$passed-ne26){exit 1}
