const std = @import("std");
const App = @import("App.zig").App;
const c = @import("Win32.zig").c;
const build_options = @import("build_options");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var stdout = std.fs.File.stdout().writer(&.{});
            try stdout.interface.print("{s}\n", .{build_options.version});
            return;
        }
    }
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

pub export fn WinMain(
    _: c.HINSTANCE,
    _: c.HINSTANCE,
    _: [*:0]u16,
    _: c.INT,
) callconv(.winapi) c.INT {
    main() catch return 1;
    return 0;
}
