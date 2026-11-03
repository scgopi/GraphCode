function Stop-OwnedLiveProcess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][Diagnostics.Process] $Process,
    [Parameter(Mandatory)][string] $Name,
    [ValidateRange(1, 60000)][int] $TimeoutMilliseconds = 10000
  )

  if ($Process.HasExited) { return }
  try {
    $Process.Kill()
  } catch {
    $killError = $_.Exception
    try {
      $exited = $Process.HasExited
    } catch {
      throw [AggregateException]::new(
        "Could not stop or verify the owned $Name process.",
        [Exception[]]@($killError, $_.Exception))
    }
    if (-not $exited) { throw $killError }
  }
  if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
    throw [TimeoutException]::new(
      "The owned $Name process did not exit within $TimeoutMilliseconds ms.")
  }
}

function Write-OwnedLiveText {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][IO.TextWriter] $Writer,
    [AllowEmptyString()][string] $Text,
    [Parameter(Mandatory)][ref] $Pending,
    [switch] $Final
  )

  $textToWrite = $Pending.Value + $Text
  $Pending.Value = ""
  if (-not $Final -and $textToWrite.Length -gt 0 -and
      [char]::IsHighSurrogate($textToWrite[$textToWrite.Length - 1])) {
    $Pending.Value = $textToWrite.Substring($textToWrite.Length - 1)
    $textToWrite = $textToWrite.Substring(0, $textToWrite.Length - 1)
  }
  if ($textToWrite.Length -gt 0) {
    $Writer.Write($textToWrite)
    $Writer.Flush()
  }
}

function Write-OwnedLiveOutputChunk {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Scope,
    [Parameter(Mandatory)][Diagnostics.Process] $Process,
    [Parameter(Mandatory)][hashtable] $Pending
  )

  $maximumCharacters = 65536
  $chunk = Receive-ShellOwnedOutput $Scope $Process -MaximumCharacters $maximumCharacters
  if ($null -eq $chunk -or $chunk.Output -isnot [string] -or
      $chunk.Error -isnot [string] -or
      $chunk.Output.Length -gt $maximumCharacters -or
      $chunk.Error.Length -gt $maximumCharacters) {
    throw "Owned incremental output returned an invalid or oversized chunk."
  }
  $outputPending = $Pending.Output
  $errorPending = $Pending.Error
  Write-OwnedLiveText -Writer ([Console]::Out) -Text $chunk.Output -Pending ([ref]$outputPending)
  Write-OwnedLiveText -Writer ([Console]::Error) -Text $chunk.Error -Pending ([ref]$errorPending)
  $Pending.Output = $outputPending
  $Pending.Error = $errorPending
  return ($chunk.Output.Length -gt 0 -or $chunk.Error.Length -gt 0)
}

function Invoke-OwnedLiveCommand {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Scope,
    [Parameter(Mandatory)][Diagnostics.ProcessStartInfo] $StartInfo,
    [switch] $StreamOutput
  )

  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $process = Start-ShellOwnedProcess $Scope $StartInfo
  if ($StreamOutput) {
    $pending = @{ Output = ""; Error = "" }
    do {
      $received = Write-OwnedLiveOutputChunk -Scope $Scope -Process $process -Pending $pending
      $wait = if ($received) { 0 } else { 100 }
      $exited = $process.WaitForExit($wait)
    } while (-not $exited)
  } else {
    [void]$process.WaitForExit()
  }
  Complete-ShellOwnedProcess $Scope $process
  if ($StreamOutput) {
    do {
      $received = Write-OwnedLiveOutputChunk -Scope $Scope -Process $process -Pending $pending
    } while ($received)
    $outputPending = $pending.Output
    $errorPending = $pending.Error
    Write-OwnedLiveText -Writer ([Console]::Out) -Text "" -Pending ([ref]$outputPending) -Final
    Write-OwnedLiveText -Writer ([Console]::Error) -Text "" -Pending ([ref]$errorPending) -Final
  }
  return [pscustomobject]@{
    ExitCode = $process.ExitCode
    Output = Read-ShellOwnedOutput $Scope $process
    Error = Read-ShellOwnedOutput $Scope $process -StandardError
  }
}

function Get-OwnedLiveProcessRetainedRoots {
  [CmdletBinding()]
  param(
    [Exception[]] $Errors = @(),
    [string[]] $RetainedRoots = @()
  )

  $observed = [Collections.Generic.List[string]]::new()
  $pathsSeen = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  $pending = [Collections.Generic.Stack[Exception]]::new()
  $errorsSeen = [Collections.Generic.HashSet[Exception]]::new()
  foreach ($root in $RetainedRoots) {
    if ($root -and [IO.Directory]::Exists($root) -and $pathsSeen.Add($root)) {
      $observed.Add($root)
    }
  }
  foreach ($error in $Errors) {
    if ($error) { $pending.Push($error) }
  }
  while ($pending.Count -gt 0) {
    $current = $pending.Pop()
    if (-not $errorsSeen.Add($current)) { continue }
    if ($current.Data.Contains("GraphCodeValidationRetainedRoots")) {
      foreach ($root in @($current.Data["GraphCodeValidationRetainedRoots"])) {
        if ($root -is [string] -and $root -and [IO.Directory]::Exists($root) -and
            $pathsSeen.Add($root)) {
          $observed.Add($root)
        }
      }
    }
    if ($current -is [AggregateException]) {
      foreach ($inner in $current.InnerExceptions) { $pending.Push($inner) }
    } elseif ($current.InnerException) {
      $pending.Push($current.InnerException)
    }
  }
  return $observed.ToArray()
}

function New-OwnedLiveProcessCleanupError {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Message,
    [Parameter(Mandatory)][Exception[]] $Errors,
    [string[]] $RetainedRoots = @()
  )

  $allErrors = [Collections.Generic.List[Exception]]::new()
  foreach ($error in $Errors) { $allErrors.Add($error) }
  $environment = [Environment]::GetEnvironmentVariables(
    [EnvironmentVariableTarget]::Process)
  try {
    if (-not $environment.Contains("GRAPHCODE_VALIDATION_ROOT")) {
      throw "GRAPHCODE_VALIDATION_ROOT is absent; a retention receipt cannot be written."
    }
    $root = [string]$environment["GRAPHCODE_VALIDATION_ROOT"]
    if ([string]::IsNullOrWhiteSpace($root) -or
        -not [IO.Path]::IsPathFullyQualified($root)) {
      throw "GRAPHCODE_VALIDATION_ROOT is not a fully qualified path."
    }
    $directory = [IO.DirectoryInfo]::new($root)
    while ($directory) {
      if (-not $directory.Exists -or
          ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Validation root or an ancestor is missing or is a reparse point: $($directory.FullName)"
      }
      $directory = $directory.Parent
    }
    $receiptPath = Join-Path $root "ownership-unproven.json"
    $receiptExists = $true
    try {
      [void][IO.File]::GetAttributes($receiptPath)
    } catch [IO.FileNotFoundException] {
      $receiptExists = $false
    }
    if ($receiptExists) { throw "Ownership receipt already exists: $receiptPath" }
    $receipt = [ordered]@{
      schemaVersion = 1
      validationRoot = $root
      reason = "ownership_unproven"
    } | ConvertTo-Json -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($receipt)
    if ($bytes.Length -gt 4096) { throw "Ownership receipt exceeds 4096 bytes." }
    $stream = [IO.File]::Open(
      $receiptPath, [IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally {
      $stream.Dispose()
    }
  } catch {
    $allErrors.Add($_.Exception)
    try {
      [Console]::Out.WriteLine(
        "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven")
      [Console]::Out.Flush()
    } catch {
      $allErrors.Add($_.Exception)
    }
  }

  $result = [AggregateException]::new($Message, [Exception[]]$allErrors.ToArray())
  $result.Data["GraphCodeValidationRootRetentionRequired"] = $true
  $result.Data["GraphCodeValidationRetainedRoots"] = [string[]]@(
    Get-OwnedLiveProcessRetainedRoots -Errors $Errors -RetainedRoots $RetainedRoots)
  return ,$result
}

function Test-OwnedLiveProcessRetentionRequired {
  [CmdletBinding()]
  param([Parameter(Mandatory)][Exception] $Exception)

  $pending = [Collections.Generic.Stack[Exception]]::new()
  $seen = [Collections.Generic.HashSet[Exception]]::new()
  $pending.Push($Exception)
  while ($pending.Count -gt 0) {
    $current = $pending.Pop()
    if (-not $seen.Add($current)) { continue }
    if ($current.Data.Contains("GraphCodeValidationRootRetentionRequired") -and
        $current.Data["GraphCodeValidationRootRetentionRequired"] -is [bool] -and
        $current.Data["GraphCodeValidationRootRetentionRequired"]) {
      return $true
    }
    if ($current -is [AggregateException]) {
      foreach ($inner in $current.InnerExceptions) { $pending.Push($inner) }
    } elseif ($current.InnerException) {
      $pending.Push($current.InnerException)
    }
  }
  return $false
}
