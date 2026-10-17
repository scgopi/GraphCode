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
    /// Why the last paste, drop or upload did nothing. Shown beside the field and
    /// cleared by the next one that works.
    var notice: String?
    /// A remote graph's images, by attachment id, once Create has copied them to the
    /// host the loop will run on. `items` keep the local staging path so the chips can
    /// still draw a thumbnail.
    var remotePaths: [UUID: String] = [:]
    var isUploading = false
    /// Whether anything may have reached the remote host, so a cancelled draft knows to
    /// clean up after itself there.
    var hasUploaded = false
  }

  enum DraftAttachmentAction: Equatable {
    /// An image arrived on the brief field — pasted over ⌘V or dropped onto it. Carries
    /// the decoded bytes because a pasteboard cannot be read from an effect: its
    /// contents belong to the moment of the keystroke.
    case imageArrived(DraftImageImport.Payload)
    case removed(UUID)
    /// A drop that yielded nothing graphcode could write down.
    case rejected(String)
    /// Every image of a remote draft reached its host; Create can go ahead.
    /// Carries the draft's id: a reply for a draft that was cancelled must not create
    /// whatever draft the form holds now.
    case uploaded(draftID: UUID, paths: [UUID: String])
    case uploadFailed(draftID: UUID, reason: String)
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
    case .uploaded(let draftID, let paths):
      guard draftID == state.draftID, state.draftAttachments.isUploading else { return .none }
      state.draftAttachments.isUploading = false
      state.draftAttachments.remotePaths.merge(paths) { $1 }
      let created = confirmCreateNode(&state)
      guard !state.showingNewNodeForm else { return created }
      DraftImageImport.discardAll(projectPath: state.graph.project.path, nodeID: state.draftID)
      return created
    case .uploadFailed(let draftID, let reason):
      guard draftID == state.draftID else { return .none }
      state.draftAttachments.isUploading = false
      state.draftAttachments.notice = reason
      return .none
    }
  }

  /// Create, for a draft whose images may first have to reach a remote host.
  func confirmCreateNodeAfterUploads(_ state: inout State) -> Effect<Action> {
    let pending = pendingRemoteUploads(state)
    guard !pending.isEmpty, state.draft.isValid else { return confirmCreateNode(&state) }
    return uploadDraftAttachments(&state, pending)
  }

  /// The images a remote draft still has to copy to its host before Create may send the
  /// node — whose prompt would otherwise name files that host has never seen. Empty for
  /// a local graph, and once every image is up.
  func pendingRemoteUploads(_ state: State) -> [PromptAttachment] {
    guard RemoteProjectLocation.parse(projectPath: state.graph.project.path) != nil else {
      return []
    }
    return state.draftAttachments.items.filter { state.draftAttachments.remotePaths[$0.id] == nil }
  }

  /// Copies a remote draft's images, then comes back through `.uploaded` to create the
  /// node. The form stays open throughout, so a failure leaves the human a draft to retry
  /// rather than a loop whose prompt names a missing file.
  func uploadDraftAttachments(
    _ state: inout State, _ pending: [PromptAttachment]
  ) -> Effect<Action> {
    guard !state.draftAttachments.isUploading else { return .none }
    state.draftAttachments.isUploading = true
    state.draftAttachments.hasUploaded = true
    state.draftAttachments.notice = "Copying images to the remote machine…"
    let projectPath = state.graph.project.path
    let nodeID = state.draftID
    return .run { send in
      var paths: [UUID: String] = [:]
      do {
        for attachment in pending {
          let local = URL(fileURLWithPath: attachment.path)
          let data = try Data(contentsOf: local)
          paths[attachment.id] = try await remoteAttachmentClient.upload(
            data, local.lastPathComponent, projectPath, nodeID)
        }
      } catch {
        await send(
          .draftAttachment(.uploadFailed(draftID: nodeID, reason: error.localizedDescription)))
        return
      }
      await send(.draftAttachment(.uploaded(draftID: nodeID, paths: paths)))
    }
    .cancellable(id: CancelID.draftUpload, cancelInFlight: true)
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
    guard !state.draftAttachments.isUploading else { return .none }
    // A remote graph's images are staged here too, and copied to the host only when
    // Create is pressed (`uploadDraftAttachments`) — a draft that is cancelled never
    // dials, nor starts a stopped Codespace.
    let projectPath = state.graph.project.path
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
    guard !state.draftAttachments.isUploading,
      let index = state.draftAttachments.items.firstIndex(where: { $0.id == id })
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
    if state.draftAttachments.hasUploaded {
      remoteAttachmentClient.discard(state.graph.project.path, state.draftID)
    }
    state.draftAttachments = DraftAttachments()
    return .merge(.cancel(id: CancelID.templateWatch), .cancel(id: CancelID.draftUpload))
  }
}
