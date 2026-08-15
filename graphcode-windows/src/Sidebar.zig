const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const Tokens = @import("DesignTokens.zig");
const c = @import("Win32.zig").c;

pub fn draw(
    hdc: c.HDC,
    model: *const GraphModel.Model,
    status: []const u8,
    allocator: std.mem.Allocator,
) void {
    const sidebar = rect(0, Tokens.header_height, Tokens.sidebar_width, 1200);
    fill(hdc, sidebar, Tokens.workspace_rail);
    drawText(hdc, allocator, "GRAPH", 18, Tokens.header_height + 20, 16, 0x00FFFFFF);
    drawText(hdc, allocator, "Projects", 18, Tokens.header_height + 54, 14, 0x00B8B8B8);
    var y: i32 = Tokens.header_height + 78;
    for (model.recent_projects.items) |project| {
        drawText(hdc, allocator, project.name, 24, y, 13, 0x00E6E6E6);
        y += 24;
    }
    if (model.graph) |graph| {
        drawText(hdc, allocator, "Open", 18, y + 10, 14, 0x00B8B8B8);
        drawText(hdc, allocator, graph.project.name, 24, y + 36, 13, 0x00FFFFFF);
        y += 62;
    }
    drawText(hdc, allocator, status, 18, 700, 11, 0x00909090);
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
