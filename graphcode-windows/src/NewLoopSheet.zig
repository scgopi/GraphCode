const std = @import("std");
const Forms = @import("Forms.zig");

pub const Choice = struct {
    label: []const u8,
    value: []const u8,
    description: []const u8 = "",
    accent: u32 = 0,
};

fn color(red: u8, green: u8, blue: u8) u32 {
    return @as(u32, red) | (@as(u32, green) << 8) | (@as(u32, blue) << 16);
}

pub const loop_type_choices = [_]Choice{
    .{ .label = "Main", .value = "sketch", .description = "Just start. No goal, no schedule, nothing to fill in.", .accent = color(211, 218, 227) },
    .{ .label = "Goal", .value = "goalBased", .description = "Works until a condition is met", .accent = color(25, 158, 112) },
    .{ .label = "Timed", .value = "timeBased", .description = "Runs again on a schedule", .accent = color(201, 133, 0) },
    .{ .label = "Turn", .value = "turnBased", .description = "Pauses for you each turn", .accent = color(213, 81, 129) },
    .{ .label = "Composite", .value = "proactive", .description = "A group of loops, armed later", .accent = color(144, 133, 233) },
};

pub const cadence_choices = [_]Choice{
    .{ .label = "15m", .value = "15m" },
    .{ .label = "1h", .value = "1h" },
    .{ .label = "6h", .value = "6h" },
    .{ .label = "Daily", .value = "24h" },
    .{ .label = "Custom…", .value = "custom" },
};

pub const pause_choices = [_]Choice{
    .{ .label = "After every turn", .value = "false" },
    .{ .label = "Only before it writes files", .value = "true", .description = "reads and searches run through" },
};

pub const schedule_choices = [_]Choice{
    .{ .label = "Daily", .value = "daily" },
    .{ .label = "Weekdays", .value = "weekdays" },
    .{ .label = "Weekly", .value = "weekly" },
    .{ .label = "On a trigger", .value = "onATrigger" },
};

pub const Field = enum(usize) {
    loop_type = 0,
    sketch_note = 1,
    goal_summary = 2,
    goal_predicate = 3,
    goal_metric = 4,
    goal_budget = 5,
    timed_cadence = 6,
    timed_custom_cadence = 7,
    timed_task = 8,
    timed_stop_after = 9,
    turn_instruction = 10,
    turn_pause = 11,
    turn_check = 12,
    composite_schedule = 13,
    composite_time = 14,
    title = 15,
    backend = 16,
    model = 17,
    branch = 18,
};

pub const field_count = 19;

pub fn canonicalLoopType(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "composite")) "proactive" else value;
}

pub fn isComposite(value: []const u8) bool {
    const canonical = canonicalLoopType(value);
    return std.mem.eql(u8, canonical, "proactive");
}

pub fn fieldLabel(loop_type_value: []const u8, index: usize) []const u8 {
    const loop_type = canonicalLoopType(loop_type_value);
    const field: Field = std.enums.fromInt(Field, index) orelse return "";
    return switch (field) {
        .loop_type => "",
        .sketch_note => "Starting note",
        .goal_summary => "What does done look like?",
        .goal_predicate => "Done check",
        .goal_metric => "Measured by",
        .goal_budget => "Token budget",
        .timed_cadence => "How often?",
        .timed_custom_cadence => "Custom interval",
        .timed_task => "What to do each time",
        .timed_stop_after => "Stop after",
        .turn_instruction => "First instruction",
        .turn_pause => "Pause",
        .turn_check => "What you're checking for",
        .composite_schedule => "Intended schedule",
        .composite_time => "Time",
        .title => if (std.mem.eql(u8, loop_type, "sketch")) "" else "Name",
        .backend => "Agent",
        .model => "Model",
        .branch => "Branch",
    };
}

pub fn fieldHelp(index: usize) []const u8 {
    const field: Field = std.enums.fromInt(Field, index) orelse return "";
    return switch (field) {
        .sketch_note => "No done check, no cadence — it works with you until you promote it or close it.",
        .goal_summary => "In your own words. The loop is told this, and works toward it.",
        .goal_predicate => "Optional. Runs periodically while the loop works. Exit 0 means done.",
        .goal_metric => "A command printing one number. Sampled once per pass, not per poll.",
        .goal_budget => "Optional. Stops once its backend reports this many tokens spent.",
        .timed_cadence => "GraphCode writes the /loop directive for you.",
        .timed_stop_after => "Optional. Left empty, it keeps running until you stop it.",
        .turn_pause => "Only-before-writes lets reads and searches run through.",
        .turn_check => "Optional. Shown at each pause and to the loop as the bar it is aiming for.",
        .composite_schedule => "Local time. Nothing is scheduled until you pilot and arm it.",
        .title => "Optional except for Composite; other loops can name themselves after creation.",
        .branch => "This folder creates no worktree binding.",
        else => "",
    };
}

pub fn configureVisibility(
    visible: *[256]bool,
    loop_type_value: []const u8,
    metric_expanded: bool,
    budget_expanded: bool,
    custom_cadence: bool,
    schedule_has_time: bool,
) void {
    @memset(visible, false);
    visible[@intFromEnum(Field.loop_type)] = true;
    const loop_type = canonicalLoopType(loop_type_value);
    if (std.mem.eql(u8, loop_type, "sketch")) {
        visible[@intFromEnum(Field.sketch_note)] = true;
    } else if (std.mem.eql(u8, loop_type, "goalBased")) {
        visible[@intFromEnum(Field.goal_summary)] = true;
        visible[@intFromEnum(Field.goal_predicate)] = true;
        visible[@intFromEnum(Field.goal_metric)] = metric_expanded;
        visible[@intFromEnum(Field.goal_budget)] = budget_expanded;
        visible[@intFromEnum(Field.title)] = true;
    } else if (std.mem.eql(u8, loop_type, "timeBased")) {
        visible[@intFromEnum(Field.timed_cadence)] = true;
        visible[@intFromEnum(Field.timed_custom_cadence)] = custom_cadence;
        visible[@intFromEnum(Field.timed_task)] = true;
        visible[@intFromEnum(Field.timed_stop_after)] = true;
        visible[@intFromEnum(Field.title)] = true;
    } else if (std.mem.eql(u8, loop_type, "turnBased")) {
        visible[@intFromEnum(Field.turn_instruction)] = true;
        visible[@intFromEnum(Field.turn_pause)] = true;
        visible[@intFromEnum(Field.turn_check)] = true;
        visible[@intFromEnum(Field.title)] = true;
    } else if (isComposite(loop_type)) {
        visible[@intFromEnum(Field.composite_schedule)] = true;
        visible[@intFromEnum(Field.composite_time)] = schedule_has_time;
        visible[@intFromEnum(Field.title)] = true;
    }
    visible[@intFromEnum(Field.backend)] = true;
    visible[@intFromEnum(Field.model)] = true;
    visible[@intFromEnum(Field.branch)] = true;
}

pub fn primaryLabel(loop_type: []const u8) []const u8 {
    if (std.mem.eql(u8, canonicalLoopType(loop_type), "sketch")) return "Start";
    if (isComposite(loop_type)) return "Create & open";
    return "Create loop";
}

pub fn disabledReason(draft: Forms.NodeDraft) ?[]const u8 {
    const loop_type = canonicalLoopType(draft.loop_type);
    if (draft.backend) |backend| {
        if (!backendCanHost(backend, loop_type)) return "This agent can't host this kind of loop";
    }
    if (std.mem.eql(u8, loop_type, "sketch")) return null;
    if (std.mem.eql(u8, loop_type, "goalBased") and std.mem.trim(u8, draft.goal_summary, " \t\r\n").len == 0)
        return "Say what done looks like to continue";
    if (std.mem.eql(u8, loop_type, "timeBased") and std.mem.trim(u8, draft.trigger_prompt, " \t\r\n").len == 0)
        return "Say what to do each time to continue";
    if (std.mem.eql(u8, loop_type, "turnBased") and std.mem.trim(u8, draft.first_instruction, " \t\r\n").len == 0)
        return "Add a first instruction to continue";
    if (isComposite(loop_type) and std.mem.trim(u8, draft.title, " \t\r\n").len == 0)
        return "Name it to continue";
    return null;
}

pub fn backendCanHost(backend: []const u8, loop_type: []const u8) bool {
    return !(isComposite(loop_type) and std.mem.eql(u8, backend, "codex"));
}

pub fn cadencePrompt(allocator: std.mem.Allocator, cadence: []const u8, custom: []const u8, task: []const u8, stop_after: []const u8) ![]u8 {
    const trimmed_task = std.mem.trim(u8, task, " \t\r\n");
    if (trimmed_task.len == 0) return allocator.dupe(u8, "");
    const interval = if (std.mem.eql(u8, cadence, "custom")) blk: {
        const value = std.mem.trim(u8, custom, " \t\r\n");
        break :blk if (value.len == 0) "1h" else value;
    } else cadence;
    const stop = std.mem.trim(u8, stop_after, " \t\r\n");
    return if (stop.len == 0)
        std.fmt.allocPrint(allocator, "/loop {s} {s}", .{ interval, trimmed_task })
    else
        std.fmt.allocPrint(allocator, "/loop {s} {s} Stop after {s}.", .{ interval, trimmed_task, stop });
}

pub const TimedPrompt = struct {
    cadence: []const u8 = "1h",
    custom: []const u8 = "",
    task: []const u8,
    stop_after: []const u8 = "",
};

pub fn parseTimedPrompt(prompt: []const u8) TimedPrompt {
    if (!std.mem.startsWith(u8, prompt, "/loop ")) return .{ .task = prompt };
    const rest = prompt["/loop ".len..];
    const separator = std.mem.indexOfScalar(u8, rest, ' ') orelse return .{ .task = prompt };
    const interval = rest[0..separator];
    var task = rest[separator + 1 ..];
    var stop: []const u8 = "";
    if (std.mem.lastIndexOf(u8, task, " Stop after ")) |stop_index| {
        stop = std.mem.trimRight(u8, task[stop_index + " Stop after ".len ..], ".");
        task = task[0..stop_index];
    }
    const known = std.mem.eql(u8, interval, "15m") or std.mem.eql(u8, interval, "1h") or
        std.mem.eql(u8, interval, "6h") or std.mem.eql(u8, interval, "24h");
    return .{
        .cadence = if (known) interval else "custom",
        .custom = if (known) "" else interval,
        .task = task,
        .stop_after = stop,
    };
}

pub fn schedulePrompt(allocator: std.mem.Allocator, schedule: []const u8, time: []const u8) ![]u8 {
    if (std.mem.eql(u8, schedule, "onATrigger"))
        return allocator.dupe(u8, "Intended schedule: on a trigger");
    const display = if (std.mem.eql(u8, schedule, "weekdays"))
        "weekdays"
    else if (std.mem.eql(u8, schedule, "weekly"))
        "weekly"
    else
        "daily";
    const at = if (std.mem.trim(u8, time, " \t\r\n").len == 0) "09:00" else std.mem.trim(u8, time, " \t\r\n");
    return std.fmt.allocPrint(allocator, "Intended schedule: {s} at {s}", .{ display, at });
}

pub const SchedulePrompt = struct {
    schedule: []const u8 = "daily",
    time: []const u8 = "09:00",
};

pub fn parseSchedulePrompt(prompt: []const u8) SchedulePrompt {
    const prefix = "Intended schedule: ";
    if (!std.mem.startsWith(u8, prompt, prefix)) return .{};
    const value = prompt[prefix.len..];
    if (std.mem.eql(u8, value, "on a trigger")) return .{ .schedule = "onATrigger", .time = "" };
    const marker = " at ";
    const at = std.mem.indexOf(u8, value, marker) orelse return .{};
    const schedule = value[0..at];
    if (!std.mem.eql(u8, schedule, "daily") and
        !std.mem.eql(u8, schedule, "weekdays") and
        !std.mem.eql(u8, schedule, "weekly")) return .{};
    return .{ .schedule = schedule, .time = value[at + marker.len ..] };
}

pub fn parseBudget(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    return if (value > 0) value else null;
}

pub fn recap(allocator: std.mem.Allocator, draft: Forms.NodeDraft, worktree_branch: []const u8) ![]u8 {
    const location = if (worktree_branch.len == 0)
        ""
    else
        try std.fmt.allocPrint(allocator, " in the {s} worktree", .{worktree_branch});
    defer if (worktree_branch.len != 0) allocator.free(location);
    const loop_type = canonicalLoopType(draft.loop_type);
    if (std.mem.eql(u8, loop_type, "sketch"))
        return std.fmt.allocPrint(allocator, "Opens a session{s} and waits for you. Nothing is scheduled and nothing resolves on its own — it works with you until you promote it or close it.", .{location});
    if (std.mem.eql(u8, loop_type, "goalBased")) {
        const check = if (std.mem.trim(u8, draft.goal_predicate, " \t\r\n").len == 0)
            "resolves when its session finishes"
        else
            "resolves itself when the done check passes";
        const cap = if (draft.token_budget) |budget|
            try std.fmt.allocPrint(allocator, " Stops if it spends more than {d} tokens.", .{budget})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(cap);
        return std.fmt.allocPrint(allocator, "Starts now{s}, works toward the goal, and {s}.{s}", .{ location, check, cap });
    }
    if (std.mem.eql(u8, loop_type, "timeBased"))
        return std.fmt.allocPrint(allocator, "Starts now{s} and runs again on its own until you stop it.", .{location});
    if (std.mem.eql(u8, loop_type, "turnBased"))
        return std.fmt.allocPrint(
            allocator,
            "Waits until you open it, then works in turns — pausing {s} for your review.",
            .{if (draft.pauses_before_writes_only) "before it writes anything" else "after each one"},
        );
    return std.fmt.allocPrint(
        allocator,
        "Creates an empty group called “{s}” and opens it so you can add loops. It won't run — and can't be armed — until you pilot it once.",
        .{Forms.resolvedTitle(draft.title)},
    );
}
