[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$scratch = Join-Path $repoRoot (".build\pester-version-tests\" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $scratch
$cases = 0

function Assert-Contract([bool] $condition, [string] $message) {
  if (-not $condition) { throw "Pester version contract: $message" }
}

function Invoke-VersionCase {
  param(
    [string] $Name,
    [string[]] $Versions,
    [string] $Preload = "",
    [string] $Entry = "loader",
    [string] $ExpectedVersion = "5.7.1",
    [switch] $Unavailable,
    [switch] $LoadedMismatch,
    [switch] $Broken
  )

  $caseRoot = Join-Path $scratch $Name
  $moduleRoot = Join-Path $caseRoot "modules"
  $null = New-Item -ItemType Directory -Path $moduleRoot
  foreach ($version in $Versions) {
    $versionRoot = Join-Path $moduleRoot "Pester\$version"
    $null = New-Item -ItemType Directory -Path $versionRoot
    @"
@{
  RootModule = 'Pester.psm1'
  ModuleVersion = '$version'
  GUID = '19248199-94e3-43aa-b116-73253b78ec6d'
  FunctionsToExport = @('Invoke-Pester', 'BeforeAll', 'Describe')
}
"@ | Set-Content -LiteralPath (Join-Path $versionRoot "Pester.psd1")
    $moduleSource = @'
function Invoke-Pester {
  param([Alias('Path')] $Script, [switch] $PassThru)
  [IO.File]::WriteAllText($env:GRAPHCODE_PESTER_PROBE, $MyInvocation.MyCommand.Module.Version.ToString())
  [pscustomobject]@{ TotalCount = 1; PassedCount = 1; FailedCount = 0 }
}
function BeforeAll {
  param([scriptblock] $Body)
  [IO.File]::WriteAllText($env:GRAPHCODE_PESTER_PROBE, $MyInvocation.MyCommand.Module.Version.ToString())
  throw 'PINNED_DSL_ENTRY'
}
function Describe {
  param([string] $Name, [scriptblock] $Body)
  [IO.File]::WriteAllText($env:GRAPHCODE_PESTER_PROBE, $MyInvocation.MyCommand.Module.Version.ToString())
  throw 'PINNED_DSL_ENTRY'
}
Export-ModuleMember -Function Invoke-Pester, BeforeAll, Describe
'@
    if ($Broken -and ([version] $version).Major -eq 5) {
      $moduleSource = "throw 'BROKEN_PESTER_FIVE'"
    }
    Set-Content -LiteralPath (Join-Path $versionRoot "Pester.psm1") -Value $moduleSource
  }

  $childSource = @'
$ErrorActionPreference = 'Stop'
$env:PSModulePath = $env:GRAPHCODE_PESTER_MODULE_PATH
$repoRoot = $env:GRAPHCODE_PESTER_REPO
$preload = $env:GRAPHCODE_PESTER_PRELOAD
if ($preload) { Import-Module Pester -RequiredVersion $preload -ErrorAction Stop }
$entry = $env:GRAPHCODE_PESTER_ENTRY
if ($entry -in @('visual-baseline', 'windows-shell')) {
  $runner = Join-Path $repoRoot 'Tools\windows\validate.ps1'
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$errors)
  if ($errors.Count) { throw 'Validation runner does not parse' }
  $task = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Task'
  }, $true)
  $switch = $task.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] }, $true)
  $clause = @($switch.Clauses | Where-Object { $_.Item1.Value -eq $entry })
  if ($clause.Count -ne 1) { throw 'Expected exactly one task clause' }
  $statements = [Collections.Generic.List[string]]::new()
  $foundPester = $false
  foreach ($statement in $clause[0].Item2.Statements) {
    $statements.Add($statement.Extent.Text)
    if ($statement.Extent.Text -match '= Invoke-Pester') { $foundPester = $true }
    if ($foundPester -and $statement -is [Management.Automation.Language.IfStatementAst]) { break }
  }
  if (-not $foundPester) { throw 'Task has no Pester invocation' }
  function Invoke-Native { param($Name, $Action) }
  & ([scriptblock]::Create(($statements -join "`n")))
} elseif ($entry -eq 'loader') {
  . (Join-Path $repoRoot 'Tools\windows\Import-PinnedPester.ps1')
  Invoke-Pester -PassThru | Out-Null
} else {
  try { & (Join-Path $repoRoot "Tools\windows\Tests\$entry") } catch {
    if ($_.Exception.Message -cne 'PINNED_DSL_ENTRY') { throw }
  }
}
'@
  $childPath = Join-Path $caseRoot "probe.ps1"
  Set-Content -LiteralPath $childPath -Value $childSource
  $probePath = Join-Path $caseRoot "selected.txt"
  $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in @("-NoProfile", "-File", $childPath)) {
    $start.ArgumentList.Add($argument)
  }
  $start.Environment["PSModulePath"] = $moduleRoot + [IO.Path]::PathSeparator + (Join-Path $PSHOME "Modules")
  $start.Environment["GRAPHCODE_PESTER_MODULE_PATH"] = $start.Environment["PSModulePath"]
  $start.Environment["TEMP"] = $caseRoot
  $start.Environment["TMP"] = $caseRoot
  $start.Environment["GRAPHCODE_PESTER_REPO"] = $repoRoot
  $start.Environment["GRAPHCODE_PESTER_ENTRY"] = $Entry
  $start.Environment["GRAPHCODE_PESTER_PROBE"] = $probePath
  $start.Environment["GRAPHCODE_PESTER_PRELOAD"] = $Preload
  $child = [Diagnostics.Process]::Start($start)
  try {
    $stdout = $child.StandardOutput.ReadToEndAsync()
    $stderr = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(60000)) {
      $child.Kill($true)
      throw "Pester version contract: $Name exceeded 60 seconds"
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    if ($Unavailable) {
      Assert-Contract ($child.ExitCode -ne 0) "$Name accepted an environment without Pester 5"
      Assert-Contract ($output -match "Pester 5\.x is required") "$Name lost the actionable missing-major error: $output"
      Assert-Contract ($output -match "Save-Module") "$Name lost isolated dependency recovery instructions"
      Assert-Contract (-not (Test-Path -LiteralPath $probePath)) "$Name invoked an unsupported Pester"
    } elseif ($LoadedMismatch) {
      Assert-Contract ($child.ExitCode -ne 0 -and $output -match "Pester 5\.x is required") "$Name accepted a loaded incompatible major: $output"
      Assert-Contract ($output -match "fresh pwsh -NoProfile") "$Name lost the fresh-process remedy"
      Assert-Contract (-not (Test-Path -LiteralPath $probePath)) "$Name invoked a loaded incompatible major"
    } elseif ($Broken) {
      Assert-Contract ($child.ExitCode -ne 0 -and $output -match "BROKEN_PESTER_FIVE") "$Name hid an import failure: $output"
      Assert-Contract (-not (Test-Path -LiteralPath $probePath)) "$Name fell back after a broken Pester 5 import"
    } else {
      Assert-Contract ($child.ExitCode -eq 0) "$Name failed: $output"
      Assert-Contract (Test-Path -LiteralPath $probePath) "$Name did not execute a Pester command"
      $selected = [IO.File]::ReadAllText($probePath)
      Assert-Contract ($selected -ceq $ExpectedVersion) "$Name expected Pester $ExpectedVersion, observed $selected"
    }
    $script:cases++
    Write-Host "PASS: $Name"
  } finally {
    $child.Dispose()
  }
}

try {
  $allVersions = @("4.10.1", "5.0.0", "5.7.1", "6.2.0")
  Invoke-VersionCase "runner-palette-selects-five" $allVersions -Entry "visual-baseline"
  Invoke-VersionCase "runner-isolation-selects-five" $allVersions -Entry "windows-shell"
  Invoke-VersionCase "palette-entry-selects-five" $allVersions -Entry "PaletteParity.Tests.ps1"
  Invoke-VersionCase "isolation-entry-selects-five" $allVersions -Entry "ValidationIsolation.Tests.ps1"
  Invoke-VersionCase "bootstrap-entry-selects-five" $allVersions -Entry "Bootstrap.Tests.ps1"
  Invoke-VersionCase "newest-five-not-six" $allVersions
  Invoke-VersionCase "loaded-four-is-rejected" $allVersions -Preload "4.10.1" -LoadedMismatch
  Invoke-VersionCase "loaded-six-is-rejected" $allVersions -Preload "6.2.0" -LoadedMismatch
  Invoke-VersionCase "already-loaded-five" $allVersions -Preload "5.7.1"
  Invoke-VersionCase "loaded-five-is-not-upgraded" $allVersions -Preload "5.0.0" -ExpectedVersion "5.0.0"
  Invoke-VersionCase "four-only-is-rejected" @("4.10.1") -Preload "4.10.1" -Unavailable
  Invoke-VersionCase "six-only-is-rejected" @("6.2.0") -Preload "6.2.0" -Unavailable
  Invoke-VersionCase "no-pester-is-rejected" @() -Unavailable
  Invoke-VersionCase "broken-five-is-not-hidden" $allVersions -Broken
  Assert-Contract ($cases -eq 14) "expected 14 executed cases, observed $cases"
  Write-Host "PesterVersion.Tests.ps1: PASS; executed=$cases"
} finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
