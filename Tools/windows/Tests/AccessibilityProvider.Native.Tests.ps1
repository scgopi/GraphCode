[CmdletBinding()]
param([string] $VcVars, [switch] $HeadlessSelection)

$ErrorActionPreference = "Stop"
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
    providerSource = '"%~3"'
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
if (-not $VcVars) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio vswhere is required" }
  $installation = & $vswhere -latest -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($LASTEXITCODE -ne 0 -or -not $installation) { throw "Visual C++ build tools are required" }
  $VcVars = Join-Path $installation "VC\Auxiliary\Build\vcvars64.bat"
}
if (-not (Test-Path -LiteralPath $VcVars)) { throw "Missing Visual C++ setup: $VcVars" }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("graphcode-uia-native-" + [guid]::NewGuid())
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$savedPath = $env:PATH
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  $env:TEMP = $scratch
  $env:TMP = $scratch
  $installer = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
  $pathEntries = @($savedPath -split ";")
  if (Test-Path -LiteralPath $installer) { $pathEntries = @($installer) + $pathEntries }
  # Repeated Swift setup grows PATH until vcvars expansion exceeds cmd's limit.
  $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $uniquePaths = @(foreach ($entry in $pathEntries) {
    if ($seenPaths.Add($entry)) { $entry }
  })
  $env:PATH = $uniquePaths -join ";"
  Write-Host "[native-uia] PATH entries=$($pathEntries.Count) -> $($uniquePaths.Count); length=$($savedPath.Length) -> $($env:PATH.Length)"
  if ($env:PATH.Length -ge 8191) {
    throw "Native accessibility provider deduplicated PATH is still too long for cmd: $($env:PATH.Length)"
  }
  $provider = Join-Path $repoRoot "graphcode-windows\src\AccessibilityProvider.cpp"
  # Change directory inside cmd only: a Push-Location here becomes this process's
  # working directory at the native call and then locks the scratch folder.
  # vcvars can exit non-zero when an optional extension (for example the Linux
  # ConnectionManager) is absent even though the MSVC environment is usable, so
  # require a resolvable cl instead of trusting its exit code.
  Write-Host "[native-uia] vcvars path: $VcVars"
  # Keep batch source ASCII; pass Unicode paths through cmd arguments.
  $command = @'
@echo off
cd /d "%~dp0"
if errorlevel 1 exit /b %errorlevel%
echo [native-uia] stage=vcvars start
call "%~1"
set "vcvars_exit=%errorlevel%"
echo [native-uia] stage=vcvars exit=%vcvars_exit%
"%ComSpec%" /d /u /c set PATH >vcvars-path.txt
echo [native-uia] stage=where-cl start
where cl
set "where_exit=%errorlevel%"
echo [native-uia] stage=where-cl exit=%where_exit%
if not "%where_exit%"=="0" exit /b %where_exit%
echo [native-uia] stage=compile start
cl /nologo /EHsc /std:c++17 TEST_DEFINITIONS /Fe:uia-native.exe "%~2" PROVIDER_SOURCE TEST_LIBRARIES
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
  $arguments = 'call "{0}" "{1}" "{2}" "{3}"' -f $commandPath, $VcVars, $test, $provider
  $nativeStage = "cmd-startup"
  $nativeOutput = @(& $env:ComSpec /d /s /c $arguments 2>&1 | ForEach-Object {
    $line = "$_"
    if ($line -match '^\[native-uia\] stage=([a-z-]+) start$') {
      $nativeStage = $Matches[1]
    }
    Write-Host $line
    $line
  })
  $nativeExit = $LASTEXITCODE
  Write-Host "[native-uia] cmd exit=$nativeExit"
  if ($nativeExit -ne 0) { throw "Native accessibility provider stage '$nativeStage' failed: $nativeExit" }
  $setupPath = @(Get-Content -LiteralPath (Join-Path $scratch "vcvars-path.txt") -Encoding Unicode |
    Where-Object { $_ -match '^PATH=' })
  if ($setupPath.Count -ne 1) { throw "Native accessibility provider did not record one post-vcvars PATH" }
  $setupPathLength = $setupPath[0].Substring(5).Length
  Write-Host "[native-uia] post-vcvars PATH length=$setupPathLength (cmd limit=8191)"
  if ($setupPathLength -ge 8191) { throw "Native accessibility provider post-vcvars PATH exceeds cmd limit: $setupPathLength" }
  if (@($nativeOutput | Where-Object { $_ -ceq $plan.summary }).Count -ne 1) {
    throw "Native accessibility provider test-exe did not report exactly one expected summary: $($plan.summary)"
  }
} finally {
  $env:TEMP = $savedTemp
  $env:TMP = $savedTmp
  $env:PATH = $savedPath
    if ($HeadlessSelection) {
      Write-Host "HEADLESS_SELECTION_RETAINED_SCRATCH=$scratch"
    } else {
      # Native compiler outputs can stay locked briefly after the process exits.
      for ($attempt = 1; Test-Path -LiteralPath $scratch; $attempt++) {
        try {
          Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop
        } catch {
          if ($attempt -ge 10) {
            Write-Warning "Native accessibility test scratch was not removed: $scratch ($($_.Exception.Message))"
            break
          }
          Start-Sleep -Milliseconds 500
        }
      }
    }
}
