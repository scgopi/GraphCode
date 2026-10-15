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
    # Observability (records the ACTUAL terminal classification and whether the
    # conclusion was governed by a retained kernel exit; never a mere alias of the
    # metadata-observed flag).
    $terminalState = if ($snapshot.IsExited) { 'KernelExitedBeforeQuery' } else { $null }
    $concludedGoneByKernelExit = [bool]$snapshot.IsExited
    if (-not $snapshot.IsExited) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $state = Read-CapProcessMetadataState -Pid $Process.Id
            # The retained kernel handle governs an Absent/Incomplete reading. EOF is
            # proven later by the launch caller, so the loop passes BothStreamsEofReached
            # = $false and treats either exited disposition as "break and defer the EOF
            # gate to the caller".
            $snapshot = [CapNative]::Snapshot($Process.Handle, $Process.Id)
            $disposition = Resolve-CapAttestationDisposition -State $state.State `
                -KernelExited ([bool]$snapshot.IsExited) -BothStreamsEofReached $false
            $terminalState = if ($snapshot.IsExited) { "KernelExitedWith$($state.State)" } else { $state.State }
            if ($disposition -eq 'UseMetadata') { $metadata = $state.Metadata; break }
            if ($disposition -eq 'GoneByKernelExit' -or $disposition -eq 'RequireBothEofBeforeGone') {
                $concludedGoneByKernelExit = $true; break
            }
            if ($disposition -eq 'RefuseLiveIncomplete') {
                # A torn-down row on a still-live owned child is refused outright,
                # exactly as main did; it is never retried into a passing outcome.
                throw "Live $Role PID $($Process.Id) has incomplete current CIM metadata; refusing ownership inference."
            }
            # RetryAbsent: not yet listed on a live child -> bounded startup re-poll.
            Start-Sleep -Milliseconds 50
        }
        if ($null -eq $metadata -and -not $concludedGoneByKernelExit -and -not $snapshot.IsExited -and
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
        AttestationTerminalState = $terminalState
        ConcludedGoneByKernelExit = $concludedGoneByKernelExit
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

function Read-CapProcessMetadataState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Pid)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    # Classify the current Win32_Process reading without inferring liveness:
    #   Absent     - no single matching row (the PID is not currently listed)
    #   Incomplete - a row exists but a required field is torn down/unreadable
    #   Complete    - a fully populated owned-process row
    # The caller decides what Absent/Incomplete means by consulting the retained
    # kernel handle; this function never treats a missing field as proof of death.
    $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $Pid" -ErrorAction Stop)
    if ($rows.Count -ne 1) { return [pscustomobject]@{ State = 'Absent'; Metadata = $null } }
    $row = $rows[0]
    if ($null -eq $row.CreationDate -or [string]::IsNullOrWhiteSpace([string]$row.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace([string]$row.CommandLine) -or $null -eq $row.ParentProcessId) {
        return [pscustomobject]@{ State = 'Incomplete'; Metadata = $null }
    }
    return [pscustomobject]@{
        State = 'Complete'
        Metadata = [pscustomobject]@{
            Pid = [int]$row.ProcessId
            ParentPid = [int]$row.ParentProcessId
            SessionId = [int]$row.SessionId
            CreationFileTimeUtc = Convert-CapCimCreationTime $row.CreationDate
            ImagePath = ConvertTo-CapImagePath -Path ([string]$row.ExecutablePath)
            CommandLine = [string]$row.CommandLine
        }
    }
}

function Resolve-CapAttestationDisposition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Complete', 'Incomplete', 'Absent')][string]$State,
        [Parameter(Mandatory)][bool]$KernelExited,
        [Parameter(Mandatory)][bool]$BothStreamsEofReached
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    # Pure decision rule bound to the (observed CIM classification x retained-kernel
    # exit x both-stream EOF) matrix. No process, I/O or timing. It encodes two
    # invariants: the retained kernel handle governs an Absent/Incomplete reading,
    # and a genuinely-gone conclusion requires both redirected streams to have
    # reached bounded EOF - a kernel exit alone never suffices.
    #   UseMetadata              - live child, complete row; attest with it.
    #   RefuseLiveIncomplete     - live child, torn-down row; refuse immediately.
    #   RetryAbsent              - live child, not yet listed; bounded startup re-poll.
    #   GoneByKernelExit         - kernel exited AND both streams reached EOF; gone.
    #   RequireBothEofBeforeGone - kernel exited but EOF not yet proven; not gone.
    if (-not $KernelExited) {
        switch ($State) {
            'Complete' { return 'UseMetadata' }
            'Incomplete' { return 'RefuseLiveIncomplete' }
            'Absent' { return 'RetryAbsent' }
        }
    }
    if ($BothStreamsEofReached) { return 'GoneByKernelExit' }
    return 'RequireBothEofBeforeGone'
}

function Get-CapCurrentMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Pid)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    # Strict contract (unchanged): a complete reading returns the metadata record,
    # an absent reading returns $null, and an incomplete reading is refused. Callers
    # that must distinguish incomplete from absent use Read-CapProcessMetadataState.
    $state = Read-CapProcessMetadataState -Pid $Pid
    if ($state.State -eq 'Incomplete') {
        throw "Live PID $Pid has incomplete current CIM metadata; refusing ownership inference."
    }
    return $state.Metadata
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
    $state = Read-CapProcessMetadataState -Pid $Identity.Pid
    if ($state.State -ne 'Complete') {
        # A missing or incomplete reading is governed by the retained kernel handle,
        # never treated as proof of death on its own. If the owned generation has
        # exited, report it exited; if it is still live, an incomplete/absent row
        # is a refusal, not a silent pass.
        if ([CapNative]::IsExited($Identity.Process.Handle, $Identity.Pid)) { return [pscustomobject]@{ State = 'Exited'; Snapshot = $snapshot; Metadata = $null } }
        throw "Live PID $($Identity.Pid) has no complete current CIM row; refusing."
    }
    $metadata = $state.Metadata
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
        $exitedDuringAttestation = [CapNative]::IsExited($process.Handle, $process.Id)
        if (-not $exitedDuringAttestation) {
            if (-not $identity.InitialMetadataObserved -or -not $identity.InitialMetadataMatchesExpected) {
                throw "Live $Role PID $($process.Id) lacks a complete expected-parent/session attestation."
            }
            # Consume the verification result: the child can exit during this final
            # assertion, and that exit must also be routed through the shared EOF gate
            # rather than silently accepted.
            $verified = Assert-CapProcessIdentity -Identity $identity
            if ($verified.State -eq 'Exited') { $exitedDuringAttestation = $true }
        }
        if ($exitedDuringAttestation) {
            # The owned generation exited during attestation. Route the final gone
            # decision through the same pure decision seam: a retained kernel exit is
            # accepted as genuinely gone ONLY when both redirected streams have reached
            # bounded EOF, never from a missing or incomplete CIM reading alone. Every
            # attestation-time exit, including one discovered inside the final assertion,
            # passes through this one gate.
            $bothEof = $launchRecord.StdoutTask.Wait(2000) -and $launchRecord.StderrTask.Wait(2000)
            $final = Resolve-CapAttestationDisposition -State 'Absent' -KernelExited $true -BothStreamsEofReached $bothEof
            if ($final -cne 'GoneByKernelExit') {
                throw "Exited $Role PID $($process.Id) did not reach bounded stdout/stderr EOF; cannot attest it genuinely gone."
            }
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

function Assert-CapDataRecord {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][hashtable]$Fields,
        [Parameter(Mandatory)][string]$Label)
    if ($Value -isnot [pscustomobject]) { throw "$Label must be a complete typed object." }
    foreach ($name in $Fields.Keys) {
        $property = $Value.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value -or
            -not $Fields[$name].IsInstanceOfType($property.Value) -or
            ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value))) {
            throw "$Label requires a non-null $($Fields[$name].Name) field '$name'."
        }
    }
}

function Assert-CapSceneContract {
    param([Parameter(Mandatory)]$Job)
    if ($Job.lane -cne 'B' -or $Job.sceneAdapter -cne 'B_FIVE_SCENES_V1') {
        throw 'Unsupported scene adapter; generic identity does not implement C/D/E scene execution.'
    }
    Assert-CapDataRecord $Job @{ authority = [pscustomobject]; captureContract = [pscustomobject]
        scenes = [array]; fixture = [pscustomobject] } 'B scene job'
    Assert-CapDataRecord $Job.authority @{ centralCaptureLeaseGrantedByThisArtifact = [bool]
        bWorkerMayLaunchGui = [bool] } 'Job non-authority'
    Assert-CapDataRecord $Job.captureContract @{ phases = [array]; sceneCountPerPhase = [long]
        windowOuterXYWH = [array]; expectedClientWH = [array]; dpi = [long]; canvasZoomPercent = [long] } 'B geometry'
    Assert-CapDataRecord $Job.fixture @{ sha256 = [string]; mappingSha256 = [string]
        originalRoot = [string]; offlinePeerReference = [pscustomobject] } 'B fixture'
    Assert-CapDataRecord $Job.fixture.offlinePeerReference @{ sha256 = [string] } 'Offline peer'
    Assert-CapDataRecord $Job.binaries.offlineZmx @{ sha256 = [string]; seedArgumentOrder = [array] } 'Offline seed'
    if ($Job.authority.centralCaptureLeaseGrantedByThisArtifact -or $Job.authority.bWorkerMayLaunchGui -or
        ($Job.captureContract.phases -join ',') -cne 'before,after' -or
        $Job.captureContract.sceneCountPerPhase -ne 5 -or
        ($Job.captureContract.windowOuterXYWH -join ',') -cne '30,30,1456,959' -or
        ($Job.captureContract.expectedClientWH -join ',') -cne '1440,900' -or
        $Job.captureContract.dpi -ne 96 -or $Job.captureContract.canvasZoomPercent -ne 100 -or
        $Job.scenes.Count -ne 5 -or
        (($Job.scenes | ForEach-Object name) -join ',') -cne 'project-alpha,project-beta,overview,workspace,actions') {
        throw 'B scene, geometry, zoom or non-authority contract differs from the implemented adapter.'
    }
    $seed = @('run', 'graphcode-11111111-1111-4111-8111-000000000001', '-d',
        'cmd.exe', '/Q', '/K', 'echo Offline card fixture - no backend')
    if (($Job.binaries.offlineZmx.seedArgumentOrder -join [char]0) -cne ($seed -join [char]0)) {
        throw 'B scene adapter requires the exact offline cmd-only seed vector.'
    }
    foreach ($digest in @($Job.fixture.sha256, $Job.fixture.mappingSha256,
        $Job.fixture.offlinePeerReference.sha256, $Job.binaries.offlineZmx.sha256)) {
        if ($digest -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Scene input SHA256 digest is missing or invalid.' }
    }
}

function Read-CapBoundJson {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Reference)
    Assert-CapDataRecord $Reference @{ path = [string]; sha256 = [string] } 'Artifact reference'
    $path = Assert-CapArtifactPath -Root $Root -Path $Reference.path
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($Reference.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ne $Reference.sha256) {
        throw "Bound artifact hash mismatch: $path"
    }
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    $document = [Text.Json.JsonDocument]::Parse($json)
    try {
        $visit = {
            param([Text.Json.JsonElement]$Element)
            if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $Element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw "Duplicate JSON field in bound artifact: $($property.Name)" }
                    & $visit $property.Value
                }
            } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $Element.EnumerateArray()) { & $visit $item }
            }
        }
        & $visit $document.RootElement
    } finally { $document.Dispose() }
    return ConvertFrom-Json -InputObject $json -DateKind String
}

function Invoke-CapAdmissionGit {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git --no-pager --no-optional-locks -c core.quotepath=false -c core.fsmonitor=false -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Source identity Git command failed ($($Arguments -join ' ')): $($output -join [Environment]::NewLine)" }
    return $output
}

function Assert-CapSourceArchive {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)]$Receipt)
    $sourceRoot = Assert-CapArtifactPath -Root $Root -Path $Receipt.sourceRoot
    # This is archive byte validation, not a claim that compilation was observed by this process.
    $treeSpec = if ($Receipt.sourceSubdirectory -ceq '.') { "$Commit`^{tree}" }
        elseif ($Receipt.sourceSubdirectory -ceq 'graphcode-windows') { "${Commit}:graphcode-windows" }
        else { throw 'Fresh source coverage must be the full repository or graphcode-windows, not a narrowed input subset.' }
    $tree = [string](Invoke-CapAdmissionGit $Repository @('rev-parse', '--verify', $treeSpec))
    if ($tree -cne $Receipt.sourceTree) { throw 'Fresh source tree does not match the named Git object.' }
    $entries = @(Invoke-CapAdmissionGit $Repository @('ls-tree', '-r', $tree))
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gitlinks = [Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        if ($entry -notmatch '^(100644|100755|160000) (blob|commit) ([a-f0-9]{40})\t([^\r\n\t"]+)$') {
            throw "Unsupported source archive entry: $entry"
        }
        $mode, $kind, $blob, $relative = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
        if ($mode -eq '160000' -and $kind -eq 'commit') { $gitlinks.Add("$relative=$blob"); continue }
        if ($kind -cne 'blob' -or -not $expected.Add($relative)) { throw 'Invalid or duplicate source archive path.' }
        $file = Assert-CapArtifactPath -Root $Root -Path (Join-Path $sourceRoot $relative.Replace('/', '\'))
        $stream = [IO.File]::OpenRead($file)
        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
        try {
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes("blob $($stream.Length)`0"))
            $buffer = [byte[]]::new(65536)
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $read) }
            $actual = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        } finally { $hash.Dispose(); $stream.Dispose() }
        if ($actual -cne $blob) { throw "Fresh source bytes differ from the named Git object: $relative" }
    }
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File)
    if ($expected.Count -le 0 -or $files.Count -ne $expected.Count) { throw 'Fresh source archive has missing or additional files.' }
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName).Replace('\', '/')
        if (-not $expected.Contains($relative)) { throw "Untracked fresh source input: $relative" }
    }
    return [pscustomobject]@{ tree = $tree; files = $expected.Count; gitlinks = @($gitlinks) }
}

function Assert-CapJobIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)]$Lease, [Parameter(Mandatory)][string]$JobSha256,
        [switch]$OfflineTestData)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    Assert-CapDataRecord $Job @{ lane = [string]; head = [string]; base = [string]
        sourceRepository = [string]; admission = [pscustomobject]; binaries = [pscustomobject] } 'Job identity'
    Assert-CapDataRecord $Job.admission @{ schemaVersion = [long]; reviewedHead = [string]
        reviewAcceptance = [pscustomobject]; equivalence = [pscustomobject]; ci = [pscustomobject] } 'Job admission'
    Assert-CapDataRecord $Lease @{ lane = [string]; head = [string]; base = [string]; jobManifestSha256 = [string]
        reviewedHead = [string]; reviewAcceptanceSha256 = [string]; equivalenceSha256 = [string]
        ciInventorySha256 = [string]; ciRuns = [array]
        beforeBuildReceiptSha256 = [string]; afterBuildReceiptSha256 = [string]
        beforeBinarySha256 = [string]; afterBinarySha256 = [string] } 'Lease identity'
    if ($Job.admission.schemaVersion -ne 1 -or $Job.lane -cnotmatch '^[A-Z]$' -or
        $Lease.lane -cne $Job.lane -or $Lease.head -cne $Job.head -or $Lease.base -cne $Job.base -or
        $Lease.jobManifestSha256 -ne $JobSha256 -or $Lease.reviewedHead -cne $Job.admission.reviewedHead -or
        $Lease.reviewAcceptanceSha256 -ne $Job.admission.reviewAcceptance.sha256 -or
        $Lease.equivalenceSha256 -ne $Job.admission.equivalence.sha256 -or
        $Lease.ciInventorySha256 -ne $Job.admission.ci.sha256) {
        throw 'Lease-bound job identity differs from the separately supplied coordinator lease.'
    }
    $repository = [IO.Path]::GetFullPath($Job.sourceRepository)
    if (-not [IO.Path]::IsPathFullyQualified($Job.sourceRepository) -or
        $Job.sourceRepository -notmatch '^[A-Za-z]:\\' -or $Job.sourceRepository.Substring(2).Contains(':') -or
        $Job.sourceRepository -match '(^|\\)\.\.?($|\\)') { throw 'Source repository must be an explicit safe local path.' }
    $ancestor = $repository
    while ($ancestor) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Source repository has a reparse-point ancestor.'
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    if ([string](Invoke-CapAdmissionGit $repository @('rev-parse', '--show-object-format')) -cne 'sha1') {
        throw 'Unsupported Git source object format.'
    }
    foreach ($commit in @($Job.head, $Job.base, $Job.admission.reviewedHead)) {
        if ($commit -cnotmatch '^[a-f0-9]{40}$' -or
            [string](Invoke-CapAdmissionGit $repository @('rev-parse', '--verify', "$commit`^{commit}")) -cne $commit) {
            throw 'Named source head/base/reviewed head is not an existing exact Git commit.'
        }
        $null = Invoke-CapAdmissionGit $repository @('merge-base', '--is-ancestor', $Job.base, $Job.head)
    }
    if ([string](Invoke-CapAdmissionGit $repository @('rev-parse', 'HEAD')) -cne $Job.head -or
        @(Invoke-CapAdmissionGit $repository @('status', '--porcelain', '--untracked-files=all')).Count -ne 0) {
        throw 'Named source repository is not clean at the exact job head.'
    }
    $review = Read-CapBoundJson $Root $Job.admission.reviewAcceptance
    $equivalence = Read-CapBoundJson $Root $Job.admission.equivalence
    Assert-CapDataRecord $review @{ schemaVersion = [long]; verdict = [string]; evidenceMode = [string]
        reviewedHead = [string]; reviewedBase = [string] } 'Review acceptance'
    Assert-CapDataRecord $equivalence @{ schemaVersion = [long]; reviewedHead = [string]; head = [string]
        reviewedBase = [string]; base = [string]; headDeltaPaths = [array]; baseDeltaPaths = [array] } 'Equivalence proof'
    $reviewMode = if ($OfflineTestData) { 'OFFLINE_TEST_DATA_NOT_REVIEW' } else { 'COORDINATOR_ADMITTED_REVIEW' }
    if ($review.schemaVersion -ne 1 -or $equivalence.schemaVersion -ne 1 -or
        $review.verdict -cne 'ACCEPT' -or $review.evidenceMode -cne $reviewMode -or
        $review.reviewedHead -cne $Job.admission.reviewedHead -or
        $equivalence.reviewedHead -cne $review.reviewedHead -or $equivalence.reviewedBase -cne $review.reviewedBase -or
        $equivalence.head -cne $Job.head -or $equivalence.base -cne $Job.base -or
        $review.reviewedBase -cnotmatch '^[a-f0-9]{40}$') { throw 'Reviewed reference/equivalence identity is not coordinator-bound acceptance.' }
    $null = Invoke-CapAdmissionGit $repository @('rev-parse', '--verify', "$($review.reviewedBase)`^{commit}")
    foreach ($pair in @(
        @($review.reviewedHead, $Job.head, 'headDeltaPaths'),
        @($review.reviewedBase, $Job.base, 'baseDeltaPaths')
    )) {
        $delta = @(Invoke-CapAdmissionGit $repository @('diff', '--name-only', '--no-renames', '--no-ext-diff',
            '--no-textconv', $pair[0], $pair[1], '--'))
        $declared = @($equivalence.($pair[2]))
        if (($delta -join "`0") -cne ($declared -join "`0") -or @($declared | Where-Object { $_ -isnot [string] }).Count) {
            throw 'Equivalence proof does not name the complete exact Git delta.'
        }
        foreach ($path in $delta) {
            # Docs and capture/test harnesses are not product build inputs; every other path is protected.
            $productRoot = $path -match '^(graphcode-windows|graphcode|graphcoded|graphcode-cli|GraphcodeKit|ThirdParty|Tuist)/'
            $nonProduct = -not $productRoot -and ($path -cmatch '\.md$' -or
                $path -cmatch '^(windows-tests/|Tools/[^/]+/Tests/)' -or
                $path -cmatch '^Tools/windows/(UiCaptureDriver\.psm1|Invoke-UiCapture(?:Worker)?\.ps1)$')
            if (-not $nonProduct) { throw "Non-equivalent product/provider/build input diff: $path" }
        }
    }
    $ci = Read-CapBoundJson $Root $Job.admission.ci
    Assert-CapDataRecord $ci @{ schemaVersion = [long]; repository = [string]; head = [string]
        evidenceMode = [string]; observedUtc = [string]; runs = [array] } 'CI inventory'
    Assert-CapDataRecord $Job.admission.ci @{ runs = [array] } 'Job CI identity'
    $ciMode = if ($OfflineTestData) { 'OFFLINE_TEST_DATA_NOT_LIVE_CI' } else { 'COORDINATOR_ADMITTED_GITHUB_API_SNAPSHOT' }
    if ($ci.schemaVersion -ne 1 -or $ci.repository -cne 'scgopi/GraphCode' -or $ci.head -cne $Job.head -or
        $ci.evidenceMode -cne $ciMode -or $ci.runs.Count -le 0 -or
        $ci.runs.Count -ne $Job.admission.ci.runs.Count -or $ci.runs.Count -ne $Lease.ciRuns.Count -or
        (ConvertTo-CapUtcInstant $ci.observedUtc 'CI observedUtc') -gt [DateTime]::UtcNow) {
        throw 'CI inventory identity, mode, observation time or run count differs from the lease-bound job.'
    }
    $runIds = [Collections.Generic.HashSet[long]]::new()
    $contextIds = [Collections.Generic.HashSet[long]]::new()
    $contextCount = 0
    for ($i = 0; $i -lt $ci.runs.Count; $i++) {
        $run = $ci.runs[$i]
        Assert-CapDataRecord $run @{ id = [long]; run_attempt = [long]; head_sha = [string]
            status = [string]; conclusion = [string]; total_count = [long]; jobs = [array] } 'CI run'
        foreach ($identity in @($Job.admission.ci.runs[$i], $Lease.ciRuns[$i])) {
            Assert-CapDataRecord $identity @{ id = [long]; attempt = [long] } 'Bound CI run identity'
            if ($identity.id -ne $run.id -or $identity.attempt -ne $run.run_attempt) { throw 'CI run identity/attempt differs from the lease.' }
        }
        if ($run.id -le 0 -or $run.run_attempt -le 0 -or -not $runIds.Add($run.id) -or
            $run.head_sha -cne $Job.head -or $run.status -cne 'completed' -or $run.conclusion -cne 'success') {
            throw 'CI run is not exact-head completed success with a unique positive identity.'
        }
        if ($run.total_count -le 0 -or $run.total_count -ne $run.jobs.Count) {
            throw 'CI inventory must contain a positive complete context count.'
        }
        foreach ($context in $run.jobs) {
            Assert-CapDataRecord $context @{ id = [long]; run_id = [long]; head_sha = [string]; name = [string]
                status = [string]; conclusion = [string]; configuredSkip = [bool] } 'CI context'
            if ($context.id -le 0 -or -not $contextIds.Add($context.id) -or $context.run_id -ne $run.id -or
                $context.head_sha -cne $Job.head -or $context.status -cne 'completed' -or
                ($context.conclusion -cne 'success' -and
                    -not ($context.conclusion -ceq 'skipped' -and $context.configuredSkip))) {
                throw 'CI context is not exact-head green or an explicitly configured skip.'
            }
            $contextCount++
        }
    }
    $builds = [ordered]@{}
    foreach ($phase in @('before', 'after')) {
        $binary = $Job.binaries.$phase
        Assert-CapDataRecord $binary @{ path = [string]; sha256 = [string]; source = [string]
            binaryBuiltAtSource = [string]; buildReceipt = [pscustomobject] } "$phase binary"
        if ($Lease."${phase}BuildReceiptSha256" -ne $binary.buildReceipt.sha256 -or
            $Lease."${phase}BinarySha256" -ne $binary.sha256) { throw 'Lease-bound build receipt/binary identity differs.' }
        $commit = if ($phase -ceq 'before') { $Job.base } else { $Job.head }
        $receipt = Read-CapBoundJson $Root $binary.buildReceipt
        Assert-CapDataRecord $receipt @{ schemaVersion = [long]; evidenceMode = [string]; sourceCommit = [string]
            sourceTree = [string]; sourceRoot = [string]; sourceSubdirectory = [string]
            binaryBuiltAtSource = [string]; archive = [pscustomobject]; log = [pscustomobject]
            rawReceipt = [pscustomobject]; executablePath = [string]; executableSha256 = [string]
            startedUtc = [string]; finishedUtc = [string]; exitCode = [long]; command = [string]; inputs = [array] } "$phase fresh build receipt"
        $buildMode = if ($OfflineTestData) { 'OFFLINE_TEST_DATA_NOT_PRODUCT_BUILD' } else { 'SEPARATE_FRESH_BUILD' }
        if ($receipt.schemaVersion -ne 1 -or $receipt.evidenceMode -cne $buildMode -or
            $binary.source -cne $commit -or $binary.binaryBuiltAtSource -cne $commit -or
            $receipt.sourceCommit -cne $commit -or $receipt.binaryBuiltAtSource -cne $commit -or
            $receipt.exitCode -ne 0 -or $receipt.executablePath -cne $binary.path -or
            $receipt.executableSha256 -ne $binary.sha256 -or $receipt.inputs.Count -le 0) {
            throw 'Fresh build provenance must name the exact phase source and actual built-at commit.'
        }
        $started = ConvertTo-CapUtcInstant $receipt.startedUtc 'Build startedUtc'
        $finished = ConvertTo-CapUtcInstant $receipt.finishedUtc 'Build finishedUtc'
        if ($finished -lt $started -or $finished -gt [DateTime]::UtcNow) { throw 'Fresh build timestamps are reversed or future-dated.' }
        $binaryPath = Assert-CapArtifactPath -Root $Root -Path $binary.path
        if ($binary.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash -ne $binary.sha256) {
            throw "$phase binary hash mismatch against the separately produced fresh build."
        }
        $artifactPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($reference in @($receipt.archive, $receipt.log) + @($receipt.inputs)) {
            Assert-CapDataRecord $reference @{ path = [string]; sha256 = [string] } 'Build artifact'
            $path = Assert-CapArtifactPath -Root $Root -Path $reference.path
            if (-not $artifactPaths.Add($path)) { throw 'Duplicate fresh build artifact/input path.' }
            if ($reference.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $reference.sha256) {
                throw "Fresh build artifact hash mismatch: $path"
            }
        }
        $raw = Read-CapBoundJson $Root $receipt.rawReceipt
        Assert-CapDataRecord $raw @{ sourceSha = [string]; builtAtSha = [string]; sourceTree = [string]
            sourceExportSha256 = [string]; executableSha256 = [string]; exitCode = [long]
            startedUtc = [string]; finishedUtc = [string]; command = [string] } 'Original build receipt'
        if ($raw.sourceSha -cne $commit -or $raw.builtAtSha -cne $commit -or $raw.sourceTree -cne $receipt.sourceTree -or
            $raw.sourceExportSha256 -ne $receipt.archive.sha256 -or $raw.executableSha256 -ne $binary.sha256 -or
            $raw.exitCode -ne 0 -or $raw.startedUtc -cne $receipt.startedUtc -or
            $raw.finishedUtc -cne $receipt.finishedUtc -or $raw.command -cne $receipt.command) {
            throw 'Original build receipt does not agree with its relocated fresh-build artifacts.'
        }
        $source = Assert-CapSourceArchive -Root $Root -Repository $repository -Commit $commit -Receipt $receipt
        $builds[$phase] = [ordered]@{ source = $binary.source; binaryBuiltAtSource = $binary.binaryBuiltAtSource
            sha256 = $binary.sha256; receiptSha256 = $binary.buildReceipt.sha256
            sourceTree = $source.tree; sourceFiles = $source.files; gitlinks = $source.gitlinks }
    }
    return [pscustomobject]@{
        head = $Job.head; base = $Job.base; lane = $Job.lane; reviewedHead = $Job.admission.reviewedHead
        sourceRepository = $repository; ciInventorySha256 = $Job.admission.ci.sha256
        ciRuns = $ci.runs.Count; ciContexts = $contextCount
        equivalenceSha256 = $Job.admission.equivalence.sha256; builds = [pscustomobject]$builds
        attestation = 'LEASE_BOUND_ARTIFACT_VALIDATION_NOT_OBSERVED_COMPILATION_OR_LIVE_CI'
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

function New-CapJournalFailure {
    param([string]$Class, [string]$Message, [AllowNull()][Exception]$Inner = $null)
    $failure = [IO.IOException]::new("$Class`: $Message", $Inner)
    $failure.Data['CapJournalFailure'] = $Class
    return $failure
}

function Get-CapJournalNativeError {
    param([Exception]$Exception)
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [IO.IOException] -or $current -is [UnauthorizedAccessException]) {
            return '{0:X8}' -f ([long]$current.HResult -band 4294967295L)
        }
    }
    return '{0:X8}' -f ([long]$Exception.HResult -band 4294967295L)
}

function ConvertFrom-CapJournalBytes {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        throw (New-CapJournalFailure 'JournalEncoding' 'Published JSON must be UTF-8 without BOM.')
    }
    try { $json = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw (New-CapJournalFailure 'JournalEncoding' $_.Exception.Message $_.Exception) }
    try {
        $document = [Text.Json.JsonDocument]::Parse($json)
        try {
            $visit = {
                param([Text.Json.JsonElement]$Element)
                if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $Element.EnumerateObject()) {
                        if (-not $names.Add($property.Name)) { throw "Duplicate JSON field: $($property.Name)" }
                        & $visit $property.Value
                    }
                } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                    foreach ($item in $Element.EnumerateArray()) { & $visit $item }
                }
            }
            & $visit $document.RootElement
        } finally { $document.Dispose() }
        return ConvertFrom-Json -InputObject $json -DateKind String -Depth 60
    } catch { throw (New-CapJournalFailure 'JournalParse' $_.Exception.Message $_.Exception) }
}

function New-CapJournalBinding {
    [CmdletBinding()]
    param([string]$RunId, [string]$LeaseId, [string]$JobSha256, [string]$ModuleSha256,
        [string]$WorkerSha256, [string]$SupervisorSha256, [Parameter(Mandatory)]$Identity)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $null = [guid]::Parse($RunId)
    $null = [guid]::Parse($LeaseId)
    foreach ($hash in @($JobSha256, $ModuleSha256, $WorkerSha256, $SupervisorSha256)) {
        if ($hash -cnotmatch '\A[A-F0-9]{64}\z') { throw 'Journal binding requires exact source digests.' }
    }
    return [pscustomobject][ordered]@{
        runId = $RunId; leaseId = $LeaseId; jobSha256 = $JobSha256
        moduleSha256 = $ModuleSha256; workerSha256 = $WorkerSha256
        supervisorSha256 = $SupervisorSha256
        workerPid = [long]$Identity.Pid
        workerCreationFileTimeUtc = [long]$Identity.CreationFileTimeUtc
        workerImagePath = [IO.Path]::GetFullPath($Identity.ExpectedImagePath).ToUpperInvariant()
        workerExecutableSha256 = (Get-FileHash -LiteralPath $Identity.ExpectedImagePath -Algorithm SHA256).Hash
        workerParentPid = [long]$Identity.ParentPid
        workerSessionId = [long]$Identity.SessionId
        workerRole = [string]$Identity.Role
    }
}

function Assert-CapJournalBinding {
    param($Actual, $Expected)
    $fields = @{
        runId = [string]; leaseId = [string]; jobSha256 = [string]; moduleSha256 = [string]
        workerSha256 = [string]; supervisorSha256 = [string]; workerPid = [long]
        workerCreationFileTimeUtc = [long]; workerImagePath = [string]
        workerExecutableSha256 = [string]; workerParentPid = [long]; workerSessionId = [long]
        workerRole = [string]
    }
    try {
        Assert-CapDataRecord $Actual $fields 'Journal binding'
        if (@($Actual.PSObject.Properties).Count -ne $fields.Count) { throw 'Unexpected journal identity field.' }
        $null = [guid]::Parse($Actual.runId)
        $null = [guid]::Parse($Actual.leaseId)
        if ($Actual.workerPid -le 0 -or $Actual.workerCreationFileTimeUtc -le 0 -or
            $Actual.workerParentPid -le 0 -or $Actual.workerSessionId -lt 0 -or
            -not [IO.Path]::IsPathFullyQualified($Actual.workerImagePath)) {
            throw 'Invalid worker generation identity.'
        }
        foreach ($name in @('jobSha256','moduleSha256','workerSha256','supervisorSha256','workerExecutableSha256')) {
            if ($Actual.$name -cnotmatch '\A[A-F0-9]{64}\z') { throw "Invalid identity digest: $name" }
        }
        foreach ($name in $fields.Keys) {
            if ($Actual.$name -cne $Expected.$name) { throw "Journal identity differs: $name" }
        }
    } catch { throw (New-CapJournalFailure 'JournalIdentity' $_.Exception.Message $_.Exception) }
}

function New-CapJournalState {
    [CmdletBinding()]
    param([string]$Root, [string]$Directory, [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc, [string]$ObservationPath = '')
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $directoryPath = Assert-CapArtifactPath -Root $Root -Path $Directory
    if (-not ([IO.File]::GetAttributes($directoryPath) -band [IO.FileAttributes]::Directory)) {
        throw 'Journal requires an existing dedicated directory.'
    }
    if ($ObservationPath) {
        $ObservationPath = Assert-CapArtifactPath -Root $Root -Path $ObservationPath
    }
    Assert-CapJournalBinding $Binding $Binding
    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root); Directory = $directoryPath; Binding = $Binding
        DeadlineUtc = $DeadlineUtc; ObservationPath = $ObservationPath
        HighestObserved = 0L; LastApplied = 0L; Sequence = 0L; PreviousHash = ('0' * 64)
        Published = [Collections.Generic.List[object]]::new()
        Accepted = [Collections.Generic.Dictionary[long,string]]::new()
        Terminal = $null; PublicationFailed = $false; FatalError = $null
    }
}

function Write-CapJournalObservation {
    param($State, [long]$Sequence, [int]$Attempt, [string]$Decision,
        [AllowNull()][string]$NativeError, $Transaction)
    if (-not $State.ObservationPath) { return }
    $record = [ordered]@{
        runId = $State.Binding.runId; readerPid = $PID; sequence = $Sequence; attempt = $Attempt
        utc = [DateTime]::UtcNow.ToString('o')
        monotonicTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        monotonicFrequency = [Diagnostics.Stopwatch]::Frequency
        nativeHresult = $NativeError; decision = $Decision
        deadlineUtc = $Transaction.DeadlineUtc.ToString('o'); retries = $Transaction.Retries
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        (ConvertTo-Json -InputObject $record -Compress -Depth 8) + "`n")
    try {
        $stream = [IO.File]::Open($State.ObservationPath, [IO.FileMode]::Append,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
    } catch { throw (New-CapJournalFailure 'JournalObservationFailure' $_.Exception.Message $_.Exception) }
}

function Write-CapImmutableJson {
    [CmdletBinding()]
    param([string]$Root, [string]$Path, [Parameter(Mandatory)]$Value,
        [string]$TemporaryName = ('.cap-final-' + [guid]::NewGuid().ToString('N') + '.tmp'))
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $path = Assert-CapArtifactPath -Root $Root -Path $Path
    if ($TemporaryName -cnotmatch '\A(?:\.cap-journal-[0-9]{6}-[0-9a-f]{32}|\.cap-final-[0-9a-f]{32})\.tmp\z') {
        throw (New-CapJournalFailure 'JournalNamespace' 'Invalid unpublished staging name.')
    }
    $temporary = Join-Path (Split-Path -Parent $path) $TemporaryName
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
        (ConvertTo-Json -InputObject $Value -Depth 60 -Compress))
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $path)
    } catch {
        $native = Get-CapJournalNativeError $_.Exception
        $class = if ($native -in @('80070050', '800700B7')) { 'SequenceConflict' } else { 'JournalPublicationFailure' }
        throw (New-CapJournalFailure $class "$path HRESULT=$native; staging artifact retained. $($_.Exception.Message)" $_.Exception)
    }
    return [pscustomobject]@{
        name = [IO.Path]::GetFileName($path); length = [long]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }
}

function Publish-CapJournalSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State,
        [ValidateSet('Bootstrap','Progress','Terminal')][string]$Kind,
        [Parameter(Mandatory)]$Value)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($State.PublicationFailed -or $null -ne $State.Terminal) {
        throw (New-CapJournalFailure 'JournalPublicationClosed' 'No publication after failure or Terminal.')
    }
    if ([DateTime]::UtcNow -ge $State.DeadlineUtc) {
        throw (New-CapJournalFailure 'JournalExpired' 'Publication deadline reached.')
    }
    $sequence = [long]($State.Sequence + 1)
    if ($sequence -gt 999999) { throw (New-CapJournalFailure 'SequenceConflict' 'Sequence overflow.') }
    $payload = [pscustomobject][ordered]@{
        binding = $State.Binding; sequence = $sequence; previousSequence = [long]$State.Sequence
        previousSha256 = $State.PreviousHash; kind = $Kind; data = $Value
    }
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
        (ConvertTo-Json -InputObject $payload -Depth 55 -Compress))
    $envelope = [ordered]@{
        schemaVersion = 2L; sequence = $sequence; payloadLength = [long]$bytes.Length
        payloadSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        payloadBase64 = [Convert]::ToBase64String($bytes)
    }
    $name = $sequence.ToString('D6', [Globalization.CultureInfo]::InvariantCulture) + '.json'
    try {
        $reference = Write-CapImmutableJson -Root $State.Root -Path (Join-Path $State.Directory $name) `
            -Value $envelope -TemporaryName ('.cap-journal-' + $sequence.ToString('D6') + '-' +
                [guid]::NewGuid().ToString('N') + '.tmp')
    } catch { $State.PublicationFailed = $true; throw }
    $reference | Add-Member -NotePropertyName sequence -NotePropertyValue $sequence
    $State.Sequence = $sequence
    $State.PreviousHash = $reference.sha256
    $State.Published.Add($reference)
    if ($Kind -ceq 'Terminal') { $State.Terminal = $reference }
    return $reference
}

function Get-CapJournalNames {
    param($State, [switch]$Final)
    $numbers = [Collections.Generic.Dictionary[long,string]]::new()
    try { $paths = @([IO.Directory]::EnumerateFileSystemEntries($State.Directory)) }
    catch { throw (New-CapJournalFailure 'JournalNamespace' $_.Exception.Message $_.Exception) }
    foreach ($path in $paths) {
        $name = [IO.Path]::GetFileName($path)
        if ($name -cmatch '\A(?:\.cap-journal-[0-9]{6}-[0-9a-f]{32}|\.cap-final-[0-9a-f]{32})\.tmp\z') {
            if ($Final) { throw (New-CapJournalFailure 'ResidualJournalArtifact' $path) }
            continue
        }
        try { $attributes = [IO.File]::GetAttributes($path) }
        catch {
            $class = if ((Get-CapJournalNativeError $_.Exception) -eq '80070005') { 'JournalAccessDenied' } else { 'JournalNamespace' }
            throw (New-CapJournalFailure $class $_.Exception.Message $_.Exception)
        }
        if ($name -cnotmatch '\A[0-9]{6}\.json\z' -or
            ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint))) {
            throw (New-CapJournalFailure 'JournalNamespace' "Noncanonical publication: $name")
        }
        $number = [long]::Parse($name.Substring(0, 6), [Globalization.CultureInfo]::InvariantCulture)
        if ($number -lt 1 -or -not $numbers.TryAdd($number, $name)) {
            throw (New-CapJournalFailure 'SequenceConflict' "Invalid or duplicate publication: $name")
        }
    }
    return ,$numbers
}

function New-CapJournalTransaction {
    param($State)
    $remaining = [Math]::Min(1000.0, ($State.DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
    return [pscustomobject]@{
        DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $remaining))
        Clock = [Diagnostics.Stopwatch]::StartNew()
        BudgetMilliseconds = [Math]::Max(0, $remaining)
        Retries = 0
        Attempts = [Collections.Generic.Dictionary[long,int]]::new()
    }
}

function Assert-CapJournalTime {
    param($Transaction, [long]$Sequence, [AllowNull()][string]$NativeError = $null)
    if ([DateTime]::UtcNow -ge $Transaction.DeadlineUtc -or
        $Transaction.Clock.Elapsed.TotalMilliseconds -ge $Transaction.BudgetMilliseconds) {
        throw (New-CapJournalFailure 'JournalUnavailable' (
            "sequence=$Sequence HRESULT=$NativeError retries=$($Transaction.Retries); deadline/exhaustion, no late success."))
    }
}

function Read-CapJournalObject {
    param($State, [long]$Sequence, $Transaction, [switch]$Advance, [switch]$RetainStream)
    $native = $null
    while ($true) {
        Assert-CapJournalTime $Transaction $Sequence $native
        if (-not $Transaction.Attempts.ContainsKey($Sequence)) { $Transaction.Attempts[$Sequence] = 0 }
        if ($Transaction.Attempts[$Sequence] -ge 8) {
            throw (New-CapJournalFailure 'JournalUnavailable' "sequence=$Sequence HRESULT=$native; eight Open attempts.")
        }
        $Transaction.Attempts[$Sequence]++
        $attempt = $Transaction.Attempts[$Sequence]
        $name = $Sequence.ToString('D6', [Globalization.CultureInfo]::InvariantCulture) + '.json'
        $retained = $false
        try {
            $stream = [IO.File]::Open((Join-Path $State.Directory $name), [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::Read)
        } catch {
            $native = Get-CapJournalNativeError $_.Exception
            Write-CapJournalObservation $State $Sequence $attempt 'OpenFailed' $native $Transaction
            if ($native -notin @('80070002','80070003','80070020','80070021')) {
                $class = if ($native -eq '80070005') { 'JournalAccessDenied' } else { 'JournalOpenFailure' }
                throw (New-CapJournalFailure $class "sequence=$Sequence HRESULT=$native" $_.Exception)
            }
            if ($Transaction.Retries -ge 7) {
                throw (New-CapJournalFailure 'JournalUnavailable' "sequence=$Sequence HRESULT=$native; global retry limit.")
            }
            $Transaction.Retries++
            Assert-CapJournalTime $Transaction $Sequence $native
            $remaining = [Math]::Min(($Transaction.DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds,
                $Transaction.BudgetMilliseconds - $Transaction.Clock.Elapsed.TotalMilliseconds)
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Floor($remaining))) }
            Assert-CapJournalTime $Transaction $Sequence $native
            if ($Advance) {
                $names = Get-CapJournalNames $State
                foreach ($number in $names.Keys) { $State.HighestObserved = [Math]::Max($State.HighestObserved, $number) }
                $Sequence = [Math]::Max($Sequence, $State.HighestObserved)
            }
            continue
        }
        try {
            $buffer = [IO.MemoryStream]::new()
            try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() }
            finally { $buffer.Dispose() }
            Assert-CapJournalTime $Transaction $Sequence
            $envelope = ConvertFrom-CapJournalBytes $bytes
            try {
                Assert-CapDataRecord $envelope @{ schemaVersion = [long]; sequence = [long]
                    payloadLength = [long]; payloadSha256 = [string]; payloadBase64 = [string] } 'Journal envelope'
                if (@($envelope.PSObject.Properties).Count -ne 5 -or $envelope.schemaVersion -ne 2 -or
                    $envelope.sequence -ne $Sequence) { throw 'Envelope version/name/sequence mismatch.' }
                $payloadBytes = [Convert]::FromBase64String($envelope.payloadBase64)
                if ([Convert]::ToBase64String($payloadBytes) -cne $envelope.payloadBase64) {
                    throw 'Noncanonical payload base64.'
                }
            } catch { throw (New-CapJournalFailure 'JournalSchema' $_.Exception.Message $_.Exception) }
            if ($payloadBytes.Length -ne $envelope.payloadLength -or
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes)) -cne $envelope.payloadSha256) {
                throw (New-CapJournalFailure 'JournalHash' "Payload hash/length differs at $Sequence.")
            }
            $payload = ConvertFrom-CapJournalBytes $payloadBytes
            try {
                Assert-CapDataRecord $payload @{ binding = [pscustomobject]; sequence = [long]
                    previousSequence = [long]; previousSha256 = [string]; kind = [string]; data = [pscustomobject] } 'Journal payload'
                if (@($payload.PSObject.Properties).Count -ne 6 -or
                    $payload.previousSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
                    $payload.kind -cnotin @('Bootstrap','Progress','Terminal')) { throw 'Invalid journal payload schema.' }
                Assert-CapDataRecord $payload.data @{ entries = [array] } 'Journal entries'
            } catch { throw (New-CapJournalFailure 'JournalSchema' $_.Exception.Message $_.Exception) }
            Assert-CapJournalBinding $payload.binding $State.Binding
            if ($payload.sequence -ne $Sequence -or $payload.previousSequence -ne ($Sequence - 1)) {
                throw (New-CapJournalFailure 'SequenceGap' "Predecessor/sequence mismatch at $Sequence.")
            }
            Assert-CapJournalTime $Transaction $Sequence
            $reference = [pscustomobject]@{
                sequence = $Sequence; name = $name; length = [long]$bytes.Length
                sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            }
            Write-CapJournalObservation $State $Sequence $attempt 'ReadVerified' $null $Transaction
            Assert-CapJournalTime $Transaction $Sequence
            $result = [pscustomobject]@{ Reference = $reference; Payload = $payload; Stream = $null }
            if ($RetainStream) { $result.Stream = $stream; $retained = $true }
            return $result
        } finally { if (-not $retained) { $stream.Dispose() } }
    }
}

function Read-CapJournalSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($null -ne $State.FatalError) { throw $State.FatalError }
    try {
        $transaction = New-CapJournalTransaction $State
        Assert-CapJournalTime $transaction $State.HighestObserved
        $names = Get-CapJournalNames $State
        foreach ($number in $names.Keys) { $State.HighestObserved = [Math]::Max($State.HighestObserved, $number) }
        if ($State.HighestObserved -eq 0) {
            return [pscustomobject]@{ State = 'PendingFirstPublication'; Snapshot = $null; HashChainVerified = $false }
        }
        while ($true) {
            $snapshot = Read-CapJournalObject $State $State.HighestObserved $transaction -Advance
            $names = Get-CapJournalNames $State
            foreach ($number in $names.Keys) { $State.HighestObserved = [Math]::Max($State.HighestObserved, $number) }
            if ($snapshot.Reference.sequence -lt $State.HighestObserved) { continue }
            for ($number = 1L; $number -le $snapshot.Reference.sequence; $number++) {
                if (-not $names.ContainsKey($number)) {
                    $null = Read-CapJournalObject $State $number $transaction
                }
            }
            Assert-CapJournalTime $transaction $snapshot.Reference.sequence
            if ($snapshot.Reference.sequence -lt $State.LastApplied) {
                throw (New-CapJournalFailure 'SequenceRegression' 'Cannot apply older journal state.')
            }
            if ($State.Accepted.ContainsKey($snapshot.Reference.sequence) -and
                $State.Accepted[$snapshot.Reference.sequence] -cne $snapshot.Reference.sha256) {
                throw (New-CapJournalFailure 'JournalHash' 'An accepted immutable publication changed.')
            }
            $State.Accepted[$snapshot.Reference.sequence] = $snapshot.Reference.sha256
            $State.LastApplied = $snapshot.Reference.sequence
            Write-CapJournalObservation $State $snapshot.Reference.sequence `
                $transaction.Attempts[$snapshot.Reference.sequence] 'AcceptedLiveSequenceOnly' $null $transaction
            Assert-CapJournalTime $transaction $snapshot.Reference.sequence
            return [pscustomobject]@{ State = 'Published'; Snapshot = $snapshot; HashChainVerified = $false }
        }
    } catch { $State.FatalError = $_.Exception; throw }
}

function Assert-CapJournalReference {
    param($Reference, [switch]$Numbered)
    try {
        Assert-CapDataRecord $Reference @{ name = [string]; length = [long]; sha256 = [string] } 'Journal reference'
        $expectedProperties = if ($Numbered) { 4 } else { 3 }
        if (@($Reference.PSObject.Properties).Count -ne $expectedProperties) { throw 'Unexpected byte reference field.' }
        if ($Reference.length -le 0 -or $Reference.sha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
            [IO.Path]::GetFileName($Reference.name) -cne $Reference.name -or
            $Reference.name.Contains(':')) { throw 'Noncanonical byte reference.' }
        if ($Numbered) {
            Assert-CapDataRecord $Reference @{ sequence = [long] } 'Numbered reference'
            if ($Reference.sequence -lt 1 -or $Reference.sequence -gt 999999 -or
                $Reference.name -cne ($Reference.sequence.ToString('D6') + '.json')) {
                throw 'Numbered reference differs from its sequence.'
            }
        }
    } catch { throw (New-CapJournalFailure 'JournalSchema' $_.Exception.Message $_.Exception) }
}

function Format-CapJournalFinalRecord {
    [CmdletBinding()]
    param($Binding, $Manifest, $Terminal)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    Assert-CapJournalReference $Manifest
    Assert-CapJournalReference $Terminal -Numbered
    $record = [ordered]@{ schemaVersion = 2L; binding = $Binding; manifest = $Manifest; terminal = $Terminal }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        (ConvertTo-Json -InputObject $record -Depth 15 -Compress))
    return 'CAP_JOURNAL_FINAL_V2 ' + [Convert]::ToBase64String($bytes)
}

function Read-CapJournalFinalRecord {
    [CmdletBinding()]
    param([string]$Stdout, $Binding)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $lines = @([regex]::Split($Stdout, '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $records = @($lines | Where-Object { $_.StartsWith('CAP_JOURNAL_FINAL', [StringComparison]::Ordinal) })
    if ($records.Count -ne 1 -or $lines[-1] -cne $records[0] -or
        $records[0] -cnotmatch '\ACAP_JOURNAL_FINAL_V2 ([A-Za-z0-9+/]+={0,2})\z') {
        throw (New-CapJournalFailure 'JournalFinalRecord' 'Missing, duplicate, partial or nonfinal stdout binding.')
    }
    try {
        $encoded = $records[0].Substring('CAP_JOURNAL_FINAL_V2 '.Length)
        $bytes = [Convert]::FromBase64String($encoded)
        if ([Convert]::ToBase64String($bytes) -cne $encoded) { throw 'Noncanonical final base64.' }
        $record = ConvertFrom-CapJournalBytes $bytes
        Assert-CapDataRecord $record @{ schemaVersion = [long]; binding = [pscustomobject]
            manifest = [pscustomobject]; terminal = [pscustomobject] } 'Final binding'
        if ($record.schemaVersion -ne 2 -or @($record.PSObject.Properties).Count -ne 4) { throw 'Final binding schema differs.' }
        Assert-CapJournalBinding $record.binding $Binding
        Assert-CapJournalReference $record.manifest
        Assert-CapJournalReference $record.terminal -Numbered
        if ((Format-CapJournalFinalRecord $Binding $record.manifest $record.terminal) -cne $records[0]) {
            throw 'Final record is not the canonical compact encoding.'
        }
        return $record
    } catch { throw (New-CapJournalFailure 'JournalFinalRecord' $_.Exception.Message $_.Exception) }
}

function Read-CapJournalFinalProof {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [string]$OutputDirectory,
        [Parameter(Mandatory)]$Record, [switch]$RetainStreams)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($null -ne $State.FatalError) { throw $State.FatalError }
    Assert-CapJournalBinding $Record.binding $State.Binding
    Assert-CapJournalReference $Record.terminal -Numbered
    Assert-CapJournalReference $Record.manifest
    if ($State.HighestObserved -gt $Record.terminal.sequence) {
        throw (New-CapJournalFailure 'PostTerminalPublication' 'Observed floor exceeds final binding.')
    }
    $transaction = New-CapJournalTransaction $State
    Assert-CapJournalTime $transaction $Record.terminal.sequence
    $manifestPath = Assert-CapArtifactPath -Root $State.Root -Path (Join-Path $OutputDirectory $Record.manifest.name)
    $stream = $null
    $held = [Collections.Generic.List[IO.Stream]]::new()
    $keepStreams = $false
    try {
        $stream = Open-CapJournalManifestStream $State $manifestPath $transaction $Record.terminal.sequence
        $held.Add($stream)
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
        if ($bytes.Length -ne $Record.manifest.length -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $Record.manifest.sha256) {
            throw (New-CapJournalFailure 'JournalHash' 'Final manifest bytes differ.')
        }
        $manifest = ConvertFrom-CapJournalBytes $bytes
        Assert-CapDataRecord $manifest @{ journal = [pscustomobject]; status = [string]
            ownedProcesses = [array]; ownedProcessSurvivors = [array]
            pendingLaunchesRemaining = [array]; cleanupFailures = [array] } 'Final manifest'
        Assert-CapDataRecord $manifest.journal @{ protocolVersion = [long]; binding = [pscustomobject]
            terminal = [pscustomobject]; published = [array]; directory = [string] } 'Final journal inventory'
        Assert-CapJournalBinding $manifest.journal.binding $State.Binding
        if ($manifest.journal.protocolVersion -ne 2 -or $manifest.status -cnotin @('COMPLETE','FAILED') -or
            $manifest.journal.directory -ine $State.Directory -or
            (ConvertTo-Json $manifest.journal.terminal -Compress) -cne (ConvertTo-Json $Record.terminal -Compress)) {
            throw (New-CapJournalFailure 'JournalFinalBinding' 'Terminal manifest binding differs.')
        }
        Assert-CapJournalTime $transaction $Record.terminal.sequence
        $names = Get-CapJournalNames $State -Final
        $published = @($manifest.journal.published)
        if (@($names.Keys | Where-Object { $_ -gt $Record.terminal.sequence }).Count -ne 0) {
            throw (New-CapJournalFailure 'PostTerminalPublication' 'Publication above exact terminal sequence.')
        }
        if ($published.Count -ne $Record.terminal.sequence -or $names.Count -ne $published.Count) {
            throw (New-CapJournalFailure 'SequenceGap' 'Final inventory has missing or extra publications.')
        }
        $previous = '0' * 64
        $terminal = $null
        for ($index = 0; $index -lt $published.Count; $index++) {
            $reference = $published[$index]
            Assert-CapJournalReference $reference -Numbered
            $number = [long]($index + 1)
            if ($reference.sequence -ne $number -or -not $names.ContainsKey($number)) {
                throw (New-CapJournalFailure 'SequenceGap' 'Final inventory is not exactly contiguous.')
            }
            $object = Read-CapJournalObject $State $number (New-CapJournalTransaction $State) -RetainStream
            $held.Add($object.Stream)
            if ($object.Reference.sha256 -cne $reference.sha256 -or $object.Reference.length -ne $reference.length -or
                $object.Payload.previousSha256 -cne $previous) {
                throw (New-CapJournalFailure 'JournalHash' "Final predecessor chain or bytes differ at $number.")
            }
            if (($number -eq 1 -and $object.Payload.kind -cne 'Bootstrap') -or
                ($number -gt 1 -and $object.Payload.kind -ceq 'Bootstrap')) {
                throw (New-CapJournalFailure 'JournalSchema' 'Bootstrap position differs.')
            }
            if ($number -lt $Record.terminal.sequence -and $object.Payload.kind -ceq 'Terminal') {
                throw (New-CapJournalFailure 'PostTerminalPublication' 'A publication follows an earlier Terminal.')
            }
            $previous = $object.Reference.sha256
            $terminal = $object
        }
        if ($null -eq $terminal -or $terminal.Payload.kind -cne 'Terminal' -or
            $terminal.Reference.sha256 -cne $Record.terminal.sha256 -or
            $terminal.Reference.length -ne $Record.terminal.length) {
            throw (New-CapJournalFailure 'JournalFinalBinding' 'Exact Terminal snapshot missing.')
        }
        $data = $terminal.Payload.data
        Assert-CapDataRecord $data @{ entries = [array]; ownedProcesses = [array]; outcome = [string]
            ownedProcessSurvivors = [array]; pendingLaunchesRemaining = [array]; cleanupFailures = [array] } 'Terminal cleanup'
        if ($data.outcome -cne $manifest.status -or
            (ConvertTo-Json $data.ownedProcesses -Depth 15 -Compress) -cne
                (ConvertTo-Json $manifest.ownedProcesses -Depth 15 -Compress) -or
            (ConvertTo-Json $data.ownedProcessSurvivors -Depth 12 -Compress) -cne
                (ConvertTo-Json $manifest.ownedProcessSurvivors -Depth 12 -Compress) -or
            (ConvertTo-Json $data.pendingLaunchesRemaining -Depth 12 -Compress) -cne
                (ConvertTo-Json $manifest.pendingLaunchesRemaining -Depth 12 -Compress) -or
            (ConvertTo-Json $data.cleanupFailures -Depth 12 -Compress) -cne
                (ConvertTo-Json $manifest.cleanupFailures -Depth 12 -Compress)) {
            throw (New-CapJournalFailure 'JournalFinalBinding' 'Manifest and terminal cleanup differ.')
        }
        $processKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $entryKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($process in $data.ownedProcesses) {
            Assert-CapDataRecord $process @{ pid = [long]; creationFileTimeUtc = [long]; expectedImagePath = [string]
                role = [string]; parentPid = [long]; sessionId = [long]; kernelExited = [bool]
                stdoutEof = [bool]; stderrEof = [bool]; streamOwnerPid = [long]
                streamOwnerCreationFileTimeUtc = [long] } 'Owned process receipt'
            if (-not $process.kernelExited -or -not $process.stdoutEof -or -not $process.stderrEof) {
                throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Kernel exit or owning-stream EOF is unproved.')
            }
            if ($process.pid -le 0 -or $process.creationFileTimeUtc -le 0 -or $process.parentPid -le 0 -or
                $process.sessionId -lt 0 -or $process.streamOwnerPid -le 0 -or
                $process.streamOwnerCreationFileTimeUtc -le 0 -or -not [IO.Path]::IsPathFullyQualified($process.expectedImagePath)) {
                throw (New-CapJournalFailure 'JournalIdentity' 'Invalid cleanup generation identity.')
            }
            if (-not $processKeys.Add("$($process.pid):$($process.creationFileTimeUtc):$($process.role)")) {
                throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Duplicate owned process receipt.')
            }
            $owners = @($data.ownedProcesses | Where-Object {
                $_.pid -eq $process.streamOwnerPid -and
                $_.creationFileTimeUtc -eq $process.streamOwnerCreationFileTimeUtc -and
                $_.streamOwnerPid -eq $_.pid
            })
            if ($owners.Count -ne 1) {
                throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Owning managed-root streams are unbound.')
            }
        }
        foreach ($entry in $data.entries) {
            Assert-CapDataRecord $entry @{ pid = [long]; creationFileTimeUtc = [long]; role = [string]
                expectedImagePath = [string]; expectedParentPid = [long]; expectedSessionId = [long] } 'Registered generation'
            $matches = @($data.ownedProcesses | Where-Object {
                $_.pid -eq $entry.pid -and $_.creationFileTimeUtc -eq $entry.creationFileTimeUtc -and
                $_.role -ceq $entry.role -and $_.expectedImagePath -ieq $entry.expectedImagePath -and
                $_.parentPid -eq $entry.expectedParentPid -and $_.sessionId -eq $entry.expectedSessionId
            })
            if ($matches.Count -ne 1) { throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Registered generation lacks exact cleanup receipt.') }
            $null = $entryKeys.Add("$($entry.pid):$($entry.creationFileTimeUtc):$($entry.role)")
        }
        if (-not $entryKeys.SetEquals($processKeys)) {
            throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Owned and registered generation inventories differ.')
        }
        $namesAfter = Get-CapJournalNames $State -Final
        if ($namesAfter.Count -ne $names.Count -or
            @($namesAfter.Keys | Where-Object { -not $names.ContainsKey($_) }).Count -ne 0) {
            throw (New-CapJournalFailure 'PostTerminalPublication' 'Namespace changed after final inventory.')
        }
        if ([DateTime]::UtcNow -ge $State.DeadlineUtc) {
            throw (New-CapJournalFailure 'JournalUnavailable' 'Final inventory exceeded cleanup hard deadline.')
        }
        $result = [pscustomobject]@{
            Manifest = $manifest; Terminal = $terminal; Record = $Record; Inventory = $published
            HeldStreams = @(); HashChainVerified = $true
        }
        if ($RetainStreams) { $result.HeldStreams = @($held.ToArray()); $keepStreams = $true }
        return $result
    } finally { if (-not $keepStreams) { foreach ($item in $held) { $item.Dispose() } } }
}

function Read-CapNumberedSeedProof {
    [CmdletBinding()]
    param([string]$Root, [Parameter(Mandatory)]$Reference, [string]$JobSha256,
        [string]$ModuleSha256, [string]$WorkerSha256, [DateTime]$DeadlineUtc)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($Reference -isnot [pscustomobject] -or -not $Reference.PSObject.Properties['protocolVersion'] -or
        $Reference.protocolVersion -ne 2) {
        throw (New-CapJournalFailure 'LegacyJournalProtocol' 'Exact numbered terminal proof is required.')
    }
    Assert-CapDataRecord $Reference @{ directory = [string]; outputDirectory = [string]
        binding = [pscustomobject]; record = [pscustomobject] } 'Numbered seed proof'
    if ($Reference.directory.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -or
        $Reference.binding.jobSha256 -cne $JobSha256 -or
        $Reference.binding.moduleSha256 -cne $ModuleSha256 -or
        $Reference.binding.workerSha256 -cne $WorkerSha256) {
        throw (New-CapJournalFailure 'JournalIdentity' 'Seed proof layout or exact source binding differs.')
    }
    $state = New-CapJournalState -Root $Root -Directory $Reference.directory `
        -Binding $Reference.binding -DeadlineUtc $DeadlineUtc
    $proof = Read-CapJournalFinalProof -State $state -OutputDirectory $Reference.outputDirectory -Record $Reference.record
    if ($proof.Manifest.status -cne 'COMPLETE' -or $proof.Terminal.Payload.data.ownedProcessSurvivors.Count -ne 0 -or
        $proof.Terminal.Payload.data.pendingLaunchesRemaining.Count -ne 0 -or
        $proof.Terminal.Payload.data.cleanupFailures.Count -ne 0) {
        throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Seed proof is not a completed clean terminal.')
    }
    return $proof
}

function Open-CapJournalManifestStream {
    param($State, [string]$Path, $Transaction, [long]$Sequence)
    $native = $null
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        Assert-CapJournalTime $Transaction $Sequence $native
        try {
            return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        } catch {
            $native = Get-CapJournalNativeError $_.Exception
            Write-CapJournalObservation $State $Sequence $attempt 'FinalManifestOpenFailed' $native $Transaction
            if ($native -notin @('80070002','80070003','80070020','80070021')) {
                throw (New-CapJournalFailure 'JournalOpenFailure' "Final manifest HRESULT=$native" $_.Exception)
            }
            if ($Transaction.Retries -ge 7) { break }
            $Transaction.Retries++
            Assert-CapJournalTime $Transaction $Sequence $native
            $remaining = [Math]::Min(($Transaction.DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds,
                $Transaction.BudgetMilliseconds - $Transaction.Clock.Elapsed.TotalMilliseconds)
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Floor($remaining))) }
        }
    }
    throw (New-CapJournalFailure 'JournalUnavailable' "Final manifest sequence=$Sequence HRESULT=$native; retry limit.")
}

function Assert-CapNoWorkerTransientArtifacts {
    [CmdletBinding()]
    param([string[]]$Directories)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($Directories.Count -eq 0) { throw 'Worker artifact inventory requires explicit roots.' }
    $files = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    foreach ($directory in $Directories) { $pending.Push($directory) }
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        if ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) {
            throw (New-CapJournalFailure 'JournalNamespace' "Reparse-point inventory root: $directory")
        }
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($path)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw (New-CapJournalFailure 'JournalNamespace' "Reparse-point artifact preserved: $path")
            }
            if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Push($path) }
            else {
                $files.Add($path)
                if ($path.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase) -or
                    $path.EndsWith('.partial', [StringComparison]::OrdinalIgnoreCase) -or
                    $path.EndsWith('.partial.json', [StringComparison]::OrdinalIgnoreCase)) {
                    throw (New-CapJournalFailure 'ResidualJournalArtifact' "$path retained, never deleted.")
                }
            }
        }
    }
    if ($files.Count -eq 0) { throw 'Worker artifact inventory is empty; cannot prove an executed run.' }
    return @($files.ToArray())
}

Export-ModuleMember -Function @(
    'New-CapJournalBinding',
    'New-CapJournalState',
    'Publish-CapJournalSnapshot',
    'Read-CapJournalSnapshot',
    'Write-CapImmutableJson',
    'Format-CapJournalFinalRecord',
    'Read-CapJournalFinalRecord',
    'Read-CapJournalFinalProof',
    'Read-CapNumberedSeedProof',
    'Assert-CapNoWorkerTransientArtifacts',
    'Set-CapTracePath',
    'Write-CapTrace',
    'Get-CapTraceFailures',
    'Assert-CapArtifactPath',
    'Assert-CapFixtureMapping',
    'Read-CapBoundJson',
    'Assert-CapDataRecord',
    'Assert-CapJobIdentity',
    'Assert-CapSceneContract',
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
    'Read-CapProcessMetadataState',
    'Resolve-CapAttestationDisposition',
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
