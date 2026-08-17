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
    const package_version = b.option([]const u8, "version", "Packaged GraphCode release version") orelse "dev";

    const winghostty_dir = b.option(
        []const u8,
        "winghostty-dir",
        "Path to the exact pinned Winghostty provider worktree",
    ) orelse {
        const fail = b.addFail("pass -Dwinghostty-dir=<pinned provider worktree>");
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
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", package_version);
    module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "graphcode-windows",
        .root_module = module,
    });
    exe.subsystem = .Windows;
    exe.addCSourceFile(.{
        .file = b.path("src/FolderPicker.c"),
        .flags = &.{ "-DUNICODE", "-D_UNICODE" },
    });
    exe.addCSourceFile(.{
        .file = b.path("src/AccessibilityProvider.cpp"),
        .flags = &.{ "-Wno-unused-command-line-argument" },
    });
    exe.addObjectFile(.{ .cwd_relative = winghostty_lib });
    for ([_][]const u8{
        "user32",
        "gdi32",
        "opengl32",
        "kernel32",
        "imm32",
        "oleaut32",
        "ole32",
        "oleaut32",
        "uiautomationcore",
        "shell32",
        "advapi32",
        "winhttp",
    }) |library| {
        exe.linkSystemLibrary(library);
    }
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the GraphCode Windows shell");
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);
}
