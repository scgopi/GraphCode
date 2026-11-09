[CmdletBinding()]
param(
  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [string] $AssemblyPath,
  [switch] $MockOnly
)

$ErrorActionPreference = "Stop"
$ArtifactRoot = Join-Path $ArtifactRoot ("uia-held-" + [guid]::NewGuid().ToString("N"))
if (Test-Path -LiteralPath $ArtifactRoot) { throw "Held-launch contracts require a fresh artifact root" }
$null = New-Item -ItemType Directory -Path $ArtifactRoot
$gate = Join-Path $RepositoryRoot "Tools\windows\uia-live-gate.ps1"
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($gate, [ref]$null, [ref]$errors)
if ($errors.Count) { throw "UIA launch source must parse" }
$definitions = @{}
foreach ($name in @("Start-UiaOwnedProcess", "Complete-UiaHeldCapture", "Register-UiaHeldProcess",
    "Complete-MultiProjectCapture", "Stop-UiaOwnedProcessTrees", "New-UiaOwnershipFailure")) {
  $found = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true))
  if ($found.Count -eq 1) { $definitions[$name] = $found[0].Extent.Text }
}
if (-not $definitions.ContainsKey("Start-UiaOwnedProcess")) { throw "Actual default UIA launch entry is missing" }
. ([scriptblock]::Create($definitions["Start-UiaOwnedProcess"]))
if ($definitions.ContainsKey("Complete-UiaHeldCapture")) {
  . ([scriptblock]::Create($definitions["Complete-UiaHeldCapture"]))
}
foreach ($name in @("Complete-MultiProjectCapture", "Stop-UiaOwnedProcessTrees", "New-UiaOwnershipFailure")) {
  . ([scriptblock]::Create($definitions[$name]))
}
$results = [Collections.Generic.List[object]]::new()
function Assert-Held([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}
function Read-HeldLog([string] $Path) {
  return [string](Get-Content -LiteralPath $Path -Raw)
}
function Invoke-HeldCase([string] $Name, [scriptblock] $Action) {
  $failure = $null
  try { & $Action } catch { $failure = $_ }
  if ($Name.StartsWith("actual-", [StringComparison]::Ordinal) -and $failure -and
      (Test-ShellOwnershipUnproven $failure)) {
    try { Write-Host "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" }
    finally { [Threading.Thread]::Sleep([Threading.Timeout]::Infinite) }
  }
  $results.Add([pscustomobject]@{
    name = $Name; passed = $null -eq $failure
    error = $(if ($failure) { $failure.ToString() + "`n" + $failure.ScriptStackTrace } else { "" })
  })
}
function Get-Process { throw "PID reopening must not occur in the default launch entry" }
function Start-MultiProjectOwnedProcess { throw "Legacy PID-file launcher was invoked" }
function New-ShellProcessScope {
  $state.events.Add("scope")
  return [pscustomobject]@{ Closed = $false }
}
function Start-ShellOwnedProcess($Scope, $StartInfo, $StandardOutputWriter, $StandardErrorWriter) {
  $state.events.Add("start")
  $state.info = $StartInfo
  $state.output = $StandardOutputWriter
  $state.error = $StandardErrorWriter
  Assert-Held ($script:UiaGateOwnedCaptures.Count -eq 1) "Scope was not registered before launch"
  if ($state.startFailure) { throw $state.startFailure }
  return $state.process
}
function Register-UiaHeldProcess($Process) {
  $state.events.Add("register")
  Assert-Held ([object]::ReferenceEquals($Process, $state.process)) "Registration adopted a different process"
  if ($state.registerFailure) { throw $state.registerFailure }
}
function Close-ShellProcessScope($Scope, [int] $TimeoutMilliseconds) {
  $state.events.Add("close")
  $state.closeBudget = $TimeoutMilliseconds
  if ($state.closeFailure) { throw $state.closeFailure }
  $Scope.Closed = $true
}
function Test-ShellOwnershipUnproven($Failure) {
  $exception = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
  return $exception.Data["GraphCodeValidationRootRetentionRequired"] -eq $true
}
function Set-ShellOwnershipUnproven([Exception] $Exception) {
  $Exception.Data["GraphCodeValidationRootRetentionRequired"] = $true
  return $Exception
}

$mockCases = @("original-reference", "hidden", "derived-output", "output-collision",
  "error-collision", "start-failure", "registration-failure", "unknown-start",
  "unknown-close", "unknown-no-retry", "streaming", "clean-close", "cleanup-budget")
foreach ($case in $mockCases) {
  Invoke-HeldCase $case {
    $caseRoot = Join-Path $ArtifactRoot $case
    $null = New-Item -ItemType Directory -Path $caseRoot
    $out = Join-Path $caseRoot "shell-stdout.log"
    $err = Join-Path $caseRoot "shell-stderr.log"
    $script:UiaGateOwnedCaptures = [Collections.Generic.List[object]]::new()
    $state = @{
      events = [Collections.Generic.List[string]]::new(); process = [Diagnostics.Process]::new()
      startFailure = $null; registerFailure = $null; closeFailure = $null
    }
    $primary = [IO.IOException]::new("original controlled failure")
    if ($case -cin @("start-failure", "unknown-start")) { $state.startFailure = $primary }
    if ($case -ceq "registration-failure") { $state.registerFailure = $primary }
    if ($case -ceq "unknown-start") { $primary.Data["GraphCodeValidationRootRetentionRequired"] = $true }
    if ($case -cin @("unknown-close", "unknown-no-retry")) { $state.closeFailure = $primary }
    if ($case -ceq "output-collision") { [IO.File]::WriteAllText($out, "retained") }
    if ($case -ceq "error-collision") { [IO.File]::WriteAllText($err, "retained") }
    $failure = $null
    $actual = $null
    try {
      $actual = Start-UiaOwnedProcess -file "C:\controlled\fixture.exe" `
        -arguments @("space value", "quote`"value", "unicode-$([char]0x3bb)") `
        -standardOutputPath $(if ($case -ceq "derived-output") { "" } else { $out }) `
        -standardErrorPath $err -Hidden:($case -ceq "hidden")
    } catch { $failure = $_ }
    if ($case -cin @("output-collision", "error-collision")) {
      Assert-Held ($null -ne $failure -and $failure.Exception.GetBaseException() -is [IO.IOException] -and
        -not $state.events.Contains("start")) "Output collision launched a target or failed for an unrelated reason"
      $collision = if ($case -ceq "output-collision") { $out } else { $err }
      Assert-Held ([IO.File]::ReadAllText($collision) -ceq "retained") "Output collision overwrote retained bytes"
      return
    }
    if ($case -cin @("start-failure", "registration-failure", "unknown-start")) {
      Assert-Held ($failure -and [object]::ReferenceEquals($failure.Exception, $primary)) "Launch replaced its primary failure"
      Assert-Held ($state.events.Contains("close") -eq ($case -cne "unknown-start")) "Wrong failed-launch custody release"
      if ($case -ceq "unknown-start") {
        Assert-Held (-not $script:UiaGateOwnedCaptures[0].cleaned) "Unknown startup discarded its registered scope"
        $state.output.Write("retained-after-start-failure")
      }
      return
    }
    Assert-Held (-not $failure -and [object]::ReferenceEquals($actual, $state.process)) "Default launch did not return its original held process"
    Assert-Held (($state.info.ArgumentList -join "|") -ceq "space value|quote`"value|unicode-$([char]0x3bb)") "Argument binding changed"
    Assert-Held ($state.info.WorkingDirectory -ceq (Get-Location).ProviderPath -and
      -not $state.info.UseShellExecute -and $state.info.RedirectStandardOutput -and
      $state.info.RedirectStandardError -and $state.info.CreateNoWindow -eq ($case -ceq "hidden")) "Launch settings changed"
    Assert-Held (($state.events -join ",") -ceq "scope,start,register") "Wrong launch registration order"
    if ($case -ceq "streaming") {
      $state.output.Write("stdout-live")
      $state.error.Write("stderr-live")
      Assert-Held ((Read-HeldLog $out) -ceq "stdout-live" -and
        (Read-HeldLog $err) -ceq "stderr-live") "Logs were not visible while the target was live"
    }
    $capture = $script:UiaGateOwnedCaptures[0]
    $cleanupFailure = $null
    try {
      if ($case -ceq "cleanup-budget") { $null = Complete-MultiProjectCapture $capture $caseRoot 137 }
      else { $null = Complete-UiaHeldCapture $capture }
    } catch { $cleanupFailure = $_ }
    if ($case -cin @("unknown-close", "unknown-no-retry")) {
      Assert-Held ($cleanupFailure -and (Test-ShellOwnershipUnproven $cleanupFailure) -and -not $capture.cleaned) "Unknown teardown released custody"
      $state.output.Write("retained-writer")
      if ($case -ceq "unknown-no-retry") {
        $repeatFailure = $null
        try { $null = Complete-UiaHeldCapture $capture } catch { $repeatFailure = $_ }
        Assert-Held ($repeatFailure -and
          [object]::ReferenceEquals($repeatFailure.Exception, $cleanupFailure.Exception) -and
          @($state.events | Where-Object { $_ -ceq "close" }).Count -eq 1) "Unknown teardown was retried or returned success"
      }
    } else {
      Assert-Held (-not $cleanupFailure -and $capture.cleaned -and $capture.scope.Closed) "Clean teardown did not finalize scope"
      Assert-Held ($state.closeBudget -eq $(if ($case -ceq "cleanup-budget") { 137 } else { 5000 })) "Cleanup dispatch reset its original budget"
      $disposed = $false
      try { $state.output.Write("after-close") } catch [ObjectDisposedException] { $disposed = $true }
      Assert-Held $disposed "Output writer survived verified cleanup"
    }
  }
}

if (-not $MockOnly -and @($results | Where-Object { -not $_.passed }).Count -eq 0) {
  Import-Module (Join-Path $RepositoryRoot "Tools\windows\ShellProcessOwnership.psm1") -Force
  $env:GRAPHCODE_VALIDATION_ASSEMBLY = $AssemblyPath
  & (Join-Path $RepositoryRoot "Tools\windows\Import-CompiledValidationAssembly.ps1") `
    -AssemblyPath $AssemblyPath -RequiredType "ShellOwnedLaunch" | Out-Null
  . ([scriptblock]::Create($definitions["Register-UiaHeldProcess"]))
  function New-ShellProcessScope { ShellProcessOwnership\New-ShellProcessScope }
  function Start-ShellOwnedProcess($Scope, $StartInfo, $StandardOutputWriter, $StandardErrorWriter) {
    ShellProcessOwnership\Start-ShellOwnedProcess $Scope $StartInfo `
      -StandardOutputWriter $StandardOutputWriter -StandardErrorWriter $StandardErrorWriter
  }
  function Close-ShellProcessScope($Scope, [int] $TimeoutMilliseconds) {
    ShellProcessOwnership\Close-ShellProcessScope $Scope -TimeoutMilliseconds $TimeoutMilliseconds
  }
  function Test-ShellOwnershipUnproven($Failure) { ShellProcessOwnership\Test-ShellOwnershipUnproven $Failure }
  function Set-ShellOwnershipUnproven([Exception] $Exception) {
    ShellProcessOwnership\Set-ShellOwnershipUnproven $Exception
  }
  foreach ($case in @("actual-streams-and-binding", "actual-exit-failure", "actual-start-failure")) {
    Invoke-HeldCase $case {
      $caseRoot = Join-Path $ArtifactRoot $case
      $null = New-Item -ItemType Directory -Path $caseRoot
      $out = Join-Path $caseRoot "shell-stdout.log"
      $err = Join-Path $caseRoot "shell-stderr.log"
      $fixture = Join-Path $caseRoot "child.ps1"
      [IO.File]::WriteAllText($fixture, @'
param([string] $Expected, [string] $Release)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::WriteLine("BINDING=" + $Expected + "|" + (Get-Location).ProviderPath + "|" + $env:GRAPHCODE_HELD_TEST)
[Console]::Out.WriteLine("o" * 100000)
[Console]::Error.WriteLine("e" * 100000)
[Console]::Out.WriteLine("READY")
[Console]::Out.Flush()
if ($env:GRAPHCODE_HELD_TEST -ceq "exit-seven") { exit 7 }
$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not [IO.File]::Exists($Release)) {
  if ($clock.ElapsedMilliseconds -gt 10000) { exit 9 }
  [Threading.Thread]::Sleep(10)
}
'@, [Text.UTF8Encoding]::new($false))
      $script:UiaGateOwnedCaptures = [Collections.Generic.List[object]]::new()
      $env:GRAPHCODE_HELD_TEST = if ($case -ceq "actual-exit-failure") { "exit-seven" } else { "present" }
      $release = Join-Path $caseRoot "release"
      $value = "space quote`" unicode-$([char]0x3bb)"
      $file = if ($case -ceq "actual-start-failure") { Join-Path $caseRoot "missing.exe" } else { (Get-Command pwsh).Source }
      $failure = $null
      $process = $null
      try {
        try {
          $process = Start-UiaOwnedProcess -file $file -arguments @("-NoProfile", "-File", $fixture, $value, $release) `
            -standardOutputPath $out -standardErrorPath $err -Hidden
        } catch { $failure = $_ }
        if ($case -ceq "actual-start-failure") {
          Assert-Held ($failure -and $script:UiaGateOwnedCaptures[0].cleaned) "Failed CreateProcess did not clean its registered empty scope"
        } else {
          Assert-Held (-not $failure) "Actual held child failed to launch: $failure"
          $clock = [Diagnostics.Stopwatch]::StartNew()
          while (-not (([string](Read-HeldLog $out)).Contains("READY") -and
              ([string](Read-HeldLog $err)).Contains("e" * 100000))) {
            if ($clock.ElapsedMilliseconds -gt 5000) { throw "Actual child did not stream READY before deadline" }
            [Threading.Thread]::Sleep(10)
          }
          $text = Read-HeldLog $out
          Assert-Held ($text.Contains("BINDING=$value|$((Get-Location).ProviderPath)|$env:GRAPHCODE_HELD_TEST") -and
            $text.Contains("o" * 100000) -and (Read-HeldLog $err).Contains("e" * 100000)) "Actual argument/environment/directory/concurrent streams differ"
          if ($case -ceq "actual-streams-and-binding") {
            Assert-Held (-not $process.HasExited) "Streaming evidence was collected only after exit"
            [IO.File]::WriteAllText($release, "release")
          }
          Assert-Held ($process.WaitForExit(5000)) "Actual child did not exit before deadline"
          Assert-Held ($process.ExitCode -eq $(if ($case -ceq "actual-exit-failure") { 7 } else { 0 })) "Actual child exit was masked"
        }
      } finally {
        Stop-UiaOwnedProcessTrees @($process)
      }
    }
  }
}
$failed = @($results | Where-Object { -not $_.passed })
[IO.File]::WriteAllText((Join-Path $ArtifactRoot "cases.json"), ($results | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$expected = if ($MockOnly) { 13 } else { 16 }
$complete = $results.Count -eq $expected -and $failed.Count -eq 0 -and
  @($results.name | Sort-Object -Unique).Count -eq $expected
Write-Host "UIA held launcher: $($results.Count) cases, $($failed.Count) failures; expected=$expected"
foreach ($failure in $failed) { Write-Host "$($failure.name): $($failure.error)" }
if (-not $MockOnly) {
  Write-Output ("HOST_CASE_RESULT=" + ([ordered]@{
    id = "host.uia-held-launcher"; status = $(if ($complete) { "Passed" } else { "Failed" })
    executedCount = $results.Count; groups = @($results | Where-Object passed | ForEach-Object name)
    evidence = "Actual default launch dispatch and existing held scope; mock refusals plus three owned non-GUI child cases; UIA calls=0"
  } | ConvertTo-Json -Compress))
}
if (-not $complete) { exit 1 }
