import Foundation
import GraphcodeKit
import Testing

@Suite
struct QuickChatProtocolTests {
  @Test
  func commandAndEventCodableRoundTrip() throws {
    let commands: [DaemonCommand] = [
      .listQuickChats,
      .createQuickChat(title: "Scratch", backend: .claudeCode),
      .openQuickChat(id: UUID()),
      .renameQuickChat(id: UUID(), title: "Renamed"),
      .deleteQuickChat(id: UUID()),
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for command in commands {
      #expect(try decoder.decode(DaemonCommand.self, from: encoder.encode(command)) == command)
    }

    let chat = QuickChat(title: "Scratch")
    let events: [DaemonEvent] = [
      .quickChatsListed([chat]),
      .quickChatChanged(chat),
      .quickChatDeleted(chat.id),
      .quickChatActivity(
        id: chat.id,
        activity: QuickChatActivity(sequence: 2, text: "editing", presence: .unknown)),
    ]
    for event in events {
      #expect(try decoder.decode(DaemonEvent.self, from: encoder.encode(event)) == event)
    }
  }

  @Test
  func storeKeepsActivitySequenceOnStableChatIdentity() {
    let directory = URL(fileURLWithPath: "quick-chat-protocol-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = QuickChatStore(baseDirectory: directory)
    let chat = QuickChat(title: "Scratch")
    store.create(chat)
    _ = store.updateActivity(id: chat.id, activity: QuickChatActivity(sequence: 1, text: "first"))
    _ = store.updateActivity(id: chat.id, activity: QuickChatActivity(sequence: 2, text: "second"))
    #expect(store.chat(id: chat.id)?.activity?.sequence == 2)
    #expect(store.chat(id: chat.id)?.activity?.text == "second")
  }

  @Test
  func zmxFixtureUsesChatIdentityForAttachAndKill() throws {
    let chat = QuickChat(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      title: "Scratch",
      backend: .claudeCode)
    let node = LoopNode(
      id: chat.id,
      title: chat.title,
      backend: chat.backend,
      state: .idle,
      createdAt: chat.createdAt)
    let sessionName = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    #expect(sessionName == "graphcode-\(chat.id.uuidString)")
    #expect(SurfaceRef.nodeID(fromZmxSessionName: sessionName) == chat.id)
  }
}
