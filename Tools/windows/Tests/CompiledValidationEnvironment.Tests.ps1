[CmdletBinding()]
param([string] $Worker, [string] $WorkspaceRoot, [string] $ProducerPath)

$ErrorActionPreference = 'Stop'
function Import-CompiledEnvironmentProducer([string] $Path) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw 'Compiled environment producer does not parse' }
  $functions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Invoke-WithCompiledValidationAssembly'
  }, $true))
  if ($functions.Count -ne 1) { throw 'Expected exactly one compiled environment boundary' }
  [scriptblock]::Create($functions[0].Extent.Text)
}
if ($Worker -eq 'empty') {
  . (Import-CompiledEnvironmentProducer $ProducerPath)
  $before = [Environment]::GetEnvironmentVariables('Process')
  if (-not $before.Contains('GRAPHCODE_VALIDATION_ASSEMBLY') -or
      [Environment]::GetEnvironmentVariable('GRAPHCODE_VALIDATION_ASSEMBLY') -ne '') {
    throw 'Child did not receive an explicitly empty environment entry'
  }
  $state = @{ ran = $false }
  $failure = $null
  try {
    Invoke-WithCompiledValidationAssembly -WorkspaceRoot $WorkspaceRoot -Action { $state.ran = $true }
  } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -notmatch 'explicitly empty' -or $state.ran -or
      -not [Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY') -or
      [Environment]::GetEnvironmentVariable('GRAPHCODE_VALIDATION_ASSEMBLY') -ne '') {
    throw 'Explicit empty entry was replaced, removed, or admitted'
  }
  Write-Output 'COMPILED_ENV_EMPTY_PRESERVED=1'
  exit 0
}
. (Join-Path $PSScriptRoot '..\Import-PinnedPester.ps1')

Describe 'Scoped compiled assembly publication at the actual Windows caller boundary' {
  BeforeAll {
    $repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $producer = Join-Path $repository 'Tools\windows\validate.ps1'
    $testScript = Join-Path $PSScriptRoot 'CompiledValidationEnvironment.Tests.ps1'
    $testAst = [Management.Automation.Language.Parser]::ParseFile($testScript, [ref]$null, [ref]$null)
    $loader = $testAst.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Import-CompiledEnvironmentProducer'
    }, $true)
    . ([scriptblock]::Create($loader.Extent.Text))
    . (Import-CompiledEnvironmentProducer $producer)
  }
  BeforeEach {
    $present = [Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY')
    $saved = [Environment]::GetEnvironmentVariable('GRAPHCODE_VALIDATION_ASSEMBLY')
    if ($present) { Remove-Item -LiteralPath 'Env:\GRAPHCODE_VALIDATION_ASSEMBLY' -ErrorAction Stop }
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $scripts = Join-Path $root 'Tools\windows'
    $null = New-Item -ItemType Directory -Force -Path $scripts
    $assembly = Join-Path $root 'ValidationRunner.dll'
    [IO.File]::WriteAllBytes($assembly, [byte[]]@())
    $events = Join-Path $root 'events.txt'
    $settings = Join-Path $root 'settings.json'
    @{ assembly = $assembly; events = $events; mode = 'normal' } | ConvertTo-Json |
      Set-Content -LiteralPath $settings
    @'
$s = Get-Content (Join-Path $PSScriptRoot '..\..\settings.json') -Raw | ConvertFrom-Json
Add-Content -LiteralPath $s.events -Value 'build'
if ($s.mode -eq 'build-fail') { throw [IO.IOException]::new('controlled compiler failure') }
$s.assembly
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Build-CompiledValidationRunner.ps1')
    @'
param([string] $AssemblyPath, [string] $RequiredType)
$s = Get-Content (Join-Path $PSScriptRoot '..\..\settings.json') -Raw | ConvertFrom-Json
Add-Content -LiteralPath $s.events -Value 'load'
if ($s.mode -eq 'load-fail') { throw [IO.IOException]::new('controlled provenance failure') }
if ($AssemblyPath -cne $s.assembly -or $RequiredType -cne 'ShellOwnedLaunch') {
  throw 'Unexpected current assembly loader arguments'
}
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Import-CompiledValidationAssembly.ps1')
  }
  AfterEach {
    if ($present) { [Environment]::SetEnvironmentVariable('GRAPHCODE_VALIDATION_ASSEMBLY', $saved, 'Process') }
    elseif ([Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY')) {
      Remove-Item -LiteralPath 'Env:\GRAPHCODE_VALIDATION_ASSEMBLY' -ErrorAction Stop
    }
  }
  It 'builds and validates once before publishing a missing entry, then removes only its publication' {
    Invoke-WithCompiledValidationAssembly -WorkspaceRoot $root -Action {
      $env:GRAPHCODE_VALIDATION_ASSEMBLY | Should -BeExactly $assembly
      $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
      $start.UseShellExecute = $false
      $start.CreateNoWindow = $true
      $start.RedirectStandardOutput = $true
      $start.RedirectStandardError = $true
      foreach ($argument in @('-NoProfile', '-Command',
          '[Environment]::GetEnvironmentVariable("GRAPHCODE_VALIDATION_ASSEMBLY")')) {
        $start.ArgumentList.Add($argument)
      }
      $child = [Diagnostics.Process]::Start($start)
      try {
        $child.WaitForExit(15000) | Should -BeTrue
        $child.ExitCode | Should -Be 0 -Because ($child.StandardError.ReadToEnd())
        $child.StandardOutput.ReadToEnd().Trim() | Should -BeExactly $assembly
      } finally { $child.Dispose() }
      Add-Content -LiteralPath $events -Value 'action'
    }
    (Get-Content $events) -join ',' | Should -BeExactly 'build,load,action'
    [Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY') | Should -BeFalse
  }
  It 'validates but does not replace or rebuild a supplied assembly entry' {
    [Environment]::SetEnvironmentVariable('GRAPHCODE_VALIDATION_ASSEMBLY', $assembly, 'Process')
    Invoke-WithCompiledValidationAssembly -WorkspaceRoot $root -Action {
      $env:GRAPHCODE_VALIDATION_ASSEMBLY | Should -BeExactly $assembly
    }
    (Get-Content $events) -join ',' | Should -BeExactly 'load'
    $env:GRAPHCODE_VALIDATION_ASSEMBLY | Should -BeExactly $assembly
  }
  It 'preserves and refuses an explicitly empty native child entry without compiling or running the action' {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['GRAPHCODE_VALIDATION_ASSEMBLY'] = ''
    foreach ($argument in @('-NoProfile', '-File', $testScript, '-Worker', 'empty',
        '-WorkspaceRoot', $root, '-ProducerPath', $producer)) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($start)
    try {
      $child.WaitForExit(15000) | Should -BeTrue
      $stdout = $child.StandardOutput.ReadToEnd()
      $stderr = $child.StandardError.ReadToEnd()
      $child.ExitCode | Should -Be 0 -Because $stderr
      $stdout.Trim() | Should -BeExactly 'COMPILED_ENV_EMPTY_PRESERVED=1'
      Test-Path -LiteralPath $events | Should -BeFalse
    } finally { $child.Dispose() }
  }
  It 'keeps compiler failure primary and does not publish or invoke the action' {
    @{ assembly = $assembly; events = $events; mode = 'build-fail' } | ConvertTo-Json | Set-Content $settings
    { Invoke-WithCompiledValidationAssembly -WorkspaceRoot $root -Action { throw 'unexpected action' } } |
      Should -Throw '*controlled compiler failure*'
    (Get-Content $events) -join ',' | Should -BeExactly 'build'
    [Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY') | Should -BeFalse
  }
  It 'refuses failed current-source provenance before publishing or running the action' {
    @{ assembly = $assembly; events = $events; mode = 'load-fail' } | ConvertTo-Json | Set-Content $settings
    { Invoke-WithCompiledValidationAssembly -WorkspaceRoot $root -Action { throw 'unexpected action' } } |
      Should -Throw '*controlled provenance failure*'
    (Get-Content $events) -join ',' | Should -BeExactly 'build,load'
    [Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY') | Should -BeFalse
  }
  It 'preserves action exception identity while restoring the originally missing entry' {
    $expected = [IO.IOException]::new('controlled action failure')
    $failure = $null
    try {
      Invoke-WithCompiledValidationAssembly -WorkspaceRoot $root -Action {
        Remove-Item -LiteralPath 'Env:\GRAPHCODE_VALIDATION_ASSEMBLY' -ErrorAction Stop
        throw $expected
      }
    }
    catch { $failure = $_ }
    [object]::ReferenceEquals($failure.Exception, $expected) | Should -BeTrue
    [Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ASSEMBLY') | Should -BeFalse
  }
  It 'wraps the actual Windows task exactly once inside profile isolation and only outside dry run' {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($producer, [ref]$tokens, [ref]$errors)
    $calls = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-WithCompiledValidationAssembly'
    }, $true))
    $calls.Count | Should -Be 1
    $blocks = @($calls[0].CommandElements | Where-Object {
      $_ -is [Management.Automation.Language.ScriptBlockExpressionAst]
    })
    $blocks.Count | Should -Be 1
    $blocks[0].Extent.Text | Should -Match 'Invoke-Task "windows-shell"'
    $isolation = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-WindowsShellValidationIsolation' -and
        $node.Extent.StartOffset -le $calls[0].Extent.StartOffset -and
        $node.Extent.EndOffset -ge $calls[0].Extent.EndOffset
    }, $true))
    $isolation.Count | Should -Be 1
    ([IO.File]::ReadAllText($producer)) | Should -Match '\$name -eq "windows-shell" -and -not \$DryRun'
  }
}
