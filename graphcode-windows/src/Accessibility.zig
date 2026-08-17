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
    rows: ?[*]const [*:0]const u8,
    selected: ?[*]const c_int,
    eligible: ?[*]const c_int,
    count: c_int,
    focused: c_int,
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
        if (!builtin.link_libc) return;
        const native = self.native_provider orelse return;
        const status_z = self.allocator.dupeZ(u8, status) catch return;
        defer self.allocator.free(status_z);
        var names = self.allocator.alloc([*:0]const u8, rows.len) catch return;
        defer self.allocator.free(names);
        var selected = self.allocator.alloc(c_int, rows.len) catch return;
        defer self.allocator.free(selected);
        var eligible = self.allocator.alloc(c_int, rows.len) catch return;
        defer self.allocator.free(eligible);
        var owned = self.allocator.alloc([:0]u8, rows.len) catch return;
        defer self.allocator.free(owned);
        for (owned) |*name| name.* = @constCast(&.{});
        defer for (owned) |name| self.allocator.free(name);
        for (rows, 0..) |row, index| {
            owned[index] = self.allocator.dupeZ(u8, row.path) catch return;
            names[index] = owned[index].ptr;
            selected[index] = if (row.selected) 1 else 0;
            eligible[index] = if (row.eligible) 1 else 0;
        }
        var focused: c_int = 0;
        for (rows, 0..) |row, index| {
            if (row.selected) {
                focused = @intCast(100 + index);
                break;
            }
        }
        _ = gc_uia_update(
            native,
            status_z.ptr,
            if (names.len == 0) null else names.ptr,
            if (selected.len == 0) null else selected.ptr,
            if (eligible.len == 0) null else eligible.ptr,
            @intCast(rows.len),
            focused,
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
    _ = try provider.add(.{ .id = "graph", .name = "Graph", .role = .navigation, .parent = window });
    _ = try provider.add(.{ .id = "graph-card", .name = "Graph card", .role = .card, .parent = 5, .focusable = true, .patterns = &.{ .selection, .invoke } });
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
