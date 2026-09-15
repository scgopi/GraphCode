#if os(Windows)
  public actor AwakeAssertion {
    public static let shared = AwakeAssertion()

    public static func shouldStayAwake(runningLoops: Int, enabled: Bool) -> Bool {
      enabled && runningLoops > 0
    }

    public func apply(shouldHold: Bool, runningLoops: Int) {}
  }
#endif
