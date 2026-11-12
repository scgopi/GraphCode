param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('wt' + [guid]::NewGuid().ToString('N').Substring(0,8))),
    [switch]$LegacyBehavior,
    [switch]$DispatchOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($LegacyBehavior -and $DispatchOnly) {throw 'LegacyBehavior and DispatchOnly are mutually exclusive.'}
$directory=Split-Path -Parent $PSScriptRoot
$repository=Split-Path -Parent (Split-Path -Parent $directory)
Import-Module (Join-Path $directory 'UiCaptureDriver.psm1') -Force -WarningAction SilentlyContinue
if (Test-Path -LiteralPath $ScratchRoot) {throw 'Refusing to overwrite wire evidence.'}
$null=New-Item -ItemType Directory -Path $ScratchRoot
Set-CapTracePath -Path (Join-Path $ScratchRoot 'calls.jsonl')
$results=[Collections.Generic.List[object]]::new()
function Test-WireCase {
    param([string]$Name,[scriptblock]$CaseAction)
    try {& $CaseAction; $results.Add(@{name=$Name;passed=$true})}
    catch {$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}
}
function Assert-WireCase {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) {throw $Message}
}
function Reject-WireCase {
    param([string]$Name,[scriptblock]$Body,[string]$Message)
    Test-WireCase $Name {
        $failure=$null
        try {& $Body|Out-Null} catch {$failure=$_}
        Assert-WireCase ($null -ne $failure -and $failure.Exception.Message.Contains($Message)) `
            "Expected refusal '$Message'; actual=$failure"
    }
}

if (-not $LegacyBehavior) {
    Test-WireCase 'actual worker dispatch presses source then holds moves and releases target' {
        Add-Type -TypeDefinition @'
using System;
public static class WireDispatchRecorder {
  public static object[] PostPointerClickScreen(IntPtr window,int x,int y) {
    return new object[] { "click",window.ToInt64(),x,y };
  }
  public static object[] PostPointerDragScreen(IntPtr window,int sx,int sy,int tx,int ty) {
    return new object[] { "drag",window.ToInt64(),sx,sy,tx,ty };
  }
}
'@
        $tokens=$null;$parseErrors=$null
        $worker=[Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $directory 'Invoke-UiCaptureWorker.ps1'),[ref]$tokens,[ref]$parseErrors)
        Assert-WireCase ($parseErrors.Count -eq 0) 'Worker source did not parse.'
        $functions=@($worker.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-CapWireCompletionSupplement'
        },$false))
        Assert-WireCase ($functions.Count -eq 1) 'Expected the actual Wire supplement definition.'
        $assignments=@($functions[0].Body.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -cin @('$sourceX','$sourceY','$targetX','$targetY','$dispatch')
        },$false))
        $calls=@($assignments|Where-Object {$_.Left.Extent.Text -ceq '$dispatch'})
        Assert-WireCase ($calls.Count -eq 1 -and $calls[0].Right.Extent.Text.StartsWith('[CapNative]::')) `
            'Expected one actual CapNative worker dispatch boundary.'
        $app=[pscustomobject]@{Window=[IntPtr]123}
        $reacquired=[pscustomobject]@{sourceScreenPoint=@(250,48);screenPoint=@(393,15)}
        $dispatch=$null
        foreach ($assignment in $assignments) {
            $statement=$assignment.Extent.Text
            if ($assignment.Left.Extent.Text -ceq '$dispatch') {
                $statement=$statement.Replace('[CapNative]::','[WireDispatchRecorder]::')
            }
            . ([scriptblock]::Create($statement))
        }
        Assert-WireCase ($dispatch[1] -eq 123) 'Worker dispatched to a different root HWND.'
        $script:dragMessages=[Collections.Generic.List[string]]::new()
        $poster=[Func[uint32,uint32,long,bool]]{
            param($message,$keys,$position)
            $script:dragMessages.Add("$message/$keys/$position")
            return $true
        }
        if ($dispatch[0] -ceq 'click') {
            $receipt=[CapPointerReceipt]::new()
            $receipt.PackedLParam=($dispatch[3] -shl 16) -bor $dispatch[2]
            [CapNative]::DispatchPointerMessages($receipt,$poster)
        } elseif ($dispatch[0] -ceq 'drag') {
            $receipt=New-Object -TypeName CapPointerDragReceipt
            $receipt.Start=[CapPointerReceipt]::new();$receipt.End=[CapPointerReceipt]::new()
            $receipt.Start.PackedLParam=($dispatch[3] -shl 16) -bor $dispatch[2]
            $receipt.End.PackedLParam=($dispatch[5] -shl 16) -bor $dispatch[4]
            [CapNative]::DispatchPointerDragMessages($receipt,$poster)
        } else {throw "Unexpected worker dispatch: $($dispatch[0])"}
        $actual=$script:dragMessages -join ','
        Assert-WireCase ($actual -ceq '512/0/3145978,513/1/3145978,512/1/983433,514/0/983433') `
            "Worker gesture must press source, hold-move, release target; actual=$actual"
    }
    Test-WireCase 'actual worker reads exact locked endpoints before Create and refuses invalid fields' {
        $tokens=$null;$parseErrors=$null
        $worker=[Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $directory 'Invoke-UiCaptureWorker.ps1'),[ref]$tokens,[ref]$parseErrors)
        Assert-WireCase ($parseErrors.Count -eq 0) 'Worker source did not parse.'
        $function=$worker.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-CapWireCompletionSupplement'
        },$false)
        $body=@($function.Body.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0].Body
        $statements=@($body.Statements)
        $createIndexes=@(for ($i=0;$i -lt $statements.Count;$i++) {
            if ($statements[$i].Extent.Text -ceq
                '$creates[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()') {$i}
        })
        Assert-WireCase ($createIndexes.Count -eq 1) 'Expected the actual worker Create boundary.'
        $createIndex=$createIndexes[0]
        $readerIndexes=@(for ($i=0;$i -lt $createIndex;$i++) {
            if ($statements[$i].Extent.Text -match '^\$endpoints\s*=\s*Read-UiaReadonlyEdgeEndpoints\b') {$i}
        })
        Assert-WireCase ($readerIndexes.Count -le 1) 'Duplicate endpoint observations before Create.'
        $first=if ($readerIndexes.Count -eq 1) {$readerIndexes[0]} else {$createIndex}
        $transaction=[scriptblock]::Create(($statements[$first..$createIndex].Extent.Text -join "`n"))
        $sourceId='60000000-0000-4000-8000-000000000001'
        $targetId='60000000-0000-4000-8000-000000000002'
        $app=[pscustomobject]@{Window=[IntPtr]123;Run=[pscustomobject]@{Identity=[pscustomobject]@{Pid=4242}}}
        $formElement=[pscustomobject]@{Identity='owned-form'}
        $invoker=[pscustomobject]@{}
        $invoker|Add-Member ScriptMethod Invoke {
            $script:wireEndpointState.calls.Add('create')
            $script:wireEndpointState.creates++
        }
        $create=[pscustomobject]@{Invoker=$invoker}
        $create|Add-Member ScriptMethod GetCurrentPattern {param($pattern) return $this.Invoker}
        $creates=@($create)
        function Read-UiaReadonlyEdgeEndpoints {
            param($Dialog,$ProcessId,$Owner,$Title,$ExpectedSource,$ExpectedTarget,$AssemblyPath)
            $script:wireEndpointState.calls.Add('read')
            Assert-WireCase ($Dialog -eq $formElement -and $ProcessId -eq 4242 -and $Owner -eq [IntPtr]123 -and
                $ExpectedSource -ceq $sourceId -and $ExpectedTarget -ceq $targetId) 'Worker endpoint binding differs.'
            if ($script:wireEndpointState.scenario -cin @('missing','writable','mutable')) {
                throw "Endpoint refusal: $($script:wireEndpointState.scenario)"
            }
            return @{source=$(if ($script:wireEndpointState.scenario -ceq 'wrong-source') {$targetId} else {$sourceId})
                target=$(if ($script:wireEndpointState.scenario -ceq 'wrong-target') {$sourceId} else {$targetId})
                snapshot=@{fields=@(@{controlId=9100;readonly=$true},@{controlId=9101;readonly=$true})}}
        }
        foreach ($scenario in @('valid','wrong-source','wrong-target','missing','writable','mutable')) {
            $script:wireEndpointState=@{scenario=$scenario;creates=0;calls=[Collections.Generic.List[string]]::new()}
            $endpoints=$null;$failure=$null
            try {. $transaction} catch {$failure=$_}
            if ($scenario -ceq 'valid') {
                Assert-WireCase ($null -eq $failure -and $script:wireEndpointState.creates -eq 1 -and
                    ($script:wireEndpointState.calls -join ',') -ceq 'read,create' -and
                    $null -ne $endpoints.snapshot) `
                    "Actual worker must read exact locked endpoints before Create; actual=$($script:wireEndpointState.calls -join ','); failure=$failure"
            } else {
                Assert-WireCase ($null -ne $failure -and $script:wireEndpointState.creates -eq 0 -and
                    ($script:wireEndpointState.calls -join ',') -ceq 'read') `
                    "Actual worker invoked Create after $scenario endpoint refusal."
            }
        }
    }
    Test-WireCase 'shared readonly endpoint decision preserves ordinary defaults and exact Wire identities' {
        $reader=(Get-Command Read-UiaReadonlyEdgeEndpoints -CommandType Function).ScriptBlock.Ast
        $defaults=@{}
        foreach ($parameter in $reader.Body.ParamBlock.Parameters) {
            if ($parameter.Name.VariablePath.UserPath -cin @('ExpectedSource','ExpectedTarget')) {
                $defaults[$parameter.Name.VariablePath.UserPath]=$parameter.DefaultValue.SafeGetValue()
            }
        }
        Assert-WireCase ($defaults.ExpectedSource -ceq '11111111-1111-4111-8111-111111111111' -and
            $defaults.ExpectedTarget -ceq '22222222-2222-4222-8222-222222222222') 'Ordinary UIA fixture defaults changed.'
        foreach ($ids in @(
            @($defaults.ExpectedSource,$defaults.ExpectedTarget),
            @('60000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002'))) {
            $sample=@{
                handle=10;processId=123;owner=5;class='GraphCodeSheetHost';title='Create or edit edge';captionless=$true
                viewport=@{handle=11;parent=10;processId=123;class='GraphCodeSheetViewport';matches=1;stable=$true;runtime='11';owned=$true}
                content=@{handle=12;parent=11;processId=123;class='GraphCodeNativeForm';matches=1;stable=$true;runtime='12';owned=$true}
                fields=@(
                    @{handle=21;parent=12;processId=123;controlId=9100;class='Edit';matches=1;stable=$true;runtime='21';owned=$true
                        readonly=$true;nativeReadonly=$true;value=$ids[0];semanticValue=$ids[0];semanticProcessId=123;name='Source loop identity'},
                    @{handle=22;parent=12;processId=123;controlId=9101;class='Edit';matches=1;stable=$true;runtime='22';owned=$true
                        readonly=$true;nativeReadonly=$true;value=$ids[1];semanticValue=$ids[1];semanticProcessId=123;name='Target loop identity'})
            }
            Assert-WireCase (Get-UiaReadonlyEndpointsDecision $sample 123 5 'Create or edit edge' $ids[0] $ids[1]).ready `
                'Shared reader rejected matching native and semantic endpoint values.'
            foreach ($fault in @('missing','duplicate','wrong-id','wrong-pid','wrong-parent','wrong-sheet-owner',
                'writable','native-writable','missing-native-readonly','wrong-value','wrong-target','semantic-mismatch','stale','wrong-class')) {
                $changed=$sample|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
                switch ($fault) {
                    'missing' {$changed.fields=@($changed.fields[1])}
                    'duplicate' {$changed.fields[0].matches=2}
                    'wrong-id' {$changed.fields[0].controlId=9101}
                    'wrong-pid' {$changed.fields[0].processId=456}
                    'wrong-parent' {$changed.fields[0].parent=11}
                    'wrong-sheet-owner' {$changed.owner=6}
                    'writable' {$changed.fields[0].readonly=$false}
                    'native-writable' {$changed.fields[0].nativeReadonly=$false}
                    'missing-native-readonly' {$changed.fields[0].Remove('nativeReadonly')}
                    'wrong-value' {$changed.fields[0].value=$ids[1];$changed.fields[0].semanticValue=$ids[1]}
                    'wrong-target' {$changed.fields[1].value=$ids[0];$changed.fields[1].semanticValue=$ids[0]}
                    'semantic-mismatch' {$changed.fields[0].semanticValue=$ids[1]}
                    'stale' {$changed.fields[0].stable=$false}
                    'wrong-class' {$changed.fields[0].class='Static'}
                }
                Assert-WireCase (-not (Get-UiaReadonlyEndpointsDecision $changed 123 5 'Create or edit edge' $ids[0] $ids[1]).ready) `
                    "Shared reader accepted $fault endpoints."
            }
        }
    }
}

if (-not $DispatchOnly) {
# Harmless native hierarchy with the same parent/owner distinction as the sheet.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WireFixture {
  delegate IntPtr Proc(IntPtr window,uint message,IntPtr wp,IntPtr lp);
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
  struct Class {
    public uint Style; public Proc Procedure; public int ClassExtra,WindowExtra;
    public IntPtr Instance,Icon,Cursor,Brush; public string Menu,Name;
  }
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern ushort RegisterClassW(ref Class cls);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProcW(IntPtr w,uint m,IntPtr wp,IntPtr lp);
  static Proc procedure=DefWindowProcW;
  static WireFixture() {
    var cls=new Class { Procedure=procedure, Name="WireTargetFixture" };
    if(RegisterClassW(ref cls)==0) throw new Exception("Fixture class registration failed.");
    cls.Name="WireTargetFixtureContent";
    if(RegisterClassW(ref cls)==0) throw new Exception("Fixture child class registration failed.");
    foreach(var name in new[] { "GraphCodeSheetHost","GraphCodeSheetViewport","GraphCodeNativeForm" }) {
      cls.Name=name;
      if(RegisterClassW(ref cls)==0) throw new Exception("Endpoint fixture class registration failed.");
    }
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style,
    int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr value);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
  [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] struct Message {
    public IntPtr Window; public uint Id; public UIntPtr WParam; public IntPtr LParam;
    public uint Time; public Point Point; public uint Private;
  }
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
  [DllImport("user32.dll")] static extern bool PeekMessageW(out Message message,IntPtr window,uint first,uint last,uint remove);
  [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr window,uint message,IntPtr wp,IntPtr lp);
  public static void SetReadonly(IntPtr window,bool value) {
    if(SendMessageW(window,0x00CF,new IntPtr(value ? 1 : 0),IntPtr.Zero)==IntPtr.Zero)
      throw new Exception("Endpoint fixture readonly update failed.");
  }
  public static IntPtr[] CreateEndpoints(IntPtr owner,string source,string target) {
    IntPtr host=CreateWindowExW(0x08000008,"GraphCodeSheetHost","Create or edit edge",0x90000000,
      20,20,350,180,owner,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
    if(host==IntPtr.Zero) throw new Exception("Endpoint fixture host creation failed.");
    try {
      IntPtr viewport=CreateWindowExW(0,"GraphCodeSheetViewport","",0x50000000,
        0,0,350,180,host,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
      if(viewport==IntPtr.Zero) throw new Exception("Endpoint fixture viewport creation failed.");
      IntPtr content=CreateWindowExW(0,"GraphCodeNativeForm","",0x50000000,
        0,0,350,180,viewport,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
      if(content==IntPtr.Zero) throw new Exception("Endpoint fixture content creation failed.");
      IntPtr from=CreateWindowExW(0,"EDIT",source,0x50000800,
        5,5,320,25,content,new IntPtr(9100),IntPtr.Zero,IntPtr.Zero);
      if(from==IntPtr.Zero) throw new Exception("Endpoint fixture source creation failed.");
      IntPtr to=CreateWindowExW(0,"EDIT",target,0x50000800,
        5,40,320,25,content,new IntPtr(9101),IntPtr.Zero,IntPtr.Zero);
      if(to==IntPtr.Zero) throw new Exception("Endpoint fixture target creation failed.");
      return new[] { host,viewport,content,from,to };
    } catch(Exception primary) {
      if(!DestroyWindow(host)) throw new AggregateException(primary,new Exception("Endpoint fixture failed-launch cleanup failed."));
      throw;
    }
  }
  public static IntPtr AtPoint(int x,int y) { return WindowFromPoint(new Point { X=x,Y=y }); }
  public static bool HasPointerMessage(IntPtr window) {
    Message message; return PeekMessageW(out message,window,0x0200,0x0202,0);
  }
  public static uint OwnerProcess(IntPtr window) {
    uint processId; GetWindowThreadProcessId(window,out processId); return processId;
  }
  public static IntPtr Create(IntPtr parent, bool child, string name) {
    // Isolate only owned top-level fixtures without taking keyboard focus.
    IntPtr result=CreateWindowExW(child ? 0x08000000u : 0x08000008u,child ? "WireTargetFixtureContent" : "WireTargetFixture",
      name,child ? 0x50000000u : 0x90000000u,
      20,20,250,96,parent,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
    if(result==IntPtr.Zero) throw new Exception("Fixture CreateWindow failed.");
    return result;
  }
}
'@
$root=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero;$content=[IntPtr]::Zero
try {
    $fixtureDpiContext=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-4))
    Assert-WireCase ($fixtureDpiContext -ne [IntPtr]::Zero) 'Fixture PMv2 setup failed.'
    try {
        $root=[WireFixture]::Create([IntPtr]::Zero,$false,'wire fixture owner')
        $hostWindow=[WireFixture]::Create($root,$false,'wire fixture sheet')
        $content=[WireFixture]::Create($hostWindow,$true,'wire fixture content')
    } finally {$null=[WireFixture]::SetThreadDpiAwarenessContext($fixtureDpiContext)}
    if ($LegacyBehavior) {
        Test-WireCase 'owned child form is observable, not just a top-level class' {
            $actual=[CapUiaGateState]::FindTopLevel('WireTargetFixtureContent',[uint32]$PID)
            Assert-WireCase ($actual -eq $content) 'Top-level-only oracle missed the owned child content.'
        }
        Test-WireCase 'target point excludes the inline Mark action' {
            $point=@(125,48)
            Assert-WireCase (-not ($point[0] -ge 90 -and $point[0] -lt 176 -and
                $point[1] -ge 31 -and $point[1] -lt 51)) 'Card midpoint hits Mark as entry before generic node selection.'
        }
    } else {
        $binding=Get-CapWireTargetBinding -Repository $repository -OwnedRoot $ScratchRoot
        Test-WireCase 'production binding preserves exact planned UUIDs and source-derived title band' {
            $null=Assert-CapWireTargetBinding $binding $repository $ScratchRoot
            Assert-WireCase (($binding.safeLogicalBounds -join ',') -ceq '11,0,176,31' -and
                $binding.sourceNodeId -cne $binding.targetNodeId) 'Invalid source-derived safe region.'
        }
        foreach ($field in @('sourceNodeId','targetNodeId','sourceCardId','targetCardId','scene','phase','projectPath','wireId','sourceHashes','gesture','sourceConnector')) {
            $changed=$binding|ConvertTo-Json -Depth 20|ConvertFrom-Json
            $changed.$field='foreign'
            Reject-WireCase "reject planned $field drift" {
                Assert-CapWireTargetBinding $changed $repository $ScratchRoot
            } 'planned source/target binding differs'
        }
        Reject-WireCase 'reject absent target plan before launch' {
            Assert-CapWireTargetBinding $null $repository $ScratchRoot
        } 'binding differs'
        function New-WireRow {
            param([string]$Id,[string]$Name,[double[]]$Bounds)
            [pscustomobject]@{AutomationId=$Id;Name=$Name;ProcessId=$PID;IsEnabled=$true
                IsOffscreen=$false;Bounds=$Bounds;RuntimeId=@(1,2)}
        }
        $baseRows=@(
            (New-WireRow $binding.sourceCardId 'Wire source' @(0,0,250,96)),
            (New-WireRow $binding.targetCardId 'Wire target' @(300,0,550,96)),
            (New-WireRow $binding.wireId 'Wire it up' @(11,31,84,51)),
            (New-WireRow 'target-mark' 'Mark as entry' @(390,31,476,51)),
            (New-WireRow 'status' 'Choose a target loop to wire this entry' @(0,150,500,180)))
        foreach ($dpi in @(96,192)) {
            $rows=$baseRows|ConvertTo-Json -Depth 20|ConvertFrom-Json
            foreach ($row in $rows) {$row.Bounds=@($row.Bounds|ForEach-Object {$_*$dpi/96})}
            Test-WireCase "production safe target excludes inline Mark at DPI$dpi" {
                $observation=Get-CapWireTargetObservation $binding $rows $PID $dpi
                Assert-WireCase ($observation.screenPoint[1] -lt 31*$dpi/96 -and
                    $observation.screenPoint[0] -gt 300*$dpi/96 -and
                    ($observation.sourceScreenPoint -join ',') -ceq "$([int](250*$dpi/96)),$([int](48*$dpi/96))") `
                    'Target point hits inline action or source point misses connector.'
            }
        }
        Test-WireCase 'production algorithm preflight is explicitly model-only with no launch' {
            $proof=Get-CapWireAlgorithmPreflight $binding $PID
            Assert-WireCase (-not $proof.runtimeWindowEvidence -and $proof.productLaunches -eq 0 -and
                $proof.providerLaunches -eq 0 -and $proof.sheet.content.Handle -eq 4) 'Preflight inflated evidence.'
        }
        $first=Get-CapWireTargetObservation $binding $baseRows $PID 96
        Test-WireCase 'immutable reacquisition preserves exact target and root identity' {
            Assert-CapWireTargetStable $first $first @(1,2) @(1,2)
        }
        foreach ($fault in @('source','target','runtime','bounds','mode','root','source-point')) {
            $second=$first|ConvertTo-Json -Depth 20|ConvertFrom-Json
            $rootAfter=@(1,2)
            switch ($fault) {
                'source' {$second.source.AutomationId='foreign'}
                'target' {$second.target.AutomationId='foreign'}
                'runtime' {$second.target.RuntimeId=@(1,3)}
                'bounds' {$second.target.Bounds[0]++}
                'mode' {$second.mode='not armed'}
                'root' {$rootAfter=@(1,3)}
                'source-point' {$second.sourceScreenPoint[0]++}
            }
            Reject-WireCase "reacquisition rejects $fault drift" {
                Assert-CapWireTargetStable $first $second @(1,2) $rootAfter
            } 'drifted before dispatch'
        }
        foreach ($fault in @('source','target','mode','foreign-process','offscreen','disabled','bounds','NaN','duplicate','overlap','source-overlap')) {
            $rows=@($baseRows|ConvertTo-Json -Depth 20|ConvertFrom-Json)
            switch ($fault) {
                'source' {$rows[0].AutomationId='foreign'}
                'target' {$rows[1].Name='Wrong target'}
                'mode' {$rows[4].Name='Marked as an entry for this session'}
                'foreign-process' {$rows[1].ProcessId++}
                'offscreen' {$rows[1].IsOffscreen=$true}
                'disabled' {$rows[1].IsEnabled=$false}
                'bounds' {$rows[1].Bounds[2]++ ; $rows[1].Bounds[2]++}
                'NaN' {$rows[1].Bounds[0]=[double]::NaN}
                'duplicate' {$rows+= $rows[1]}
                'overlap' {$rows[3].Bounds=@(300,0,550,31)}
                'source-overlap' {$rows[3].Bounds=@(240,40,260,60)}
            }
            $message=switch ($fault) {
                'foreign-process' {'does not match owned PID'}
                {$_ -in @('offscreen','disabled','bounds','NaN')} {'bounds/scale'}
                'overlap' {'Unsafe wire target point'}
                'source-overlap' {'Unsafe wire source connector'}
                default {'identity or active Wire mode'}
            }
            Reject-WireCase "reject observed $fault" {
                Get-CapWireTargetObservation $binding $rows $PID 96
            } $message
        }
        $self=[Diagnostics.Process]::GetCurrentProcess()
        $identity=Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName -Role 'wire-fixture'
        $nativeRows=@(Get-CapOwnedWindowHierarchy -RootHandle $root -ProcessIdentity $identity)
        $changedIdentity=$identity.PSObject.Copy()
        $changedIdentity.CreationFileTimeUtc++
        Reject-WireCase 'owned census rejects changed held process generation' {
            Get-CapOwnedWindowHierarchy -RootHandle $root -ProcessIdentity $changedIdentity
        } 'Kernel process identity changed'
        Reject-WireCase 'owned census rejects replaced or absent root HWND' {
            Get-CapOwnedWindowHierarchy -RootHandle ([IntPtr]::Zero) -ProcessIdentity $identity
        } 'GetWindowThreadProcessId failed'
        Test-WireCase 'owned census trace preserves numeric handles and bounds, not object type names' {
            $trace=@(Get-Content (Join-Path $ScratchRoot 'calls.jsonl')|ForEach-Object {$_|ConvertFrom-Json}|
                Where-Object command -CEQ 'Get-CapOwnedWindowHierarchy')[-1]
            $observed=@($trace.parameters.rows|ConvertFrom-Json)
            Assert-WireCase (@($observed|Where-Object Handle -EQ $content.ToInt64()).Count -eq 1) `
                'Census trace lost actual native rows.'
        }
        [IO.File]::WriteAllText((Join-Path $ScratchRoot 'native-census.json'),
            (@{root=[long]$root;host=[long]$hostWindow;content=[long]$content;rows=$nativeRows}|ConvertTo-Json -Depth 20))
        Test-WireCase 'native census observes child and binds it to the owned sheet host' {
            $found=Resolve-CapOwnedSheet -Rows @($nativeRows|Where-Object Handle -NE $root.ToInt64()) `
                -RootHandle $root -ExpectedProcessId $PID -SheetClass 'WireTargetFixture' -ContentClass 'WireTargetFixtureContent'
            Assert-WireCase ($found.host.Handle -eq $hostWindow.ToInt64() -and
                $found.content.Handle -eq $content.ToInt64()) 'Owned child was not observed.'
        }
        $model=@(
            [pscustomobject]@{Handle=10L;Parent=0L;Owner=1L;ProcessId=$PID;ClassName='GraphCodeSheetHost';Visible=$true},
            [pscustomobject]@{Handle=11L;Parent=10L;Owner=0L;ProcessId=$PID;ClassName='viewport';Visible=$true},
            [pscustomobject]@{Handle=12L;Parent=11L;Owner=0L;ProcessId=$PID;ClassName='GraphCodeNativeForm';Visible=$true})
        Test-WireCase 'production oracle follows viewport ancestor rather than top-level-only class' {
            $found=Resolve-CapOwnedSheet $model 1 $PID
            Assert-WireCase ($found.content.Handle -eq 12 -and $found.host.Handle -eq 10) 'Child hierarchy missed.'
        }
        foreach ($fault in @('foreign-owner','missing-host','hidden-host','missing-child')) {
            $rows=@($model|ConvertTo-Json|ConvertFrom-Json)
            switch ($fault) {
                'foreign-owner' {$rows[0].Owner=99}
                'missing-host' {$rows=@($rows|Where-Object Handle -NE 10)}
                'hidden-host' {$rows[0].Visible=$false}
                'missing-child' {$rows=@($rows|Where-Object Handle -NE 12)}
            }
            Test-WireCase "no success for $fault" {
                Assert-WireCase ($null -eq (Resolve-CapOwnedSheet $rows 1 $PID)) 'Foreign/missing sheet accepted.'
            }
        }
        foreach ($fault in @('foreign-process','duplicate-host','duplicate-child','missing-ancestor','cycle')) {
            $rows=@($model|ConvertTo-Json|ConvertFrom-Json)
            switch ($fault) {
                'foreign-process' {$rows[2].ProcessId++}
                'duplicate-host' {$rows+=$rows[0]}
                'duplicate-child' {$rows+=$rows[2]}
                'missing-ancestor' {$rows[2].Parent=99}
                'cycle' {$rows[1].Parent=11}
            }
            $message=switch ($fault) {
                'foreign-process' {'does not match owned PID'}
                'duplicate-host' {'Ambiguous owned sheet'}
                'missing-ancestor' {'Missing or ambiguous sheet ancestor'}
                'cycle' {'Cyclic sheet'}
                default {'Missing or ambiguous owned sheet child'}
            }
            Reject-WireCase "reject sheet $fault" {Resolve-CapOwnedSheet $rows 1 $PID} $message
        }
        Test-WireCase 'native unrelated topmost fixture refuses a pointer before posting' {
            $b=@($nativeRows|Where-Object Handle -EQ $hostWindow.ToInt64())[0].Bounds
            $overlay=[IntPtr]::Zero
            $previous=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-4))
            Assert-WireCase ($previous -ne [IntPtr]::Zero) 'Overlay PMv2 setup failed.'
            try {
                $overlay=[WireFixture]::Create([IntPtr]::Zero,$false,'wire fixture unrelated overlay')
                Assert-WireCase ([WireFixture]::AtPoint(($b[0]+10),($b[1]+10)) -eq $overlay -and
                    [WireFixture]::OwnerProcess($overlay) -eq $PID) 'Controlled unrelated overlay is not the actual recipient.'
                Assert-WireCase (-not [WireFixture]::HasPointerMessage($hostWindow) -and
                    -not [WireFixture]::HasPointerMessage($overlay)) 'Pointer message was already queued before the refusal control.'
                $failure=$null
                try {[CapNative]::PostPointerClickScreen($hostWindow,($b[0]+10),($b[1]+10))|Out-Null}
                catch {$failure=$_}
                Assert-WireCase ($null -ne $failure -and
                    $failure.Exception.Message.Contains('Pointer recipient differs from intended owned HWND')) `
                    'Unrelated same-process HWND was not refused by the actual recipient guard.'
                Assert-WireCase (-not [WireFixture]::HasPointerMessage($hostWindow) -and
                    -not [WireFixture]::HasPointerMessage($overlay)) 'Recipient refusal posted a pointer message.'
                $failure=$null
                try {[CapNative]::PostPointerDragScreen($hostWindow,($b[0]+10),($b[1]+10),($b[0]+20),($b[1]+20))|Out-Null}
                catch {$failure=$_}
                Assert-WireCase ($null -ne $failure -and
                    $failure.Exception.Message.Contains('Pointer recipient differs from intended owned HWND')) `
                    'Drag accepted an unrelated same-process source recipient.'
                Assert-WireCase (-not [WireFixture]::HasPointerMessage($hostWindow) -and
                    -not [WireFixture]::HasPointerMessage($overlay)) 'Drag source refusal posted a pointer message.'
            } finally {
                try {
                    if ($overlay -ne [IntPtr]::Zero -and -not [WireFixture]::DestroyWindow($overlay)) {
                        throw 'Controlled overlay destruction failed.'
                    }
                } finally {$null=[WireFixture]::SetThreadDpiAwarenessContext($previous)}
            }
        }
        Test-WireCase 'drag refuses a foreign end recipient before any dispatch and restores PMv2' {
            $b=@($nativeRows|Where-Object Handle -EQ $hostWindow.ToInt64())[0].Bounds
            $previous=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-4))
            Assert-WireCase ($previous -ne [IntPtr]::Zero) 'Drag recipient preflight PMv2 setup failed.'
            try {
                Assert-WireCase ([WireFixture]::AtPoint(($b[0]+10),($b[1]+10)) -eq $hostWindow -and
                    [WireFixture]::OwnerProcess($hostWindow) -eq $PID) 'Owned drag source recipient preflight refused.'
                Assert-WireCase (-not [WireFixture]::HasPointerMessage($hostWindow)) 'Pointer message queued before end refusal.'
                $before=[WireFixture]::GetThreadDpiAwarenessContext()
                $failure=$null
                try {[CapNative]::PostPointerDragScreen($hostWindow,($b[0]+10),($b[1]+10),-30000,-30000)|Out-Null}
                catch {$failure=$_}
                Assert-WireCase ($null -ne $failure -and $failure.Exception.Message.Contains('recipient differs')) `
                    'Foreign drag endpoint was accepted.'
                $cause=$failure.Exception
                while ($cause.InnerException) {$cause=$cause.InnerException}
                $partial=$cause.Data['PointerDragReceipt']
                Assert-WireCase ($null -ne $partial -and $null -ne $partial.Start -and
                    -not $partial.Start.MovePosted -and -not $partial.Start.DownPosted -and
                    -not $partial.HeldMovePosted -and $null -eq $partial.End -and
                    -not [WireFixture]::HasPointerMessage($hostWindow) -and
                    [WireFixture]::GetThreadDpiAwarenessContext() -eq $before) `
                    'End recipient refusal posted a partial gesture, lost its receipt, or leaked DPI awareness.'
            } finally {$null=[WireFixture]::SetThreadDpiAwarenessContext($previous)}
        }
        Test-WireCase 'native PMv2 conversion dispatch persists coordinates and restores caller awareness' {
            $b=@($nativeRows|Where-Object Handle -EQ $hostWindow.ToInt64())[0].Bounds
            $preflight=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-4))
            Assert-WireCase ($preflight -ne [IntPtr]::Zero) 'Owned pointer fixture PMv2 preflight failed.'
            try {
                Assert-WireCase ([WireFixture]::AtPoint(($b[0]+10),($b[1]+10)) -eq $hostWindow -and
                    [WireFixture]::OwnerProcess($hostWindow) -eq $PID) 'Owned pointer fixture recipient preflight refused.'
            } finally {$null=[WireFixture]::SetThreadDpiAwarenessContext($preflight)}
            $previous=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-1))
            try {
                $before=[WireFixture]::GetThreadDpiAwarenessContext()
                $receipt=[CapNative]::PostPointerClickScreen($hostWindow,($b[0]+10),($b[1]+10))
                Assert-WireCase ($receipt.ClientX -eq 10 -and $receipt.ClientY -eq 10 -and
                    $receipt.PackedLParam -eq ((10 -shl 16) -bor 10) -and $receipt.MovePosted -and
                    $receipt.DownPosted -and $receipt.UpPosted -and
                    [WireFixture]::GetThreadDpiAwarenessContext() -eq $before) 'DPI conversion/receipt/restore failed.'
            } finally {$null=[WireFixture]::SetThreadDpiAwarenessContext($previous)}
        }
        Reject-WireCase 'invalid native HWND is not a successful click' {
            [CapNative]::PostPointerClickScreen([IntPtr]::Zero,0,0)
        } 'recipient differs'
        Test-WireCase 'native drag validates both endpoints under restored PMv2 awareness' {
            $b=@($nativeRows|Where-Object Handle -EQ $hostWindow.ToInt64())[0].Bounds
            $preflight=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-4))
            Assert-WireCase ($preflight -ne [IntPtr]::Zero) 'Owned drag recipient PMv2 preflight failed.'
            try {
                # The child content starts at client20,20; both recipients must be the host.
                foreach ($offset in @(10,15)) {
                    $recipient=[WireFixture]::AtPoint(($b[0]+$offset),($b[1]+$offset))
                    $recipientPid=[WireFixture]::OwnerProcess($recipient)
                    Assert-WireCase ($recipient -eq $hostWindow -and $recipientPid -eq $PID) `
                        "Owned drag recipient preflight refused: offset=$offset; intended=$hostWindow; recipient=$recipient; recipientPID=$recipientPid; expectedPID=$PID."
                }
            } finally {$null=[WireFixture]::SetThreadDpiAwarenessContext($preflight)}
            $previous=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-1))
            try {
                $before=[WireFixture]::GetThreadDpiAwarenessContext()
                $activePrevious=[WireFixture]::SetThreadDpiAwarenessContext([IntPtr](-4))
                Assert-WireCase ($activePrevious -ne [IntPtr]::Zero) 'Drag PMv2 observation setup failed.'
                try {$retainedDpiContext=[WireFixture]::GetThreadDpiAwarenessContext()}
                finally {
                    $restored=[WireFixture]::SetThreadDpiAwarenessContext($activePrevious)
                    Assert-WireCase ($restored -ne [IntPtr]::Zero) 'Drag PMv2 observation restore failed.'
                }
                $receipt=[CapNative]::PostPointerDragScreen($hostWindow,($b[0]+10),($b[1]+10),($b[0]+15),($b[1]+15))
                Assert-WireCase ($receipt.Start.ClientX -eq 10 -and $receipt.Start.ClientY -eq 10 -and
                    $receipt.End.ClientX -eq 15 -and $receipt.End.ClientY -eq 15 -and
                    $receipt.End.ClientX-$receipt.Start.ClientX -eq 5 -and
                    $receipt.End.ClientY-$receipt.Start.ClientY -eq 5 -and
                    $receipt.End.ScreenX-$receipt.Start.ScreenX -eq 5 -and
                    $receipt.End.ScreenY-$receipt.Start.ScreenY -eq 5 -and
                    $receipt.Start.MovePosted -and $receipt.Start.DownPosted -and
                    $receipt.HeldMovePosted -and $receipt.End.UpPosted -and
                    $receipt.Start.Recipient -eq $hostWindow.ToInt64() -and
                    $receipt.End.Recipient -eq $hostWindow.ToInt64() -and
                    $receipt.Start.DpiContext -eq $retainedDpiContext -and
                    $receipt.End.DpiContext -eq $retainedDpiContext -and
                    $receipt.Delivery -ceq 'POSTED_WINDOW_MESSAGES_NOT_PHYSICAL_POINTER' -and
                    [WireFixture]::GetThreadDpiAwarenessContext() -eq $before) `
                    "Drag receipt/DPI restore failed: $($receipt|ConvertTo-Json -Depth 10 -Compress); retained=$retainedDpiContext; before=$before; after=$([WireFixture]::GetThreadDpiAwarenessContext())"
            } finally {$null=[WireFixture]::SetThreadDpiAwarenessContext($previous)}
        }
        foreach ($failureIndex in 0..3) {
            $script:dragMessages=[Collections.Generic.List[string]]::new()
            $receipt=[CapPointerDragReceipt]::new()
            $receipt.Start=[CapPointerReceipt]::new();$receipt.End=[CapPointerReceipt]::new()
            $poster=[Func[uint32,uint32,long,bool]]{
                param($message,$keys,$position)
                $script:dragMessages.Add("$message/$keys/$position")
                return $script:dragMessages.Count -ne ($failureIndex+1)
            }
            Test-WireCase "drag dispatch reports failure at step $failureIndex" {
                $failure=$null
                try {[CapNative]::DispatchPointerDragMessages($receipt,$poster)}
                catch {$failure=$_}
                Assert-WireCase ($null -ne $failure -and
                    $failure.Exception.Message.Contains('Native pointer drag dispatch failed')) 'Expected explicit drag refusal.'
                $cause=$failure.Exception
                while ($cause.InnerException) {$cause=$cause.InnerException}
                Assert-WireCase ([object]::ReferenceEquals($cause.Data['PointerDragReceipt'],$receipt) -and
                    $receipt.Start.MovePosted -eq ($failureIndex -gt 0) -and
                    $receipt.Start.DownPosted -eq ($failureIndex -gt 1) -and
                    $receipt.HeldMovePosted -eq ($failureIndex -gt 2) -and -not $receipt.End.UpPosted) `
                    'Dispatch failure lost or misstated its partial receipt.'
            }
            Test-WireCase "drag dispatch stops without retry or synthetic UP after step $failureIndex" {
                Assert-WireCase ($script:dragMessages.Count -eq ($failureIndex+1)) 'Drag continued after refusal.'
            }
        }
        Reject-WireCase 'native conversion error is explicit, never a successful coordinate fallback' {
            [CapNative]::ConvertPointerScreen([IntPtr]123,0,0)
        } 'ScreenToClient failed'
        Reject-WireCase 'native conversion rejects overflowing screen coordinates before native truncation' {
            [CapNative]::ConvertPointerScreen($hostWindow,[int]::MaxValue,[int]::MaxValue)
        } 'signed native conversion range'
        foreach ($failedMessage in @(0x0200,0x0201,0x0202)) {
            $script:messages=[Collections.Generic.List[uint32]]::new()
            $poster=[Func[uint32,uint32,long,bool]]{
                param($message,$keys,$position)
                $script:messages.Add($message)
                return $message -ne $failedMessage
            }
            Reject-WireCase "native dispatch rejects message $failedMessage failure" {
                [CapNative]::DispatchPointerMessages([CapPointerReceipt]::new(),$poster)
            } 'Native pointer dispatch failed'
            Test-WireCase "native dispatch stops at failed message $failedMessage" {
                Assert-WireCase ($script:messages[-1] -eq $failedMessage -and
                    $script:messages.Count -eq ($failedMessage-0x0200+1)) 'Dispatch continued after rejection.'
            }
        }
        Test-WireCase 'shared native reader validates owned readonly exact endpoints and refuses changed fields' {
            $handles=[WireFixture]::CreateEndpoints($root,
                '60000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002')
            try {
                $dialog=[Windows.Automation.AutomationElement]::FromHandle($handles[0])
                $proof=Read-UiaReadonlyEdgeEndpoints -Dialog $dialog -ProcessId $PID -Owner $root `
                    -Title 'Create or edit edge' -ExpectedSource '60000000-0000-4000-8000-000000000001' `
                    -ExpectedTarget '60000000-0000-4000-8000-000000000002'
                Assert-WireCase ($proof.source -ceq '60000000-0000-4000-8000-000000000001' -and
                    $proof.target -ceq '60000000-0000-4000-8000-000000000002' -and
                    $proof.snapshot.fields[0].nativeReadonly -and $proof.snapshot.fields[0].readonly -and
                    $proof.snapshot.fields[1].nativeReadonly -and $proof.snapshot.fields[1].readonly) `
                    'Native fixture lost exact locked endpoint evidence.'
                [WireFixture]::SetReadonly($handles[3],$false)
                $failure=$null
                try {
                    Read-UiaReadonlyEdgeEndpoints -Dialog $dialog -ProcessId $PID -Owner $root `
                        -Title 'Create or edit edge' -ExpectedSource $proof.source -ExpectedTarget $proof.target|Out-Null
                } catch {$failure=$_}
                Assert-WireCase ($null -ne $failure -and $failure.Exception.Message.Contains('Readonly native/semantic endpoint')) `
                    'Shared native reader accepted a mutable endpoint.'
                [WireFixture]::SetReadonly($handles[3],$true)
                $failure=$null
                try {
                    Read-UiaReadonlyEdgeEndpoints -Dialog $dialog -ProcessId $PID -Owner $root `
                        -Title 'Create or edit edge' -ExpectedSource $proof.target -ExpectedTarget $proof.source|Out-Null
                } catch {$failure=$_}
                Assert-WireCase ($null -ne $failure -and $failure.Exception.Message.Contains('Readonly native/semantic endpoint')) `
                    'Shared native reader accepted swapped endpoint identities.'
                if (-not [WireFixture]::DestroyWindow($handles[4])) {throw 'Endpoint fixture field cleanup failed.'}
                $failure=$null
                try {
                    Read-UiaReadonlyEdgeEndpoints -Dialog $dialog -ProcessId $PID -Owner $root `
                        -Title 'Create or edit edge' -ExpectedSource $proof.source -ExpectedTarget $proof.target|Out-Null
                } catch {$failure=$_}
                Assert-WireCase ($null -ne $failure -and $failure.Exception.Message.Contains('Exact owned readonly endpoint child missing')) `
                    'Shared native reader accepted an absent endpoint.'
            } finally {
                if (-not [WireFixture]::DestroyWindow($handles[0])) {throw 'Endpoint fixture host cleanup failed.'}
            }
        }
        Test-WireCase 'worker preserves original primary when stub cleanup also refuses' {
            & {
                . (Join-Path $directory 'Invoke-UiCaptureWorker.ps1') -OwnedRoot $ScratchRoot -DefinitionsOnly
                $runDirectory=Join-Path $ScratchRoot 'cleanup-model'
                $job=[pscustomobject]@{sceneAdapter='S_MATCHED_V12_DPI_V1'}
                function Get-CapWorkerWindowIdentity {param($Phase,$SceneName) return @{}}
                function Get-CapWorkerWireBinding {return $binding}
                function Start-CapManagedProcess {return [pscustomobject]@{Identity=@{Role='MODEL_NO_PROCESS'}}}
                function Start-CapGraphCodeApp {throw 'ORIGINAL_WIRE_PRIMARY_MODEL'}
                function Stop-CapManagedProcess {throw 'CLEANUP_REFUSAL_MODEL'}
                $failure=$null
                try {Invoke-CapWireCompletionSupplement -StubDaemonPath 'MODEL_NEVER_EXECUTED'}
                catch {$failure=$_}
                Assert-WireCase ($failure.Exception.Message -ceq 'ORIGINAL_WIRE_PRIMARY_MODEL' -and
                    $cleanupFailures.Count -eq 1 -and $cleanupFailures[0].Contains('CLEANUP_REFUSAL_MODEL')) `
                    "Worker lost its original failure or falsely reported cleanup success: $failure; cleanup=$cleanupFailures"
            }
        }
    }
} finally {
    foreach ($window in @($content,$hostWindow,$root)) {
        if ($window -ne [IntPtr]::Zero -and -not [WireFixture]::DestroyWindow($window)) {
            throw 'Harmless fixture window cleanup failed.'
        }
        if (Get-Variable self -ErrorAction SilentlyContinue) {$self.Dispose()}
    }
}
}
$failed=@($results|Where-Object passed -EQ $false).Count
$report=[ordered]@{suite='WireTargeting';executed=$results.Count;passed=($results.Count-$failed)
    failed=$failed;skipped=0;productLaunches=0;providerLaunches=0;cases=@($results)}
[IO.File]::WriteAllText((Join-Path $ScratchRoot 'report.json'),($report|ConvertTo-Json -Depth 30),
    [Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $ScratchRoot 'summary.json')
[pscustomobject]$report|Select-Object suite,executed,passed,failed,skipped|ConvertTo-Json -Compress
foreach ($result in @($results|Where-Object passed -EQ $false)) {$result|ConvertTo-Json -Compress|Write-Host}
if ($failed -gt 0) {throw "$failed behavioral wire targeting contracts failed."}
if ($results.Count -ne $(if ($DispatchOnly) {3} elseif ($LegacyBehavior) {2} else {75})) {throw 'Wire targeting executed count differs.'}
