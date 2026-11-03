param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = "Stop"
$root = Join-Path ([IO.Path]::GetTempPath()) ("providers-" + [guid]::NewGuid().ToString("N").Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$compiler = Join-Path $root "compiler.cmd"
$executable = [IO.Path]::ChangeExtension($AssemblyPath, ".exe")
[IO.File]::WriteAllText($compiler, '@"' + $executable + '" --host-fixture provider-compiler %*' + "`r`n",
  [Text.ASCIIEncoding]::new())
$pins = [ordered]@{ schemaVersion = 1 }
foreach ($provider in @("winghostty", "zmx")) {
  $path = Join-Path $root $provider
  [void][IO.Directory]::CreateDirectory($path)
  & git -C $path init --quiet
  if ($LASTEXITCODE -ne 0) { throw "Controlled provider Git init failed" }
  & git -C $path config core.autocrlf false
  if ($LASTEXITCODE -ne 0) { throw "Controlled provider Git line-ending isolation failed" }
  [IO.File]::WriteAllText((Join-Path $path ".gitignore"), "zig-out/`n", [Text.UTF8Encoding]::new($false))
  & git -C $path add .gitignore
  & git -C $path -c user.name=ValidationFixture -c user.email=validation@example.invalid commit --quiet -s `
    -m "Pin controlled provider fixture" -m "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
  if ($LASTEXITCODE -ne 0) { throw "Controlled provider Git pin failed" }
  $sha = & git -C $path rev-parse HEAD
  if ($LASTEXITCODE -ne 0) { throw "Controlled provider Git revision failed" }
  $pins[$provider] = [ordered]@{ sha = $sha }
}
$pinsPath = Join-Path $root "pins.json"
$pins | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pinsPath
$providerScript = Join-Path $RepositoryRoot "Tools\windows\provider-build.ps1"
$pwsh = [Environment]::ProcessPath
$executed = 0
function Invoke-CompilerCase([string] $Behavior = "") {
  foreach ($provider in @("winghostty", "zmx")) {
    $generated = Join-Path $root "$provider\zig-out"
    if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Recurse -Force }
  }
  $log = Join-Path $root ("compiler-" + [guid]::NewGuid().ToString("N") + ".jsonl")
  $env:GRAPHCODE_PROVIDER_COMPILER_LOG = $log
  $env:GRAPHCODE_PROVIDER_COMPILER_BEHAVIOR = $Behavior
  $output = @(& $pwsh -NoLogo -NoProfile -NonInteractive -File $providerScript `
      -WinghosttyRoot (Join-Path $root "winghostty") -ZmxRoot (Join-Path $root "zmx") `
      -Zig0152 $compiler -Zig0160 $compiler -PinsPath $pinsPath -ZmxAttempts 1 2>&1 |
    ForEach-Object { "$_" })
  $exit = $LASTEXITCODE
  $calls = if (Test-Path -LiteralPath $log) { @([IO.File]::ReadAllLines($log)) } else { @() }
  return [pscustomobject]@{ exit = $exit; output = $output; calls = $calls }
}
function Assert-Provider([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw "Controlled provider-build contract: $Message" }
}
$pass = Invoke-CompilerCase
Assert-Provider ($pass.exit -eq 0 -and $pass.calls.Count -eq 2 -and
  @($pass.output | Where-Object { $_ -ceq "PROVIDER_BUILD_EXECUTED=2" }).Count -eq 1 -and
  @($pass.output | Where-Object { $_ -like "PROVIDER_BUILD_STEP=*" }).Count -eq 2) "complete two-provider build not counted exactly"
Assert-Provider ($pass.calls[0] -ceq '["build","-Demit-win32-host=true"]' -and
  $pass.calls[1] -ceq '["build","-Dtarget=x86_64-windows-gnu"]') "canonical flags changed"
Assert-Provider (($pass.output -join "`n") -notmatch '(?i)terminal gate|smoke|TerminalGate\.Tests|zmx send|uia') `
  "build-only provider script dispatched a terminal test"
$executed++
foreach ($behavior in @("missing", "fail")) {
  $actual = Invoke-CompilerCase $behavior
  Assert-Provider ($actual.exit -ne 0 -and
    @($actual.output | Where-Object { $_ -like "PROVIDER_BUILD_EXECUTED=*" }).Count -eq 0) "partial compiler result admitted: $behavior"
  $executed++
}
$dirty = Join-Path $root "zmx\dirty.txt"
[IO.File]::WriteAllText($dirty, "controlled untracked source")
$actual = Invoke-CompilerCase
Assert-Provider ($actual.exit -ne 0 -and $actual.calls.Count -eq 0) "dirty provider compiled"
Remove-Item -LiteralPath $dirty
$executed++
$pins.zmx.sha = "0" * 40
$pins | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pinsPath
$actual = Invoke-CompilerCase
Assert-Provider ($actual.exit -ne 0 -and $actual.calls.Count -eq 0) "unpinned provider compiled"
$executed++
Assert-Provider ($executed -eq 5) "not all actual production dispatch controls ran"
$row = [ordered]@{
  id = "host.provider-build"; status = "Passed"; executedCount = $executed
  evidence = "Actual provider-build.ps1 with ordinary compiled controlled compiler; two canonical flags, partial/error/dirty/wrong-pin controls"
}
Write-Output ("HOST_CASE_RESULT=" + ($row | ConvertTo-Json -Compress))
