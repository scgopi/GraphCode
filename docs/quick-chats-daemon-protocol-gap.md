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

The daemon command surface is complete. The remaining integration point is attaching and
terminating the backend zmx session from `openQuickChat`/`deleteQuickChat`; until that hook
is wired, those commands still provide canonical persisted records and events but do not
claim a live terminal session.
