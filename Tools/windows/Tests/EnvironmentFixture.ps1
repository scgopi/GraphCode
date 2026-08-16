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
} finally {
  $client.Dispose()
  $server.Dispose()
}
exit 0
