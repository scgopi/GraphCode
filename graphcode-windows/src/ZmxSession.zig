const std = @import("std");

pub const prefix = "graphcode-";

pub fn nameBuffer(session: []const u8, buffer: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, session, prefix)) return session;
    return std.fmt.bufPrint(buffer, prefix ++ "{s}", .{session});
}

pub fn allocName(allocator: std.mem.Allocator, session: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, session, prefix)) return allocator.dupe(u8, session);
    return std.fmt.allocPrint(allocator, prefix ++ "{s}", .{session});
}

test "canonical zmx session names add the ownership prefix exactly once" {
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings("graphcode-alpha", try nameBuffer("alpha", &storage));
    try std.testing.expectEqualStrings(
        "graphcode-alpha",
        try nameBuffer("graphcode-alpha", &storage),
    );
}
