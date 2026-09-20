import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The New Node dialog's images: what the draft holds, and what a paste or a drop does
/// to it.
///
/// Its own file for the reason `AppFeature`'s helpers have one — `ProjectFeature.swift`
/// sits at swiftlint's file and type-body budgets, and a concern that arrives whole is
/// easier to read whole.
extension ProjectFeature {
  /// Images attached to the brief field, already written to disk under the draft's own
  /// id (`PromptAttachment`). Each one put an `[image #N]` placeholder into the brief;
  /// the path replaces it when the prompt is composed (`LoopNode.sessionPrompt`).
  struct DraftAttachments: Equatable {
    var items: [PromptAttachment] = []
    /// How many this draft has ever taken, which is what names their files. Position
    /// would re-use a name: remove the second of three and the next paste is number
    /// three again, landing on a file that is still attached.
    var taken = 0
    /// Why the last paste or drop did nothing — a remote graph, or a file too big.
    /// Shown beside the field and cleared by the next one that works.
    var notice: String?
  }

  enum DraftAttachmentAction: Equatable {
    /// An image arrived on the brief field — pasted over ⌘V or dropped onto it. Carries
    /// the decoded bytes because a pasteboard cannot be read from an effect: its
    /// contents belong to the moment of the keystroke.
    case imageArrived(DraftImageImport.Payload)
    case removed(UUID)
    /// A drop that yielded nothing graphcode could write down.
    case rejected(String)
  }

  func draftAttachment(
    _ state: inout State, _ action: DraftAttachmentAction
  ) -> Effect<Action> {
    switch action {
    case .imageArrived(let payload): return attachDraftImage(&state, payload)
    case .removed(let id): return removeDraftAttachment(&state, id)
    case .rejected(let reason):
      state.draftAttachments.notice = reason
      return .none
    }
  }

  /// Writes a pasted or dropped image down and puts its placeholder in the brief.
  ///
  /// Synchronous, where most of this reducer's work is an effect: the number the file is
  /// named after and the number the placeholder carries have to be decided in the same
  /// breath, and an effect deciding them from a state that has since taken another paste
  /// would hand two images the same name. The write is bounded at
  /// `DraftImageImport.maximumBytes`, which is a few milliseconds of a dialog nobody is
  /// typing into mid-paste.
  func attachDraftImage(
    _ state: inout State, _ payload: DraftImageImport.Payload
  ) -> Effect<Action> {
    // A composite never opens a session, so it has no prompt for a path to travel in —
    // and no prose field for the placeholder to land in either.
    guard state.draftLoopType != .composite else { return .none }
    let projectPath = state.graph.project.path
    // A remote loop runs on another machine, and the ensure dial that delivers
    // graphcode's files there carries text (`ZmxSessionLauncher.remoteDeliveryScript`).
    // A path to a file that host has never seen would read to the agent as a file that
    // isn't there, which is worse than saying so here.
    guard RemoteProjectLocation.parse(projectPath: projectPath) == nil else {
      state.draftAttachments.notice =
        "Images can't be attached to a loop on another machine yet."
      return .none
    }
    let number = state.draftAttachments.taken + 1
    let url = DraftImageImport.destination(
      projectPath: projectPath, nodeID: state.draftID, number: number,
      fileExtension: payload.fileExtension)
    guard DraftImageImport.write(payload, to: url) else {
      state.draftAttachments.notice = "Couldn't save that image."
      return .none
    }
    state.draftAttachments.taken = number
    state.draftAttachments.items.append(PromptAttachment(path: url.path))
    let placeholder = PromptAttachments.token(state.draftAttachments.items.count)
    let brief = state.currentBriefText
    state.setBriefText(brief.isEmpty ? placeholder : brief + " " + placeholder)
    state.draftAttachments.notice = nil
    return .none
  }

  /// Takes the chip, the file, and the placeholder — and renumbers the placeholders
  /// after it, so removing the middle of three doesn't leave one pointing at nothing.
  func removeDraftAttachment(_ state: inout State, _ id: UUID) -> Effect<Action> {
    guard let index = state.draftAttachments.items.firstIndex(where: { $0.id == id })
    else { return .none }
    let total = state.draftAttachments.items.count
    let removed = state.draftAttachments.items.remove(at: index)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: removed.path))
    state.setBriefText(
      PromptAttachments.removing(
        attachment: index + 1, from: state.currentBriefText, of: total))
    state.draftAttachments.notice = nil
    return .none
  }

  /// Closing the dialog without creating anything. The draft's id is a node id nothing
  /// will now create, so its images have no other owner to outlive. A created node's are
  /// left alone: `NodeMemory.remove` takes them when the node itself goes.
  func cancelNodeForm(_ state: inout State) -> Effect<Action> {
    state.showingNewNodeForm = false
    DraftImageImport.discardAll(
      projectPath: state.graph.project.path, nodeID: state.draftID)
    state.draftAttachments = DraftAttachments()
    return .cancel(id: CancelID.templateWatch)
  }
}
