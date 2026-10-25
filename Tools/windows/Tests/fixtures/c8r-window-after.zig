pub fn create(self: *Window, title: [*:0]const u16) !void {
    self.hwnd = c.CreateWindowExW(
        0,
        class_name.ptr,
        title,
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        1280,
        820,
        null,
        null,
        self.instance,
        @ptrCast(self),
    ) orelse return error.WindowCreationFailed;
    try installMenu(self.hwnd);
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
}
