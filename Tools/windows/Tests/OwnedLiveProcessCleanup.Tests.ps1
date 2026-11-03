[CmdletBinding()]
param([string] $SourceRoot = $PSScriptRoot)

$ErrorActionPreference = "Stop"
$compiledValidationAssembly = $env:GRAPHCODE_VALIDATION_ASSEMBLY
if (-not $compiledValidationAssembly) {
  $compiledValidationAssembly = & (Join-Path $PSScriptRoot "..\Build-CompiledValidationRunner.ps1")
}
$testsRoot = $SourceRoot
$helper = Join-Path $testsRoot "..\OwnedLiveProcess.ps1"
if (Test-Path -LiteralPath $helper -PathType Leaf) {
  . $helper
}

$script:pidStops = [Collections.Generic.List[int]]::new()
$script:removedPaths = [Collections.Generic.List[string]]::new()
$script:mockRemoveFailure = $false
$script:cleanupEvents = [Collections.Generic.List[string]]::new()
$script:scopeCloseCalls = 0
$script:scopeCloseFailure = $false
$processScope = $null
function Stop-Process {
  [CmdletBinding()]
  param([int] $Id, [switch] $Force)
  $script:pidStops.Add($Id)
}
function Remove-Item {
  [CmdletBinding()]
  param([string] $LiteralPath, [switch] $Recurse, [switch] $Force)
  $script:removedPaths.Add($LiteralPath)
  $script:cleanupEvents.Add("remove")
  if ($script:mockRemoveFailure) { throw "mock fixture removal failure" }
}
function Close-ShellProcessScope {
  param($Scope)
  $script:scopeCloseCalls++
  $script:cleanupEvents.Add("close-job")
  if ($script:scopeCloseFailure) { throw "mock job cleanup failure" }
}

function New-MockProcess([int] $id) {
  $process = [Diagnostics.Process]::new()
  $process | Add-Member NoteProperty Id $id -Force
  $process | Add-Member NoteProperty HasExited $false -Force
  $process | Add-Member NoteProperty MockKillCount 0
  $process | Add-Member NoteProperty MockWaitCount 0
  $process | Add-Member NoteProperty MockWaitResult $true
  $process | Add-Member NoteProperty MockDisposed $false
  $process | Add-Member ScriptMethod Kill { $this.MockKillCount++ } -Force
  $process | Add-Member ScriptMethod WaitForExit {
    param([int] $milliseconds)
    $this.MockWaitCount++
    return $this.MockWaitResult
  } -Force
  $process | Add-Member ScriptMethod Dispose { $this.MockDisposed = $true } -Force
  return $process
}

function Get-ParsedSource([string] $name) {
  $path = Join-Path $testsRoot $name
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "$name has parser errors: $errors" }
  return $ast
}

function Get-BlockScript([Management.Automation.Language.StatementBlockAst] $block) {
  $text = $block.Extent.Text
  return [scriptblock]::Create($text.Substring(1, $text.Length - 2))
}

function Get-ScrubbedCleanup {
  $ast = Get-ParsedSource "ScrubbedShellStartup.Live.Tests.ps1"
  $function = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Invoke-Case"
    }, $true)
  if (-not $function) { throw "Scrubbed startup case function not found" }
  $matches = @($function.FindAll({
      param($node)
      $node -is [Management.Automation.Language.TryStatementAst] -and
        $null -ne $node.Finally -and
        $node.Extent.Text -match "onboardingObserved"
    }, $true))
  if ($matches.Count -ne 1) { throw "Expected one scrubbed case cleanup; found $($matches.Count)" }
  return Get-BlockScript $matches[0].Finally
}

function Get-GdiplusCleanup {
  $ast = Get-ParsedSource "GdiplusStartup.Live.Tests.ps1"
  $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.TryStatementAst] -and
        $null -ne $node.Finally -and
        $node.Extent.Text -match "GraphCodeGdiplusStartupTest"
    }, $true))
  if ($matches.Count -ne 1) { throw "Expected one GDI+ runner cleanup; found $($matches.Count)" }
  return Get-BlockScript $matches[0].Finally
}

function Get-GdiplusScratchAdmission {
  $ast = Get-ParsedSource "GdiplusStartup.Live.Tests.ps1"
  $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match 'Test-Path -LiteralPath \$scratch'
    }, $true))
  if ($matches.Count -eq 0) { throw "GDI+ scratch admission was not found" }
  $text = $ast.Extent.Text
  $start = $matches[0].Extent.StartOffset
  $end = $text.IndexOf('New-Item -ItemType Directory -Force -Path', $start, [StringComparison]::Ordinal)
  if ($end -le $start) { throw "GDI+ scratch creation boundary was not found" }
  return [scriptblock]::Create($text.Substring($start, $end - $start))
}

function Get-ScrubbedScratchAdmission {
  $ast = Get-ParsedSource "ScrubbedShellStartup.Live.Tests.ps1"
  $function = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Invoke-Case"
    }, $true)
  $body = $function.Body.EndBlock.Extent.Text
  $start = $body.IndexOf('$root = Join-Path $ScratchRoot $name', [StringComparison]::Ordinal)
  $end = $body.IndexOf('if ($action -in', [StringComparison]::Ordinal)
  if ($start -lt 0 -or $end -le $start) { throw "Scrubbed scratch admission not found" }
  return [scriptblock]::Create($body.Substring($start, $end - $start))
}

function Get-RoundTripScratchAdmission {
  $ast = Get-ParsedSource "DaemonRoundTrip.Live.Tests.ps1"
  $text = $ast.Extent.Text
  $start = $text.IndexOf('if (Test-Path -LiteralPath $runRoot)', [StringComparison]::Ordinal)
  $end = $text.IndexOf('New-Item -ItemType Directory -Force -Path @(', $start, [StringComparison]::Ordinal)
  if ($start -lt 0 -or $end -le $start) { throw "Round-trip scratch admission was not found" }
  return [scriptblock]::Create($text.Substring($start, $end - $start))
}

function Import-SourceFunction([string] $file, [string] $functionName) {
  $ast = Get-ParsedSource $file
  $definitions = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
    }, $true))
  if ($definitions.Count -ne 1) { throw "Expected one source function named $functionName" }
  return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Get-RoundTripFallback {
  $ast = Get-ParsedSource "DaemonRoundTrip.Live.Tests.ps1"
  $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.TryStatementAst] -and
        $node.Body.Extent.Text -match '^\{\s*Stop-OwnedDaemon\s+\$daemonProcess\s*;?\s*\}$' -and
        $node.CatchClauses.Count -eq 1
    }, $true))
  if ($matches.Count -ne 1) { throw "Expected one round-trip cleanup fallback; found $($matches.Count)" }
  return Get-BlockScript $matches[0].CatchClauses[0].Body
}

function Get-RoundTripCleanup {
  $ast = Get-ParsedSource "DaemonRoundTrip.Live.Tests.ps1"
  $matches = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.TryStatementAst] -and
        $null -ne $node.Finally -and
        $node.Extent.Text -match "Round-trip daemon cleanup could not be verified"
    }, $true))
  if ($matches.Count -ne 1) { throw "Expected one round-trip cleanup; found $($matches.Count)" }
  return Get-BlockScript $matches[0].Finally
}

function Remove-ValidationRootEnvironment {
  $environment = [Environment]::GetEnvironmentVariables(
    [EnvironmentVariableTarget]::Process)
  if ($environment.Contains("GRAPHCODE_VALIDATION_ROOT")) {
    Microsoft.PowerShell.Management\Remove-Item `
      -LiteralPath "Env:\GRAPHCODE_VALIDATION_ROOT" -Force -ErrorAction Stop
  }
}

function Invoke-ReceiptFixture([scriptblock] $test) {
  $environment = [Environment]::GetEnvironmentVariables(
    [EnvironmentVariableTarget]::Process)
  $hadRoot = $environment.Contains("GRAPHCODE_VALIDATION_ROOT")
  $previousRoot = if ($hadRoot) { [string]$environment["GRAPHCODE_VALIDATION_ROOT"] } else { $null }
  $root = Join-Path $env:TEMP ("owned-live-retention-" + [guid]::NewGuid().ToString("N"))
  [void][IO.Directory]::CreateDirectory($root)
  try {
    & $test $root
  } finally {
    if ($hadRoot) {
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", $previousRoot, [EnvironmentVariableTarget]::Process)
    } else {
      Remove-ValidationRootEnvironment
    }
    $receipt = Join-Path $root "ownership-unproven.json"
    if ([IO.File]::Exists($receipt)) { [IO.File]::Delete($receipt) }
    $target = Join-Path $root "target"
    $targetReceipt = Join-Path $target "ownership-unproven.json"
    if ([IO.File]::Exists($targetReceipt)) { [IO.File]::Delete($targetReceipt) }
    $nested = Join-Path $target "nested"
    $nestedReceipt = Join-Path $nested "ownership-unproven.json"
    if ([IO.File]::Exists($nestedReceipt)) { [IO.File]::Delete($nestedReceipt) }
    $link = Join-Path $root "link"
    if ([IO.Directory]::Exists($link)) {
      Microsoft.PowerShell.Management\Remove-Item -LiteralPath $link -Force -ErrorAction Stop
    }
    if ([IO.Directory]::Exists($nested)) { [IO.Directory]::Delete($nested) }
    if ([IO.Directory]::Exists($target)) { [IO.Directory]::Delete($target) }
    $rootFile = Join-Path $root "not-directory"
    if ([IO.File]::Exists($rootFile)) { [IO.File]::Delete($rootFile) }
    $failureLog = Join-Path $root "daemon-roundtrip-test-failure.txt"
    if ([IO.File]::Exists($failureLog)) { [IO.File]::Delete($failureLog) }
    [IO.Directory]::Delete($root)
  }
}

function Invoke-CapturingConsole([scriptblock] $test) {
  $previous = [Console]::Out
  $writer = [IO.StringWriter]::new()
  try {
    [Console]::SetOut($writer)
    $value = & $test
  } finally {
    [Console]::SetOut($previous)
  }
  $text = $writer.ToString()
  $writer.Dispose()
  return [pscustomobject]@{ Value = $value; Text = $text }
}

$failures = [Collections.Generic.List[string]]::new()
$executed = 0
function Invoke-Case([string] $name, [scriptblock] $test) {
  $script:pidStops.Clear()
  $script:removedPaths.Clear()
  $script:mockRemoveFailure = $false
  $script:cleanupEvents.Clear()
  $script:scopeCloseCalls = 0
  $script:scopeCloseFailure = $false
  $script:executed++
  $previousOutput = [Console]::Out
  $capturedOutput = [IO.StringWriter]::new()
  try {
    [Console]::SetOut($capturedOutput)
    $null = & $test
    $outcome = "PASS $name"
  } catch {
    $script:failures.Add("${name}: $($_.Exception.Message)")
    $outcome = "FAIL ${name}: $($_.Exception.Message); $($_.ScriptStackTrace)"
  } finally {
    [Console]::SetOut($previousOutput)
    $capturedOutput.Dispose()
  }
  Write-Output $outcome
}

$environment = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
$hadValidationRoot = $environment.Contains("GRAPHCODE_VALIDATION_ROOT")
$originalValidationRoot = if ($hadValidationRoot) {
  [string]$environment["GRAPHCODE_VALIDATION_ROOT"]
} else { $null }
Remove-ValidationRootEnvironment
try {
  Invoke-Case "scrubbed-cleanup-uses-held-processes" {
    $shellProcess = New-MockProcess 91001
    $daemonProcess = New-MockProcess 91002
    $shellStarted = $daemonStarted = $true
    $shellHandleHeld = $daemonHandleHeld = $true
    $root = "C:\mock-scrubbed-case"
    $caseError = $null
    & (Get-ScrubbedCleanup)
    if ($script:pidStops.Count -ne 0 -or
        $shellProcess.MockKillCount -ne 1 -or $daemonProcess.MockKillCount -ne 1 -or
        $shellProcess.MockWaitCount -ne 1 -or $daemonProcess.MockWaitCount -ne 1) {
      throw "expected two held-process kills and waits, zero PID stops; pid=$($script:pidStops.Count) shell=$($shellProcess.MockKillCount) daemon=$($daemonProcess.MockKillCount)"
    }
  }

  Invoke-Case "gdiplus-cleanup-uses-held-process" {
    $process = New-MockProcess 91003
    $started = $true
    $handleHeld = $true
    $scratch = "C:\mock-gdiplus-case"
    $caseError = $null
    & (Get-GdiplusCleanup)
    if ($script:pidStops.Count -ne 0 -or
        $process.MockKillCount -ne 1 -or $process.MockWaitCount -ne 1) {
      throw "expected a held-process kill and wait, zero PID stops; pid=$($script:pidStops.Count) kills=$($process.MockKillCount)"
    }
  }

  Invoke-Case "roundtrip-fallback-uses-held-process" {
    $daemonProcess = New-MockProcess 91004
    try {
      throw [TimeoutException]::new("mock graceful shutdown timed out")
    } catch {
      & (Get-RoundTripFallback)
    }
    if ($script:pidStops.Count -ne 0 -or
        $daemonProcess.MockKillCount -ne 1 -or $daemonProcess.MockWaitCount -ne 1) {
      throw "expected a held-process kill and wait, zero PID stops; pid=$($script:pidStops.Count) kills=$($daemonProcess.MockKillCount)"
    }
  }

  Invoke-Case "scrubbed-unstarted-shell-does-not-block-daemon-cleanup" {
    $shellProcess = [Diagnostics.Process]::new()
    $shellProcess | Add-Member NoteProperty MockDisposed $false
    $shellProcess | Add-Member ScriptMethod Dispose { $this.MockDisposed = $true } -Force
    $daemonProcess = New-MockProcess 91006
    $shellStarted = $false
    $shellHandleHeld = $false
    $daemonStarted = $true
    $daemonHandleHeld = $true
    $root = "C:\mock-scrubbed-case"
    $caseError = [InvalidOperationException]::new("shell did not start")
    try {
      & (Get-ScrubbedCleanup)
    } catch {
      throw "unstarted shell blocked daemon cleanup: $($_.Exception.Message)"
    }
    if (($daemonProcess.MockKillCount + $script:pidStops.Count) -ne 1 -or
        $daemonProcess.MockWaitCount -ne 1) {
      throw "expected the launched daemon to be stopped and waited after shell start failed; pidStops=$($script:pidStops.Count) kills=$($daemonProcess.MockKillCount) waits=$($daemonProcess.MockWaitCount)"
    }
  }

  Invoke-Case "gdiplus-unverified-exit-retains-fixture" {
    $process = New-MockProcess 91007
    $process.MockWaitResult = $false
    $started = $true
    $handleHeld = $true
    $scratch = "C:\mock-gdiplus-case"
    $caseError = $null
    $failure = $null
    try {
      & (Get-GdiplusCleanup)
    } catch {
      $failure = $_.Exception
    }
    if (-not $failure) {
      throw "cleanup accepted an unverified exit; removed=$($script:removedPaths.Count)"
    }
    if ($script:removedPaths.Count -ne 0 -or
        -not (Test-OwnedLiveProcessRetentionRequired $failure)) {
      throw "unverified exit did not preserve the fixture and tag the failure"
    }
  }

  Invoke-Case "gdiplus-refuses-existing-scratch-without-removing" {
    Invoke-ReceiptFixture {
      param($root)
      $scratch = Join-Path $root "existing-scratch"
      [void][IO.Directory]::CreateDirectory($scratch)
      try {
        $failure = $null
        try { & (Get-GdiplusScratchAdmission) } catch { $failure = $_.Exception }
        if (-not $failure -or $script:removedPaths.Count -ne 0 -or
            -not [IO.Directory]::Exists($scratch)) {
          throw "existing GDI+ scratch was reused or removal was attempted"
        }
      } finally {
        [IO.Directory]::Delete($scratch)
      }
    }
  }

  Invoke-Case "scrubbed-refuses-existing-scratch-without-reusing" {
    Invoke-ReceiptFixture {
      param($root)
      $ScratchRoot = $root
      $name = "existing-case"
      $action = "escape"
      $existing = Join-Path $root $name
      [void][IO.Directory]::CreateDirectory($existing)
      $script:exclusiveCalls = 0
      function New-ValidationFixtureDirectory { $script:exclusiveCalls++ }
      try {
        $failure = $null
        try { & (Get-ScrubbedScratchAdmission) } catch { $failure = $_.Exception }
        if (-not $failure -or $script:exclusiveCalls -ne 0 -or
            -not [IO.Directory]::Exists($existing)) {
          throw "existing scrubbed-case scratch was reused"
        }
      } finally {
        [IO.Directory]::Delete($existing)
      }
    }
  }

  Invoke-Case "gdiplus-refuses-scratch-admission-collision" {
    Invoke-ReceiptFixture {
      param($root)
      $scratch = Join-Path $root "collision"
      function New-ValidationFixtureDirectory {
        param($Path)
        [void][IO.Directory]::CreateDirectory($Path)
        throw "mock concurrent directory creation"
      }
      try {
        $failure = $null
        try { & (Get-GdiplusScratchAdmission) } catch { $failure = $_.Exception }
        if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
            $script:removedPaths.Count -ne 0 -or -not [IO.Directory]::Exists($scratch) -or
            @($failure.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $scratch) {
          throw "GDI+ admission collision was not retained and tagged"
        }
      } finally {
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch) }
      }
    }
  }

  Invoke-Case "scrubbed-refuses-scratch-admission-collision" {
    Invoke-ReceiptFixture {
      param($root)
      $ScratchRoot = $root
      $name = "collision"
      $action = "escape"
      $scratch = Join-Path $root $name
      function New-ValidationFixtureDirectory {
        param($Path)
        [void][IO.Directory]::CreateDirectory($Path)
        throw "mock concurrent directory creation"
      }
      try {
        $failure = $null
        try { & (Get-ScrubbedScratchAdmission) } catch { $failure = $_.Exception }
        if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
            $script:removedPaths.Count -ne 0 -or -not [IO.Directory]::Exists($scratch) -or
            @($failure.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $scratch) {
          throw "scrubbed admission collision was not retained and tagged"
        }
      } finally {
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch) }
      }
    }
  }

  foreach ($collision in @($false, $true)) {
    Invoke-Case "roundtrip-refuses-existing-or-racing-scratch-$collision" {
      Invoke-ReceiptFixture {
        param($root)
        $runRoot = Join-Path $root "roundtrip"
        if (-not $collision) { [void][IO.Directory]::CreateDirectory($runRoot) }
        function New-ValidationFixtureDirectory {
          param($Path)
          [void][IO.Directory]::CreateDirectory($Path)
          throw "mock concurrent directory creation"
        }
        try {
          $failure = $null
          try { & (Get-RoundTripScratchAdmission) } catch { $failure = $_.Exception }
          if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
              $script:removedPaths.Count -ne 0 -or -not [IO.Directory]::Exists($runRoot) -or
              @($failure.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $runRoot) {
            throw "round-trip scratch collision was not retained and tagged"
          }
        } finally {
          if ([IO.Directory]::Exists($runRoot)) { [IO.Directory]::Delete($runRoot) }
        }
      }
    }
  }

  foreach ($kind in @("gdiplus", "scrubbed", "roundtrip")) {
    Invoke-Case "$kind-scratch-uses-exclusive-admission" {
      Invoke-ReceiptFixture {
        param($fixtureRoot)
        $ScratchRoot = $fixtureRoot
        $name = "exclusive-collision"
        $action = "escape"
        $scratch = Join-Path $fixtureRoot $name
        $runRoot = $scratch
        $marker = Join-Path $scratch "foreign.txt"
        $script:exclusiveCalls = 0
        $script:exclusiveError = [ComponentModel.Win32Exception]::new(
          183, "controlled exclusive directory collision")
        function New-ValidationFixtureDirectory {
          param([string] $Path)
          $script:exclusiveCalls++
          if ($Path -cne $scratch) { throw "exclusive creator received the wrong path" }
          [void][IO.Directory]::CreateDirectory($Path)
          [IO.File]::WriteAllText($marker, "foreign content")
          throw $script:exclusiveError
        }
        function New-Item {
          [CmdletBinding()]
          param([string] $ItemType, [string] $Path)
          throw "nonexclusive directory creation was attempted"
        }
        try {
          $failure = $null
          try {
            switch ($kind) {
              "gdiplus" { & (Get-GdiplusScratchAdmission) }
              "scrubbed" { & (Get-ScrubbedScratchAdmission) }
              "roundtrip" { & (Get-RoundTripScratchAdmission) }
            }
          } catch {
            $failure = $_.Exception
          }
          if ($script:exclusiveCalls -ne 1) {
            throw "scratch admission did not call the exclusive creator exactly once"
          }
          if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
              $script:removedPaths.Count -ne 0 -or
              @($failure.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $scratch) {
            throw "exclusive admission failure was not retained and tagged"
          }
          $originalErrors = @($failure.InnerExceptions | Where-Object {
              [object]::ReferenceEquals($_, $script:exclusiveError)
            })
          if ($originalErrors.Count -ne 1 -or
              [IO.File]::ReadAllText($marker) -cne "foreign content") {
            throw "exclusive admission lost its error or changed the foreign fixture"
          }
        } finally {
          if ([IO.File]::Exists($marker)) { [IO.File]::Delete($marker) }
          if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch) }
        }
      }
    }

    Invoke-Case "$kind-scratch-continues-after-exclusive-admission" {
      Invoke-ReceiptFixture {
        param($fixtureRoot)
        $ScratchRoot = $fixtureRoot
        $name = "exclusive-success"
        $action = "escape"
        $scratch = Join-Path $fixtureRoot $name
        $runRoot = $scratch
        $script:exclusiveCalls = 0
        $script:nestedCalls = 0
        function New-ValidationFixtureDirectory {
          param([string] $Path)
          if ($Path -cne $scratch) { throw "exclusive creator received the wrong path" }
          $script:exclusiveCalls++
          return [pscustomobject]@{ Path = $Path }
        }
        function New-Item {
          [CmdletBinding()]
          param([string] $ItemType, [string[]] $Path, [switch] $Force)
          if ($script:exclusiveCalls -ne 1) {
            throw "nested fixture setup began before exclusive admission"
          }
          $script:nestedCalls++
        }
        switch ($kind) {
          "gdiplus" { & (Get-GdiplusScratchAdmission) }
          "scrubbed" { & (Get-ScrubbedScratchAdmission) }
          "roundtrip" { & (Get-RoundTripScratchAdmission) }
        }
        $expectedNestedCalls = if ($kind -eq "scrubbed") { 1 } else { 0 }
        if ($script:exclusiveCalls -ne 1 -or $script:nestedCalls -ne $expectedNestedCalls -or
            $script:removedPaths.Count -ne 0) {
          throw "successful exclusive admission did not continue to fixture setup"
        }
      }
    }

    Invoke-Case "$kind-scratch-preserves-exclusive-creation-error" {
      Invoke-ReceiptFixture {
        param($fixtureRoot)
        $ScratchRoot = $fixtureRoot
        $name = "exclusive-failure"
        $action = "escape"
        $scratch = Join-Path $fixtureRoot $name
        $runRoot = $scratch
        $script:exclusiveCalls = 0
        $script:exclusiveError = [UnauthorizedAccessException]::new(
          "controlled exclusive directory creation failure")
        function New-ValidationFixtureDirectory {
          param([string] $Path)
          if ($Path -cne $scratch) { throw "exclusive creator received the wrong path" }
          $script:exclusiveCalls++
          throw $script:exclusiveError
        }
        function New-Item {
          [CmdletBinding()]
          param([string] $ItemType, [string] $Path)
          throw "nonexclusive directory creation was attempted"
        }
        $failure = $null
        try {
          switch ($kind) {
            "gdiplus" { & (Get-GdiplusScratchAdmission) }
            "scrubbed" { & (Get-ScrubbedScratchAdmission) }
            "roundtrip" { & (Get-RoundTripScratchAdmission) }
          }
        } catch {
          $failure = $_.Exception
        }
        if ($script:exclusiveCalls -ne 1 -or
            -not [object]::ReferenceEquals($failure, $script:exclusiveError) -or
            $script:removedPaths.Count -ne 0 -or (Test-Path -LiteralPath $scratch)) {
          throw "exclusive creation failure was changed or followed by fixture cleanup"
        }
      }
    }
  }

  Invoke-Case "scratch-consumers-import-exclusive-admission-helper" {
    foreach ($file in @(
        "GdiplusStartup.Live.Tests.ps1",
        "ScrubbedShellStartup.Live.Tests.ps1",
        "DaemonRoundTrip.Live.Tests.ps1"
      )) {
      $source = [IO.File]::ReadAllText((Join-Path $testsRoot $file))
      if (-not $source.Contains(
          '. (Join-Path $PSScriptRoot "ValidationFixtureDirectory.ps1")')) {
        throw "$file does not import the exclusive admission helper"
      }
    }
  }

  Invoke-Case "gdiplus-creates-missing-scratch-parent" {
    Invoke-ReceiptFixture {
      param($fixtureRoot)
      $parent = Join-Path $fixtureRoot "parent"
      $scratch = Join-Path $parent "child"
      $script:exclusiveCalls = 0
      function New-ValidationFixtureDirectory {
        param([string] $Path)
        if ($Path -cne $scratch -or -not [IO.Directory]::Exists($parent)) {
          throw "exclusive creation was attempted before the scratch parent existed"
        }
        $script:exclusiveCalls++
        return [pscustomobject]@{ Path = $Path }
      }
      try {
        & (Get-GdiplusScratchAdmission)
        if ($script:exclusiveCalls -ne 1 -or $script:removedPaths.Count -ne 0) {
          throw "GDI+ did not create its parent before exclusive scratch admission"
        }
      } finally {
        if ([IO.Directory]::Exists($parent)) { [IO.Directory]::Delete($parent) }
      }
    }
  }

  Invoke-Case "scrubbed-cli-completes-before-output-read" {
    $script:cliProcess = New-MockProcess 91033
    $script:cliProcess | Add-Member NoteProperty Handle ([IntPtr]1) -Force
    $script:cliProcess | Add-Member NoteProperty ExitCode 0 -Force
    $script:cliProcess | Add-Member ScriptMethod WaitForExit {
      param([int] $milliseconds)
      $this.MockWaitCount++
      $this.HasExited = $true
      return $true
    } -Force
    $script:cliCompleted = $false
    $script:cliInfo = $null
    $jobScope = [pscustomobject]@{ Name = "mock job" }
    $Cli = "C:\mock\graphcode.exe"
    function New-StartInfo([string] $file, [string] $root) {
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.FileName = $file
      $info.UseShellExecute = $false
      return $info
    }
    function Start-ShellOwnedProcess($Scope, $StartInfo) {
      if (-not [object]::ReferenceEquals($Scope, $jobScope)) { throw "wrong CLI scope" }
      $script:cliInfo = $StartInfo
      return $script:cliProcess
    }
    function Complete-ShellOwnedProcess($Scope, $Process) {
      if (-not [object]::ReferenceEquals($Scope, $jobScope) -or
          -not [object]::ReferenceEquals($Process, $script:cliProcess) -or
          -not $Process.HasExited) { throw "CLI completed before its root exited" }
      $script:cliCompleted = $true
    }
    function Read-ShellOwnedOutput($Scope, $Process, [switch] $StandardError) {
      if (-not $script:cliCompleted) { throw "CLI output read preceded completion" }
      if ($StandardError) { return "cli stderr" }
      return "cli stdout"
    }
    . (Import-SourceFunction "ScrubbedShellStartup.Live.Tests.ps1" "Invoke-ScrubbedCli")
    $result = Invoke-ScrubbedCli $jobScope "case" "C:\mock\root" "C:\mock\support" @("projects")
    if (-not $script:cliCompleted -or -not $script:cliProcess.MockDisposed -or
        $script:cliProcess.MockKillCount -ne 0 -or $result.ExitCode -ne 0 -or
        $result.Output -cne "cli stdout" -or $result.Error -cne "cli stderr" -or
        $script:cliInfo.Environment["GRAPHCODE_SUPPORT_DIR"] -cne "C:\mock\support" -or
        @($script:cliInfo.ArgumentList).Count -ne 1 -or
        $script:cliInfo.ArgumentList[0] -cne "projects") {
      throw "scrubbed CLI lost launch arguments, finalization, output or cleanup"
    }
  }

  Invoke-Case "roundtrip-daemon-completes-after-graceful-exit" {
    $daemon = New-MockProcess 91034
    $daemon | Add-Member NoteProperty ExitCode 0 -Force
    $daemon | Add-Member ScriptMethod Refresh { } -Force
    $daemon | Add-Member ScriptMethod WaitForExit {
      param([int] $milliseconds)
      $this.MockWaitCount++
      $this.HasExited = $true
      return $true
    } -Force
    $shutdownEvent = [pscustomobject]@{}
    $shutdownEvent | Add-Member ScriptMethod Set { return $true }
    $processScope = [pscustomobject]@{ Name = "mock job" }
    $script:runLog = [Collections.Generic.List[string]]::new()
    $script:daemonCompleted = $false
    function Complete-ShellOwnedProcess($Scope, $Process) {
      if (-not [object]::ReferenceEquals($Scope, $processScope) -or
          -not $Process.HasExited -or $Process.MockWaitCount -ne 1) {
        throw "daemon completion did not follow graceful root exit"
      }
      $script:daemonCompleted = $true
    }
    function Read-ShellOwnedOutput($Scope, $Process, [switch] $StandardError) {
      if (-not $script:daemonCompleted) { throw "daemon output read preceded completion" }
      if ($StandardError) { return " stderr " }
      return " stdout "
    }
    . (Import-SourceFunction "DaemonRoundTrip.Live.Tests.ps1" "Stop-OwnedDaemon")
    Stop-OwnedDaemon $daemon
    if (-not $script:daemonCompleted -or $daemon.MockKillCount -ne 0 -or
        $script:runLog.Count -ne 3 -or $script:runLog[1] -cne "daemon-stdout=stdout" -or
        $script:runLog[2] -cne "daemon-stderr=stderr") {
      throw "round-trip daemon finalization lost graceful exit or output"
    }
  }

  Invoke-Case "owned-command-retains-scope-arguments-and-output" {
    $jobScope = [pscustomobject]@{ Name = "mock job" }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = "C:\mock\zig.exe"
    $info.UseShellExecute = $false
    [void]$info.ArgumentList.Add("test")
    $script:commandProcess = New-MockProcess 91030
    $script:commandProcess | Add-Member NoteProperty ExitCode 7 -Force
    $script:commandScope = $null
    $script:commandInfo = $null
    function Start-ShellOwnedProcess($Scope, $StartInfo) {
      $script:commandScope = $Scope
      $script:commandInfo = $StartInfo
      return $script:commandProcess
    }
    function Complete-ShellOwnedProcess($Scope, $Process) {
      if (-not [object]::ReferenceEquals($Scope, $jobScope) -or
          -not [object]::ReferenceEquals($Process, $script:commandProcess) -or
          $Process.MockWaitCount -ne 1) {
        throw "completion did not follow the owned root exit"
      }
      $script:commandCompleted = $true
    }
    function Receive-ShellOwnedOutput { throw "buffered command unexpectedly requested a stream chunk" }
    function Read-ShellOwnedOutput($Scope, $Process, [switch] $StandardError) {
      if (-not [object]::ReferenceEquals($Scope, $jobScope) -or
          -not [object]::ReferenceEquals($Process, $script:commandProcess) -or
          -not $script:commandCompleted) {
        throw "output read was not bound to the owned launch"
      }
      if ($StandardError) { return "mock stderr" }
      return "mock stdout"
    }
    $script:commandCompleted = $false
    $result = Invoke-OwnedLiveCommand -Scope $jobScope -StartInfo $info
    if (-not [object]::ReferenceEquals($script:commandScope, $jobScope) -or
        -not [object]::ReferenceEquals($script:commandInfo, $info) -or
        $script:commandProcess.MockWaitCount -ne 1 -or $result.ExitCode -ne 7 -or
        $result.Output -cne "mock stdout" -or $result.Error -cne "mock stderr" -or
        -not $info.RedirectStandardOutput -or -not $info.RedirectStandardError) {
      throw "owned command lost its launch, output, or exit status"
    }
  }

  Invoke-Case "owned-command-streams-before-exit-and-drains-after-completion" {
    $jobScope = [pscustomobject]@{ Name = "mock job" }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $script:commandProcess = New-MockProcess 91036
    $script:commandProcess | Add-Member NoteProperty ExitCode 0 -Force
    $script:commandEvents = [Collections.Generic.List[string]]::new()
    $script:receiveCount = 0
    $script:commandCompleted = $false
    $script:commandProcess | Add-Member ScriptMethod WaitForExit {
      param($milliseconds = $null)
      if ($null -eq $milliseconds) {
        $script:commandEvents.Add("wait:blocking")
        $this.HasExited = $true
        return
      }
      $script:commandEvents.Add("wait:$milliseconds")
      if ($milliseconds -eq 100) {
        $this.HasExited = $true
        return $true
      }
      return $false
    } -Force
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:commandProcess }
    function Complete-ShellOwnedProcess($Scope, $Process) {
      if (-not $Process.HasExited) { throw "completion preceded root exit" }
      $script:commandEvents.Add("complete")
      $script:commandCompleted = $true
    }
    function Receive-ShellOwnedOutput($Scope, $Process, [int] $MaximumCharacters) {
      if (-not [object]::ReferenceEquals($Scope, $jobScope) -or
          -not [object]::ReferenceEquals($Process, $script:commandProcess) -or
          $MaximumCharacters -ne 65536) {
        throw "stream read lost its scope, process or bound"
      }
      $script:receiveCount++
      $script:commandEvents.Add("receive:$script:receiveCount")
      switch ($script:receiveCount) {
        1 { return [pscustomobject]@{ Output = "early stdout"; Error = "early stderr" } }
        2 { return [pscustomobject]@{ Output = ""; Error = "" } }
        3 {
          if (-not $script:commandCompleted) { throw "late drain preceded completion" }
          return [pscustomobject]@{ Output = "late stdout"; Error = "late stderr" }
        }
        4 { return [pscustomobject]@{ Output = ""; Error = "" } }
        default { throw "unexpected extra stream read" }
      }
    }
    function Read-ShellOwnedOutput($Scope, $Process, [switch] $StandardError) {
      if (-not $script:commandCompleted -or $script:receiveCount -ne 4) {
        throw "final output preceded completed stream drainage"
      }
      if ($StandardError) { return "complete stderr" }
      return "complete stdout"
    }
    $previousOutput = [Console]::Out
    $previousError = [Console]::Error
    $output = [IO.StringWriter]::new()
    $error = [IO.StringWriter]::new()
    try {
      [Console]::SetOut($output)
      [Console]::SetError($error)
      $result = Invoke-OwnedLiveCommand -Scope $jobScope -StartInfo $info -StreamOutput
      $outputText = $output.ToString()
      $errorText = $error.ToString()
    } finally {
      [Console]::SetOut($previousOutput)
      [Console]::SetError($previousError)
      $output.Dispose()
      $error.Dispose()
    }
    if ($outputText -cne "early stdoutlate stdout" -or
        $errorText -cne "early stderrlate stderr" -or
        $result.Output -cne "complete stdout" -or $result.Error -cne "complete stderr" -or
        ($script:commandEvents -join ",") -cne
        "receive:1,wait:0,receive:2,wait:100,complete,receive:3,receive:4") {
      throw "streamed output was delayed, duplicated, reordered or incompletely drained"
    }
  }

  Invoke-Case "owned-command-stream-surfaces-pump-failure" {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $script:commandProcess = New-MockProcess 91037
    $script:completionCalls = 0
    $script:finalReads = 0
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:commandProcess }
    function Receive-ShellOwnedOutput { throw "mock incremental output pump failed" }
    function Complete-ShellOwnedProcess { $script:completionCalls++ }
    function Read-ShellOwnedOutput { $script:finalReads++ }
    $failure = $null
    try { Invoke-OwnedLiveCommand -Scope ([pscustomobject]@{}) -StartInfo $info -StreamOutput } catch {
      $failure = $_.Exception
    }
    if (-not $failure -or $failure.Message -notmatch "mock incremental output pump failed" -or
        $script:completionCalls -ne 0 -or $script:finalReads -ne 0) {
      throw "incremental pump failure was hidden or treated as finalized output"
    }
  }

  Invoke-Case "owned-command-stream-preserves-split-surrogate-pairs" {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $script:commandProcess = New-MockProcess 91041
    $script:commandProcess | Add-Member NoteProperty ExitCode 0 -Force
    $script:commandProcess | Add-Member ScriptMethod WaitForExit {
      param([int] $milliseconds)
      if ($milliseconds -eq 100) {
        $this.HasExited = $true
        return $true
      }
      return $false
    } -Force
    $script:receiveCount = 0
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:commandProcess }
    function Complete-ShellOwnedProcess { }
    function Receive-ShellOwnedOutput {
      $script:receiveCount++
      switch ($script:receiveCount) {
        1 { return [pscustomobject]@{ Output = [string][char]0xD83D; Error = [string][char]0xD83D } }
        2 { return [pscustomobject]@{ Output = ""; Error = "" } }
        3 { return [pscustomobject]@{ Output = [string][char]0xDE80; Error = [string][char]0xDE80 } }
        4 { return [pscustomobject]@{ Output = ""; Error = "" } }
        default { throw "unexpected extra stream read" }
      }
    }
    function Read-ShellOwnedOutput { return "complete capture" }
    $previousOutput = [Console]::Out
    $previousError = [Console]::Error
    $outputBytes = [IO.MemoryStream]::new()
    $errorBytes = [IO.MemoryStream]::new()
    $encoding = [Text.UTF8Encoding]::new($false)
    $output = [IO.StreamWriter]::new($outputBytes, $encoding, 1024, $true)
    $error = [IO.StreamWriter]::new($errorBytes, $encoding, 1024, $true)
    try {
      [Console]::SetOut($output)
      [Console]::SetError($error)
      [void](Invoke-OwnedLiveCommand -Scope ([pscustomobject]@{}) -StartInfo $info -StreamOutput)
      $output.Flush()
      $error.Flush()
      $stdout = $encoding.GetString($outputBytes.ToArray())
      $stderr = $encoding.GetString($errorBytes.ToArray())
    } finally {
      [Console]::SetOut($previousOutput)
      [Console]::SetError($previousError)
      $output.Dispose()
      $error.Dispose()
      $outputBytes.Dispose()
      $errorBytes.Dispose()
    }
    $expected = [string][char]0xD83D + [string][char]0xDE80
    if ($stdout -cne $expected -or $stderr -cne $expected) {
      throw "a split UTF-16 surrogate pair was corrupted while forwarding output"
    }
  }

  Invoke-Case "owned-command-stream-flushes-final-unpaired-surrogate" {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $script:commandProcess = New-MockProcess 91042
    $script:commandProcess | Add-Member NoteProperty ExitCode 0 -Force
    $script:commandProcess | Add-Member ScriptMethod WaitForExit {
      param([int] $milliseconds)
      if ($milliseconds -eq 100) {
        $this.HasExited = $true
        return $true
      }
      return $false
    } -Force
    $script:receiveCount = 0
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:commandProcess }
    function Complete-ShellOwnedProcess { }
    function Receive-ShellOwnedOutput {
      $script:receiveCount++
      if ($script:receiveCount -eq 1) {
        return [pscustomobject]@{ Output = [string][char]0xD83D; Error = "" }
      }
      return [pscustomobject]@{ Output = ""; Error = "" }
    }
    function Read-ShellOwnedOutput { return "complete capture" }
    $previousOutput = [Console]::Out
    $outputBytes = [IO.MemoryStream]::new()
    $encoding = [Text.UTF8Encoding]::new($false)
    $output = [IO.StreamWriter]::new($outputBytes, $encoding, 1024, $true)
    try {
      [Console]::SetOut($output)
      [void](Invoke-OwnedLiveCommand -Scope ([pscustomobject]@{}) -StartInfo $info -StreamOutput)
      $output.Flush()
      $stdout = $encoding.GetString($outputBytes.ToArray())
    } finally {
      [Console]::SetOut($previousOutput)
      $output.Dispose()
      $outputBytes.Dispose()
    }
    if ($stdout -cne [string][char]0xFFFD) {
      throw "a final unpaired surrogate was silently discarded"
    }
  }

  Invoke-Case "owned-command-stream-surfaces-final-drain-failure" {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $script:commandProcess = New-MockProcess 91038
    $script:commandProcess | Add-Member ScriptMethod WaitForExit {
      param([int] $milliseconds)
      $this.HasExited = $true
      return $true
    } -Force
    $script:completed = $false
    $script:finalReads = 0
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:commandProcess }
    function Receive-ShellOwnedOutput {
      if ($script:completed) { throw "mock final incremental drain failed" }
      return [pscustomobject]@{ Output = ""; Error = "" }
    }
    function Complete-ShellOwnedProcess { $script:completed = $true }
    function Read-ShellOwnedOutput { $script:finalReads++ }
    $failure = $null
    try { Invoke-OwnedLiveCommand -Scope ([pscustomobject]@{}) -StartInfo $info -StreamOutput } catch {
      $failure = $_.Exception
    }
    if (-not $failure -or $failure.Message -notmatch "mock final incremental drain failed" -or
        -not $script:completed -or $script:finalReads -ne 0) {
      throw "final incremental drain failure was hidden or followed by a full output read"
    }
  }

  foreach ($invalid in @(
      @{ Name = "missing"; Chunk = $null },
      @{ Name = "null-output"; Chunk = [pscustomobject]@{ Output = $null; Error = "" } },
      @{ Name = "nonstring-error"; Chunk = [pscustomobject]@{ Output = ""; Error = 1 } },
      @{ Name = "oversized-output"; Chunk = [pscustomobject]@{ Output = [string]::new([char]"x", 65537); Error = "" } },
      @{ Name = "oversized-error"; Chunk = [pscustomobject]@{ Output = ""; Error = [string]::new([char]"x", 65537) } })) {
    Invoke-Case "owned-stream-rejects-invalid-chunk-$($invalid.Name)" {
      $script:streamChunk = $invalid.Chunk
      $process = New-MockProcess 91039
      $pending = @{ Output = ""; Error = "" }
      function Receive-ShellOwnedOutput { return $script:streamChunk }
      $result = Invoke-CapturingConsole {
        try {
          [void](Write-OwnedLiveOutputChunk -Scope ([pscustomobject]@{}) -Process $process -Pending $pending)
          return $null
        } catch { return $_.Exception }
      }
      if (-not $result.Value -or
          $result.Value.Message -notmatch "invalid or oversized chunk" -or
          $result.Text.Length -ne 0) {
        throw "invalid incremental output was accepted or partially written"
      }
    }
  }

  Invoke-Case "owned-stream-accepts-exact-chunk-limit" {
    $script:streamChunk = [pscustomobject]@{ Output = [string]::new([char]"x", 65536); Error = "" }
    $process = New-MockProcess 91040
    $pending = @{ Output = ""; Error = "" }
    function Receive-ShellOwnedOutput { return $script:streamChunk }
    $result = Invoke-CapturingConsole {
      Write-OwnedLiveOutputChunk -Scope ([pscustomobject]@{}) -Process $process -Pending $pending
    }
    if ($result.Value -ne $true -or $result.Text.Length -ne 65536 -or
        $result.Text -cne $script:streamChunk.Output) {
      throw "a chunk at the exact limit was not forwarded intact"
    }
  }

  Invoke-Case "gdiplus-build-selects-streaming-without-reprinting-final-output" {
    $source = [IO.File]::ReadAllText((Join-Path $testsRoot "GdiplusStartup.Live.Tests.ps1"))
    if ($source -notmatch '\$build\s*=\s*Invoke-OwnedLiveCommand\b[^\r\n]*-StreamOutput' -or
        $source -match '\[Console\]::(?:Out|Error)\.Write\(\$build\.(?:Output|Error)\)') {
      throw "GDI+ build must stream during the owned run without reprinting its final capture"
    }
  }

  Invoke-Case "owned-command-surfaces-output-read-failure" {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $script:commandProcess = New-MockProcess 91031
    $script:commandProcess | Add-Member NoteProperty ExitCode 0 -Force
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:commandProcess }
    function Complete-ShellOwnedProcess($Scope, $Process) { }
    function Read-ShellOwnedOutput { throw "mock unproved output EOF" }
    $failure = $null
    try { Invoke-OwnedLiveCommand -Scope ([pscustomobject]@{}) -StartInfo $info } catch {
      $failure = $_.Exception
    }
    if (-not $failure -or $failure.Message -notmatch "mock unproved output EOF" -or
        $script:commandProcess.MockWaitCount -ne 1) {
      throw "owned command did not surface the output read failure"
    }
  }

  Invoke-Case "owned-command-surfaces-launch-failure" {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    function Start-ShellOwnedProcess { throw "mock refused owned launch" }
    $failure = $null
    try { Invoke-OwnedLiveCommand -Scope ([pscustomobject]@{}) -StartInfo $info } catch {
      $failure = $_.Exception
    }
    if (-not $failure -or $failure.Message -notmatch "mock refused owned launch") {
      throw "owned command did not surface the launch failure"
    }
  }

  Invoke-Case "owned-command-surfaces-completion-failure-before-output" {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $script:commandProcess = New-MockProcess 91032
    $script:commandProcess | Add-Member NoteProperty ExitCode 0 -Force
    $script:commandReads = 0
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:commandProcess }
    function Complete-ShellOwnedProcess { throw "mock unproved descendant cleanup" }
    function Read-ShellOwnedOutput { $script:commandReads++ }
    $failure = $null
    try { Invoke-OwnedLiveCommand -Scope ([pscustomobject]@{}) -StartInfo $info } catch {
      $failure = $_.Exception
    }
    if (-not $failure -or $failure.Message -notmatch "mock unproved descendant cleanup" -or
        $script:commandProcess.MockWaitCount -ne 1 -or $script:commandReads -ne 0) {
      throw "owned command read output after an unproved launch completion"
    }
  }

  foreach ($fileName in @(
      "ScrubbedShellStartup.Live.Tests.ps1",
      "GdiplusStartup.Live.Tests.ps1",
      "DaemonRoundTrip.Live.Tests.ps1")) {
    Invoke-Case "job-owned-live-launches-$fileName" {
      $source = [IO.File]::ReadAllText((Join-Path $testsRoot $fileName))
      if ($source -notmatch 'ShellProcessOwnership\.psm1' -or
          $source -notmatch 'New-ShellProcessScope' -or
          $source -notmatch 'Start-ShellOwnedProcess' -or
          $source -notmatch 'Close-ShellProcessScope') {
        throw "live runner does not use a pre-launch owned job through cleanup"
      }
    }
  }

  Invoke-Case "job-contains-gdiplus-build" {
    $source = [IO.File]::ReadAllText((Join-Path $testsRoot "GdiplusStartup.Live.Tests.ps1"))
    if ($source -match '&\s*\$ZigExecutable\s+build-exe' -or
        $source -notmatch 'Invoke-OwnedLiveCommand') {
      throw "GDI+ build is not launched through the owned job"
    }
  }

  Invoke-Case "job-contains-roundtrip-tests" {
    $source = [IO.File]::ReadAllText((Join-Path $testsRoot "DaemonRoundTrip.Live.Tests.ps1"))
    if ($source -match '&\s*\$ZigExecutable\s+test' -or
        $source -notmatch 'Invoke-OwnedLiveCommand') {
      throw "daemon round-trip Zig tests are not launched through the owned job"
    }
  }

  foreach ($successBoundary in @(
      @{ File = "GdiplusStartup.Live.Tests.ps1"; Cleanup = "GraphCodeGdiplusStartupTest"; Pass = "GDIPLUS_STARTUP_LIVE: PASS" },
      @{ File = "DaemonRoundTrip.Live.Tests.ps1"; Cleanup = "Round-trip daemon cleanup could not be verified"; Pass = "REAL_DAEMON_ROUNDTRIP: PASS" })) {
    Invoke-Case "pass-follows-job-cleanup-$($successBoundary.File)" {
      $ast = Get-ParsedSource $successBoundary.File
      $blocks = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally -and
            $node.Extent.Text.Contains($successBoundary.Cleanup)
        }, $true))
      $passOffset = $ast.Extent.Text.IndexOf($successBoundary.Pass, [StringComparison]::Ordinal)
      if ($blocks.Count -ne 1 -or $passOffset -le $blocks[0].Extent.EndOffset) {
        throw "live PASS was reported before cleanup finished"
      }
    }
  }

  Invoke-Case "scrubbed-closes-job-before-root-removal" {
    $shellProcess = New-MockProcess 91027
    $daemonProcess = New-MockProcess 91028
    $shellStarted = $daemonStarted = $false
    $shellHandleHeld = $daemonHandleHeld = $false
    $processScope = [pscustomobject]@{ Name = "mock job" }
    $root = "C:\mock-scrubbed-case"
    $caseError = $null
    & (Get-ScrubbedCleanup)
    if ($script:scopeCloseCalls -ne 1 -or
        ($script:cleanupEvents -join ",") -cne "close-job,remove") {
      throw "scrubbed fixture was removed before verified job cleanup"
    }
  }

  Invoke-Case "gdiplus-job-close-failure-retains-root" {
    $process = New-MockProcess 91029
    $process.HasExited = $true
    $started = $true
    $handleHeld = $true
    $processScope = [pscustomobject]@{ Name = "mock job" }
    $scratch = "C:\mock-gdiplus-case"
    $caseError = [InvalidOperationException]::new("mock primary failure")
    $script:scopeCloseFailure = $true
    $failure = $null
    try { & (Get-GdiplusCleanup) } catch { $failure = $_.Exception }
    if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
        $script:scopeCloseCalls -ne 1 -or $script:removedPaths.Count -ne 0 -or
        -not [object]::ReferenceEquals($failure.InnerExceptions[0], $caseError)) {
      throw "GDI+ job failure did not preserve the primary error and root"
    }
  }

  Invoke-Case "roundtrip-job-close-failure-retains-root" {
    Invoke-ReceiptFixture {
      param($root)
      $target = Join-Path $root "target"
      [void][IO.Directory]::CreateDirectory($target)
      $daemonProcess = $null
      $processScope = [pscustomobject]@{ Name = "mock job" }
      $shutdownEvent = $null
      $roundtripError = [InvalidOperationException]::new("mock primary failure")
      $successful = $true
      $runRoot = $target
      $evidenceDirectory = $root
      $nonce = "test"
      $runLog = [Collections.Generic.List[string]]::new()
      $script:scopeCloseFailure = $true
      $failure = $null
      try { $null = & (Get-RoundTripCleanup) } catch { $failure = $_.Exception }
      if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
          $script:scopeCloseCalls -ne 1 -or
          @($script:removedPaths | Where-Object { $_ -ceq $runRoot }).Count -ne 0 -or
          -not [object]::ReferenceEquals($failure.InnerExceptions[0], $roundtripError)) {
        throw "round-trip job failure did not preserve the primary error and root"
      }
    }
  }

  Invoke-Case "roundtrip-fallback-waits-for-exit" {
    $daemonProcess = New-MockProcess 91008
    try {
      throw [TimeoutException]::new("mock graceful shutdown timed out")
    } catch {
      & (Get-RoundTripFallback)
    }
    if ($daemonProcess.MockWaitCount -ne 1) {
      throw "forced fallback did not wait for the launched daemon to exit"
    }
  }

  Invoke-Case "roundtrip-startup-failure-stops-launched-daemon" {
    $ast = Get-ParsedSource "DaemonRoundTrip.Live.Tests.ps1"
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq "Start-OwnedDaemon"
      }, $true)
    if (-not $function) { throw "Round-trip daemon startup function not found" }
    $source = $function.Extent.Text
    if ($source -notmatch 'Start-ShellOwnedProcess') {
      throw "Expected an owned daemon launch in the startup function"
    }
    $script:startupMockProcess = New-MockProcess 91009
    $script:startupMockProcess | Add-Member ScriptMethod Start { return $true } -Force
    $script:startupMockProcess | Add-Member ScriptMethod Refresh { } -Force
    $script:startupMockProcess | Add-Member NoteProperty Handle ([IntPtr]1) -Force
    $script:startupMockProcess | Add-Member NoteProperty StandardOutput (
      [IO.StringReader]::new("")) -Force
    $script:startupMockProcess | Add-Member NoteProperty StandardError (
      [IO.StringReader]::new("")) -Force
    $script:shutdownEvent = [pscustomobject]@{}
    $script:shutdownEvent | Add-Member ScriptMethod Reset { return $true }
    $expectedDaemonPath = "C:\mock\graphcoded.exe"
    $supportDirectory = "C:\mock\support"
    $daemonPipe = "\\.\pipe\mock-daemon"
    $shutdownEventName = "mock-shutdown"
    $runRoot = "C:\mock-roundtrip-case"
    $processScope = [pscustomobject]@{ Name = "mock job" }
    function Start-ShellOwnedProcess($Scope, $StartInfo) { return $script:startupMockProcess }
    function Get-OwnedDaemon([int] $processId) { throw "mock process discovery failure" }
    . ([scriptblock]::Create($source))
    $failure = $null
    try {
      Start-OwnedDaemon
    } catch {
      $failure = $_.Exception
    }
    if (-not $failure -or $failure.Message -notmatch "mock process discovery failure") {
      throw "startup did not preserve the discovery failure"
    }
    if ($script:startupMockProcess.MockKillCount -ne 1 -or
        $script:startupMockProcess.MockWaitCount -ne 1 -or
        -not $script:startupMockProcess.MockDisposed) {
      throw "launched daemon was not stopped, waited, and disposed after startup failure"
    }
  }

  Invoke-Case "helper-does-not-kill-exited-process" {
    $process = New-MockProcess 91010
    $process.HasExited = $true
    Stop-OwnedLiveProcess -Process $process -Name "mock"
    if ($process.MockKillCount -ne 0 -or $process.MockWaitCount -ne 0) {
      throw "already-exited process was killed or waited"
    }
  }

  Invoke-Case "helper-surfaces-kill-failure-while-live" {
    $process = New-MockProcess 91011
    $process | Add-Member ScriptMethod Kill {
      $this.MockKillCount++
      throw "mock kill failure"
    } -Force
    $failure = $null
    try { Stop-OwnedLiveProcess -Process $process -Name "mock" } catch { $failure = $_.Exception }
    if (-not $failure -or $failure.Message -notmatch "mock kill failure" -or
        $process.MockKillCount -ne 1 -or $process.MockWaitCount -ne 0) {
      throw "live process kill failure was not preserved"
    }
  }

  Invoke-Case "helper-allows-confirmed-concurrent-exit" {
    $process = New-MockProcess 91012
    $process | Add-Member ScriptMethod Kill {
      $this.MockKillCount++
      $this.HasExited = $true
      throw "mock process exited during kill"
    } -Force
    Stop-OwnedLiveProcess -Process $process -Name "mock"
    if ($process.MockKillCount -ne 1 -or $process.MockWaitCount -ne 1) {
      throw "confirmed concurrent exit was not waited"
    }
  }

  Invoke-Case "helper-rejects-wait-timeout" {
    $process = New-MockProcess 91013
    $process.MockWaitResult = $false
    $failure = $null
    try { Stop-OwnedLiveProcess -Process $process -Name "mock" } catch { $failure = $_.Exception }
    if (-not $failure -or $failure.Message -notmatch "did not exit" -or
        $process.MockKillCount -ne 1 -or $process.MockWaitCount -ne 1) {
      throw "wait timeout was not surfaced"
    }
  }

  Invoke-Case "scrubbed-unattested-shell-leaves-it-alone-and-cleans-daemon" {
    $shellProcess = New-MockProcess 91014
    $daemonProcess = New-MockProcess 91015
    $shellStarted = $daemonStarted = $true
    $shellHandleHeld = $false
    $daemonHandleHeld = $true
    $root = "C:\mock-scrubbed-case"
    $caseError = [InvalidOperationException]::new("mock initial case failure")
    $failure = $null
    try { & (Get-ScrubbedCleanup) } catch { $failure = $_.Exception }
    if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
        $shellProcess.MockKillCount -ne 0 -or $daemonProcess.MockKillCount -ne 1 -or
        $daemonProcess.MockWaitCount -ne 1 -or $script:removedPaths.Count -ne 0) {
      throw "unattested shell was acted on or daemon/retention cleanup was skipped"
    }
    if ($failure.InnerExceptions[0].Message -ne "mock initial case failure") {
      throw "initial case failure was not preserved first"
    }
  }

  Invoke-Case "scrubbed-continues-after-first-cleanup-failure" {
    $shellProcess = New-MockProcess 91016
    $shellProcess | Add-Member ScriptMethod Kill {
      $this.MockKillCount++
      throw "mock shell kill failure"
    } -Force
    $daemonProcess = New-MockProcess 91017
    $shellStarted = $daemonStarted = $true
    $shellHandleHeld = $daemonHandleHeld = $true
    $root = "C:\mock-scrubbed-case"
    $caseError = [InvalidOperationException]::new("mock primary failure")
    $failure = $null
    try { & (Get-ScrubbedCleanup) } catch { $failure = $_.Exception }
    if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
        $daemonProcess.MockKillCount -ne 1 -or $daemonProcess.MockWaitCount -ne 1 -or
        -not $shellProcess.MockDisposed -or -not $daemonProcess.MockDisposed -or
        $script:removedPaths.Count -ne 0) {
      throw "first cleanup failure prevented daemon cleanup or root retention"
    }
    if ($failure.InnerExceptions[0].Message -ne "mock primary failure") {
      throw "primary failure was not preserved first"
    }
  }

  Invoke-Case "scrubbed-tagged-inner-failure-retains-fixture" {
    $shellProcess = New-MockProcess 91020
    $daemonProcess = New-MockProcess 91021
    $shellStarted = $false
    $shellHandleHeld = $false
    $daemonStarted = $true
    $daemonHandleHeld = $true
    $root = "C:\mock-scrubbed-case"
    $caseError = New-OwnedLiveProcessCleanupError `
      -Message "mock CLI ownership failure" -Errors @([InvalidOperationException]::new("mock"))
    $null = & (Get-ScrubbedCleanup)
    if ($daemonProcess.MockKillCount -ne 1 -or $daemonProcess.MockWaitCount -ne 1 -or
        $script:removedPaths.Count -ne 0) {
      throw "tagged CLI failure did not preserve the case root after daemon cleanup"
    }
  }

  Invoke-Case "gdiplus-dispose-failure-preserves-primary" {
    $process = New-MockProcess 91022
    $process | Add-Member ScriptMethod Dispose {
      throw "mock disposal failure"
    } -Force
    $started = $true
    $handleHeld = $true
    $scratch = "C:\mock-gdiplus-case"
    $caseError = [InvalidOperationException]::new("mock primary failure")
    $failure = $null
    try { & (Get-GdiplusCleanup) } catch { $failure = $_.Exception }
    if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
        $failure.InnerExceptions[0].Message -ne "mock primary failure" -or
        $process.MockWaitCount -ne 1 -or $script:removedPaths.Count -ne 0) {
      throw "disposal failure masked the primary error or removed the fixture"
    }
  }

  Invoke-Case "scrubbed-fixture-removal-failure-preserves-primary" {
    $shellProcess = New-MockProcess 91023
    $daemonProcess = New-MockProcess 91024
    $shellStarted = $daemonStarted = $false
    $shellHandleHeld = $daemonHandleHeld = $false
    $root = "C:\mock-scrubbed-case"
    $caseError = [InvalidOperationException]::new("mock primary failure")
    $script:mockRemoveFailure = $true
    $failure = $null
    try { & (Get-ScrubbedCleanup) } catch { $failure = $_.Exception }
    if ($failure -isnot [AggregateException] -or
        -not [object]::ReferenceEquals($failure.InnerExceptions[0], $caseError) -or
        $failure.InnerExceptions.Count -lt 2) {
      throw "fixture removal failure masked the primary scrubbed-case error"
    }
  }

  Invoke-Case "gdiplus-fixture-removal-failure-preserves-primary" {
    $process = New-MockProcess 91025
    $process.HasExited = $true
    $started = $true
    $handleHeld = $true
    $scratch = "C:\mock-gdiplus-case"
    $caseError = [InvalidOperationException]::new("mock primary failure")
    $script:mockRemoveFailure = $true
    $failure = $null
    try { & (Get-GdiplusCleanup) } catch { $failure = $_.Exception }
    if ($failure -isnot [AggregateException] -or
        -not [object]::ReferenceEquals($failure.InnerExceptions[0], $caseError) -or
        $failure.InnerExceptions.Count -lt 2) {
      throw "fixture removal failure masked the primary GDI+ error"
    }
  }

  Invoke-Case "roundtrip-unverified-fallback-tags-failure" {
    $daemonProcess = New-MockProcess 91018
    $daemonProcess.MockWaitResult = $false
    $roundtripError = [InvalidOperationException]::new("mock primary failure")
    $shutdownError = $cleanupError = $retentionError = $null
    $runRoot = "C:\mock-roundtrip-case"
    try {
      throw [TimeoutException]::new("mock shutdown failure")
    } catch {
      . (Get-RoundTripFallback)
    }
    if (-not $retentionError -or
        -not (Test-OwnedLiveProcessRetentionRequired $retentionError) -or
        $daemonProcess.MockWaitCount -ne 1 -or
        $retentionError.InnerExceptions[0].Message -ne "mock primary failure") {
      throw "failed fallback did not retain the primary failure and request root preservation"
    }
  }

  Invoke-Case "roundtrip-initializes-primary-error-in-outer-scope" {
    $ast = Get-ParsedSource "DaemonRoundTrip.Live.Tests.ps1"
    $zig = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq "Invoke-ZigTest"
      }, $true)
    if (-not $zig -or $zig.Extent.Text -match '\$roundtripError\s*=\s*\$null' -or
        $ast.Extent.Text -notmatch '(?s)\$roundtripError\s*=\s*\$null\s*try\s*\{\s*\$processScope\s*=\s*New-ShellProcessScope') {
      throw "round-trip primary error was not initialized in the outer scope"
    }
  }

  Invoke-Case "roundtrip-dispose-failure-preserves-primary-and-retains" {
    Invoke-ReceiptFixture {
      param($root)
      $daemonProcess = New-MockProcess 91019
      $daemonProcess | Add-Member ScriptMethod Dispose {
        throw "mock handle disposal failure"
      } -Force
      function Stop-OwnedDaemon([Diagnostics.Process] $process) { }
      $shutdownEvent = $null
      $roundtripError = [InvalidOperationException]::new("mock primary failure")
      $successful = $false
      $runRoot = Join-Path $root "run"
      $evidenceDirectory = $root
      $nonce = "test"
      $runLog = [Collections.Generic.List[string]]::new()
      $failure = $null
      try { $null = & (Get-RoundTripCleanup) } catch { $failure = $_.Exception }
      if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
          $failure.InnerExceptions[0].Message -ne "mock primary failure" -or
          @($script:removedPaths | Where-Object { $_ -ceq $runRoot }).Count -ne 0) {
        throw "handle disposal failure masked the primary error or failed to retain the run"
      }
    }
  }

  Invoke-Case "roundtrip-report-failure-preserves-retention-tag" {
    Invoke-ReceiptFixture {
      param($root)
      $daemonProcess = $null
      $shutdownEvent = $null
      $roundtripError = New-OwnedLiveProcessCleanupError `
        -Message "mock ownership failure" -Errors @([InvalidOperationException]::new("mock primary"))
      $successful = $false
      $runRoot = Join-Path $root "run"
      $evidenceDirectory = Join-Path $root "missing-evidence"
      $nonce = "test"
      $runLog = [Collections.Generic.List[string]]::new()
      $failure = $null
      try { $null = & (Get-RoundTripCleanup) } catch { $failure = $_.Exception }
      if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
          -not [object]::ReferenceEquals($failure.InnerExceptions[0], $roundtripError) -or
          $failure.InnerExceptions.Count -lt 2) {
        $detail = if ($failure) {
          "type=$($failure.GetType().FullName); tag=$(Test-OwnedLiveProcessRetentionRequired $failure); inner=$($failure.InnerExceptions.Count); first=$($failure.InnerExceptions[0].Message); message=$($failure.Message)"
        } else { "no failure" }
        throw "failure reporting masked the tagged original error: $detail"
      }
    }
  }

  foreach ($reportFailure in @($false, $true)) {
    Invoke-Case "roundtrip-tagged-shutdown-failure-retains-root-$reportFailure" {
      Invoke-ReceiptFixture {
        param($root)
        $runRoot = Join-Path $root "target"
        [void][IO.Directory]::CreateDirectory($runRoot)
        $daemonProcess = New-MockProcess 91035
        $daemonProcess.HasExited = $true
        $processScope = [pscustomobject]@{ Name = "mock job" }
        $shutdownEvent = $null
        $roundtripError = [InvalidOperationException]::new("mock primary failure")
        $taggedShutdown = [InvalidOperationException]::new("mock ownership-unproven shutdown")
        $taggedShutdown.Data["GraphCodeValidationRootRetentionRequired"] = $true
        $taggedShutdown.Data["GraphCodeValidationRetainedRoots"] = [string[]]@($runRoot)
        function Stop-OwnedDaemon([Diagnostics.Process] $process) { throw $taggedShutdown }
        $successful = $false
        $evidenceDirectory = if ($reportFailure) { Join-Path $root "missing-evidence" } else { $root }
        $nonce = "test"
        $runLog = [Collections.Generic.List[string]]::new()
        $failure = $null
        try { $null = & (Get-RoundTripCleanup) } catch { $failure = $_.Exception }
        if (-not $failure -or
            $failure.Data["GraphCodeValidationRootRetentionRequired"] -isnot [bool] -or
            -not $failure.Data["GraphCodeValidationRootRetentionRequired"] -or
            -not [object]::ReferenceEquals($failure.InnerExceptions[0], $roundtripError) -or
            @($failure.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $runRoot -or
            @($script:removedPaths | Where-Object { $_ -ceq $runRoot }).Count -ne 0) {
          throw "tagged shutdown was lost during aggregate failure propagation"
        }
      }
    }
  }

  Invoke-Case "roundtrip-event-dispose-failure-preserves-primary" {
    Invoke-ReceiptFixture {
      param($root)
      $daemonProcess = $null
      $shutdownEvent = [pscustomobject]@{}
      $shutdownEvent | Add-Member ScriptMethod Dispose { throw "mock event disposal failure" }
      $roundtripError = [InvalidOperationException]::new("mock primary failure")
      $successful = $false
      $runRoot = Join-Path $root "run"
      $evidenceDirectory = $root
      $nonce = "test"
      $runLog = [Collections.Generic.List[string]]::new()
      $failure = $null
      try { $null = & (Get-RoundTripCleanup) } catch { $failure = $_.Exception }
      if ($failure -isnot [AggregateException] -or
          -not [object]::ReferenceEquals($failure.InnerExceptions[0], $roundtripError) -or
          $failure.InnerExceptions.Count -lt 2) {
        throw "event disposal failure masked the primary error"
      }
    }
  }

  Invoke-Case "roundtrip-forced-cleanup-preserves-tagged-primary" {
    Invoke-ReceiptFixture {
      param($root)
      $target = Join-Path $root "target"
      [void][IO.Directory]::CreateDirectory($target)
      $daemonProcess = New-MockProcess 91026
      function Stop-OwnedDaemon([Diagnostics.Process] $process) {
        throw "mock graceful shutdown failure"
      }
      $shutdownEvent = $null
      $roundtripError = [InvalidOperationException]::new("mock ownership failure")
      $roundtripError.Data["GraphCodeValidationRootRetentionRequired"] = $true
      $roundtripError.Data["GraphCodeValidationRetainedRoots"] = [string[]]@($target)
      $successful = $false
      $runRoot = $target
      $evidenceDirectory = $root
      $nonce = "test"
      $runLog = [Collections.Generic.List[string]]::new()
      $failure = $null
      try { $null = & (Get-RoundTripCleanup) } catch { $failure = $_.Exception }
      if (-not $failure -or
          $failure.Data["GraphCodeValidationRootRetentionRequired"] -isnot [bool] -or
          -not $failure.Data["GraphCodeValidationRootRetentionRequired"] -or
          -not [object]::ReferenceEquals($failure.InnerExceptions[0], $roundtripError) -or
          @($failure.Data["GraphCodeValidationRetainedRoots"]).Count -ne 1 -or
          $failure.Data["GraphCodeValidationRetainedRoots"][0] -cne $target) {
        throw "forced cleanup failed to propagate the primary retention tag and root list"
      }
    }
  }

  Invoke-Case "roundtrip-report-failure-preserves-retained-roots" {
    Invoke-ReceiptFixture {
      param($root)
      $target = Join-Path $root "target"
      [void][IO.Directory]::CreateDirectory($target)
      $daemonProcess = $null
      $shutdownEvent = $null
      $roundtripError = [InvalidOperationException]::new("mock ownership failure")
      $roundtripError.Data["GraphCodeValidationRootRetentionRequired"] = $true
      $roundtripError.Data["GraphCodeValidationRetainedRoots"] = [string[]]@($target)
      $successful = $false
      $runRoot = $target
      $evidenceDirectory = Join-Path $root "missing-evidence"
      $nonce = "test"
      $runLog = [Collections.Generic.List[string]]::new()
      $failure = $null
      try { $null = & (Get-RoundTripCleanup) } catch { $failure = $_.Exception }
      if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
          @($failure.Data["GraphCodeValidationRetainedRoots"]).Count -ne 1 -or
          $failure.Data["GraphCodeValidationRetainedRoots"][0] -cne $target) {
        throw "failure reporting discarded the observed retained-root list"
      }
    }
  }

  Invoke-Case "retained-root-list-records-observed-only" {
    Invoke-ReceiptFixture {
      param($root)
      $target = Join-Path $root "target"
      $nested = Join-Path $target "nested"
      [void][IO.Directory]::CreateDirectory($nested)
      $inner = [InvalidOperationException]::new("mock inner")
      $inner.Data["GraphCodeValidationRootRetentionRequired"] = $true
      $inner.Data["GraphCodeValidationRetainedRoots"] = [string[]]@($nested)
      $missing = Join-Path $root "missing"
      $error = New-OwnedLiveProcessCleanupError `
        -Message "mock cleanup failure" -Errors @($inner) `
        -RetainedRoots @($target, $missing, $target)
      $observed = @($error.Data["GraphCodeValidationRetainedRoots"])
      if ($observed.Count -ne 2 -or $observed -cnotcontains $target -or
          $observed -cnotcontains $nested -or $observed -ccontains $missing) {
        throw "retained-root list did not preserve distinct observed directories"
      }
    }
  }

  Invoke-Case "absent-receipt-root-emits-sentinel" {
    Invoke-ReceiptFixture {
      param($root)
      Remove-ValidationRootEnvironment
      if ([Environment]::GetEnvironmentVariables("Process").Contains("GRAPHCODE_VALIDATION_ROOT")) {
        throw "test did not establish an absent validation-root variable"
      }
      $result = Invoke-CapturingConsole {
        New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      }
      if ($result.Text.Trim() -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $result.Value) -or
          $result.Value.InnerExceptions.Count -ne 2) {
        throw "absent root did not emit a tagged receipt-failure sentinel"
      }
    }
  }

  Invoke-Case "failed-sentinel-write-preserves-retention-and-errors" {
    Invoke-ReceiptFixture {
      param($root)
      & (Join-Path $PSScriptRoot "..\Import-CompiledValidationAssembly.ps1") `
        -AssemblyPath $compiledValidationAssembly `
        -RequiredType "GraphCode.Validation.TestFixtures.FailingRetentionSentinelWriter" | Out-Null
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", "relative-root", [EnvironmentVariableTarget]::Process)
      $previous = [Console]::Out
      $writer = [GraphCode.Validation.TestFixtures.FailingRetentionSentinelWriter]::new()
      try {
        [Console]::SetOut($writer)
        $error = New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("primary cleanup failure")) `
          -RetainedRoots @($root)
      } finally {
        [Console]::SetOut($previous)
        $writer.Dispose()
      }
      if (-not (Test-OwnedLiveProcessRetentionRequired $error) -or
          $error.InnerExceptions.Count -ne 3 -or
          $error.ToString() -notmatch "primary cleanup failure" -or
          $error.ToString() -notmatch "fully qualified path" -or
          $error.ToString() -notmatch "controlled sentinel write failure" -or
          @($error.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $root) {
        throw "sentinel failure lost the retention tag, observed root, or contributing errors"
      }

      $shellProcess = New-MockProcess 91099
      $daemonProcess = $null
      $shellStarted = $true
      $shellHandleHeld = $false
      $daemonStarted = $daemonHandleHeld = $false
      $processScope = $null
      $caseError = [InvalidOperationException]::new("source cleanup primary")
      $failure = $null
      $writer = [GraphCode.Validation.TestFixtures.FailingRetentionSentinelWriter]::new()
      try {
        [Console]::SetOut($writer)
        try { & (Get-ScrubbedCleanup) } catch { $failure = $_.Exception }
      } finally {
        [Console]::SetOut($previous)
        $writer.Dispose()
      }
      if (-not $failure -or -not (Test-OwnedLiveProcessRetentionRequired $failure) -or
          $failure.ToString() -notmatch "source cleanup primary" -or
          $failure.ToString() -notmatch "controlled sentinel write failure" -or
          @($failure.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $root -or
          $shellProcess.MockKillCount -ne 0 -or $script:removedPaths.Count -ne 0) {
        throw "source cleanup lost the retention tag or acted on an unattested process or fixture"
      }
    }
  }

  Invoke-Case "failed-sentinel-flush-preserves-retention-and-errors" {
    Invoke-ReceiptFixture {
      param($root)
      & (Join-Path $PSScriptRoot "..\Import-CompiledValidationAssembly.ps1") `
        -AssemblyPath $compiledValidationAssembly `
        -RequiredType "GraphCode.Validation.TestFixtures.FailingRetentionSentinelFlush" | Out-Null
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", "relative-root", [EnvironmentVariableTarget]::Process)
      $previous = [Console]::Out
      $writer = [GraphCode.Validation.TestFixtures.FailingRetentionSentinelFlush]::new()
      try {
        [Console]::SetOut($writer)
        $error = New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("primary cleanup failure")) `
          -RetainedRoots @($root)
      } finally {
        [Console]::SetOut($previous)
        $writer.Dispose()
      }
      if (-not (Test-OwnedLiveProcessRetentionRequired $error) -or
          $error.InnerExceptions.Count -ne 3 -or
          $error.ToString() -notmatch "primary cleanup failure" -or
          $error.ToString() -notmatch "fully qualified path" -or
          $error.ToString() -notmatch "controlled sentinel flush failure" -or
          @($error.Data["GraphCodeValidationRetainedRoots"]) -cnotcontains $root) {
        throw "sentinel flush failure lost the retention tag, observed root, or contributing errors"
      }
    }
  }

  Invoke-Case "receipt-preserves-exact-root-and-tag" {
    Invoke-ReceiptFixture {
      param($root)
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", $root, [EnvironmentVariableTarget]::Process)
      $error = New-OwnedLiveProcessCleanupError `
        -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      $path = Join-Path $root "ownership-unproven.json"
      if (-not [IO.File]::Exists($path)) { throw "receipt was not created" }
      $bytes = [IO.File]::ReadAllBytes($path)
      $receipt = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
        ConvertFrom-Json
      if ($bytes.Length -gt 4096 -or $receipt.schemaVersion -ne 1 -or
          $receipt.validationRoot -cne $root -or $receipt.reason -cne "ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $error)) {
        throw "receipt content or Boolean retention tag was incorrect"
      }
    }
  }

  Invoke-Case "existing-receipt-is-not-overwritten" {
    Invoke-ReceiptFixture {
      param($root)
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", $root, [EnvironmentVariableTarget]::Process)
      $path = Join-Path $root "ownership-unproven.json"
      [IO.File]::WriteAllText($path, "preexisting evidence")
      $result = Invoke-CapturingConsole {
        New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      }
      if ([IO.File]::ReadAllText($path) -cne "preexisting evidence" -or
          $result.Text.Trim() -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $result.Value) -or
          $result.Value.InnerExceptions.Count -ne 2) {
        throw "existing receipt was overwritten or its write failure was not surfaced"
      }
    }
  }

  Invoke-Case "invalid-receipt-root-emits-sentinel" {
    Invoke-ReceiptFixture {
      param($root)
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", "relative-root", [EnvironmentVariableTarget]::Process)
      $result = Invoke-CapturingConsole {
        New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      }
      if ($result.Text.Trim() -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $result.Value) -or
          $result.Value.InnerExceptions.Count -ne 2) {
        throw "invalid receipt root did not emit a tagged sentinel failure"
      }
    }
  }

  Invoke-Case "empty-receipt-root-emits-sentinel" {
    Invoke-ReceiptFixture {
      param($root)
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", "", [EnvironmentVariableTarget]::Process)
      $environment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process)
      if (-not $environment.Contains("GRAPHCODE_VALIDATION_ROOT")) {
        throw "test did not establish a present empty validation-root variable"
      }
      $result = Invoke-CapturingConsole {
        New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      }
      if ($result.Text.Trim() -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $result.Value)) {
        throw "present empty root did not emit a tagged sentinel failure"
      }
    }
  }

  Invoke-Case "receipt-root-file-emits-sentinel" {
    Invoke-ReceiptFixture {
      param($root)
      $file = Join-Path $root "not-directory"
      [IO.File]::WriteAllText($file, "existing file")
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", $file, [EnvironmentVariableTarget]::Process)
      $result = Invoke-CapturingConsole {
        New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      }
      if ($result.Text.Trim() -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $result.Value) -or
          [IO.File]::ReadAllText($file) -cne "existing file") {
        throw "a file-valued root was not refused without modification"
      }
    }
  }

  Invoke-Case "reparse-root-emits-sentinel-without-writing-target" {
    Invoke-ReceiptFixture {
      param($root)
      $target = Join-Path $root "target"
      $link = Join-Path $root "link"
      [void][IO.Directory]::CreateDirectory($target)
      [void](New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop)
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", $link, [EnvironmentVariableTarget]::Process)
      $result = Invoke-CapturingConsole {
        New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      }
      if ($result.Text.Trim() -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $result.Value) -or
          [IO.File]::Exists((Join-Path $target "ownership-unproven.json"))) {
        throw "reparse root was not refused without writing through it"
      }
    }
  }

  Invoke-Case "reparse-ancestor-emits-sentinel-without-writing-target" {
    Invoke-ReceiptFixture {
      param($root)
      $target = Join-Path $root "target"
      $nested = Join-Path $target "nested"
      $link = Join-Path $root "link"
      [void][IO.Directory]::CreateDirectory($nested)
      [void](New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop)
      [Environment]::SetEnvironmentVariable(
        "GRAPHCODE_VALIDATION_ROOT", (Join-Path $link "nested"),
        [EnvironmentVariableTarget]::Process)
      $result = Invoke-CapturingConsole {
        New-OwnedLiveProcessCleanupError `
          -Message "mock cleanup failure" -Errors @([InvalidOperationException]::new("mock"))
      }
      if ($result.Text.Trim() -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" -or
          -not (Test-OwnedLiveProcessRetentionRequired $result.Value) -or
          [IO.File]::Exists((Join-Path $nested "ownership-unproven.json"))) {
        throw "reparse ancestor was not refused without writing through it"
      }
    }
  }

  Invoke-Case "receipt-writer-uses-create-new-and-flush" {
    $source = [IO.File]::ReadAllText($helper)
    if ($source -notmatch '\[IO\.FileMode\]::CreateNew' -or
        $source -notmatch '\$stream\.Flush\(\$true\)') {
      throw "receipt writer must create exclusively and flush the file stream"
    }
  }

  Invoke-Case "nested-retention-tag-is-observed" {
    $tagged = [InvalidOperationException]::new("tagged")
    $tagged.Data["GraphCodeValidationRootRetentionRequired"] = $true
    $wrapped = [AggregateException]::new(
      "wrapped", [Exception[]]@([InvalidOperationException]::new("untagged"), $tagged))
    $stringTag = [InvalidOperationException]::new("string tag")
    $stringTag.Data["GraphCodeValidationRootRetentionRequired"] = "true"
    if (-not (Test-OwnedLiveProcessRetentionRequired $wrapped) -or
        (Test-OwnedLiveProcessRetentionRequired ([InvalidOperationException]::new("ordinary"))) -or
        (Test-OwnedLiveProcessRetentionRequired $stringTag)) {
      throw "nested Boolean retention tag was not distinguished from an ordinary error"
    }
  }

  Write-Output "OWNED_LIVE_PROCESS_CLEANUP_CASES=$executed FAILURES=$($failures.Count)"
  if ($executed -ne 84 -or $failures.Count -ne 0) {
    throw "Owned live process cleanup contract failed: $($failures -join '; ')"
  }
} finally {
  if ($hadValidationRoot) {
    [Environment]::SetEnvironmentVariable(
      "GRAPHCODE_VALIDATION_ROOT", $originalValidationRoot, [EnvironmentVariableTarget]::Process)
  } else {
    Remove-ValidationRootEnvironment
  }
}
