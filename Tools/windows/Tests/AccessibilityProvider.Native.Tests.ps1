[CmdletBinding()]
param([string] $VcVars)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
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
  if (Test-Path -LiteralPath $installer) { $env:PATH = "$installer;$savedPath" }
  $test = Join-Path $PSScriptRoot "AccessibilityProvider.Native.Tests.cpp"
  $provider = Join-Path $repoRoot "graphcode-windows\src\AccessibilityProvider.cpp"
  # Change directory inside cmd only: a Push-Location here becomes this process's
  # working directory at the native call and then locks the scratch folder.
  # vcvars can exit non-zero when an optional extension (for example the Linux
  # ConnectionManager) is absent even though the MSVC environment is usable, so
  # require a resolvable cl instead of trusting its exit code.
  Write-Host "[native-uia] vcvars path: $VcVars"
  $command = @"
@echo off
cd /d "$scratch"
if errorlevel 1 exit /b %errorlevel%
echo [native-uia] stage=vcvars start
call "$VcVars"
set "vcvars_exit=%errorlevel%"
echo [native-uia] stage=vcvars exit=%vcvars_exit%
echo [native-uia] stage=where-cl start
where cl
set "where_exit=%errorlevel%"
echo [native-uia] stage=where-cl exit=%where_exit%
if not "%where_exit%"=="0" exit /b %where_exit%
echo [native-uia] stage=compile start
cl /nologo /EHsc /std:c++17 /Fe:uia-native.exe "$test" "$provider" oleaut32.lib uiautomationcore.lib user32.lib
set "compile_exit=%errorlevel%"
echo [native-uia] stage=compile exit=%compile_exit%
if not "%compile_exit%"=="0" exit /b %compile_exit%
echo [native-uia] stage=test-exe start
.\uia-native.exe
set "test_exit=%errorlevel%"
echo [native-uia] stage=test-exe exit=%test_exit%
exit /b %test_exit%
"@
  $commandPath = Join-Path $scratch "run-native.cmd"
  [IO.File]::WriteAllText($commandPath, $command, [Text.Encoding]::Default)
  & $env:ComSpec /d /s /c "`"$commandPath`""
  $nativeExit = $LASTEXITCODE
  Write-Host "[native-uia] cmd exit=$nativeExit"
  if ($nativeExit -ne 0) { throw "Native accessibility provider tests failed: $nativeExit (see [native-uia] stage exits above)" }
} finally {
  $env:TEMP = $savedTemp
  $env:TMP = $savedTmp
  $env:PATH = $savedPath
  # The just-built test executable and compiler outputs can stay locked briefly
  # (for example by an antivirus scan) after the process exits. Cleanup must not
  # turn a passing run into a failure, so retry and then only warn.
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
