$ErrorActionPreference = 'Stop'
$script:OwnershipCases = [Collections.Generic.List[object]]::new()

function Read-OwnershipProductionAst([string] $Path) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors.Count -ne 0) { throw "Production source failed to parse: $Path" }
    return $ast
}

function Import-OwnershipProductionFunctions($Ast, [string[]] $Names, [hashtable] $Replacements = @{}) {
    foreach ($name in $Names) {
        $definitions = @($Ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true))
        if ($definitions.Count -ne 1) { throw "Expected one complete production function: $name" }
        $text = $definitions[0].Extent.Text
        foreach ($key in $Replacements.Keys) { $text = $text.Replace($key, $Replacements[$key]) }
        . ([scriptblock]::Create($text))
    }
}

function Assert-Ownership([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}

function Invoke-OwnershipCase([string] $Id, [scriptblock] $Body) {
    if (@($script:OwnershipCases | Where-Object Id -CEQ $Id).Count -ne 0) { throw "Duplicate ownership case: $Id" }
    try {
        & $Body 6>&1 | ForEach-Object {
            if ([string]$_ -cne 'GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven') { $_ }
        } | Out-Null
        $script:OwnershipCases.Add([ordered]@{ Id = $Id; Passed = $true; Failure = $null })
    } catch {
        $script:OwnershipCases.Add([ordered]@{ Id = $Id; Passed = $false; Failure = $_.ToString() })
    }
}

function Complete-OwnershipFamily([string] $Id, [int] $Expected, [string[]] $Groups = @('powershell-semantics')) {
    $failed = @($script:OwnershipCases | Where-Object { -not $_.Passed })
    $passed = $script:OwnershipCases.Count -eq $Expected -and $failed.Count -eq 0 -and $Expected -gt 0
    $row = [ordered]@{
        id = $Id
        status = $(if ($passed) { 0 } else { 1 })
        executedCount = $script:OwnershipCases.Count
        evidence = (@{
            expected = $Expected
            executed = $script:OwnershipCases.Count
            failed = $failed.Count
            cases = $script:OwnershipCases.ToArray()
            nativeProductCalls = 0
        } | ConvertTo-Json -Depth 12 -Compress)
        groups = $Groups
    }
    Write-Output ('OWNERSHIP_CASE_RESULT=' + ($row | ConvertTo-Json -Depth 14 -Compress))
    $script:OwnershipCases.Clear()
    if (-not $passed) { $script:OwnershipAdapterFailed = $true }
}

function Restore-OwnershipEnvironment([Collections.IDictionary] $Snapshot, [string[]] $Names) {
    foreach ($name in $Names) {
        if ($Snapshot.Contains($name)) { [Environment]::SetEnvironmentVariable($name, $Snapshot[$name], 'Process') }
        else { Remove-OwnershipEnvironment $name }
    }
}

function Remove-OwnershipEnvironment([string] $Name) {
    if ([Environment]::GetEnvironmentVariables('Process').Contains($Name)) {
        Remove-Item -LiteralPath "Env:\$Name" -ErrorAction Stop
    }
}
