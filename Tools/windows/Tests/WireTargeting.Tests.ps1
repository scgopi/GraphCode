param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('wt' + [guid]::NewGuid().ToString('N').Substring(0,8))),
    [switch]$LegacyBehavior
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
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
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style,
    int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr value);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
  public static IntPtr Create(IntPtr parent, bool child, string name) {
    IntPtr result=CreateWindowExW(0x08000000,child ? "WireTargetFixtureContent" : "WireTargetFixture",
      name,child ? 0x50000000u : 0x90000000u,
      20,20,250,96,parent,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
    if(result==IntPtr.Zero) throw new Exception("Fixture CreateWindow failed.");
    return result;
  }
}
'@
$root=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero;$content=[IntPtr]::Zero
try {
    $root=[WireFixture]::Create([IntPtr]::Zero,$false,'wire fixture owner')
    $hostWindow=[WireFixture]::Create($root,$false,'wire fixture sheet')
    $content=[WireFixture]::Create($hostWindow,$true,'wire fixture content')
    if ($LegacyBehavior) {
        Test-WireCase 'owned child form is observable, not just a top-level class' {
            $actual=[GraphCodeUiaGateState]::FindTopLevel('WireTargetFixtureContent',[uint32]$PID)
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
        foreach ($field in @('sourceNodeId','targetNodeId','sourceCardId','targetCardId','scene','phase','projectPath','wireId','sourceHashes')) {
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
                    $observation.screenPoint[0] -gt 300*$dpi/96) 'Target point hits inline action.'
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
        foreach ($fault in @('source','target','runtime','bounds','mode','root')) {
            $second=$first|ConvertTo-Json -Depth 20|ConvertFrom-Json
            $rootAfter=@(1,2)
            switch ($fault) {
                'source' {$second.source.AutomationId='foreign'}
                'target' {$second.target.AutomationId='foreign'}
                'runtime' {$second.target.RuntimeId=@(1,3)}
                'bounds' {$second.target.Bounds[0]++}
                'mode' {$second.mode='not armed'}
                'root' {$rootAfter=@(1,3)}
            }
            Reject-WireCase "reacquisition rejects $fault drift" {
                Assert-CapWireTargetStable $first $second @(1,2) $rootAfter
            } 'drifted before dispatch'
        }
        foreach ($fault in @('source','target','mode','foreign-process','offscreen','disabled','bounds','NaN','duplicate','overlap')) {
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
            }
            $message=switch ($fault) {
                'foreign-process' {'does not match owned PID'}
                {$_ -in @('offscreen','disabled','bounds','NaN')} {'bounds/scale'}
                'overlap' {'Unsafe wire target point'}
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
        Test-WireCase 'native PMv2 conversion dispatch persists coordinates and restores caller awareness' {
            $b=@($nativeRows|Where-Object Handle -EQ $hostWindow.ToInt64())[0].Bounds
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
$failed=@($results|Where-Object passed -EQ $false).Count
$report=[ordered]@{suite='WireTargeting';executed=$results.Count;passed=($results.Count-$failed)
    failed=$failed;skipped=0;productLaunches=0;providerLaunches=0;cases=@($results)}
[IO.File]::WriteAllText((Join-Path $ScratchRoot 'report.json'),($report|ConvertTo-Json -Depth 30),
    [Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $ScratchRoot 'summary.json')
[pscustomobject]$report|Select-Object suite,executed,passed,failed,skipped|ConvertTo-Json -Compress
foreach ($result in @($results|Where-Object passed -EQ $false)) {$result|ConvertTo-Json -Compress|Write-Host}
if ($failed -gt 0) {throw "$failed behavioral wire targeting contracts failed."}
if ($results.Count -ne $(if ($LegacyBehavior) {2} else {56})) {throw 'Wire targeting executed count differs.'}
