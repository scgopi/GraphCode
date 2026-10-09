[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
. (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1")
$fixture = Join-Path ([IO.Path]::GetTempPath()) "graphcode-scheduler-$([guid]::NewGuid())"
$oldSupport = $env:GRAPHCODE_SUPPORT_DIR
$env:GRAPHCODE_SUPPORT_DIR = $fixture
$InstallRoot = Join-Path $fixture "current"
$identity = Get-TaskIdentity $fixture
$scheduler = New-Object -ComObject Schedule.Service
$folder = $null
$definition = $null
$registered = $null
$action = $null
try {
  $scheduler.Connect()
  $definition = $scheduler.NewTask(0)
  $definition.Principal.UserId = $identity.sid
  $definition.Principal.LogonType = 3
  $definition.Settings.Enabled = $true
  $action = $definition.Actions.Create(0)
  $action.Path = Join-Path $env:SystemRoot "System32\cmd.exe"
  $action.Arguments = "/d /c exit 0"
  $rootFolder = $scheduler.GetFolder("\")
  try {
    try { $folder = $scheduler.GetFolder("\GraphCode") } catch {
      $failure = $_.Exception
      while ($failure.InnerException) { $failure = $failure.InnerException }
      if ($failure.HResult -notin @(-2147024894, -2147024893)) { throw }
      $folder = $rootFolder.CreateFolder("GraphCode")
    }
    $registered = $folder.RegisterTaskDefinition($identity.name.Split("\")[-1], $definition, 2, $identity.sid, $null, 3)
  } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($rootFolder) }
  if ($registered.State -ne 3) { throw "Scheduler fixture is not idle/ready" }
  if (-not (Test-DaemonTask $identity.name)) { throw "Existing idle task was reported absent" }
  $missingName = "graphcode-missing-$([guid]::NewGuid())"
  $missingError = $null
  try { [void] $folder.GetTask($missingName) } catch {
    $missingError = $_.Exception
    while ($missingError.InnerException) { $missingError = $missingError.InnerException }
  }
  if (-not $missingError -or $missingError.HResult -ne -2147024894) {
    throw "Missing task did not produce ERROR_FILE_NOT_FOUND: $missingError"
  }
  if (Test-DaemonTask "GraphCode\$missingName") { throw "Missing task was reported present" }
  $ended = Invoke-PackageCommand "schtasks.exe" @("/End", "/TN", $identity.name)
  if ($ended.ExitCode -ne 0) { throw "Ending an idle task failed: $($ended.Output)" }
  Stop-InstalledDaemon
  Remove-DaemonTask
  if (Test-DaemonTask $identity.name) { throw "Idle task was not removed" }
  Write-Output "Native missing-task HRESULT 0x80070002 and idle-task stop/delete: PASS"

  # The installed task definition must keep the daemon alive the way launchd KeepAlive does:
  # restart it once it has stopped, never refuse or kill it on battery, and let an explicit
  # stop stick.
  [xml] $taskXml = New-DaemonTaskXml $identity $fixture
  $ns = New-Object Xml.XmlNamespaceManager($taskXml.NameTable)
  $ns.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
  function Get-TaskSetting([string] $name) { $taskXml.SelectSingleNode("//t:Settings/t:$name", $ns).InnerText }
  $expectedSettings = [ordered]@{
    MultipleInstancesPolicy = "IgnoreNew"
    DisallowStartIfOnBatteries = "false"
    StopIfGoingOnBatteries = "false"
    StartWhenAvailable = "true"
    ExecutionTimeLimit = "PT0S"
  }
  foreach ($key in $expectedSettings.Keys) {
    if ((Get-TaskSetting $key) -ne $expectedSettings[$key]) {
      throw "Task setting $key is '$(Get-TaskSetting $key)', expected '$($expectedSettings[$key])'"
    }
  }
  $triggers = @($taskXml.SelectNodes("//t:Triggers/*", $ns) | ForEach-Object { $_.LocalName })
  if (($triggers -join ",") -ne "LogonTrigger,TimeTrigger") { throw "Task triggers are '$($triggers -join ',')'" }
  $repetition = $taskXml.SelectSingleNode("//t:TimeTrigger/t:Repetition", $ns)
  if ($repetition.Interval -ne "PT1M" -or $repetition.SelectSingleNode("t:Duration", $ns)) {
    throw "Daemon task must repeat every minute indefinitely"
  }

  # Prove the behaviour on the real scheduler with a harmless action in place of the daemon.
  New-Item -ItemType Directory -Force $fixture | Out-Null
  $marker = Join-Path $fixture "runs.txt"
  $taskXml.SelectSingleNode("//t:Exec/t:Command", $ns).InnerText = Join-Path $env:SystemRoot "System32\cmd.exe"
  $taskXml.SelectSingleNode("//t:Exec/t:Arguments", $ns).InnerText = "/d /c echo run>>`"$marker`""
  $taskXml.SelectSingleNode("//t:Exec/t:WorkingDirectory", $ns).InnerText = $fixture
  $xmlPath = Join-Path $fixture "daemon-task.xml"
  [IO.File]::WriteAllText($xmlPath, $taskXml.OuterXml, [Text.Encoding]::Unicode)
  $created = Invoke-PackageCommand "schtasks.exe" @("/Create", "/TN", $identity.name, "/XML", $xmlPath, "/F")
  if ($created.ExitCode -ne 0) { throw "Daemon task definition was rejected by the scheduler: $($created.Output)" }
  function Get-RunCount { if (Test-Path -LiteralPath $marker) { @(Get-Content -LiteralPath $marker).Count } else { 0 } }
  function Wait-RunCount([int] $count, [int] $seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    while ((Get-RunCount) -lt $count -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
    return (Get-RunCount) -ge $count
  }
  $started = Invoke-PackageCommand "schtasks.exe" @("/Run", "/TN", $identity.name)
  if ($started.ExitCode -ne 0) { throw "Starting the daemon task failed: $($started.Output)" }
  if (-not (Wait-RunCount 1 30)) { throw "The daemon task did not run its action" }
  # The action has already exited; only the repeating trigger can run it again.
  if (-not (Wait-RunCount 2 150)) { throw "A stopped daemon task was not restarted by the repeating trigger" }
  Write-Output "Daemon task restarts after its process ends: PASS"

  Stop-InstalledDaemon
  $runsAtStop = Get-RunCount
  Start-Sleep -Seconds 70
  if ((Get-RunCount) -ne $runsAtStop) { throw "The daemon task restarted after an explicit stop" }
  $live = $folder.GetTask($identity.name.Split("\")[-1])
  try {
    if ($live.Enabled) { throw "An explicitly stopped daemon task is still enabled" }
  } finally {
    [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($live)
  }
  Remove-DaemonTask
  if (Test-DaemonTask $identity.name) { throw "Daemon task was not removed" }
  Write-Output "Daemon task stays stopped after an explicit stop and is removable: PASS"
} finally {
  try {
    if (Test-DaemonTask $identity.name) {
      $deleted = Invoke-PackageCommand "schtasks.exe" @("/Delete", "/TN", $identity.name, "/F")
      if ($deleted.ExitCode -ne 0) { throw "Could not remove owned scheduler fixture: $($deleted.Output)" }
    }
  } finally {
    $env:GRAPHCODE_SUPPORT_DIR = $oldSupport
    foreach ($value in @($registered, $action, $definition, $folder, $scheduler)) {
      if ($null -ne $value) { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($value) }
    }
  }
}
