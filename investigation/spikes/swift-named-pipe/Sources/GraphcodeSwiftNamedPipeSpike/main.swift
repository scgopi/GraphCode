import Foundation
import WinSDK

enum PipeError: Error {
  case win32(String, DWORD)
  case invalidFrame
  case frameTooLarge(UInt32)
}
let maxFrameBytes: UInt32 = 1_048_576
func withWideString<Result>(
  _ value: String,
  _ body: (UnsafePointer<WCHAR>) throws -> Result
) rethrows -> Result {
  var buffer = Array(value.utf16)
  buffer.append(0)
  return try buffer.withUnsafeBufferPointer { pointer in
    try body(pointer.baseAddress!)
  }
}
func checkHandle(_ handle: HANDLE?, operation: String) throws -> HANDLE {
  guard let handle, handle != INVALID_HANDLE_VALUE else {
    throw PipeError.win32(operation, GetLastError())
  }
  return handle
}
func writeAll(_ bytes: [UInt8], to handle: HANDLE) throws {
  var offset = 0
  while offset < bytes.count {
    var written: DWORD = 0
    let succeeded = bytes.withUnsafeBytes { rawBuffer in
      WriteFile(
        handle,
        rawBuffer.baseAddress!.advanced(by: offset),
        DWORD(bytes.count - offset),
        &written,
        nil)
    }
    guard succeeded != false else {
      throw PipeError.win32("WriteFile", GetLastError())
    }
    offset += Int(written)
  }
}
func readExactly(_ count: Int, from handle: HANDLE) throws -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  var offset = 0
  while offset < count {
    var bytesRead: DWORD = 0
    let succeeded = bytes.withUnsafeMutableBytes { rawBuffer in
      ReadFile(
        handle,
        rawBuffer.baseAddress!.advanced(by: offset),
        DWORD(count - offset),
        &bytesRead,
        nil)
    }
    guard succeeded != false else {
      throw PipeError.win32("ReadFile", GetLastError())
    }
    guard bytesRead > 0 else { throw PipeError.invalidFrame }
    offset += Int(bytesRead)
  }
  return bytes
}
func writeFrame(_ text: String, to handle: HANDLE) throws {
  let payload = Array(text.utf8)
  let count = UInt32(payload.count)
  let header: [UInt8] = [
    UInt8((count >> 24) & 0xff),
    UInt8((count >> 16) & 0xff),
    UInt8((count >> 8) & 0xff),
    UInt8(count & 0xff),
  ]
  try writeAll(header + payload, to: handle)
}
func validatedFrameLength(_ header: [UInt8]) throws -> Int {
  guard header.count == 4 else { throw PipeError.invalidFrame }
  let count =
    (UInt32(header[0]) << 24)
    | (UInt32(header[1]) << 16)
    | (UInt32(header[2]) << 8)
    | UInt32(header[3])
  guard count <= maxFrameBytes else { throw PipeError.frameTooLarge(count) }
  return Int(count)
}
func readFrame(from handle: HANDLE) throws -> String {
  let count = try validatedFrameLength(readExactly(4, from: handle))
  let payload = try readExactly(count, from: handle)
  guard let text = String(bytes: payload, encoding: .utf8) else {
    throw PipeError.invalidFrame
  }
  return text
}
func createServerPipe(
  named name: String,
  maxInstances: DWORD = DWORD(bitPattern: PIPE_UNLIMITED_INSTANCES)
)
  throws -> HANDLE
{
  try withWideString(name) { wideName in
    try checkHandle(
      CreateNamedPipeW(
        wideName,
        DWORD(PIPE_ACCESS_DUPLEX),
        DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
        maxInstances,
        64 * 1024,
        64 * 1024,
        1_000,
        nil),
      operation: "CreateNamedPipeW")
  }
}
func connectClient(to name: String) throws -> HANDLE {
  try withWideString(name) { wideName in
    guard WaitNamedPipeW(wideName, 2_000) != false else {
      throw PipeError.win32("WaitNamedPipeW", GetLastError())
    }
    return try checkHandle(
      CreateFileW(
        wideName,
        DWORD(GENERIC_READ) | DWORD(bitPattern: GENERIC_WRITE),
        0,
        nil,
        DWORD(OPEN_EXISTING),
        0,
        nil),
      operation: "CreateFileW")
  }
}
func serveOne(
  pipeName: String,
  ready: DispatchSemaphore,
  result: @escaping @Sendable (Result<String, Error>) -> Void
) {
  DispatchQueue.global().async {
    do {
      let pipe = try createServerPipe(named: pipeName)
      defer { CloseHandle(pipe) }
      ready.signal()
      let connected = ConnectNamedPipe(pipe, nil)
      guard connected != false || GetLastError() == ERROR_PIPE_CONNECTED else {
        throw PipeError.win32("ConnectNamedPipe", GetLastError())
      }
      let request = try readFrame(from: pipe)
      try writeFrame("response:\(request)", to: pipe)
      try writeFrame("event:graphChanged", to: pipe)
      FlushFileBuffers(pipe)
      DisconnectNamedPipe(pipe)
      result(.success(request))
    } catch {
      result(.failure(error))
    }
  }
}
let pipeName = #"\\.\pipe\graphcode-spike-\#(GetCurrentProcessId())"#
let ready = DispatchSemaphore(value: 0)
let serversDone = DispatchGroup()
let clientsDone = DispatchGroup()
final class FailureStore: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ text: String) {
    lock.lock()
    storage.append(text)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
final class SendableHandle: @unchecked Sendable {
  let value: HANDLE

  init(_ value: HANDLE) {
    self.value = value
  }
}
let failures = FailureStore()
for _ in 0..<2 {
  serversDone.enter()
  serveOne(pipeName: pipeName, ready: ready) { result in
    if case .failure(let error) = result {
      failures.append("server: \(error)")
    }
    serversDone.leave()
  }
}
ready.wait()
ready.wait()
for request in ["client-one", "client-two"] {
  clientsDone.enter()
  DispatchQueue.global().async {
    defer { clientsDone.leave() }
    do {
      let client = try connectClient(to: pipeName)
      defer { CloseHandle(client) }
      try writeFrame(request, to: client)
      let response = try readFrame(from: client)
      let event = try readFrame(from: client)
      guard response == "response:\(request)", event == "event:graphChanged" else {
        throw PipeError.invalidFrame
      }
    } catch {
      failures.append("client \(request): \(error)")
    }
  }
}
clientsDone.wait()
serversDone.wait()
let reconnectReady = DispatchSemaphore(value: 0)
let reconnectDone = DispatchSemaphore(value: 0)
serveOne(pipeName: pipeName, ready: reconnectReady) { result in
  if case .failure(let error) = result {
    failures.append("reconnect server: \(error)")
  }
  reconnectDone.signal()
}
reconnectReady.wait()
do {
  let client = try connectClient(to: pipeName)
  try writeFrame("reconnected", to: client)
  guard try readFrame(from: client) == "response:reconnected",
    try readFrame(from: client) == "event:graphChanged"
  else {
    throw PipeError.invalidFrame
  }
  CloseHandle(client)
} catch {
  failures.append("reconnect client: \(error)")
}
reconnectDone.wait()
let missingName = pipeName + "-missing"
let missingError = withWideString(missingName) { wideName -> DWORD in
  let handle = CreateFileW(
    wideName,
    DWORD(GENERIC_READ) | DWORD(bitPattern: GENERIC_WRITE),
    0,
    nil,
    DWORD(OPEN_EXISTING),
    0,
    nil)
  if handle != INVALID_HANDLE_VALUE {
    CloseHandle(handle)
    return DWORD(bitPattern: ERROR_SUCCESS)
  }
  return GetLastError()
}
if missingError != DWORD(bitPattern: ERROR_FILE_NOT_FOUND) {
  failures.append("daemon unavailable error was \(missingError)")
}
let busyName = pipeName + "-busy"
do {
  let busyPipe = try createServerPipe(named: busyName, maxInstances: 1)
  let busyPipeBox = SendableHandle(busyPipe)
  let connected = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    _ = ConnectNamedPipe(busyPipeBox.value, nil)
    connected.signal()
  }
  let firstClient = try connectClient(to: busyName)
  connected.wait()
  let timeoutError = withWideString(busyName) { wideName -> DWORD in
    if WaitNamedPipeW(wideName, 100) != false {
      return DWORD(bitPattern: ERROR_SUCCESS)
    }
    return GetLastError()
  }
  if timeoutError != DWORD(bitPattern: ERROR_SEM_TIMEOUT) {
    failures.append("busy-pipe timeout error was \(timeoutError)")
  }
  CloseHandle(firstClient)
  DisconnectNamedPipe(busyPipe)
  CloseHandle(busyPipe)
} catch {
  failures.append("timeout setup: \(error)")
}
do {
  _ = try validatedFrameLength([0x7f, 0xff, 0xff, 0xff])
  failures.append("oversized frame was accepted")
} catch PipeError.frameTooLarge {
} catch {
  failures.append("oversized frame returned unexpected error: \(error)")
}
if !failures.values.isEmpty {
  for failure in failures.values { FileHandle.standardError.write(Data("\(failure)\n".utf8)) }
  exit(1)
}
print("swift-named-pipe request-response: ok")
print("swift-named-pipe event-stream: ok")
print("swift-named-pipe multiple-clients: ok")
print("swift-named-pipe reconnect: ok")
print("swift-named-pipe daemon-unavailable: ok")
print("swift-named-pipe connection-availability-timeout: ok")
print("swift-named-pipe oversized-frame-rejection: ok")
