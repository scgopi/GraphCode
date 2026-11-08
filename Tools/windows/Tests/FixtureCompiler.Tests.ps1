[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\FixtureCompiler.ps1')
if (Test-Path -LiteralPath $ScratchRoot) { throw 'Fresh scratch directory required.' }
$null = New-Item -ItemType Directory -Path $ScratchRoot
$installation = Join-Path $ScratchRoot 'VS'
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$versionFile = Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
$compiler = Join-Path $installation 'VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\cl.exe'
$sdk = Join-Path $ScratchRoot 'SDK'
foreach ($path in @($vcvars,$versionFile,$compiler,
    (Join-Path $sdk 'Include\10.0.26100.0\um\Windows.h'),
    (Join-Path $sdk 'Include\10.0.26100.0\ucrt\stdio.h'),
    (Join-Path $sdk 'Lib\10.0.26100.0\um\x64\kernel32.lib'),
    (Join-Path $sdk 'Lib\10.0.26100.0\ucrt\x64\ucrt.lib'))) {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, 'controlled fixture, never executed')
}
[IO.File]::WriteAllText($versionFile, '14.51.36231')
$inputFile = Join-Path $ScratchRoot 'compiler.json'
$inputRecord = [ordered]@{
    schemaVersion = 1; installationPath = $installation; msvcVersion = '14.51.36231'
    compilerSha256 = (Get-FileHash $compiler).Hash; vcvarsSha256 = (Get-FileHash $vcvars).Hash
    sdkRoot = $sdk; sdkVersion = '10.0.26100.0'
}
function Write-Input { [IO.File]::WriteAllText($inputFile, ($inputRecord | ConvertTo-Json)); return (Get-FileHash $inputFile).Hash }
function Invoke-CapBoundedChild { throw 'Discovery must not execute for an explicit input.' }
$results = [Collections.Generic.List[object]]::new()
function Test-Case([string]$CaseName, [scriptblock]$Action) {
    try { & $Action; $results.Add(@{ name=$CaseName; passed=$true }) }
    catch { $results.Add(@{ name=$CaseName; passed=$false; error=$_.Exception.Message }); Write-Host "FAIL $CaseName : $($_.Exception.Message)" }
}
function Assert-True([bool]$Value) { if (-not $Value) { throw 'Assertion failed.' } }
function Assert-Refused([scriptblock]$Action) {
    $refused = $false
    try { & $Action } catch { if ($_.Exception.Message -notlike 'FixtureCompilerInput:*') { throw }; $refused = $true }
    Assert-True $refused
}
Test-Case 'explicit input selects verified tools without discovery' {
    $selection = Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused'
    Assert-True ($selection.mode -ceq 'explicit' -and $selection.compiler -ceq $compiler -and
        $selection.vcvars -ceq $vcvars -and $selection.sdkVersion -ceq '10.0.26100.0')
}
Test-Case 'path requires hash' { Assert-Refused { Resolve-CapFixtureCompiler $inputFile '' $ScratchRoot 'unused' } }
Test-Case 'hash requires path' { Assert-Refused { Resolve-CapFixtureCompiler '' ('A'*64) $ScratchRoot 'unused' } }
Test-Case 'wrong input digest refused' { Assert-Refused { Resolve-CapFixtureCompiler $inputFile ('A'*64) $ScratchRoot 'unused' } }
Test-Case 'changed compiler refused' {
    $hash = Write-Input
    [IO.File]::AppendAllText($compiler, 'changed')
    try { Assert-Refused { Resolve-CapFixtureCompiler $inputFile $hash $ScratchRoot 'unused' } }
    finally { [IO.File]::WriteAllText($compiler, 'controlled fixture, never executed') }
}
Test-Case 'changed vcvars refused' {
    $hash = Write-Input
    [IO.File]::AppendAllText($vcvars, 'changed')
    try { Assert-Refused { Resolve-CapFixtureCompiler $inputFile $hash $ScratchRoot 'unused' } }
    finally { [IO.File]::WriteAllText($vcvars, 'controlled fixture, never executed') }
}
foreach ($field in @('msvcVersion','sdkVersion','installationPath','sdkRoot','schemaVersion')) {
    Test-Case "invalid $field refused" {
        $original = $inputRecord[$field]
        $inputRecord[$field] = if ($field -ceq 'schemaVersion') { 2 } else { 'bad%input' }
        try { Assert-Refused { Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused' } }
        finally { $inputRecord[$field] = $original }
    }
}
Test-Case 'missing SDK library refused' {
    $path = Join-Path $sdk 'Lib\10.0.26100.0\um\x64\kernel32.lib'
    [IO.File]::Move($path, "$path.saved")
    try { Assert-Refused { Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused' } }
    finally { [IO.File]::Move("$path.saved", $path) }
}
Test-Case 'default discovery retains bounded child and role' {
    function Invoke-CapBoundedChild {
        param($FilePath,$Arguments,$Directory,$Role)
        Assert-True ($FilePath -like '*\vswhere.exe' -and $Arguments.Count -eq 7 -and $Role -ceq 'default-role')
        return @{ exitCode=0; stdout=$installation }
    }
    $selection = Resolve-CapFixtureCompiler '' '' $ScratchRoot 'default-role'
    Assert-True ($selection.mode -ceq 'discovery' -and $selection.compiler -ceq $compiler)
}
function New-EnvironmentText {
    return @(
        'VCToolsVersion=14.51.36231'
        "VCToolsInstallDir=$installation\VC\Tools\MSVC\14.51.36231\"
        "WindowsSdkDir=$sdk\"
        'WindowsSDKVersion=10.0.26100.0\'
        "INCLUDE=$installation\VC\Tools\MSVC\14.51.36231\include;$sdk\Include\10.0.26100.0\um;$sdk\Include\10.0.26100.0\ucrt"
        "LIB=$installation\VC\Tools\MSVC\14.51.36231\lib\x64;$sdk\Lib\10.0.26100.0\um\x64;$sdk\Lib\10.0.26100.0\ucrt\x64"
    ) -join "`r`n"
}
Test-Case 'actual compiler SDK include and library observations accepted' {
    $selection = Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused'
    Assert-CapFixtureCompilerEnvironment $selection (New-EnvironmentText)
}
Test-Case 'vcvars equivalent repeated path separators accepted' {
    $selection = Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused'
    $text = (New-EnvironmentText).Replace("$sdk\Include", "$sdk\\Include").Replace("$sdk\Lib", "$sdk\\Lib")
    Assert-CapFixtureCompilerEnvironment $selection $text
}
foreach ($name in @('VCToolsVersion','VCToolsInstallDir','WindowsSdkDir','WindowsSDKVersion','INCLUDE','LIB')) {
    Test-Case "actual $name mismatch refused" {
        $selection = Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused'
        $text = (New-EnvironmentText) -replace "(?m)^$name=.*$", "$name=wrong"
        Assert-Refused { Assert-CapFixtureCompilerEnvironment $selection $text }
    }
}
Test-Case 'missing environment observation refused' {
    $selection = Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused'
    Assert-Refused { Assert-CapFixtureCompilerEnvironment $selection '' }
}
Test-Case 'duplicate environment observation refused' {
    $selection = Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused'
    Assert-Refused { Assert-CapFixtureCompilerEnvironment $selection ((New-EnvironmentText) + "`nLIB=wrong") }
}
foreach ($name in @('INCLUDE','LIB')) {
    Test-Case "SDK-only $name without selected MSVC inputs refused" {
        $selection = Resolve-CapFixtureCompiler $inputFile (Write-Input) $ScratchRoot 'unused'
        $toolPath = if ($name -ceq 'INCLUDE') { "$installation\VC\Tools\MSVC\14.51.36231\include;" }
            else { "$installation\VC\Tools\MSVC\14.51.36231\lib\x64;" }
        Assert-Refused { Assert-CapFixtureCompilerEnvironment $selection ((New-EnvironmentText).Replace($toolPath,'')) }
    }
}
Test-Case 'default environment route unchanged' {
    Assert-CapFixtureCompilerEnvironment ([pscustomobject]@{mode='discovery'}) ''
}
Test-Case 'canonical adapter forwards input only to fresh preparation' {
    $adapter = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\ValidationRunner\Adapters\StandaloneSuites.cs'))
    Assert-True ($adapter.Contains('context.FixtureCompilerInput') -and
        $adapter.Contains('["-PrepareFixturesOnly", "-ScratchRoot", prebuilt, .. compilerArguments]') -and
        $adapter.Contains('["-ScratchRoot", suiteRoot, "-PrebuiltFixtureManifest", manifest, "-PrebuiltFixtureManifestSha256", hash]'))
    $entry = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\ValidationRunner\Program.cs'))
    Assert-True ($entry.Contains('case "--fixture-compiler-input":') -and
        $entry.Contains('case "--fixture-compiler-input-sha256":') -and
        $entry.Contains('new ValidationContext(repositoryRoot, artifactRoot, fixtureCompilerInput, fixtureCompilerInputSha256)'))
    $wrapper = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Invoke-ValidationRunnerContract.ps1'))
    Assert-True ($wrapper.Contains('--artifact-root $artifactRoot @compilerArguments'))
}
$passed = @($results | Where-Object passed -EQ $true).Count
$report = @{ suite='FixtureCompiler'; executed=$results.Count; passed=$passed; failed=$results.Count-$passed; skipped=0; cases=@($results); nativeExecution=0 }
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ScratchRoot 'report.json') -Encoding utf8NoBOM
$report | Select-Object suite,executed,passed,failed,skipped | ConvertTo-Json -Compress
if ($results.Count -ne 27 -or $passed -ne $results.Count) { exit 1 }
