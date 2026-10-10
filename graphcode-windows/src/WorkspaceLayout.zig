const std = @import("std");

pub const schema_version: i64 = 2;
pub const Direction = enum { horizontal, vertical };

pub const Pane = struct {
    id: []u8,
    launches_agent: bool = false,
};

pub const ClosedPane = struct {
    id: []u8,
    launches_agent: bool,
    tab_id: u64,
    tab_index: usize,
    pane_index: usize,
    split_direction: Direction,
    focused_pane: usize,
    selected_tab: usize,

    pub fn deinit(self: *ClosedPane, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
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
    /// The graph loop this layout belongs to; empty for a project-level layout.
    loop_key: []u8 = &.{},
    tabs: std.ArrayListUnmanaged(Tab) = .empty,
    selected_tab: usize = 0,
    next_tab_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, project_key: []const u8) !Layout {
        return .{
            .allocator = allocator,
            .project_key = try allocator.dupe(u8, project_key),
        };
    }

    pub fn initForLoop(allocator: std.mem.Allocator, project_key: []const u8, loop_key: []const u8) !Layout {
        var layout = try init(allocator, project_key);
        errdefer layout.deinit();
        layout.loop_key = try allocator.dupe(u8, loop_key);
        return layout;
    }

    pub fn deinit(self: *Layout) void {
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        self.allocator.free(self.project_key);
        if (self.loop_key.len != 0) self.allocator.free(self.loop_key);
    }

    /// Whether any pane of the layout is `id`.
    pub fn hasPane(self: *const Layout, id: []const u8) bool {
        return self.idExists(id);
    }

    /// Makes sure the layout names `id` as its agent pane, adding it as the first tab when
    /// missing, as macOS does when a saved layout lost it. The human's selected tab stays.
    pub fn ensureAgentFirst(self: *Layout, id: []const u8) !void {
        if (self.idExists(id)) return;
        var panes: std.ArrayListUnmanaged(Pane) = .empty;
        errdefer panes.deinit(self.allocator);
        try panes.append(self.allocator, .{ .id = try self.allocator.dupe(u8, id), .launches_agent = true });
        errdefer self.allocator.free(panes.items[0].id);
        try self.tabs.insert(self.allocator, 0, .{ .id = self.next_tab_id, .panes = panes });
        self.next_tab_id += 1;
        if (self.tabs.items.len == 1) {
            self.selected_tab = 0;
        } else {
            self.selected_tab += 1;
        }
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
            if (!self.idExists(output[0..])) {
                if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_SESSION_PREFIX")) |prefix| {
                    defer self.allocator.free(prefix);
                    return std.fmt.allocPrint(
                        self.allocator,
                        "{s}-{s}",
                        .{ prefix, output[0..] },
                    );
                } else |_| {
                    return self.allocator.dupe(u8, output[0..]);
                }
            }
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

    pub fn closeFocusedPane(self: *Layout) !ClosedPane {
        const tab = self.selected() orelse return error.NoTabs;
        if (tab.panes.items.len == 0 or tab.focused_pane >= tab.panes.items.len)
            return error.InvalidTopology;
        const tab_index = self.selected_tab;
        const pane_index = tab.focused_pane;
        const removed = tab.panes.orderedRemove(tab.focused_pane);
        const id = removed.id;
        const record = ClosedPane{
            .id = id,
            .launches_agent = removed.launches_agent,
            .tab_id = tab.id,
            .tab_index = tab_index,
            .pane_index = pane_index,
            .split_direction = tab.split_direction,
            .focused_pane = tab.focused_pane,
            .selected_tab = self.selected_tab,
        };
        if (tab.panes.items.len == 0) {
            var closed = self.tabs.orderedRemove(self.selected_tab);
            closed.deinit(self.allocator);
            if (self.selected_tab >= self.tabs.items.len and self.tabs.items.len != 0)
                self.selected_tab = self.tabs.items.len - 1;
        } else if (tab.focused_pane >= tab.panes.items.len) {
            tab.focused_pane = tab.panes.items.len - 1;
        }
        return record;
    }

    pub fn restoreClosedPane(self: *Layout, record: *const ClosedPane) !void {
        if (self.idExists(record.id)) return error.DuplicateSurfaceID;
        for (self.tabs.items) |*tab| {
            if (tab.id != record.tab_id) continue;
            try tab.panes.insert(self.allocator, record.pane_index, .{
                .id = try self.allocator.dupe(u8, record.id),
                .launches_agent = record.launches_agent,
            });
            tab.split_direction = record.split_direction;
            tab.focused_pane = @min(record.focused_pane, tab.panes.items.len - 1);
            self.selected_tab = @min(record.selected_tab, self.tabs.items.len - 1);
            return;
        }
        var panes: std.ArrayListUnmanaged(Pane) = .empty;
        errdefer panes.deinit(self.allocator);
        try panes.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, record.id),
            .launches_agent = record.launches_agent,
        });
        try self.tabs.insert(self.allocator, @min(record.tab_index, self.tabs.items.len), .{
            .id = record.tab_id,
            .panes = panes,
            .split_direction = record.split_direction,
            .focused_pane = 0,
        });
        self.selected_tab = @min(record.selected_tab, self.tabs.items.len - 1);
    }

    pub fn replacePaneID(self: *Layout, old_id: []const u8, new_id: []const u8) !void {
        if (std.mem.eql(u8, old_id, new_id)) return;
        if (new_id.len == 0 or new_id.len > 128 or self.idExists(new_id)) return error.DuplicateSurfaceID;
        for (self.tabs.items) |*tab| {
            for (tab.panes.items) |*pane| {
                if (std.mem.eql(u8, pane.id, old_id)) {
                    const replacement = try self.allocator.dupe(u8, new_id);
                    self.allocator.free(pane.id);
                    pane.id = replacement;
                    return;
                }
            }
        }
        return error.InvalidSurface;
    }

    /// Records whether a pane's session is a loop the daemon starts (see `Pane`).
    pub fn setLaunchesAgent(self: *Layout, id: []const u8, launches_agent: bool) bool {
        for (self.tabs.items) |*tab| for (tab.panes.items) |*pane| {
            if (std.mem.eql(u8, pane.id, id)) {
                pane.launches_agent = launches_agent;
                return true;
            }
        };
        return false;
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
        if (self.tabs.items.len != 0 and self.selected_tab >= self.tabs.items.len)
            return error.InvalidTopology;
        if (self.tabs.items.len != 0) try self.validateTopology();
        // A name of its own per writer: two shells sharing the support directory must never
        // interleave their bytes in one temporary file before it is renamed over the layout.
        var nonce: [8]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.{x}.tmp", .{ file_path, std.mem.readInt(u64, &nonce, .little) });
        defer self.allocator.free(tmp_path);
        if (std.fs.path.dirname(file_path)) |directory| try std.fs.cwd().makePath(directory);
        {
            var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
            defer file.close();
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(&buffer);
            try self.writeJson(&writer.interface);
            try writer.interface.flush();
            try file.sync();
        }
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        try std.fs.cwd().rename(tmp_path, file_path);
    }

    fn writeJson(self: *const Layout, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"schemaVersion\":2,\"project\":");
        try writer.print("{f}", .{std.json.fmt(self.project_key, .{})});
        if (self.loop_key.len != 0) try writer.print(",\"loop\":{f}", .{std.json.fmt(self.loop_key, .{})});
        try writer.print(",\"selectedTab\":{d},\"tabs\":[", .{self.selected_tab});
        for (self.tabs.items, 0..) |tab, tab_index| {
            if (tab_index != 0) try writer.writeByte(',');
            try writer.print(
                "{{\"id\":{d},\"direction\":\"{s}\",\"focused\":{d},\"panes\":[",
                .{ tab.id, @tagName(tab.split_direction), tab.focused_pane },
            );
            for (tab.panes.items, 0..) |pane, pane_index| {
                if (pane_index != 0) try writer.writeByte(',');
                try writer.print(
                    "{{\"id\":{f},\"agent\":{s}}}",
                    .{ std.json.fmt(pane.id, .{}), if (pane.launches_agent) "true" else "false" },
                );
            }
            try writer.writeAll("]}");
        }
        try writer.writeAll("]}");
    }

    pub fn load(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        expected_project: []const u8,
    ) !Layout {
        return loadFor(allocator, file_path, expected_project, "");
    }

    /// `expected_loop` is empty for a project-level layout, which must not name a loop.
    pub fn loadFor(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        expected_project: []const u8,
        expected_loop: []const u8,
    ) !Layout {
        const data = std.fs.cwd().readFileAlloc(allocator, file_path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound, error.OutOfMemory => return err,
            // Locked by another shell, denied, too large: nothing says the layout is bad.
            else => return error.LayoutUnreadable,
        };
        defer allocator.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();
        const root = try object(parsed.value);
        const version = try integer(try field(root, "schemaVersion"));
        if (version != schema_version) return error.UnsupportedSchema;
        const project = try string(try field(root, "project"));
        if (!std.mem.eql(u8, project, expected_project)) return error.ProjectMismatch;
        const loop = if (root.get("loop")) |value| try string(value) else "";
        if (!std.mem.eql(u8, loop, expected_loop)) return error.LoopMismatch;
        const selected_index = try nonNegativeIndex(try field(root, "selectedTab"));
        const values = try array(try field(root, "tabs"));
        var layout = try Layout.initForLoop(allocator, expected_project, expected_loop);
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
        if (layout.selected_tab >= layout.tabs.items.len and layout.tabs.items.len != 0)
            return error.InvalidTopology;
        if (layout.tabs.items.len != 0) try layout.validateTopology();
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

pub const layouts_directory_name = "terminal-layouts";

/// `%GRAPHCODE_SUPPORT_DIR%` when set, otherwise `%USERPROFILE%\.graphcode`: where every
/// other per-user shell state lives, never the install directory.
pub fn supportDirectory(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        if (value.len != 0) return value;
        allocator.free(value);
    } else |_| {}
    const profile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(profile);
    return std.fs.path.join(allocator, &.{ profile, ".graphcode" });
}

/// The per-loop layout directory, as macOS's `<support>/terminal-layouts/`.
pub fn layoutsDirectory(allocator: std.mem.Allocator) ![]u8 {
    const support = try supportDirectory(allocator);
    defer allocator.free(support);
    return std.fs.path.join(allocator, &.{ support, layouts_directory_name });
}

pub fn projectSuffix(project: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project, &digest, .{});
    var suffix: [16]u8 = undefined;
    const value = std.mem.readInt(u64, digest[0..8], .little);
    const hex = "0123456789abcdef";
    for (0..16) |index| {
        suffix[15 - index] = hex[(value >> @as(u6, @intCast(index * 4))) & 0x0f];
    }
    return suffix;
}

fn isFileSafeID(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

/// A loop's layout file, `<root>\<loop>.json`; an id that is not a plain file name is hashed.
pub fn loopLayoutPath(allocator: std.mem.Allocator, root: []const u8, loop: []const u8) ![]u8 {
    if (isFileSafeID(loop)) return std.fmt.allocPrint(allocator, "{s}\\{s}.json", .{ root, loop });
    return std.fmt.allocPrint(allocator, "{s}\\loop-{s}.json", .{ root, projectSuffix(loop) });
}

pub fn projectLayoutPath(allocator: std.mem.Allocator, root: []const u8, project: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\\project.{s}.json", .{ root, projectSuffix(project) });
}

/// Where earlier shells saved the project-wide layout: `graphcode-workspace.<hash>.json` in
/// the shell's working directory, which for the installed shell is its install `bin`
/// folder. Read-only here; nothing is ever written to it again.
pub fn legacyLayoutPath(allocator: std.mem.Allocator, directory: []const u8, project: []const u8) ![]u8 {
    if (directory.len == 0) return std.fmt.allocPrint(allocator, "graphcode-workspace.{s}.json", .{projectSuffix(project)});
    return std.fmt.allocPrint(allocator, "{s}\\graphcode-workspace.{s}.json", .{ directory, projectSuffix(project) });
}

/// Whether a failed load means the file's contents are not a usable layout of this shell
/// (corrupt, foreign, or from a newer schema), as opposed to it being unreadable right now.
pub fn isInvalidLayout(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.LayoutUnreadable, error.OutOfMemory => false,
        else => true,
    };
}

/// Moves a layout file this shell must not use or delete aside as `<file>.<suffix>`, or
/// `<file>.<suffix>.<n>` when that is taken: renaming over an earlier one would lose it.
/// False when it could not be moved, in which case the file is left where it is.
pub fn setAside(allocator: std.mem.Allocator, file_path: []const u8, suffix: []const u8) bool {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const target = if (attempt == 0)
            std.fmt.allocPrint(allocator, "{s}.{s}", .{ file_path, suffix }) catch return false
        else
            std.fmt.allocPrint(allocator, "{s}.{s}.{d}", .{ file_path, suffix, attempt }) catch return false;
        defer allocator.free(target);
        if (std.fs.cwd().access(target, .{})) |_| continue else |_| {}
        std.fs.cwd().rename(file_path, target) catch return false;
        return true;
    }
    return false;
}

fn sameSession(a: []const u8, b: []const u8) bool {
    const prefix = "graphcode-";
    const left = if (std.mem.startsWith(u8, a, prefix)) a[prefix.len..] else a;
    const right = if (std.mem.startsWith(u8, b, prefix)) b[prefix.len..] else b;
    return std.mem.eql(u8, left, right);
}

pub const Claim = enum { claimed, unclaimed, unknown };

/// Whether any layout file in `root` other than `except_file` names `session` as a pane,
/// whatever its project or loop. A session two layouts both claim is not safely one's to end.
/// `unknown` when the scan could not be completed (more files than the cap, a directory or
/// file that could not be read, or one that is not a layout): absence of a claim is only
/// known from a scan that saw every layout.
pub fn claimedByOtherLayout(allocator: std.mem.Allocator, root: []const u8, except_file: []const u8, session: []const u8) Claim {
    var directory = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| return if (err == error.FileNotFound) .unclaimed else .unknown;
    defer directory.close();
    const except_name = std.fs.path.basename(except_file);
    var iterator = directory.iterate();
    var seen: usize = 0;
    var complete = true;
    while (true) {
        const entry = (iterator.next() catch {
            complete = false;
            break;
        }) orelse break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, except_name)) continue;
        seen += 1;
        if (seen > max_scanned_layouts) {
            complete = false;
            break;
        }
        switch (fileClaim(allocator, directory, entry.name, session)) {
            .claimed => return .claimed,
            .unclaimed => {},
            .unknown => complete = false,
        }
    }
    return if (complete) .unclaimed else .unknown;
}

fn fileClaim(allocator: std.mem.Allocator, directory: std.fs.Dir, name: []const u8, session: []const u8) Claim {
    const data = directory.readFileAlloc(allocator, name, 4 * 1024 * 1024) catch |err| {
        // A file that vanished mid-scan claims nothing; one that cannot be read might.
        return if (err == error.FileNotFound) .unclaimed else .unknown;
    };
    defer allocator.free(data);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return .unknown;
    defer parsed.deinit();
    const root_object = switch (parsed.value) {
        .object => |value| value,
        else => return .unknown,
    };
    const tabs = switch (root_object.get("tabs") orelse return .unknown) {
        .array => |value| value.items,
        else => return .unknown,
    };
    for (tabs) |tab| {
        const tab_object = switch (tab) {
            .object => |value| value,
            else => return .unknown,
        };
        const panes = switch (tab_object.get("panes") orelse return .unknown) {
            .array => |value| value.items,
            else => return .unknown,
        };
        for (panes) |pane| {
            const pane_object = switch (pane) {
                .object => |value| value,
                else => return .unknown,
            };
            const id = pane_object.get("id") orelse return .unknown;
            if (id != .string) return .unknown;
            if (sameSession(id.string, session)) return .claimed;
        }
    }
    return .unclaimed;
}

pub const owned_sessions_directory_name = "shell-sessions";

/// The record that a shell session is this shell's own: a file named for the session in
/// `<root>\shell-sessions`, made when the shell mints the session for a new tab or split and
/// before anything can attach to it. A name's shape cannot say who made the session; only
/// this record, which no layout edit or corruption touches, can. Null when `session` is not
/// a plain file name.
fn ownedSessionPath(allocator: std.mem.Allocator, root: []const u8, session: []const u8) ?[]u8 {
    if (!isFileSafeID(session)) return null;
    return std.fmt.allocPrint(allocator, "{s}\\{s}\\{s}", .{ root, owned_sessions_directory_name, session }) catch null;
}

pub fn markShellOwned(allocator: std.mem.Allocator, root: []const u8, session: []const u8) !void {
    const path = ownedSessionPath(allocator, root, session) orelse return error.InvalidSessionName;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |directory| try std.fs.cwd().makePath(directory);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    file.close();
}

pub fn isShellOwned(allocator: std.mem.Allocator, root: []const u8, session: []const u8) bool {
    const path = ownedSessionPath(allocator, root, session) orelse return false;
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn forgetShellOwned(allocator: std.mem.Allocator, root: []const u8, session: []const u8) void {
    const path = ownedSessionPath(allocator, root, session) orelse return;
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

/// A loop's layout from the project-wide legacy file, for a loop that has none of its own
/// yet. The legacy file mixed every loop of the project: it is adopted only when it names
/// `loop` as one of its panes, and then without the agent panes of any other loop. Null
/// when it is absent, unreadable, or not this loop's. `target_project` is the project the
/// adopted layout is saved under.
pub fn adoptLegacyLayout(
    allocator: std.mem.Allocator,
    legacy_path: []const u8,
    legacy_project: []const u8,
    loop: []const u8,
    target_project: []const u8,
) !?Layout {
    var legacy = Layout.load(allocator, legacy_path, legacy_project) catch return null;
    errdefer legacy.deinit();
    if (!legacy.idExists(loop)) {
        legacy.deinit();
        return null;
    }
    var foreign: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (foreign.items) |id| allocator.free(id);
        foreign.deinit(allocator);
    }
    for (legacy.tabs.items) |tab| for (tab.panes.items) |pane| {
        if (pane.launches_agent and !std.mem.eql(u8, pane.id, loop))
            try foreign.append(allocator, try allocator.dupe(u8, pane.id));
    };
    for (foreign.items) |id| _ = legacy.removePane(id);
    const project = try allocator.dupe(u8, target_project);
    allocator.free(legacy.project_key);
    legacy.project_key = project;
    legacy.loop_key = try allocator.dupe(u8, loop);
    return legacy;
}

pub const LoopRecord = struct {
    loop: []u8,
    project: []u8,
    /// When the layout file was last written, in nanoseconds since 1970 (0 when unknown).
    modified_ns: i128 = 0,
};

pub fn freeLoopRecords(allocator: std.mem.Allocator, records: []LoopRecord) void {
    for (records) |record| {
        allocator.free(record.loop);
        allocator.free(record.project);
    }
    allocator.free(records);
}

const max_scanned_layouts: usize = 1024;

/// The loop-scoped layouts saved in `root`, best effort: unreadable or foreign files are skipped.
pub fn scanLoopLayouts(allocator: std.mem.Allocator, root: []const u8) ![]LoopRecord {
    var records: std.ArrayListUnmanaged(LoopRecord) = .empty;
    errdefer {
        for (records.items) |record| {
            allocator.free(record.loop);
            allocator.free(record.project);
        }
        records.deinit(allocator);
    }
    var directory = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return records.toOwnedSlice(allocator);
    defer directory.close();
    var iterator = directory.iterate();
    var seen: usize = 0;
    while (iterator.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        seen += 1;
        if (seen > max_scanned_layouts) break;
        const data = directory.readFileAlloc(allocator, entry.name, 4 * 1024 * 1024) catch continue;
        defer allocator.free(data);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        const root_object = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };
        const version = root_object.get("schemaVersion") orelse continue;
        if (version != .integer or version.integer != schema_version) continue;
        const project = root_object.get("project") orelse continue;
        const loop = root_object.get("loop") orelse continue;
        if (project != .string or loop != .string or loop.string.len == 0) continue;
        const owned_loop = try allocator.dupe(u8, loop.string);
        errdefer allocator.free(owned_loop);
        const owned_project = try allocator.dupe(u8, project.string);
        errdefer allocator.free(owned_project);
        const modified_ns: i128 = if (directory.statFile(entry.name)) |stat| stat.mtime else |_| std.math.maxInt(i128);
        try records.append(allocator, .{ .loop = owned_loop, .project = owned_project, .modified_ns = modified_ns });
    }
    return records.toOwnedSlice(allocator);
}

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

test "a loop opened into a shell tab's slot is persisted as a loop pane" {
    var layout = try Layout.init(std.testing.allocator, "project-a");
    defer layout.deinit();
    try layout.addTab("shell-tab", false);
    try layout.replacePaneID("shell-tab", "loop-node");
    try std.testing.expect(layout.setLaunchesAgent("loop-node", true));
    try std.testing.expect(!layout.setLaunchesAgent("missing", true));
    try layout.save("workspace-layout-agent-test.json");
    defer std.fs.cwd().deleteFile("workspace-layout-agent-test.json") catch {};
    var restored = try Layout.load(std.testing.allocator, "workspace-layout-agent-test.json", "project-a");
    defer restored.deinit();
    try std.testing.expect(restored.tabs.items[0].panes.items[0].launches_agent);
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

test "close rollback restores exact tab and pane topology" {
        var layout = try Layout.default(std.testing.allocator, "p", "first");
        defer layout.deinit();
        try layout.splitFocused(.vertical, "second");
        layout.selected_tab = 0;
        layout.tabs.items[0].focused_pane = 1;
        layout.tabs.items[0].panes.items[1].launches_agent = true;
        const before_direction = layout.tabs.items[0].split_direction;
        var record = try layout.closeFocusedPane();
        defer record.deinit(std.testing.allocator);
        try layout.restoreClosedPane(&record);
        try std.testing.expectEqual(@as(u64, 1), layout.tabs.items[0].id);
        try std.testing.expectEqual(before_direction, layout.tabs.items[0].split_direction);
        try std.testing.expectEqual(@as(usize, 2), layout.tabs.items[0].panes.items.len);
        try std.testing.expectEqualStrings("second", layout.tabs.items[0].panes.items[1].id);
        try std.testing.expect(layout.tabs.items[0].panes.items[1].launches_agent);
        try std.testing.expectEqual(@as(usize, 1), layout.tabs.items[0].focused_pane);
}

test "topology mutation rollback leaves no phantom tab or split" {
    var layout = try Layout.default(std.testing.allocator, "p", "first");
    defer layout.deinit();
    const selected = layout.selected_tab;
    const next_id = layout.next_tab_id;
    try layout.addTab("second", false);
    try std.testing.expectEqual(@as(usize, 2), layout.tabs.items.len);
    _ = layout.removePane("second");
    layout.selected_tab = selected;
    layout.next_tab_id = next_id;
    try std.testing.expectEqual(@as(usize, 1), layout.tabs.items.len);
    const tab = layout.selected().?;
    const focus = tab.focused_pane;
    const direction = tab.split_direction;
    try layout.splitFocused(.vertical, "split");
    _ = layout.removePane("split");
    if (layout.selected()) |restored| {
        restored.focused_pane = focus;
        restored.split_direction = direction;
    }
    try std.testing.expectEqual(@as(usize, 1), layout.selected().?.panes.items.len);
    try std.testing.expectEqual(focus, layout.selected().?.focused_pane);
    try std.testing.expectEqual(direction, layout.selected().?.split_direction);
}

test "a loop's layout is saved under its own file in a directory it creates, and refuses another loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const directory = try std.fs.path.join(std.testing.allocator, &.{ root, "support", layouts_directory_name });
    defer std.testing.allocator.free(directory);
    const path = try loopLayoutPath(std.testing.allocator, directory, "3f2a-loop");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "terminal-layouts\\3f2a-loop.json"));

    var layout = try Layout.initForLoop(std.testing.allocator, "project-a", "3f2a-loop");
    defer layout.deinit();
    try layout.addTab("3f2a-loop", true);
    try layout.addTab("shell", false);
    try layout.save(path);

    var restored = try Layout.loadFor(std.testing.allocator, path, "project-a", "3f2a-loop");
    defer restored.deinit();
    try std.testing.expectEqualStrings("3f2a-loop", restored.loop_key);
    try std.testing.expectEqual(@as(usize, 2), restored.tabs.items.len);
    try std.testing.expectError(error.LoopMismatch, Layout.loadFor(std.testing.allocator, path, "project-a", "other-loop"));
    try std.testing.expectError(error.LoopMismatch, Layout.load(std.testing.allocator, path, "project-a"));
    try std.testing.expectError(error.ProjectMismatch, Layout.loadFor(std.testing.allocator, path, "project-b", "3f2a-loop"));
}

test "layout file names are the loop id when it is a plain name and a hash otherwise" {
    const plain = try loopLayoutPath(std.testing.allocator, "C:\\s", "00000000-0000-4000-8000-0A6CC9277ED5");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("C:\\s\\00000000-0000-4000-8000-0A6CC9277ED5.json", plain);
    for ([_][]const u8{ "..\\escape", "a/b", "project.x", "" }) |hostile| {
        const path = try loopLayoutPath(std.testing.allocator, "C:\\s", hostile);
        defer std.testing.allocator.free(path);
        try std.testing.expect(std.mem.startsWith(u8, path, "C:\\s\\loop-"));
        try std.testing.expect(std.mem.indexOfAny(u8, path["C:\\s\\".len..], "\\/") == null);
    }
    const project = try projectLayoutPath(std.testing.allocator, "C:\\s", "C:/GraphCode-Fixtures/Core");
    defer std.testing.allocator.free(project);
    try std.testing.expect(std.mem.startsWith(u8, project, "C:\\s\\project."));
    const legacy = try legacyLayoutPath(std.testing.allocator, "", "C:/GraphCode-Fixtures/Core");
    defer std.testing.allocator.free(legacy);
    try std.testing.expect(std.mem.startsWith(u8, legacy, "graphcode-workspace."));
}

test "ensureAgentFirst mounts the loop's agent tab first and keeps the selected tab" {
    var layout = try Layout.init(std.testing.allocator, "p");
    defer layout.deinit();
    try layout.ensureAgentFirst("loop");
    try std.testing.expectEqual(@as(usize, 1), layout.tabs.items.len);
    try std.testing.expect(layout.tabs.items[0].panes.items[0].launches_agent);
    try layout.addTab("shell", false);
    layout.selected_tab = 1;
    try layout.ensureAgentFirst("loop");
    try std.testing.expectEqual(@as(usize, 2), layout.tabs.items.len);
    var other = try Layout.init(std.testing.allocator, "p");
    defer other.deinit();
    try other.addTab("shell", false);
    try other.ensureAgentFirst("loop");
    try std.testing.expectEqualStrings("loop", other.tabs.items[0].panes.items[0].id);
    try std.testing.expectEqualStrings("shell", other.tabs.items[1].panes.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), other.selected_tab);
    try std.testing.expectEqualStrings("shell", other.selected().?.panes.items[0].id);
}

test "legacy project layout is adopted by the loop it names, without other loops' agent panes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const legacy_path = try legacyLayoutPath(std.testing.allocator, root, "project-a");
    defer std.testing.allocator.free(legacy_path);
    var legacy = try Layout.init(std.testing.allocator, "project-a");
    defer legacy.deinit();
    try legacy.addTab("loop-a", true);
    try legacy.addTab("shell-1", false);
    try legacy.addTab("loop-b", true);
    try legacy.save(legacy_path);

    var adopted = (try adoptLegacyLayout(std.testing.allocator, legacy_path, "project-a", "loop-a", "project-a")).?;
    defer adopted.deinit();
    try std.testing.expectEqualStrings("loop-a", adopted.loop_key);
    try std.testing.expect(adopted.hasPane("loop-a"));
    try std.testing.expect(adopted.hasPane("shell-1"));
    try std.testing.expect(!adopted.hasPane("loop-b"));

    try std.testing.expect((try adoptLegacyLayout(std.testing.allocator, legacy_path, "project-a", "loop-c", "project-a")) == null);
    try std.testing.expect((try adoptLegacyLayout(std.testing.allocator, legacy_path, "project-b", "loop-a", "project-b")) == null);
    try std.testing.expect((try adoptLegacyLayout(std.testing.allocator, "missing.json", "project-a", "loop-a", "project-a")) == null);
}

test "scanning loop layouts reports only loop-scoped files and skips everything else" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var scoped = try Layout.initForLoop(std.testing.allocator, "project-a", "loop-a");
    defer scoped.deinit();
    try scoped.addTab("loop-a", true);
    const scoped_path = try loopLayoutPath(std.testing.allocator, root, "loop-a");
    defer std.testing.allocator.free(scoped_path);
    try scoped.save(scoped_path);
    var project_level = try Layout.init(std.testing.allocator, "project-a");
    defer project_level.deinit();
    try project_level.addTab("shell", false);
    const project_path = try projectLayoutPath(std.testing.allocator, root, "project-a");
    defer std.testing.allocator.free(project_path);
    try project_level.save(project_path);
    try tmp.dir.writeFile(.{ .sub_path = "garbage.json", .data = "not json" });
    try tmp.dir.writeFile(.{ .sub_path = "note.txt", .data = "{}" });

    const records = try scanLoopLayouts(std.testing.allocator, root);
    defer freeLoopRecords(std.testing.allocator, records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("loop-a", records[0].loop);
    try std.testing.expectEqualStrings("project-a", records[0].project);

    const missing = try scanLoopLayouts(std.testing.allocator, "C:\\no\\such\\layouts");
    defer freeLoopRecords(std.testing.allocator, missing);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
    try std.testing.expect(records[0].modified_ns > 0);
}

test "a layout is set aside under a name that never replaces an earlier one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}\\loop.json", .{root});
    defer std.testing.allocator.free(path);

    try tmp.dir.writeFile(.{ .sub_path = "loop.json", .data = "first" });
    try std.testing.expect(setAside(std.testing.allocator, path, "bad"));
    try tmp.dir.writeFile(.{ .sub_path = "loop.json", .data = "second" });
    try std.testing.expect(setAside(std.testing.allocator, path, "bad"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("loop.json", .{}));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("first", try tmp.dir.readFile("loop.json.bad", &buffer));
    try std.testing.expectEqualStrings("second", try tmp.dir.readFile("loop.json.bad.1", &buffer));
    try std.testing.expect(!setAside(std.testing.allocator, path, "bad"));
}

test "loading tells a missing layout, an unreadable one and an invalid one apart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}\\loop.json", .{root});
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.FileNotFound, Layout.loadFor(std.testing.allocator, path, "project-a", "loop"));
    try std.testing.expect(!isInvalidLayout(error.FileNotFound));

    // A directory where the file should be cannot be read, and says nothing about its contents.
    try tmp.dir.makePath("loop.json");
    try std.testing.expectError(error.LayoutUnreadable, Layout.loadFor(std.testing.allocator, path, "project-a", "loop"));
    try std.testing.expect(!isInvalidLayout(error.LayoutUnreadable));
    try tmp.dir.deleteDir("loop.json");

    const invalid = [_][]const u8{
        "{\"schemaVersion\":2,\"project\":\"",
        "{\"schemaVersion\":3,\"project\":\"project-a\",\"loop\":\"loop\",\"selectedTab\":0,\"tabs\":[]}",
        "{\"schemaVersion\":2,\"project\":\"project-b\",\"loop\":\"loop\",\"selectedTab\":0,\"tabs\":[]}",
        "{\"schemaVersion\":2,\"project\":\"project-a\",\"loop\":\"other\",\"selectedTab\":0,\"tabs\":[]}",
        "[]",
    };
    for (invalid) |data| {
        try tmp.dir.writeFile(.{ .sub_path = "loop.json", .data = data });
        if (Layout.loadFor(std.testing.allocator, path, "project-a", "loop")) |value| {
            var loaded = value;
            loaded.deinit();
            return error.TestExpectedInvalidLayout;
        } else |err| try std.testing.expect(isInvalidLayout(err));
    }
}

test "a pane another layout names is claimed, however the session is spelled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var other = try Layout.initForLoop(std.testing.allocator, "project-a", "loop-b");
    defer other.deinit();
    try other.addTab("loop-b", true);
    try other.addTab("graphcode-shared", false);
    const other_path = try loopLayoutPath(std.testing.allocator, root, "loop-b");
    defer std.testing.allocator.free(other_path);
    try other.save(other_path);
    try tmp.dir.writeFile(.{ .sub_path = "garbage.json", .data = "{ not a layout" });
    const mine = try loopLayoutPath(std.testing.allocator, root, "loop-a");
    defer std.testing.allocator.free(mine);

    try std.testing.expectEqual(Claim.claimed, claimedByOtherLayout(std.testing.allocator, root, mine, "graphcode-shared"));
    try std.testing.expectEqual(Claim.claimed, claimedByOtherLayout(std.testing.allocator, root, mine, "shared"));
    // An unreadable layout might name anything, so nothing is known to be unclaimed.
    try std.testing.expectEqual(Claim.unknown, claimedByOtherLayout(std.testing.allocator, root, mine, "unshared"));
    try tmp.dir.deleteFile("garbage.json");
    try std.testing.expectEqual(Claim.unclaimed, claimedByOtherLayout(std.testing.allocator, root, mine, "unshared"));
    // The layout being retired never makes its own panes shared.
    try std.testing.expectEqual(Claim.unclaimed, claimedByOtherLayout(std.testing.allocator, root, other_path, "shared"));
    try std.testing.expectEqual(Claim.unclaimed, claimedByOtherLayout(std.testing.allocator, "C:\\no\\such\\layouts", mine, "shared"));
}

test "a layout scan past its cap is unknown, not unclaimed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    for (0..max_scanned_layouts + 5) |index| {
        var name: [32]u8 = undefined;
        try tmp.dir.writeFile(.{ .sub_path = try std.fmt.bufPrint(&name, "filler-{d:0>4}.json", .{index}), .data = "{\"tabs\":[]}" });
    }
    try tmp.dir.writeFile(.{ .sub_path = "zzz-claimant.json", .data = "{\"tabs\":[{\"panes\":[{\"id\":\"shared\"}]}]}" });
    try std.testing.expectEqual(Claim.unknown, claimedByOtherLayout(std.testing.allocator, root, "", "shared"));
}

test "a shell session is owned only once the shell has recorded it, and not after it is forgotten" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const name = "graphcode-5e11ba5e-0001-4000-8000-000000000001";
    try std.testing.expect(!isShellOwned(std.testing.allocator, root, name));
    try markShellOwned(std.testing.allocator, root, name);
    try std.testing.expect(isShellOwned(std.testing.allocator, root, name));
    try std.testing.expect(!isShellOwned(std.testing.allocator, root, "graphcode-5e11ba5e-0002-4000-8000-000000000002"));
    try std.testing.expect(!isShellOwned(std.testing.allocator, root, "..\\escape"));
    try std.testing.expectError(error.InvalidSessionName, markShellOwned(std.testing.allocator, root, "..\\escape"));
    forgetShellOwned(std.testing.allocator, root, name);
    try std.testing.expect(!isShellOwned(std.testing.allocator, root, name));
}

test "saving replaces a layout whole, leaves no temporary file, and keeps the old one when it fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try loopLayoutPath(std.testing.allocator, root, "loop-a");
    defer std.testing.allocator.free(path);

    var first = try Layout.initForLoop(std.testing.allocator, "project-a", "loop-a");
    defer first.deinit();
    try first.addTab("loop-a", true);
    try first.save(path);
    var second = try Layout.initForLoop(std.testing.allocator, "project-a", "loop-a");
    defer second.deinit();
    try second.addTab("loop-a", true);
    try second.addTab("shell", false);
    try second.save(path);
    var loaded = try Layout.loadFor(std.testing.allocator, path, "project-a", "loop-a");
    defer loaded.deinit();
    try std.testing.expect(loaded.hasPane("shell"));

    // A layout that fails validation never touches the file.
    second.selected_tab = 9;
    try std.testing.expectError(error.InvalidTopology, second.save(path));
    var kept = try Layout.loadFor(std.testing.allocator, path, "project-a", "loop-a");
    kept.deinit();

    var directory = try tmp.dir.openDir(".", .{ .iterate = true });
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}
