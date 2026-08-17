[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $Shell,
  [string] $Zmx = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$oldZmx = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX")
$oldCwd = [Environment]::GetEnvironmentVariable("GRAPHCODE_GATE_CWD")
try {
  if ($Zmx) { $env:GRAPHCODE_ZMX = $Zmx }
  $env:GRAPHCODE_GATE_CWD = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $process = Start-Process -FilePath $Shell -PassThru -WindowStyle Normal
  try {
    for ($i = 0; $i -lt 80; $i++) {
      Start-Sleep -Milliseconds 250
      $process.Refresh()
      if ($process.MainWindowHandle -ne 0) { break }
      if ($process.HasExited) { throw "shell exited with code $($process.ExitCode)" }
    }
    if ($process.MainWindowHandle -eq 0) { throw "shell did not create an HWND" }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    $invoke = $root.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $children = $root.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    $invoke.Invoke()
    [pscustomobject]@{
      name = $root.Current.Name
      automationId = $root.Current.AutomationId
      controlType = $root.Current.ControlType.ProgrammaticName
      childCount = $children.Count
      firstChild = if ($children.Count -gt 0) { $children[0].Current.Name } else { "" }
      invokePattern = $true
    } | ConvertTo-Json -Compress
  } finally {
    if (-not $process.HasExited) {
      $process.Kill()
      $process.WaitForExit()
    }
  }
} finally {
  if ($null -eq $oldZmx) {
    Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_ZMX = $oldZmx
  }
  if ($null -eq $oldCwd) {
    Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_GATE_CWD = $oldCwd
  }
}
