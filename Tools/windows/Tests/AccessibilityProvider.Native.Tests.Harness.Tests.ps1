[CmdletBinding()]
param(
  [switch] $PlanOnly,
  [string] $RepositoryRoot,
  [string] $ArtifactRoot,
  [string] $AssemblyPath,
  [string] $NativeScriptUnderTest
)

$ErrorActionPreference = "Stop"
$nativeScript = Join-Path $PSScriptRoot "AccessibilityProvider.Native.Tests.ps1"
$parseErrors = $null
$nativeAst = [Management.Automation.Language.Parser]::ParseFile($nativeScript, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "Native accessibility runner must parse" }
$planFunctions = @($nativeAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq "Get-AccessibilityProviderNativeTestPlan"
}, $true))
if ($planFunctions.Count -ne 1) { throw "Native accessibility needs one shared compile plan" }
. ([scriptblock]::Create($planFunctions[0].Extent.Text))
$planChecks = 0
foreach ($headless in @($false, $true)) {
  $plan = Get-AccessibilityProviderNativeTestPlan $headless
  $expected = if ($headless) {
    @("/DGC_UIA_HEADLESS_SELECTION", "", "oleaut32.lib user32.lib uuid.lib",
      "Headless navigation selection: 179 checks, 0 failures")
  } else {
    @("", '"%GRAPHCODE_NATIVE_PROVIDER%"', "oleaut32.lib uiautomationcore.lib user32.lib",
      "Native accessibility provider: 280 checks, 0 failures")
  }
  $actual = @($plan.definitions, $plan.providerSource, $plan.libraries, $plan.summary)
  for ($index = 0; $index -lt $expected.Count; $index++) {
    if ($actual[$index] -cne $expected[$index]) { throw "Wrong native compile plan: headless=$headless field=$index" }
    $planChecks++
  }
}
$nativeSource = [IO.File]::ReadAllText($nativeScript)
foreach ($literal in @(
  '.Replace("TEST_DEFINITIONS", $plan.definitions)',
  'Replace("PROVIDER_SOURCE", $plan.providerSource)',
  'Replace("TEST_LIBRARIES", $plan.libraries)',
  '$_ -ceq $plan.summary',
  'if ($HeadlessSelection)',
  'GC_UIA_HEADLESS_SELECTION'
)) {
  if (-not $nativeSource.Contains($literal)) { throw "Native compile plan is not enforced: $literal" }
  $planChecks++
}
Write-Host "Native accessibility compile plan: $planChecks checks, 0 failures (source/data only)"
if ($PlanOnly) {
  if ($ArtifactRoot) {
    Write-Output ("UI_CASE_RESULT=" + ([ordered]@{
      id = "ui.navigation.headless-runner-plan"; status = "Passed"; executedCount = $planChecks
      evidence = "Actual native runner compile plan; source/data controls; compilerCalls=0; nativeCalls=0"
    } | ConvertTo-Json -Compress))
    return
  }
  return $planChecks
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
if (-not $AssemblyPath) { $AssemblyPath = & (Join-Path $PSScriptRoot "..\Build-CompiledValidationRunner.ps1") }
& (Join-Path $PSScriptRoot "..\Import-CompiledValidationAssembly.ps1") `
  -AssemblyPath $AssemblyPath -RequiredType "GraphCode.Validation.Ownership.OwnedChildSupervisor" | Out-Null
foreach ($name in @("Invoke-AccessibilityProviderOwnedStep", "Get-AccessibilityProviderRemaining",
    "Wait-AccessibilityProviderOwnershipRecovery", "Wait-AccessibilityProviderRetainedAuthority")) {
  $found = @($nativeAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true))
  if ($found.Count -ne 1) { throw "Missing unique native supervision helper: $name" }
  . ([scriptblock]::Create($found[0].Extent.Text))
}
if (-not $NativeScriptUnderTest) { $NativeScriptUnderTest = $nativeScript }
$safetyCases = [Collections.Generic.List[string]]::new()
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("graphcode uia harness-" + [char]0xe9 + [guid]::NewGuid())
function Test-AbruptStage([string] $Stage, [switch] $RepeatedPath, [switch] $TimeoutMode,
    [switch] $MetadataFailure, [switch] $FakeSummary) {
  $caseName = if ($FakeSummary) { "fake-summary" } elseif ($MetadataFailure) { "timeout-metadata" } elseif ($TimeoutMode) { "timeout" } elseif ($RepeatedPath) { "$Stage-repeated-path" } else { $Stage }
  $fixture = Join-Path $scratch $caseName
  $childTemp = Join-Path $fixture "temp"
  New-Item -ItemType Directory -Path $childTemp | Out-Null
  $vcvars = Join-Path $fixture "vcvars.cmd"
  $setup = if ($RepeatedPath) {
    "@echo off`r`necho [native-harness] setup PATH=%PATH%`r`nexit /b 0`r`n"
  } elseif ($Stage -eq "vcvars") {
    "@echo off`r`nexit 255`r`n"
  } else {
    "@echo off`r`nset `"PATH=%~dp0;%SystemRoot%\System32`"`r`nexit /b 0`r`n"
  }
  [IO.File]::WriteAllText($vcvars, $setup, [Text.Encoding]::ASCII)
  if ($Stage -ne "vcvars") {
    $tool = if ($Stage -eq "where-cl") { "where.cmd" } else { "cl.cmd" }
    $toolBody = "@echo off`r`nexit 255`r`n"
    if ($TimeoutMode) {
      $extra = if ($MetadataFailure) { 'mkdir native\supervision.json' + "`r`n" } else { "" }
      $toolBody = "@echo off`r`n${extra}echo timeout-ready`r`necho timeout-stderr 1>&2`r`n`"$(Join-Path $PSHOME 'pwsh.exe')`" -NoProfile -Command `"Start-Sleep -Seconds 30`"`r`n"
    }
    if ($FakeSummary) { $toolBody = "@echo off`r`necho Native accessibility provider: 280 checks, 0 failures`r`nexit /b 0`r`n" }
    [IO.File]::WriteAllText((Join-Path $fixture $tool), $toolBody, [Text.Encoding]::ASCII)
    if ($TimeoutMode) {
      $recipe = [IO.File]::ReadAllText((Join-Path $fixture $tool))
      $stdoutMarker = $recipe.IndexOf("echo timeout-ready`r`n", [StringComparison]::Ordinal)
      $stderrMarker = $recipe.IndexOf("echo timeout-stderr 1>&2`r`n", [StringComparison]::Ordinal)
      $sleeper = $recipe.IndexOf('"' + (Join-Path $PSHOME 'pwsh.exe') + '"', [StringComparison]::Ordinal)
      if ($stdoutMarker -lt 0 -or $stderrMarker -le $stdoutMarker -or $sleeper -le $stderrMarker) {
        throw "Timeout fixture must emit both exact partial-stream markers before nested sleeper startup"
      }
    }
  }
  $wrapper = Join-Path $fixture "invoke.ps1"
  [IO.File]::WriteAllText($wrapper, @'
param([string] $NativeScript, [string] $VcVars, [int] $CaseTimeout, [switch] $LegacyControl)
$before = $env:PATH
$result = 0
try {
  if ($LegacyControl) { & $NativeScript -VcVars $VcVars }
  else { & $NativeScript -VcVars $VcVars -TimeoutMilliseconds $CaseTimeout }
} catch {
  for ($errorNode = $_.Exception; $errorNode; $errorNode = $errorNode.InnerException) {
    if ($errorNode.Data.Contains("NativeSupervisionReportFailure")) {
      Write-Host "NATIVE_REPORT_FAILURE_RETAINED=True"
      break
    }
  }
  Write-Error -ErrorRecord $_ -ErrorAction Continue
  $result = 1
} finally {
  if ($env:PATH -cne $before) { throw "Native harness original PATH was not restored" }
  Write-Host "[native-harness] original PATH restored"
}
exit $result
'@, [Text.Encoding]::ASCII)
  $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
  $wrapperEncoding = [Text.Encoding]::GetEncoding([ShellOwnedLaunch]::OemCodePage(),
    [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
  $start.StandardOutputEncoding = $wrapperEncoding
  $start.StandardErrorEncoding = $wrapperEncoding
  foreach ($argument in @(
      "-NoProfile", "-File", $wrapper, "-NativeScript",
      $NativeScriptUnderTest, "-VcVars", $vcvars,
      "-CaseTimeout", $(if ($TimeoutMode) { "1000" } else { "10000" }))) {
    $start.ArgumentList.Add($argument)
  }
  if ($NativeScriptUnderTest -cne $nativeScript) { $start.ArgumentList.Add("-LegacyControl") }
  $start.Environment["TEMP"] = $childTemp
  $start.Environment["TMP"] = $childTemp
  $start.Environment["GRAPHCODE_VALIDATION_ASSEMBLY"] = $AssemblyPath
  if ($RepeatedPath) {
    $start.Environment["PATH"] = (@($fixture) + @($fixture.ToUpperInvariant()) * 99 +
      @("$env:SystemRoot\System32")) -join ";"
  }
  $execution = Invoke-AccessibilityProviderOwnedStep $start 30000 (Join-Path $fixture "outer-supervision")
    $diagnosticPrefix = "NATIVE_UIA_DIAGNOSTIC_JSON="
    $output = (@(($execution.StandardOutput + $execution.StandardError) -split "\r?\n") | ForEach-Object {
      if ($_.StartsWith($diagnosticPrefix, [StringComparison]::Ordinal)) {
        $_.Substring($diagnosticPrefix.Length) | ConvertFrom-Json
      } else { $_ }
    }) -join "`n"
    Write-Host ("NATIVE_HARNESS_CHILD_OUTPUT_JSON=" + ($output | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii))
    if ($execution.ExitCode -eq 0) { throw "RED: native harness masked $Stage failure" }
    $retained = @(Get-ChildItem -LiteralPath $childTemp -Directory)
    if ($retained.Count -ne 1) { throw "Native runner deleted or failed to retain its exact scratch after $caseName" }
    $nativeEvidence = Join-Path $retained[0].FullName "native"
    if ($FakeSummary) {
      if ($output -notmatch "did not report exactly one compile/test execution marker" -or
          $output -match "\[native-uia\] stage=test-exe start") {
        throw "Fake positive summary without actual fixture execution was accepted"
      }
      $proof = Get-Content (Join-Path $nativeEvidence "supervision.json") -Raw | ConvertFrom-Json
      if ($proof.exitCode -ne 0 -or -not $proof.cleanup.ResourcesClosed) { throw "Fake-summary control lost its real host result" }
      $safetyCases.Add($caseName)
      return
    }
    if ($TimeoutMode) {
      if ($output -notmatch "OWNED_CAPTURE_EXIT: original deadline exceeded" -or
          $output -match "\[native-uia\] stage=test-exe start") {
        throw "Native timeout was masked or continued into the fixture"
      }
      $raw = @(Get-ChildItem -LiteralPath $nativeEvidence -Filter "*-stdout.log")
      $rawError = @(Get-ChildItem -LiteralPath $nativeEvidence -Filter "*-stderr.log")
      if ($raw.Count -ne 1 -or $rawError.Count -ne 1 -or
          -not [IO.File]::ReadAllText($raw[0].FullName).Contains("timeout-ready") -or
          -not [IO.File]::ReadAllText($rawError[0].FullName).Contains("timeout-stderr")) {
        throw "Native timeout lost independent partial output"
      }
      if ($MetadataFailure) {
        if (-not (Test-Path -LiteralPath (Join-Path $nativeEvidence "supervision.json") -PathType Container)) {
          throw "Metadata failure control did not reach its actual collision"
        }
        if ($output -notmatch "NATIVE_REPORT_FAILURE_RETAINED=True") { throw "Metadata write failure replaced or lost its primary diagnostic" }
      } else {
        $proof = Get-Content (Join-Path $nativeEvidence "supervision.json") -Raw | ConvertFrom-Json
        if (-not $proof.failed -or -not $proof.cleanup.RootExited -or -not $proof.cleanup.JobEmpty -or
            -not $proof.cleanup.StdoutEof -or -not $proof.cleanup.StderrEof -or -not $proof.cleanup.ResourcesClosed) {
          throw "Timed-out native host did not prove original job/root/pipe cleanup"
        }
      }
      $safetyCases.Add($caseName)
      return
    }
    if ($output -notmatch "\[native-uia\] stage=$Stage start" -or
        $output -notmatch '\[native-uia\] cmd exit=255') {
      throw "RED: native harness lost the actual $Stage command exit"
    }
    if ($output -notmatch "stage '$Stage' failed: 255") {
      throw "RED: native harness did not attribute abrupt exit 255 to $Stage"
    }
    if ($output -match '\[native-uia\] stage=test-exe start' -or
        ($Stage -ne "compile" -and $output -match '\[native-uia\] stage=compile start')) {
      throw "RED: native harness continued after abrupt $Stage failure"
    }
    $proof = Get-Content (Join-Path $nativeEvidence "supervision.json") -Raw | ConvertFrom-Json
    if ($proof.exitCode -ne 255 -or -not $proof.cleanup.RootExited -or -not $proof.cleanup.JobEmpty -or
        -not $proof.cleanup.StdoutEof -or -not $proof.cleanup.StderrEof -or -not $proof.cleanup.ResourcesClosed) {
      throw "Native mock failure did not retain exact exit and successful held cleanup proof"
    }
    if ($proof.stdoutCodePage -ne [ShellOwnedLaunch]::OemCodePage() -or
        $proof.stderrCodePage -ne $proof.stdoutCodePage) { throw "cmd producer encodings were not bound explicitly" }
    if ($Stage -ceq "compile" -and -not $output.Contains((Join-Path $fixture "cl.cmd"))) {
      throw "Controlled non-ASCII compiler path did not roundtrip through cmd's actual OEM codec"
    }
    if ($output -notmatch '\[native-harness\] original PATH restored') {
      throw "RED: native harness did not restore the exact original PATH after $Stage failure"
    }
    if ($RepeatedPath) {
      $pathLine = [regex]::Match($output, '(?m)^\[native-harness\] setup PATH=(.*)\r?$')
      $entries = @($pathLine.Groups[1].Value.TrimEnd("`r") -split ";")
      $matching = @($entries | Where-Object { $_ -ieq $fixture })
      if ($matching.Count -ne 1 -or $matching[0] -cne $fixture -or
          [Array]::IndexOf($entries, $fixture) -ge [Array]::IndexOf($entries, "$env:SystemRoot\System32")) {
        throw "RED: native harness did not preserve case-insensitive first-occurrence PATH order"
      }
    }
    $safetyCases.Add($caseName)
}
try {
  foreach ($stage in @("vcvars", "where-cl", "compile")) {
    Test-AbruptStage $stage
  }
  Test-AbruptStage "compile" -RepeatedPath
  Write-Host "Native accessibility harness: 25 checks, 0 failures (mock tools; no native fixture)"
  Test-AbruptStage "compile" -FakeSummary
  Test-AbruptStage "compile" -TimeoutMode
  Test-AbruptStage "compile" -TimeoutMode -MetadataFailure
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $first = Get-AccessibilityProviderRemaining $clock 1000
  [Threading.Thread]::Sleep(20)
  $second = Get-AccessibilityProviderRemaining $clock 1000
  if ($first -le 0 -or $second -le 0 -or $second -ge $first) { throw "Original case budget was reset across steps" }
  $safetyCases.Add("shared-budget")
  $refused = $false
  try { $null = Get-AccessibilityProviderRemaining $clock 1 } catch [TimeoutException] { $refused = $true }
  if (-not $refused) { throw "Expired original budget did not refuse another launch" }
  $safetyCases.Add("expired-budget")
  $info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
  $info.UseShellExecute = $false
  $refused = $false
  try { $null = Invoke-AccessibilityProviderOwnedStep $info 0 (Join-Path $scratch "must-not-create") } catch [TimeoutException] { $refused = $true }
  if (-not $refused -or (Test-Path -LiteralPath (Join-Path $scratch "must-not-create"))) { throw "Zero-budget step acquired resources" }
  $safetyCases.Add("zero-budget")
  & {
    $state = @{ waits = 0; signals = 0 }
    function Wait-AccessibilityProviderOwnershipRecovery { $state.waits++; throw "controlled retained authority" }
    function Write-Host($Object) {
      if ([string]$Object -cne "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven") { throw "Unexpected retention signal" }
      $state.signals++
    }
    Wait-AccessibilityProviderRetainedAuthority 0
    if ($state.waits -ne 0 -or $state.signals -ne 0) { throw "Zero retained leases entered the passive barrier" }
    $safetyCases.Add("zero-retention")
    $failure = $null
    try { Wait-AccessibilityProviderRetainedAuthority 1 } catch { $failure = $_ }
    if (-not $failure -or $failure.Exception.Message -cne "controlled retained authority" -or
        $state.waits -ne 1 -or $state.signals -ne 1) { throw "UNKNOWN did not signal and enter passive original-authority retention" }
    $safetyCases.Add("unknown-retention")
    $state.waits = 0
    function Write-Host($Object) { throw "controlled diagnostic failure" }
    try { Wait-AccessibilityProviderRetainedAuthority 1 } catch { $failure = $_ }
    if ($state.waits -ne 1) { throw "Diagnostic failure bypassed passive original-authority retention" }
    $safetyCases.Add("unknown-diagnostic-failure")
  }
  $invalidInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
  $invalidInfo.UseShellExecute = $false
  $invalidInfo.CreateNoWindow = $true
  $invalidInfo.RedirectStandardOutput = $true
  $invalidInfo.RedirectStandardError = $true
  $invalidInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
  $invalidInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
  $invalidScript = '[Console]::OpenStandardOutput().Write([byte[]]@(255),0,1)'
  foreach ($argument in @("-NoProfile", "-EncodedCommand", [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invalidScript)))) {
    $invalidInfo.ArgumentList.Add($argument)
  }
  $invalidRoot = Join-Path $scratch "invalid-utf8"
  $failure = $null
  try { $null = Invoke-AccessibilityProviderOwnedStep $invalidInfo 10000 $invalidRoot } catch { $failure = $_ }
  $raw = @(Get-ChildItem -LiteralPath $invalidRoot -Filter "*-stdout.log")
  $proof = Get-Content (Join-Path $invalidRoot "supervision.json") -Raw | ConvertFrom-Json
  if (-not $failure -or $failure.Exception.Message -notmatch "OWNED_CAPTURE_DRAIN" -or $raw.Count -ne 1 -or
      ([IO.File]::ReadAllBytes($raw[0].FullName) -join ",") -cne "255" -or
      $proof.stdoutCodePage -ne 65001 -or -not $proof.failed -or -not $proof.cleanup.ResourcesClosed) {
    throw "Invalid-byte control was recoded, silently replaced or lost authoritative raw evidence"
  }
  $safetyCases.Add("invalid-byte-refusal")
  $missing = [Diagnostics.ProcessStartInfo]::new((Join-Path $scratch "missing.exe"))
  $missing.UseShellExecute = $false
  $failure = $null
  $missingRoot = Join-Path $scratch "missing-executable"
  try { $null = Invoke-AccessibilityProviderOwnedStep $missing 1000 $missingRoot } catch { $failure = $_ }
  $proof = Get-Content (Join-Path $missingRoot "supervision.json") -Raw | ConvertFrom-Json
  if (-not $failure -or -not $proof.failed -or $null -ne $proof.cleanup -or $proof.retainedLeaseCount -ne 0) {
    throw "Missing executable did not preserve explicit unavailable cleanup evidence without inventing success"
  }
  $safetyCases.Add("missing-executable")
  if ([regex]::Matches($nativeSource, [regex]::Escape('(Get-AccessibilityProviderRemaining $caseClock $TimeoutMilliseconds)')).Count -ne 2) {
    throw "Discovery and compile/test must use the same original clock/budget"
  }
  $pairClock = [Diagnostics.Stopwatch]::StartNew()
  $pairInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
  $pairInfo.UseShellExecute = $false
  $pairInfo.CreateNoWindow = $true
  $pairInfo.RedirectStandardOutput = $true
  $pairInfo.RedirectStandardError = $true
  foreach ($argument in @("-NoProfile", "-Command", "[Console]::WriteLine('stage-one')")) { $pairInfo.ArgumentList.Add($argument) }
  $firstStep = Invoke-AccessibilityProviderOwnedStep $pairInfo (Get-AccessibilityProviderRemaining $pairClock 2000) `
    (Join-Path $scratch "pair-first")
  if ($firstStep.ExitCode -ne 0 -or -not $firstStep.StandardOutput.Contains("stage-one")) { throw "First original-budget step did not execute" }
  $pairInfo.ArgumentList.Clear()
  foreach ($argument in @("-NoProfile", "-Command", "Start-Sleep -Seconds 10")) { $pairInfo.ArgumentList.Add($argument) }
  $failure = $null
  $pairSecond = Join-Path $scratch "pair-second"
  try { $null = Invoke-AccessibilityProviderOwnedStep $pairInfo (Get-AccessibilityProviderRemaining $pairClock 2000) $pairSecond }
  catch { $failure = $_ }
  $proof = Get-Content (Join-Path $pairSecond "supervision.json") -Raw | ConvertFrom-Json
  if (-not $failure -or $failure.Exception.Message -notmatch "OWNED_CAPTURE_EXIT" -or
      $proof.timeoutMilliseconds -ge 2000 -or $proof.launchBudgetMilliseconds -gt $proof.timeoutMilliseconds -or
      -not $proof.failed -or -not $proof.cleanup.ResourcesClosed) {
    throw "Second actual supervised step refreshed its original total budget or lost cleanup proof"
  }
  $safetyCases.Add("two-step-original-budget")
  if ($safetyCases.Count -ne 16 -or @($safetyCases | Sort-Object -Unique).Count -ne 16) { throw "Native safety case inventory differs" }
  Write-Host "Native accessibility runner safety: 16 cases, 0 failures"
  if ($ArtifactRoot) {
    Write-Output ("UI_CASE_RESULT=" + ([ordered]@{
      id = "ui.navigation.native-runner-safety"; status = "Passed"; executedCount = 16
      groups = $safetyCases.ToArray()
      evidence = "Actual existing runner/import/supervised invocation; controlled failing and timed-out tools; no C++ fixture or UIA entrypoints"
    } | ConvertTo-Json -Compress))
  }
} finally {
  try { Write-Host ("NATIVE_HARNESS_RETAINED_SCRATCH_JSON=" + ($scratch | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii)) }
  finally {
    Wait-AccessibilityProviderRetainedAuthority `
      ([GraphCode.Validation.Ownership.OwnedChildSupervisor]::RetainedLeaseCount)
  }
}
