[CmdletBinding()]
param()

# Uninstall must either remove the whole installation or change nothing. The live-session
# case reproduces the Dev Box D10 failure: a zmx session host launched from the installed
# bin keeps bin\zmx.exe locked while Uninstall runs.
$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$fixture = Join-Path $repoRoot ".build\packaging-uninstall-$([guid]::NewGuid())"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Packaging script has parse errors: $errors" }
foreach ($definition in $ast.FindAll({
      param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
if (-not (Get-Command Uninstall-Package -CommandType Function -ErrorAction SilentlyContinue)) {
  throw "Packaging helper is missing: Uninstall-Package"
}

# The machine-wide surfaces (scheduler, registry PATH) are modelled; files, shortcuts and
# processes are real and live under the fixture.
function Get-InstalledDaemons {
  if ($state.daemon) { @([pscustomobject]@{ ProcessId = 0 }) } else { @() }
}
function Stop-InstalledDaemon { $state.stops++; $state.daemon = $false }
function Test-DaemonTask([string] $name) { $state.task }
function Remove-DaemonTask {
  if ($case -eq "task-removal-failure") { throw "injected task removal failure" }
  $state.task = $false
}
function Start-DaemonTask { $state.starts++; $state.task = $true; $state.daemon = $true }
function Set-UserPath([string] $bin, [bool] $add) { $state.path = $add }

function Assert([bool] $condition, [string] $message) {
  if (-not $condition) { throw "$case`: $message" }
}
function Get-TreeDigest([string] $root) {
  @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
      "$($_.FullName.Substring($root.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    }) -join "`n"
}

$oldProfile = $env:USERPROFILE
$oldAppData = $env:APPDATA
$NoScheduledTask = $false
$RemoveUserData = $false
$KeepUserData = $false
$failures = [Collections.Generic.List[string]]::new()
$executed = 0
try {
  foreach ($case in @("live-session", "locked-file", "task-removal-failure", "success")) {
    $session = $null
    $lock = $null
    try {
      $caseRoot = Join-Path $fixture $case
      $InstallRoot = Join-Path $caseRoot "GraphCode\current"
      $env:USERPROFILE = Join-Path $caseRoot "user"
      $env:APPDATA = Join-Path $env:USERPROFILE "AppData\Roaming"
      $bin = Join-Path $InstallRoot "bin"
      New-Item -ItemType Directory -Force -Path $bin, (Join-Path $InstallRoot "licenses") | Out-Null
      Copy-Item (Join-Path $env:SystemRoot "System32\PING.EXE") (Join-Path $bin "zmx.exe")
      foreach ($name in @("graphcoded.exe", "graphcode.exe", "graphcode-windows.exe", "_FoundationICU.dll")) {
        Set-Content (Join-Path $bin $name) "payload $name"
      }
      foreach ($name in @("GraphCode-Setup.ps1", "manifest.json", "metadata.json", "licenses\ZMX-LICENSE.txt")) {
        Set-Content (Join-Path $InstallRoot $name) "payload $name"
      }
      $shortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.lnk"
      New-Item -ItemType Directory -Force -Path (Split-Path $shortcut -Parent) | Out-Null
      Set-Content $shortcut "installed shortcut"
      $userData = Join-Path $env:USERPROFILE ".graphcode\graph.json"
      New-Item -ItemType Directory -Force -Path (Split-Path $userData -Parent) | Out-Null
      Set-Content $userData '{"projects":["kept"]}'
      $installBefore = Get-TreeDigest $InstallRoot
      $dataBefore = Get-TreeDigest (Split-Path $userData -Parent)
      $state = @{ daemon = $true; task = $true; path = $true; stops = 0; starts = 0 }

      if ($case -eq "live-session") {
        $session = Start-Process -FilePath (Join-Path $bin "zmx.exe") -ArgumentList "-n", "120", "127.0.0.1" `
          -WindowStyle Hidden -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Get-CimInstance Win32_Process -Filter "ProcessId=$($session.Id)" -ErrorAction SilentlyContinue) -and
          [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert (-not $session.HasExited) "the fixture session host did not start"
      }
      if ($case -eq "locked-file") {
        # A runtime DLL held open by a process that is not itself launched from the install root.
        $lock = [IO.File]::Open((Join-Path $bin "_FoundationICU.dll"),
          [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
      }

      $errorMessage = $null
      $output = $null
      try { $output = Uninstall-Package *>&1 | Out-String } catch { $errorMessage = $_.Exception.Message }
      $debris = @(Get-ChildItem -LiteralPath (Split-Path $InstallRoot -Parent) -Force -Directory |
        Where-Object { $_.Name -ne "current" })
      Assert ($debris.Count -eq 0) "left transaction debris: $($debris.Name -join ', ')"
      Assert ((Get-TreeDigest (Split-Path $userData -Parent)) -ceq $dataBefore) "changed preserved user data"

      if ($case -eq "success") {
        Assert (-not $errorMessage) "failed: $errorMessage"
        Assert (-not (Test-Path -LiteralPath $InstallRoot)) "left the installation behind"
        Assert (-not $state.task -and -not $state.daemon -and -not $state.path) "left daemon, task or PATH integration"
        Assert (-not (Test-Path -LiteralPath $shortcut)) "left the Start-menu shortcut"
        Assert ($output -match "User data preserved") "did not report preserved user data: $output"
        $executed++
        continue
      }

      Assert ([bool] $errorMessage) "succeeded although the installation could not be removed"
      Assert ((Test-Path -LiteralPath $InstallRoot) -and (Get-TreeDigest $InstallRoot) -ceq $installBefore) `
        "left a partial installation: $errorMessage"
      Assert ($state.task -and $state.path) "removed the task or PATH entry before failing: $errorMessage"
      Assert ((Test-Path -LiteralPath $shortcut) -and (Get-Content $shortcut) -eq "installed shortcut") `
        "removed the Start-menu shortcut before failing: $errorMessage"
      Assert $state.daemon "left the daemon stopped after refusing: $errorMessage"
      switch ($case) {
        "live-session" {
          Assert ($errorMessage -match "changed nothing" -and $errorMessage -match "zmx\.exe" -and
            $errorMessage -match "PID $($session.Id)\b" -and $errorMessage -match " kill ") `
            "did not name the running session host with an actionable fix: $errorMessage"
          Assert ($state.stops -eq 0) "stopped the daemon before refusing up front"
          Assert (-not $session.HasExited) "killed the user's live session host"
        }
        "locked-file" {
          Assert ($errorMessage -match "changed nothing" -and $errorMessage -match "_FoundationICU\.dll") `
            "did not name the file in use: $errorMessage"
          Assert ($state.starts -eq 1) "did not restart the daemon it stopped"
        }
        "task-removal-failure" {
          Assert ($errorMessage -match "injected task removal failure") "lost the initiating failure: $errorMessage"
          Assert ($state.starts -eq 1) "did not restart the daemon it stopped"
        }
      }
      $executed++
    } catch {
      $failures.Add("$_")
    } finally {
      if ($lock) { $lock.Dispose() }
      if ($session -and -not $session.HasExited) { $session.Kill(); $session.WaitForExit() }
    }
  }
  if ($failures.Count) { throw "RED: Uninstall lifecycle contract failed:`n$($failures -join "`n")" }
  if ($executed -ne 4) { throw "Uninstall lifecycle contract executed $executed of 4 cases" }
  Write-Output "Uninstall live-session refusal and all-or-nothing removal contracts (4 cases): PASS"
} finally {
  $env:USERPROFILE = $oldProfile
  $env:APPDATA = $oldAppData
  if (Test-Path -LiteralPath $fixture) {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
  }
}
