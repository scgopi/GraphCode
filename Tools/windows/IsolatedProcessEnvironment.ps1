$ErrorActionPreference = "Stop"

function Get-IsolatedExpectedEnvironment {
  [CmdletBinding()]
  param([Parameter(Mandatory)] [pscustomobject] $Expected)

  $names = @(
    "SystemRoot", "WINDIR", "SystemDrive", "COMSPEC", "PATHEXT", "PATH", "PSModulePath",
    "TEMP", "TMP", "HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "DOTNET_ROOT",
    "DOTNET_ROOT_X64", "DOTNET_MULTILEVEL_LOOKUP", "DOTNET_ROLL_FORWARD", "DOTNET_CLI_HOME",
    "DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "DOTNET_CLI_TELEMETRY_OPTOUT", "DOTNET_NOLOGO",
    "DOTNET_BUNDLE_EXTRACT_BASE_DIR", "NUGET_PACKAGES", "NUGET_HTTP_CACHE_PATH",
    "NUGET_PLUGINS_CACHE_PATH", "PSModuleAnalysisCachePath", "PS_DISABLE_MODULE_ANALYSIS_CACHE",
    "POWERSHELL_TELEMETRY_OPTOUT", "XDG_CACHE_HOME", "MSBUILDUSEREXTENSIONSPATH"
  )
  $properties = @($Expected.PSObject.Properties)
  if ($properties.Count -ne 30) { throw "ISOLATED_ENV_EXPECTED_KEYS" }
  $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
  foreach ($property in $properties) {
    if ($property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty -or
        $property.Name -cnotin $names -or $property.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace($property.Value) -or $property.Value.Contains([char]0)) {
      throw "ISOLATED_ENV_EXPECTED_LITERAL"
    }
    $values.Add($property.Name, $property.Value)
  }
  foreach ($name in $names) {
    if (-not $values.ContainsKey($name)) { throw "ISOLATED_ENV_EXPECTED_KEYS" }
  }
  return ,$values
}

function Initialize-IsolatedProcessEnvironment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [pscustomobject] $Expected,
    [Parameter(Mandatory)] [string] $EntryScriptPath,
    [Parameter(Mandatory)] [string] $ApprovedEntryScriptPath
  )

  $values = Get-IsolatedExpectedEnvironment -Expected $Expected
  if (-not [IO.Path]::IsPathFullyQualified($EntryScriptPath) -or
      -not [IO.Path]::IsPathFullyQualified($ApprovedEntryScriptPath) -or
      -not [string]::Equals([IO.Path]::GetFullPath($EntryScriptPath),
        [IO.Path]::GetFullPath($ApprovedEntryScriptPath), [StringComparison]::OrdinalIgnoreCase) -or
      -not [IO.File]::Exists($EntryScriptPath)) {
    throw "ISOLATED_ENV_ENTRY_PATH"
  }

  # pwsh constructs PSModulePath at startup; only these two reviewed literals are reasserted.
  try {
    [Environment]::SetEnvironmentVariable("PATHEXT", $values["PATHEXT"], [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable("PSModulePath", $values["PSModulePath"], [EnvironmentVariableTarget]::Process)
  } catch {
    throw "ISOLATED_ENV_PROCESS_WRITE"
  }
}

function Assert-IsolatedProcessEnvironment {
  [CmdletBinding()]
  param([Parameter(Mandatory)] [pscustomobject] $Expected)

  $values = Get-IsolatedExpectedEnvironment -Expected $Expected
  $actual = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
  $expectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $values.Keys) { $null = $expectedNames.Add($name) }
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $actual.Keys) {
    if (-not $expectedNames.Contains([string]$name)) { throw "ISOLATED_ENV_UNEXPECTED_KEY" }
    $null = $names.Add([string]$name)
  }
  if ($actual.Count -ne 30 -or $names.Count -ne 30) { throw "ISOLATED_ENV_KEY_SET" }
  foreach ($entry in $values.GetEnumerator()) {
    if (-not $names.Contains($entry.Key) -or
        -not [string]::Equals(
          [Environment]::GetEnvironmentVariable($entry.Key, [EnvironmentVariableTarget]::Process),
          $entry.Value, [StringComparison]::Ordinal)) {
      throw "ISOLATED_ENV_LITERAL"
    }
  }
}
