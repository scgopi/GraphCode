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
    allocator: std.mem.Allocator,
) void {
    const sidebar = rect(0, Tokens.header_height, Tokens.sidebar_width, 1200);
    fill(hdc, sidebar, Tokens.workspace_rail);
    drawText(hdc, allocator, "GRAPH", 18, Tokens.header_height + 20, 16, 0x00FFFFFF);
    drawText(hdc, allocator, "Projects", 18, Tokens.header_height + 54, 14, 0x00B8B8B8);
    var y: i32 = Tokens.header_height + 78 - scroll_offset;
    for (model.recent_projects.items) |project| {
        drawText(hdc, allocator, project.name, 24, y, 13, 0x00E6E6E6);
        y += 24;
    }
    if (model.graphs.items.len != 0) {
        drawText(hdc, allocator, "Open", 18, y + 10, 14, 0x00B8B8B8);
        for (model.graphs.items, 0..) |summary, graph_index| {
            const project_top = sharedGraphTop(model, graph_index);
            const selected = if (model.selected_project_path) |path|
                std.mem.eql(u8, path, summary.project.path)
            else false;
            drawText(hdc, allocator, summary.project.name, 24, project_top, 13,
                if (selected) 0x00FFFFFF else 0x00D0D0D0);
            for (summary.nodes.items, 0..) |node, node_index| {
                drawText(
                    hdc,
                    allocator,
                    node.title,
                    36,
                    sharedLoopTop(model, graph_index, node_index),
                    11,
                    0x00E6E6E6,
                );
            }
        }
        if (inspection) |value| {
            drawText(hdc, allocator, "Worktrees", 18, sharedWorktreeTop(model, 0) - 14, 11, 0x007A7A7A);
            for (value.entries.items, 0..) |entry, index| {
                drawText(hdc, allocator, entry.path, 24, sharedWorktreeTop(model, index), 11, 0x00E6E6E6);
            }
        }
    } else if (model.graph) |graph| {
        drawText(hdc, allocator, "Open", 18, y + 10, 14, 0x00B8B8B8);
        drawText(hdc, allocator, graph.project.name, 24, y + 36, 13, 0x00FFFFFF);
        y += 62;
        drawText(hdc, allocator, "Loops", 18, y + 10, 11, 0x007A7A7A);
        for (graph.nodes.items, 0..) |node, index| {
            const row_y = layoutFor(model, inspection).loopTop(index) - scroll_offset;
            drawText(hdc, allocator, node.title, 24, row_y, 11, 0x00E6E6E6);
        }
        y += @as(i32, @intCast(graph.nodes.items.len * 24));
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
            const row_y = layoutFor(model, inspection).worktreeTop(index) - scroll_offset;
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

    }
    drawText(hdc, allocator, status, 18, 700, 11, 0x00909090);
}

pub fn loopRowTop(project_count: usize, index: usize) i32 {
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = 0, .worktree_count = 0 };
    return layout.loopTop(index);
}

pub fn worktreeRowTop(project_count: usize, loop_count: usize, index: usize) i32 {
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = loop_count, .worktree_count = 0 };
    return layout.worktreeTop(index);
}

pub const RowKind = enum { project, overview, loop, worktree };
pub const Row = struct {
    kind: RowKind,
    index: usize,
    top: i32,
    project_path: ?[]const u8 = null,
};
pub const Layout = struct {
    base: i32,
    project_count: usize,
    loop_count: usize,
    worktree_count: usize,

    pub fn projectTop(self: Layout, index: usize) i32 {
        return self.base + @as(i32, @intCast(index * 24));
    }
    pub fn overviewTop(self: Layout) i32 {
        return self.base + @as(i32, @intCast(self.project_count * 24)) + 24;
    }
    pub fn loopTop(self: Layout, index: usize) i32 {
        return self.base + @as(i32, @intCast(self.project_count * 24)) + 86 +
            @as(i32, @intCast(index * 24));
    }
    pub fn worktreeTop(self: Layout, index: usize) i32 {
        return self.base + @as(i32, @intCast(self.project_count * 24)) + 140 +
            @as(i32, @intCast(self.loop_count * 24)) +
            @as(i32, @intCast(index * 34));
    }
};

pub fn layoutFor(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) Layout {
    var loop_count: usize = 0;
    if (model.graphs.items.len != 0) {
        for (model.graphs.items) |summary| loop_count += summary.nodes.items.len;
    } else if (model.graph) |graph| {
        loop_count = graph.nodes.items.len;
    }

    return .{
        .base = Tokens.header_height + 78,
        .project_count = model.recent_projects.items.len,
        .loop_count = loop_count,
        .worktree_count = if (inspection) |value| value.entries.items.len else 0,
    };
}

pub fn sharedGraphTop(model: *const GraphModel.Model, graph_index: usize) i32 {
    var top = Tokens.header_height + 78 +
        @as(i32, @intCast(model.recent_projects.items.len * 24)) + 36;
    for (model.graphs.items[0..@min(graph_index, model.graphs.items.len)]) |summary| {
        top += 62 + @as(i32, @intCast(summary.nodes.items.len * 24));
    }
    return top;
}

pub fn sharedLoopTop(model: *const GraphModel.Model, graph_index: usize, node_index: usize) i32 {
    return sharedGraphTop(model, graph_index) + 48 + @as(i32, @intCast(node_index * 24));
}

pub fn sharedWorktreeTop(model: *const GraphModel.Model, index: usize) i32 {
    var top = Tokens.header_height + 78 +
        @as(i32, @intCast(model.recent_projects.items.len * 24)) + 36;
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
    const layout = layoutFor(model, inspection);
    const project_top = layout.projectTop(0) - scroll_offset;
    if (y >= project_top and y < project_top + @as(i32, @intCast(model.recent_projects.items.len * 24))) {
        const index: usize = @intCast(@divTrunc(y - project_top, 24));
        return .{
            .kind = .project,
            .index = index,
            .top = project_top,
            .project_path = model.recent_projects.items[index].path,
        };
    }
    if (model.graph != null or model.graphs.items.len != 0) {
        const overview_top = layout.overviewTop() - scroll_offset;
        if (y >= overview_top and y < overview_top + 38) {
            return .{ .kind = .overview, .index = 0, .top = overview_top };
        }
        var loop_index: usize = 0;
        for (model.graphs.items, 0..) |summary, graph_index| {
            for (summary.nodes.items, 0..) |_, node_index| {
                const loop_top = sharedLoopTop(model, graph_index, node_index) - scroll_offset;
                if (y >= loop_top and y < loop_top + 24) {
                    return .{
                        .kind = .loop,
                        .index = loop_index,
                        .top = loop_top,
                        .project_path = summary.project.path,
                    };
                }
                loop_index += 1;
            }
        }
        if (model.graphs.items.len == 0) {
            const loop_top = layout.loopTop(0) - scroll_offset;
            if (y >= loop_top and y < loop_top + @as(i32, @intCast(layout.loop_count * 24))) {
                return .{ .kind = .loop, .index = @intCast(@divTrunc(y - loop_top, 24)), .top = loop_top };
            }
        }
    }
    if (inspection) |value| {
        const worktree_base = if (model.graphs.items.len == 0)
            layout.worktreeTop(0)
        else
            sharedWorktreeTop(model, 0);
        const worktree_top = worktree_base - scroll_offset;
        if (y >= worktree_top and y < worktree_top + @as(i32, @intCast(value.entries.items.len * 34))) {
            return .{ .kind = .worktree, .index = @intCast(@divTrunc(y - worktree_top, 34)), .top = worktree_top };
        }
    }
    return null;
}

pub fn worktreeSectionBottom(project_count: usize, worktree_count: usize) i32 {
    return worktreeRowTop(project_count, 0, worktree_count) + 10;
}

pub fn contentBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) i32 {
    const section = sidebarSectionBottom(model, inspection);
    return if (model.attentionCount() == 0) section else section + 30 +
        @as(i32, @intCast(@min(model.attentionCount(), 4))) * 19;
}

pub fn sidebarSectionBottom(model: *const GraphModel.Model, inspection: ?*const WorktreeStatus.Inspection) i32 {
    var bottom = Tokens.header_height + 78 +
        @as(i32, @intCast(model.recent_projects.items.len * 24));
    if (model.graphs.items.len != 0) {
        bottom = sharedWorktreeTop(model, 0);
        if (inspection) |value| bottom += 24 + @as(i32, @intCast(value.entries.items.len * 34)) + 10;
    } else if (model.graph != null) {
        bottom += 62 + 54 + @as(i32, @intCast(model.graph.?.nodes.items.len * 24));
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
    try std.testing.expectEqual(sharedWorktreeTop(&model, 0), sidebarSectionBottom(&model, null));
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
