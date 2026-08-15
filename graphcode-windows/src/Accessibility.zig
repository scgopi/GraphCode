pub const Announcement = struct {
    role: []const u8,
    name: []const u8,
    state: []const u8,
};

pub fn nodeAnnouncement(title: []const u8, state: []const u8) Announcement {
    return .{ .role = "Graph node", .name = title, .state = state };
}

pub fn terminalAnnouncement(index: usize) Announcement {
    return .{
        .role = "Terminal surface",
        .name = if (index == 0) "GraphCode terminal A" else "GraphCode terminal B",
        .state = "interactive",
    };
}

pub fn log(announcement: Announcement) void {
    _ = announcement;
}
