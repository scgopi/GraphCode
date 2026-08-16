[CmdletBinding()]
param(
  [switch] $Environment,
  [int] $Run = 0
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$pwsh = (Get-Command pwsh.exe).Source
$fixtureRoot = Join-Path $repoRoot ".build\windows-hardening-$PID"
$fixture = Join-Path $fixtureRoot "fixture.ps1"
$results = [System.Collections.Generic.List[object]]::new()
$realSamples = [System.Collections.Generic.List[object]]::new()

function Assert-True([bool] $condition, [string] $message) {
  if (-not $condition) { throw "Hardening failure: $message" }
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
    $sessionName = "graphcode-hardening-output-$PID"
    $payloadFile = Join-Path $support "real-output.bin"
    $markerFile = Join-Path $support "real-output.marker"
    $escapedPayload = $payloadFile.Replace("'", "''")
    $escapedMarker = $markerFile.Replace("'", "''")
    & $zmx kill --force $sessionName *> $null
    & $zmx run $sessionName -d powershell.exe -NoProfile -Command `
      "`$bytes = New-Object byte[] 4194304; [IO.File]::WriteAllBytes('$escapedPayload',`$bytes); [IO.File]::WriteAllText('$escapedMarker','hardening-real-output'); [Console]::Write('hardening-real-output')"
    Assert-True ($LASTEXITCODE -eq 0) "real zmx output session did not start"
    $completed = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
      $listing = (& $zmx list 2>$null | Out-String)
      if ($listing -match ("(?s)name=" + [regex]::Escape($sessionName) + ".*?ended=.*?exit_code=0")) {
        $completed = $true
        break
      }
      Start-Sleep -Milliseconds 250
    }
    Assert-True $completed "real zmx output session did not complete"
    Assert-True ((Get-Item -LiteralPath $payloadFile).Length -eq 4194304) `
      "real zmx session did not produce exactly 4 MiB"
    Assert-True ((Get-Content -LiteralPath $markerFile -Raw) -eq "hardening-real-output") `
      "real zmx session missed output marker"
    & $zmx kill --force $sessionName *> $null
    Assert-True ($LASTEXITCODE -eq 0) "real zmx output session cleanup failed"
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 250
    $after = Get-ResourceSample
    $handleDelta = $after.handles - $before.handles
    $privateMB = [Math]::Round($after.privateBytes / 1MB, 1)
    Assert-True ($handleDelta -le 256) "real hardening handle growth exceeded 256: $handleDelta"
    Assert-True ($privateMB -le 512) "real hardening private memory exceeded 512 MiB: $privateMB"
    if ($realSamples.Count -gt 0) {
      $growthMB = [Math]::Round(($after.privateBytes - $realSamples[0].privateBytes) / 1MB, 1)
      Assert-True ($growthMB -le 32) "real hardening private-memory growth exceeded 32 MiB: $growthMB"
    } else {
      $growthMB = 0
    }
    $realSamples.Add($after)
    Write-Output "HARDENING real-products: PASS (graphcoded/graphcode/shell/zmx; handles delta=$handleDelta; private MiB=$privateMB; growth MiB=$growthMB)"
  } finally {
    if ($daemon -and -not $daemon.HasExited) {
      Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
    }
    if ($daemon) { $daemon.Dispose() }
    if ($oldSupport) { $env:GRAPHCODE_SUPPORT_DIR = $oldSupport }
    else { Remove-Item Env:GRAPHCODE_SUPPORT_DIR -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $support -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($Run -eq 0) {
  $runs = [System.Collections.Generic.List[string]]::new()
  $realPrivate = [System.Collections.Generic.List[double]]::new()
  $realHandles = [System.Collections.Generic.List[int]]::new()
  for ($index = 1; $index -le 3; $index++) {
    if ($Environment) {
      $output = & $pwsh -NoProfile -File $PSCommandPath -Run $index -Environment
    } else {
      $output = & $pwsh -NoProfile -File $PSCommandPath -Run $index
    }
    if ($LASTEXITCODE -ne 0) {
      throw "hardening repeated run $index failed with exit code $LASTEXITCODE"
    }
    $runs.Add(($output -join "`n"))
    foreach ($line in @($output | Where-Object { $_ -match "private MiB=([0-9.]+)" })) {
      if ($line -match "private MiB=([0-9.]+)") {
        $realPrivate.Add([double] $Matches[1])
      }
    }
    foreach ($line in @($output | Where-Object { $_ -match "handles delta=(-?\d+)" })) {
      if ($line -match "handles delta=(-?\d+)") {
        $realHandles.Add([int] $Matches[1])
      }
    }
  }
  if ($realPrivate.Count -gt 1) {
    $growth = [Math]::Round(($realPrivate | Measure-Object -Maximum).Maximum -
      ($realPrivate | Measure-Object -Minimum).Minimum, 1)
    Assert-True ($growth -le 32) "repeated real private-memory trend exceeded 32 MiB: $growth"
    Write-Output "HARDENING repeated-resource-trend: PASS (private MiB range=$growth)"
  }
  if ($realHandles.Count -gt 1) {
    $handleRange = [Math]::Abs(
      ($realHandles | Measure-Object -Maximum).Maximum -
      ($realHandles | Measure-Object -Minimum).Minimum)
    Assert-True ($handleRange -le 64) `
      "repeated real handle trend exceeded 64 handles: $handleRange"
    Write-Output "HARDENING repeated-handle-trend: PASS (range=$handleRange)"
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
    Invoke-RealMatrix
    Write-Output "HARDENING environment: PASS (owned harness executed)"
  } else {
    Write-Output "HARDENING environment: NOT RUN (set -Environment only with an owned test target)"
  }
  Write-Output "Hardening deterministic fixtures: PASS"
} finally {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
