[CmdletBinding()]
param(
  [string] $ToolRoot,
  [string] $ProviderRoot,
  [switch] $SkipSwift,
  [string] $ZigBaseUrl = $env:GRAPHCODE_ZIG_MIRROR,
  [ValidateRange(0, 20)]
  [int] $ZigRetryCount = 3,
  [ValidateRange(1, 3600)]
  [int] $ZigStallTimeoutSeconds = 30,
  [ValidateRange(1, 86400)]
  [int] $ZigOverallTimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"
# Suppress built-in archive progress; Zig downloads emit throttled byte/rate/ETA
# lines instead of PowerShell's high-overhead per-record rendering.
$ProgressPreference = "SilentlyContinue"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $PSScriptRoot "DotNetSdk.ps1")
if (-not $ToolRoot) {
  $ToolRoot = Join-Path $repoRoot ".graphcode-tools"
}
if (-not $ProviderRoot) {
  $ProviderRoot = Join-Path $ToolRoot "providers"
}
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$ProviderRoot = [IO.Path]::GetFullPath($ProviderRoot)
if (-not $ZigBaseUrl) {
  $ZigBaseUrl = "https://ziglang.org"
}
$ZigBaseUrl = $ZigBaseUrl.TrimEnd("/")

function Test-BootstrapPathBudget(
    [string] $RepositoryRoot,
    [string] $Providers,
    [scriptblock] $WarningSink
  ) {
  $legacyMaxPath = 259
  $providerProbe = Join-Path (Join-Path $Providers "winghostty") (
    "test\fuzz-libghostty\corpus\parser-cmin\" +
    "id_000213,time_0,execs_0,orig_id_001278,src_001266,time_20982," +
    "execs_1128131,op_quick,pos_31,val_+2,+cov")
  $worktreeProbe = Join-Path $RepositoryRoot (
    "graphcode-windows\.zig-cache\" +
    "worktree-process-00000000000000000000000000000000\" +
    "removal-output-selected-00000000000000000000000000000000\" +
    "outside\.git\objects")
  $overBudget = @($providerProbe, $worktreeProbe |
      Where-Object { $_.Length -gt $legacyMaxPath })
  if ($overBudget.Count -eq 0) {
    return
  }

  $lengths = $overBudget | ForEach-Object { $_.Length }
  $message = (
    "GraphCode Windows bootstrap path budget warning: projected paths reach " +
    "$($lengths -join ', ') characters, above legacy MAX_PATH " +
    "($legacyMaxPath). Use a short checkout such as C:\src\GraphCode and, " +
    "when needed, pass -ToolRoot C:\gc-tools -ProviderRoot C:\gc-providers. " +
    "Provider Git operations enable repository-local core.longpaths=true, " +
    "but other Windows tools and tests can still fail at this depth.")
  if ($WarningSink) {
    & $WarningSink $message
  } else {
    Write-Warning $message -WarningAction Continue
  }
}

Test-BootstrapPathBudget $repoRoot $ProviderRoot
New-Item -ItemType Directory -Force $ToolRoot, $ProviderRoot | Out-Null
$dotnet = Resolve-GraphCodeDotNetSdk -RepositoryRoot $repoRoot -ToolRoot $ToolRoot -InstallIfMissing

function Format-ZigDownloadSize([long] $Bytes) {
  if ($Bytes -lt 1KB) {
    return "$Bytes bytes"
  }
  if ($Bytes -lt 1MB) {
    return "$([Math]::Round($Bytes / 1KB, 1)) KiB"
  }
  return "$([Math]::Round($Bytes / 1MB, 1)) MiB"
}

function Write-ZigDownloadProgress(
    [long] $Downloaded,
    [Nullable[long]] $Total,
    [long] $Transferred,
    [double] $ElapsedSeconds
  ) {
  $rate = if ($ElapsedSeconds -gt 0) {
    $Transferred / $ElapsedSeconds
  } else {
    0
  }
  $message = "Zig download: $(Format-ZigDownloadSize $Downloaded)"
  if ($null -ne $Total) {
    $message += " / $(Format-ZigDownloadSize $Total)"
  }
  if ($rate -gt 0) {
    $message += " at $(Format-ZigDownloadSize ([long] $rate))/s"
    if ($null -ne $Total -and $Downloaded -lt $Total) {
      $etaSeconds = [Math]::Ceiling(($Total - $Downloaded) / $rate)
      $message += ", ETA $([TimeSpan]::FromSeconds($etaSeconds).ToString("g"))"
    }
  }
  Write-Host $message
}

function Invoke-ZigHttpDownloadAttempt(
    [uri] $Uri,
    [string] $PartialPath,
    [long] $Offset,
    [int] $StallTimeoutSeconds,
    [datetime] $OverallDeadline,
    [int] $ProgressIntervalSeconds
  ) {
  $client = [Net.Http.HttpClient]::new()
  $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
  $request = [Net.Http.HttpRequestMessage]::new(
    [Net.Http.HttpMethod]::Get,
    $Uri)
  if ($Offset -gt 0) {
    $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new(
      $Offset,
      $null)
  }

  $response = $null
  $contentStream = $null
  $fileStream = $null
  try {
    $remaining = $OverallDeadline - [datetime]::UtcNow
    if ($remaining.TotalMilliseconds -le 0) {
      throw [TimeoutException]::new("Zig download exceeded its overall timeout")
    }
    $headerTimeout = [Math]::Min(
      $StallTimeoutSeconds,
      [Math]::Max(0.001, $remaining.TotalSeconds))
    $headerCancellation = [Threading.CancellationTokenSource]::new(
      [TimeSpan]::FromSeconds($headerTimeout))
    try {
      try {
        $response = $client.Send(
          $request,
          [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
          $headerCancellation.Token)
      } catch [OperationCanceledException] {
        if ([datetime]::UtcNow -ge $OverallDeadline) {
          throw [TimeoutException]::new(
            "Zig download exceeded its overall timeout waiting for response headers")
        }
        throw [TimeoutException]::new(
          "Zig download stalled waiting for response headers")
      }
    } finally {
      $headerCancellation.Dispose()
    }

    $append = $Offset -gt 0 -and
      $response.StatusCode -eq [Net.HttpStatusCode]::PartialContent
    if ($append) {
      $rangeStart = $response.Content.Headers.ContentRange.From
      if ($null -eq $rangeStart -or $rangeStart -ne $Offset) {
        Remove-Item -LiteralPath $PartialPath -Force -ErrorAction SilentlyContinue
        throw [IO.InvalidDataException]::new(
          "Zig download returned an invalid Content-Range for offset $Offset")
      }
    } elseif ($Offset -gt 0 -and
        $response.StatusCode -eq [Net.HttpStatusCode]::RequestedRangeNotSatisfiable) {
      Remove-Item -LiteralPath $PartialPath -Force -ErrorAction SilentlyContinue
      throw [IO.InvalidDataException]::new(
        "Zig download server rejected the partial archive range; restarting is required")
    } elseif ($Offset -gt 0 -and
        $response.StatusCode -eq [Net.HttpStatusCode]::OK) {
      Write-Host "Zig download server ignored Range; restarting this attempt."
      $Offset = 0
    } else {
      [void] $response.EnsureSuccessStatusCode()
      $Offset = 0
    }

    $total = $null
    $contentRangeLength = if ($response.Content.Headers.ContentRange) {
      $response.Content.Headers.ContentRange.Length
    } else {
      $null
    }
    if ($null -ne $contentRangeLength) {
      $total = [Nullable[long]] $contentRangeLength
    } elseif ($null -ne $response.Content.Headers.ContentLength) {
      $total = [Nullable[long]] (
        $Offset + $response.Content.Headers.ContentLength)
    }

    $mode = if ($append) {
      [IO.FileMode]::OpenOrCreate
    } else {
      [IO.FileMode]::Create
    }
    $fileStream = [IO.File]::Open(
      $PartialPath,
      $mode,
      [IO.FileAccess]::Write,
      [IO.FileShare]::Read)
    if ($append) {
      $fileStream.SetLength($Offset)
      $fileStream.Position = $Offset
    }
    $contentStream = $response.Content.ReadAsStream()
    $buffer = [byte[]]::new(1MB)
    $downloaded = $Offset
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastProgress = [datetime]::UtcNow
    while ($true) {
      $remaining = $OverallDeadline - [datetime]::UtcNow
      if ($remaining.TotalMilliseconds -le 0) {
        throw [TimeoutException]::new("Zig download exceeded its overall timeout")
      }
      $readTimeout = [Math]::Min(
        $StallTimeoutSeconds,
        [Math]::Max(0.001, $remaining.TotalSeconds))
      $readCancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($readTimeout))
      try {
        try {
          $read = $contentStream.ReadAsync(
            $buffer,
            0,
            $buffer.Length,
            $readCancellation.Token).GetAwaiter().GetResult()
        } catch [OperationCanceledException] {
          if ([datetime]::UtcNow -ge $OverallDeadline) {
            throw [TimeoutException]::new(
              "Zig download exceeded its overall timeout")
          }
          throw [TimeoutException]::new(
            "Zig download stalled for $StallTimeoutSeconds seconds")
        }
      } finally {
        $readCancellation.Dispose()
      }
      if ($read -eq 0) {
        break
      }
      $fileStream.Write($buffer, 0, $read)
      $downloaded += $read
      $now = [datetime]::UtcNow
      if (($now - $lastProgress).TotalSeconds -ge $ProgressIntervalSeconds) {
        Write-ZigDownloadProgress `
          $downloaded `
          $total `
          ($downloaded - $Offset) `
          $stopwatch.Elapsed.TotalSeconds
        $lastProgress = $now
      }
    }
    $fileStream.Flush()
    Write-ZigDownloadProgress `
      $downloaded `
      $total `
      ($downloaded - $Offset) `
      $stopwatch.Elapsed.TotalSeconds
    if ($null -ne $total -and $downloaded -ne $total) {
      throw [IO.EndOfStreamException]::new(
        "Zig download ended at $downloaded of $total bytes")
    }
  } finally {
    if ($fileStream) {
      $fileStream.Dispose()
    }
    if ($contentStream) {
      $contentStream.Dispose()
    }
    if ($response) {
      $response.Dispose()
    }
    $request.Dispose()
    $client.Dispose()
  }
}

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
  $partialArchive = "$archive.partial"
  if (Test-Path -LiteralPath $archive -PathType Leaf) {
    if ((Get-FileHash $archive -Algorithm SHA256).Hash -eq $Sha256) {
      Write-Host "Reusing checksum-verified Zig $Version archive: $archive"
      Remove-Item `
        -LiteralPath $partialArchive `
        -Force `
        -ErrorAction SilentlyContinue
    } else {
      Write-Warning "Removing corrupt cached Zig $Version archive: $archive"
      Remove-Item -LiteralPath $archive -Force
    }
  }

  if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    $baseUri = [uri] $ZigBaseUrl
    if (-not $baseUri.IsAbsoluteUri -or
        $baseUri.Scheme -notin @("http", "https")) {
      throw "Zig base URL must be an absolute HTTP or HTTPS URL: $ZigBaseUrl"
    }
    $uri = [uri] (
      "$($ZigBaseUrl.TrimEnd('/'))/download/$Version/" +
      "zig-x86_64-windows-$Version.zip")
    $maxAttempts = $ZigRetryCount + 1
    $deadline = [datetime]::UtcNow.AddSeconds($ZigOverallTimeoutSeconds)
    $progressInterval = if ($env:CI) { 60 } else { 10 }
    $completed = $false
    $attemptsMade = 0
    $lastFailure = ""
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
      if ([datetime]::UtcNow -ge $deadline) {
        $lastFailure = "overall timeout of $ZigOverallTimeoutSeconds seconds expired"
        break
      }
      $attemptsMade = $attempt
      $offset = if (Test-Path -LiteralPath $partialArchive -PathType Leaf) {
        (Get-Item -LiteralPath $partialArchive).Length
      } else {
        0
      }
      $startDescription = if ($offset -gt 0) {
        "resuming at $(Format-ZigDownloadSize $offset)"
      } else {
        "starting from zero"
      }
      Write-Host (
        "Downloading Zig $Version, attempt $attempt/$maxAttempts, " +
        "$startDescription from $($uri.Host).")
      try {
        Invoke-ZigHttpDownloadAttempt `
          -Uri $uri `
          -PartialPath $partialArchive `
          -Offset $offset `
          -StallTimeoutSeconds $ZigStallTimeoutSeconds `
          -OverallDeadline $deadline `
          -ProgressIntervalSeconds $progressInterval
        $actualHash = (Get-FileHash $partialArchive -Algorithm SHA256).Hash
        if ($actualHash -ne $Sha256) {
          Remove-Item -LiteralPath $partialArchive -Force
          throw [IO.InvalidDataException]::new(
            "Zig $Version archive checksum mismatch from $uri")
        }
        Move-Item -LiteralPath $partialArchive -Destination $archive -Force
        Write-Host "Verified Zig $Version archive checksum."
        $completed = $true
        break
      } catch {
        $lastFailure = $_.Exception.Message
        if ($attempt -lt $maxAttempts -and [datetime]::UtcNow -lt $deadline) {
          Write-Warning (
            "Zig $Version download attempt $attempt failed: $lastFailure " +
            "Retrying with the partial archive when available.")
          Start-Sleep -Seconds ([Math]::Min($attempt, 5))
        }
      }
    }
    if (-not $completed) {
      $partialState = if (
        Test-Path -LiteralPath $partialArchive -PathType Leaf
      ) {
        "Partial archive preserved for the next run: $partialArchive"
      } else {
        "No resumable partial archive remains."
      }
      throw (
        "Downloading Zig $Version failed after $attemptsMade attempts: " +
        "$lastFailure. $partialState")
    }
  }

  $extracted = Join-Path $ToolRoot "zig-x86_64-windows-$Version"
  if (Test-Path -LiteralPath $extracted) {
    Remove-Item -LiteralPath $extracted -Recurse -Force
  }
  # The Windows inbox bsdtar extracts the checksum-verified archive an order of
  # magnitude faster than Expand-Archive; fall back when it is unavailable.
  $tar = Join-Path $env:SystemRoot "System32\tar.exe"
  $expanded = $false
  if (Test-Path -LiteralPath $tar -PathType Leaf) {
    & $tar -xf $archive -C $ToolRoot
    $expanded = $LASTEXITCODE -eq 0
    if (-not $expanded -and (Test-Path -LiteralPath $extracted)) {
      Remove-Item -LiteralPath $extracted -Recurse -Force
    }
  }
  if (-not $expanded) {
    Expand-Archive -LiteralPath $archive -DestinationPath $ToolRoot -Force
  }
  Move-Item `
    -LiteralPath (Join-Path $ToolRoot "zig-x86_64-windows-$Version") `
    -Destination $destination
  return $executable
}

function Install-Provider([object] $Pin, [string] $Name) {
  $destination = Join-Path $ProviderRoot $Name
  $gitDirectory = Join-Path $destination ".git"
  $checkoutMarker = Join-Path $gitDirectory "graphcode-bootstrap-checkout"
  $existingCheckout = Test-Path -LiteralPath $gitDirectory -PathType Container
  $recoverCheckout = $existingCheckout -and
    (Test-Path -LiteralPath $checkoutMarker -PathType Leaf)
  if (-not $existingCheckout) {
    git -c core.longpaths=true clone --no-checkout $Pin.remoteUrl $destination
    if ($LASTEXITCODE -ne 0) {
      throw "Cloning $Name failed"
    }
  }

  git -C $destination config --local core.longpaths true
  if ($LASTEXITCODE -ne 0) {
    throw "Configuring long-path support for $Name failed"
  }
  if ($existingCheckout -and -not $recoverCheckout) {
    $status = @(git -c core.longpaths=true -C $destination status `
        --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
      throw "Inspecting $Name provider checkout failed"
    }
    if ($status.Count -ne 0) {
      throw "$Name provider checkout is dirty: $destination"
    }
  }

  git -c core.longpaths=true -C $destination fetch --quiet origin $Pin.sha
  if ($LASTEXITCODE -ne 0) {
    throw "Fetching $Name pin $($Pin.sha) failed"
  }
  if (-not $recoverCheckout) {
    Set-Content -LiteralPath $checkoutMarker -Value $Pin.sha -NoNewline
  }
  if ($recoverCheckout) {
    git -c core.longpaths=true -C $destination checkout --force --quiet `
      --detach $Pin.sha
  } else {
    git -c core.longpaths=true -C $destination checkout --quiet --detach $Pin.sha
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Checking out $Name pin $($Pin.sha) failed"
  }
  $status = @(git -c core.longpaths=true -C $destination status `
      --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw "Inspecting $Name provider checkout failed"
  }
  if ($status.Count -ne 0) {
    throw "$Name provider checkout is dirty: $destination"
  }
  Remove-Item -LiteralPath $checkoutMarker -Force
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
  GRAPHCODE_DOTNET10403 = $dotnet
  DOTNET_ROOT = [IO.Path]::GetDirectoryName($dotnet)
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
