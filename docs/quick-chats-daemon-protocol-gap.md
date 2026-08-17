# Quick Chats daemon protocol gap

## Ready-to-file issue

**Title:** Add shared daemon-owned Quick Chat commands, snapshots, and activity events

The macOS implementation currently stores `QuickChat` records in
`GraphcodeKit/Sources/QuickChatStore.swift` under the app support directory and owns the
zmx session directly. `DaemonCommand`/`DaemonEvent` have no Quick Chat cases, so a Windows
client cannot implement parity without inventing a second persistence and lifecycle
protocol.

### Required contract

Add these `DaemonCommand` cases:

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

`QuickChat` must remain keyed by stable UUID, persist atomically under the daemon support
directory, and use the same backend/session lifecycle hooks as a composite session.
`openQuickChat` must return the canonical record and ensure/attach its zmx session; delete
must terminate that session before removing persistence. Every mutation must be echoed to
the requesting v2 client and broadcast to subscribed clients. v1 should receive the same
event-shaped compatibility frames used by graph mutations.

## Dependent todo / acceptance contract

1. **GraphcodeKit model:** move the persisted Quick Chat record and store behind a daemon
   service; add Codable command/event cases and round-trip tests.
2. **ProjectRegistry:** own the service, route all five commands, and broadcast snapshots
   plus activity/presence updates.
3. **graphcoded:** wire session ensure/terminate and activity polling to the service.
4. **macOS app:** replace `QuickChatStore` file mutations with daemon requests while
   retaining the existing canvas and rename/delete UI.
5. **Windows shell:** replace `QuickChats.Controller`'s `blocked_protocol_gap` result with
   wire encoders/decoders and reachable create/open/rename/delete actions.
6. **Acceptance:** two clients observe identical list/order, rename/delete survive daemon
   restart, open reattaches the stable zmx session, activity updates do not reorder
   unrelated chats, and no client reports a chat as available before the negotiated daemon
   version advertises these cases.

Until this contract lands, Quick Chats remain intentionally **blocked**, not “available”
through a local-only Windows implementation.
