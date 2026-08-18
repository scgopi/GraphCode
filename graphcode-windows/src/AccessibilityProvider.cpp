#include <windows.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <algorithm>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr int64_t kRowPrefix = 0x1000000000000000LL;
constexpr uint64_t kRowPayloadMask = 0x0fffffffffffffffULL;
constexpr WPARAM kSelectionCommandTag = 0xc000000000000000ULL;
constexpr WPARAM kDynamicInvokeTag = 0x8000000000000000ULL;
constexpr WPARAM kSelectionOperationMask = 0x3000000000000000ULL;
constexpr int kSelectionOperationShift = 60;

enum SelectionOperation { kSelect = 0, kAdd = 1, kRemove = 2 };

class Node;
struct Row {
  std::string identity;
  std::wstring name;
  int parent = 3;
  bool selected = false;
  bool eligible = false;
  bool invokable = false;
  RECT bounds{};
};
struct State {
  std::mutex mutex;
  HWND hwnd{};
  Node *root{};
  std::unordered_map<int64_t, Node *> elements;
  std::wstring status = L"Ready";
  std::unordered_map<int64_t, Row> rows;
  std::vector<int64_t> row_order;
  int64_t focused = 0;
  bool allow_reclaim = false;
  bool confirm_each_reclaim = true;
  bool active = true;
};

static std::wstring wide(const char *value) {
  if (!value) return {};
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1,
                      const_cast<wchar_t *>(result.data()), length);
  result.pop_back();
  return result;
}

static uint64_t hashPath(const std::string &path) {
  uint64_t hash = 1469598103934665603ULL;
  for (unsigned char value : path) {
    hash ^= value;
    hash *= 1099511628211ULL;
  }
  return hash;
}

static bool isRowKey(int64_t id) {
  return (static_cast<uint64_t>(id) & static_cast<uint64_t>(kRowPrefix)) != 0;
}

class Node final : public IRawElementProviderSimple,
                   public IRawElementProviderFragment,
                   public IRawElementProviderFragmentRoot,
                   public IInvokeProvider,
                   public ISelectionProvider,
                   public ISelectionItemProvider,
                   public IToggleProvider {
 public:
  Node(std::shared_ptr<State> state, int64_t id) : state_(std::move(state)), id_(id), refs_(1) {
    if (id_ == 0) {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->root = this;
    }
  }
  ~Node() {
    std::lock_guard<std::mutex> lock(state_->mutex);
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
    else if (iid == __uuidof(ISelectionProvider) && id_ >= 1 && id_ <= 4)
      *out = static_cast<ISelectionProvider *>(this);
    else if (iid == __uuidof(ISelectionItemProvider) && isAvailableRow())
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
    *value = static_cast<ProviderOptions>(
        ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading |
        ProviderOptions_ProviderOwnsSetFocus);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id, IUnknown **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (id == UIA_InvokePatternId && supportsInvoke())
      *value = static_cast<IInvokeProvider *>(this);
    else if (id == UIA_SelectionPatternId && id_ >= 1 && id_ <= 4)
      *value = static_cast<ISelectionProvider *>(this);
    else if (id == UIA_SelectionItemPatternId && isAvailableRow())
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
    std::wstring string_value;
    LONG integer_value = 0;
    bool bool_value = false;
    enum { kNone, kString, kInteger, kBool } kind = kNone;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      if (property == UIA_NamePropertyId) {
        string_value = nameLocked();
        kind = kString;
      } else if (property == UIA_AutomationIdPropertyId) {
        string_value = automationIdLocked();
        kind = kString;
      } else if (property == UIA_ControlTypePropertyId) {
        integer_value = controlTypeLocked();
        kind = kInteger;
      } else if (property == UIA_IsKeyboardFocusablePropertyId ||
                 property == UIA_IsEnabledPropertyId ||
                 property == UIA_IsControlElementPropertyId ||
                 property == UIA_IsContentElementPropertyId) {
        bool_value = true;
        kind = kBool;
      } else if (property == UIA_HasKeyboardFocusPropertyId) {
        bool_value = state_->focused == id_;
        kind = kBool;
      } else if (property == UIA_LiveSettingPropertyId && id_ == 6) {
        integer_value = 1;
        kind = kInteger;
      } else if (property == UIA_ValueValuePropertyId && id_ == 6) {
        string_value = state_->status;
        kind = kString;
      }
    }
    if (kind == kNone) return S_FALSE;
    if (kind == kString) {
      value->vt = VT_BSTR;
      value->bstrVal = SysAllocString(string_value.c_str());
      return value->bstrVal ? S_OK : E_OUTOFMEMORY;
    }
    if (kind == kInteger) {
      value->vt = VT_I4;
      value->lVal = integer_value;
      return S_OK;
    }
    value->vt = VT_BOOL;
    value->boolVal = bool_value ? VARIANT_TRUE : VARIANT_FALSE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **value) override {
    if (!value) return E_POINTER;
    HWND hwnd = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) {
        *value = nullptr;
        return UIA_E_ELEMENTNOTAVAILABLE;
      }
      if (id_ != 0) {
        *value = nullptr;
        return S_OK;
      }
      hwnd = state_->hwnd;
    }
    return UiaHostProviderFromHwnd(hwnd, value);
  }

  HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction,
                                      IRawElementProviderFragment **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    Node *target = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      int64_t destination = -1;
      if (direction == NavigateDirection_Parent) destination = parentLocked();
      if (direction == NavigateDirection_FirstChild) destination = firstChildLocked();
      if (direction == NavigateDirection_LastChild) destination = lastChildLocked();
      if (direction == NavigateDirection_NextSibling) destination = siblingLocked(1);
      if (direction == NavigateDirection_PreviousSibling) destination = siblingLocked(-1);
      if (destination >= 0) target = retainElementLocked(destination);
    }
    if (target) *value = static_cast<IRawElementProviderFragment *>(target);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    int64_t id = 0;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      if (id_ == 0) return S_OK;
      id = id_;
    }
    const LONG count = isRowKey(id) ? 4 : 2;
    *value = SafeArrayCreateVector(VT_I4, 0, count);
    if (!*value) return E_OUTOFMEMORY;
    if (isRowKey(id)) {
      const uint64_t row = static_cast<uint64_t>(id);
      LONG values[4] = {
          UiaAppendRuntimeId,
          0x475243,
          static_cast<LONG>(row & 0xffffffffULL),
          static_cast<LONG>(row >> 32),
      };
      for (LONG index = 0; index < count; ++index) SafeArrayPutElement(*value, &index, &values[index]);
    } else {
      LONG values[2] = {UiaAppendRuntimeId, static_cast<LONG>(id)};
      for (LONG index = 0; index < count; ++index) SafeArrayPutElement(*value, &index, &values[index]);
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *value) override {
    if (!value) return E_POINTER;
    HWND hwnd = nullptr;
    RECT dynamic_bounds{};
    bool has_dynamic_bounds = false;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      hwnd = state_->hwnd;
      if (isRowKey(id_)) {
        dynamic_bounds = state_->rows.at(id_).bounds;
        has_dynamic_bounds = true;
      }
    }
    RECT rect{};
    GetClientRect(hwnd, &rect);
    POINT origin{0, 0};
    ClientToScreen(hwnd, &origin);
    value->left = origin.x;
    value->top = origin.y;
    value->width = rect.right - rect.left;
    value->height = 28;
    if (has_dynamic_bounds) {
      value->left = origin.x + dynamic_bounds.left;
      value->top = origin.y + dynamic_bounds.top;
      value->width = dynamic_bounds.right - dynamic_bounds.left;
      value->height = dynamic_bounds.bottom - dynamic_bounds.top;
    } else if (id_ == 14 || id_ == 15) {
      value->left = origin.x + 8;
      value->top = origin.y + (id_ == 14 ? 142 : 358);
      value->width = 220;
      value->height = 24;
    } else if (id_ == 16) {
      value->left = origin.x + (rect.right > 140 ? rect.right - 140 : 0);
      value->top = origin.y + 56;
      value->width = 120;
      value->height = 32;
    } else if (id_ >= 17 && id_ <= 20) {
      const LONG widths[] = {36, 68, 36, 38};
      LONG left = rect.right > 190 ? rect.right - 190 : 0;
      for (int64_t index = 17; index < id_; ++index) left += widths[index - 17];
      value->left = origin.x + left;
      value->top = origin.y + (rect.bottom > 48 ? rect.bottom - 48 : 0);
      value->width = widths[id_ - 17];
      value->height = 36;
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetFocus() override {
    bool changed = false;
    HWND hwnd = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      changed = state_->focused != id_;
      state_->focused = id_;
      hwnd = state_->hwnd;
    }
    if (hwnd) {
      const DWORD current_thread = GetCurrentThreadId();
      const DWORD window_thread = GetWindowThreadProcessId(hwnd, nullptr);
      const bool attach =
          window_thread != 0 && window_thread != current_thread;
      if (attach && !AttachThreadInput(current_thread, window_thread, TRUE))
        return HRESULT_FROM_WIN32(GetLastError());
      SetForegroundWindow(hwnd);
      SetLastError(ERROR_SUCCESS);
      if (::SetFocus(hwnd) == nullptr) {
        const DWORD error = GetLastError();
        if (error != ERROR_SUCCESS) {
          if (attach) AttachThreadInput(current_thread, window_thread, FALSE);
          return HRESULT_FROM_WIN32(error);
        }
      }
      if (attach) AttachThreadInput(current_thread, window_thread, FALSE);
    }
    if (changed) {
      UiaRaiseAutomationEvent(
          static_cast<IRawElementProviderSimple *>(this),
          UIA_AutomationFocusChangedEventId);
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!isAvailableLocked() || !state_->root) return UIA_E_ELEMENTNOTAVAILABLE;
    state_->root->AddRef();
    *value = static_cast<IRawElementProviderFragmentRoot *>(state_->root);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double, double,
                                                      IRawElementProviderFragment **value) override {
    return focusedElement(value);
  }
  HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **value) override {
    return focusedElement(value);
  }

  HRESULT STDMETHODCALLTYPE Invoke() override {
    if (!supportsInvoke()) return UIA_E_ELEMENTNOTENABLED;
    HWND hwnd = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      hwnd = state_->hwnd;
    }
    if (isRowKey(id_)) {
      const WPARAM command = kDynamicInvokeTag |
          (static_cast<uint64_t>(id_) & kRowPayloadMask);
      PostMessageW(hwnd, WM_COMMAND, command, 0);
      return S_OK;
    }
    const UINT command = id_ == 7 ? 6 : id_ == 8 ? 7 : id_ == 9 ? 8 :
                         id_ == 10 ? 9 : id_ == 11 ? 10 : id_ == 12 ? 12 :
                         id_ == 13 ? 13 : id_ == 14 ? 20 : id_ == 15 ? 21 :
                         id_ == 16 ? 22 : id_ == 17 ? 23 : id_ == 18 ? 24 :
                         id_ == 19 ? 25 : 26;
    PostMessageW(hwnd, WM_COMMAND, command, 0);
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
    std::vector<Node *> selected;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked() || id_ < 1 || id_ > 4) {
        *value = nullptr;
        return UIA_E_ELEMENTNOTAVAILABLE;
      }
      for (int64_t id : state_->row_order) {
        const auto row = state_->rows.find(id);
        if (row != state_->rows.end() && row->second.parent == id_ && row->second.selected) {
          if (Node *node = retainElementLocked(id)) selected.push_back(node);
        }
      }
    }
    *value = SafeArrayCreateVector(VT_UNKNOWN, 0, static_cast<ULONG>(selected.size()));
    if (!*value) {
      for (Node *node : selected) node->Release();
      return selected.empty() ? S_OK : E_OUTOFMEMORY;
    }
    for (LONG index = 0; index < static_cast<LONG>(selected.size()); ++index) {
      IUnknown *unknown = static_cast<IRawElementProviderSimple *>(selected[static_cast<size_t>(index)]);
      SafeArrayPutElement(*value, &index, unknown);
      selected[static_cast<size_t>(index)]->Release();
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Select() override { return setSelected(kSelect); }
  HRESULT STDMETHODCALLTYPE AddToSelection() override { return setSelected(kAdd); }
  HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return setSelected(kRemove); }
  HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *value) override {
    if (!value) return E_POINTER;
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!isAvailableLocked() || !isRowKey(id_))
      return UIA_E_ELEMENTNOTAVAILABLE;
    *value = state_->rows.at(id_).selected ? TRUE : FALSE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    Node *container = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked() || !isRowKey(id_))
        return UIA_E_ELEMENTNOTAVAILABLE;
      container = retainElementLocked(state_->rows.at(id_).parent);
    }
    if (!container) return UIA_E_ELEMENTNOTAVAILABLE;
    *value = static_cast<IRawElementProviderSimple *>(container);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Toggle() override {
    if (id_ != 12 && id_ != 13) return UIA_E_INVALIDOPERATION;
    HWND hwnd = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      hwnd = state_->hwnd;
    }
    PostMessageW(hwnd, WM_COMMAND, static_cast<WPARAM>(id_), 0);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *value) override {
    if (!value) return E_POINTER;
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
    if (id_ == 12) *value = state_->allow_reclaim ? ToggleState_On : ToggleState_Off;
    else if (id_ == 13) *value = state_->confirm_each_reclaim ? ToggleState_On : ToggleState_Off;
    else return UIA_E_INVALIDOPERATION;
    return S_OK;
  }

  void update(const char *status, const char **identities, const char **names,
              const int *parents, const int *selected, const int *eligible,
              const int *invokable, const int *bounds, int count, bool allow_reclaim,
              bool confirm_each_reclaim) {
    std::wstring old_status;
    std::wstring new_status;
    Node *status_node = nullptr;
    Node *focus_node = nullptr;
    Node *allow_reclaim_node = nullptr;
    Node *confirm_reclaim_node = nullptr;
    std::vector<Node *> retired;
    std::vector<std::pair<Node *, EVENTID>> selection_events;
    bool status_changed = false;
    bool focus_changed = false;
    bool structure_changed = false;
    bool allow_reclaim_changed = false;
    bool confirm_reclaim_changed = false;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!state_->active) return;
      old_status = state_->status;
      state_->status = wide(status);
      new_status = state_->status;
      status_changed = old_status != new_status;
      const bool old_allow_reclaim = state_->allow_reclaim;
      const bool old_confirm_reclaim = state_->confirm_each_reclaim;
      state_->allow_reclaim = allow_reclaim;
      state_->confirm_each_reclaim = confirm_each_reclaim;

      std::unordered_map<int64_t, Row> next_rows;
      std::vector<int64_t> next_order;
      for (int index = 0; index < count; ++index) {
        const std::string identity = identities && identities[index] ? identities[index] : "";
        int64_t key = rowKeyForIdentityLocked(identity, next_rows);
        const auto existing = std::find_if(
            state_->rows.begin(), state_->rows.end(),
            [&identity](const std::pair<const int64_t, Row> &item) {
              return item.second.identity == identity;
            });
        if (existing != state_->rows.end()) key = existing->first;
        while (next_rows.find(key) != next_rows.end()) key = nextRowKey(key);
        next_rows.emplace(key, Row{
            identity,
            wide(names && names[index] ? names[index] : identity.c_str()),
            parents ? parents[index] : 3,
            selected && selected[index] != 0,
            eligible && eligible[index] != 0,
            invokable && invokable[index] != 0,
            bounds ? RECT{bounds[index * 4], bounds[index * 4 + 1],
                          bounds[index * 4 + 2], bounds[index * 4 + 3]} : RECT{},
        });
        next_order.push_back(key);
      }
      structure_changed = state_->row_order != next_order || state_->rows.size() != next_rows.size();
      std::vector<int64_t> added_selection;
      std::vector<int64_t> removed_selection;
      size_t next_selected_count[5]{};
      for (const auto &item : next_rows) {
        if (item.second.parent < 1 || item.second.parent > 4) continue;
        if (item.second.selected) ++next_selected_count[item.second.parent];
        const auto old = state_->rows.find(item.first);
        if (item.second.selected &&
            (old == state_->rows.end() || !old->second.selected)) {
          added_selection.push_back(item.first);
        }
      }
      for (const auto &item : state_->rows) {
        if (item.second.parent < 1 || item.second.parent > 4) continue;
        const auto next = next_rows.find(item.first);
        if (item.second.selected &&
            (next == next_rows.end() || !next->second.selected)) {
          removed_selection.push_back(item.first);
        }
      }
      for (const auto &item : state_->rows) {
        if (next_rows.find(item.first) != next_rows.end()) continue;
        const auto element = state_->elements.find(item.first);
        if (element == state_->elements.end()) continue;
        element->second->retired_ = true;
        retired.push_back(element->second);
        state_->elements.erase(element);
      }
      state_->rows = std::move(next_rows);
      state_->row_order = std::move(next_order);
      for (int64_t id : added_selection) {
        const auto row = state_->rows.find(id);
        if (row == state_->rows.end()) continue;
        const EVENTID event = next_selected_count[row->second.parent] == 1
            ? UIA_SelectionItem_ElementSelectedEventId
            : UIA_SelectionItem_ElementAddedToSelectionEventId;
        if (Node *node = retainElementLocked(id)) {
          selection_events.emplace_back(node, event);
        }
      }
      for (int64_t id : removed_selection) {
        if (Node *node = retainElementLocked(id)) {
          selection_events.emplace_back(node, UIA_SelectionItem_ElementRemovedFromSelectionEventId);
        }
      }
      allow_reclaim_changed = old_allow_reclaim != state_->allow_reclaim;
      confirm_reclaim_changed = old_confirm_reclaim != state_->confirm_each_reclaim;
      if (allow_reclaim_changed) allow_reclaim_node = retainElementLocked(12);
      if (confirm_reclaim_changed) confirm_reclaim_node = retainElementLocked(13);
      const int64_t old_focus = state_->focused;
      if (!isKeyAvailableLocked(state_->focused)) state_->focused = 0;
      focus_changed = old_focus != state_->focused;
      if (status_changed) status_node = retainElementLocked(6);
      if (focus_changed) focus_node = retainElementLocked(state_->focused);
    }
    for (Node *node : retired) node->Release();
    for (const auto &event : selection_events) {
      UiaRaiseAutomationEvent(
          static_cast<IRawElementProviderSimple *>(event.first), event.second);
      event.first->Release();
    }
    raiseToggleChanged(allow_reclaim_node, !allow_reclaim, allow_reclaim);
    raiseToggleChanged(confirm_reclaim_node, !confirm_each_reclaim, confirm_each_reclaim);
    if (structure_changed) {
      UiaRaiseStructureChangedEvent(
          static_cast<IRawElementProviderSimple *>(this),
          StructureChangeType_ChildrenInvalidated, nullptr, 0);
    }
    raiseStatusChanged(status_node, old_status, new_status);
    if (focus_node) {
      UiaRaiseAutomationEvent(
          static_cast<IRawElementProviderSimple *>(focus_node),
          UIA_AutomationFocusChangedEventId);
      focus_node->Release();
    }
  }
  void setStatus(const char *status) {
    std::wstring old_status;
    std::wstring new_status;
    Node *status_node = nullptr;
    bool status_changed = false;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!state_->active) return;
      old_status = state_->status;
      state_->status = wide(status);
      new_status = state_->status;
      status_changed = old_status != new_status;
      if (status_changed) status_node = retainElementLocked(6);
    }
    raiseStatusChanged(status_node, old_status, new_status);
  }
  void shutdown() {
    if (id_ != 0) return;
    std::vector<Node *> elements;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!state_->active) return;
      state_->active = false;
      state_->root = nullptr;
      for (const auto &item : state_->elements) {
        item.second->retired_ = true;
        elements.push_back(item.second);
      }
      state_->elements.clear();
    }
    for (Node *node : elements) node->Release();
  }

 private:
  bool retired_ = false;

  bool supportsInvoke() const {
    if (id_ == 0 || (id_ >= 7 && id_ <= 20)) return true;
    std::lock_guard<std::mutex> lock(state_->mutex);
    const auto row = state_->rows.find(id_);
    return row != state_->rows.end() && row->second.invokable;
  }
  bool isAvailableLocked() const {
    return state_->active && !retired_ && isKeyAvailableLocked(id_);
  }
  bool isKeyAvailableLocked(int64_t id) const {
    return !isRowKey(id) || state_->rows.find(id) != state_->rows.end();
  }
  bool isAvailableRow() const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return isAvailableLocked() && isRowKey(id_);
  }
  int64_t rowKeyForIdentityLocked(
      const std::string &identity,
      const std::unordered_map<int64_t, Row> &pending) const {
    int64_t key = static_cast<int64_t>(
        static_cast<uint64_t>(kRowPrefix) | (hashPath(identity) & kRowPayloadMask));
    while (state_->rows.find(key) != state_->rows.end() &&
           state_->rows.at(key).identity != identity) {
      key = nextRowKey(key);
    }
    while (pending.find(key) != pending.end()) key = nextRowKey(key);
    return key;
  }
  static int64_t nextRowKey(int64_t key) {
    const uint64_t payload = (static_cast<uint64_t>(key) + 1) & kRowPayloadMask;
    return static_cast<int64_t>(static_cast<uint64_t>(kRowPrefix) | payload);
  }
  Node *elementLocked(int64_t id) {
    if (!state_->active || !isKeyAvailableLocked(id)) return nullptr;
    if (id == 0) return state_->root;
    const auto existing = state_->elements.find(id);
    if (existing != state_->elements.end()) return existing->second;
    Node *node = new Node(state_, id);
    if (!node) return nullptr;
    state_->elements.emplace(id, node);
    return node;
  }
  Node *retainElementLocked(int64_t id) {
    Node *node = elementLocked(id);
    if (node) node->AddRef();
    return node;
  }
  int64_t parentLocked() const {
    if (id_ == 0) return -1;
    if (isRowKey(id_)) return state_->rows.at(id_).parent;
    if (id_ >= 1 && id_ <= 6) return 0;
    if (id_ >= 7 && id_ <= 13) return 5;
    if (id_ == 14 || id_ == 15) return 1;
    if (id_ >= 16 && id_ <= 20) return 4;
    return -1;
  }
  int64_t firstChildLocked() const {
    if (id_ == 0) return 1;
    if (id_ >= 1 && id_ <= 4) {
      for (int64_t key : state_->row_order)
        if (state_->rows.at(key).parent == id_) return key;
    }
    if (id_ == 5) return 7;
    if (id_ == 1) return 14;
    if (id_ == 4) return 16;
    return -1;
  }
  int64_t lastChildLocked() const {
    if (id_ == 0) return 6;
    if (id_ == 2 || id_ == 3) {
      for (auto current = state_->row_order.rbegin(); current != state_->row_order.rend(); ++current)
        if (state_->rows.at(*current).parent == id_) return *current;
    }
    if (id_ == 5) return 13;
    if (id_ == 1) return 15;
    if (id_ == 4) return 20;
    return -1;
  }
  int64_t siblingLocked(int delta) const {
    if (isRowKey(id_)) {
      std::vector<int64_t> siblings;
      const int parent = state_->rows.at(id_).parent;
      for (int64_t key : state_->row_order)
        if (state_->rows.at(key).parent == parent) siblings.push_back(key);
      const auto current = std::find(siblings.begin(), siblings.end(), id_);
      if (current == siblings.end()) return -1;
      const auto index = current - siblings.begin() + delta;
      if (index < 0) return -1;
      if (index >= static_cast<ptrdiff_t>(siblings.size())) {
        return parent == 1 ? 14 : parent == 4 ? 16 : -1;
      }
      return siblings[static_cast<size_t>(index)];
    }
    if (id_ >= 1 && id_ <= 6) {
      const int64_t next = id_ + delta;
      return next >= 1 && next <= 6 ? next : -1;
    }
    if (id_ >= 7 && id_ <= 13) {
      const int64_t next = id_ + delta;
      return next >= 7 && next <= 13 ? next : -1;
    }
    if (id_ >= 14 && id_ <= 15) {
      if (id_ == 14 && delta < 0) {
        for (auto current = state_->row_order.rbegin(); current != state_->row_order.rend(); ++current)
          if (state_->rows.at(*current).parent == 1) return *current;
      }
      const int64_t next = id_ + delta;
      return next >= 14 && next <= 15 ? next : -1;
    }
    if (id_ >= 16 && id_ <= 20) {
      if (id_ == 16 && delta < 0) {
        for (auto current = state_->row_order.rbegin(); current != state_->row_order.rend(); ++current)
          if (state_->rows.at(*current).parent == 4) return *current;
      }
      const int64_t next = id_ + delta;
      return next >= 16 && next <= 20 ? next : -1;
    }
    return -1;
  }
  std::wstring nameLocked() const {
    if (isRowKey(id_)) return state_->rows.at(id_).name;
    if (id_ == 6) return state_->status;
    static const wchar_t *names[] = {
        L"GraphCode UIA Root", L"Projects", L"Loops", L"Worktrees", L"Graph", L"Actions",
        L"Status", L"Inspect worktrees", L"Reclaim selected worktrees", L"Reveal in Explorer",
        L"Edit worktree policy", L"Save worktree policy", L"Allow reclaim", L"Confirm each reclaim",
        L"Graph", L"Quick Chats", L"New Loop or Chat", L"Zoom out",
        L"Actual size", L"Zoom in", L"Fit canvas",
    };
    return names[id_ >= 0 && id_ <= 20 ? id_ : 0];
  }
  std::wstring automationIdLocked() const {
    if (isRowKey(id_)) {
      const Row &row = state_->rows.at(id_);
      const int parent = row.parent;
      const wchar_t *prefix =
          row.identity.rfind("sidebar-section:", 0) == 0 ? L"sidebar-section-" :
          row.identity.rfind("project-new-loop:", 0) == 0 ? L"project-new-loop-" :
          row.identity.rfind("project-disclosure:", 0) == 0 ? L"project-disclosure-" :
          row.identity.rfind("quick-chats-header:", 0) == 0 ? L"quick-chats-header-" :
          row.identity.rfind("quick-chat-new:", 0) == 0 ? L"quick-chat-new-" :
          row.identity.rfind("quick-chats-disclosure:", 0) == 0 ? L"quick-chats-disclosure-" :
          row.identity.rfind("quick-chat-row:", 0) == 0 ? L"quick-chat-row-" :
          row.identity.rfind("loop-disclosure:", 0) == 0 ? L"loop-disclosure-" :
          parent == 1 ? L"project-row-" :
          parent == 2 ? L"loop-row-" :
          parent == 3 ? L"worktree-row-" : L"canvas-card-";
      return prefix + std::to_wstring(id_);
    }
    static const wchar_t *ids[] = {
        L"graphcode-root", L"projects", L"loops", L"worktrees", L"graph", L"actions",
        L"status", L"inspect-worktrees", L"reclaim-worktrees", L"reveal-worktree",
        L"edit-worktree-policy", L"save-worktree-policy", L"allow-reclaim", L"confirm-each-reclaim",
        L"overview-destination", L"quick-chats-destination", L"canvas-primary-action",
        L"zoom-out", L"actual-size", L"zoom-in", L"fit-canvas",
    };
    return ids[id_ >= 0 && id_ <= 20 ? id_ : 0];
  }
  CONTROLTYPEID controlTypeLocked() const {
    if (id_ == 0) return UIA_WindowControlTypeId;
    if (id_ >= 1 && id_ <= 3) return UIA_ListControlTypeId;
    if (isRowKey(id_)) {
      const Row &row = state_->rows.at(id_);
      const bool action =
          row.identity.rfind("sidebar-section:", 0) == 0 ||
          row.identity.rfind("project-new-loop:", 0) == 0 ||
          row.identity.rfind("project-disclosure:", 0) == 0 ||
          row.identity.rfind("quick-chats-header:", 0) == 0 ||
          row.identity.rfind("quick-chat-new:", 0) == 0 ||
          row.identity.rfind("quick-chats-disclosure:", 0) == 0 ||
          row.identity.rfind("loop-disclosure:", 0) == 0;
      return row.parent == 4 || action ? UIA_ButtonControlTypeId : UIA_ListItemControlTypeId;
    }
    if ((id_ >= 7 && id_ <= 11) || (id_ >= 14 && id_ <= 20)) return UIA_ButtonControlTypeId;
    if (id_ == 12 || id_ == 13) return UIA_CheckBoxControlTypeId;
    if (id_ == 5) return UIA_MenuControlTypeId;
    if (id_ == 6) return UIA_StatusBarControlTypeId;
    return UIA_PaneControlTypeId;
  }
  HRESULT focusedElement(IRawElementProviderFragment **value) {
    if (!value) return E_POINTER;
    *value = nullptr;
    Node *focused = nullptr;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked()) return UIA_E_ELEMENTNOTAVAILABLE;
      focused = retainElementLocked(state_->focused);
    }
    if (focused) *value = static_cast<IRawElementProviderFragment *>(focused);
    return S_OK;
  }
  void raiseStatusChanged(
      Node *status_node,
      const std::wstring &old_status,
      const std::wstring &new_status) {
    if (!status_node) return;
    if (old_status == new_status) {
      status_node->Release();
      return;
    }
    auto *provider = static_cast<IRawElementProviderSimple *>(status_node);
    UiaRaiseAutomationEvent(provider, UIA_LiveRegionChangedEventId);
    VARIANT old_value, new_value;
    VariantInit(&old_value);
    VariantInit(&new_value);
    old_value.vt = VT_BSTR;
    old_value.bstrVal = SysAllocString(old_status.c_str());
    new_value.vt = VT_BSTR;
    new_value.bstrVal = SysAllocString(new_status.c_str());
    UiaRaiseAutomationPropertyChangedEvent(provider, UIA_NamePropertyId, old_value, new_value);
    VariantClear(&old_value);
    VariantClear(&new_value);
    status_node->Release();
  }
  void raiseToggleChanged(Node *toggle_node, bool old_value, bool new_value) {
    if (!toggle_node) return;
    VARIANT old_state, new_state;
    VariantInit(&old_state);
    VariantInit(&new_state);
    old_state.vt = VT_I4;
    old_state.lVal = old_value ? ToggleState_On : ToggleState_Off;
    new_state.vt = VT_I4;
    new_state.lVal = new_value ? ToggleState_On : ToggleState_Off;
    UiaRaiseAutomationPropertyChangedEvent(
        static_cast<IRawElementProviderSimple *>(toggle_node),
        UIA_ToggleToggleStatePropertyId, old_state, new_state);
    toggle_node->Release();
  }
  HRESULT setSelected(SelectionOperation operation) {
    HWND hwnd = nullptr;
    bool changed = false;
    bool dynamic_invoke = false;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!isAvailableLocked() || !isRowKey(id_))
        return UIA_E_ELEMENTNOTAVAILABLE;
      const auto selected = state_->rows.find(id_);
      if (selected->second.parent != 3) {
        if (operation == kRemove || !selected->second.invokable)
          return UIA_E_INVALIDOPERATION;
        hwnd = state_->hwnd;
        dynamic_invoke = true;
      } else {
        if (!selected->second.eligible) return UIA_E_INVALIDOPERATION;
        if (operation == kSelect) {
          for (auto &item : state_->rows) {
            if (item.first == id_ || item.second.parent != 3) continue;
            if (item.second.selected) changed = true;
            item.second.selected = false;
          }
        }
        const bool desired = operation != kRemove;
        changed = changed || selected->second.selected != desired;
        selected->second.selected = desired;
        hwnd = state_->hwnd;
      }
    }
    if (dynamic_invoke) {
      const WPARAM command = kDynamicInvokeTag |
          (static_cast<uint64_t>(id_) & kRowPayloadMask);
      PostMessageW(hwnd, WM_COMMAND, command, 0);
      return S_OK;
    }
    const WPARAM command = kSelectionCommandTag |
        (static_cast<WPARAM>(operation) << kSelectionOperationShift) |
        (static_cast<WPARAM>(id_) & kRowPayloadMask);
    PostMessageW(hwnd, WM_COMMAND, command, 0);
    if (changed) {
      EVENTID event = UIA_SelectionItem_ElementSelectedEventId;
      if (operation == kAdd) event = UIA_SelectionItem_ElementAddedToSelectionEventId;
      if (operation == kRemove) event = UIA_SelectionItem_ElementRemovedFromSelectionEventId;
      UiaRaiseAutomationEvent(
          static_cast<IRawElementProviderSimple *>(this), event);
    }
    return S_OK;
  }

  std::shared_ptr<State> state_;
  int64_t id_;
  volatile LONG refs_;
};

}  // namespace

extern "C" IRawElementProviderSimple *gc_uia_create(HWND hwnd) {
  auto state = std::make_shared<State>();
  state->hwnd = hwnd;
  return new Node(std::move(state), 0);
}

extern "C" void gc_uia_release(IRawElementProviderSimple *provider) {
  if (provider) {
    static_cast<Node *>(provider)->shutdown();
    provider->Release();
  }
}

extern "C" LRESULT gc_uia_get_object(HWND hwnd, WPARAM wparam, LPARAM lparam,
                                      IRawElementProviderSimple *provider) {
  if (!provider || lparam != UiaRootObjectId) return 0;
  return UiaReturnRawElementProvider(hwnd, wparam, lparam, provider);
}

extern "C" HRESULT gc_uia_update(IRawElementProviderSimple *provider, const char *status,
                                  const char **identities, const char **names,
                                  const int *parents, const int *selected,
                                  const int *eligible, const int *invokable,
                                  const int *bounds, int count, int allow_reclaim,
                                  int confirm_each_reclaim) {
  if (!provider || count < 0) return E_INVALIDARG;
  auto *root = static_cast<Node *>(provider);
  root->update(status, identities, names, parents, selected, eligible,
               invokable, bounds, count,
               allow_reclaim != 0, confirm_each_reclaim != 0);
  return S_OK;
}

extern "C" HRESULT gc_uia_set_status(IRawElementProviderSimple *provider, const char *status) {
  if (!provider) return E_INVALIDARG;
  static_cast<Node *>(provider)->setStatus(status);
  return S_OK;
}
