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
    collapsed_nodes: std.StringHashMapUnmanaged(void) = .empty,
    root_order: std.ArrayListUnmanaged([]u8) = .empty,
    selection: Selection = .none,
    workspace_name: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        freeSet(self.allocator, &self.collapsed_projects);
        freeSet(self.allocator, &self.collapsed_nodes);
        for (self.root_order.items) |id| self.allocator.free(id);
        self.root_order.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn toggleProject(self: *State, path: []const u8) !void {
        try toggleSet(self.allocator, &self.collapsed_projects, path);
    }

    pub fn toggleNode(self: *State, id: []const u8) !void {
        try toggleSet(self.allocator, &self.collapsed_nodes, id);
    }

    pub fn isProjectCollapsed(self: *const State, path: []const u8) bool {
        return self.collapsed_projects.contains(path);
    }

    pub fn isNodeExpanded(self: *const State, id: []const u8) bool {
        return !self.collapsed_nodes.contains(id);
    }

    pub fn clearExpandedNodes(self: *State) void {
        freeSet(self.allocator, &self.collapsed_nodes);
        self.collapsed_nodes = .empty;
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
        var iterator = self.collapsed_nodes.keyIterator();
        while (iterator.next()) |id| try result.writer(allocator).print("collapsed\t{s}\n", .{id.*});
        for (self.root_order.items) |id| try result.writer(allocator).print("root\t{s}\n", .{id});
        return result.toOwnedSlice(allocator);
    }

    pub fn decode(self: *State, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            // Legacy files only recorded expanded nodes; unrecorded nodes now start expanded.
            if (!std.mem.startsWith(u8, line, "collapsed\t")) continue;
            const id = line["collapsed\t".len..];
            if (id.len != 0 and !self.collapsed_nodes.contains(id))
                try self.collapsed_nodes.put(self.allocator, try self.allocator.dupe(u8, id), {});
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
    _ = status;
    const sidebar = rect(0, Tokens.header_height, Tokens.sidebar_width, viewport_bottom);
    fill(hdc, sidebar, Tokens.workspace_rail);
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
        const ink: u32 = 0x00E6E6E6;
        const selected = rowSelected(row, model, state.selection);
        if (selected) roundedFill(hdc, rowBounds(row.top), selection_blue, 8);
        switch (row.kind) {
            .local_heading => {
                drawTextRect(hdc, allocator, "Local Projects", rect(18, row.top, Tokens.sidebar_width - 14, row.top + row_height), 11, 0x00909090, loop_text_format | c.DT_VCENTER);
                if (hover_y >= row.top and hover_y < row.top + row_height)
                    drawChevron(hdc, 207, row.top + 16, !state.local_collapsed, 0x00909090);
            },
            .remote_heading => {
                drawTextRect(hdc, allocator, "Remote Repositories", rect(18, row.top, Tokens.sidebar_width - 14, row.top + row_height), 11, 0x00909090, loop_text_format | c.DT_VCENTER);
                if (hover_y >= row.top and hover_y < row.top + row_height)
                    drawChevron(hdc, 207, row.top + 16, !state.remote_collapsed, 0x00909090);
            },
            .project => {
                const project = model.recent_projects.items[row.index];
                drawIcon(hdc, if (project.isRemote()) .network else .folder, 18, row.top + 9, ink);
                drawTextRect(hdc, allocator, project.name, projectTitleRect(row.top), 13, ink, loop_text_format | c.DT_VCENTER);
            },
            .overview => {
                drawIcon(hdc, .graph, 18, row.top + 9, ink);
                drawTextRect(hdc, allocator, "Graph", projectTitleRect(row.top), 13, ink, loop_text_format | c.DT_VCENTER);
            },
            .open_project => if (row.project_path) |path| {
                const project = projectForRow(model, path) orelse continue;
                drawIcon(hdc, if (project.isRemote()) .network else .folder, 18, row.top + 9, ink);
                drawTextRect(hdc, allocator, project.name, projectTitleRect(row.top), 13, ink, loop_text_format | c.DT_VCENTER);
                if (hover_y >= row.top and hover_y < row.top + row_height) {
                    drawPlus(hdc, 184, row.top + 16, ink);
                    if (row.has_children) drawChevron(hdc, 207, row.top + 16, !state.isProjectCollapsed(path), ink);
                }
            },
            .loop => if (row.project_path) |path| if (model.graphFor(path)) |summary| {
                if (row.index < summary.nodes.items.len) {
                    const node = summary.nodes.items[row.index];
                    const indent = @as(i32, @intCast(@min(row.depth, max_visual_depth))) * 16;
                    roundedFill(hdc, rect(34 + indent, row.top + 9, 37 + indent, row.top + 23), loopAccent(node.loop_type), 3);
                    const text = loopRowTextRects(row.top, row.depth);
                    drawTextRect(hdc, allocator, node.title, text.title, 13, ink, loop_text_format | c.DT_VCENTER);
                    drawStateDot(hdc, text.state, displayState(node));
                    const elapsed = elapsedText(allocator, @intCast(node.created_at orelse 0), std.time.timestamp()) catch null;
                    defer if (elapsed) |value| allocator.free(value);
                    if (elapsed) |value| drawTextRect(hdc, allocator, value, text.age, 10, 0x008E8E93, loop_text_format | c.DT_RIGHT | c.DT_VCENTER);
                    if (row.has_children) drawChevron(hdc, 207, row.top + 16, state.isNodeExpanded(node.id), 0x007A7A7A);
                }
            },
            .worktree => if (inspection) |value| {
                const entry = value.entries.items[row.index];
                const worktree_selected = std.mem.eql(u8, entry.path, selected_worktree_path);
                if (worktree_selected and WorktreeStatus.decision(entry) == .reclaimable)
                    fill(hdc, rect(12, row.top - 3, Tokens.sidebar_width - 12, row.top + 25), 0x003A3A44);
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
                drawIcon(hdc, .chats, 18, row.top + 9, ink);
                drawTextRect(hdc, allocator, "Quick Chats", projectTitleRect(row.top), 13, ink, loop_text_format | c.DT_VCENTER);
                if (hover_y >= row.top and hover_y < row.top + row_height) {
                    drawPlus(hdc, 184, row.top + 16, ink);
                    if (model.quick_chats.items.len != 0)
                        drawChevron(hdc, 207, row.top + 16, !state.chats_collapsed, ink);
                }
            },
            .quick_chat => if (row.index < model.quick_chats.items.len)
                drawTextRect(hdc, allocator, model.quick_chats.items[row.index].title, rect(34, row.top, Tokens.sidebar_width - 14, row.top + row_height), 13, ink, loop_text_format | c.DT_VCENTER),
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
    if (state.workspace_name.len != 0) {
        const workspace = workspaceFooterRect(viewport_bottom);
        fill(hdc, workspace, 0x00282624);
        fill(hdc, rect(workspace.left, workspace.top, workspace.right, workspace.top + 1), 0x00454341);
        drawIcon(hdc, .workspace, 18, workspace.top + 9, 0x00909090);
        drawTextRect(hdc, allocator, state.workspace_name, rect(40, workspace.top, Tokens.sidebar_width - 28, workspace.bottom), 13, 0x00D0D0D0, loop_text_format | c.DT_VCENTER);
        const x = Tokens.sidebar_width - 16;
        stroke(hdc, &.{ .{ .x = x - 3, .y = workspace.top + 14 }, .{ .x = x, .y = workspace.top + 11 }, .{ .x = x + 3, .y = workspace.top + 14 } }, 0x00909090);
        drawChevron(hdc, x, workspace.top + 20, true, 0x00909090);
    }
}

const loop_text_format: c.UINT = c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX;
pub const row_height: i32 = 32;
const max_visual_depth: usize = 3;
pub const selection_blue: u32 = 0x00D15900;
pub const Selection = union(enum) { none, overview, quick_chats, project: []const u8, loop: []const u8, chat: []const u8 };

pub fn selectionForSurface(model: *const GraphModel.Model, surface: anytype, quick_chat: bool, chat_index: ?usize, worktree_project: ?[]const u8) Selection {
    return switch (surface) {
        .overview => if (worktree_project) |path| .{ .project = path } else .overview,
        .quick_chats => .quick_chats,
        .project => if (model.selected_project_path) |path| .{ .project = path } else .none,
        .workspace => if (quick_chat) blk: {
            const index = chat_index orelse break :blk .none;
            break :blk if (index < model.quick_chats.items.len) .{ .chat = model.quick_chats.items[index].id } else .none;
        } else if (model.selected_node_id) |id| .{ .loop = id } else .none,
    };
}

const loop_age_right: i32 = 188;
const loop_age_width: i32 = 24;
const loop_text_gap: i32 = 4;

pub const LoopRowText = struct { title: c.RECT, state: c.RECT, age: c.RECT };

/// Reserve age, state dot, and disclosure before giving the rest to the indented title.
pub fn loopRowTextRects(row_top: i32, depth: usize) LoopRowText {
    const indent = @as(i32, @intCast(@min(depth, max_visual_depth))) * 16;
    const age = rect(loop_age_right - loop_age_width, row_top, loop_age_right, row_top + row_height);
    const state = rect(190, row_top + 12, 197, row_top + 19);
    const title_left = 44 + indent;
    return .{ .title = rect(title_left, row_top, age.left - loop_text_gap, row_top + row_height), .state = state, .age = age };
}

pub const content_top: i32 = Tokens.header_height + 12;

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

pub fn rowBounds(top: i32) c.RECT {
    return rect(10, top, Tokens.sidebar_width - 8, top + row_height);
}

pub fn workspaceFooterRect(viewport_bottom: i32) c.RECT {
    return rect(0, @max(Tokens.header_height, viewport_bottom - 34), Tokens.sidebar_width, viewport_bottom);
}

pub fn workspaceName(path: []const u8) []const u8 {
    const base = std.fs.path.basenameWindows(path);
    if (std.mem.startsWith(u8, base, ".graphcode-")) return base[".graphcode-".len..];
    if (base.len == 0 or std.mem.eql(u8, base, ".graphcode")) return "Default";
    return base;
}

pub fn workspaceWorthShowing(path: []const u8, known_count: usize) bool {
    const base = std.fs.path.basenameWindows(path);
    return (base.len != 0 and !std.mem.eql(u8, base, ".graphcode")) or known_count > 1;
}

pub fn workspaceFooterAt(x: i32, y: i32, viewport_bottom: i32) bool {
    const bounds = workspaceFooterRect(viewport_bottom);
    return x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom;
}

fn projectTitleRect(top: i32) c.RECT {
    return rect(42, top, 174, top + row_height);
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
    if (std.mem.eql(u8, loop_type, "composite") or std.mem.eql(u8, loop_type, "proactive")) return 0x00E98590;
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
    if (seconds < 86400) return std.fmt.allocPrint(allocator, "{d}h", .{@divTrunc(seconds, 3600)});
    return std.fmt.allocPrint(allocator, "{d}d", .{@divTrunc(seconds, 86400)});
}

pub fn loopRowTop(project_count: usize, index: usize) i32 {
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = 0, .worktree_count = 0 };
    return layout.loopTop(index);
}

pub fn loopRowTopForModel(model: *const GraphModel.Model, index: usize, inspection: ?*const WorktreeStatus.Inspection, state: *const State) !?i32 {
    const graph = model.currentGraph() orelse return null;
    var rows = try appendRows(model.allocator, model, inspection, 0, state);
    defer rows.deinit(model.allocator);
    var parent_top: ?i32 = null;
    for (rows.items) |row| {
        if (row.kind == .loop and row.index == index and row.project_path != null and std.mem.eql(u8, row.project_path.?, graph.project.path)) return row.top;
        if (row.kind == .open_project and row.project_path != null and std.mem.eql(u8, row.project_path.?, graph.project.path)) {
            parent_top = row.top;
        } else if (parent_top == null and
            (row.kind == .overview and graph.project.isGlobal() or
                row.kind == .local_heading and !graph.project.isRemote() or
                row.kind == .remote_heading and graph.project.isRemote()))
        {
            parent_top = row.top;
        }
    }
    return parent_top;
}

pub fn worktreeRowTop(project_count: usize, loop_count: usize, index: usize) i32 {
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = loop_count, .worktree_count = 0 };
    return layout.worktreeTop(index);
}

pub fn worktreeRowTopForModel(model: *const GraphModel.Model, inspection: *const WorktreeStatus.Inspection, index: usize, state: *const State) !?i32 {
    var rows = try appendRows(model.allocator, model, inspection, 0, state);
    defer rows.deinit(model.allocator);
    for (rows.items) |row| if (row.kind == .worktree and row.index == index) return row.top;
    return null;
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
        return self.base;
    }
    pub fn loopTop(self: Layout, index: usize) i32 {
        return self.base + 12 + @as(i32, @intCast(3 + self.quick_chat_count + self.project_count + self.project_heading_count + index)) * row_height;
    }
    pub fn worktreeTop(self: Layout, index: usize) i32 {
        return self.base + self.projectSectionHeight() + 140 +
            @as(i32, @intCast(self.loop_count * 24)) +
            @as(i32, @intCast(index * 34));
    }
    pub fn quickChatHeadingTop(self: Layout) i32 {
        return self.quickChatRowTop(0);
    }
    pub fn quickChatRowTop(self: Layout, index: usize) i32 {
        return self.base + @as(i32, @intCast(1 + index)) * row_height;
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
    errdefer rows.deinit(allocator);
    var top: i32 = content_top - scroll_offset;
    const local_collapsed = if (state) |value| value.local_collapsed else false;
    const remote_collapsed = if (state) |value| value.remote_collapsed else false;
    const chats_collapsed = if (state) |value| value.chats_collapsed else false;
    try rows.append(allocator, .{ .kind = .overview, .index = 0, .top = top });
    top += row_height;
    if (model.graphFor("graphcode://global")) |graph|
        try appendLoopRows(allocator, &rows, graph, &top, state);
    try rows.append(allocator, .{ .kind = .quick_chat_overview, .index = 0, .top = top });
    top += row_height;
    if (!chats_collapsed) {
        for (model.quick_chats.items, 0..) |_, index| {
            try rows.append(allocator, .{ .kind = .quick_chat, .index = index, .top = top });
            top += row_height;
        }
    }
    if (hasLocalProjects(model)) try appendProjectSection(allocator, &rows, model, &top, state, .local, local_collapsed);
    if (hasRemoteProjects(model)) try appendProjectSection(allocator, &rows, model, &top, state, .remote, remote_collapsed);
    if (inspection) |value| {
        top += 24;
        for (value.entries.items, 0..) |_, index| {
            try rows.append(allocator, .{ .kind = .worktree, .index = index, .top = top });
            top += 34;
        }
    }
    return rows;
}

fn appendProjectSection(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), model: *const GraphModel.Model, top: *i32, state: ?*const State, section: ProjectSection, collapsed: bool) !void {
    top.* += 12;
    try rows.append(allocator, .{ .kind = if (section == .local) .local_heading else .remote_heading, .index = 0, .top = top.* });
    top.* += row_height;
    if (collapsed) return;
    for (model.recent_projects.items, 0..) |project, index| {
        if (!projectIsVisibleInSection(model, project, section) or project.isGlobal()) continue;
        try rows.append(allocator, .{ .kind = .project, .index = index, .top = top.*, .project_path = project.path });
        top.* += row_height;
    }
    for (model.open_projects.items, 0..) |project, index| {
        if (hasGraphForProject(model, project.path) or project.isGlobal() or project.isRemote() != (section == .remote)) continue;
        try rows.append(allocator, .{ .kind = .open_project, .index = index, .top = top.*, .project_path = project.path });
        top.* += row_height;
    }
    if (model.graphs.items.len != 0) {
        for (model.graphs.items, 0..) |graph, index| {
            if (graph.project.isGlobal() or graph.project.isRemote() != (section == .remote)) continue;
            try rows.append(allocator, .{ .kind = .open_project, .index = index, .top = top.*, .project_path = graph.project.path, .has_children = graph.nodes.items.len != 0 });
            top.* += row_height;
            try appendLoopRows(allocator, rows, graph, top, state);
        }
    } else if (model.graph) |graph| {
        if (graph.project.isGlobal() or graph.project.isRemote() != (section == .remote)) return;
        try rows.append(allocator, .{ .kind = .open_project, .index = 0, .top = top.*, .project_path = graph.project.path, .has_children = graph.nodes.items.len != 0 });
        top.* += row_height;
        try appendLoopRows(allocator, rows, graph, top, state);
    }
}

fn appendLoopRows(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), graph: anytype, top: *i32, state: ?*const State) !void {
    if (state) |value| if (value.isProjectCollapsed(graph.project.path)) return;
    var hierarchy = try hierarchyItems(allocator, graph.nodes.items, graph.edges.items, state);
    defer hierarchy.deinit(allocator);
    for (hierarchy.items) |item| {
        try rows.append(allocator, .{ .kind = .loop, .index = item.index, .top = top.*, .project_path = graph.project.path, .depth = item.depth, .has_children = item.has_children });
        top.* += row_height;
    }
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
        .base = content_top,
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
    if (graph_index >= model.graphs.items.len) return content_top;
    return generatedRowTop(model, .open_project, model.graphs.items[graph_index].project.path, 0);
}

pub fn sharedLoopTop(model: *const GraphModel.Model, graph_index: usize, node_index: usize) i32 {
    if (graph_index >= model.graphs.items.len) return content_top;
    const graph = model.graphs.items[graph_index];
    return generatedRowTop(model, .loop, graph.project.path, node_index);
}

fn generatedRowTop(model: *const GraphModel.Model, kind: RowKind, path: []const u8, index: usize) i32 {
    var rows = appendRows(std.heap.page_allocator, model, null, 0, null) catch return content_top;
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| {
        if (row.kind == kind and (kind != .loop or row.index == index) and row.project_path != null and std.mem.eql(u8, row.project_path.?, path)) return row.top;
    }
    return content_top;
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
    if (x < 0 or x >= Tokens.sidebar_width or y < content_top or y >= viewport_bottom) return null;
    var rows = appendRows(std.heap.page_allocator, model, inspection, scroll_offset, state) catch return null;
    defer rows.deinit(std.heap.page_allocator);
    for (rows.items) |row| {
        const height: i32 = switch (row.kind) {
            .local_heading, .remote_heading, .project, .open_project, .overview, .loop, .quick_chat_overview, .quick_chat => row_height,
            .worktree => 34,
        };
        if (y >= row.top and y < row.top + height) return row;
    }
    return null;
}

fn hasLocalProjects(model: *const GraphModel.Model) bool {
    return hasProjectsInSection(model, .local);
}

fn hasRemoteProjects(model: *const GraphModel.Model) bool {
    return hasProjectsInSection(model, .remote);
}

fn hasProjectsInSection(model: *const GraphModel.Model, section: ProjectSection) bool {
    for (model.recent_projects.items) |project| if (!project.isGlobal() and project.isRemote() == (section == .remote)) return true;
    for (model.open_projects.items) |project| if (!project.isGlobal() and project.isRemote() == (section == .remote)) return true;
    for (model.graphs.items) |graph| if (!graph.project.isGlobal() and graph.project.isRemote() == (section == .remote)) return true;
    if (model.graph) |graph| if (!graph.project.isGlobal() and graph.project.isRemote() == (section == .remote)) return true;
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
    const reachable = try allocator.alloc(bool, nodes.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var roots = try collectRootIndices(allocator, nodes, edges, state, false, visited);
    defer roots.deinit(allocator);
    for (roots.items) |index| {
        reachable[index] = true;
        markDescendantsVisited(reachable, nodes, edges, index);
        try appendHierarchy(allocator, &result, visited, nodes, edges, index, 0, state);
    }
    var unresolved = try collectRootIndices(allocator, nodes, edges, state, true, reachable);
    defer unresolved.deinit(allocator);
    for (unresolved.items) |index| if (!reachable[index]) {
        reachable[index] = true;
        markDescendantsVisited(reachable, nodes, edges, index);
        try appendHierarchy(allocator, &result, visited, nodes, edges, index, 0, state);
    };
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
            if (std.mem.eql(u8, edge.to, node.id) and GraphModel.findNodeIndexByID(nodes, edge.from) != null) {
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
        if (std.mem.eql(u8, edge.from, nodes[index].id) and
            GraphModel.findNodeIndexByID(nodes, edge.to) != null)
        {
            has_children = true;
            break;
        }
    }
    try result.append(allocator, .{ .index = index, .depth = depth, .has_children = has_children });
    if (depth != 0 or has_children) {
        if (state) |value| if (!value.isNodeExpanded(nodes[index].id)) return;
    }
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.from, nodes[index].id)) continue;
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
        if (!std.mem.eql(u8, edge.from, nodes[index].id)) continue;
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
    return last.top + (if (last.kind == .worktree) @as(i32, 34) else row_height);
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

pub fn hitTestWorktree(x: i32, y: i32, project_count: usize, count: usize, scroll_offset: i32, viewport_bottom: i32) ?usize {
    if (x < 12 or x >= Tokens.sidebar_width) return null;
    if (y < content_top or y >= viewport_bottom) return null;
    const layout = Layout{ .base = Tokens.header_height + 78, .project_count = project_count, .loop_count = 0, .worktree_count = 0 };
    const top = layout.worktreeTop(0) - scroll_offset;
    if (y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 34));
    if (index >= count) return null;
    return index;
}

pub fn hitTestProject(x: i32, y: i32, model: *const GraphModel.Model, scroll_offset: i32, viewport_bottom: i32) ?usize {
    if (x < 0 or x >= Tokens.sidebar_width or y < content_top or y >= viewport_bottom) return null;
    const top = Tokens.header_height + 78 - scroll_offset;
    if (y < top) return null;
    const index: usize = @intCast(@divTrunc(y - top, 24));
    if (index >= model.recent_projects.items.len) return null;
    return index;
}

pub fn hitTestOverviewLoop(x: i32, y: i32, model: *const GraphModel.Model, scroll_offset: i32, viewport_bottom: i32) ?usize {
    if (x < 0 or x >= Tokens.sidebar_width or y < content_top or y >= viewport_bottom) return null;
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

test "parity sidebar pins Graph and Quick Chats above captioned open folders" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\fixture","name":"Fixture"},"nodes":[{"id":"root","title":"Root","state":"idle"}],"edges":[]}}}
    );
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = @constCast("main"),
        .project_path = @constCast("C:\\fixture"),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{ .path = @constCast("C:\\fixture\\wt"), .branch = @constCast("topic") });
    var rows = try appendRows(allocator, &model, &inspection, 0, null);
    defer rows.deinit(allocator);
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.quick_chat_overview, rows.items[1].kind);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.open_project, rows.items[3].kind);
    try std.testing.expectEqual(@as(usize, 1), countRows(rows.items, .worktree));
}

test "parity sidebar expands the whole mixed-edge tree by default without duplicating a cycle" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\fixture","name":"Fixture"},"nodes":[{"id":"root","title":"Main","state":"idle"},{"id":"goal","title":"Goal","state":"awaitingInput"},{"id":"turn","title":"Turn","state":"idle"},{"id":"timed","title":"Timed","state":"stopped"}],"edges":[{"id":"a","from":"root","to":"goal","kind":"spawn"},{"id":"b","from":"goal","to":"turn","kind":"handoff"},{"id":"c","from":"turn","to":"timed","kind":"message"},{"id":"d","from":"turn","to":"goal","kind":"handoff"}]}}}
    );
    var state = State.init(allocator);
    defer state.deinit();
    var rows = try appendRows(allocator, &model, null, 0, &state);
    defer rows.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), countRows(rows.items, .loop));
    var depth: usize = 0;
    for (rows.items) |row| if (row.kind == .loop) {
        try std.testing.expectEqual(depth, row.depth);
        depth += 1;
    };
}

test "parity sidebar type stripes use macOS RGB converted to COLORREF" {
    try std.testing.expectEqual(@as(u32, 0x00E3DAD3), loopAccent("sketch"));
    try std.testing.expectEqual(@as(u32, 0x00709E19), loopAccent("goalBased"));
    try std.testing.expectEqual(@as(u32, 0x008151D5), loopAccent("turnBased"));
    try std.testing.expectEqual(@as(u32, 0x000085C9), loopAccent("timeBased"));
    try std.testing.expectEqual(@as(u32, 0x00E98590), loopAccent("composite"));
    try std.testing.expectEqual(@as(u32, 0x00E98590), loopAccent("proactive"));
}

test "parity sidebar diamond child remains visible under its expanded parent" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("a"), .title = @constCast("A"), .loop_type = @constCast("sketch"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("b"), .title = @constCast("B"), .loop_type = @constCast("sketch"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("c"), .title = @constCast("Shared"), .loop_type = @constCast("sketch"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("d"), .title = @constCast("Hidden"), .loop_type = @constCast("sketch"), .state = @constCast("idle"), .activity = @constCast(""), .presence = @constCast("idle") },
    };
    const edges = [_]GraphModel.Edge{
        .{ .from = @constCast("a"), .to = @constCast("c"), .kind = @constCast("spawn") },
        .{ .from = @constCast("b"), .to = @constCast("c"), .kind = @constCast("message") },
        .{ .from = @constCast("a"), .to = @constCast("d"), .kind = @constCast("handoff") },
    };
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.toggleNode("a");
    var hierarchy = try hierarchyItems(std.testing.allocator, &nodes, &edges, &state);
    defer hierarchy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), hierarchy.items.len);
    try std.testing.expectEqual(@as(usize, 2), hierarchy.items[2].index);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.items[2].depth);
    for (hierarchy.items) |row| try std.testing.expect(row.index != 3);
}

test "parity jump scroll target follows expanded rows and falls back to the folded project" {
    const allocator = std.testing.allocator;
    var model = try manyLoopModel(allocator, 30);
    defer model.deinit();
    var state = State.init(allocator);
    defer state.deinit();
    for ([_]bool{ false, true }) |folded| {
        if (folded) try state.toggleProject("C:\\many-loops");
        var rows = try appendRows(allocator, &model, null, 0, &state);
        defer rows.deinit(allocator);
        const expected = for (rows.items) |row| {
            if ((!folded and row.kind == .loop and row.index == 29) or (folded and row.kind == .open_project)) break row.top;
        } else return error.TestExpectedJumpTarget;
        const target = try loopRowTopForModel(&model, 29, null, &state) orelse return error.TestExpectedJumpTarget;
        try std.testing.expectEqual(expected, target);
        const bottom = contentViewportBottom(400, false, false);
        const scroll = clampScroll(target - content_top, maxScroll(&model, null, bottom, &state));
        try std.testing.expect(target - scroll >= content_top);
        try std.testing.expect(target - scroll + row_height <= bottom);
    }
}

test "parity sidebar deeply indented titles keep useful space alongside age and state dot" {
    const text = loopRowTextRects(100, 3);
    try std.testing.expect(text.title.right - text.title.left >= 64);
    try std.testing.expect(text.title.right <= text.age.left);
    try std.testing.expect(text.age.right <= 198);
}

test "parity sidebar selection is a rounded blue pill and the workspace footer never overlaps content" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    var state = State.init(allocator);
    defer state.deinit();
    state.selection = .quick_chats;
    state.workspace_name = workspaceName("C:\\fixture\\.graphcode-parityref");
    try std.testing.expectEqualStrings("parityref", state.workspace_name);
    const screen = c.GetDC(null) orelse return error.SkipZigTest;
    defer _ = c.ReleaseDC(null, screen);
    const hdc = c.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteDC(hdc);
    const bitmap = c.CreateCompatibleBitmap(screen, Tokens.sidebar_width, 700) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteObject(bitmap);
    const previous = c.SelectObject(hdc, bitmap);
    defer _ = c.SelectObject(hdc, previous);
    draw(hdc, &model, null, "", 0, "Status must not cover the footer", 700, "", "", &state, -1, allocator);
    const top = content_top + row_height;
    try std.testing.expectEqual(selection_blue, c.GetPixel(hdc, 60, top + 2));
    try std.testing.expectEqual(@as(u32, Tokens.workspace_rail), c.GetPixel(hdc, rowBounds(top).left, top));
    try std.testing.expectEqual(@as(u32, Tokens.workspace_rail), c.GetPixel(hdc, 60, content_top + 2));
    const footer = workspaceFooterRect(700);
    try std.testing.expect(contentViewportBottom(700, false, false) <= footer.top);
    try std.testing.expect(workspaceFooterAt(18, footer.top + 12, 700));
    try std.testing.expect(!workspaceFooterAt(18, footer.top - 1, 700));
    try std.testing.expect(rowAt(18, footer.top + 12, &model, null, 0, contentViewportBottom(700, false, false), &state) == null);
}

test "parity sidebar state dots distinguish presence and hollow stopped blocked waiting states" {
    const node = GraphModel.Node{ .id = @constCast("a"), .title = @constCast("A"), .loop_type = @constCast("goalBased"), .state = @constCast("running"), .activity = @constCast(""), .presence = @constCast("awaitingInput") };
    try std.testing.expectEqualStrings("awaitingInput", displayState(node));
    try std.testing.expectEqual(@as(u32, 0x000A9FFF), dotColor(displayState(node)));
    try std.testing.expectEqual(@as(u32, 0x0058D130), dotColor("succeeded"));
    for ([_][]const u8{ "blocked", "stopped", "waiting" }) |value| try std.testing.expect(dotHollow(value));
    for ([_][]const u8{ "idle", "running", "awaitingInput", "succeeded", "failed", "stalled" }) |value| try std.testing.expect(!dotHollow(value));
}

test "parity sidebar workspace switcher only shows when it disambiguates the workspace" {
    try std.testing.expect(!workspaceWorthShowing("C:\\fixture\\.graphcode", 1));
    try std.testing.expect(workspaceWorthShowing("C:\\fixture\\.graphcode", 2));
    try std.testing.expect(workspaceWorthShowing("C:\\fixture\\.graphcode-parityref", 1));
    try std.testing.expectEqualStrings("Default", workspaceName("C:\\fixture\\.graphcode"));
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
    try std.testing.expectEqual(remote_top + row_height, sidebarSectionBottom(&model, null, null));
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

test "sidebar without graph counts only static rendered content" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "project"),
        .name = try std.testing.allocator.dupe(u8, "Project"),
    });
    const no_graph_max = maxScroll(&model, null, 100, null);
    try std.testing.expectEqual(@as(i32, content_top + 4 * row_height + 12 - 100), no_graph_max);
    try std.testing.expectEqual(no_graph_max, clampScroll(180, no_graph_max));
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
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.quick_chat_overview, rows.items[1].kind);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[3].kind);
    try std.testing.expectEqual(@as(usize, 1), rows.items[3].index);
    try std.testing.expectEqual(RowKind.remote_heading, rows.items[4].kind);
    try std.testing.expectEqual(@as(usize, 0), rows.items[5].index);
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
    try std.testing.expectEqual(RowKind.overview, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.quick_chat_overview, rows.items[1].kind);
    try std.testing.expectEqual(RowKind.local_heading, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[3].kind);
    try std.testing.expectEqualStrings("C:\\recent", rows.items[3].project_path.?);
    try std.testing.expectEqual(RowKind.open_project, rows.items[4].kind);
    try std.testing.expectEqualStrings("C:\\open", rows.items[4].project_path.?);
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

test "message and spawn edges define sidebar hierarchy as on macOS" {
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
    try std.testing.expect(hierarchy.items[0].has_children);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.items[1].depth);
    try std.testing.expect(hierarchy.items[1].has_children);
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
    try std.testing.expectEqual(RowKind.local_heading, rows.items[2].kind);
    try std.testing.expectEqual(RowKind.remote_heading, rows.items[3].kind);
    try std.testing.expectEqual(RowKind.project, rows.items[4].kind);
    try std.testing.expectEqual(@as(usize, 1), rows.items[4].index);

    try state.toggleNode("root");
    const encoded = try state.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var restored = State.init(std.testing.allocator);
    defer restored.deinit();
    try restored.decode(encoded);
    try std.testing.expect(!restored.isNodeExpanded("root"));
    try restored.toggleNode("root");
    try std.testing.expect(restored.isNodeExpanded("root"));
}

test "daemon hierarchy starts expanded and hides children by stable id on request" {
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
    try std.testing.expectEqual(@as(usize, 2), countRows(collapsed.items, .loop));
    try state.toggleNode("root");
    var expanded = try appendRows(std.testing.allocator, &model, null, 0, &state);
    defer expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), countRows(expanded.items, .loop));
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
    try std.testing.expectEqual(layout.quickChatHeadingTop(), layout.quickChatRowTop(0));
    const overview = rowAt(24, layout.quickChatRowTop(0) + 4, &model, null, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat_overview, overview.kind);
    const row = rowAt(24, layout.quickChatRowTop(1) + 4, &model, null, 0, 700, null) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(RowKind.quick_chat, row.kind);
    try std.testing.expectEqual(@as(usize, 0), row.index);
    try std.testing.expectEqual(
        @as(i32, content_top + row_height),
        layout.quickChatRowTop(0),
    );
    try std.testing.expect(rowAt(24, layout.quickChatHeadingTop() + 4, &model, null, 0, 700, null).?.kind == .quick_chat_overview);
    try std.testing.expectEqual(layout.quickChatRowTop(2), sidebarSectionBottom(&model, null, null));
}

test "quick chat heading and rows stay distinct across graph layouts" {
    const layouts = [_]Layout{
        .{ .base = 100, .project_count = 2, .loop_count = 0, .worktree_count = 0, .graph_present = false },
        .{ .base = 100, .project_count = 2, .loop_count = 3, .worktree_count = 0 },
        .{ .base = 100, .project_count = 2, .loop_count = 3, .worktree_count = 4, .inspection_present = true },
    };
    for (layouts) |layout| {
        try std.testing.expectEqual(layout.quickChatHeadingTop(), layout.quickChatRowTop(0));
        try std.testing.expectEqual(row_height, layout.quickChatRowTop(1) - layout.quickChatRowTop(0));
    }
}

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

test "sidebar footer reserve keeps content workspace bar banner and error footer disjoint" {
    for ([_]bool{ false, true }) |has_update| for ([_]bool{ false, true }) |has_error| for ([_]i32{ 420, 522, 772 }) |viewport_bottom| {
        const content_bottom = contentViewportBottom(viewport_bottom, has_update, has_error);
        const workspace = workspaceFooterRect(viewport_bottom);
        try std.testing.expect(content_bottom <= workspace.top);
        try std.testing.expectEqual(rect(0, viewport_bottom - 34, Tokens.sidebar_width, viewport_bottom), workspace);
        if (has_update) {
            const banner = updateBannerRect(viewport_bottom, has_error);
            try std.testing.expect(content_bottom <= banner.top);
            try std.testing.expect(banner.bottom <= workspace.top);
        }
        if (has_error) {
            const footer = errorFooterRect(viewport_bottom);
            try std.testing.expect(content_bottom <= footer.top);
            try std.testing.expect(footer.bottom <= workspace.top);
            if (has_update) try std.testing.expect(updateBannerRect(viewport_bottom, true).bottom <= footer.top);
        }
    };
    // A viewport too short for the footer still leaves a well-formed, header-anchored content rect.
    try std.testing.expectEqual(@as(i32, Tokens.header_height), contentViewportBottom(100, true, true));
}

test "sidebar rows beneath the update banner are neither hit nor counted as visible" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    for (0..12) |index| try model.recent_projects.append(.{
        .path = try std.fmt.allocPrint(std.testing.allocator, "project-{d}", .{index}),
        .name = try std.fmt.allocPrint(std.testing.allocator, "Project {d}", .{index}),
    });
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
    try std.testing.expect(last.top + 24 - max <= content_bottom);
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
    draw(hdc, &model, null, "", 0, long_status, viewport_bottom, "", "", &state, -1, draw_allocator.allocator());

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
            } else if (y < workspaceFooterRect(viewport_bottom).top and (y >= status.bottom or x >= status.right)) {
                // No scrolling content is painted in the gap above the workspace footer.
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
    draw(hdc, &model, null, "", 0, "", 800, "", "", &state, -1, draw_allocator.allocator());
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
    try std.testing.expect(under_header >= 1);
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
    draw(hdc, &model, null, "", scroll, "", viewport_bottom, "", "", &state, -1, draw_allocator.allocator());

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

test "loop row title age state dot and disclosure occupy disjoint columns" {
    for (0..5) |depth| {
        const text = loopRowTextRects(100, depth);
        try std.testing.expect(text.title.left < text.title.right);
        try std.testing.expect(text.title.right <= text.age.left);
        try std.testing.expect(text.age.right <= text.state.left);
        try std.testing.expect(text.state.right <= 198);
        // Clear of the hover disclosure's hit zone and the sidebar rail edge.
        try std.testing.expect(text.age.right <= 198 and text.age.right <= Tokens.sidebar_width);
    }
    const screen = c.GetDC(null) orelse return error.SkipZigTest;
    defer _ = c.ReleaseDC(null, screen);
    const hdc = c.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
    defer _ = c.DeleteDC(hdc);
    const previous = AppFont.select(hdc, 10, false);
    defer _ = c.SelectObject(hdc, previous);
    const text = loopRowTextRects(100, 0);
    var widest_age: i32 = 0;
    for ([_][]const u8{ "-", "59s", "59m", "23h", "99d", "365d", "999d" }) |label| {
        const width = try measuredWidth(hdc, label);
        widest_age = @max(widest_age, width);
        try std.testing.expect(width <= text.age.right - text.age.left);
    }
    // Guard against vacuous measurements.
    try std.testing.expect(widest_age > 10);
}

fn measuredWidth(hdc: c.HDC, label: []const u8) !i32 {
    var wide: [16]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(hdc, &wide, @intCast(length), &size) == 0) return error.TestUnexpectedResult;
    return size.cx;
}

fn rect(left: i32, top: i32, right: i32, bottom: i32) c.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn projectForRow(model: *const GraphModel.Model, path: []const u8) ?GraphModel.Project {
    if (model.graphFor(path)) |graph| return graph.project;
    for (model.open_projects.items) |project| if (std.mem.eql(u8, project.path, path)) return project;
    return null;
}

pub fn rowSelected(row: Row, model: *const GraphModel.Model, selection: Selection) bool {
    return switch (selection) {
        .none => false,
        .overview => row.kind == .overview,
        .quick_chats => row.kind == .quick_chat_overview,
        .project => |path| row.kind == .open_project and row.project_path != null and std.mem.eql(u8, row.project_path.?, path),
        .loop => |id| blk: {
            if (row.kind != .loop) break :blk false;
            const selected_project = model.selected_project_path orelse break :blk false;
            if (row.project_path == null or !std.mem.eql(u8, row.project_path.?, selected_project)) break :blk false;
            const graph = model.graphFor(row.project_path orelse break :blk false) orelse break :blk false;
            break :blk row.index < graph.nodes.items.len and std.mem.eql(u8, graph.nodes.items[row.index].id, id);
        },
        .chat => |id| row.kind == .quick_chat and row.index < model.quick_chats.items.len and std.mem.eql(u8, model.quick_chats.items[row.index].id, id),
    };
}

fn displayState(node: GraphModel.Node) []const u8 {
    if (std.mem.eql(u8, node.presence, "busy")) return "running";
    if (std.mem.eql(u8, node.presence, "awaitingInput")) return "awaitingInput";
    if (std.mem.eql(u8, node.state, "running") and std.mem.eql(u8, node.presence, "idle")) return "idle";
    return node.state;
}

fn dotColor(state: []const u8) u32 {
    if (std.mem.eql(u8, state, "running") or std.mem.eql(u8, state, "waiting")) return 0x00FF840A;
    if (std.mem.eql(u8, state, "awaitingInput") or std.mem.eql(u8, state, "blocked")) return 0x000A9FFF;
    if (std.mem.eql(u8, state, "succeeded")) return 0x0058D130;
    if (std.mem.eql(u8, state, "failed")) return 0x003A45FF;
    if (std.mem.eql(u8, state, "stalled")) return 0x00F25ABF;
    return 0x00636363;
}

fn dotHollow(state: []const u8) bool {
    return std.mem.eql(u8, state, "blocked") or std.mem.eql(u8, state, "stopped") or std.mem.eql(u8, state, "waiting");
}

fn drawStateDot(hdc: c.HDC, bounds: c.RECT, state: []const u8) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, dotColor(state));
    defer _ = c.DeleteObject(pen);
    const brush = c.CreateSolidBrush(dotColor(state));
    defer _ = c.DeleteObject(brush);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    const old_brush = c.SelectObject(hdc, if (dotHollow(state)) c.GetStockObject(c.HOLLOW_BRUSH) else brush);
    defer _ = c.SelectObject(hdc, old_brush);
    _ = c.Ellipse(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom);
}

fn roundedFill(hdc: c.HDC, bounds: c.RECT, color: u32, radius: i32) void {
    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(brush);
    const old_brush = c.SelectObject(hdc, brush);
    defer _ = c.SelectObject(hdc, old_brush);
    const old_pen = c.SelectObject(hdc, c.GetStockObject(c.NULL_PEN));
    defer _ = c.SelectObject(hdc, old_pen);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, radius * 2, radius * 2);
}

fn stroke(hdc: c.HDC, points: []const c.POINT, color: u32) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, color);
    defer _ = c.DeleteObject(pen);
    const previous = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, previous);
    _ = c.Polyline(hdc, points.ptr, @intCast(points.len));
}

fn drawChevron(hdc: c.HDC, x: i32, y: i32, expanded: bool, color: u32) void {
    const points = if (expanded)
        [_]c.POINT{ .{ .x = x - 3, .y = y - 2 }, .{ .x = x, .y = y + 1 }, .{ .x = x + 3, .y = y - 2 } }
    else
        [_]c.POINT{ .{ .x = x - 2, .y = y - 3 }, .{ .x = x + 1, .y = y }, .{ .x = x - 2, .y = y + 3 } };
    stroke(hdc, &points, color);
}

fn drawPlus(hdc: c.HDC, x: i32, y: i32, color: u32) void {
    stroke(hdc, &.{ .{ .x = x - 4, .y = y }, .{ .x = x + 5, .y = y } }, color);
    stroke(hdc, &.{ .{ .x = x, .y = y - 4 }, .{ .x = x, .y = y + 5 } }, color);
}

const Icon = enum { folder, graph, chats, network, workspace };

fn drawIcon(hdc: c.HDC, icon: Icon, x: i32, y: i32, color: u32) void {
    switch (icon) {
        .folder => {
            stroke(hdc, &.{
                .{ .x = x, .y = y + 2 },      .{ .x = x + 6, .y = y + 2 },   .{ .x = x + 8, .y = y + 4 },
                .{ .x = x + 15, .y = y + 4 }, .{ .x = x + 15, .y = y + 14 }, .{ .x = x, .y = y + 14 },
                .{ .x = x, .y = y + 2 },
            }, color);
            stroke(hdc, &.{ .{ .x = x, .y = y + 6 }, .{ .x = x + 15, .y = y + 6 } }, color);
        },
        .graph, .network => {
            stroke(hdc, &.{ .{ .x = x + 3, .y = y + 3 }, .{ .x = x + 13, .y = y + 3 }, .{ .x = x + 8, .y = y + 13 }, .{ .x = x + 3, .y = y + 3 } }, color);
            roundedFill(hdc, rect(x, y, x + 5, y + 5), color, 2);
            roundedFill(hdc, rect(x + 11, y, x + 16, y + 5), color, 2);
            roundedFill(hdc, rect(x + 6, y + 11, x + 11, y + 16), color, 2);
        },
        .chats => {
            stroke(hdc, &.{
                .{ .x = x, .y = y },         .{ .x = x + 11, .y = y },     .{ .x = x + 11, .y = y + 9 },
                .{ .x = x + 5, .y = y + 9 }, .{ .x = x + 2, .y = y + 12 }, .{ .x = x + 2, .y = y + 9 },
                .{ .x = x, .y = y + 9 },     .{ .x = x, .y = y },
            }, color);
            stroke(hdc, &.{ .{ .x = x + 12, .y = y + 4 }, .{ .x = x + 18, .y = y + 4 }, .{ .x = x + 18, .y = y + 13 }, .{ .x = x + 16, .y = y + 13 }, .{ .x = x + 16, .y = y + 16 }, .{ .x = x + 13, .y = y + 13 }, .{ .x = x + 7, .y = y + 13 }, .{ .x = x + 7, .y = y + 10 } }, color);
        },
        .workspace => {
            stroke(hdc, &.{ .{ .x = x, .y = y + 4 }, .{ .x = x + 6, .y = y }, .{ .x = x + 12, .y = y + 4 }, .{ .x = x + 6, .y = y + 8 }, .{ .x = x, .y = y + 4 } }, color);
            stroke(hdc, &.{ .{ .x = x, .y = y + 7 }, .{ .x = x + 6, .y = y + 11 }, .{ .x = x + 12, .y = y + 7 } }, color);
        },
    }
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
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch return;
    defer allocator.free(wide);
    if (wide.len == 0) return;
    const old_font = AppFont.select(hdc, size, false);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, format);
    _ = c.SelectObject(hdc, old_font);
}
