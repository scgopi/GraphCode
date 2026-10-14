# Same A/cap lineage, FSL-1.1-MIT (repository LICENSE).
# CaptureWorker.psm1 SHA256 B35472CFD934B542F4A8867D8698F6C0688931AACA9D7DB96854E8290979B592.
# Native ownership/PrintWindow ancestry: capture-prompts.ps1
# SHA256 13F2FB63BE761F6E8549CD1ABF936CBD24D64BCF3A15BCB20644BA66DB7E81F6.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CapPendingLaunches = [Collections.Generic.List[object]]::new()
$script:CapExcludedDescendants = [Collections.Generic.List[object]]::new()
$script:CapLastRollbackReceipt = $null
$script:CapTracePath = $null
$script:CapTraceFailures = [Collections.Generic.List[object]]::new()

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing

# Only the required FindTopLevel/PostCommand fragments, not the executable live gate.
# Tools/windows/uia-live-gate.ps1, first Add-Type, FSL-1.1-MIT:
# SHA256 7455148BDCB64A03914812DC415B39EB300293D8970502C1BDFD110044C30795.
# Extracted GraphCodeUiaGateState.cs:
# SHA256 C2514CECBC2637202D6DAE639DF33C77901EB69ADBEDD8CB795C37C8BF92B162.
$helperSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class GraphCodeUiaGateState {
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool PostMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
  private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr window, StringBuilder className, int capacity);
  public static IntPtr FindTopLevel(string className, uint processId) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId) return true;
      var actualClass = new StringBuilder(256);
      GetClassName(window, actualClass, actualClass.Capacity);
      if (!String.Equals(actualClass.ToString(), className, StringComparison.Ordinal)) return true;
      result = window;
      return false;
    }, IntPtr.Zero);
    return result;
  }
  public static bool PostCommand(IntPtr window, uint command) {
    return PostMessage(window, 0x0111, (UIntPtr)command, IntPtr.Zero);
  }
}
'@
if (-not ('GraphCodeUiaGateState' -as [type])) {
    Add-Type -TypeDefinition $helperSource
}

$nativeSource = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public sealed class CapProcessSnapshot {
  public int ProcessId { get; set; }
  public long CreationFileTimeUtc { get; set; }
  public long ExitFileTimeUtc { get; set; }
  public string ImagePath { get; set; }
  public bool IsExited { get; set; }
}

public sealed class CapWindowSnapshot {
  public int[] OuterBounds { get; set; }
  public int[] ClientBounds { get; set; }
  public uint Dpi { get; set; }
}

public sealed class CapCaptureResult {
  public int Width { get; set; }
  public int Height { get; set; }
  public int SampledColors { get; set; }
  public int NonMagentaSamples { get; set; }
  public uint Dpi { get; set; }
}

public static class CapNative {
  private const uint WAIT_OBJECT_0 = 0;
  private const uint WAIT_TIMEOUT = 0x102;
  private const uint WAIT_FAILED = 0xFFFFFFFF;

  [StructLayout(LayoutKind.Sequential)]
  private struct NativeRect { public int Left, Top, Right, Bottom; }

  [StructLayout(LayoutKind.Sequential)]
  private struct NativeFileTime { public uint Low, High; }

  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern uint GetProcessId(IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool GetProcessTimes(IntPtr process, out NativeFileTime creation, out NativeFileTime exit, out NativeFileTime kernel, out NativeFileTime user);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder image, ref uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool TerminateProcess(IntPtr process, uint exitCode);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool GetClientRect(IntPtr window, out NativeRect rect);
  [DllImport("user32.dll")]
  private static extern uint GetDpiForWindow(IntPtr window);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern bool WaitNamedPipeW(string name, uint timeout);

  private static long FileTime(NativeFileTime value) {
    return ((long)value.High << 32) | value.Low;
  }

  public static CapProcessSnapshot Snapshot(IntPtr handle, int expectedPid) {
    if (handle == IntPtr.Zero) throw new ArgumentNullException("handle");
    uint pid = GetProcessId(handle);
    if (pid == 0 || pid != (uint)expectedPid) throw new InvalidOperationException("Process handle/PID mismatch.");
    NativeFileTime creation, exit, kernel, user;
    if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user))
      throw new InvalidOperationException("GetProcessTimes failed: " + Marshal.GetLastWin32Error());
    uint wait = WaitForSingleObject(handle, 0);
    if (wait == WAIT_FAILED) throw new InvalidOperationException("WaitForSingleObject failed: " + Marshal.GetLastWin32Error());
    bool exited = wait == WAIT_OBJECT_0;
    string path = "";
    uint size = 32768;
    var buffer = new StringBuilder((int)size);
    if (QueryFullProcessImageNameW(handle, 0, buffer, ref size)) path = buffer.ToString();
    else if (!exited) throw new InvalidOperationException("QueryFullProcessImageName failed for live PID " + pid + ": " + Marshal.GetLastWin32Error());
    return new CapProcessSnapshot {
      ProcessId = (int)pid,
      CreationFileTimeUtc = FileTime(creation),
      ExitFileTimeUtc = exited ? FileTime(exit) : 0,
      ImagePath = path,
      IsExited = exited
    };
  }

  public static int WindowProcessId(IntPtr window) {
    uint processId;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out processId) == 0 || processId == 0)
      throw new InvalidOperationException("GetWindowThreadProcessId failed: " + Marshal.GetLastWin32Error());
    return (int)processId;
  }

  public static bool IsExited(IntPtr handle, int pid) {
    uint wait = WaitForSingleObject(handle, 0);
    if (wait == WAIT_OBJECT_0) return true;
    if (wait == WAIT_TIMEOUT) return false;
    throw new InvalidOperationException("Kernel wait failed for PID " + pid + ": " + Marshal.GetLastWin32Error());
  }

  public static bool Terminate(IntPtr handle, int pid, uint exitCode, int timeoutMilliseconds) {
    if (IsExited(handle, pid)) return false;
    bool terminated = TerminateProcess(handle, exitCode);
    int terminateError = terminated ? 0 : Marshal.GetLastWin32Error();
    uint wait = WaitForSingleObject(handle, (uint)timeoutMilliseconds);
    if (wait == WAIT_OBJECT_0) return terminated;
    throw new InvalidOperationException("Guarded process did not exit within " + timeoutMilliseconds +
      " ms; TerminateProcess=" + terminated + " error=" + terminateError + " wait=" + wait);
  }

  public static bool SetWindowPosition(IntPtr window, int x, int y, int width, int height) {
    return SetWindowPos(window, IntPtr.Zero, x, y, width, height, 0x0014);
  }

  public static CapWindowSnapshot WindowSnapshot(IntPtr window, int expectedPid) {
    uint owner;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)expectedPid)
      throw new InvalidOperationException("Window ownership mismatch.");
    NativeRect outer, client;
    if (!GetWindowRect(window, out outer) || !GetClientRect(window, out client))
      throw new InvalidOperationException("Window geometry query failed: " + Marshal.GetLastWin32Error());
    return new CapWindowSnapshot {
      OuterBounds = new[] { outer.Left, outer.Top, outer.Right, outer.Bottom },
      ClientBounds = new[] { client.Left, client.Top, client.Right, client.Bottom },
      Dpi = GetDpiForWindow(window)
    };
  }

  public static CapCaptureResult CaptureWindow(IntPtr window, int expectedPid, string path) {
    uint owner;
    NativeRect rect;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)expectedPid ||
        !GetWindowRect(window, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top)
      throw new InvalidOperationException("Capture ownership/geometry mismatch.");
    int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
    using (var bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb))
    using (var graphics = Graphics.FromImage(bitmap)) {
      graphics.Clear(Color.Magenta);
      IntPtr dc = graphics.GetHdc();
      bool ok;
      try { ok = PrintWindow(window, dc, 2); }
      finally { graphics.ReleaseHdc(dc); }
      if (!ok) throw new InvalidOperationException("PrintWindow(flag=2) failed.");
      var colors = new System.Collections.Generic.HashSet<int>();
      int nonMagenta = 0;
      for (int y = 4; y < bitmap.Height; y += 12) {
        for (int x = 4; x < bitmap.Width; x += 12) {
          int color = bitmap.GetPixel(x, y).ToArgb();
          colors.Add(color);
          if (color != Color.Magenta.ToArgb()) nonMagenta++;
        }
      }
      if (colors.Count < 4 || nonMagenta < 20)
        throw new InvalidOperationException("PrintWindow pixel check failed: distinct=" + colors.Count + " painted=" + nonMagenta);
      bitmap.Save(path, ImageFormat.Png);
      return new CapCaptureResult {
        Width = width,
        Height = height,
        SampledColors = colors.Count,
        NonMagentaSamples = nonMagenta,
        Dpi = GetDpiForWindow(window)
      };
    }
  }

  public static int ProbePipe(string pipeName, uint timeoutMilliseconds) {
    if (String.IsNullOrWhiteSpace(pipeName) || pipeName.Contains("\\") || pipeName.Contains("/"))
      throw new ArgumentException("PipeName must be an unqualified unique pipe name.", "pipeName");
    string path = @"\\.\pipe\" + pipeName;
    if (WaitNamedPipeW(path, timeoutMilliseconds)) return 0;
    return Marshal.GetLastWin32Error();
  }

  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
}
'@

if (-not ('CapNative' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies @(
        [System.Drawing.Bitmap].Assembly.Location,
        [System.Drawing.Graphics].Assembly.Location,
        [System.Drawing.Color].Assembly.Location,
        (Join-Path $PSHOME 'System.Private.Windows.Core.dll'),
        (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll'),
        'System.Collections.dll'
    )
}

function Set-CapTracePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:CapTracePath = [IO.Path]::GetFullPath($Path)
}

function Write-CapTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [System.Collections.IDictionary]$Parameters = @{}
    )
    if (-not $script:CapTracePath) { return }
    $values = [ordered]@{}
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        $values[$key] = if ($null -eq $value -or $value -is [string] -or $value -is [ValueType] -or
            $value -is [string[]]) { $value }
        elseif ($value.PSObject.Properties['Pid'] -and $value.PSObject.Properties['CreationFileTimeUtc'] -and
            $value.PSObject.Properties['ExpectedImagePath'] -and $value.PSObject.Properties['Role']) {
            [ordered]@{ pid = $value.Pid; creationFileTimeUtc = $value.CreationFileTimeUtc
                expectedImagePath = $value.ExpectedImagePath; role = $value.Role }
        } else { $value.GetType().FullName }
    }
    $stack = @(Get-PSCallStack | Select-Object -Skip 1 -First 2 | ForEach-Object {
        [ordered]@{ command = $_.Command; file = $_.ScriptName; line = $_.ScriptLineNumber }
    })
    $line = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); callerPid = $PID; callsites = $stack
        command = $Command; parameters = $values } | ConvertTo-Json -Depth 8 -Compress
    try {
        [IO.File]::AppendAllText($script:CapTracePath, $line + "`n", [Text.UTF8Encoding]::new($false))
    } catch [IO.IOException], [UnauthorizedAccessException] {
        if (-not @($script:CapTraceFailures | Where-Object command -CEQ $Command).Count) {
            $script:CapTraceFailures.Add([pscustomobject]@{
                command = $Command; path = $script:CapTracePath; failure = $_.Exception.ToString()
            })
            [Console]::Error.WriteLine("CAP_TRACE_FAILURE command=$Command path=$($script:CapTracePath): $($_.Exception.Message)")
        }
    }
}

function Get-CapTraceFailures {
    [CmdletBinding()]
    param()
    return @($script:CapTraceFailures.ToArray())
}

function Assert-CapArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    foreach ($candidate in @($Root, $Path)) {
        if (-not [IO.Path]::IsPathFullyQualified($candidate) -or $candidate -notmatch '^[A-Za-z]:\\' -or
            $candidate.Substring(2).Contains(':') -or $candidate -match '(^|\\)\.\.?($|\\)') {
            throw 'Capture artifacts require explicit local absolute paths without traversal or device syntax.'
        }
        $ancestor = [IO.Path]::GetFullPath($candidate)
        while ($ancestor) {
            if (Test-Path -LiteralPath $ancestor) {
                $item = Get-Item -LiteralPath $ancestor -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Capture artifact path has a reparse-point ancestor: $ancestor"
                }
            }
            $ancestor = Split-Path -Parent $ancestor
        }
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($rootFull -ieq [IO.Path]::GetPathRoot($rootFull).TrimEnd('\') -or
        $rootFull -match '^C:\\gcs\\(?:cap|ia|ib|ic|id|ie)(?:\\|$)') {
        throw 'Capture output must use a dedicated caller-owned root, not a drive or preserved lane root.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Capture artifact escaped the explicit owned root: $full"
    }
    return $full
}

function Get-CapActionSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('actual-size', 'open-project', 'overview-destination', 'open-loop', 'file-exit')][string]$Action,
        [string]$Name
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    switch ($Action) {
        'actual-size' { return [pscustomobject]@{ AutomationId = 'actual-size'; AutomationIdPrefix = $null; Name = 'Actual size'; CommandId = $null } }
        'open-project' {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw 'open-project requires a project name.' }
            return [pscustomobject]@{ AutomationId = $null; AutomationIdPrefix = 'open-project-'; Name = $Name; CommandId = $null }
        }
        'overview-destination' { return [pscustomobject]@{ AutomationId = 'overview-destination'; AutomationIdPrefix = $null; Name = 'Graph'; CommandId = $null } }
        'open-loop' {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw 'open-loop requires a loop name.' }
            return [pscustomobject]@{ AutomationId = $null; AutomationIdPrefix = 'canvas-card-'; Name = $Name; CommandId = $null }
        }
        'file-exit' { return [pscustomobject]@{ AutomationId = $null; AutomationIdPrefix = $null; Name = $null; CommandId = 4104 } }
    }
}

function Assert-CapFixtureMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$MappingPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedMappingSha256,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSourceSha256,
        [Parameter(Mandatory)][string]$OriginalRoot
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $FixturePath = Assert-CapArtifactPath -Root $Root -Path $FixturePath
    $SourcePath = Assert-CapArtifactPath -Root $Root -Path $SourcePath
    $MappingPath = Assert-CapArtifactPath -Root $Root -Path $MappingPath
    $mappingHash = (Get-FileHash -LiteralPath $MappingPath -Algorithm SHA256).Hash
    $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    $fixtureHash = (Get-FileHash -LiteralPath $FixturePath -Algorithm SHA256).Hash
    if ($mappingHash -ne $ExpectedMappingSha256 -or $sourceHash -ne $ExpectedSourceSha256) {
        throw 'Fixture mapping/source does not match its exact trusted hashes.'
    }
    $mapping = Get-Content -LiteralPath $MappingPath -Raw | ConvertFrom-Json -DateKind String
    if ($mapping.sourcePath -cne (Join-Path $OriginalRoot 'fixture.json') -or
        $mapping.sourceSha256 -ne $ExpectedSourceSha256 -or
        $mapping.copiedSourcePath -cne $SourcePath -or $mapping.rewrittenFixturePath -cne $FixturePath -or
        $mapping.rewrittenFixtureSha256 -ne $fixtureHash -or
        $mapping.pathPrefixMap.from -cne $OriginalRoot -or
        $mapping.pathPrefixMap.to -cne (Join-Path $Root 'fixtures\projects') -or
        $mapping.graphs -ne 2 -or $mapping.topLevelNodes -ne 10 -or $mapping.pathsRewritten -ne $true) {
        throw 'Fixture mapping does not bind the exact source and rewritten owned-root fixture.'
    }
    $source = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json -DateKind String
    $fixture = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json -DateKind String
    if ($source.graphs.Count -ne 2 -or $fixture.graphs.Count -ne 2 -or
        ($source.graphs | ForEach-Object { $_.nodes.Count } | Measure-Object -Sum).Sum -ne 10 -or
        ($fixture.graphs | ForEach-Object { $_.nodes.Count } | Measure-Object -Sum).Sum -ne 10) {
        throw 'Fixture mapping changed the two-graph/ten-node capture contract.'
    }
    foreach ($index in 0..1) {
        $sourceProject = $source.graphs[$index].project
        $mappedProject = $fixture.graphs[$index].project
        if ($sourceProject.path -cne (Join-Path $OriginalRoot $sourceProject.name) -or
            $mappedProject.name -cne $sourceProject.name -or
            $mappedProject.path -cne (Join-Path (Join-Path $Root 'fixtures\projects') $sourceProject.name) -or
            $fixture.graphs[$index].nodes.Count -ne $source.graphs[$index].nodes.Count) {
            throw "Fixture mapping changed graph identity, owned project path, or node count at index $index."
        }
    }
    $projectsRoot = Join-Path $Root 'fixtures\projects'
    $visit = {
        param($Value)
        if ($Value -is [string]) {
            if ($Value -match '^[A-Za-z]:[\\/]') {
                $path = [IO.Path]::GetFullPath($Value)
                if ($path -ine $projectsRoot -and
                    -not $path.StartsWith($projectsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Fixture contains a foreign or unrewritten embedded path.'
                }
                $null = Assert-CapArtifactPath -Root $Root -Path $Value
            }
        } elseif ($Value -is [array]) {
            foreach ($item in $Value) { & $visit $item }
        } elseif ($Value -is [pscustomobject]) {
            foreach ($property in $Value.PSObject.Properties) { & $visit $property.Value }
        }
    }
    & $visit $fixture
    $originalEscaped = ($OriginalRoot | ConvertTo-Json -Compress).Trim('"')
    $ownedEscaped = ($projectsRoot | ConvertTo-Json -Compress).Trim('"')
    $expectedFixture = [IO.File]::ReadAllText($SourcePath).Replace($originalEscaped, $ownedEscaped) |
        ConvertFrom-Json -DateKind String | ConvertTo-Json -Depth 40 -Compress
    if (($fixture | ConvertTo-Json -Depth 40 -Compress) -cne $expectedFixture) {
        throw 'Rewritten fixture differs from the source beyond the complete owned-prefix substitution.'
    }
    return [pscustomobject]@{ FixtureSha256 = $fixtureHash; SourceSha256 = $sourceHash; MappingSha256 = $mappingHash }
}

function Assert-CapUiaProcessIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][int[]]$ObservedProcessIds
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    foreach ($observedProcessId in $ObservedProcessIds) {
        if ($observedProcessId -le 0 -or $observedProcessId -ne $ExpectedProcessId) {
            throw "UIA subtree process $observedProcessId does not match owned PID $ExpectedProcessId."
        }
    }
    return $true
}

function Resolve-CapAutomationCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][string]$Name,
        [string]$AutomationId,
        [string]$AutomationIdPrefix,
        [switch]$AllowOffscreen
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $found = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $Candidates) {
        if ($null -eq $candidate) { throw 'UIA resolver returned a null candidate.' }
        $current = if ($candidate.PSObject.Properties['Current']) { $candidate.Current } else { $candidate }
        $null = Assert-CapUiaProcessIds -ExpectedProcessId $ExpectedProcessId -ObservedProcessIds @([int]$current.ProcessId)
        if ([string]$current.Name -cne $Name) { continue }
        if ($AutomationId -and [string]$current.AutomationId -cne $AutomationId) { continue }
        if ($AutomationIdPrefix -and -not ([string]$current.AutomationId).StartsWith($AutomationIdPrefix, [StringComparison]::Ordinal)) { continue }
        if (-not $AllowOffscreen -and [bool]$current.IsOffscreen) { continue }
        $rect = $current.BoundingRectangle
        if ($null -eq $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { continue }
        $found.Add($candidate)
    }
    if ($found.Count -ne 1) {
        throw "Expected exactly one visible UIA element Name='$Name' id='$AutomationId' prefix='$AutomationIdPrefix'; found=$($found.Count)."
    }
    return $found[0]
}

function Find-CapAutomationElement {
    [CmdletBinding(DefaultParameterSetName = 'Window')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Window')][IntPtr]$RootHandle,
        [Parameter(Mandatory)][object]$ProcessIdentity,
        [Parameter(Mandatory, ParameterSetName = 'Element')][System.Windows.Automation.AutomationElement]$Parent,
        [int]$ExpectedProcessId = 0,
        [Parameter(Mandatory)][string]$Name,
        [string]$AutomationId,
        [string]$AutomationIdPrefix,
        [System.Windows.Automation.TreeScope]$Scope = [System.Windows.Automation.TreeScope]::Descendants,
        [switch]$AllowOffscreen
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $rootElement = if ($PSCmdlet.ParameterSetName -eq 'Window') {
        [System.Windows.Automation.AutomationElement]::FromHandle($RootHandle)
    } else {
        $Parent
    }
    if ($null -eq $rootElement) { throw 'UIA root is unavailable.' }
    if ($PSCmdlet.ParameterSetName -eq 'Window') {
        $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity
    } else {
        $verified = Assert-CapProcessIdentity -Identity $ProcessIdentity
        if ($verified.State -ne 'Live') { throw "UIA parent process PID $($ProcessIdentity.Pid) is no longer live." }
    }
    $rootProcessId = [int]$rootElement.Current.ProcessId
    if ($ExpectedProcessId -le 0) { $ExpectedProcessId = [int]$ProcessIdentity.Pid }
    if ($ExpectedProcessId -ne [int]$ProcessIdentity.Pid) {
        throw "Expected UIA PID $ExpectedProcessId does not match held window generation PID $($ProcessIdentity.Pid)."
    }
    $null = Assert-CapUiaProcessIds -ExpectedProcessId $ExpectedProcessId -ObservedProcessIds @($rootProcessId)
    $elements = $rootElement.FindAll($Scope, [System.Windows.Automation.Condition]::TrueCondition)
    return Resolve-CapAutomationCandidate -Candidates @($elements) -ExpectedProcessId $ExpectedProcessId `
        -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix -AllowOffscreen:$AllowOffscreen
}

function Get-CapDirectChildren {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Windows.Automation.AutomationElement]$Parent)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $children = $Parent.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    return @($children)
}

function Get-CapActionObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Parent,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][string[]]$RequiredNames,
        [scriptblock]$ChildrenResolver
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $children = if ($ChildrenResolver) { @(& $ChildrenResolver $Parent) } else { @(Get-CapDirectChildren -Parent $Parent) }
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($child in $children) {
        $current = if ($child.PSObject.Properties['Current']) { $child.Current } else { $child }
        $null = Assert-CapUiaProcessIds -ExpectedProcessId $ExpectedProcessId -ObservedProcessIds @([int]$current.ProcessId)
        if ($current.Name -notin $RequiredNames) { continue }
        $bounds = $current.BoundingRectangle
        if ($current.IsOffscreen -or $bounds.Width -le 0 -or $bounds.Height -le 0) {
            throw "Action observation '$($current.Name)' is not visibly bounded."
        }
        $observations.Add([pscustomobject]@{
            Name = [string]$current.Name
            AutomationId = [string]$current.AutomationId
            ProcessId = [int]$current.ProcessId
            IsEnabled = [bool]$current.IsEnabled
            Bounds = [pscustomobject]@{ Left = $bounds.Left; Top = $bounds.Top; Width = $bounds.Width; Height = $bounds.Height }
        })
    }
    foreach ($name in $RequiredNames) {
        $count = @($observations | Where-Object Name -CEQ $name).Count
        if ($count -ne 1) { throw "Expected one visible direct action observation '$name'; found=$count." }
    }
    return @($observations)
}

function Get-CapGraphActionObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$RootHandle,
        [Parameter(Mandatory)]$ProcessIdentity,
        [Parameter(Mandatory)][string[]]$RequiredNames,
        [scriptblock]$GraphResolver,
        [scriptblock]$ChildrenResolver,
        [scriptblock]$WindowProcessResolver
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if (($GraphResolver -or $ChildrenResolver -or $WindowProcessResolver) -and
        (-not $GraphResolver -or -not $ChildrenResolver -or -not $WindowProcessResolver)) {
        throw 'Graph/action observation mocks must supply all three resolver seams.'
    }
    $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity `
        -WindowProcessResolver $WindowProcessResolver
    $graph = if ($GraphResolver) {
        & $GraphResolver $RootHandle $ProcessIdentity
    } else {
        Find-CapAutomationElement -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity `
            -ExpectedProcessId $ProcessIdentity.Pid -Name 'Graph' -AutomationId 'graph'
    }
    if ($null -eq $graph) { throw 'The owned Graph UIA element is unavailable.' }
    $current = if ($graph.PSObject.Properties['Current']) { $graph.Current } else { $graph }
    $null = Assert-CapUiaProcessIds -ExpectedProcessId $ProcessIdentity.Pid -ObservedProcessIds @([int]$current.ProcessId)
    return Get-CapActionObservations -Parent $graph -ExpectedProcessId $ProcessIdentity.Pid `
        -RequiredNames $RequiredNames -ChildrenResolver $ChildrenResolver
}

function Assert-CapRootProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$RootHandle,
        [Parameter(Mandatory)]$ProcessIdentity,
        [scriptblock]$WindowProcessResolver
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $verified = Assert-CapProcessIdentity -Identity $ProcessIdentity
    if ($verified.State -ne 'Live') { throw "Root process PID $($ProcessIdentity.Pid) is no longer live." }
    $windowProcessId = if ($WindowProcessResolver) {
        [int](& $WindowProcessResolver $RootHandle)
    } else {
        [CapNative]::WindowProcessId($RootHandle)
    }
    if ($windowProcessId -ne [int]$ProcessIdentity.Pid) {
        throw "Root HWND belongs to PID $windowProcessId, not held generation PID $($ProcessIdentity.Pid)."
    }
    return $verified
}

function Invoke-CapAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][IntPtr]$RootHandle,
        [Parameter(Mandatory)]$ProcessIdentity,
        [string]$Name,
        [scriptblock]$Invoker,
        [scriptblock]$WindowProcessResolver,
        [scriptblock]$ElementResolver
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($Action -in @('reply', 'reclaim', 'keep')) { throw "Mutating graph action '$Action' is prohibited by the capture contract." }
    if ($Action -notin @('actual-size', 'open-project', 'overview-destination', 'open-loop', 'file-exit')) {
        throw "Unsupported capture action '$Action'."
    }
    if ($WindowProcessResolver -and -not $Invoker) { throw 'A custom HWND resolver is allowed only with the action mock.' }
    if ($ElementResolver -and -not $Invoker) { throw 'A custom UIA candidate resolver is allowed only with the action mock.' }
    if ($Invoker -and $Action -notin @('file-exit') -and -not $ElementResolver) {
        throw 'UIA action mocks must exercise the production candidate resolver.'
    }
    $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity -WindowProcessResolver $WindowProcessResolver
    $spec = Get-CapActionSpec -Action $Action -Name $Name
    if ($Action -eq 'file-exit') {
        if ($Invoker) { return & $Invoker $spec }
        $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity -WindowProcessResolver $WindowProcessResolver
        if (-not [GraphCodeUiaGateState]::PostCommand($RootHandle, [uint32]$spec.CommandId)) {
            throw 'Posting the native File > Exit command failed.'
        }
        return [pscustomobject]@{ Action = $Action; CommandId = $spec.CommandId; Invoked = $true }
    }
    $element = if ($ElementResolver) {
        $candidates = @(& $ElementResolver $RootHandle $ProcessIdentity $spec)
        Resolve-CapAutomationCandidate -Candidates $candidates -ExpectedProcessId $ProcessIdentity.Pid `
            -Name $spec.Name -AutomationId $spec.AutomationId -AutomationIdPrefix $spec.AutomationIdPrefix
    } else {
        Find-CapAutomationElement -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity `
            -ExpectedProcessId $ProcessIdentity.Pid -Name $spec.Name -AutomationId $spec.AutomationId `
            -AutomationIdPrefix $spec.AutomationIdPrefix
    }
    $current = if ($element.PSObject.Properties['Current']) { $element.Current } else { $element }
    $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity -WindowProcessResolver $WindowProcessResolver
    $null = Assert-CapUiaProcessIds -ExpectedProcessId $ProcessIdentity.Pid -ObservedProcessIds @([int]$current.ProcessId)
    if ($Invoker) { return & $Invoker $spec $element }
    $invoke = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invoke.Invoke()
    return [pscustomobject]@{
        Action = $Action
        Name = $spec.Name
        AutomationId = $element.Current.AutomationId
        Invoked = $true
    }
}

function Measure-CapZoom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Automation.AutomationElement]$Element,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$NaturalWidth
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $current = $Element.Current
    $rect = $current.BoundingRectangle
    if ($current.IsOffscreen -or $rect.Width -le 0 -or $rect.Height -le 0) {
        throw "Zoom probe '$($current.Name)' is not visibly bounded."
    }
    $percent = [Math]::Round(($rect.Width / $NaturalWidth) * 100, 2)
    if ($percent -lt 99 -or $percent -gt 101) { throw "Actual-size zoom measured $percent%, expected 100%." }
    return [pscustomobject]@{
        Name = $current.Name
        AutomationId = $current.AutomationId
        Bounds = [pscustomobject]@{ Left = $rect.Left; Top = $rect.Top; Width = $rect.Width; Height = $rect.Height }
        NaturalWidth = $NaturalWidth
        MeasuredWidth = $rect.Width
        ZoomPercent = $percent
    }
}

function Get-CapWindowMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $null = Assert-CapRootProcess -RootHandle $Window -ProcessIdentity $ProcessIdentity
    return [CapNative]::WindowSnapshot($Window, [int]$ProcessIdentity.Pid)
}

function Set-CapWindowPosition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity,
        [int]$X = 30,
        [int]$Y = 30,
        [int]$Width = 1456,
        [int]$Height = 959
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $null = Assert-CapRootProcess -RootHandle $Window -ProcessIdentity $ProcessIdentity
    if (-not [CapNative]::SetWindowPosition($Window, $X, $Y, $Width, $Height)) {
        throw "SetWindowPos failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Find-CapTopLevelWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ProcessIdentity,
        [ValidateSet('GraphCodeWindowsShell')][string]$ClassName = 'GraphCodeWindowsShell',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds -and [DateTime]::UtcNow -lt $DeadlineUtc) {
        $verified = Assert-CapProcessIdentity -Identity $ProcessIdentity
        if ($verified.State -ne 'Live') { throw "Owned app PID $($ProcessIdentity.Pid) exited before its window appeared." }
        $window = [GraphCodeUiaGateState]::FindTopLevel($ClassName, [uint32]$ProcessIdentity.Pid)
        if ($window -ne [IntPtr]::Zero) {
            $null = Assert-CapRootProcess -RootHandle $window -ProcessIdentity $ProcessIdentity
            return $window
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Owned window '$ClassName' did not appear within its remaining bounded wait."
}

function Capture-CapWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity,
        [Parameter(Mandatory)][string]$Path
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Capture directory missing: $parent" }
    $null = Assert-CapRootProcess -RootHandle $Window -ProcessIdentity $ProcessIdentity
    $result = [CapNative]::CaptureWindow($Window, [int]$ProcessIdentity.Pid, $Path)
    return [pscustomobject]@{
        Path = $Path
        Width = $result.Width
        Height = $result.Height
        SampledColors = $result.SampledColors
        NonMagentaSamples = $result.NonMagentaSamples
        Dpi = $result.Dpi
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    }
}

function ConvertTo-CapImagePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $value = $Path.Trim()
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\' + $value.Substring(8)
    } elseif ($value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(4)
    }
    return [IO.Path]::GetFullPath($value)
}

function Get-CapProcessIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$ExpectedImagePath,
        [Parameter(Mandatory)][string]$Role,
        [int]$ExpectedParentPid = -1,
        [int]$ExpectedSessionId = -1
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $snapshot = [CapNative]::Snapshot($Process.Handle, $Process.Id)
    if ($snapshot.ProcessId -ne $Process.Id) { throw "Kernel PID changed while tracking $Role." }
    $expected = ConvertTo-CapImagePath -Path $ExpectedImagePath
    if (-not $snapshot.IsExited -and (ConvertTo-CapImagePath -Path $snapshot.ImagePath) -ine $expected) {
        throw "Live $Role executable mismatch: $($snapshot.ImagePath) != $expected."
    }
    $metadata = $null
    if (-not $snapshot.IsExited) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $metadata = Get-CapCurrentMetadata -Pid $Process.Id
            if ($metadata) { break }
            $snapshot = [CapNative]::Snapshot($Process.Handle, $Process.Id)
            if ($snapshot.IsExited) { break }
            Start-Sleep -Milliseconds 50
        }
        if ($null -eq $metadata -and -not $snapshot.IsExited -and
            ($ExpectedParentPid -lt 0 -or $ExpectedSessionId -lt 0)) {
            throw "Live $Role PID $($Process.Id) has no current CIM metadata."
        }
    }
    $expectedMetadataMatches = if ($metadata) {
        ($ExpectedParentPid -lt 0 -or $metadata.ParentPid -eq $ExpectedParentPid) -and
        ($ExpectedSessionId -lt 0 -or $metadata.SessionId -eq $ExpectedSessionId)
    } else { $null }
    $identity = [pscustomobject]@{
        Process = $Process
        Pid = $snapshot.ProcessId
        CreationFileTimeUtc = $snapshot.CreationFileTimeUtc
        ImagePath = if ($snapshot.ImagePath) { ConvertTo-CapImagePath -Path $snapshot.ImagePath } else { $expected }
        ExpectedImagePath = $expected
        Role = $Role
        ParentPid = if ($ExpectedParentPid -ge 0) { $ExpectedParentPid } elseif ($metadata) { $metadata.ParentPid } else { $null }
        SessionId = if ($ExpectedSessionId -ge 0) { $ExpectedSessionId } elseif ($metadata) { $metadata.SessionId } else { $null }
        InitialMetadataObserved = $null -ne $metadata
        InitialMetadataMatchesExpected = $expectedMetadataMatches
    }
    if ($metadata) { $null = Assert-CapMetadataRecord -Identity $identity -Metadata $metadata }
    return $identity
}

function Convert-CapCimCreationTime {
    param([Parameter(Mandatory)]$Value)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($Value -is [DateTime]) { $date = $Value.ToUniversalTime() }
    elseif ($Value -is [string]) { $date = [Management.ManagementDateTimeConverter]::ToDateTime($Value).ToUniversalTime() }
    else { throw "Unsupported CIM CreationDate type: $($Value.GetType().FullName)" }
    return $date.ToFileTimeUtc()
}

function Assert-CapDescendantLifetime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$ParentCreationFileTimeUtc,
        [Parameter(Mandatory)][long]$ChildCreationFileTimeUtc,
        [long]$ParentExitFileTimeUtc = 0
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($ChildCreationFileTimeUtc -lt $ParentCreationFileTimeUtc -or
        ($ParentExitFileTimeUtc -gt 0 -and $ChildCreationFileTimeUtc -gt $ParentExitFileTimeUtc)) {
        throw "Child generation $ChildCreationFileTimeUtc is outside parent lifetime $ParentCreationFileTimeUtc..$ParentExitFileTimeUtc."
    }
    return $true
}

function Test-CapGraphAppRootRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Role)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    return $Role -match '^graphcode-app-(before|after)-(normal|actions)$'
}

function Get-CapCurrentMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Pid)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $Pid" -ErrorAction Stop)
    if ($rows.Count -ne 1) { return $null }
    $row = $rows[0]
    if ($null -eq $row.CreationDate -or [string]::IsNullOrWhiteSpace([string]$row.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace([string]$row.CommandLine) -or $null -eq $row.ParentProcessId) {
        throw "Live PID $Pid has incomplete current CIM metadata; refusing ownership inference."
    }
    return [pscustomobject]@{
        Pid = [int]$row.ProcessId
        ParentPid = [int]$row.ParentProcessId
        SessionId = [int]$row.SessionId
        CreationFileTimeUtc = Convert-CapCimCreationTime $row.CreationDate
        ImagePath = ConvertTo-CapImagePath -Path ([string]$row.ExecutablePath)
        CommandLine = [string]$row.CommandLine
    }
}

function Assert-CapMetadataRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Identity,
        [AllowNull()]$Metadata
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($null -eq $Metadata) { throw "Current CIM metadata is missing for live PID $($Identity.Pid); refusing." }
    if ([string]::IsNullOrWhiteSpace([string]$Metadata.CommandLine) -or
        [string]::IsNullOrWhiteSpace([string]$Metadata.ImagePath) -or
        $null -eq $Metadata.CreationFileTimeUtc -or $null -eq $Metadata.ParentPid -or
        $null -eq $Metadata.SessionId) {
        throw "Current CIM metadata is incomplete for live PID $($Identity.Pid); refusing."
    }
    $tolerance = [TimeSpan]::FromMilliseconds(100).Ticks
    if ([int]$Metadata.Pid -ne [int]$Identity.Pid -or
        [Math]::Abs([double]([long]$Metadata.CreationFileTimeUtc - [long]$Identity.CreationFileTimeUtc)) -gt $tolerance -or
        (ConvertTo-CapImagePath -Path ([string]$Metadata.ImagePath)) -ine
        (ConvertTo-CapImagePath -Path ([string]$Identity.ExpectedImagePath)) -or
        [int]$Metadata.ParentPid -ne [int]$Identity.ParentPid -or
        [int]$Metadata.SessionId -ne [int]$Identity.SessionId) {
        throw "Current CIM metadata no longer identifies owned PID $($Identity.Pid); refusing."
    }
    return $true
}

function Assert-CapProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($Identity.Pid -ne $Identity.Process.Id) { throw "Tracked PID changed for $($Identity.Role)." }
    $snapshot = [CapNative]::Snapshot($Identity.Process.Handle, $Identity.Pid)
    if ($snapshot.IsExited) { return [pscustomobject]@{ State = 'Exited'; Snapshot = $snapshot; Metadata = $null } }
    if ($snapshot.ProcessId -ne $Identity.Pid -or
        $snapshot.CreationFileTimeUtc -ne [long]$Identity.CreationFileTimeUtc -or
        (ConvertTo-CapImagePath -Path $snapshot.ImagePath) -ine
        (ConvertTo-CapImagePath -Path $Identity.ExpectedImagePath)) {
        throw "Kernel process identity changed for live PID $($Identity.Pid); refusing."
    }
    $metadata = Get-CapCurrentMetadata -Pid $Identity.Pid
    if ($null -eq $metadata) {
        if ([CapNative]::IsExited($Identity.Process.Handle, $Identity.Pid)) { return [pscustomobject]@{ State = 'Exited'; Snapshot = $snapshot; Metadata = $null } }
        throw "Live PID $($Identity.Pid) has no current CIM row; refusing."
    }
    $null = Assert-CapMetadataRecord -Identity $Identity -Metadata $metadata
    return [pscustomobject]@{ State = 'Live'; Snapshot = $snapshot; Metadata = $metadata }
}

function Stop-CapManagedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Identity,
        [uint32]$ExitCode = 125,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 5000
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $verified = Assert-CapProcessIdentity -Identity $Identity
    if ($verified.State -eq 'Exited') {
        return [pscustomobject]@{ Pid = $Identity.Pid; Role = $Identity.Role; Result = 'SKIP_GENUINELY_EXITED_KERNEL' }
    }
    $terminated = [CapNative]::Terminate($Identity.Process.Handle, $Identity.Pid, $ExitCode, $TimeoutMilliseconds)
    if (-not [CapNative]::IsExited($Identity.Process.Handle, $Identity.Pid)) { throw "Owned process PID $($Identity.Pid) remains live after guarded termination." }
    return [pscustomobject]@{ Pid = $Identity.Pid; Role = $Identity.Role
        Result = if ($terminated) { 'TERMINATED_GUARDED_HANDLE' } else { 'EXITED_DURING_GUARDED_STOP' } }
}

function Wait-CapManagedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [ValidateRange(10, 1000)][int]$PollMilliseconds = 100
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $process = $Run.Identity.Process
    if ($process.Id -ne $Run.Identity.Pid) { throw "Held process PID changed for $($Run.Identity.Role)." }
    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        $remaining = [int][Math]::Max(1, [Math]::Min(
            $PollMilliseconds,
            [Math]::Ceiling(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
        ))
        if ($process.WaitForExit($remaining)) {
            return [pscustomobject]@{
                State = 'Exited'
                ExitCode = $process.ExitCode
                CompletedUtc = [DateTime]::UtcNow
            }
        }
    }
    return [pscustomobject]@{ State = 'TimedOut'; ExitCode = $null; CompletedUtc = [DateTime]::UtcNow }
}

function Invoke-CapLaunchRollback {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LaunchRecord)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $process = $LaunchRecord.Process
    $snapshot = [CapNative]::Snapshot($process.Handle, $process.Id)
    $result = $null
    if ($snapshot.IsExited) {
        $result = 'SKIP_GENUINELY_EXITED_KERNEL'
    } else {
        $metadata = $null
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $metadata = Get-CapCurrentMetadata -Pid $process.Id
            if ($metadata) { break }
            $snapshot = [CapNative]::Snapshot($process.Handle, $process.Id)
            if ($snapshot.IsExited) { break }
            Start-Sleep -Milliseconds 50
        }
        if ($snapshot.IsExited) {
            $result = 'SKIP_GENUINELY_EXITED_KERNEL'
        } elseif ($null -eq $metadata) {
            throw "Rollback refused for live PID $($process.Id): current process metadata is unavailable."
        } else {
            $expectedPath = ConvertTo-CapImagePath -Path $LaunchRecord.ExpectedImagePath
            if ($metadata.Pid -ne $process.Id -or
                [Math]::Abs([double]([long]$metadata.CreationFileTimeUtc - [long]$snapshot.CreationFileTimeUtc)) -gt
                [TimeSpan]::FromMilliseconds(100).Ticks -or
                $metadata.ImagePath -ine $expectedPath -or
                $metadata.ParentPid -ne $LaunchRecord.ExpectedParentPid -or
                $metadata.SessionId -ne $LaunchRecord.ExpectedSessionId) {
                throw "Rollback refused for live PID $($process.Id): current kernel/CIM identity differs from the held launch record."
            }
            $identity = [pscustomobject]@{
                Process = $process
                Pid = $process.Id
                CreationFileTimeUtc = $snapshot.CreationFileTimeUtc
                ImagePath = $expectedPath
                ExpectedImagePath = $expectedPath
                Role = $LaunchRecord.Role
                ParentPid = $LaunchRecord.ExpectedParentPid
                SessionId = $LaunchRecord.ExpectedSessionId
                InitialMetadataObserved = $true
                InitialMetadataMatchesExpected = $true
            }
            $null = Assert-CapMetadataRecord -Identity $identity -Metadata $metadata
            $stop = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
            $result = $stop.Result
        }
    }
    if ($null -eq $LaunchRecord.StdoutTask) { $LaunchRecord.StdoutTask = $process.StandardOutput.ReadToEndAsync() }
    if ($null -eq $LaunchRecord.StderrTask) { $LaunchRecord.StderrTask = $process.StandardError.ReadToEndAsync() }
    if (-not $LaunchRecord.StdoutTask.Wait(2000)) { throw "Rollback stdout reader did not reach bounded EOF for PID $($process.Id)." }
    if (-not $LaunchRecord.StderrTask.Wait(2000)) { throw "Rollback stderr reader did not reach bounded EOF for PID $($process.Id)." }
    $stdout = [string]$LaunchRecord.StdoutTask.Result
    $stderr = [string]$LaunchRecord.StderrTask.Result
    if (-not [CapNative]::IsExited($process.Handle, $process.Id)) { throw "Rollback left live PID $($process.Id)." }
    return [pscustomobject]@{
        Pid = $process.Id
        Role = $LaunchRecord.Role
        ExpectedPath = $LaunchRecord.ExpectedImagePath
        CreationFileTimeUtc = $snapshot.CreationFileTimeUtc
        Result = $result
        KernelExited = $true
        StdoutEof = $true
        StderrEof = $true
        StdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
        StderrBytes = [Text.Encoding]::UTF8.GetByteCount($stderr)
    }
}

function Start-CapManagedProcessCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Role,
        [hashtable]$Environment = @{},
        [switch]$CloseStdin,
        [scriptblock]$AttestationOverride
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $fullPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Executable missing: $fullPath" }
    $parentMetadata = Get-CapCurrentMetadata -Pid $PID
    if ($null -eq $parentMetadata) { throw "Cannot establish current metadata for launcher PID $PID." }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fullPath
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = [bool]$CloseStdin
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    foreach ($key in @($startInfo.Environment.Keys)) {
        if ([string]$key -like 'GRAPHCODE_*' -or [string]$key -like 'ZMX_*') {
            $null = $startInfo.Environment.Remove([string]$key)
        }
    }
    foreach ($key in $Environment.Keys) { $startInfo.Environment[[string]$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { throw "Process.Start returned null for $Role." }
    $launchRecord = [pscustomobject]@{
        Process = $process
        ExpectedImagePath = $fullPath
        ExpectedParentPid = $PID
        ExpectedSessionId = $parentMetadata.SessionId
        Role = $Role
        StartInfo = $startInfo
        Snapshot = $null
        StdoutTask = $null
        StderrTask = $null
        Identity = $null
        StartFailure = $null
        RollbackFailure = $null
    }
    $script:CapPendingLaunches.Add($launchRecord)
    try {
        $launchRecord.Snapshot = [CapNative]::Snapshot($process.Handle, $process.Id)
        $launchRecord.StdoutTask = $process.StandardOutput.ReadToEndAsync()
        $launchRecord.StderrTask = $process.StandardError.ReadToEndAsync()
        Write-CapTrace -Command 'Process.Start' -Parameters @{
            FilePath = $fullPath; ArgumentList = $ArgumentList; Role = $Role
            Pid = $process.Id; CreationFileTimeUtc = $launchRecord.Snapshot.CreationFileTimeUtc
            HeldKernelHandle = $process.Handle.ToInt64(); ExpectedParentPid = $PID
            ExpectedSessionId = $parentMetadata.SessionId
        }
        if (-not $launchRecord.Snapshot.IsExited -and
            (ConvertTo-CapImagePath -Path $launchRecord.Snapshot.ImagePath) -ine $fullPath) {
            throw "Kernel image path mismatch after Process.Start for $Role."
        }
        $identity = if ($AttestationOverride) {
            & $AttestationOverride $process $fullPath $Role $PID $parentMetadata.SessionId
        } else {
            Get-CapProcessIdentity -Process $process -ExpectedImagePath $fullPath -Role $Role `
                -ExpectedParentPid $PID -ExpectedSessionId $parentMetadata.SessionId
        }
        if ($identity.Pid -ne $process.Id -or $identity.CreationFileTimeUtc -ne $launchRecord.Snapshot.CreationFileTimeUtc) {
            throw "Identity attestor returned a different kernel generation for $Role."
        }
        if (-not [CapNative]::IsExited($process.Handle, $process.Id)) {
            if (-not $identity.InitialMetadataObserved -or -not $identity.InitialMetadataMatchesExpected) {
                throw "Live $Role PID $($process.Id) lacks a complete expected-parent/session attestation."
            }
            $null = Assert-CapProcessIdentity -Identity $identity
        }
        $launchRecord.Identity = $identity
        if ($CloseStdin) { $process.StandardInput.Close() }
        $null = $script:CapPendingLaunches.Remove($launchRecord)
    } catch {
        $startFailure = $_.Exception
        $launchRecord.StartFailure = $startFailure.Message
        try {
            $rollback = Invoke-CapLaunchRollback -LaunchRecord $launchRecord
            $script:CapLastRollbackReceipt = $rollback
            $null = $script:CapPendingLaunches.Remove($launchRecord)
            $process.Dispose()
        } catch {
            $launchRecord.RollbackFailure = $_.Exception.Message
            $script:CapLastRollbackReceipt = [pscustomobject]@{
                Pid = $process.Id
                Role = $Role
                ExpectedPath = $fullPath
                CreationFileTimeUtc = if ($launchRecord.Snapshot) { $launchRecord.Snapshot.CreationFileTimeUtc } else { $null }
                KernelExited = if ($launchRecord.Snapshot) { [bool]$launchRecord.Snapshot.IsExited } else { $null }
                RollbackFailure = $launchRecord.RollbackFailure
                RefusedUnsafeTermination = $true
            }
            throw "Process.Start identity attestation failed for $Role PID $($process.Id): $($startFailure.Message); guarded rollback also failed: $($launchRecord.RollbackFailure)."
        }
        throw "Process.Start identity attestation failed for $Role PID $($process.Id): $($startFailure.Message); guarded rollback=$($rollback.Result), stdoutEOF=$($rollback.StdoutEof), stderrEOF=$($rollback.StderrEof)."
    }
    return [pscustomobject]@{
        Identity = $identity
        StdoutTask = $launchRecord.StdoutTask
        StderrTask = $launchRecord.StderrTask
        StartInfo = $startInfo
        StdinClosed = [bool]$CloseStdin
        StartedUtc = [DateTime]::UtcNow
    }
}

function Start-CapManagedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Role,
        [hashtable]$Environment = @{},
        [switch]$CloseStdin
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if ($script:CapTraceFailures.Count -gt 0) { throw 'Capture tracing failed; refusing a new process launch.' }

    return Start-CapManagedProcessCore @PSBoundParameters
}

function Test-CapManagedProcessRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    $script:CapLastRollbackReceipt = $null
    $injectFailure = {
        param($Process, $ExpectedPath, $Role, $ParentPid, $SessionId)
        $identity = Get-CapProcessIdentity -Process $Process -ExpectedImagePath $ExpectedPath -Role $Role `
            -ExpectedParentPid $ParentPid -ExpectedSessionId $SessionId
        if (-not $identity.InitialMetadataObserved -or -not $identity.InitialMetadataMatchesExpected) {
            throw 'Failure injection could not first establish the child identity.'
        }
        throw 'INJECTED_IDENTITY_ATTESTATION_FAILURE'
    }.GetNewClosure()
    try {
        $null = Start-CapManagedProcessCore -FilePath $ProcessPath -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 10'
        ) `
            -WorkingDirectory $WorkingDirectory -Role 'rollback-failure-injection' -AttestationOverride $injectFailure
        throw 'Identity attestation failure injection unexpectedly returned a child.'
    } catch {
        if ($_.Exception.Message -like 'Identity attestation failure injection unexpectedly returned*') { throw }
        if ($_.Exception.Message -notlike '*INJECTED_IDENTITY_ATTESTATION_FAILURE*') { throw }
    }
    if ($script:CapPendingLaunches.Count -ne 0) { throw "Unreturned child launch records remain: $($script:CapPendingLaunches.Count)." }
    if ($null -eq $script:CapLastRollbackReceipt -or
        -not $script:CapLastRollbackReceipt.KernelExited -or
        -not $script:CapLastRollbackReceipt.StdoutEof -or
        -not $script:CapLastRollbackReceipt.StderrEof) {
        throw 'Failure-injected child rollback did not prove kernel exit and both bounded EOF readers.'
    }
    return $script:CapLastRollbackReceipt
}

function Get-CapPendingLaunches {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    return @($script:CapPendingLaunches | ForEach-Object {
        $record = $_
        $kernelExited = $null
        $kernelProbeFailure = $null
        try { $kernelExited = [CapNative]::IsExited($record.Process.Handle, $record.Process.Id) }
        catch [InvalidOperationException], [ComponentModel.Win32Exception] { $kernelProbeFailure = $_.Exception.ToString() }
        [pscustomobject]@{
            Pid = $record.Process.Id
            Role = $record.Role
            ExpectedPath = $record.ExpectedImagePath
            CreationFileTimeUtc = if ($record.Snapshot) { $record.Snapshot.CreationFileTimeUtc } else { $null }
            ExpectedParentPid = $record.ExpectedParentPid
            ExpectedSessionId = $record.ExpectedSessionId
            StartFailure = $record.StartFailure
            RollbackFailure = $record.RollbackFailure
            KernelExited = $kernelExited
            KernelProbeFailure = $kernelProbeFailure
        }
    })
}

function Get-CapExcludedDescendants {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    return @($script:CapExcludedDescendants.ToArray())
}

function Resolve-CapPendingLaunches {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $results = [Collections.Generic.List[object]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($record in $script:CapPendingLaunches.ToArray()) {
        try {
            $receipt = Invoke-CapLaunchRollback -LaunchRecord $record
            $results.Add($receipt)
            $null = $script:CapPendingLaunches.Remove($record)
            $record.Process.Dispose()
        } catch {
            $failures.Add("PID $($record.Process.Id) role=$($record.Role): $($_.Exception.Message)")
        }
    }
    if ($failures.Count) { throw "Pending launch rollback refused or failed: $($failures -join '; ')" }
    return @($results)
}

function Get-CapOwnedDescendants {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Roots,
        [Parameter(Mandatory)][string]$ZmxPath,
        [Parameter(Mandatory)][string]$CmdPath,
        [Parameter(Mandatory)][string]$ConhostPath,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$CommandMarker,
        [switch]$AllowGraphCodeRoot,
        [switch]$AllowUnmarkedCmd
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $known = [Collections.Generic.Dictionary[int, object]]::new()
    foreach ($root in $Roots) { $known[$root.Pid] = $root }
    $children = [Collections.Generic.List[object]]::new()
    for ($pass = 0; $pass -lt 8; $pass++) {
        $changed = $false
        $rows = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        foreach ($row in $rows) {
            $pid = [int]$row.ProcessId
            if ($known.ContainsKey($pid) -or -not $known.ContainsKey([int]$row.ParentProcessId)) { continue }
            $parent = $known[[int]$row.ParentProcessId]
            $process = $null
            try { $process = [Diagnostics.Process]::GetProcessById($pid) }
            catch [ArgumentException] { continue }
            $identity = Get-CapProcessIdentity -Process $process -ExpectedImagePath ([string]$row.ExecutablePath) `
                -Role 'descendant' -ExpectedParentPid $parent.Pid -ExpectedSessionId $parent.SessionId
            $verified = Assert-CapProcessIdentity -Identity $identity
            if ($verified.State -eq 'Exited') { $process.Dispose(); continue }
            $meta = $verified.Metadata
            $parentSnapshot = [CapNative]::Snapshot($parent.Process.Handle, $parent.Pid)
            $parentExitFileTimeUtc = [long]$parentSnapshot.ExitFileTimeUtc
            $outsideParentLifetime =
                ([long]$meta.CreationFileTimeUtc -lt [long]$parent.CreationFileTimeUtc) -or
                ($parentExitFileTimeUtc -gt 0 -and
                    [long]$meta.CreationFileTimeUtc -gt $parentExitFileTimeUtc)
            if ($outsideParentLifetime) {
                $alreadyRecorded = @($script:CapExcludedDescendants | Where-Object {
                    $_.Pid -eq $pid -and $_.ParentPid -eq $parent.Pid -and
                    $_.CandidateCreationFileTimeUtc -eq [long]$meta.CreationFileTimeUtc
                }).Count -gt 0
                if (-not $alreadyRecorded) {
                    $script:CapExcludedDescendants.Add([pscustomobject]@{
                        Pid = $pid
                        ParentPid = $parent.Pid
                        ParentCreationFileTimeUtc = [long]$parent.CreationFileTimeUtc
                        ParentExitFileTimeUtc = $parentExitFileTimeUtc
                        CandidateCreationFileTimeUtc = [long]$meta.CreationFileTimeUtc
                        CandidateImagePath = $meta.ImagePath
                        CandidateCommandLineSha256 = [Convert]::ToHexString(
                            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($meta.CommandLine))
                        )
                        Disposition = 'REJECTED_PARENT_PID_REUSE_NOT_TERMINATED'
                    })
                }
                $process.Dispose()
                continue
            }
            $null = Assert-CapDescendantLifetime `
                -ParentCreationFileTimeUtc ([long]$parent.CreationFileTimeUtc) `
                -ChildCreationFileTimeUtc ([long]$meta.CreationFileTimeUtc) `
                -ParentExitFileTimeUtc $parentExitFileTimeUtc
            if ($meta.ParentPid -ne $parent.Pid -or
                $meta.SessionId -ne $parent.SessionId) {
                $process.Dispose()
                throw "Descendant PID $pid does not match the saved parent generation/session; refusing."
            }
            $imagePath = ConvertTo-CapImagePath -Path ([string]$meta.ImagePath)
            if ($imagePath -ieq (ConvertTo-CapImagePath -Path $ZmxPath)) {
                $validParentRole = $parent.Role -eq 'zmx-seed' -or
                    ($AllowGraphCodeRoot -and (Test-CapGraphAppRootRole -Role $parent.Role))
                if (-not $validParentRole -or $meta.CommandLine -notlike "*$SessionName*") {
                    $process.Dispose()
                    throw "Unrecognized live zmx child PID $pid; refusing."
                }
                $identity.Role = 'zmx-daemon'
            } elseif ($imagePath -ieq (ConvertTo-CapImagePath -Path $CmdPath)) {
                $commandMatches = $CommandMarker -and $meta.CommandLine -like "*$CommandMarker*"
                if ($parent.Role -notin @('zmx-daemon', 'offline-cmd-peer') -or
                    (-not $commandMatches -and -not $AllowUnmarkedCmd)) {
                    $process.Dispose()
                    throw "Unrecognized live cmd child PID $pid; refusing."
                }
                $identity.Role = 'offline-cmd-peer'
            } elseif ($imagePath -ieq (ConvertTo-CapImagePath -Path $ConhostPath)) {
                $commandLine = $meta.CommandLine.Trim()
                if ($commandLine.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
                    $commandLine = $commandLine.Substring(4)
                } elseif ($commandLine.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
                    $commandLine = $commandLine.Substring(4)
                }
                $commandParts = @($commandLine -split '\s+')
                $knownConhostCommand = $false
                if ($commandParts.Count -eq 2) {
                    $knownConhostCommand =
                        ((ConvertTo-CapImagePath -Path $commandParts[0]) -ieq (ConvertTo-CapImagePath -Path $ConhostPath)) -and
                        ($commandParts[1] -match '^0x[0-9a-fA-F]+$')
                } elseif ($commandParts.Count -eq 10) {
                    $knownConhostCommand =
                        ((ConvertTo-CapImagePath -Path $commandParts[0]) -ieq (ConvertTo-CapImagePath -Path $ConhostPath)) -and
                        ($commandParts[1] -ceq '--headless') -and
                        ($commandParts[2] -ceq '--width') -and
                        ($commandParts[3] -match '^[1-9][0-9]*$') -and
                        ($commandParts[4] -ceq '--height') -and
                        ($commandParts[5] -match '^[1-9][0-9]*$') -and
                        ($commandParts[6] -ceq '--signal') -and
                        ($commandParts[7] -match '^0x[0-9a-fA-F]+$') -and
                        ($commandParts[8] -ceq '--server') -and
                        ($commandParts[9] -match '^0x[0-9a-fA-F]+$')
                }
                $validConhostParent = $parent.Role -eq 'zmx-daemon' -or
                    ($AllowUnmarkedCmd -and $parent.Role -eq 'offline-cmd-peer')
                if (-not $validConhostParent -or -not $knownConhostCommand) {
                    $process.Dispose()
                    throw "Unrecognized live ConPTY conhost child PID $pid; refusing."
                }
                $identity.Role = 'conpty-conhost'
            } else {
                $process.Dispose()
                throw "Unknown live descendant PID $pid image='$($meta.ImagePath)'; refusing."
            }
            $known[$pid] = $identity
            $children.Add($identity)
            $changed = $true
        }
        if (-not $changed) { break }
    }
    return @($children)
}

function Test-CapPipeUnserved {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PipeName)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $errorCode = [CapNative]::ProbePipe($PipeName, 200)
    if ($errorCode -eq 2) { return [pscustomobject]@{ PipeName = $PipeName; Unserved = $true; Win32Error = $errorCode } }
    if ($errorCode -eq 0) { throw "Unique pipe '$PipeName' unexpectedly has a server." }
    throw "Pipe '$PipeName' probe is ambiguous or failed with Win32 error $errorCode."
}

function Test-CapNativeBindings {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $types = @([CapNative], [GraphCodeUiaGateState])
    $bindings = [Collections.Generic.List[object]]::new()
    foreach ($type in $types) {
        foreach ($method in $type.GetMethods([Reflection.BindingFlags]'Static,Public,NonPublic')) {
            $import = $method.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false) |
                Select-Object -First 1
            if ($null -eq $import) { continue }
            $libraryHandle = [IntPtr]::Zero
            try {
                $libraryHandle = [Runtime.InteropServices.NativeLibrary]::Load($import.Value)
                $entryPoint = if ([string]::IsNullOrWhiteSpace($import.EntryPoint)) { $method.Name } else { $import.EntryPoint }
                $candidates = [Collections.Generic.List[string]]::new()
                if (-not $import.ExactSpelling) {
                    switch ($import.CharSet) {
                        ([Runtime.InteropServices.CharSet]::Unicode) { $candidates.Add($entryPoint + 'W') }
                        ([Runtime.InteropServices.CharSet]::Auto) { $candidates.Add($entryPoint + 'W') }
                        default { $candidates.Add($entryPoint + 'A') }
                    }
                }
                $candidates.Add($entryPoint)
                $resolvedEntryPoint = $null
                foreach ($candidate in $candidates) {
                    $address = [IntPtr]::Zero
                    if ([Runtime.InteropServices.NativeLibrary]::TryGetExport($libraryHandle, $candidate, [ref]$address) -and
                        $address -ne [IntPtr]::Zero) {
                        $resolvedEntryPoint = $candidate
                        break
                    }
                }
                if ($null -eq $resolvedEntryPoint) {
                    throw "Native export '$entryPoint' (candidates=$($candidates -join ', ')) is missing from '$($import.Value)' for $($type.FullName)."
                }
                $bindings.Add([pscustomobject]@{ Type = $type.FullName; Method = $method.Name; Library = $import.Value; EntryPoint = $resolvedEntryPoint })
            } finally {
                if ($libraryHandle -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($libraryHandle) }
            }
        }
    }
    if ($bindings.Count -eq 0) { throw 'No native P/Invoke bindings were inspected.' }
    return @($bindings)
}

function Test-CapFixtureIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$Namespace
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $phaseRoots = @()
    foreach ($phase in @('before', 'after')) {
        $phaseRoot = Join-Path $rootFull "preflight\$Namespace\phases\$phase"
        $phaseRoots += [IO.Path]::GetFullPath($phaseRoot)
        foreach ($name in @('support', 'local', 'temp', 'tmp', 'profile', 'zmx')) {
            $path = Join-Path $phaseRoot $name
            $full = [IO.Path]::GetFullPath($path)
            if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture path escapes cap root: $full" }
            if ($full -match '\\(ia|ib|ic|id|ie)(\\|$)' -or $full -match '\\gcia(\\|$)') { throw "Foreign lane/runtime path found: $full" }
            New-Item -ItemType Directory -Path $full -Force | Out-Null
        }
    }
    if ($phaseRoots[0] -ieq $phaseRoots[1]) { throw 'Before/after fixture roots are not isolated.' }
    $supportBefore = Join-Path $phaseRoots[0] 'support'
    $supportAfter = Join-Path $phaseRoots[1] 'support'
    [IO.File]::WriteAllText((Join-Path $supportBefore 'onboarding-seen'), '1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $supportAfter 'onboarding-seen'), '1', [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Root = $rootFull
        BeforeRoot = $phaseRoots[0]
        AfterRoot = $phaseRoots[1]
        BeforeSupport = $supportBefore
        AfterSupport = $supportAfter
        SupportFilesDistinct = ((Join-Path $supportBefore 'onboarding-seen') -ine (Join-Path $supportAfter 'onboarding-seen'))
        SharedFixturePath = Join-Path $rootFull 'fixtures\fixture.json'
        SharedFixtureSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $rootFull 'fixtures\fixture.json')).Hash
    }
}

function ConvertTo-CapUtcInstant {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Field
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($Value -notmatch '(?i)(?:Z|[+-]\d{2}:\d{2})$') {
        throw "$Field must include an explicit UTC marker or numeric offset."
    }
    try {
        return [DateTimeOffset]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None
        ).UtcDateTime
    } catch {
        throw "$Field is not a valid offset-qualified timestamp: $Value"
    }
}

function Get-CapLeaseWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GrantedUtc,
        [Parameter(Mandatory)][string]$ExpiresUtc,
        [Parameter(Mandatory)][double]$MaximumMinutes,
        [Parameter(Mandatory)][DateTime]$NowUtc
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        throw 'Lease validation clock must be an explicitly UTC DateTime.'
    }
    $granted = ConvertTo-CapUtcInstant -Value $GrantedUtc -Field 'grantedUtc'
    $expires = ConvertTo-CapUtcInstant -Value $ExpiresUtc -Field 'expiresUtc'
    $durationMinutes = ($expires - $granted).TotalMinutes
    if ($MaximumMinutes -le 0 -or $MaximumMinutes -gt 15 -or
        $durationMinutes -le 0 -or $durationMinutes -gt $MaximumMinutes -or
        $durationMinutes -gt 15 -or $granted -gt $NowUtc -or $expires -le $NowUtc) {
        throw 'Coordinator lease is expired, future-dated, or exceeds the 15-minute allocation ceiling.'
    }
    return [pscustomobject]@{
        GrantedUtc = $granted
        ExpiresUtc = $expires
        WorkerDeadlineUtc = $expires.AddSeconds(-90)
        DurationMinutes = $durationMinutes
        MaximumMinutes = $MaximumMinutes
        NowUtc = $NowUtc
    }
}

function Get-CapAuthorizedWorkerDeadline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkerDeadlineUtc,
        [Parameter(Mandatory)]$LeaseWindow,
        [Parameter(Mandatory)][DateTime]$NowUtc
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        throw 'Worker deadline validation clock must be an explicitly UTC DateTime.'
    }
    $deadline = ConvertTo-CapUtcInstant -Value $WorkerDeadlineUtc -Field 'workerDeadlineUtc'
    if ($deadline -ne $LeaseWindow.WorkerDeadlineUtc) {
        throw 'Coordinator authorization worker deadline does not match the validated lease cleanup reserve.'
    }
    if ($deadline -le $NowUtc) {
        throw 'Coordinator-granted worker deadline has already expired.'
    }
    return $deadline
}

Export-ModuleMember -Function @(
    'Set-CapTracePath',
    'Write-CapTrace',
    'Get-CapTraceFailures',
    'Assert-CapArtifactPath',
    'Assert-CapFixtureMapping',
    'Assert-CapDescendantLifetime',
    'Test-CapGraphAppRootRole',
    'Resolve-CapAutomationCandidate',
    'Get-CapActionSpec',
    'Find-CapAutomationElement',
    'Get-CapDirectChildren',
    'Get-CapActionObservations',
    'Get-CapGraphActionObservations',
    'Assert-CapRootProcess',
    'Assert-CapUiaProcessIds',
    'Invoke-CapAction',
    'Measure-CapZoom',
    'Get-CapWindowMetrics',
    'Set-CapWindowPosition',
    'Find-CapTopLevelWindow',
    'Capture-CapWindow',
    'Get-CapProcessIdentity',
    'Get-CapCurrentMetadata',
    'Assert-CapMetadataRecord',
    'Assert-CapProcessIdentity',
    'Stop-CapManagedProcess',
    'Wait-CapManagedProcess',
    'Test-CapManagedProcessRollback',
    'Start-CapManagedProcess',
    'Get-CapPendingLaunches',
    'Get-CapExcludedDescendants',
    'Resolve-CapPendingLaunches',
    'Get-CapOwnedDescendants',
    'Test-CapNativeBindings',
    'Test-CapPipeUnserved',
    'Test-CapFixtureIsolation',
    'Get-CapLeaseWindow',
    'Get-CapAuthorizedWorkerDeadline'
)
