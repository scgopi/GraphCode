#include <windows.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <algorithm>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

namespace onboarding_uia {

constexpr UINT kFocusMessage = WM_APP + 60;

enum NodeId : int {
  kRoot = 0,
  kPage = 1,
  kSkip = 2,
  kBack = 3,
  kPrimary = 4,
  kClaudeCode = 5,
  kCopilotCli = 6,
  kCodex = 7,
};

struct State;

class Node final : public IRawElementProviderSimple,
                   public IRawElementProviderFragment,
                   public IRawElementProviderFragmentRoot,
                   public IInvokeProvider {
 public:
  Node(std::shared_ptr<State> state, int id);

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *value) override;
  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id, IUnknown **value) override;
  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *value) override;
  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(
      IRawElementProviderSimple **value) override;
  HRESULT STDMETHODCALLTYPE Navigate(
      NavigateDirection direction,
      IRawElementProviderFragment **value) override;
  HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **value) override;
  HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *value) override;
  HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **value) override;
  HRESULT STDMETHODCALLTYPE SetFocus() override;
  HRESULT STDMETHODCALLTYPE get_FragmentRoot(
      IRawElementProviderFragmentRoot **value) override;
  HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(
      double x, double y, IRawElementProviderFragment **value) override;
  HRESULT STDMETHODCALLTYPE GetFocus(
      IRawElementProviderFragment **value) override;
  HRESULT STDMETHODCALLTYPE Invoke() override;

  void shutdown();
  HRESULT update(int page, int focused, int backend);

 private:
  bool availableLocked() const;
  bool invokable() const;
  std::vector<int> childrenLocked() const;
  Node *createRetainedLocked(int id) const;
  HRESULT focusedElement(IRawElementProviderFragment **value);

  std::shared_ptr<State> state_;
  int id_;
  volatile LONG refs_ = 1;
};

struct State {
  std::mutex mutex;
  HWND hwnd{};
  Node *root{};
  int page = 0;
  int focused = kPrimary;
  int backend = 0;
  bool active = true;
};

static bool isAction(int id) {
  return id >= kSkip && id <= kCodex;
}

static bool hasNativeFocus(HWND hwnd) {
  GUITHREADINFO info{};
  info.cbSize = sizeof(info);
  return GetGUIThreadInfo(GetWindowThreadProcessId(hwnd, nullptr), &info) &&
      info.hwndFocus == hwnd && GetForegroundWindow() == hwnd &&
      IsWindowEnabled(hwnd);
}

static bool isAvailable(int id, int page) {
  if (id == kRoot || id == kPage || id == kSkip || id == kPrimary) return true;
  if (id == kBack) return page > 0;
  if (id >= kClaudeCode && id <= kCodex) return page == 4;
  return false;
}

static std::vector<int> childrenForPage(int page) {
  std::vector<int> children{kPage, kSkip};
  if (page > 0) children.push_back(kBack);
  if (page == 4) {
    children.push_back(kClaudeCode);
    children.push_back(kCopilotCli);
    children.push_back(kCodex);
  }
  children.push_back(kPrimary);
  return children;
}

static const wchar_t *pageName(int page) {
  static const wchar_t *names[] = {
      L"Welcome to GraphCode: Agents you can watch",
      L"How to read a loop",
      L"Four kinds of loop",
      L"One window per line of work",
      L"Which agent runs them",
  };
  return names[page >= 0 && page < 5 ? page : 0];
}

static const wchar_t *automationId(int id) {
  static const wchar_t *ids[] = {
      L"onboarding-root",
      L"onboarding-page",
      L"onboarding-skip",
      L"onboarding-back",
      L"onboarding-primary",
      L"onboarding-backend-claude-code",
      L"onboarding-backend-copilot-cli",
      L"onboarding-backend-codex",
  };
  return ids[id >= kRoot && id <= kCodex ? id : kRoot];
}

static const wchar_t *nameFor(int id, int page) {
  switch (id) {
    case kRoot: return L"GraphCode onboarding";
    case kPage: return pageName(page);
    case kSkip: return L"Skip onboarding";
    case kBack: return L"Back";
    case kPrimary: return page == 4 ? L"Get Started" : L"Continue";
    case kClaudeCode: return L"Claude Code";
    case kCopilotCli: return L"Copilot CLI";
    case kCodex: return L"Codex";
    default: return L"GraphCode onboarding";
  }
}

static CONTROLTYPEID controlType(int id) {
  if (id == kRoot) return UIA_WindowControlTypeId;
  if (id == kPage) return UIA_PaneControlTypeId;
  if (id >= kClaudeCode && id <= kCodex) return UIA_RadioButtonControlTypeId;
  return UIA_ButtonControlTypeId;
}

static RECT clientBounds(int id, int page) {
  switch (id) {
    case kPage: return RECT{32, 56, 528, 536};
    case kSkip: return RECT{474, 12, 540, 42};
    case kBack: return RECT{20, 564, 102, 604};
    case kPrimary: return RECT{418, 564, 540, 604};
    case kClaudeCode: return RECT{58, 182, 502, 248};
    case kCopilotCli: return RECT{58, 258, 502, 324};
    case kCodex: return RECT{58, 334, 502, 400};
    default:
      if (page >= 0) return RECT{0, 0, 560, 620};
      return RECT{};
  }
}

static HRESULT focusWindow(HWND hwnd) {
  const DWORD current_thread = GetCurrentThreadId();
  const DWORD window_thread = GetWindowThreadProcessId(hwnd, nullptr);
  const bool attach = window_thread != 0 && window_thread != current_thread;
  if (attach && !AttachThreadInput(current_thread, window_thread, TRUE))
    return HRESULT_FROM_WIN32(GetLastError());
  SetForegroundWindow(hwnd);
  SetLastError(ERROR_SUCCESS);
  if (::SetFocus(hwnd) == nullptr) {
    const DWORD error = GetLastError();
    if (attach) AttachThreadInput(current_thread, window_thread, FALSE);
    if (error != ERROR_SUCCESS) return HRESULT_FROM_WIN32(error);
  }
  if (attach) AttachThreadInput(current_thread, window_thread, FALSE);
  return S_OK;
}

Node::Node(std::shared_ptr<State> state, int id)
    : state_(std::move(state)), id_(id) {
  if (id_ == kRoot) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->root = this;
  }
}

HRESULT STDMETHODCALLTYPE Node::QueryInterface(REFIID iid, void **out) {
  if (!out) return E_POINTER;
  *out = nullptr;
  if (iid == IID_IUnknown || iid == __uuidof(IRawElementProviderSimple))
    *out = static_cast<IRawElementProviderSimple *>(this);
  else if (iid == __uuidof(IRawElementProviderFragment))
    *out = static_cast<IRawElementProviderFragment *>(this);
  else if (iid == __uuidof(IRawElementProviderFragmentRoot) && id_ == kRoot)
    *out = static_cast<IRawElementProviderFragmentRoot *>(this);
  else if (iid == __uuidof(IInvokeProvider) && invokable())
    *out = static_cast<IInvokeProvider *>(this);
  else
    return E_NOINTERFACE;
  AddRef();
  return S_OK;
}

ULONG STDMETHODCALLTYPE Node::AddRef() {
  return static_cast<ULONG>(InterlockedIncrement(&refs_));
}

ULONG STDMETHODCALLTYPE Node::Release() {
  const ULONG value = static_cast<ULONG>(InterlockedDecrement(&refs_));
  if (value == 0) delete this;
  return value;
}

HRESULT STDMETHODCALLTYPE Node::get_ProviderOptions(ProviderOptions *value) {
  if (!value) return E_POINTER;
  *value = static_cast<ProviderOptions>(
      ProviderOptions_ServerSideProvider |
      ProviderOptions_UseComThreading |
      ProviderOptions_ProviderOwnsSetFocus);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::GetPatternProvider(PATTERNID id, IUnknown **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  if (id != UIA_InvokePatternId || !invokable()) return S_FALSE;
  AddRef();
  *value = static_cast<IInvokeProvider *>(this);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::GetPropertyValue(PROPERTYID property, VARIANT *value) {
  if (!value) return E_POINTER;
  VariantInit(value);
  int page = 0;
  int focused = 0;
  int backend = 0;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    page = state_->page;
    focused = state_->focused;
    backend = state_->backend;
  }
  if (property == UIA_NamePropertyId ||
      property == UIA_AutomationIdPropertyId ||
      property == UIA_ItemStatusPropertyId) {
    const wchar_t *text = L"";
    if (property == UIA_NamePropertyId) text = nameFor(id_, page);
    if (property == UIA_AutomationIdPropertyId) text = automationId(id_);
    if (property == UIA_ItemStatusPropertyId &&
        id_ >= kClaudeCode && id_ <= kCodex) {
      text = backend == id_ - kClaudeCode ? L"Selected" : L"Not selected";
    }
    value->vt = VT_BSTR;
    value->bstrVal = SysAllocString(text);
    return value->bstrVal ? S_OK : E_OUTOFMEMORY;
  }
  if (property == UIA_ControlTypePropertyId) {
    value->vt = VT_I4;
    value->lVal = controlType(id_);
    return S_OK;
  }
  if (property == UIA_IsEnabledPropertyId ||
      property == UIA_IsControlElementPropertyId ||
      property == UIA_IsContentElementPropertyId ||
      property == UIA_IsKeyboardFocusablePropertyId ||
      property == UIA_HasKeyboardFocusPropertyId) {
    bool result = true;
    if (property == UIA_IsKeyboardFocusablePropertyId) result = isAction(id_);
    if (property == UIA_HasKeyboardFocusPropertyId)
      result = focused == id_ && hasNativeFocus(state_->hwnd);
    value->vt = VT_BOOL;
    value->boolVal = result ? VARIANT_TRUE : VARIANT_FALSE;
    return S_OK;
  }
  return S_FALSE;
}

HRESULT STDMETHODCALLTYPE Node::get_HostRawElementProvider(
    IRawElementProviderSimple **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  HWND hwnd = nullptr;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    if (id_ != kRoot) return S_OK;
    hwnd = state_->hwnd;
  }
  return UiaHostProviderFromHwnd(hwnd, value);
}

HRESULT STDMETHODCALLTYPE Node::Navigate(
    NavigateDirection direction, IRawElementProviderFragment **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  Node *target = nullptr;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    if (direction == NavigateDirection_Parent && id_ != kRoot) {
      target = createRetainedLocked(kRoot);
    } else if (id_ == kRoot &&
               (direction == NavigateDirection_FirstChild ||
                direction == NavigateDirection_LastChild)) {
      const auto children = childrenLocked();
      if (!children.empty()) {
        target = createRetainedLocked(
            direction == NavigateDirection_FirstChild
                ? children.front()
                : children.back());
      }
    } else if (id_ != kRoot &&
               (direction == NavigateDirection_NextSibling ||
                direction == NavigateDirection_PreviousSibling)) {
      const auto siblings = childrenLocked();
      const auto current = std::find(siblings.begin(), siblings.end(), id_);
      if (current != siblings.end()) {
        if (direction == NavigateDirection_NextSibling &&
            current + 1 != siblings.end())
          target = createRetainedLocked(*(current + 1));
        if (direction == NavigateDirection_PreviousSibling &&
            current != siblings.begin())
          target = createRetainedLocked(*(current - 1));
      }
    }
  }
  if (target) *value = static_cast<IRawElementProviderFragment *>(target);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::GetRuntimeId(SAFEARRAY **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
  }
  if (id_ == kRoot) return S_OK;
  *value = SafeArrayCreateVector(VT_I4, 0, 3);
  if (!*value) return E_OUTOFMEMORY;
  LONG values[] = {UiaAppendRuntimeId, 0x47434f, id_};
  for (LONG index = 0; index < 3; ++index)
    SafeArrayPutElement(*value, &index, &values[index]);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::get_BoundingRectangle(UiaRect *value) {
  if (!value) return E_POINTER;
  HWND hwnd = nullptr;
  int page = 0;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    hwnd = state_->hwnd;
    page = state_->page;
  }
  RECT bounds{};
  if (id_ == kRoot)
    GetClientRect(hwnd, &bounds);
  else
    bounds = clientBounds(id_, page);
  POINT origin{0, 0};
  ClientToScreen(hwnd, &origin);
  value->left = origin.x + bounds.left;
  value->top = origin.y + bounds.top;
  value->width = bounds.right - bounds.left;
  value->height = bounds.bottom - bounds.top;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::GetEmbeddedFragmentRoots(SAFEARRAY **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::SetFocus() {
  if (!isAction(id_)) return UIA_E_INVALIDOPERATION;
  HWND hwnd = nullptr;
  bool changed = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    changed = state_->focused != id_;
    state_->focused = id_;
    hwnd = state_->hwnd;
  }
  const HRESULT result = focusWindow(hwnd);
  if (FAILED(result)) return result;
  PostMessageW(hwnd, kFocusMessage, static_cast<WPARAM>(id_), 0);
  if (changed)
    UiaRaiseAutomationEvent(
        static_cast<IRawElementProviderSimple *>(this),
        UIA_AutomationFocusChangedEventId);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::get_FragmentRoot(
    IRawElementProviderFragmentRoot **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (!availableLocked() || !state_->root)
    return UIA_E_ELEMENTNOTAVAILABLE;
  state_->root->AddRef();
  *value = static_cast<IRawElementProviderFragmentRoot *>(state_->root);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::ElementProviderFromPoint(
    double x, double y, IRawElementProviderFragment **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  HWND hwnd = nullptr;
  int page = 0;
  std::vector<int> children;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    hwnd = state_->hwnd;
    page = state_->page;
    children = childrenLocked();
  }
  POINT point{static_cast<LONG>(x), static_cast<LONG>(y)};
  ScreenToClient(hwnd, &point);
  for (auto current = children.rbegin(); current != children.rend(); ++current) {
    const RECT bounds = clientBounds(*current, page);
    if (PtInRect(&bounds, point)) {
      auto *node = new (std::nothrow) Node(state_, *current);
      if (!node) return E_OUTOFMEMORY;
      *value = static_cast<IRawElementProviderFragment *>(node);
      return S_OK;
    }
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE Node::GetFocus(
    IRawElementProviderFragment **value) {
  return focusedElement(value);
}

HRESULT STDMETHODCALLTYPE Node::Invoke() {
  HWND hwnd = nullptr;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked() || !isAction(id_))
      return UIA_E_ELEMENTNOTENABLED;
    hwnd = state_->hwnd;
  }
  return PostMessageW(hwnd, WM_COMMAND, static_cast<WPARAM>(id_), 0)
      ? S_OK
      : HRESULT_FROM_WIN32(GetLastError());
}

void Node::shutdown() {
  if (id_ != kRoot) return;
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->active = false;
  state_->root = nullptr;
}

HRESULT Node::update(int page, int focused, int backend) {
  bool page_changed = false;
  bool focus_changed = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->active) return UIA_E_ELEMENTNOTAVAILABLE;
    page_changed = state_->page != page;
    focus_changed = state_->focused != focused;
    state_->page = page;
    state_->focused = focused;
    state_->backend = backend;
  }
  if (page_changed)
    UiaRaiseStructureChangedEvent(
        static_cast<IRawElementProviderSimple *>(this),
        StructureChangeType_ChildrenInvalidated, nullptr, 0);
  if (focus_changed) {
    auto *focused_node = new (std::nothrow) Node(state_, focused);
    if (!focused_node) return E_OUTOFMEMORY;
    UiaRaiseAutomationEvent(
        static_cast<IRawElementProviderSimple *>(focused_node),
        UIA_AutomationFocusChangedEventId);
    focused_node->Release();
  }
  return S_OK;
}

bool Node::availableLocked() const {
  return state_->active && isAvailable(id_, state_->page);
}

bool Node::invokable() const {
  std::lock_guard<std::mutex> lock(state_->mutex);
  return availableLocked() && isAction(id_);
}

std::vector<int> Node::childrenLocked() const {
  return childrenForPage(state_->page);
}

Node *Node::createRetainedLocked(int id) const {
  if (!isAvailable(id, state_->page)) return nullptr;
  if (id == kRoot) {
    if (!state_->root) return nullptr;
    state_->root->AddRef();
    return state_->root;
  }
  return new (std::nothrow) Node(state_, id);
}

HRESULT Node::focusedElement(IRawElementProviderFragment **value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  int focused = 0;
  HWND hwnd = nullptr;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!availableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    focused = state_->focused;
    hwnd = state_->hwnd;
    if (!isAvailable(focused, state_->page)) return S_OK;
  }
  if (!hasNativeFocus(hwnd)) return S_OK;
  auto *node = new (std::nothrow) Node(state_, focused);
  if (!node) return E_OUTOFMEMORY;
  *value = static_cast<IRawElementProviderFragment *>(node);
  return S_OK;
}

}  // namespace onboarding_uia

extern "C" IRawElementProviderSimple *gc_onboarding_uia_create(HWND hwnd) {
  auto state = std::make_shared<onboarding_uia::State>();
  state->hwnd = hwnd;
  return new (std::nothrow) onboarding_uia::Node(
      std::move(state), onboarding_uia::kRoot);
}

extern "C" void gc_onboarding_uia_release(
    IRawElementProviderSimple *provider) {
  if (!provider) return;
  auto *root = static_cast<onboarding_uia::Node *>(provider);
  root->shutdown();
  root->Release();
}

extern "C" LRESULT gc_onboarding_uia_get_object(
    HWND hwnd, WPARAM wparam, LPARAM lparam,
    IRawElementProviderSimple *provider) {
  if (!provider || lparam != UiaRootObjectId) return 0;
  return UiaReturnRawElementProvider(hwnd, wparam, lparam, provider);
}

extern "C" HRESULT gc_onboarding_uia_update(
    IRawElementProviderSimple *provider, int page, int focused, int backend) {
  if (!provider || page < 0 || page > 4 ||
      backend < 0 || backend > 2 ||
      !onboarding_uia::isAvailable(focused, page) ||
      !onboarding_uia::isAction(focused))
    return E_INVALIDARG;
  auto *root = static_cast<onboarding_uia::Node *>(provider);
  return root->update(page, focused, backend);
}
