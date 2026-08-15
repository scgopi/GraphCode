const std = @import("std");

pub const schema_version: i64 = 2;
pub const Direction = enum { horizontal, vertical };

pub const Pane = struct {
    id: []u8,
    launches_agent: bool = false,
};

pub const Tab = struct {
    id: u64,
    panes: std.ArrayListUnmanaged(Pane),
    split_direction: Direction = .horizontal,
    focused_pane: usize = 0,

    fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        for (self.panes.items) |pane| allocator.free(pane.id);
        self.panes.deinit(allocator);
    }
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    project_key: []u8,
    tabs: std.ArrayListUnmanaged(Tab) = .empty,
    selected_tab: usize = 0,
    next_tab_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, project_key: []const u8) !Layout {
        return .{
            .allocator = allocator,
            .project_key = try allocator.dupe(u8, project_key),
        };
    }

    pub fn deinit(self: *Layout) void {
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        self.allocator.free(self.project_key);
    }

    pub fn default(allocator: std.mem.Allocator, project_key: []const u8, node_id: []const u8) !Layout {
        var layout = try Layout.init(allocator, project_key);
        errdefer layout.deinit();
        try layout.addTab(node_id, true);
        return layout;
    }

    pub fn addTab(self: *Layout, surface_id: []const u8, launches_agent: bool) !void {
        try self.validateNewID(surface_id);
        var panes: std.ArrayListUnmanaged(Pane) = .empty;
        errdefer panes.deinit(self.allocator);
        try panes.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, surface_id),
            .launches_agent = launches_agent,
        });
        try self.tabs.append(self.allocator, .{ .id = self.next_tab_id, .panes = panes });
        self.next_tab_id += 1;
        self.selected_tab = self.tabs.items.len - 1;
    }

    pub fn newSurfaceID(self: *Layout) ![]u8 {
        var bytes: [16]u8 = undefined;
        var output: [36]u8 = undefined;
        while (true) {
            std.crypto.random.bytes(&bytes);
            var output_index: usize = 0;
            for (bytes) |byte| {
                while (output_index == 8 or output_index == 13 or output_index == 18 or output_index == 23)
                    output_index += 1;
                const hex = "0123456789abcdef";
                output[output_index] = hex[byte >> 4];
                output[output_index + 1] = hex[byte & 0x0f];
                output_index += 2;
            }
            output[8] = '-';
            output[13] = '-';
            output[18] = '-';
            output[23] = '-';
            if (!self.idExists(output[0..])) return self.allocator.dupe(u8, output[0..]);
        }
    }

    pub fn selected(self: *Layout) ?*Tab {
        if (self.selected_tab >= self.tabs.items.len) return null;
        return &self.tabs.items[self.selected_tab];
    }

    pub fn selectedConst(self: *const Layout) ?*const Tab {
        if (self.selected_tab >= self.tabs.items.len) return null;
        return &self.tabs.items[self.selected_tab];
    }

    pub fn selectTab(self: *Layout, index: usize) !void {
        if (index >= self.tabs.items.len) return error.InvalidTab;
        self.selected_tab = index;
    }

    pub fn selectRelativeTab(self: *Layout, offset: isize) void {
        if (self.tabs.items.len == 0) return;
        const count: isize = @intCast(self.tabs.items.len);
        const current: isize = @intCast(self.selected_tab);
        self.selected_tab = @intCast(@mod(current + offset, count));
    }

    pub fn splitFocused(self: *Layout, direction: Direction, surface_id: []const u8) !void {
        const tab = self.selected() orelse return error.NoTabs;
        try self.validateNewID(surface_id);
        if (tab.focused_pane >= tab.panes.items.len) return error.InvalidFocus;
        tab.split_direction = direction;
        try tab.panes.insert(self.allocator, tab.focused_pane + 1, .{
            .id = try self.allocator.dupe(u8, surface_id),
        });
        tab.focused_pane += 1;
    }

    pub fn closeFocusedPane(self: *Layout) ![]u8 {
        const tab = self.selected() orelse return error.NoTabs;
        if (tab.panes.items.len == 0 or tab.focused_pane >= tab.panes.items.len)
            return error.InvalidTopology;
        const removed = tab.panes.orderedRemove(tab.focused_pane);
        const id = removed.id;
        if (tab.panes.items.len == 0) {
            var closed = self.tabs.orderedRemove(self.selected_tab);
            closed.deinit(self.allocator);
            if (self.selected_tab >= self.tabs.items.len and self.tabs.items.len != 0)
                self.selected_tab = self.tabs.items.len - 1;
        } else if (tab.focused_pane >= tab.panes.items.len) {
            tab.focused_pane = tab.panes.items.len - 1;
        }
        return id;
    }

    pub fn removePane(self: *Layout, id: []const u8) bool {
        for (self.tabs.items, 0..) |*tab, tab_index| {
            for (tab.panes.items, 0..) |pane, pane_index| {
                if (!std.mem.eql(u8, pane.id, id)) continue;
                self.allocator.free(pane.id);
                _ = tab.panes.orderedRemove(pane_index);
                if (tab.panes.items.len == 0) {
                    var removed_tab = self.tabs.orderedRemove(tab_index);
                    removed_tab.deinit(self.allocator);
                    if (self.selected_tab >= self.tabs.items.len and self.tabs.items.len != 0)
                        self.selected_tab = self.tabs.items.len - 1;
                } else if (tab.focused_pane >= tab.panes.items.len) {
                    tab.focused_pane = tab.panes.items.len - 1;
                }
                return true;
            }
        }
        return false;
    }

    pub fn focusPane(self: *Layout, offset: isize) !void {
        const tab = self.selected() orelse return error.NoTabs;
        if (tab.panes.items.len == 0 or tab.focused_pane >= tab.panes.items.len)
            return error.InvalidFocus;
        const count: isize = @intCast(tab.panes.items.len);
        tab.focused_pane = @intCast(@mod(@as(isize, @intCast(tab.focused_pane)) + offset, count));
    }

    pub fn save(self: *const Layout, file_path: []const u8) !void {
        if (self.tabs.items.len == 0 or self.selected_tab >= self.tabs.items.len)
            return error.InvalidTopology;
        try self.validateTopology();
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
        defer self.allocator.free(tmp_path);
        var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        try writer.interface.writeAll("{\"schemaVersion\":2,\"project\":");
        try writer.interface.print("{f}", .{std.json.fmt(self.project_key, .{})});
        try writer.interface.print(",\"selectedTab\":{d},\"tabs\":[", .{self.selected_tab});
        for (self.tabs.items, 0..) |tab, tab_index| {
            if (tab_index != 0) try writer.interface.writeByte(',');
            try writer.interface.print(
                "{{\"id\":{d},\"direction\":\"{s}\",\"focused\":{d},\"panes\":[",
                .{ tab.id, @tagName(tab.split_direction), tab.focused_pane },
            );
            for (tab.panes.items, 0..) |pane, pane_index| {
                if (pane_index != 0) try writer.interface.writeByte(',');
                try writer.interface.print(
                    "{{\"id\":{f},\"agent\":{s}}}",
                    .{ std.json.fmt(pane.id, .{}), if (pane.launches_agent) "true" else "false" },
                );
            }
            try writer.interface.writeAll("]}");
        }
        try writer.interface.writeAll("]}");
        try writer.interface.flush();
        file.close();
        try std.fs.cwd().rename(tmp_path, file_path);
    }

    pub fn load(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        expected_project: []const u8,
    ) !Layout {
        const data = try std.fs.cwd().readFileAlloc(allocator, file_path, 4 * 1024 * 1024);
        defer allocator.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();
        const root = try object(parsed.value);
        const version = try integer(try field(root, "schemaVersion"));
        if (version != schema_version) return error.UnsupportedSchema;
        const project = try string(try field(root, "project"));
        if (!std.mem.eql(u8, project, expected_project)) return error.ProjectMismatch;
        const selected_index = try nonNegativeIndex(try field(root, "selectedTab"));
        const values = try array(try field(root, "tabs"));
        var layout = try Layout.init(allocator, expected_project);
        errdefer layout.deinit();
        layout.selected_tab = selected_index;
        for (values) |encoded| {
            const tab_object = try object(encoded);
            const tab_id = try positiveU64(try field(tab_object, "id"));
            const direction_name = try string(try field(tab_object, "direction"));
            const direction = if (std.mem.eql(u8, direction_name, "horizontal"))
                Direction.horizontal
            else if (std.mem.eql(u8, direction_name, "vertical"))
                Direction.vertical
            else
                return error.InvalidDirection;
            const focused = try nonNegativeIndex(try field(tab_object, "focused"));
            const pane_values = try array(try field(tab_object, "panes"));
            if (pane_values.len == 0 or focused >= pane_values.len) return error.InvalidTopology;
            var panes: std.ArrayListUnmanaged(Pane) = .empty;
            errdefer {
                for (panes.items) |pane| allocator.free(pane.id);
                panes.deinit(allocator);
            }
            for (pane_values) |encoded_pane| {
                const pane_object = try object(encoded_pane);
                const id = try string(try field(pane_object, "id"));
                if (id.len == 0 or id.len > 128 or layout.idExists(id)) return error.DuplicateSurfaceID;
                for (panes.items) |existing| {
                    if (std.mem.eql(u8, existing.id, id)) return error.DuplicateSurfaceID;
                }
                const agent = try boolean(try field(pane_object, "agent"));
                try panes.append(allocator, .{
                    .id = try allocator.dupe(u8, id),
                    .launches_agent = agent,
                });
            }
            try layout.tabs.append(allocator, .{
                .id = tab_id,
                .panes = panes,
                .split_direction = direction,
                .focused_pane = focused,
            });
        }
        if (layout.tabs.items.len == 0 or layout.selected_tab >= layout.tabs.items.len)
            return error.InvalidTopology;
        try layout.validateTopology();
        layout.next_tab_id = 1;
        for (layout.tabs.items) |tab| layout.next_tab_id = @max(layout.next_tab_id, tab.id + 1);
        return layout;
    }

    fn validateNewID(self: *const Layout, id: []const u8) !void {
        if (id.len == 0 or id.len > 128 or self.idExists(id)) return error.DuplicateSurfaceID;
    }

    fn idExists(self: *const Layout, id: []const u8) bool {
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| {
            if (std.mem.eql(u8, pane.id, id)) return true;
        };
        return false;
    }

    fn validateTopology(self: *const Layout) !void {
        if (self.tabs.items.len == 0 or self.selected_tab >= self.tabs.items.len)
            return error.InvalidTopology;
        var ids = std.StringHashMap(void).init(self.allocator);
        defer ids.deinit();
        for (self.tabs.items) |tab| {
            if (tab.id == 0 or tab.panes.items.len == 0 or tab.focused_pane >= tab.panes.items.len)
                return error.InvalidTopology;
            for (tab.panes.items) |pane| {
                if (pane.id.len == 0 or pane.id.len > 128 or ids.contains(pane.id))
                    return error.InvalidTopology;
                try ids.put(pane.id, {});
            }
        }
    }
};

fn field(object_value: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object_value.get(name) orelse error.MissingField;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |value_object| value_object,
        else => error.ExpectedObject,
    };
}

fn array(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |value_array| value_array.items,
        else => error.ExpectedArray,
    };
}

fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |value_string| value_string,
        else => error.ExpectedString,
    };
}

fn boolean(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |value_bool| value_bool,
        else => error.ExpectedBoolean,
    };
}

fn integer(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |value_integer| value_integer,
        else => error.ExpectedInteger,
    };
}

fn nonNegativeIndex(value: std.json.Value) !usize {
    const number = try integer(value);
    if (number < 0) return error.NegativeIndex;
    return std.math.cast(usize, number) orelse error.IndexOverflow;
}

fn positiveU64(value: std.json.Value) !u64 {
    const number = try integer(value);
    if (number <= 0) return error.InvalidIdentifier;
    return std.math.cast(u64, number) orelse error.IdentifierOverflow;
}

test "validated persistence rejects corruption and scopes projects" {
    var layout = try Layout.default(std.testing.allocator, "project-a", "node-a");
    defer layout.deinit();
    try layout.save("workspace-layout-test.json");
    defer std.fs.cwd().deleteFile("workspace-layout-test.json") catch {};
    var restored = try Layout.load(std.testing.allocator, "workspace-layout-test.json", "project-a");
    restored.deinit();
    try std.testing.expectError(error.ProjectMismatch, Layout.load(
        std.testing.allocator,
        "workspace-layout-test.json",
        "project-b",
    ));
}

test "generated surface IDs are unique across tabs" {
    var layout = try Layout.init(std.testing.allocator, "project");
    defer layout.deinit();
    const first = try layout.newSurfaceID();
    defer std.testing.allocator.free(first);
    const second = try layout.newSurfaceID();
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "validated persistence rejects malformed topology" {
    const cases = [_]struct {
        json: []const u8,
        expected: anyerror,
    }{
        .{ .json = "{\"schemaVersion\":2,\"project\":\"p\",\"tabs\":[]}", .expected = error.MissingField },
        .{ .json = "{\"schemaVersion\":2,\"project\":\"p\",\"selectedTab\":-1,\"tabs\":[]}", .expected = error.NegativeIndex },
        .{ .json = "{\"schemaVersion\":2,\"project\":\"p\",\"selectedTab\":0,\"tabs\":[{\"id\":1,\"direction\":\"diagonal\",\"focused\":0,\"panes\":[{\"id\":\"a\",\"agent\":false}]}]}", .expected = error.InvalidDirection },
        .{ .json = "{\"schemaVersion\":2,\"project\":\"p\",\"selectedTab\":0,\"tabs\":[{\"id\":1,\"direction\":\"horizontal\",\"focused\":0,\"panes\":[{\"id\":\"a\",\"agent\":false},{\"id\":\"a\",\"agent\":false}]}]}", .expected = error.DuplicateSurfaceID },
    };
    for (cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "workspace-corrupt-{d}.json", .{index});
        defer std.testing.allocator.free(path);
        defer std.fs.cwd().deleteFile(path) catch {};
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = case.json });
        try std.testing.expectError(case.expected, Layout.load(std.testing.allocator, path, "p"));
    }
}
