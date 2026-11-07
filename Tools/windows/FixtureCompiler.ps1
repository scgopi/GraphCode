function Resolve-CapFixtureCompiler {
    param([string]$InputPath, [string]$InputSha256, [string]$Directory, [string]$Role)

    if ($InputPath -or $InputSha256) {
        if (-not $InputPath -or $InputSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
            -not [IO.Path]::IsPathFullyQualified($InputPath) -or
            -not [IO.File]::Exists($InputPath)) {
            throw 'FixtureCompilerInput: an absolute existing JSON path and uppercase SHA256 are required together.'
        }
        $bytes = [IO.File]::ReadAllBytes($InputPath)
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $InputSha256) {
            throw 'FixtureCompilerInput: input digest differs.'
        }
        try { $inputRecord = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'FixtureCompilerInput: invalid JSON.' }
        $fields = @('schemaVersion','installationPath','msvcVersion','compilerSha256','vcvarsSha256','sdkRoot','sdkVersion')
        if ($inputRecord -isnot [pscustomobject] -or
            @($inputRecord.PSObject.Properties).Count -ne $fields.Count -or
            @($fields | Where-Object { $_ -cnotin $inputRecord.PSObject.Properties.Name }).Count -ne 0) {
            throw 'FixtureCompilerInput: exact schema fields are required.'
        }
        if ($inputRecord.schemaVersion -isnot [long] -and $inputRecord.schemaVersion -isnot [int]) {
            throw 'FixtureCompilerInput: schemaVersion must be an integer.'
        }
        if ($inputRecord.schemaVersion -ne 1 -or $inputRecord.msvcVersion -cnotmatch '\A\d+\.\d+\.\d+\z' -or
            $inputRecord.sdkVersion -cnotmatch '\A\d+\.\d+\.\d+\.\d+\z') {
            throw 'FixtureCompilerInput: unsupported schema or tool version.'
        }
        foreach ($field in $fields | Where-Object { $_ -cne 'schemaVersion' }) {
            if ($inputRecord.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($inputRecord.$field)) {
                throw "FixtureCompilerInput: $field must be a nonempty string."
            }
        }
        foreach ($field in @('installationPath','sdkRoot')) {
            $path = $inputRecord.$field
            if (-not [IO.Path]::IsPathFullyQualified($path) -or $path -match '[\r\n"%!&|<>^]' -or
                -not [IO.Directory]::Exists($path)) {
                throw "FixtureCompilerInput: $field must be an existing batch-safe absolute directory."
            }
        }
        $installation = [IO.Path]::GetFullPath($inputRecord.installationPath)
        $version = $inputRecord.msvcVersion
        $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
        $compiler = Join-Path $installation "VC\Tools\MSVC\$version\bin\Hostx64\x64\cl.exe"
        foreach ($pair in @(@($compiler,'compilerSha256'),@($vcvars,'vcvarsSha256'))) {
            if ($inputRecord.($pair[1]) -cnotmatch '\A[A-F0-9]{64}\z' -or -not [IO.File]::Exists($pair[0]) -or
                (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -cne $inputRecord.($pair[1])) {
                throw "FixtureCompilerInput: $($pair[1]) does not bind the actual selected file."
            }
        }
        foreach ($relative in @("Include\$($inputRecord.sdkVersion)\um\Windows.h",
            "Include\$($inputRecord.sdkVersion)\ucrt\stdio.h",
            "Lib\$($inputRecord.sdkVersion)\um\x64\kernel32.lib",
            "Lib\$($inputRecord.sdkVersion)\ucrt\x64\ucrt.lib")) {
            if (-not [IO.File]::Exists((Join-Path $inputRecord.sdkRoot $relative))) {
                throw "FixtureCompilerInput: required SDK input is missing: $relative"
            }
        }
        return [pscustomobject]@{
            mode = 'explicit'; inputPath = [IO.Path]::GetFullPath($InputPath); inputSha256 = $InputSha256
            installationPath = $installation; msvcVersion = $version; sdkVersion = $inputRecord.sdkVersion
            sdkRoot = [IO.Path]::GetFullPath($inputRecord.sdkRoot); vcvars = $vcvars; compiler = $compiler
            compilerSha256 = $inputRecord.compilerSha256; vcvarsSha256 = $inputRecord.vcvarsSha256
            discoveryDirectory = Join-Path $installation '..\..\Installer'
        }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'Existing MSVC discovery is unavailable; this offline suite does not install a compiler.'
    }
    $discovery = Invoke-CapBoundedChild -FilePath $vswhere -Arguments @(
        '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath'
    ) -Directory $Directory -Role $Role
    if ($discovery.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($discovery.stdout)) {
        throw 'Existing MSVC was not found.'
    }
    $installation = $discovery.stdout.Trim()
    $version = [IO.File]::ReadAllText((Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt')).Trim()
    return [pscustomobject]@{
        mode = 'discovery'; inputPath = $null; inputSha256 = $null
        installationPath = $installation; msvcVersion = $version; sdkVersion = $null
        vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
        compiler = Join-Path $installation "VC\Tools\MSVC\$version\bin\Hostx64\x64\cl.exe"
        discoveryDirectory = Split-Path -Parent $vswhere
    }
}

function Assert-CapFixtureCompilerEnvironment {
    param($Selection, [string]$Stdout)
    if ($Selection.mode -cne 'explicit') { return }
    $values = @{}
    foreach ($line in $Stdout -split '\r?\n') {
        if ($line -cmatch '\A(VCToolsVersion|VCToolsInstallDir|WindowsSdkDir|WindowsSDKVersion|INCLUDE|LIB)=(.*)\z') {
            if ($values.ContainsKey($Matches[1])) { throw 'FixtureCompilerInput: duplicate compiler environment observation.' }
            $values[$Matches[1]] = $Matches[2]
        }
    }
    foreach ($name in @('VCToolsVersion','VCToolsInstallDir','WindowsSdkDir','WindowsSDKVersion','INCLUDE','LIB')) {
        if (-not $values.ContainsKey($name)) { throw "FixtureCompilerInput: actual vcvars environment missing $name." }
    }
    if ($values.VCToolsVersion -cne $Selection.msvcVersion -or
        $values.VCToolsInstallDir.TrimEnd('\') -ine (Join-Path $Selection.installationPath "VC\Tools\MSVC\$($Selection.msvcVersion)") -or
        $values.WindowsSdkDir.TrimEnd('\') -ine $Selection.sdkRoot.TrimEnd('\') -or
        $values.WindowsSDKVersion.TrimEnd('\') -cne $Selection.sdkVersion) {
        throw 'FixtureCompilerInput: actual vcvars compiler/SDK selection differs.'
    }
    foreach ($pair in @(@('INCLUDE',(Join-Path $Selection.sdkRoot "Include\$($Selection.sdkVersion)\um")),
        @('INCLUDE',(Join-Path $Selection.sdkRoot "Include\$($Selection.sdkVersion)\ucrt")),
        @('LIB',(Join-Path $Selection.sdkRoot "Lib\$($Selection.sdkVersion)\um\x64")),
        @('LIB',(Join-Path $Selection.sdkRoot "Lib\$($Selection.sdkVersion)\ucrt\x64")),
        @('INCLUDE',(Join-Path $Selection.installationPath "VC\Tools\MSVC\$($Selection.msvcVersion)\include")),
        @('LIB',(Join-Path $Selection.installationPath "VC\Tools\MSVC\$($Selection.msvcVersion)\lib\x64")))) {
        $expected = $pair[1]
        $actualPaths = @($values.($pair[0]) -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
        if ($expected -inotin $actualPaths) {
            throw "FixtureCompilerInput: actual $($pair[0]) does not contain the selected compiler/SDK inputs."
        }
    }
    foreach ($pair in @(@($Selection.compiler,'compilerSha256'),@($Selection.vcvars,'vcvarsSha256'))) {
        if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -cne $Selection.($pair[1])) {
            throw 'FixtureCompilerInput: selected tool bytes changed during compilation.'
        }
    }
}
