$ErrorActionPreference = "Stop"

$spike = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $spike "..\..\..")
$sources = Join-Path $spike "Sources"
$link = Join-Path $sources "GraphcodePortableDomain"
$target = Join-Path $repo "GraphcodeKit\Sources\Domain"

New-Item -ItemType Directory -Force -Path $sources | Out-Null
if (Test-Path $link) {
  Remove-Item $link
}
New-Item -ItemType Junction -Path $link -Target $target | Out-Null
Write-Host "Linked $link -> $target"
