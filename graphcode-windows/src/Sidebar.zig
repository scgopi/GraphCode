const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const Tokens = @import("DesignTokens.zig");
const c = @import("Win32.zig").c;

pub const RowKind = enum {
    overview,
    quick_chats,
    local_section,
    remote_section,
    project,
    loop,
};

pub const Row = struct {
    kind: RowKind,
    title: []const u8,
    path: []const u8,
    node_index: ?usize = null,
    depth: u8 = 0,
    bounds: c.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub fn viewportBottom(client_bottom: i32) i32 {
    return @max(Tokens.header_height + 1, client_bottom - 24);
}

pub fn buildRows(
    model: *const GraphModel.Model,
    allocator: std.mem.Allocator,
    height: i32,
) !std.array_list.Managed(Row) {
    var rows = std.array_list.Managed(Row).init(allocator);
    errdefer rows.deinit();
    try rows.append(.{ .kind = .overview, .title = "Graph Overview", .path = "" });
    try appendGlobalLoops(&rows, model);
    try rows.append(.{ .kind = .quick_chats, .title = "Quick Chats", .path = "" });

    var has_local = false;
    var has_remote = false;
    for (model.recent_projects.items) |project| {
        if (project.isGlobal()) continue;
        if (project.isRemote()) has_remote = true else has_local = true;
    }
    if (model.graph) |graph| {
        if (!graph.project.isGlobal()) {
            if (graph.project.isRemote()) has_remote = true else has_local = true;
        }
    }
    if (has_local) try rows.append(.{ .kind = .local_section, .title = "Local Projects", .path = "" });
    try appendProjects(&rows, model, false);
    if (has_remote) try rows.append(.{ .kind = .remote_section, .title = "Remote Repositories", .path = "" });
    try appendProjects(&rows, model, true);
    _ = height;
    return rows;
}

fn appendProjects(rows: *std.array_list.Managed(Row), model: *const GraphModel.Model, remote: bool) !void {
    for (model.recent_projects.items) |project| {
        if (project.isGlobal()) continue;
        if (project.isRemote() != remote) continue;
        try appendProject(rows, model, project);
    }
    if (model.graph) |graph| {
        if (graph.project.isGlobal()) return;
        if (graph.project.isRemote() == remote and !containsProject(model.recent_projects.items, graph.project.path)) {
            try appendProject(rows, model, graph.project);
        }
    }
}

fn appendGlobalLoops(rows: *std.array_list.Managed(Row), model: *const GraphModel.Model) !void {
    const graph = model.graph orelse return;
    if (!graph.project.isGlobal()) return;
    for (graph.nodes.items, 0..) |node, index| {
        try rows.append(.{
            .kind = .loop,
            .title = node.title,
            .path = graph.project.path,
            .node_index = index,
            .depth = 1,
        });
    }
}

fn appendProject(rows: *std.array_list.Managed(Row), model: *const GraphModel.Model, project: GraphModel.Project) !void {
    try rows.append(.{ .kind = .project, .title = project.name, .path = project.path });
    if (model.graph) |graph| {
        if (!std.mem.eql(u8, graph.project.path, project.path)) return;
        for (graph.nodes.items, 0..) |node, index| {
            try rows.append(.{
                .kind = .loop,
                .title = node.title,
                .path = graph.project.path,
                .node_index = index,
                .depth = 1,
            });
        }
    }
}

fn containsProject(projects: []const GraphModel.Project, path: []const u8) bool {
    for (projects) |project| if (std.mem.eql(u8, project.path, path)) return true;
    return false;
}

pub fn layoutRows(rows: []Row, top: i32, bottom: i32, scroll_offset: i32) i32 {
    var content_y = top;
    for (rows) |*row| {
        const row_height: i32 = if (row.kind == .local_section or row.kind == .remote_section) 30 else 28;
        const y = content_y - scroll_offset;
        row.bounds = if (y < bottom and y + row_height > top)
            rect(0, @max(top, y), Tokens.sidebar_width, @min(bottom, y + row_height))
        else
            rect(0, 0, 0, 0);
        content_y += row_height;
    }
    return content_y;
}

pub fn hitTest(rows: []const Row, x: i32, y: i32) ?Row {
    if (x < 0 or x >= Tokens.sidebar_width) return null;
    for (rows) |row| {
        if (row.bounds.right > row.bounds.left and y >= row.bounds.top and y < row.bounds.bottom) return row;
    }
    return null;
}

pub fn isVisible(row: Row) bool {
    return row.bounds.right > row.bounds.left and row.bounds.bottom > row.bounds.top;
}

pub fn draw(
    hdc: c.HDC,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    selected_worktree_path: []const u8,
    scroll_offset: i32,
    status: []const u8,
    allocator: std.mem.Allocator,
    client_bottom: i32,
    scroll_offset: i32,
) void {
    var rows = buildRows(model, allocator, 1200) catch return;
    defer rows.deinit();
    _ = layoutRows(rows.items, Tokens.header_height, viewportBottom(client_bottom), scroll_offset);
    const sidebar = rect(0, Tokens.header_height, Tokens.sidebar_width, client_bottom);
    fill(hdc, sidebar, Tokens.workspace_rail);
    for (rows.items) |row| {
        if (!isVisible(row)) continue;
        const x: i32 = if (row.kind == .loop) 34 else 18;
        const color: u32 = switch (row.kind) {
            .local_section, .remote_section => 0x00909090,
            .overview, .quick_chats => 0x00FFFFFF,
            .project, .loop => 0x00E6E6E6,
        };
        const size: i32 = if (row.kind == .local_section or row.kind == .remote_section) 11 else 13;
        if (icon(row.kind).len != 0) {
            drawText(hdc, allocator, icon(row.kind), 8, row.bounds.top + 7, size, color);
        }
        drawText(hdc, allocator, row.title, x, row.bounds.top + 7, size, color);
    drawText(hdc, allocator, "GRAPH", 18, Tokens.header_height + 20, 16, 0x00FFFFFF);
    drawText(hdc, allocator, "Projects", 18, Tokens.header_height + 54, 14, 0x00B8B8B8);
    var y: i32 = Tokens.header_height + 78 - scroll_offset;
    for (model.recent_projects.items) |project| {
        drawText(hdc, allocator, project.name, 24, y, 13, 0x00E6E6E6);
        y += 24;
    }
    if (model.graph) |graph| {
        drawText(hdc, allocator, "Open", 18, y + 10, 14, 0x00B8B8B8);
        drawText(hdc, allocator, graph.project.name, 24, y + 36, 13, 0x00FFFFFF);
        y += 62;
        drawText(hdc, allocator, "Worktrees", 18, y + 10, 11, 0x007A7A7A);
        drawText(
            hdc,
            allocator,
            "Inspect live repository hygiene",
            24,
            y + 30,
            11,
            0x00B8B8B8,
        );
        y += 54;
        if (inspection) |value| {
            drawText(hdc, allocator, "Live rows", 18, y + 10, 11, 0x007A7A7A);
            y += 24;
        for (value.entries.items, 0..) |entry, index| {
                const selected = std.mem.eql(u8, entry.path, selected_worktree_path);
            const row_y = worktreeRowTop(model.recent_projects.items.len, index) - scroll_offset;
            if (selected and WorktreeStatus.decision(entry) == .reclaimable)
                fill(hdc, rect(12, row_y - 3, Tokens.sidebar_width - 12, row_y + 25), 0x003A3A44);
            drawText(hdc, allocator, entry.path, 24, row_y, 11, 0x00E6E6E6);
            drawText(hdc, allocator, reason(entry), 24, row_y + 14, 10,
                if (WorktreeStatus.decision(entry) == .reclaimable) 0x0078D7A8 else 0x00FFCD7A);
        }
        }
    }

    const section_y = sidebarSectionBottom(model, inspection) - scroll_offset;
    if (model.attentionCount() != 0) {
        drawText(hdc, allocator, "Needs you", 18, section_y + 10, 11, 0x00FFCD7A);
        var attention_y = section_y + 30;
        for (model.attention.items[0..@min(model.attention.items.len, 4)]) |node| {
            drawText(hdc, allocator, node.title, 24, attention_y, 11, 0x00E6E6E6);
            attention_y += 19;
        }

>>>>>>> 6540896 (Add     }
    var rows = try buildRows(&model, allocator, 800);
    defer rows.deinit();
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.quick_chats, rows.items[1].kind);
    try std.testing.expectEqual(RowKind.local_section, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[3].kind);
    try std.testing.expectEqual(RowKind.loop, rows.items[4].kind);
    try std.testing.expectEqual(RowKind.remote_section, rows.items[5].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[6].kind);
    try std.testing.expectEqualStrings("Local Graph", rows.items[3].title);
    try std.testing.expectEqualStrings("Loop A", rows.items[4].title);
}

test "sidebar layout clips and hit-tests many projects in a short viewport" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    for (0..12) |index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "C:\\work\\project-{d}", .{index});
        const name = try std.fmt.allocPrint(std.testing.allocator, "Project {d}", .{index});
        try model.recent_projects.append(.{ .path = path, .name = name });
    var rows = try buildRows(&model, std.testing.allocator, 120);
    defer rows.deinit();
    const viewport_bottom = viewportBottom(120);
    const content_height = layoutRows(rows.items, Tokens.header_height, viewport_bottom, 0);
    try std.testing.expect(content_height > viewport_bottom);
    try std.testing.expect(hitTest(rows.items, 20, viewport_bottom) == null);
    const max_scroll = content_height - viewport_bottom;
    _ = layoutRows(rows.items, Tokens.header_height, viewport_bottom, max_scroll);
    const last = hitTest(rows.items, 20, 90) orelse return error.ExpectedVisibleRow;
    try std.testing.expectEqual(RowKind.project, last.kind);
    try std.testing.expectEqualStrings("Project 11", last.title);
}

test "global graph is overview-owned and excluded from project sections" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "graphcode://global"),
        .name = try std.testing.allocator.dupe(u8, "Graph"),
    });
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\work\\local"),
        .name = try std.testing.allocator.dupe(u8, "Local"),
    });
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"global","project":{"path":"graphcode://global","name":"Graph"},"nodes":[{"id":"global-node","title":"Global Loop","loopType":"turnBased","state":"idle"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    var rows = try buildRows(&model, std.testing.allocator, 800);
    defer rows.deinit();
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.loop, rows.items[1].kind);
    try std.testing.expectEqualStrings("Global Loop", rows.items[1].title);
    try std.testing.expectEqual(RowKind.quick_chats, rows.items[2].kind);
    for (rows.items) |row| {
        try std.testing.expect(!(row.kind == .project and std.mem.eql(u8, row.path, "graphcode://global")));
    }
}

test "scrolled-off rows produce no paint command" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\work\\local"),
        .name = try std.testing.allocator.dupe(u8, "Local"),
    });
    var rows = try buildRows(&model, std.testing.allocator, 120);
    defer rows.deinit();
    _ = layoutRows(rows.items, Tokens.header_height, viewportBottom(120), 500);
    try std.testing.expect(!isVisible(rows.items[0]));
    try std.testing.expect(hitTest(rows.items, 20, 7) == null);
}

pub fn worktreeRowTop(project_count: usize, index: usize) i32 {
    return Tokens.header_height + 78 + @as(i32, @intCast(project_count * 24)) + 62 + 54 + 24 +
        @as(i32, @intCast(index * 34));
}

pub fn worktreeSectionBottom(project_count: usize, worktree_count: usize) i32 {
    return worktreeRowTop(project_count, worktree_count) + 10;
}

pub fn contentBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) i32 {
    const section = sidebarSectionBottom(model, inspection);
    return if (model.attentionCount() == 0) section else section + 30 +
        @as(i32, @intCast(@min(model.attentionCount(), 4))) * 19;
}

pub fn sidebarSectionBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) i32 {
    var bottom = Tokens.header_height + 78 +
        @as(i32, @intCast(model.recent_projects.items.len * 24));
    if (model.graph != null) {
        bottom += 62 + 54;
        if (inspection) |value| bottom += 24 + @as(i32, @intCast(value.entries.items.len * 34)) + 10;
    }
    return bottom;
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
    const top = worktreeRowTop(project_count, 0) - scroll_offset;
    if (y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 34));
    if (index >= count) return null;
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
    const top = worktreeRowTop(2, 0);
    try std.testing.expectEqual(@as(?usize, 0), hitTestWorktree(24, top + 4, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(?usize, 1), hitTestWorktree(24, top + 34 + 4, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(?usize, null), hitTestWorktree(Tokens.sidebar_width + 1, top, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(?usize, null), hitTestWorktree(24, top + 68, 2, 2, 0, 700));
    try std.testing.expectEqual(@as(i32, worktreeRowTop(3, 0) - worktreeRowTop(1, 0)), 48);
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
    const expected_short = Tokens.header_height + 78 + 72 + 62 + 54 + 24 + 170 + 10 + 30 + 4 * 19 - 400;
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
    const expected_reduced = @max(Tokens.header_height + 78 + 24 + 62 + 54 + 24 + 68 + 10 + 30 + 1 * 19 - 500, 0);
    try std.testing.expectEqual(expected_reduced, reduced_max);
    scroll = clampScroll(scroll, reduced_max);
    try std.testing.expectEqual(@as(i32, 0), scroll);
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
    try std.testing.expectEqual(@as(i32, Tokens.header_height + 78 + 24 - 100), no_graph_max);
    try std.testing.expectEqual(no_graph_max, clampScroll(80, no_graph_max));
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
