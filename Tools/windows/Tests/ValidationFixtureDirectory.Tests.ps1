[CmdletBinding()]
param(
  [string] $ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) (
    "validation-fixture-" + [guid]::NewGuid().ToString("N")))
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ValidationFixtureDirectory.ps1")
$results = [Collections.Generic.List[object]]::new()

function Assert-Fixture([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-FixtureNativeCollision($Failure) {
  $exception = $Failure.Exception
  while ($null -ne $exception -and $exception -isnot [ComponentModel.Win32Exception]) {
    $exception = $exception.InnerException
  }
  Assert-Fixture ($null -ne $exception) "Exclusive-create failure lost its Win32 error"
  Assert-Fixture ($exception.NativeErrorCode -eq 183) "Exclusive create did not report ERROR_ALREADY_EXISTS"
  Write-Output "NATIVE_CREATE_ERROR=$($exception.NativeErrorCode)"
}

function Invoke-FixtureCase([string] $CaseName, [scriptblock] $Action) {
  try {
    & $Action
    $results.Add([pscustomobject]@{ name = $CaseName; passed = $true })
    Write-Output "PASS $CaseName"
  } catch {
    $results.Add([pscustomobject]@{ name = $CaseName; passed = $false })
    Write-Output "FAIL ${CaseName}: $($_.Exception.Message)"
  }
}

Invoke-FixtureCase "helper import does not load or invoke its native binding" {
  Assert-Fixture ($null -eq ("GraphCode.ValidationFixtureDirectoryNative" -as [type])) `
    "Helper import eagerly loaded its native binding"
}

$root = (New-ValidationFixtureDirectory -Path $ScratchRoot).Path

Invoke-FixtureCase "harness acquires scratch exclusively and retains its contents" {
  $source = [IO.File]::ReadAllText($PSCommandPath)
  Assert-Fixture ($source.Contains(
    '$root = (New-ValidationFixtureDirectory -Path $ScratchRoot).Path')) "Harness root admission is not exclusive"
  Assert-Fixture (-not ($source -match 'Remove-Item\s+-LiteralPath\s+\$root\b')) `
    "Harness removes unrecognized scratch contents"
}

foreach ($name in @("validation-runner-untracked", "OwnershipSentinel")) {
  Invoke-FixtureCase "$name creates missing parent containers without owning their cleanup" {
    $parent = Join-Path $root "$name-missing-parent\Sources\GraphcodeWindowsContracts"
    $path = Join-Path $parent $name
    Assert-Fixture (-not [IO.Directory]::Exists($parent)) "Clean parent hierarchy already exists"
    $fixture = New-ValidationFixtureDirectory -Path $path
    Assert-Fixture ($fixture.Path -ceq $path) "Receipt adopted a parent rather than the exclusive leaf"
    Remove-ValidationFixtureDirectory -Fixture $fixture
    Assert-Fixture (-not [IO.Directory]::Exists($path)) "Owned leaf survived cleanup"
    Assert-Fixture ([IO.Directory]::Exists($parent)) "Cleanup removed a generated parent container"
    Assert-Fixture ([IO.Directory]::Exists((Join-Path $root "$name-missing-parent\Sources"))) `
      "Cleanup removed a generated ancestor"
  }

  Invoke-FixtureCase "$name preserves an existing parent's contents after leaf cleanup" {
    $parent = Join-Path $root "$name-existing-parent"
    $parentFixture = New-ValidationFixtureDirectory -Path $parent
    New-ValidationFixtureFile -Fixture $parentFixture -Name "retained.txt" -Content "existing parent"
    $marker = Join-Path $parent "retained.txt"
    $before = (Get-FileHash -LiteralPath $marker).Hash
    $path = Join-Path $parent $name
    $fixture = New-ValidationFixtureDirectory -Path $path
    Assert-Fixture ($fixture.Path -ceq $path) "Receipt adopted the existing parent"
    Remove-ValidationFixtureDirectory -Fixture $fixture
    Assert-Fixture ([IO.Directory]::Exists($parent)) "Existing parent was removed"
    Assert-Fixture ((Get-FileHash -LiteralPath $marker).Hash -ceq $before) "Existing parent contents changed"
  }

  Invoke-FixtureCase "$name preserves pre-existing directory contents" {
    $path = Join-Path $root "$name-existing-directory"
    [void](New-Item -ItemType Directory -Path $path)
    $file = Join-Path $path "Unformatted.swift"
    [IO.File]::WriteAllText($file, "pre-existing content")
    $before = (Get-FileHash -LiteralPath $file).Hash
    $failure = $null
    try { $null = New-ValidationFixtureDirectory -Path $path } catch { $failure = $_ }
    Assert-Fixture ($null -ne $failure) "Existing directory was accepted as owned"
    Assert-FixtureNativeCollision $failure
    Assert-Fixture ((Get-FileHash -LiteralPath $file).Hash -ceq $before) "Existing contents changed"
  }

  Invoke-FixtureCase "$name preserves pre-existing file" {
    $path = Join-Path $root "$name-existing-file"
    [IO.File]::WriteAllText($path, "pre-existing file")
    $before = (Get-FileHash -LiteralPath $path).Hash
    $failure = $null
    try { $null = New-ValidationFixtureDirectory -Path $path } catch { $failure = $_ }
    Assert-Fixture ($null -ne $failure) "Existing file was accepted as owned"
    Assert-FixtureNativeCollision $failure
    Assert-Fixture ((Get-FileHash -LiteralPath $path).Hash -ceq $before) "Existing file changed"
  }

  Invoke-FixtureCase "$name refuses a collision at the directory-create boundary" {
    $path = Join-Path $root "$name-create-collision"
    $file = Join-Path $path "retained.txt"
    $script:fixtureCollisionCount = 0
    $script:fixtureCollisionCleanupCount = 0
    $nativeCreate = Get-Command Invoke-ValidationFixtureDirectoryCreate -ErrorAction SilentlyContinue
    $nativeCreateBody = if ($null -ne $nativeCreate) { $nativeCreate.ScriptBlock } else { $null }

    function Add-FixtureCollision {
      [void][IO.Directory]::CreateDirectory($path)
      [IO.File]::WriteAllText($file, "concurrent creator")
      $script:fixtureCollisionCount++
    }

    # Model the provider's idempotent final create after its earlier existence check.
    function New-Item {
      param($ItemType, $Path, $ErrorAction)
      Add-FixtureCollision
      return Get-Item -LiteralPath $Path
    }

    function Invoke-ValidationFixtureDirectoryCreate {
      param([string] $Path)
      Add-FixtureCollision
      & $nativeCreateBody -Path $Path
    }

    function Remove-ValidationFixtureDirectory {
      param($Fixture)
      $script:fixtureCollisionCleanupCount++
    }

    $failure = $null
    $fixture = $null
    try {
      $fixture = New-ValidationFixtureDirectory -Path $path
      try { } finally { Remove-ValidationFixtureDirectory -Fixture $fixture }
    } catch { $failure = $_ }
    Assert-Fixture ($script:fixtureCollisionCount -eq 1) "Collision did not occur at the create boundary"
    Assert-Fixture ($null -ne $failure -and $null -eq $fixture) "Concurrent directory was accepted as owned"
    Assert-Fixture ($script:fixtureCollisionCleanupCount -eq 0) "Failed acquisition reached cleanup"
    Assert-Fixture ([IO.File]::ReadAllText($file) -ceq "concurrent creator") "Concurrent contents changed"
    if ($null -ne $nativeCreateBody) {
      Assert-FixtureNativeCollision $failure
    }
  }

  Invoke-FixtureCase "$name removes only a successfully created fixture" {
    $path = Join-Path $root "$name-owned"
    $sibling = Join-Path $root "$name-sibling"
    [IO.File]::WriteAllText($sibling, "sibling")
    $fixture = New-ValidationFixtureDirectory -Path $path
    try {
      Assert-Fixture ([IO.Directory]::Exists($path)) "Owned directory was not created"
      New-ValidationFixtureFile -Fixture $fixture -Name "Unformatted.swift" -Content "let value=1"
    } finally {
      Remove-ValidationFixtureDirectory -Fixture $fixture
    }
    Assert-Fixture (-not (Test-Path -LiteralPath $path)) "Owned directory survived cleanup"
    Assert-Fixture ([IO.File]::ReadAllText($sibling) -ceq "sibling") "Sibling changed"
  }

  Invoke-FixtureCase "$name cleans its owned fixture after workload failure" {
    $path = Join-Path $root "$name-failed-workload"
    $fixture = New-ValidationFixtureDirectory -Path $path
    $primary = [InvalidOperationException]::new("controlled workload failure")
    $failure = $null
    try {
      try { throw $primary } finally { Remove-ValidationFixtureDirectory -Fixture $fixture }
    } catch { $failure = $_ }
    Assert-Fixture ([object]::ReferenceEquals($primary, $failure.Exception)) "Primary error changed"
    Assert-Fixture (-not (Test-Path -LiteralPath $path)) "Failed workload left its owned directory"
  }

  foreach ($kind in @("file", "directory")) {
    Invoke-FixtureCase "$name cleanup preserves an unexpected child $kind" {
      $path = Join-Path $root "$name-unexpected-$kind"
      $fixture = New-ValidationFixtureDirectory -Path $path
      if ($name -eq "validation-runner-untracked") {
        New-ValidationFixtureFile -Fixture $fixture -Name "Unformatted.swift" -Content "let value=1"
        Assert-Fixture ($fixture.OwnedFiles.Count -eq 1) "Untracked known-file path was not exercised"
        $ownedFile = Join-Path $path "Unformatted.swift"
        $ownedBefore = (Get-FileHash -LiteralPath $ownedFile).Hash
      }
      $unexpected = Join-Path $path "unexpected"
      $file = $unexpected
      if ($kind -eq "directory") {
        [void][IO.Directory]::CreateDirectory($unexpected)
        $file = Join-Path $unexpected "retained.txt"
      }
      [IO.File]::WriteAllText($file, "unexpected child")
      $before = (Get-FileHash -LiteralPath $file).Hash
      $failure = $null
      try { Remove-ValidationFixtureDirectory -Fixture $fixture } catch { $failure = $_ }
      Assert-Fixture ($null -ne $failure) "Cleanup accepted unexpected contents"
      Assert-Fixture ((Get-FileHash -LiteralPath $file).Hash -ceq $before) "Unexpected contents changed"
      if ($name -eq "validation-runner-untracked") {
        Assert-Fixture ((Get-FileHash -LiteralPath $ownedFile).Hash -ceq $ownedBefore) `
          "Cleanup removed its known file before refusing unexpected contents"
        Write-Output "UNTRACKED_OWNED_FILE_PREFLIGHT_KIND=$kind OWNED_FILES=1 PRESERVED=1"
      }
    }
  }

  Invoke-FixtureCase "$name refuses an existing file without acquiring cleanup ownership" {
    $path = Join-Path $root "$name-file-create-collision"
    $fixture = New-ValidationFixtureDirectory -Path $path
    $file = Join-Path $path "Unformatted.swift"
    [IO.File]::WriteAllText($file, "concurrent file")
    $failure = $null
    try {
      New-ValidationFixtureFile -Fixture $fixture -Name "Unformatted.swift" -Content "let value=1"
    } catch { $failure = $_ }
    Assert-Fixture ($null -ne $failure) "Existing file was overwritten"
    Assert-Fixture ($fixture.OwnedFiles.Count -eq 0) "Failed file acquisition granted cleanup ownership"
    $cleanupFailure = $null
    try { Remove-ValidationFixtureDirectory -Fixture $fixture } catch { $cleanupFailure = $_ }
    Assert-Fixture ($null -ne $cleanupFailure) "Unowned file did not prevent directory cleanup"
    Assert-Fixture ([IO.File]::ReadAllText($file) -ceq "concurrent file") "Existing file contents changed"
  }

  Invoke-FixtureCase "$name preserves both workload and cleanup errors" {
    $path = Join-Path $root "$name-workload-and-cleanup-errors"
    $fixture = New-ValidationFixtureDirectory -Path $path
    $file = Join-Path $path "unexpected.txt"
    [IO.File]::WriteAllText($file, "preserved")
    $primary = [InvalidOperationException]::new("controlled primary failure")
    $primaryRecord = $null
    $failure = $null
    try {
      try { throw $primary } catch {
        $primaryRecord = $_
        throw
      } finally {
        Remove-ValidationFixtureDirectory -Fixture $fixture -PrimaryError $primaryRecord
      }
    } catch { $failure = $_ }
    Assert-Fixture ($failure.Exception -is [AggregateException]) "Cleanup masked the workload error"
    Assert-Fixture ($failure.Exception.InnerExceptions.Count -eq 2) "Both errors were not retained"
    Assert-Fixture ([object]::ReferenceEquals($primary, $failure.Exception.InnerExceptions[0])) `
      "Original workload exception was replaced"
    Assert-Fixture ($failure.Exception.InnerExceptions[1].Message -like "*Unexpected validation fixture contents*") `
      "Cleanup refusal was not retained"
    Assert-Fixture ([IO.File]::ReadAllText($file) -ceq "preserved") "Unexpected file changed"
  }
}

Invoke-FixtureCase "cleanup refuses a replaced fixture and preserves its contents" {
  $path = Join-Path $root "replaced"
  $fixture = New-ValidationFixtureDirectory -Path $path
  [IO.Directory]::Delete($path, $false)
  [void](New-Item -ItemType Directory -Path $path)
  [IO.Directory]::SetCreationTimeUtc($path, $fixture.CreationTimeUtc.AddDays(-1))
  $file = Join-Path $path "retained.txt"
  [IO.File]::WriteAllText($file, "replacement")
  $failure = $null
  try { Remove-ValidationFixtureDirectory -Fixture $fixture } catch { $failure = $_ }
  Assert-Fixture ($null -ne $failure) "Replacement directory was removed"
  Assert-Fixture ([IO.File]::ReadAllText($file) -ceq "replacement") "Replacement contents changed"
}

Invoke-FixtureCase "cleanup refuses a replaced owned file and preserves its contents" {
  $path = Join-Path $root "replaced-file"
  $fixture = New-ValidationFixtureDirectory -Path $path
  New-ValidationFixtureFile -Fixture $fixture -Name "Unformatted.swift" -Content "let value=1"
  $file = Join-Path $path "Unformatted.swift"
  [IO.File]::Delete($file)
  [IO.File]::WriteAllText($file, "replacement file")
  [IO.File]::SetCreationTimeUtc($file, $fixture.OwnedFiles[0].CreationTimeUtc.AddDays(-1))
  $failure = $null
  try { Remove-ValidationFixtureDirectory -Fixture $fixture } catch { $failure = $_ }
  Assert-Fixture ($null -ne $failure) "Replacement file was removed"
  Assert-Fixture ([IO.File]::ReadAllText($file) -ceq "replacement file") "Replacement file contents changed"
}

# Read the blocked runner only as data; never import or execute its contents.
$runnerSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "ValidationRunner.Tests.ps1"))
foreach ($binding in @(
    @{ name = "untracked"; path = "untrackedDirectory"; fixture = "untrackedFixture"; failure = "untrackedFailure" },
    @{ name = "sentinel"; path = "foreignJunction"; fixture = "foreignFixture"; failure = "foreignFailure" }
  )) {
  Invoke-FixtureCase "$($binding.name) runner wiring acquires before try and cleans only its fixture" {
    $acquire = '\$' + $binding.fixture + ' = New-ValidationFixtureDirectory -Path \$' +
      $binding.path + '\s+try \{'
    $cleanup = '\} finally \{\s+Remove-ValidationFixtureDirectory -Fixture \$' +
      $binding.fixture + ' -PrimaryError \$' + $binding.failure + '\s+\}'
    $primary = '\} catch \{\s+\$' + $binding.failure + ' = \$_\s+throw\s+' + $cleanup
    Assert-Fixture ($runnerSource -match $acquire) "Runner does not acquire an exclusive fixture before try"
    Assert-Fixture ($runnerSource -match $cleanup) "Runner cleanup does not use its acquired fixture"
    Assert-Fixture ($runnerSource -match $primary) "Runner does not retain its primary workload error"
    Assert-Fixture ($runnerSource -notmatch (
      'New-Item -ItemType Directory -Force \$' + $binding.path)) "Runner still adopts a pre-existing directory"
    Assert-Fixture ($runnerSource -notmatch (
      'Remove-Item -LiteralPath \$' + $binding.path)) "Runner still removes the unowned fixed path"
    Assert-Fixture ($runnerSource.Contains(
      '. (Join-Path $PSScriptRoot "ValidationFixtureDirectory.ps1")')) "Runner does not import fixture helper"
    if ($binding.name -eq "untracked") {
      Assert-Fixture ($runnerSource.Contains(
        'New-ValidationFixtureFile -Fixture $untrackedFixture -Name "Unformatted.swift" -Content "let value=1"')) `
        "Runner does not acquire its known unformatted file exclusively"
    }
  }
}

$failed = @($results | Where-Object { -not $_.passed }).Count
[ordered]@{
  suite = "ValidationFixtureDirectory"
  executed = $results.Count
  passed = $results.Count - $failed
  failed = $failed
  skipped = 0
  notRun = 0
} | ConvertTo-Json -Compress | Write-Output
if ($results.Count -ne 28 -or $failed -ne 0) {
  throw "Validation fixture contracts failed; retained evidence: $root"
}
Write-Output "FIXTURE_SCRATCH_RETAINED=$root"
