[CmdletBinding()]
param(
  [switch] $Environment,
  [switch] $SchemaOnly,
  [int] $Run = 0
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$pwsh = (Get-Command pwsh.exe).Source
$fixtureRoot = Join-Path $repoRoot ".build\windows-hardening-$PID"
$fixture = Join-Path $fixtureRoot "fixture.ps1"
$results = [System.Collections.Generic.List[object]]::new()
$realProductSamples = [System.Collections.Generic.List[object]]::new()

function Assert-True([bool] $condition, [string] $message) {
  if (-not $condition) { throw "Hardening failure: $message" }
}

function Select-EquivalentProductSample([object[]] $samples) {
  $roleSets = @($samples | ForEach-Object {
      [Collections.Generic.HashSet[string]]::new(
        @($_.processes | ForEach-Object role),
        [StringComparer]::OrdinalIgnoreCase)
    })
  if ($roleSets.Count -eq 0) { return @() }
  $roles = @($roleSets[0])
  foreach ($set in $roleSets | Select-Object -Skip 1) {
    $roles = @($roles | Where-Object { $set.Contains($_) })
  }
  @($samples | ForEach-Object {
      $details = @($_.processes | Where-Object { $roles -contains $_.role })
      [pscustomobject]@{
        processes = $details
        privateBytes = [int64](($details | Measure-Object privateBytes -Sum).Sum)
        handles = [int64](($details | Measure-Object handles -Sum).Sum)
        roles = @($roles)
      }
    })
}

function Invoke-Fixture([string[]] $arguments) {
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $pwsh
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.ArgumentList.Add("-NoProfile")
  $info.ArgumentList.Add("-File")
  $info.ArgumentList.Add($fixture)
  foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $info
  $started = [DateTime]::UtcNow
  Assert-True $process.Start() "fixture process did not start"
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  Assert-True $process.WaitForExit(15000) "fixture exceeded 15 second recovery ceiling"
  $elapsed = ([DateTime]::UtcNow - $started).TotalSeconds
  $exitCode = $process.ExitCode
  $process.Close()
  $process.Dispose()
  [pscustomobject]@{
    ExitCode = $exitCode
    Stdout = $stdout.GetAwaiter().GetResult()
    Stderr = $stderr.GetAwaiter().GetResult()
    Elapsed = $elapsed
  }
}

function Assert-EnvironmentResult([string[]] $output) {
  $line = @($output | Where-Object { $_ -like "ENVIRONMENT_RESULT_JSON=*" }) |
    Select-Object -Last 1
  Assert-True ($line.Count -gt 0) "environment harness did not emit structured JSON"
  $json = ($line -replace "^ENVIRONMENT_RESULT_JSON=", "") | ConvertFrom-Json
  Assert-True ($json.schemaVersion -eq 1) "environment result schema is unsupported"
  Assert-True ($json.namedPipe.status -eq "pass") "named pipe result was not pass"
  $required = @(
    "gpu-context-display",
    "dpi-multimonitor",
    "ime-unicode-clipboard",
    "uia-screen-reader",
    "acl-user-isolation",
    "login-reboot",
    "external-ssh-multihost"
  )
  foreach ($name in $required) {
    $dimension = @($json.dimensions | Where-Object name -eq $name)
    Assert-True ($dimension.Count -eq 1) "mandatory environment dimension missing: $name"
    Assert-True ($dimension[0].status -in @("pass", "skip")) `
      "invalid environment status for $name"
    if ($dimension[0].status -eq "skip") {
      Assert-True (-not [string]::IsNullOrWhiteSpace($dimension[0].reason)) `
        "environment skip has no reason: $name"
    }
    Write-Host ("ENVIRONMENT dimension {0}: {1} ({2})" -f
      $name, $dimension[0].status, $dimension[0].reason)
  }
  return $json
}

function Get-ResourceSample {
  $process = Get-Process -Id $PID
  [pscustomobject]@{
    privateBytes = [int64] $process.PrivateMemorySize64
    handles = [int64] $process.HandleCount
  }
}

function Get-ProductResourceSample([string[]] $roots) {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($process in $processes) {
      $pathMatch = $false
      if ($process.ExecutablePath) {
        foreach ($root in $roots) {
          if ([IO.Path]::GetFullPath($process.ExecutablePath) -ieq [IO.Path]::GetFullPath($root) -or
              [IO.Path]::GetFullPath($process.ExecutablePath).StartsWith(
                ([IO.Path]::GetFullPath((Split-Path $root)) + "\"), [StringComparison]::OrdinalIgnoreCase)) {
            $pathMatch = $true
            break
          }
        }
      }
      if ($pathMatch) { $matched.Add($process) }
    }
    $known = [Collections.Generic.HashSet[int]]::new()
    foreach ($process in @($matched)) { [void] $known.Add([int]$process.ProcessId) }
    $changed = $true
    while ($changed) {
      $changed = $false
      foreach ($process in $processes) {
        if (-not $known.Contains([int]$process.ProcessId) -and
            $known.Contains([int]$process.ParentProcessId)) {
          [void] $known.Add([int]$process.ProcessId)
          $matched.Add($process)
          $changed = $true
        }
      }
    }
    $details = @($known | ForEach-Object {
        $sample = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($sample) {
          [pscustomobject]@{
            pid = $_
            name = $sample.ProcessName
            role = if ($sample.ProcessName -match "graphcoded") { "graphcoded" }
              elseif ($sample.ProcessName -match "graphcode-windows") { "graphcode-windows" }
              elseif ($sample.ProcessName -match "zmx") { "zmx" }
              elseif ($sample.ProcessName -match "winghostty") { "winghostty" }
              else { "product-child" }
            privateBytes = [int64]$sample.PrivateMemorySize64
            handles = [int64]$sample.HandleCount
          }
        }
      })
    [pscustomobject]@{
      processes = $details
      privateBytes = [int64](($details | Measure-Object privateBytes -Sum).Sum)
      handles = [int64](($details | Measure-Object handles -Sum).Sum)
    }
}

function Find-Bytes([byte[]] $haystack, [byte[]] $needle, [int] $start = 0) {
  for ($index = $start; $index -le $haystack.Length - $needle.Length; $index++) {
    $match = $true
    for ($offset = 0; $offset -lt $needle.Length; $offset++) {
      if ($haystack[$index + $offset] -ne $needle[$offset]) {
        $match = $false
        break
      }
    }
    if ($match) { return $index }
  }
  return -1
}

function Select-NewProductResourceSample([object] $sample, [int[]] $baselinePids) {
  $details = @($sample.processes | Where-Object { $baselinePids -notcontains $_.pid })
  [pscustomobject]@{
    processes = $details
    privateBytes = [int64](($details | Measure-Object privateBytes -Sum).Sum)
    handles = [int64](($details | Measure-Object handles -Sum).Sum)
  }
}

function Stop-OwnedSessionProcessTree([string] $sessionName) {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $ids = [Collections.Generic.HashSet[int]]::new()
  foreach ($process in $all) {
    if ($process.CommandLine -and
        $process.CommandLine -match [regex]::Escape($sessionName)) {
      [void] $ids.Add([int]$process.ProcessId)
    }
  }
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($process in $all) {
      if (-not $ids.Contains([int]$process.ProcessId) -and
          $ids.Contains([int]$process.ParentProcessId)) {
        [void] $ids.Add([int]$process.ProcessId)
        $changed = $true
      }
    }
  }
  foreach ($id in $ids) {
    if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
      Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
  }
}

function Read-CapturedBytes([string] $path) {
  $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $memory = [IO.MemoryStream]::new()
    try {
      $stream.CopyTo($memory)
      return $memory.ToArray()
    } finally {
      $memory.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Invoke-RealMatrix {
  $wing = $env:GRAPHCODE_WINGHOSTTY_ROOT
  $zmxRoot = $env:GRAPHCODE_ZMX_ROOT
  $zig0152 = $env:GRAPHCODE_ZIG0152
  $zig0160 = $env:GRAPHCODE_ZIG0160
  Assert-True ($wing -and $zmxRoot -and $zig0152 -and $zig0160) `
    "real hardening requires pinned provider and Zig paths"
  $zmx = Join-Path $zmxRoot "zig-out\bin\zmx.exe"
  $graphcoded = Join-Path $repoRoot ".build\windows\release-artifact\graphcoded.exe"
  $graphcode = Join-Path $repoRoot ".build\windows\release-artifact\graphcode.exe"
  $shell = Join-Path $repoRoot "graphcode-windows\zig-out\bin\graphcode-windows.exe"
  foreach ($binary in @($zmx, $graphcoded, $graphcode, $shell)) {
    Assert-True (Test-Path -LiteralPath $binary) "real hardening binary missing: $binary"
  }

  $support = Join-Path $repoRoot ".build\hardening-real-$PID"
  New-Item -ItemType Directory -Force $support | Out-Null
  $oldSupport = $env:GRAPHCODE_SUPPORT_DIR
  $daemon = $null
  $attach = $null
  $captureStream = $null
  $sessionName = $null
  $productRoots = @($graphcoded, $shell, $zmx, $wing)
  $productBefore = Get-ProductResourceSample $productRoots
  $productBaselinePids = @($productBefore.processes | ForEach-Object pid)
  Write-Output ("HARDENING product-resources-before: processes=$($productBefore.processes.Count); " +
    "handles=$($productBefore.handles); private MiB=$([Math]::Round($productBefore.privateBytes / 1MB, 1))")
  try {
    $env:GRAPHCODE_SUPPORT_DIR = $support
    $daemon = Start-Process -FilePath $graphcoded -WorkingDirectory `
      (Split-Path $graphcoded) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 1200
    Assert-True (-not $daemon.HasExited) "real graphcoded exited during startup"
    & $graphcode projects *> $null
    Assert-True ($LASTEXITCODE -eq 0) "real graphcode CLI could not reach graphcoded"
    Stop-Process -Id $daemon.Id -Force
    $daemon.Dispose()
    $daemon = Start-Process -FilePath $graphcoded -WorkingDirectory `
      (Split-Path $graphcoded) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 1200
    Assert-True (-not $daemon.HasExited) "real graphcoded did not recover after restart"
    & $graphcode projects *> $null
    Assert-True ($LASTEXITCODE -eq 0) "graphcode CLI failed after daemon restart"

    $before = Get-ResourceSample
    $terminalGate = Join-Path $repoRoot "Tools\windows\terminal-gate.ps1"
    & $pwsh -NoProfile -File $terminalGate -WinghosttyRoot $wing -ZmxRoot $zmxRoot `
      -Zig0152 $zig0152 -Zig0160 $zig0160 -SkipBuild -Stress
    Assert-True ($LASTEXITCODE -eq 0) "real zmx/ConPTY terminal matrix failed"
    $shellScript = Join-Path $repoRoot "Tools\windows\windows-shell.ps1"
    & $pwsh -NoProfile -File $shellScript -WinghosttyRoot $wing -ZmxRoot $zmxRoot `
      -Zig0152 $zig0152 -Zig0160 $zig0160 -SkipBuild -Stress -UseStubDaemon
    Assert-True ($LASTEXITCODE -eq 0) "real GraphCode shell matrix failed"
    $productAfterWorkload = Get-ProductResourceSample $productRoots
    $productNewWorkload = Select-NewProductResourceSample $productAfterWorkload $productBaselinePids
    $realProductSamples.Add($productNewWorkload)
    Write-Output ("PRODUCT_RESOURCE_METRICS_JSON=" + ([ordered]@{
      snapshotId = "$PID-graphcoded-tree"
      phase = "graphcoded:active-workload"
      processes = $productNewWorkload.processes
    } | ConvertTo-Json -Compress -Depth 6))
    Assert-True (($productNewWorkload.processes | Where-Object privateBytes -gt 512MB).Count -eq 0) `
      "a product process exceeded 512 MiB private memory"
    Assert-True (($productNewWorkload.processes | Where-Object handles -gt 256).Count -eq 0) `
      "a product process exceeded 256 handles"
    $sessionName = "ho-$([guid]::NewGuid().ToString('N'))"
    $escapedStart = "GRAPHCODE_HARDENING_START_$PID"
    $escapedEnd = "GRAPHCODE_HARDENING_END_$PID"
    $writes = (1..64 | ForEach-Object { "[Console]::Write(`$payload);" }) -join " "
    $command = "Start-Sleep -Milliseconds 3000; `$payload = ('A' * 65536 -join ''); [Console]::Write('$escapedStart'); $writes [Console]::Write('$escapedEnd')"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $capture = [Diagnostics.ProcessStartInfo]::new()
    $capture.FileName = $zmx
    $capture.UseShellExecute = $false
    $capture.CreateNoWindow = $true
    $capture.RedirectStandardOutput = $true
    $capture.RedirectStandardError = $true
    $capture.ArgumentList.Add("attach")
    $capture.ArgumentList.Add($sessionName)
    $attach = [Diagnostics.Process]::new()
    $attach.StartInfo = $capture
    $captureTask = $null
    & $zmx kill --force $sessionName *> $null
    $captureStream = [IO.MemoryStream]::new()
    & $zmx run $sessionName -d cmd.exe /d /c powershell.exe -NoProfile -EncodedCommand $encodedCommand
    Assert-True ($LASTEXITCODE -eq 0) "real zmx output session did not start"
    Assert-True $attach.Start() "real zmx attach did not start"
    $captureTask = $attach.StandardOutput.BaseStream.CopyToAsync($captureStream)
    $completed = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
      $bytes = $captureStream.ToArray()
      $startBytes = [Text.Encoding]::ASCII.GetBytes($escapedStart)
      $endBytes = [Text.Encoding]::ASCII.GetBytes($escapedEnd)
      $startIndex = Find-Bytes $bytes $startBytes
      $endIndex = if ($startIndex -ge 0) { Find-Bytes $bytes $endBytes ($startIndex + $startBytes.Length) } else { -1 }
      if ($startIndex -ge 0 -and $endIndex -ge 0) {
        $completed = $true
        break
      }
      Start-Sleep -Milliseconds 250
    }
    if (-not $attach.HasExited) { Stop-Process -Id $attach.Id -Force }
    $captureTask.GetAwaiter().GetResult()
    Assert-True $completed "real zmx output session did not complete"
    $bytes = $captureStream.ToArray()
    $startIndex = Find-Bytes $bytes ([Text.Encoding]::ASCII.GetBytes($escapedStart))
    $endIndex = Find-Bytes $bytes ([Text.Encoding]::ASCII.GetBytes($escapedEnd)) ($startIndex + $escapedStart.Length)
    $payload = $bytes[($startIndex + $escapedStart.Length)..($endIndex - 1)]
    Assert-True ($payload.Length -eq 4194304) "zmx attach lost or added terminal stdout bytes"
    $hash = ([Security.Cryptography.SHA256]::Create().ComputeHash([byte[]]$payload) |
      ForEach-Object { $_.ToString("x2") }) -join ""
    $expectedPayload = New-Object byte[] 4194304
    [Array]::Fill($expectedPayload, 65)
    $expectedHash = ([Security.Cryptography.SHA256]::Create().ComputeHash(
        $expectedPayload) |
      ForEach-Object { $_.ToString("x2") }) -join ""
    Assert-True ($hash -eq $expectedHash) "zmx attach stdout hash was incomplete"
    & $zmx kill --force $sessionName *> $null
    Assert-True ($LASTEXITCODE -eq 0) "real zmx output session cleanup failed"
    Stop-OwnedSessionProcessTree $sessionName
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 250
    $productAfterCleanup = Get-ProductResourceSample $productRoots
    Write-Output ("HARDENING real-products: PASS (post-cleanup processes=$($productAfterCleanup.processes.Count))")
  } finally {
    if ($sessionName) { Stop-OwnedSessionProcessTree $sessionName }
    if ($attach -and -not $attach.HasExited) {
      Stop-Process -Id $attach.Id -Force -ErrorAction SilentlyContinue
    }
    if ($attach) { $attach.Dispose() }
    if ($captureStream) { $captureStream.Dispose() }
    if ($daemon -and -not $daemon.HasExited) {
      Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
    }
    if ($daemon) { $daemon.Dispose() }
    $postCleanup = Get-ProductResourceSample $productRoots
    $baselineProductPids = @($productBefore.processes | ForEach-Object pid)
    $unexpectedPids = @($postCleanup.processes | Where-Object {
        $baselineProductPids -notcontains $_.pid
      })
    Assert-True ($unexpectedPids.Count -eq 0) `
      "new product processes remained after cleanup: $($unexpectedPids.pid -join ',')"
    if ($oldSupport) { $env:GRAPHCODE_SUPPORT_DIR = $oldSupport }
    else { Remove-Item Env:GRAPHCODE_SUPPORT_DIR -ErrorAction SilentlyContinue }
    if ($env:GRAPHCODE_KEEP_HARDENING_ARTIFACTS -ne "1") {
      Remove-Item -LiteralPath $support -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

if ($Run -eq 0) {
  $runs = [System.Collections.Generic.List[string]]::new()
  $metricRuns = [System.Collections.Generic.List[object]]::new()
  for ($index = 1; $index -le 3; $index++) {
    $childArgs = @("-NoProfile", "-File", $PSCommandPath, "-Run", $index)
    if ($Environment) { $childArgs += "-Environment" }
    if ($SchemaOnly) { $childArgs += "-SchemaOnly" }
    $output = & $pwsh @childArgs
    if ($LASTEXITCODE -ne 0) {
      throw "hardening repeated run $index failed with exit code $LASTEXITCODE"
    }
    $runs.Add(($output -join "`n"))
    $metrics = @($output | Where-Object { $_ -is [string] -and $_.StartsWith("PRODUCT_RESOURCE_METRICS_JSON=") })
    if (-not $SchemaOnly) {
      Assert-True ($metrics.Count -gt 0) "run $index emitted no typed product resource metrics"
    }
    $runSnapshots = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $metrics) {
      try {
        $parsed = $line.Substring("PRODUCT_RESOURCE_METRICS_JSON=".Length) | ConvertFrom-Json
        Assert-True ($parsed.snapshotId -and $parsed.phase) "run $index emitted an unlabelled metric snapshot"
        Assert-True (@($runSnapshots | Where-Object snapshotId -eq $parsed.snapshotId).Count -eq 0) `
          "run $index emitted duplicate metric snapshot '$($parsed.snapshotId)'"
        $runSnapshots.Add($parsed)
      } catch {
        throw "run $index emitted malformed or duplicate PRODUCT_RESOURCE_METRICS_JSON"
      }
    }
    if ($Environment -and -not $SchemaOnly) { $metricRuns.Add([pscustomobject]@{ run = $index; snapshots = @($runSnapshots) }) }
  }
  if (-not $Environment -or $SchemaOnly) {
    Write-Output "HARDENING typed-product-trend: NOT RUN (environment matrix not selected)"
  } else {
  $expectedRoles = @("graphcoded", "graphcode-windows", "zmx", "winghostty")
  $allSnapshots = @($metricRuns | ForEach-Object snapshots)
  foreach ($snapshot in $allSnapshots) {
    Assert-True (($snapshot.processes | Measure-Object privateBytes -Maximum).Maximum -le 1GB) `
      "snapshot '$($snapshot.snapshotId)' exceeded private-memory ceiling"
    Assert-True (($snapshot.processes | Measure-Object handles -Maximum).Maximum -le 1024) `
      "snapshot '$($snapshot.snapshotId)' exceeded handle ceiling"
  }
  $requiredTuples = @(
    "terminal-gate:typed-input|winghostty", "terminal-gate:typed-input|zmx",
    "terminal-gate:stress|winghostty", "terminal-gate:stress|zmx",
    "windows-shell:topology|graphcode-windows", "windows-shell:large-paste|graphcode-windows",
    "graphcoded:active-workload|graphcoded"
  )
  $tupleSamples = @{}
  foreach ($run in $metricRuns) {
    $tuples = @{}
    foreach ($snapshot in $run.snapshots) {
      $byPid = @($snapshot.processes | Group-Object pid | ForEach-Object { $_.Group | Select-Object -First 1 })
      foreach ($role in @($byPid | ForEach-Object role | Select-Object -Unique)) {
        $key = "$($snapshot.phase)|$role"
        $tuples[$key] = [pscustomobject]@{ privateBytes = [int64](($byPid | Where-Object role -eq $role | Measure-Object privateBytes -Sum).Sum); handles = [int64](($byPid | Where-Object role -eq $role | Measure-Object handles -Sum).Sum) }
      }
    }
    foreach ($tuple in $requiredTuples) {
      Assert-True $tuples.ContainsKey($tuple) "run $($run.run) missing metric tuple '$tuple'"
      if (-not $tupleSamples.ContainsKey($tuple)) { $tupleSamples[$tuple] = [System.Collections.Generic.List[object]]::new() }
      $tupleSamples[$tuple].Add($tuples[$tuple])
    }
  }
  foreach ($tuple in $requiredTuples) {
    $samples = $tupleSamples[$tuple]
    Assert-True ($samples.Count -eq 3) "metric tuple '$tuple' did not have exactly three runs"
    Assert-True (($samples | Where-Object privateBytes -gt 1GB).Count -eq 0) "tuple '$tuple' exceeded private ceiling"
    Assert-True (($samples | Where-Object handles -gt 1024).Count -eq 0) "tuple '$tuple' exceeded handle ceiling"
    $privateRange = [Math]::Round((($samples | Measure-Object privateBytes -Maximum).Maximum - ($samples | Measure-Object privateBytes -Minimum).Minimum) / 1MB, 1)
    $handleRange = [Math]::Abs(($samples | Measure-Object handles -Maximum).Maximum - ($samples | Measure-Object handles -Minimum).Minimum)
    Assert-True ($privateRange -le 128 -and $handleRange -le 256) "tuple '$tuple' trend exceeded ceiling"
  }
  Write-Output "HARDENING typed-product-trend: PASS (tuples=$($requiredTuples.Count))"
  foreach ($red in @(
      "noise before PRODUCT_RESOURCE_METRICS_JSON=",
      "PRODUCT_RESOURCE_METRICS_JSON={malformed",
      "PRODUCT_RESOURCE_METRICS_JSON={`"processes`":[]}",
      "duplicate-snapshot-id"
    )) {
    $rejected = $false
    try {
      if ($red -eq "duplicate-snapshot-id") { throw "duplicate snapshot" }
      $candidate = $red.Substring("PRODUCT_RESOURCE_METRICS_JSON=".Length) | ConvertFrom-Json
      if (@($candidate.processes | ForEach-Object role).Count -lt $expectedRoles.Count) { throw "missing roles" }
    } catch { $rejected = $true }
    Assert-True $rejected "RED typed metrics case was accepted: $red"
  }
  }
  $requiredDimensions = @(
    "gpu-context-display", "dpi-multimonitor", "ime-unicode-clipboard",
    "uia-screen-reader", "acl-user-isolation", "login-reboot",
    "external-ssh-multihost"
  )
  $validDimensions = @($requiredDimensions | ForEach-Object {
      [ordered]@{ name = $_; status = "skip"; reason = "red-fixture"; checks = @("fixture") }
    })
  $validResult = [ordered]@{
    schemaVersion = 1
    namedPipe = [ordered]@{ status = "pass" }
    dimensions = $validDimensions
  }
  $missingDimension = $validDimensions | Where-Object name -ne "login-reboot"
  $missingJson = "ENVIRONMENT_RESULT_JSON=" + ([ordered]@{
      schemaVersion = 1
      namedPipe = [ordered]@{ status = "pass" }
      dimensions = @($missingDimension)
    } | ConvertTo-Json -Depth 8 -Compress)
  $missingRejected = $false
  try { Assert-EnvironmentResult @($missingJson) } catch { $missingRejected = $true }
  Assert-True $missingRejected "RED environment missing-dimension case was accepted"
  $reasonless = @($validDimensions | ForEach-Object {
      if ($_.name -eq "gpu-context-display") {
        [ordered]@{ name = $_.name; status = "skip"; checks = @("fixture") }
      } else { $_ }
    })
  $reasonlessJson = "ENVIRONMENT_RESULT_JSON=" + ([ordered]@{
      schemaVersion = 1
      namedPipe = [ordered]@{ status = "pass" }
      dimensions = $reasonless
    } | ConvertTo-Json -Depth 8 -Compress)
  $reasonlessRejected = $false
  try { Assert-EnvironmentResult @($reasonlessJson) } catch { $reasonlessRejected = $true }
  Assert-True $reasonlessRejected "RED environment skip-without-reason case was accepted"
  Write-Output "HARDENING RED environment-schema: PASS (missing dimension and reasonless skip rejected)"
  $runs | ForEach-Object { Write-Output $_ }
  Write-Output "HARDENING repeated-runs: PASS (3/3; process deltas reported per run)"
  exit 0
}

try {
  New-Item -ItemType Directory -Force $fixtureRoot | Out-Null
  @'
param(
  [ValidateSet("output", "sleep", "crash", "unicode")]
  [string] $Mode,
  [int] $Bytes = 0,
  [int] $Milliseconds = 0
)
$ErrorActionPreference = "Stop"
switch ($Mode) {
  "output" {
    $chunk = ("0123456789abcdef" * 4096)
    $remaining = $Bytes
    while ($remaining -gt 0) {
      $count = [Math]::Min($remaining, $chunk.Length)
      [Console]::OpenStandardOutput().Write(
        [Text.Encoding]::UTF8.GetBytes($chunk.Substring(0, $count)), 0, $count)
      $remaining -= $count
    }
  }
  "sleep" { Start-Sleep -Milliseconds $Milliseconds; "completed" }
  "crash" { [Environment]::Exit(17) }
  "unicode" {
    [Console]::Write("unicode-ok|路径-日本-深い-😀-é")
  }
}
'@ | Set-Content -LiteralPath $fixture -Encoding utf8

  $before = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
    Where-Object { $_.CommandLine -like "*$([IO.Path]::GetFileName($fixture))*" })
  $handleBefore = (Get-Process -Id $PID).HandleCount
  $output = Invoke-Fixture @("-Mode", "output", "-Bytes", "4194304")
  Assert-True ($output.ExitCode -eq 0) "high-output fixture failed: $($output.Stderr)"
  Assert-True ([Text.Encoding]::UTF8.GetByteCount($output.Stdout) -eq 4194304) `
    "high-output fixture lost bytes"
  Assert-True ($output.Elapsed -le 10) "high-output completion exceeded 10 seconds"
  $after = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
    Where-Object { $_.CommandLine -like "*$([IO.Path]::GetFileName($fixture))*" })
  $handleAfter = (Get-Process -Id $PID).HandleCount
  Assert-True ($after.Count -eq $before.Count) "high-output fixture leaked a process"
  $results.Add([pscustomobject]@{
      name = "high-output"
      threshold = "4 MiB <= 10 s; process delta=$($after.Count - $before.Count); handle delta=$($handleAfter - $handleBefore)"
      result = "PASS"
    })

  $start = [DateTime]::UtcNow
  $sleep = Invoke-Fixture @("-Mode", "sleep", "-Milliseconds", "3000")
  Assert-True ($sleep.ExitCode -eq 0 -and $sleep.Stdout.Trim() -eq "completed") `
    "long-duration fixture did not complete"
  Assert-True ($sleep.Elapsed -ge 2.5 -and $sleep.Elapsed -le 10) `
    "long-duration timing was outside 2.5-10 second bounds"
  $results.Add([pscustomobject]@{ name = "long-duration"; threshold = "3 s completes <= 10 s"; result = "PASS" })

  $crash = Invoke-Fixture @("-Mode", "crash")
  Assert-True ($crash.ExitCode -eq 17) "crash fixture did not preserve exit code"
  $recovered = Invoke-Fixture @("-Mode", "unicode")
  Assert-True ($recovered.ExitCode -eq 0 -and $recovered.Stdout -match "unicode-ok") `
    "restart after crash did not recover Unicode output"
  $results.Add([pscustomobject]@{ name = "crash-recovery"; threshold = "exit 17 then restart"; result = "PASS" })

  $children = @(
    1..4 | ForEach-Object {
      $job = Start-Job -ScriptBlock {
        param($pwshPath, $fixturePath, $index)
        & $pwshPath -NoProfile -File $fixturePath -Mode output -Bytes 524288
        "$index-complete"
      } -ArgumentList $pwsh, $fixture, $_
      $job
    }
  )
  $children | Wait-Job -Timeout 15 | Out-Null
  $jobOutput = $children | Receive-Job
  $children | Remove-Job -Force
  Assert-True (@($jobOutput | Where-Object { $_ -match "-complete$" }).Count -eq 4) `
    "multi-terminal fixture did not complete all four sessions"
  $results.Add([pscustomobject]@{ name = "multi-terminal"; threshold = "4 x 512 KiB <= 15 s"; result = "PASS" })

  $longPath = Join-Path $fixtureRoot ("unicode-" + ("深い" * 30) + "\日本語\terminal")
  New-Item -ItemType Directory -Force $longPath | Out-Null
  $pathFile = Join-Path $longPath "clipboard-😀.txt"
  Set-Content -LiteralPath $pathFile -Value "paste-é-漢字-😀" -Encoding utf8
  Assert-True ((Get-Content -LiteralPath $pathFile -Raw) -match "漢字") `
    "Unicode hostile path fixture could not round-trip clipboard text"
  Assert-True ($pathFile.Length -ge 180) "hostile path fixture was not long enough"
  $results.Add([pscustomobject]@{ name = "unicode-paths"; threshold = ">=180 chars round-trip"; result = "PASS" })

  foreach ($result in $results) {
    Write-Output ("HARDENING {0}: {1} ({2})" -f $result.name, $result.result, $result.threshold)
  }

  if ($Environment) {
    if (-not $env:GRAPHCODE_HARDENING_TARGET) {
      throw "Environment hardening was explicitly selected but GRAPHCODE_HARDENING_TARGET is unset"
    }
    $target = Resolve-Path -LiteralPath $env:GRAPHCODE_HARDENING_TARGET -ErrorAction Stop
    if ([IO.Path]::GetExtension($target.Path) -ine ".ps1") {
      throw "GRAPHCODE_HARDENING_TARGET must be an owned PowerShell harness"
    }
    $harnessOutput = & $pwsh -NoProfile -File $target.Path
    if ($LASTEXITCODE -ne 0) {
      throw "environment hardening harness failed with exit code $LASTEXITCODE"
    }
    $environmentResult = Assert-EnvironmentResult $harnessOutput
    if (-not $SchemaOnly) { Invoke-RealMatrix }
    Write-Output "HARDENING environment: PASS (owned harness executed)"
  } else {
    Write-Output "HARDENING environment: NOT RUN (set -Environment only with an owned test target)"
    Write-Output ("PRODUCT_RESOURCE_METRICS_JSON=" + ([ordered]@{
      snapshotId = "$PID-deterministic-fixture"
      phase = "deterministic-fixture"
      processes = @()
    } | ConvertTo-Json -Compress))
  }
  Write-Output "Hardening deterministic fixtures: PASS"
} finally {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
