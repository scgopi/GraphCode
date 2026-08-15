const std = @import("std");
const GraphModel = @import("GraphModel.zig");
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
    try rows.append(.{ .kind = .quick_chats, .title = "Quick Chats", .path = "" });

    var has_local = false;
    var has_remote = false;
    for (model.recent_projects.items) |project| {
        if (project.isRemote()) has_remote = true else has_local = true;
    }
    if (model.graph) |graph| {
        if (graph.project.isRemote()) has_remote = true else has_local = true;
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
        if (project.isRemote() != remote) continue;
        try appendProject(rows, model, project);
    }
    if (model.graph) |graph| {
        if (graph.project.isRemote() == remote and !containsProject(model.recent_projects.items, graph.project.path)) {
            try appendProject(rows, model, graph.project);
        }
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

pub fn draw(
    hdc: c.HDC,
    model: *const GraphModel.Model,
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
    }
    drawText(hdc, allocator, status, 18, @max(Tokens.header_height, client_bottom - 22), 11, 0x00909090);
}

fn icon(kind: RowKind) []const u8 {
    return switch (kind) {
        .overview => "◉",
        .quick_chats => "••",
        .local_section, .remote_section => "",
        .project => "▰",
        .loop => "·",
    };
}

test "sidebar rows include overview, chats, and daemon projects with loop children" {
    const allocator = std.testing.allocator;
    const frame = try std.fs.cwd().readFileAlloc(allocator, "fixtures/sidebar-recent-projects.json", 64 * 1024);
    defer allocator.free(frame);
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(frame);
    const graph_frame =
        \\{"version":2,"kind":"event","sequence":5,"event":{"graphChanged":{"id":"graph","project":{"path":"C:\\work\\local","name":"Local Graph"},"nodes":[{"id":"node-a","title":"Loop A","loopType":"turnBased","state":"running","activity":"","presence":{"presence":"busy"}}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(graph_frame);
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
    }
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
