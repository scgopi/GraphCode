[CmdletBinding()]
param(
  [ValidateSet(
    "all",
    "swift-portable",
    "swift-contracts",
    "swift-paths",
    "swift-process",
    "swift-named-pipe",
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
  "swift-paths",
  "swift-process",
  "swift-named-pipe",
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

  if ($swift -match "^(.*\\Swift)\\Toolchains\\([^\\]+)\\usr\\bin\\swift\.exe$") {
    $swiftRoot = $Matches[1]
    $toolchainName = $Matches[2]
    $version = $toolchainName.Split("+")[0]
    $runtime = Join-Path $swiftRoot "Runtimes\$version\usr\bin"
    $sdk = Join-Path $swiftRoot "Platforms\$version\Windows.platform\Developer\SDKs\Windows.sdk"
    if (Test-Path $runtime) {
      $env:PATH = "$runtime;$env:PATH"
    }
    if (Test-Path $sdk) {
      $env:SDKROOT = $sdk
    }
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

  $swift = Resolve-SwiftExecutable
  Initialize-SwiftEnvironment $swift
  $swiftBin = Split-Path $swift

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
          Where-Object Stream -ne ':$DATA'
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
          ".md", ".swift", ".c", ".ps1", ".resolved", ".json", ".txt" -and
          $file.Name -ne ".gitignore") {
          continue
        }
        $content = Get-Content -LiteralPath $file.FullName -Raw
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
  }
  foreach ($junction in $junctions) {
    if (Test-Path $junction) {
      Remove-Item -LiteralPath $junction -Force
    }
  }
}
