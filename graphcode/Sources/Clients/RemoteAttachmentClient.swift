import ComposableArchitecture
import Foundation
import GraphcodeKit

/// Copies a draft's images to the machine a remote loop will run on (issue #819). See
/// `RemoteAttachmentUpload`.
struct RemoteAttachmentClient: Sendable {
  /// The absolute path of the uploaded file on the remote host.
  var upload:
    @Sendable (_ data: Data, _ fileName: String, _ projectPath: String, _ nodeID: UUID)
      async throws -> String
  /// Best-effort removal of what a draft that was never created uploaded.
  var discard: @Sendable (_ projectPath: String, _ nodeID: UUID) -> Void
}

extension RemoteAttachmentClient: DependencyKey {
  static let liveValue = RemoteAttachmentClient(
    upload: { data, fileName, projectPath, nodeID in
      try await RemoteAttachmentUpload.upload(
        data, fileName: fileName, projectPath: projectPath, nodeID: nodeID)
    },
    discard: { projectPath, nodeID in
      // The draft uploaded moments ago, so even a Codespace is running.
      RemoteAttachmentUpload.removeRemoteMemory(
        projectPath: projectPath, nodeID: nodeID, includingCodespace: true)
    })

  static let testValue = RemoteAttachmentClient(
    upload: { _, _, _, _ in throw RemoteAttachmentUploadError.failed("not stubbed") },
    discard: { _, _ in })
}

extension DependencyValues {
  var remoteAttachmentClient: RemoteAttachmentClient {
    get { self[RemoteAttachmentClient.self] }
    set { self[RemoteAttachmentClient.self] = newValue }
  }
}
