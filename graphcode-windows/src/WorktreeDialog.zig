const std = @import("std");
const WorktreeStatus = @import("WorktreeStatus.zig");

pub const Row = struct {
    entry: WorktreeStatus.Entry,
    selected: bool = false,
};

pub const ReclaimError = error{
    ConfirmationRequired,
    PolicyDisabled,
    UnsafeSelection,
};

pub const Dialog = struct {
    allocator: std.mem.Allocator,
    project_path: []u8,
    policy: WorktreeStatus.Policy,
    rows: std.array_list.Managed(Row),
    confirmation_armed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        project_path: []const u8,
        entries: []const WorktreeStatus.Entry,
        policy: WorktreeStatus.Policy,
    ) !Dialog {
        var dialog = Dialog{
            .allocator = allocator,
            .project_path = try allocator.dupe(u8, project_path),
            .policy = policy,
            .rows = std.array_list.Managed(Row).init(allocator),
        };
        errdefer dialog.deinit();
        for (entries) |entry| try dialog.rows.append(.{ .entry = entry });
        return dialog;
    }

    pub fn deinit(self: *Dialog) void {
        self.allocator.free(self.project_path);
        self.rows.deinit();
    }

    pub fn toggle(self: *Dialog, index: usize) bool {
        if (index >= self.rows.items.len) return false;
        self.rows.items[index].selected = !self.rows.items[index].selected;
        self.confirmation_armed = false;
        return true;
    }

    pub fn clearSelection(self: *Dialog) void {
        for (self.rows.items) |*row| row.selected = false;
        self.confirmation_armed = false;
    }

    pub fn setPolicy(self: *Dialog, policy: WorktreeStatus.Policy) void {
        self.policy = policy;
        self.confirmation_armed = false;
    }

    pub fn savePolicy(self: *const Dialog) !void {
        try WorktreeStatus.savePolicy(self.allocator, self.project_path, self.policy);
    }

    pub fn selectedCount(self: *const Dialog) usize {
        var count: usize = 0;
        for (self.rows.items) |row| {
            if (row.selected) count += 1;
        }
        return count;
    }

    pub fn selectedPaths(self: *const Dialog, allocator: std.mem.Allocator) !std.array_list.Managed([]const u8) {
        var result = std.array_list.Managed([]const u8).init(allocator);
        errdefer result.deinit();
        for (self.rows.items) |row| if (row.selected) try result.append(row.entry.path);
        return result;
    }

    pub fn armConfirmation(self: *Dialog) ReclaimError!void {
        if (!self.policy.allow_reclaim) return error.PolicyDisabled;
        if (self.selectedCount() == 0) return error.UnsafeSelection;
        for (self.rows.items) |row| {
            if (row.selected and WorktreeStatus.decision(row.entry) != .reclaimable)
                return error.UnsafeSelection;
        }
        self.confirmation_armed = true;
    }

    pub fn canConfirm(self: *const Dialog) bool {
        return self.confirmation_armed and self.policy.allow_reclaim;
    }

    pub fn consumeConfirmation(self: *Dialog) ReclaimError!void {
        if (!self.canConfirm()) return error.ConfirmationRequired;
        self.confirmation_armed = false;
    }

    pub fn revealSelected(self: *const Dialog) !WorktreeStatus.ExplorerArgs {
        for (self.rows.items) |row| if (row.selected) return WorktreeStatus.explorerArgs(row.entry.path);
        return error.EmptyProjectPath;
    }
};

test "multi-select requires explicit confirmation and fails closed" {
    var entries = [_]WorktreeStatus.Entry{
        .{ .path = @constCast("C:\\safe ☃"), .branch = @constCast("safe"), .pushed = true, .landed = true },
        .{ .path = @constCast("C:\\dirty"), .branch = @constCast("dirty"), .dirty = true, .pushed = true, .landed = true },
    };
    var dialog = try Dialog.init(std.testing.allocator, "C:\\project", &entries, .{});
    defer dialog.deinit();
    try std.testing.expect(dialog.toggle(0));
    try std.testing.expectError(error.PolicyDisabled, dialog.armConfirmation());
    dialog.policy.allow_reclaim = true;
    try std.testing.expect(dialog.toggle(1));
    try std.testing.expectError(error.UnsafeSelection, dialog.armConfirmation());
}

test "reveal preserves Unicode path and uses Explorer verb" {
    var entries = [_]WorktreeStatus.Entry{
        .{ .path = @constCast("C:\\工作\\review"), .branch = @constCast("review"), .pushed = true, .landed = true },
    };
    var dialog = try Dialog.init(std.testing.allocator, "C:\\project", &entries, .{ .allow_reclaim = true });
    defer dialog.deinit();
    _ = dialog.toggle(0);
    const args = try dialog.revealSelected();
    try std.testing.expectEqualStrings("explore", args.verb);
    try std.testing.expectEqualStrings("C:\\工作\\review", args.path);
}

test "confirmed multi-select is consumable exactly once" {
    var entries = [_]WorktreeStatus.Entry{
        .{ .path = @constCast("C:\\one"), .branch = @constCast("one"), .pushed = true, .landed = true },
        .{ .path = @constCast("C:\\two"), .branch = @constCast("two"), .pushed = true, .landed = true },
    };
    var dialog = try Dialog.init(std.testing.allocator, "C:\\project", &entries, .{ .allow_reclaim = true });
    defer dialog.deinit();
    _ = dialog.toggle(0);
    _ = dialog.toggle(1);
    try dialog.armConfirmation();
    try dialog.consumeConfirmation();
    try std.testing.expectError(error.ConfirmationRequired, dialog.consumeConfirmation());
}
