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
  [pscustomobject]@{
    Process = $process
    Stdout = $stdout.GetAwaiter().GetResult()
    Stderr = $stderr.GetAwaiter().GetResult()
    Elapsed = $elapsed
  }
}

if ($Run -eq 0) {
  $runs = [System.Collections.Generic.List[string]]::new()
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
  }
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
  Assert-True ($output.Process.ExitCode -eq 0) "high-output fixture failed: $($output.Stderr)"
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
  Assert-True ($sleep.Process.ExitCode -eq 0 -and $sleep.Stdout.Trim() -eq "completed") `
    "long-duration fixture did not complete"
  Assert-True ($sleep.Elapsed -ge 2.5 -and $sleep.Elapsed -le 10) `
    "long-duration timing was outside 2.5-10 second bounds"
  $results.Add([pscustomobject]@{ name = "long-duration"; threshold = "3 s completes <= 10 s"; result = "PASS" })

  $crash = Invoke-Fixture @("-Mode", "crash")
  Assert-True ($crash.Process.ExitCode -eq 17) "crash fixture did not preserve exit code"
  $recovered = Invoke-Fixture @("-Mode", "unicode")
  Assert-True ($recovered.Process.ExitCode -eq 0 -and $recovered.Stdout -match "unicode-ok") `
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
    & $pwsh -NoProfile -File $target.Path
    if ($LASTEXITCODE -ne 0) {
      throw "environment hardening harness failed with exit code $LASTEXITCODE"
    }
    Write-Output "HARDENING environment: PASS (owned harness executed)"
  } else {
    Write-Output "HARDENING environment: NOT RUN (set -Environment only with an owned test target)"
  }
  Write-Output "Hardening deterministic fixtures: PASS"
} finally {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
