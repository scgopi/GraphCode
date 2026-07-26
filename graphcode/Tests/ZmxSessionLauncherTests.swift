import Foundation
import Testing

@testable import GraphcodeKit

/// The command `graphcoded` builds to start a time-based node's session.
///
/// The load-bearing property is the session *name*: get it wrong and clicking the node
/// silently opens a second, empty session beside the running loop instead of attaching to
/// it. The prompt itself needs no escaping here — `zmx` shell-quotes every argument
/// (`util.shellQuote`) before typing the command into the session, so it must be passed
/// through raw. Quoting it ourselves would double-quote it.
@Suite
struct ZmxSessionLauncherTests {
  private static func node(prompt: String?) -> LoopNode {
    LoopNode(title: "Poll inbox", loopType: .timeBased, triggerPrompt: prompt)
  }

  @Test
  func targetsTheSameSessionTheAppAttachesTo() {
    let node = Self.node(prompt: "/loop 1h Check for new reports")
    let arguments = ZmxSessionLauncher.arguments(forNode: node) ?? []
    let expectedName = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName

    // `-d` follows the name, not the subcommand: `zmx run -d <name>` would create a
    // session literally called "-d". And the name must match what the app's primary
    // surface attaches to.
    #expect(Array(arguments.dropLast()) == ["run", expectedName, "-d", "claude"])
    #expect(arguments.last == "/loop 1h Check for new reports")
    #expect(expectedName == "graphcode-\(node.id.uuidString)")
  }

  @Test
  func passesAHostilePromptThroughUntouched() {
    // Quotes, a subshell, and command separators all survive verbatim as one argument —
    // zmx quotes them on the way into the shell, so escaping them here would corrupt the
    // prompt rather than protect anything.
    let hostile = #"/loop 1h "; rm -rf ~; echo $(whoami) `id` 'quoted'"#
    let arguments = ZmxSessionLauncher.arguments(forNode: Self.node(prompt: hostile))

    #expect(arguments?.count == 5)
    #expect(arguments?.last == hostile)
  }

  @Test
  func flattensNewlinesThatWouldTruncateTheCommand() {
    // zmx ends the command it types with `\r`; an embedded one would submit the line
    // early and run only the first fragment.
    let arguments = ZmxSessionLauncher.arguments(
      forNode: Self.node(prompt: "/loop 1h Check\r\nthen report\nand stop"))

    #expect(arguments?.last == "/loop 1h Check then report and stop")
  }

  @Test
  func checksForAnExistingSessionUnderTheSameName() {
    // `zmx run` re-sends its command when the session is already live, so the launcher
    // has to look before it leaps — and it has to look under the exact name it would
    // create, or the check is meaningless.
    let node = Self.node(prompt: "/loop 1h Check")
    let check = ZmxSessionLauncher.existenceCheckArguments(forNode: node)

    #expect(check == ["get", "graphcode-\(node.id.uuidString)"])
    #expect(check.last == ZmxSessionLauncher.arguments(forNode: node)?[1])
  }

  @Test
  func launchesNothingWithoutAPrompt() {
    // A time-based node with no prompt has nothing to run — starting a bare `claude`
    // would sit there waiting for a human who isn't there.
    #expect(ZmxSessionLauncher.arguments(forNode: Self.node(prompt: nil)) == nil)
    #expect(ZmxSessionLauncher.arguments(forNode: Self.node(prompt: "")) == nil)
  }
}
