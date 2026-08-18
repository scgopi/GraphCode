const std = @import("std");
const GraphCanvas = @import("GraphCanvas.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,

    pub fn init(allocator: std.mem.Allocator) !Store {
        const base = resolveSupportDirectory(allocator) catch blk: {
            const profile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
            defer allocator.free(profile);
            break :blk try std.fs.path.join(allocator, &.{ profile, ".graphcode" });
        };
        defer allocator.free(base);
        try std.fs.cwd().makePath(base);
        return .{
            .allocator = allocator,
            .path = try std.fs.path.join(allocator, &.{ base, "windows-canvas-layout.tsv" }),
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn load(self: *Store, state: *GraphCanvas.CanvasState) !void {
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(data);
        try state.decodeNodeOffsets(data);
    }

    pub fn save(self: *Store, state: *const GraphCanvas.CanvasState) !void {
        const data = try state.encodeNodeOffsets(self.allocator);
        defer self.allocator.free(data);
        const temp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.tmp-{d}",
            .{ self.path, std.time.nanoTimestamp() },
        );
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

fn resolveSupportDirectory(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        return value;
    } else |_| {}
    const profile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(profile);
    return std.fs.path.join(allocator, &.{ profile, ".graphcode" });
}
