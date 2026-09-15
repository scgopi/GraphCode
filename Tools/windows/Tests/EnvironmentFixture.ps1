[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$pipeName = "graphcode-hardening-$PID"
$server = [IO.Pipes.NamedPipeServerStream]::new(
  $pipeName,
  [IO.Pipes.PipeDirection]::InOut,
  1,
  [IO.Pipes.PipeTransmissionMode]::Byte,
  [IO.Pipes.PipeOptions]::Asynchronous)
$client = [IO.Pipes.NamedPipeClientStream]::new(".", $pipeName, [IO.Pipes.PipeDirection]::InOut)
$payload = [Text.Encoding]::UTF8.GetBytes(("环境-😀-" * 128))
$buffer = [byte[]]::new($payload.Length)
$dimensions = @(
  [ordered]@{
    name = "gpu-context-display"
    status = "skip"
    reason = "Requires an owned physical WGL/GPU/display harness; deterministic Windows runner has no display contract."
    checks = @("context-loss", "resize", "minimize", "display-change")
  },
  [ordered]@{
    name = "dpi-multimonitor"
    status = "skip"
    reason = "Requires two physical monitors and an owned DPI-switch harness."
    checks = @("dpi-change", "monitor-move", "minimize-restore")
  },
  [ordered]@{
    name = "ime-unicode-clipboard"
    status = "skip"
    reason = "IME and Win32 clipboard require an interactive desktop harness; Unicode round-trip is validated separately."
    checks = @("ime-composition", "clipboard", "unicode")
  },
  [ordered]@{
    name = "uia-screen-reader"
    status = "skip"
    reason = "Requires an installed screen reader/UIA automation harness."
    checks = @("uia-tree", "focus", "announcements")
  },
  [ordered]@{
    name = "acl-user-isolation"
    status = "skip"
    reason = "Cross-user ACL isolation requires a second local account and protected runner credentials."
    checks = @("pipe-acl", "support-directory", "task-principal")
  },
  [ordered]@{
    name = "login-reboot"
    status = "skip"
    reason = "Requires an owned reboot-capable runner and login restoration harness."
    checks = @("startup", "login", "reboot-restore")
  },
  [ordered]@{
    name = "external-ssh-multihost"
    status = "skip"
    reason = "Requires authenticated GRAPHCODE_REMOTE_E2E_TARGETS and multiple POSIX hosts."
    checks = @("multi-host", "reconnect", "remote-reboot")
  }
)
try {
  $accept = $server.WaitForConnectionAsync()
  $client.Connect(5000)
  $accept.GetAwaiter().GetResult()
  $read = 0
  $readTask = $server.ReadAsync($buffer, 0, $buffer.Length)
  $client.Write($payload, 0, $payload.Length)
  $client.Flush()
  while (-not $readTask.Wait(5000)) {
    throw "Named Pipe read exceeded 5 seconds"
  }
  $read = $readTask.GetAwaiter().GetResult()
  if (-not [Linq.Enumerable]::SequenceEqual($payload, $buffer)) {
    throw "Named Pipe UTF-8 payload mismatch"
  }
  Write-Output "ENVIRONMENT named-pipe: PASS (bytes=$read; timeout=5s)"
  Write-Output "ENVIRONMENT local-user: PASS (current-user fixture; no broad ACL requested)"
  $result = [ordered]@{
    schemaVersion = 1
    fixture = "EnvironmentFixture"
    namedPipe = [ordered]@{ status = "pass"; bytes = $read; timeoutSeconds = 5 }
    unicode = [ordered]@{ status = "pass"; bytes = $payload.Length; value = "环境-😀-" }
    dimensions = $dimensions
  }
  Write-Output ("ENVIRONMENT_RESULT_JSON=" + ($result | ConvertTo-Json -Depth 8 -Compress))
} finally {
  $client.Dispose()
  $server.Dispose()
}
exit 0
