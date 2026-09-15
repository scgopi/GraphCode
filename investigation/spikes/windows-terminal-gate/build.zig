const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .msvc,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const winghostty_dir = b.option(
        []const u8,
        "winghostty-dir",
        "Path to the exact local Winghostty provider worktree",
    ) orelse {
        const fail = b.addFail("pass -Dwinghostty-dir=<provider worktree>");
        b.getInstallStep().dependOn(&fail.step);
        return;
    };
    const winghostty_include = b.option(
        []const u8,
        "winghostty-include",
        "Optional Winghostty include directory",
    ) orelse b.pathJoin(&.{ winghostty_dir, "include" });
    const winghostty_lib = b.option(
        []const u8,
        "winghostty-lib",
        "Optional Winghostty static host library",
    ) orelse b.pathJoin(&.{ winghostty_dir, "zig-out", "lib", "winghostty-win32-host.lib" });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(.{ .cwd_relative = winghostty_include });

    const exe = b.addExecutable(.{
        .name = "graphcode-terminal-gate",
        .root_module = module,
    });
    exe.addObjectFile(.{ .cwd_relative = winghostty_lib });
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("opengl32");
    exe.linkSystemLibrary("kernel32");
    exe.linkSystemLibrary("imm32");
    exe.linkSystemLibrary("oleaut32");
    exe.linkSystemLibrary("ole32");
    exe.linkSystemLibrary("uiautomationcore");
    exe.linkSystemLibrary("shell32");
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the two-surface terminal gate");
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);
}
