import AppKit
import ComposableArchitecture
import GraphcodeKit
import SwiftUI
import UniformTypeIdentifiers

/// Getting a picture out of the pasteboard, or off a drag, and onto disk where a loop's
/// prompt can name it (`PromptAttachment`).
///
/// The bytes are read here, in the view layer, because that is the only place they exist:
/// a pasteboard is a live thing whose contents can change between the keystroke and any
/// effect that runs afterwards.
enum DraftImageImport {
  /// What a paste or a drop yielded — already decoded, so the reducer never touches a
  /// pasteboard and a test never needs one.
  struct Payload: Equatable, Sendable {
    var data: Data
    var fileExtension: String
  }

  /// Bigger than this is refused. An agent reads a screenshot, not a poster, and every
  /// byte here is written synchronously while the dialog is open.
  static let maximumBytes = 10 * 1024 * 1024

  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp",
  ]

  /// The image on `pasteboard`, or `nil` to let ⌘V mean what it has always meant.
  ///
  /// **A pasteboard carrying both a picture and text is read as text.** Copying a
  /// selection out of a rich-text editor puts a TIFF rendering of it on the pasteboard
  /// beside the words, and swallowing that paste would lose something the human meant to
  /// type into the field. Missing an image paste costs nothing — the same picture can be
  /// dragged in — where eating a text paste is a keystroke that silently did nothing.
  /// A copied image *file* is unambiguous and wins regardless.
  static func payload(on pasteboard: NSPasteboard) -> Payload? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
      let url = urls.first(where: { imageExtensions.contains($0.pathExtension.lowercased()) })
    {
      return payload(ofFileAt: url)
    }
    guard pasteboard.string(forType: .string) == nil else { return nil }
    if let png = pasteboard.data(forType: .png), png.count <= maximumBytes {
      return Payload(data: png, fileExtension: "png")
    }
    if let tiff = pasteboard.data(forType: .tiff) { return pngPayload(fromTIFF: tiff) }
    return nil
  }

  static func payload(ofFileAt url: URL) -> Payload? {
    guard imageExtensions.contains(url.pathExtension.lowercased()),
      let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= maximumBytes
    else { return nil }
    return Payload(data: data, fileExtension: url.pathExtension.lowercased())
  }

  private static func pngPayload(fromTIFF tiff: Data) -> Payload? {
    guard let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
      png.count <= maximumBytes
    else { return nil }
    return Payload(data: png, fileExtension: "png")
  }

  /// Whatever the drag carried, as the same payload a paste produces. `nil` for a drag
  /// of something that isn't an image graphcode can write down.
  static func payload(from providers: [NSItemProvider]) async -> Payload? {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
        let url = await loadFileURL(from: provider), let payload = payload(ofFileAt: url)
      {
        return payload
      }
      for type in [UTType.png, UTType.jpeg, UTType.tiff, UTType.image] {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier),
          let data = await loadData(from: provider, type: type)
        else { continue }
        if type == .tiff { return pngPayload(fromTIFF: data) }
        guard data.count <= maximumBytes else { return nil }
        return Payload(data: data, fileExtension: type == .jpeg ? "jpg" : "png")
      }
    }
    return nil
  }

  private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url)
      }
    }
  }

  private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }

  /// Where the `number`-th image of a draft lands. Named by position rather than by
  /// whatever the source file was called: the name is what the agent sees in the path,
  /// and `IMG_4821 (1).png` says less than `image-2.png` about which placeholder it is.
  static func destination(
    projectPath: String, nodeID: UUID, number: Int, fileExtension: String
  ) -> URL {
    NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
      .appendingPathComponent("image-\(number).\(fileExtension)")
  }

  static func write(_ payload: Payload, to url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try payload.data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  /// Drops a cancelled draft's images. The form's id is a node id nothing will ever
  /// create, so its directory has no other owner to outlive.
  static func discardAll(projectPath: String, nodeID: UUID) {
    try? FileManager.default.removeItem(
      at: NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID))
  }
}

/// ⌘V, caught before the focused field can spend it on nothing.
///
/// A SwiftUI `TextField`'s field editor owns the keystroke and accepts only text, so a
/// pasted screenshot lands nowhere and the human sees the dialog do nothing at all. A
/// local monitor reads the pasteboard itself and decides: an image is taken, anything
/// else is handed straight back to the field. Installed only while the dialog is on
/// screen — and the dialog is a sheet, so nothing behind it can own the keyboard
/// meanwhile.
struct DraftImagePasteCatcher: ViewModifier {
  var isEnabled: Bool
  let onImage: (DraftImageImport.Payload) -> Void

  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear { install() }
      .onDisappear { remove() }
      .onChange(of: isEnabled) { _, _ in
        remove()
        install()
      }
  }

  private func install() {
    guard isEnabled, monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.contains(.command),
        !event.modifierFlags.contains(.option),
        event.charactersIgnoringModifiers?.lowercased() == "v",
        let payload = DraftImageImport.payload(on: .general)
      else { return event }
      onImage(payload)
      return nil
    }
  }

  private func remove() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

extension View {
  func catchingPastedImages(
    isEnabled: Bool, onImage: @escaping (DraftImageImport.Payload) -> Void
  ) -> some View {
    modifier(DraftImagePasteCatcher(isEnabled: isEnabled, onImage: onImage))
  }
}
