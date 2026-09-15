import Foundation

public enum DaemonEndpoint: Equatable, Sendable {
  case unixSocket(URL)
  case namedPipe(String)
  case loopbackTCP(host: String, port: UInt16)
}
public protocol DaemonByteStream: Sendable {
  func readExactly(_ count: Int) async throws -> Data
  func writeAll(_ data: Data) async throws
  func close() async throws
}
public protocol DaemonConnection: Sendable {
  var id: UUID { get }
  var endpoint: DaemonEndpoint { get }

  func receiveFrame() async throws -> Data
  func sendFrame(_ data: Data) async throws
  func close() async throws
}
public protocol DaemonListener: Sendable {
  var endpoint: DaemonEndpoint { get }

  func accept() async throws -> any DaemonConnection
  func close() async throws
}
