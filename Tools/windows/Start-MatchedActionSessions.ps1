param(
    [Parameter(Mandatory)][string]$ZmxPath,
    [Parameter(Mandatory)][string]$SessionManifestPath
)
$ErrorActionPreference='Stop'
$manifest=Get-Content -LiteralPath $SessionManifestPath -Raw | ConvertFrom-Json -DateKind String
if ($manifest.schemaVersion -ne 1 -or $manifest.sessions.Count -lt 1 -or
    @($manifest.sessions | Sort-Object -Unique).Count -ne $manifest.sessions.Count) {
    throw 'Matched action session manifest is invalid.'
}
$cmd=Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
foreach ($session in @($manifest.sessions)) {
    if ([string]$session -cnotmatch '^graphcode-(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|s-after-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
        throw 'Matched action session identity is outside the frozen fixture namespace.'
    }
    & $ZmxPath run $session -d $cmd /Q /K "echo Offline action fixture $session"
    if ($LASTEXITCODE -ne 0) {
        throw "Pinned zmx failed to seed matched action session $session."
    }
}
