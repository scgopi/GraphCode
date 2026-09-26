test "production WorktreeStatus subprocess owned fixture" {
    try @import("worktree").SubprocessTests.run();
}
