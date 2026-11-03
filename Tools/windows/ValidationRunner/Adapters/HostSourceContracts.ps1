[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][ValidateSet("host-prerequisite", "provider-boundary", "delayed-responses")][string] $Contract
)

$ErrorActionPreference = "Stop"
$source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot "Tools\windows\validate.ps1"))
$cases = [Collections.Generic.List[string]]::new()
function Assert-Source([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw "Compiled validation source contract: $Message" }
}
function Get-TaskBody([string] $Text, [string] $Task) {
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errors)
  Assert-Source ($errors.Count -eq 0) "validation source does not parse"
  $function = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Invoke-Task"
    }, $true))
  Assert-Source ($function.Count -eq 1) "task dispatcher is missing or duplicated"
  $switches = @($function[0].FindAll({
      param($node)
      $node -is [Management.Automation.Language.SwitchStatementAst]
    }, $true))
  $clauses = @($switches.Clauses | Where-Object { $_.Item1.Value -ceq $Task })
  Assert-Source ($clauses.Count -eq 1) "task branch missing or duplicated: $Task"
  return $clauses[0].Item2
}
function Confirm-HostOrder([string] $Text) {
  $body = Get-TaskBody $Text "windows-shell"
  $commands = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst]
    }, $true))
  $stages = @{}
  foreach ($entry in @(
      @{ key = "build"; title = '"Pinned Winghostty host build for App contracts"' },
      @{ key = "smoke"; title = '"Pinned GraphCode Windows shell build and smoke"' }
    )) {
    $values = @($commands | Where-Object {
        $_.GetCommandName() -ceq "Invoke-Native" -and $_.CommandElements[1].Extent.Text -ceq $entry.title
      })
    Assert-Source ($values.Count -eq 1) "missing or duplicated $($entry.key)"
    $stages[$entry.key] = $values[0].Extent
  }
  $calls = @($commands | Where-Object {
      $_.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
        $_.CommandElements[0].Extent.Text -match 'Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1'
    })
  Assert-Source ($calls.Count -eq 1) "App contracts call missing or duplicated"
  $stages.contracts = $calls[0].Extent
  $guards = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.IfStatementAst]
    }, $true))
  foreach ($entry in @(
      @{ key = "pin"; pattern = '\$actualWinghosttyPin -ne \$pins\.winghostty\.sha' },
      @{ key = "clean"; pattern = '\$providerStatus\.Count -ne 0' },
      @{ key = "library"; pattern = 'Test-Path -LiteralPath \$winghosttyLib -PathType Leaf' }
    )) {
    $values = @($guards | Where-Object { $_.Extent.Text -match $entry.pattern })
    Assert-Source ($values.Count -eq 1) "missing or duplicated $($entry.key) guard"
    $stages[$entry.key] = $values[0].Extent
  }
  Assert-Source ($stages.pin.EndOffset -lt $stages.build.StartOffset -and
    $stages.clean.EndOffset -lt $stages.build.StartOffset -and
    $stages.build.EndOffset -lt $stages.library.StartOffset -and
    $stages.library.EndOffset -lt $stages.contracts.StartOffset -and
    $stages.contracts.EndOffset -lt $stages.smoke.StartOffset) "App host prerequisite ordering changed"
  Assert-Source ($stages.build.Text -match
    '(?s)Push-Location \$winghosttyRoot.*& \$zig0152 build -Demit-win32-host=true.*finally \{ Pop-Location \}') `
    "host compile is not the pinned build with restored working directory"
}
switch ($Contract) {
  "host-prerequisite" {
    Confirm-HostOrder $source
    $cases.Add("actual-pinned-order")
    $call = [regex]::Match($source,
      '(?s)& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1"\)\s*`\s*-ZigExecutable \$zig0152').Value
    Assert-Source (-not [string]::IsNullOrEmpty($call)) "cannot construct early-call mutation"
    $variants = [ordered]@{
      "missing-build" = $source.Replace('& $zig0152 build -Demit-win32-host=true', 'Write-Output "build removed"')
      "missing-stage" = $source.Replace('"Pinned Winghostty host build for App contracts"', '"build removed"')
      "early-contracts" = $source.Replace($call, "").Replace(
        'Invoke-Native "Pinned Winghostty host build for App contracts"',
        $call + "`n" + 'Invoke-Native "Pinned Winghostty host build for App contracts"')
    }
    foreach ($name in $variants.Keys) {
      Assert-Source ($variants[$name] -cne $source) "ineffective mutation: $name"
      $rejected = $false
      try { Confirm-HostOrder $variants[$name] } catch { $rejected = $true }
      Assert-Source $rejected "unsafe prerequisite mutation admitted: $name"
      $cases.Add($name)
    }
  }
  "provider-boundary" {
    $body = (Get-TaskBody $source "provider-build").Extent.Text
    Assert-Source ($body -match 'Invoke-ProviderBuild' -and
      $body -notmatch '(?i)terminal-gate\.ps1|TerminalGate\.Tests|windows-shell\.ps1|uia|Stress') `
      "build-only task runs more than the shared provider compile"
    $cases.Add("build-only-dispatch")
    $terminal = (Get-TaskBody $source "terminal-gate").Extent.Text
    Assert-Source ($terminal -match '(?s)Invoke-ProviderBuild.*?terminal-gate\.ps1.*?-SkipProviderBuild.*?-Stress') `
      "terminal gate no longer reuses the shared compile"
    $cases.Add("terminal-shared-build")
    foreach ($consumer in @("terminal-gate.ps1", "windows-shell.ps1")) {
      $text = [IO.File]::ReadAllText((Join-Path $RepositoryRoot "Tools\windows\$consumer"))
      Assert-Source ($text -match 'provider-build\.ps1' -and
        $text -notmatch '-Demit-win32-host=true|-Dtarget=x86_64-windows-gnu') "consumer duplicates build flags: $consumer"
      $cases.Add($consumer)
    }
    $provider = [IO.File]::ReadAllText((Join-Path $RepositoryRoot "Tools\windows\provider-build.ps1"))
    Assert-Source ($provider.Contains('-Demit-win32-host=true') -and $provider.Contains('-Dtarget=x86_64-windows-gnu')) `
      "canonical provider build flags are absent"
    $cases.Add("canonical-flags")
  }
  "delayed-responses" {
    foreach ($path in @("Tools\windows\validate.ps1", "Tools\windows\Tests\Hardening.Tests.ps1")) {
      $text = [IO.File]::ReadAllText((Join-Path $RepositoryRoot $path))
      Assert-Source ($text.Contains('-StubResponseDelayMilliseconds 150')) "delayed correlated response not exercised: $path"
      $cases.Add($path)
    }
  }
}
Assert-Source ($cases.Count -gt 0) "no cases executed"
[ordered]@{
  suite = "HostSource.$Contract"; executed = $cases.Count; passed = $cases.Count; failed = 0; skipped = 0
} | ConvertTo-Json -Compress | Write-Output
