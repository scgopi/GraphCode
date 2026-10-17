import AppKit
import GhosttyKit
import GraphcodeKit

/// The remote agent a surface talks to, when it talks to one: what an image paste needs
/// to know to copy the picture there (issue #819).
struct RemoteImagePasteTarget: Equatable {
  var projectPath: String
  var nodeID: UUID
  var host: String
}

/// Pasting a picture into an agent that runs on another machine.
///
/// The Mac owns the pasteboard and the agent's CLI cannot see it — a `claude` on the
/// remote host reading *its* clipboard finds nothing, and libghostty's paste carries
/// text only. So an image-only paste on a remote agent surface is taken here: the bytes
/// go to the host over ssh (`RemoteAttachmentUpload`) and a sentence naming the remote
/// file is typed into the composer, unsent, for the human to add to.
enum RemoteImagePaste {
  /// ⌘V, and ⌃V — the key Claude Code and Codex read an image paste on.
  static func isPasteKey(_ flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    guard characters?.lowercased() == "v", !flags.contains(.option), !flags.contains(.shift)
    else { return false }
    return flags.contains(.command) != flags.contains(.control)
  }

  /// Generated, never taken from the pasted file: the name is what lands in a remote
  /// path and a typed command line.
  static func fileName(fileExtension: String, now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let suffix = UUID().uuidString.prefix(6).lowercased()
    return "paste-\(formatter.string(from: now))-\(suffix).\(fileExtension.lowercased())"
  }
}

extension GhosttyTerminalNSView {
  /// Takes the keystroke when it is an image paste on a remote agent surface. `false`
  /// hands it on untouched — a text paste, a local surface, a plain shell.
  func interceptRemoteImagePaste(_ event: NSEvent) -> Bool {
    guard let target = remoteImagePaste,
      RemoteImagePaste.isPasteKey(
        event.modifierFlags, characters: event.charactersIgnoringModifiers),
      let payload = DraftImageImport.payload(on: .general)
    else { return false }
    swallowedPasteKeyCode = event.keyCode
    upload(payload, to: target)
    return true
  }

  private func upload(_ payload: DraftImageImport.Payload, to target: RemoteImagePasteTarget) {
    showPasteNotice("Copying image to \(target.host)…", isError: false, sticky: true)
    let fileName = RemoteImagePaste.fileName(fileExtension: payload.fileExtension)
    Task { @MainActor [weak self] in
      do {
        let path = try await RemoteAttachmentUpload.upload(
          payload.data, fileName: fileName, projectPath: target.projectPath,
          nodeID: target.nodeID)
        guard let self else { return }
        guard self.remoteImagePaste == target, !self.processHasExited, let surface = self.surface
        else {
          self.showPasteNotice(
            "The image was copied, but the session ended before it could be referenced.",
            isError: true, sticky: false)
          return
        }
        let text = RemoteAttachmentUpload.composerReference(toImageAt: path)
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        self.hidePasteNotice()
      } catch {
        self?.showPasteNotice(error.localizedDescription, isError: true, sticky: false)
      }
    }
  }

  private func showPasteNotice(_ text: String, isError: Bool, sticky: Bool) {
    let label = pasteNoticeLabel ?? makePasteNoticeLabel()
    label.stringValue = text
    label.textColor = isError ? .systemRed : .secondaryLabelColor
    label.isHidden = false
    pasteNoticeGeneration += 1
    guard !sticky else { return }
    let generation = pasteNoticeGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      guard let self, self.pasteNoticeGeneration == generation else { return }
      self.hidePasteNotice()
    }
  }

  private func hidePasteNotice() {
    pasteNoticeGeneration += 1
    pasteNoticeLabel?.isHidden = true
  }

  private func makePasteNoticeLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.drawsBackground = true
    label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
    ])
    pasteNoticeLabel = label
    return label
  }
}
