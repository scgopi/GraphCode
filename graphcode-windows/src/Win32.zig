pub const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0601");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
    @cInclude("sddl.h");
    @cInclude("winghostty/win32_host.h");
});
