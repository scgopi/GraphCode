import Foundation
import GraphcodeKit
import Testing

/// The fourth loop type is called `composite` in the code and on every surface, but it
/// shipped as `proactive` and that is the word in every graph already on disk. A decode
/// failure reads to a user as their loops having been wiped, so the raw value is pinned
/// here against literal JSON rather than against whatever the enum currently spells.
@Suite
struct LoopTypeCodingTests {
  @Test
  func compositeStillSerialisesAsProactive() {
    #expect(LoopType.composite.rawValue == "proactive")
    #expect(LoopType(rawValue: "proactive") == .composite)
  }

  @Test
  func aSavedProactiveNodeDecodesAsAComposite() throws {
    let node = try JSONDecoder().decode(
      LoopNode.self,
      from: Data(
        """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "Nightly triage",
          "loopType": "proactive"
        }
        """.utf8))

    #expect(node.loopType == .composite)
  }

  @Test
  func aCompositeRoundTripsThroughTheWordOnDisk() throws {
    let encoded = try JSONEncoder().encode(LoopNode(title: "Pipeline", loopType: .composite))
    #expect(String(decoding: encoded, as: UTF8.self).contains("\"proactive\""))
    #expect(try JSONDecoder().decode(LoopNode.self, from: encoded).loopType == .composite)
  }
}
