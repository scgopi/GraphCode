const std = @import("std");

pub const Channel = enum { stable, beta };
pub const State = enum { disabled, ready };

pub const CheckState = struct {
    channel: Channel = .stable,
    state: State = .disabled,

    pub fn configure(beta_enabled: bool) CheckState {
        return .{ .channel = if (beta_enabled) .beta else .stable, .state = .ready };
    }

    pub fn label(self: CheckState) []const u8 {
        return if (self.state == .disabled) "Updates disabled"
        else if (self.channel == .beta) "Beta update channel enabled"
        else "Stable update channel enabled";
    }
};

test "update channel state follows beta setting" {
    try std.testing.expectEqual(Channel.stable, CheckState.configure(false).channel);
    try std.testing.expectEqual(State.ready, CheckState.configure(true).state);
    try std.testing.expectEqualStrings("Beta update channel enabled", CheckState.configure(true).label());
}
