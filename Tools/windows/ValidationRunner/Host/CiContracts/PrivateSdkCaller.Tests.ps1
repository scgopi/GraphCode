param([Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot)
. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$wrapper = Join-Path $RepositoryRoot 'Tools\windows\Invoke-ValidationRunnerContract.ps1'
. (Get-ProductionFunction $wrapper 'Invoke-WithValidationRunnerRuntime')
$sdk = 'C:\fixture\private-sdk\dotnet.exe'
$expectedRoot = 'C:\fixture\private-sdk'
$names = @('GRAPHCODE_DOTNET10403', 'DOTNET_ROOT', 'DOTNET_ROOT_X64')
$before = @{}
$priorExit = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$priorExitValue = if ($null -ne $priorExit) { $priorExit.Value } else { $null }
$environment = [Environment]::GetEnvironmentVariables('Process')
foreach ($name in $names) { $before[$name] = @{ present = $environment.Contains($name); value = $environment[$name] } }
function Test-Path($LiteralPath, $PathType) { $LiteralPath -ceq $sdk -and $PathType -ceq 'Leaf' }

function Set-PrivateSdkTestState([string] $Kind) {
  [Environment]::SetEnvironmentVariable('GRAPHCODE_DOTNET10403', $sdk, 'Process')
  foreach ($name in @('DOTNET_ROOT', 'DOTNET_ROOT_X64')) {
    $value = switch ($Kind) {
      'absent' { $null }
      'empty' { '' }
      'valued' { "C:\existing\$name" }
      'mixed' { if ($name -ceq 'DOTNET_ROOT') { $null } else { 'C:\existing\x64' } }
    }
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
  }
  $environment = [Environment]::GetEnvironmentVariables('Process')
  if ($Kind -ceq 'empty') {
    Assert-Root ($environment.Contains('DOTNET_ROOT') -and $environment.Contains('DOTNET_ROOT_X64')) `
      'This empty-state case must actually begin with present empty environment entries'
  }
  $snapshot = @{}
  foreach ($name in @('DOTNET_ROOT', 'DOTNET_ROOT_X64')) {
    $snapshot[$name] = @{ present = $environment.Contains($name); value = $environment[$name] }
  }
  return $snapshot
}

function Assert-PrivateSdkStateRestored($Snapshot) {
  $environment = [Environment]::GetEnvironmentVariables('Process')
  foreach ($name in @('DOTNET_ROOT', 'DOTNET_ROOT_X64')) {
    Assert-Root ($environment.Contains($name) -eq $Snapshot[$name].present -and
      $environment[$name] -ceq $Snapshot[$name].value) "Exact process environment state was not restored: $name"
  }
}

try {
  foreach ($kind in @('absent', 'empty', 'valued', 'mixed')) {
    foreach ($outcome in @('success', 'failure')) {
      Test-RootCase "private-sdk.$kind.$outcome" {
        $snapshot = Set-PrivateSdkTestState $kind
        $calls = @{ Count = 0 }
        $primary = [InvalidOperationException]::new('PRIVATE_SDK_PRIMARY_FAILURE')
        $failure = $null
        try {
          Invoke-WithValidationRunnerRuntime {
            $calls.Count++
            Assert-Root ([Environment]::GetEnvironmentVariable('DOTNET_ROOT', 'Process') -ceq $expectedRoot -and
              [Environment]::GetEnvironmentVariable('DOTNET_ROOT_X64', 'Process') -ceq $expectedRoot) `
              'The apphost action did not observe the selected private runtime in both resolution variables'
            if ($outcome -ceq 'failure') { throw $primary }
          }
        } catch { $failure = $_ }
        Assert-Root ($calls.Count -eq 1) 'The apphost action did not execute exactly once'
        Assert-Root (($outcome -ceq 'success' -and $null -eq $failure) -or
          ($outcome -ceq 'failure' -and [object]::ReferenceEquals($failure.Exception, $primary))) `
          'The original apphost action failure was swallowed or replaced'
        Assert-PrivateSdkStateRestored $snapshot
      }
    }
  }
  Test-RootCase 'private-sdk.unconfigured-ci-root' {
    $snapshot = Set-PrivateSdkTestState 'valued'
    [Environment]::SetEnvironmentVariable('GRAPHCODE_DOTNET10403', $null, 'Process')
    Invoke-WithValidationRunnerRuntime { Assert-PrivateSdkStateRestored $snapshot }
    Assert-PrivateSdkStateRestored $snapshot
  }
  Test-RootCase 'private-sdk.empty-selection-ci-root' {
    $snapshot = Set-PrivateSdkTestState 'valued'
    [Environment]::SetEnvironmentVariable('GRAPHCODE_DOTNET10403', '', 'Process')
    Invoke-WithValidationRunnerRuntime { Assert-PrivateSdkStateRestored $snapshot }
    Assert-PrivateSdkStateRestored $snapshot
  }
  foreach ($entry in @(
      @{ Id = 'relative'; Path = 'dotnet.exe' },
      @{ Id = 'missing'; Path = 'C:\fixture\missing\dotnet.exe' })) {
    Test-RootCase "private-sdk.invalid.$($entry.Id)" {
      $snapshot = Set-PrivateSdkTestState 'valued'
      [Environment]::SetEnvironmentVariable('GRAPHCODE_DOTNET10403', $entry.Path, 'Process')
      $calls = @{ Count = 0 }
      $failure = $null
      try { Invoke-WithValidationRunnerRuntime { $calls.Count++ } } catch { $failure = $_ }
      Assert-Root ($calls.Count -eq 0 -and $null -ne $failure -and
        $failure.Exception.Message.Contains('GRAPHCODE_DOTNET10403')) 'Invalid private SDK selection was silently accepted'
      Assert-PrivateSdkStateRestored $snapshot
    }
  }
  Test-RootCase 'private-sdk.action-output-only' {
    $snapshot = Set-PrivateSdkTestState 'mixed'
    $output = @(Invoke-WithValidationRunnerRuntime { 'first'; 'second' })
    Assert-Root ($output.Count -eq 2 -and ($output -join ',') -ceq 'first,second') 'Runtime scoping polluted the apphost output stream'
    Assert-PrivateSdkStateRestored $snapshot
  }
  Test-RootCase 'private-sdk.error-stream-and-native-exit' {
    $snapshot = Set-PrivateSdkTestState 'empty'
    $output = @(Invoke-WithValidationRunnerRuntime {
      'stdout'
      Write-Error 'PRIVATE_SDK_TEST_STDERR' -ErrorAction Continue
      $global:LASTEXITCODE = 17
    } 2>&1)
    Assert-Root ($output.Count -eq 2 -and $output[0] -ceq 'stdout' -and
      $output[1] -is [Management.Automation.ErrorRecord] -and $global:LASTEXITCODE -eq 17) `
      'Runtime scoping changed output/error identity or native exit state'
    Assert-PrivateSdkStateRestored $snapshot
  }
  Test-RootCase 'private-sdk.unconfigured-absent-root' {
    $snapshot = Set-PrivateSdkTestState 'absent'
    [Environment]::SetEnvironmentVariable('GRAPHCODE_DOTNET10403', $null, 'Process')
    Invoke-WithValidationRunnerRuntime { Assert-PrivateSdkStateRestored $snapshot }
    Assert-PrivateSdkStateRestored $snapshot
  }
  Test-RootCase 'private-sdk.actual-normal-command-is-scoped' {
    $tokens = $null
    $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$errors)
    Assert-Root ($errors.Count -eq 0) 'Actual wrapper does not parse'
    $scopes = @($tree.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-WithValidationRunnerRuntime'
    }, $true))
    Assert-Root ($scopes.Count -eq 1 -and
      $scopes[0].CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) `
      'Actual wrapper must scope exactly one action'
    $calls = @($scopes[0].CommandElements[1].ScriptBlock.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
        $node.CommandElements[0].Extent.Text -ceq '$runner'
    }, $true))
    Assert-Root ($calls.Count -eq 1 -and
      (@($calls[0].CommandElements | ForEach-Object { $_.Extent.Text }) -join ' ') -ceq
        '$runner --repository-root $repoRoot --artifact-root $artifactRoot @compilerArguments') 'Runtime scope changed the normal unfiltered apphost arguments or omitted compiler-input forwarding'
  }
} finally {
  foreach ($name in $names) {
    $value = if ($before[$name].present) { $before[$name].value } else { $null }
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
  }
  if ($null -eq $priorExit) { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
  else { $global:LASTEXITCODE = $priorExitValue }
}
Write-RootSummary 'host.private-sdk-caller-controls'
if ($script:RootCases.Count -ne 16 -or @($script:RootCases | Where-Object { -not $_.passed }).Count -ne 0) {
  throw 'Private SDK caller controls require exactly 16 passing cases'
}
