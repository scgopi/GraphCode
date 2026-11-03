$ErrorActionPreference = 'Stop'
$script:RootCases = [Collections.Generic.List[object]]::new()

function Test-RootCase([string] $Id, [scriptblock] $Body) {
  try {
    & $Body | Out-Null
    $script:RootCases.Add([ordered]@{ id = $Id; passed = $true; error = $null })
  } catch {
    $script:RootCases.Add([ordered]@{ id = $Id; passed = $false; error = $_.Exception.Message })
  }
}

function Assert-Root([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}

function Get-ProductionFunction([string] $Path, [string] $Name) {
  $tokens = $null
  $errors = $null
  $tree = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Production source does not parse: $Path" }
  $found = @($tree.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  if ($found.Count -ne 1) { throw "Expected one production function $Name; found $($found.Count)" }
  [scriptblock]::Create($found[0].Extent.Text)
}

function Write-RootSummary([string] $Suite) {
  $failures = @($script:RootCases | Where-Object { -not $_.passed })
  $report = Join-Path $ArtifactRoot ($Suite + '-cases-' + [guid]::NewGuid().ToString('N') + '.json')
  $script:RootCases.ToArray() | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report
  $row = [ordered]@{
    id = $Suite
    status = $(if ($failures.Count -eq 0) { 'Passed' } else { 'Failed' })
    executedCount = $script:RootCases.Count
    evidence = "Production-backed cases: executed=$($script:RootCases.Count); failed=$($failures.Count); report=$report"
    groups = @($script:RootCases | Where-Object passed | ForEach-Object { $_.id })
  }
  Write-Output ('HOST_CASE_RESULT=' + ($row | ConvertTo-Json -Depth 8 -Compress))
}
