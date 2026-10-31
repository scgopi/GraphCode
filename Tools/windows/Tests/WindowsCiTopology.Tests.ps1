[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$portWorkflow = Get-Content `
  (Join-Path $repoRoot ".github\workflows\windows-port-validation.yml") -Raw
$hardeningWorkflow = Get-Content `
  (Join-Path $repoRoot ".github\workflows\windows-hardening.yml") -Raw
$checks = 0

function Assert-Contract([object] $Condition, [string] $Message) {
  $values = @($Condition)
  if ($values.Count -ne 1 -or -not [bool] $values[0]) {
    throw "RED: $Message"
  }
  $script:checks++
}

function Get-WorkflowJobs([string] $Workflow) {
  $body = $Workflow.Replace("`r`n", "`n")
  $jobsStart = [regex]::Match($body, '(?m)^jobs:\s*$')
  if (-not $jobsStart.Success) { throw "Workflow has no jobs mapping" }
  $body = $body.Substring($jobsStart.Index + $jobsStart.Length)
  $heads = @([regex]::Matches($body, '(?m)^  ([A-Za-z0-9_-]+):\s*$'))
  $jobs = [ordered]@{}
  for ($index = 0; $index -lt $heads.Count; $index++) {
    $end = if ($index + 1 -lt $heads.Count) { $heads[$index + 1].Index } else { $body.Length }
    $jobs[$heads[$index].Groups[1].Value] =
      $body.Substring($heads[$index].Index, $end - $heads[$index].Index)
  }
  $jobs
}

$portJobs = Get-WorkflowJobs $portWorkflow
$hardeningJobs = Get-WorkflowJobs $hardeningWorkflow

Assert-Contract $portJobs.Contains("validation-runner") `
  "Windows port CI needs a dedicated validation-runner job"
$runnerJob = $portJobs["validation-runner"]
Assert-Contract ($runnerJob -match '(?m)^    needs: changes\s*$' -and
  $runnerJob -match "needs\.changes\.outputs\.windows == 'true'") `
  "the validation-runner job must use the fail-closed Windows path gate"
Assert-Contract ($runnerJob -match '(?m)^    runs-on: windows-2022\s*$' -and
  $runnerJob -notmatch '(?m)^\s+(strategy|matrix):') `
  "the validation-runner job must execute exactly once on Windows 2022"
Assert-Contract ($runnerJob -match
  'compnerd/gha-setup-swift@397094e75494a93fa8d81db0268dbc8f5d6cf7c6' -and
  $runnerJob -match 'swift-version: swift-6\.3\.3-release' -and
  $runnerJob -match 'swift-build: 6\.3\.3-RELEASE') `
  "the validation-runner job must install the pinned Swift formatter"
Assert-Contract ([regex]::Matches(
    $runnerJob,
    '(?m)^\s+run: \./Tools/windows/Invoke-ValidationRunnerContract\.ps1\s*$'
  ).Count -eq 1) `
  "the dedicated job must run the counted validation runner contract exactly once"
Assert-Contract ($runnerJob -notmatch 'bootstrap\.ps1|\.ci-providers|validate\.ps1|continue-on-error') `
  "the source-only validation runner job must not bootstrap providers or hide failures"

$spikesSwift = $portJobs["spikes-swift"]
Assert-Contract ($spikesSwift -notmatch
  'ValidationRunner\.Tests\.ps1|Invoke-ValidationRunnerContract\.ps1') `
  "the sequential Swift job must not repeat the validation runner contract"
Assert-Contract ([regex]::Matches(
    $spikesSwift,
    '(?m)^\s+run: \./Tools/windows/Tests/WindowsCiTopology\.Tests\.ps1\s*$'
  ).Count -eq 1) `
  "the Swift job must verify runner scheduling before expensive setup"
Assert-Contract ([regex]::Matches(
    $portWorkflow,
    '(?m)^\s+run: \./Tools/windows/Invoke-ValidationRunnerContract\.ps1\s*$'
  ).Count -eq 1) `
  "Windows port CI must declare exactly one validation runner step"

$aggregate = $portJobs["windows-spikes"]
Assert-Contract ($aggregate -match
  '(?m)^    needs: \[changes, validation-runner, spikes-swift, spikes-other\]\s*$' -and
  $aggregate -match
  'Assert-CiPartResults\.ps1 -NeedsJson \$env:NEEDS_JSON -Required \$env:WINDOWS_REQUIRED') `
  "the required windows-spikes aggregate must fail closed over the dedicated runner job"

$hardeningRunnerStep = [regex]::Match(
  $hardeningJobs["deterministic"],
  '(?ms)^      - name: Verify runner contract\s+.*?(?=^      - |\z)'
)
$hardeningRunnerIf = [regex]::Match(
  $hardeningRunnerStep.Value,
  '(?m)^        if: ([^\r\n]+)\s*$'
)
Assert-Contract ($hardeningRunnerStep.Success -and $hardeningRunnerIf.Success -and
  $hardeningRunnerStep.Value -match
    '(?m)^        run: \./Tools/windows/Invoke-ValidationRunnerContract\.ps1\s*$' -and
  $hardeningRunnerIf.Groups[1].Value -match "env\.HARDENING_REQUIRED == 'true'" -and
  $hardeningRunnerIf.Groups[1].Value -match "github\.event_name != 'pull_request'" -and
  $hardeningRunnerIf.Groups[1].Value -match "matrix\.os == 'windows-2022'") `
  "hardening must keep one scheduled/manual fallback without duplicating the PR contract"
Assert-Contract ([regex]::Matches(
    $hardeningWorkflow,
    '(?m)^\s+run: \./Tools/windows/Invoke-ValidationRunnerContract\.ps1\s*$'
  ).Count -eq 1) `
  "hardening must declare exactly one non-PR validation runner fallback"

$wrapper = Get-Content `
  (Join-Path $repoRoot "Tools\windows\Invoke-ValidationRunnerContract.ps1") -Raw
Assert-Contract ([regex]::Matches(
    $wrapper,
    '(?m)^& \$pwsh -NoProfile -File \$runner 2>&1 \| ForEach-Object \{\s*$'
  ).Count -eq 1 -and
  $wrapper -match '\$exitCode -ne 0' -and
  $wrapper -match '\$passMarkers -ne 1' -and
  $wrapper -match 'VALIDATION_RUNNER_EXECUTED=1') `
  "the validation runner wrapper must execute once, fail closed, and report a positive count"

Write-Host "Windows CI topology: $checks checks, 0 failures"
exit 0
