import ComposableArchitecture
import Foundation
import GraphcodeKit
import MailroomKit

extension ProjectFeature {
  /// A broadcast with the room's posts carried over from the copy this project holds
  /// — they are not on the wire (`LoopGraph.mailroom`) — and whether its digest says
  /// that copy is stale, which is what asks for a fresh one. A snapshot from a daemon
  /// that still ships posts keeps its own and is never stale.
  static func carryingRoom(
    _ broadcast: LoopGraph, over current: LoopGraph
  ) -> (graph: LoopGraph, stale: Bool) {
    guard broadcast.mailroom.isEmpty else { return (broadcast, false) }
    var carried = broadcast
    carried.mailroom = current.mailroom
    return (carried, broadcast.boardDigest != current.boardDigest)
  }

  /// Asks the daemon for the project's whole room — the posts a `.graphChanged`
  /// snapshot describes but no longer carries. The reply lands as `.mailbox`, on this
  /// connection alone. Whole bodies, since the rail shows them.
  static func fetchBoard<A>(_ projectPath: String, via client: OrchestratorClient) -> Effect<A> {
    .run { _ in
      try? await client.send(
        .mailbox(
          projectPath: projectPath, query: MailboxQuery(selection: .board, fullBodies: true)))
    }
  }
}
