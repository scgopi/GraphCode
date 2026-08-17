const std = @import("std");

pub const Role = enum { window, navigation, list, list_item, button, card, menu, menu_item, text, terminal, status, dialog };
pub const Pattern = enum { invoke, selection, selection_item, expand_collapse, scroll, value, text };
pub const Element = struct {
    id: []const u8,
    name: []const u8,
    role: Role,
    patterns: []const Pattern = &.{},
    focusable: bool = false,
    parent: ?usize = null,
};
pub const Notification = struct { text: []const u8, kind: enum { status, error, focus, action } };
pub const Announcement = struct { role: []const u8, name: []const u8, state: []const u8 };

pub const Provider = struct {
    allocator: std.mem.Allocator,
    elements: std.array_list.Managed(Element),
    focus_order: std.array_list.Managed(usize),
    notifications: std.array_list.Managed(Notification),

    pub fn init(allocator: std.mem.Allocator) Provider {
        return .{
            .allocator = allocator,
            .elements = std.array_list.Managed(Element).init(allocator),
            .focus_order = std.array_list.Managed(usize).init(allocator),
            .notifications = std.array_list.Managed(Notification).init(allocator),
        };
    }
    pub fn deinit(self: *Provider) void {
        self.elements.deinit(); self.focus_order.deinit(); self.notifications.deinit();
    }
    pub fn add(self: *Provider, element: Element) !usize {
        const index = self.elements.items.len;
        try self.elements.append(element);
        if (element.focusable) try self.focus_order.append(index);
        return index;
    }
    pub fn announce(self: *Provider, text: []const u8, kind: Notification.kind) !void {
        try self.notifications.append(.{ .text = text, .kind = kind });
    }
    pub fn nextFocus(self: *const Provider, current: ?usize) ?usize {
        if (self.focus_order.items.len == 0) return null;
        if (current) |value| for (self.focus_order.items, 0..) |index, offset| {
            if (index == value) return self.focus_order.items[(offset + 1) % self.focus_order.items.len];
        };
        return self.focus_order.items[0];
    }
    pub fn hasPattern(self: *const Provider, index: usize, pattern: Pattern) bool {
        if (index >= self.elements.items.len) return false;
        for (self.elements.items[index].patterns) |candidate| if (candidate == pattern) return true;
        return false;
    }
};

pub fn defaultContract(allocator: std.mem.Allocator) !Provider {
    var provider = Provider.init(allocator);
    errdefer provider.deinit();
    const window = try provider.add(.{ .id = "window", .name = "GraphCode Windows", .role = .window });
    const sidebar = try provider.add(.{ .id = "sidebar", .name = "Navigation", .role = .navigation, .parent = window });
    _ = try provider.add(.{ .id = "projects", .name = "Projects", .role = .list, .parent = sidebar, .focusable = true, .patterns = &.{ .selection, .scroll } });
    _ = try provider.add(.{ .id = "loops", .name = "Loops", .role = .list, .parent = sidebar, .focusable = true, .patterns = &.{ .selection, .scroll } });
    _ = try provider.add(.{ .id = "worktrees", .name = "Worktrees", .role = .list, .parent = sidebar, .focusable = true, .patterns = &.{ .selection, .scroll } });
    _ = try provider.add(.{ .id = "graph", .name = "Graph", .role = .navigation, .parent = window });
    _ = try provider.add(.{ .id = "graph-card", .name = "Graph card", .role = .card, .parent = 5, .focusable = true, .patterns = &.{ .selection, .invoke } });
    const menu = try provider.add(.{ .id = "actions", .name = "Actions", .role = .menu, .parent = window, .focusable = true, .patterns = &.{ .expand_collapse } });
    _ = try provider.add(.{ .id = "inspect-worktrees", .name = "Inspect worktrees", .role = .menu_item, .parent = menu, .patterns = &.{ .invoke } });
    _ = try provider.add(.{ .id = "reclaim-worktrees", .name = "Reclaim selected worktrees", .role = .menu_item, .parent = menu, .patterns = &.{ .invoke } });
    _ = try provider.add(.{ .id = "reveal-worktree", .name = "Reveal in Explorer", .role = .menu_item, .parent = menu, .patterns = &.{ .invoke } });
    _ = try provider.add(.{ .id = "terminal-a", .name = "Terminal A", .role = .terminal, .parent = window, .focusable = true, .patterns = &.{ .text, .scroll } });
    _ = try provider.add(.{ .id = "terminal-b", .name = "Terminal B", .role = .terminal, .parent = window, .focusable = true, .patterns = &.{ .text, .scroll } });
    _ = try provider.add(.{ .id = "status", .name = "Status", .role = .status, .parent = window });
    _ = try provider.add(.{ .id = "errors", .name = "Errors", .role = .status, .parent = window });
    return provider;
}

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

test "UIA contract exposes named roles patterns and deterministic focus order" {
    var provider = try defaultContract(std.testing.allocator);
    defer provider.deinit();
    try std.testing.expectEqual(Role.navigation, provider.elements.items[1].role);
    try std.testing.expect(provider.hasPattern(2, .selection));
    try std.testing.expect(provider.hasPattern(11, .text));
    try std.testing.expectEqual(@as(?usize, 3), provider.nextFocus(2));
    try std.testing.expectEqual(@as(?usize, 4), provider.nextFocus(3));
}

test "status and error announcements are retained for screen readers" {
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try provider.announce("Worktrees inspected", .status);
    try provider.announce("Reclaim blocked: unpushed commits", .error);
    try std.testing.expectEqual(@as(usize, 2), provider.notifications.items.len);
}
