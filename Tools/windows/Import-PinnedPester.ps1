& {
  $loaded = @(Get-Module -Name Pester)
  $pester = $loaded |
    Where-Object { $_.Version.Major -eq 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if ($null -eq $pester) {
    $pester = Get-Module -ListAvailable -Name Pester |
      Where-Object { $_.Version.Major -eq 5 } |
      Sort-Object Version -Descending |
      Select-Object -First 1
  }
  if ($null -eq $pester) {
    throw ('Pester 5.x is required; other major versions are unsupported. ' +
      'Save-Module Pester -RequiredVersion 5.7.1 -Path .\.graphcode-tools\modules; ' +
      'then prepend that directory to PSModulePath in this process and rerun. ' +
      'No modules were installed automatically.')
  }

  if ($loaded | Where-Object { $_.Version.Major -ne 5 }) {
    throw ('Pester 5.x is required, but another major is already loaded. ' +
      'Start a fresh pwsh -NoProfile process and load Import-PinnedPester.ps1 ' +
      'before invoking Pester; incompatible Pester assemblies cannot be replaced safely.')
  }

  # Do not force a reload while a test file is being discovered by Pester 5.
  Import-Module -ModuleInfo $pester -Global -ErrorAction Stop
}
