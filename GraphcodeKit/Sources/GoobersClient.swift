import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The read-only boundary between GraphCode and one local Goobers instance.
///
/// A Goobers daemon publishes its chosen loopback address to
/// `<instance>/scheduler/api.address`. Discovering that file rather than assuming port
/// 8080 lets several graph-owned instances coexist. Only loopback addresses are accepted
/// in this first integration: remote and MDB hosting need an explicit authentication and
/// trust design, not an accidental widening of this client.
public struct GoobersClient: Sendable {
  public enum ClientError: Error, Equatable, Sendable {
    case daemonNotRunning
    case invalidAddress(String)
    case nonLoopbackAddress(String)
    case unexpectedStatus(Int)
    case invalidResponse
  }

  public struct InstanceIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var environment: String
  }

  public struct Health: Codable, Equatable, Sendable {
    public var apiVersion: String
    public var schemaVersion: String
    public var ready: Bool
    public var healthy: Bool
    public var instance: InstanceIdentity
  }

  public struct Trigger: Codable, Equatable, Sendable {
    public var kind: String
    public var ref: String?
  }

  public struct Run: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var workflow: String
    public var workflowVersion: Int
    public var workflowDigest: String?
    public var gaggle: String
    public var trigger: Trigger
    public var phase: String
    public var terminal: Bool
    public var currentStage: String?
    public var startedAt: String
    public var finishedAt: String?
    public var durationMillis: Int64
    public var lastActivityAt: String
    public var stale: Bool
    public var repassCount: Int
    public var retryCount: Int
    public var noWork: Bool
  }

  public struct RunList: Codable, Equatable, Sendable {
    public var runs: [Run]
    public var nextCursor: String?
  }

  public struct Request: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var body: Data?

    public init(url: URL, method: String = "GET", body: Data? = nil) {
      self.url = url
      self.method = method
      self.body = body
    }
  }

  public struct TriggerResponse: Codable, Equatable, Sendable {
    public var runId: String?
    public var duplicate: Bool?
  }

  public typealias Loader = @Sendable (Request) async throws -> (Data, Int)

  public let instanceRoot: URL
  private let load: Loader

  public init(
    instanceRoot: URL,
    load: @escaping Loader = { request in
      try await GoobersClient.defaultLoad(request)
    }
  ) {
    self.instanceRoot = instanceRoot
    self.load = load
  }

  public var addressFile: URL {
    instanceRoot
      .appendingPathComponent("scheduler", isDirectory: true)
      .appendingPathComponent("api.address")
  }

  public func baseURL() throws -> URL {
    guard let raw = try? String(contentsOf: addressFile, encoding: .utf8) else {
      throw ClientError.daemonNotRunning
    }
    let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty else { throw ClientError.invalidAddress(address) }

    let candidate = address.contains("://") ? address : "http://\(address)"
    guard let url = URL(string: candidate), url.scheme == "http",
      let host = url.host, url.port != nil
    else {
      throw ClientError.invalidAddress(address)
    }
    guard Self.isLoopback(host) else {
      throw ClientError.nonLoopbackAddress(address)
    }
    return url
  }

  public func health() async throws -> Health {
    try await send(Request(url: try endpoint("/api/v1/health")), as: Health.self)
  }

  public func runs(limit: Int = 50) async throws -> RunList {
    let bounded = min(max(limit, 1), 200)
    return try await send(
      Request(url: try endpoint("/api/v1/runs?limit=\(bounded)")), as: RunList.self)
  }

  public func trigger(
    gaggle: String,
    workflow: String,
    requestID: String = UUID().uuidString
  ) async throws -> TriggerResponse {
    let body = try JSONEncoder().encode(
      TriggerRequest(gaggle: gaggle, workflow: workflow, requestId: requestID))
    return try await send(
      Request(url: try endpoint("/api/v1/triggers"), method: "POST", body: body),
      as: TriggerResponse.self)
  }

  private func send<Response: Decodable & Sendable>(
    _ request: Request, as _: Response.Type
  ) async throws -> Response {
    let (data, status) = try await load(request)
    guard (200..<300).contains(status) else {
      throw ClientError.unexpectedStatus(status)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw ClientError.invalidResponse
    }
  }

  private func endpoint(_ path: String) throws -> URL {
    guard
      var components = URLComponents(
        url: try baseURL(), resolvingAgainstBaseURL: false)
    else {
      throw ClientError.invalidAddress(path)
    }
    guard let requested = URLComponents(string: path) else {
      throw ClientError.invalidAddress(path)
    }
    components.path = requested.path
    components.query = requested.query
    guard let url = components.url else { throw ClientError.invalidAddress(path) }
    return url
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  public static func defaultLoad(_ request: Request) async throws -> (Data, Int) {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    if request.body != nil {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else {
      throw ClientError.invalidResponse
    }
    return (data, http.statusCode)
  }

  private struct TriggerRequest: Encodable {
    var gaggle: String
    var workflow: String
    var requestId: String
  }
}

extension GoobersClient.ClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .daemonNotRunning:
      return "The Goobers daemon is not running for this graph."
    case .invalidAddress(let address):
      return "Goobers published an invalid API address: \(address)"
    case .nonLoopbackAddress(let address):
      return "Remote Goobers APIs are not enabled yet: \(address)"
    case .unexpectedStatus(let status):
      return "The Goobers API returned HTTP \(status)."
    case .invalidResponse:
      return "The Goobers API returned a response GraphCode could not read."
    }
  }
}
