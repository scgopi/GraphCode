param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = "Stop"
$loader = Join-Path $RepositoryRoot "Tools\windows\Import-CompiledValidationAssembly.ps1"
$source = Join-Path $RepositoryRoot "Tools\windows\ValidationFixtureDirectoryNative.cs"
$before = [IO.File]::ReadAllBytes($source)
$backup = Join-Path $ArtifactRoot ("provenance-source-" + [guid]::NewGuid().ToString("N") + ".before")
[IO.File]::WriteAllBytes($backup, $before)
function Write-ProvenanceCase([string] $Id, [string] $Evidence) {
  $row = [ordered]@{ id = $Id; status = "Passed"; executedCount = 1; evidence = $Evidence }
  Write-Output ("HOST_CASE_RESULT=" + ($row | ConvertTo-Json -Compress))
}
& $loader -AssemblyPath $AssemblyPath -RequiredType "GraphCode.ValidationFixtureDirectoryNative" | Out-Null
Write-ProvenanceCase "host.provenance.current-source" "Actual compiled source/reference fingerprints and file MVID admitted; native create not invoked"
try {
  $changed = [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($before) + "`n// Controlled stale-source contract.`n")
  [IO.File]::WriteAllBytes($source, $changed)
  $failure = $null
  try { & $loader -AssemblyPath $AssemblyPath -RequiredType "GraphCode.ValidationFixtureDirectoryNative" | Out-Null }
  catch { $failure = $_ }
  if ($null -eq $failure -or
      $failure.Exception.Message -cne "Compiled validation inputs changed after build; rebuild with Build-CompiledValidationRunner.ps1") {
    throw "Same-worktree source change was not refused before native binding use"
  }
  Write-ProvenanceCase "host.provenance.source-changed" "Actual same-worktree C# input changed without rebuilding; already-loaded same-path assembly refused"
} finally {
  [IO.File]::WriteAllBytes($source, $before)
}
if ((Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath $backup).Hash) {
  throw "Provenance negative control did not restore its exact owned source bytes"
}
& $loader -AssemblyPath $AssemblyPath -RequiredType "GraphCode.ValidationFixtureDirectoryNative" | Out-Null
Write-ProvenanceCase "host.provenance.source-restored" "Exact original source bytes restored; same binding admitted again; native create not invoked"
