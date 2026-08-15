const std = @import("std");
const App = @import("App.zig").App;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var app = App.init(allocator) catch |err| {
        if (err == error.InstanceAlreadyRunning) {
            std.debug.print("GraphCode Windows is already running for this user.\n", .{});
            return;
        }
        return err;
    };
    defer app.deinit();
    app.configureArgs(args[1..]);
    try app.run();
}
