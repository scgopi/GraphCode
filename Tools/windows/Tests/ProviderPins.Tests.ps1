[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$contract = Join-Path $PSScriptRoot "TerminalGate.Tests.ps1"
$productPath = Join-Path $repoRoot "graphcode-windows\provider-pins.json"
$gatePath = Join-Path $repoRoot "investigation\spikes\windows-terminal-gate\provider-pins.json"
$fixture = Join-Path $repoRoot ".build\provider-pin-contract-$([guid]::NewGuid())"
$pwsh = (Get-Process -Id $PID).Path

function Test-Pins([string] $label, [scriptblock] $mutate, [string] $failure) {
  $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json -AsHashtable
  $gate = Get-Content -LiteralPath $gatePath -Raw | ConvertFrom-Json -AsHashtable
  & $mutate $product $gate
  $product | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $fixture "product.json")
  $gate | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $fixture "gate.json")
  $output = & $pwsh -NoProfile -File $contract `
    -ProductPinsPath (Join-Path $fixture "product.json") `
    -GatePinsPath (Join-Path $fixture "gate.json") 2>&1 | Out-String
  if ($failure) {
    if ($LASTEXITCODE -eq 0) { throw "RED: $label was accepted" }
    if ($output -notmatch [regex]::Escape($failure)) {
      throw "$label failed for the wrong reason: $output"
    }
  } elseif ($LASTEXITCODE -ne 0) {
    throw "$label did not pass: $output"
  }
}

try {
  New-Item -ItemType Directory -Path $fixture | Out-Null
  foreach ($provider in @("winghostty", "zmx")) {
    foreach ($field in @("repository", "remoteUrl", "sha", "artifact", "minimumZig")) {
      foreach ($side in @("product", "gate")) {
        Test-Pins "$side $provider.$field drift" {
          param($product, $gate)
          $pins = if ($side -eq "product") { $product } else { $gate }
          $pins[$provider][$field] += "-drift"
        } "provider pins differ: $provider.$field"
      }
    }
    Test-Pins "$provider missing field" {
      param($product, $gate)
      $gate[$provider].Remove("artifact")
    } "provider pins differ: $provider.artifact"
    Test-Pins "$provider additional field" {
      param($product, $gate)
      $product[$provider].newPinField = "future-value"
    } "provider pins differ: $provider.newPinField"
    Test-Pins "$provider field type" {
      param($product, $gate)
      $product[$provider].minimumZig = 152
    } "provider pins differ: $provider.minimumZig"
  }
  Test-Pins "schema drift" {
    param($product, $gate)
    $product.schemaVersion = 2
  } "provider pin schemas differ"
  foreach ($rejectedSha in @(
      "029e11d2b19162fb3bdf90c8270237d303b8bfb4",
      "56caff0df61b122c89633e6ad39b8f2c1aafba11"
    )) {
    Test-Pins "matching unaccepted zmx SHA $rejectedSha" {
      param($product, $gate)
      $product.zmx.sha = $rejectedSha
      $gate.zmx.sha = $rejectedSha
    } "zmx SHA is not exact"
  }
  Test-Pins "matching sources" { param($product, $gate) } ""
  Test-Pins "order and explanatory metadata" {
    param($product, $gate)
    $reordered = [ordered]@{}
    @($product.winghostty.Keys) | Sort-Object -Descending | ForEach-Object {
      $reordered[$_] = $product.winghostty[$_]
    }
    $product.winghostty = $reordered
    $product.localFallback.reason = "different explanatory wording"
  } ""
  Write-Output "Provider pin no-divergence contracts: PASS"
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force
}
