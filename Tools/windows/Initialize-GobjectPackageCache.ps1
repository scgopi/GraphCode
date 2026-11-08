[CmdletBinding()]
param(
  [string] $Zig0160 = $env:GRAPHCODE_ZIG0160,
  [string] $ArtifactParent = $env:RUNNER_TEMP,
  [switch] $PublishJobEnvironment
)

$ErrorActionPreference = "Stop"

function Assert-GobjectArchiveProof([long] $Bytes, [string] $Sha256) {
  if ($Bytes -ne 1867503 -or
      $Sha256 -cne "D572886E8672A46AC6C740E3FE3A1F1C9D9A1A9F09D59FD62328A41FCDB70196") {
    throw "Official gobject asset size or SHA-256 mismatch; package fetch was not authorized."
  }
}

function Assert-GobjectFetchProof($Result) {
  $expected = "gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3"
  if ($Result.ExitCode -ne 0 -or $Result.StandardOutput -cnotin @("$expected`n", "$expected`r`n") -or
      $Result.StandardError -cne "" -or -not $Result.Cleanup.CanRelease -or
      -not $Result.Cleanup.ResourcesClosed) {
    throw "Local gobject fetch did not return exactly the pinned package hash with complete owned cleanup."
  }
}

function New-GobjectFetchStart([string] $Executable, [string] $Project,
    [string] $Cache, [string] $Archive, [string] $Temp) {
  $start = [Diagnostics.ProcessStartInfo]::new($Executable)
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.WorkingDirectory = $Project
  $start.Environment["TEMP"] = $Temp
  $start.Environment["TMP"] = $Temp
  $start.Environment["ZIG_GLOBAL_CACHE_DIR"] = $Cache
  $null = $start.Environment.Remove("ZIG_LOCAL_CACHE_DIR")
  $null = $start.Environment.Remove("GH_TOKEN")
  $null = $start.Environment.Remove("GITHUB_TOKEN")
  foreach ($argument in @("fetch", "--global-cache-dir", $Cache, $Archive)) {
    $start.ArgumentList.Add($argument)
  }
  return $start
}

function Save-OfficialGobjectArchive([string] $Path, [string] $Token) {
  if ([string]::IsNullOrWhiteSpace($Token) -or $Token -match '\s') {
    throw "Official asset API requires the existing job token without whitespace."
  }
  $client = [Net.Http.HttpClient]::new()
  $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
  $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(60))
  $request = [Net.Http.HttpRequestMessage]::new(
    [Net.Http.HttpMethod]::Get,
    "https://api.github.com/repos/ghostty-org/zig-gobject/releases/assets/493157198")
  $response = $null
  $input = $null
  $output = $null
  $primary = $null
  try {
    $request.Headers.UserAgent.ParseAdd("GraphCode-pinned-gobject-prefetch")
    $request.Headers.Accept.ParseAdd("application/octet-stream")
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $Token)
    $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
      $deadline.Token).GetAwaiter().GetResult()
    [IO.File]::WriteAllText("$Path.http-status.json",
      (@{ statusCode = [int]$response.StatusCode; assetId = 493157198 } | ConvertTo-Json),
      [Text.UTF8Encoding]::new($false))
    $null = $response.EnsureSuccessStatusCode()
    $input = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
    $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $buffer = [byte[]]::new(16384)
    $total = 0L
    while (($read = $input.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).
        GetAwaiter().GetResult()) -gt 0) {
      $output.Write($buffer, 0, $read)
      $total += $read
      if ($total -gt 1867503) { throw "Official asset exceeds the exact pinned byte count." }
    }
    $output.Flush($true)
  } catch {
    $primary = $_.Exception
    throw
  } finally {
    $cleanupErrors = [Collections.Generic.List[Exception]]::new()
    foreach ($resource in @($output, $input, $response, $request, $deadline, $client)) {
      if ($null -ne $resource) {
        try { $resource.Dispose() } catch { $cleanupErrors.Add($_.Exception) }
      }
    }
    if ($cleanupErrors.Count -gt 0) {
      $cleanupFailure = [AggregateException]::new("Official asset transport cleanup failed.", $cleanupErrors)
      if ($primary) { $primary.Data["GobjectTransportCleanupFailure"] = $cleanupFailure } else { throw $cleanupFailure }
    }
  }
}

if ($MyInvocation.InvocationName -eq ".") { return }

$assembly = $env:GRAPHCODE_VALIDATION_ASSEMBLY
if ([string]::IsNullOrWhiteSpace($assembly)) {
  throw "Official prefetch requires the existing source-bound compiled ownership bindings."
}
& (Join-Path $PSScriptRoot "Import-CompiledValidationAssembly.ps1") `
  -AssemblyPath $assembly -RequiredType "GraphCode.Validation.Ownership.OwnedChildSupervisor" | Out-Null
& (Join-Path $PSScriptRoot "Import-CompiledValidationAssembly.ps1") `
  -AssemblyPath (Join-Path (Split-Path $assembly) "ValidationFixtureBindings.dll") `
  -RequiredType "GraphCode.ValidationFixtureDirectoryNative" | Out-Null
if ([string]::IsNullOrWhiteSpace($ArtifactParent) -or
    $ArtifactParent.Contains("`r") -or $ArtifactParent.Contains("`n") -or
    -not [IO.Path]::IsPathFullyQualified($ArtifactParent) -or
    -not (Test-Path -LiteralPath $ArtifactParent -PathType Container) -or
    [string]::IsNullOrWhiteSpace($Zig0160) -or -not [IO.Path]::IsPathFullyQualified($Zig0160) -or
    -not (Test-Path -LiteralPath $Zig0160 -PathType Leaf)) {
  throw "Official prefetch requires an existing absolute job temp parent and pinned Zig executable."
}
if ($PublishJobEnvironment -and (
    [string]::IsNullOrWhiteSpace($env:GITHUB_ENV) -or
    -not [IO.Path]::IsPathFullyQualified($env:GITHUB_ENV) -or
    -not (Test-Path -LiteralPath $env:GITHUB_ENV -PathType Leaf))) {
  throw "Package cache publication requires the existing job environment file."
}
$root = Join-Path $ArtifactParent ("gobject-prefetch-" + [guid]::NewGuid().ToString("N"))
[GraphCode.ValidationFixtureDirectoryNative]::CreateOwnedByCurrentUser($root)
foreach ($name in @("project", "global", "temp", "logs")) {
  [GraphCode.ValidationFixtureDirectoryNative]::CreateOwnedByCurrentUser((Join-Path $root $name))
}
Write-Host "GOBJECT_PREFETCH_ARTIFACT_ROOT=$root"
$project = Join-Path $root "project"
$cache = Join-Path $root "global"
$marker = Join-Path $project "build.zig"
$file = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$file.Dispose()
$archive = Join-Path $root "official-gobject.tar.gz"
$version = $null
$result = $null
$primary = $null
try {
  $versionStart = New-GobjectFetchStart $Zig0160 $project $cache $archive (Join-Path $root "temp")
  $versionStart.ArgumentList.Clear()
  $versionStart.ArgumentList.Add("version")
  $version = [GraphCode.Validation.Ownership.OwnedChildSupervisor]::RunAsync(
    $versionStart, [TimeSpan]::FromSeconds(10), (Join-Path $root "logs")).GetAwaiter().GetResult()
  if ($version.ExitCode -ne 0 -or $version.StandardOutput -cnotin @("0.16.0`n", "0.16.0`r`n") -or
      $version.StandardError -cne "" -or -not $version.Cleanup.CanRelease -or
      -not $version.Cleanup.ResourcesClosed) { throw "Prefetch requires exactly pinned Zig 0.16.0." }
  Save-OfficialGobjectArchive $archive $env:GH_TOKEN
  $archiveInfo = Get-Item -LiteralPath $archive
  $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
  Assert-GobjectArchiveProof $archiveInfo.Length $archiveHash
  $start = New-GobjectFetchStart $Zig0160 $project $cache $archive (Join-Path $root "temp")
  $before = [ordered]@{
    fileName = $start.FileName; executableSha256 = (Get-FileHash -LiteralPath $Zig0160 -Algorithm SHA256).Hash
    argumentList = @($start.ArgumentList); workingDirectory = $start.WorkingDirectory
    markerBytes = (Get-Item -LiteralPath $marker).Length
    archiveBytes = $archiveInfo.Length; archiveSha256 = $archiveHash
    globalCache = $cache; timeoutSeconds = 120; recursive = $false; save = $false
  }
  if ($before.markerBytes -ne 0) { throw "The private fetch context marker must remain empty." }
  $before | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root "before-fetch.json") -Encoding utf8
  $result = [GraphCode.Validation.Ownership.OwnedChildSupervisor]::RunAsync(
    $start, [TimeSpan]::FromSeconds(120), (Join-Path $root "logs")).GetAwaiter().GetResult()
  Assert-GobjectFetchProof $result
  $cachedArchive = Join-Path $cache "p\gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3.tar.gz"
  if (-not (Test-Path -LiteralPath $cachedArchive -PathType Leaf) -or
      (Get-Item -LiteralPath $cachedArchive).Length -le 0 -or
      (Get-Item -LiteralPath $marker).Length -ne 0 -or
      (Test-Path -LiteralPath (Join-Path $project "build.zig.zon"))) {
    throw "Verified fetch did not retain its native global archive or changed the empty project context."
  }
  if ($PublishJobEnvironment) {
    [IO.File]::AppendAllText($env:GITHUB_ENV, "ZIG_GLOBAL_CACHE_DIR=$cache`n", [Text.UTF8Encoding]::new($false))
  }
  $env:ZIG_GLOBAL_CACHE_DIR = $cache
} catch {
  $primary = $_
  throw
} finally {
  try {
    [ordered]@{
      version = $version; result = $result
      failure = if ($primary) { $primary.Exception.Message } else { $null }
      globalCache = $cache; markerBytes = (Get-Item -LiteralPath $marker).Length
      files = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
        @{ path = $_.FullName.Substring($root.Length + 1); bytes = $_.Length
          sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
      })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root "receipt.json") -Encoding utf8
  } catch {
    if ($primary) {
      $primary.Exception.Data["GobjectPrefetchReceiptFailure"] = $_.Exception
    } else { throw }
  } finally {
    if ([GraphCode.Validation.Ownership.OwnedChildSupervisor]::RequiresLifetimeHold) {
      [Console]::Out.WriteLine("GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven")
      [Console]::Out.Flush()
      $null = [GraphCode.Validation.Ownership.OwnedChildSupervisor]::HoldRetainedResourcesAsync().GetAwaiter().GetResult()
    }
  }
}
Write-Host "GOBJECT_PACKAGE_HASH_VERIFIED=gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3"
