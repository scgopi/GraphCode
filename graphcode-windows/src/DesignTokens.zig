pub const Color = u32;

// Every value below is converted 1:1 from graphcode/Sources/Features/App/Theme.swift
// (the macOS `Theme` enum, the single source of truth for this app's dark palette).
// Windows literals are Win32 COLORREF-style `0xAABBGGRR` (an optional alpha byte,
// then Blue, Green, Red -- reversed from web `#RRGGBB` notation). To convert a mac
// `Color(red:g:b:)` (0.0-1.0 floats), each channel is `round(component * 255)`; an
// `.opacity(x)` on top of a *painted* (non-glass) surface is pre-blended into a flat
// equivalent against the base it is actually painted over here, since this codebase
// has no real Win32 alpha-blending path (no `AlphaBlend`/`BLENDFUNCTION` usage
// anywhere) -- the one exception is `window_background`/`unfocused_pane_veil` below,
// which keep a literal alpha byte purely as documentation for a future consumer.
pub const window_tone: Color = 0x001E1E1E; // Theme.windowTone = Color(white: 0.118)
pub const window_background: Color = 0x8C1E1E1E; // Theme.windowBackground = windowTone.opacity(0.55)
// Theme.canvasBackground = canvasTone (mac defines it as a literal alias, not a
// distinct value -- opaque on purpose, see Theme.swift's doc comment).
pub const canvas_background: Color = canvas_tone;
// Theme.canvasTone = Color(red: 0.040, green: 0.048, blue: 0.044) -- a near-black with
// a trace of green, "so a long session against it reads warmer than dead neutral".
// Previously 0x00181818 (flat neutral gray), which lost that intentional warmth.
pub const canvas_tone: Color = 0x000B0C0A;
// Theme.canvasGridLine = Color(red: 0.082, green: 0.094, blue: 0.086), one step off
// canvasTone. Previously 0x00272727 (flat gray, same bug as canvas_tone above).
pub const canvas_grid_line: Color = 0x00161815;
pub const canvas_edge: Color = 0x006A6A6A;
pub const canvas_selection: Color = 0x007AB8FF;
pub const unfocused_pane_veil: Color = 0x591E1E1E;
pub const terminal_background_opacity: f32 = 0.80;
// Theme.workspaceRail = Color(red: 0.114, green: 0.114, blue: 0.129) // #1d1d21.
// Previously 0x001D1D21, which has Red and Blue swapped relative to that hex (decodes
// to R=0x21,G=0x1D,B=0x1D instead of R=0x1D,G=0x1D,B=0x21) -- a genuine color bug, not
// just quantization, fixed here to match the mac literal exactly.
pub const workspace_rail: Color = 0x00211D1D;
pub const pane_focus_tint: Color = 0x00FF840A; // Theme.paneFocusTint = #0a84ff

// --- Chrome gloss / gradient surfaces -------------------------------------------
// macOS paints these as `LinearGradient`s (top -> bottom). This codebase has no
// GDI+/Direct2D dependency, so they are approximated with Win32 `GradientFill`
// (msimg32.dll, see `GdiGradient.zig`) driven by a `_top`/`_bottom` stop pair, with a
// safe flat-fill fallback if `GradientFill` is unavailable. Where a stop has
// `.opacity(x)` in Theme.swift (i.e. it is a translucent scrim over the window's
// glass on mac), the value here is pre-blended flat against the concrete Windows
// surface it paints over, since Windows chrome here is opaque paint, not glass.

// Theme.tabBarGloss: 3-stop gradient (white 0.145/0.66, 0.122/0.62, 0.106/0.58)
// blended over `workspace_rail`, approximated as a 2-stop top/bottom pair (the
// middle stop is close to the midpoint of these two and GradientFill's rect mode
// only takes two vertices per rectangle).
pub const tab_bar_gloss_top: Color = 0x00242222;
pub const tab_bar_gloss_bottom: Color = 0x001E1C1C;
// Theme.tabBarHighlight = Color.white.opacity(0.08), blended over `workspace_rail`.
pub const tab_bar_highlight: Color = 0x00332F2F;
// Theme.tabBarShadowLine = Color.black.opacity(0.35), blended over `loop_bar_bottom`.
pub const tab_bar_shadow_line: Color = 0x00161414;
// Theme.tabSelectedBackground = Color(red: 0.235, green: 0.245, blue: 0.267).
pub const tab_selected_background: Color = 0x00443E3C;

// Theme.controlGloss: LinearGradient(0.243,0.255,0.278 -> 0.192,0.200,0.220).
pub const control_gloss_top: Color = 0x0047413E;
pub const control_gloss_bottom: Color = 0x00383331;
// Theme.controlGlossHovered: LinearGradient(0.310,0.322,0.349 -> 0.243,0.255,0.278).
pub const control_gloss_hovered_top: Color = 0x0059524F;
pub const control_gloss_hovered_bottom: Color = control_gloss_top;
// Theme.controlBorder = Color.white.opacity(0.10), blended over `control_gloss_bottom`.
pub const control_border: Color = 0x004C4746;

// Theme.loopCard: LinearGradient(#2c2c30 -> #232326).
pub const loop_card_top: Color = 0x00302C2C;
pub const loop_card_bottom: Color = 0x00262323;
// Theme.loopCardAttention: LinearGradient(#302a22 -> #262220).
pub const loop_card_attention_top: Color = 0x00222A30;
pub const loop_card_attention_bottom: Color = 0x00202226;
// Theme.loopCardBorder = Color.white.opacity(0.09), blended over `loop_card_bottom`.
pub const loop_card_border: Color = 0x003A3737;
// Theme.loopCardAttentionBorder = Color(1.0, 0.624, 0.039).opacity(0.55), blended
// over `loop_card_attention_bottom`.
pub const loop_card_attention_border: Color = 0x0014679D;

// Theme.loopBar: LinearGradient(#24242a -> #1e1e22).
pub const loop_bar_top: Color = 0x002A2424;
pub const loop_bar_bottom: Color = 0x00221E1E;

// Theme.activityStrip = Color(red: 0.114, green: 0.114, blue: 0.125) // #1d1d20.
pub const activity_strip: Color = 0x00201D1D;

// Theme.sheet = Color(red: 0.165, green: 0.165, blue: 0.180) // #2a2a2e -- "the
// new-loop sheet and the fields on it". Distinct from `dialog_panel` below (which
// mirrors the settings sheet); used for the node/edge creation forms.
pub const sheet: Color = 0x002E2A2A;
// Theme.draftField = Color(red: 0.118, green: 0.118, blue: 0.133) // #1e1e22.
pub const draft_field: Color = 0x00221E1E;
// Theme.onboardingSheet = Color(red: 0.137, green: 0.137, blue: 0.149) // #232326 --
// numerically identical to `dialog_panel`/`onboarding` background already in use.
pub const onboarding_sheet: Color = 0x00262323;

// Theme.folderGlyph = Color(red: 0.365, green: 0.647, blue: 0.937) -- "the Finder
// blue" (#5da5ef). Added for parity even though no Windows folder-glyph render call
// site currently exists; available for a future icon.
pub const folder_glyph: Color = 0x00EFA55D;

pub const loop_card_width: i32 = 250;
pub const loop_card_height: i32 = 106;
pub const loop_card_radius: i32 = 11;
pub const loop_card_stripe: i32 = 4;
pub const workspace_rail_width: i32 = 212;
pub const loop_bar_height: i32 = 46;
pub const loop_detail_width: i32 = 272;
pub const pane_header_height: i32 = 22;
pub const tab_bar_height: i32 = 30;
pub const canvas_grid_cell: i32 = 24;

// Shared dark dialog/sheet palette. Values match the already-validated
// WindowsProductSettings.zig sheet (settingsRgb(35,35,38) background,
// settingsRgb(245,245,247) titles, settingsRgb(190,190,198) body text,
// settingsRgb(135,135,142) muted/help text) and Sidebar.zig's ingress-error
// red (0x006060FF), so every legacy dialog now paints with the exact same
// dark native language instead of inventing a new one.
pub const dialog_panel: Color = 0x00262323;
pub const dialog_title_text: Color = 0x00F7F5F5;
pub const dialog_body_text: Color = 0x00C6BEBE;
pub const dialog_muted_text: Color = 0x008E8787;
pub const dialog_error_text: Color = 0x006060FF;
pub const dialog_field_background: Color = 0x00302B2B;
pub const dialog_field_border: Color = 0x00473F3F;

pub const sidebar_width: i32 = 220;
pub const header_height: i32 = 34;
pub const workspace_height: i32 = 250;
pub const activity_strip_height: i32 = 48;

pub fn rgb(color: Color) u32 {
    return color & 0x00FFFFFF;
}
