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

    }
    drawText(hdc, allocator, status, 18, 700, 11, 0x00909090);
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
    if (model.graph == null or y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 24));
    if (index >= model.graph.?.nodes.items.len) return null;
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
