const std = @import("std");

/// Product-level terminal layout. Winghostty owns a surface; this type owns the
/// tabs, pane order, selection, and focus that surround those surfaces.
pub const Direction = enum { horizontal, vertical };

pub const Pane = struct {
    id: []u8,
    launches_agent: bool = false,
};

pub const Tab = struct {
    id: u64,
    panes: std.ArrayList(Pane),
    split_direction: Direction = .horizontal,
    focused_pane: usize = 0,

    fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        for (self.panes.items) |pane| allocator.free(pane.id);
        self.panes.deinit();
    }
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(Tab),
    selected_tab: usize = 0,
    next_tab_id: u64 = 1,
    next_surface_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Layout {
        return .{ .allocator = allocator, .tabs = std.ArrayList(Tab).init(allocator) };
    }

    pub fn deinit(self: *Layout) void {
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit();
    }

    pub fn default(allocator: std.mem.Allocator, node_id: []const u8) !Layout {
        var layout = Layout.init(allocator);
        errdefer layout.deinit();
        try layout.addTab(node_id, true);
        return layout;
    }

    pub fn addTab(self: *Layout, surface_id: []const u8, launches_agent: bool) !void {
        var panes = std.ArrayList(Pane).init(self.allocator);
        errdefer panes.deinit();
        try panes.append(.{
            .id = try self.allocator.dupe(u8, surface_id),
            .launches_agent = launches_agent,
        });
        try self.tabs.append(.{ .id = self.next_tab_id, .panes = panes });
        self.next_tab_id += 1;
        self.selected_tab = self.tabs.items.len - 1;
    }

    pub fn selected(self: *Layout) ?*Tab {
        if (self.selected_tab >= self.tabs.items.len) return null;
        return &self.tabs.items[self.selected_tab];
    }

    pub fn selectTab(self: *Layout, index: usize) void {
        if (index < self.tabs.items.len) self.selected_tab = index;
    }

    pub fn selectRelativeTab(self: *Layout, offset: isize) void {
        if (self.tabs.items.len == 0) return;
        const count: isize = @intCast(self.tabs.items.len);
        const current: isize = @intCast(self.selected_tab);
        self.selected_tab = @intCast(@mod(current + offset, count));
    }

    pub fn splitFocused(self: *Layout, direction: Direction, surface_id: []const u8) !void {
        const tab = self.selected() orelse return error.NoTabs;
        if (tab.focused_pane >= tab.panes.items.len) tab.focused_pane = 0;
        tab.split_direction = direction;
        try tab.panes.insert(tab.focused_pane + 1, .{
            .id = try self.allocator.dupe(u8, surface_id),
        });
        tab.focused_pane += 1;
        self.next_surface_id += 1;
    }

    pub fn closeFocusedPane(self: *Layout) ![]u8 {
        const tab = self.selected() orelse return error.NoTabs;
        if (tab.panes.items.len == 0) return error.NoPanes;
        const index = tab.focused_pane;
        const removed = tab.panes.orderedRemove(index);
        const id = removed.id;
        if (tab.panes.items.len == 0) {
            const closed = self.tabs.orderedRemove(self.selected_tab);
            closed.deinit(self.allocator);
            if (self.selected_tab >= self.tabs.items.len and self.tabs.items.len != 0)
                self.selected_tab = self.tabs.items.len - 1;
        } else {
            const remaining = &self.tabs.items[self.selected_tab];
            if (remaining.focused_pane >= remaining.panes.items.len)
                remaining.focused_pane = remaining.panes.items.len - 1;
        }
        return id;
    }

    pub fn focusPane(self: *Layout, offset: isize) void {
        const tab = self.selected() orelse return;
        if (tab.panes.items.len == 0) return;
        const count: isize = @intCast(tab.panes.items.len);
        const current: isize = @intCast(tab.focused_pane);
        tab.focused_pane = @intCast(@mod(current + offset, count));
    }

    pub fn save(self: *const Layout, file_path: []const u8) !void {
        var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        defer file.close();
        var writer = file.writer();
        try writer.writeAll("{\"selectedTab\":");
        try writer.print("{d},\"tabs\":[", .{self.selected_tab});
        for (self.tabs.items, 0..) |tab, tab_index| {
            if (tab_index != 0) try writer.writeByte(',');
            try writer.print(
                "{{\"id\":{d},\"direction\":\"{s}\",\"focused\":{d},\"panes\":[",
                .{ tab.id, @tagName(tab.split_direction), tab.focused_pane },
            );
            for (tab.panes.items, 0..) |pane, pane_index| {
                if (pane_index != 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":");
                try std.json.stringify(pane.id, .{}, writer);
                try writer.print(",\"agent\":{s}}}", .{if (pane.launches_agent) "true" else "false"});
            }
            try writer.writeAll("]}");
        }
        try writer.writeAll("]}");
    }

    pub fn load(allocator: std.mem.Allocator, file_path: []const u8) !Layout {
        const data = try std.fs.cwd().readFileAlloc(allocator, file_path, 4 * 1024 * 1024);
        defer allocator.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        var layout = Layout.init(allocator);
        errdefer layout.deinit();
        layout.selected_tab = @intCast(root.get("selectedTab").?.integer);
        const tabs = root.get("tabs").?.array.items;
        for (tabs) |encoded_tab| {
            const object = encoded_tab.object;
            var panes = std.ArrayList(Pane).init(allocator);
            errdefer panes.deinit();
            const encoded_panes = object.get("panes").?.array.items;
            for (encoded_panes) |encoded_pane| {
                const pane = encoded_pane.object;
                try panes.append(.{
                    .id = try allocator.dupe(u8, pane.get("id").?.string),
                    .launches_agent = pane.get("agent").?.bool,
                });
            }
            const direction = if (std.mem.eql(u8, object.get("direction").?.string, "vertical"))
                Direction.vertical
            else
                Direction.horizontal;
            try layout.tabs.append(.{
                .id = @intCast(object.get("id").?.integer),
                .panes = panes,
                .split_direction = direction,
                .focused_pane = @intCast(object.get("focused").?.integer),
            });
        }
        layout.next_tab_id = 1;
        for (layout.tabs.items) |tab| layout.next_tab_id = @max(layout.next_tab_id, tab.id + 1);
        return layout;
    }
};

test "tabs, splits, focus, and close preserve live surface identity" {
    var layout = try Layout.default(std.testing.allocator, "node-a");
    defer layout.deinit();
    try layout.addTab("shell-b", false);
    try std.testing.expectEqual(@as(usize, 2), layout.tabs.items.len);
    try layout.splitFocused(.vertical, "shell-c");
    try std.testing.expectEqual(@as(usize, 2), layout.selected().?.panes.items.len);
    try std.testing.expectEqualStrings("shell-c", layout.selected().?.panes.items[1].id);
    layout.focusPane(-1);
    const removed = try layout.closeFocusedPane();
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("shell-b", removed);
    try std.testing.expectEqual(@as(usize, 1), layout.tabs.items.len);
}

test "relative tab selection wraps" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    try layout.addTab("a", true);
    try layout.addTab("b", false);
    layout.selectRelativeTab(1);
    try std.testing.expectEqual(@as(usize, 1), layout.selected_tab);
    layout.selectRelativeTab(1);
    try std.testing.expectEqual(@as(usize, 0), layout.selected_tab);
}

test "layout persists selected tab, split direction, focus, and agent role" {
    var layout = try Layout.default(std.testing.allocator, "node-a");
    defer layout.deinit();
    try layout.addTab("shell-b", false);
    try layout.splitFocused(.vertical, "shell-c");
    try layout.save("workspace-layout-test.json");
    defer std.fs.cwd().deleteFile("workspace-layout-test.json") catch {};

    var restored = try Layout.load(std.testing.allocator, "workspace-layout-test.json");
    defer restored.deinit();
    try std.testing.expectEqual(layout.selected_tab, restored.selected_tab);
    try std.testing.expectEqual(layout.tabs.items.len, restored.tabs.items.len);
    try std.testing.expectEqual(
        layout.tabs.items[1].split_direction,
        restored.tabs.items[1].split_direction,
    );
    try std.testing.expectEqualStrings(
        "shell-c",
        restored.tabs.items[1].panes.items[1].id,
    );
}
