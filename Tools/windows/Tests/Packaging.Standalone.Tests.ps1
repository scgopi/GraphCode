[CmdletBinding()]
param(
  [switch] $SelfTest,
  [switch] $DiagnosticSelfTest,
  [switch] $LauncherSelfTest,
  [switch] $HelpersOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$fixture = Join-Path ([IO.Path]::GetTempPath()) "graphcode-standalone-$([guid]::NewGuid())"
$setupCases = @{ Completed = 0; Scenarios = @{}; LastDiagnostic = $null }
$definitions = @{}
foreach ($file in @("package.ps1", "PackageRuntime.ps1")) {
  $path = Join-Path $repoRoot "Tools\windows\$file"
  if (-not (Test-Path -LiteralPath $path)) { continue }
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "Packaging parse errors: $errors" }
  foreach ($node in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
      }, $true)) {
    $definitions[$node.Name] = $node.Extent.Text
  }
}
foreach ($name in @("Fail", "Require", "Get-Manifest", "Write-Metadata", "Write-PackageSetup")) {
  if (-not $definitions.ContainsKey($name)) { throw "RED: standalone setup helper is missing: $name" }
  . ([scriptblock]::Create($definitions[$name]))
}

function ConvertTo-StandaloneLiteral([string] $value) {
  return "'" + $value.Replace("'", "''") + "'"
}

function Get-StandaloneLaunchCommand(
  [string] $gate, [string] $trace, [string] $entryPoint, [string[]] $arguments
) {
  $scripts = @($entryPoint)
  if ($entryPoint -eq (Join-Path $repoRoot "Tools\windows\package.ps1")) {
    $scripts += Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1"
  }
  $argumentLiterals = @($arguments | ForEach-Object { ConvertTo-StandaloneLiteral $_ }) -join ","
  $scriptLiterals = @($scripts | ForEach-Object { ConvertTo-StandaloneLiteral $_ }) -join ","
  $launchDeclaration = '$launch = @{ gate = ' + (ConvertTo-StandaloneLiteral $gate) +
    '; entryPoint = ' + (ConvertTo-StandaloneLiteral $entryPoint) +
    '; arguments = [string[]]@(' + $argumentLiterals + '); scripts = [string[]]@(' + $scriptLiterals + ') }'
  # Assignment precedes the gate, so even an immediately spawning script belongs to our job.
  $command = '$global:StandaloneDiagnosticTracePath = ' + (ConvertTo-StandaloneLiteral $trace) + "`n"
  $command += @'
$global:StandaloneDiagnosticClock = [Diagnostics.Stopwatch]::StartNew()
[IO.File]::AppendAllText($global:StandaloneDiagnosticTracePath, "0:host-entered" + [Environment]::NewLine)
function Write-StandaloneStage([string] $stage) {
  [IO.File]::AppendAllText($global:StandaloneDiagnosticTracePath,
    $global:StandaloneDiagnosticClock.ElapsedMilliseconds.ToString() + ":" + $stage + [Environment]::NewLine)
}
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$global:LASTEXITCODE = 0
Write-StandaloneStage ("host-version:" + $PSVersionTable.PSVersion.ToString())
Write-StandaloneStage "launch-values:begin"
'@
  # Literal strings and typed arrays require no child-side JSON command/module discovery.
  $command += "`n" + $launchDeclaration + "`n"
  $command += @'
Write-StandaloneStage "launch-values:end"
Write-StandaloneStage "gate-wait:begin"
while (-not [IO.File]::Exists($launch.gate)) { [Threading.Thread]::Sleep(10) }
Write-StandaloneStage "gate-wait:end"
Write-StandaloneStage "stage-registration:begin"
$global:StandaloneDiagnosticScripts = $launch.scripts
foreach ($name in @("Open-Package", "Verify-PackageContents", "Assert-Package", "Verify-Manifest",
    "Read-ProviderProvenance", "Verify-SignedPackage", "Invoke-PackageCommand", "Close-Package",
    "Get-Content", "ConvertFrom-Json", "Get-FileHash", "Expand-Archive", "Get-AuthenticodeSignature",
    "Test-FileCatalog", "Import-Module", "Add-Type", "Get-Command")) {
  $action = [scriptblock]::Create("`$frame = Get-PSCallStack | Where-Object { " +
    "`$_.ScriptName -in `$global:StandaloneDiagnosticScripts } | Select-Object -First 1; " +
    "[IO.File]::AppendAllText(`$global:StandaloneDiagnosticTracePath, " +
    "`$global:StandaloneDiagnosticClock.ElapsedMilliseconds.ToString() + ':command:${name}:script=' + " +
    "[IO.Path]::GetFileName(`$frame.ScriptName) + ':line=' + `$frame.ScriptLineNumber + [Environment]::NewLine)")
  Set-PSBreakpoint -Script $launch.scripts -Command $name -Action $action | Out-Null
}
Write-StandaloneStage "stage-registration:end"
$named = @{}
$positional = [Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $launch.arguments.Length; $index++) {
  $argument = $launch.arguments[$index]
  if ($argument -match '^-[A-Za-z][A-Za-z0-9]*$') {
    $name = $argument.Substring(1)
    if ($named.ContainsKey($name) -or $index + 1 -ge $launch.arguments.Length) {
      throw "Standalone launcher has a duplicate or valueless named argument"
    }
    $index++
    $named[$name] = $launch.arguments[$index]
  } else { $positional.Add($argument) }
}
$positionalArguments = $positional.ToArray()
Write-StandaloneStage "dispatch:begin"
& $launch.entryPoint @named @positionalArguments
Write-StandaloneStage "dispatch:end"
exit $LASTEXITCODE
'@
  return $command
}

function Invoke-Setup(
  [string] $hostPath, [string[]] $arguments, [string] $expectedError,
  [string] $entryPoint = $setup, [string] $successMarker = "Package verification: PASS",
  [ValidateRange(1, 60000)][int] $timeoutMilliseconds = 60000,
  [string] $scenario = ""
) {
  if ($scenario -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $setupCases.Scenarios.ContainsKey($scenario)) {
    throw "Standalone scenario identity is missing or ambiguous"
  }
  $setupCases.Scenarios[$scenario] = $true
  $trace = Join-Path $fixture "stage-$([guid]::NewGuid()).log"
  $display = {
    param([string] $value)
    $value.Replace($fixture, "(fixture)").Replace($repoRoot, "(repo)")
  }
  $report = [ordered]@{
    Scenario = $scenario
    Host = (& $display $hostPath)
    HostVersion = $null
    Arguments = @($arguments | ForEach-Object { & $display $_ })
    EntryPoint = (& $display $entryPoint)
    BudgetMilliseconds = $timeoutMilliseconds
    ControllerStage = "job-create"
    CurrentStage = "host-not-entered"
    Stages = @()
    ProcessId = $null
    CreationUtcTicks = $null
    HasExited = $null
    ExitCode = $null
    HostArguments = @("-NoProfile", "-NonInteractive", "-OutputFormat", "Text", "-EncodedCommand", "(owned launch payload)")
    StdoutBeforeTeardown = $null
    StderrBeforeTeardown = $null
    StdoutAfterTeardown = $null
    StderrAfterTeardown = $null
    ActiveBeforeTeardown = $null
    ActiveAfterTeardown = $null
    JobBeforeTeardown = $null
    OwnedProcessesBeforeTeardown = $null
    ElapsedMilliseconds = 0
  }
  Write-Output "Standalone scenario BEGIN: $($report | ConvertTo-Json -Depth 8 -Compress)"
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $hostPath
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.WorkingDirectory = $fixture
  $start.Environment["PATH"] = Join-Path $env:SystemRoot "System32"
  $start.Environment["PSModuleAnalysisCachePath"] = Join-Path $fixture "ModuleAnalysisCache"
  [void] $start.Environment.Remove("PSModulePath")
  foreach ($variable in @($start.Environment.Keys | Where-Object { $_ -like "GRAPHCODE_*" -or $_ -like "SWIFT*" -or $_ -like "ZIG*" })) {
    [void] $start.Environment.Remove($variable)
  }
  $gate = Join-Path $fixture "setup-start-$([guid]::NewGuid())"
  $command = Get-StandaloneLaunchCommand $gate $trace $entryPoint $arguments
  foreach ($argument in @("-NoProfile", "-NonInteractive", "-OutputFormat", "Text", "-EncodedCommand",
      [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) {
    [void] $start.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  $job = [IntPtr]::Zero
  $started = $false
  $assigned = $false
  $stdout = $null
  $stderr = $null
  $primaryError = $null
  $clock = [Diagnostics.Stopwatch]::StartNew()
  try {
    $job = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Create()
    $report.ControllerStage = "process-start"
    $started = $process.Start()
    if (-not $started) { throw "Could not start standalone setup host" }
    $report.ProcessId = $process.Id
    $report.CreationUtcTicks = $process.StartTime.ToUniversalTime().Ticks
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $report.ControllerStage = "job-assign"
    [GraphCode.Validation.Ownership.StandaloneProcessJob]::Assign($job, $process.Handle)
    $assigned = $true
    $report.ControllerStage = "gate-release"
    [IO.File]::WriteAllText($gate, "assigned")
    $report.ControllerStage = "process-wait"
    $remaining = [Math]::Max(0, $timeoutMilliseconds - [int] $clock.ElapsedMilliseconds)
    if (-not $process.WaitForExit($remaining)) {
      throw "Standalone setup timed out"
    }
    $report.ControllerStage = "output-capture"
    $remaining = [Math]::Max(0, $timeoutMilliseconds - [int] $clock.ElapsedMilliseconds)
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]] @($stdout, $stderr), $remaining)) {
      throw "Standalone setup output capture timed out"
    }
    $report.ControllerStage = "result-assertions"
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    if ($expectedError) {
      if ($process.ExitCode -eq 0 -or $output -notmatch [regex]::Escape($expectedError)) {
        throw "Standalone rejection was not specific ($expectedError): $output"
      }
    } elseif ($process.ExitCode -ne 0 -or $output -notmatch ("(?m)^" + [regex]::Escape($successMarker) + "\r?$")) {
      throw "Standalone verification failed with $hostPath`: $output"
    }
    $stages = if ([IO.File]::Exists($trace)) { [IO.File]::ReadAllLines($trace) } else { @() }
    foreach ($stage in @("host-entered", "launch-values:begin", "launch-values:end", "gate-wait:begin",
        "gate-wait:end", "stage-registration:begin", "stage-registration:end", "dispatch:begin")) {
      if (@($stages | Where-Object { $_ -match ("^\d+:" + [regex]::Escape($stage) + "$") }).Count -ne 1) {
        throw "Standalone stage evidence is missing or incomplete"
      }
    }
    $setupCases.Completed++
  } catch {
    $primaryError = $_
    throw
  } finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
      $report.ElapsedMilliseconds = $clock.ElapsedMilliseconds
      $report.Stages = @(if ([IO.File]::Exists($trace)) { [IO.File]::ReadAllLines($trace) })
      if ($report.Stages.Count) { $report.CurrentStage = ($report.Stages[-1] -split ":", 2)[1] }
      $versions = @($report.Stages | Where-Object { $_ -match '^\d+:host-version:' })
      if ($versions.Count -eq 1) { $report.HostVersion = ($versions[0] -split ":", 3)[2] }
      if ($started) {
        $report.HasExited = $process.HasExited
        if ($process.HasExited) { $report.ExitCode = $process.ExitCode }
      }
      if ($assigned) {
        $report.ActiveBeforeTeardown = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($job)
        $report.JobBeforeTeardown = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Summary($job)
        $report.OwnedProcessesBeforeTeardown = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Processes($job)
      }
      # ReadToEndAsync cannot expose partial pipes; distinguish pending capture from empty output.
      $report.StdoutBeforeTeardown = if ($stdout -and $stdout.IsCompletedSuccessfully) {
        & $display $stdout.GetAwaiter().GetResult()
      } else { "(capture pending)" }
      $report.StderrBeforeTeardown = if ($stderr -and $stderr.IsCompletedSuccessfully) {
        & $display $stderr.GetAwaiter().GetResult()
      } else { "(capture pending)" }
      $setupCases.LastDiagnostic = $report
      if ($primaryError) {
        $primaryError.Exception.Data["StandaloneDiagnostic"] = $report
        $primaryError.Exception.Data["StandaloneInvocation"] = @{
          Host = $hostPath; HostArguments = @($start.ArgumentList); EntryPoint = $entryPoint; Arguments = @($arguments)
        }
        Write-Warning "Standalone failure BEFORE owned teardown: $($report | ConvertTo-Json -Depth 8 -Compress)" -WarningAction Continue
      }
    } catch { $cleanupErrors.Add("capturing standalone stage evidence: $($_.Exception.Message)") }
    try {
      if ($assigned) {
        [GraphCode.Validation.Ownership.StandaloneProcessJob]::Terminate($job)
        [GraphCode.Validation.Ownership.StandaloneProcessJob]::WaitForEmpty($job, 5000)
        $report.ActiveAfterTeardown = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($job)
      } elseif ($started -and -not $process.HasExited) {
        $process.Kill($true)
      }
      if ($started -and -not $process.WaitForExit(5000)) { throw "Standalone host survived termination" }
    } catch { $cleanupErrors.Add("owned process termination: $($_.Exception.Message)") }
    try {
      if ($job -ne [IntPtr]::Zero) { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Close($job) }
    } catch { $cleanupErrors.Add("closing owned job: $($_.Exception.Message)") }
    try {
      if ($stdout -and $stderr) {
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]] @($stdout, $stderr), 5000)) {
          throw "Standalone output readers did not complete after owned teardown"
        }
        $report.StdoutAfterTeardown = & $display $stdout.GetAwaiter().GetResult()
        $report.StderrAfterTeardown = & $display $stderr.GetAwaiter().GetResult()
        if ($primaryError) {
          $primaryError.Exception.Data["StandaloneOutput"] = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
          $primaryError.Exception.Data["StandaloneStdout"] = $stdout.GetAwaiter().GetResult()
          $primaryError.Exception.Data["StandaloneStderr"] = $stderr.GetAwaiter().GetResult()
          if ($primaryError.Exception.Message -in @("Standalone setup timed out", "Standalone setup output capture timed out") -and
              $primaryError.Exception.Data["StandaloneOutput"].Trim()) {
            Write-Warning "Standalone setup captured output after owned teardown: $($primaryError.Exception.Data['StandaloneOutput'])" -WarningAction Continue
          }
        }
      }
    } catch { $cleanupErrors.Add("draining redirected output: $($_.Exception.Message)") }
    try { $process.Dispose() } catch { $cleanupErrors.Add("disposing host: $($_.Exception.Message)") }
    Write-Output "Standalone scenario END: $($report | ConvertTo-Json -Depth 8 -Compress)"
    if ($cleanupErrors.Count) {
      $diagnostic = "Standalone setup teardown failed: $($cleanupErrors -join '; ')"
      if ($primaryError) {
        $primaryError.Exception.Data["StandaloneTeardownFailure"] = $diagnostic
        Write-Warning $diagnostic -WarningAction Continue
      } else { throw $diagnostic }
    }
  }
}

function Invoke-StandaloneFixture {
  [CmdletBinding()]
  param([scriptblock] $action)
  $primaryError = $null
  try {
    & $action
  } catch {
    $primaryError = $_
    throw
  } finally {
    try {
      if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    } catch {
      if (-not $primaryError) { throw }
      $diagnostic = "Standalone fixture cleanup failed: $($_.Exception.Message)"
      $primaryError.Exception.Data["StandaloneCleanupFailure"] = $diagnostic
      Write-Warning $diagnostic -WarningAction Continue
    }
  }
}

$validationAssemblyPath = $env:GRAPHCODE_VALIDATION_ASSEMBLY
if (-not $validationAssemblyPath) {
  $validationAssemblyPath = & (Join-Path $PSScriptRoot "..\Build-CompiledValidationRunner.ps1")
}
& (Join-Path $PSScriptRoot "..\Import-CompiledValidationAssembly.ps1") `
  -AssemblyPath $validationAssemblyPath -RequiredType "GraphCode.Validation.Ownership.StandaloneProcessJob" | Out-Null

function Test-StandaloneHarness([switch] $diagnosticOnly, [switch] $launcherOnly) {
  $hostPath = (Get-Command pwsh).Source
  $failures = 0
  $passed = 0
  $descendantSource = @'
param([string] $hostPath, [string] $mode)
$self = [Diagnostics.Process]::GetCurrentProcess()
$self.StartTime.ToUniversalTime().Ticks.ToString() + ":" + $self.Id |
  Set-Content (Join-Path $PSScriptRoot "root-identity")
$self.Dispose()
$start = [Diagnostics.ProcessStartInfo]::new($hostPath)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WorkingDirectory = $PSScriptRoot
$payload = "[IO.File]::WriteAllText('" + (Join-Path $PSScriptRoot "descendant-ready").Replace("'", "''") +
  "', 'ready'); [Threading.Thread]::Sleep(30000)"
foreach ($arg in @("-NoProfile", "-NonInteractive", "-EncodedCommand",
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload)))) {
  [void] $start.ArgumentList.Add($arg)
}
$descendant = [Diagnostics.Process]::Start($start)
$descendant.StartTime.ToUniversalTime().Ticks.ToString() + ":" + $descendant.Id |
  Set-Content (Join-Path $PSScriptRoot "descendant-identity")
$deadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not (Test-Path (Join-Path $PSScriptRoot "descendant-ready"))) {
  if ([DateTime]::UtcNow -ge $deadline) { throw "Descendant did not become ready" }
  Start-Sleep -Milliseconds 10
}
Write-Output "Package verification: PASS"
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "marker-written"), "ready")
if ($mode -like "timeout*") { [Threading.Thread]::Sleep(30000) }
'@
  $cases = @("success", "exit-stderr", "malformed-marker", "missing-marker", "timeout",
      "inherited-pipes", "cleanup-failure", "primary-and-cleanup", "timeout-and-cleanup",
      "exit-and-cleanup", "marker-and-cleanup")
  $specs = @()
  if (-not $diagnosticOnly -and -not $launcherOnly) {
    $specs += @($cases | ForEach-Object { @{ Case = $_; HostPath = $hostPath; HostId = "pwsh7" } })
  }
  foreach ($hostSpec in @(
      @{ Path = (Get-Command powershell.exe).Source; Id = "winps51" },
      @{ Path = $hostPath; Id = "pwsh7" }
    )) {
    $hostCases = @("launcher-no-json", "launcher-literals", "launcher-target-json")
    if (-not $launcherOnly) {
      $hostCases += @("diagnostic-success", "diagnostic-missing-stage", "diagnostic-identity", "diagnostic-timeout")
    }
    foreach ($case in $hostCases) {
      $specs += @{ Case = $case; HostPath = $hostSpec.Path; HostId = $hostSpec.Id }
    }
  }
  foreach ($spec in $specs) {
    $case = $spec.Case
    $caseId = "$($spec.HostId)-$case"
    $caseRoot = Join-Path $fixture $caseId
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
    $worker = Join-Path $fixture "$caseId-worker.ps1"
    $source = @'
param([string] $sourcePath, [string] $caseRoot, [string] $case, [string] $hostPath, [string] $testHostPath)
$ErrorActionPreference = "Stop"
. $sourcePath -HelpersOnly
$fixture = $caseRoot
Write-Output "CASE START: $case"
$entry = Join-Path $fixture "child.ps1"
if ($case -eq "launcher-literals") { $entry = Join-Path $fixture "child's literal script.ps1" }
$literalValues = @("Verify", "fixture's label with spaces", '-literal ; $value "quotes"', "",
  "-example", ([string][char]0x03BB + [char]0x96EA), 'literal`backtick', 'C:\fixture\path',
  'C:\fixture\trailing\', "'; [IO.File]::WriteAllText('injection-marker','bad'); #")
$literalNames = @("Command", "Label", "Literal", "Empty", "ParameterValue", "Unicode",
  "Backtick", "Path", "Trailing", "Code")
$literalArguments = @()
for ($index = 0; $index -lt $literalNames.Count; $index++) {
  $literalArguments += "-" + $literalNames[$index]
  $literalArguments += $literalValues[$index]
}
switch ($case) {
  "success" { $child = 'Write-Output "Package verification: PASS"' }
  { $_ -in @("exit-stderr", "exit-and-cleanup") } {
    $child = 'Write-Output "Package verification: PASS"; [Console]::Error.WriteLine("intentional stderr"); exit 7'
  }
  { $_ -in @("malformed-marker", "marker-and-cleanup") } { $child = 'Write-Output "Package verification: PASS-extra"' }
  "missing-marker" { $child = 'Write-Output "verification completed without marker"' }
  { $_ -in @("launcher-no-json", "launcher-literals", "launcher-target-json") } {
    $expected = @($literalValues | ForEach-Object { ConvertTo-StandaloneLiteral $_ }) -join ","
    $parameters = @($literalNames | ForEach-Object { '$' + $_ }) -join ","
    $child = 'param(' + $parameters + '); $expected = [string[]]@(' + $expected +
      '); $actual = @(' + $parameters + '); for ($index = 0; $index -lt $expected.Length; $index++) {' +
      ' if ($actual[$index] -isnot [string] -or $actual[$index] -cne $expected[$index]) {' +
      ' throw "Launcher changed literal argument at index $index" } };'
    if ($case -eq "launcher-target-json") {
      $child += ' if ((''{"verification":"allowed"}'' | ConvertFrom-Json).verification -ne "allowed") { throw "Target JSON verification was disabled" };'
    }
    $child += ' Write-Output "Package verification: PASS"'
  }
  "diagnostic-success" {
    $child = 'param([string] $Label); if ($Label -ne "fixture label with spaces") { throw "Fixture argument changed" }; function Verify-PackageContents { Write-Output "Package verification: PASS" }; Verify-PackageContents'
  }
  "diagnostic-identity" {
    $child = 'function Verify-PackageContents { Write-Output "Package verification: PASS" }; Verify-PackageContents'
  }
  "diagnostic-missing-stage" {
    $child = 'if ($global:StandaloneDiagnosticTracePath) { [IO.File]::Delete($global:StandaloneDiagnosticTracePath) }; Write-Output "Package verification: PASS"'
  }
  "diagnostic-timeout" {
    $child = 'Write-StandaloneStage "fixture-timeout-ready"; Write-Output "diagnostic-fixture-wait"; [Threading.Thread]::Sleep(120000)'
  }
  { $_ -in @("timeout", "inherited-pipes", "timeout-and-cleanup") } {
    $child = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("CHILD_SOURCE_BASE64"))
  }
}
if ($child) { [IO.File]::WriteAllText($entry, $child, [Text.UTF8Encoding]::new($true)) }
if ($case -like "launcher-*") {
  if ($case -eq "launcher-no-json") {
    $originalLauncher = ${function:Get-StandaloneLaunchCommand}
    function Get-StandaloneLaunchCommand($gate, $trace, $entryPoint, $arguments) {
      "function ConvertFrom-Json { throw 'Launcher JSON dependency forbidden' };`n" +
        (& $originalLauncher $gate $trace $entryPoint $arguments)
    }
  }
  Invoke-Setup $testHostPath $literalArguments "" $entry "Package verification: PASS" 60000 $case
  $report = $setupCases.LastDiagnostic
  if (($report.Arguments -join "|") -cne ($literalArguments -join "|") -or
      $report.ActiveAfterTeardown -ne 0 -or $report.CurrentStage -ne "dispatch:end") {
    throw "Launcher literal arguments, stage or owned teardown changed"
  }
  $launchBegin = @($report.Stages | Where-Object { $_ -match '^\d+:launch-values:begin$' })
  $launchEnd = @($report.Stages | Where-Object { $_ -match '^\d+:launch-values:end$' })
  if ($launchBegin.Count -ne 1 -or $launchEnd.Count -ne 1 -or
      ($report.Stages -join "`n") -match 'launch-json:') {
    throw "Launcher did not use the dependency-free typed-values path"
  }
  if ([IO.File]::Exists((Join-Path $fixture "injection-marker"))) { throw "Launcher executed a literal argument" }
  if ($case -eq "launcher-target-json" -and
      ($report.Stages -join "`n") -notmatch 'command:ConvertFrom-Json:script=child.ps1:line=1') {
    throw "Target JSON verification did not run after entry"
  }
} elseif ($case -like "diagnostic-*") {
  $actual = $null
  $clock = [Diagnostics.Stopwatch]::StartNew()
  try {
    $diagnosticArguments = @(if ($case -eq "diagnostic-success") { "-Label"; "fixture label with spaces" })
    Invoke-Setup $testHostPath $diagnosticArguments "" $entry "Package verification: PASS" 60000 $case
  } catch { $actual = $_ }
  if ($case -eq "diagnostic-success") {
    if ($actual) { throw $actual }
    $report = $setupCases.LastDiagnostic
    if (-not $report -or $report.Scenario -ne $case -or
        ($report.Arguments -join "|") -ne "-Label|fixture label with spaces" -or
        $report.Host -notmatch 'powershell\.exe|pwsh\.exe' -or $report.HostVersion -notmatch '^(5\.1|7\.)' -or
        $report.EntryPoint -ne "(fixture)\child.ps1" -or
        ($report.Stages -join "`n") -notmatch "command:Verify-PackageContents:script=child.ps1:line=1" -or
        ($report.Stages -join "`n") -notmatch "dispatch:end" -or $report.ActiveAfterTeardown -ne 0) {
      throw "Standalone scenario/host/argv/stage/owned-teardown diagnostics were missing"
    }
    if (($report | ConvertTo-Json -Depth 8) -match [regex]::Escape($fixture)) {
      throw "Standalone diagnostics leaked the private fixture root"
    }
  } elseif ($case -eq "diagnostic-missing-stage") {
    if (-not $actual -or $actual.Exception.Message -ne "Standalone stage evidence is missing or incomplete") {
      throw "Silent missing-stage result was accepted: $actual"
    }
    $report = $actual.Exception.Data["StandaloneDiagnostic"]
    if ($report.Stages.Count -ne 1 -or $report.CurrentStage -ne "dispatch:end") {
      throw "Incomplete stage evidence lost its exact surviving stage"
    }
  } elseif ($case -eq "diagnostic-timeout") {
    if (-not $actual -or $actual.Exception.Message -ne "Standalone setup timed out") {
      throw "Diagnostic timeout lost the exact primary failure: $actual"
    }
    $report = $actual.Exception.Data["StandaloneDiagnostic"]
    if (-not $report -or $report.CurrentStage -ne "fixture-timeout-ready" -or
        $report.ControllerStage -ne "process-wait" -or $report.ActiveBeforeTeardown -lt 1 -or
        $report.ActiveAfterTeardown -ne 0 -or $report.ProcessId -le 0 -or $report.CreationUtcTicks -le 0 -or
        $report.OwnedProcessesBeforeTeardown -notmatch ("pid=" + $report.ProcessId + "; creationUtcTicks=" + $report.CreationUtcTicks + "; name=(powershell|pwsh)") -or
        $actual.Exception.Data["StandaloneOutput"] -notmatch "diagnostic-fixture-wait") {
      throw "Timeout stage, identity, output, or owned accounting was missing"
    }
    if ($clock.ElapsedMilliseconds -gt 67000) { throw "Diagnostic timeout exceeded bounded teardown" }
  } else {
    if ($actual) { throw $actual }
    $completed = $setupCases.Completed
    foreach ($identity in @("", $case)) {
      $actual = $null
      try { Invoke-Setup $testHostPath @() "" $entry "Package verification: PASS" 3500 $identity }
      catch { $actual = $_ }
      if (-not $actual -or $actual.Exception.Message -ne "Standalone scenario identity is missing or ambiguous") {
        throw "Missing or duplicate scenario identity was accepted"
      }
    }
    if ($setupCases.Completed -ne $completed) { throw "Ambiguous scenario launched an unlabelled helper" }
  }
} elseif ($case -eq "cleanup-failure" -or $case -like "*-and-cleanup") {
  $locked = Join-Path $fixture "locked.txt"
  [IO.File]::WriteAllText($locked, "owned lock")
  $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  $actual = $null
  $warnings = @()
  try {
    try {
      Invoke-StandaloneFixture {
        if ($case -eq "primary-and-cleanup") { throw "exact primary failure" }
        if ($case -ne "cleanup-failure") {
          Invoke-Setup $hostPath @($hostPath, $case) "" $entry "Package verification: PASS" 2000 $case
        }
      } -WarningVariable warnings
    } catch { $actual = $_ }
    if (-not $actual) { throw "Cleanup failure was swallowed" }
    if ($case -ne "cleanup-failure") {
      $expected = switch ($case) {
        "primary-and-cleanup" { "exact primary failure" }
        "timeout-and-cleanup" { "Standalone setup timed out" }
        default { "Standalone verification failed with $hostPath`: " }
      }
      if (-not $actual.Exception.Message.StartsWith($expected) -or
          ($case -in @("primary-and-cleanup", "timeout-and-cleanup") -and $actual.Exception.Message -ne $expected)) {
        throw "Primary failure was masked: $($actual.Exception.Message)"
      }
      if (($warnings -join "`n") -notmatch "Standalone fixture cleanup failed:" -or
          $actual.Exception.Data["StandaloneCleanupFailure"] -notmatch "locked.txt") {
        throw "Secondary cleanup diagnostic was missing"
      }
      Write-Output "Primary retained: $($actual.Exception.Message)"
    } elseif ($actual.Exception.Message -notmatch "locked.txt") {
      throw "Cleanup-only failure lost its exact locked path: $actual"
    }
  } finally { $handle.Dispose() }
} else {
  $actual = $null
  $clock = [Diagnostics.Stopwatch]::StartNew()
  try {
    Invoke-Setup $hostPath @($hostPath, $case) "" $entry "Package verification: PASS" 2000 $case
  } catch { $actual = $_ }
  if ($case -eq "success") {
    if ($actual) { throw $actual }
  } elseif ($case -in @("timeout", "inherited-pipes")) {
    $expected = if ($case -eq "timeout") { "Standalone setup timed out" } else { "Standalone setup output capture timed out" }
    if (-not $actual -or $actual.Exception.Message -ne $expected) { throw "Exact primary message lost ($expected): $actual" }
    if ($clock.ElapsedMilliseconds -gt 9000) { throw "Helper exceeded its bounded teardown/capture deadline" }
    if (-not (Test-Path (Join-Path $fixture "descendant-ready"))) { throw "Owned descendant never reached test readiness" }
    if ($actual.Exception.Data["StandaloneOutput"] -notmatch "(?m)^Package verification: PASS\r?$") {
      throw "Redirected timeout diagnostics were not retained"
    }
    $identity = (Get-Content (Join-Path $fixture "descendant-identity") -Raw).Trim().Split(":")
    $report = $actual.Exception.Data["StandaloneDiagnostic"]
    if (-not $report -or $report.ActiveAfterTeardown -ne 0 -or
        $report.OwnedProcessesBeforeTeardown -notmatch
          ("pid=" + $identity[1] + "; creationUtcTicks=" + $identity[0] + "; name=pwsh")) {
      throw "Owned descendant was not identified before bounded teardown"
    }
    $survivor = Get-Process -Id ([int] $identity[1]) -ErrorAction SilentlyContinue
    if ($survivor -and $survivor.StartTime.ToUniversalTime().Ticks -eq [long] $identity[0]) {
      throw "Owned descendant survived helper return"
    }
    Write-Output "Owned descendant exited; capture drained; elapsedMilliseconds=$($clock.ElapsedMilliseconds)"
  } elseif (-not $actual -or $actual.Exception.Message -notlike "Standalone verification failed with*") {
    throw "Invalid setup result was accepted: $case"
  } elseif ($case -eq "exit-stderr" -and $actual.Exception.Message -notmatch "intentional stderr") {
    throw "Intentional exit failure lost stderr"
  }
}
Invoke-StandaloneFixture {}
if (Test-Path -LiteralPath $fixture) { throw "Owned fixture survived cleanup" }
Write-Output "CASE PASS: $case"
'@
    $source = $source.Replace("CHILD_SOURCE_BASE64", [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($descendantSource)))
    [IO.File]::WriteAllText($worker, $source)
    $gate = Join-Path $fixture "$case-start"
    $workerArguments = @($worker, $PSCommandPath, $caseRoot, $case, $hostPath, $spec.HostPath) |
      ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
    $command = "while (-not [IO.File]::Exists('" + $gate.Replace("'", "''") +
      "')) { [Threading.Thread]::Sleep(10) }; & " + ($workerArguments -join " ")
    $start = [Diagnostics.ProcessStartInfo]::new($hostPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $fixture
    $start.Environment["PSModuleAnalysisCachePath"] = Join-Path $fixture "$case-worker-cache"
    foreach ($argument in @("-NoProfile", "-NonInteractive", "-OutputFormat", "Text", "-EncodedCommand",
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) {
      [void] $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $job = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Create()
    $started = $false
    $assigned = $false
    try {
      $started = $process.Start()
      if (-not $started) { throw "Could not start harness self-test worker" }
      $stdout = $process.StandardOutput.ReadToEndAsync()
      $stderr = $process.StandardError.ReadToEndAsync()
      [GraphCode.Validation.Ownership.StandaloneProcessJob]::Assign($job, $process.Handle)
      $assigned = $true
      [IO.File]::WriteAllText($gate, "assigned")
      $workerBudget = if ($case -like "diagnostic-*" -or $case -like "launcher-*") { 70000 } else { 12000 }
      $finished = $process.WaitForExit($workerBudget)
      $settle = [Diagnostics.Stopwatch]::StartNew()
      while ($finished -and [GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($job) -ne 0 -and $settle.ElapsedMilliseconds -lt 250) {
        Start-Sleep -Milliseconds 10
      }
      $activeBeforeTeardown = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($job)
      if (-not $finished) {
        foreach ($role in @("root", "descendant")) {
          $identityPath = Join-Path $caseRoot "$role-identity"
          if (Test-Path -LiteralPath $identityPath) {
            $identity = (Get-Content -LiteralPath $identityPath -Raw).Trim().Split(":")
            $owned = Get-Process -Id ([int] $identity[1]) -ErrorAction SilentlyContinue
            $alive = $null -ne $owned -and $owned.StartTime.ToUniversalTime().Ticks -eq [long] $identity[0]
            Write-Output "Watchdog identity: role=$role; pid=$($identity[1]); sameCreationAlive=$alive"
          }
        }
        Write-Output "Watchdog readiness: descendantReady=$(Test-Path (Join-Path $caseRoot 'descendant-ready')); markerWritten=$(Test-Path (Join-Path $caseRoot 'marker-written'))"
      }
      [GraphCode.Validation.Ownership.StandaloneProcessJob]::Terminate($job)
      [GraphCode.Validation.Ownership.StandaloneProcessJob]::WaitForEmpty($job, 5000)
      if (-not $process.WaitForExit(5000)) { throw "Self-test worker survived owned job termination" }
      if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]] @($stdout, $stderr), 5000)) {
        throw "Self-test output capture exceeded its deadline"
      }
      $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
      Write-Output $output
      if (-not $finished -or $process.ExitCode -ne 0 -or $activeBeforeTeardown -ne 0 -or $output -notmatch "CASE PASS: $case") {
        $failures++
        Write-Output "CASE FAIL: $caseId; finished=$finished; exit=$($process.ExitCode); activeBeforeTeardown=$activeBeforeTeardown; activeAfterTeardown=$([GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($job))"
        if (-not $finished -or $activeBeforeTeardown -ne 0 -or
            $output -match "Standalone setup (?:output capture )?timed out") {
          throw "Stopped standalone harness at unexpected timeout or ownership failure: $caseId"
        }
      } else {
        $passed++
        Write-Output "Owned worker job: activeBeforeTeardown=$activeBeforeTeardown; activeAfterTeardown=$([GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($job))"
      }
    } finally {
      try {
        if ($assigned) {
          [GraphCode.Validation.Ownership.StandaloneProcessJob]::Terminate($job)
          [GraphCode.Validation.Ownership.StandaloneProcessJob]::WaitForEmpty($job, 5000)
        } elseif ($started -and -not $process.HasExited) {
          $process.Kill($true)
          if (-not $process.WaitForExit(5000)) { throw "Unassigned self-test worker survived termination" }
        }
      } finally {
        try { [GraphCode.Validation.Ownership.StandaloneProcessJob]::Close($job) } finally { $process.Dispose() }
      }
    }
  }
  Write-Output "Standalone harness self-tests: executed=$($passed + $failures); passed=$passed; failed=$failures"
  if ($failures) { throw "$failures standalone harness self-test(s) failed" }
}

if ($HelpersOnly) { return }

Invoke-StandaloneFixture {
  Test-StandaloneHarness -diagnosticOnly:$DiagnosticSelfTest -launcherOnly:$LauncherSelfTest
  if ($SelfTest -or $DiagnosticSelfTest -or $LauncherSelfTest) { return }
  $root = Join-Path $fixture "extracted package\GraphCode"
  New-Item -ItemType Directory -Path (Join-Path $root "bin"), (Join-Path $root "licenses"), (Join-Path $root "assets") -Force | Out-Null
  foreach ($name in @("graphcode-windows.exe", "graphcoded.exe", "graphcode.exe", "zmx.exe", "swiftCore.dll")) {
    Set-Content (Join-Path $root "bin\$name") "verification-only fixture"
  }
  foreach ($name in @("LICENSE", "THIRD-PARTY-NOTICES.txt", "licenses\WINGHOSTTY-LICENSE.txt",
      "licenses\ZMX-LICENSE.txt", "assets\winghostty-win32-host.lib")) {
    Set-Content (Join-Path $root $name) "fixture"
  }
  Copy-Item (Join-Path $shellRoot "provider-pins.json") (Join-Path $root "provider-pins.json")
  $pins = Get-Content (Join-Path $root "provider-pins.json") -Raw | ConvertFrom-Json
  $provenance = @{ schemaVersion = 1 }
  foreach ($provider in @("winghostty", "zmx")) {
    $artifact = if ($provider -eq "winghostty") { "assets/winghostty-win32-host.lib" } else { "bin/zmx.exe" }
    $license = "licenses/$($provider.ToUpperInvariant())-LICENSE.txt"
    $provenance[$provider] = @{
      repository = $pins.$provider.repository
      sha = $pins.$provider.sha
      packagePath = $artifact
      sha256 = (Get-FileHash (Join-Path $root $artifact)).Hash
      licensePath = $license
      licenseSha256 = (Get-FileHash (Join-Path $root $license)).Hash
    }
  }
  $provenance | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root "provider-provenance.json") -Encoding utf8
  Write-PackageSetup $root
  $ReleaseTag = "v1.2.3"
  $ReleaseTagCommit = "1234567890abcdef1234567890abcdef12345678"
  $SourceCommit = $ReleaseTagCommit
  $ReleaseTagMatchesSource = "true"
  $TagMismatchAllowed = "false"
  Write-Metadata $root "1.2.3"
  @{ schemaVersion = 1; files = @(Get-Manifest $root) } |
    ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root "manifest.json") -Encoding utf8
  $setup = Join-Path $root "GraphCode-Setup.ps1"
  $setupSource = Get-Content -LiteralPath $setup -Raw
  if ($setupSource -match '\$repoRoot|\$shellRoot|# GRAPHCODE_PACKAGE_RUNTIME|function Build-Package') {
    throw "Standalone setup retains build/repository dependencies"
  }
  $runtime = Get-Content (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1") -Raw
  if (-not $setupSource.Contains($runtime.Trim())) { throw "Setup does not embed the shared lifecycle verbatim" }
  $zip = Join-Path $fixture "GraphCode.zip"
  [IO.Compression.ZipFile]::CreateFromDirectory($root, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
  $nextRoot = Join-Path $fixture "next release\GraphCode"
  New-Item -ItemType Directory -Path (Split-Path $nextRoot -Parent) | Out-Null
  Copy-Item -LiteralPath $root -Destination $nextRoot -Recurse
  $pins.zmx.sha = "1" * 40
  $pins | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $nextRoot "provider-pins.json") -Encoding utf8
  $provenance.zmx.sha = $pins.zmx.sha
  $provenance | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $nextRoot "provider-provenance.json") -Encoding utf8
  $nextMetadata = Get-Content (Join-Path $nextRoot "metadata.json") -Raw | ConvertFrom-Json
  $nextMetadata.version = "1.2.4"
  $nextMetadata.providerPins = $pins
  $nextMetadata | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $nextRoot "metadata.json") -Encoding utf8
  @{ schemaVersion = 1; files = @(Get-Manifest $nextRoot) } |
    ConvertTo-Json -Depth 10 | Set-Content (Join-Path $nextRoot "manifest.json") -Encoding utf8
  $nextZip = Join-Path $fixture "next-release.zip"
  [IO.Compression.ZipFile]::CreateFromDirectory($nextRoot, $nextZip, [IO.Compression.CompressionLevel]::Optimal, $true)
  $nativeProbe = Join-Path $fixture "native-command.ps1"
  $nativeSource = (@("Fail", "Invoke-PackageCommand") | ForEach-Object { $definitions[$_] }) -join "`n"
  $nativeSource += @'

$ErrorActionPreference = "Stop"
$global:LASTEXITCODE = 41
$result = Invoke-PackageCommand (Join-Path $env:SystemRoot "System32\cmd.exe") @("/d", "/c", "echo expected-native-error 1>&2 & exit /b 7")
if ($result.ExitCode -ne 7 -or $result.Output -notmatch "expected-native-error") {
  throw "Native failure lost its exit code or stderr"
}
if ($ErrorActionPreference -ne "Stop") { throw "Native capture changed caller error policy" }
if ($global:LASTEXITCODE -ne 41) { throw "Native capture changed caller exit status" }
$global:LASTEXITCODE = 0
Write-Output "Native command exit/stderr preservation: PASS"
'@
  [IO.File]::WriteAllText($nativeProbe, $nativeSource, [Text.UTF8Encoding]::new($true))
  foreach ($hostPath in @((Get-Command powershell.exe).Source, (Get-Command pwsh).Source)) {
    $hostId = if ([IO.Path]::GetFileName($hostPath) -eq "powershell.exe") { "winps51" } else { "pwsh7" }
    Invoke-Setup $hostPath @() "" -scenario "$hostId-default-verify"
    Invoke-Setup $hostPath @("-Command", "Verify", "-Package", $zip) "" -scenario "$hostId-zip-verify"
    Invoke-Setup $hostPath @("-Command", "Verify", "-Package", $nextRoot) "" -scenario "$hostId-next-directory-verify"
    Invoke-Setup $hostPath @("-Command", "Verify", "-Package", $nextZip) "" -scenario "$hostId-next-zip-verify"
    Invoke-Setup $hostPath @("-Command", "Verify", "-Package", $nextRoot) "zmx provenance pin mismatch" `
      (Join-Path $repoRoot "Tools\windows\package.ps1") -scenario "$hostId-repository-pin-rejection"
    Invoke-Setup $hostPath @("-Command", "Verify", "-TrustedSignerThumbprint", ("A" * 40)) `
      "trusted publisher verification requires a signed package" -scenario "$hostId-unsigned-trust-rejection"
    Invoke-Setup $hostPath @("-Command", "Build") "Cannot validate argument" -scenario "$hostId-invalid-command-rejection"
    Invoke-Setup $hostPath @() "" $nativeProbe "Native command exit/stderr preservation: PASS" -scenario "$hostId-native-capture"
  }
  $pins.zmx.sha = "2" * 40
  $pins | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $nextRoot "provider-pins.json") -Encoding utf8
  @{ schemaVersion = 1; files = @(Get-Manifest $nextRoot) } |
    ConvertTo-Json -Depth 10 | Set-Content (Join-Path $nextRoot "manifest.json") -Encoding utf8
  Invoke-Setup (Get-Command powershell.exe).Source @("-Command", "Verify", "-Package", $nextRoot) `
    "zmx provenance pin mismatch" -scenario "winps51-tampered-pin-rejection"
  Add-Content (Join-Path $root "bin\swiftCore.dll") "tamper"
  Invoke-Setup (Get-Command powershell.exe).Source @("-Command", "Verify") "size mismatch" -scenario "winps51-tampered-size-rejection"
  if ($setupCases.Completed -ne 18) { throw "Expected 18 standalone setup cases, completed $($setupCases.Completed)" }
  Write-Output "Standalone setup without repository/toolchains on Windows PowerShell 5.1 and PowerShell 7: PASS; executed=$($setupCases.Completed)"
}
