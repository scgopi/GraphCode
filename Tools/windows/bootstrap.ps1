[CmdletBinding()]
param(
  [string] $ToolRoot,
  [string] $ProviderRoot,
  [switch] $SkipSwift
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
if (-not $ToolRoot) {
  $ToolRoot = Join-Path $repoRoot ".graphcode-tools"
}
if (-not $ProviderRoot) {
  $ProviderRoot = Join-Path $ToolRoot "providers"
}
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$ProviderRoot = [IO.Path]::GetFullPath($ProviderRoot)
New-Item -ItemType Directory -Force $ToolRoot, $ProviderRoot | Out-Null

function Install-Zig([string] $Version, [string] $Sha256) {
  $destination = Join-Path $ToolRoot "zig-$Version"
  $executable = Join-Path $destination "zig.exe"
  if (Test-Path -LiteralPath $executable -PathType Leaf) {
    $installedVersion = & $executable version
    if ($LASTEXITCODE -eq 0 -and $installedVersion -eq $Version) {
      return $executable
    }
    throw "Existing Zig installation is not version ${Version}: $destination"
  }

  $archive = Join-Path $ToolRoot "zig-$Version.zip"
  Invoke-WebRequest `
    -Uri "https://ziglang.org/download/$Version/zig-x86_64-windows-$Version.zip" `
    -OutFile $archive
  if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $Sha256) {
    throw "Zig $Version archive checksum mismatch"
  }
  Expand-Archive -LiteralPath $archive -DestinationPath $ToolRoot -Force
  Move-Item `
    -LiteralPath (Join-Path $ToolRoot "zig-x86_64-windows-$Version") `
    -Destination $destination
  Remove-Item -LiteralPath $archive -Force
  return $executable
}

function Install-Provider([object] $Pin, [string] $Name) {
  $destination = Join-Path $ProviderRoot $Name
  if (-not (Test-Path -LiteralPath (Join-Path $destination ".git"))) {
    git clone --no-checkout $Pin.remoteUrl $destination
    if ($LASTEXITCODE -ne 0) {
      throw "Cloning $Name failed"
    }
  }
  git -C $destination fetch --quiet origin $Pin.sha
  if ($LASTEXITCODE -ne 0) {
    throw "Fetching $Name pin $($Pin.sha) failed"
  }
  git -C $destination checkout --quiet --detach $Pin.sha
  if ($LASTEXITCODE -ne 0) {
    throw "Checking out $Name pin $($Pin.sha) failed"
  }
  if (@(git -C $destination status --porcelain --untracked-files=all).Count -ne 0) {
    throw "$Name provider checkout is dirty: $destination"
  }
  return $destination
}

function Resolve-Swift633 {
  $candidates = @(
    Get-ChildItem `
      (Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains") `
      -Recurse -Filter swift.exe -File -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty FullName
  )
  foreach ($candidate in $candidates) {
    if ($candidate -match "\\Toolchains\\6\.3\.3[^\\]*\\usr\\bin\\swift\.exe$") {
      return $candidate
    }
    $version = & $candidate --version 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $version -match "Swift version 6\.3\.3") {
      return $candidate
    }
  }
  return $null
}

$zig0152 = Install-Zig `
  "0.15.2" `
  "3A0ED1E8799A2F8CE2A6E6290A9FF22E6906F8227865911FB7DDEDC3CC14CB0C"
$zig0160 = Install-Zig `
  "0.16.0" `
  "68659EB5F1E4EB1437A722F1DD889C5A322C9954607F5EDCF337BC3684A75A7E"

$pins = Get-Content `
  -LiteralPath (Join-Path $repoRoot "graphcode-windows\provider-pins.json") `
  -Raw | ConvertFrom-Json
$winghosttyRoot = Install-Provider $pins.winghostty "winghostty"
$zmxRoot = Install-Provider $pins.zmx "zmx"

$swift = Resolve-Swift633
if (-not $swift -and -not $SkipSwift) {
  winget install --id Swift.Toolchain --exact --version 6.3.3 `
    --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) {
    throw "Installing Swift 6.3.3 failed"
  }
  $swift = Resolve-Swift633
}
if (-not $swift -and -not $SkipSwift) {
  throw "Swift 6.3.3 was installed but swift.exe could not be located"
}

$values = [ordered]@{
  GRAPHCODE_ZIG0152 = $zig0152
  GRAPHCODE_ZIG0160 = $zig0160
  GRAPHCODE_WINGHOSTTY_ROOT = $winghosttyRoot
  GRAPHCODE_ZMX_ROOT = $zmxRoot
}
if ($swift) {
  $values["GRAPHCODE_SWIFT633"] = $swift
}

foreach ($entry in $values.GetEnumerator()) {
  [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
  if ($env:GITHUB_ENV) {
    "$($entry.Key)=$($entry.Value)" | Add-Content -LiteralPath $env:GITHUB_ENV
  }
}

$environmentScript = Join-Path $ToolRoot "environment.ps1"
$values.GetEnumerator() |
  ForEach-Object { "`$env:$($_.Key) = '$($_.Value.Replace("'", "''"))'" } |
  Set-Content -LiteralPath $environmentScript

Write-Host "GraphCode Windows dependencies are ready."
Write-Host "Load them in a new shell with: . '$environmentScript'"
Write-Host "Validate with:"
Write-Host "pwsh -NoProfile -File Tools\windows\validate.ps1 -Task windows-shell -SwiftExecutable '$swift'"
