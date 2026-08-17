#include <windows.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <memory>
#include <string>
#include <vector>

namespace {

// Stable fragment IDs: root -> six top-level containers; Worktrees owns only rows;
// Actions owns the command and policy controls.
constexpr int kRootChildren[] = {1, 2, 3, 4, 5, 6};
constexpr int kActionChildren[] = {7, 8, 9, 10, 11, 12, 13};

class Node;
struct State {
  HWND hwnd{};
  Node *root{};
  std::wstring status = L"Ready";
  std::vector<std::wstring> rows;
  std::vector<bool> selected;
  std::vector<bool> eligible;
  int focused = 0;
  bool allow_reclaim = false;
  bool confirm_each_reclaim = true;
};

static std::wstring wide(const char *value) {
  if (!value) return {};
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, const_cast<wchar_t *>(result.data()), length);
  result.pop_back();
  return result;
}

class Node final : public IRawElementProviderSimple,
                   public IRawElementProviderFragment,
                   public IRawElementProviderFragmentRoot,
                   public IInvokeProvider,
                   public ISelectionProvider,
                   public ISelectionItemProvider,
                   public IToggleProvider {
 public:
  Node(std::shared_ptr<State> state, int id) : state_(std::move(state)), id_(id), refs_(1) {
    if (id_ == 0) state_->root = this;
  }
  ~Node() {
    if (id_ == 0 && state_->root == this) state_->root = nullptr;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (iid == IID_IUnknown || iid == __uuidof(IRawElementProviderSimple))
      *out = static_cast<IRawElementProviderSimple *>(this);
    else if (iid == __uuidof(IRawElementProviderFragment))
      *out = static_cast<IRawElementProviderFragment *>(this);
    else if (iid == __uuidof(IRawElementProviderFragmentRoot) && id_ == 0)
      *out = static_cast<IRawElementProviderFragmentRoot *>(this);
    else if (iid == __uuidof(IInvokeProvider) && supportsInvoke())
      *out = static_cast<IInvokeProvider *>(this);
    else if (iid == __uuidof(ISelectionProvider) && id_ == 3)
      *out = static_cast<ISelectionProvider *>(this);
    else if (iid == __uuidof(ISelectionItemProvider) && isRow())
      *out = static_cast<ISelectionItemProvider *>(this);
    else if (iid == __uuidof(IToggleProvider) && (id_ == 12 || id_ == 13))
      *out = static_cast<IToggleProvider *>(this);
    else
      return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&refs_));
  }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG value = static_cast<ULONG>(InterlockedDecrement(&refs_));
    if (value == 0) delete this;
    return value;
  }

  HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *value) override {
    if (!value) return E_POINTER;
    *value = ProviderOptions_ServerSideProvider;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id, IUnknown **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (id == UIA_InvokePatternId && supportsInvoke())
      *value = static_cast<IInvokeProvider *>(this);
    else if (id == UIA_SelectionPatternId && id_ == 3)
      *value = static_cast<ISelectionProvider *>(this);
    else if (id == UIA_SelectionItemPatternId && isRow())
      *value = static_cast<ISelectionItemProvider *>(this);
    else if (id == UIA_TogglePatternId && (id_ == 12 || id_ == 13))
      *value = static_cast<IToggleProvider *>(this);
    else
      return S_FALSE;
    AddRef();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *value) override {
    if (!value) return E_POINTER;
    VariantInit(value);
    if (property == UIA_NamePropertyId) {
      value->vt = VT_BSTR;
      value->bstrVal = SysAllocString(name().c_str());
      return value->bstrVal ? S_OK : E_OUTOFMEMORY;
    }
    if (property == UIA_AutomationIdPropertyId) {
      value->vt = VT_BSTR;
      value->bstrVal = SysAllocString(automationId().c_str());
      return value->bstrVal ? S_OK : E_OUTOFMEMORY;
    }
    if (property == UIA_ControlTypePropertyId) {
      value->vt = VT_I4;
      value->lVal = controlType();
      return S_OK;
    }
    if (property == UIA_IsKeyboardFocusablePropertyId || property == UIA_IsEnabledPropertyId ||
        property == UIA_IsControlElementPropertyId || property == UIA_IsContentElementPropertyId) {
      value->vt = VT_BOOL;
      value->boolVal = VARIANT_TRUE;
      return S_OK;
    }
    if (property == UIA_LiveSettingPropertyId && id_ == 6) {
      value->vt = VT_I4;
      value->lVal = 1;
      return S_OK;
    }
    if (property == UIA_ValueValuePropertyId && id_ == 6) {
      value->vt = VT_BSTR;
      value->bstrVal = SysAllocString(state_->status.c_str());
      return value->bstrVal ? S_OK : E_OUTOFMEMORY;
    }
    return S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **value) override {
    if (!value) return E_POINTER;
    return UiaHostProviderFromHwnd(state_->hwnd, value);
  }

  HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction,
                                      IRawElementProviderFragment **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    const int parent = parentId();
    if (direction == NavigateDirection_Parent && parent >= 0) return make(parent, value);
    if (direction == NavigateDirection_FirstChild) return make(firstChild(), value);
    if (direction == NavigateDirection_LastChild) return make(lastChild(), value);
    if (direction == NavigateDirection_NextSibling) return make(sibling(1), value);
    if (direction == NavigateDirection_PreviousSibling) return make(sibling(-1), value);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **value) override {
    if (!value) return E_POINTER;
    *value = SafeArrayCreateVector(VT_I4, 0, 3);
    if (!*value) return E_OUTOFMEMORY;
    LONG values[3] = { UiaAppendRuntimeId, 0x475243, id_ };
    for (LONG i = 0; i < 3; ++i) SafeArrayPutElement(*value, &i, &values[i]);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *value) override {
    if (!value) return E_POINTER;
    RECT rect{};
    GetWindowRect(state_->hwnd, &rect);
    value->left = rect.left;
    value->top = rect.top + (isRow() ? (id_ - 100 + 1) * 34 : 0);
    value->width = rect.right - rect.left;
    value->height = isRow() ? 32 : 28;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetFocus() override {
    ::SetFocus(state_->hwnd);
    const int old = state_->focused;
    state_->focused = id_;
    if (old != id_) UiaRaiseAutomationEvent(this, UIA_AutomationFocusChangedEventId);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (!state_->root) return UIA_E_ELEMENTNOTAVAILABLE;
    return state_->root->QueryInterface(
        __uuidof(IRawElementProviderFragmentRoot), reinterpret_cast<void **>(value));
  }
  HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double, double,
                                                      IRawElementProviderFragment **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    return make(state_->focused, value);
  }
  HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    return make(state_->focused, value);
  }

  HRESULT STDMETHODCALLTYPE Invoke() override {
    if (!supportsInvoke()) return UIA_E_ELEMENTNOTENABLED;
    if (id_ == 10) setStatus("Worktree policy editor opened");
    if (id_ == 11) setStatus("Worktree policy saved");
    UINT command = id_ == 7 ? 6 : id_ == 8 ? 7 : id_ == 9 ? 8 :
                   id_ == 10 ? 9 : id_ == 11 ? 10 : id_ == 12 ? 12 : id_ == 13 ? 13 : 6;
    PostMessageW(state_->hwnd, WM_COMMAND, command, 0);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_CanSelectMultiple(BOOL *value) override {
    if (!value) return E_POINTER;
    *value = TRUE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_IsSelectionRequired(BOOL *value) override {
    if (!value) return E_POINTER;
    *value = FALSE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY **value) override {
    if (!value) return E_POINTER;
    std::vector<int> selected;
    for (size_t i = 0; i < state_->selected.size(); ++i)
      if (state_->selected[i]) selected.push_back(static_cast<int>(i));
    *value = SafeArrayCreateVector(VT_UNKNOWN, 0, static_cast<ULONG>(selected.size()));
    if (!*value) return selected.empty() ? S_OK : E_OUTOFMEMORY;
    for (LONG i = 0; i < static_cast<LONG>(selected.size()); ++i) {
      Node *node = new Node(state_, 100 + selected[static_cast<size_t>(i)]);
      if (!node) {
        SafeArrayDestroy(*value);
        *value = nullptr;
        return E_OUTOFMEMORY;
      }
      IUnknown *unknown = nullptr;
      node->QueryInterface(IID_IUnknown, reinterpret_cast<void **>(&unknown));
      node->Release();
      SafeArrayPutElement(*value, &i, unknown);
      if (unknown) unknown->Release();
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Select() override { return setSelected(true, 0); }
  HRESULT STDMETHODCALLTYPE AddToSelection() override { return setSelected(true, 1); }
  HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return setSelected(false, 2); }
  HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *value) override {
    if (!value) return E_POINTER;
    *value = isRow() && state_->selected[static_cast<size_t>(id_ - 100)] ? TRUE : FALSE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    return makeSimple(3, value);
  }
  HRESULT STDMETHODCALLTYPE Toggle() override {
    if (id_ != 12 && id_ != 13) return UIA_E_INVALIDOPERATION;
    PostMessageW(state_->hwnd, WM_COMMAND, id_, 0);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *value) override {
    if (!value) return E_POINTER;
    if (id_ == 12) *value = state_->allow_reclaim ? ToggleState_On : ToggleState_Off;
    else if (id_ == 13) *value = state_->confirm_each_reclaim ? ToggleState_On : ToggleState_Off;
    else return UIA_E_INVALIDOPERATION;
    return S_OK;
  }
  void update(const char *status, const char **rows, const int *selected,
              const int *eligible, int count, int focused, bool allow_reclaim,
              bool confirm_each_reclaim) {
    state_->status = wide(status);
    state_->rows.clear();
    state_->selected.clear();
    state_->eligible.clear();
    state_->focused = focused;
    state_->allow_reclaim = allow_reclaim;
    state_->confirm_each_reclaim = confirm_each_reclaim;
    for (int i = 0; i < count; ++i) {
      state_->rows.push_back(wide(rows ? rows[i] : nullptr));
      state_->selected.push_back(selected && selected[i] != 0);
      state_->eligible.push_back(eligible && eligible[i] != 0);
    }
    UiaRaiseAutomationEvent(this, UIA_LiveRegionChangedEventId);
    Node *status_node = new Node(state_, 6);
    UiaRaiseAutomationEvent(status_node, UIA_LiveRegionChangedEventId);
  }
  void setStatus(const char *status) {
    const std::wstring old_status = state_->status;
    state_->status = wide(status);
    Node *status_node = new Node(state_, 6);
    UiaRaiseAutomationEvent(status_node, UIA_LiveRegionChangedEventId);
    VARIANT old_value, new_value;
    VariantInit(&old_value);
    VariantInit(&new_value);
    old_value.vt = VT_BSTR;
    old_value.bstrVal = SysAllocString(old_status.c_str());
    new_value.vt = VT_BSTR;
    new_value.bstrVal = SysAllocString(state_->status.c_str());
    UiaRaiseAutomationPropertyChangedEvent(
        status_node, UIA_NamePropertyId, old_value, new_value);
    VariantClear(&old_value);
    VariantClear(&new_value);
    status_node->Release();
  }

 private:
  bool isRow() const { return id_ >= 100 && static_cast<size_t>(id_ - 100) < state_->rows.size(); }
  bool supportsInvoke() const { return id_ == 0 || (id_ >= 7 && id_ <= 13); }
  int parentId() const {
    if (id_ == 0) return -1;
    if (id_ >= 100) return 3;
    if (id_ == 1) return 0;
    if (id_ >= 2 && id_ <= 6) return 0;
    if (id_ == 7) return 5;
    if (id_ >= 8 && id_ <= 13) return 5;
    return 0;
  }
  int firstChild() const {
    if (id_ == 0) return 1;
    if (id_ == 3 && !state_->rows.empty()) return 100;
    if (id_ == 5) return 7;
    return -1;
  }
  int lastChild() const {
    if (id_ == 0) return 6;
    if (id_ == 3 && !state_->rows.empty()) return 99 + static_cast<int>(state_->rows.size());
    if (id_ == 5) return 13;
    return -1;
  }
  int sibling(int delta) const {
    if (id_ >= 100) {
      const int index = id_ - 100 + delta;
      if (index >= 0 && index < static_cast<int>(state_->rows.size())) return 100 + index;
      return -1;
    }
    if (id_ >= 1 && id_ <= 6) {
      const int next = id_ + delta;
      return next >= 1 && next <= 6 ? next : -1;
    }
    if (id_ >= 7 && id_ <= 13) {
      const int next = id_ + delta;
      return next >= 7 && next <= 13 ? next : -1;
    }
    return -1;
  }
  std::wstring name() const {
    if (isRow()) return state_->rows[static_cast<size_t>(id_ - 100)];
    if (id_ == 6) return state_->status;
    static const wchar_t *names[] = {L"GraphCode UIA Root", L"Projects", L"Loops", L"Worktrees",
                                     L"Graph", L"Actions", L"Status", L"Inspect worktrees",
                                     L"Reclaim selected worktrees", L"Reveal in Explorer",
                                     L"Edit worktree policy", L"Save worktree policy",
                                     L"Allow reclaim", L"Confirm each reclaim"};
    return names[id_ <= 13 ? id_ : 0];
  }
  std::wstring automationId() const {
    if (isRow()) return L"worktree-row-" + std::to_wstring(id_ - 100);
    static const wchar_t *ids[] = {L"graphcode-root", L"projects", L"loops", L"worktrees",
                                   L"graph", L"actions", L"status", L"inspect-worktrees",
                                   L"reclaim-worktrees", L"reveal-worktree",
                                   L"edit-worktree-policy", L"save-worktree-policy",
                                   L"allow-reclaim", L"confirm-each-reclaim"};
    return ids[id_ <= 13 ? id_ : 0];
  }
  CONTROLTYPEID controlType() const {
    if (id_ == 0) return UIA_WindowControlTypeId;
    if (id_ == 3) return UIA_ListControlTypeId;
    if (id_ >= 100) return UIA_ListItemControlTypeId;
    if (id_ >= 7 && id_ <= 11) return UIA_ButtonControlTypeId;
    if (id_ == 12 || id_ == 13) return UIA_CheckBoxControlTypeId;
    if (id_ == 5) return UIA_MenuControlTypeId;
    if (id_ == 6) return UIA_StatusBarControlTypeId;
    return UIA_PaneControlTypeId;
  }
  HRESULT make(int id, IRawElementProviderFragment **value) {
    if (id < 0) return S_OK;
    Node *node = new Node(state_, id);
    if (!node) return E_OUTOFMEMORY;
    *value = static_cast<IRawElementProviderFragment *>(node);
    return S_OK;
  }
  HRESULT makeSimple(int id, IRawElementProviderSimple **value) {
    Node *node = new Node(state_, id);
    if (!node) return E_OUTOFMEMORY;
    *value = static_cast<IRawElementProviderSimple *>(node);
    return S_OK;
  }
  HRESULT setSelected(bool selected, int operation) {
    if (!isRow()) return UIA_E_INVALIDOPERATION;
    size_t index = static_cast<size_t>(id_ - 100);
    if (!state_->eligible[index]) return UIA_E_INVALIDOPERATION;
    if (operation == 0) {
      for (size_t i = 0; i < state_->selected.size(); ++i) state_->selected[i] = false;
    }
    state_->selected[index] = selected;
    const UINT command = 2000 + static_cast<UINT>(index) * 3 + static_cast<UINT>(operation);
    PostMessageW(state_->hwnd, WM_COMMAND, command, 0);
    UiaRaiseAutomationEvent(this, selected
        ? UIA_SelectionItem_ElementSelectedEventId
        : UIA_SelectionItem_ElementRemovedFromSelectionEventId);
    return S_OK;
  }

  std::shared_ptr<State> state_;
  int id_;
  volatile LONG refs_;
};

} // namespace

extern "C" IRawElementProviderSimple *gc_uia_create(HWND hwnd) {
  auto state = std::make_shared<State>();
  state->hwnd = hwnd;
  return new Node(std::move(state), 0);
}

extern "C" void gc_uia_release(IRawElementProviderSimple *provider) {
  if (provider) provider->Release();
}

extern "C" LRESULT gc_uia_get_object(HWND hwnd, WPARAM wparam, LPARAM lparam,
                                      IRawElementProviderSimple *provider) {
  if (!provider || lparam != UiaRootObjectId) return 0;
  return UiaReturnRawElementProvider(hwnd, wparam, lparam, provider);
}

extern "C" HRESULT gc_uia_update(IRawElementProviderSimple *provider, const char *status,
                                  const char **rows, const int *selected, const int *eligible,
                                  int count, int focused, int allow_reclaim,
                                  int confirm_each_reclaim) {
  if (!provider || count < 0) return E_INVALIDARG;
  auto *root = static_cast<Node *>(provider);
  root->update(status, rows, selected, eligible, count, focused,
               allow_reclaim != 0, confirm_each_reclaim != 0);
  return S_OK;
}

extern "C" HRESULT gc_uia_notify(IRawElementProviderSimple *provider) {
  if (!provider) return E_INVALIDARG;
  return UiaRaiseAutomationEvent(provider, UIA_LiveRegionChangedEventId);
}

extern "C" HRESULT gc_uia_set_status(IRawElementProviderSimple *provider, const char *status) {
  if (!provider) return E_INVALIDARG;
  auto *root = static_cast<Node *>(provider);
  root->setStatus(status);
  return S_OK;
}
