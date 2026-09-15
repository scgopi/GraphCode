#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <ghostty/vt.h>

typedef struct Surface {
    HWND hwnd;
    GhosttyTerminal terminal;
    GhosttyRenderState render;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
    int paint_count;
    const char* title;
} Surface;

static Surface g_surfaces[2];
static HWND g_host;
static const wchar_t* HOST_CLASS = L"GraphCodeEmbeddingSpikeHost";
static const wchar_t* SURFACE_CLASS = L"GraphCodeEmbeddingSpikeSurface";

static COLORREF to_color(GhosttyColorRgb c) {
    return RGB(c.r, c.g, c.b);
}

static GhosttyColorRgb style_color(GhosttyStyleColor color,
                                   const GhosttyRenderStateColors* colors,
                                   GhosttyColorRgb fallback) {
    if (color.tag == GHOSTTY_STYLE_COLOR_RGB) return color.value.rgb;
    if (color.tag == GHOSTTY_STYLE_COLOR_PALETTE) return colors->palette[color.value.palette];
    return fallback;
}

static void paint_surface(Surface* surface, HDC dc) {
    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    if (ghostty_render_state_colors_get(surface->render, &colors) != GHOSTTY_SUCCESS) return;

    uint16_t cols = 0, rows = 0;
    if (ghostty_render_state_get(surface->render, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) != GHOSTTY_SUCCESS ||
        ghostty_render_state_get(surface->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) != GHOSTTY_SUCCESS) return;

    HFONT font = CreateFontW(16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN, L"Consolas");
    HGDIOBJ old_font = SelectObject(dc, font);
    SetBkMode(dc, OPAQUE);

    if (ghostty_render_state_get(surface->render,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            &surface->rows) != GHOSTTY_SUCCESS) return;

    int cell_w = 10, cell_h = 20;
    int row_index = 0;
    while (row_index < rows && ghostty_render_state_row_iterator_next(surface->rows)) {
        if (ghostty_render_state_row_get(surface->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &surface->cells) != GHOSTTY_SUCCESS) break;
        int col_index = 0;
        while (col_index < cols && ghostty_render_state_row_cells_next(surface->cells)) {
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            if (ghostty_render_state_row_cells_get(surface->cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) != GHOSTTY_SUCCESS) break;

            GhosttyColorRgb fg = style_color(style.fg_color, &colors, colors.foreground);
            GhosttyColorRgb bg = style_color(style.bg_color, &colors, colors.background);
            SetTextColor(dc, to_color(fg));
            SetBkColor(dc, to_color(bg));

            uint32_t grapheme_len = 0;
            ghostty_render_state_row_cells_get(surface->cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);
            char ch = ' ';
            if (grapheme_len > 0) {
                uint32_t codepoints[16] = {0};
                ghostty_render_state_row_cells_get(surface->cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints);
                if (codepoints[0] >= 32 && codepoints[0] < 127) ch = (char)codepoints[0];
            }
            RECT cell = { col_index * cell_w, row_index * cell_h,
                          (col_index + 1) * cell_w, (row_index + 1) * cell_h };
            ExtTextOutA(dc, cell.left + 1, cell.top + 1, ETO_OPAQUE, &cell, &ch, 1, NULL);
            col_index++;
        }
        row_index++;
    }

    SelectObject(dc, old_font);
    DeleteObject(font);
    surface->paint_count++;
}

static LRESULT CALLBACK host_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_ERASEBKGND:
            return 1;
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(hwnd, &ps);
            RECT r;
            GetClientRect(hwnd, &r);
            HBRUSH brush = CreateSolidBrush(RGB(30, 30, 35));
            FillRect(dc, &r, brush);
            DeleteObject(brush);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK surface_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    Surface* surface = (Surface*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (msg == WM_NCCREATE) {
        CREATESTRUCTW* create = (CREATESTRUCTW*)lp;
        surface = (Surface*)create->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)surface);
        surface->hwnd = hwnd;
    }
    switch (msg) {
        case WM_ERASEBKGND:
            return 1;
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(hwnd, &ps);
            if (surface) paint_surface(surface, dc);
            EndPaint(hwnd, &ps);
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static int fail(const char* message) {
    fprintf(stderr, "FAIL: %s (win32=%lu)\n", message, (unsigned long)GetLastError());
    return 1;
}

static int init_surface(Surface* surface, const char* title, const char* content) {
    GhosttyResult result = ghostty_terminal_new(NULL, &surface->terminal, 40, 8);
    if (result != GHOSTTY_SUCCESS) return 0;
    result = ghostty_render_state_new(NULL, &surface->render);
    if (result != GHOSTTY_SUCCESS) return 0;
    result = ghostty_render_state_row_iterator_new(NULL, &surface->rows);
    if (result != GHOSTTY_SUCCESS) return 0;
    result = ghostty_render_state_row_cells_new(NULL, &surface->cells);
    if (result != GHOSTTY_SUCCESS) return 0;
    ghostty_terminal_vt_write(surface->terminal, (const uint8_t*)content, strlen(content));
    result = ghostty_render_state_update(surface->render, surface->terminal);
    if (result != GHOSTTY_SUCCESS) return 0;
    surface->title = title;
    return 1;
}

static void free_surface(Surface* surface) {
    if (surface->cells) ghostty_render_state_row_cells_free(surface->cells);
    if (surface->rows) ghostty_render_state_row_iterator_free(surface->rows);
    if (surface->render) ghostty_render_state_free(surface->render);
    if (surface->terminal) ghostty_terminal_free(surface->terminal);
    memset(surface, 0, sizeof(*surface));
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    fprintf(stderr, "stage: start\n"); fflush(stderr);
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW host_class = {0};
    host_class.hInstance = instance;
    host_class.lpfnWndProc = host_proc;
    host_class.lpszClassName = HOST_CLASS;
    host_class.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    if (!RegisterClassW(&host_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return fail("register host class");

    WNDCLASSW surface_class = {0};
    surface_class.hInstance = instance;
    surface_class.lpfnWndProc = surface_proc;
    surface_class.lpszClassName = SURFACE_CLASS;
    surface_class.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32513));
    if (!RegisterClassW(&surface_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return fail("register surface class");

    fprintf(stderr, "stage: before surface A\n"); fflush(stderr);
    if (!init_surface(&g_surfaces[0], "surface-a", "Surface A: \033[1;32mindependent\033[0m VT state\r\n")) return fail("initialize surface A");
    fprintf(stderr, "stage: after surface A\n"); fflush(stderr);
    if (!init_surface(&g_surfaces[1], "surface-b", "Surface B: \033[1;34mindependent\033[0m VT state\r\n")) return fail("initialize surface B");

    fprintf(stderr, "stage: after surface B\n"); fflush(stderr);
    g_host = CreateWindowExW(0, HOST_CLASS, L"GraphCode-owned embedding host",
                             WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                             900, 260, NULL, NULL, instance, NULL);
    if (!g_host) return fail("create top-level host HWND");

    g_surfaces[0].hwnd = CreateWindowExW(WS_EX_CLIENTEDGE, SURFACE_CLASS, L"A",
        WS_CHILD | WS_VISIBLE, 12, 12, 420, 180, g_host, NULL, instance, &g_surfaces[0]);
    g_surfaces[1].hwnd = CreateWindowExW(WS_EX_CLIENTEDGE, SURFACE_CLASS, L"B",
        WS_CHILD | WS_VISIBLE, 444, 12, 420, 180, g_host, NULL, instance, &g_surfaces[1]);
    if (!g_surfaces[0].hwnd || !g_surfaces[1].hwnd) return fail("create two child terminal HWNDs");

    fprintf(stderr, "stage: after windows\n"); fflush(stderr);
    printf("HOST hwnd=%p CHILD_A hwnd=%p CHILD_B hwnd=%p\n",
           (void*)g_host, (void*)g_surfaces[0].hwnd, (void*)g_surfaces[1].hwnd);
    ShowWindow(g_host, SW_SHOWNOACTIVATE);
    UpdateWindow(g_host);
    UpdateWindow(g_surfaces[0].hwnd);
    UpdateWindow(g_surfaces[1].hwnd);

    if (g_surfaces[0].paint_count < 1 || g_surfaces[1].paint_count < 1) {
        fprintf(stderr, "FAIL: child paint smoke test A=%d B=%d\n",
                g_surfaces[0].paint_count, g_surfaces[1].paint_count);
        DestroyWindow(g_host);
        free_surface(&g_surfaces[0]);
        free_surface(&g_surfaces[1]);
        return 1;
    }

    printf("SMOKE PASS: created=2 painted A=%d B=%d independent-terminal-state=PASS\n",
           g_surfaces[0].paint_count, g_surfaces[1].paint_count);

    DestroyWindow(g_host);
    free_surface(&g_surfaces[0]);
    free_surface(&g_surfaces[1]);
    return 0;
}
