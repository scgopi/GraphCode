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

    pub fn rowHeight(row: Row) i32 {
        const bounds = rowBounds(row);
        return bounds.bottom - bounds.top;
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
    surface: Surface,
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
    const footer = effectiveFooter(viewport_bottom, update_version.len != 0, ingress_error.len != 0);
    const has_update = footer.update;
    const has_error = footer.ingress;
    const saved_clip = c.SaveDC(hdc);
    _ = c.IntersectClipRect(
        hdc,
        0,
        content_top,
        Tokens.sidebar_width,
        contentViewportBottom(viewport_bottom, has_update, has_error),
    );
    var rows = appendRows(allocator, model, inspection, scroll_offset, state) catch {
        if (saved_clip != 0) _ = c.RestoreDC(hdc, saved_clip);
        return;
    };
    defer rows.deinit(allocator);
    for (rows.items) |row| {
        const bounds = rowBounds(row);
        switch (row.kind) {
            .local_heading => {
                drawStyledTextRect(hdc, allocator, row.project_name orelse "Local Projects", rect(18, row.top, 198, row.top + 20), 11, .semibold, 0x00909090, loop_text_format);
                if (hover_y >= bounds.top and hover_y < bounds.bottom)
                    drawDisclosureIcon(hdc, rect(198, row.top, 220, row.top + 20), state.local_collapsed, 0x00909090);
            },
            .remote_heading => {
                drawStyledTextRect(hdc, allocator, row.project_name orelse "Remote Repositories", rect(18, row.top, 198, row.top + 20), 11, .semibold, 0x00909090, loop_text_format);
                if (hover_y >= bounds.top and hover_y < bounds.bottom)
                    drawDisclosureIcon(hdc, rect(198, row.top, 220, row.top + 20), state.remote_collapsed, 0x00909090);
            },
            .project => {
                const project = model.recent_projects.items[row.index];
                drawText(hdc, allocator, if (project.isRemote()) "R" else "L", 18, row.top + 1, 9, 0x007A7A7A);
                drawText(hdc, allocator, project.name, 34, row.top, 13, 0x00E6E6E6);
            },
            .overview => {
                if (navigationRowSelected(row, surface, model.selected_project_path))
                    fill(hdc, bounds, 0x003A3A44);
                drawOutlineIcon(hdc, .graph, rect(18, row.top + 8, 34, row.top + 24), 0x00E6E6E6);
                drawTextRect(hdc, allocator, "Graph", rect(44, row.top + 5, 172, row.top + 27), 13, 0x00E6E6E6, loop_text_format);
                if (hover_y >= bounds.top and hover_y < bounds.bottom and row.has_graph) {
                    drawPlusIcon(hdc, newLoopBounds(row), 0x00B8B8B8);
                    if (row.has_children) drawDisclosureIcon(hdc, disclosureBounds(row), state.isProjectCollapsed(global_project_path), 0x00B8B8B8);
                }
            },
            .open_project => if (row.project_path) |path| {
                const selected = navigationRowSelected(row, surface, model.selected_project_path);
                if (selected) fill(hdc, bounds, 0x003A3A44);
                const graph = graphForProject(model, path);
                const remote = if (graph) |value| value.project().isRemote() else std.mem.startsWith(u8, path, "ssh://") or std.mem.startsWith(u8, path, "codespace://");
                drawOutlineIcon(hdc, if (remote) .remote_folder else .local_folder, rect(18, row.top + 8, 34, row.top + 24), 0x00E6E6E6);
                drawTextRect(
                    hdc,
                    allocator,
                    row.project_name orelse path,
                    rect(44, row.top + 5, 172, row.top + 27),
                    13,
                    if (selected) 0x00FFFFFF else 0x00D0D0D0,
                    loop_text_format,
                );
                if (hover_y >= bounds.top and hover_y < bounds.bottom and row.has_graph) {
                    drawPlusIcon(hdc, newLoopBounds(row), 0x00B8B8B8);
                    if (row.has_children) drawDisclosureIcon(hdc, disclosureBounds(row), state.isProjectCollapsed(path), 0x00B8B8B8);
                }
            },
            .loop => if (row.project_path) |path| if (graphForProject(model, path)) |graph| {
                const nodes = graph.nodes();
                if (row.index < nodes.len) {
                    const node = nodes[row.index];
                    const indent = loopIndent(row.depth);
                    const elapsed = elapsedText(allocator, @intCast(node.created_at orelse 0), std.time.timestamp()) catch |err| blk: {
                        std.log.err("Sidebar elapsed label failed: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                    defer if (elapsed) |value| allocator.free(value);
                    const age_width = if (elapsed) |value| measuredAgeWidth(hdc, value) catch |err| blk: {
                        std.log.err("Sidebar age measurement failed: {s}", .{@errorName(err)});
                        break :blk loop_age_width;
                    } else loop_age_width;
                    const text = loopRowTextRectsForAgeWidth(row.top, row.depth, age_width);
                    // Deep trees elide the title, never the fixed age/state/control columns.
                    if (37 + indent <= text.age.left - loop_text_gap)
                        drawLoopStripe(hdc, rect(34 + indent, row.top + 3, 37 + indent, row.top + 17), loopAccent(node.loop_type));
                    drawStyledTextRect(hdc, allocator, node.title, text.title, 12.5, .regular, 0x00E6E6E6, loop_text_format);
                    drawStateIndicator(hdc, node.state, text.state);
                    if (elapsed) |value| drawStyledTextRect(hdc, allocator, value, text.age, 10.5, .card_mono, 0x00908E8E, loop_text_format | c.DT_RIGHT);
                    if (row.has_children)
                        drawDisclosureIcon(hdc, rect(198, row.top + 4, 220, row.top + 20), !state.isNodeExpanded(node.id), if (hover_y >= bounds.top and hover_y < bounds.bottom) 0x00B8B8B8 else 0x006A6A6A);
                }
            },
            .worktree => if (inspection) |value| {
                const entry = value.entries.items[row.index];
                const selected = std.mem.eql(u8, entry.path, selected_worktree_path);
                if (selected and WorktreeStatus.decision(entry) == .reclaimable)
                    fill(hdc, bounds, 0x003A3A44);
                drawText(hdc, allocator, entry.path, 24, row.top, 11, 0x00E6E6E6);
                const size = WorktreeStatus.sizeCoverageText(allocator, entry.sizeCoverage()) catch null;
                defer if (size) |value_text| allocator.free(value_text);
                const detail = if (size) |value_text|
                    std.fmt.allocPrint(allocator, "{s} · {s}", .{ reason(entry), if (!entry.size_complete and entry.size_error == null and entry.size_bytes == 0) "size pending" else value_text }) catch null
                else
                    null;
                defer if (detail) |value_text| allocator.free(value_text);
                drawText(hdc, allocator, detail orelse reason(entry), 24, row.top + 14, 10, if (WorktreeStatus.decision(entry) == .reclaimable) 0x0078D7A8 else 0x00FFCD7A);
            },
            .quick_chat_overview => {
                const selected = navigationRowSelected(row, surface, model.selected_project_path);
                if (selected) fill(hdc, bounds, 0x003A3A44);
                drawOutlineIcon(hdc, .chat, rect(18, row.top + 8, 34, row.top + 24), 0x00E6E6E6);
                drawTextRect(hdc, allocator, "Quick Chats", rect(44, row.top + 5, 172, row.top + 27), 13, if (selected) 0x00FFFFFF else 0x00E6E6E6, loop_text_format);
                if (hover_y >= bounds.top and hover_y < bounds.bottom) {
                    drawPlusIcon(hdc, newChatBounds(row), 0x00B8B8B8);
                    if (row.has_children) drawDisclosureIcon(hdc, chatsDisclosureBounds(row), state.chats_collapsed, 0x00B8B8B8);
                }
            },
            .quick_chat => if (row.index < model.quick_chats.items.len)
                drawTextRect(hdc, allocator, model.quick_chats.items[row.index].title, rect(34, row.top + 5, Tokens.sidebar_width - 12, row.top + 27), 13, 0x00E6E6E6, loop_text_format),
        }
    }

    const section_y = sidebarSectionBottom(model, inspection, state) - scroll_offset;
    if (model.attentionCount() != 0) {
        const label = needsYouLabelRect(sidebarSectionBottom(model, inspection, state), scroll_offset);
        drawText(hdc, allocator, "Needs you", label.left, label.top, 11, 0x00FFCD7A);
        var attention_y = section_y + 30;
        if (model.attention_entries.items.len != 0) {
            for (model.attention_entries.items[0..@min(model.attention_entries.items.len, 4)], 0..) |entry, index| {
                drawText(hdc, allocator, entry.node.title, 24, attention_y, 11, 0x00E6E6E6);
                drawText(hdc, allocator, attentionReason(entry.node), 24, attention_y + 15, 9, stateColor(entry.node.state));
                const stop_bounds = needsYouStopBounds(model, inspection, state, scroll_offset, index);
                fill(hdc, stop_bounds, 0x00353224);
                drawTextRect(hdc, allocator, "Stop", stop_bounds, 9, 0x00FFCD7A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
                attention_y += 34;
            }
        } else {
            for (model.attention.items[0..@min(model.attention.items.len, 4)], 0..) |node, index| {
                drawText(hdc, allocator, node.title, 24, attention_y, 11, 0x00E6E6E6);
                drawText(hdc, allocator, attentionReason(node), 24, attention_y + 15, 9, stateColor(node.state));
                const stop_bounds = needsYouStopBounds(model, inspection, state, scroll_offset, index);
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
        const filter_bounds = activityFilterBounds(model, inspection, state, scroll_offset);
        fill(hdc, filter_bounds, if (state.activity_attention_only) 0x00302B1D else 0x0026262B);
        drawTextRect(hdc, allocator, "Attention only", filter_bounds, 9, if (state.activity_attention_only) 0x00FFCD7A else 0x00B8B8B8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        const left_bounds = activityControlBounds(model, inspection, state, scroll_offset, .left);
        const right_bounds = activityControlBounds(model, inspection, state, scroll_offset, .right);
        fill(hdc, left_bounds, 0x0026262B);
        fill(hdc, right_bounds, 0x0026262B);
        drawTextRect(hdc, allocator, "<", left_bounds, 10, 0x00B8B8B8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        drawTextRect(hdc, allocator, ">", right_bounds, 10, 0x00B8B8B8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        const viewport = activityViewport(model, state);
        for (0..viewport.visible_count) |visible_index| {
            const activity_index = activityEventAtVisible(model, state, visible_index) orelse break;
            const event = model.activity.items[activity_index];
            const card = activityCardBounds(model, inspection, state, scroll_offset, visible_index);
            const stamp = std.fmt.allocPrint(allocator, "{d}m", .{@max(0, @divTrunc(std.time.timestamp() - event.timestamp, 60))}) catch null;
            defer if (stamp) |value| allocator.free(value);
            fill(hdc, card, 0x0026262B);
            fill(hdc, rect(card.left, card.top, card.left + 3, card.bottom), stateColor(event.state));
            drawTextRect(hdc, allocator, event.title, rect(card.left + 8, card.top + 4, card.right - 8, card.top + 20), 10, 0x00E6E6E6, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
            drawTextRect(hdc, allocator, stamp orelse "", rect(card.left + 8, card.top + 18, card.right - 8, card.bottom - 4), 9, stateColor(event.state), c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER);
        }
    }
    if (saved_clip != 0) _ = c.RestoreDC(hdc, saved_clip);
    if (has_error and errorFooterVisible(viewport_bottom)) {
        const bounds = errorFooterRect(viewport_bottom);
        fill(hdc, bounds, 0x00242448);
        drawTextRect(hdc, allocator, ingress_error, errorFooterTextRect(viewport_bottom), 10, 0x006060FF, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
    }
    if (has_update) {
        const bounds = updateBannerRect(viewport_bottom, has_error);
        fill(hdc, bounds, 0x00352B1C);
        drawText(hdc, allocator, "v", bounds.left + 10, bounds.top + 10, 14, 0x00FF840A);
        drawText(hdc, allocator, "Update available", bounds.left + 30, bounds.top + 7, 12, 0x00F0F0F0);
        const detail = std.fmt.allocPrint(allocator, "{s} · click to install", .{update_version}) catch null;
        defer if (detail) |value| allocator.free(value);
        drawText(hdc, allocator, detail orelse update_version, bounds.left + 30, bounds.top + 24, 10, 0x00909090);
    }
    drawTextRect(
        hdc,
        allocator,
        status,
        statusTextRect(viewport_bottom, has_update, has_error),
        11,
        0x00909090,
        c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );
}

const loop_text_format: c.UINT = c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX;
const loop_age_right: i32 = 176;
const loop_age_width: i32 = 56;
const loop_text_gap: i32 = 4;

pub const LoopRowText = struct { title: c.RECT, state: c.RECT, age: c.RECT };

fn loopIndent(depth: usize) i32 {
    return @as(i32, @intCast(@min(depth, 9))) * 16;
}

/// AppSidebarView.nodeRow: title, monospaced age, then a 7pt state indicator.
/// Keep all three clear of the existing disclosure hit zone (x >= 198).
pub fn loopRowTextRects(row_top: i32, depth: usize) LoopRowText {
    return loopRowTextRectsForAgeWidth(row_top, depth, loop_age_width);
}

fn loopRowTextRectsForAgeWidth(row_top: i32, depth: usize, age_width: i32) LoopRowText {
    const age = rect(loop_age_right - std.math.clamp(age_width, 1, loop_age_width), row_top + 1, loop_age_right, row_top + 20);
    const state = rect(age.right + 7, row_top + 7, age.right + 14, row_top + 14);
    const title_right = age.left - loop_text_gap;
    const title_left = @min(44 + loopIndent(depth), title_right);
    return .{ .title = rect(title_left, row_top + 1, title_right, row_top + 20), .state = state, .age = age };
}

fn measuredAgeWidth(hdc: c.HDC, label: []const u8) !i32 {
    const font = AppFont.getStyle(10.5, .card_mono) orelse return error.AgeFontUnavailable;
    const previous = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, previous);
    return measuredWidth(hdc, label);
}

/// Top edge of the scrollable sidebar content, 3 px above the first row's top so a row's
/// selection fill is never cut at rest. The GRAPH / Projects header above it is fixed, so rows,
/// labels, hit targets, and UIA bounds all start here and never overlap it.
pub const content_top: i32 = Tokens.header_height + 78 - 3;

const footer_status_extent: i32 = 58;
const footer_error_extent: i32 = 50;
const footer_update_extent: i32 = 58;
const status_line_height: i32 = 20;

/// Height the sidebar footer (status line, optional update banner, optional error footer)
/// takes from the bottom of the sidebar. Scrolling content never extends into it.
pub fn footerReserve(has_update: bool, has_error: bool) i32 {
    return footer_status_extent +
        (if (has_error) footer_error_extent else 0) +
        (if (has_update) footer_update_extent else 0);
}

/// Scroll region (52 px, room for two 24 px row slots) the sidebar keeps before it gives footer space back to content. It is a region height, not a guarantee of two published elements at every offset.
pub const min_content_region: i32 = 52;

pub const Footer = struct {
    /// The update banner is shown above the status line.
    update: bool,
    /// The inline ingress error footer is shown above the update banner.
    ingress: bool,
};

/// The footer parts that fit while still leaving `min_content_region` of scrolling content. On a
/// short viewport the error footer collapses first, then the update banner; the status line is
/// the footer's floor. The same result drives drawing, hit testing, and UIA, so a collapsed
/// part is neither painted nor published nor clickable.
pub fn effectiveFooter(viewport_bottom: i32, has_update: bool, has_error: bool) Footer {
    var footer = Footer{ .update = has_update, .ingress = has_error };
    if (footerLeavesRegion(viewport_bottom, footer)) return footer;
    footer.ingress = false;
    if (footerLeavesRegion(viewport_bottom, footer)) return footer;
    footer.update = false;
    return footer;
}

fn footerLeavesRegion(viewport_bottom: i32, footer: Footer) bool {
    return viewport_bottom - footerReserve(footer.update, footer.ingress) - content_top >= min_content_region;
}

/// Bottom edge of the scrollable sidebar content; rows, labels, hit targets, and UIA
/// bounds all end here so they cannot sit under the status line, banner, or error footer.
pub fn contentViewportBottom(viewport_bottom: i32, has_update: bool, has_error: bool) i32 {
    return @max(viewport_bottom - footerReserve(has_update, has_error), Tokens.header_height);
}

pub fn statusTextRect(viewport_bottom: i32, has_update: bool, has_error: bool) c.RECT {
    const top = viewport_bottom - footerReserve(has_update, has_error);
    return rect(18, top, Tokens.sidebar_width - 10, top + status_line_height);
}

pub fn chatsLabelRect(row_top: i32) c.RECT {
    return rect(18, row_top - 32, Tokens.sidebar_width - 10, row_top - 32 + 18);
}

pub fn needsYouLabelRect(section_bottom: i32, scroll_offset: i32) c.RECT {
    const top = section_bottom - scroll_offset + 10;
    return rect(18, top, Tokens.sidebar_width - 10, top + 19);
}

/// Rect of the inline error footer, anchored to the sidebar's visible bottom. Drawing and UIA
/// both use this rect. It never rises above the header; a viewport too short to hold any
/// of it yields an empty rect, which callers neither draw nor publish.
pub fn errorFooterRect(viewport_bottom: i32) c.RECT {
    const bottom = viewport_bottom - 42;
    const top = @max(viewport_bottom - 84, Tokens.header_height);
    return rect(8, top, Tokens.sidebar_width - 8, @max(bottom, top));
}

pub fn errorFooterTextRect(viewport_bottom: i32) c.RECT {
    const bounds = errorFooterRect(viewport_bottom);
    const top = @min(bounds.top + 8, bounds.bottom);
    return rect(bounds.left + 10, top, bounds.right - 10, @max(bounds.bottom - 8, top));
}

pub fn errorFooterVisible(viewport_bottom: i32) bool {
    const bounds = errorFooterRect(viewport_bottom);
    return bounds.top < bounds.bottom;
}

pub fn updateBannerRect(viewport_bottom: i32, has_error: bool) c.RECT {
    const error_offset: i32 = if (has_error) 50 else 0;
    return rect(8, viewport_bottom - 92 - error_offset, Tokens.sidebar_width - 8, viewport_bottom - 42 - error_offset);
}

pub fn updateBannerAt(x: i32, y: i32, viewport_bottom: i32, available: bool, has_error: bool) bool {
    const footer = effectiveFooter(viewport_bottom, available, has_error);
    if (!footer.update) return false;
    const bounds = updateBannerRect(viewport_bottom, footer.ingress);
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
    if (std.mem.eql(u8, loop_type, "goalBased")) return 0x00709E19;
    if (std.mem.eql(u8, loop_type, "timeBased")) return 0x000085C9;
    if (std.mem.eql(u8, loop_type, "turnBased")) return 0x008151D5;
    if (std.mem.eql(u8, loop_type, "composite")) return 0x00E98590;
    return 0x00E3DAD3;
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
    const hours = @mod(@divTrunc(seconds, 3600), 24);
    const minutes = @mod(@divTrunc(seconds, 60), 60);
    if (seconds < 86400) {
        if (minutes != 0) return std.fmt.allocPrint(allocator, "{d}h {d}m", .{ hours, minutes });
        return std.fmt.allocPrint(allocator, "{d}h", .{hours});
    }
    const days = @divTrunc(seconds, 86400);
    if (hours != 0) return std.fmt.allocPrint(allocator, "{d}d {d}h", .{ days, hours });
    return std.fmt.allocPrint(allocator, "{d}d", .{days});
}

pub const Surface = enum { project, overview, quick_chats, workspace };
pub const RowKind = enum { local_heading, remote_heading, project, open_project, overview, loop, worktree, quick_chat_overview, quick_chat };
pub const Row = struct {
    kind: RowKind,
    index: usize,
    top: i32,
    project_path: ?[]const u8 = null,
    project_name: ?[]const u8 = null,
    depth: usize = 0,
    has_graph: bool = false,
    has_children: bool = false,
};
pub const ProjectGraph = union(enum) {
    summary: *const GraphModel.GraphSummary,
    legacy: *const GraphModel.Graph,

    pub fn project(self: ProjectGraph) GraphModel.Project {
        return switch (self) {
            .summary => |graph| graph.project,
            .legacy => |graph| graph.project,
        };
    }

    pub fn nodes(self: ProjectGraph) []const GraphModel.Node {
        return switch (self) {
            .summary => |graph| graph.nodes.items,
            .legacy => |graph| graph.nodes.items,
        };
    }

    pub fn edges(self: ProjectGraph) []const GraphModel.Edge {
        return switch (self) {
            .summary => |graph| graph.edges.items,
            .legacy => |graph| graph.edges.items,
        };
    }
};
pub const RowControl = enum { add_loop, disclosure, new_chat, chats_disclosure };

const navigation_row_height: i32 = 32;
const section_gap: i32 = 12;
const global_project_path = "graphcode://global";

pub fn navigationRowSelected(row: Row, surface: Surface, selected_project_path: ?[]const u8) bool {
    return switch (row.kind) {
        .overview => surface == .overview,
        .quick_chat_overview => surface == .quick_chats,
        .open_project => surface == .project and
            row.project_path != null and
            selected_project_path != null and
            std.mem.eql(u8, row.project_path.?, selected_project_path.?),
        else => false,
    };
}

pub fn graphForProject(model: *const GraphModel.Model, path: []const u8) ?ProjectGraph {
    if (model.graphFor(path)) |graph| return .{ .summary = graph };
    if (model.graph) |*graph| {
        if (std.mem.eql(u8, graph.project.path, path)) return .{ .legacy = graph };
    }
    return null;
}

pub fn projectHasChildren(model: *const GraphModel.Model, path: []const u8) bool {
    const graph = graphForProject(model, path) orelse return false;
    return graph.nodes().len != 0;
}

pub fn projectName(model: *const GraphModel.Model, path: []const u8) ?[]const u8 {
    const graph = graphForProject(model, path) orelse return null;
    return graph.project().name;
}

pub fn rowBounds(row: Row) c.RECT {
    const top_offset: i32 = if (row.kind == .loop) -2 else -3;
    const bottom_offset: i32 = switch (row.kind) {
        .local_heading, .remote_heading => 21,
        .loop => 22,
        .worktree => 31,
        else => 29,
    };
    return rect(12, row.top + top_offset, Tokens.sidebar_width, row.top + bottom_offset);
}

pub fn newLoopBounds(row: Row) c.RECT {
    return rect(174, row.top - 3, 198, row.top + 29);
}

pub fn disclosureBounds(row: Row) c.RECT {
    return rect(198, row.top - 3, 220, row.top + 29);
}

pub fn newChatBounds(row: Row) c.RECT {
    return newLoopBounds(row);
}

pub fn chatsDisclosureBounds(row: Row) c.RECT {
    return disclosureBounds(row);
}

pub fn rowControlAt(x: i32, y: i32, row: Row) ?RowControl {
    const bounds = rowBounds(row);
    if (x < bounds.left or x >= bounds.right or y < bounds.top or y >= bounds.bottom) return null;
    return switch (row.kind) {
        .overview, .open_project, .loop => if (x >= 198 and x < 220 and row.has_children)
            .disclosure
        else if (x >= 174 and x < 198 and row.has_graph)
            .add_loop
        else
            null,
        .quick_chat_overview => if (x >= 198 and x < 220 and row.has_children)
            .chats_disclosure
        else if (x >= 174 and x < 198)
            .new_chat
        else
            null,
        else => null,
    };
}

const HierarchyItem = struct { index: usize, depth: usize, has_children: bool };

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
    const global_graph = graphForProject(model, global_project_path);
    try rows.append(allocator, .{
        .kind = .overview,
        .index = 0,
        .top = top,
        .project_path = global_project_path,
        .project_name = "Graph",
        .has_graph = global_graph != null,
        .has_children = if (global_graph) |graph| graph.nodes().len != 0 else false,
    });
    top += navigation_row_height;
    if (global_graph != null) {
        if (state == null or !state.?.isProjectCollapsed(global_project_path)) {
            top = try appendProjectLoops(allocator, &rows, model, global_project_path, top, state);
        }
    }

    top += section_gap;
    try rows.append(allocator, .{
        .kind = .quick_chat_overview,
        .index = 0,
        .top = top,
        .has_children = model.quick_chats.items.len != 0,
    });
    top += navigation_row_height;
    if (!chats_collapsed) {
        for (model.quick_chats.items, 0..) |_, index| {
            try rows.append(allocator, .{ .kind = .quick_chat, .index = index, .top = top });
            top += navigation_row_height;
        }
    }
    top += section_gap;

    if (hasOpenOwnerInSection(model, .local)) {
        try rows.append(allocator, .{ .kind = .local_heading, .index = 0, .top = top, .project_name = "Local Projects" });
        top += 24;
        if (!local_collapsed) top = try appendOpenOwners(allocator, &rows, model, .local, top, state);
        top += section_gap;
    }
    if (hasOpenOwnerInSection(model, .remote)) {
        try rows.append(allocator, .{ .kind = .remote_heading, .index = 0, .top = top, .project_name = "Remote Repositories" });
        top += 24;
        if (!remote_collapsed) top = try appendOpenOwners(allocator, &rows, model, .remote, top, state);
        top += section_gap;
    }
    if (inspection) |value| {
        for (value.entries.items, 0..) |_, index| {
            try rows.append(allocator, .{ .kind = .worktree, .index = index, .top = top });
            top += 34;
        }
    }
    return rows;
}

pub fn sharedGraphTop(model: *const GraphModel.Model, graph_index: usize) i32 {
    if (graph_index >= model.graphs.items.len) return Tokens.header_height + 78;
    const path = model.graphs.items[graph_index].project.path;
    var rows = appendRows(std.heap.page_allocator, model, null, 0, null) catch return Tokens.header_height + 78;
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| {
        if (row.kind == .open_project and row.project_path != null and std.mem.eql(u8, row.project_path.?, path)) return row.top;
    }
    return Tokens.header_height + 78;
}

pub fn sharedLoopTop(model: *const GraphModel.Model, graph_index: usize, node_index: usize) i32 {
    if (graph_index >= model.graphs.items.len) return sharedGraphTop(model, graph_index) + navigation_row_height;
    const path = model.graphs.items[graph_index].project.path;
    var rows = appendRows(std.heap.page_allocator, model, null, 0, null) catch return sharedGraphTop(model, graph_index);
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| {
        if (row.kind == .loop and row.index == node_index and row.project_path != null and std.mem.eql(u8, row.project_path.?, path)) return row.top;
    }
    return sharedGraphTop(model, graph_index) + navigation_row_height;
}

pub fn sharedWorktreeTop(model: *const GraphModel.Model, index: usize) i32 {
    var rows = appendRows(std.heap.page_allocator, model, null, 0, null) catch return Tokens.header_height + 78;
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| if (row.kind == .worktree and row.index == index) return row.top;
    return Tokens.header_height + 78;
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
    if (x < 0 or x >= Tokens.sidebar_width or y < content_top or y >= viewport_bottom) return null;
    var rows = appendRows(std.heap.page_allocator, model, inspection, scroll_offset, state) catch return null;
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| {
        const bounds = rowBounds(row);
        if (y >= bounds.top and y < bounds.bottom) return row;
    }
    return null;
}

const OwnerSource = enum { open_project, graph_summary, legacy_graph };
const OwnerGroup = enum { local, remote };

fn appendGraphLoops(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    graph: anytype,
    initial_top: i32,
    state: ?*const State,
) !i32 {
    var top = initial_top;
    var hierarchy = try hierarchyItems(allocator, graph.nodes.items, graph.edges.items, state);
    defer hierarchy.deinit(allocator);
    for (hierarchy.items) |item| {
        try rows.append(allocator, .{
            .kind = .loop,
            .index = item.index,
            .top = top,
            .project_path = graph.project.path,
            .depth = item.depth,
            .has_children = item.has_children,
        });
        top += 24;
    }
    return top;
}

fn appendProjectLoops(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    model: *const GraphModel.Model,
    path: []const u8,
    top: i32,
    state: ?*const State,
) !i32 {
    return switch (graphForProject(model, path) orelse return top) {
        .summary => |graph| try appendGraphLoops(allocator, rows, graph, top, state),
        .legacy => |graph| try appendGraphLoops(allocator, rows, graph, top, state),
    };
}

fn ownerPathSeenEarlier(model: *const GraphModel.Model, path: []const u8, source: OwnerSource, index: usize) bool {
    const open_limit = if (source == .open_project) index else model.open_projects.items.len;
    for (model.open_projects.items[0..open_limit]) |project| {
        if (std.mem.eql(u8, project.path, path)) return true;
    }
    if (source == .open_project) return false;

    const graph_limit = if (source == .graph_summary) index else model.graphs.items.len;
    for (model.graphs.items[0..graph_limit]) |graph| {
        if (std.mem.eql(u8, graph.project.path, path)) return true;
    }
    return false;
}

fn projectInGroup(project: GraphModel.Project, group: OwnerGroup) bool {
    if (project.isGlobal()) return false;
    return project.isRemote() == (group == .remote);
}

fn hasOpenOwnerInSection(model: *const GraphModel.Model, group: OwnerGroup) bool {
    for (model.open_projects.items, 0..) |project, index| {
        if (projectInGroup(project, group) and !ownerPathSeenEarlier(model, project.path, .open_project, index)) return true;
    }
    for (model.graphs.items, 0..) |graph, index| {
        if (projectInGroup(graph.project, group) and !ownerPathSeenEarlier(model, graph.project.path, .graph_summary, index)) return true;
    }
    if (model.graph) |graph| {
        if (projectInGroup(graph.project, group) and !ownerPathSeenEarlier(model, graph.project.path, .legacy_graph, 0)) return true;
    }
    return false;
}

fn openOwnerCount(model: *const GraphModel.Model, group: OwnerGroup) usize {
    var count: usize = 0;
    for (model.open_projects.items, 0..) |project, index| {
        if (projectInGroup(project, group) and !ownerPathSeenEarlier(model, project.path, .open_project, index)) count += 1;
    }
    for (model.graphs.items, 0..) |graph, index| {
        if (projectInGroup(graph.project, group) and !ownerPathSeenEarlier(model, graph.project.path, .graph_summary, index)) count += 1;
    }
    if (model.graph) |graph| {
        if (projectInGroup(graph.project, group) and !ownerPathSeenEarlier(model, graph.project.path, .legacy_graph, 0)) count += 1;
    }
    return count;
}

fn appendOwnerCandidate(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    model: *const GraphModel.Model,
    project: GraphModel.Project,
    source: OwnerSource,
    index: usize,
    group: OwnerGroup,
    top: *i32,
    state: ?*const State,
) !void {
    if (!projectInGroup(project, group) or ownerPathSeenEarlier(model, project.path, source, index)) return;
    const graph = graphForProject(model, project.path);
    const name = if (graph) |value| value.project().name else project.name;
    try rows.append(allocator, .{
        .kind = .open_project,
        .index = index,
        .top = top.*,
        .project_path = project.path,
        .project_name = if (name.len == 0) project.path else name,
        .has_graph = graph != null,
        .has_children = if (graph) |value| value.nodes().len != 0 else false,
    });
    top.* += navigation_row_height;
    if (graph != null) {
        if (state == null or !state.?.isProjectCollapsed(project.path)) {
            top.* = try appendProjectLoops(allocator, rows, model, project.path, top.*, state);
        }
    }
}

fn appendOpenOwners(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    model: *const GraphModel.Model,
    group: OwnerGroup,
    initial_top: i32,
    state: ?*const State,
) !i32 {
    var top = initial_top;
    for (model.open_projects.items, 0..) |project, index| {
        try appendOwnerCandidate(allocator, rows, model, project, .open_project, index, group, &top, state);
    }
    for (model.graphs.items, 0..) |graph, index| {
        try appendOwnerCandidate(allocator, rows, model, graph.project, .graph_summary, index, group, &top, state);
    }
    if (model.graph) |graph| {
        try appendOwnerCandidate(allocator, rows, model, graph.project, .legacy_graph, 0, group, &top, state);
    }
    return top;
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
    return rowBounds(last).bottom;
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
    const left: i32 = if (control == .left) 172 else 196;
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

pub fn hitTestOverviewLoop(x: i32, y: i32, model: *const GraphModel.Model, scroll_offset: i32, viewport_bottom: i32) ?usize {
    if (x < 0 or x >= Tokens.sidebar_width or y < content_top or y >= viewport_bottom) return null;
    var rows = appendRows(std.heap.page_allocator, model, null, scroll_offset, null) catch return null;
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| {
        if (row.kind != .loop or row.project_path == null or !std.mem.eql(u8, row.project_path.?, global_project_path)) continue;
        const bounds = rowBounds(row);
        if (y >= bounds.top and y < bounds.bottom) return row.index;
    }
    return null;
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

test "worktree row hit testing uses generated visible rows" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = try allocator.dupe(u8, "main"),
        .project_path = try allocator.dupe(u8, "project"),
    };
    defer WorktreeStatus.deinitInspection(allocator, &inspection);
    for (0..2) |index| try inspection.entries.append(.{
        .path = try std.fmt.allocPrint(allocator, "worktree-{d}", .{index}),
        .branch = try allocator.dupe(u8, "branch"),
    });
    var rows = try appendRows(allocator, &model, &inspection, 0, null);
    defer rows.deinit(allocator);
    const worktree_rows = [_]Row{
        for (rows.items) |row| {
            if (row.kind == .worktree and row.index == 0) break row;
        } else return error.TestUnexpectedResult,
        for (rows.items) |row|
        {
            if (row.kind == .worktree and row.index == 1) break row;
        } else return error.TestUnexpectedResult,
    };
    for (worktree_rows) |row| {
        const hit = rowAt(24, row.top + 14, &model, &inspection, 0, 700, null) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(RowKind.worktree, hit.kind);
        try std.testing.expectEqual(row.index, hit.index);
    }
    try std.testing.expectEqual(@as(i32, 34), worktree_rows[1].top - worktree_rows[0].top);
    try std.testing.expect(rowAt(Tokens.sidebar_width + 1, worktree_rows[0].top + 14, &model, &inspection, 0, 700, null) == null);
    const handoff = rowAt(24, worktree_rows[0].top + 31, &model, &inspection, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(worktree_rows[1].index, handoff.index);
    try std.testing.expect(rowAt(24, 700, &model, &inspection, 0, 700, null) == null);
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

test "sidebar layout routes generated loop rows after owner rows and scroll" {
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
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    var loop_rows: usize = 0;
    for (0..2) |index| {
        const row = for (rows.items) |candidate| {
            if (candidate.kind == .loop and candidate.index == index) break candidate;
        } else return error.TestUnexpectedResult;
        loop_rows += 1;
        const hit = rowAt(24, row.top - 11 + 12, &model, null, 11, 700, null) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(RowKind.loop, hit.kind);
        try std.testing.expectEqual(index, hit.index);
        try std.testing.expectEqual(RowKind.loop, row.kind);
        try std.testing.expectEqual(index, row.index);
    }
    try std.testing.expectEqual(@as(usize, 2), loop_rows);
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
    var rows = try appendRows(allocator, &model, null, 0, null);
    defer rows.deinit(allocator);
    const last = rows.items[rows.items.len - 1];
    try std.testing.expectEqual(
        rowBounds(last).bottom,
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
    var hits: usize = 0;
    var hidden: usize = 0;
    for (rows.items) |row| {
        const hit = rowAt(24, row.top + 4, &model, &inspection, scroll, 700, null) orelse {
            // Rows scrolled under the fixed header are not targets.
            try std.testing.expect(row.top + 4 < content_top);
            hidden += 1;
            continue;
        };
        hits += 1;
        try std.testing.expect(row.top + 4 >= content_top);
        try std.testing.expectEqual(row.kind, hit.kind);
        if (row.kind == .project or row.kind == .open_project or row.kind == .loop)
            try std.testing.expectEqualStrings(row.project_path orelse "recent", hit.project_path orelse "recent");
    }
    try std.testing.expect(hits >= 3 and hidden >= 1);
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

test "sidebar without graph excludes recent-project rows from its content extent" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "project"),
        .name = try std.testing.allocator.dupe(u8, "Project"),
    });
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), countRows(rows.items, .project));
    try std.testing.expectEqual(@as(usize, 0), countRows(rows.items, .open_project));
    try std.testing.expectEqual(@as(usize, 1), model.recent_projects.items.len);
    const last = rows.items[rows.items.len - 1];
    const no_graph_max = maxScroll(&model, null, 100, null);
    const expected_max = @max(rowBounds(last).bottom - 100, 0);
    try std.testing.expectEqual(expected_max, no_graph_max);
    try std.testing.expectEqual(expected_max, clampScroll(180, no_graph_max));
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

test "open owners are grouped by locality while recent projects stay out of navigation" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "ssh://host/repo"),
        .name = try std.testing.allocator.dupe(u8, "Recent remote"),
    });
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\repo"),
        .name = try std.testing.allocator.dupe(u8, "Recent local"),
    });
    try appendTestOpenProject(std.testing.allocator, &model, "ssh://host/open", "Remote");
    try appendTestOpenProject(std.testing.allocator, &model, "C:\\open", "Local");
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.quick_chat_overview, rows.items[1].kind);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.open_project, rows.items[3].kind);
    try std.testing.expectEqualStrings("C:\\open", rows.items[3].project_path.?);
    try std.testing.expectEqual(RowKind.remote_heading, rows.items[4].kind);
    try std.testing.expectEqual(RowKind.open_project, rows.items[5].kind);
    try std.testing.expectEqualStrings("ssh://host/open", rows.items[5].project_path.?);
    try std.testing.expectEqual(@as(usize, 0), countRows(rows.items, .project));
}

test "recent project data remains available without adding sidebar destinations" {
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
    try std.testing.expectEqual(@as(usize, 2), model.recent_projects.items.len);
    try std.testing.expectEqualStrings("C:\\recent", model.recent_projects.items[1].path);
    try std.testing.expectEqual(@as(usize, 0), countRows(rows.items, .project));
    try std.testing.expectEqual(@as(usize, 1), countProjectRows(rows.items, .open_project, "C:\\open"));
    try std.testing.expectEqual(@as(usize, 0), countProjectRows(rows.items, .open_project, "C:\\recent"));
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
    try appendTestOpenProject(std.testing.allocator, &model, "C:\\local", "Local");
    try appendTestOpenProject(std.testing.allocator, &model, "ssh://host/remote", "Remote");
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.local_collapsed = true;
    var rows = try appendRows(std.testing.allocator, &model, null, 0, &state);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.quick_chat_overview, rows.items[1].kind);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.remote_heading, rows.items[3].kind);
    try std.testing.expectEqual(RowKind.open_project, rows.items[4].kind);
    try std.testing.expectEqualStrings("ssh://host/remote", rows.items[4].project_path.?);

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

fn appendTestOpenProject(allocator: std.mem.Allocator, model: *GraphModel.Model, path: []const u8, name: []const u8) !void {
    try model.open_projects.append(.{
        .path = try allocator.dupe(u8, path),
        .name = try allocator.dupe(u8, name),
    });
}

fn countProjectRows(rows: []const Row, kind: RowKind, path: []const u8) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (row.kind == kind and row.project_path != null and std.mem.eql(u8, row.project_path.?, path)) count += 1;
    }
    return count;
}

fn expectRowProjectPath(row: Row, path: []const u8) !void {
    try std.testing.expectEqualStrings(path, row.project_path orelse return error.TestUnexpectedResult);
}

test "parity sidebar navigation pins destinations before open folder groups" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try allocator.dupe(u8, "C:\\recent"),
        .name = try allocator.dupe(u8, "Recent local"),
    });
    try model.recent_projects.append(.{
        .path = try allocator.dupe(u8, "ssh://host/recent"),
        .name = try allocator.dupe(u8, "Recent remote"),
    });
    try appendTestOpenProject(allocator, &model, "C:\\local", "Local");
    try appendTestOpenProject(allocator, &model, "ssh://host/remote", "Remote");
    try model.quick_chats.append(.{
        .id = try allocator.dupe(u8, "chat"),
        .title = try allocator.dupe(u8, "Chat"),
        .backend = try allocator.dupe(u8, "claudeCode"),
    });

    var rows = try appendRows(allocator, &model, null, 0, null);
    defer rows.deinit(allocator);

    const expected = [_]RowKind{
        .overview,
        .quick_chat_overview,
        .quick_chat,
        .local_heading,
        .open_project,
        .remote_heading,
        .open_project,
    };
    try std.testing.expectEqual(expected.len, rows.items.len);
    for (expected, rows.items) |kind, row| try std.testing.expectEqual(kind, row.kind);
    try std.testing.expectEqual(@as(usize, 0), countRows(rows.items, .project));
    try expectRowProjectPath(rows.items[4], "C:\\local");
    try expectRowProjectPath(rows.items[6], "ssh://host/remote");
}

test "parity sidebar navigation emits each open owner once including global and loading owners" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    try appendTestOpenProject(allocator, &model, "C:\\same-a", "Same");
    try appendTestOpenProject(allocator, &model, "C:\\same-b", "Same");
    try appendTestOpenProject(allocator, &model, "C:\\loading", "Loading owner");
    try appendTestOpenProject(allocator, &model, "C:\\loading", "Loading owner duplicate");
    try appendTestOpenProject(allocator, &model, "graphcode://global", "Global graph");
    try model.recent_projects.append(.{
        .path = try allocator.dupe(u8, "graphcode://global"),
        .name = try allocator.dupe(u8, "Global graph fallback"),
    });

    var global = GraphModel.Graph{
        .project = .{
            .path = try allocator.dupe(u8, "graphcode://global"),
            .name = try allocator.dupe(u8, "Graph"),
        },
        .nodes = std.array_list.Managed(GraphModel.Node).init(allocator),
        .edges = std.array_list.Managed(GraphModel.Edge).init(allocator),
    };
    try global.nodes.append(.{
        .id = try allocator.dupe(u8, "global-loop"),
        .title = try allocator.dupe(u8, "Global loop"),
        .loop_type = try allocator.dupe(u8, "goalBased"),
        .state = try allocator.dupe(u8, "idle"),
        .activity = try allocator.dupe(u8, ""),
        .presence = try allocator.dupe(u8, "idle"),
    });
    model.graph = global;

    var rows = try appendRows(allocator, &model, null, 0, null);
    defer rows.deinit(allocator);

    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try expectRowProjectPath(rows.items[0], "graphcode://global");
    try std.testing.expect(rows.items[0].has_children);
    try std.testing.expectEqual(RowKind.loop, rows.items[1].kind);
    try expectRowProjectPath(rows.items[1], "graphcode://global");
    try std.testing.expectEqual(@as(usize, 1), countProjectRows(rows.items, .open_project, "C:\\same-a"));
    try std.testing.expectEqual(@as(usize, 1), countProjectRows(rows.items, .open_project, "C:\\same-b"));
    try std.testing.expectEqual(@as(usize, 1), countProjectRows(rows.items, .open_project, "C:\\loading"));
    try std.testing.expectEqual(@as(usize, 0), countProjectRows(rows.items, .open_project, "graphcode://global"));
    try std.testing.expectEqual(@as(usize, 0), countRows(rows.items, .project));

    var loaded_model = GraphModel.Model.init(allocator);
    defer loaded_model.deinit();
    const loaded_graph =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"loaded","project":{"path":"C:\\loaded","name":"Loaded graph"},"nodes":[],"edges":[]}}}
    ;
    _ = try loaded_model.updateFromFrame(loaded_graph);
    try appendTestOpenProject(allocator, &loaded_model, "C:\\loaded", "Duplicate metadata");
    var loaded_rows = try appendRows(allocator, &loaded_model, null, 0, null);
    defer loaded_rows.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), countProjectRows(loaded_rows.items, .open_project, "C:\\loaded"));
}

test "parity sidebar navigation folds do not hide peer destinations" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    try appendTestOpenProject(allocator, &model, "C:\\local", "Local");
    try appendTestOpenProject(allocator, &model, "ssh://host/remote", "Remote");
    try model.quick_chats.append(.{
        .id = try allocator.dupe(u8, "chat"),
        .title = try allocator.dupe(u8, "Chat"),
        .backend = try allocator.dupe(u8, "claudeCode"),
    });
    var state = State.init(allocator);
    defer state.deinit();
    state.local_collapsed = true;

    var local_collapsed = try appendRows(allocator, &model, null, 0, &state);
    defer local_collapsed.deinit(allocator);
    try std.testing.expectEqual(RowKind.overview, local_collapsed.items[0].kind);
    try std.testing.expectEqual(RowKind.quick_chat_overview, local_collapsed.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), countRows(local_collapsed.items, .quick_chat));
    try std.testing.expectEqual(@as(usize, 0), countProjectRows(local_collapsed.items, .open_project, "C:\\local"));
    try std.testing.expectEqual(@as(usize, 1), countProjectRows(local_collapsed.items, .open_project, "ssh://host/remote"));

    state.local_collapsed = false;
    state.remote_collapsed = true;
    var remote_collapsed = try appendRows(allocator, &model, null, 0, &state);
    defer remote_collapsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), countProjectRows(remote_collapsed.items, .open_project, "C:\\local"));
    try std.testing.expectEqual(@as(usize, 0), countProjectRows(remote_collapsed.items, .open_project, "ssh://host/remote"));
    try std.testing.expectEqual(@as(usize, 1), countRows(remote_collapsed.items, .quick_chat));
}

test "parity sidebar navigation shares row extents across scroll and hit testing" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    for (0..14) |index| {
        const path = try std.fmt.allocPrint(allocator, "C:\\project-{d}", .{index});
        defer allocator.free(path);
        const name = try std.fmt.allocPrint(allocator, "Project {d}", .{index});
        defer allocator.free(name);
        try appendTestOpenProject(allocator, &model, path, name);
    }
    try model.quick_chats.append(.{
        .id = try allocator.dupe(u8, "chat"),
        .title = try allocator.dupe(u8, "Chat"),
        .backend = try allocator.dupe(u8, "claudeCode"),
    });

    var rows = try appendRows(allocator, &model, null, 0, null);
    defer rows.deinit(allocator);
    for (rows.items) |row| {
        if (row.kind != .overview and row.kind != .quick_chat_overview and
            row.kind != .open_project and row.kind != .quick_chat) continue;
        const center = row.top + 16;
        const center_hit = rowAt(24, center, &model, null, 0, 1000, null) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(row.kind, center_hit.kind);
        try std.testing.expectEqual(row.project_path, center_hit.project_path);
        const lower_slot_hit = rowAt(24, row.top + 28, &model, null, 0, 1000, null) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(row.kind, lower_slot_hit.kind);
        try std.testing.expectEqual(row.project_path, lower_slot_hit.project_path);
    }

    const viewport_bottom: i32 = 240;
    const content_bottom = contentViewportBottom(viewport_bottom, false, false);
    const scroll = maxScroll(&model, null, content_bottom, null);
    try std.testing.expect(scroll > 0);
    var scrolled = try appendRows(allocator, &model, null, scroll, null);
    defer scrolled.deinit(allocator);
    const last = scrolled.items[scrolled.items.len - 1];
    const last_hit = rowAt(24, last.top + 16, &model, null, scroll, content_bottom, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(last.kind, last_hit.kind);
    try std.testing.expectEqual(last.project_path, last_hit.project_path);
    try std.testing.expect(rowAt(24, content_bottom, &model, null, scroll, content_bottom, null) == null);
}

test "quick chats remain selectable without an open graph or inspection" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.quick_chats.append(.{
        .id = try std.testing.allocator.dupe(u8, "chat-1"),
        .title = try std.testing.allocator.dupe(u8, "Scratch"),
        .backend = try std.testing.allocator.dupe(u8, "claudeCode"),
    });
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    const overview_row = for (rows.items) |row| {
        if (row.kind == .quick_chat_overview) break row;
    } else return error.TestUnexpectedResult;
    const chat_row = for (rows.items) |row| {
        if (row.kind == .quick_chat) break row;
    } else return error.TestUnexpectedResult;
    const overview = rowAt(24, overview_row.top + 16, &model, null, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat_overview, overview.kind);
    const row = rowAt(24, chat_row.top + 16, &model, null, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat, row.kind);
    try std.testing.expectEqual(@as(usize, 0), row.index);
    try std.testing.expectEqual(@as(i32, navigation_row_height), chat_row.top - overview_row.top);
    try std.testing.expectEqual(rowBounds(rows.items[rows.items.len - 1]).bottom, sidebarSectionBottom(&model, null, null));
}

test "quick chat rows use the navigation row height after graph loops" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"graphcode://global","name":"Graph"},"nodes":[{"id":"one","title":"One","state":"idle"},{"id":"two","title":"Two","state":"idle"}],"edges":[]}}}
    );
    try model.quick_chats.append(.{
        .id = try std.testing.allocator.dupe(u8, "chat"),
        .title = try std.testing.allocator.dupe(u8, "Chat"),
        .backend = try std.testing.allocator.dupe(u8, "claudeCode"),
    });
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    const last_graph_loop = for (rows.items) |row| {
        if (row.kind == .loop and std.mem.eql(u8, row.project_path.?, global_project_path) and row.index == 1)
            break row;
    } else return error.TestUnexpectedResult;
    const chats_row = for (rows.items) |row| {
        if (row.kind == .quick_chat_overview) break row;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 36), chats_row.top - last_graph_loop.top);
    try std.testing.expectEqual(@as(usize, 1), countRows(rows.items, .quick_chat));
}

test "sidebar row parity uses the macOS kind stripe palette" {
    const kinds = [_][]const u8{ "sketch", "goalBased", "timeBased", "turnBased", "composite" };
    const colors = [_]u32{ 0x00E3DAD3, 0x00709E19, 0x000085C9, 0x008151D5, 0x00E98590 };
    for (kinds, colors) |kind, color| try std.testing.expectEqual(color, loopAccent(kind));
}

test "sidebar row parity retains remainder units in elapsed time" {
    const allocator = std.testing.allocator;
    const base: i64 = 788918400;
    const ages = [_]i64{ 3660, 7199, 90000, 172799 };
    const labels = [_][]const u8{ "1h 1m", "1h 59m", "1d 1h", "1d 23h" };
    for (ages, labels) |seconds, expected| {
        const actual = try elapsedText(allocator, base, base + seconds);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "sidebar row parity orders title age and a seven pixel trailing state" {
    for (0..5) |depth| {
        const text = loopRowTextRects(100, depth);
        try std.testing.expect(text.title.left < text.title.right);
        try std.testing.expect(text.title.right <= text.age.left);
        try std.testing.expect(text.age.right < text.state.left);
        try std.testing.expectEqual(@as(i32, 7), text.state.right - text.state.left);
        try std.testing.expectEqual(@as(i32, 7), text.state.bottom - text.state.top);
        try std.testing.expect(text.state.right <= 198);
    }
    const root = loopRowTextRects(100, 0);
    const child = loopRowTextRects(100, 1);
    try std.testing.expectEqual(@as(i32, 16), child.title.left - root.title.left);
    for ([_]i32{ 0, 12, 56, 100 }) |width| for (0..32) |depth| {
        const text = loopRowTextRectsForAgeWidth(100, depth, width);
        try std.testing.expect(text.title.left <= text.title.right);
        try std.testing.expect(text.title.right < text.age.left);
        try std.testing.expect(text.age.left < text.age.right);
        try std.testing.expect(text.age.right < text.state.left);
        try std.testing.expectEqual(root.state, text.state);
    };
}

test "sidebar row parity paints solid and hollow states on the production draw path" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\parity","name":"Parity"},"nodes":[{"id":"asking","title":"Question","loopType":"turnBased","state":"awaitingInput"},{"id":"blocked","title":"Blocked","loopType":"goalBased","state":"blocked"},{"id":"running","title":"Working","loopType":"sketch","state":"running"},{"id":"waiting","title":"Waiting","loopType":"composite","state":"waiting"},{"id":"done","title":"Finished","loopType":"timeBased","state":"succeeded"},{"id":"failed","title":"Failed","state":"failed"},{"id":"stalled","title":"Stalled","state":"stalled"},{"id":"stopped","title":"Stopped","state":"stopped"},{"id":"idle","title":"Idle","state":"idle"}],"edges":[]}}}
    );
    var state = State.init(allocator);
    defer state.deinit();
    var bitmap = try TestSidebarBitmap.init();
    defer bitmap.deinit();
    draw(bitmap.hdc, &model, .overview, null, "", 0, "", 800, "", "", &state, -1, allocator);
    var rows = try appendRows(allocator, &model, null, 0, &state);
    defer rows.deinit(allocator);
    const colors = [_]u32{ 0x000A9FFF, 0x000A9FFF, 0x00FF840A, 0x00FF840A, 0x0058D130, 0x003A45FF, 0x00F25ABF, 0x006F6C6C, 0x006F6C6C };
    var checked: usize = 0;
    for (rows.items) |row| {
        if (row.kind != .loop) continue;
        const indicator = loopRowTextRects(row.top, row.depth).state;
        const center = c.GetPixel(bitmap.hdc, 186, row.top + 10);
        const hollow = row.index == 1 or row.index == 3 or row.index == 7;
        if (hollow) {
            try std.testing.expectEqual(@as(u32, Tokens.workspace_rail), center);
        } else {
            try std.testing.expectEqual(colors[row.index], center);
        }
        var outline_pixels: usize = 0;
        var y = indicator.top;
        while (y < indicator.bottom) : (y += 1) {
            var x = indicator.left;
            while (x < indicator.right) : (x += 1) {
                if (c.GetPixel(bitmap.hdc, x, y) != Tokens.workspace_rail) outline_pixels += 1;
            }
        }
        try std.testing.expect(outline_pixels > 0);
        const node = graphForProject(&model, row.project_path.?).?.nodes()[row.index];
        const stripe_color = loopAccent(node.loop_type);
        var stripe_pixels: usize = 0;
        var stripe_rows: usize = 0;
        y = row.top - 2;
        while (y < row.top + 22) : (y += 1) {
            var pixels_on_row: usize = 0;
            var x: i32 = 28;
            while (x < 40) : (x += 1) {
                if (c.GetPixel(bitmap.hdc, x, y) != stripe_color) continue;
                try std.testing.expect(x >= 34 and x < 37);
                try std.testing.expect(y >= row.top + 3 and y < row.top + 17);
                pixels_on_row += 1;
                stripe_pixels += 1;
            }
            if (pixels_on_row != 0) stripe_rows += 1;
        }
        try std.testing.expectEqual(@as(usize, 14), stripe_rows);
        try std.testing.expect(stripe_pixels >= 28 and stripe_pixels <= 42);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), checked);
}

test "sidebar row parity keeps section controls trailing and header icons aligned" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    try appendTestOpenProject(allocator, &model, "C:\\local", "Local");
    try appendTestOpenProject(allocator, &model, "ssh://host/remote", "Remote");
    var state = State.init(allocator);
    defer state.deinit();
    state.chats_collapsed = true;
    var bitmap = try TestSidebarBitmap.init();
    defer bitmap.deinit();
    var rows = try appendRows(allocator, &model, null, 0, &state);
    defer rows.deinit(allocator);
    draw(bitmap.hdc, &model, .workspace, null, "", 0, "", 800, "", "", &state, -1, allocator);
    var headers_checked: usize = 0;
    var sections_checked: usize = 0;
    for (rows.items) |row| {
        switch (row.kind) {
            .overview, .quick_chat_overview, .open_project => {
                var icon_pixels: usize = 0;
                var y = row.top + 5;
                while (y < row.top + 24) : (y += 1) {
                    var x: i32 = 18;
                    while (x < 34) : (x += 1) {
                        if (c.GetPixel(bitmap.hdc, x, y) == 0x00E6E6E6) icon_pixels += 1;
                    }
                }
                try std.testing.expect(icon_pixels >= 10);
                headers_checked += 1;
            },
            .local_heading, .remote_heading => {
                var y = row.top;
                while (y < row.top + 20) : (y += 1) {
                    var x: i32 = 198;
                    while (x < 220) : (x += 1)
                        try std.testing.expectEqual(@as(u32, Tokens.workspace_rail), c.GetPixel(bitmap.hdc, x, y));
                }
                draw(bitmap.hdc, &model, .workspace, null, "", 0, "", 800, "", "", &state, row.top + 8, allocator);
                var chevron_pixels: usize = 0;
                y = row.top;
                while (y < row.top + 20) : (y += 1) {
                    var x: i32 = 198;
                    while (x < 220) : (x += 1) {
                        if (c.GetPixel(bitmap.hdc, x, y) != Tokens.workspace_rail) chevron_pixels += 1;
                    }
                }
                try std.testing.expect(chevron_pixels > 0);
                sections_checked += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 4), headers_checked);
    try std.testing.expectEqual(@as(usize, 2), sections_checked);
}

test "sidebar row parity gives short elapsed labels spare title space" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    const frame = try std.fmt.allocPrint(allocator,
        \\{{"version":2,"kind":"event","sequence":1,"event":{{"graphChanged":{{"project":{{"path":"C:\\parity","name":"Parity"}},"nodes":[{{"id":"loop","title":"MMMMMMMMM","state":"idle","createdAt":{d}}}],"edges":[]}}}}}}
    , .{std.time.timestamp() - 978_307_200 - 180});
    defer allocator.free(frame);
    _ = try model.updateFromFrame(frame);
    var state = State.init(allocator);
    defer state.deinit();
    var bitmap = try TestSidebarBitmap.init();
    defer bitmap.deinit();
    draw(bitmap.hdc, &model, .overview, null, "", 0, "", 800, "", "", &state, -1, allocator);
    var rows = try appendRows(allocator, &model, null, 0, &state);
    defer rows.deinit(allocator);
    const loop = for (rows.items) |row| {
        if (row.kind == .loop) break row;
    } else return error.TestUnexpectedResult;
    var title_pixels: usize = 0;
    var y = loop.top;
    while (y < loop.top + 20) : (y += 1) {
        var x: i32 = 120;
        while (x < 150) : (x += 1) {
            if (c.GetPixel(bitmap.hdc, x, y) != Tokens.workspace_rail) title_pixels += 1;
        }
    }
    try std.testing.expect(title_pixels > 20);
}

const TestSidebarBitmap = struct {
    hdc: c.HDC,
    bitmap: c.HBITMAP,
    previous: c.HGDIOBJ,

    fn init() !TestSidebarBitmap {
        const hdc = c.CreateCompatibleDC(null) orelse return error.CreateMemoryDcFailed;
        errdefer _ = c.DeleteDC(hdc);
        var info = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = 256;
        info.bmiHeader.biHeight = -800;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = c.BI_RGB;
        var pixels: ?*anyopaque = null;
        const bitmap = c.CreateDIBSection(hdc, &info, c.DIB_RGB_COLORS, &pixels, null, 0) orelse return error.CreateMemoryBitmapFailed;
        return .{ .hdc = hdc, .bitmap = bitmap, .previous = c.SelectObject(hdc, bitmap) };
    }

    fn deinit(self: *TestSidebarBitmap) void {
        _ = c.SelectObject(self.hdc, self.previous);
        _ = c.DeleteObject(self.bitmap);
        _ = c.DeleteDC(self.hdc);
    }
};

test "sidebar loop presentation preserves type and terminal states" {
    try std.testing.expectEqual(@as(u32, 0x00709E19), loopAccent("goalBased"));
    try std.testing.expectEqualStrings("done", compactState("succeeded"));
    try std.testing.expectEqualStrings("running", compactState("running"));
    try std.testing.expectEqual(@as(u32, 0x005F5FFF), stateColor("failed"));
}

test "loop row age reads the daemon's reference-date createdAt" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"loop","title":"Loop","state":"running","createdAt":812912680.0330639}],"edges":[]}}}
    );
    const node = model.currentGraph().?.nodes.items[0];
    // Five seconds after creation on the Unix clock; the daemon's Date counts from 2001.
    const now: i64 = 812912680 + 978_307_200 + 5;
    const age = try elapsedText(allocator, @intCast(node.created_at orelse 0), now);
    defer allocator.free(age);
    try std.testing.expectEqualStrings("5s", age);
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

    // The sidebar shares LoopCardPresentation.duration's remainder units.
    const twenty_three_hours = try elapsedText(allocator, base, base + 86399);
    defer allocator.free(twenty_three_hours);
    try std.testing.expectEqualStrings("23h 59m", twenty_three_hours);

    const one_day = try elapsedText(allocator, base, base + 86400);
    defer allocator.free(one_day);
    try std.testing.expectEqualStrings("1d", one_day);

    // Multi-day ages keep days and hours, omitting minutes rather than rolling into weeks.
    const ten_days = try elapsedText(allocator, base, base + 86400 * 10 + 3599);
    defer allocator.free(ten_days);
    try std.testing.expectEqualStrings("10d", ten_days);
}

test "sidebar footer reserve keeps content, status text, banner, and error footer disjoint" {
    for ([_]bool{ false, true }) |has_update| for ([_]bool{ false, true }) |has_error| for ([_]i32{ 420, 522, 772 }) |viewport_bottom| {
        const content_bottom = contentViewportBottom(viewport_bottom, has_update, has_error);
        const status = statusTextRect(viewport_bottom, has_update, has_error);
        try std.testing.expect(content_bottom <= status.top);
        try std.testing.expect(status.right <= Tokens.sidebar_width and status.bottom <= viewport_bottom);
        if (has_update) {
            const banner = updateBannerRect(viewport_bottom, has_error);
            try std.testing.expect(content_bottom <= banner.top);
            try std.testing.expect(status.bottom <= banner.top);
        }
        if (has_error) {
            const footer = errorFooterRect(viewport_bottom);
            try std.testing.expect(content_bottom <= footer.top);
            try std.testing.expect(status.bottom <= footer.top);
        }
    };
    // A viewport too short for the footer still leaves a well-formed, header-anchored content rect.
    try std.testing.expectEqual(@as(i32, Tokens.header_height), contentViewportBottom(100, true, true));
}

test "sidebar rows beneath the update banner are neither hit nor counted as visible" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    for (0..12) |index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "C:\\project-{d}", .{index});
        const name = try std.fmt.allocPrint(std.testing.allocator, "Project {d}", .{index});
        try appendTestOpenProject(std.testing.allocator, &model, path, name);
        std.testing.allocator.free(path);
        std.testing.allocator.free(name);
    }
    const viewport_bottom: i32 = 420;
    const banner = updateBannerRect(viewport_bottom, false);
    const content_bottom = contentViewportBottom(viewport_bottom, true, false);
    var rows = try appendRows(std.testing.allocator, &model, null, 0, null);
    defer rows.deinit(std.testing.allocator);
    var under_banner: usize = 0;
    for (rows.items) |row| {
        const y = row.top + 8;
        if (y >= banner.top and y < banner.bottom) {
            under_banner += 1;
            try std.testing.expect(rowAt(24, y, &model, null, 0, content_bottom, null) == null);
        } else if (y >= Tokens.header_height and y < content_bottom) {
            try std.testing.expect(rowAt(24, y, &model, null, 0, content_bottom, null) != null);
        }
    }
    try std.testing.expect(under_banner >= 1);
    // Scrolling to the end brings the last row above the banner instead of leaving it beneath.
    const max = maxScroll(&model, null, content_bottom, null);
    try std.testing.expectEqual(contentBottom(&model, null, null) - content_bottom, max);
    const last = rows.items[rows.items.len - 1];
    try std.testing.expect(rowBounds(last).bottom - max <= content_bottom);
}

test "update banner is a bounded footer action" {
    const bounds = updateBannerRect(700, false);
    try std.testing.expect(updateBannerAt(bounds.left, bounds.top, 700, true, false));
    try std.testing.expect(updateBannerAt(bounds.right - 1, bounds.bottom - 1, 700, true, false));
    try std.testing.expect(!updateBannerAt(bounds.right, bounds.bottom - 1, 700, true, false));
    try std.testing.expect(!updateBannerAt(bounds.left, bounds.top, 700, false, false));
    try std.testing.expect(updateBannerRect(700, true).bottom < errorFooterRect(700).top);
}

test "footer parts collapse error footer first, then the update banner, to keep a 52 px scroll region" {
    // Room for everything: nothing collapses.
    try std.testing.expectEqual(Footer{ .update = true, .ingress = true }, effectiveFooter(700, true, true));
    try std.testing.expectEqual(Footer{ .update = false, .ingress = false }, effectiveFooter(700, false, false));
    try std.testing.expectEqual(Footer{ .update = true, .ingress = false }, effectiveFooter(700, true, false));
    // The collapse points are exact: the stack fits when viewport - reserve - content_top >= min.
    const status_only = content_top + min_content_region + footerReserve(false, false);
    const with_update = content_top + min_content_region + footerReserve(true, false);
    const with_both = content_top + min_content_region + footerReserve(true, true);
    try std.testing.expectEqual(Footer{ .update = true, .ingress = true }, effectiveFooter(with_both, true, true));
    try std.testing.expectEqual(Footer{ .update = true, .ingress = false }, effectiveFooter(with_both - 1, true, true));
    try std.testing.expectEqual(Footer{ .update = true, .ingress = false }, effectiveFooter(with_update, true, true));
    try std.testing.expectEqual(Footer{ .update = false, .ingress = false }, effectiveFooter(with_update - 1, true, true));
    try std.testing.expectEqual(Footer{ .update = false, .ingress = false }, effectiveFooter(status_only, true, true));
    // An error footer collapses without an update banner too, and nothing is ever added.
    try std.testing.expectEqual(Footer{ .update = false, .ingress = true }, effectiveFooter(content_top + min_content_region + footerReserve(false, true), false, true));
    try std.testing.expectEqual(Footer{ .update = false, .ingress = false }, effectiveFooter(content_top + min_content_region + footerReserve(false, true) - 1, false, true));
    try std.testing.expectEqual(Footer{ .update = false, .ingress = false }, effectiveFooter(10, false, false));
    // The collapsed footer is the one the content region, status line, and banner hit test use.
    for ([_]i32{ status_only, with_update - 1, with_update, with_both - 1, with_both }) |viewport| {
        const footer = effectiveFooter(viewport, true, true);
        try std.testing.expect(viewport - footerReserve(footer.update, footer.ingress) - content_top >= min_content_region or !footer.update and !footer.ingress);
        const banner = updateBannerRect(viewport, footer.ingress);
        try std.testing.expectEqual(footer.update, updateBannerAt(banner.left, banner.top, viewport, true, true));
    }
}

test "error footer exposes an inset wrapping rect" {
    const footer = errorFooterRect(700);
    const text = errorFooterTextRect(700);
    try std.testing.expect(text.left > footer.left);
    try std.testing.expect(text.right < footer.right);
    try std.testing.expect(text.top > footer.top);
    try std.testing.expect(text.bottom < footer.bottom);
}

test "error footer stays below the header and above the viewport bottom on short viewports" {
    try std.testing.expectEqual(@as(i32, 204), errorFooterRect(700).right - errorFooterRect(700).left);
    try std.testing.expectEqual(@as(i32, 42), errorFooterRect(700).bottom - errorFooterRect(700).top);
    for ([_]i32{ -50, 0, 60, 76, 90, 118, 119, 300, 700 }) |viewport_bottom| {
        const footer = errorFooterRect(viewport_bottom);
        const text = errorFooterTextRect(viewport_bottom);
        try std.testing.expect(footer.top >= Tokens.header_height);
        try std.testing.expect(footer.top <= footer.bottom);
        try std.testing.expect(footer.bottom <= @max(viewport_bottom - 42, Tokens.header_height));
        try std.testing.expect(text.top <= text.bottom and text.top >= footer.top and text.bottom <= footer.bottom);
        try std.testing.expectEqual(footer.top < footer.bottom, errorFooterVisible(viewport_bottom));
        // Never reaches the update banner above it or the status line above that.
        try std.testing.expect(updateBannerRect(viewport_bottom, true).bottom <= footer.top);
        try std.testing.expect(statusTextRect(viewport_bottom, true, true).bottom <= footer.top);
    }
    try std.testing.expect(!errorFooterVisible(70));
    try std.testing.expect(errorFooterVisible(100));
}

test "sidebar draw clips rows to the content viewport and keeps status text inside the rail" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    for (0..14) |index| try model.recent_projects.append(.{
        .path = try std.fmt.allocPrint(allocator, "project-{d}", .{index}),
        .name = try std.fmt.allocPrint(allocator, "Project {d} with a name long enough to run far past the sidebar rail edge and into the canvas", .{index}),
    });
    var state = State.init(allocator);
    defer state.deinit();
    const screen = c.GetDC(null) orelse return error.SkipZigTest;
    defer _ = c.ReleaseDC(null, screen);
    const hdc = c.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteDC(hdc);
    const viewport_bottom: i32 = 500;
    const bitmap = c.CreateCompatibleBitmap(screen, 400, viewport_bottom) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteObject(bitmap);
    const previous = c.SelectObject(hdc, bitmap);
    defer _ = c.SelectObject(hdc, previous);
    const sentinel: u32 = 0x00FF00FF;
    fill(hdc, rect(0, 0, 400, viewport_bottom), sentinel);
    var draw_allocator = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(draw_allocator.deinit() == .ok);
    const long_status = "S" ** 120;
    draw(hdc, &model, .project, null, "", 0, long_status, viewport_bottom, "", "", &state, -1, draw_allocator.allocator());

    const content_bottom = contentViewportBottom(viewport_bottom, false, false);
    const status = statusTextRect(viewport_bottom, false, false);
    var painted_in_content: usize = 0;
    var y: i32 = Tokens.header_height;
    while (y < viewport_bottom) : (y += 1) {
        var x: i32 = 0;
        while (x < 400) : (x += 1) {
            const pixel = c.GetPixel(hdc, x, y);
            if (x >= Tokens.sidebar_width) {
                try std.testing.expectEqual(sentinel, pixel);
                continue;
            }
            const background = pixel == Tokens.workspace_rail;
            if (y < content_bottom) {
                if (!background) painted_in_content += 1;
            } else if (y >= status.bottom or x >= status.right) {
                // Below the status line, and right of it, only the rail background may show.
                try std.testing.expectEqual(@as(u32, Tokens.workspace_rail), pixel);
            }
        }
    }
    try std.testing.expect(painted_in_content > 200);
}

test "sidebar paints an open project whose daemon name is empty" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\unnamed","name":""},"nodes":[{"id":"n1","title":"","state":"idle"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqualStrings("", model.graph.?.project.name);
    var state = State.init(allocator);
    defer state.deinit();
    const screen = c.GetDC(null) orelse return error.SkipZigTest;
    defer _ = c.ReleaseDC(null, screen);
    const hdc = c.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteDC(hdc);
    const bitmap = c.CreateCompatibleBitmap(screen, 400, 800) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteObject(bitmap);
    const previous = c.SelectObject(hdc, bitmap);
    defer _ = c.SelectObject(hdc, previous);
    var draw_allocator = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(draw_allocator.deinit() == .ok);
    draw(hdc, &model, .project, null, "", 0, "", 800, "", "", &state, -1, draw_allocator.allocator());
}

fn manyLoopModel(allocator: std.mem.Allocator, loops: usize) !GraphModel.Model {
    var model = GraphModel.Model.init(allocator);
    errdefer model.deinit();
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);
    try frame.appendSlice(allocator, "{\"version\":2,\"kind\":\"event\",\"sequence\":1,\"event\":{\"graphChanged\":{\"project\":{\"path\":\"C:\\\\many-loops\",\"name\":\"Many loops\"},\"nodes\":[");
    for (0..loops) |index| {
        if (index != 0) try frame.append(allocator, ',');
        try frame.print(allocator, "{{\"id\":\"loop-{d}\",\"title\":\"Loop {d}\",\"loopType\":\"goalBased\",\"state\":\"stopped\"}}", .{ index, index });
    }
    try frame.appendSlice(allocator, "],\"edges\":[]}}}");
    _ = try model.updateFromFrame(frame.items);
    return model;
}

test "scrolled rows beneath the fixed GRAPH/Projects header are not hit" {
    const allocator = std.testing.allocator;
    var model = try manyLoopModel(allocator, 40);
    defer model.deinit();
    var state = State.init(allocator);
    defer state.deinit();
    const content_bottom = contentViewportBottom(500, false, false);
    const scroll: i32 = 150;

    var rows = try appendRows(allocator, &model, null, scroll, &state);
    defer rows.deinit(allocator);
    var under_header: usize = 0;
    for (rows.items) |row| {
        const y = row.top + 8;
        if (y >= Tokens.header_height and y < content_top) {
            under_header += 1;
            try std.testing.expect(rowAt(24, y, &model, null, scroll, content_bottom, &state) == null);
        }
    }
    try std.testing.expect(under_header >= 2);
}

test "scrolled rows are not drawn over the fixed GRAPH/Projects header" {
    const allocator = std.testing.allocator;
    var model = try manyLoopModel(allocator, 40);
    defer model.deinit();
    var state = State.init(allocator);
    defer state.deinit();
    const viewport_bottom: i32 = 500;
    const content_bottom = contentViewportBottom(viewport_bottom, false, false);
    const scroll: i32 = 150;

    const screen = c.GetDC(null) orelse return error.SkipZigTest;
    defer _ = c.ReleaseDC(null, screen);
    const hdc = c.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteDC(hdc);
    const bitmap = c.CreateCompatibleBitmap(screen, 400, viewport_bottom) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteObject(bitmap);
    const previous = c.SelectObject(hdc, bitmap);
    defer _ = c.SelectObject(hdc, previous);
    var draw_allocator = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(draw_allocator.deinit() == .ok);
    draw(hdc, &model, .project, null, "", scroll, "", viewport_bottom, "", "", &state, -1, draw_allocator.allocator());

    // The goalBased accent bar is only ever painted by loop rows.
    const accent: u32 = 0x00709E19;
    var accent_in_header: usize = 0;
    var accent_in_content: usize = 0;
    var y: i32 = Tokens.header_height;
    while (y < content_bottom) : (y += 1) {
        var x: i32 = 0;
        while (x < Tokens.sidebar_width) : (x += 1) {
            if (c.GetPixel(hdc, x, y) != accent) continue;
            if (y < content_top) accent_in_header += 1 else accent_in_content += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), accent_in_header);
    try std.testing.expect(accent_in_content > 30);
}

test "loop row title age and state indicator occupy disjoint columns and compound ages fit" {
    for (0..5) |depth| {
        const text = loopRowTextRects(100, depth);
        try std.testing.expect(text.title.left < text.title.right);
        try std.testing.expect(text.title.right <= text.age.left);
        try std.testing.expect(text.age.right < text.state.left);
        // Clear of the hover disclosure's hit zone and the sidebar rail edge.
        try std.testing.expect(text.state.right <= 198 and text.state.right <= Tokens.sidebar_width);
    }
    const screen = c.GetDC(null) orelse return error.SkipZigTest;
    defer _ = c.ReleaseDC(null, screen);
    const hdc = c.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteDC(hdc);
    const previous = c.SelectObject(hdc, AppFont.getStyle(10.5, .card_mono));
    defer _ = c.SelectObject(hdc, previous);
    const text = loopRowTextRects(100, 0);
    var widest_age: i32 = 0;
    for ([_][]const u8{ "-", "59s", "59m", "23h 59m", "99d 23h", "365d 23h", "999d 23h" }) |label| {
        const width = try measuredWidth(hdc, label);
        widest_age = @max(widest_age, width);
        try std.testing.expect(width <= text.age.right - text.age.left);
    }
    // Guard against vacuous measurements.
    try std.testing.expect(widest_age > 40);
}

fn measuredWidth(hdc: c.HDC, label: []const u8) !i32 {
    var wide: [64]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(hdc, &wide, @intCast(length), &size) == 0) return error.TestUnexpectedResult;
    return size.cx;
}

const SidebarIcon = enum { graph, local_folder, remote_folder, chat };

fn drawOutlineIcon(hdc: c.HDC, icon: SidebarIcon, bounds: c.RECT, color: u32) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, color) orelse return;
    const previous_pen = c.SelectObject(hdc, pen);
    const previous_brush = c.SelectObject(hdc, c.GetStockObject(c.HOLLOW_BRUSH));
    switch (icon) {
        .graph => {
            _ = c.MoveToEx(hdc, bounds.left + 4, bounds.top + 10, null);
            _ = c.LineTo(hdc, bounds.left + 8, bounds.top + 4);
            _ = c.LineTo(hdc, bounds.left + 12, bounds.top + 10);
            _ = c.MoveToEx(hdc, bounds.left + 4, bounds.top + 10, null);
            _ = c.LineTo(hdc, bounds.left + 12, bounds.top + 10);
            _ = c.Ellipse(hdc, bounds.left + 1, bounds.top + 7, bounds.left + 7, bounds.top + 13);
            _ = c.Ellipse(hdc, bounds.left + 5, bounds.top + 1, bounds.left + 11, bounds.top + 7);
            _ = c.Ellipse(hdc, bounds.left + 9, bounds.top + 7, bounds.left + 15, bounds.top + 13);
        },
        .local_folder => {
            _ = c.MoveToEx(hdc, bounds.left + 1, bounds.top + 4, null);
            _ = c.LineTo(hdc, bounds.left + 6, bounds.top + 4);
            _ = c.LineTo(hdc, bounds.left + 8, bounds.top + 6);
            _ = c.LineTo(hdc, bounds.right - 1, bounds.top + 6);
            _ = c.LineTo(hdc, bounds.right - 2, bounds.bottom - 1);
            _ = c.LineTo(hdc, bounds.left + 2, bounds.bottom - 1);
            _ = c.LineTo(hdc, bounds.left + 1, bounds.top + 4);
        },
        .remote_folder => {
            _ = c.MoveToEx(hdc, bounds.left + 8, bounds.top + 4, null);
            _ = c.LineTo(hdc, bounds.left + 8, bounds.top + 9);
            _ = c.MoveToEx(hdc, bounds.left + 3, bounds.top + 12, null);
            _ = c.LineTo(hdc, bounds.left + 3, bounds.top + 9);
            _ = c.LineTo(hdc, bounds.left + 13, bounds.top + 9);
            _ = c.LineTo(hdc, bounds.left + 13, bounds.top + 12);
            _ = c.Rectangle(hdc, bounds.left + 6, bounds.top + 1, bounds.left + 11, bounds.top + 6);
            _ = c.Rectangle(hdc, bounds.left + 1, bounds.top + 11, bounds.left + 6, bounds.top + 16);
            _ = c.Rectangle(hdc, bounds.left + 11, bounds.top + 11, bounds.left + 16, bounds.top + 16);
        },
        .chat => {
            _ = c.RoundRect(hdc, bounds.left + 1, bounds.top + 1, bounds.left + 12, bounds.top + 10, 4, 4);
            _ = c.MoveToEx(hdc, bounds.left + 4, bounds.top + 9, null);
            _ = c.LineTo(hdc, bounds.left + 2, bounds.top + 12);
            _ = c.RoundRect(hdc, bounds.left + 5, bounds.top + 5, bounds.right, bounds.top + 14, 4, 4);
            _ = c.MoveToEx(hdc, bounds.left + 12, bounds.top + 13, null);
            _ = c.LineTo(hdc, bounds.left + 14, bounds.bottom);
        },
    }
    _ = c.SelectObject(hdc, previous_brush);
    _ = c.SelectObject(hdc, previous_pen);
    _ = c.DeleteObject(pen);
}

fn drawPlusIcon(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, color) orelse return;
    const previous = c.SelectObject(hdc, pen);
    const x = @divTrunc(bounds.left + bounds.right, 2);
    const y = @divTrunc(bounds.top + bounds.bottom, 2);
    _ = c.MoveToEx(hdc, x - 4, y, null);
    _ = c.LineTo(hdc, x + 5, y);
    _ = c.MoveToEx(hdc, x, y - 4, null);
    _ = c.LineTo(hdc, x, y + 5);
    _ = c.SelectObject(hdc, previous);
    _ = c.DeleteObject(pen);
}

fn drawDisclosureIcon(hdc: c.HDC, bounds: c.RECT, collapsed: bool, color: u32) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, color) orelse return;
    const previous = c.SelectObject(hdc, pen);
    const x = @divTrunc(bounds.left + bounds.right, 2);
    const y = @divTrunc(bounds.top + bounds.bottom, 2);
    if (collapsed) {
        _ = c.MoveToEx(hdc, x - 2, y - 4, null);
        _ = c.LineTo(hdc, x + 2, y);
        _ = c.LineTo(hdc, x - 2, y + 4);
    } else {
        _ = c.MoveToEx(hdc, x - 4, y - 2, null);
        _ = c.LineTo(hdc, x, y + 2);
        _ = c.LineTo(hdc, x + 4, y - 2);
    }
    _ = c.SelectObject(hdc, previous);
    _ = c.DeleteObject(pen);
}

fn drawLoopStripe(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const brush = c.CreateSolidBrush(color) orelse {
        std.log.err("Sidebar loop stripe brush creation failed", .{});
        return;
    };
    defer _ = c.DeleteObject(brush);
    const middle = rect(bounds.left, bounds.top + 1, bounds.right, bounds.bottom - 1);
    const caps = rect(bounds.left + 1, bounds.top, bounds.right - 1, bounds.bottom);
    _ = c.FillRect(hdc, &middle, brush);
    _ = c.FillRect(hdc, &caps, brush);
}

fn drawStateIndicator(hdc: c.HDC, state: []const u8, bounds: c.RECT) void {
    // GraphModel has no exit-code/dependent metadata for the full macOS displayState.
    // Show the recorded state, rather than inventing a derived idle/failed state.
    const color: u32 = if (std.mem.eql(u8, state, "running") or std.mem.eql(u8, state, "waiting"))
        0x00FF840A
    else if (std.mem.eql(u8, state, "awaitingInput") or std.mem.eql(u8, state, "blocked"))
        0x000A9FFF
    else if (std.mem.eql(u8, state, "succeeded"))
        0x0058D130
    else if (std.mem.eql(u8, state, "failed"))
        0x003A45FF
    else if (std.mem.eql(u8, state, "stalled"))
        0x00F25ABF
    else
        0x006F6C6C;
    const hollow = std.mem.eql(u8, state, "blocked") or std.mem.eql(u8, state, "stopped") or std.mem.eql(u8, state, "waiting");
    const pen = c.CreatePen(c.PS_SOLID, if (hollow) 2 else 1, color) orelse {
        std.log.err("Sidebar state indicator pen creation failed", .{});
        return;
    };
    defer _ = c.DeleteObject(pen);
    const brush = if (hollow) null else c.CreateSolidBrush(color) orelse {
        std.log.err("Sidebar state indicator brush creation failed", .{});
        return;
    };
    defer {
        if (brush != null) _ = c.DeleteObject(brush);
    }
    const previous_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, previous_pen);
    const previous_brush = c.SelectObject(hdc, if (hollow) c.GetStockObject(c.HOLLOW_BRUSH) else brush);
    defer _ = c.SelectObject(hdc, previous_brush);
    _ = c.Ellipse(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom);
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
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch |err| {
        std.log.err("Sidebar text conversion failed: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(wide);
    if (wide.len == 0) return;
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
    drawStyledTextRect(hdc, allocator, text, bounds_value, @floatFromInt(size), .regular, color, format);
}

fn drawStyledTextRect(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    text: []const u8,
    bounds_value: c.RECT,
    size: f32,
    style: AppFont.Style,
    color: u32,
    format: c.UINT,
) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch |err| {
        std.log.err("Sidebar text conversion failed: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(wide);
    if (wide.len == 0) return;
    const old_font = c.SelectObject(hdc, AppFont.getStyle(size, style));
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, format);
    _ = c.SelectObject(hdc, old_font);
}
