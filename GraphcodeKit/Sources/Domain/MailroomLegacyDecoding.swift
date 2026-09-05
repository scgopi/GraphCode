import Foundation

/// The spellings a file written before the Artifactory → Mailroom rename uses.
///
/// A dynamic key rather than extra `CodingKeys` cases, for a reason that is easy to
/// discover the hard way: `LoopNode` and `GraphcodeSettings` both hand-write
/// `init(from:)` and let the compiler synthesise `encode(to:)`, and synthesis requires
/// every case to have a matching property. A legacy key has none — and must be read
/// and never written, or the old spelling would outlive the rename in every file the
/// app touches.
private struct MailroomLegacyKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { nil }
}

extension Decoder {
  /// What an older file stored under `key`, or nil — never a throw. A legacy value that
  /// will not decode falls back to the current default instead of failing the whole
  /// read, which for a graph means `ProjectPersistence` reporting "no saved graph" and
  /// for settings means every other preference resetting alongside it.
  func legacyMailroomValue<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
    guard let container = try? container(keyedBy: MailroomLegacyKey.self) else { return nil }
    return (try? container.decodeIfPresent(type, forKey: MailroomLegacyKey(key))) ?? nil
  }
}
