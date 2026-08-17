$ErrorActionPreference = "Stop"

$spike = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $spike "..\..\..")
$targetRoot = Join-Path $spike "Sources\GraphcodeWindowsContracts"

New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
$supportLink = Join-Path $targetRoot "SupportDirectory.swift"
$quickChatLink = Join-Path $targetRoot "QuickChatStore.swift"
foreach ($file in @($supportLink, $quickChatLink)) {
  if (Test-Path -LiteralPath $file) {
    Remove-Item -LiteralPath $file -Force
  }
}
$links = @{
  Domain = Join-Path $repo "GraphcodeKit\Sources\Domain"
  IPC = Join-Path $repo "GraphcodeKit\Sources\IPC"
  Platform = Join-Path $repo "GraphcodeKit\Sources\Platform"
}
foreach ($entry in $links.GetEnumerator()) {
  $link = Join-Path $targetRoot $entry.Key
  if (Test-Path $link) {
    Remove-Item $link -Force
  }
  New-Item -ItemType Junction -Path $link -Target $entry.Value | Out-Null
}
New-Item -ItemType HardLink `
  -Path $supportLink `
  -Target (Join-Path $repo "GraphcodeKit\Sources\SupportDirectory.swift") | Out-Null
New-Item -ItemType HardLink `
  -Path $quickChatLink `
  -Target (Join-Path $repo "GraphcodeKit\Sources\QuickChatStore.swift") | Out-Null
Write-Host "Linked Graphcode contract sources"
