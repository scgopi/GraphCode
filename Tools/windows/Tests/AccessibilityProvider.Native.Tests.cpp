#include <windows.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <cstdio>
#include <cwchar>
#include <string>

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

int main() {
  HWND hwnd = CreateWindowW(L"STATIC", L"UIA native test", WS_OVERLAPPED,
                            0, 0, 100, 100, nullptr, nullptr, nullptr, nullptr);
  check(hwnd != nullptr, "native window exists");
  if (!hwnd) return 1;

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
