import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The argument-injection guard (`SafeArgument`) and the boundaries that enforce it: a
/// dash-leading value must never reach git's or ssh's option parser, and a clone's
/// destination must never reach out of the folder the human picked. Every case here is a
/// value a real branch, host, login, or folder name would never take.
@Suite
struct ArgumentInjectionTests {
  // MARK: - The guard itself

  @Test
  func optionShapedValuesAreRejected() {
    #expect(SafeArgument.looksLikeOption("--upload-pack=touch /tmp/pwned"))
    #expect(SafeArgument.looksLikeOption("-oProxyCommand=x"))
    #expect(!SafeArgument.looksLikeOption("github.com"))
    #expect(!SafeArgument.looksLikeOption("my-branch"))
  }

  @Test
  func safeSSHComponentAcceptsRealHostsAndLoginsOnly() {
    #expect(SafeArgument.isSafeSSHComponent("build-box"))
    #expect(SafeArgument.isSafeSSHComponent("192.168.0.10"))
    #expect(SafeArgument.isSafeSSHComponent("dev"))
    #expect(SafeArgument.isSafeSSHComponent("::1"))
    // The injection shapes: an option-looking host/user, or one carrying whitespace or
    // control characters, is refused.
    #expect(!SafeArgument.isSafeSSHComponent(""))
    #expect(!SafeArgument.isSafeSSHComponent("-oProxyCommand=calc"))
    #expect(!SafeArgument.isSafeSSHComponent("-J jump"))
    #expect(!SafeArgument.isSafeSSHComponent("host name"))
    #expect(!SafeArgument.isSafeSSHComponent("host\tx"))
  }

  @Test
  func safePathComponentIsOneInnocentSegment() {
    #expect(SafeArgument.isSafePathComponent("widget"))
    #expect(SafeArgument.isSafePathComponent("widget-fork"))
    // Traversal, separators, option shapes, and the empty/dot names are all refused.
    #expect(!SafeArgument.isSafePathComponent(""))
    #expect(!SafeArgument.isSafePathComponent("."))
    #expect(!SafeArgument.isSafePathComponent(".."))
    #expect(!SafeArgument.isSafePathComponent("../../etc"))
    #expect(!SafeArgument.isSafePathComponent("a/b"))
    #expect(!SafeArgument.isSafePathComponent("-rf"))
  }

  // MARK: - Clone destination stays inside the picked folder

  @Test
  func aTraversingFolderNameYieldsNoDestination() {
    var draft = WelcomeFeature.CloneDraft()
    draft.repositoryURL = "https://github.com/acme/widget.git"
    draft.locationPath = "/tmp/checkouts"
    // A well-formed name still resolves as before.
    #expect(draft.destinationURL?.path == "/tmp/checkouts/widget")
    // A `..` or separator in the leaf disables the Clone button rather than escaping the
    // parent (which the failure-path `removeItem` would otherwise delete outside it).
    draft.folderName = "../../../etc"
    #expect(draft.destinationURL == nil)
    #expect(!draft.canSubmit)
    draft.folderName = "nested/evil"
    #expect(draft.destinationURL == nil)
  }

  // MARK: - Remote identity refuses a dash-leading host or user

  @Test
  func aDashLeadingHostOrUserDoesNotParse() {
    // These would otherwise be read by ssh as `-oProxyCommand=…` / `-J …` options.
    #expect(RemoteProjectLocation.parse(projectPath: "ssh://-evilhost/srv/repo") == nil)
    #expect(RemoteProjectLocation.parse(projectPath: "ssh://-J@host/srv/repo") == nil)
    // A legitimate remote identity is untouched.
    #expect(
      RemoteProjectLocation.parse(projectPath: "ssh://dev@build-box/srv/repo")
        == RemoteProjectLocation(user: "dev", host: "build-box", remotePath: "/srv/repo"))
  }

  @Test
  func theRemoteFormRefusesADashLeadingHostOrUser() {
    var draft = WelcomeFeature.RemoteDraft()
    draft.server = "-oProxyCommand=calc"
    draft.user = "dev"
    draft.remotePath = "/srv/repo"
    #expect(draft.location == nil)
    #expect(!draft.canSubmit)

    draft.server = "build-box"
    draft.user = "-J"
    #expect(draft.location == nil)

    draft.user = "dev"
    #expect(draft.location != nil)
  }
}
