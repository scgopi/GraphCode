. (Join-Path $PSScriptRoot "SourceReader.ps1")

function Invoke-CandidateAdmissionGit([string] $Repository, [string[]] $Arguments) {
  $output = @(& git -C $Repository @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Candidate admission git -C '$Repository' $($Arguments -join ' ') failed: $($output -join '; ')"
  }
  return $output
}

function Get-CandidateAdmissionFileRecord([string] $Kind, [string] $Path, [string] $RelativeRoot) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "Candidate admission $Kind file is missing: $fullPath"
  }
  $relative = [IO.Path]::GetRelativePath($RelativeRoot, $fullPath).Replace('\', '/')
  return [ordered]@{
    kind = $Kind
    path = $fullPath
    relativePath = $relative
    length = [IO.FileInfo]::new($fullPath).Length
    sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
  }
}

function Get-CandidateAdmissionRepositoryRecord([string] $Name, [string] $Path, [switch] $RequireClean) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath (Join-Path $fullPath ".git"))) {
    throw "Candidate admission $Name is not a Git worktree: $fullPath"
  }
  $head = [string](Invoke-CandidateAdmissionGit $fullPath @("rev-parse", "HEAD") |
      Select-Object -Last 1)
  $tree = [string](Invoke-CandidateAdmissionGit $fullPath @("rev-parse", "HEAD^{tree}") |
      Select-Object -Last 1)
  $status = @(Invoke-CandidateAdmissionGit $fullPath @(
      "status", "--porcelain=v1", "--untracked-files=all"
    ))
  if ($RequireClean -and $status.Count -ne 0) {
    throw "Candidate admission $Name worktree is dirty: $($status -join '; ')"
  }
  [ordered]@{
    name = $Name
    path = $fullPath
    head = $head
    tree = $tree
    status = $status
  }
}

function Assert-WindowsShellCandidateEnvironment {
  $environment = [Environment]::GetEnvironmentVariables('Process')
  foreach ($name in @(
      'GRAPHCODE_UIA_GATE',
      'GRAPHCODE_UIA_SUPERVISED_FOREGROUND',
      'GRAPHCODE_UIA_EDGE_ACTION_TRACE'
    )) {
    if ($environment.Contains($name)) {
      throw "Candidate admission requires $name to be absent before Windows shell validation."
    }
  }
  if ($environment.Contains('GRAPHCODE_VALIDATION_ASSEMBLY')) {
    $assembly = [Environment]::GetEnvironmentVariable('GRAPHCODE_VALIDATION_ASSEMBLY', 'Process')
    if ([string]::IsNullOrEmpty($assembly) -or
        -not [IO.Path]::IsPathFullyQualified($assembly) -or
        -not (Test-Path -LiteralPath $assembly -PathType Leaf)) {
      throw "GRAPHCODE_VALIDATION_ASSEMBLY has an explicitly empty or invalid candidate binding."
    }
  }
}

function Assert-WindowsShellValidationRootsFresh([string] $Parent) {
  $fullParent = [IO.Path]::GetFullPath($Parent)
  if (-not (Test-Path -LiteralPath $fullParent -PathType Container)) { return }
  $stale = @(Get-ChildItem -LiteralPath $fullParent -Force |
      Where-Object { $_.Name -cmatch '^[0-9a-f]{32}$' } |
      Sort-Object Name)
  if ($stale.Count -ne 0) {
    throw "Candidate admission found stale Windows shell validation root(s): " +
      (($stale | ForEach-Object FullName) -join ', ')
  }
}

function Get-WindowsShellCandidateManifestPaths([string] $WorkspaceRoot) {
  $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
  $paths = [Collections.Generic.List[string]]::new()
  foreach ($relative in @(
      'graphcode-windows\provider-pins.json',
      'graphcode-windows\build.zig.zon',
      'graphcode-windows\build.zig',
      'Tools\windows\ValidationRunner\ValidationRunner.csproj'
    )) {
    $paths.Add([IO.Path]::GetFullPath((Join-Path $workspace $relative)))
  }
  $manifestRoot = Join-Path $workspace 'Tools\windows\ValidationRunner\Manifests'
  foreach ($manifest in Get-ChildItem -LiteralPath $manifestRoot -Filter '*.json' -File |
      Sort-Object FullName) {
    $paths.Add($manifest.FullName)
  }
  return @($paths | Sort-Object -Unique)
}

function Get-CandidateAdmissionPaths([object[]] $Paths) {
  $normalized = [Collections.Generic.List[string]]::new()
  $pending = [Collections.Generic.Queue[object]]::new()
  foreach ($path in @($Paths)) { $pending.Enqueue($path) }
  while ($pending.Count -ne 0) {
    $candidate = $pending.Dequeue()
    if ($candidate -is [string]) {
      if ([string]::IsNullOrEmpty($candidate) -or $candidate -match "[`r`n]") {
        throw 'Candidate admission paths must be nonempty scalar strings without embedded line endings.'
      }
      $normalized.Add($candidate)
      continue
    }
    if ($candidate -is [Collections.IEnumerable]) {
      foreach ($entry in $candidate) { $pending.Enqueue($entry) }
      continue
    }
    throw "Candidate admission path collection contains an unsupported value of type '$($candidate.GetType().FullName)'."
  }
  return @($normalized | Sort-Object -Unique)
}

function Get-CandidateAdmissionFileRecords(
  [Parameter(Mandatory)][string] $Kind,
  [Parameter(Mandatory)][object[]] $Paths,
  [Parameter(Mandatory)][string] $RelativeRoot
) {
  $records = [Collections.Generic.List[object]]::new()
  foreach ($path in @(Get-CandidateAdmissionPaths -Paths $Paths)) {
    $records.Add((Get-CandidateAdmissionFileRecord `
      -Kind $Kind `
      -Path ([string]$path) `
      -RelativeRoot $RelativeRoot))
  }
  return $records.ToArray()
}

function Write-WindowsShellCandidateAdmission(
  [Parameter(Mandatory)][string] $WorkspaceRoot,
  [Parameter(Mandatory)][string] $ValidationRoot,
  [Parameter(Mandatory)][object[]] $BindingPaths,
  [Parameter(Mandatory)][string] $WinghosttyRoot,
  [Parameter(Mandatory)][string] $ZmxRoot,
  [Parameter(Mandatory)][string] $Zig0152,
  [Parameter(Mandatory)][string] $Zig0160,
  [object[]] $ManifestPaths = @(),
  [object[]] $SourcePaths = @()
) {
  Assert-WindowsShellCandidateEnvironment
  $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
  $validation = [IO.Path]::GetFullPath($ValidationRoot)
  $processEnvironment = [Environment]::GetEnvironmentVariables('Process')
  $environment = [ordered]@{}
  foreach ($name in @(
      'GRAPHCODE_UIA_GATE',
      'GRAPHCODE_UIA_SUPERVISED_FOREGROUND',
      'GRAPHCODE_UIA_EDGE_ACTION_TRACE',
      'GRAPHCODE_VALIDATION_ASSEMBLY'
    )) {
    $environment[$name] = [ordered]@{
      present = $processEnvironment.Contains($name)
      value = if ($processEnvironment.Contains($name)) {
        [Environment]::GetEnvironmentVariable($name, 'Process')
      } else { $null }
    }
  }
  $pinsPath = Join-Path $workspace 'graphcode-windows\provider-pins.json'
  if (-not (Test-Path -LiteralPath $pinsPath -PathType Leaf)) {
    throw "Candidate admission provider pin manifest is missing: $pinsPath"
  }
  $pins = Read-SemanticSource $pinsPath | ConvertFrom-Json -Depth 20 -ErrorAction Stop
  $repository = Get-CandidateAdmissionRepositoryRecord 'workspace' $workspace
  $winghostty = Get-CandidateAdmissionRepositoryRecord 'winghostty' $WinghosttyRoot -RequireClean
  $zmx = Get-CandidateAdmissionRepositoryRecord 'zmx' $ZmxRoot -RequireClean
  if ($winghostty.head -cne [string]$pins.winghostty.sha -or
      $zmx.head -cne [string]$pins.zmx.sha) {
    throw 'Candidate admission provider worktrees do not match graphcode-windows\provider-pins.json.'
  }

  $allManifestPaths = @(Get-CandidateAdmissionPaths -Paths @($ManifestPaths, $pinsPath))
  $allSourcePaths = @(Get-CandidateAdmissionPaths -Paths $SourcePaths)
  $allBindingPaths = @(Get-CandidateAdmissionPaths -Paths $BindingPaths)
  $tools = @(
    (Get-CandidateAdmissionFileRecord 'zig-0.15.2' $Zig0152 $workspace),
    (Get-CandidateAdmissionFileRecord 'zig-0.16.0' $Zig0160 $workspace)
  )
  $bindings = @(Get-CandidateAdmissionFileRecords `
      -Kind 'validation-binding' -Paths $allBindingPaths -RelativeRoot $workspace)
  $manifests = @(Get-CandidateAdmissionFileRecords `
      -Kind 'manifest' -Paths $allManifestPaths -RelativeRoot $workspace)
  $sources = @(Get-CandidateAdmissionFileRecords `
      -Kind 'source' -Paths $allSourcePaths -RelativeRoot $workspace)
  if ($bindings.Count -eq 0 -or $manifests.Count -eq 0 -or $sources.Count -eq 0) {
    throw 'Candidate admission requires binding, manifest and source hashes.'
  }
  $record = [ordered]@{
    schemaVersion = 1
    environment = $environment
    validationRoot = $validation
    repository = $repository
    providers = [ordered]@{
      winghostty = $winghostty
      zmx = $zmx
    }
    tools = $tools
    bindings = $bindings
    manifests = $manifests
    sources = $sources
  }
  $path = Join-Path $validation 'candidate-admission.json'
  $json = $record | ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($path, $json + "`n", [Text.UTF8Encoding]::new($false))
  [pscustomobject]@{
    Path = $path
    Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Json = $json
  }
}
