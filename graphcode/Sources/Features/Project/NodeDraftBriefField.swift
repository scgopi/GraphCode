import ComposableArchitecture
import GraphcodeKit
import SwiftUI
import UniformTypeIdentifiers

/// The brief field, plus the pictures attached to it.
///
/// Every loop type has exactly one field that says what the loop is for — the starting
/// note, the goal, the task, the first instruction — and it is the one an image belongs
/// to. Wrapping it once is what keeps the drop target, the chips and the placeholder
/// numbering from being written four times and drifting three ways.
struct DraftBriefField: View {
  @Bindable var store: StoreOf<ProjectFeature>
  let placeholder: String
  @Binding var text: String
  var takesFocusRequest: Binding<Bool>?
  var onTokenJump: (() -> Bool)?

  @State private var isTargeted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DraftProseField(
        placeholder: placeholder, text: $text, takesFocusRequest: takesFocusRequest,
        onTokenJump: onTokenJump
      )
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Theme.paneFocusTint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
      }
      .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
        Task { @MainActor in
          guard let payload = await DraftImageImport.payload(from: providers) else {
            store.send(
              .draftAttachment(.rejected("That isn't an image GraphCode can attach.")))
            return
          }
          store.send(.draftAttachment(.imageArrived(payload)))
        }
        return true
      }
      DraftAttachmentStrip(store: store)
    }
  }
}

/// What is attached, under the field it is attached to: one chip per image, each
/// carrying the placeholder that stands for it in the text so the two can be read
/// against each other. Removing a chip takes the placeholder with it.
struct DraftAttachmentStrip: View {
  @Bindable var store: StoreOf<ProjectFeature>

  var body: some View {
    if !store.draftAttachments.items.isEmpty || store.draftAttachments.notice != nil {
      VStack(alignment: .leading, spacing: 6) {
        if !store.draftAttachments.items.isEmpty {
          HStack(spacing: 8) {
            ForEach(Array(store.draftAttachments.items.enumerated()), id: \.element.id) {
              number, attachment in
              chip(attachment, number: number + 1)
            }
            Spacer(minLength: 0)
          }
        }
        if let notice = store.draftAttachments.notice {
          Text(notice)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func chip(_ attachment: PromptAttachment, number: Int) -> some View {
    HStack(spacing: 6) {
      AttachmentThumbnail(path: attachment.path)
      Text(PromptAttachments.token(number))
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.8))
      Button {
        store.send(.draftAttachment(.removed(attachment.id)))
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.white.opacity(0.55))
      }
      .buttonStyle(.plain)
      .help("Remove this image")
    }
    .padding(.leading, 4)
    .padding(.trailing, 7)
    .padding(.vertical, 4)
    .background(Theme.draftField, in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1)
    }
  }
}

/// A 22pt look at what was attached. Loaded off the main actor and only when the path
/// changes — the dialog re-renders on every keystroke, and decoding a screenshot per
/// character would be felt.
private struct AttachmentThumbnail: View {
  let path: String

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "photo")
          .font(.system(size: 9))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
    .frame(width: 22, height: 22)
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .task(id: path) {
      let loaded = await Task.detached(priority: .utility) {
        NSImage(contentsOfFile: path)
      }.value
      image = loaded
    }
  }
}
