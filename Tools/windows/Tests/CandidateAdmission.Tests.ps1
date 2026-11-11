[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Import-PinnedPester.ps1')

Describe 'Windows validation candidate admission' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    . (Join-Path $repoRoot 'Tools\windows\CandidateAdmission.ps1')
    . (Join-Path $repoRoot 'Tools\windows\SourceReader.ps1')

    function New-AdmissionRepository([string] $Path, [hashtable] $Files) {
      $null = New-Item -ItemType Directory -Force -Path $Path
      git -C $Path init --initial-branch=main | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'fixture git init failed' }
      git -C $Path config user.name 'Admission Fixture' | Out-Null
      git -C $Path config user.email 'admission@example.invalid' | Out-Null
      foreach ($entry in $Files.GetEnumerator()) {
        $file = Join-Path $Path $entry.Key
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent)
        [IO.File]::WriteAllText($file, [string] $entry.Value, [Text.UTF8Encoding]::new($false))
      }
      git -C $Path add --all | Out-Null
      git -C $Path commit -m fixture | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'fixture git commit failed' }
      [pscustomobject]@{
        Head = ((git -C $Path rev-parse HEAD) | Select-Object -Last 1).Trim()
        Tree = ((git -C $Path rev-parse 'HEAD^{tree}') | Select-Object -Last 1).Trim()
      }
    }
  }

  BeforeEach {
    $environmentNames = @(
      'GRAPHCODE_UIA_GATE',
      'GRAPHCODE_UIA_SUPERVISED_FOREGROUND',
      'GRAPHCODE_UIA_EDGE_ACTION_TRACE',
      'GRAPHCODE_VALIDATION_ASSEMBLY'
    )
    $savedEnvironment = @{}
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $environmentNames) {
      $savedEnvironment[$name] = [ordered]@{
        Present = $environment.Contains($name)
        Value = [Environment]::GetEnvironmentVariable($name, 'Process')
      }
      Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
    }
  }

  AfterEach {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
      if ($entry.Value.Present) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value.Value, 'Process')
      } elseif ([Environment]::GetEnvironmentVariables('Process').Contains($entry.Key)) {
        Remove-Item -LiteralPath "Env:\$($entry.Key)" -ErrorAction Stop
      }
    }
  }

  It 'admits only the explicit outer environment membership contract' {
    { Assert-WindowsShellCandidateEnvironment } | Should -Not -Throw
    $assembly = Join-Path $TestDrive 'validation.dll'
    [IO.File]::WriteAllBytes($assembly, [byte[]](1, 2, 3))
    $env:GRAPHCODE_VALIDATION_ASSEMBLY = $assembly
    { Assert-WindowsShellCandidateEnvironment } | Should -Not -Throw
    $env:GRAPHCODE_VALIDATION_ASSEMBLY = ''
    { Assert-WindowsShellCandidateEnvironment } | Should -Throw '*explicitly empty*'
    Remove-Item Env:\GRAPHCODE_VALIDATION_ASSEMBLY

    foreach ($name in @(
        'GRAPHCODE_UIA_GATE',
        'GRAPHCODE_UIA_SUPERVISED_FOREGROUND',
        'GRAPHCODE_UIA_EDGE_ACTION_TRACE'
      )) {
      [Environment]::SetEnvironmentVariable($name, '', 'Process')
      { Assert-WindowsShellCandidateEnvironment } | Should -Throw "*$name*absent*"
      Remove-Item -LiteralPath "Env:\$name" -ErrorAction Stop
    }
  }

  It 'refuses stale validation roots without deleting them' {
    $parent = Join-Path $TestDrive 'validation-roots'
    $stale = Join-Path $parent '0123456789abcdef0123456789abcdef'
    $unrelated = Join-Path $parent 'operator-notes'
    $null = New-Item -ItemType Directory -Force -Path $stale,$unrelated
    { Assert-WindowsShellValidationRootsFresh -Parent $parent } |
      Should -Throw '*stale Windows shell validation root*'
    Test-Path -LiteralPath $stale | Should -BeTrue
    Remove-Item -LiteralPath $stale -Recurse -Force
    { Assert-WindowsShellValidationRootsFresh -Parent $parent } | Should -Not -Throw
  }

  It 'captures exact deterministic repository, provider, tool, binding and manifest identities' {
    $winghostty = New-AdmissionRepository (Join-Path $TestDrive 'winghostty') @{
      'provider.txt' = 'winghostty'
    }
    $zmx = New-AdmissionRepository (Join-Path $TestDrive 'zmx') @{
      'provider.txt' = 'zmx'
    }
    $pins = [ordered]@{
      winghostty = [ordered]@{ sha = $winghostty.Head }
      zmx = [ordered]@{ sha = $zmx.Head }
    } | ConvertTo-Json -Compress
    $workspace = Join-Path $TestDrive 'workspace'
    $candidate = New-AdmissionRepository $workspace @{
      'src\candidate.cs' = "namespace Fixture {}`n"
      'graphcode-windows\provider-pins.json' = $pins
      'graphcode-windows\build.zig.zon' = ".{ .name = .fixture }`n"
      'Tools\windows\validate.ps1' = "Write-Output 'fixture'`n"
    }
    $binding = Join-Path $workspace 'binding\ValidationFixtureBindings.dll'
    $zig0152 = Join-Path $workspace 'tools\zig-0.15.2\zig.exe'
    $zig0160 = Join-Path $workspace 'tools\zig-0.16.0\zig.exe'
    $section = Join-Path $workspace 'manifest\sections.json'
    foreach ($file in @($binding, $zig0152, $zig0160, $section)) {
      $null = New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent)
    }
    [IO.File]::WriteAllBytes($binding, [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes($zig0152, [byte[]](2, 3, 4))
    [IO.File]::WriteAllBytes($zig0160, [byte[]](3, 4, 5))
    [IO.File]::WriteAllText($section, '{"section":"fixture"}', [Text.UTF8Encoding]::new($false))
    $validationRoot = Join-Path $TestDrive 'validation-root'
    $null = New-Item -ItemType Directory -Path $validationRoot
    $arguments = @{
      WorkspaceRoot = $workspace
      ValidationRoot = $validationRoot
      BindingPaths = @($binding)
      WinghosttyRoot = (Join-Path $TestDrive 'winghostty')
      ZmxRoot = (Join-Path $TestDrive 'zmx')
      Zig0152 = $zig0152
      Zig0160 = $zig0160
      ManifestPaths = @(
        (Join-Path $workspace 'graphcode-windows\provider-pins.json'),
        $section
      )
      SourcePaths = @(
        (Join-Path $workspace 'Tools\windows\validate.ps1'),
        (Join-Path $workspace 'src\candidate.cs')
      )
    }

    $first = Write-WindowsShellCandidateAdmission @arguments
    $firstBytes = [IO.File]::ReadAllBytes($first.Path)
    if ($firstBytes.Length -ge 3) {
      ($firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF) |
        Should -BeFalse
    }
    $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($firstBytes) |
      ConvertFrom-Json -Depth 20
    $manifest.repository.head | Should -BeExactly $candidate.Head
    $manifest.repository.tree | Should -BeExactly $candidate.Tree
    $manifest.environment.GRAPHCODE_UIA_GATE.present | Should -BeFalse
    $manifest.environment.GRAPHCODE_UIA_SUPERVISED_FOREGROUND.present | Should -BeFalse
    $manifest.environment.GRAPHCODE_UIA_EDGE_ACTION_TRACE.present | Should -BeFalse
    $manifest.environment.GRAPHCODE_VALIDATION_ASSEMBLY.present | Should -BeFalse
    $manifest.providers.winghostty.head | Should -BeExactly $winghostty.Head
    $manifest.providers.zmx.tree | Should -BeExactly $zmx.Tree
    @($manifest.tools).Count | Should -Be 2
    @($manifest.bindings).Count | Should -Be 1
    @($manifest.manifests).Count | Should -Be 2
    @($manifest.sources).Count | Should -Be 2
    ($first.Sha256 -cmatch '^[A-F0-9]{64}$') | Should -BeTrue

    Remove-Item -LiteralPath $first.Path -Force
    $second = Write-WindowsShellCandidateAdmission @arguments
    $second.Sha256 | Should -BeExactly $first.Sha256
    [IO.File]::ReadAllBytes($second.Path) | Should -HaveCount $firstBytes.Length
  }
}

Describe 'Semantic source reader' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    . (Join-Path $repoRoot 'Tools\windows\SourceReader.ps1')
  }

  It 'normalizes LF and CRLF at the semantic boundary without rewriting raw bytes' {
    $file = Join-Path $TestDrive 'source.cs'
    $lf = "first`nsecond`n"
    $crlf = $lf.Replace("`n", "`r`n")
    [IO.File]::WriteAllText($file, $crlf, [Text.UTF8Encoding]::new($false))
    $raw = [IO.File]::ReadAllBytes($file)
    (Read-SemanticSource -Path $file) | Should -BeExactly $lf
    ConvertTo-SemanticSourceText $crlf | Should -BeExactly $lf
    ([IO.File]::ReadAllBytes($file) -join ',') | Should -BeExactly ($raw -join ',')
  }

  It 'refuses BOM and malformed UTF-8 semantic source' {
    $file = Join-Path $TestDrive 'invalid-source.cs'
    [IO.File]::WriteAllBytes($file, [byte[]](0xEF, 0xBB, 0xBF, 0x61))
    { Read-SemanticSource -Path $file } | Should -Throw '*BOM*'
    [IO.File]::WriteAllBytes($file, [byte[]](0xC3, 0x28))
    { Read-SemanticSource -Path $file } | Should -Throw
  }
}
