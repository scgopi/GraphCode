[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("graphcode uia harness-" + [char]0xe9 + [guid]::NewGuid())
function Test-AbruptStage([string] $Stage, [switch] $RepeatedPath) {
  $fixture = Join-Path $scratch $(if ($RepeatedPath) { "$Stage-repeated-path" } else { $Stage })
  $childTemp = Join-Path $fixture "temp"
  New-Item -ItemType Directory -Path $childTemp | Out-Null
  $vcvars = Join-Path $fixture "vcvars.cmd"
  $setup = if ($RepeatedPath) {
    "@echo off`r`necho [native-harness] setup PATH=%PATH%`r`nexit /b 0`r`n"
  } elseif ($Stage -eq "vcvars") {
    "@echo off`r`nexit 255`r`n"
  } else {
    "@echo off`r`nset `"PATH=%~dp0;%SystemRoot%\System32`"`r`nexit /b 0`r`n"
  }
  [IO.File]::WriteAllText($vcvars, $setup, [Text.Encoding]::ASCII)
  if ($Stage -ne "vcvars") {
    $tool = if ($Stage -eq "where-cl") { "where.cmd" } else { "cl.cmd" }
    [IO.File]::WriteAllText((Join-Path $fixture $tool), "@echo off`r`nexit 255`r`n", [Text.Encoding]::ASCII)
  }
  $wrapper = Join-Path $fixture "invoke.ps1"
  [IO.File]::WriteAllText($wrapper, @'
param([string] $NativeScript, [string] $VcVars)
$before = $env:PATH
$result = 0
try {
  & $NativeScript -VcVars $VcVars
} catch {
  Write-Error -ErrorRecord $_ -ErrorAction Continue
  $result = 1
} finally {
  if ($env:PATH -cne $before) { throw "Native harness original PATH was not restored" }
  Write-Host "[native-harness] original PATH restored"
}
exit $result
'@, [Text.Encoding]::ASCII)
  $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in @(
      "-NoProfile", "-File", $wrapper, "-NativeScript",
      (Join-Path $PSScriptRoot "AccessibilityProvider.Native.Tests.ps1"),
      "-VcVars", $vcvars)) {
    $start.ArgumentList.Add($argument)
  }
  $start.Environment["TEMP"] = $childTemp
  $start.Environment["TMP"] = $childTemp
  if ($RepeatedPath) {
    $start.Environment["PATH"] = (@($fixture) + @($fixture.ToUpperInvariant()) * 99 +
      @("$env:SystemRoot\System32")) -join ";"
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  try {
    if (-not $process.Start()) { throw "Native harness child did not start" }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Native harness launcher-only child timed out"
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Host $output
    if ($process.ExitCode -eq 0) { throw "RED: native harness masked $Stage failure" }
    if ($output -notmatch "\[native-uia\] stage=$Stage start" -or
        $output -notmatch '\[native-uia\] cmd exit=255') {
      throw "RED: native harness lost the actual $Stage command exit"
    }
    if ($output -notmatch "stage '$Stage' failed: 255") {
      throw "RED: native harness did not attribute abrupt exit 255 to $Stage"
    }
    if ($output -match '\[native-uia\] stage=test-exe start' -or
        ($Stage -ne "compile" -and $output -match '\[native-uia\] stage=compile start')) {
      throw "RED: native harness continued after abrupt $Stage failure"
    }
    if (@(Get-ChildItem -LiteralPath $childTemp -Force).Count -ne 0) {
      throw "RED: native harness left owned native scratch after $Stage failure"
    }
    if ($output -notmatch '\[native-harness\] original PATH restored') {
      throw "RED: native harness did not restore the exact original PATH after $Stage failure"
    }
    if ($RepeatedPath) {
      $pathLine = [regex]::Match($output, '(?m)^\[native-harness\] setup PATH=(.*)\r?$')
      $entries = @($pathLine.Groups[1].Value.TrimEnd("`r") -split ";")
      $matching = @($entries | Where-Object { $_ -ieq $fixture })
      if ($matching.Count -ne 1 -or $matching[0] -cne $fixture -or
          [Array]::IndexOf($entries, $fixture) -ge [Array]::IndexOf($entries, "$env:SystemRoot\System32")) {
        throw "RED: native harness did not preserve case-insensitive first-occurrence PATH order"
      }
    }
  } finally {
    $process.Dispose()
  }
}
try {
  foreach ($stage in @("vcvars", "where-cl", "compile")) {
    Test-AbruptStage $stage
  }
  Test-AbruptStage "compile" -RepeatedPath
  Write-Host "Native accessibility harness: 25 checks, 0 failures (mock tools; no native fixture)"
} finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
