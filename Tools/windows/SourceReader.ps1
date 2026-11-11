function ConvertTo-SemanticSourceText([string] $Source) {
  return $Source.Replace("`r`n", "`n")
}

function Read-SemanticSource([string] $Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $bytes = [IO.File]::ReadAllBytes($fullPath)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and
      $bytes[2] -eq 0xBF) {
    throw [IO.InvalidDataException]::new("Semantic source must be UTF-8 without BOM: $fullPath")
  }
  $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  return ConvertTo-SemanticSourceText $text
}
