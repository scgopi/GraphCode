#include <windows.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <cwchar>
#include <string>
#include <vector>

extern "C" IRawElementProviderSimple *gc_uia_create(HWND hwnd);
extern "C" void gc_uia_release(IRawElementProviderSimple *provider);
extern "C" HRESULT gc_uia_update(IRawElementProviderSimple *provider, const char *status,
                                   const char **identities, const char **names,
                                   const int *parents, const int *selected,
                                   const int *eligible, const int *invokable,
                                   const int *bounds, int count, int allow_reclaim,
                                   int confirm_each_reclaim);

static int failures = 0;
static int checks = 0;

static void check(bool condition, const char *description) {
  ++checks;
  if (!condition) {
    ++failures;
    std::fprintf(stderr, "FAIL: %s\n", description);
  }
}

static IRawElementProviderFragment *child(
    IRawElementProviderFragment *parent, NavigateDirection direction) {
  IRawElementProviderFragment *result = nullptr;
  check(parent && parent->Navigate(direction, &result) == S_OK && result,
        "native UIA navigation returns the requested element");
  return result;
}

static void checkName(IRawElementProviderFragment *fragment, const wchar_t *expected) {
  IRawElementProviderSimple *simple = nullptr;
  check(fragment && fragment->QueryInterface(IID_PPV_ARGS(&simple)) == S_OK,
        "retained fragment supports the native property API");
  if (!simple) return;
  VARIANT value;
  VariantInit(&value);
  const HRESULT result = simple->GetPropertyValue(UIA_NamePropertyId, &value);
  check(result == S_OK && value.vt == VT_BSTR &&
            value.bstrVal && std::wcscmp(value.bstrVal, expected) == 0,
        "retained element exposes the expected published name");
  VariantClear(&value);
  simple->Release();
}

typedef HRESULT (*FullUpdate)(IRawElementProviderSimple *, const char *, const char **,
                              const char **, const int *, const int *, const int *,
                              const int *, const int *, int, int, int, int, int, int, int);

static std::wstring stringProperty(IRawElementProviderFragment *fragment, PROPERTYID property) {
  std::wstring result;
  IRawElementProviderSimple *simple = nullptr;
  if (!fragment || fragment->QueryInterface(IID_PPV_ARGS(&simple)) != S_OK) return result;
  VARIANT value;
  VariantInit(&value);
  if (simple->GetPropertyValue(property, &value) == S_OK && value.vt == VT_BSTR && value.bstrVal)
    result = value.bstrVal;
  VariantClear(&value);
  simple->Release();
  return result;
}

static bool offscreenProperty(IRawElementProviderFragment *fragment) {
  bool result = false;
  IRawElementProviderSimple *simple = nullptr;
  if (!fragment || fragment->QueryInterface(IID_PPV_ARGS(&simple)) != S_OK) return result;
  VARIANT value;
  VariantInit(&value);
  if (simple->GetPropertyValue(UIA_IsOffscreenPropertyId, &value) == S_OK && value.vt == VT_BOOL)
    result = value.boolVal != VARIANT_FALSE;
  VariantClear(&value);
  simple->Release();
  return result;
}

static bool invokable(IRawElementProviderFragment *fragment) {
  IRawElementProviderSimple *simple = nullptr;
  if (!fragment || fragment->QueryInterface(IID_PPV_ARGS(&simple)) != S_OK) return false;
  IUnknown *pattern = nullptr;
  const bool result = simple->GetPatternProvider(UIA_InvokePatternId, &pattern) == S_OK && pattern;
  if (pattern) pattern->Release();
  simple->Release();
  return result;
}

static void checkRect(IRawElementProviderFragment *fragment, POINT origin,
                      LONG left, LONG top, LONG width, LONG height, const char *description) {
  UiaRect rect{};
  const bool ok = fragment && fragment->get_BoundingRectangle(&rect) == S_OK &&
      rect.left == origin.x + left && rect.top == origin.y + top &&
      rect.width == width && rect.height == height;
  check(ok, description);
}

extern "C" HRESULT gc_uia_set_canvas_bounds(IRawElementProviderSimple *provider, int left, int top,
                                             int right, int bottom);
extern "C" HRESULT gc_uia_set_sidebar_scroll(IRawElementProviderSimple *provider, int offset,
                                              int max_offset, int viewport);

// Resolves a client-relative point through the root fragment, as UIA does for coordinate
// hit-testing, and checks the element it names (nullptr: no element under the point).
static void expectHit(IRawElementProviderFragmentRoot *root, POINT origin, double x, double y,
                      const wchar_t *expected_name, const char *description) {
  IRawElementProviderFragment *hit = nullptr;
  const HRESULT result = root->ElementProviderFromPoint(origin.x + x, origin.y + y, &hit);
  bool ok = result == S_OK;
  if (ok) {
    if (!expected_name) {
      ok = hit == nullptr;
    } else {
      ok = hit != nullptr && stringProperty(hit, UIA_NamePropertyId) == expected_name;
    }
  }
  if (!ok) {
    std::fwprintf(stderr, L"  point (%.0f,%.0f): expected %ls, got %ls (hr=0x%08lx)\n", x, y,
                  expected_name ? expected_name : L"nothing",
                  hit ? stringProperty(hit, UIA_NamePropertyId).c_str() : L"nothing",
                  static_cast<unsigned long>(result));
  }
  check(ok, description);
  if (hit) hit->Release();
}

// UIA coordinate hit-testing must resolve to the row, destination, banner or header under the
// point (not the focused element), honour z-order, and return nothing where nothing is drawn.
static void nativeHitTestChecks(IRawElementProviderSimple *provider, HWND hwnd) {
  POINT origin{0, 0};
  ClientToScreen(hwnd, &origin);
  IRawElementProviderFragmentRoot *root = nullptr;
  check(provider->QueryInterface(IID_PPV_ARGS(&root)) == S_OK && root,
        "provider is a fragment root for hit-testing");
  if (!root) return;
  const char *identities[] = {
      "header-attention:needs-you", "loop:under-header", "overview-destination:graph",
      "quick-chats-destination:quick-chats", "loop:visible", "loop:scrolled-out",
      "needs-you-row:a", "needs-you-stop:a", "loop:under-banner", "sidebar-update-banner:update"};
  const char *names[] = {"Needs you header", "Row under header", "Graph destination",
                         "Quick Chats destination", "Visible row", "Scrolled-out row",
                         "Needs you row", "Stop loop", "Row under banner", "Update available"};
  const int parents[] = {1, 2, 1, 1, 2, 2, 1, 1, 2, 1};
  const int none[] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  const int actions[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
  const int bounds[] = {
      100, 10, 200, 40,    // header
      12, 20, 232, 60,     // row published (wrongly) under the header: the header must win
      12, 150, 232, 176,   // Graph destination
      0, 0, 0, 0,          // Quick Chats destination, scrolled out
      12, 200, 232, 226,   // visible loop row
      0, 0, 0, 0,          // scrolled-out loop row
      12, 300, 232, 330,   // needs-you row
      166, 306, 218, 326,  // its Stop button, nested inside the row
      12, 480, 232, 520,   // row published (wrongly) under the banner: the banner must win
      8, 500, 212, 550,    // update banner
  };
  auto update = reinterpret_cast<FullUpdate>(&gc_uia_update);
  check(update(provider, "Hit testing", identities, names, parents, none, none, actions, bounds,
               10, 0, 1, 0, 0, 0, 0) == S_OK,
        "hit-testing publication succeeds");

  expectHit(root, origin, 100, 210, L"Visible row", "a point over a visible row resolves to that row");
  expectHit(root, origin, 100, 160, L"Graph", "a point over the Graph destination resolves to the fixed Graph destination");
  expectHit(root, origin, 190, 315, L"Stop loop", "a nested control wins over the row that contains it");
  expectHit(root, origin, 50, 315, L"Needs you row", "the row resolves where its control is not");
  expectHit(root, origin, 150, 30, L"Needs you header", "the header is above a row published under it");
  expectHit(root, origin, 50, 30, L"Row under header", "the row resolves where the header does not cover it");
  expectHit(root, origin, 100, 510, L"Update available", "the banner is above a row published under it");
  expectHit(root, origin, 20, 490, L"Row under banner", "the row resolves where the banner does not cover it");
  expectHit(root, origin, 100, 300 - 40, nullptr, "an empty region resolves to nothing, not the focused element");
  expectHit(root, origin, 100, 100, nullptr, "where a scrolled-out row would have been resolves to nothing");
  expectHit(root, origin, 500, 600, nullptr, "a point outside every published element resolves to nothing");
  expectHit(root, origin, 232, 210, nullptr, "an element's right edge is exclusive");
  expectHit(root, origin, 12, 200, L"Visible row", "an element's left/top edge is inclusive");

  // The real canvas rect is the lowest layer: only reported bounds make it hit-testable.
  expectHit(root, origin, 600, 400, nullptr, "an unreported canvas is not hit-testable");
  check(gc_uia_set_canvas_bounds(provider, 240, 34, 1200, 800) == S_OK, "canvas bounds publish");
  IRawElementProviderFragment *canvas = nullptr;
  check(root->ElementProviderFromPoint(origin.x + 600, origin.y + 400, &canvas) == S_OK && canvas &&
            stringProperty(canvas, UIA_AutomationIdPropertyId) == L"graph",
        "a point over the reported canvas resolves to the canvas element");
  if (canvas) canvas->Release();
  expectHit(root, origin, 100, 210, L"Visible row", "rows still win outside the canvas");
  root->Release();
}

// The sidebar's Graph and Quick Chats destinations, its scrolled rows, and its update
// banner must publish exactly their drawn rect, and an element scrolled out of the visible
// region must be reported offscreen rather than sharing another element's rect.
static void nativeSidebarGeometryChecks(IRawElementProviderSimple *provider, HWND hwnd,
                                        IRawElementProviderFragment *root) {
  POINT origin{0, 0};
  ClientToScreen(hwnd, &origin);
  const char *identities[] = {"sidebar-update-banner:update", "overview-destination:graph",
                              "quick-chats-destination:quick-chats", "loop:hidden", "loop:shown"};
  const char *names[] = {"Update available", "Graph", "Quick Chats", "Hidden", "Shown"};
  const int parents[] = {1, 1, 1, 2, 2};
  const int none[] = {0, 0, 0, 0, 0};
  const int actions[] = {1, 1, 1, 1, 1};
  const int bounds[] = {8, 500, 212, 550,  12, 150, 232, 176,  0, 0, 0, 0,  0, 0, 0, 0,  12, 200, 232, 226};
  auto update = reinterpret_cast<FullUpdate>(&gc_uia_update);
  check(update(provider, "Geometry", identities, names, parents, none, none, actions, bounds,
               5, 0, 1, 0, 0, 0, 0) == S_OK,
        "sidebar geometry publication succeeds");

  auto *projects = child(root, NavigateDirection_FirstChild);
  auto *banner = child(projects, NavigateDirection_FirstChild);
  auto *overview = child(banner, NavigateDirection_NextSibling);
  auto *chats = child(overview, NavigateDirection_NextSibling);
  check(stringProperty(banner, UIA_AutomationIdPropertyId).rfind(L"sidebar-update-banner-", 0) == 0,
        "update banner publishes a stable sidebar-update-banner automation id");
  checkName(banner, L"Update available");
  check(invokable(banner), "update banner exposes the invoke pattern");
  checkRect(banner, origin, 8, 500, 204, 50, "update banner bounds equal the drawn rect");
  check(!offscreenProperty(banner), "drawn update banner is not offscreen");
  check(stringProperty(overview, UIA_AutomationIdPropertyId) == L"overview-destination",
        "Graph destination keeps its fixed automation id");
  checkRect(overview, origin, 12, 150, 220, 26, "Graph destination bounds follow the published drawn rect");
  check(!offscreenProperty(overview), "visible Graph destination is not offscreen");
  check(stringProperty(chats, UIA_AutomationIdPropertyId) == L"quick-chats-destination",
        "Quick Chats destination keeps its fixed automation id");
  checkRect(chats, origin, 0, 0, 0, 0, "scrolled-out Quick Chats destination publishes an empty rect");
  check(offscreenProperty(chats), "scrolled-out Quick Chats destination is offscreen");

  auto *first_list = child(root, NavigateDirection_FirstChild);
  auto *loop_list = child(first_list, NavigateDirection_NextSibling);
  auto *hidden = child(loop_list, NavigateDirection_FirstChild);
  auto *shown = child(hidden, NavigateDirection_NextSibling);
  checkName(hidden, L"Hidden");
  check(offscreenProperty(hidden), "scrolled-out loop row is offscreen");
  checkName(shown, L"Shown");
  check(!offscreenProperty(shown), "visible loop row is not offscreen");
  checkRect(shown, origin, 12, 200, 220, 26, "visible loop row bounds equal the drawn rect");

  // Without a published destination rect the fixed elements keep their placeholder geometry.
  const char *plain_identities[] = {"loop:shown"};
  const char *plain_names[] = {"Shown"};
  const int plain_parents[] = {2};
  const int plain_flags[] = {0};
  check(update(provider, "Geometry", plain_identities, plain_names, plain_parents, plain_flags,
               plain_flags, plain_flags, nullptr, 1, 0, 1, 0, 0, 0, 0) == S_OK,
        "publication without destination rects succeeds");
  auto *fallback = child(projects, NavigateDirection_FirstChild);
  check(stringProperty(fallback, UIA_AutomationIdPropertyId) == L"overview-destination",
        "destination rows never become dynamic rows");
  checkRect(fallback, origin, 8, 142, 220, 24, "Graph destination falls back to its placeholder rect");
  check(!offscreenProperty(fallback), "placeholder Graph destination is not offscreen");
  if (fallback) fallback->Release();
  if (shown) shown->Release();
  if (hidden) hidden->Release();
  if (loop_list) loop_list->Release();
  if (first_list) first_list->Release();
  if (chats) chats->Release();
  if (overview) overview->Release();
  if (banner) banner->Release();
  if (projects) projects->Release();
}

// A window that records the commands and sidebar-scroll requests the provider sends it, the way
// the shell's window procedure receives them.
static const UINT kSidebarScrollMessage = WM_APP + 47;
enum ScrollOperation { kScrollSetPercent = 5, kScrollIntoView = 6 };
struct SentMessage { WPARAM wparam; LPARAM lparam; };
static std::vector<WPARAM> posted_commands;
static std::vector<SentMessage> sidebar_scroll_requests;
static LRESULT sidebar_scroll_result = 1;

static LRESULT CALLBACK captureProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_COMMAND) posted_commands.push_back(wparam);
  if (message == kSidebarScrollMessage) {
    sidebar_scroll_requests.push_back({wparam, lparam});
    return sidebar_scroll_result;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

static HWND createCaptureWindow() {
  static ATOM atom = 0;
  if (!atom) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = captureProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"GraphCodeUiaNativeCapture";
    atom = RegisterClassW(&window_class);
  }
  return CreateWindowW(L"GraphCodeUiaNativeCapture", L"UIA native capture", WS_OVERLAPPED,
                       0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
}

static void drainMessages(HWND window) {
  MSG message;
  while (PeekMessageW(&message, window, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
}

static uint64_t identityPayload(const char *identity) {
  uint64_t hash = 1469598103934665603ULL;
  for (const char *cursor = identity; *cursor; ++cursor) {
    hash ^= static_cast<unsigned char>(*cursor);
    hash *= 1099511628211ULL;
  }
  return hash & 0x0fffffffffffffffULL;
}

static IUnknown *pattern(IRawElementProviderFragment *fragment, PATTERNID id) {
  IRawElementProviderSimple *simple = nullptr;
  if (!fragment || fragment->QueryInterface(IID_PPV_ARGS(&simple)) != S_OK) return nullptr;
  IUnknown *result = nullptr;
  if (simple->GetPatternProvider(id, &result) != S_OK) result = nullptr;
  simple->Release();
  return result;
}

// The update banner must be invokable through COM, and Invoke must post exactly the command
// the shell maps back to the banner's click action (the same update offer).
static void nativeBannerInvokeChecks(IRawElementProviderSimple *provider, HWND hwnd,
                                     IRawElementProviderFragment *root) {
  const char *identities[] = {"sidebar-update-banner:update"};
  const char *names[] = {"Update available"};
  const int parents[] = {1};
  const int none[] = {0};
  const int actions[] = {1};
  const int bounds[] = {8, 500, 212, 550};
  auto update = reinterpret_cast<FullUpdate>(&gc_uia_update);
  check(update(provider, "Banner", identities, names, parents, none, none, actions, bounds,
               1, 0, 1, 0, 0, 0, 0) == S_OK,
        "banner publication succeeds");
  auto *projects = child(root, NavigateDirection_FirstChild);
  auto *banner = child(projects, NavigateDirection_FirstChild);
  checkName(banner, L"Update available");
  auto *invoke = static_cast<IInvokeProvider *>(pattern(banner, UIA_InvokePatternId));
  check(invoke != nullptr, "the banner exposes IInvokeProvider through GetPatternProvider");
  posted_commands.clear();
  if (invoke) {
    check(invoke->Invoke() == S_OK, "invoking the banner through COM succeeds");
    invoke->Release();
  }
  check(posted_commands.empty(), "Invoke posts rather than running the offer inside the UIA call");
  drainMessages(hwnd);
  // 0x83fd6a5f429785e1 is the dynamic-invoke tag over FNV-1a("sidebar-update-banner:update"),
  // the value graphcode-windows App.zig asserts maps to the banner's click action.
  check(posted_commands.size() == 1 && posted_commands[0] == 0x83fd6a5f429785e1ULL,
        "Invoke posts the exact dynamic-invoke command for the banner identity");
  if (banner) banner->Release();
  if (projects) projects->Release();
}

// The sidebar lists scroll as one viewport, and every row that scrolls with it can be brought
// into view through UIA, so keyboard and assistive clients can reach rows that are offscreen.
static void nativeScrollChecks(IRawElementProviderSimple *provider, HWND hwnd,
                               IRawElementProviderFragment *root) {
  const char *identities[] = {"loop:far", "overview-destination:graph", "header-jump:jump",
                              "sidebar-update-banner:update"};
  const char *names[] = {"Far loop", "Graph", "Jump", "Update available"};
  const int parents[] = {2, 1, 1, 1};
  const int none[] = {0, 0, 0, 0};
  // Bit 0 invokable, bit 1 scrolls with the sidebar.
  const int actions[] = {3, 3, 1, 1};
  const int bounds[] = {0, 0, 0, 0,  12, 150, 232, 176,  100, 10, 200, 40,  8, 500, 212, 550};
  auto update = reinterpret_cast<FullUpdate>(&gc_uia_update);
  check(update(provider, "Scroll", identities, names, parents, none, none, actions, bounds,
               4, 0, 1, 0, 0, 0, 0) == S_OK,
        "scroll publication succeeds");

  auto *projects = child(root, NavigateDirection_FirstChild);
  auto *loops = child(projects, NavigateDirection_NextSibling);
  auto *worktrees = child(loops, NavigateDirection_NextSibling);
  IRawElementProviderFragment *containers[] = {projects, loops, worktrees};
  for (auto *container : containers) {
    auto *scroll = static_cast<IScrollProvider *>(pattern(container, UIA_ScrollPatternId));
    check(scroll != nullptr, "each sidebar list exposes IScrollProvider");
    if (scroll) scroll->Release();
  }
  auto *root_scroll = pattern(root, UIA_ScrollPatternId);
  check(root_scroll == nullptr, "the window root is not a scroll container");

  auto *scroll = static_cast<IScrollProvider *>(pattern(loops, UIA_ScrollPatternId));
  sidebar_scroll_requests.clear();
  sidebar_scroll_result = 1;
  if (scroll) {
    // Until the shell publishes a scrollable extent there is nothing to scroll.
    BOOL scrollable = TRUE;
    double percent = 0, view = 0, horizontal_percent = 0, horizontal_view = 0;
    BOOL horizontal = TRUE;
    check(scroll->get_VerticallyScrollable(&scrollable) == S_OK && !scrollable,
          "a sidebar that fits its viewport is not vertically scrollable");
    check(scroll->get_VerticalScrollPercent(&percent) == S_OK && percent == UIA_ScrollPatternNoScroll,
          "a sidebar that fits reports UIA_ScrollPatternNoScroll");
    check(scroll->Scroll(ScrollAmount_NoAmount, ScrollAmount_LargeIncrement) == UIA_E_INVALIDOPERATION,
          "scrolling a sidebar that fits its viewport is an invalid operation");

    // 200 of a possible 800 with a 400 high viewport: 25% down, a third of the content visible.
    check(gc_uia_set_sidebar_scroll(provider, 200, 800, 400) == S_OK, "sidebar scroll state publishes");
    check(scroll->get_VerticallyScrollable(&scrollable) == S_OK && scrollable,
          "a sidebar taller than its viewport is vertically scrollable");
    check(scroll->get_VerticalScrollPercent(&percent) == S_OK && std::fabs(percent - 25.0) < 0.001,
          "the vertical scroll percent is offset over maximum offset");
    check(scroll->get_VerticalViewSize(&view) == S_OK && std::fabs(view - 100.0 / 3.0) < 0.001,
          "the vertical view size is the visible fraction of the content");
    check(scroll->get_HorizontalScrollPercent(&horizontal_percent) == S_OK &&
              horizontal_percent == UIA_ScrollPatternNoScroll &&
              scroll->get_HorizontalViewSize(&horizontal_view) == S_OK && horizontal_view == 100.0 &&
              scroll->get_HorizontallyScrollable(&horizontal) == S_OK && !horizontal,
          "the sidebar reports no horizontal scrolling");
    check(gc_uia_set_sidebar_scroll(provider, 5000, 800, 400) == S_OK &&
              scroll->get_VerticalScrollPercent(&percent) == S_OK && percent == 100.0,
          "an offset beyond the maximum is clamped");
    check(gc_uia_set_sidebar_scroll(provider, 200, 800, 400) == S_OK, "sidebar scroll state republishes");

    check(scroll->Scroll(ScrollAmount_NoAmount, ScrollAmount_LargeIncrement) == S_OK,
          "a vertical page scroll succeeds");
    check(scroll->Scroll(ScrollAmount_NoAmount, ScrollAmount_SmallDecrement) == S_OK,
          "a vertical line scroll succeeds");
    check(scroll->Scroll(ScrollAmount_SmallIncrement, ScrollAmount_NoAmount) == UIA_E_INVALIDOPERATION,
          "the sidebar does not scroll horizontally");
    check(scroll->SetScrollPercent(UIA_ScrollPatternNoScroll, 50.0) == S_OK,
          "setting the vertical scroll percent succeeds");
    check(scroll->SetScrollPercent(UIA_ScrollPatternNoScroll, 150.0) == E_INVALIDARG,
          "an out-of-range scroll percent is rejected");
    check(scroll->SetScrollPercent(10.0, UIA_ScrollPatternNoScroll) == UIA_E_INVALIDOPERATION,
          "a horizontal scroll percent is rejected");
    scroll->Release();
  }
  check(sidebar_scroll_requests.size() == 3, "only the three valid scroll requests reach the shell");
  if (sidebar_scroll_requests.size() == 3) {
    check(sidebar_scroll_requests[0].wparam == ScrollAmount_LargeIncrement,
          "the page scroll carries its UIA scroll amount");
    check(sidebar_scroll_requests[1].wparam == ScrollAmount_SmallDecrement,
          "the line scroll carries its UIA scroll amount");
    check(sidebar_scroll_requests[2].wparam == kScrollSetPercent &&
              sidebar_scroll_requests[2].lparam == 5000,
          "the scroll percent is carried in hundredths of a percent");
  }

  auto *far_row = child(loops, NavigateDirection_FirstChild);
  // The sidebar's own children are its published rows first, then the fixed Graph destination.
  auto *jump = child(projects, NavigateDirection_FirstChild);
  auto *banner = child(jump, NavigateDirection_NextSibling);
  auto *graph = child(banner, NavigateDirection_NextSibling);
  checkName(far_row, L"Far loop");
  checkName(jump, L"Jump");
  checkName(banner, L"Update available");
  checkName(graph, L"Graph");

  sidebar_scroll_requests.clear();
  auto *far_item = static_cast<IScrollItemProvider *>(pattern(far_row, UIA_ScrollItemPatternId));
  check(far_item != nullptr, "an offscreen sidebar row exposes IScrollItemProvider");
  if (far_item) {
    check(far_item->ScrollIntoView() == S_OK, "scrolling an offscreen row into view succeeds");
    far_item->Release();
  }
  check(sidebar_scroll_requests.size() == 1 &&
            sidebar_scroll_requests[0].wparam == kScrollIntoView &&
            static_cast<uint64_t>(sidebar_scroll_requests[0].lparam) == identityPayload("loop:far"),
        "ScrollIntoView asks the shell to reveal exactly that row's identity");
  sidebar_scroll_result = 0;
  far_item = static_cast<IScrollItemProvider *>(pattern(far_row, UIA_ScrollItemPatternId));
  if (far_item) {
    check(far_item->ScrollIntoView() == UIA_E_INVALIDOPERATION,
          "a shell that cannot reveal the row fails ScrollIntoView instead of reporting success");
    far_item->Release();
  }
  sidebar_scroll_result = 1;

  auto *destination_item = static_cast<IScrollItemProvider *>(pattern(graph, UIA_ScrollItemPatternId));
  check(destination_item != nullptr, "the Graph destination exposes IScrollItemProvider");
  if (destination_item) destination_item->Release();
  check(pattern(jump, UIA_ScrollItemPatternId) == nullptr, "a fixed header does not scroll into view");
  check(pattern(banner, UIA_ScrollItemPatternId) == nullptr, "the fixed update banner does not scroll into view");

  if (banner) banner->Release();
  if (jump) jump->Release();
  if (graph) graph->Release();
  if (far_row) far_row->Release();
  if (worktrees) worktrees->Release();
  if (loops) loops->Release();
  if (projects) projects->Release();
}

static void nativeCommandAndScrollChecks() {
  HWND capture = createCaptureWindow();
  check(capture != nullptr, "capture window exists");
  if (!capture) return;
  IRawElementProviderSimple *provider = gc_uia_create(capture);
  check(provider != nullptr, "capture provider exists");
  if (provider) {
    IRawElementProviderFragment *root = nullptr;
    check(provider->QueryInterface(IID_PPV_ARGS(&root)) == S_OK, "capture root fragment exists");
    if (root) {
      nativeBannerInvokeChecks(provider, capture, root);
      nativeScrollChecks(provider, capture, root);
      root->Release();
    }
    gc_uia_release(provider);
  }
  DestroyWindow(capture);
}

int main() {
  HWND hwnd = CreateWindowW(L"STATIC", L"UIA native test", WS_OVERLAPPED,
                            0, 0, 100, 100, nullptr, nullptr, nullptr, nullptr);
  check(hwnd != nullptr, "native window exists");
  if (!hwnd) return 1;
  nativeCommandAndScrollChecks();

  auto *provider = gc_uia_create(hwnd);
  check(provider != nullptr, "native provider exists");
  if (!provider) return 1;
  const char *identities[] = {"worktree:test"};
  const char *names[] = {"Original"};
  const int parents[] = {3};
  const int flags[] = {0};
  check(gc_uia_update(provider, "Ready", identities, names, parents,
                      flags, flags, flags, nullptr, 1, 0, 1) == S_OK,
        "initial native publication succeeds");

  IRawElementProviderFragment *root = nullptr;
  check(provider->QueryInterface(IID_PPV_ARGS(&root)) == S_OK, "root fragment exists");
  auto *projects = child(root, NavigateDirection_FirstChild);
  auto *loops = child(projects, NavigateDirection_NextSibling);
  auto *worktrees = child(loops, NavigateDirection_NextSibling);
  auto *retained = child(worktrees, NavigateDirection_FirstChild);
  auto *graph = child(worktrees, NavigateDirection_NextSibling);
  auto *actions = child(graph, NavigateDirection_NextSibling);
  auto *status = child(actions, NavigateDirection_NextSibling);
  checkName(retained, L"Original");
  checkName(status, L"Ready");

  check(gc_uia_update(provider, "\xff", identities, names, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "malformed UTF-8 status is rejected");
  checkName(status, L"Ready");
  const char *bad_utf8[] = {"\xff", "\xc0\xaf", "\xed\xa0\x80", "\xe2\x82"};
  for (const char *bad : bad_utf8) {
    const char *invalid_names[] = {bad};
    const char *invalid_identities[] = {bad};
    check(gc_uia_update(provider, "Changed", identities, invalid_names, parents,
                        flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
          "malformed name is rejected");
    check(gc_uia_update(provider, "Changed", invalid_identities, names, parents,
                        flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
          "malformed identity is rejected");
    checkName(retained, L"Original");
    checkName(status, L"Ready");
  }
  check(gc_uia_update(provider, "Changed", nullptr, names, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "missing row identities are rejected without changing the tree");
  check(gc_uia_update(provider, "Changed", identities, nullptr, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "missing row names are rejected without changing the tree");
  const char *missing_name[] = {nullptr};
  check(gc_uia_update(provider, "Changed", identities, missing_name, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "null individual row name is rejected without changing the tree");
  check(gc_uia_update(provider, "Changed", identities, names, parents,
                      flags, flags, nullptr, nullptr, 1, 1, 0) == E_INVALIDARG,
        "missing row flag array is rejected without changing the tree");
  checkName(retained, L"Original");
  checkName(status, L"Ready");

  check(gc_uia_update(provider, "Cleared", nullptr, nullptr, nullptr,
                      nullptr, nullptr, nullptr, nullptr, 0, 0, 1) == S_OK,
        "subsequent valid empty publication succeeds");
  IRawElementProviderSimple *old_simple = nullptr;
  if (retained && retained->QueryInterface(IID_PPV_ARGS(&old_simple)) == S_OK) {
    VARIANT value;
    VariantInit(&value);
    check(old_simple->GetPropertyValue(UIA_NamePropertyId, &value) ==
              UIA_E_ELEMENTNOTAVAILABLE,
          "removed retained row is unavailable");
    VariantClear(&value);
    old_simple->Release();
  }
  checkName(status, L"Cleared");

  const char *unicode_names[] = {"Caf\xc3\xa9"};
  check(gc_uia_update(provider, "Restored", identities, unicode_names, parents,
                      flags, flags, flags, nullptr, 1, 0, 1) == S_OK,
        "valid UTF-8 remains publishable");
  auto *replacement = child(worktrees, NavigateDirection_FirstChild);
  checkName(replacement, L"Caf\u00e9");
  IRawElementProviderSimple *retired_simple = nullptr;
  if (retained && retained->QueryInterface(IID_PPV_ARGS(&retired_simple)) == S_OK) {
    VARIANT value;
    VariantInit(&value);
    check(retired_simple->GetPropertyValue(UIA_NamePropertyId, &value) ==
              UIA_E_ELEMENTNOTAVAILABLE,
          "reusing a row identity does not revive a retired provider reference");
    VariantClear(&value);
    retired_simple->Release();
  }
  if (replacement) replacement->Release();
  nativeSidebarGeometryChecks(provider, hwnd, root);
  nativeHitTestChecks(provider, hwnd);
  if (status) status->Release();
  if (actions) actions->Release();
  if (graph) graph->Release();
  if (retained) retained->Release();
  if (worktrees) worktrees->Release();
  if (loops) loops->Release();
  if (projects) projects->Release();
  if (root) root->Release();
  gc_uia_release(provider);
  DestroyWindow(hwnd);
  std::printf("Native accessibility provider: %d checks, %d failures\n", checks, failures);
  return failures || checks == 0 ? 1 : 0;
}
