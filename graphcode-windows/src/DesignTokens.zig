pub const Color = u32;

pub const window_tone: Color = 0x001E1E1E;
pub const window_background: Color = 0x8C1E1E1E;
pub const canvas_background: Color = 0x9E181818;
pub const canvas_tone: Color = 0x00181818;
pub const canvas_grid_line: Color = 0x00272727;
pub const unfocused_pane_veil: Color = 0x591E1E1E;
pub const terminal_background_opacity: f32 = 0.80;
pub const workspace_rail: Color = 0x001D1D21;
pub const pane_focus_tint: Color = 0x000A84FF;

pub const loop_card_width: i32 = 250;
pub const loop_card_height: i32 = 106;
pub const loop_card_radius: i32 = 11;
pub const loop_card_stripe: i32 = 4;
pub const workspace_rail_width: i32 = 212;
pub const pane_header_height: i32 = 22;
pub const tab_bar_height: i32 = 30;
pub const canvas_grid_cell: i32 = 24;

pub const sidebar_width: i32 = 220;
pub const header_height: i32 = 34;
pub const workspace_height: i32 = 250;
pub const activity_strip_height: i32 = 48;

pub fn rgb(color: Color) u32 {
    return color & 0x00FFFFFF;
}
