const std = @import("std");
const App = @import("App.zig").App;
const c = @import("Win32.zig").c;

fn run() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var app = App.init(allocator) catch |err| {
        if (err == error.InstanceAlreadyRunning) {
            @import("MainWindow.zig").restoreExistingInstance();
            return;
        }
        return err;
    };
    defer app.deinit();
    app.configureArgs(args[1..]);
    try app.run();
}

pub fn main() !void {
    try run();
}

pub export fn WinMain(
    _: c.HINSTANCE,
    _: c.HINSTANCE,
    _: [*:0]u16,
    _: c.INT,
) callconv(.winapi) c.INT {
    run() catch return 1;
    return 0;
}
