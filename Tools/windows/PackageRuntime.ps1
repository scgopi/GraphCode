function Fail([string] $message) { throw "GraphCode packaging: $message" }
function Require([bool] $condition, [string] $message) { if (-not $condition) { Fail $message } }
function Save-Shortcut([string] $destination) {
  foreach ($path in @(
      (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.lnk"),
      (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.url")
    )) {
    if (Test-Path $path) {
      Copy-Item $path (Join-Path $destination (Split-Path $path -Leaf)) -Force
    }
  }
}
function Restore-Shortcut([string] $source) {
  Set-Shortcut $false
  foreach ($name in @("GraphCode.lnk", "GraphCode.url")) {
    $path = Join-Path $source $name
    if (Test-Path $path) {
      Copy-Item $path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$name") -Force
    }
  }
}
function Copy-Tree([string] $source, [string] $destination) {
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  Get-ChildItem -LiteralPath $source -File -Recurse -Force | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length).TrimStart("\", "/")
    $target = Join-Path $destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}
function Normalize-ManifestPath([string] $path) {
  Require (-not [string]::IsNullOrWhiteSpace($path)) "manifest contains an empty path"
  $normalized = $path.Replace("\", "/")
  Require (-not [IO.Path]::IsPathRooted($normalized) -and
    $normalized -notmatch "^[A-Za-z]:/" -and $normalized -notmatch "://" ) `
    "manifest contains an absolute path: $path"
  $parts = $normalized.Split("/")
  $leaf = $parts[-1]
  Require ($parts -notcontains "" -and $parts -notcontains "." -and $parts -notcontains "..") `
    "manifest contains an unsafe path: $path"
  Require ($leaf -notin @("manifest.json", "checksums.sha256", "package.cat")) `
    "manifest contains a reserved filename: $path"
  Require ($normalized -notmatch "[<>:`"|?*]") "manifest contains an invalid path: $path"
  return $normalized
}
function Get-ActualPackageFiles([string] $root) {
  @(Get-ChildItem -LiteralPath $root -File -Recurse -Force |
    Where-Object {
      $_.FullName -ne (Join-Path $root "manifest.json") -and
      $_.FullName -ne (Join-Path $root "checksums.sha256") -and
      $_.FullName -ne (Join-Path $root "package.cat")
    } |
    ForEach-Object {
      Normalize-ManifestPath $_.FullName.Substring($root.Length).TrimStart("\", "/")
    } | Sort-Object -Unique)
}
function Assert-Package([string] $root) {
  Require (Test-Path -LiteralPath (Join-Path $root "metadata.json")) "metadata.json is missing"
  $metadata = Get-Content (Join-Path $root "metadata.json") -Raw | ConvertFrom-Json
  foreach ($name in $required) { Require (Test-Path -LiteralPath (Join-Path $root "bin\$name")) "$name is missing" }
  Require (Test-Path -LiteralPath (Join-Path $root "bin\graphcode-windows.exe")) "graphcode-windows.exe is missing"
  Require (@(Get-ChildItem -LiteralPath (Join-Path $root "bin") -Filter *.dll -ErrorAction SilentlyContinue).Count -gt 0) "Swift runtime DLLs are missing"
  Require (Test-Path -LiteralPath (Join-Path $root "LICENSE")) "LICENSE is missing"
  Require (Test-Path -LiteralPath (Join-Path $root "THIRD-PARTY-NOTICES.txt")) "third-party notices are missing"
  Require (Test-Path -LiteralPath (Join-Path $root "licenses\WINGHOSTTY-LICENSE.txt")) "Winghostty license is missing"
  Require (Test-Path -LiteralPath (Join-Path $root "licenses\ZMX-LICENSE.txt")) "zmx license is missing"
  Require (Test-Path -LiteralPath (Join-Path $root "provider-provenance.json")) "provider provenance is missing"
  Require ($metadata.platform -eq "windows-x86_64") "unsupported package platform"
  if ($metadata.PSObject.Properties.Name -contains "setup") {
    Require ($metadata.setup -ceq "GraphCode-Setup.ps1") "unsupported package setup entry point"
    Require (Test-Path -LiteralPath (Join-Path $root $metadata.setup) -PathType Leaf) "GraphCode-Setup.ps1 is missing"
  }
  return $metadata
}
function Verify-Manifest([string] $root) {
  $manifestPath = Join-Path $root "manifest.json"
  Require (Test-Path -LiteralPath $manifestPath) "manifest.json is missing"
  $expected = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $entries = @($expected.files)
  $normalizedEntries = @()
  foreach ($entry in $entries) {
    $normalized = Normalize-ManifestPath ([string] $entry.path)
    Require ($entry.size -is [int] -or $entry.size -is [long] -or $entry.size -is [double]) "manifest size is invalid: $normalized"
    Require ([string] $entry.sha256 -match "^[0-9a-fA-F]{64}$") "manifest hash is invalid: $normalized"
    Require ($normalizedEntries -notcontains $normalized.ToLowerInvariant()) "manifest contains duplicate paths"
    $normalizedEntries += $normalized.ToLowerInvariant()
    $file = Join-Path $root ($normalized -replace "/", "\")
    Require (Test-Path -LiteralPath $file -PathType Leaf) "manifest file is missing: $($entry.path)"
    $item = Get-Item -LiteralPath $file -Force
    Require ($item.Length -eq [int64]$entry.size) "size mismatch: $normalized"
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    Require ($actual -eq ([string]$entry.sha256).ToLowerInvariant()) "checksum mismatch: $normalized"
  }
  $actualFiles = @(Get-ActualPackageFiles $root | ForEach-Object { $_.ToLowerInvariant() })
  $expectedFiles = @($normalizedEntries | Sort-Object -Unique)
  Require (($actualFiles -join "`n") -eq ($expectedFiles -join "`n")) "manifest file set differs from package contents"
  return $expected
}
function Read-ProviderProvenance([string] $root) {
  $path = Join-Path $root "provider-provenance.json"
  $provenance = Get-Content $path -Raw | ConvertFrom-Json
  $pinsPath = if ($ProviderPinsPath) { $ProviderPinsPath } else { Join-Path $root "provider-pins.json" }
  $pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
  foreach ($provider in @("winghostty", "zmx")) {
    $p = $provenance.$provider
    $pin = $pins.$provider
    Require ($p.sha -eq $pin.sha -and $p.repository -eq $pin.repository) "$provider provenance pin mismatch"
    Require ([string]$p.sha256 -match "^[0-9a-fA-F]{64}$") "$provider provenance digest is missing"
    $normalizedPath = Normalize-ManifestPath ([string]$p.packagePath)
    Require ($normalizedPath -eq $p.packagePath) "$provider provenance path is not normalized"
    $artifact = Join-Path $root ($p.packagePath -replace "/", "\")
    Require (Test-Path $artifact -PathType Leaf) "$provider provenance artifact is missing"
    Require ((Get-FileHash $artifact -Algorithm SHA256).Hash.ToLowerInvariant() -eq $p.sha256.ToLowerInvariant()) "$provider provenance digest mismatch"
    $normalizedLicensePath = Normalize-ManifestPath ([string]$p.licensePath)
    Require ($normalizedLicensePath -eq $p.licensePath) "$provider license path is not normalized"
    $licensePath = Join-Path $root ($normalizedLicensePath -replace "/", "\")
    Require (Test-Path $licensePath -PathType Leaf) "$provider license file is missing"
    Require ((Get-FileHash $licensePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $p.licenseSha256.ToLowerInvariant()) "$provider license digest mismatch"
  }
  return $provenance
}
function Get-PackageCodeFiles([string] $root) {
  Get-ChildItem -LiteralPath (Join-Path $root "bin") -Filter *.exe -File -Recurse -Force
  $setup = Join-Path $root "GraphCode-Setup.ps1"
  if (Test-Path -LiteralPath $setup -PathType Leaf) { Get-Item -LiteralPath $setup -Force }
}
function Verify-SignedPackage(
  [string] $root,
  [object] $metadata,
  [string] $trustedSigner = $TrustedSignerThumbprint
) {
  $catalogPath = Join-Path $root "package.cat"
  if ($metadata.signing -ne "signed") {
    Require (-not $trustedSigner) "trusted publisher verification requires a signed package"
    Require (-not (Test-Path -LiteralPath $catalogPath)) "unsigned package contains a signing catalog"
    return
  }
  Require ([bool]$trustedSigner) "trusted publisher thumbprint is required for signed packages"
  Require ($trustedSigner -match "^[0-9a-fA-F]{40}$") "trusted publisher thumbprint is invalid"
  Require (Test-Path -LiteralPath $catalogPath -PathType Leaf) "signed package has no catalog"
  $signature = Get-AuthenticodeSignature -FilePath $catalogPath
  Require ($signature.Status -eq "Valid") "catalog Authenticode verification failed"
  Require ($signature.SignerCertificate.Thumbprint -eq $trustedSigner) "catalog publisher does not match trusted thumbprint"
  $catalog = Test-FileCatalog -CatalogFilePath $catalogPath -Path $root -Detailed
  Require ($catalog.HashAlgorithm -eq "SHA256") "catalog must use SHA256"
  Require ($catalog.Status -eq "Valid") "catalog contents do not match package files"
  Require (Test-Path (Join-Path $root "SIGNATURES.txt")) "signed package has no signature record"
  $tool = if ($SignToolPath) { $SignToolPath } else { (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source }
  foreach ($file in @(Get-PackageCodeFiles $root)) {
    $authenticode = Get-AuthenticodeSignature -FilePath $file.FullName
    Require ($authenticode.Status -eq "Valid") "clean-machine Authenticode verification failed: $($file.Name)"
    Require ($authenticode.SignerCertificate.Thumbprint -eq $trustedSigner) "code publisher does not match: $($file.Name)"
    if ($tool -and (Test-Path $tool)) {
      & $tool verify /pa $file.FullName *> $null
      Require ($LASTEXITCODE -eq 0) "optional signtool diagnostic failed: $($file.Name)"
    }
  }
}
function Verify-PackageContents([string] $root, [string] $trustedSigner = $TrustedSignerThumbprint) {
  $root = (Resolve-Path -LiteralPath $root).Path
  $metadata = Assert-Package $root
  Verify-Manifest $root | Out-Null
  Read-ProviderProvenance $root | Out-Null
  Verify-SignedPackage $root $metadata $trustedSigner
  return $metadata
}
function Get-TaskIdentity([string] $support) {
  $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
  $resolved = [IO.Path]::GetFullPath($support).TrimEnd("\").ToLowerInvariant()
  $bytes = [Text.Encoding]::UTF8.GetBytes("$sid|$resolved")
  $hash = ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  return @{ sid = $sid; name = "GraphCode\graphcoded-$($hash.Substring(0, 32))" }
}
function Xml-Escape([string] $value) {
  return [System.Security.SecurityElement]::Escape($value)
}
function Invoke-PackageCommand([string] $executable, [string[]] $arguments) {
  $application = Get-Command $executable -CommandType Application -ErrorAction Stop
  # Windows PowerShell converts redirected native stderr into ErrorRecords.
  # Capture it locally and decide success from the native exit code on both hosts.
  $ErrorActionPreference = "Continue"
  $previousExitCode = $global:LASTEXITCODE
  try {
    $global:LASTEXITCODE = $null
    $output = & $application.Source @arguments 2>&1 | Out-String
    $exitCode = $global:LASTEXITCODE
  } finally { $global:LASTEXITCODE = $previousExitCode }
  if ($null -eq $exitCode) { Fail "could not execute $executable`: $output" }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output.Trim() }
}
function Test-DaemonTask([string] $name) {
  $scheduler = New-Object -ComObject Schedule.Service
  $folder = $null
  $task = $null
  try {
    $scheduler.Connect()
    try {
      $folder = $scheduler.GetFolder("\GraphCode")
      $task = $folder.GetTask(($name.Split("\")[-1]))
      return $true
    } catch {
      $failure = $_.Exception
      while ($failure.InnerException) { $failure = $failure.InnerException }
      if ($failure.HResult -in @(-2147024894, -2147024893)) { return $false }
      throw
    }
  } finally {
    foreach ($value in @($task, $folder, $scheduler)) {
      if ($null -ne $value) { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($value) }
    }
  }
}
function Open-Package([string] $path) {
  Require (Test-Path -LiteralPath $path) "package does not exist: $path"
  if ((Get-Item $path).PSIsContainer) { return (Resolve-Path $path).Path }
  $extract = Join-Path ([IO.Path]::GetTempPath()) "graphcode-package-$([guid]::NewGuid())"
  $script:PackageExtraction = $extract
  Expand-Archive -LiteralPath $path -DestinationPath $extract
  $entries = @(Get-ChildItem $extract)
  $nested = @($entries | Where-Object { $_.PSIsContainer })
  if ($nested.Count -eq 1 -and $nested[0].Name -eq "GraphCode" -and
    @($entries | Where-Object { -not $_.PSIsContainer }).Count -eq 0) { return $nested[0].FullName }
  if ((Test-Path (Join-Path $extract "manifest.json")) -and (Test-Path (Join-Path $extract "metadata.json"))) { return $extract }
  Fail "ZIP must contain one GraphCode directory or a verified flat package root"
}
function Close-Package {
  if ($script:PackageExtraction) {
    Remove-Item -LiteralPath $script:PackageExtraction -Recurse -Force -ErrorAction SilentlyContinue
    $script:PackageExtraction = $null
  }
}
function Set-UserPath([string] $bin, [bool] $add) {
  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @($current -split ";" | Where-Object { $_ -and $_ -ne $bin })
  if ($add) { $parts += $bin }
  [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}
function Set-Shortcut([bool] $create) {
  $shortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.lnk"
  $fallback = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.url"
  if (-not $create) {
    Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fallback -Force -ErrorAction SilentlyContinue
    return
  }
  $directory = Split-Path $shortcut -Parent
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = Join-Path $InstallRoot "bin\graphcode-windows.exe"
    $link.WorkingDirectory = Join-Path $InstallRoot "bin"
    $link.Description = "GraphCode Windows shell"
    $link.Save()
  } catch {
    $target = [Uri]::new((Join-Path $InstallRoot "bin\graphcode-windows.exe")).AbsoluteUri
    @"
[InternetShortcut]
URL=$target
IconFile=$(Join-Path $InstallRoot "bin\graphcode-windows.exe")
IconIndex=0
"@ | Set-Content -LiteralPath $fallback -Encoding ascii
  }
}
function Get-InstalledDaemons {
  $expected = [IO.Path]::GetFullPath((Join-Path $InstallRoot "bin\graphcoded.exe"))
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected)
    })
}
function Disable-DaemonTask([string] $name) {
  # The repeating trigger would otherwise restart a daemon that an explicit stop just ended.
  $result = Invoke-PackageCommand "schtasks.exe" @("/Change", "/TN", $name, "/DISABLE")
  Require ($result.ExitCode -eq 0) "scheduled-task disable failed: $($result.Output)"
}
function Stop-InstalledDaemon {
  $support = if ($env:GRAPHCODE_SUPPORT_DIR) { $env:GRAPHCODE_SUPPORT_DIR } else { Join-Path $env:USERPROFILE ".graphcode" }
  $identity = Get-TaskIdentity $support
  if (Test-DaemonTask $identity.name) {
    Disable-DaemonTask $identity.name
    $result = Invoke-PackageCommand "schtasks.exe" @("/End", "/TN", $identity.name)
    Require ($result.ExitCode -eq 0) "scheduled-task stop failed: $($result.Output)"
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  while (@(Get-InstalledDaemons).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 200
  }
  foreach ($process in @(Get-InstalledDaemons)) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(4)
  while (@(Get-InstalledDaemons).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 200
  }
  Require (@(Get-InstalledDaemons).Count -eq 0) "installed graphcoded process did not stop"
}
function Remove-DaemonTask {
  $support = if ($env:GRAPHCODE_SUPPORT_DIR) { $env:GRAPHCODE_SUPPORT_DIR } else { Join-Path $env:USERPROFILE ".graphcode" }
  $identity = Get-TaskIdentity $support
  if (-not (Test-DaemonTask $identity.name)) { return }
  Disable-DaemonTask $identity.name
  $result = Invoke-PackageCommand "schtasks.exe" @("/End", "/TN", $identity.name)
  Require ($result.ExitCode -eq 0) "scheduled-task stop failed: $($result.Output)"
  $result = Invoke-PackageCommand "schtasks.exe" @("/Delete", "/TN", $identity.name, "/F")
  Require ($result.ExitCode -eq 0) "scheduled-task removal failed: $($result.Output)"
}
function New-DaemonTaskXml([hashtable] $identity, [string] $support) {
  $sid = Xml-Escape $identity.sid
  $command = Xml-Escape (Join-Path $env:SystemRoot "System32\cmd.exe")
  $arguments = Xml-Escape "/d /s /c `"set `"GRAPHCODE_SUPPORT_DIR=$support`"`&`&`"$InstallRoot\bin\graphcoded.exe`"`""
  $workingDirectory = Xml-Escape (Join-Path $InstallRoot "bin")
  # launchd runs the macOS daemon with KeepAlive; the Windows equivalent is a one-minute
  # repeating trigger. MultipleInstancesPolicy IgnoreNew makes every tick a no-op while the
  # daemon runs and restarts it, whatever its exit code, once it has stopped. Task Scheduler's
  # own RestartOnFailure is not used: it fires only when a task cannot launch, never when a
  # launched process exits. Uninstall and upgrade disable the task before ending it, so an
  # explicit stop is not undone by the next tick. Battery limits would otherwise refuse or kill
  # the daemon on laptops.
  return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>GraphCode daemon for $sid</Description></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId></LogonTrigger>
    <TimeTrigger><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><StartBoundary>2000-01-01T00:00:00</StartBoundary><Enabled>true</Enabled></TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings>
  <Actions Context="Author"><Exec><Command>$command</Command><Arguments>$arguments</Arguments><WorkingDirectory>$workingDirectory</WorkingDirectory></Exec></Actions>
</Task>
"@
}
function Start-DaemonTask {
  $support = if ($env:GRAPHCODE_SUPPORT_DIR) { $env:GRAPHCODE_SUPPORT_DIR } else { Join-Path $env:USERPROFILE ".graphcode" }
  $identity = Get-TaskIdentity $support
  New-Item -ItemType Directory -Force $support | Out-Null
  $xmlPath = Join-Path (Split-Path $InstallRoot -Parent) "GraphCode-daemon-task.xml"
  $xml = New-DaemonTaskXml $identity $support
  [IO.File]::WriteAllText($xmlPath, $xml, [Text.Encoding]::Unicode)
  $result = Invoke-PackageCommand "schtasks.exe" @("/Create", "/TN", $identity.name, "/XML", $xmlPath, "/F")
  Require ($result.ExitCode -eq 0) "scheduled-task registration failed: $($result.Output)"
  Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
  $result = Invoke-PackageCommand "schtasks.exe" @("/Run", "/TN", $identity.name)
  Require ($result.ExitCode -eq 0) "scheduled-task start failed: $($result.Output)"
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (@(Get-InstalledDaemons).Count -gt 0) {
      $cli = Join-Path $InstallRoot "bin\graphcode.exe"
      $env:GRAPHCODE_SUPPORT_DIR = $support
      $result = Invoke-PackageCommand $cli @("projects")
      if ($result.ExitCode -eq 0) { return }
    }
    Start-Sleep -Milliseconds 300
  }
  throw "scheduled graphcoded endpoint did not become reachable"
}
function Move-InstallDirectory([string] $source, [string] $destination) {
  # Staging and backup are siblings: use a rename, not Move-Item's recursive move.
  $source = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($source)
  $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($destination)
  [IO.Directory]::Move($source, $destination)
}
function Install-Package([bool] $upgrade) {
  try {
    $root = Open-Package ($(if ($Package) { $Package } else { Fail "-Package is required" }))
    $metadata = Verify-PackageContents $root
    if ($versionWasProvided -and $metadata.version -ne $Version) { Fail "version mismatch: expected $Version, package is $($metadata.version)" }
    $parent = Split-Path $InstallRoot -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $stage = Join-Path $parent ".GraphCode-install-$([guid]::NewGuid())"
    $backup = Join-Path $parent ".GraphCode-rollback-$([guid]::NewGuid())"
    $shortcutBackup = Join-Path $parent ".GraphCode-shortcut-$([guid]::NewGuid())"
    $previousInstallMoved = $false
    $stagedInstallPromoted = $false
    $integrationAttempted = $false
    $daemonAttempted = $false
    $keepShortcutBackup = $false
    $committed = $false
    try {
      Copy-Tree $root $stage
      $stagedMetadata = Verify-PackageContents $stage
      Require ($stagedMetadata.version -eq $metadata.version) "package version changed during staging"
      New-Item -ItemType Directory -Force -Path $shortcutBackup | Out-Null
      Save-Shortcut $shortcutBackup
      $oldPath = [Environment]::GetEnvironmentVariable("Path", "User")
      if (-not $NoScheduledTask) {
        $daemonAttempted = $true
        Stop-InstalledDaemon
        Remove-DaemonTask
      }
      if (Test-Path -LiteralPath $InstallRoot) {
        Move-InstallDirectory $InstallRoot $backup
        $previousInstallMoved = $true
      }
      Move-InstallDirectory $stage $InstallRoot
      $stagedInstallPromoted = $true
      $integrationAttempted = $true
      Set-UserPath (Join-Path $InstallRoot "bin") $true
      Set-Shortcut $true
      if (-not $NoScheduledTask) { Start-DaemonTask }
      $committed = $true
    } catch {
      $failure = $_
      $rollbackErrors = [Collections.Generic.List[string]]::new()
      $canRestoreFiles = $true
      if ($stagedInstallPromoted -and $daemonAttempted) {
        try {
          Stop-InstalledDaemon
          Remove-DaemonTask
        } catch {
          $rollbackErrors.Add("stopping the new installation: $($_.Exception.Message)")
          $canRestoreFiles = $false
        }
      }
      # Never delete an installation that this transaction did not promote.
      if ($stagedInstallPromoted -and $canRestoreFiles) {
        try {
          Remove-Item -LiteralPath $InstallRoot -Recurse -Force
          $stagedInstallPromoted = $false
        } catch {
          $rollbackErrors.Add("removing the new installation: $($_.Exception.Message)")
          $canRestoreFiles = $false
        }
      }
      if ($previousInstallMoved -and $canRestoreFiles) {
        try {
          Move-InstallDirectory $backup $InstallRoot
          $previousInstallMoved = $false
        } catch {
          $rollbackErrors.Add("restoring the previous installation: $($_.Exception.Message)")
        }
      }
      if ($integrationAttempted) {
        try { [Environment]::SetEnvironmentVariable("Path", $oldPath, "User") } catch {
          $rollbackErrors.Add("restoring user PATH: $($_.Exception.Message)")
        }
        try { Restore-Shortcut $shortcutBackup } catch {
          $keepShortcutBackup = $true
          $rollbackErrors.Add("restoring shortcuts: $($_.Exception.Message)")
        }
      }
      if ($daemonAttempted -and -not $previousInstallMoved -and -not $stagedInstallPromoted -and
          (Test-Path -LiteralPath (Join-Path $InstallRoot "bin\graphcoded.exe"))) {
        try { Start-DaemonTask } catch {
          $rollbackErrors.Add("restarting the previous daemon: $($_.Exception.Message)")
        }
      }
      if ($rollbackErrors.Count) {
        $recovery = @()
        if ($previousInstallMoved) { $recovery += "Previous installation retained at: $backup." }
        if ($keepShortcutBackup) { $recovery += "Shortcut recovery snapshot retained at: $shortcutBackup." }
        Fail "Installation failed: $($failure.Exception.Message). Rollback incomplete: $($rollbackErrors -join '; '). $($recovery -join ' ')"
      }
      throw $failure
    } finally {
      $cleanup = @($stage)
      if ($committed) { $cleanup += $backup }
      if (-not $keepShortcutBackup) { $cleanup += $shortcutBackup }
      foreach ($path in $cleanup) {
        if (Test-Path -LiteralPath $path) {
          try { Remove-Item -LiteralPath $path -Recurse -Force } catch {
            Write-Warning "GraphCode packaging: could not clean transaction directory '$path': $($_.Exception.Message)"
          }
        }
      }
    }
    Write-Output "Installed GraphCode $($metadata.version) at $InstallRoot"
  } finally {
    Close-Package
  }
}
function Get-FullInstallRoot {
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallRoot).TrimEnd("\")
}
function Get-InstallRootProcesses {
  $root = (Get-FullInstallRoot) + "\"
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    })
}
function Assert-InstallRootIdle([bool] $daemonManaged) {
  # Session hosts (zmx), the shell, and the CLI are the user's work: refuse rather than kill them.
  $daemon = Join-Path (Get-FullInstallRoot) "bin\graphcoded.exe"
  $blocking = @(Get-InstallRootProcesses | Where-Object {
      -not ($daemonManaged -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $daemon)
    })
  if ($blocking.Count -eq 0) { return }
  $summary = @($blocking | Group-Object Name | Sort-Object Name | ForEach-Object {
      "$($_.Name) (PID $((@($_.Group | ForEach-Object { $_.ProcessId }) | Sort-Object) -join ', '))"
    }) -join "; "
  $zmx = Join-Path $InstallRoot "bin\zmx.exe"
  Fail ("Uninstall changed nothing: $($blocking.Count) GraphCode process(es) are still running from " +
    "$InstallRoot`: $summary. Close GraphCode, end its terminal sessions (list them with " +
    "`"$zmx`" ls and stop each with `"$zmx`" kill NAME), then run Uninstall again from a " +
    "terminal outside GraphCode.")
}
function Find-LockedInstallFile([string] $root) {
  foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
    $access = if ($file.IsReadOnly) { [IO.FileAccess]::Read } else { [IO.FileAccess]::ReadWrite }
    try {
      # Exclusive opens fail for any open handle and, with write access, for mapped images.
      $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, $access, [IO.FileShare]::None)
      $stream.Dispose()
    } catch {
      $failure = $_.Exception
      while ($failure.InnerException) { $failure = $failure.InnerException }
      return "$($file.FullName) ($($failure.Message))"
    }
  }
  return $null
}
function Uninstall-Package {
  $daemonManaged = -not $NoScheduledTask
  $installed = Test-Path -LiteralPath $InstallRoot
  if ($installed) { Assert-InstallRootIdle $daemonManaged }
  $daemonWasRunning = $false
  $daemonTaskExisted = $false
  if ($daemonManaged) {
    $daemonWasRunning = @(Get-InstalledDaemons).Count -gt 0
    $support = if ($env:GRAPHCODE_SUPPORT_DIR) { $env:GRAPHCODE_SUPPORT_DIR } else { Join-Path $env:USERPROFILE ".graphcode" }
    $daemonTaskExisted = Test-DaemonTask (Get-TaskIdentity $support).name
    Stop-InstalledDaemon
  }
  $bin = Join-Path $InstallRoot "bin"
  $parent = Split-Path (Get-FullInstallRoot) -Parent
  $removed = $null
  $shortcutBackup = $null
  $pathAttempted = $false
  $shortcutAttempted = $false
  $oldPath = $null
  try {
    if ($installed) {
      # Re-check after stopping the daemon, then take the whole tree out of service with
      # one rename so a held file can never leave a half-deleted installation behind.
      Assert-InstallRootIdle $daemonManaged
      $locked = Find-LockedInstallFile $InstallRoot
      if ($locked) {
        Fail "Uninstall changed nothing: an installed file is in use: $locked. Close the program using it, then run Uninstall again."
      }
      $removed = Join-Path $parent ".GraphCode-uninstall-$([guid]::NewGuid())"
      Move-InstallDirectory $InstallRoot $removed
    }
    $shortcutBackup = Join-Path ([IO.Path]::GetTempPath()) "GraphCode-uninstall-shortcut-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force -Path $shortcutBackup | Out-Null
    Save-Shortcut $shortcutBackup
    $oldPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($daemonManaged) { Remove-DaemonTask }
    $pathAttempted = $true
    Set-UserPath $bin $false
    $shortcutAttempted = $true
    Set-Shortcut $false
  } catch {
    $failure = $_
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    $restored = $true
    if ($removed -and (Test-Path -LiteralPath $removed)) {
      try { Move-InstallDirectory $removed $InstallRoot } catch {
        $restored = $false
        $rollbackErrors.Add("restoring the installation from '$removed': $($_.Exception.Message)")
      }
    }
    if ($pathAttempted) {
      try { [Environment]::SetEnvironmentVariable("Path", $oldPath, "User") } catch {
        $rollbackErrors.Add("restoring user PATH: $($_.Exception.Message)")
      }
    }
    $keepShortcutBackup = $false
    if ($shortcutAttempted) {
      try { Restore-Shortcut $shortcutBackup } catch {
        $keepShortcutBackup = $true
        $rollbackErrors.Add("restoring shortcuts from '$shortcutBackup': $($_.Exception.Message)")
      }
    }
    # Stopping disabled the task, so a refused uninstall must re-register it, not just restart.
    if (($daemonWasRunning -or $daemonTaskExisted) -and $restored) {
      try { Start-DaemonTask } catch {
        $rollbackErrors.Add("restarting the daemon: $($_.Exception.Message)")
      }
    }
    if (-not $keepShortcutBackup -and $shortcutBackup -and (Test-Path -LiteralPath $shortcutBackup)) {
      Remove-Item -LiteralPath $shortcutBackup -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($rollbackErrors.Count) {
      Fail "Uninstall failed: $($failure.Exception.Message) Rollback incomplete: $($rollbackErrors -join '; ')."
    }
    throw $failure
  }
  if ($shortcutBackup -and (Test-Path -LiteralPath $shortcutBackup)) {
    Remove-Item -LiteralPath $shortcutBackup -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($removed) {
    try { Remove-Item -LiteralPath $removed -Recurse -Force } catch {
      Write-Warning "GraphCode packaging: GraphCode was uninstalled, but leftover files remain at '$removed': $($_.Exception.Message) Delete that directory after closing the program using it."
    }
  }
  $data = Join-Path $env:USERPROFILE ".graphcode"
  if ($RemoveUserData -and -not $KeepUserData) {
    Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    Write-Output "User data preserved under $data"
  }
}
