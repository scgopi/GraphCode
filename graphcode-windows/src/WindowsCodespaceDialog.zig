//! The add-codespace sheet — a GitHub Codespace as a remote project, with
//! `gh codespace ssh` as the dial. The parity twin of the macOS `CodespaceFormView`
//! and the codespace half of `WelcomeFeature`.
//!
//! The picker is `gh codespace list`'s answer, so the sheet only ever offers
//! codespaces that actually exist; when there are none it points at GitHub's create
//! page instead — for the repositories already open in GraphCode when it can,
//! generically otherwise. Discovery and validation both run off the message loop, so
//! Cancel and Try Again stay live while gh is thinking.
//!
//! Chrome is the dark, keyboard-first Win32 posture the other GraphCode sheets use:
//! standard EDIT/LISTBOX/BUTTON controls (so UI Automation sees a real control tree
//! with no custom provider), a STATIC label immediately before each control to name
//! it, tab stops in reading order, Enter on the default button, and Escape to cancel.

const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const Tokens = @import("DesignTokens.zig");
const AppFont = @import("AppFont.zig");
const Codespaces = @import("Codespaces.zig");

pub const intro_text =
    "Add a GitHub Codespace as a remote project. Loops run in the codespace; this PC " ++
    "steers them. Needs the GitHub CLI signed in with the codespace scope, and zmx " ++
    "installed in the codespace. A stopped codespace is started by the connection.";

pub const loading_text = "Asking the GitHub CLI for your codespaces…";
pub const validating_text = "Connecting to the codespace and checking the repository path…";
pub const abandoning_text = "Waiting for the codespace connection to finish…";
pub const empty_text =
    "No codespaces yet. Create one on GitHub, then come back here to add it.";

/// What the sheet is showing right now. `failed` and `empty` are distinct on purpose:
/// one is a problem with a fix, the other is an account that simply has no codespaces
/// and needs a create link rather than a retry.
pub const Phase = enum { loading, ready, empty, failed, validating, abandoning };

/// The sheet's state, separated from its window so the flow — discovery, selection,
/// path prefill, submission — is exercised without a message loop.
pub const Model = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .loading,
    list: ?Codespaces.CodespaceList = null,
    /// Why discovery failed, in the words the human needs; `null` unless `failed`.
    list_failure: ?[]u8 = null,
    /// The last submission failure, cleared by any edit so a stale message cannot
    /// outlive the input that caused it.
    inline_failure: ?[]u8 = null,
    selection: ?usize = null,
    path: []u8 = &.{},
    /// `owner/repo` for the open local projects, so an empty list can offer "create
    /// one for the repository you're already working in".
    suggestions: [][]u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        if (self.list) |*list| list.deinit();
        self.list = null;
        self.clearListFailure();
        self.clearInlineFailure();
        if (self.path.len != 0) self.allocator.free(self.path);
        self.path = &.{};
        for (self.suggestions) |suggestion| self.allocator.free(suggestion);
        if (self.suggestions.len != 0) self.allocator.free(self.suggestions);
        self.suggestions = &.{};
    }

    fn clearListFailure(self: *Model) void {
        if (self.list_failure) |message| self.allocator.free(message);
        self.list_failure = null;
    }

    pub fn clearInlineFailure(self: *Model) void {
        if (self.inline_failure) |message| self.allocator.free(message);
        self.inline_failure = null;
    }

    pub fn setInlineFailure(self: *Model, message: []const u8) void {
        const copy = self.allocator.dupe(u8, message) catch return;
        self.clearInlineFailure();
        self.inline_failure = copy;
    }

    pub fn setSuggestions(self: *Model, suggestions: [][]u8) void {
        for (self.suggestions) |suggestion| self.allocator.free(suggestion);
        if (self.suggestions.len != 0) self.allocator.free(self.suggestions);
        self.suggestions = suggestions;
    }

    pub fn applyLoaded(self: *Model, list: Codespaces.CodespaceList) void {
        if (self.list) |*existing| existing.deinit();
        self.list = list;
        self.clearListFailure();
        self.phase = if (list.items.len == 0) .empty else .ready;
        if (list.items.len != 0) self.select(0);
    }

    pub fn applyFailure(self: *Model, failure: Codespaces.Failure) void {
        if (self.list) |*existing| existing.deinit();
        self.list = null;
        self.selection = null;
        const message = self.allocator.dupe(u8, Codespaces.failureMessage(failure)) catch null;
        self.clearListFailure();
        self.list_failure = message;
        self.phase = .failed;
    }

    /// Back to loading, which is what Try Again means: the old answer is dropped so a
    /// stale list can't be mistaken for the retry's result.
    pub fn beginRetry(self: *Model) void {
        if (self.list) |*existing| existing.deinit();
        self.list = null;
        self.selection = null;
        self.clearListFailure();
        self.clearInlineFailure();
        self.phase = .loading;
    }

    /// Prefill only when the human hasn't typed a path of their own — switching picks
    /// refreshes a default, never overwrites an edit made for another codespace of the
    /// same repository.
    pub fn select(self: *Model, index: usize) void {
        const list = self.list orelse return;
        if (index >= list.items.len) return;
        self.selection = index;
        self.clearInlineFailure();
        if (!self.pathIsDefault()) return;
        const prefill = list.items[index].defaultWorkspacePath(self.allocator) catch return;
        if (self.path.len != 0) self.allocator.free(self.path);
        self.path = prefill;
    }

    fn pathIsDefault(self: *Model) bool {
        if (self.path.len == 0) return true;
        const list = self.list orelse return false;
        for (list.items) |item| {
            const candidate = item.defaultWorkspacePath(self.allocator) catch continue;
            defer self.allocator.free(candidate);
            if (std.mem.eql(u8, candidate, self.path)) return true;
        }
        return false;
    }

    pub fn setPath(self: *Model, value: []const u8) void {
        const copy = self.allocator.dupe(u8, value) catch return;
        if (self.path.len != 0) self.allocator.free(self.path);
        self.path = copy;
        self.clearInlineFailure();
    }

    pub fn selected(self: *const Model) ?Codespaces.Codespace {
        const list = self.list orelse return null;
        const index = self.selection orelse return null;
        if (index >= list.items.len) return null;
        return list.items[index];
    }

    pub fn fields(self: *const Model) ?Codespaces.Fields {
        const codespace = self.selected() orelse return null;
        const trimmed = std.mem.trim(u8, self.path, " \t\r\n");
        const candidate = Codespaces.Fields{ .name = codespace.name, .path = trimmed };
        Codespaces.validate(candidate) catch return null;
        return candidate;
    }

    /// The Add button's enablement: a validatable identity, and nothing already in
    /// flight.
    pub fn canSubmit(self: *const Model) bool {
        return self.phase == .ready and self.fields() != null;
    }

    /// The repository the create link should point at: the selected codespace's when
    /// there is one, otherwise the first open local GitHub project.
    pub fn createRepository(self: *const Model) []const u8 {
        if (self.selected()) |codespace| return codespace.repository;
        if (self.suggestions.len != 0) return self.suggestions[0];
        return "";
    }

    /// What the sheet's status line says in every phase, so the message a human reads
    /// is a property of the state rather than of whichever branch last ran.
    pub fn statusText(self: *const Model) []const u8 {
        return switch (self.phase) {
            .loading => loading_text,
            .empty => empty_text,
            .failed => self.list_failure orelse Codespaces.failureMessage(.list_failed),
            .validating => validating_text,
            .abandoning => abandoning_text,
            .ready => "",
        };
    }
};

const dialog_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeCodespaceIngressDialog");
const title_text = "Add Codespace";
const id_list = 4120;
const id_path = 4121;
const id_retry = 4122;
const id_create = 4123;
const id_accept = 1;
const id_cancel = 2;
const timer_id: usize = 11;
const em_setcuebanner = 0x1501;

const DialogState = struct {
    allocator: std.mem.Allocator,
    parent: c.HWND,
    model: *Model,
    list_operation: ?*Codespaces.ListOperation = null,
    validation: ?*Codespaces.ValidationOperation = null,
    list_box: c.HWND = null,
    path_edit: c.HWND = null,
    status_label: c.HWND = null,
    error_label: c.HWND = null,
    retry_button: c.HWND = null,
    create_button: c.HWND = null,
    accept_button: c.HWND = null,
    updating_path: bool = false,
    accepted: bool = false,
    closed: bool = false,
};

var dialog_active = false;
var dialog_state: DialogState = undefined;
var dark_field_brush: c.HBRUSH = null;

/// The validated codespace the sheet produced. Owned by the caller; `null` when the
/// human cancelled.
pub const Accepted = struct {
    name: []u8,
    path: []u8,

    pub fn deinit(self: *Accepted, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Runs the sheet to completion. Discovery starts with the window, so the list is
/// already arriving while the human reads the intro; validation runs before the sheet
/// closes, which is what makes the returned identity one whose sessions can start.
pub fn open(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    local_project_paths: []const []const u8,
) !?Accepted {
    if (dialog_active) return error.CodespaceDialogAlreadyOpen;
    try registerClass();

    var model = Model.init(allocator);
    defer model.deinit();
    if (Codespaces.repositorySuggestions(allocator, local_project_paths)) |suggestions| {
        model.setSuggestions(suggestions);
    } else |_| {}

    dialog_state = .{ .allocator = allocator, .parent = parent, .model = &model };
    dialog_active = true;
    defer dialog_active = false;
    defer if (dialog_state.list_operation) |operation| operation.deinit();
    defer if (dialog_state.validation) |operation| operation.deinit();

    dialog_state.list_operation = Codespaces.ListOperation.start(allocator) catch null;
    if (dialog_state.list_operation == null) model.applyFailure(.list_failed);

    const wide_title = try wideZ(allocator, title_text);
    defer allocator.free(wide_title);
    const style = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU;
    const ex_style = c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT;
    var frame = c.RECT{ .left = 0, .top = 0, .right = 640, .bottom = 540 };
    _ = c.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const width = frame.right - frame.left;
    const height = frame.bottom - frame.top;
    var owner: c.RECT = undefined;
    _ = c.GetWindowRect(parent, &owner);
    const x = owner.left + @divTrunc((owner.right - owner.left) - width, 2);
    const y = owner.top + @divTrunc((owner.bottom - owner.top) - height, 2);
    const hwnd = c.CreateWindowExW(
        ex_style,
        dialog_class.ptr,
        wide_title.ptr,
        style,
        x,
        y,
        width,
        height,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.CodespaceDialogCreationFailed;

    _ = c.SetTimer(hwnd, timer_id, 100, null);
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetFocus(dialog_state.list_box);

    var message: c.MSG = undefined;
    while (!dialog_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            dialog_state.closed = true;
            break;
        }
        if (message.message == c.WM_KEYDOWN and message.wParam == c.VK_ESCAPE) {
            requestCancel();
            continue;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }

    _ = c.KillTimer(hwnd, timer_id);
    ModalTeardown.dismiss(hwnd, parent);
    if (!dialog_state.accepted) return null;
    const accepted = model.fields() orelse return null;
    const name = try allocator.dupe(u8, accepted.name);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, accepted.path);
    return Accepted{ .name = name, .path = path };
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&dialogProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = dialog_class.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    klass.hbrBackground = null;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.CodespaceDialogClassRegistrationFailed;
}

fn dialogProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!dialog_active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            createControls(hwnd);
            refreshPresentation();
            return 0;
        },
        c.WM_ERASEBKGND => return eraseBackground(hwnd, wparam),
        c.WM_CTLCOLORSTATIC => return colorStatic(controlHandleFrom(lparam), wparam),
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX => return colorField(wparam),
        c.WM_TIMER => {
            if (wparam == timer_id) pollOperations();
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            switch (command) {
                id_accept => submit(),
                id_cancel => requestCancel(),
                id_retry => retry(),
                id_create => openCreatePage(hwnd),
                id_list => {
                    if (notification == c.LBN_SELCHANGE) selectionChanged();
                    if (notification == c.LBN_DBLCLK) submit();
                },
                id_path => {
                    if (notification == c.EN_CHANGE and !dialog_state.updating_path) pathChanged();
                },
                else => {},
            }
            return 0;
        },
        c.WM_CLOSE => {
            requestCancel();
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn createControls(hwnd: c.HWND) void {
    const state = &dialog_state;
    _ = createStatic(hwnd, intro_text, 24, 20, 592, 58, 0);
    // Every interactive control is preceded in z-order by the STATIC that names it,
    // which is how UI Automation and Narrator derive a name for a bare Win32 control.
    _ = createStatic(hwnd, "Codespace", 24, 90, 592, 20, 0);
    state.list_box = createControl(
        hwnd,
        c.WS_EX_CLIENTEDGE,
        "LISTBOX",
        "",
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.WS_VSCROLL | c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT,
        24,
        114,
        592,
        180,
        id_list,
    );
    state.status_label = createStatic(hwnd, loading_text, 24, 302, 592, 54, 0);
    _ = createStatic(hwnd, "Repository path inside the codespace", 24, 362, 592, 20, 0);
    state.path_edit = createControl(
        hwnd,
        c.WS_EX_CLIENTEDGE,
        "EDIT",
        "",
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        24,
        386,
        592,
        28,
        id_path,
    );
    const cue = wideZ(state.allocator, "/workspaces/repository — absolute") catch null;
    if (cue) |value| {
        defer state.allocator.free(value);
        _ = c.SendMessageW(state.path_edit, em_setcuebanner, 1, @bitCast(@intFromPtr(value.ptr)));
    }
    state.error_label = createStatic(hwnd, "", 24, 424, 592, 40, 0);
    state.create_button = createButton(hwnd, "Create on GitHub…", id_create, 24, 476, 168, 30, false);
    state.retry_button = createButton(hwnd, "Try Again", id_retry, 200, 476, 108, 30, false);
    _ = createButton(hwnd, "Cancel", id_cancel, 430, 476, 88, 30, false);
    state.accept_button = createButton(hwnd, "Add", id_accept, 528, 476, 88, 30, true);
}

fn pollOperations() void {
    const state = &dialog_state;
    if (state.list_operation) |operation| {
        if (operation.poll()) |status| {
            switch (status) {
                .loaded => if (operation.takeList()) |list| state.model.applyLoaded(list) else state.model.applyFailure(.unreadable_list),
                .failed => state.model.applyFailure(operation.failure),
                .loading => return,
            }
            operation.deinit();
            state.list_operation = null;
            refreshPresentation();
        }
        return;
    }
    if (state.validation) |operation| {
        const status = operation.poll() orelse return;
        operation.deinit();
        state.validation = null;
        const abandoned = state.model.phase == .abandoning;
        switch (status) {
            .succeeded => {
                if (abandoned) {
                    state.closed = true;
                    return;
                }
                state.accepted = true;
                state.closed = true;
                return;
            },
            else => {
                if (abandoned) {
                    state.closed = true;
                    return;
                }
                state.model.phase = .ready;
                state.model.setInlineFailure(
                    "The codespace could not be reached, or that path isn't a Git repository inside it. " ++
                        "Check the path, then try again.",
                );
                refreshPresentation();
            },
        }
    }
}

fn selectionChanged() void {
    const selected = c.SendMessageW(dialog_state.list_box, c.LB_GETCURSEL, 0, 0);
    if (selected < 0) return;
    dialog_state.model.select(@intCast(selected));
    syncPathEdit();
    refreshPresentation();
}

fn pathChanged() void {
    const allocator = dialog_state.allocator;
    const value = readControlText(allocator, dialog_state.path_edit) catch return;
    defer allocator.free(value);
    dialog_state.model.setPath(value);
    refreshPresentation();
}

fn retry() void {
    if (dialog_state.list_operation != null) return;
    dialog_state.model.beginRetry();
    dialog_state.list_operation = Codespaces.ListOperation.start(dialog_state.allocator) catch null;
    if (dialog_state.list_operation == null) dialog_state.model.applyFailure(.list_failed);
    refreshPresentation();
}

/// Cancel is honest about an in-flight dial: the sheet stops taking input and waits
/// for gh to return rather than tearing a live child process out from under itself.
fn requestCancel() void {
    if (dialog_state.validation != null) {
        dialog_state.model.phase = .abandoning;
        refreshPresentation();
        return;
    }
    dialog_state.closed = true;
}

fn submit() void {
    const state = &dialog_state;
    if (state.model.phase != .ready) return;
    const fields = state.model.fields() orelse {
        const codespace = state.model.selected();
        const message = if (codespace == null)
            Codespaces.validationMessage(error.MissingCodespaceName)
        else blk: {
            const trimmed = std.mem.trim(u8, state.model.path, " \t\r\n");
            Codespaces.validate(.{ .name = codespace.?.name, .path = trimmed }) catch |err|
                break :blk Codespaces.validationMessage(err);
            break :blk Codespaces.validationMessage(error.MissingCodespacePath);
        };
        state.model.setInlineFailure(message);
        refreshPresentation();
        return;
    };
    state.model.clearInlineFailure();
    state.validation = Codespaces.ValidationOperation.start(state.allocator, fields) catch null;
    if (state.validation == null) {
        state.model.setInlineFailure("The codespace connection could not be started.");
        refreshPresentation();
        return;
    }
    state.model.phase = .validating;
    refreshPresentation();
}

fn openCreatePage(hwnd: c.HWND) void {
    const allocator = dialog_state.allocator;
    const url = Codespaces.createURLFor(allocator, dialog_state.model.createRepository()) catch return;
    defer allocator.free(url);
    const wide = wideZ(allocator, url) catch return;
    defer allocator.free(wide);
    _ = c.ShellExecuteW(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("open").ptr,
        wide.ptr,
        null,
        null,
        c.SW_SHOWNORMAL,
    );
}

fn syncPathEdit() void {
    dialog_state.updating_path = true;
    setControlText(dialog_state.path_edit, dialog_state.model.path);
    dialog_state.updating_path = false;
}

/// One place decides what every control shows, from the model — the reason a failed
/// retry can't leave a stale list behind or an enabled Add without a selection.
fn refreshPresentation() void {
    const state = &dialog_state;
    const model = state.model;
    if (model.phase == .ready or model.phase == .empty) refillList();
    setControlText(state.status_label, model.statusText());
    _ = c.ShowWindow(state.status_label, if (model.statusText().len == 0) c.SW_HIDE else c.SW_SHOW);
    setControlText(state.error_label, model.inline_failure orelse "");
    const busy = model.phase == .validating or model.phase == .abandoning or model.phase == .loading;
    _ = c.EnableWindow(state.list_box, @intFromBool(model.phase == .ready));
    _ = c.EnableWindow(state.path_edit, @intFromBool(model.phase == .ready));
    _ = c.EnableWindow(state.accept_button, @intFromBool(model.canSubmit()));
    _ = c.EnableWindow(state.retry_button, @intFromBool(!busy));
    _ = c.EnableWindow(state.create_button, @intFromBool(!busy));
}

fn refillList() void {
    const state = &dialog_state;
    _ = c.SendMessageW(state.list_box, c.LB_RESETCONTENT, 0, 0);
    const list = state.model.list orelse return;
    for (list.items) |item| {
        const label = item.rowLabel(state.allocator) catch continue;
        defer state.allocator.free(label);
        const wide = wideZ(state.allocator, label) catch continue;
        defer state.allocator.free(wide);
        _ = c.SendMessageW(state.list_box, c.LB_ADDSTRING, 0, @bitCast(@intFromPtr(wide.ptr)));
    }
    if (state.model.selection) |index| _ = c.SendMessageW(state.list_box, c.LB_SETCURSEL, index, 0);
    syncPathEdit();
}

fn eraseBackground(hwnd: c.HWND, wparam: c.WPARAM) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const brush = c.CreateSolidBrush(Tokens.dialog_panel);
    if (brush != null) {
        _ = c.FillRect(hdc, &client, brush);
        _ = c.DeleteObject(brush);
    }
    return 1;
}

fn colorStatic(control: c.HWND, wparam: c.WPARAM) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    _ = c.SetTextColor(hdc, if (control == dialog_state.error_label)
        Tokens.dialog_error_text
    else
        Tokens.dialog_body_text);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    return @intCast(@intFromPtr(c.GetStockObject(c.NULL_BRUSH)));
}

fn colorField(wparam: c.WPARAM) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    _ = c.SetTextColor(hdc, Tokens.dialog_title_text);
    _ = c.SetBkColor(hdc, Tokens.dialog_field_background);
    _ = c.SetBkMode(hdc, c.OPAQUE);
    if (dark_field_brush == null) dark_field_brush = c.CreateSolidBrush(Tokens.dialog_field_background);
    return @intCast(@intFromPtr(dark_field_brush));
}

fn deviceContextFrom(wparam: c.WPARAM) c.HDC {
    return Win32.opaquePointerFromInt(c.HDC, wparam);
}

fn controlHandleFrom(lparam: c.LPARAM) c.HWND {
    return Win32.messagePointer(c.HWND, lparam);
}

fn createStatic(hwnd: c.HWND, text: []const u8, x: i32, y: i32, width: i32, height: i32, id: usize) c.HWND {
    return createControl(hwnd, 0, "STATIC", text, c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, x, y, width, height, id);
}

fn createButton(hwnd: c.HWND, text: []const u8, id: usize, x: i32, y: i32, width: i32, height: i32, default: bool) c.HWND {
    return createControl(
        hwnd,
        0,
        "BUTTON",
        text,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | @as(c.LONG, if (default) 1 else 0),
        x,
        y,
        width,
        height,
        id,
    );
}

fn createControl(
    hwnd: c.HWND,
    ex_style: c.DWORD,
    class: []const u8,
    text: []const u8,
    style: c.LONG,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    id: usize,
) c.HWND {
    const allocator = dialog_state.allocator;
    const wide_class = wideZ(allocator, class) catch return null;
    defer allocator.free(wide_class);
    const wide_text = wideZ(allocator, text) catch return null;
    defer allocator.free(wide_text);
    const control = c.CreateWindowExW(
        ex_style,
        wide_class.ptr,
        wide_text.ptr,
        @bitCast(style),
        x,
        y,
        width,
        height,
        hwnd,
        controlId(id),
        c.GetModuleHandleW(null),
        null,
    ) orelse return null;
    AppFont.apply(control, AppFont.control_size, false);
    return control;
}

fn controlId(id: usize) c.HMENU {
    if (id == 0) return null;
    return Win32.opaquePointerFromInt(c.HMENU, id);
}

fn readControlText(allocator: std.mem.Allocator, control: c.HWND) ![]u8 {
    const length: usize = @intCast(c.GetWindowTextLengthW(control));
    const wide = try allocator.alloc(u16, length + 1);
    defer allocator.free(wide);
    const copied = c.GetWindowTextW(control, wide.ptr, @intCast(wide.len));
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..@intCast(copied)]);
}

fn setControlText(control: c.HWND, value: []const u8) void {
    if (control == null) return;
    const wide = wideZ(dialog_state.allocator, value) catch return;
    defer dialog_state.allocator.free(wide);
    _ = c.SetWindowTextW(control, wide.ptr);
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

fn testList(allocator: std.mem.Allocator, json: []const u8) !Codespaces.CodespaceList {
    return Codespaces.parseList(allocator, json);
}

test "the sheet starts in loading and says what it is waiting for" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expectEqual(Phase.loading, model.phase);
    try std.testing.expectEqualStrings(loading_text, model.statusText());
    try std.testing.expect(!model.canSubmit());
}

test "a loaded list selects the first codespace and prefills its workspace path" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.applyLoaded(try testList(std.testing.allocator,
        \\[{"name":"dev-widget","displayName":"widget","repository":"octo/widget","state":"Available"},
        \\ {"name":"dev-gadget","displayName":"gadget","repository":"octo/gadget","state":"Shutdown"}]
    ));
    try std.testing.expectEqual(Phase.ready, model.phase);
    try std.testing.expectEqualStrings("dev-widget", model.selected().?.name);
    try std.testing.expectEqualStrings("/workspaces/widget", model.path);
    try std.testing.expect(model.canSubmit());
    try std.testing.expectEqualStrings("", model.statusText());

    // Switching picks refreshes an untouched default…
    model.select(1);
    try std.testing.expectEqualStrings("/workspaces/gadget", model.path);

    // …and never overwrites a path the human typed.
    model.setPath("/srv/custom");
    model.select(0);
    try std.testing.expectEqualStrings("/srv/custom", model.path);
}

test "an empty account is offered a create link rather than a retry" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const suggestions = try std.testing.allocator.alloc([]u8, 1);
    suggestions[0] = try std.testing.allocator.dupe(u8, "octo/widget");
    model.setSuggestions(suggestions);
    model.applyLoaded(try testList(std.testing.allocator, "[]"));
    try std.testing.expectEqual(Phase.empty, model.phase);
    try std.testing.expect(!model.canSubmit());
    try std.testing.expectEqualStrings(empty_text, model.statusText());
    try std.testing.expectEqualStrings("octo/widget", model.createRepository());

    const url = try Codespaces.createURLFor(std.testing.allocator, model.createRepository());
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://codespaces.new/octo/widget", url);
}

test "a discovery failure shows its fix and retry returns to loading" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.applyLoaded(try testList(std.testing.allocator,
        \\[{"name":"dev-widget","displayName":"widget","repository":"octo/widget","state":"Available"}]
    ));
    model.applyFailure(.missing_codespace_scope);
    try std.testing.expectEqual(Phase.failed, model.phase);
    try std.testing.expect(model.list == null);
    try std.testing.expectEqual(@as(?Codespaces.Codespace, null), model.selected());
    try std.testing.expect(std.mem.indexOf(u8, model.statusText(), "gh auth refresh") != null);
    try std.testing.expect(!model.canSubmit());

    model.beginRetry();
    try std.testing.expectEqual(Phase.loading, model.phase);
    try std.testing.expectEqualStrings(loading_text, model.statusText());
}

test "submission is blocked while a dial is in flight and while the path is unusable" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.applyLoaded(try testList(std.testing.allocator,
        \\[{"name":"dev-widget","displayName":"widget","repository":"octo/widget","state":"Available"}]
    ));
    try std.testing.expect(model.canSubmit());

    model.phase = .validating;
    try std.testing.expect(!model.canSubmit());
    try std.testing.expectEqualStrings(validating_text, model.statusText());
    model.phase = .abandoning;
    try std.testing.expectEqualStrings(abandoning_text, model.statusText());

    model.phase = .ready;
    model.setPath("workspaces/widget");
    try std.testing.expectEqual(@as(?Codespaces.Fields, null), model.fields());
    try std.testing.expect(!model.canSubmit());

    model.setPath("  /workspaces/widget  ");
    try std.testing.expectEqualStrings("/workspaces/widget", model.fields().?.path);
    try std.testing.expect(model.canSubmit());
}

test "an inline failure survives until the next edit" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.applyLoaded(try testList(std.testing.allocator,
        \\[{"name":"dev-widget","displayName":"widget","repository":"octo/widget","state":"Available"}]
    ));
    model.setInlineFailure("The codespace could not be reached.");
    try std.testing.expectEqualStrings("The codespace could not be reached.", model.inline_failure.?);
    model.setPath("/workspaces/other");
    try std.testing.expectEqual(@as(?[]u8, null), model.inline_failure);
}

test "sheet copy states the trade and the codespace requirements" {
    try std.testing.expect(std.mem.indexOf(u8, intro_text, "codespace scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, intro_text, "zmx") != null);
    try std.testing.expect(std.mem.indexOf(u8, intro_text, "stopped codespace is started") != null);
}
