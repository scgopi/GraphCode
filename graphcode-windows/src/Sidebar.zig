const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const Tokens = @import("DesignTokens.zig");
const c = @import("Win32.zig").c;
const AppFont = @import("AppFont.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    local_collapsed: bool = false,
    remote_collapsed: bool = false,
    chats_collapsed: bool = false,
    activity_attention_only: bool = false,
    activity_scroll: usize = 0,
    collapsed_projects: std.StringHashMapUnmanaged(void) = .empty,
    expanded_nodes: std.StringHashMapUnmanaged(void) = .empty,
    root_order: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        freeSet(self.allocator, &self.collapsed_projects);
        freeSet(self.allocator, &self.expanded_nodes);
        for (self.root_order.items) |id| self.allocator.free(id);
        self.root_order.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn toggleProject(self: *State, path: []const u8) !void {
        try toggleSet(self.allocator, &self.collapsed_projects, path);
    }

    pub fn toggleNode(self: *State, id: []const u8) !void {
        try toggleSet(self.allocator, &self.expanded_nodes, id);
    }

    pub fn isProjectCollapsed(self: *const State, path: []const u8) bool {
        return self.collapsed_projects.contains(path);
    }

    pub fn isNodeExpanded(self: *const State, id: []const u8) bool {
        return self.expanded_nodes.contains(id);
    }

    pub fn clearExpandedNodes(self: *State) void {
        freeSet(self.allocator, &self.expanded_nodes);
        self.expanded_nodes = .empty;
    }

    pub fn reorderRoots(self: *State, roots: []const []const u8) !void {
        var seen = std.StringHashMapUnmanaged(void){};
        defer freeSet(self.allocator, &seen);
        for (roots) |root| {
            if (root.len == 0 or seen.contains(root)) return error.InvalidRootOrder;
            try seen.put(self.allocator, try self.allocator.dupe(u8, root), {});
        }
        var next: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (next.items) |id| self.allocator.free(id);
            next.deinit(self.allocator);
        }
        for (roots) |root| try next.append(self.allocator, try self.allocator.dupe(u8, root));
        for (self.root_order.items) |id| self.allocator.free(id);
        self.root_order.deinit(self.allocator);
        self.root_order = next;
    }

    pub fn encode(self: *const State, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        var iterator = self.expanded_nodes.keyIterator();
        while (iterator.next()) |id| try result.writer(allocator).print("expanded\t{s}\n", .{id.*});
        for (self.root_order.items) |id| try result.writer(allocator).print("root\t{s}\n", .{id});
        return result.toOwnedSlice(allocator);
    }

    pub fn decode(self: *State, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "expanded\t")) continue;
            const id = line["expanded\t".len..];
            if (id.len != 0 and !self.expanded_nodes.contains(id))
                try self.expanded_nodes.put(self.allocator, try self.allocator.dupe(u8, id), {});
        }
        var roots = std.mem.splitScalar(u8, data, '\n');
        while (roots.next()) |line| {
            if (!std.mem.startsWith(u8, line, "root\t")) continue;
            const id = line["root\t".len..];
            if (id.len != 0) try self.root_order.append(self.allocator, try self.allocator.dupe(u8, id));
        }
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,

    pub fn init(allocator: std.mem.Allocator) !Store {
        const base = if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value|
            value
        else |_| blk: {
            const profile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
            defer allocator.free(profile);
            break :blk try std.fs.path.join(allocator, &.{ profile, ".graphcode" });
        };
        defer allocator.free(base);
        try std.fs.cwd().makePath(base);
        return .{
            .allocator = allocator,
            .path = try std.fs.path.join(allocator, &.{ base, "windows-sidebar-state.tsv" }),
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn load(self: *Store, state: *State) !void {
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(data);
        try state.decode(data);
    }

    pub fn save(self: *Store, state: *const State) !void {
        const data = try state.encode(self.allocator);
        defer self.allocator.free(data);
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp-{d}", .{ self.path, std.time.nanoTimestamp() });
        defer self.allocator.free(temp_path);
        var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
        file.writeAll(data) catch |err| {
            file.close();
            std.fs.cwd().deleteFile(temp_path) catch {};
            return err;
        };
        file.close();
        std.os.windows.MoveFileEx(
            temp_path,
            self.path,
            std.os.windows.MOVEFILE_REPLACE_EXISTING | std.os.windows.MOVEFILE_WRITE_THROUGH,
        ) catch |err| {
            std.fs.cwd().deleteFile(temp_path) catch {};
            return err;
        };
    }
};

fn freeSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var iterator = set.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
    set.deinit(allocator);
}

fn toggleSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), key: []const u8) !void {
    if (set.fetchRemove(key)) |removed| {
        allocator.free(removed.key);
    } else {
        try set.put(allocator, try allocator.dupe(u8, key), {});
    }
}

pub fn draw(
    hdc: c.HDC,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    selected_worktree_path: []const u8,
    scroll_offset: i32,
    status: []const u8,
    viewport_bottom: i32,
    update_version: []const u8,
    ingress_error: []const u8,
    state: *const State,
    hover_y: i32,
    allocator: std.mem.Allocator,
) void {
    const sidebar = rect(0, Tokens.header_height, Tokens.sidebar_width, 1200);
    fill(hdc, sidebar, Tokens.workspace_rail);
    drawText(hdc, allocator, "GRAPH", 18, Tokens.header_height + 20, 16, 0x00FFFFFF);
    drawText(hdc, allocator, "Projects", 18, Tokens.header_height + 54, 14, 0x00B8B8B8);
    var rows = appendRows(allocator, model, inspection, scroll_offset, state) catch return;
    defer rows.deinit(allocator);
    for (rows.items) |row| {
        switch (row.kind) {
            .local_heading => {
                drawText(hdc, allocator, if (state.local_collapsed) ">  LOCAL" else "v  LOCAL", 18, row.top, 10, 0x007A7A7A);
            },
            .remote_heading => {
                drawText(hdc, allocator, if (state.remote_collapsed) ">  REMOTE" else "v  REMOTE", 18, row.top, 10, 0x007A7A7A);
            },
            .project => {
                const project = model.recent_projects.items[row.index];
                drawText(hdc, allocator, if (project.isRemote()) "R" else "L", 18, row.top + 1, 9, 0x007A7A7A);
                drawText(hdc, allocator, project.name, 34, row.top, 13, 0x00E6E6E6);
            },
            .overview => {
                drawText(hdc, allocator, "G", 18, row.top, 11, 0x007AB8FF);
                drawText(hdc, allocator, "Graph", 34, row.top, 13, 0x00E6E6E6);
            },
            .open_project => if (row.project_path) |path| if (model.graphFor(path)) |summary| {
                const selected = if (model.selected_project_path) |selected_path|
                    std.mem.eql(u8, selected_path, path)
                else
                    false;
                drawText(hdc, allocator, if (state.isProjectCollapsed(path)) ">" else "v", 18, row.top, 9, 0x007A7A7A);
                drawText(hdc, allocator, if (summary.project.isRemote()) "R" else "L", 31, row.top + 1, 9, 0x007A7A7A);
                drawText(hdc, allocator, summary.project.name, 44, row.top, 13, if (selected) 0x00FFFFFF else 0x00D0D0D0);
                if (hover_y >= row.top and hover_y < row.top + 24) {
                    drawText(hdc, allocator, "+", 181, row.top, 13, 0x00B8B8B8);
                    if (row.has_children) drawText(hdc, allocator, if (state.isProjectCollapsed(path)) ">" else "v", 204, row.top, 9, 0x00B8B8B8);
                }
            },
            .loop => if (row.project_path) |path| if (model.graphFor(path)) |summary| {
                if (row.index < summary.nodes.items.len) {
                    const node = summary.nodes.items[row.index];
                    const indent = @as(i32, @intCast(row.depth * 12));
                    if (row.depth != 0) drawText(hdc, allocator, ">", 28 + indent, row.top, 9, 0x006A6A6A);
                    fill(hdc, rect(30 + indent, row.top - 2, 33 + indent, row.top + 17), loopAccent(node.loop_type));
                    drawText(hdc, allocator, node.title, 39 + indent, row.top, 11, 0x00E6E6E6);
                    drawText(hdc, allocator, compactState(node.state), 150, row.top, 9, stateColor(node.state));
                    const elapsed = elapsedText(allocator, @intCast(node.created_at orelse 0), std.time.timestamp()) catch null;
                    defer if (elapsed) |value| allocator.free(value);
                    if (elapsed) |value| drawText(hdc, allocator, value, 168, row.top, 9, 0x008E8E93);
                    if (row.has_children and hover_y >= row.top and hover_y < row.top + 24)
                        drawText(hdc, allocator, if (state.isNodeExpanded(node.id)) "v" else ">", 204, row.top, 9, 0x00B8B8B8);
                }
            },
            .worktree => if (inspection) |value| {
                const entry = value.entries.items[row.index];
                const selected = std.mem.eql(u8, entry.path, selected_worktree_path);
                if (selected and WorktreeStatus.decision(entry) == .reclaimable)
                    fill(hdc, rect(12, row.top - 3, Tokens.sidebar_width - 12, row.top + 25), 0x003A3A44);
                drawText(hdc, allocator, entry.path, 24, row.top, 11, 0x00E6E6E6);
                drawText(hdc, allocator, reason(entry), 24, row.top + 14, 10, if (WorktreeStatus.decision(entry) == .reclaimable) 0x0078D7A8 else 0x00FFCD7A);
            },
            .quick_chat_overview => {
                drawText(hdc, allocator, if (state.chats_collapsed) ">" else "v", 18, row.top, 9, 0x007A7A7A);
                drawText(hdc, allocator, "Quick Chats", 32, row.top, 13, 0x00E6E6E6);
                if (hover_y >= row.top and hover_y < row.top + 24) {
                    drawText(hdc, allocator, "+", 181, row.top, 13, 0x00B8B8B8);
                    if (model.quick_chats.items.len != 0)
                        drawText(hdc, allocator, if (state.chats_collapsed) ">" else "v", 204, row.top, 9, 0x00B8B8B8);
                }
            },
            .quick_chat => if (row.index < model.quick_chats.items.len)
                drawText(hdc, allocator, model.quick_chats.items[row.index].title, 24, row.top, 11, 0x00E6E6E6),
        }
    }
    for (rows.items) |row| if (row.kind == .quick_chat_overview) {
        drawText(hdc, allocator, "CHATS", 18, row.top - 32, 10, 0x007A7A7A);
        break;
    };

    const section_y = sidebarSectionBottom(model, inspection, state) - scroll_offset;
    if (model.attentionCount() != 0) {
        drawText(hdc, allocator, "Needs you", 18, section_y + 10, 11, 0x00FFCD7A);
        var attention_y = section_y + 30;
        if (model.attention_entries.items.len != 0) {
            for (model.attention_entries.items[0..@min(model.attention_entries.items.len, 4)], 0..) |entry, index| {
                drawText(hdc, allocator, entry.node.title, 24, attention_y, 11, 0x00E6E6E6);
                drawText(hdc, allocator, attentionReason(entry.node), 24, attention_y + 15, 9, stateColor(entry.node.state));
                const stop_bounds = needsYouStopBounds(model, inspection, state, 0, index);
                fill(hdc, stop_bounds, 0x00353224);
                drawTextRect(hdc, allocator, "Stop", stop_bounds, 9, 0x00FFCD7A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
                attention_y += 34;
            }
        } else {
            for (model.attention.items[0..@min(model.attention.items.len, 4)], 0..) |node, index| {
                drawText(hdc, allocator, node.title, 24, attention_y, 11, 0x00E6E6E6);
                drawText(hdc, allocator, attentionReason(node), 24, attention_y + 15, 9, stateColor(node.state));
                const stop_bounds = needsYouStopBounds(model, inspection, state, 0, index);
                fill(hdc, stop_bounds, 0x00353224);
                drawTextRect(hdc, allocator, "Stop", stop_bounds, 9, 0x00FFCD7A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
                attention_y += 34;
            }
        }
    }
    if (model.activity.items.len != 0) {
        const attention_rows = @min(model.attentionCount(), 4);
        const activity_y = section_y + 30 + (@as(i32, @intCast(attention_rows)) * 34) + 18;
        drawText(hdc, allocator, "Activity", 18, activity_y, 11, 0x00B8B8B8);
        const filter_bounds = activityFilterBounds(model, inspection, state, 0);
        fill(hdc, filter_bounds, if (state.activity_attention_only) 0x00302B1D else 0x0026262B);
        drawTextRect(hdc, allocator, "Attention only", filter_bounds, 9, if (state.activity_attention_only) 0x00FFCD7A else 0x00B8B8B8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        const left_bounds = activityControlBounds(model, inspection, state, 0, .left);
        const right_bounds = activityControlBounds(model, inspection, state, 0, .right);
        fill(hdc, left_bounds, 0x0026262B);
        fill(hdc, right_bounds, 0x0026262B);
        drawTextRect(hdc, allocator, "<", left_bounds, 10, 0x00B8B8B8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        drawTextRect(hdc, allocator, ">", right_bounds, 10, 0x00B8B8B8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        const viewport = activityViewport(model, state);
        for (0..viewport.visible_count) |visible_index| {
            const activity_index = activityEventAtVisible(model, state, visible_index) orelse break;
            const event = model.activity.items[activity_index];
            const card = activityCardBounds(model, inspection, state, 0, visible_index);
            const stamp = std.fmt.allocPrint(allocator, "{d}m", .{@max(0, @divTrunc(std.time.timestamp() - event.timestamp, 60))}) catch null;
            defer if (stamp) |value| allocator.free(value);
            fill(hdc, card, 0x0026262B);
            fill(hdc, rect(card.left, card.top, card.left + 3, card.bottom), stateColor(event.state));
            drawTextRect(hdc, allocator, event.title, rect(card.left + 8, card.top + 4, card.right - 8, card.top + 20), 10, 0x00E6E6E6, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
            drawTextRect(hdc, allocator, stamp orelse "", rect(card.left + 8, card.top + 18, card.right - 8, card.bottom - 4), 9, stateColor(event.state), c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER);
        }
    }
    if (ingress_error.len != 0) {
        const bounds = errorFooterRect(viewport_bottom);
        fill(hdc, bounds, 0x00242448);
        drawTextRect(hdc, allocator, ingress_error, errorFooterTextRect(viewport_bottom), 10, 0x006060FF, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
    }
    if (update_version.len != 0) {
        const bounds = updateBannerRect(viewport_bottom, ingress_error.len != 0);
        fill(hdc, bounds, 0x00352B1C);
        drawText(hdc, allocator, "v", bounds.left + 10, bounds.top + 10, 14, 0x00FF840A);
        drawText(hdc, allocator, "Update available", bounds.left + 30, bounds.top + 7, 12, 0x00F0F0F0);
        const detail = std.fmt.allocPrint(allocator, "{s} · click to install", .{update_version}) catch null;
        defer if (detail) |value| allocator.free(value);
        drawText(hdc, allocator, detail orelse update_version, bounds.left + 30, bounds.top + 24, 10, 0x00909090);
    }
    const status_offset: i32 = 58 +
        (if (ingress_error.len != 0) @as(i32, 50) else 0) +
        (if (update_version.len != 0) @as(i32, 58) else 0);
    drawText(hdc, allocator, status, 18, viewport_bottom - status_offset, 11, 0x00909090);
}

pub fn errorFooterRect(viewport_bottom: i32) c.RECT {
    return rect(8, viewport_bottom - 84, Tokens.sidebar_width - 8, viewport_bottom - 42);
}

pub fn errorFooterTextRect(viewport_bottom: i32) c.RECT {
    const bounds = errorFooterRect(viewport_bottom);
    return rect(bounds.left + 10, bounds.top + 8, bounds.right - 10, bounds.bottom - 8);
}

pub fn updateBannerRect(viewport_bottom: i32, has_error: bool) c.RECT {
    const error_offset: i32 = if (has_error) 50 else 0;
    return rect(8, viewport_bottom - 92 - error_offset, Tokens.sidebar_width - 8, viewport_bottom - 42 - error_offset);
}

pub fn updateBannerAt(x: i32, y: i32, viewport_bottom: i32, available: bool, has_error: bool) bool {
    if (!available) return false;
    const bounds = updateBannerRect(viewport_bottom, has_error);
    return x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom;
}

pub const ActivityControl = enum { filter, left, right };
pub const ActivityDirection = enum { left, right };

pub const ActivityViewport = struct {
    start: usize,
    visible_count: usize,
    total_count: usize,
};

fn loopAccent(loop_type: []const u8) u32 {
    if (std.mem.eql(u8, loop_type, "goalBased")) return 0x0048C78E;
    if (std.mem.eql(u8, loop_type, "timeBased")) return 0x00D6A649;
    if (std.mem.eql(u8, loop_type, "composite")) return 0x00C77DFF;
    return 0x007AB8FF;
}

fn compactState(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "succeeded")) return "done";
    if (std.mem.eql(u8, state, "awaitingInput")) return "needs";
    return state;
}

fn stateColor(state: []const u8) u32 {
    if (std.mem.eql(u8, state, "failed") or std.mem.eql(u8, state, "stalled")) return 0x005F5FFF;
    if (std.mem.eql(u8, state, "succeeded")) return 0x006BD58D;
    if (std.mem.eql(u8, state, "blocked")) return 0x0049B8FF;
    return 0x008E8E93;
}

fn attentionContext(model: *const GraphModel.Model, entry: GraphModel.AttentionEntry) []const u8 {
    for (model.graphs.items) |graph| {
        if (std.mem.eql(u8, graph.project.path, entry.project_path)) return graph.project.name;
    }
    return compactState(entry.node.state);
}

pub fn attentionReason(node: GraphModel.Node) []const u8 {
    if (std.mem.eql(u8, node.state, "failed")) return "Failed - action needed";
    if (std.mem.eql(u8, node.state, "stalled")) return "Stalled - action needed";
    if (std.mem.eql(u8, node.presence, "awaitingInput")) return "Awaiting your input";
    if (std.mem.eql(u8, node.state, "blocked")) return "Blocked - upstream unavailable";
    return compactState(node.state);
}

pub fn activityNeedsAttention(state: []const u8) bool {
    return std.mem.eql(u8, state, "failed") or
        std.mem.eql(u8, state, "stalled") or
        std.mem.eql(u8, state, "blocked") or
        std.mem.eql(u8, state, "awaitingInput");
}

fn elapsedText(allocator: std.mem.Allocator, created_at: i64, now: i64) ![]u8 {
    if (created_at <= 0 or now <= created_at) return allocator.dupe(u8, "-");
    const seconds = now - created_at;
    if (seconds < 60) return std.fmt.allocPrint(allocator, "{d}s", .{seconds});
    if (seconds < 3600) return std.fmt.allocPrint(allocator, "{d}m", .{@divTrunc(seconds, 60)});
    if (seconds < 86400) return std.fmt.allocPrint(allocator, "{d}h", .{@divTrunc(seconds, 3600)});
    return std.fmt.allocPrint(allocator, "{d}d", .{@divTrunc(seconds, 86400)});
}

pub fn loopRowTop(project_count: usize, index: usize) i32 {
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = 0, .worktree_count = 0 };
    return layout.loopTop(index);
}

pub fn loopRowTopForModel(model: *const GraphModel.Model, index: usize) i32 {
    const layout = layoutFor(model, null);
    const graph = model.currentGraph() orelse return layout.loopTop(index);
    const position = hierarchyPosition(std.heap.page_allocator, graph.nodes.items, graph.edges.items, index) catch index;
    return layout.loopTop(position);
}

pub fn worktreeRowTop(project_count: usize, loop_count: usize, index: usize) i32 {
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = loop_count, .worktree_count = 0 };
    return layout.worktreeTop(index);
}

pub fn worktreeRowTopForModel(model: *const GraphModel.Model, loop_count: usize, index: usize) i32 {
    const layout = Layout{
        .base = Tokens.header_height + 78,
        .project_count = visibleProjectCount(model),
        .project_heading_count = projectHeadingCount(model),
        .loop_count = loop_count,
        .worktree_count = 0,
    };
    return layout.worktreeTop(index);
}

pub const RowKind = enum { local_heading, remote_heading, project, open_project, overview, loop, worktree, quick_chat_overview, quick_chat };
pub const Row = struct {
    kind: RowKind,
    index: usize,
    top: i32,
    project_path: ?[]const u8 = null,
    depth: usize = 0,
    has_children: bool = false,
};
const HierarchyItem = struct { index: usize, depth: usize, has_children: bool };
pub const Layout = struct {
    base: i32,
    project_count: usize,
    project_heading_count: usize = 0,
    loop_count: usize,
    worktree_count: usize,
    quick_chat_count: usize = 0,
    graph_present: bool = true,
    inspection_present: bool = false,
    graph_section_height: i32 = 0,

    pub fn projectTop(self: Layout, index: usize) i32 {
        return self.base + @as(i32, @intCast(index * 24));
    }
    pub fn overviewTop(self: Layout) i32 {
        return self.base + self.projectSectionHeight() + 24;
    }
    pub fn loopTop(self: Layout, index: usize) i32 {
        return self.base + self.projectSectionHeight() + 86 +
            @as(i32, @intCast(index * 24));
    }
    pub fn worktreeTop(self: Layout, index: usize) i32 {
        return self.base + self.projectSectionHeight() + 140 +
            @as(i32, @intCast(self.loop_count * 24)) +
            @as(i32, @intCast(index * 34));
    }
    pub fn quickChatHeadingTop(self: Layout) i32 {
        return self.quickChatRowTop(0) - 32;
    }
    pub fn quickChatRowTop(self: Layout, index: usize) i32 {
        const project_bottom = self.base + self.projectSectionHeight();
        const worktree_height: i32 = if (self.inspection_present)
            24 + @as(i32, @intCast(self.worktree_count * 34))
        else
            0;
        const section_bottom = project_bottom + self.graph_section_height + worktree_height;
        return section_bottom + 42 + @as(i32, @intCast(index * 24));
    }
    fn projectSectionHeight(self: Layout) i32 {
        return @as(i32, @intCast((self.project_count + self.project_heading_count) * 24));
    }
};

pub fn appendRows(
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    scroll_offset: i32,
    state: ?*const State,
) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    var top: i32 = Tokens.header_height + 78 - scroll_offset;
    const local_collapsed = if (state) |value| value.local_collapsed else false;
    const remote_collapsed = if (state) |value| value.remote_collapsed else false;
    const chats_collapsed = if (state) |value| value.chats_collapsed else false;
    if (hasLocalProjects(model)) {
        try rows.append(allocator, .{ .kind = .local_heading, .index = 0, .top = top });
        top += 24;
    }
    if (!local_collapsed) {
        for (model.recent_projects.items, 0..) |project, index| {
            if (!projectIsVisibleInSection(model, project, .local)) continue;
            try rows.append(allocator, .{ .kind = .project, .index = index, .top = top, .project_path = project.path });
            top += 24;
        }
    }
    if (hasRemoteProjects(model)) {
        try rows.append(allocator, .{ .kind = .remote_heading, .index = 0, .top = top });
        top += 24;
    }
    if (!remote_collapsed) {
        for (model.recent_projects.items, 0..) |project, index| {
            if (!projectIsVisibleInSection(model, project, .remote)) continue;
            try rows.append(allocator, .{ .kind = .project, .index = index, .top = top, .project_path = project.path });
            top += 24;
        }
    }
    try rows.append(allocator, .{ .kind = .overview, .index = 0, .top = top + 24 });
    top += 62;
    for (model.open_projects.items, 0..) |project, index| {
        if (hasGraphForProject(model, project.path)) continue;
        try rows.append(allocator, .{ .kind = .open_project, .index = index, .top = top, .project_path = project.path });
        top += 62;
    }
    if (model.graphs.items.len != 0 or model.graph != null) {
        if (model.graphs.items.len != 0) {
            for (model.graphs.items, 0..) |summary, graph_index| {
                try rows.append(allocator, .{ .kind = .open_project, .index = graph_index, .top = top, .project_path = summary.project.path, .has_children = summary.nodes.items.len != 0 });
                top += 24;
                if (state == null or !state.?.isProjectCollapsed(summary.project.path)) {
                    var hierarchy = try hierarchyItems(allocator, summary.nodes.items, summary.edges.items, state);
                    defer hierarchy.deinit(allocator);
                    for (hierarchy.items) |item| {
                        try rows.append(allocator, .{ .kind = .loop, .index = item.index, .top = top, .project_path = summary.project.path, .depth = item.depth, .has_children = item.has_children });
                        top += 24;
                    }
                }
                top += 38;
            }
        } else if (model.graph) |graph| {
            try rows.append(allocator, .{ .kind = .open_project, .index = 0, .top = top, .project_path = graph.project.path, .has_children = graph.nodes.items.len != 0 });
            top += 24;
            if (state == null or !state.?.isProjectCollapsed(graph.project.path)) {
                var hierarchy = try hierarchyItems(allocator, graph.nodes.items, graph.edges.items, state);
                defer hierarchy.deinit(allocator);
                for (hierarchy.items) |item| {
                    try rows.append(allocator, .{ .kind = .loop, .index = item.index, .top = top, .project_path = graph.project.path, .depth = item.depth, .has_children = item.has_children });
                    top += 24;
                }
            }
            top += 38;
        }
    }
    if (inspection) |value| {
        top += 24;
        for (value.entries.items, 0..) |_, index| {
            try rows.append(allocator, .{ .kind = .worktree, .index = index, .top = top });
            top += 34;
        }
    }
    top += 42;
    try rows.append(allocator, .{ .kind = .quick_chat_overview, .index = 0, .top = top });
    top += 24;
    if (!chats_collapsed) {
        for (model.quick_chats.items, 0..) |_, index| {
            try rows.append(allocator, .{ .kind = .quick_chat, .index = index, .top = top });
            top += 24;
        }
    }
    return rows;
}

pub fn layoutFor(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) Layout {
    var loop_count: usize = 0;
    var graph_section_height: i32 = 62 + @as(i32, @intCast(openProjectPlaceholderCount(model) * 62));
    if (model.graphs.items.len != 0) {
        for (model.graphs.items) |summary| {
            loop_count += summary.nodes.items.len;
            graph_section_height += 62 + @as(i32, @intCast(summary.nodes.items.len * 24));
        }
    } else if (model.graph) |graph| {
        loop_count = graph.nodes.items.len;
        graph_section_height += 62 + @as(i32, @intCast(graph.nodes.items.len * 24));
    }

    return .{
        .base = Tokens.header_height + 78,
        .project_count = visibleProjectCount(model),
        .project_heading_count = projectHeadingCount(model),
        .loop_count = loop_count,
        .worktree_count = if (inspection) |value| value.entries.items.len else 0,
        .quick_chat_count = model.quick_chats.items.len,
        .graph_present = true,
        .inspection_present = inspection != null,
        .graph_section_height = graph_section_height,
    };
}

pub fn sharedGraphTop(model: *const GraphModel.Model, graph_index: usize) i32 {
    var top = Tokens.header_height + 78 +
        @as(i32, @intCast((visibleProjectCount(model) + projectHeadingCount(model)) * 24)) +
        @as(i32, @intCast(openProjectPlaceholderCount(model) * 62)) + 36;
    for (model.graphs.items[0..@min(graph_index, model.graphs.items.len)]) |summary| {
        top += 62 + @as(i32, @intCast(summary.nodes.items.len * 24));
    }
    return top;
}

pub fn sharedLoopTop(model: *const GraphModel.Model, graph_index: usize, node_index: usize) i32 {
    if (graph_index >= model.graphs.items.len) return sharedGraphTop(model, graph_index) + 48;
    const graph = model.graphs.items[graph_index];
    const position = hierarchyPosition(std.heap.page_allocator, graph.nodes.items, graph.edges.items, node_index) catch node_index;
    return sharedGraphTop(model, graph_index) + 48 + @as(i32, @intCast(position * 24));
}

pub fn sharedWorktreeTop(model: *const GraphModel.Model, index: usize) i32 {
    var top = Tokens.header_height + 78 +
        @as(i32, @intCast((visibleProjectCount(model) + projectHeadingCount(model)) * 24)) +
        @as(i32, @intCast(openProjectPlaceholderCount(model) * 62)) + 36;
    for (model.graphs.items) |summary| {
        top += 62 + @as(i32, @intCast(summary.nodes.items.len * 24));
    }
    return top + 24 + @as(i32, @intCast(index * 34));
}

pub fn rowAt(
    x: i32,
    y: i32,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    scroll_offset: i32,
    viewport_bottom: i32,
    state: ?*const State,
) ?Row {
    if (x < 0 or x >= Tokens.sidebar_width or y < Tokens.header_height or y >= viewport_bottom) return null;
    var rows = appendRows(std.heap.page_allocator, model, inspection, scroll_offset, state) catch return null;
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| {
        const height: i32 = switch (row.kind) {
            .local_heading, .remote_heading, .project, .open_project, .overview, .loop, .quick_chat_overview, .quick_chat => 24,
            .worktree => 34,
        };
        if (y >= row.top and y < row.top + height) return row;
    }
    return null;
}

fn hasLocalProjects(model: *const GraphModel.Model) bool {
    for (model.recent_projects.items) |project| {
        if (projectIsVisibleInSection(model, project, .local)) return true;
    }
    return false;
}

fn hasRemoteProjects(model: *const GraphModel.Model) bool {
    for (model.recent_projects.items) |project| {
        if (projectIsVisibleInSection(model, project, .remote)) return true;
    }
    return false;
}

const ProjectSection = enum { local, remote };

fn projectIsVisibleInSection(
    model: *const GraphModel.Model,
    project: GraphModel.Project,
    section: ProjectSection,
) bool {
    if (isProjectOpen(model, project.path)) return false;
    return project.isRemote() == (section == .remote);
}

fn visibleProjectCount(model: *const GraphModel.Model) usize {
    var count: usize = 0;
    for (model.recent_projects.items) |project| {
        if (projectIsVisibleInSection(model, project, if (project.isRemote()) .remote else .local)) count += 1;
    }
    return count;
}

fn projectHeadingCount(model: *const GraphModel.Model) usize {
    return @as(usize, @intFromBool(hasLocalProjects(model))) +
        @as(usize, @intFromBool(hasRemoteProjects(model)));
}

fn hasGraphForProject(model: *const GraphModel.Model, path: []const u8) bool {
    for (model.graphs.items) |graph| {
        if (std.mem.eql(u8, graph.project.path, path)) return true;
    }
    if (model.graph) |graph| return std.mem.eql(u8, graph.project.path, path);
    return false;
}

fn openProjectPlaceholderCount(model: *const GraphModel.Model) usize {
    var count: usize = 0;
    for (model.open_projects.items) |project| {
        if (!hasGraphForProject(model, project.path)) count += 1;
    }
    return count;
}

fn isProjectOpen(model: *const GraphModel.Model, path: []const u8) bool {
    for (model.open_projects.items) |project| {
        if (std.mem.eql(u8, project.path, path)) return true;
    }
    for (model.graphs.items) |graph| {
        if (std.mem.eql(u8, graph.project.path, path)) return true;
    }
    if (model.graph) |graph| return std.mem.eql(u8, graph.project.path, path);
    return false;
}

fn hierarchyItems(
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    state: ?*const State,
) !std.ArrayList(HierarchyItem) {
    var result: std.ArrayList(HierarchyItem) = .empty;
    errdefer result.deinit(allocator);
    const visited = try allocator.alloc(bool, nodes.len);
    defer allocator.free(visited);
    @memset(visited, false);
    var roots = try collectRootIndices(allocator, nodes, edges, state, false, visited);
    defer roots.deinit(allocator);
    for (roots.items) |index| try appendHierarchy(allocator, &result, visited, nodes, edges, index, 0, state);
    var unresolved = try collectRootIndices(allocator, nodes, edges, state, true, visited);
    defer unresolved.deinit(allocator);
    for (unresolved.items) |index| if (!visited[index]) try appendHierarchy(allocator, &result, visited, nodes, edges, index, 0, state);
    return result;
}

fn collectRootIndices(
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    state: ?*const State,
    only_unvisited: bool,
    visited: []const bool,
) !std.ArrayList(usize) {
    var indices: std.ArrayList(usize) = .empty;
    errdefer indices.deinit(allocator);
    for (nodes, 0..) |node, index| {
        if (only_unvisited) {
            if (!visited[index]) try indices.append(allocator, index);
            continue;
        }
        var incoming = false;
        for (edges) |edge| {
            if (std.mem.eql(u8, edge.kind, "handoff") and std.mem.eql(u8, edge.to, node.id)) {
                incoming = true;
                break;
            }
        }
        if (!incoming) try indices.append(allocator, index);
    }
    std.sort.heap(usize, indices.items, RootOrderContext{ .nodes = nodes, .state = state }, compareRootOrder);
    return indices;
}

const RootOrderContext = struct {
    nodes: []const GraphModel.Node,
    state: ?*const State,
};

fn rootOrderRank(state: ?*const State, id: []const u8) usize {
    if (state) |value| {
        for (value.root_order.items, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, id)) return index;
        }
    }
    return std.math.maxInt(usize);
}

fn compareRootOrder(context: RootOrderContext, lhs: usize, rhs: usize) bool {
    const lhs_rank = rootOrderRank(context.state, context.nodes[lhs].id);
    const rhs_rank = rootOrderRank(context.state, context.nodes[rhs].id);
    if (lhs_rank == rhs_rank) return lhs < rhs;
    return lhs_rank < rhs_rank;
}

fn appendHierarchy(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(HierarchyItem),
    visited: []bool,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    index: usize,
    depth: usize,
    state: ?*const State,
) !void {
    if (index >= nodes.len or visited[index]) return;
    visited[index] = true;
    var has_children = false;
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.kind, "handoff") and
            std.mem.eql(u8, edge.from, nodes[index].id) and
            GraphModel.findNodeIndexByID(nodes, edge.to) != null)
        {
            has_children = true;
            break;
        }
    }
    try result.append(allocator, .{ .index = index, .depth = depth, .has_children = has_children });
    if (depth != 0 or has_children) {
        if (state) |value| if (!value.isNodeExpanded(nodes[index].id)) {
            markDescendantsVisited(visited, nodes, edges, index);
            return;
        };
    }
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.kind, "handoff") or
            !std.mem.eql(u8, edge.from, nodes[index].id)) continue;
        const child = GraphModel.findNodeIndexByID(nodes, edge.to) orelse continue;
        try appendHierarchy(allocator, result, visited, nodes, edges, child, depth + 1, state);
    }
}

fn markDescendantsVisited(
    visited: []bool,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    index: usize,
) void {
    if (index >= nodes.len) return;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.kind, "handoff") or
            !std.mem.eql(u8, edge.from, nodes[index].id)) continue;
        const child = GraphModel.findNodeIndexByID(nodes, edge.to) orelse continue;
        if (visited[child]) continue;
        visited[child] = true;
        markDescendantsVisited(visited, nodes, edges, child);
    }
}

fn hierarchyPosition(
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    node_index: usize,
) !usize {
    var hierarchy = try hierarchyItems(allocator, nodes, edges, null);
    defer hierarchy.deinit(allocator);
    for (hierarchy.items, 0..) |item, position| if (item.index == node_index) return position;
    return node_index;
}

pub fn worktreeSectionBottom(project_count: usize, worktree_count: usize) i32 {
    return worktreeRowTop(project_count, 0, worktree_count) + 10;
}

pub fn contentBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection, state: ?*const State) i32 {
    const section = sidebarSectionBottom(model, inspection, state);
    var bottom = section;
    if (model.attentionCount() != 0) {
        bottom += 30 + @as(i32, @intCast(@min(model.attentionCount(), 4))) * 34;
    }
    if (model.activity.items.len != 0) {
        bottom += 18 + 24 + 34;
    }
    return bottom;
}

pub fn attentionRowAt(
    y: i32,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: ?*const State,
    scroll_offset: i32,
) ?usize {
    if (model.attentionCount() == 0) return null;
    const top = sidebarSectionBottom(model, inspection, state) - scroll_offset + 30;
    if (y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 34));
    return if (index < @min(model.attentionCount(), 4)) index else null;
}

pub fn sidebarSectionBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection, state: ?*const State) i32 {
    var rows = appendRows(std.heap.page_allocator, model, inspection, 0, state) catch return Tokens.header_height;
    defer rows.deinit(std.heap.page_allocator);
    if (rows.items.len == 0) return Tokens.header_height;
    const last = rows.items[rows.items.len - 1];
    return last.top + (if (last.kind == .worktree) @as(i32, 34) else 24);
}

pub fn needsYouStopBounds(
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: ?*const State,
    scroll_offset: i32,
    index: usize,
) c.RECT {
    const top = sidebarSectionBottom(model, inspection, state) - scroll_offset + 30 + @as(i32, @intCast(index)) * 34;
    return rect(Tokens.sidebar_width - 66, top + 6, Tokens.sidebar_width - 14, top + 26);
}

pub fn needsYouStopAt(
    x: i32,
    y: i32,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: ?*const State,
    scroll_offset: i32,
) ?usize {
    if (model.attentionCount() == 0) return null;
    const count = @min(model.attentionCount(), 4);
    for (0..count) |index| {
        const bounds = needsYouStopBounds(model, inspection, state, scroll_offset, index);
        if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom)
            return index;
    }
    return null;
}

pub fn activityFilterBounds(
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: *const State,
    scroll_offset: i32,
) c.RECT {
    const top = activityHeaderTop(model, inspection, state, scroll_offset);
    return rect(78, top + 2, 168, top + 22);
}

pub fn activityControlBounds(
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: *const State,
    scroll_offset: i32,
    control: ActivityDirection,
) c.RECT {
    const top = activityHeaderTop(model, inspection, state, scroll_offset);
    const left: i32 = if (control == .left) 184 else 208;
    return rect(left, top, left + 22, top + 22);
}

pub fn activityControlAt(
    x: i32,
    y: i32,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: *const State,
    scroll_offset: i32,
) ?ActivityControl {
    if (model.activity.items.len == 0) return null;
    const filter = activityFilterBounds(model, inspection, state, scroll_offset);
    if (x >= filter.left and x < filter.right and y >= filter.top and y < filter.bottom) return .filter;
    const left = activityControlBounds(model, inspection, state, scroll_offset, .left);
    if (x >= left.left and x < left.right and y >= left.top and y < left.bottom) return .left;
    const right = activityControlBounds(model, inspection, state, scroll_offset, .right);
    if (x >= right.left and x < right.right and y >= right.top and y < right.bottom) return .right;
    return null;
}

pub fn activityCardBounds(
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: *const State,
    scroll_offset: i32,
    visible_index: usize,
) c.RECT {
    const top = activityCardsTop(model, inspection, state, scroll_offset);
    const left = 18 + @as(i32, @intCast(visible_index)) * 112;
    return rect(left, top, @min(left + 100, Tokens.sidebar_width - 10), top + 34);
}

pub fn activityCardAt(
    x: i32,
    y: i32,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: *const State,
    scroll_offset: i32,
) ?usize {
    const viewport = activityViewport(model, state);
    for (0..viewport.visible_count) |visible_index| {
        const bounds = activityCardBounds(model, inspection, state, scroll_offset, visible_index);
        if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom)
            return activityEventAtVisible(model, state, visible_index);
    }
    return null;
}

pub fn activityViewport(model: *const GraphModel.Model, state: *const State) ActivityViewport {
    const total = filteredActivityCount(model, state);
    const capacity = @min(total, @as(usize, 2));
    const max_start = if (total > capacity) total - capacity else 0;
    return .{
        .start = @min(state.activity_scroll, max_start),
        .visible_count = capacity,
        .total_count = total,
    };
}

pub fn activityEventAtVisible(model: *const GraphModel.Model, state: *const State, visible_index: usize) ?usize {
    const viewport = activityViewport(model, state);
    if (visible_index >= viewport.visible_count) return null;
    const target = viewport.start + visible_index;
    var count: usize = 0;
    for (model.activity.items, 0..) |event, index| {
        if (!activityMatchesFilter(event, state)) continue;
        if (count == target) return index;
        count += 1;
    }
    return null;
}

pub fn stepActivity(state: *State, model: *const GraphModel.Model, direction: ActivityDirection) void {
    const viewport = activityViewport(model, state);
    if (viewport.total_count <= viewport.visible_count) {
        state.activity_scroll = 0;
        return;
    }
    if (direction == .left) {
        if (state.activity_scroll > 0) state.activity_scroll -= 1;
    } else {
        const max_start = viewport.total_count - viewport.visible_count;
        if (state.activity_scroll < max_start) state.activity_scroll += 1;
    }
}

pub fn toggleActivityAttentionOnly(state: *State, model: *const GraphModel.Model) void {
    state.activity_attention_only = !state.activity_attention_only;
    const viewport = activityViewport(model, state);
    if (viewport.total_count <= viewport.visible_count) {
        state.activity_scroll = 0;
    } else if (state.activity_scroll > viewport.total_count - viewport.visible_count) {
        state.activity_scroll = viewport.total_count - viewport.visible_count;
    }
}

pub fn rootIDs(
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    state: ?*const State,
) !std.ArrayList([]const u8) {
    const visited = try allocator.alloc(bool, nodes.len);
    defer allocator.free(visited);
    @memset(visited, false);
    var root_indices = try collectRootIndices(allocator, nodes, edges, state, false, visited);
    defer root_indices.deinit(allocator);
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);
    for (root_indices.items) |index| try ids.append(allocator, nodes[index].id);
    return ids;
}

pub fn reorderRootIDs(
    state: *State,
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    dragged_id: []const u8,
    drop_index: usize,
) !bool {
    var roots = try rootIDs(allocator, nodes, edges, state);
    defer roots.deinit(allocator);
    const from_index = for (roots.items, 0..) |id, index| {
        if (std.mem.eql(u8, id, dragged_id)) break index;
    } else return false;
    const bounded_drop = @min(drop_index, roots.items.len);
    const target = if (bounded_drop > from_index) bounded_drop - 1 else bounded_drop;
    if (target == from_index) return false;
    const dragged = roots.orderedRemove(from_index);
    roots.insert(allocator, target, dragged) catch return error.OutOfMemory;
    try state.reorderRoots(roots.items);
    return true;
}

fn filteredActivityCount(model: *const GraphModel.Model, state: *const State) usize {
    var count: usize = 0;
    for (model.activity.items) |event| {
        if (activityMatchesFilter(event, state)) count += 1;
    }
    return count;
}

fn activityMatchesFilter(event: GraphModel.ActivityEvent, state: *const State) bool {
    return !state.activity_attention_only or activityNeedsAttention(event.state);
}

fn activityHeaderTop(
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: *const State,
    scroll_offset: i32,
) i32 {
    const section = sidebarSectionBottom(model, inspection, state);
    const attention_rows = @min(model.attentionCount(), 4);
    return section - scroll_offset + 30 + (@as(i32, @intCast(attention_rows)) * 34) + 18;
}

fn activityCardsTop(
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    state: *const State,
    scroll_offset: i32,
) i32 {
    return activityHeaderTop(model, inspection, state, scroll_offset) + 24;
}

pub fn maxScroll(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection, viewport_bottom: i32, state: ?*const State) i32 {
    return @max(contentBottom(model, inspection, state) - viewport_bottom, 0);
}

pub fn clampScroll(value: i32, maximum: i32) i32 {
    return @min(@max(value, 0), @max(maximum, 0));
}

pub fn hitTestWorktree(x: i32, y: i32, project_count: usize, count: usize, scroll_offset: i32, viewport_bottom: i32) ?usize {
    if (x < 12 or x >= Tokens.sidebar_width) return null;
    if (y < Tokens.header_height or y >= viewport_bottom) return null;
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = 0, .worktree_count = 0 };
    const top = layout.worktreeTop(0) - scroll_offset;
    if (y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 34));
    if (index >= count) return null;
    return index;
}

pub fn hitTestProject(x: i32, y: i32, model: *const GraphModel.Model, scroll_offset: i32, viewport_bottom: i32) ?usize {
    if (x < 0 or x >= Tokens.sidebar_width or y < Tokens.header_height or y >= viewport_bottom) return null;
    const top = Tokens.header_height + 78 - scroll_offset;
    if (y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 24));
    if (index >= model.recent_projects.items.len) return null;
    return index;
}

pub fn hitTestOverviewLoop(x: i32, y: i32, model: *const GraphModel.Model, scroll_offset: i32, viewport_bottom: i32) ?usize {
    if (x < 0 or x >= Tokens.sidebar_width or y < Tokens.header_height or y >= viewport_bottom) return null;
    const top = Tokens.header_height + 78 +
        @as(i32, @intCast((visibleProjectCount(model) + projectHeadingCount(model)) * 24)) -
        scroll_offset;
    if (model.graph == null and model.graphs.items.len == 0 or y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 24));
    if (index >= layoutFor(model, null).loop_count) return null;
    return index;
}

fn reason(entry: WorktreeStatus.Entry) []const u8 {
    if (entry.primary) return "primary checkout";
    if (entry.locked) return "locked";
    if (entry.prunable) return "prunable/stale";
    if (entry.bound_running) return "bound to active loop";
    if (entry.dirty or entry.untracked or entry.conflicted) return "local changes";
    if (!entry.pushed) return "unpushed commits";
    if (!entry.landed) return "not landed on default";
    return if (WorktreeStatus.decision(entry) == .reclaimable) "safe to reclaim" else "unsafe to reclaim";
}

test "worktree row hit testing selects only visible rows" {
    const top = worktreeRowTop(2, 0, 0);
    try std.testing.expectEqual(@as(?usize, 0), hitTestWorktree(24, top + 4, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(?usize, 1), hitTestWorktree(24, top + 34 + 4, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(?usize, null), hitTestWorktree(Tokens.sidebar_width + 1, top, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(?usize, null), hitTestWorktree(24, top + 68, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(i32, worktreeRowTop(3, 0, 0) - worktreeRowTop(1, 0, 0)), 48);
}

test "root reorder validates uniqueness and replaces order atomically" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.reorderRoots(&.{ "root-a", "root-b" });
    try std.testing.expectEqual(@as(usize, 2), state.root_order.items.len);
    try std.testing.expectEqualStrings("root-a", state.root_order.items[0]);
    try std.testing.expectError(error.InvalidRootOrder, state.reorderRoots(&.{ "root-a", "root-a" }));
    try std.testing.expectEqualStrings("root-a", state.root_order.items[0]);
    try std.testing.expectEqualStrings("root-b", state.root_order.items[1]);
}

test "root ordering follows persisted root ids and can be reordered by drop index" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("root-b"), .title = @constCast("Root B"), .loop_type = @constCast("turnBased"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("root-a"), .title = @constCast("Root A"), .loop_type = @constCast("turnBased"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
    };
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var initial = try rootIDs(std.testing.allocator, &nodes, &.{}, &state);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("root-b", initial.items[0]);
    try std.testing.expect(try reorderRootIDs(&state, std.testing.allocator, &nodes, &.{}, "root-a", 0));
    try std.testing.expectEqualStrings("root-a", state.root_order.items[0]);
    var reordered = try rootIDs(std.testing.allocator, &nodes, &.{}, &state);
    defer reordered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("root-a", reordered.items[0]);
    try std.testing.expectEqualStrings("root-b", reordered.items[1]);
    try std.testing.expect(try reorderRootIDs(&state, std.testing.allocator, &nodes, &.{}, "root-a", 2));
    var moved_to_end = try rootIDs(std.testing.allocator, &nodes, &.{}, &state);
    defer moved_to_end.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("root-b", moved_to_end.items[0]);
    try std.testing.expectEqualStrings("root-a", moved_to_end.items[1]);
}

test "activity viewport filters attention events and scrolls horizontally" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    for ([_][]const u8{ "running", "failed", "blocked" }, 0..) |state_text, index| {
        try model.activity.append(.{
            .title = try std.fmt.allocPrint(std.testing.allocator, "Event {d}", .{index}),
            .state = try std.testing.allocator.dupe(u8, state_text),
        });
    }
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 2), activityViewport(&model, &state).visible_count);
    try std.testing.expectEqual(@as(?usize, 0), activityEventAtVisible(&model, &state, 0));
    stepActivity(&state, &model, .right);
    try std.testing.expectEqual(@as(?usize, 1), activityEventAtVisible(&model, &state, 0));
    toggleActivityAttentionOnly(&state, &model);
    try std.testing.expect(state.activity_attention_only);
    try std.testing.expectEqual(@as(usize, 2), activityViewport(&model, &state).total_count);
    try std.testing.expectEqual(@as(?usize, 1), activityEventAtVisible(&model, &state, 0));
    try std.testing.expectEqual(@as(?usize, 2), activityEventAtVisible(&model, &state, 1));
}

test "needs-you stop and activity hit targets remain bounded" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.attention.append(.{
        .id = try std.testing.allocator.dupe(u8, "attention"),
        .title = try std.testing.allocator.dupe(u8, "Needs You"),
        .loop_type = try std.testing.allocator.dupe(u8, "goal"),
        .state = try std.testing.allocator.dupe(u8, "failed"),
        .activity = try std.testing.allocator.dupe(u8, "failed"),
        .presence = try std.testing.allocator.dupe(u8, "idle"),
        .worktree_path = try std.testing.allocator.dupe(u8, ""),
        .worktree_branch = try std.testing.allocator.dupe(u8, ""),
    });
    try model.activity.append(.{
        .title = try std.testing.allocator.dupe(u8, "Activity"),
        .state = try std.testing.allocator.dupe(u8, "failed"),
    });
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const stop = needsYouStopBounds(&model, null, &state, 0, 0);
    try std.testing.expectEqual(@as(?usize, 0), needsYouStopAt(stop.left + 2, stop.top + 2, &model, null, &state, 0));
    const card = activityCardBounds(&model, null, &state, 0, 0);
    try std.testing.expectEqual(@as(?usize, 0), activityCardAt(card.left + 2, card.top + 2, &model, null, &state, 0));
    const filter = activityFilterBounds(&model, null, &state, 0);
    try std.testing.expectEqual(ActivityControl.filter, activityControlAt(filter.left + 2, filter.top + 2, &model, null, &state, 0).?);
}

test "shared sidebar layout routes every loop row after project rows and scroll" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .name = try std.testing.allocator.dupe(u8, "Project"),
        .path = try std.testing.allocator.dupe(u8, "C:\\project"),
    });
    var graph = GraphModel.Graph{
        .project = .{
            .path = try std.testing.allocator.dupe(u8, "C:\\project"),
            .name = try std.testing.allocator.dupe(u8, "Project"),
        },
        .nodes = std.array_list.Managed(GraphModel.Node).init(std.testing.allocator),
        .edges = std.array_list.Managed(GraphModel.Edge).init(std.testing.allocator),
    };
    try graph.nodes.append(.{
        .id = try std.testing.allocator.dupe(u8, "node-7"),
        .title = try std.testing.allocator.dupe(u8, "Seven"),
        .loop_type = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, ""),
        .activity = try std.testing.allocator.dupe(u8, ""),
        .presence = try std.testing.allocator.dupe(u8, ""),
    });
    try graph.nodes.append(.{
        .id = try std.testing.allocator.dupe(u8, "node-42"),
        .title = try std.testing.allocator.dupe(u8, "Forty two"),
        .loop_type = try std.testing.allocator.dupe(u8, ""),
        .state = try std.testing.allocator.dupe(u8, ""),
        .activity = try std.testing.allocator.dupe(u8, ""),
        .presence = try std.testing.allocator.dupe(u8, ""),
    });
    model.graph = graph;
    const layout = layoutFor(&model, null);
    for (0..2) |index| {
        const row = rowAt(24, layout.loopTop(index) - 11, &model, null, 11, 700, null) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(RowKind.loop, row.kind);
        try std.testing.expectEqual(index, row.index);
    }
}

test "multi-project rows share render and hit-test offsets with project identity" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    const local = try std.fs.cwd().readFileAlloc(allocator, "fixtures/daemon-v2-multi-project.json", 64 * 1024);
    defer allocator.free(local);
    const remote = try std.fs.cwd().readFileAlloc(allocator, "fixtures/daemon-v2-multi-project-remote.json", 64 * 1024);
    defer allocator.free(remote);
    _ = try model.updateFromFrame(local);
    _ = try model.updateFromFrame(remote);
    const local_top = sharedLoopTop(&model, 0, 0);
    const remote_top = sharedLoopTop(&model, 1, 0);
    const local_row = rowAt(24, local_top + 4, &model, null, 0, 700, null) orelse return error.TestUnexpectedResult;
    const remote_row = rowAt(24, remote_top + 4, &model, null, 0, 700, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("C:\\work\\local", local_row.project_path.?);
    try std.testing.expectEqualStrings("ssh://build/remote", remote_row.project_path.?);
    try std.testing.expectEqual(
        layoutFor(&model, null).quickChatRowTop(model.quick_chats.items.len + 1),
        sidebarSectionBottom(&model, null, null),
    );
}

test "scroll-adjusted generated rows hit titles loops and worktrees" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"a1","title":"Loop A","state":"running"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try model.recent_projects.append(.{
        .path = try allocator.dupe(u8, "recent"),
        .name = try allocator.dupe(u8, "Recent"),
    });
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = try allocator.dupe(u8, "main"),
        .project_path = try allocator.dupe(u8, "A"),
    };
    defer WorktreeStatus.deinitInspection(allocator, &inspection);
    try inspection.entries.append(.{
        .path = try allocator.dupe(u8, "wt"),
        .branch = try allocator.dupe(u8, "main"),
    });
    const scroll: i32 = 37;
    var rows = try appendRows(allocator, &model, &inspection, scroll, null);
    defer rows.deinit(allocator);
    for (rows.items) |row| {
        const hit = rowAt(24, row.top + 4, &model, &inspection, scroll, 700, null) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(row.kind, hit.kind);
        if (row.kind == .project or row.kind == .open_project or row.kind == .loop)
            try std.testing.expectEqualStrings(row.project_path orelse "recent", hit.project_path orelse "recent");
    }
}

test "sidebar scroll clamps overflow, shrink, and resize" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    for (0..3) |index| {
        try model.recent_projects.append(.{
            .path = try std.fmt.allocPrint(std.testing.allocator, "project-{d}", .{index}),
            .name = try std.fmt.allocPrint(std.testing.allocator, "Project {d}", .{index}),
        });
    }
    for (0..4) |_| try model.attention.append(.{
        .id = try std.testing.allocator.dupe(u8, "attention"),
        .title = try std.testing.allocator.dupe(u8, "Needs You"),
        .loop_type = try std.testing.allocator.dupe(u8, "goal"),
        .state = try std.testing.allocator.dupe(u8, "failed"),
        .activity = try std.testing.allocator.dupe(u8, "failed"),
        .presence = try std.testing.allocator.dupe(u8, "idle"),
        .worktree_path = try std.testing.allocator.dupe(u8, ""),
        .worktree_branch = try std.testing.allocator.dupe(u8, ""),
    });
    model.graph = .{
        .project = .{
            .path = try std.testing.allocator.dupe(u8, "project-0"),
            .name = try std.testing.allocator.dupe(u8, "Project 0"),
        },
        .nodes = std.array_list.Managed(GraphModel.Node).init(std.testing.allocator),
        .edges = std.array_list.Managed(GraphModel.Edge).init(std.testing.allocator),
    };
    for (0..3) |_| try model.activity.append(.{
        .title = try std.testing.allocator.dupe(u8, "Activity"),
        .state = try std.testing.allocator.dupe(u8, "succeeded"),
    });
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .default_branch = @constCast("main"),
        .project_path = @constCast("project-0"),
    };
    for (0..5) |_| try inspection.entries.append(.{
        .path = @constCast("worktree"),
        .branch = @constCast("branch"),
    });
    const short_max = maxScroll(&model, &inspection, 400, null);
    // Activity adds its section gap, control row, and card below Needs You.
    const expected_short = sidebarSectionBottom(&model, &inspection, null) + 30 + 4 * 34 + 18 + 24 + 34 - 400;
    try std.testing.expectEqual(expected_short, short_max);
    const activity_only_max = maxScroll(&model, &inspection, 400, null);
    try std.testing.expectEqual(short_max, activity_only_max);
    var scroll: i32 = 0;
    // Overshoot comfortably so this assertion always exercises clamping.
    for (0..40) |_| scroll = clampScroll(scroll + 40, short_max);
    try std.testing.expectEqual(short_max, scroll);
    while (model.activity.items.len > 1) {
        const event = model.activity.pop() orelse break;
        std.testing.allocator.free(event.title);
        std.testing.allocator.free(event.state);
    }
    try std.testing.expectEqual(short_max, maxScroll(&model, &inspection, 400, null));
    while (model.recent_projects.items.len > 1) {
        const project = model.recent_projects.pop() orelse break;
        std.testing.allocator.free(project.path);
        std.testing.allocator.free(project.name);
    }
    while (model.attention.items.len > 1) {
        const node = model.attention.pop() orelse break;
        std.testing.allocator.free(node.id);
        std.testing.allocator.free(node.title);
        std.testing.allocator.free(node.loop_type);
        std.testing.allocator.free(node.state);
        std.testing.allocator.free(node.activity);
        std.testing.allocator.free(node.presence);
        std.testing.allocator.free(node.worktree_path);
        std.testing.allocator.free(node.worktree_branch);
    }
    inspection.entries.shrinkRetainingCapacity(2);
    const reduced_max = maxScroll(&model, &inspection, 500, null);
    const expected_reduced = @max(sidebarSectionBottom(&model, &inspection, null) + 30 + 1 * 34 + 18 + 24 + 34 - 500, 0);
    try std.testing.expectEqual(expected_reduced, reduced_max);
    scroll = clampScroll(scroll, reduced_max);
    try std.testing.expectEqual(reduced_max, scroll);
    try std.testing.expectEqual(@as(i32, 0), clampScroll(-50, reduced_max));
    inspection.entries.deinit();
}

test "sidebar without graph counts only static rendered content" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "project"),
        .name = try std.testing.allocator.dupe(u8, "Project"),
    });
    const no_graph_max = maxScroll(&model, null, 100, null);
    try std.testing.expectEqual(@as(i32, Tokens.header_height + 78 + 24 + 24 + 62 + 42 + 24 - 100), no_graph_max);
    try std.testing.expectEqual(@as(i32, 180), clampScroll(180, no_graph_max));
}

test "global Graph row remains pinned without an open project" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    const graph_row = rowAt(24, rows.items[0].top + 4, &model, null, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.overview, graph_row.kind);
}

test "recent projects are grouped into local and remote sections" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "ssh://host/repo"),
        .name = try std.testing.allocator.dupe(u8, "Remote"),
    });
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\repo"),
        .name = try std.testing.allocator.dupe(u8, "Local"),
    });
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), rows.items[1].index);
    try std.testing.expectEqual(RowKind.remote_heading, rows.items[2].kind);
    try std.testing.expectEqual(@as(usize, 0), rows.items[3].index);
}

test "recent project rows exclude folders already open in the projects list" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\open"),
        .name = try std.testing.allocator.dupe(u8, "Open local"),
    });
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\recent"),
        .name = try std.testing.allocator.dupe(u8, "Recent local"),
    });
    try model.open_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\open"),
        .name = try std.testing.allocator.dupe(u8, "Open local"),
    });
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[1].kind);
    try std.testing.expectEqualStrings("C:\\recent", rows.items[1].project_path.?);
    try std.testing.expectEqual(RowKind.overview, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.open_project, rows.items[3].kind);
    try std.testing.expectEqualStrings("C:\\open", rows.items[3].project_path.?);
}

test "handoff edges derive stable nested loop order and depth" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("child"), .title = @constCast("Child"), .loop_type = @constCast("turnBased"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("root"), .title = @constCast("Root"), .loop_type = @constCast("turnBased"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
    };
    const edges = [_]GraphModel.Edge{.{
        .from = @constCast("root"),
        .to = @constCast("child"),
        .kind = @constCast("handoff"),
    }};
    var hierarchy = try hierarchyItems(std.testing.allocator, &nodes, &edges, null);
    defer hierarchy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.items[0].index);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.items[0].depth);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.items[1].index);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.items[1].depth);
}

test "message and spawn edges do not define sidebar hierarchy" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("first"), .title = @constCast("First"), .loop_type = @constCast("turnBased"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("second"), .title = @constCast("Second"), .loop_type = @constCast("turnBased"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
    };
    const edges = [_]GraphModel.Edge{
        .{ .from = @constCast("first"), .to = @constCast("second"), .kind = @constCast("message") },
        .{ .from = @constCast("second"), .to = @constCast("first"), .kind = @constCast("spawn") },
    };
    var hierarchy = try hierarchyItems(std.testing.allocator, &nodes, &edges, null);
    defer hierarchy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hierarchy.items.len);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.items[0].depth);
    try std.testing.expect(!hierarchy.items[0].has_children);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.items[1].depth);
    try std.testing.expect(!hierarchy.items[1].has_children);
}

test "sidebar groups and nested disclosures collapse independently and persist expansion" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\local"),
        .name = try std.testing.allocator.dupe(u8, "Local"),
    });
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "ssh://host/remote"),
        .name = try std.testing.allocator.dupe(u8, "Remote"),
    });
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.local_collapsed = true;
    var rows = try appendRows(std.testing.allocator, &model, null, 0, &state);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.remote_heading, rows.items[1].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[2].kind);
    try std.testing.expectEqual(@as(usize, 1), rows.items[2].index);

    try state.toggleNode("root");
    const encoded = try state.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var restored = State.init(std.testing.allocator);
    defer restored.deinit();
    try restored.decode(encoded);
    try std.testing.expect(restored.isNodeExpanded("root"));
    try restored.toggleNode("root");
    try std.testing.expect(!restored.isNodeExpanded("root"));
}

test "daemon hierarchy starts with only roots visible and reveals children by stable id" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\fixture","name":"Fixture"},"nodes":[{"id":"root","title":"Root","state":"running"},{"id":"child","title":"Child","state":"idle"}],"edges":[{"id":"edge","from":"root","to":"child","kind":"handoff"}]}}}
    ;
    _ = try model.updateFromFrame(frame);
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var collapsed = try appendRows(std.testing.allocator, &model, null, 0, &state);
    defer collapsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), countRows(collapsed.items, .loop));
    try state.toggleNode("root");
    var expanded = try appendRows(std.testing.allocator, &model, null, 0, &state);
    defer expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countRows(expanded.items, .loop));
}

fn countRows(rows: []const Row, kind: RowKind) usize {
    var count: usize = 0;
    for (rows) |row| if (row.kind == kind) {
        count += 1;
    };
    return count;
}

test "quick chats remain selectable without an open graph or inspection" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.quick_chats.append(.{
        .id = try std.testing.allocator.dupe(u8, "chat-1"),
        .title = try std.testing.allocator.dupe(u8, "Scratch"),
        .backend = try std.testing.allocator.dupe(u8, "claudeCode"),
    });
    const layout = layoutFor(&model, null);
    try std.testing.expect(layout.quickChatHeadingTop() + 11 < layout.quickChatRowTop(0));
    const overview = rowAt(24, layout.quickChatRowTop(0) + 4, &model, null, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat_overview, overview.kind);
    const row = rowAt(24, layout.quickChatRowTop(1) + 4, &model, null, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat, row.kind);
    try std.testing.expectEqual(@as(usize, 0), row.index);
    try std.testing.expectEqual(
        @as(i32, Tokens.header_height + 78 + 62 + 42),
        layout.quickChatRowTop(0),
    );
    try std.testing.expect(rowAt(24, layout.quickChatHeadingTop() + 4, &model, null, 0, 700, null) == null);
    try std.testing.expectEqual(layout.quickChatRowTop(2), sidebarSectionBottom(&model, null, null));
}

test "quick chat heading and rows stay distinct across graph layouts" {
    const layouts = [_]Layout{
        .{ .base = 100, .project_count = 2, .loop_count = 0, .worktree_count = 0, .graph_present = false },
        .{ .base = 100, .project_count = 2, .loop_count = 3, .worktree_count = 0 },
        .{ .base = 100, .project_count = 2, .loop_count = 3, .worktree_count = 4, .inspection_present = true },
    };
    for (layouts) |layout| {
        try std.testing.expect(layout.quickChatHeadingTop() + 11 < layout.quickChatRowTop(0));
        try std.testing.expectEqual(@as(i32, 24), layout.quickChatRowTop(1) - layout.quickChatRowTop(0));
    }
}

test "sidebar loop presentation preserves type and terminal states" {
    try std.testing.expectEqual(@as(u32, 0x0048C78E), loopAccent("goalBased"));
    try std.testing.expectEqualStrings("done", compactState("succeeded"));
    try std.testing.expectEqualStrings("running", compactState("running"));
    try std.testing.expectEqual(@as(u32, 0x005F5FFF), stateColor("failed"));
}

test "elapsedText renders a compact age and its unit boundaries honestly" {
    const allocator = std.testing.allocator;
    const base: i64 = 788918400;

    // Invalid/degenerate createdAt values must not be presented as an age.
    const not_created = try elapsedText(allocator, 0, base + 1000);
    defer allocator.free(not_created);
    try std.testing.expectEqualStrings("-", not_created);

    const negative_created = try elapsedText(allocator, -5, base + 1000);
    defer allocator.free(negative_created);
    try std.testing.expectEqualStrings("-", negative_created);

    const not_yet_created = try elapsedText(allocator, base + 1000, base + 999);
    defer allocator.free(not_yet_created);
    try std.testing.expectEqualStrings("-", not_yet_created);

    const same_instant = try elapsedText(allocator, base + 1000, base + 1000);
    defer allocator.free(same_instant);
    try std.testing.expectEqualStrings("-", same_instant);

    // Seconds stay seconds up to the 59s/60s boundary, where the unit flips to minutes.
    const fifty_nine_seconds = try elapsedText(allocator, base, base + 59);
    defer allocator.free(fifty_nine_seconds);
    try std.testing.expectEqualStrings("59s", fifty_nine_seconds);

    const sixty_seconds = try elapsedText(allocator, base, base + 60);
    defer allocator.free(sixty_seconds);
    try std.testing.expectEqualStrings("1m", sixty_seconds);

    // Minutes stay minutes up to the 3599s/3600s boundary, where the unit flips to hours.
    const fifty_nine_minutes = try elapsedText(allocator, base, base + 3599);
    defer allocator.free(fifty_nine_minutes);
    try std.testing.expectEqualStrings("59m", fifty_nine_minutes);

    const one_hour = try elapsedText(allocator, base, base + 3600);
    defer allocator.free(one_hour);
    try std.testing.expectEqualStrings("1h", one_hour);

    // Hours stay hours up to the 86399s/86400s boundary, where the unit flips to days.
    const twenty_three_hours = try elapsedText(allocator, base, base + 86399);
    defer allocator.free(twenty_three_hours);
    try std.testing.expectEqualStrings("23h", twenty_three_hours);

    const one_day = try elapsedText(allocator, base, base + 86400);
    defer allocator.free(one_day);
    try std.testing.expectEqualStrings("1d", one_day);

    // Multi-day ages keep truncating to whole days rather than rolling into weeks.
    const ten_days = try elapsedText(allocator, base, base + 86400 * 10 + 3599);
    defer allocator.free(ten_days);
    try std.testing.expectEqualStrings("10d", ten_days);
}

test "update banner is a bounded footer action" {
    const bounds = updateBannerRect(700, false);
    try std.testing.expect(updateBannerAt(bounds.left, bounds.top, 700, true, false));
    try std.testing.expect(updateBannerAt(bounds.right - 1, bounds.bottom - 1, 700, true, false));
    try std.testing.expect(!updateBannerAt(bounds.right, bounds.bottom - 1, 700, true, false));
    try std.testing.expect(!updateBannerAt(bounds.left, bounds.top, 700, false, false));
    try std.testing.expect(updateBannerRect(700, true).bottom < errorFooterRect(700).top);
}

test "error footer exposes an inset wrapping rect" {
    const footer = errorFooterRect(700);
    const text = errorFooterTextRect(700);
    try std.testing.expect(text.left > footer.left);
    try std.testing.expect(text.right < footer.right);
    try std.testing.expect(text.top > footer.top);
    try std.testing.expect(text.bottom < footer.bottom);
}

fn rect(left: i32, top: i32, right: i32, bottom: i32) c.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn fill(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const brush = c.CreateSolidBrush(color);
    if (brush != null) {
        _ = c.FillRect(hdc, &bounds, brush);
        _ = c.DeleteObject(brush);
    }
}

fn drawText(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: i32,
    y: i32,
    size: i32,
    color: u32,
) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch return;
    defer allocator.free(wide);
    const old_font = AppFont.select(hdc, size, false);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = rect(x, y, 1200, y + size + 8);
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
    _ = c.SelectObject(hdc, old_font);
}

fn drawTextRect(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    text: []const u8,
    bounds_value: c.RECT,
    size: i32,
    color: u32,
    format: c.UINT,
) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch return;
    defer allocator.free(wide);
    const old_font = AppFont.select(hdc, size, false);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, format);
    _ = c.SelectObject(hdc, old_font);
}
