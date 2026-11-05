$ErrorActionPreference = 'Stop'

function Get-GraphCodeDotNetPin([string] $RepositoryRoot) {
  $path = Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\global.json'
  $pin = [IO.File]::ReadAllText($path) | ConvertFrom-Json
  if ($pin.sdk.version -isnot [string] -or $pin.sdk.version -notmatch '^10\.0\.\d+$' -or
      $pin.sdk.rollForward -isnot [string] -or $pin.sdk.rollForward -cne 'disable' -or $pin.sdk.allowPrerelease -isnot [bool] -or
      $pin.sdk.allowPrerelease -ne $false) {
    throw "Invalid release SDK pin in $path; an exact 10.0 SDK with rollForward=disable is required"
  }
  return [string]$pin.sdk.version
}

function Invoke-GraphCodeDotNetCommand(
  [string] $Executable, [string] $WorkingDirectory, [string[]] $Arguments
) {
  $PSNativeCommandUseErrorActionPreference = $false
  Push-Location -LiteralPath $WorkingDirectory
  try {
    $output = @(& $Executable @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } finally { Pop-Location }
}

function Get-GraphCodeDotNetSdkProbe(
  [string] $Executable, [string] $RepositoryRoot, [string] $ToolRoot, [string] $Version
) {
  $invalid = { param($reason) [pscustomobject]@{ Valid = $false; Reason = $reason; Executable = $Executable } }
  if (-not [IO.Path]::IsPathFullyQualified($Executable) -or
      -not [IO.File]::Exists($Executable) -or [IO.Path]::GetExtension($Executable) -ine '.exe') {
    return & $invalid "SDK host is not an existing absolute executable: $Executable"
  }
  $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Executable))
  $sdkRoot = Join-Path $root "sdk\$Version"
  $propsPath = Join-Path $sdkRoot 'Microsoft.NETCoreSdk.BundledVersions.props'
  if (-not [IO.File]::Exists((Join-Path $sdkRoot 'MSBuild.dll')) -or -not [IO.File]::Exists($propsPath)) {
    return & $invalid "SDK $Version inputs are missing below $root"
  }
  [xml]$props = [IO.File]::ReadAllText($propsPath)
  $sdkNodes = @($props.SelectNodes("//*[local-name()='NETCoreSdkVersion']"))
  if ($sdkNodes.Count -ne 1 -or $sdkNodes[0].InnerText -cne $Version) {
    return & $invalid "SDK metadata below $root does not declare $Version"
  }
  foreach ($framework in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')) {
    $nodes = @($props.SelectNodes("//*[local-name()='KnownFrameworkReference' and @Include='$framework' and @TargetFramework='net10.0']"))
    if ($nodes.Count -ne 1 -or $nodes[0].TargetingPackVersion -notmatch '^10\.0\.\d+$' -or
        $nodes[0].TargetingPackName -cne "$framework.Ref") {
      return & $invalid "SDK metadata is missing the net10.0 $framework targeting-pack declaration"
    }
    $referenceRoot = Join-Path $root ("packs\{0}\{1}\ref\net10.0" -f $nodes[0].TargetingPackName, $nodes[0].TargetingPackVersion)
    $files = if ($framework -ceq 'Microsoft.NETCore.App') { @('System.Runtime.dll') }
      else { @('UIAutomationClient.dll', 'UIAutomationTypes.dll', 'WindowsBase.dll') }
    foreach ($file in $files) {
      if (-not [IO.File]::Exists((Join-Path $referenceRoot $file))) {
        return & $invalid "Missing $framework reference input: $(Join-Path $referenceRoot $file)"
      }
    }
  }

  $stateRoot = Join-Path $ToolRoot 'dotnet-state'
  $values = @{
    DOTNET_ROOT = $root; DOTNET_MULTILEVEL_LOOKUP = '0'; DOTNET_ROLL_FORWARD = 'LatestPatch'
    DOTNET_CLI_HOME = (Join-Path $stateRoot 'home'); NUGET_PACKAGES = (Join-Path $stateRoot 'nuget')
    TEMP = (Join-Path $stateRoot 'temp'); TMP = (Join-Path $stateRoot 'temp')
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'; DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'; DOTNET_NOLOGO = '1'
  }
  $before = [Environment]::GetEnvironmentVariables('Process')
  try {
    $null = [IO.Directory]::CreateDirectory($values.TEMP)
    foreach ($name in $values.Keys) { [Environment]::SetEnvironmentVariable($name, $values[$name], 'Process') }
    $workingDirectory = Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner'
    $versionProbe = Invoke-GraphCodeDotNetCommand $Executable $workingDirectory @('--version')
    if ($versionProbe.ExitCode -ne 0 -or ($versionProbe.Output -join "`n").Trim() -cne $Version) {
      return & $invalid "SDK pin resolution from $workingDirectory did not select $Version`: $($versionProbe.Output -join '; ')"
    }
    $runtimes = Invoke-GraphCodeDotNetCommand $Executable $workingDirectory @('--list-runtimes')
    if ($runtimes.ExitCode -ne 0) { return & $invalid "Listing runtimes failed for $Executable" }
    foreach ($framework in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')) {
      $runtimeRoot = Join-Path $root "shared\$framework"
      $present = $false
      foreach ($line in $runtimes.Output) {
        if ($line -match ('^' + [regex]::Escape($framework) + ' (10\.0\.\d+) \[(.+)\]$')) {
          $runtimeVersion = $Matches[1]
          if ([IO.Path]::GetFullPath($Matches[2]) -ieq [IO.Path]::GetFullPath($runtimeRoot)) {
            $runtimeFile = if ($framework -ceq 'Microsoft.NETCore.App') { 'coreclr.dll' } else { 'PresentationCore.dll' }
            if ([IO.File]::Exists((Join-Path $runtimeRoot "$runtimeVersion\$runtimeFile"))) { $present = $true }
          }
        }
      }
      if (-not $present) { return & $invalid "Missing usable $framework 10.0 runtime below $root; rerun Tools\windows\bootstrap.ps1" }
    }
    return [pscustomobject]@{ Valid = $true; Reason = ''; Executable = [IO.Path]::GetFullPath($Executable) }
  } finally {
    foreach ($name in $values.Keys) {
      if ($before.Contains($name)) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
      elseif ([Environment]::GetEnvironmentVariables('Process').Contains($name)) {
        Remove-Item -LiteralPath "Env:\$name" -ErrorAction Stop
      }
    }
  }
}

function Get-GraphCodeDotNetCandidates([string] $ToolRoot, [string] $Version) {
  $candidates = [Collections.Generic.List[string]]::new()
  $candidates.Add((Join-Path $ToolRoot "dotnet\$Version\dotnet.exe"))
  foreach ($command in @(Get-Command dotnet -CommandType Application -All -ErrorAction SilentlyContinue)) {
    if ($command.Source) { $candidates.Add($command.Source) }
  }
  foreach ($root in @($env:DOTNET_ROOT, $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'dotnet' }))) {
    if ($root) { $candidates.Add((Join-Path $root 'dotnet.exe')) }
  }
  return @($candidates | Select-Object -Unique)
}

function Get-GraphCodeDotNetAsset([string] $Version) {
  $rid = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
    X64 { 'win-x64' }; Arm64 { 'win-arm64' }
    default { throw 'SDK bootstrap requires a 64-bit Windows host (x64 or Arm64)' }
  }
  $metadata = Invoke-RestMethod -Uri 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/10.0/releases.json' `
    -TimeoutSec 60 -MaximumRedirection 0 -ErrorAction Stop
  $assets = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
  foreach ($release in $metadata.releases) {
    $sdks = @($release.sdks) + @($release.sdk)
    foreach ($sdk in $sdks) {
      if ($null -eq $sdk -or $sdk.version -cne $Version) { continue }
      foreach ($file in $sdk.files) {
        if ($file.rid -cne $rid -or $file.name -cne "dotnet-sdk-$rid.zip") { continue }
        $uri = [uri]$file.url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or
            $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
            $uri.Host -cnotin @('builds.dotnet.microsoft.com', 'dotnetcli.blob.core.windows.net',
              'dotnetcli.azureedge.net', 'download.visualstudio.microsoft.com', 'download.microsoft.com') -or
            -not $uri.AbsolutePath.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
          throw "SDK metadata contains a non-official ZIP URL for $Version"
        }
        if ($file.hash -notmatch '^[0-9A-Fa-f]{128}$') { throw "SDK metadata has no valid SHA-512 checksum for $Version" }
        $key = $uri.AbsoluteUri + ':' + $file.hash.ToUpperInvariant()
        $assets[$key] = [pscustomobject]@{ Uri = $uri; Sha512 = $file.hash.ToUpperInvariant() }
      }
    }
  }
  if ($assets.Count -ne 1) { throw "Official Microsoft metadata must provide exactly one SDK $Version $rid ZIP and SHA-512; found $($assets.Count)" }
  return @($assets.Values)[0]
}

function Assert-GraphCodeDotNetArchive([string] $Archive, [string] $Destination) {
  $prefix = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    if ($zip.Entries.Count -eq 0) { throw 'SDK ZIP is empty' }
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('/', '\')
      if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or
          -not [IO.Path]::GetFullPath((Join-Path $Destination $name)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
          (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
        throw "SDK ZIP contains an unsafe archive entry: $($entry.FullName)"
      }
    }
  } finally { $zip.Dispose() }
}

function Install-GraphCodeDotNetSdk([string] $RepositoryRoot, [string] $ToolRoot, [string] $Version) {
  $sdkParent = Join-Path $ToolRoot 'dotnet'
  $destination = Join-Path $sdkParent $Version
  if (Test-Path -LiteralPath $destination) {
    throw "Private SDK destination already exists but was not verified: $destination; preserve it and select a fresh -ToolRoot"
  }
  $null = [IO.Directory]::CreateDirectory($sdkParent)
  $scratch = Join-Path $sdkParent ('.install-' + [guid]::NewGuid().ToString('N'))
  $null = [IO.Directory]::CreateDirectory($scratch)
  $primary = $null
  try {
    $asset = Get-GraphCodeDotNetAsset $Version
    $archive = Join-Path $scratch 'sdk.zip'
    Invoke-WebRequest -Uri $asset.Uri -OutFile $archive -TimeoutSec 900 -MaximumRedirection 0 -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash -cne $asset.Sha512) {
      throw "SDK $Version SHA-512 checksum mismatch; archive was not extracted"
    }
    $payload = Join-Path $scratch 'payload'
    Assert-GraphCodeDotNetArchive $archive $payload
    Expand-Archive -LiteralPath $archive -DestinationPath $payload -ErrorAction Stop
    $probe = Get-GraphCodeDotNetSdkProbe (Join-Path $payload 'dotnet.exe') $RepositoryRoot $ToolRoot $Version
    if (-not $probe.Valid) { throw "Downloaded SDK failed verification: $($probe.Reason)" }
    [IO.Directory]::Move($payload, $destination)
    return Join-Path $destination 'dotnet.exe'
  } catch {
    $primary = $_.Exception
    throw
  } finally {
    try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop }
    catch {
      if ($primary) {
        $primary.Data['GraphCodeDotNetCleanupFailure'] = $_.Exception.ToString()
        Write-Warning "SDK scratch cleanup failed at $scratch; the primary failure is preserved"
      } else { throw }
    }
  }
}

function Resolve-GraphCodeDotNetSdk {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ToolRoot,
    [switch] $InstallIfMissing
  )
  $RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
  $ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
  $version = Get-GraphCodeDotNetPin $RepositoryRoot
  $environment = [Environment]::GetEnvironmentVariables('Process')
  if ($environment.Contains('GRAPHCODE_DOTNET10403')) {
    $selected = [string]$environment['GRAPHCODE_DOTNET10403']
    if ([string]::IsNullOrWhiteSpace($selected)) { throw 'GRAPHCODE_DOTNET10403 is explicitly empty; reload the bootstrap environment' }
    $probe = Get-GraphCodeDotNetSdkProbe $selected $RepositoryRoot $ToolRoot $version
    if (-not $probe.Valid) { throw "GRAPHCODE_DOTNET10403 is invalid: $($probe.Reason)" }
    return $probe.Executable
  }
  $rejected = [Collections.Generic.List[string]]::new()
  foreach ($candidate in @(Get-GraphCodeDotNetCandidates $ToolRoot $version)) {
    $probe = Get-GraphCodeDotNetSdkProbe $candidate $RepositoryRoot $ToolRoot $version
    if ($probe.Valid) { return $probe.Executable }
    $rejected.Add($probe.Reason)
    Write-Verbose $probe.Reason
  }
  if ($InstallIfMissing) { return Install-GraphCodeDotNetSdk $RepositoryRoot $ToolRoot $version }
  throw "Verified .NET SDK $version with .NETCore/WindowsDesktop 10.0 runtimes and reference inputs is required. Run Tools\windows\bootstrap.ps1. $($rejected -join '; ')"
}
