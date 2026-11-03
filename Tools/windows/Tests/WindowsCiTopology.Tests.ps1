[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$portWorkflow = Get-Content `
  (Join-Path $repoRoot ".github\workflows\windows-port-validation.yml") -Raw
$hardeningWorkflow = Get-Content `
  (Join-Path $repoRoot ".github\workflows\windows-hardening.yml") -Raw
$portWorkflow = $portWorkflow.Replace("`r`n", "`n")
$hardeningWorkflow = $hardeningWorkflow.Replace("`r`n", "`n")
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

function Get-CompiledInvocationCount([string] $Text) {
  [regex]::Matches($Text,
    '(?m)^\s*\.\\Tools\\windows\\ValidationRunner\\bin\\Release\\net10\.0-windows\\ValidationRunner\.exe --repository-root \$PWD --artifact-root \.ci-validation-runner[ \t]*$').Count
}

function Assert-CompiledBuild([string] $Job) {
  Assert-Contract ($Job -match 'actions/setup-dotnet@[0-9a-f]{40}' -and
    $Job -match '(?m)^\s+dotnet-version: 10\.0\.403[ \t]*$') `
    "the compiled runner must install the exact pinned SDK"
  $steps = @([regex]::Matches($Job, '(?ms)^      - .*?(?=^      - |\z)') |
    ForEach-Object Value | Where-Object { $_ -match '(?m)^\s+dotnet build -c Release[ \t]*$' })
  Assert-Contract ($steps.Count -eq 1 -and
    $steps[0] -match '(?m)^        working-directory: Tools/windows/ValidationRunner[ \t]*$' -and
    $steps[0] -match 'dotnet --version' -and
    $steps[0] -match "\`$version -cne '10\.0\.403'" -and
    $steps[0] -match '\$LASTEXITCODE -ne 0') `
    "the host build must select global.json from its nested directory and fail on an SDK/build error"
}

function Assert-CompleteProof([string] $Text) {
  Assert-Contract ($Text -match '\$exitCode -ne 0' -and
    $Text.Contains('coverage.json') -and
    $Text -match '-not \$report\.complete' -and
    $Text -match '\$report\.requiredCount -le 0' -and
    $Text -match '\$report\.passedCount -ne \$report\.requiredCount' -and
    $Text -match '@\(\$report\.units\)\.Count -ne \$report\.requiredCount' -and
    $Text -match '@\(\$report\.errors\)\.Count -ne 0') `
    "normal execution must require exit zero and complete positive full coverage, not an empty or filtered report"
  Assert-Contract ($Text.Contains('CompiledValidationRunner: PASS') -and
    $Text.Contains('VALIDATION_RUNNER_EXECUTED=1') -and
    $Text -match '\$passMarkers -ne 1' -and
    $Text -match '\$executedMarkers -ne 1') `
    "normal execution must require exactly one full PASS marker and one positive execution marker"
}

$portJobs = Get-WorkflowJobs $portWorkflow
$hardeningJobs = Get-WorkflowJobs $hardeningWorkflow

Assert-Contract $portJobs.Contains("validation-runner") `
  "Windows port CI needs a dedicated validation-runner job"
$runnerJob = $portJobs["validation-runner"]
Assert-Contract ($runnerJob -match '(?m)^    needs: changes\s*$' -and
  $runnerJob -match "needs\.changes\.outputs\.windows == 'true'" -and
  $runnerJob -match "needs\.changes\.result != 'success'") `
  "the validation-runner job must use the fail-closed Windows path gate"
Assert-Contract ($runnerJob -match '(?m)^    runs-on: windows-2022\s*$' -and
  $runnerJob -notmatch '(?m)^\s+(strategy|matrix):') `
  "the validation-runner job must execute exactly once on Windows 2022"
Assert-Contract ($runnerJob -match
  'compnerd/gha-setup-swift@397094e75494a93fa8d81db0268dbc8f5d6cf7c6' -and
  $runnerJob -match 'swift-version: swift-6\.3\.3-release' -and
  $runnerJob -match 'swift-build: 6\.3\.3-RELEASE') `
  "the validation-runner job must install the pinned Swift formatter"
Assert-CompiledBuild $runnerJob
Assert-Contract ((Get-CompiledInvocationCount $runnerJob) -eq 1 -and
  $runnerJob -notmatch '--suite\b|--self-test\b|--fixture\b|ValidationRunner\.Tests\.ps1|Invoke-ValidationRunnerContract\.ps1') `
  "the dedicated job must run the normal full compiled host exactly once, never a filtered, fixture, or legacy entry"
Assert-CompleteProof $runnerJob
Assert-Contract ($runnerJob -notmatch 'bootstrap\.ps1|\.ci-providers|validate\.ps1|continue-on-error') `
  "the source-only validation runner job must not bootstrap providers or hide failures"

$spikesSwift = $portJobs["spikes-swift"]
Assert-Contract ($spikesSwift -notmatch
  'ValidationRunner\.Tests\.ps1|Invoke-ValidationRunnerContract\.ps1|ValidationRunner\.exe') `
  "the sequential Swift job must not repeat the validation runner contract"
Assert-Contract ([regex]::Matches(
    $spikesSwift,
    '(?m)^\s+run: \./Tools/windows/Tests/WindowsCiTopology\.Tests\.ps1\s*$'
  ).Count -eq 1) `
  "the Swift job must verify runner scheduling before expensive setup"
Assert-Contract ((Get-CompiledInvocationCount $portWorkflow) -eq 1 -and
  $portWorkflow -notmatch '(?m)^\s+run:.*(?:ValidationRunner\.Tests\.ps1|Invoke-ValidationRunnerContract\.ps1)') `
  "Windows port CI must declare exactly one direct compiled validation run and no legacy invocation"

$aggregate = $portJobs["windows-spikes"]
Assert-Contract ($aggregate -match
  '(?m)^    needs: \[changes, validation-runner, spikes-swift, spikes-other\]\s*$' -and
  $aggregate -match
  'Assert-CiPartResults\.ps1 -NeedsJson \$env:NEEDS_JSON -Required \$env:WINDOWS_REQUIRED') `
  "the required windows-spikes aggregate must fail closed over the dedicated runner job"

$hardeningRunnerStep = [regex]::Match(
  $hardeningJobs["deterministic"],
  '(?ms)^      - name: Verify complete compiled validation runner contract\s+.*?(?=^      - |\z)'
)
$hardeningRunnerIf = [regex]::Match(
  $hardeningRunnerStep.Value,
  '(?m)^        if: ([^\r\n]+)\s*$'
)
Assert-Contract ($hardeningRunnerStep.Success -and $hardeningRunnerIf.Success -and
  (Get-CompiledInvocationCount $hardeningRunnerStep.Value) -eq 1 -and
  $hardeningRunnerIf.Groups[1].Value -match "env\.HARDENING_REQUIRED == 'true'" -and
  $hardeningRunnerIf.Groups[1].Value -match "github\.event_name != 'pull_request'" -and
  $hardeningRunnerIf.Groups[1].Value -match "matrix\.os == 'windows-2022'") `
  "hardening must keep one scheduled/manual fallback without duplicating the PR contract"
Assert-Contract ((Get-CompiledInvocationCount $hardeningWorkflow) -eq 1 -and
  $hardeningWorkflow -notmatch '(?m)^\s+run:.*(?:ValidationRunner\.Tests\.ps1|Invoke-ValidationRunnerContract\.ps1)') `
  "hardening must declare exactly one non-PR compiled runner fallback and no legacy invocation"
Assert-CompiledBuild $hardeningJobs["deterministic"]
Assert-CompleteProof $hardeningRunnerStep.Value
Assert-Contract ($runnerJob.Contains('path: .ci-validation-runner') -and
  $hardeningJobs["deterministic"].Contains('path: .ci-validation-runner')) `
  "both canonical execution paths must retain their compiled coverage and payload evidence"

$wrapper = Get-Content `
  (Join-Path $repoRoot "Tools\windows\Invoke-ValidationRunnerContract.ps1") -Raw
Assert-Contract ($wrapper.Contains('Build-CompiledValidationRunner.ps1') -and
  $wrapper.Contains('ValidationRunner.exe') -and
  $wrapper -match '(?m)^\s*& \$runner --repository-root \$repoRoot --artifact-root \$artifactRoot 2>&1 \| ForEach-Object \{' -and
  $wrapper -notmatch 'ValidationRunner\.Tests\.ps1|--suite\b|--self-test\b|--fixture\b') `
  "the compatibility wrapper must build and execute only the normal compiled host"
Assert-CompleteProof $wrapper

$privateSdkArtifacts = Join-Path $repoRoot (".build\private-sdk-caller-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $privateSdkArtifacts
& (Join-Path $repoRoot "Tools\windows\ValidationRunner\Host\CiContracts\PrivateSdkCaller.Tests.ps1") `
  -RepositoryRoot $repoRoot.Path -ArtifactRoot $privateSdkArtifacts

Write-Host "Windows CI topology: $checks checks, 0 failures"
exit 0
