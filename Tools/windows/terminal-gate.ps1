[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $WinghosttyRoot,
  [Parameter(Mandatory)]
  [string] $ZmxRoot,
  [string] $Zig0152 = "zig",
  [string] $Zig0160 = "zig",
  [switch] $SkipBuild,
  [switch] $Stress
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$gateRoot = Join-Path $repoRoot "investigation\spikes\windows-terminal-gate"
$pins = Get-Content (Join-Path $gateRoot "provider-pins.json") -Raw | ConvertFrom-Json
$app = Join-Path $gateRoot "zig-out\bin\graphcode-terminal-gate.exe"
$wingLib = Join-Path $WinghosttyRoot "zig-out\lib\winghostty-win32-host.lib"
$zmx = Join-Path $ZmxRoot "zig-out\bin\zmx.exe"

function Invoke-Native([string] $description, [scriptblock] $command) {
  Write-Host "==> $description"
  & $command
  if ($LASTEXITCODE -ne 0) {
    throw "$description failed with exit code $LASTEXITCODE"
  }
}

function Assert-Equal([string] $actual, [string] $expected, [string] $label) {
  if ($actual -ne $expected) {
    throw "$label expected $expected but found $actual"
  }
}

function Assert-HistoryContains([string] $name, [string] $marker, [string] $label) {
  $history = (& $zmx history $name --vt 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0 -or $history -notmatch [regex]::Escape($marker)) {
    throw "$label did not contain the persistent VT marker '$marker'"
  }
}

Assert-Equal (git -C $WinghosttyRoot rev-parse HEAD) $pins.winghostty.sha "Winghostty pin"
Assert-Equal (git -C $ZmxRoot rev-parse HEAD) $pins.zmx.sha "zmx pin"

try {
  if (-not $SkipBuild) {
    Invoke-Native "Winghostty host artifact" {
      Push-Location $WinghosttyRoot
      try { & $Zig0152 build -Demit-win32-host=true } finally { Pop-Location }
    }
    Invoke-Native "zmx Windows provider artifact" {
      Push-Location $ZmxRoot
      try { & $Zig0160 build -Dtarget=x86_64-windows-gnu } finally { Pop-Location }
    }
    Invoke-Native "GraphCode terminal gate" {
      Push-Location $gateRoot
      try {
        & $Zig0152 build `
          "-Dwinghostty-dir=$WinghosttyRoot" `
          "-Dwinghostty-lib=$wingLib" `
          -Doptimize=ReleaseSafe
      } finally { Pop-Location }
    }
  }

  if (-not (Test-Path $app)) { throw "terminal gate executable is missing: $app" }
  if (-not (Test-Path $zmx)) { throw "zmx executable is missing: $zmx" }

  $env:GRAPHCODE_ZMX = $zmx
  $env:GRAPHCODE_GATE_CWD = $repoRoot
  $names = @(
    "graphcode-terminal-gate-a",
    "graphcode-terminal-gate-b",
    "graphcode-terminal-gate-shared"
  )
  try {
    Invoke-Native "terminal gate first attach smoke" {
      & $app --smoke
    }
    Invoke-Native "first-session health" {
      & $zmx get graphcode-terminal-gate-a
      & $zmx get graphcode-terminal-gate-b
    }
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode typed output A" "typed A output"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode typed output B" "typed B output"
    Invoke-Native "seed persistent shell output" {
      & $zmx send graphcode-terminal-gate-a "echo GraphCode persistent VT output A`r"
      & $zmx send graphcode-terminal-gate-b "echo GraphCode persistent VT output B`r"
    }
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode persistent VT output A" "first-session A history"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode persistent VT output B" "first-session B history"
    Invoke-Native "terminal gate independent restart attach smoke" {
      & $app --smoke
    }
    Invoke-Native "restart-session health" {
      & $zmx get graphcode-terminal-gate-a
      & $zmx get graphcode-terminal-gate-b
    }
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode persistent VT output A" "restart A history"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode persistent VT output B" "restart B history"
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode typed output A" "restart typed A history"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode typed output B" "restart typed B history"
    Invoke-Native "terminal gate same-session attach smoke" {
      & $app --smoke --same-session
    }
    Invoke-Native "same-session health" {
      & $zmx get graphcode-terminal-gate-shared
    }
    Invoke-Native "seed shared persistent shell output" {
      & $zmx send graphcode-terminal-gate-shared "echo GraphCode shared VT output`r"
    }
    Assert-HistoryContains "graphcode-terminal-gate-shared" `
      "GraphCode shared VT output" "same-session history"
    Invoke-Native "terminal gate same-session restart smoke" {
      & $app --smoke --same-session
    }
    Assert-HistoryContains "graphcode-terminal-gate-shared" `
      "GraphCode shared VT output" "same-session restart history"
    if ($Stress) {
      Invoke-Native "terminal gate destroy/recreate stress" {
        & $app --smoke --stress
      }
      Invoke-Native "post-stress session health" {
        & $zmx get graphcode-terminal-gate-a
        & $zmx get graphcode-terminal-gate-b
      }
    }
    Write-Host "Windows terminal gate smoke/stress: PASS"
  }
  finally {
    foreach ($name in $names) {
      & $zmx kill $name *> $null
    }
  }
}
finally {
  Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue
  Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue
}

exit 0
