import Foundation
import GraphcodeKit
import Testing

/// A remote session's browser sign-in: the loopback callback port is read out of the
/// clicked URL and forwarded into the machine the session runs on, so `az login`,
/// `claude`, or `codex login` inside a codespace or ssh remote completes against the
/// Mac's browser. Generic on purpose — the port comes from the URL, never a per-CLI
/// list, which is what makes az's random port work at all.
@Suite
struct AuthPortForwardingTests {
  @Test
  func theCallbackPortIsReadFromTheURLItself() {
    // codex's shape: the printed URL *is* the localhost server.
    #expect(
      AuthCallbackPorts.extract(fromURLString: "http://localhost:1455/auth/callback?x=1")
        == [1455])
    #expect(
      AuthCallbackPorts.extract(fromURLString: "http://127.0.0.1:54545/callback") == [54545])
  }

  @Test
  func theCallbackPortIsReadFromARedirectURIParameter() {
    // az's shape: a provider URL carrying a percent-encoded localhost redirect with a
    // port chosen at random for this one login.
    let az =
      "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize"
      + "?client_id=x&response_type=code"
      + "&redirect_uri=http%3A%2F%2Flocalhost%3A8400%2F&scope=openid"
    #expect(AuthCallbackPorts.extract(fromURLString: az) == [8400])

    // claude's shape: console URL with an explicit localhost redirect_uri.
    let claude =
      "https://console.anthropic.com/oauth/authorize?client_id=x"
      + "&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=s"
    #expect(AuthCallbackPorts.extract(fromURLString: claude) == [54545])
  }

  @Test
  func onlyLoopbackUnprivilegedPortsCount() {
    // A page that merely links elsewhere must not open tunnels: non-loopback hosts,
    // privileged ports, and portless URLs all extract nothing.
    #expect(AuthCallbackPorts.extract(fromURLString: "https://github.com/login/device") == [])
    #expect(
      AuthCallbackPorts.extract(
        fromURLString: "https://x.test/?redirect_uri=https%3A%2F%2Fapp.x.test%2Fcb") == [])
    #expect(AuthCallbackPorts.extract(fromURLString: "http://localhost/cb") == [])
    #expect(AuthCallbackPorts.extract(fromURLString: "http://localhost:80/cb") == [])
    #expect(AuthCallbackPorts.extract(fromURLString: "not a url") == [])
    // Deduplicated when the URL and its redirect_uri agree.
    #expect(
      AuthCallbackPorts.extract(
        fromURLString: "http://localhost:9005/?redirect_uri=http%3A%2F%2Flocalhost%3A9005%2F")
        == [9005])
  }

  @Test
  func aCodespaceForwardDialsThroughGh() {
    let location = RemoteProjectLocation(
      host: "dev-widget-x5jq4w", remotePath: "/workspaces/widget", isCodespace: true)
    let invocation = RemoteAuthPortForwarder.forwardInvocation(port: 8400, to: location)
    #expect(invocation.first == GhLocator.executablePath)
    #expect(
      Array(invocation.dropFirst().prefix(5))
        == ["codespace", "ssh", "-c", "dev-widget-x5jq4w", "--"])
    #expect(invocation.contains("-N"))
    let forward = invocation.firstIndex(of: "-L").map { invocation[$0 + 1] }
    #expect(forward == "8400:localhost:8400")
    // gh names the destination itself; a trailing one would be read as the command.
    #expect(invocation.last != "dev-widget-x5jq4w")
    #expect(invocation.contains("ExitOnForwardFailure=yes"))
  }

  @Test
  func anSSHForwardCarriesTheDialAndDestination() {
    let location = RemoteProjectLocation(
      user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")
    let invocation = RemoteAuthPortForwarder.forwardInvocation(port: 8400, to: location)
    #expect(invocation.first == "/usr/bin/ssh")
    let forward = invocation.firstIndex(of: "-L").map { invocation[$0 + 1] }
    #expect(forward == "8400:localhost:8400")
    #expect(invocation.contains("2222"))
    #expect(invocation.last == "dev@build-box")
  }
}
