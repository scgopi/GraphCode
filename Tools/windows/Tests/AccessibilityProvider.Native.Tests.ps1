[CmdletBinding()]
param(
  [string] $VcVars,
  [switch] $HeadlessSelection,
  [ValidateRange(1, 600000)][int] $TimeoutMilliseconds = 120000
)

$ErrorActionPreference = "Stop"
$caseClock = [Diagnostics.Stopwatch]::StartNew()
function Write-AccessibilityProviderDiagnostic([string] $Line) {
  if ($Line -cmatch '[^\x00-\x7f]') {
    Write-Host ("NATIVE_UIA_DIAGNOSTIC_JSON=" + ($Line | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii))
  } else { Write-Host $Line }
}
function Get-AccessibilityProviderRemaining([Diagnostics.Stopwatch] $Clock, [int] $Budget) {
  $remaining = $Budget - [int]$Clock.ElapsedMilliseconds
  if ($remaining -le 0) { throw [TimeoutException]::new("Native accessibility provider original case deadline exceeded") }
  return $remaining
}

function Invoke-AccessibilityProviderOwnedStep(
  [Diagnostics.ProcessStartInfo] $StartInfo,
  [int] $TimeoutMilliseconds,
  [string] $ArtifactRoot
) {
  $stepClock = [Diagnostics.Stopwatch]::StartNew()
  if ($TimeoutMilliseconds -le 0) { throw [TimeoutException]::new("Native accessibility provider has no launch budget") }
  $null = New-Item -ItemType Directory -Path $ArtifactRoot
  $result = $null
  $failure = $null
  $launchBudget = $null
  try {
    $launchBudget = $TimeoutMilliseconds - [int]$stepClock.ElapsedMilliseconds
    if ($launchBudget -le 0) { throw [TimeoutException]::new("Native accessibility provider step exhausted its original budget before launch") }
    $result = [GraphCode.Validation.Ownership.OwnedChildSupervisor]::RunAsync(
      $StartInfo, [TimeSpan]::FromMilliseconds($launchBudget), $ArtifactRoot,
      [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  } catch {
    $failure = $_
    throw
  } finally {
    $proof = if ($result) { $result.Cleanup } else { $null }
    if ($failure) {
      for ($exception = $failure.Exception; $exception; $exception = $exception.InnerException) {
        if ($exception.Data.Contains("OwnedCleanupProof")) { $proof = $exception.Data["OwnedCleanupProof"]; break }
      }
    }
    $record = [ordered]@{
      stage = Split-Path -Leaf $ArtifactRoot
      executable = $StartInfo.FileName
      timeoutMilliseconds = $TimeoutMilliseconds
      launchBudgetMilliseconds = $launchBudget
      exitCode = $(if ($result) { $result.ExitCode } else { $null })
      failed = $null -ne $failure
      failureType = $(if ($failure) { $failure.Exception.GetBaseException().GetType().FullName } else { $null })
      stdoutCodePage = $(if ($StartInfo.StandardOutputEncoding) { $StartInfo.StandardOutputEncoding.CodePage } else { $null })
      stderrCodePage = $(if ($StartInfo.StandardErrorEncoding) { $StartInfo.StandardErrorEncoding.CodePage } else { $null })
      cleanup = $proof
      retainedLeaseCount = [GraphCode.Validation.Ownership.OwnedChildSupervisor]::RetainedLeaseCount
    }
    try {
      [IO.File]::WriteAllText((Join-Path $ArtifactRoot "supervision.json"),
        ($record | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    } catch {
      if ($failure) { $failure.Exception.Data["NativeSupervisionReportFailure"] = $_.Exception }
      else { throw }
    }
  }
  return $result
}

function Wait-AccessibilityProviderOwnershipRecovery {
  [Threading.Thread]::Sleep([Threading.Timeout]::Infinite)
}

function Wait-AccessibilityProviderRetainedAuthority([int] $RetainedLeaseCount) {
  if ($RetainedLeaseCount -eq 0) { return }
  try { Write-Host "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" }
  finally { Wait-AccessibilityProviderOwnershipRecovery }
}

function Get-AccessibilityProviderNativeTestPlan([bool] $HeadlessSelection) {
  if ($HeadlessSelection) {
    return [pscustomobject]@{
      definitions = "/DGC_UIA_HEADLESS_SELECTION"
      providerSource = ""
      libraries = "oleaut32.lib user32.lib uuid.lib"
      summary = "Headless navigation selection: 179 checks, 0 failures"
    }
  }
  return [pscustomobject]@{
    definitions = ""
    providerSource = '"%GRAPHCODE_NATIVE_PROVIDER%"'
    libraries = "oleaut32.lib uiautomationcore.lib user32.lib"
    summary = "Native accessibility provider: 280 checks, 0 failures"
  }
}
$plan = Get-AccessibilityProviderNativeTestPlan ([bool]$HeadlessSelection)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$test = Join-Path $PSScriptRoot "AccessibilityProvider.Native.Tests.cpp"
if ($HeadlessSelection) {
  $testSource = [IO.File]::ReadAllText($test)
  if ($testSource -notmatch '(?m)^#if(?:def\s+GC_UIA_HEADLESS_SELECTION|[ \t]+defined\s*\(\s*GC_UIA_HEADLESS_SELECTION\s*\))' -or
      -not $testSource.Contains("Headless navigation selection:")) {
    throw "Headless selection requires the intercepted C++ test branch; the legacy native entry will not run"
  }
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("graphcode-uia-native-" + [guid]::NewGuid())
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$savedPath = $env:PATH
New-Item -ItemType Directory -Path $scratch | Out-Null
$bindingsLoaded = $false
try {
  $assemblyPath = $env:GRAPHCODE_VALIDATION_ASSEMBLY
  if (-not $assemblyPath) {
    $assemblyPath = & (Join-Path $PSScriptRoot "..\Build-CompiledValidationRunner.ps1")
  }
  & (Join-Path $PSScriptRoot "..\Import-CompiledValidationAssembly.ps1") `
    -AssemblyPath $assemblyPath -RequiredType "GraphCode.Validation.Ownership.OwnedChildSupervisor" | Out-Null
  $bindingsLoaded = $true
  $env:TEMP = $scratch
  $env:TMP = $scratch
  if (-not $VcVars) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio vswhere is required" }
    $discovery = [Diagnostics.ProcessStartInfo]::new($vswhere)
    $discovery.UseShellExecute = $false
    $discovery.CreateNoWindow = $true
    $discovery.WorkingDirectory = $scratch
    $discovery.RedirectStandardOutput = $true
    $discovery.RedirectStandardError = $true
    $discovery.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $discovery.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    foreach ($argument in @("-latest", "-products", "*", "-requires",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath", "-utf8")) {
      $discovery.ArgumentList.Add($argument)
    }
    $discovered = Invoke-AccessibilityProviderOwnedStep $discovery `
      (Get-AccessibilityProviderRemaining $caseClock $TimeoutMilliseconds) (Join-Path $scratch "discovery")
    $installations = @($discovered.StandardOutput -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($discovered.ExitCode -ne 0 -or $installations.Count -ne 1) { throw "Visual C++ build tools discovery did not return one installation" }
    $VcVars = Join-Path $installations[0] "VC\Auxiliary\Build\vcvars64.bat"
  }
  if (-not (Test-Path -LiteralPath $VcVars)) { throw "Missing Visual C++ setup: $VcVars" }
  foreach ($path in @($VcVars, $test, (Join-Path $repoRoot "graphcode-windows\src\AccessibilityProvider.cpp"))) {
    if ($path -match '["%!\r\n]') { throw "Native accessibility compiler paths must be batch-safe" }
  }
  $installer = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
  $pathEntries = @($savedPath -split ";")
  if (Test-Path -LiteralPath $installer) { $pathEntries = @($installer) + $pathEntries }
  # Repeated Swift setup grows PATH until vcvars expansion exceeds cmd's limit.
  $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $uniquePaths = @(foreach ($entry in $pathEntries) {
    if ($seenPaths.Add($entry)) { $entry }
  })
  $env:PATH = $uniquePaths -join ";"
  Write-AccessibilityProviderDiagnostic "[native-uia] PATH entries=$($pathEntries.Count) -> $($uniquePaths.Count); length=$($savedPath.Length) -> $($env:PATH.Length)"
  if ($env:PATH.Length -ge 8191) {
    throw "Native accessibility provider deduplicated PATH is still too long for cmd: $($env:PATH.Length)"
  }
  $provider = Join-Path $repoRoot "graphcode-windows\src\AccessibilityProvider.cpp"
  # Change directory inside cmd only: a Push-Location here becomes this process's
  # working directory at the native call and then locks the scratch folder.
  # vcvars can exit non-zero when an optional extension (for example the Linux
  # ConnectionManager) is absent even though the MSVC environment is usable, so
  # require a resolvable cl instead of trusting its exit code.
  Write-AccessibilityProviderDiagnostic "[native-uia] vcvars path: $VcVars"
  # Keep batch source ASCII; pass Unicode paths through cmd arguments.
  $command = @'
@echo off
cd /d "%~dp0"
if errorlevel 1 exit /b %errorlevel%
echo [native-uia] stage=vcvars start
call "%GRAPHCODE_NATIVE_VCVARS%"
set "vcvars_exit=%errorlevel%"
echo [native-uia] stage=vcvars exit=%vcvars_exit%
"%ComSpec%" /d /u /c set PATH >vcvars-path.txt
echo [native-uia] stage=where-cl start
where cl
set "where_exit=%errorlevel%"
echo [native-uia] stage=where-cl exit=%where_exit%
if not "%where_exit%"=="0" exit /b %where_exit%
echo [native-uia] stage=compile start
cl /nologo /EHsc /std:c++17 TEST_DEFINITIONS /Fe:uia-native.exe "%GRAPHCODE_NATIVE_TEST%" PROVIDER_SOURCE TEST_LIBRARIES
set "compile_exit=%errorlevel%"
echo [native-uia] stage=compile exit=%compile_exit%
if not "%compile_exit%"=="0" exit /b %compile_exit%
echo [native-uia] stage=test-exe start
.\uia-native.exe
set "test_exit=%errorlevel%"
echo [native-uia] stage=test-exe exit=%test_exit%
exit /b %test_exit%
'@
  $command = $command.Replace("TEST_DEFINITIONS", $plan.definitions).
    Replace("PROVIDER_SOURCE", $plan.providerSource).
    Replace("TEST_LIBRARIES", $plan.libraries)
  $commandPath = Join-Path $scratch "run-native.cmd"
  [IO.File]::WriteAllText($commandPath,
    $command.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
  $native = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
  $native.UseShellExecute = $false
  $native.CreateNoWindow = $true
  $native.WorkingDirectory = $scratch
  $native.RedirectStandardOutput = $true
  $native.RedirectStandardError = $true
  [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
  $oemEncoding = [Text.Encoding]::GetEncoding([ShellOwnedLaunch]::OemCodePage(),
    [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
  $native.StandardOutputEncoding = $oemEncoding
  $native.StandardErrorEncoding = $oemEncoding
  foreach ($argument in @("/d", "/s", "/c", "run-native.cmd")) { $native.ArgumentList.Add($argument) }
  $native.Environment["GRAPHCODE_NATIVE_VCVARS"] = [IO.Path]::GetFullPath($VcVars)
  $native.Environment["GRAPHCODE_NATIVE_TEST"] = $test
  $native.Environment["GRAPHCODE_NATIVE_PROVIDER"] = $provider
  $nativeStage = "cmd-startup"
  $nativeResult = Invoke-AccessibilityProviderOwnedStep $native `
    (Get-AccessibilityProviderRemaining $caseClock $TimeoutMilliseconds) (Join-Path $scratch "native")
  $nativeOutput = @(@($nativeResult.StandardOutput -split "\r?\n") + @($nativeResult.StandardError -split "\r?\n"))
  foreach ($line in $nativeOutput) {
    if ($line -match '^\[native-uia\] stage=([a-z-]+) start$') {
      $nativeStage = $Matches[1]
    }
    Write-AccessibilityProviderDiagnostic $line
  }
  $nativeExit = $nativeResult.ExitCode
  Write-AccessibilityProviderDiagnostic "[native-uia] cmd exit=$nativeExit"
  if ($nativeExit -ne 0) { throw "Native accessibility provider stage '$nativeStage' failed: $nativeExit" }
  $setupPath = @(Get-Content -LiteralPath (Join-Path $scratch "vcvars-path.txt") -Encoding Unicode |
    Where-Object { $_ -match '^PATH=' })
  if ($setupPath.Count -ne 1) { throw "Native accessibility provider did not record one post-vcvars PATH" }
  $setupPathLength = $setupPath[0].Substring(5).Length
  Write-AccessibilityProviderDiagnostic "[native-uia] post-vcvars PATH length=$setupPathLength (cmd limit=8191)"
  if ($setupPathLength -ge 8191) { throw "Native accessibility provider post-vcvars PATH exceeds cmd limit: $setupPathLength" }
  foreach ($marker in @("[native-uia] stage=compile exit=0", "[native-uia] stage=test-exe start",
      "[native-uia] stage=test-exe exit=0")) {
    if (@($nativeOutput | Where-Object { $_ -ceq $marker }).Count -ne 1) {
      throw "Native accessibility provider did not report exactly one compile/test execution marker: $marker"
    }
  }
  if (@($nativeOutput | Where-Object { $_ -ceq $plan.summary }).Count -ne 1) {
    throw "Native accessibility provider test-exe did not report exactly one expected summary: $($plan.summary)"
  }
} finally {
  $env:TEMP = $savedTemp
  $env:TMP = $savedTmp
  $env:PATH = $savedPath
  try {
    Write-AccessibilityProviderDiagnostic "NATIVE_ACCESSIBILITY_RETAINED_SCRATCH=$scratch"
    if ($HeadlessSelection) { Write-AccessibilityProviderDiagnostic "HEADLESS_SELECTION_RETAINED_SCRATCH=$scratch" }
  } finally {
    if ($bindingsLoaded) {
      Wait-AccessibilityProviderRetainedAuthority `
        ([GraphCode.Validation.Ownership.OwnedChildSupervisor]::RetainedLeaseCount)
    }
  }
}
