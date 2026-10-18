[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\Import-PinnedPester.ps1")

BeforeAll {
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$bootstrapPath = Join-Path $repoRoot "Tools\windows\bootstrap.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $bootstrapPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Bootstrap script has parse errors: $errors" }
foreach ($name in @(
    "Test-BootstrapPathBudget",
    "Format-ZigDownloadSize",
    "Install-Zig",
    "Install-Provider"
  )) {
  $definition = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true)
  if ($definition) {
    . ([scriptblock]::Create($definition.Extent.Text))
  } elseif ($name -eq "Test-BootstrapPathBudget") {
    function Test-BootstrapPathBudget {}
  } else {
    throw "Bootstrap helper is missing: $name"
  }
}

function Write-TestArchiveBytes(
    [string] $Path,
    [byte[]] $Bytes,
    [long] $Offset
  ) {
  $stream = [IO.File]::Open(
    $Path,
    [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::Write,
    [IO.FileShare]::Read)
  try {
    $stream.SetLength($Offset)
    $stream.Position = $Offset
    $remaining = $Bytes.Length - [int] $Offset
    if ($remaining -gt 0) {
      $stream.Write($Bytes, [int] $Offset, $remaining)
    }
  } finally {
    $stream.Dispose()
  }
}
}

Describe "Windows bootstrap provider setup" {
  BeforeEach {
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) (
      "graphcode-bootstrap-" + [guid]::NewGuid().ToString("N"))
    $script:ProviderRoot = Join-Path $script:fixture "providers"
    [void][IO.Directory]::CreateDirectory($script:ProviderRoot)
    $script:gitCalls = [Collections.Generic.List[string]]::new()
    $script:statusOutput = @()
    $script:failNextCheckout = $false
    function script:git {
      $arguments = @($args | ForEach-Object { [string] $_ })
      $script:gitCalls.Add(($arguments -join [char]31))
      $global:LASTEXITCODE = 0
      if ($arguments -contains "clone") {
        [void][IO.Directory]::CreateDirectory(
          (Join-Path $arguments[-1] ".git"))
      }
      if ($arguments -contains "checkout" -and $script:failNextCheckout) {
        $script:failNextCheckout = $false
        $global:LASTEXITCODE = 1
        return
      }
      if ($arguments -contains "checkout" -and $arguments -contains "--force") {
        $script:statusOutput = @()
      }
      if ($arguments -contains "status") {
        return $script:statusOutput
      }
    }
    $script:pin = [pscustomobject]@{
      remoteUrl = "https://example.invalid/provider.git"
      sha = "0123456789012345678901234567890123456789"
    }
  }

  AfterEach {
    Remove-Item -LiteralPath $script:fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\git -ErrorAction SilentlyContinue
  }

  It "enables long paths for provider Git operations and persists local config" {
    $destination = Install-Provider $script:pin "winghostty"
    $separator = [char]31
    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "clone", "--no-checkout",
          $script:pin.remoteUrl, $destination) -join $separator)) | Should -Be $true
    ($script:gitCalls -contains (
        @("-C", $destination, "config", "--local", "core.longpaths", "true") -join $separator)) |
      Should -Be $true
    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "-C", $destination, "fetch", "--quiet",
          "origin", $script:pin.sha) -join $separator)) | Should -Be $true
    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "-C", $destination, "checkout", "--quiet",
          "--detach", $script:pin.sha) -join $separator)) | Should -Be $true
    Test-Path -LiteralPath (Join-Path $destination ".git\graphcode-bootstrap-checkout") |
      Should -Be $false
  }

  It "recovers a bootstrap-owned partial provider checkout" {
    $destination = Join-Path $script:ProviderRoot "winghostty"
    $marker = Join-Path $destination ".git\graphcode-bootstrap-checkout"
    $script:failNextCheckout = $true
    { Install-Provider $script:pin "winghostty" } |
      Should -Throw -ExpectedMessage "Checking out winghostty pin $($script:pin.sha) failed"
    Test-Path -LiteralPath $marker -PathType Leaf | Should -Be $true
    $script:statusOutput = @(" D missing-long-path-corpus")

    Install-Provider $script:pin "winghostty" | Should -Be $destination

    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "-C", $destination, "checkout", "--force",
          "--quiet", "--detach", $script:pin.sha) -join [char]31)) | Should -Be $true
    Test-Path -LiteralPath $marker | Should -Be $false
  }

  It "does not overwrite an unmarked dirty provider checkout" {
    $destination = Join-Path $script:ProviderRoot "winghostty"
    [void][IO.Directory]::CreateDirectory((Join-Path $destination ".git"))
    $script:statusOutput = @(" M contributor-change")

    { Install-Provider $script:pin "winghostty" } |
      Should -Throw -ExpectedMessage "winghostty provider checkout is dirty: $destination"
    @($script:gitCalls | Where-Object { $_ -match ([char]31 + "checkout" + [char]31) }).Count |
      Should -Be 0
  }

  It "warns when pinned provider or worktree fixtures exceed the legacy path budget" {
    $warnings = [Collections.Generic.List[string]]::new()
    $deepRoot = "C:\" + ("deep\" * 30) + "GraphCode"
    $deepProviders = Join-Path $deepRoot ".graphcode-tools\providers"

    Test-BootstrapPathBudget $deepRoot $deepProviders {
      param($message)
      $warnings.Add($message)
    }

    $warnings.Count | Should -Be 1
    $warnings[0] | Should -Match "legacy MAX_PATH"
    $warnings[0] | Should -Match ([regex]::Escape("C:\src\GraphCode"))
    $warnings[0] | Should -Match ([regex]::Escape("-ProviderRoot C:\gc-providers"))
  }

  It "does not warn for a short checkout and provider root" {
    $warnings = [Collections.Generic.List[string]]::new()
    Test-BootstrapPathBudget "C:\src\GraphCode" "C:\gc-providers" {
      param($message)
      $warnings.Add($message)
    }
    $warnings.Count | Should -Be 0
  }
}

Describe "Windows bootstrap Zig downloads" {
  BeforeEach {
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) (
      "graphcode-zig-download-" + [guid]::NewGuid().ToString("N"))
    $script:ToolRoot = Join-Path $script:fixture "tools"
    [void][IO.Directory]::CreateDirectory($script:ToolRoot)
    $script:version = "0.15.2-test"
    $script:expandedName = "zig-x86_64-windows-$($script:version)"
    $payloadRoot = Join-Path $script:fixture "payload"
    $payload = Join-Path $payloadRoot $script:expandedName
    [void][IO.Directory]::CreateDirectory($payload)
    Set-Content -LiteralPath (Join-Path $payload "zig.exe") -Value "fixture"
    $sourceArchive = Join-Path $script:fixture "source.zip"
    Compress-Archive -LiteralPath $payload -DestinationPath $sourceArchive
    $script:archiveBytes = [IO.File]::ReadAllBytes($sourceArchive)
    $script:sha256 = (Get-FileHash $sourceArchive -Algorithm SHA256).Hash
    $script:ZigBaseUrl = "https://ziglang.org"
    $script:ZigRetryCount = 2
    $script:ZigStallTimeoutSeconds = 1
    $script:ZigOverallTimeoutSeconds = 30
    $script:previousCI = $env:CI
    $script:downloadCalls = [Collections.Generic.List[object]]::new()
    $script:downloadBehavior = {
      param($Uri, $PartialPath, $Offset)
      Write-TestArchiveBytes $PartialPath $script:archiveBytes $Offset
    }

    function script:Invoke-WebRequest {
      param($Uri, $OutFile)
      $offset = if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
        (Get-Item -LiteralPath $OutFile).Length
      } else {
        0
      }
      $script:downloadCalls.Add([pscustomobject]@{
          Uri = [string] $Uri
          Offset = $offset
          Path = $OutFile
        })
      & $script:downloadBehavior $Uri $OutFile $offset
    }

    function script:Invoke-ZigHttpDownloadAttempt {
      param(
        $Uri,
        $PartialPath,
        $Offset,
        $StallTimeoutSeconds,
        $OverallDeadline,
        $ProgressIntervalSeconds
      )
      $script:downloadCalls.Add([pscustomobject]@{
          Uri = [string] $Uri
          Offset = [long] $Offset
          Path = $PartialPath
          StallTimeoutSeconds = [int] $StallTimeoutSeconds
          OverallDeadline = [datetime] $OverallDeadline
          ProgressIntervalSeconds = [int] $ProgressIntervalSeconds
        })
      & $script:downloadBehavior $Uri $PartialPath $Offset
    }

    function script:Start-Sleep {}
  }

  AfterEach {
    Remove-Item -LiteralPath $script:fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-ZigHttpDownloadAttempt -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    $env:CI = $script:previousCI
  }

  It "retries an interrupted transfer and resumes from the partial archive" {
    $split = [Math]::Floor($script:archiveBytes.Length / 3)
    $script:downloadBehavior = {
      param($Uri, $PartialPath, $Offset)
      if ($script:downloadCalls.Count -eq 1) {
        [IO.File]::WriteAllBytes(
          $PartialPath,
          $script:archiveBytes[0..($split - 1)])
        throw "fixture connection reset"
      }
      Write-TestArchiveBytes $PartialPath $script:archiveBytes $Offset
    }

    $executable = Install-Zig $script:version $script:sha256

    Test-Path -LiteralPath $executable -PathType Leaf | Should -Be $true
    $script:downloadCalls.Count | Should -Be 2
    $script:downloadCalls[0].Offset | Should -Be 0
    $script:downloadCalls[1].Offset | Should -Be $split
  }

  It "uses the configured mirror base while retaining the pinned archive name" {
    $script:ZigBaseUrl = "https://mirror.example.invalid/zig"

    Install-Zig $script:version $script:sha256 | Out-Null

    $script:downloadCalls.Count | Should -Be 1
    $script:downloadCalls[0].Uri | Should -Be (
      "https://mirror.example.invalid/zig/download/$($script:version)/" +
      "$($script:expandedName).zip")
  }

  It "passes bounded timeout settings and throttles progress in CI" {
    $script:ZigRetryCount = 0
    $script:ZigStallTimeoutSeconds = 7
    $script:ZigOverallTimeoutSeconds = 12
    $env:CI = "true"
    $started = [datetime]::UtcNow

    Install-Zig $script:version $script:sha256 | Out-Null

    $script:downloadCalls.Count | Should -Be 1
    $script:downloadCalls[0].StallTimeoutSeconds | Should -Be 7
    $script:downloadCalls[0].ProgressIntervalSeconds | Should -Be 60
    $script:downloadCalls[0].OverallDeadline | Should -BeGreaterThan $started.AddSeconds(10)
    $script:downloadCalls[0].OverallDeadline | Should -BeLessThan $started.AddSeconds(14)
  }

  It "reuses only a checksum-verified cached archive" {
    $archive = Join-Path $script:ToolRoot "zig-$($script:version).zip"
    $partial = "$archive.partial"
    [IO.File]::WriteAllBytes($archive, $script:archiveBytes)
    Set-Content -LiteralPath $partial -Value "stale partial"
    $script:downloadBehavior = { throw "verified cache should not download" }

    $executable = Install-Zig $script:version $script:sha256

    Test-Path -LiteralPath $executable -PathType Leaf | Should -Be $true
    $script:downloadCalls.Count | Should -Be 0
    Test-Path -LiteralPath $archive -PathType Leaf | Should -Be $true
    Test-Path -LiteralPath $partial | Should -Be $false
  }

  It "removes a corrupt cached archive before downloading its replacement" {
    $archive = Join-Path $script:ToolRoot "zig-$($script:version).zip"
    Set-Content -LiteralPath $archive -Value "corrupt cache"

    Install-Zig $script:version $script:sha256 | Out-Null

    $script:downloadCalls.Count | Should -Be 1
    (Get-FileHash $archive -Algorithm SHA256).Hash | Should -Be $script:sha256
  }

  It "removes checksum-mismatched completed downloads before retrying" {
    $script:downloadBehavior = {
      param($Uri, $PartialPath, $Offset)
      [IO.File]::WriteAllBytes($PartialPath, [Text.Encoding]::UTF8.GetBytes("bad"))
    }

    $message = ""
    try {
      Install-Zig $script:version $script:sha256 | Out-Null
      throw "Install-Zig unexpectedly accepted a checksum mismatch"
    } catch {
      $message = $_.Exception.Message
    }

    $script:downloadCalls.Count | Should -Be 3
    @($script:downloadCalls | Where-Object Offset -ne 0).Count | Should -Be 0
    $message | Should -Match "checksum mismatch"
    Test-Path (Join-Path $script:ToolRoot "zig-$($script:version).zip") |
      Should -Be $false
    Test-Path (Join-Path $script:ToolRoot "zig-$($script:version).zip.partial") |
      Should -Be $false
  }

  It "preserves a partial archive after the bounded retry budget is exhausted" {
    $script:downloadBehavior = {
      param($Uri, $PartialPath, $Offset)
      $stream = [IO.File]::Open(
        $PartialPath,
        [IO.FileMode]::Append,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read)
      try {
        $stream.WriteByte(42)
      } finally {
        $stream.Dispose()
      }
      throw "fixture stall"
    }

    $message = ""
    try {
      Install-Zig $script:version $script:sha256 | Out-Null
      throw "Install-Zig unexpectedly exceeded its retry budget"
    } catch {
      $message = $_.Exception.Message
    }

    $partial = Join-Path $script:ToolRoot "zig-$($script:version).zip.partial"
    $script:downloadCalls.Count | Should -Be 3
    (($script:downloadCalls | ForEach-Object Offset) -join ",") |
      Should -Be "0,1,2"
    $message | Should -Match "failed after 3 attempts"
    Test-Path -LiteralPath $partial -PathType Leaf | Should -Be $true
    (Get-Item -LiteralPath $partial).Length | Should -Be 3
  }

}
