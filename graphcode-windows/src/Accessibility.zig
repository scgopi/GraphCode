const std = @import("std");
const WorktreeStatus = @import("WorktreeStatus.zig");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows and builtin.link_libc) @import("Win32.zig").c else struct {
    pub const HWND = ?*anyopaque;
    pub const HANDLE = ?*anyopaque;
    pub const WPARAM = usize;
    pub const LPARAM = isize;
    pub const LRESULT = isize;
    pub const HRESULT = i32;
    pub fn SetPropW(_: HWND, _: [*:0]const u16, _: HANDLE) c_int { return 0; }
    pub fn RemovePropW(_: HWND, _: [*:0]const u16) HANDLE { return null; }
    pub fn GetPropW(_: HWND, _: [*:0]const u16) HANDLE { return null; }
    pub fn GetDesktopWindow() HWND { return null; }
};
const provider_property = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.AccessibilityProvider");
const NativeProvider = opaque {};
extern fn gc_uia_create(hwnd: c.HWND) ?*NativeProvider;
extern fn gc_uia_release(provider: *NativeProvider) void;
extern fn gc_uia_get_object(hwnd: c.HWND, wparam: c.WPARAM, lparam: c.LPARAM, provider: *NativeProvider) c.LRESULT;
extern fn gc_uia_set_status(provider: *NativeProvider, status: [*:0]const u8) c.HRESULT;
extern fn gc_uia_update(
    provider: *NativeProvider,
    status: [*:0]const u8,
    identities: ?[*]const [*:0]const u8,
    names: ?[*]const [*:0]const u8,
    parents: ?[*]const c_int,
    selected: ?[*]const c_int,
    eligible: ?[*]const c_int,
    invokable: ?[*]const c_int,
    bounds: ?[*]const c_int,
    count: c_int,
    allow_reclaim: c_int,
    confirm_each_reclaim: c_int,
) c.HRESULT;

pub const Role = enum { window, navigation, list, list_item, button, card, menu, menu_item, text, terminal, status, dialog };
pub const Pattern = enum { invoke, selection, selection_item, expand_collapse, scroll, value, text };
pub const Element = struct {
    id: []const u8,
    name: []const u8,
    role: Role,
    patterns: []const Pattern = &.{},
    focusable: bool = false,
    parent: ?usize = null,
};
pub const NotificationKind = enum { status, @"error", focus, action };
pub const Notification = struct { text: []const u8, kind: NotificationKind };
pub const Announcement = struct { role: []const u8, name: []const u8, state: []const u8 };
pub const WorktreeRow = struct { path: []const u8, selected: bool, eligible: bool };
pub const DynamicElement = struct {
    identity: []const u8,
    name: []const u8,
    parent: c_int,
    selected: bool = false,
    eligible: bool = false,
    invokable: bool = true,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};
pub const uia_selection_command_tag: usize = 0xC000000000000000;
pub const uia_selection_command_mask: usize = 0xC000000000000000;
pub const uia_selection_operation_mask: usize = 0x3000000000000000;
pub const uia_selection_operation_shift: u6 = 60;
pub const uia_row_payload_mask: usize = 0x0FFFFFFFFFFFFFFF;
pub const uia_open_overview_command: usize = 20;
pub const uia_open_quick_chats_command: usize = 21;
pub const uia_primary_canvas_action_command: usize = 22;
pub const uia_zoom_out_command: usize = 23;
pub const uia_actual_size_command: usize = 24;
pub const uia_zoom_in_command: usize = 25;
pub const uia_fit_command: usize = 26;
pub const uia_dynamic_invoke_tag: usize = 0x8000000000000000;
pub const uia_dynamic_invoke_mask: usize = 0xC000000000000000;

pub fn worktreeIdentityPayload(path: []const u8) usize {
    var hash: u64 = 1469598103934665603;
    for (path) |value| {
        hash ^= value;
        hash *%= 1099511628211;
    }
    return @intCast(hash & uia_row_payload_mask);
}

pub const Provider = struct {
    allocator: std.mem.Allocator,
    elements: std.array_list.Managed(Element),
    focus_order: std.array_list.Managed(usize),
    notifications: std.array_list.Managed(Notification),
    attached_hwnd: c.HWND = null,
    native_provider: ?*NativeProvider = null,

    pub fn init(allocator: std.mem.Allocator) Provider {
        return .{
            .allocator = allocator,
            .elements = std.array_list.Managed(Element).init(allocator),
            .focus_order = std.array_list.Managed(usize).init(allocator),
            .notifications = std.array_list.Managed(Notification).init(allocator),
        };
    }
    pub fn deinit(self: *Provider) void {
        self.detach();
        self.elements.deinit(); self.focus_order.deinit(); self.notifications.deinit();
    }
    pub fn attach(self: *Provider, hwnd: c.HWND) bool {
        if (!builtin.link_libc) return false;
        if (hwnd == null) return false;
        const native = gc_uia_create(hwnd) orelse {
            std.debug.print("UIA provider creation failed\n", .{});
            return false;
        };
        if (c.SetPropW(hwnd, provider_property.ptr, @ptrCast(native)) == 0) {
            std.debug.print("UIA SetPropW failed\n", .{});
            gc_uia_release(native);
            return false;
        }
        self.attached_hwnd = hwnd;
        self.native_provider = native;
        return true;
    }
    pub fn detach(self: *Provider) void {
        if (self.attached_hwnd) |hwnd| {
            _ = c.RemovePropW(hwnd, provider_property.ptr);
            self.attached_hwnd = null;
        }
        if (self.native_provider) |native| {
            if (builtin.link_libc) gc_uia_release(native);
            self.native_provider = null;
        }
    }
    pub fn isAttached(self: *const Provider) bool {
        const hwnd = self.attached_hwnd orelse return false;
        const native = self.native_provider orelse return false;
        return c.GetPropW(hwnd, provider_property.ptr) == @as(c.HANDLE, @ptrCast(native));
    }
    pub fn getObject(self: *const Provider, hwnd: c.HWND, wparam: c.WPARAM, lparam: c.LPARAM) c.LRESULT {
        if (!builtin.link_libc) return 0;
        const native = self.native_provider orelse return 0;
        return gc_uia_get_object(hwnd, wparam, lparam, native);
    }
    pub fn syncWorktrees(
        self: *Provider,
        status: []const u8,
        rows: []const WorktreeRow,
        policy: WorktreeStatus.Policy,
    ) void {
        var elements = self.allocator.alloc(DynamicElement, rows.len) catch return;
        defer self.allocator.free(elements);
        for (rows, 0..) |row, index| {
            const top = 34 + @as(i32, @intCast(index * 34));
            elements[index] = .{
                .identity = row.path,
                .name = row.path,
                .parent = 3,
                .selected = row.selected,
                .eligible = row.eligible,
                .invokable = false,
                .left = 12,
                .top = top,
                .right = 232,
                .bottom = top + 32,
            };
        }
        self.syncElements(status, elements, policy);
    }
    pub fn syncElements(
        self: *Provider,
        status: []const u8,
        elements: []const DynamicElement,
        policy: WorktreeStatus.Policy,
    ) void {
        if (!builtin.link_libc) return;
        const native = self.native_provider orelse return;
        const status_z = self.allocator.dupeZ(u8, status) catch return;
        defer self.allocator.free(status_z);
        var identities = self.allocator.alloc([*:0]const u8, elements.len) catch return;
        defer self.allocator.free(identities);
        var names = self.allocator.alloc([*:0]const u8, elements.len) catch return;
        defer self.allocator.free(names);
        var parents = self.allocator.alloc(c_int, elements.len) catch return;
        defer self.allocator.free(parents);
        var selected = self.allocator.alloc(c_int, elements.len) catch return;
        defer self.allocator.free(selected);
        var eligible = self.allocator.alloc(c_int, elements.len) catch return;
        defer self.allocator.free(eligible);
        var invokable = self.allocator.alloc(c_int, elements.len) catch return;
        defer self.allocator.free(invokable);
        var bounds = self.allocator.alloc(c_int, elements.len * 4) catch return;
        defer self.allocator.free(bounds);
        var owned_identities = self.allocator.alloc([:0]u8, elements.len) catch return;
        defer self.allocator.free(owned_identities);
        var owned_names = self.allocator.alloc([:0]u8, elements.len) catch return;
        defer self.allocator.free(owned_names);
        for (owned_identities) |*value| value.* = @constCast(&.{});
        for (owned_names) |*value| value.* = @constCast(&.{});
        defer for (owned_identities) |value| self.allocator.free(value);
        defer for (owned_names) |value| self.allocator.free(value);
        for (elements, 0..) |element, index| {
            owned_identities[index] = self.allocator.dupeZ(u8, element.identity) catch return;
            owned_names[index] = self.allocator.dupeZ(u8, element.name) catch return;
            identities[index] = owned_identities[index].ptr;
            names[index] = owned_names[index].ptr;
            parents[index] = element.parent;
            selected[index] = if (element.selected) 1 else 0;
            eligible[index] = if (element.eligible) 1 else 0;
            invokable[index] = if (element.invokable) 1 else 0;
            bounds[index * 4] = element.left;
            bounds[index * 4 + 1] = element.top;
            bounds[index * 4 + 2] = element.right;
            bounds[index * 4 + 3] = element.bottom;
        }
        _ = gc_uia_update(
            native,
            status_z.ptr,
            if (identities.len == 0) null else identities.ptr,
            if (names.len == 0) null else names.ptr,
            if (parents.len == 0) null else parents.ptr,
            if (selected.len == 0) null else selected.ptr,
            if (eligible.len == 0) null else eligible.ptr,
            if (invokable.len == 0) null else invokable.ptr,
            if (bounds.len == 0) null else bounds.ptr,
            @intCast(elements.len),
            if (policy.allow_reclaim) 1 else 0,
            if (policy.confirm_each_reclaim) 1 else 0,
        );
    }
    pub fn syncStatus(self: *Provider, status: []const u8) void {
        if (!builtin.link_libc) return;
        const native = self.native_provider orelse return;
        const status_z = self.allocator.dupeZ(u8, status) catch return;
        defer self.allocator.free(status_z);
        _ = gc_uia_set_status(native, status_z.ptr);
    }
    pub fn add(self: *Provider, element: Element) !usize {
        const index = self.elements.items.len;
        try self.elements.append(element);
        if (element.focusable) try self.focus_order.append(index);
        return index;
    }
    pub fn announce(self: *Provider, text: []const u8, kind: NotificationKind) !void {
        try self.notifications.append(.{ .text = text, .kind = kind });
    }
    pub fn nextFocus(self: *const Provider, current: ?usize) ?usize {
        if (self.focus_order.items.len == 0) return null;
        if (current) |value| for (self.focus_order.items, 0..) |index, offset| {
            if (index == value) return self.focus_order.items[(offset + 1) % self.focus_order.items.len];
        };
        return self.focus_order.items[0];
    }
    pub fn hasPattern(self: *const Provider, index: usize, pattern: Pattern) bool {
        if (index >= self.elements.items.len) return false;
        for (self.elements.items[index].patterns) |candidate| if (candidate == pattern) return true;
        return false;
    }
};

pub fn defaultContract(allocator: std.mem.Allocator) !Provider {
    var provider = Provider.init(allocator);
    errdefer provider.deinit();
    const window = try provider.add(.{ .id = "window", .name = "GraphCode Windows", .role = .window });
    const sidebar = try provider.add(.{ .id = "sidebar", .name = "Navigation", .role = .navigation, .parent = window });
    _ = try provider.add(.{ .id = "projects", .name = "Projects", .role = .list, .parent = sidebar, .focusable = true, .patterns = &.{ .selection, .scroll } });
    _ = try provider.add(.{ .id = "loops", .name = "Loops", .role = .list, .parent = sidebar, .focusable = true, .patterns = &.{ .selection, .scroll } });
    _ = try provider.add(.{ .id = "worktrees", .name = "Worktrees", .role = .list, .parent = sidebar, .focusable = true, .patterns = &.{ .selection, .scroll } });
    const graph = try provider.add(.{ .id = "graph", .name = "Graph", .role = .navigation, .parent = window });
    _ = try provider.add(.{ .id = "graph-card", .name = "Graph card", .role = .card, .parent = graph, .focusable = true, .patterns = &.{ .selection, .invoke } });
    _ = try provider.add(.{ .id = "overview-destination", .name = "Graph", .role = .button, .parent = sidebar, .focusable = true, .patterns = &.{.invoke} });
    _ = try provider.add(.{ .id = "quick-chats-destination", .name = "Quick Chats", .role = .button, .parent = sidebar, .focusable = true, .patterns = &.{.invoke} });
    _ = try provider.add(.{ .id = "canvas-primary-action", .name = "New Loop or Chat", .role = .button, .parent = graph, .focusable = true, .patterns = &.{.invoke} });
    _ = try provider.add(.{ .id = "zoom-out", .name = "Zoom out", .role = .button, .parent = graph, .focusable = true, .patterns = &.{.invoke} });
    _ = try provider.add(.{ .id = "actual-size", .name = "Actual size", .role = .button, .parent = graph, .focusable = true, .patterns = &.{.invoke} });
    _ = try provider.add(.{ .id = "zoom-in", .name = "Zoom in", .role = .button, .parent = graph, .focusable = true, .patterns = &.{.invoke} });
    _ = try provider.add(.{ .id = "fit-canvas", .name = "Fit canvas", .role = .button, .parent = graph, .focusable = true, .patterns = &.{.invoke} });
    const menu = try provider.add(.{ .id = "actions", .name = "Actions", .role = .menu, .parent = window, .focusable = true, .patterns = &.{ .expand_collapse } });
    _ = try provider.add(.{ .id = "inspect-worktrees", .name = "Inspect worktrees", .role = .menu_item, .parent = menu, .patterns = &.{ .invoke } });
    _ = try provider.add(.{ .id = "reclaim-worktrees", .name = "Reclaim selected worktrees", .role = .menu_item, .parent = menu, .patterns = &.{ .invoke } });
    _ = try provider.add(.{ .id = "reveal-worktree", .name = "Reveal in Explorer", .role = .menu_item, .parent = menu, .patterns = &.{ .invoke } });
    _ = try provider.add(.{ .id = "terminal-a", .name = "Terminal A", .role = .terminal, .parent = window, .focusable = true, .patterns = &.{ .text, .scroll } });
    _ = try provider.add(.{ .id = "terminal-b", .name = "Terminal B", .role = .terminal, .parent = window, .focusable = true, .patterns = &.{ .text, .scroll } });
    _ = try provider.add(.{ .id = "status", .name = "Status", .role = .status, .parent = window });
    _ = try provider.add(.{ .id = "errors", .name = "Errors", .role = .status, .parent = window });
    return provider;
}

pub fn nodeAnnouncement(title: []const u8, state: []const u8) Announcement {
    return .{ .role = "Graph node", .name = title, .state = state };
}

pub fn terminalAnnouncement(index: usize) Announcement {
    return .{
        .role = "Terminal surface",
        .name = if (index == 0) "GraphCode terminal A" else "GraphCode terminal B",
        .state = "interactive",
    };
}

pub fn log(announcement: Announcement) void {
    _ = announcement;
}

test "UIA contract exposes named roles patterns and deterministic focus order" {
    var provider = try defaultContract(std.testing.allocator);
    defer provider.deinit();
    try std.testing.expectEqual(Role.navigation, provider.elements.items[1].role);
    try std.testing.expect(provider.hasPattern(2, .selection));
    try std.testing.expect(provider.hasPattern(11, .text));
    try std.testing.expectEqual(@as(?usize, 3), provider.nextFocus(2));
    try std.testing.expectEqual(@as(?usize, 4), provider.nextFocus(3));
}

test "status and error announcements are retained for screen readers" {
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try provider.announce("Worktrees inspected", .status);
    try provider.announce("Reclaim blocked: unpushed commits", .@"error");
    try std.testing.expectEqual(@as(usize, 2), provider.notifications.items.len);
}

test "production provider attaches to and detaches from a live HWND" {
    if (!builtin.link_libc) return;
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    const hwnd = c.GetDesktopWindow();
    try std.testing.expect(hwnd != null);
    try std.testing.expect(provider.attach(hwnd));
    try std.testing.expect(provider.isAttached());
    provider.detach();
    try std.testing.expect(!provider.isAttached());
}
