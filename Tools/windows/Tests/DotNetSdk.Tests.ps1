$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Import-PinnedPester.ps1')

BeforeAll {
  $script:repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
  . (Join-Path $repositoryRoot 'Tools\windows\DotNetSdk.ps1')
  function New-DotNetTestFixture {
    $script:caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $script:fixtureRepo = Join-Path $caseRoot 'repo'
    $script:toolRoot = Join-Path $caseRoot 'tools'
    $script:sdkRoot = Join-Path $caseRoot 'installed'
    $script:exe = Join-Path $sdkRoot 'dotnet.exe'
    $script:propsPath = Join-Path $sdkRoot 'sdk\10.0.403\Microsoft.NETCoreSdk.BundledVersions.props'
    $files = @('dotnet.exe', 'sdk\10.0.403\MSBuild.dll',
      'packs\Microsoft.NETCore.App.Ref\10.0.14\ref\net10.0\System.Runtime.dll',
      'packs\Microsoft.WindowsDesktop.App.Ref\10.0.14\ref\net10.0\UIAutomationClient.dll',
      'packs\Microsoft.WindowsDesktop.App.Ref\10.0.14\ref\net10.0\UIAutomationTypes.dll',
      'packs\Microsoft.WindowsDesktop.App.Ref\10.0.14\ref\net10.0\WindowsBase.dll',
      'shared\Microsoft.NETCore.App\10.0.14\coreclr.dll',
      'shared\Microsoft.WindowsDesktop.App\10.0.14\PresentationCore.dll')
    foreach ($file in $files) {
      $path = Join-Path $sdkRoot $file
      $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
      [IO.File]::WriteAllText($path, 'deliberate test input; never executed')
    }
    [IO.File]::WriteAllText($propsPath, @'
<Project><PropertyGroup><NETCoreSdkVersion>10.0.403</NETCoreSdkVersion></PropertyGroup><ItemGroup>
<KnownFrameworkReference Include="Microsoft.NETCore.App" TargetFramework="net10.0" TargetingPackName="Microsoft.NETCore.App.Ref" TargetingPackVersion="10.0.14" />
<KnownFrameworkReference Include="Microsoft.WindowsDesktop.App" TargetFramework="net10.0" TargetingPackName="Microsoft.WindowsDesktop.App.Ref" TargetingPackVersion="10.0.14" />
</ItemGroup></Project>
'@)
    $runner = Join-Path $fixtureRepo 'Tools\windows\ValidationRunner'
    $null = [IO.Directory]::CreateDirectory($runner)
    [IO.File]::WriteAllText((Join-Path $runner 'global.json'),
      '{"sdk":{"version":"10.0.403","rollForward":"disable","allowPrerelease":false}}')
    $script:runtimeOutput = @("Microsoft.NETCore.App 10.0.14 [$sdkRoot\shared\Microsoft.NETCore.App]",
      "Microsoft.WindowsDesktop.App 10.0.14 [$sdkRoot\shared\Microsoft.WindowsDesktop.App]")
  }
}

Describe 'Pinned .NET prerequisite production wiring' {
  It 'resolves the SDK during the existing bootstrap and exports its executable' {
    $text = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'Tools\windows\bootstrap.ps1'))
    $text | Should -Match 'Resolve-GraphCodeDotNetSdk'
    $text | Should -Match 'GRAPHCODE_DOTNET10403'
  }
  It 'uses the shared SDK resolver in the actual compiled build wrapper' {
    $text = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'Tools\windows\Build-CompiledValidationRunner.ps1'))
    $text | Should -Match 'Resolve-GraphCodeDotNetSdk'
    $text | Should -Match 'GRAPHCODE_DOTNET10403'
    $text | Should -Match 'DOTNET_ROOT'
  }
  It 'documents the pinned SDK in the Windows contributor prerequisites' {
    $text = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'graphcode-windows\README.md'))
    $start = $text.IndexOf('## Windows contributor quick start', [StringComparison]::Ordinal)
    $text.Substring($start, [Math]::Min(6000, $text.Length - $start)) | Should -Match '\.NET SDK.*10\.0\.403'
  }
}

Describe 'Exact SDK discovery and prerequisite probes' {
  BeforeEach {
    New-DotNetTestFixture
    $script:savedEnvironment = [Environment]::GetEnvironmentVariables('Process')
    if ([Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_DOTNET10403')) {
      Remove-Item -LiteralPath Env:\GRAPHCODE_DOTNET10403
    }
    Mock Get-GraphCodeDotNetCandidates { @($exe) }
    Mock Install-GraphCodeDotNetSdk { throw 'Unexpected installation' }
    Mock Invoke-RestMethod { throw 'Unexpected network' }
    Mock Invoke-GraphCodeDotNetCommand {
      if ($Arguments[0] -ceq '--version') { return [pscustomobject]@{ ExitCode=0; Output=@('10.0.403') } }
      [pscustomobject]@{ ExitCode=0; Output=$runtimeOutput }
    }
  }
  AfterEach {
    foreach ($name in @('GRAPHCODE_DOTNET10403','DOTNET_ROOT','DOTNET_CLI_HOME','DOTNET_ROLL_FORWARD','TEMP','TMP',
        'GRAPHCODE_ZIG0152','GRAPHCODE_ZIG0160','GRAPHCODE_WINGHOSTTY_ROOT','GRAPHCODE_ZMX_ROOT','GITHUB_ENV')) {
      if ($savedEnvironment.Contains($name)) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
      } elseif ([Environment]::GetEnvironmentVariables('Process').Contains($name)) {
        Remove-Item -LiteralPath "Env:\$name"
      }
    }
  }
  It 'reuses a verified installed exact SDK without installing or fetching metadata' {
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot -InstallIfMissing | Should -BeExactly $exe
    Should -Invoke Install-GraphCodeDotNetSdk -Times 0
    Should -Invoke Invoke-RestMethod -Times 0
  }
  It 'prefers the explicitly exported full executable and bypasses discovery' {
    $env:GRAPHCODE_DOTNET10403 = $exe
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot | Should -BeExactly $exe
    Should -Invoke Get-GraphCodeDotNetCandidates -Times 0
  }
  It 'rejects an explicitly empty override instead of treating it as absent' {
    [Environment]::SetEnvironmentVariable('GRAPHCODE_DOTNET10403', '', 'Process')
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*explicitly empty*'
  }
  It 'rejects an invalid explicit override without falling back to another executable' {
    $env:GRAPHCODE_DOTNET10403 = Join-Path $TestDrive 'missing.exe'
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot -InstallIfMissing } | Should -Throw '*GRAPHCODE_DOTNET10403 is invalid*'
    Should -Invoke Get-GraphCodeDotNetCandidates -Times 0
    Should -Invoke Install-GraphCodeDotNetSdk -Times 0
  }
  It 'resolves global.json from the actual validator directory, never a project argument' {
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot | Should -BeExactly $exe
    Should -Invoke Invoke-GraphCodeDotNetCommand -Times 1 -ParameterFilter {
      $WorkingDirectory -ceq (Join-Path $fixtureRepo 'Tools\windows\ValidationRunner') -and
      $Arguments.Count -eq 1 -and $Arguments[0] -ceq '--version'
    }
  }
  It 'does not accept an SDK version fallback even when the host exits successfully' {
    Mock Invoke-GraphCodeDotNetCommand { [pscustomobject]@{ ExitCode=0; Output=@('10.0.404') } }
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*did not select 10.0.403*'
    Should -Invoke Install-GraphCodeDotNetSdk -Times 0
  }
  It 'rejects a failing exact SDK command and preserves actionable diagnostics' {
    Mock Invoke-GraphCodeDotNetCommand { [pscustomobject]@{ ExitCode=145; Output=@('SDK selection failed') } }
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*SDK selection failed*'
  }
  It 'rejects missing WindowsDesktop runtime rather than admitting compile-only evidence' {
    $script:runtimeOutput = @($runtimeOutput[0])
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*Microsoft.WindowsDesktop.App 10.0 runtime*'
  }
  It 'rejects empty runtime enumeration instead of passing vacuously' {
    $script:runtimeOutput = @()
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*Missing usable Microsoft.NETCore.App*'
  }
  It 'rejects a runtime reported from another installation root' {
    $script:runtimeOutput = @("Microsoft.NETCore.App 10.0.14 [C:\foreign\shared\Microsoft.NETCore.App]",
      $runtimeOutput[1])
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*Missing usable Microsoft.NETCore.App*'
  }
  It 'requires the exact SDK-declared reference-pack version' {
    Remove-Item -LiteralPath (Join-Path $sdkRoot 'packs\Microsoft.WindowsDesktop.App.Ref\10.0.14\ref\net10.0\UIAutomationTypes.dll')
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*Missing Microsoft.WindowsDesktop.App reference input*'
  }
  It 'restores environment membership and empty values after successful probes' {
    $names=@('DOTNET_ROOT','DOTNET_CLI_HOME','TEMP','TMP','DOTNET_ROLL_FORWARD')
    $before=[Environment]::GetEnvironmentVariables('Process')
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot | Should -BeExactly $exe
    $after=[Environment]::GetEnvironmentVariables('Process')
    foreach($name in $names) {
      $after.Contains($name) | Should -Be $before.Contains($name)
      if($before.Contains($name)) { $after[$name] | Should -BeExactly $before[$name] }
    }
  }
  It 'restores process environment when a native probe throws, without alternate downloads' {
    $before=[Environment]::GetEnvironmentVariables('Process')
    Mock Invoke-GraphCodeDotNetCommand { throw [IO.IOException]::new('controlled probe error') }
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot -InstallIfMissing } | Should -Throw '*controlled probe error*'
    $after=[Environment]::GetEnvironmentVariables('Process')
    foreach($name in @('DOTNET_ROOT','TEMP','TMP','DOTNET_CLI_HOME')) {
      $after.Contains($name) | Should -Be $before.Contains($name)
      if($before.Contains($name)) { $after[$name] | Should -BeExactly $before[$name] }
    }
    Should -Invoke Install-GraphCodeDotNetSdk -Times 0
  }
  It 'fails actionably when no exact SDK exists and installation was not requested' {
    Mock Get-GraphCodeDotNetCandidates { @() }
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*Run Tools\windows\bootstrap.ps1*'
    Should -Invoke Install-GraphCodeDotNetSdk -Times 0
  }
  It 'routes missing prerequisites through the repository private installer only when requested' {
    Mock Get-GraphCodeDotNetCandidates { @() }
    Mock Install-GraphCodeDotNetSdk { Join-Path $ToolRoot "dotnet\$Version\dotnet.exe" }
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot -InstallIfMissing |
      Should -BeExactly (Join-Path $toolRoot 'dotnet\10.0.403\dotnet.exe')
    Should -Invoke Install-GraphCodeDotNetSdk -Times 1 -ParameterFilter { $Version -ceq '10.0.403' }
  }
  It 'keeps the pin as the single source of truth and rejects roll-forward' {
    $path=Join-Path $fixtureRepo 'Tools\windows\ValidationRunner\global.json'
    [IO.File]::WriteAllText($path,'{"sdk":{"version":"10.0.403","rollForward":"latestPatch","allowPrerelease":false}}')
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*Invalid release SDK pin*'
  }
  It 'restores an absent environment variable as absent rather than present-empty' {
    if ([Environment]::GetEnvironmentVariables('Process').Contains('DOTNET_ROOT')) { Remove-Item Env:\DOTNET_ROOT }
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot | Should -BeExactly $exe
    [Environment]::GetEnvironmentVariables('Process').Contains('DOTNET_ROOT') | Should -BeFalse
  }
  It 'preserves a genuinely empty environment value across the probe' {
    [Environment]::SetEnvironmentVariable('DOTNET_ROLL_FORWARD', '', 'Process')
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot | Should -BeExactly $exe
    $after=[Environment]::GetEnvironmentVariables('Process')
    $after.Contains('DOTNET_ROLL_FORWARD') | Should -BeTrue
    $after['DOTNET_ROLL_FORWARD'] | Should -BeExactly ''
  }
  It 'rejects a string-valued prerelease flag instead of coercing it' {
    [IO.File]::WriteAllText((Join-Path $fixtureRepo 'Tools\windows\ValidationRunner\global.json'),
      '{"sdk":{"version":"10.0.403","rollForward":"disable","allowPrerelease":"false"}}')
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*Invalid release SDK pin*'
  }
  It 'reads the version from global.json rather than returning a baked-in SDK version' {
    [IO.File]::WriteAllText((Join-Path $fixtureRepo 'Tools\windows\ValidationRunner\global.json'),
      '{"sdk":{"version":"10.0.404","rollForward":"disable","allowPrerelease":false}}')
    Get-GraphCodeDotNetPin $fixtureRepo | Should -BeExactly '10.0.404'
    { Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot } | Should -Throw '*SDK 10.0.404 inputs are missing*'
  }
  It 'reuses a private exact SDK without installing or consulting remote metadata' {
    $private=Join-Path $toolRoot 'dotnet\10.0.403'
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($private))
    [IO.Directory]::Move($sdkRoot,$private)
    $script:sdkRoot=$private
    $script:exe=Join-Path $private 'dotnet.exe'
    $script:runtimeOutput=@("Microsoft.NETCore.App 10.0.14 [$private\shared\Microsoft.NETCore.App]",
      "Microsoft.WindowsDesktop.App 10.0.14 [$private\shared\Microsoft.WindowsDesktop.App]")
    $env:GRAPHCODE_DOTNET10403=$exe
    Resolve-GraphCodeDotNetSdk $fixtureRepo $toolRoot -InstallIfMissing | Should -BeExactly $exe
    Should -Invoke Install-GraphCodeDotNetSdk -Times 0
    Should -Invoke Invoke-RestMethod -Times 0
  }
  It 'runs the actual bootstrap SDK assignment and environment producers without provider installation' {
    $bootstrapAst=[Management.Automation.Language.Parser]::ParseFile(
      (Join-Path $repositoryRoot 'Tools\windows\bootstrap.ps1'),[ref]$null,[ref]$null)
    $sdkAssignment=@($bootstrapAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$dotnet'
    },$true))
    $valuesAssignment=@($bootstrapAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$values'
    },$true))
    $exportLoop=@($bootstrapAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.ForEachStatementAst] -and
        $node.Variable.VariablePath.UserPath -ceq 'entry' -and
        $node.Condition.Extent.Text -ceq '$values.GetEnumerator()'
    },$true))
    $environmentWriter=@($bootstrapAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.PipelineAst] -and
        $node.Extent.Text.Contains('Set-Content -LiteralPath $environmentScript')
    },$true))
    $sdkAssignment.Count | Should -Be 1
    $valuesAssignment.Count | Should -Be 1
    $exportLoop.Count | Should -Be 1
    $environmentWriter.Count | Should -Be 1
    $setters=@($exportLoop[0].FindAll({
      param($node)
      $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -ceq 'SetEnvironmentVariable'
    },$true))
    $setters.Count | Should -Be 1
    $setters[0].Arguments.Count | Should -Be 2
    $repoRoot=$fixtureRepo
    $ToolRoot=$script:toolRoot
    $zig0152='fixture-zig0152';$zig0160='fixture-zig0160';$winghosttyRoot='fixture-winghostty';$zmxRoot='fixture-zmx'
    $environmentScript=Join-Path $caseRoot 'environment.ps1'
    $env:GITHUB_ENV=Join-Path $caseRoot 'github.env'
    . ([scriptblock]::Create($sdkAssignment[0].Extent.Text))
    . ([scriptblock]::Create($valuesAssignment[0].Extent.Text))
    . ([scriptblock]::Create($exportLoop[0].Extent.Text))
    . ([scriptblock]::Create($environmentWriter[0].Extent.Text))
    $env:GRAPHCODE_DOTNET10403 | Should -BeExactly $exe
    $env:DOTNET_ROOT | Should -BeExactly $sdkRoot
    $text=[IO.File]::ReadAllText($environmentScript)
    $text | Should -Match ('\$env:GRAPHCODE_DOTNET10403 = ' + [regex]::Escape("'$exe'"))
    $text | Should -Match ('\$env:DOTNET_ROOT = ' + [regex]::Escape("'$sdkRoot'"))
    [IO.File]::ReadAllText($env:GITHUB_ENV) | Should -Match ([regex]::Escape("GRAPHCODE_DOTNET10403=$exe"))
    Should -Invoke Install-GraphCodeDotNetSdk -Times 0
    Should -Invoke Invoke-RestMethod -Times 0
  }
}

Describe 'Official private SDK acquisition' {
  BeforeEach {
    New-DotNetTestFixture
    $rid = if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ceq 'Arm64') {'win-arm64'} else {'win-x64'}
    $script:metadataSdk=[pscustomobject]@{version='10.0.403';files=@([pscustomobject]@{
      name="dotnet-sdk-$rid.zip";rid=$rid;url="https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.403/dotnet-sdk-10.0.403-$rid.zip";hash=('A'*128)})}
    Mock Invoke-RestMethod { [pscustomobject]@{releases=@([pscustomobject]@{sdks=@($metadataSdk);sdk=$metadataSdk})} }
  }
  It 'selects the exact official version and deduplicates identical sdk/sdks metadata' {
    $asset=Get-GraphCodeDotNetAsset '10.0.403'
    $asset.Sha512 | Should -BeExactly ('A'*128)
    $asset.Uri.Host | Should -BeExactly 'builds.dotnet.microsoft.com'
    Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $TimeoutSec -eq 60 -and $MaximumRedirection -eq 0 }
  }
  It 'does not substitute a newer release when the requested SDK is absent' {
    $metadataSdk.version='10.0.404'
    { Get-GraphCodeDotNetAsset '10.0.403' } | Should -Throw '*exactly one SDK 10.0.403*found 0*'
  }
  It 'rejects missing or malformed checksums' {
    $metadataSdk.files[0].hash='not-a-sha512'
    { Get-GraphCodeDotNetAsset '10.0.403' } | Should -Throw '*valid SHA-512*'
  }
  It 'rejects non-Microsoft metadata URLs before downloading' {
    $metadataSdk.files[0].url='https://example.invalid/sdk.zip'
    { Get-GraphCodeDotNetAsset '10.0.403' } | Should -Throw '*non-official ZIP URL*'
  }
  It 'rejects conflicting exact-version assets rather than picking the first' {
    $other=[pscustomobject]@{name=$metadataSdk.files[0].name;rid=$metadataSdk.files[0].rid;url='https://builds.dotnet.microsoft.com/other.zip';hash=('B'*128)}
    $metadataSdk.files += $other
    { Get-GraphCodeDotNetAsset '10.0.403' } | Should -Throw '*found 2*'
  }
}

Describe 'Private SDK integrity and atomic publication' {
  BeforeEach {
    New-DotNetTestFixture
    $script:archiveSource=Join-Path $caseRoot 'source.zip'
    $zip=[IO.Compression.ZipFile]::Open($archiveSource,[IO.Compression.ZipArchiveMode]::Create)
    try { $entry=$zip.CreateEntry('dotnet.exe');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('fixture only')}finally{$writer.Dispose()} } finally {$zip.Dispose()}
    $script:archiveHash=(Get-FileHash -LiteralPath $archiveSource -Algorithm SHA512).Hash
    Mock Get-GraphCodeDotNetAsset { [pscustomobject]@{Uri=[uri]'https://builds.dotnet.microsoft.com/sdk.zip';Sha512=$archiveHash} }
    Mock Invoke-WebRequest { Copy-Item -LiteralPath $archiveSource -Destination $OutFile }
    Mock Expand-Archive {
      $null=[IO.Directory]::CreateDirectory($DestinationPath)
      [IO.File]::WriteAllText((Join-Path $DestinationPath 'dotnet.exe'),'fixture only; not executed')
    }
    Mock Get-GraphCodeDotNetSdkProbe { [pscustomobject]@{Valid=$true;Reason='';Executable=$Executable} }
  }
  It 'verifies checksum before extraction and publishes only a verified staged SDK' {
    $result=Install-GraphCodeDotNetSdk $fixtureRepo $toolRoot '10.0.403'
    $result | Should -BeExactly (Join-Path $toolRoot 'dotnet\10.0.403\dotnet.exe')
    Test-Path -LiteralPath $result -PathType Leaf | Should -BeTrue
    Should -Invoke Expand-Archive -Times 1
    Should -Invoke Get-GraphCodeDotNetSdkProbe -Times 1 -ParameterFilter { $Version -ceq '10.0.403' -and $Executable -like '*payload\dotnet.exe' }
    @(Get-ChildItem (Join-Path $toolRoot 'dotnet') -Directory | Where-Object Name -Like '.install-*').Count | Should -Be 0
  }
  It 'never extracts a checksum-mismatched archive' {
    $script:archiveHash='0'*128
    { Install-GraphCodeDotNetSdk $fixtureRepo $toolRoot '10.0.403' } | Should -Throw '*SHA-512 checksum mismatch*'
    Should -Invoke Expand-Archive -Times 0
    Test-Path (Join-Path $toolRoot 'dotnet\10.0.403') | Should -BeFalse
  }
  It 'surfaces download failure and leaves no published SDK' {
    Mock Invoke-WebRequest { throw [IO.IOException]::new('controlled download failure') }
    { Install-GraphCodeDotNetSdk $fixtureRepo $toolRoot '10.0.403' } | Should -Throw '*controlled download failure*'
    Should -Invoke Expand-Archive -Times 0
  }
  It 'rejects a downloaded payload with missing runtime/reference inputs before publication' {
    Mock Get-GraphCodeDotNetSdkProbe { [pscustomobject]@{Valid=$false;Reason='missing WindowsDesktop runtime';Executable=$Executable} }
    { Install-GraphCodeDotNetSdk $fixtureRepo $toolRoot '10.0.403' } | Should -Throw '*Downloaded SDK failed verification*'
    Test-Path (Join-Path $toolRoot 'dotnet\10.0.403') | Should -BeFalse
  }
  It 'preserves an existing private directory instead of overwriting unknown contents' {
    $directory=Join-Path $toolRoot 'dotnet\10.0.403';$null=[IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'preserve.txt'),'owned elsewhere')
    { Install-GraphCodeDotNetSdk $fixtureRepo $toolRoot '10.0.403' } | Should -Throw '*already exists but was not verified*'
    [IO.File]::ReadAllText((Join-Path $directory 'preserve.txt')) | Should -BeExactly 'owned elsewhere'
    Should -Invoke Invoke-WebRequest -Times 0
  }
  It 'rejects traversal entries before extraction even if the archive hash matches' {
    Remove-Item -LiteralPath $archiveSource
    $zip=[IO.Compression.ZipFile]::Open($archiveSource,[IO.Compression.ZipArchiveMode]::Create)
    try {$null=$zip.CreateEntry('../outside.exe')} finally {$zip.Dispose()}
    $script:archiveHash=(Get-FileHash -LiteralPath $archiveSource -Algorithm SHA512).Hash
    { Install-GraphCodeDotNetSdk $fixtureRepo $toolRoot '10.0.403' } | Should -Throw '*unsafe archive entry*'
    Should -Invoke Expand-Archive -Times 0
  }
}

Describe 'Installed exact SDK live prerequisite probe' {
  It 'verifies this machine without installing dependencies or changing process environment' {
    $before=[Environment]::GetEnvironmentVariables('Process')
    $exe=(Get-Command dotnet -CommandType Application -ErrorAction Stop).Source
    $result=Get-GraphCodeDotNetSdkProbe $exe $repositoryRoot (Join-Path $TestDrive 'actual-probe') (Get-GraphCodeDotNetPin $repositoryRoot)
    $result.Valid | Should -BeTrue -Because $result.Reason
    $result.Executable | Should -BeExactly $exe
    $after=[Environment]::GetEnvironmentVariables('Process')
    foreach($name in @('DOTNET_ROOT','DOTNET_CLI_HOME','TEMP','TMP','DOTNET_ROLL_FORWARD')) {
      $after.Contains($name) | Should -Be $before.Contains($name)
      if($before.Contains($name)){$after[$name]|Should -BeExactly $before[$name]}
    }
  }
}
