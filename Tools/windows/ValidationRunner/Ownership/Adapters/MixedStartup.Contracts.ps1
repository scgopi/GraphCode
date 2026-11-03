[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
$gate = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
. Import-OwnershipProductionFunctions $gate @('ConvertTo-MultiProjectStartupXPathLiteral', 'New-MultiProjectStartupEventQuery',
    'ConvertFrom-MultiProjectEventNumber', 'ConvertFrom-MultiProjectOwnedStartupEvent',
    'Invoke-MultiProjectOwnedStartupFailure', 'Get-MultiProjectRetentionError')
$eventStart = [DateTimeOffset]::Parse('2026-10-01T18:29:43.1462496Z').UtcDateTime
$eventEnd = $eventStart.AddSeconds(1)
$held = [pscustomobject]@{ Id = 5832; StartTime = $eventStart }
$executable = 'D:\owned\graphcode-windows.exe'
function New-OwnedEvent([string] $Mutation = '') {
    $pidValue = '0x{0:x}' -f $held.Id
    $generation = '0x{0:x}' -f $eventStart.ToFileTimeUtc()
    $path = $executable; $provider = 'Application Error'; $timestamp = $eventEnd.ToString('o')
    $module = 'kernelbase.dll'; $code = '0xc0000142'; $extra = ''
    switch ($Mutation) {
        'foreign-pid' { $pidValue = '0x7777'; $module = 'SECRET_FOREIGN_MODULE' }
        'reused-pid' { $generation = '0x{0:x}' -f $eventStart.AddSeconds(-1).ToFileTimeUtc() }
        'foreign-path' { $path = 'D:\foreign\other.exe'; $module = 'SECRET_FOREIGN_MODULE' }
        'provider' { $provider = 'Windows Error Reporting' }
        'outside-window' { $timestamp = $eventStart.AddSeconds(-1).ToString('o') }
        'duplicate-id' { $extra = '<Data Name="ProcessId">0x7777</Data>' }
        'module-path' { $module = 'C:\private\SECRET_FOREIGN_MODULE.dll' }
        'code-type' { $code = 'SECRET_COMMANDLINE' }
        'unnamed' { $extra = '<Data>SECRET_MESSAGE</Data>' }
    }
    $xml = @"
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="$provider"/><EventID>1000</EventID><TimeCreated SystemTime="$timestamp"/><EventRecordID>42</EventRecordID><Execution ProcessID="9999"/></System><EventData><Data Name="ProcessId">$pidValue</Data><Data Name="ProcessCreationTime">$generation</Data><Data Name="AppPath">$path</Data><Data Name="ModuleName">$module</Data><Data Name="ExceptionCode">$code</Data><Data Name="FaultingOffset">0x1234</Data>$extra</EventData></Event>
"@
    if ($Mutation -ceq 'execution-only') { $xml = $xml.Replace('<Data Name="ProcessId">' + $pidValue + '</Data>', '') }
    if ($Mutation -ceq 'missing-generation') { $xml = $xml.Replace('<Data Name="ProcessCreationTime">' + $generation + '</Data>', '') }
    if ($Mutation -ceq 'oversized') { $xml += 'x' * 65536 }
    if ($Mutation -ceq 'bad-xml') { $xml = '<Event>broken' }
    if ($Mutation -ceq 'dtd') { $xml = '<!DOCTYPE Event [<!ENTITY canary SYSTEM "file:///D:/foreign">]>' + $xml }
    $record = [pscustomobject]@{ Xml = $xml }
    $record | Add-Member ScriptMethod ToXml { $this.Xml }
    $record | Add-Member ScriptProperty Message { throw 'Forbidden event Message access.' }
    return $record
}
function Invoke-StartupProbe($Records, $Process = $held, [string] $Path = $executable, [string] $Faults = '') {
    $state = @{ queries = 0; files = 0; summaries = 0; warnings = 0; caught = $null }
    $original = [InvalidOperationException]::new('shell exited with code -1073741502')
    try {
        Invoke-MultiProjectOwnedStartupFailure $Process -1073741502 $Path $ArtifactRoot { throw $original } -observedUtc $eventEnd `
            -querySource {
                param($filter, $maximum)
                $state.queries++
                Assert-Ownership ($maximum -eq 8) 'Canonical startup event result bound changed.'
                $xml = [xml]$filter
                $selects = @($xml.QueryList.Query.Select)
                $selector = $selects[0].InnerText
                Assert-Ownership ($selects.Count -eq 1 -and $selects[0].Path -ceq 'Application' -and
                    $selector.Contains("Provider[@Name='Application Error']") -and $selector.Contains('EventID=1000') -and
                    $selector.Contains("Data[@Name='ProcessId']='5832'") -and
                    $selector.Contains("Data[@Name='ProcessCreationTime']='" + $eventStart.ToFileTimeUtc() + "'") -and
                    $selector.Contains("Data[@Name='AppPath']") -and $selector.Contains($executable) -and
                    $selector.Contains($eventStart.ToString('o')) -and $selector.Contains($eventEnd.ToString('o')) -and
                    -not $selector.Contains('Execution')) 'Canonical selector lost exact held subject generation/path/time.'
                if ($Faults.Contains('query')) { throw [IO.IOException]::new('SECRET_QUERY_COMMANDLINE') }
                return $Records
            } -fileSink {
                param($file, $json)
                $state.files++
                if ($Faults.Contains('file')) { throw [IO.IOException]::new('SECRET_FILE_COMMANDLINE') }
            } -summarySink {
                param($line)
                $state.summaries++
                if ($Faults.Contains('summary')) { throw [IO.IOException]::new('SECRET_SUMMARY_COMMANDLINE') }
                Assert-Ownership (-not $line.Contains('SECRET') -and -not $line.Contains('<Event') -and
                    -not $line.Contains('Execution')) 'Canonical summary leaked foreign/raw event data.'
            } -warningSink {
                param($line)
                $state.warnings++
                if ($Faults.Contains('warning')) { throw [IO.IOException]::new('SECRET_WARNING_COMMANDLINE') }
                Assert-Ownership (-not $line.Contains('SECRET')) 'Secondary warning leaked query/writer payload.'
            }
    } catch { $state.caught = $_ }
    Assert-Ownership ($state.caught -and [Object]::ReferenceEquals($state.caught.Exception, $original) -and
        $state.caught.Exception.Message -ceq 'shell exited with code -1073741502') 'Startup diagnostic changed the original exception instance.'
    return @{
        state = $state
        report = $state.caught.Exception.Data['OwnedStartupEvents']
        secondary = @($state.caught.Exception.Data['OwnedStartupEventDiagnostics'])
    }
}
Invoke-OwnershipCase 'canonical-owned-event' {
    $result = Invoke-StartupProbe @((New-OwnedEvent))
    Assert-Ownership ($result.state.queries -eq 1 -and $result.report.events.Count -eq 1 -and
        $result.report.events[0].module.value -ceq 'kernelbase.dll' -and $result.report.events[0].subjectPID -eq 5832 -and
        -not $result.report.rootCauseEstablished -and $result.report.providers[1].readCount -eq 0 -and
        $result.report.providers[2].readCount -eq 0) 'Canonical ownership was lost or an unproved provider/cause was substituted.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2060' 1 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'empty-query-is-unknown' {
    $result = Invoke-StartupProbe @()
    Assert-Ownership ($result.state.queries -eq 1 -and $result.report.events.Count -eq 0 -and
        $result.report.state -ceq 'unknown-no-matching-canonical-events') 'An executed empty query became passing startup/module evidence.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2068' 1 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'missing-optional-module-fields' {
    $record = New-OwnedEvent
    $record.Xml = $record.Xml.Replace('<Data Name="ModuleName">kernelbase.dll</Data>', '').Replace('<Data Name="ExceptionCode">0xc0000142</Data>', '')
    $result = Invoke-StartupProbe @($record)
    Assert-Ownership ($result.report.events.Count -eq 1 -and $result.report.events[0].module.state -ceq 'unavailable' -and
        $result.report.events[0].exceptionCode.state -ceq 'unavailable' -and $null -eq $result.report.events[0].module.value -and
        -not $result.report.rootCauseEstablished) 'Unavailable module/code was synthesized from the failing exit.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2074' 1 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'actual-no-match-error-record' {
    $state = @{ queries = 0; caught = $null }
    $original = [InvalidOperationException]::new('shell exited with code -1073741502')
    try {
        Invoke-MultiProjectOwnedStartupFailure $held -1073741502 $executable $ArtifactRoot { throw $original } -observedUtc $eventEnd `
            -querySource {
                param($filter, $maximum)
                $state.queries++
                throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('No events'), 'NoMatchingEventsFound',
                    [Management.Automation.ErrorCategory]::ObjectNotFound, $null)
            } -fileSink { param($path, $json) } -summarySink { param($line) } -warningSink { param($line) }
    } catch { $state.caught = $_ }
    Assert-Ownership ($state.queries -eq 1 -and [Object]::ReferenceEquals($state.caught.Exception, $original) -and
        $state.caught.Exception.Data['OwnedStartupEvents'].state -ceq 'unknown-no-matching-canonical-events') 'Actual no-match ErrorRecord changed primary or fabricated diagnosis.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2083' 1 @('held-identity-canonical-event-mock')
foreach ($mutation in @('foreign-pid', 'reused-pid', 'foreign-path', 'provider', 'outside-window', 'duplicate-id',
    'module-path', 'code-type', 'unnamed', 'execution-only', 'missing-generation', 'oversized', 'bad-xml', 'dtd')) {
    Invoke-OwnershipCase $mutation {
        $result = Invoke-StartupProbe @((New-OwnedEvent $mutation))
        Assert-Ownership ($result.state.queries -eq 1 -and $result.report.state -ceq 'refused-or-unavailable' -and
            $result.report.events.Count -eq 0 -and $result.secondary.Count -eq 1) 'Canonical event identity/schema/size refusal was weakened.'
    }
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2101' 14 @('held-identity-canonical-event-mock')
foreach ($mutation in @('missing-pid', 'missing-start', 'relative-path', 'old-window', 'future-start', 'unsafe-quotes')) {
    Invoke-OwnershipCase $mutation {
        $process = [pscustomobject]@{ Id = 5832; StartTime = $eventStart }
        $path = $executable
        switch ($mutation) {
            'missing-pid' { $process.Id = 0 }
            'missing-start' { $process.StartTime = $null }
            'relative-path' { $path = 'relative.exe' }
            'old-window' { $process.StartTime = $eventStart.AddSeconds(-31) }
            'future-start' { $process.StartTime = $eventEnd.AddSeconds(1) }
            'unsafe-quotes' { $path = 'D:\owned\a''"b.exe' }
        }
        $result = Invoke-StartupProbe @() $process $path
        Assert-Ownership ($result.state.queries -eq 0 -and $result.secondary.Count -eq 1 -and $result.report.events.Count -eq 0) 'An invalid held identity reached event transport.'
    }
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2109' 6 @('held-identity-canonical-event-mock')
foreach ($faults in @('query', 'file', 'summary', 'query-file-summary-warning')) {
    Invoke-OwnershipCase $faults {
        $result = Invoke-StartupProbe @((New-OwnedEvent)) -Faults $faults
        Assert-Ownership ($result.secondary.Count -eq $(if ($faults -ceq 'query-file-summary-warning') { 4 } else { 1 }) -and
            $result.state.queries -eq 1) 'A secondary writer/query failure was omitted.'
        foreach ($failure in $result.secondary) {
            Assert-Ownership ($failure.operation.StartsWith('startup-event') -and $failure.errorType -ceq 'System.IO.IOException' -and
                $failure.hresult -is [int] -and -not $failure.message.Contains('SECRET')) 'Typed privacy-preserving secondary failure metadata changed.'
        }
    }
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2126' 4 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'over-eight-records' {
    $record = New-OwnedEvent
    $result = Invoke-StartupProbe @($record, $record, $record, $record, $record, $record, $record, $record, $record)
    Assert-Ownership ($result.report.events.Count -eq 0 -and $result.secondary.Count -eq 1) 'Nine selected records were silently truncated.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2137' 1 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'duplicate-record-identity' {
    $record = New-OwnedEvent
    $result = Invoke-StartupProbe @($record, $record)
    Assert-Ownership ($result.report.events.Count -eq 0 -and $result.secondary.Count -eq 1) 'Duplicate event record identity inflated evidence.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2143' 1 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'non-hosted-default-transport-refused' {
    $snapshot = [Environment]::GetEnvironmentVariables('Process')
    $state = @{ queries = 0; caught = $null }
    function Get-WinEvent { $state.queries++; throw 'Forbidden actual event transport.' }
    $original = [InvalidOperationException]::new('shell exited with code -1073741502')
    try {
        $env:GITHUB_ACTIONS = 'false'
        try {
            Invoke-MultiProjectOwnedStartupFailure $held -1073741502 $executable $ArtifactRoot { throw $original } -observedUtc $eventEnd `
                -fileSink { param($path, $json) } -summarySink { param($line) } -warningSink { param($line) }
        } catch { $state.caught = $_ }
    } finally { Restore-OwnershipEnvironment $snapshot @('GITHUB_ACTIONS') }
    Assert-Ownership ($state.queries -eq 0 -and [Object]::ReferenceEquals($state.caught.Exception, $original) -and
        $state.caught.Exception.Data['OwnedStartupEvents'].state -ceq 'refused-non-hosted-query') 'Default EventLog transport ran outside hosted CI.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2149' 1 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'exact-path-xml-xpath-escaping' {
    $identity = New-MultiProjectStartupEventQuery $held "D:\owned\a'b&c.exe" $eventEnd
    $xml = [xml]$identity.filterXml
    Assert-Ownership ($xml.QueryList.Query.Select.InnerText.Contains('Data[@Name=''AppPath'']="D:\owned\a''b&c.exe"') -and
        $identity.filterXml.Contains('&amp;')) 'Exact executable XPath/XML escaping changed.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2165' 1 @('held-identity-canonical-event-mock')
Invoke-OwnershipCase 'actual-first-failure-branch' {
    $branch = $gate.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.StartsWith('if ($process.HasExited)', [StringComparison]::Ordinal) -and
            $node.Extent.Text.Contains('Invoke-MultiProjectOwnedStartupFailure')
    }, $true)
    Assert-Ownership ($null -ne $branch) 'Actual first-failure branch missing.'
    $process = [pscustomobject]@{ HasExited = $true; Id = 5832; ExitCode = -1073741502; StartTime = $eventStart }
    $Shell = $executable; $logDirectory = $ArtifactRoot; $settingsDirectory = $ArtifactRoot
    $state = @{ legacy = 0; canonical = 0; caught = $null }
    function Write-UiaStartupFailureDiagnostic { param($held, $exit, $exe, $cwd, $logs, $support) $state.legacy++ }
    function Invoke-MultiProjectOwnedStartupFailure {
        param($held, $exit, $exe, $logs, $failure)
        $state.canonical++
        & $failure
    }
    try { . ([scriptblock]::Create($branch.Extent.Text)) } catch { $state.caught = $_ }
    Assert-Ownership ($state.legacy -eq 1 -and $state.canonical -eq 1 -and
        $state.caught.Exception.Message -ceq 'shell exited with code -1073741502') 'Actual failure branch replayed diagnostics or changed the primary.'
}
Complete-OwnershipFamily 'ownership.mixed-startup.source-line-2173' 1 @('held-identity-canonical-event-mock')
if ($script:OwnershipAdapterFailed) { exit 1 }
