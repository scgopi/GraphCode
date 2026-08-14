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
    "swift-format",
    "visual-baseline",
    "tdd-evidence",
    "privacy"
  )]
  [string] $Task = "all",
  [switch] $List,
  [switch] $DryRun,
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
  "swift-format",
  "visual-baseline",
  "tdd-evidence",
  "privacy"
)

if ($List) {
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
  $env:PATH = "$toolBin;$env:PATH"

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
    if (Test-Path $sdk) {
      $env:SDKROOT = $sdk
    }
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

function Invoke-Task([string] $name) {
  if ($DryRun) {
    Write-Output "task=$name"
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
      $daemonProcess = $null
      $secondDaemonProcess = $null
      $cliProcess = $null
      try {
        $daemonProcess = Start-CleanRuntimeProcess `
          (Join-Path $installedBin "graphcoded.exe") @() $smokeSupport
        Start-Sleep -Milliseconds 1000
        if ($daemonProcess.HasExited) {
          throw "graphcoded.exe exited during clean-environment smoke"
        }

        $secondDaemonProcess = Start-CleanRuntimeProcess `
          (Join-Path $installedBin "graphcoded.exe") @() $smokeSupport
        $secondStdoutTask = $secondDaemonProcess.StandardOutput.ReadToEndAsync()
        $secondStderrTask = $secondDaemonProcess.StandardError.ReadToEndAsync()
        if (-not $secondDaemonProcess.WaitForExit(5000)) {
          $secondDaemonProcess.Kill()
          $secondDaemonProcess.WaitForExit()
          throw "second graphcoded.exe did not exit after singleton rejection"
        }
        $secondStderr = $secondStderrTask.GetAwaiter().GetResult()
        if ($secondDaemonProcess.ExitCode -eq 0 -or
          $secondStderr -notmatch "already running") {
          throw "second graphcoded.exe did not reject the singleton cleanly: $secondStderr"
        }

        $cliProcess = Start-CleanRuntimeProcess `
          (Join-Path $installedBin "graphcode.exe") @("projects") $smokeSupport
        $stdoutTask = $cliProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $cliProcess.StandardError.ReadToEndAsync()
        $cliProcess.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
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
        & $python.Source -B -m unittest discover `
          -s (Join-Path $repoRoot "investigation\spikes\remote-bridge") `
          -p "test_*.py" -v
      }
      & (Join-Path $repoRoot "Tools\windows\Tests\RemoteBridgePrivacyRace.Tests.ps1")
      if ($LASTEXITCODE -ne 0) {
        throw "Remote bridge privacy race regression failed with exit code $LASTEXITCODE"
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
    }
    "tdd-evidence" {
      & (Join-Path $repoRoot "Tools\tdd\Tests\TddEvidence.Tests.ps1")
      if ($LASTEXITCODE -ne 0) {
        throw "TDD evidence tests failed with exit code $LASTEXITCODE"
      }
    }
    "privacy" {
      $files = Get-ChildItem (Join-Path $repoRoot "investigation") -Recurse -File |
        Where-Object { $_.FullName -notmatch "[\\/]\.build[\\/]" }
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
        Where-Object { $_.FullName -notmatch "[\\/]\.build[\\/]" } |
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
  }
}

$selected = if ($Task -eq "all") { $tasks } else { @($Task) }
try {
  foreach ($name in $selected) {
    Invoke-Task $name
  }
} finally {
  $junctions = @()
  if ($selected -contains "swift-portable") {
    $junctions += Join-Path $repoRoot `
      "investigation\spikes\swift-portable\Sources\GraphcodePortableDomain"
  }
  if ($selected -contains "swift-contracts") {
    $junctions += @(
      (Join-Path $repoRoot `
        "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\Domain"),
      (Join-Path $repoRoot `
        "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\IPC"),
      (Join-Path $repoRoot `
        "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\Platform")
    )
    $junctions += Join-Path $repoRoot `
      "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\SupportDirectory.swift"
  }
  foreach ($junction in $junctions) {
    if (Test-Path $junction) {
      Remove-Item -LiteralPath $junction -Force
    }
  }
}
