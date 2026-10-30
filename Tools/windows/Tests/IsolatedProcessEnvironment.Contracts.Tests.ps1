[CmdletBinding()]
param(
  [ValidateSet("RED", "GREEN", "REGRESSION")] [string] $Phase = "REGRESSION",
  [ValidateSet("", "baseline", "green", "missing-pathext", "missing-modulepath", "empty-pathext",
    "empty-modulepath", "missing-other-literal", "extra-key", "other-key-drift",
    "post-reassertion-mutation", "wrong-path", "scope-user", "scope-machine", "scope-host")]
  [string] $ChildCase = "",
  [string] $ExpectedPath = ""
)

$ErrorActionPreference = "Stop"
$helperPath = Join-Path $PSScriptRoot "..\IsolatedProcessEnvironment.ps1"
if ($ChildCase) {
  $expected = Get-Content -LiteralPath $ExpectedPath -Raw | ConvertFrom-Json
  . $helperPath
  $beforePathext = [Environment]::GetEnvironmentVariable("PATHEXT", "Process")
  $beforeModules = [Environment]::GetEnvironmentVariable("PSModulePath", "Process")
  $startupDrift = -not [string]::Equals($beforePathext, $expected.PATHEXT, [StringComparison]::Ordinal) -or
    -not [string]::Equals($beforeModules, $expected.PSModulePath, [StringComparison]::Ordinal)
  $refused = $false
  $errorCode = $null
  try {
    switch ($ChildCase) {
      "missing-pathext" { $expected.PSObject.Properties.Remove("PATHEXT") }
      "missing-modulepath" { $expected.PSObject.Properties.Remove("PSModulePath") }
      "empty-pathext" { $expected.PATHEXT = "" }
      "empty-modulepath" { $expected.PSModulePath = "" }
      "missing-other-literal" { $expected.PSObject.Properties.Remove("DOTNET_NOLOGO") }
      "extra-key" { [Environment]::SetEnvironmentVariable("ISOLATED_TEST_EXTRA", "fixture", "Process") }
      "other-key-drift" { [Environment]::SetEnvironmentVariable("DOTNET_NOLOGO", "fixture-drift", "Process") }
    }
    $parameters = @{
      Expected = $expected
      EntryScriptPath = $PSCommandPath
      ApprovedEntryScriptPath = $PSCommandPath
    }
    if ($ChildCase -eq "wrong-path") { $parameters.ApprovedEntryScriptPath += ".wrong" }
    if ($ChildCase -in @("scope-user", "scope-machine", "scope-host")) {
      $parameters.Target = $ChildCase.Substring(6)
    }
    if ($ChildCase -ne "baseline") { Initialize-IsolatedProcessEnvironment @parameters }
    if ($ChildCase -eq "post-reassertion-mutation") {
      [Environment]::SetEnvironmentVariable("PSModulePath", "fixture-mutation", "Process")
    }
    Assert-IsolatedProcessEnvironment -Expected $expected
  } catch {
    $refused = $true
    $errorCode = if ($_.Exception.Message -cmatch '^ISOLATED_ENV_[A-Z_]+$') {
      $_.Exception.Message
    } elseif ($_.Exception -is [Management.Automation.ParameterBindingException]) {
      "ISOLATED_ENV_PARAMETER_BINDING"
    } else { "ISOLATED_ENV_UNEXPECTED_FAILURE" }
  }
  $untouched = [string]::Equals($beforePathext,
      [Environment]::GetEnvironmentVariable("PATHEXT", "Process"), [StringComparison]::Ordinal) -and
    [string]::Equals($beforeModules,
      [Environment]::GetEnvironmentVariable("PSModulePath", "Process"), [StringComparison]::Ordinal)
  [Console]::Out.WriteLine(([ordered]@{
    startupDrift = [bool]$startupDrift
    refused = [bool]$refused
    errorCode = $errorCode
    twoLiteralsUntouched = [bool]$untouched
  } | ConvertTo-Json -Compress))
  if ($refused) { exit 1 }
  exit 0
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$scratch = Join-Path $repoRoot (".build\isolated-process-environment\" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $scratch
$pwsh = [Environment]::ProcessPath
$hostPathext = [Environment]::GetEnvironmentVariable("PATHEXT", "Process")
$hostModules = [Environment]::GetEnvironmentVariable("PSModulePath", "Process")
$executed = 0

function Assert-Contract([bool] $Condition, [string] $Code) {
  if (-not $Condition) { throw "Isolated process environment contract: $Code" }
}

function Invoke-EnvironmentCase([string] $Name) {
  $caseRoot = Join-Path $scratch $Name
  foreach ($suffix in @("", "temp", "profile", "modules", "cache", "cache\local", "cache\roaming",
    "cache\dotnet", "cache\bundle", "cache\nuget-packages", "cache\nuget-http",
    "cache\nuget-plugins", "cache\xdg", "cache\msbuild")) {
    $path = if ($suffix) { Join-Path $caseRoot $suffix } else { $caseRoot }
    $null = New-Item -ItemType Directory -Path $path
  }
  $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
  $system = Join-Path $windows "System32"
  $expected = [ordered]@{
    SystemRoot = $windows; WINDIR = $windows; SystemDrive = [IO.Path]::GetPathRoot($windows).TrimEnd('\')
    COMSPEC = (Join-Path $system "cmd.exe"); PATHEXT = ".COM;.EXE;.BAT;.CMD"
    PATH = "$PSHOME;$system"; PSModulePath = (Join-Path $caseRoot "modules")
    TEMP = (Join-Path $caseRoot "temp"); TMP = (Join-Path $caseRoot "temp")
    HOME = (Join-Path $caseRoot "profile"); USERPROFILE = (Join-Path $caseRoot "profile")
    LOCALAPPDATA = (Join-Path $caseRoot "cache\local"); APPDATA = (Join-Path $caseRoot "cache\roaming")
    DOTNET_ROOT = $PSHOME; DOTNET_ROOT_X64 = $PSHOME; DOTNET_MULTILEVEL_LOOKUP = "0"
    DOTNET_ROLL_FORWARD = "Disable"; DOTNET_CLI_HOME = (Join-Path $caseRoot "cache\dotnet")
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"; DOTNET_CLI_TELEMETRY_OPTOUT = "1"; DOTNET_NOLOGO = "1"
    DOTNET_BUNDLE_EXTRACT_BASE_DIR = (Join-Path $caseRoot "cache\bundle")
    NUGET_PACKAGES = (Join-Path $caseRoot "cache\nuget-packages")
    NUGET_HTTP_CACHE_PATH = (Join-Path $caseRoot "cache\nuget-http")
    NUGET_PLUGINS_CACHE_PATH = (Join-Path $caseRoot "cache\nuget-plugins")
    PSModuleAnalysisCachePath = (Join-Path $caseRoot "cache\module-analysis")
    PS_DISABLE_MODULE_ANALYSIS_CACHE = "1"; POWERSHELL_TELEMETRY_OPTOUT = "1"
    XDG_CACHE_HOME = (Join-Path $caseRoot "cache\xdg")
    MSBUILDUSEREXTENSIONSPATH = (Join-Path $caseRoot "cache\msbuild")
  }
  $mapPath = Join-Path $caseRoot "expected.json"
  [IO.File]::WriteAllText($mapPath, ($expected | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.WorkingDirectory = $caseRoot
  $start.Environment.Clear()
  foreach ($key in $expected.Keys) { $start.Environment.Add($key, $expected[$key]) }
  foreach ($arg in @("-NoProfile", "-File", $PSCommandPath, "-ChildCase", $Name, "-ExpectedPath", $mapPath)) {
    $start.ArgumentList.Add($arg)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  $stdout = [IO.File]::Open((Join-Path $caseRoot "stdout.raw.log"), "CreateNew", "Write", "Read")
  $stderr = [IO.File]::Open((Join-Path $caseRoot "stderr.raw.log"), "CreateNew", "Write", "Read")
  $held = $null
  $started = $false
  $stopAttempted = $false
  try {
    $started = $process.Start()
    Assert-Contract $started "CHILD_START"
    $held = $process.SafeHandle
    $pidOwned = $process.Id
    $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    if (-not $process.WaitForExit(30000)) {
      if ($held.IsInvalid -or $held.IsClosed -or $process.Id -ne $pidOwned) { throw "No held test-child identity" }
      $stopAttempted = $true
      Stop-Process -Id $pidOwned -Force -ErrorAction Stop
      $null = $process.WaitForExit(5000)
      throw "Isolated process environment contract: CHILD_DEADLINE"
    }
    $null = $outTask.GetAwaiter().GetResult()
    $null = $errTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
  } finally {
    if ($started -and -not $process.HasExited -and -not $stopAttempted) {
      if ($null -eq $held -or $held.IsInvalid -or $held.IsClosed -or $process.Id -ne $pidOwned) {
        throw "No held test-child identity during finalization"
      }
      $stopAttempted = $true
      Stop-Process -Id $pidOwned -Force -ErrorAction Stop
      $null = $process.WaitForExit(5000)
    }
    $stdout.Dispose(); $stderr.Dispose(); $process.Dispose()
  }
  $text = [IO.File]::ReadAllText((Join-Path $caseRoot "stdout.raw.log"))
  $result = $text | ConvertFrom-Json
  Assert-Contract ((Get-Item -LiteralPath (Join-Path $caseRoot "stderr.raw.log")).Length -eq 0) "CHILD_STDERR"
  Assert-Contract ($result.startupDrift -is [bool] -and $result.refused -is [bool]) "CHILD_RESULT"
  return [pscustomobject]@{ ExitCode = $exitCode; Result = $result }
}

try {
  $cases = if ($Phase -eq "RED") { @("baseline") } elseif ($Phase -eq "GREEN") { @("green") } else {
    @("baseline", "green", "missing-pathext", "missing-modulepath", "empty-pathext", "empty-modulepath",
      "missing-other-literal", "extra-key", "other-key-drift", "post-reassertion-mutation",
      "wrong-path", "scope-user", "scope-machine", "scope-host")
  }
  foreach ($case in $cases) {
    $actual = Invoke-EnvironmentCase $case
    if ($case -eq "green") {
      Assert-Contract ($actual.ExitCode -eq 0 -and -not $actual.Result.refused) "GREEN"
      Assert-Contract $actual.Result.startupDrift "GREEN_MUST_EXERCISE_STARTUP_DRIFT"
    } else {
      Assert-Contract ($actual.ExitCode -ne 0 -and $actual.Result.refused) "EXPECTED_REFUSAL"
      $expectedCode = switch ($case) {
        "baseline" { "ISOLATED_ENV_LITERAL" }
        { $_ -in @("missing-pathext", "missing-modulepath", "missing-other-literal") } { "ISOLATED_ENV_EXPECTED_KEYS" }
        { $_ -in @("empty-pathext", "empty-modulepath") } { "ISOLATED_ENV_EXPECTED_LITERAL" }
        "extra-key" { "ISOLATED_ENV_UNEXPECTED_KEY" }
        { $_ -in @("other-key-drift", "post-reassertion-mutation") } { "ISOLATED_ENV_LITERAL" }
        "wrong-path" { "ISOLATED_ENV_ENTRY_PATH" }
        default { "ISOLATED_ENV_PARAMETER_BINDING" }
      }
      Assert-Contract ($actual.Result.errorCode -ceq $expectedCode) "EXACT_REFUSAL"
      if ($case -eq "baseline") { Assert-Contract $actual.Result.startupDrift "RED_MUST_EXERCISE_STARTUP_DRIFT" }
      if ($case -in @("wrong-path", "missing-pathext", "missing-modulepath", "empty-pathext",
        "empty-modulepath", "missing-other-literal", "scope-user", "scope-machine", "scope-host")) {
        Assert-Contract $actual.Result.twoLiteralsUntouched "REFUSAL_BEFORE_WRITES"
      }
    }
    $executed++
  }
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$null, [ref]$errors)
  Assert-Contract (@($errors).Count -eq 0) "HELPER_PARSE"
  $writes = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq "SetEnvironmentVariable"
  }, $true))
  Assert-Contract ($writes.Count -eq 2) "ONLY_TWO_WRITE_SITES"
  foreach ($write in $writes) {
    Assert-Contract ($write.Arguments.Count -eq 3 -and
      $write.Arguments[2].Extent.Text -ceq "[EnvironmentVariableTarget]::Process") "NO_HOST_USER_MACHINE_WRITE"
  }
  Assert-Contract ([string]::Equals($hostPathext,
    [Environment]::GetEnvironmentVariable("PATHEXT", "Process"), [StringComparison]::Ordinal)) "HOST_PATHEXT_UNCHANGED"
  Assert-Contract ([string]::Equals($hostModules,
    [Environment]::GetEnvironmentVariable("PSModulePath", "Process"), [StringComparison]::Ordinal)) "HOST_MODULES_UNCHANGED"
  Assert-Contract ($executed -gt 0) "POSITIVE_CASE_COUNT"
  Write-Output "Isolated process environment contracts: $executed cases; phase=$Phase"
  if ($Phase -eq "RED") { throw "RED: actual fresh-pwsh literal guard rejected startup drift without reassertion" }
} finally {
  # Retain exact child streams and synthetic maps for later evidence review.
}
