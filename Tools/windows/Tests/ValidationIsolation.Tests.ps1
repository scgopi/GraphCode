[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\Import-PinnedPester.ps1")

Describe "Windows shell validation profile isolation" {
BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
  . (Join-Path $repoRoot "Tools\windows\CandidateAdmission.ps1")
  $runnerPath = Join-Path $repoRoot "Tools\windows\validate.ps1"
  $runnerSource = Get-Content -LiteralPath $runnerPath -Raw
  $tokens = $null
  $errors = $null
  $runnerAst = [Management.Automation.Language.Parser]::ParseInput(
    $runnerSource,
    [ref] $tokens,
    [ref] $errors
  )
  if ($errors.Count -ne 0) {
    throw "Validation runner does not parse"
  }

  $requiredFunctions = @(
    "Invoke-Native",
    "Get-WindowsShellProfileSnapshot",
    "Assert-WindowsShellProfileUnchanged",
    "Invoke-WindowsShellValidationIsolation"
  )
  $missingFunctions = [Collections.Generic.List[string]]::new()
  foreach ($name in $requiredFunctions) {
    $definition = $runnerAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq $name
      }, $true)
    if ($null -eq $definition) {
      $missingFunctions.Add($name)
    } else {
      . ([scriptblock]::Create($definition.Extent.Text))
    }
  }
}

BeforeEach {
  $caseRoot = Join-Path $repoRoot (
    ".build\validation-isolation-tests\" + [guid]::NewGuid().ToString("N")
  )
  $workspaceRoot = Join-Path $caseRoot "workspace"
  $userProfileRoot = Join-Path $caseRoot "profile"
  $localAppDataRoot = Join-Path $caseRoot "local-app-data"
  New-Item -ItemType Directory -Force -Path $workspaceRoot,$userProfileRoot,$localAppDataRoot |
    Out-Null
  $capturePath = Join-Path $caseRoot "environment.json"
  $savedEnvironment = @{}
  $savedEnvironmentMembership = @{}
  $processEnvironment = [Environment]::GetEnvironmentVariables("Process")
  foreach ($name in @(
      "GRAPHCODE_VALIDATION_ROOT",
      "GRAPHCODE_SUPPORT_DIR",
      "LOCALAPPDATA",
      "TEMP",
      "TMP"
    )) {
    $savedEnvironmentMembership[$name] = $processEnvironment.Contains($name)
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, "before-$name")
  }
}

AfterEach {
  foreach ($entry in $savedEnvironment.GetEnumerator()) {
    if ($savedEnvironmentMembership[$entry.Key]) {
      [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    } elseif (Test-Path -LiteralPath "Env:\$($entry.Key)") {
      Remove-Item -LiteralPath "Env:\$($entry.Key)" -ErrorAction Stop
    }
  }
  Remove-Item -LiteralPath $caseRoot -Recurse -Force -ErrorAction SilentlyContinue
}

  It "uses worktree-owned roots and restores them after success" {
    $missingFunctions.Count | Should -Be 0
    $defaultSupport = Join-Path $userProfileRoot ".graphcode"
    $defaultLocal = Join-Path $localAppDataRoot "GraphCode"
    New-Item -ItemType Directory -Force -Path $defaultSupport,$defaultLocal | Out-Null
    Set-Content -LiteralPath (Join-Path $defaultSupport "existing.log") -Value "unchanged"
    Set-Content -LiteralPath (Join-Path $defaultLocal "existing.json") -Value "{}"
    $childCommand = @'
[ordered]@{
  validationRoot = $env:GRAPHCODE_VALIDATION_ROOT
  support = $env:GRAPHCODE_SUPPORT_DIR
  localAppData = $env:LOCALAPPDATA
  temp = $env:TEMP
  tmp = $env:TMP
} | ConvertTo-Json -Compress
'@
    $encodedCommand = [Convert]::ToBase64String(
      [Text.Encoding]::Unicode.GetBytes($childCommand)
    )
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source

    Invoke-WindowsShellValidationIsolation `
      -WorkspaceRoot $workspaceRoot `
      -UserProfileRoot $userProfileRoot `
      -LocalAppDataRoot $localAppDataRoot `
      -Action {
        $child = Start-Process -FilePath $pwsh -WindowStyle Hidden -Wait -PassThru `
          -ArgumentList @("-NoProfile", "-EncodedCommand", $encodedCommand) `
          -RedirectStandardOutput $capturePath
        if ($child.ExitCode -ne 0) {
          throw "Controlled child environment capture failed with exit code $($child.ExitCode)"
        }
      }

    $captured = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $ownedPrefix = (
      [IO.Path]::GetFullPath((Join-Path $workspaceRoot ".build\windows-shell-validation"))
    ).TrimEnd('\') + '\'
    foreach ($path in @(
        $captured.validationRoot,
        $captured.support,
        $captured.localAppData,
        $captured.temp,
        $captured.tmp
      )) {
      [IO.Path]::GetFullPath($path).StartsWith(
        $ownedPrefix,
        [StringComparison]::OrdinalIgnoreCase
      ) | Should -Be $true
    }
    $captured.support | Should -BeExactly (Join-Path $captured.validationRoot "support")
    $captured.localAppData | Should -BeExactly (
      Join-Path $captured.validationRoot "local-app-data"
    )
    $captured.temp | Should -BeExactly (Join-Path $captured.validationRoot "temp")
    $captured.temp | Should -BeExactly $captured.tmp
    Test-Path -LiteralPath $captured.validationRoot | Should -Be $false
    $env:GRAPHCODE_VALIDATION_ROOT | Should -BeExactly "before-GRAPHCODE_VALIDATION_ROOT"
    $env:GRAPHCODE_SUPPORT_DIR | Should -BeExactly "before-GRAPHCODE_SUPPORT_DIR"
    $env:LOCALAPPDATA | Should -BeExactly "before-LOCALAPPDATA"
    $env:TEMP | Should -BeExactly "before-TEMP"
    $env:TMP | Should -BeExactly "before-TMP"
  }

  It "restores and retains owned roots when the workload fails" {
    $missingFunctions.Count | Should -Be 0
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
          throw "controlled workload failure"
        }
    } catch {
      $caught = $_
    }

    $caught.Exception.Message | Should -BeExactly "controlled workload failure"
    $ownedRoot = Get-Content -LiteralPath $capturePath -Raw
    Test-Path -LiteralPath $ownedRoot.Trim() | Should -Be $true
    $caught.Exception.Data["GraphCodeValidationRootRetentionReason"] | Should -BeExactly "workload_failed_without_cleanup_proof"
    $env:GRAPHCODE_VALIDATION_ROOT | Should -BeExactly "before-GRAPHCODE_VALIDATION_ROOT"
    $env:GRAPHCODE_SUPPORT_DIR | Should -BeExactly "before-GRAPHCODE_SUPPORT_DIR"
    $env:LOCALAPPDATA | Should -BeExactly "before-LOCALAPPDATA"
    $env:TEMP | Should -BeExactly "before-TEMP"
    $env:TMP | Should -BeExactly "before-TMP"
  }

  It "opaque child <outcome> with unavailable receipt and sentinel" -TestCases @(
    @{ outcome = "failure retains isolation"; childExit = 1; retain = $true },
    @{ outcome = "forced-zero counterexample remains a limitation"; childExit = 0; retain = $false }
  ) {
    param($childExit, $retain)
      $helperPath = Join-Path $repoRoot "Tools\windows\OwnedLiveProcess.ps1"
      $helperLiteral = "'" + $helperPath.Replace("'", "''") + "'"
      $childSource = @'
using System;
using System.IO;
using System.Text;
public sealed class UnavailableOwnershipOutput : TextWriter {
    public override Encoding Encoding { get { return Encoding.UTF8; } }
    public override void WriteLine(string value) { throw new IOException("mock stdout unavailable"); }
}
'@
      $childCommand = @"
`$ErrorActionPreference = 'Stop'
. $helperLiteral
Add-Type -TypeDefinition @'
$childSource
'@
`$env:GRAPHCODE_VALIDATION_ROOT = Join-Path `$env:GRAPHCODE_VALIDATION_ROOT 'absent-child-root'
[Console]::Error.WriteLine('OPAQUE_CHILD_RECEIPT_UNAVAILABLE=true')
[Console]::SetOut([UnavailableOwnershipOutput]::new())
try {
  throw (New-OwnedLiveProcessCleanupError -Message 'mock ownership cleanup refusal' -Errors @([IO.IOException]::new('mock survivor')))
} catch {
  if ($childExit -eq 0) {
    [Console]::Error.WriteLine('OPAQUE_CHILD_FORCED_EXIT_ZERO=true')
    exit 0
  }
  throw
}
"@
      $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
      $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
      $caught = $null
      $output = [Collections.Generic.List[string]]::new()
      $oldExitCode = $global:LASTEXITCODE
      $observedExit = $null
      try {
        Invoke-WindowsShellValidationIsolation -WorkspaceRoot $workspaceRoot `
          -ValidationRootParent (Join-Path $caseRoot "short") `
          -UserProfileRoot $userProfileRoot -LocalAppDataRoot $localAppDataRoot -Action {
          Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
          Invoke-Native "opaque mock child" {
            & $pwsh -NoProfile -NonInteractive -EncodedCommand $encoded
          } | ForEach-Object { $output.Add([string]$_) }
        }
        $observedExit = $global:LASTEXITCODE
      } catch { $caught = $_; $observedExit = $global:LASTEXITCODE }
      finally { $global:LASTEXITCODE = $oldExitCode }
      $ownedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
      $observedExit | Should -Be $childExit
      @($output | Where-Object { $_ -ceq "OPAQUE_CHILD_RECEIPT_UNAVAILABLE=true" }).Count | Should -Be 1
      @($output | Where-Object { $_ -ceq "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven" }).Count | Should -Be 0
      Test-Path -LiteralPath (Join-Path $ownedRoot "ownership-unproven.json") | Should -BeFalse
      Test-Path -LiteralPath $ownedRoot | Should -Be $retain
      if ($retain) {
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data["GraphCodeValidationRootRetentionRequired"] | Should -BeTrue
        @($caught.Exception.Data["GraphCodeValidationRetainedRoots"]) | Should -Contain $ownedRoot
      } else {
        $caught | Should -BeNullOrEmpty
        @($output | Where-Object { $_ -ceq "OPAQUE_CHILD_FORCED_EXIT_ZERO=true" }).Count | Should -Be 1
        Write-Host "OPAQUE_EXIT_ZERO_COUNTEREXAMPLE=observed rootRemoved=true realProducerSwallowingProven=false"
      }
      foreach ($name in $savedEnvironment.Keys) {
        [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "before-$name"
      }
  }

  It "setup failure before workload entry removes only its partial owned root" {
    $original = [IO.IOException]::new("controlled setup failure")
    $script:actionRan = $false
    Mock New-Item {
      $partialRoot = Split-Path -Path $Path[0] -Parent
      [void][IO.Directory]::CreateDirectory($partialRoot)
      [IO.File]::WriteAllText($capturePath, $partialRoot)
      throw $original
    } -ParameterFilter { @($Path).Count -eq 3 }
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation -WorkspaceRoot $workspaceRoot `
        -ValidationRootParent (Join-Path $caseRoot "short") `
        -UserProfileRoot $userProfileRoot -LocalAppDataRoot $localAppDataRoot `
        -Action { $script:actionRan = $true }
    } catch { $caught = $_ }
    $script:actionRan | Should -BeFalse
    [object]::ReferenceEquals($caught.Exception, $original) | Should -BeTrue
    Test-Path -LiteralPath ([IO.File]::ReadAllText($capturePath)) | Should -BeFalse
    $caught.Exception.Data["GraphCodeValidationRootRetentionRequired"] | Should -BeNullOrEmpty
  }

  It "tagged ownership failure retains evidence and restores the environment" {
    $original = [InvalidOperationException]::new("controlled unattested survivor")
    $original.Data["GraphCodeValidationRootRetentionRequired"] = $true
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
          Set-Content -LiteralPath (Join-Path $env:GRAPHCODE_VALIDATION_ROOT "evidence.log") -Value "advisory snapshot"
          throw $original
        }
    } catch { $caught = $_ }
    [object]::ReferenceEquals($caught.Exception, $original) | Should -Be $true
    $ownedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    Test-Path -LiteralPath $ownedRoot | Should -Be $true
    Get-Content -LiteralPath (Join-Path $ownedRoot "evidence.log") | Should -BeExactly "advisory snapshot"
    @($caught.Exception.Data["GraphCodeValidationRetainedRoots"]) | Should -Contain $ownedRoot
    foreach ($name in $savedEnvironment.Keys) {
      [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "before-$name"
    }
  }

  It "tagged nested failure propagates both retained roots" {
    $original = [InvalidOperationException]::new("controlled nested ownership failure")
    $original.Data["GraphCodeValidationRootRetentionRequired"] = $true
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Invoke-WindowsShellValidationIsolation `
            -WorkspaceRoot (Join-Path $workspaceRoot "inner") `
            -UserProfileRoot $userProfileRoot `
            -LocalAppDataRoot $localAppDataRoot `
            -Action { throw $original }
        }
    } catch { $caught = $_ }
    [object]::ReferenceEquals($caught.Exception, $original) | Should -Be $true
    $roots = @($caught.Exception.Data["GraphCodeValidationRetainedRoots"])
    $roots.Count | Should -Be 2
    foreach ($root in $roots) { Test-Path -LiteralPath $root | Should -Be $true }
    foreach ($name in $savedEnvironment.Keys) {
      [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "before-$name"
    }
  }

  It "tagged retention reporting failure preserves the original error and root" {
    Mock Write-Host { throw [IO.IOException]::new("controlled retention reporting failure") } `
      -ParameterFilter { "$Object" -like "WINDOWS_SHELL_VALIDATION_ISOLATION_ROOT_RETAINED=*" }
    $original = [InvalidOperationException]::new("controlled original ownership failure")
    $original.Data["GraphCodeValidationRootRetentionRequired"] = $true
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
          throw $original
        }
    } catch { $caught = $_ }
    $caught.Exception | Should -BeOfType ([AggregateException])
    [object]::ReferenceEquals($caught.Exception.InnerExceptions[0], $original) | Should -Be $true
    $caught.Exception.InnerExceptions[1].Message | Should -BeExactly "controlled retention reporting failure"
    $caught.Exception.Data["GraphCodeValidationRootRetentionRequired"] | Should -Be $true
    $ownedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    Test-Path -LiteralPath $ownedRoot | Should -Be $true
    @($caught.Exception.Data["GraphCodeValidationRetainedRoots"]) | Should -Contain $ownedRoot
    foreach ($name in $savedEnvironment.Keys) {
      [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "before-$name"
    }
  }

  It "tagged missing root reports retention failure without masking the original" {
    $original = [InvalidOperationException]::new("controlled missing-root ownership failure")
    $original.Data["GraphCodeValidationRootRetentionRequired"] = $true
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Remove-Item -LiteralPath $env:GRAPHCODE_VALIDATION_ROOT -Recurse -Force
          throw $original
        }
    } catch { $caught = $_ }
    $caught.Exception | Should -BeOfType ([AggregateException])
    [object]::ReferenceEquals($caught.Exception.InnerExceptions[0], $original) | Should -Be $true
    $caught.Exception.InnerExceptions[1].Message | Should -Match "no longer exists"
    $caught.Exception.Data["GraphCodeValidationRootRetentionRequired"] | Should -Be $true
    foreach ($name in $savedEnvironment.Keys) {
      [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "before-$name"
    }
  }

  It "tagged external receipt <variant> retains the exact root" -TestCases @(
    @{ variant = "valid"; invalid = $false },
    @{ variant = "valid-limit"; invalid = $false },
    @{ variant = "wrong-root"; invalid = $true },
    @{ variant = "malformed"; invalid = $true },
    @{ variant = "oversize"; invalid = $true },
    @{ variant = "wrong-schema"; invalid = $true },
    @{ variant = "wrong-reason"; invalid = $true }
  ) {
    param($variant, $invalid)
    $original = [InvalidOperationException]::new("controlled child failure without exception data")
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
          $receipt = [ordered]@{
            schemaVersion = 1; validationRoot = $env:GRAPHCODE_VALIDATION_ROOT
            reason = "ownership_unproven"
          }
          if ($variant -eq "wrong-root") { $receipt.validationRoot += "-foreign" }
          if ($variant -eq "wrong-schema") { $receipt.schemaVersion = 2 }
          if ($variant -eq "wrong-reason") { $receipt.reason = "ordinary_failure" }
          $text = if ($variant -eq "malformed") { "not-json" } elseif ($variant -eq "oversize") {
            "x" * 4097
          } else { $receipt | ConvertTo-Json -Compress }
          if ($variant -eq "valid-limit") { $text += " " * (4096 - [Text.Encoding]::UTF8.GetByteCount($text)) }
          [IO.File]::WriteAllText((Join-Path $env:GRAPHCODE_VALIDATION_ROOT "ownership-unproven.json"),
            $text, [Text.UTF8Encoding]::new($false))
          throw $original
        }
    } catch { $caught = $_ }
    $ownedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    Test-Path -LiteralPath $ownedRoot | Should -Be $true
    $caught.Exception.Data["GraphCodeValidationRootRetentionRequired"] | Should -Be $true
    @($caught.Exception.Data["GraphCodeValidationRetainedRoots"]) | Should -Contain $ownedRoot
    if ($invalid) {
      $caught.Exception | Should -BeOfType ([AggregateException])
      [object]::ReferenceEquals($caught.Exception.InnerExceptions[0], $original) | Should -Be $true
      if ($variant -eq "oversize") { $caught.Exception.InnerExceptions[1].Message | Should -Match "4096-byte" }
    } else {
      [object]::ReferenceEquals($caught.Exception, $original) | Should -Be $true
    }
  }

  It "tagged native refusal <variant> propagates without a writable receipt" -TestCases @(
    @{ variant = "failed-exit"; childExit = 1; terminating = $false },
    @{ variant = "zero-exit"; childExit = 0; terminating = $false },
    @{ variant = "terminating"; childExit = 1; terminating = $true }
  ) {
    param($variant, $childExit, $terminating)
    $caught = $null
    $oldExitCode = $global:LASTEXITCODE
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
          Invoke-Native "mocked ownership child" {
            $global:LASTEXITCODE = $childExit
            Write-Output "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven"
            if ($terminating) { throw "controlled terminating child" }
          }
        }
    } catch { $caught = $_ } finally { $global:LASTEXITCODE = $oldExitCode }
    $caught | Should -Not -BeNullOrEmpty
    $caught.Exception.Data["GraphCodeValidationRootRetentionRequired"] | Should -Be $true
    $ownedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    Test-Path -LiteralPath $ownedRoot | Should -Be $true
    @($caught.Exception.Data["GraphCodeValidationRetainedRoots"]) | Should -Contain $ownedRoot
    if ($terminating) { $caught.Exception.Message | Should -BeExactly "controlled terminating child" }
    foreach ($name in $savedEnvironment.Keys) {
      [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "before-$name"
    }
  }

  It "tagged string truthiness does not prove cleanup after workload failure" {
    $original = [InvalidOperationException]::new("controlled ordinary failure")
    $original.Data["GraphCodeValidationRootRetentionRequired"] = "true"
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
          throw $original
        }
    } catch { $caught = $_ }
    [object]::ReferenceEquals($caught.Exception, $original) | Should -Be $true
    Test-Path -LiteralPath (Get-Content -LiteralPath $capturePath -Raw).Trim() | Should -Be $true
    $caught.Exception.Data["GraphCodeValidationRootRetentionReason"] | Should -BeExactly "workload_failed_without_cleanup_proof"
  }

  It "tagged restoration preserves originally <state> <variableName> membership" -TestCases @(
    foreach ($variable in @("GRAPHCODE_VALIDATION_ROOT", "GRAPHCODE_SUPPORT_DIR", "LOCALAPPDATA", "TEMP", "TMP")) {
      foreach ($initialState in @("absent", "empty", "valued")) {
        @{ state = $initialState; variableName = $variable }
      }
    }
  ) {
    param($state, $variableName)
    if ($state -eq "absent") {
      Remove-Item -LiteralPath "Env:\$variableName" -ErrorAction Stop
    } else {
      [Environment]::SetEnvironmentVariable($variableName, $(if ($state -eq "empty") { "" } else { "original-value" }), "Process")
    }
    $expected = [Environment]::GetEnvironmentVariables("Process")
    $expected.Contains($variableName) | Should -Be ($state -ne "absent")
    $original = [InvalidOperationException]::new("controlled membership restoration")
    $original.Data["GraphCodeValidationRootRetentionRequired"] = $true
    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          $isolated = [Environment]::GetEnvironmentVariables("Process")
          $isolated.Contains($variableName) | Should -Be $true
          $isolated[$variableName] | Should -Not -BeNullOrEmpty
          throw $original
        }
    } catch { $caught = $_ }
    [object]::ReferenceEquals($caught.Exception, $original) | Should -Be $true
    $actual = [Environment]::GetEnvironmentVariables("Process")
    $actual.Contains($variableName) | Should -Be $expected.Contains($variableName)
    if ($expected.Contains($variableName)) { $actual[$variableName] | Should -BeExactly $expected[$variableName] }
  }

  It "uses an explicit short validation parent and removes only the owned run root" {
    $missingFunctions.Count | Should -Be 0
    $shortParent = Join-Path $caseRoot "short"
    New-Item -ItemType Directory -Force -Path $shortParent | Out-Null

    Invoke-WindowsShellValidationIsolation `
      -WorkspaceRoot $workspaceRoot `
      -ValidationRootParent $shortParent `
      -UserProfileRoot $userProfileRoot `
      -LocalAppDataRoot $localAppDataRoot `
      -Action {
        Set-Content -LiteralPath $capturePath -Value $env:GRAPHCODE_VALIDATION_ROOT
      }

    $ownedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    $ownedRoot.StartsWith(
      ([IO.Path]::GetFullPath($shortParent)).TrimEnd('\') + '\',
      [StringComparison]::OrdinalIgnoreCase
    ) | Should -Be $true
    Test-Path -LiteralPath $ownedRoot | Should -Be $false
    Test-Path -LiteralPath $shortParent -PathType Container | Should -Be $true
  }

  It "fails the task when a default-profile artifact changes" {
    $missingFunctions.Count | Should -Be 0
    $defaultSupport = Join-Path $userProfileRoot ".graphcode"
    New-Item -ItemType Directory -Force -Path $defaultSupport | Out-Null
    $artifact = Join-Path $defaultSupport "graphcode-windows.log"
    Set-Content -LiteralPath $artifact -Value "before"

    $caught = $null
    try {
      Invoke-WindowsShellValidationIsolation `
        -WorkspaceRoot $workspaceRoot `
        -UserProfileRoot $userProfileRoot `
        -LocalAppDataRoot $localAppDataRoot `
        -Action {
          Set-Content -LiteralPath $artifact -Value "after"
        }
    } catch {
      $caught = $_
    }

    $caught.Exception.Message | Should -Match "default profile artifact changed"
    $caught.Exception.Message | Should -Match ([regex]::Escape($defaultSupport))
    $env:GRAPHCODE_SUPPORT_DIR | Should -BeExactly "before-GRAPHCODE_SUPPORT_DIR"
  }

  It "routes the windows-shell task through the isolation boundary" {
    $missingFunctions.Count | Should -Be 0
    $runnerSource | Should -Match (
      '(?s)foreach \(\$name in \$selected\)\s*\{\s*' +
      'if \(\$name -eq "windows-shell" -and -not \$DryRun\).*' +
      'Invoke-WindowsShellValidationIsolation.*-ValidationRootParent \$ShellValidationRoot.*Invoke-Task "windows-shell"'
    )
    $runnerSource | Should -Match (
      '(?s)Windows shell validation isolation contract.*' +
      'Invoke-Pester.*ValidationIsolation\.Tests\.ps1.*' +
      'TotalCount -le 0.*PassedCount -ne .*TotalCount.*FailedCount -ne 0'
    )
  }
}
