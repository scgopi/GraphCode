# Quick Chats daemon protocol parity

The former protocol gap is implemented in this branch. Quick Chats now use daemon-owned
Codable commands/events, persisted stable UUIDs, activity sequencing, v1/v2 event delivery,
and Windows wire/client APIs.

## Implemented contract

The shared protocol includes:

```swift
case listQuickChats
case createQuickChat(title: String, backend: CLISessionBackendKind)
case openQuickChat(id: UUID)
case renameQuickChat(id: UUID, title: String)
case deleteQuickChat(id: UUID)
```

Add these `DaemonEvent` cases:

```swift
case quickChatsListed([QuickChat])
case quickChatChanged(QuickChat)
case quickChatDeleted(UUID)
case quickChatActivity(id: UUID, activity: String?, presence: PresenceReading?)
```

Every mutation is echoed and broadcast, and stale activity sequences are ignored by clients.
The Windows app exposes production create/open/rename/delete callbacks and keyboard actions.

## Follow-up lifecycle integration

The daemon command surface and launcher integration are complete: open waits for a live
session, reconnect reattaches, and delete confirms termination before removing durable
state. Provider lifecycle validation remains a separately pinned Windows smoke concern.

## Windows provider validation

The accepted provider pin for Quick Chat lifecycle validation is zmx
`029e11d2b19162fb3bdf90c8270237d303b8bfb4`, sourced from
`D:\depot\zmx-worktrees\quickchat-hang\.zig-cache\current-validation\zmx.exe`.
Each isolated run must use a unique `ZMX_DIR` that the provider creates itself (do not
pre-create the root; the provider secures it and returns `AccessDenied` for inherited
roots), unique graph/chat session names, an eight-second command timeout, and recorded
cleanup.
