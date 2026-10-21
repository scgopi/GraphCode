[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$fixture = Join-Path $repoRoot ".build\packaging-rollback-$([guid]::NewGuid())"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Packaging script has parse errors: $errors" }
foreach ($name in @("Fail", "Require", "Copy-Tree", "Move-InstallDirectory", "Get-RollbackCleanupMarker",
    "New-RollbackCleanupMarker", "Install-Package", "Open-Package", "Close-Package")) {
  $definition = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
  if (-not $definition) { throw "Packaging helper is missing: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
$copyTree = (Get-Command Copy-Tree).ScriptBlock
$moveDirectory = (Get-Command Move-InstallDirectory).ScriptBlock
$openPackage = (Get-Command Open-Package).ScriptBlock
$closePackage = (Get-Command Close-Package).ScriptBlock
$newRollbackCleanupMarker = (Get-Command New-RollbackCleanupMarker).ScriptBlock

function Assert([bool] $condition, [string] $message) {
  if (-not $condition) { throw "RED: $message" }
}
function Copy-Tree([string] $source, [string] $destination) {
  & $copyTree $source $destination
  if ($case -eq "copy") { throw "injected copy failure" }
}
function Open-Package([string] $path) { $path }
function Close-Package { $state.closed = $true }
function Verify-PackageContents([string] $root) {
  if ($case -eq "staged-verification" -and $root -ne $Package) {
    throw "injected staged verification failure"
  }
  [pscustomobject]@{ version = "1.2.3" }
}
function Save-Shortcut([string] $destination) {
  Set-Content (Join-Path $destination "GraphCode.lnk") "old shortcut"
  if ($case -eq "snapshot") { throw "injected snapshot failure" }
}
function Restore-Shortcut([string] $source) {
  Assert ((Get-Content (Join-Path $source "GraphCode.lnk")) -eq "old shortcut") "shortcut recovery data was lost"
  if ($case -eq "restore-shortcut") { throw "injected shortcut restoration failure" }
  $state.shortcut = "old"
}
function Set-UserPath([string] $bin, [bool] $add) {
  if ($case -eq "path") { throw "injected PATH update failure" }
}
function Set-Shortcut([bool] $create) {
  $state.shortcut = "new"
  if ($case -in @("shortcut", "restore-move", "remove-new", "restore-shortcut")) {
    throw "injected shortcut update failure"
  }
}
function Stop-InstalledDaemon {
  $state.stops++
  if ($case -eq "stop" -or ($case -eq "stop-new" -and $state.stops -gt 1)) {
    throw "injected daemon stop failure"
  }
}
function Remove-DaemonTask {
  if ($case -eq "remove-task") { throw "injected task removal failure" }
}
function Start-DaemonTask {
  $state.starts++
  $payload = Get-Content (Join-Path $InstallRoot "bin\graphcoded.exe")
  if ($payload -eq "new" -and $case -in @("start", "restart", "stop-new")) {
    throw "injected new daemon startup failure"
  }
  if ($payload -eq "old" -and $case -eq "restart") {
    throw "injected old daemon restart failure"
  }
}
function Move-InstallDirectory([string] $source, [string] $destination) {
  if ($case -eq "backup-move" -and $source -eq $InstallRoot) {
    throw "injected backup move failure"
  }
  if ($case -eq "promote" -and (Split-Path $source -Leaf) -like ".GraphCode-install-*") {
    throw "injected staged promotion failure"
  }
  if ($case -eq "restore-move" -and (Split-Path $source -Leaf) -like ".GraphCode-rollback-*") {
    throw "injected backup restoration failure"
  }
  & $moveDirectory $source $destination
}
function New-RollbackCleanupMarker([string] $backup) {
  if ($case -eq "committed-cleanup-secondary") {
    throw "injected cleanup marker failure"
  }
  & $newRollbackCleanupMarker $backup
}
function Remove-Item {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)][string[]] $Path,
    [string[]] $LiteralPath,
    [switch] $Recurse,
    [switch] $Force
  )
  $targets = if ($LiteralPath) { $LiteralPath } else { $Path }
  if ($case -eq "remove-new" -and $targets -contains $InstallRoot) {
    throw "injected promoted install removal failure"
  }
  if ($case -in @("committed-cleanup-blocked", "committed-cleanup-secondary") -and
      @($targets | Where-Object { (Split-Path $_ -Leaf) -like ".GraphCode-rollback-*" }).Count) {
    throw "injected committed cleanup lock"
  }
  Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}

$versionWasProvided = $false
$NoScheduledTask = $false
$failures = [Collections.Generic.List[string]]::new()
$executed = 0
try {
  foreach ($case in @("stop", "backup-move", "restore-move", "remove-new", "stop-new", "copy",
      "staged-verification", "snapshot", "remove-task", "promote", "path", "shortcut",
      "start", "restart", "restore-shortcut", "success", "fresh-success", "fresh-failure",
      "portable-success", "locked-install", "relative-success", "committed-cleanup-blocked",
      "committed-cleanup-secondary")) {
    $executed++
    $lock = $null
    $pushed = $false
    try {
      $caseRoot = Join-Path $fixture $case
      $InstallRoot = Join-Path $caseRoot "current"
      $Package = Join-Path $caseRoot "package"
      New-Item -ItemType Directory -Path (Join-Path $Package "bin") -Force | Out-Null
      Set-Content (Join-Path $Package "bin\graphcoded.exe") "new"
      $fresh = $case -like "fresh-*"
      if (-not $fresh) {
        New-Item -ItemType Directory -Path (Join-Path $InstallRoot "bin") -Force | Out-Null
        Set-Content (Join-Path $InstallRoot "bin\graphcoded.exe") "old"
        Set-Content (Join-Path $InstallRoot "sentinel.txt") "previous installation"
      }
      $state = @{ stops = 0; starts = 0; closed = $false; shortcut = "old" }
      $NoScheduledTask = $case -in @("portable-success", "locked-install")
      $succeeds = $case -in @("success", "fresh-success", "portable-success", "relative-success",
        "committed-cleanup-blocked", "committed-cleanup-secondary")
      $errorMessage = $null
      $installOutput = @()
      $label = $case
      if ($case -eq "fresh-failure") { $case = "start" }
      if ($case -eq "locked-install") {
        $lock = [IO.File]::Open((Join-Path $InstallRoot "bin\graphcoded.exe"),
          [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
      }
      if ($case -eq "relative-success") {
        Push-Location -LiteralPath $caseRoot
        $pushed = $true
        $InstallRoot = ".\current"
      }
      try { $installOutput = @(Install-Package (-not $fresh) 3>&1) } catch { $errorMessage = $_.Exception.Message }
      Assert $state.closed "$label did not close the package"
      Assert ($succeeds -eq (-not $errorMessage)) "$label returned an unexpected result: $errorMessage"
      $backups = @(Get-ChildItem -LiteralPath $caseRoot -Directory -Filter ".GraphCode-rollback-*")
      $cleanupMarkers = @(Get-ChildItem -LiteralPath $caseRoot -File -Filter ".GraphCode-rollback-*.cleanup-ready")
      $shortcuts = @(Get-ChildItem -LiteralPath $caseRoot -Directory -Filter ".GraphCode-shortcut-*")
      $stages = @(Get-ChildItem -LiteralPath $caseRoot -Directory -Filter ".GraphCode-install-*")
      Assert ($stages.Count -eq 0) "$label leaked its unpromoted stage"
      if ($succeeds) {
        Assert ((Get-Content (Join-Path $InstallRoot "bin\graphcoded.exe")) -eq "new") "$label did not install the new payload"
        if ($label -eq "committed-cleanup-blocked") {
          Assert ($backups.Count -eq 1) "$label did not retain the cleanup-blocked committed backup"
          Assert ($cleanupMarkers.Count -eq 1) "$label did not mark the committed backup as cleanup-ready"
          Assert ($cleanupMarkers[0].BaseName -eq $backups[0].Name) "$label marker did not identify its rollback backup"
          Assert (($installOutput | Out-String) -match "could not clean transaction directory") "$label did not warn about blocked cleanup"
        } elseif ($label -eq "committed-cleanup-secondary") {
          Assert ($backups.Count -eq 1) "$label did not retain the cleanup-blocked committed backup"
          Assert ($cleanupMarkers.Count -eq 0) "$label authorized cleanup after marker creation failed"
          $warningText = $installOutput | Out-String
          Assert ($warningText -match "could not authorize later cleanup" -and
            $warningText -match "could not clean transaction directory") "$label did not report both cleanup failures"
        } else {
          Assert ($backups.Count -eq 0 -and $cleanupMarkers.Count -eq 0) "$label left transaction debris"
        }
        Assert ($shortcuts.Count -eq 0) "$label left shortcut transaction debris"
        Assert ($state.shortcut -eq "new") "$label did not update the shortcut"
        Assert ($NoScheduledTask -eq ($state.starts -eq 0 -and $state.stops -eq 0)) "$label ignored scheduled-task policy"
        continue
      }
      if ($case -eq "locked-install") {
        Assert ($errorMessage -match "access|used|denied") "$label did not report the native sharing failure: $errorMessage"
      } else {
        Assert ($errorMessage -match "injected") "$label lost the initiating failure: $errorMessage"
      }
      if ($case -in @("restore-move", "remove-new", "stop-new")) {
        Assert ($backups.Count -eq 1) "$label deleted the only recoverable installation"
        Assert ((Get-Content (Join-Path $backups[0].FullName "sentinel.txt")) -eq "previous installation") "$label corrupted the recovery payload"
        Assert ($errorMessage.Contains($backups[0].FullName)) "$label did not report the retained backup path: $errorMessage"
        Assert ($cleanupMarkers.Count -eq 0) "$label marked a required recovery backup as cleanup-ready"
        Assert ($state.starts -eq $(if ($case -eq "stop-new") { 1 } else { 0 })) "$label started a daemon before the old payload was restored"
      } elseif ($fresh) {
        Assert (-not (Test-Path -LiteralPath $InstallRoot)) "$label left the failed fresh installation"
        Assert ($cleanupMarkers.Count -eq 0) "$label marked a failed fresh install as cleanup-ready"
      } else {
        Assert (Test-Path -LiteralPath (Join-Path $InstallRoot "sentinel.txt")) "$label deleted the previous installation"
        Assert ((Get-Content (Join-Path $InstallRoot "bin\graphcoded.exe")) -eq "old") "$label did not restore the old payload"
        Assert ($backups.Count -eq 0) "$label left an unnecessary payload backup"
        Assert ($cleanupMarkers.Count -eq 0) "$label marked a restored backup as cleanup-ready"
      }
      if ($case -in @("restart", "restore-shortcut", "restore-move", "remove-new", "stop-new")) {
        $secondary = switch ($case) {
          "restart" { "injected old daemon restart failure" }
          "restore-shortcut" { "injected shortcut restoration failure" }
          "restore-move" { "injected backup restoration failure" }
          "remove-new" { "injected promoted install removal failure" }
          "stop-new" { "injected daemon stop failure" }
        }
        $primary = if ($case -in @("restart", "stop-new")) { "injected new daemon startup failure" } else { "injected shortcut update failure" }
        Assert ($errorMessage.Contains($primary) -and $errorMessage.Contains($secondary)) "$label did not report both failures: $errorMessage"
      }
      if ($case -eq "restore-shortcut") {
        Assert ($shortcuts.Count -eq 1 -and $errorMessage.Contains($shortcuts[0].FullName)) "$label lost or hid the shortcut recovery snapshot"
      } else {
        Assert ($shortcuts.Count -eq 0) "$label leaked its shortcut snapshot"
        Assert ($state.shortcut -eq "old") "$label did not restore the old shortcut"
      }
    } catch {
      $failures.Add("$case`: $_")
    } finally {
      if ($lock) { $lock.Dispose() }
      if ($pushed) { Pop-Location }
    }
  }
  & {
    $script:PackageExtraction = $null
    $script:failedExtraction = $null
    $archive = Join-Path $fixture "interrupted.zip"
    Set-Content -LiteralPath $archive "archive fixture"
    function Expand-Archive([string] $LiteralPath, [string] $DestinationPath) {
      $script:failedExtraction = $DestinationPath
      New-Item -ItemType Directory -Path $DestinationPath | Out-Null
      Set-Content (Join-Path $DestinationPath "partial.txt") "incomplete"
      throw "injected archive interruption"
    }
    try {
      try {
        & $openPackage $archive | Out-Null
        throw "Archive interruption was accepted"
      } catch {
        if ($_.Exception.Message -ne "injected archive interruption") { throw }
      } finally { & $closePackage }
      if (-not $script:failedExtraction -or (Test-Path -LiteralPath $script:failedExtraction)) {
        $failures.Add("RED: interrupted archive extraction leaked its partial directory")
      }
    } finally {
      if ($script:failedExtraction -and (Test-Path -LiteralPath $script:failedExtraction)) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:failedExtraction -Recurse -Force
      }
    }
  }
  if ($failures.Count) { throw ($failures -join "`n") }
  if ($executed -ne 23) { throw "Package rollback contract executed $executed of 23 cases" }
  Write-Output "Package transaction ownership and recoverable rollback contracts (23 cases): PASS"
} finally {
  if (Test-Path -LiteralPath $fixture) {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $fixture -Recurse -Force
  }
}
