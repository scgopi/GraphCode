function Invoke-ValidationFixtureDirectoryCreate {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path)

  if (-not $env:GRAPHCODE_VALIDATION_ASSEMBLY) {
    throw "Build with Tools\windows\Build-CompiledValidationRunner.ps1 and set GRAPHCODE_VALIDATION_ASSEMBLY to its output"
  }
  & (Join-Path $PSScriptRoot "..\Import-CompiledValidationAssembly.ps1") `
    -AssemblyPath (Join-Path ([IO.Path]::GetDirectoryName($env:GRAPHCODE_VALIDATION_ASSEMBLY)) "ValidationFixtureBindings.dll") `
    -RequiredType "GraphCode.ValidationFixtureDirectoryNative" | Out-Null
  [GraphCode.ValidationFixtureDirectoryNative]::Create($Path)
}

function New-ValidationFixtureDirectory {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path)

  $fullPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
  $parent = [IO.Path]::GetDirectoryName($fullPath)
  if (-not [string]::IsNullOrEmpty($parent)) {
    # Parent containers are shared, never part of the fixture's cleanup ownership.
    [void][IO.Directory]::CreateDirectory($parent)
  }
  Invoke-ValidationFixtureDirectoryCreate -Path $fullPath
  $directory = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  return [pscustomobject]@{
    Path = $directory.FullName
    CreationTimeUtc = $directory.CreationTimeUtc
    OwnedFiles = [Collections.Generic.List[object]]::new()
  }
}

function Get-ValidationFixtureDirectory {
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Fixture)

  $directory = Get-Item -LiteralPath $Fixture.Path -Force -ErrorAction Stop
  if (-not $directory.PSIsContainer -or
      ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      $directory.CreationTimeUtc -ne $Fixture.CreationTimeUtc) {
    throw "Validation fixture identity changed; refusing cleanup: $($Fixture.Path)"
  }
  return $directory
}

function New-ValidationFixtureFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Fixture,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Content
  )

  if ([IO.Path]::GetFileName($Name) -cne $Name -or $Name -in @(".", "..")) {
    throw "Validation fixture file must be a leaf name: $Name"
  }
  $directory = Get-ValidationFixtureDirectory -Fixture $Fixture
  $path = Join-Path $directory.FullName $Name
  $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    $Fixture.OwnedFiles.Add([pscustomobject]@{
      Path = $file.FullName
      CreationTimeUtc = $file.CreationTimeUtc
    })
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content + [Environment]::NewLine)
    $stream.Write($bytes, 0, $bytes.Length)
  } finally {
    $stream.Dispose()
  }
}

function Remove-ValidationFixtureDirectory {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Fixture,
    [Management.Automation.ErrorRecord] $PrimaryError
  )

  try {
    $directory = Get-ValidationFixtureDirectory -Fixture $Fixture
    $ownedPaths = @($Fixture.OwnedFiles | ForEach-Object { $_.Path })
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory.FullName)) {
      if ($ownedPaths -cnotcontains $entry) {
        throw "Unexpected validation fixture contents; refusing cleanup: $entry"
      }
    }
    $files = @(foreach ($owned in $Fixture.OwnedFiles) {
      $file = Get-Item -LiteralPath $owned.Path -Force -ErrorAction Stop
      if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
          $file.CreationTimeUtc -ne $owned.CreationTimeUtc) {
        throw "Validation fixture file identity changed; refusing cleanup: $($owned.Path)"
      }
      $file
    })
    foreach ($file in $files) {
      [IO.File]::Delete($file.FullName)
    }
    [IO.Directory]::Delete($directory.FullName, $false)
  } catch {
    if ($null -ne $PrimaryError) {
      throw [AggregateException]::new("Validation workload and fixture cleanup both failed.",
        [Exception[]]@($PrimaryError.Exception, $_.Exception))
    }
    throw
  }
}
