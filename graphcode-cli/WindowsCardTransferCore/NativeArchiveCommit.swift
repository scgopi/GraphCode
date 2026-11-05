#if os(Windows)
  import Foundation
  import WinSDK

  public enum CardTransferNativeArchiveCommit {
    private typealias SetInformation =
      @convention(c) (
        HANDLE?, UnsafeMutablePointer<IO_STATUS_BLOCK>?, PVOID?, ULONG, FILE_INFORMATION_CLASS
      ) -> NTSTATUS

    public static func rename(
      archive: HANDLE, parent: HANDLE, filename: String, replaceExisting: Bool
    ) throws {
      guard !filename.isEmpty, filename != ".", filename != "..",
        !filename.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0 == "\0" }),
        let nameOffset = MemoryLayout<FILE_RENAME_INFO>.offset(of: \.FileName)
      else {
        throw CardTransferFailure(
          status: .rejected, message: "An archive commit requires a single destination filename.")
      }
      let name = Array(filename.utf16)
      let byteCount = name.count * MemoryLayout<WCHAR>.size
      let size = MemoryLayout<FILE_RENAME_INFO>.size + byteCount
      guard let nativeSize = ULONG(exactly: size), let nativeNameLength = ULONG(exactly: byteCount)
      else {
        throw CardTransferFailure(
          status: .rejected, message: "The archive destination filename is too long.")
      }
      let module = (Array("ntdll.dll".utf16) + [0]).withUnsafeBufferPointer {
        GetModuleHandleW($0.baseAddress)
      }
      guard let module, let address = GetProcAddress(module, "NtSetInformationFile") else {
        throw CardTransferFailure(
          status: .unavailable,
          message: "The native archive rename API is unavailable (Win32 \(GetLastError())).")
      }
      let setInformation = unsafeBitCast(address, to: SetInformation.self)
      let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: size, alignment: MemoryLayout<FILE_RENAME_INFO>.alignment)
      defer { buffer.deallocate() }
      let info = buffer.bindMemory(to: FILE_RENAME_INFO.self, capacity: 1)
      info.initialize(to: FILE_RENAME_INFO())
      defer { info.deinitialize(count: 1) }
      buffer.storeBytes(of: UInt32(replaceExisting ? 1 : 0), as: UInt32.self)
      info.pointee.RootDirectory = parent
      info.pointee.FileNameLength = nativeNameLength
      name.withUnsafeBytes {
        buffer.advanced(by: nameOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
      }
      // The documented native rename prefix matches FILE_RENAME_INFO. Class 10 preserves
      // RootDirectory; the Win32 class-3 wrapper fails for this held-root relative rename.
      var completion = IO_STATUS_BLOCK()
      withUnsafeMutableBytes(of: &completion) {
        $0.storeBytes(of: NTSTATUS(0x103), as: NTSTATUS.self)
      }
      let status = setInformation(
        archive, &completion, buffer, nativeSize, FILE_INFORMATION_CLASS(rawValue: 10))
      let completed = withUnsafeBytes(of: completion) { $0.load(as: NTSTATUS.self) }
      try requireSynchronousSuccess(returned: status, completed: completed)
    }

    static func requireSynchronousSuccess(returned: NTSTATUS, completed: NTSTATUS) throws {
      guard returned == 0, completed == 0 else {
        throw CardTransferFailure(
          status: .outcomeUnknown,
          message:
            "Export commit did not report synchronous success (NTSTATUS 0x\(String(UInt32(bitPattern: returned), radix: 16)), "
            + "completion 0x\(String(UInt32(bitPattern: completed), radix: 16))). Check the destination before trying again."
        )
      }
    }
  }
#endif
