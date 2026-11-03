[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Root,
    [Parameter(Mandatory)][string] $Mode,
    [switch] $Descendant
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ($Descendant) {
    [IO.File]::WriteAllText((Join-Path $Root 'descendant-ready'), 'ready')
    [Threading.Thread]::Sleep(30000)
    exit 0
}
[Threading.Thread]::Sleep(300)
[IO.File]::WriteAllText((Join-Path $Root 'console-context.json'), (@{
    processId = $PID
    stdoutRedirected = [Console]::IsOutputRedirected
    stderrRedirected = [Console]::IsErrorRedirected
    stdoutStreamType = [Console]::OpenStandardOutput().GetType().FullName
    stderrStreamType = [Console]::OpenStandardError().GetType().FullName
} | ConvertTo-Json -Compress))
[Console]::Out.WriteLine('owned-capture-stdout')
[Console]::Error.WriteLine('owned-capture-stderr')
if ($Mode -in @('inherited', 'inherited-timeout', 'tree')) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Root', $Root, '-Mode', $Mode, '-Descendant')) {
        $start.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($start)
    try {
        [IO.File]::WriteAllText((Join-Path $Root 'descendant.json'), (@{
            pid = $child.Id
            startUtcTicks = $child.StartTime.ToUniversalTime().Ticks
        } | ConvertTo-Json -Compress))
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists((Join-Path $Root 'descendant-ready'))) {
            if ($deadline.ElapsedMilliseconds -ge 5000) { throw 'Controlled descendant was not ready within its original deadline.' }
            [Threading.Thread]::Sleep(10)
        }
    } finally { $child.Dispose() }
}
[IO.File]::WriteAllText((Join-Path $Root 'ready'), 'ready')
if ($Mode -in @('stop', 'timeout', 'tree')) { [Threading.Thread]::Sleep(30000) }
if ($Mode -ceq 'abrupt') { exit 23 }
