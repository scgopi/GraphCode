param([Parameter(Mandatory)][string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path $ScratchRoot){throw 'Fresh scratch required.'}
$null=[IO.Directory]::CreateDirectory($ScratchRoot)
$path=Join-Path $PSScriptRoot '..\UiCaptureDriver.psm1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
$assignment=$ast.Find({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq'$nativeSource'},$false)
$literal=$assignment.Right.Find({param($n)$n-is[Management.Automation.Language.StringConstantExpressionAst]},$true)
$source=$literal.Value
$start=$source.IndexOf('public static string DecodeImagePath(')
$end=$source.IndexOf('public static string ImagePath(')
$body=if($start-ge0-and$end-gt$start){$source.Substring($start,$end-$start)}else{''}
Add-Type -TypeDefinition ("using System;using System.Runtime.InteropServices;using System.ComponentModel;public static class ImageDecoderFixture {"+$body+"}")
$results=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Action){
    try{&$Action;$results.Add(@{name=$Name;passed=$true})}
    catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}
}
function Assert([bool]$Value){if(-not$Value){throw 'Assertion failed.'}}
function Buffer([string]$Text,[int]$Capacity,[bool]$Terminated=$true){
    $pointer=[Runtime.InteropServices.Marshal]::AllocHGlobal($Capacity*2)
    for($i=0;$i-lt$Capacity;$i++){[Runtime.InteropServices.Marshal]::WriteInt16($pointer,$i*2,[int16]-1)}
    for($i=0;$i-lt$Text.Length;$i++){
        $unit=[int][char]$Text[$i]
        if($unit-gt32767){$unit-=65536}
        [Runtime.InteropServices.Marshal]::WriteInt16($pointer,$i*2,[int16]$unit)
    }
    if($Terminated){[Runtime.InteropServices.Marshal]::WriteInt16($pointer,$Text.Length*2,[int16]0)}
    return $pointer
}
function Decode([bool]$Success,[int]$Error,[IntPtr]$Pointer,[int]$Capacity,[uint32]$Length){
    return [ImageDecoderFixture]::DecodeImagePath($Success,$Error,$Pointer,$Capacity,$Length)
}
function Reject([scriptblock]$Action,[type]$Type){
    $caught=$null
    try{&$Action|Out-Null}catch{$caught=$_.Exception.GetBaseException()}
    Assert ($null-ne$caught-and$Type.IsInstanceOfType($caught))
    return $caught
}
Check 'successful Unicode image decodes exact reported length' {
    $text='C:\owned\'+[char]0x96EA+'.exe'
    $pointer=Buffer $text 32
    try{Assert ((Decode $true 0 $pointer 32 $text.Length)-ceq$text)}
    finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)}
    $text='x'*32767
    $pointer=Buffer $text 32768
    try{Assert ((Decode $true 0 $pointer 32768 32767).Length-eq32767)}
    finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)}
}
Check 'failed query preserves real native error without reading poisoned buffer or length' {
    $error=Reject {Decode $false 5 ([IntPtr]1) 0 ([uint32]::MaxValue)} ([ComponentModel.Win32Exception])
    Assert ($error.NativeErrorCode-eq5)
}
Check 'failed query with native error zero remains failure not a successful default' {
    $error=Reject {Decode $false 0 ([IntPtr]::Zero) 0 0} ([ComponentModel.Win32Exception])
    Assert ($error.NativeErrorCode-eq0)
}
Check 'success zero or overflowing length refuses before buffer read' {
    foreach($length in @(0,32,33)){
        $null=Reject {Decode $true 0 ([IntPtr]1) 32 $length} ([InvalidOperationException])
    }
}
Check 'missing output terminator refuses' {
    $pointer=Buffer 'abc' 8 $false
    try{$null=Reject {Decode $true 0 $pointer 8 3} ([InvalidOperationException])}
    finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)}
}
Check 'embedded null cannot shorten the reported image' {
    $pointer=Buffer "a`0b" 8
    try{$null=Reject {Decode $true 0 $pointer 8 3} ([InvalidOperationException])}
    finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)}
}
Check 'successful null buffer refuses' {
    $null=Reject {Decode $true 0 ([IntPtr]::Zero) 8 3} ([InvalidOperationException])
}
Check 'uninitialized sentinel buffer cannot become image success' {
    $pointer=Buffer '' 8 $false
    try{$null=Reject {Decode $true 0 $pointer 8 3} ([InvalidOperationException])}
    finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)}
}
Check 'source uses fixed native buffer and preserves immediate error and finally free' {
    $image=$source.Substring($end,$source.IndexOf('public static CapProcessSnapshot Snapshot(',$end)-$end)
    Assert ($source.Contains('IntPtr image, ref uint size)')-and
        $image-match'bool success = QueryFullProcessImageNameW\(handle, 0, buffer, ref size\);\s*int nativeError = Marshal.GetLastWin32Error\(\);'-and
        $image.Contains('Array.Fill(initialized, (short)-1);')-and
        $image.Contains('finally { Marshal.FreeHGlobal(buffer); }')-and
        $image.Contains('GetProcessId(handle) != (uint)expectedPid')-and
        $image.Contains('const int capacity = 32768;')-and
        -not($image-match'StringBuilder|catch|Thread.Sleep'))
}
$passed=@($results|Where-Object passed -EQ $true).Count
@{suite='NativeImageBuffer';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeQueries=0;
    evidence='Actual extracted decoder with controlled managed-owned buffers; not historical native-query cause proof';cases=@($results)}|
    ConvertTo-Json -Depth 5|Set-Content (Join-Path $ScratchRoot 'report.json') -Encoding utf8NoBOM
@{suite='NativeImageBuffer';executed=$results.Count;passed=$passed;failed=$results.Count-$passed;skipped=0;nativeQueries=0}|ConvertTo-Json -Compress
if($results.Count-ne9-or$passed-ne9){exit 1}
