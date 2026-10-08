[CmdletBinding()]
param(
  [ValidateSet(
    "all",
    "swift-portable",
    "swift-contracts",
    "swift-production",
    "swift-paths",
    "swift-process",
    "swift-named-pipe",
    "remote-bridge",
    "remote-e2e",
    "swift-format",
    "visual-baseline",
    "tdd-evidence",
    "privacy",
    "provider-build",
    "terminal-gate",
    "windows-shell",
    "packaging",
    "hardening"
  )]
  [string[]] $Task = @("all"),
  # Removes tasks from the selection, for example tasks that a sibling required
  # workflow already runs. The remaining tasks keep their canonical order.
  [ValidateSet(
    "swift-portable",
    "swift-contracts",
    "swift-production",
    "swift-paths",
    "swift-process",
    "swift-named-pipe",
    "remote-bridge",
    "remote-e2e",
    "swift-format",
    "visual-baseline",
    "tdd-evidence",
    "privacy",
    "provider-build",
    "terminal-gate",
    "windows-shell",
    "packaging",
    "hardening"
  )]
  [string[]] $SkipTask = @(),
  # windows-shell parts: "unit" runs the contract and Zig executable sections
  # (optionally one shard of them); "integration" runs the release build, live
  # smoke, tray, and UI Automation gate. "all" runs both, in the original order.
  [ValidateSet("all", "unit", "integration")]
  [string] $ShellPart = "all",
  [int] $ShellTestShard = 0,
  [int] $ShellTestShardCount = 1,
  [string] $ShellTestManifest,
  # packaging parts: "contracts" are the fixture-only release, signing, scheduler,
  # rollback, and standalone contracts; "real" builds its own release inputs and
  # packages the real products.
  [ValidateSet("all", "contracts", "real")]
  [string] $PackagingPart = "all",
  [switch] $List,
  [switch] $DryRun,
  [switch] $SkipTrayLive,
  [switch] $SkipWslRemoteE2E,
  [string] $ShellValidationRoot,
  [string] $SwiftExecutable
)

$ErrorActionPreference = "Stop"
$env:GIT_CONFIG_COUNT = "1"
$env:GIT_CONFIG_KEY_0 = "safe.bareRepository"
$env:GIT_CONFIG_VALUE_0 = "all"

$tasks = @(
  "swift-portable",
  "swift-contracts",
  "swift-production",
  "swift-paths",
  "swift-process",
  "swift-named-pipe",
  "remote-bridge",
  "remote-e2e",
  "swift-format",
  "visual-baseline",
  "tdd-evidence",
  "privacy",
  "terminal-gate",
  "windows-shell",
  "packaging",
  "hardening"
)
# Selectable on its own but not part of "all": terminal-gate already runs it.
$buildOnlyTasks = @("provider-build")

if ($List) {
  $buildOnlyTasks
  $tasks
  exit 0
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Resolve-SwiftExecutable {
  if ($SwiftExecutable) {
    return (Resolve-Path $SwiftExecutable).Path
  }

  $candidates = @()
  $command = Get-Command swift.exe -ErrorAction SilentlyContinue
  if ($command) {
    $candidates += $command.Source
  }
  $candidates += Get-ChildItem `
    (Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains") `
    -Recurse -Filter swift.exe -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
  $candidates += Get-ChildItem `
    "C:\Library\Developer\Toolchains" `
    -Recurse -Filter swift.exe -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

  foreach ($candidate in $candidates | Select-Object -Unique) {
    if ($candidate -match "\\Toolchains\\([0-9]+)\.[^\\]*\\usr\\bin\\swift\.exe$" -and
      [int] $Matches[1] -ge 6) {
      return $candidate
    }
    $version = & $candidate --version 2>$null | Select-Object -First 1
    if ($version -match "Swift version ([0-9]+)\.") {
      if ([int] $Matches[1] -ge 6) {
        return $candidate
      }
    }
  }

  throw "Swift 6 or newer was not found. Install the pinned toolchain or pass -SwiftExecutable."
}

function Initialize-SwiftEnvironment([string] $swift) {
  $toolBin = Split-Path $swift

  if ($swift -match "^(.*)\\Toolchains\\([^\\]+)\\usr\\bin\\swift\.exe$") {
    $swiftRoot = $Matches[1]
    $toolchainName = $Matches[2]
    $version = $toolchainName.Split("+")[0]
    $runtimeCandidates = @(
      (Join-Path $swiftRoot "Runtimes\$version\usr\bin"),
      $toolBin
    )
    $sdk = Join-Path $swiftRoot "Platforms\$version\Windows.platform\Developer\SDKs\Windows.sdk"
    foreach ($runtime in $runtimeCandidates | Select-Object -Unique) {
      if (Test-Path $runtime) {
        $env:PATH = "$runtime;$env:PATH"
      }
    }
    $env:PATH = "$toolBin;$env:PATH"
    if (Test-Path $sdk) {
      $env:SDKROOT = $sdk
    }
  } else {
    $env:PATH = "$toolBin;$env:PATH"
  }

  # Swift selects the Windows SDK shipped with its pinned toolchain. Inherited
  # Visual Studio developer-prompt variables can redirect ClangImporter to a
  # different UCRT/MSVC installation and hide Swift's `_complex`/`ucrt` modules.
  foreach ($name in @(
      "INCLUDE", "LIB", "LIBPATH",
      "VCINSTALLDIR", "VCToolsInstallDir", "VCToolsVersion",
      "VSINSTALLDIR", "VisualStudioVersion",
      "WindowsSdkDir", "WindowsSDKVersion",
      "UniversalCRTSdkDir", "UCRTVersion")) {
    Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue
  }
}

function Resolve-SwiftRuntimeDirectory([string] $swift) {
  $toolBin = Split-Path $swift
  if ($swift -match "^(.*)\\Toolchains\\([^\\]+)\\usr\\bin\\swift\.exe$") {
    $swiftRoot = $Matches[1]
    $toolchainName = $Matches[2]
    $version = $toolchainName.Split("+")[0]
    $runtimeCandidates = @(
      (Join-Path $swiftRoot "Runtimes\$version\usr\bin"),
      $toolBin
    )
    foreach ($runtime in $runtimeCandidates | Select-Object -Unique) {
      if ((Test-Path $runtime) -and
        (Get-ChildItem -LiteralPath $runtime -Filter *.dll -ErrorAction SilentlyContinue)) {
        return $runtime
      }
    }
  }
  throw "Swift runtime DLL directory was not found for $swift"
}

function Start-CleanRuntimeProcess(
  [string] $executable,
  [string[]] $arguments,
  [string] $supportDirectory
) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $executable
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Environment["PATH"] = Join-Path $env:SystemRoot "System32"
  $startInfo.Environment["SystemRoot"] = $env:SystemRoot
  $startInfo.Environment["WINDIR"] = $env:WINDIR
  $startInfo.Environment["GRAPHCODE_SUPPORT_DIR"] = $supportDirectory
  foreach ($argument in $arguments) {
    [void] $startInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Failed to start clean-environment process: $executable"
  }
  [void] $process.Handle
  return $process
}

function Install-AtomicRuntimePackage([string] $sourceDirectory, [string] $destinationDirectory) {
  $files = @(
    Get-ChildItem -LiteralPath $sourceDirectory -File |
      Where-Object {
        $_.Name -in @("graphcoded.exe", "graphcode.exe") -or
        $_.Extension -ieq ".dll"
      }
  )
  if (-not ($files | Where-Object Extension -ieq ".dll")) {
    throw "Runtime package has no Swift DLLs: $sourceDirectory"
  }
  $parent = Split-Path -Parent $destinationDirectory
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $packageRoot = Join-Path $parent ".graphcode-packages"
  New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
  $staging = Join-Path $packageRoot "$([guid]::NewGuid())"
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  $version = Join-Path $staging ".graphcode-package.version"
  Set-Content -LiteralPath $version -Value ([guid]::NewGuid().ToString()) -NoNewline
  $backup = Join-Path $parent ".graphcode-rollback-$([guid]::NewGuid())"
  try {
    foreach ($file in $files) {
      Copy-Item -LiteralPath $file.FullName `
        -Destination (Join-Path $staging $file.Name) -Force
    }
    if (Test-Path -LiteralPath $destinationDirectory) {
      Move-Item -LiteralPath $destinationDirectory -Destination $backup
    }
    try {
      Move-Item -LiteralPath $staging -Destination $destinationDirectory
    } catch {
      if (Test-Path -LiteralPath $backup) {
        Move-Item -LiteralPath $backup -Destination $destinationDirectory
      }
      throw
    }
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Native([string] $description, [scriptblock] $command) {
  Write-Host "==> $description"
  & $command
  if ($LASTEXITCODE -ne 0) {
    throw "$description failed with exit code $LASTEXITCODE"
  }
}

function Get-WindowsShellProfileSnapshot([string] $path) {
  $fullPath = [IO.Path]::GetFullPath($path)
  if (-not (Test-Path -LiteralPath $fullPath)) {
    return ([ordered]@{
        path = $fullPath
        exists = $false
        entries = @()
      } | ConvertTo-Json -Compress -Depth 5)
  }

  $root = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  $entries = [Collections.Generic.List[object]]::new()
  if (-not $root.PSIsContainer) {
    $entries.Add([ordered]@{
        relativePath = "."
        type = "file"
        length = [int64] $root.Length
        sha256 = (Get-FileHash -LiteralPath $root.FullName -Algorithm SHA256).Hash
      })
  } else {
    foreach ($item in @(Get-ChildItem -LiteralPath $fullPath -Force -Recurse |
        Sort-Object FullName)) {
      $relativePath = [IO.Path]::GetRelativePath($fullPath, $item.FullName).
        Replace('\', '/')
      if ($item.PSIsContainer) {
        $entries.Add([ordered]@{
            relativePath = $relativePath
            type = "directory"
          })
      } else {
        $entries.Add([ordered]@{
            relativePath = $relativePath
            type = "file"
            length = [int64] $item.Length
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
          })
      }
    }
  }

  return ([ordered]@{
      path = $fullPath
      exists = $true
      entries = $entries.ToArray()
    } | ConvertTo-Json -Compress -Depth 5)
}

function Assert-WindowsShellProfileUnchanged(
  [string] $path,
  [string] $before
) {
  $after = Get-WindowsShellProfileSnapshot $path
  if (-not [string]::Equals($before, $after, [StringComparison]::Ordinal)) {
    $beforeState = $before | ConvertFrom-Json
    $afterState = $after | ConvertFrom-Json
    $beforeEntries = @{}
    $afterEntries = @{}
    foreach ($entry in @($beforeState.entries)) { $beforeEntries[$entry.relativePath] = $entry }
    foreach ($entry in @($afterState.entries)) { $afterEntries[$entry.relativePath] = $entry }
    $changes = [Collections.Generic.List[string]]::new()
    if ([bool]$beforeState.exists -ne [bool]$afterState.exists) {
      $changes.Add("root:$($beforeState.exists)->$($afterState.exists)")
    }
    foreach ($relativePath in @($beforeEntries.Keys + $afterEntries.Keys | Sort-Object -Unique)) {
      if (-not $beforeEntries.ContainsKey($relativePath)) {
        $changes.Add("added:$relativePath")
      } elseif (-not $afterEntries.ContainsKey($relativePath)) {
        $changes.Add("removed:$relativePath")
      } elseif (($beforeEntries[$relativePath] | ConvertTo-Json -Compress) -cne
          ($afterEntries[$relativePath] | ConvertTo-Json -Compress)) {
        $changes.Add("changed:$relativePath")
      }
    }
    $summary = @($changes | Select-Object -First 20) -join ","
    throw "Windows shell default profile artifact changed: $([IO.Path]::GetFullPath($path)); changes=$summary"
  }
}

function Invoke-WindowsShellValidationIsolation(
  [Parameter(Mandatory)]
  [scriptblock] $Action,
  [string] $WorkspaceRoot = $repoRoot,
  [string] $ValidationRootParent,
  [string] $UserProfileRoot = $env:USERPROFILE,
  [string] $LocalAppDataRoot = $env:LOCALAPPDATA
) {
  $defaultSupport = Join-Path $UserProfileRoot ".graphcode"
  $defaultLocalAppData = Join-Path $LocalAppDataRoot "GraphCode"
  $supportBefore = Get-WindowsShellProfileSnapshot $defaultSupport
  $localAppDataBefore = Get-WindowsShellProfileSnapshot $defaultLocalAppData
  $validationRoot = if ($ValidationRootParent) {
    $parent = [IO.Path]::GetFullPath($ValidationRootParent)
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Join-Path $parent ([guid]::NewGuid().ToString("N"))
  } else {
    Join-Path $WorkspaceRoot (
      ".build\windows-shell-validation\" + [guid]::NewGuid().ToString("N")
    )
  }
  $ownedEnvironment = [ordered]@{
    GRAPHCODE_VALIDATION_ROOT = $validationRoot
    GRAPHCODE_SUPPORT_DIR = Join-Path $validationRoot "support"
    LOCALAPPDATA = Join-Path $validationRoot "local-app-data"
    TEMP = Join-Path $validationRoot "temp"
    TMP = Join-Path $validationRoot "temp"
  }
  $savedEnvironment = @{}
  foreach ($name in $ownedEnvironment.Keys) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable(
      $name,
      [EnvironmentVariableTarget]::Process
    )
  }

  $primaryError = $null
  $cleanupErrors = [Collections.Generic.List[Exception]]::new()
  try {
    New-Item -ItemType Directory -Force -Path @(
      $ownedEnvironment.GRAPHCODE_SUPPORT_DIR,
      $ownedEnvironment.LOCALAPPDATA,
      $ownedEnvironment.TEMP
    ) | Out-Null
    foreach ($entry in $ownedEnvironment.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable(
        $entry.Key,
        $entry.Value,
        [EnvironmentVariableTarget]::Process
      )
    }
    Write-Host "WINDOWS_SHELL_VALIDATION_ISOLATION_ROOT=$validationRoot"
    & $Action
  } catch {
    $primaryError = $_
  } finally {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
      try {
        [Environment]::SetEnvironmentVariable(
          $entry.Key,
          $entry.Value,
          [EnvironmentVariableTarget]::Process
        )
      } catch {
        $cleanupErrors.Add($_.Exception)
      }
    }
    try {
      Remove-Item -LiteralPath $validationRoot -Recurse -Force -ErrorAction Stop
    } catch {
      if (-not (
          $_.Exception -is [Management.Automation.ItemNotFoundException] -or
          $_.Exception -is [IO.DirectoryNotFoundException]
        )) {
        $cleanupErrors.Add($_.Exception)
      }
    }
    try {
      Assert-WindowsShellProfileUnchanged $defaultSupport $supportBefore
    } catch {
      $cleanupErrors.Add($_.Exception)
    }
    try {
      Assert-WindowsShellProfileUnchanged $defaultLocalAppData $localAppDataBefore
    } catch {
      $cleanupErrors.Add($_.Exception)
    }
    if ($cleanupErrors.Count -eq 0) {
      Write-Host "WINDOWS_SHELL_DEFAULT_PROFILE_UNCHANGED=verified"
    }
  }

  if ($null -ne $primaryError) {
    if ($cleanupErrors.Count -eq 0) {
      throw $primaryError
    }
    $failures = [Collections.Generic.List[Exception]]::new()
    $failures.Add($primaryError.Exception)
    foreach ($cleanupError in $cleanupErrors) {
      $failures.Add($cleanupError)
    }
    throw [AggregateException]::new(
      "Windows shell validation failed and isolation cleanup detected additional errors.",
      $failures.ToArray()
    )
  }
  if ($cleanupErrors.Count -eq 1) {
    throw $cleanupErrors[0]
  }
  if ($cleanupErrors.Count -gt 1) {
    throw [AggregateException]::new(
      "Windows shell validation isolation cleanup detected multiple errors.",
      $cleanupErrors.ToArray()
    )
  }
}

# Builds the release graphcoded/graphcode products and stages the pinned Swift
# runtime DLLs beside them. Both the shell integration smoke and real packaging
# consume this, so a packaging-only run no longer depends on a prior shell run.
function Build-SwiftReleaseRuntime([string] $swift, [string] $purpose) {
  $swiftBin = Split-Path $swift
  foreach ($product in @("graphcoded", "graphcode")) {
    Invoke-Native "Swift release build for ${purpose}: $product" {
      & (Join-Path $swiftBin "swift-build.exe") `
        --package-path $repoRoot `
        --configuration release `
        --product $product
    } | Out-Host
  }
  $binPath = & (Join-Path $swiftBin "swift-build.exe") `
    --package-path $repoRoot `
    --configuration release `
    --show-bin-path
  if ($LASTEXITCODE -ne 0) {
    throw "Swift release bin path lookup for $purpose failed"
  }
  $binPath = $binPath | Select-Object -Last 1
  $swiftRuntime = Resolve-SwiftRuntimeDirectory $swift
  Get-ChildItem -LiteralPath $swiftRuntime -Filter *.dll |
    Copy-Item -Destination $binPath -Force
  return $binPath
}

function Assert-PinnedProvider([string] $root, [string] $expectedSha, [string] $label) {
  if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
    throw "$label provider root is not a Git worktree: $root"
  }
  $status = @(git -C $root status --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw "$label provider status failed or the worktree is dirty"
  }
  $actual = git -C $root rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or $actual -ne $expectedSha) {
    throw "$label provider does not match the pinned commit"
  }
}

# Real packaging consumes the Swift release products, the pinned Winghostty host
# library, and the pinned zmx package directory. Build them here so the real
# packaging part can run on its own runner in parallel with the shell task.
function Initialize-PackagingInputs {
  $swift = Resolve-SwiftExecutable
  Initialize-SwiftEnvironment $swift
  [void] (Build-SwiftReleaseRuntime $swift "packaging")
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = if ($env:GRAPHCODE_WINGHOSTTY_ROOT) { $env:GRAPHCODE_WINGHOSTTY_ROOT } else {
    Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $zmxRoot = if ($env:GRAPHCODE_ZMX_ROOT) { $env:GRAPHCODE_ZMX_ROOT } else {
    Join-Path $depotRoot "zmx-worktrees\quickchat-hang"
  }
  $pins = Get-Content (Join-Path $repoRoot "graphcode-windows\provider-pins.json") -Raw |
    ConvertFrom-Json
  Assert-PinnedProvider $winghosttyRoot $pins.winghostty.sha "Winghostty"
  Assert-PinnedProvider $zmxRoot $pins.zmx.sha "zmx"
  $zig0152 = Resolve-ZigVersion "0.15.2" "GRAPHCODE_ZIG0152"
  $zig0160 = Resolve-ZigVersion "0.16.0" "GRAPHCODE_ZIG0160"
  Invoke-Native "Pinned Winghostty host build for packaging" {
    Push-Location $winghosttyRoot
    try { & $zig0152 build -Demit-win32-host=true } finally { Pop-Location }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $winghosttyRoot "zig-out\lib\winghostty-win32-host.lib") -PathType Leaf)) {
    throw "Pinned Winghostty host build did not produce the packaging library"
  }
  # Packaging.Tests.ps1 copies zig-pkg into an isolated zmx clone and builds it
  # there; fetching the hash-pinned dependencies is all it needs from this root.
  Invoke-Native "Pinned zmx provider dependency fetch for packaging" {
    Push-Location $zmxRoot
    try { & $zig0160 build --fetch } finally { Pop-Location }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $zmxRoot "zig-pkg") -PathType Container)) {
    throw "Pinned zmx provider fetch did not produce zig-pkg"
  }
}

function Invoke-ZigResolverProbe([string] $candidate, [string] $operation) {
  $output = [Collections.Generic.List[object]]::new()
  $errors = [Collections.Generic.List[string]]::new()
  $exitCode = $null
  $failure = $null
  try {
    & $candidate $operation 2>&1 | ForEach-Object {
      if ($_ -is [Management.Automation.ErrorRecord]) {
        $errors.Add($_.ToString())
      } else {
        $output.Add($_)
      }
    }
    $exitCode = $LASTEXITCODE
  } catch {
    $failure = $_
    if ($_.Exception.PSObject.Properties["ExitCode"] -and $_.Exception.ExitCode -is [int]) {
      $exitCode = $_.Exception.ExitCode
    }
  }
  [pscustomobject]@{
    Output = $(if ($output.Count -eq 1) { $output[0] } elseif ($output.Count -gt 1) { $output.ToArray() } else { $null })
    ErrorText = $errors -join "`n"
    ExitCode = $exitCode
    Failure = $failure
  }
}

function Write-ZigResolverDiagnostic(
  [string] $candidate, [string] $source, [string] $expectedVersion,
  [Nullable[bool]] $exists, [string] $reason, $versionProbe, $envProbe
) {
  try {
    $diagnostic = [ordered]@{
      candidate = $(if ($candidate.Length -le 512 -and $candidate -match '^(?:[A-Za-z]:\\|\\\\)' -and
          $candidate -notmatch '://|[\r\n\x00@]|(?i:gh[pousr]_|github_pat_|bearer |token=|password=|authorization)') { $candidate } else { "[omitted]" })
      source = $source
      expectedVersion = $expectedVersion
      exists = $exists
      reason = $reason
      version = $null
      env = $null
    }
    foreach ($entry in @(@{ Name = "version"; Probe = $versionProbe }, @{ Name = "env"; Probe = $envProbe })) {
      if ($null -eq $entry.Probe) { continue }
      $probe = $entry.Probe
      $exception = if ($null -ne $probe.Failure) { $probe.Failure.Exception } else { $null }
      $nativeErrorCode = $null
      for ($depth = 0; $null -ne $exception -and $depth -lt 4; $depth++) {
        if ($exception.PSObject.Properties["NativeErrorCode"] -and $exception.NativeErrorCode -is [int]) {
          $nativeErrorCode = $exception.NativeErrorCode
          break
        }
        $exception = $exception.InnerException
      }
      $summary = [ordered]@{
        exitCode = $probe.ExitCode
        exitCodeHex = $(if ($null -ne $probe.ExitCode) { "0x{0:X8}" -f ([int64]$probe.ExitCode -band 0xffffffffL) } else { $null })
        outputEncoding = "UTF8-of-captured-PowerShell-lines"
        exceptionType = $(if ($null -ne $probe.Failure) { $probe.Failure.Exception.GetType().FullName } else { $null })
        nativeErrorCode = $nativeErrorCode
        observedVersion = $null
      }
      $stdout = @($probe.Output) -join "`n"
      foreach ($stream in @(@{ Name = "stdout"; Text = $stdout }, @{ Name = "stderr"; Text = $probe.ErrorText })) {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$stream.Text)
        $summary[$stream.Name] = @{
          bytes = $bytes.Length
          sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        }
      }
      $summary.stderr.reason = "unclassified"
      foreach ($known in @("unable to find zig installation directory", "unable to find lib directory", "Access is denied")) {
        if ($probe.ErrorText -match [regex]::Escape($known)) {
          $summary.stderr.reason = $known
          break
        }
      }
      if ($entry.Name -eq "version" -and [Text.Encoding]::UTF8.GetByteCount($stdout) -le 64 -and
          $stdout -cmatch '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}(?:[-+][0-9A-Za-z.-]{1,40})?\z') {
        $summary.observedVersion = $stdout
      }
      if ($entry.Name -eq "env") {
        $summary.parse = "not-inspected"
        $summary.libDirectoryCheck = "not-run"
        $summary.libDirectoryPresent = $null
        # These are metadata only: the existing resolver accepts any successful env exit.
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -le 16384) {
          try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
            $summary.parse = if ($null -eq $parsed) { "empty" } else { "parsed" }
            if ($parsed.version -is [string] -and [Text.Encoding]::UTF8.GetByteCount($parsed.version) -le 64 -and
                $parsed.version -cmatch '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\z') {
              $summary.observedVersion = $parsed.version
            }
            if ($parsed.lib_dir -is [string] -and $parsed.lib_dir.Length -le 512 -and
                $parsed.lib_dir -match '^[A-Za-z]:\\' -and $parsed.lib_dir -notmatch '[\r\n\x00]') {
              try {
                $summary.libDirectoryPresent = Test-Path -LiteralPath $parsed.lib_dir -PathType Container -ErrorAction Stop
                $summary.libDirectoryCheck = "queried"
              } catch {
                $summary.libDirectoryCheck = "query-failed"
              }
            }
          } catch {
            $summary.parse = "metadata-unavailable"
          }
        }
      }
      $diagnostic[$entry.Name] = $summary
    }
    Write-Host ("ZIG_RESOLVER_DIAGNOSTIC " + ($diagnostic | ConvertTo-Json -Compress -Depth 5))
  } catch {
    try {
      Write-Warning -WarningAction Continue "Zig resolver diagnostic could not be emitted; selection requirements are unchanged."
    } catch {
      # Neither output channel is reliable; diagnostics must not replace resolver results.
    }
  }
}

function Resolve-ZigVersion([string] $version, [string] $environmentName) {
  $candidates = @()
  $configured = [Environment]::GetEnvironmentVariable($environmentName)
  if ($configured) {
    $candidates += $configured
  }
  $command = Get-Command zig.exe -ErrorAction SilentlyContinue
  if ($command) {
    $candidates += $command.Source
  }
  $worktrees = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $candidates += Get-ChildItem $worktrees -Recurse -Filter zig.exe `
    -File -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

  foreach ($candidate in $candidates | Select-Object -Unique) {
    $source = if ($candidate -eq $configured) { "configured" } elseif ($command -and $candidate -in $command.Source) { "PATH" } else { "worktree-search" }
    $exists = Test-Path -LiteralPath $candidate -PathType Leaf
    if (-not $exists) {
      Write-ZigResolverDiagnostic $candidate $source $version $exists "candidate-missing" $null $null
      continue
    }
    $versionProbe = Invoke-ZigResolverProbe $candidate "version"
    if ($null -ne $versionProbe.Failure) {
      Write-ZigResolverDiagnostic $candidate $source $version $exists "version-exception" $versionProbe $null
      throw "Zig version probe failed; candidate selection stopped."
    }
    if ($versionProbe.ExitCode -ne 0 -or $versionProbe.Output -ne $version) {
      $reason = if ($versionProbe.ExitCode -ne 0) { "version-exit" } else { "version-mismatch" }
      Write-ZigResolverDiagnostic $candidate $source $version $exists $reason $versionProbe $null
      continue
    }
    $envProbe = Invoke-ZigResolverProbe $candidate "env"
    if ($null -ne $envProbe.Failure) {
      Write-ZigResolverDiagnostic $candidate $source $version $exists "env-exception" $versionProbe $envProbe
      throw "Zig env probe failed; candidate selection stopped."
    }
    if ($envProbe.ExitCode -eq 0) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
    Write-ZigResolverDiagnostic $candidate $source $version $exists "env-exit" $versionProbe $envProbe
  }
  throw "Zig $version is required for the pinned Windows provider; set $environmentName."
}

function Resolve-ProviderRoots([string] $defaultZmxWorktree, [string] $label) {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
  if (-not $winghosttyRoot) {
    $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
  }
  $zmxRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX_ROOT")
  if (-not $zmxRoot) {
    $zmxRoot = Join-Path $depotRoot $defaultZmxWorktree
  }
  if (-not (Test-Path -LiteralPath $winghosttyRoot -PathType Container) -or
    -not (Test-Path -LiteralPath $zmxRoot -PathType Container)) {
    throw "$label provider worktrees unavailable; real smoke is mandatory."
  }
  [pscustomobject]@{
    Winghostty = $winghosttyRoot
    Zmx = $zmxRoot
    Zig0152 = Resolve-ZigVersion "0.15.2" "GRAPHCODE_ZIG0152"
    Zig0160 = Resolve-ZigVersion "0.16.0" "GRAPHCODE_ZIG0160"
  }
}

# The single build-only provider compile (Tools\windows\provider-build.ps1),
# shared by the provider-build and terminal-gate tasks.
function Invoke-ProviderBuild([object] $roots) {
  Invoke-Native "Pinned provider build (build-only)" {
    & (Join-Path $repoRoot "Tools\windows\provider-build.ps1") `
      -WinghosttyRoot $roots.Winghostty `
      -ZmxRoot $roots.Zmx `
      -Zig0152 $roots.Zig0152 `
      -Zig0160 $roots.Zig0160
  }
}

function Invoke-Task([string] $name) {
  if ($DryRun) {
    $detail = ""
    if ($name -eq "windows-shell") { $detail = " part=$ShellPart shard=$ShellTestShard/$ShellTestShardCount" }
    if ($name -eq "packaging") { $detail = " part=$PackagingPart" }
    Write-Output "task=$name$detail"
    return
  }
  Write-Host "task=$name"

  $swiftTasks = @(
    "swift-portable",
    "swift-contracts",
    "swift-production",
    "swift-paths",
    "swift-process",
    "swift-named-pipe",
    "swift-format"
  )
  if ($swiftTasks -contains $name) {
    $swift = Resolve-SwiftExecutable
    Initialize-SwiftEnvironment $swift
    $swiftBin = Split-Path $swift
  }

  switch ($name) {
    "swift-portable" {
      & (Join-Path $repoRoot "investigation\spikes\swift-portable\prepare.ps1")
      Invoke-Native "Swift portable-domain tests" {
        & (Join-Path $swiftBin "swift-test.exe") `
          --package-path (Join-Path $repoRoot "investigation\spikes\swift-portable")
      }
    }
    "swift-contracts" {
      & (Join-Path $repoRoot "investigation\spikes\swift-contracts\prepare.ps1")
      Invoke-Native "Swift platform-contract tests" {
        & (Join-Path $swiftBin "swift-test.exe") `
          --package-path (Join-Path $repoRoot "investigation\spikes\swift-contracts")
      }
    }
    "swift-production" {
      Invoke-Native "Swift production Windows package tests" {
        & (Join-Path $swiftBin "swift-test.exe") `
          --package-path $repoRoot
      }
      foreach ($product in @("graphcoded", "graphcode")) {
        Invoke-Native "Swift production release build: $product" {
          & (Join-Path $swiftBin "swift-build.exe") `
            --package-path $repoRoot `
            --configuration release `
            --product $product
        }
      }
      $releaseBin = & (Join-Path $swiftBin "swift-build.exe") `
        --package-path $repoRoot `
        --configuration release `
        --show-bin-path
      if ($LASTEXITCODE -ne 0) {
        throw "Swift production release bin path lookup failed"
      }
      $releaseBin = $releaseBin | Select-Object -Last 1
      $runtimeDirectory = Resolve-SwiftRuntimeDirectory $swift
      $runtimeDLLs = Get-ChildItem -LiteralPath $runtimeDirectory -Filter *.dll
      if (-not $runtimeDLLs) {
        throw "Swift runtime DLL directory is empty: $runtimeDirectory"
      }
      foreach ($runtimeDLL in $runtimeDLLs) {
        Copy-Item -LiteralPath $runtimeDLL.FullName -Destination $releaseBin -Force
      }
      Write-Host "Copied $($runtimeDLLs.Count) Swift runtime DLLs to $releaseBin"
      foreach ($product in @("graphcoded.exe", "graphcode.exe")) {
        $binary = Join-Path $releaseBin $product
        if (-not (Test-Path $binary)) {
          throw "Swift production binary was not produced: $binary"
        }
      }
      $smokeSupport = Join-Path $repoRoot ".build\windows-clean-runtime-smoke-$([guid]::NewGuid())"
      New-Item -ItemType Directory -Force $smokeSupport | Out-Null
      $installedBin = Join-Path $smokeSupport "bin"
      Install-AtomicRuntimePackage $releaseBin $installedBin
      $redirectedProfileScratch = Join-Path $env:TEMP "graphcode-g558-$([guid]::NewGuid())"
      try {
        Invoke-Native "Redirected USERPROFILE daemon regression" {
          & (Join-Path $repoRoot "Tools\windows\Tests\RedirectedUserProfileDaemon.Tests.ps1") `
            -DaemonExecutable (Join-Path $installedBin "graphcoded.exe") `
            -ScratchRoot $redirectedProfileScratch
        }
      } finally {
        Remove-Item -LiteralPath $redirectedProfileScratch -Recurse -Force `
          -ErrorAction SilentlyContinue
      }
      $daemonProcess = $null
      $secondDaemonProcess = $null
      $cliProcess = $null
      try {
        $daemonProcess = @(Start-CleanRuntimeProcess `
          (Join-Path $installedBin "graphcoded.exe") @() $smokeSupport)[-1]
        if ($null -eq $daemonProcess) {
          throw "clean-environment daemon process was not returned"
        }
        Start-Sleep -Milliseconds 1000
        if ($daemonProcess.HasExited) {
          throw "graphcoded.exe exited during clean-environment smoke"
        }

        $secondDaemonProcess = @(Start-CleanRuntimeProcess `
          (Join-Path $installedBin "graphcoded.exe") @() $smokeSupport)[-1]
        if ($null -eq $secondDaemonProcess) {
          throw "second clean-environment daemon process was not returned"
        }
        $secondStdoutTask = $secondDaemonProcess.StandardOutput.ReadToEndAsync()
        $secondStderrTask = $secondDaemonProcess.StandardError.ReadToEndAsync()
        if ($null -eq $secondStdoutTask -or $null -eq $secondStderrTask) {
          throw "second clean-environment daemon output tasks were not created"
        }
        if (-not $secondDaemonProcess.WaitForExit(5000)) {
          $secondDaemonProcess.Kill()
          $secondDaemonProcess.WaitForExit()
          throw "second graphcoded.exe did not exit after singleton rejection"
        }
        $secondDaemonProcess.Refresh()
        $secondStderr = $secondStderrTask.Result
        if ($secondDaemonProcess.ExitCode -eq 0 -or
          $secondStderr -notmatch "already running") {
          throw "second graphcoded.exe did not reject the singleton cleanly: $secondStderr"
        }

        $cliProcess = @(Start-CleanRuntimeProcess `
          (Join-Path $installedBin "graphcode.exe") @("projects") $smokeSupport)[-1]
        if ($null -eq $cliProcess) {
          throw "clean-environment CLI process was not returned"
        }
        $stdoutTask = $cliProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $cliProcess.StandardError.ReadToEndAsync()
        if ($null -eq $stdoutTask -or $null -eq $stderrTask) {
          throw "clean-environment CLI output tasks were not created"
        }
        $cliProcess.WaitForExit()
        $cliProcess.Refresh()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($cliProcess.ExitCode -ne 0) {
          throw "clean-environment graphcode.exe failed: $stderr"
        }
        Write-Host "Clean-environment daemon/CLI bootstrap smoke passed"
      } finally {
        if ($cliProcess -and -not $cliProcess.HasExited) {
          $cliProcess.Kill()
          $cliProcess.WaitForExit()
        }
        if ($secondDaemonProcess -and -not $secondDaemonProcess.HasExited) {
          $secondDaemonProcess.Kill()
          $secondDaemonProcess.WaitForExit()
        }
        if ($daemonProcess -and -not $daemonProcess.HasExited) {
          $daemonProcess.Kill()
          $daemonProcess.WaitForExit()
        }
        Remove-Item -LiteralPath $smokeSupport -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    "swift-paths" {
      Invoke-Native "Swift Windows path spike" {
        & (Join-Path $swiftBin "swift-run.exe") `
          --package-path (Join-Path $repoRoot "investigation\spikes\swift-paths")
      }
    }
    "swift-process" {
      Invoke-Native "Swift Windows process spike" {
        & (Join-Path $swiftBin "swift-run.exe") `
          --package-path (Join-Path $repoRoot "investigation\spikes\swift-process")
      }
    }
    "swift-named-pipe" {
      Invoke-Native "Swift Named Pipe spike" {
        & (Join-Path $swiftBin "swift-run.exe") `
          --package-path (Join-Path $repoRoot "investigation\spikes\swift-named-pipe")
      }
    }
    "remote-bridge" {
      $python = Get-Command python.exe -ErrorAction SilentlyContinue
      if (-not $python) {
        throw "Python 3 was not found for the remote-bridge fixture"
      }
      Invoke-Native "Python remote bridge proof" {
        & $python.Source -B `
          (Join-Path $repoRoot "investigation\spikes\remote-bridge\run_tests.py")
      }
      & (Join-Path $repoRoot "Tools\windows\Tests\RemoteBridgePrivacyRace.Tests.ps1")
      if ($LASTEXITCODE -ne 0) {
        throw "Remote bridge privacy race regression failed with exit code $LASTEXITCODE"
      }
    }
    "remote-e2e" {
      $python = Get-Command python.exe -ErrorAction SilentlyContinue
      if (-not $python) {
        throw "Python 3 was not found for the remote E2E fixture"
      }
      $arguments = @(
        "-B",
        (Join-Path $repoRoot "investigation\spikes\remote-e2e\test_remote_e2e.py"),
        "-v"
      )
      if ($SkipWslRemoteE2E) {
        $arguments += "--skip-local-wsl"
      }
      Invoke-Native "Windows-to-POSIX remote E2E parity" {
        & $python.Source @arguments
      }
    }
    "swift-format" {
      $formatter = Join-Path $swiftBin "swift-format.exe"
      if (-not (Test-Path $formatter)) {
        throw "swift-format.exe was not found next to $swift"
      }
      $sources = Get-ChildItem `
        (Join-Path $repoRoot "investigation\spikes") `
        -Recurse -Filter *.swift |
        Where-Object {
          $_.FullName -notmatch "[\\/]\.build[\\/]" -and
          $_.FullName -notmatch
            "[\\/]swift-(full|portable|contracts)[\\/]Sources[\\/]"
        } |
        Select-Object -ExpandProperty FullName
      $sources += Get-ChildItem `
        (Join-Path $repoRoot "GraphcodeKit\Sources\Platform") `
        -Filter *.swift |
        Select-Object -ExpandProperty FullName
      $sources += @(
        (Join-Path $repoRoot "GraphcodeKit\Sources\SupportDirectory.swift"),
        (Join-Path $repoRoot "GraphcodeKit\Sources\ProjectPersistence.swift"),
        (Join-Path $repoRoot "GraphcodeKit\Sources\IPC\WindowsNamedPipeTransport.swift"),
        (Join-Path $repoRoot "GraphcodeKit\Sources\IPC\WindowsRemoteBridge.swift"),
        (Join-Path $repoRoot "GraphcodeKit\Sources\IPC\DaemonConnectionChannel.swift"),
        (Join-Path $repoRoot "GraphcodeKit\Sources\IPC\DaemonSocketClient.swift"),
        (Join-Path $repoRoot "GraphcodeKit\Sources\IPC\DaemonSocketPath.swift"),
        (Join-Path $repoRoot "graphcoded\Sources\main.swift"),
        (Join-Path $repoRoot "windows-tests\WindowsDaemonTests.swift"),
        (Join-Path $repoRoot `
          "investigation\spikes\swift-full\Tests\GraphcodeKitWindowsTests\PlatformTests.swift")
      )
      foreach ($source in $sources) {
        $temporary = Join-Path $env:TEMP "graphcode-format-$([guid]::NewGuid()).swift"
        try {
          $content = [IO.File]::ReadAllText($source).Replace("`r`n", "`n")
          [IO.File]::WriteAllText(
            $temporary,
            $content,
            [Text.UTF8Encoding]::new($false)
          )
          Invoke-Native "Swift formatting: $source" {
            & $formatter lint --strict `
              --configuration (Join-Path $repoRoot ".swift-format") `
              $temporary
          }
        } finally {
          Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
      }
    }
    "visual-baseline" {
      Invoke-Native "Windows visual baseline contract" {
        & (Join-Path $repoRoot "Tools\windows\Tests\VisualBaseline.Tests.ps1")
      }
      Write-Host "==> Windows/macOS palette parity contract"
      $paletteResults = Invoke-Pester `
        -Script (Join-Path $repoRoot "Tools\windows\Tests\PaletteParity.Tests.ps1") `
        -PassThru
      if ($paletteResults.TotalCount -le 0 -or $paletteResults.PassedCount -le 0 -or
          $paletteResults.FailedCount -ne 0) {
        throw "Palette parity Pester contract did not pass a nonzero test count"
      }
    }
    "tdd-evidence" {
      & (Join-Path $repoRoot "Tools\tdd\Tests\TddEvidence.Tests.ps1")
      if ($LASTEXITCODE -ne 0) {
        throw "TDD evidence tests failed with exit code $LASTEXITCODE"
      }
    }
    "privacy" {
      $files = Get-ChildItem (Join-Path $repoRoot "investigation") -Recurse -File |
        Where-Object {
          $_.FullName -notmatch "[\\/]\.build[\\/]" -and
          $_.FullName -notmatch "[\\/]\.zig-cache[\\/]" -and
          $_.FullName -notmatch "[\\/]zig-out[\\/]"
        }
      $streams = foreach ($file in $files) {
        Get-Item -LiteralPath $file.FullName -Stream * -ErrorAction SilentlyContinue |
          Where-Object Stream -notin @(':$DATA', 'sec.endpointdlp')
      }
      if ($streams) {
        throw "Investigation files contain non-default NTFS streams."
      }

      $generated = Get-ChildItem `
        (Join-Path $repoRoot "investigation\spikes") `
        -Recurse -File |
        Where-Object {
          $_.FullName -notmatch "[\\/]\.build[\\/]" -and
          $_.FullName -notmatch "[\\/]\.zig-cache[\\/]" -and
          $_.FullName -notmatch "[\\/]zig-out[\\/]"
        } |
        Where-Object {
          $_.Extension -in ".exe", ".obj", ".lib", ".exp", ".log" -or
          $_.Name -eq "ready.txt"
        }
      if ($generated) {
        throw "Generated spike artifacts remain under investigation/spikes."
      }

      $forbidden = @(
        [regex]::Escape($repoRoot.Path),
        [regex]::Escape($env:USERPROFILE),
        "GraphCode-worktrees",
        "Visual Studio\\[0-9]{4}\\(Enterprise|BuildTools)"
      )
      foreach ($file in $files) {
        if ($file.Extension -notin
          ".md", ".swift", ".c", ".py", ".ps1", ".resolved", ".json", ".txt" -and
          $file.Name -ne ".gitignore") {
          continue
        }
        try {
          $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        } catch {
          if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
            $_.Exception -is [System.IO.FileNotFoundException]) {
            continue
          }
          throw
        }
        foreach ($pattern in $forbidden) {
          if ($content -match $pattern) {
            throw "Environment-specific content matched '$pattern' in $($file.FullName)"
          }
        }
      }
      Write-Host "Privacy checks passed"
    }
    "provider-build" {
      $roots = Resolve-ProviderRoots "zmx-worktrees\quickchat-hang" "Pinned provider build"
      Invoke-ProviderBuild $roots
    }
    "terminal-gate" {
      & (Join-Path $repoRoot "Tools\windows\Tests\ProviderPins.Tests.ps1")
      & (Join-Path $repoRoot "Tools\windows\Tests\TerminalGate.Tests.ps1")
      if ($LASTEXITCODE -ne 0) {
        throw "Windows terminal gate contract failed with exit code $LASTEXITCODE"
      }
      $roots = Resolve-ProviderRoots "zmx-worktrees\attach" "Windows terminal gate"
      Invoke-ProviderBuild $roots
      Invoke-Native "Pinned Windows terminal gate build and smoke" {
        & (Join-Path $repoRoot "Tools\windows\terminal-gate.ps1") `
          -WinghosttyRoot $roots.Winghostty `
          -ZmxRoot $roots.Zmx `
          -Zig0152 $roots.Zig0152 `
          -Zig0160 $roots.Zig0160 `
          -SkipProviderBuild `
          -Stress
      }
    }
    "windows-shell" {
      Write-Host "==> Windows shell validation isolation contract"
      $isolationResults = Invoke-Pester `
        -Script (Join-Path $repoRoot "Tools\windows\Tests\ValidationIsolation.Tests.ps1") `
        -PassThru
      if ($isolationResults.TotalCount -le 0 -or
          $isolationResults.PassedCount -ne $isolationResults.TotalCount -or
          $isolationResults.FailedCount -ne 0) {
        throw "Windows shell validation isolation contract did not pass a nonzero test count"
      }
      Write-Host "WINDOWS_SHELL_ISOLATION_CONTRACT_CASES=$($isolationResults.TotalCount)"
      $uiaProductProcessBaseline = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
      )
      $initialUiaProductProcesses = @(Get-CimInstance Win32_Process -Filter `
        "Name = 'graphcode-windows.exe' OR Name = 'graphcoded.exe'" -ErrorAction Stop)
      foreach ($candidate in $initialUiaProductProcesses) {
        $identity = "$([int]$candidate.ProcessId)|$($candidate.CreationDate.ToUniversalTime().ToString('o'))"
        [void]$uiaProductProcessBaseline.Add($identity)
      }
      Write-Host ("WINDOWS_SHELL_PREVALIDATION_PRODUCT_PROCESSES=" +
        (ConvertTo-Json -InputObject @($initialUiaProductProcesses | ForEach-Object {
          [ordered]@{
            processId = [int]$_.ProcessId
            name = $_.Name
            executablePath = $_.ExecutablePath
            sessionId = [int]$_.SessionId
          }
        }) -Compress -Depth 4))
      $zig0152 = Resolve-ZigVersion "0.15.2" "GRAPHCODE_ZIG0152"
      $runShellUnit = $ShellPart -ne "integration"
      $runShellIntegration = $ShellPart -ne "unit"
      if ($runShellIntegration) {
        $swift = Resolve-SwiftExecutable
        Initialize-SwiftEnvironment $swift
        $daemonRuntime = Build-SwiftReleaseRuntime $swift "shell daemon handoff"
      }
      $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
      $winghosttyRoot = [Environment]::GetEnvironmentVariable(
        "GRAPHCODE_WINGHOSTTY_ROOT"
      )
      if (-not $winghosttyRoot) {
        $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
      }
      $zmxRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX_ROOT")
      if (-not $zmxRoot) {
        $zmxRoot = Join-Path $depotRoot "zmx-worktrees\quickchat-hang"
      }
      if (-not (Test-Path -LiteralPath $winghosttyRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $zmxRoot -PathType Container)) {
        throw "Windows shell provider worktrees unavailable; real smoke is mandatory."
      }
      $pins = Get-Content (Join-Path $repoRoot "graphcode-windows\provider-pins.json") -Raw |
        ConvertFrom-Json
      if (-not (Test-Path -LiteralPath (Join-Path $winghosttyRoot ".git"))) {
        throw "Winghostty provider root is not a Git worktree: $winghosttyRoot"
      }
      $providerStatus = @(git -C $winghosttyRoot status --porcelain --untracked-files=all)
      if ($LASTEXITCODE -ne 0 -or $providerStatus.Count -ne 0) {
        throw "Winghostty provider status failed or the worktree is dirty"
      }
      $actualWinghosttyPin = git -C $winghosttyRoot rev-parse HEAD
      if ($LASTEXITCODE -ne 0 -or $actualWinghosttyPin -ne $pins.winghostty.sha) {
        throw "Winghostty provider does not match the pinned commit"
      }
      Invoke-Native "Pinned Winghostty host build for App contracts" {
        Push-Location $winghosttyRoot
        try { & $zig0152 build -Demit-win32-host=true } finally { Pop-Location }
      }
      $winghosttyLib = Join-Path $winghosttyRoot "zig-out\lib\winghostty-win32-host.lib"
      if (-not (Test-Path -LiteralPath $winghosttyLib -PathType Leaf)) {
        throw "Pinned Winghostty host build did not produce the App test library"
      }
      if ($runShellUnit) {
        & (Join-Path $repoRoot "Tools\windows\Tests\WindowsShell.Tests.ps1") `
          -ZigExecutable $zig0152 `
          -Shard $ShellTestShard `
          -ShardCount $ShellTestShardCount `
          -SectionManifest $ShellTestManifest
        if ($LASTEXITCODE -ne 0) {
          throw "Windows shell scaffold contract failed with exit code $LASTEXITCODE"
        }
      }
      # The unit part ends here; `break` leaves this switch clause only.
      if (-not $runShellIntegration) { break }
      $zig0160 = Resolve-ZigVersion "0.16.0" "GRAPHCODE_ZIG0160"
      Invoke-Native "Pinned GraphCode Windows shell build and smoke" {
        & (Join-Path $repoRoot "Tools\windows\windows-shell.ps1") `
          -WinghosttyRoot $winghosttyRoot `
          -ZmxRoot $zmxRoot `
          -Zig0152 $zig0152 `
          -Zig0160 $zig0160 `
          -DaemonRuntimeDirectory $daemonRuntime `
          -UseStubDaemon `
          -StubResponseDelayMilliseconds 150 `
          -SkipTrayLive:$SkipTrayLive `
          -Stress
      }
      Invoke-Native "Scrubbed production shell startup" {
        & pwsh -NoProfile -File `
          (Join-Path $repoRoot "Tools\windows\Tests\ScrubbedShellStartup.Live.Tests.ps1") `
          -Shell (Join-Path $repoRoot "graphcode-windows\zig-out\bin\graphcode-windows.exe") `
          -Daemon (Join-Path $daemonRuntime "graphcoded.exe") `
          -Cli (Join-Path $daemonRuntime "graphcode.exe") `
          -ScratchRoot (Join-Path $env:TEMP "scrubbed-shell-startup")
      }
      Invoke-Native "Real daemon wire round trip" {
        & pwsh -NoProfile -File `
          (Join-Path $repoRoot "Tools\windows\Tests\DaemonRoundTrip.Live.Tests.ps1") `
          -DaemonExecutable (Join-Path $daemonRuntime "graphcoded.exe") `
          -ZigExecutable $zig0152 `
          -WinghosttyInclude (Join-Path $winghosttyRoot "include") `
          -ScratchRoot (Join-Path $env:TEMP "daemon-roundtrip")
      }
      & (Join-Path $repoRoot "Tools\windows\Tests\TrayDaemon.Tests.ps1") `
        -Executable (Join-Path $repoRoot "graphcode-windows\zig-out\bin\graphcode-windows.exe")
      if ($LASTEXITCODE -ne 0) {
        throw "Tray daemon executable tests failed with exit code $LASTEXITCODE"
      }
      $zmxExecutable = Join-Path $zmxRoot "zig-out\bin\zmx.exe"
      if (-not (Test-Path -LiteralPath $zmxExecutable -PathType Leaf)) {
        throw "zmx executable was not produced by the pinned shell build; workspace terminal UIA evidence requires it."
      }
      $preUiaProcesses = @(Get-CimInstance Win32_Process -Filter `
        "Name = 'graphcode-windows.exe' OR Name = 'graphcoded.exe'" -ErrorAction Stop)
      $preUiaSnapshot = @($preUiaProcesses | ForEach-Object {
        $identity = "$([int]$_.ProcessId)|$($_.CreationDate.ToUniversalTime().ToString('o'))"
        [ordered]@{
          processId = [int]$_.ProcessId
          parentProcessId = [int]$_.ParentProcessId
          name = $_.Name
          executablePath = $_.ExecutablePath
          creationDate = $_.CreationDate.ToUniversalTime().ToString("o")
          sessionId = [int]$_.SessionId
          existedBeforeValidation = $uiaProductProcessBaseline.Contains($identity)
        }
      })
      Write-Host ("WINDOWS_SHELL_PRE_UIA_PROCESS_SNAPSHOT=" +
        (ConvertTo-Json -InputObject $preUiaSnapshot -Compress -Depth 4))
      $repositoryPrefix = ([IO.Path]::GetFullPath($repoRoot)).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
      $ownedSurvivors = @($preUiaProcesses | Where-Object {
        $identity = "$([int]$_.ProcessId)|$($_.CreationDate.ToUniversalTime().ToString('o'))"
        $_.ExecutablePath -and
          $_.ExecutablePath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase) -and
          -not $uiaProductProcessBaseline.Contains($identity)
      })
      foreach ($survivor in $ownedSurvivors) {
        $current = Get-CimInstance Win32_Process -Filter `
          "ProcessId = $([int]$survivor.ProcessId)" -ErrorAction Stop
        if ($null -eq $current -or
            [string]$current.CreationDate -cne [string]$survivor.CreationDate) {
          continue
        }
        Stop-Process -Id ([int]$survivor.ProcessId) -Force -ErrorAction Stop
      }
      $remainingSurvivors = @()
      foreach ($survivor in $ownedSurvivors) {
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
          $current = Get-CimInstance Win32_Process -Filter `
            "ProcessId = $([int]$survivor.ProcessId)" -ErrorAction Stop
          if ($null -eq $current -or
              [string]$current.CreationDate -cne [string]$survivor.CreationDate) {
            break
          }
          Start-Sleep -Milliseconds 100
        }
        $current = Get-CimInstance Win32_Process -Filter `
          "ProcessId = $([int]$survivor.ProcessId)" -ErrorAction Stop
        if ($null -ne $current -and
            [string]$current.CreationDate -ceq [string]$survivor.CreationDate) {
          $remainingSurvivors += [int]$survivor.ProcessId
        }
      }
      if ($remainingSurvivors.Count -gt 0) {
        throw "Owned GraphCode processes survived pre-UIA cleanup: $($remainingSurvivors -join ',')"
      }
      Write-Host "WINDOWS_SHELL_PRE_UIA_CLEANUP=verified terminated=$($ownedSurvivors.Count)"
      Invoke-Native "Native UI Automation live gate" {
        & (Join-Path $repoRoot "Tools\windows\uia-live-gate.ps1") `
          -Shell (Join-Path $repoRoot "graphcode-windows\zig-out\bin\graphcode-windows.exe") `
          -Zmx $zmxExecutable
      }
    }
    "packaging" {
      if ($PackagingPart -ne "real") {
        & (Join-Path $repoRoot "Tools\windows\Tests\SourceCustody.Tests.ps1")
        if ($LASTEXITCODE -ne 0) {
          throw "Windows source custody tests failed with exit code $LASTEXITCODE"
        }
        & (Join-Path $repoRoot "Tools\windows\Tests\Release.Tests.ps1")
        & (Join-Path $repoRoot "Tools\windows\Tests\PreviewCore.Tests.ps1")
        & (Join-Path $repoRoot "Tools\windows\Tests\Packaging.Signing.Tests.ps1")
        & (Join-Path $repoRoot "Tools\windows\Tests\Packaging.ScriptSigning.Tests.ps1")
        & (Join-Path $repoRoot "Tools\windows\Tests\Packaging.Scheduler.Tests.ps1")
        & (Join-Path $repoRoot "Tools\windows\Tests\Packaging.Rollback.Tests.ps1")
        & (Join-Path $repoRoot "Tools\windows\Tests\Packaging.Uninstall.Tests.ps1")
        & (Join-Path $repoRoot "Tools\windows\Tests\Packaging.Standalone.Tests.ps1")
      }
      if ($PackagingPart -ne "contracts") {
        Initialize-PackagingInputs
        & (Join-Path $repoRoot "Tools\windows\Tests\Packaging.Tests.ps1")
        if ($LASTEXITCODE -ne 0) {
          throw "Windows packaging tests failed with exit code $LASTEXITCODE"
        }
      }
    }
    "hardening" {
      if ($env:GRAPHCODE_HARDENING_TARGET) {
        & (Join-Path $repoRoot "Tools\windows\Tests\Hardening.Tests.ps1") -Environment
      } else {
        & (Join-Path $repoRoot "Tools\windows\Tests\Hardening.Tests.ps1")
      }
      if ($LASTEXITCODE -ne 0) {
        throw "Windows hardening tests failed with exit code $LASTEXITCODE"
      }
    }
  }
}

$selected = @(@($buildOnlyTasks) + @($tasks) | Where-Object {
    (($Task -contains "all" -and $buildOnlyTasks -notcontains $_) -or $Task -contains $_) -and
      $SkipTask -notcontains $_
  })
if ($selected.Count -eq 0) {
  throw "No validation tasks remain after applying -Task $($Task -join ',') and -SkipTask $($SkipTask -join ',')"
}
try {
  foreach ($name in $selected) {
    if ($name -eq "windows-shell" -and -not $DryRun) {
      Invoke-WindowsShellValidationIsolation -ValidationRootParent $ShellValidationRoot -Action {
        Invoke-Task "windows-shell"
      }
    } else {
      Invoke-Task $name
    }
  }
} finally {
  $junctions = @()
  if ($selected -contains "swift-portable") {
    $junctions += @(
      (Join-Path $repoRoot `
        "investigation\spikes\swift-portable\Sources\GraphcodePortableDomain"),
      (Join-Path $repoRoot `
        "investigation\spikes\swift-portable\Sources\MailroomKit")
    )
  }
  if ($selected -contains "swift-contracts") {
    $junctions += @(
      (Join-Path $repoRoot `
        "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\Domain"),
      (Join-Path $repoRoot `
        "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\IPC"),
      (Join-Path $repoRoot `
        "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\MailroomKit"),
      (Join-Path $repoRoot `
        "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\Platform")
    )
    $junctions += Join-Path $repoRoot `
      "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\SupportDirectory.swift"
  }
  foreach ($junction in $junctions) {
    if (Test-Path -LiteralPath $junction) {
      $item = Get-Item -LiteralPath $junction -Force
      if ($item.PSIsContainer) {
        [System.IO.Directory]::Delete($item.FullName, $false)
      } else {
        [System.IO.File]::Delete($item.FullName)
      }
    }
  }
}
