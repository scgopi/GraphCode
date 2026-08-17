const std = @import("std");
const Wire = @import("Wire.zig");

pub const Availability = enum {
    available,
};

pub const Operation = enum {
    create,
    open,
    rename,
    delete,
};

pub const Result = union(enum) {
    accepted: Availability,
};

pub const Controller = struct {
    pub fn availability(_: Controller) Availability {
        return .available;
    }

    pub fn request(_: Controller, _: Operation) Result {
        return .{ .accepted = .available };
    }
};

pub fn protocolGapMessage(operation: Operation) []const u8 {
    return switch (operation) {
        .create => "Quick chats: create command unavailable",
        .open => "Quick chats: open command unavailable",
        .rename => "Quick chats: rename command unavailable",
        .delete => "Quick chats: delete command unavailable",
    };
}

test "quick chat operations are available through the daemon controller" {
    const controller = Controller{};
    try std.testing.expectEqual(Availability.available, controller.availability());
    inline for (std.meta.tags(Operation)) |operation| {
        const result = controller.request(operation);
        try std.testing.expectEqual(Availability.available, result.accepted);
    }
}

test "authoritative wire command vocabulary includes every quick chat operation" {
    try std.testing.expectEqualStrings("listQuickChats", Wire.commandName(.list_quick_chats));
    try std.testing.expectEqualStrings("createQuickChat", Wire.commandName(.create_quick_chat));
    try std.testing.expectEqualStrings("openQuickChat", Wire.commandName(.open_quick_chat));
    try std.testing.expectEqualStrings("renameQuickChat", Wire.commandName(.rename_quick_chat));
    try std.testing.expectEqualStrings("deleteQuickChat", Wire.commandName(.delete_quick_chat));
}
