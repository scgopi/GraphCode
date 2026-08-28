import Foundation

/// The loopback ports a browser-based sign-in URL will call back to.
///
/// Every CLI that authenticates through a browser — `az login`, `gcloud auth login`,
/// `claude`, `codex login` — binds a localhost port and encodes it in the URL it
/// prints: either the URL itself is `http://localhost:<port>/…`, or the provider URL
/// carries it as a `redirect_uri`-style query parameter. That port is on the machine
/// running the CLI; when that machine is a remote project, the Mac's browser needs the
/// same port carried over (`RemoteAuthPortForwarder`) before the redirect can land.
/// Reading the port out of the URL is what makes the forward generic: no per-CLI port
/// list, and random ports (az picks one per login) work the same as fixed ones.
public enum AuthCallbackPorts {
  static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

  /// Unprivileged loopback ports named by the URL, in the order found: the URL's own
  /// authority first, then any query-parameter value that is itself a URL (the
  /// `redirect_uri` shape — `URLComponents` has already percent-decoded it once).
  public static func extract(fromURLString urlString: String) -> [Int] {
    guard let components = URLComponents(string: urlString) else { return [] }
    var ports: [Int] = []
    func appendLoopbackPort(of components: URLComponents) {
      guard let host = components.host?.lowercased(), loopbackHosts.contains(host),
        let port = components.port, (1024...65535).contains(port),
        !ports.contains(port)
      else { return }
      ports.append(port)
    }
    appendLoopbackPort(of: components)
    for item in components.queryItems ?? [] {
      guard let value = item.value, value.contains("://"),
        let nested = URLComponents(string: value)
      else { continue }
      appendLoopbackPort(of: nested)
    }
    return ports
  }
}
