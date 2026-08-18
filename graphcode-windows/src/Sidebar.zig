const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const Tokens = @import("DesignTokens.zig");
const c = @import("Win32.zig").c;

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
    allocator: std.mem.Allocator,
) void {
    const sidebar = rect(0, Tokens.header_height, Tokens.sidebar_width, 1200);
    fill(hdc, sidebar, Tokens.workspace_rail);
    drawText(hdc, allocator, "GRAPH", 18, Tokens.header_height + 20, 16, 0x00FFFFFF);
    drawText(hdc, allocator, "Projects", 18, Tokens.header_height + 54, 14, 0x00B8B8B8);
    var rows = appendRows(allocator, model, inspection, scroll_offset) catch return;
    defer rows.deinit(allocator);
    for (rows.items) |row| {
        switch (row.kind) {
            .local_heading => {
                drawText(hdc, allocator, "v  LOCAL", 18, row.top, 10, 0x007A7A7A);
            },
            .remote_heading => {
                drawText(hdc, allocator, "v  REMOTE", 18, row.top, 10, 0x007A7A7A);
            },
            .project => {
                const project = model.recent_projects.items[row.index];
                drawText(hdc, allocator, if (project.isRemote()) "R" else "L", 18, row.top + 1, 9, 0x007A7A7A);
                drawText(hdc, allocator, project.name, 34, row.top, 13, 0x00E6E6E6);
            },
            .overview => drawText(hdc, allocator, "Open", 18, row.top, 14, 0x00B8B8B8),
            .open_project => if (row.project_path) |path| if (model.graphFor(path)) |summary| {
                const selected = if (model.selected_project_path) |selected_path|
                    std.mem.eql(u8, selected_path, path)
                else false;
                drawText(hdc, allocator, "v", 18, row.top, 9, 0x007A7A7A);
                drawText(hdc, allocator, if (summary.project.isRemote()) "R" else "L", 31, row.top + 1, 9, 0x007A7A7A);
                drawText(hdc, allocator, summary.project.name, 44, row.top, 13,
                    if (selected) 0x00FFFFFF else 0x00D0D0D0);
            },
            .loop => if (row.project_path) |path| if (model.graphFor(path)) |summary| {
                if (row.index < summary.nodes.items.len) {
                    const node = summary.nodes.items[row.index];
                    const indent = @as(i32, @intCast(row.depth * 12));
                    if (row.depth != 0) drawText(hdc, allocator, ">", 28 + indent, row.top, 9, 0x006A6A6A);
                    fill(hdc, rect(30 + indent, row.top - 2, 33 + indent, row.top + 17), loopAccent(node.loop_type));
                    drawText(hdc, allocator, node.title, 39 + indent, row.top, 11, 0x00E6E6E6);
                    drawText(hdc, allocator, compactState(node.state), 168, row.top, 9, stateColor(node.state));
                }
            },
            .worktree => if (inspection) |value| {
                const entry = value.entries.items[row.index];
                const selected = std.mem.eql(u8, entry.path, selected_worktree_path);
                if (selected and WorktreeStatus.decision(entry) == .reclaimable)
                    fill(hdc, rect(12, row.top - 3, Tokens.sidebar_width - 12, row.top + 25), 0x003A3A44);
                drawText(hdc, allocator, entry.path, 24, row.top, 11, 0x00E6E6E6);
                drawText(hdc, allocator, reason(entry), 24, row.top + 14, 10,
                    if (WorktreeStatus.decision(entry) == .reclaimable) 0x0078D7A8 else 0x00FFCD7A);
            },
            .quick_chat_overview => {
                drawText(hdc, allocator, "v", 18, row.top, 9, 0x007A7A7A);
                drawText(hdc, allocator, "Quick Chats", 32, row.top, 13, 0x00E6E6E6);
            },
            .quick_chat => if (row.index < model.quick_chats.items.len)
                drawText(hdc, allocator, model.quick_chats.items[row.index].title, 24, row.top, 11, 0x00E6E6E6),
        }
    }
    const layout = layoutFor(model, inspection);
    drawText(hdc, allocator, "CHATS", 18, layout.quickChatHeadingTop() - scroll_offset, 10, 0x007A7A7A);

    const section_y = sidebarSectionBottom(model, inspection) - scroll_offset;
    if (model.attentionCount() != 0) {
        drawText(hdc, allocator, "Needs you", 18, section_y + 10, 11, 0x00FFCD7A);
        var attention_y = section_y + 30;
        if (model.attention_entries.items.len != 0) {
            for (model.attention_entries.items[0..@min(model.attention_entries.items.len, 4)]) |entry| {
                drawText(hdc, allocator, entry.node.title, 24, attention_y, 11, 0x00E6E6E6);
                drawText(hdc, allocator, attentionContext(model, entry), 24, attention_y + 15, 9, stateColor(entry.node.state));
                attention_y += 34;
            }
        } else {
            for (model.attention.items[0..@min(model.attention.items.len, 4)]) |node| {
                drawText(hdc, allocator, node.title, 24, attention_y, 11, 0x00E6E6E6);
                drawText(hdc, allocator, compactState(node.state), 24, attention_y + 15, 9, stateColor(node.state));
                attention_y += 34;
            }
        }

    }
    if (ingress_error.len != 0) {
        const bounds = errorFooterRect(viewport_bottom);
        fill(hdc, bounds, 0x00242448);
        drawText(hdc, allocator, ingress_error, bounds.left + 10, bounds.top + 10, 10, 0x006060FF);
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

pub fn updateBannerRect(viewport_bottom: i32, has_error: bool) c.RECT {
    const error_offset: i32 = if (has_error) 50 else 0;
    return rect(8, viewport_bottom - 92 - error_offset, Tokens.sidebar_width - 8, viewport_bottom - 42 - error_offset);
}

pub fn updateBannerAt(x: i32, y: i32, viewport_bottom: i32, available: bool, has_error: bool) bool {
    if (!available) return false;
    const bounds = updateBannerRect(viewport_bottom, has_error);
    return x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom;
}

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
        .project_count = model.recent_projects.items.len,
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
};
const HierarchyItem = struct { index: usize, depth: usize };
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
) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    var top: i32 = Tokens.header_height + 78 - scroll_offset;
    if (hasLocalProjects(model)) {
        try rows.append(allocator, .{ .kind = .local_heading, .index = 0, .top = top });
        top += 24;
    }
    for (model.recent_projects.items, 0..) |project, index| {
        if (project.isRemote()) continue;
        try rows.append(allocator, .{ .kind = .project, .index = index, .top = top, .project_path = project.path });
        top += 24;
    }
    if (hasRemoteProjects(model)) {
        try rows.append(allocator, .{ .kind = .remote_heading, .index = 0, .top = top });
        top += 24;
    }
    for (model.recent_projects.items, 0..) |project, index| {
        if (!project.isRemote()) continue;
        try rows.append(allocator, .{ .kind = .project, .index = index, .top = top, .project_path = project.path });
        top += 24;
    }
    if (model.graphs.items.len != 0 or model.graph != null) {
        try rows.append(allocator, .{ .kind = .overview, .index = 0, .top = top + 24 });
        top += 62;
        if (model.graphs.items.len != 0) {
            for (model.graphs.items, 0..) |summary, graph_index| {
                try rows.append(allocator, .{ .kind = .open_project, .index = graph_index, .top = top, .project_path = summary.project.path });
                top += 24;
                var hierarchy = try hierarchyItems(allocator, summary.nodes.items, summary.edges.items);
                defer hierarchy.deinit(allocator);
                for (hierarchy.items) |item| {
                    try rows.append(allocator, .{ .kind = .loop, .index = item.index, .top = top, .project_path = summary.project.path, .depth = item.depth });
                    top += 24;
                }
                top += 38;
            }
        } else if (model.graph) |graph| {
            try rows.append(allocator, .{ .kind = .open_project, .index = 0, .top = top, .project_path = graph.project.path });
            top += 24;
            var hierarchy = try hierarchyItems(allocator, graph.nodes.items, graph.edges.items);
            defer hierarchy.deinit(allocator);
            for (hierarchy.items) |item| {
                try rows.append(allocator, .{ .kind = .loop, .index = item.index, .top = top, .project_path = graph.project.path, .depth = item.depth });
                top += 24;
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
    top = layoutFor(model, inspection).quickChatRowTop(0) - scroll_offset;
    try rows.append(allocator, .{ .kind = .quick_chat_overview, .index = 0, .top = top });
    top += 24;
    for (model.quick_chats.items, 0..) |_, index| {
        try rows.append(allocator, .{ .kind = .quick_chat, .index = index, .top = top });
        top += 24;
    }
    return rows;
}

pub fn layoutFor(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) Layout {
    var loop_count: usize = 0;
    var graph_section_height: i32 = 0;
    if (model.graphs.items.len != 0) {
        graph_section_height = 62;
        for (model.graphs.items) |summary| {
            loop_count += summary.nodes.items.len;
            graph_section_height += 62 + @as(i32, @intCast(summary.nodes.items.len * 24));
        }
    } else if (model.graph) |graph| {
        loop_count = graph.nodes.items.len;
        graph_section_height = 124 + @as(i32, @intCast(graph.nodes.items.len * 24));
    }

    return .{
        .base = Tokens.header_height + 78,
        .project_count = model.recent_projects.items.len,
        .project_heading_count = projectHeadingCount(model),
        .loop_count = loop_count,
        .worktree_count = if (inspection) |value| value.entries.items.len else 0,
        .quick_chat_count = model.quick_chats.items.len,
        .graph_present = model.graphs.items.len != 0 or model.graph != null,
        .inspection_present = inspection != null,
        .graph_section_height = graph_section_height,
    };
}

pub fn sharedGraphTop(model: *const GraphModel.Model, graph_index: usize) i32 {
    var top = Tokens.header_height + 78 +
        @as(i32, @intCast((model.recent_projects.items.len + projectHeadingCount(model)) * 24)) + 36;
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
        @as(i32, @intCast((model.recent_projects.items.len + projectHeadingCount(model)) * 24)) + 36;
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
) ?Row {
    if (x < 0 or x >= Tokens.sidebar_width or y < Tokens.header_height or y >= viewport_bottom) return null;
    var rows = appendRows(std.heap.page_allocator, model, inspection, scroll_offset) catch return null;
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
    for (model.recent_projects.items) |project| if (!project.isRemote()) return true;
    return false;
}

fn hasRemoteProjects(model: *const GraphModel.Model) bool {
    for (model.recent_projects.items) |project| if (project.isRemote()) return true;
    return false;
}

fn projectHeadingCount(model: *const GraphModel.Model) usize {
    return @as(usize, @intFromBool(hasLocalProjects(model))) +
        @as(usize, @intFromBool(hasRemoteProjects(model)));
}

fn hierarchyItems(
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
) !std.ArrayList(HierarchyItem) {
    var result: std.ArrayList(HierarchyItem) = .empty;
    errdefer result.deinit(allocator);
    const visited = try allocator.alloc(bool, nodes.len);
    defer allocator.free(visited);
    @memset(visited, false);
    for (nodes, 0..) |node, index| {
        var incoming = false;
        for (edges) |edge| {
            if (std.mem.eql(u8, edge.kind, "handoff") and std.mem.eql(u8, edge.to, node.id)) {
                incoming = true;
                break;
            }
        }
        if (!incoming) try appendHierarchy(allocator, &result, visited, nodes, edges, index, 0);
    }
    for (nodes, 0..) |_, index| {
        if (!visited[index]) try appendHierarchy(allocator, &result, visited, nodes, edges, index, 0);
    }
    return result;
}

fn appendHierarchy(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(HierarchyItem),
    visited: []bool,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    index: usize,
    depth: usize,
) !void {
    if (index >= nodes.len or visited[index]) return;
    visited[index] = true;
    try result.append(allocator, .{ .index = index, .depth = depth });
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.kind, "handoff") or !std.mem.eql(u8, edge.from, nodes[index].id)) continue;
        const child = GraphModel.findNodeIndexByID(nodes, edge.to) orelse continue;
        try appendHierarchy(allocator, result, visited, nodes, edges, child, depth + 1);
    }
}

fn hierarchyPosition(
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    node_index: usize,
) !usize {
    var hierarchy = try hierarchyItems(allocator, nodes, edges);
    defer hierarchy.deinit(allocator);
    for (hierarchy.items, 0..) |item, position| if (item.index == node_index) return position;
    return node_index;
}

pub fn worktreeSectionBottom(project_count: usize, worktree_count: usize) i32 {
    return worktreeRowTop(project_count, 0, worktree_count) + 10;
}

pub fn contentBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) i32 {
    const section = sidebarSectionBottom(model, inspection);
    return if (model.attentionCount() == 0) section else section + 30 +
        @as(i32, @intCast(@min(model.attentionCount(), 4))) * 34;
}

pub fn sidebarSectionBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) i32 {
    const layout = layoutFor(model, inspection);
    return layout.quickChatRowTop(model.quick_chats.items.len + 1);
}

pub fn maxScroll(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection, viewport_bottom: i32) i32 {
    return @max(contentBottom(model, inspection) - viewport_bottom, 0);
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
        @as(i32, @intCast(model.recent_projects.items.len * 24)) - scroll_offset;
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
        const row = rowAt(24, layout.loopTop(index) - 11, &model, null, 11, 700) orelse return error.TestUnexpectedResult;
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
    const local_row = rowAt(24, local_top + 4, &model, null, 0, 700) orelse return error.TestUnexpectedResult;
    const remote_row = rowAt(24, remote_top + 4, &model, null, 0, 700) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("C:\\work\\local", local_row.project_path.?);
    try std.testing.expectEqualStrings("ssh://build/remote", remote_row.project_path.?);
    try std.testing.expectEqual(
        layoutFor(&model, null).quickChatRowTop(model.quick_chats.items.len + 1),
        sidebarSectionBottom(&model, null),
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
    var rows = try appendRows(allocator, &model, &inspection, scroll);
    defer rows.deinit(allocator);
    for (rows.items) |row| {
        const hit = rowAt(24, row.top + 4, &model, &inspection, scroll, 700) orelse
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
    const short_max = maxScroll(&model, &inspection, 400);
    const expected_short = sidebarSectionBottom(&model, &inspection) + 30 + 4 * 34 - 400;
    try std.testing.expectEqual(expected_short, short_max);
    const activity_only_max = maxScroll(&model, &inspection, 400);
    try std.testing.expectEqual(short_max, activity_only_max);
    var scroll: i32 = 0;
    for (0..10) |_| scroll = clampScroll(scroll + 40, short_max);
    try std.testing.expectEqual(short_max, scroll);
    while (model.activity.items.len > 1) {
        const event = model.activity.pop() orelse break;
        std.testing.allocator.free(event.title);
        std.testing.allocator.free(event.state);
    }
    try std.testing.expectEqual(short_max, maxScroll(&model, &inspection, 400));
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
    const reduced_max = maxScroll(&model, &inspection, 500);
    const expected_reduced = @max(sidebarSectionBottom(&model, &inspection) + 30 + 1 * 34 - 500, 0);
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
    const no_graph_max = maxScroll(&model, null, 100);
    try std.testing.expectEqual(@as(i32, Tokens.header_height + 78 + 24 + 24 + 42 + 24 - 100), no_graph_max);
    try std.testing.expectEqual(no_graph_max, clampScroll(180, no_graph_max));
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
    var rows = try appendRows(std.testing.allocator, &model, null, 0);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), rows.items[1].index);
    try std.testing.expectEqual(RowKind.remote_heading, rows.items[2].kind);
    try std.testing.expectEqual(@as(usize, 0), rows.items[3].index);
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
    var hierarchy = try hierarchyItems(std.testing.allocator, &nodes, &edges);
    defer hierarchy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.items[0].index);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.items[0].depth);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.items[1].index);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.items[1].depth);
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
    const overview = rowAt(24, layout.quickChatRowTop(0) + 4, &model, null, 0, 700) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat_overview, overview.kind);
    const row = rowAt(24, layout.quickChatRowTop(1) + 4, &model, null, 0, 700) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat, row.kind);
    try std.testing.expectEqual(@as(usize, 0), row.index);
    try std.testing.expectEqual(
        @as(i32, Tokens.header_height + 78 + 42),
        layout.quickChatRowTop(0),
    );
    try std.testing.expect(rowAt(24, layout.quickChatHeadingTop() + 4, &model, null, 0, 700) == null);
    try std.testing.expectEqual(layout.quickChatRowTop(2), sidebarSectionBottom(&model, null));
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

test "update banner is a bounded footer action" {
    const bounds = updateBannerRect(700, false);
    try std.testing.expect(updateBannerAt(bounds.left, bounds.top, 700, true, false));
    try std.testing.expect(updateBannerAt(bounds.right - 1, bounds.bottom - 1, 700, true, false));
    try std.testing.expect(!updateBannerAt(bounds.right, bounds.bottom - 1, 700, true, false));
    try std.testing.expect(!updateBannerAt(bounds.left, bounds.top, 700, false, false));
    try std.testing.expect(updateBannerRect(700, true).bottom < errorFooterRect(700).top);
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
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = rect(x, y, 1200, y + size + 8);
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
}
