const std = @import("std");
const Wire = @import("Wire.zig");

/// Quick chats are intentionally not emulated by the Windows shell. The authoritative
/// daemon protocol has no chat command or event, so exposing local-only chats would make
/// their identity and lifetime diverge from the other clients.
pub const Availability = enum {
    blocked_protocol_gap,
};

pub const Operation = enum {
    create,
    open,
    rename,
    delete,
};

pub const Result = union(enum) {
    unavailable: Availability,
};

pub const Controller = struct {
    pub fn availability(_: Controller) Availability {
        return .blocked_protocol_gap;
    }

    pub fn request(_: Controller, _: Operation) Result {
        return .{ .unavailable = .blocked_protocol_gap };
    }
};

pub fn protocolGapMessage(operation: Operation) []const u8 {
    return switch (operation) {
        .create => "Quick chats blocked: daemon protocol has no create-chat command",
        .open => "Quick chats blocked: daemon protocol has no open-chat command",
        .rename => "Quick chats blocked: daemon protocol has no rename-chat command",
        .delete => "Quick chats blocked: daemon protocol has no delete-chat command",
    };
}

test "quick chat operations stay explicitly unavailable until daemon protocol support exists" {
    const controller = Controller{};
    try std.testing.expectEqual(Availability.blocked_protocol_gap, controller.availability());
    inline for (std.meta.tags(Operation)) |operation| {
        const result = controller.request(operation);
        try std.testing.expectEqual(Availability.blocked_protocol_gap, result.unavailable);
        try std.testing.expect(std.mem.indexOf(u8, protocolGapMessage(operation), "protocol") != null);
    }

    test "authoritative wire command vocabulary has no quick chat operation" {
        inline for (std.meta.tags(Wire.CommandKind)) |kind| {
            const name = Wire.commandName(kind);
            try std.testing.expect(std.mem.indexOf(u8, name, "Chat") == null);
            try std.testing.expect(std.mem.indexOf(u8, name, "chat") == null);
        }
    }
}
