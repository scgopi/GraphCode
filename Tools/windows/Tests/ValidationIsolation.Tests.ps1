[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Describe "Windows shell validation profile isolation" {
BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
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
  foreach ($name in @(
      "GRAPHCODE_VALIDATION_ROOT",
      "GRAPHCODE_SUPPORT_DIR",
      "LOCALAPPDATA",
      "TEMP",
      "TMP"
    )) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, "before-$name")
  }
}

AfterEach {
  foreach ($entry in $savedEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
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

  It "restores and cleans owned roots when the workload fails" {
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
    Test-Path -LiteralPath $ownedRoot.Trim() | Should -Be $false
    $env:GRAPHCODE_VALIDATION_ROOT | Should -BeExactly "before-GRAPHCODE_VALIDATION_ROOT"
    $env:GRAPHCODE_SUPPORT_DIR | Should -BeExactly "before-GRAPHCODE_SUPPORT_DIR"
    $env:LOCALAPPDATA | Should -BeExactly "before-LOCALAPPDATA"
    $env:TEMP | Should -BeExactly "before-TEMP"
    $env:TMP | Should -BeExactly "before-TMP"
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
