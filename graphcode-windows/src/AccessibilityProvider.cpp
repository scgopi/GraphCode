#include <windows.h>
#include <oleauto.h>
#include <UIAutomation.h>

namespace {

class Node final : public IRawElementProviderSimple,
                   public IRawElementProviderFragment,
                   public IRawElementProviderFragmentRoot,
                   public IInvokeProvider,
                   public ISelectionProvider {
public:
  Node(HWND hwnd, int index, Node *parent)
      : hwnd_(hwnd), index_(index), parent_(parent), refs_(1) {
    if (parent_) parent_->AddRef();
  }

  ~Node() {
    if (parent_) parent_->Release();
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (iid == IID_IUnknown || iid == __uuidof(IRawElementProviderSimple))
      *out = static_cast<IRawElementProviderSimple *>(this);
    else if (iid == __uuidof(IRawElementProviderFragment))
      *out = static_cast<IRawElementProviderFragment *>(this);
    else if (iid == __uuidof(IRawElementProviderFragmentRoot) && index_ == 0)
      *out = static_cast<IRawElementProviderFragmentRoot *>(this);
    else if (iid == __uuidof(IInvokeProvider))
      *out = static_cast<IInvokeProvider *>(this);
    else if (iid == __uuidof(ISelectionProvider))
      *out = static_cast<ISelectionProvider *>(this);
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
    if (id == UIA_InvokePatternId && (index_ == 0 || (index_ >= 6 && index_ <= 8)))
      *value = static_cast<IInvokeProvider *>(this);
    else if (id == UIA_SelectionPatternId && index_ == 3)
      *value = static_cast<ISelectionProvider *>(this);
    else
      return S_FALSE;
    AddRef();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID id, VARIANT *value) override {
    if (!value) return E_POINTER;
    VariantInit(value);
    if (id == UIA_NamePropertyId) {
      value->vt = VT_BSTR;
      value->bstrVal = SysAllocString(name());
      return value->bstrVal ? S_OK : E_OUTOFMEMORY;
    }
    if (id == UIA_AutomationIdPropertyId) {
      value->vt = VT_BSTR;
      value->bstrVal = SysAllocString(index_ == 0 ? L"graphcode-root" : name());
      return value->bstrVal ? S_OK : E_OUTOFMEMORY;
    }
    if (id == UIA_ControlTypePropertyId) {
      value->vt = VT_I4;
      value->lVal = controlType();
      return S_OK;
    }
    if (id == UIA_IsKeyboardFocusablePropertyId) {
      value->vt = VT_BOOL;
      value->boolVal = index_ > 0 && index_ < 10 ? VARIANT_TRUE : VARIANT_FALSE;
      return S_OK;
    }
    if (id == UIA_IsEnabledPropertyId) {
      value->vt = VT_BOOL;
      value->boolVal = VARIANT_TRUE;
      return S_OK;
    }
    if (id == UIA_IsControlElementPropertyId || id == UIA_IsContentElementPropertyId) {
      value->vt = VT_BOOL;
      value->boolVal = VARIANT_TRUE;
      return S_OK;
    }
    return S_FALSE;
  }

  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **value) override {
    if (!value) return E_POINTER;
    return UiaHostProviderFromHwnd(hwnd_, value);
  }

  HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction,
                                     IRawElementProviderFragment **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (direction == NavigateDirection_Parent && parent_)
      return parent_->QueryInterface(__uuidof(IRawElementProviderFragment), reinterpret_cast<void **>(value));
    if (index_ == 0 && direction == NavigateDirection_FirstChild)
      return child(1, value);
    if (index_ == 0 && direction == NavigateDirection_LastChild)
      return child(kChildCount, value);
    if (index_ > 0 && direction == NavigateDirection_NextSibling && index_ < kChildCount)
      return child(index_ + 1, value);
    if (index_ > 1 && direction == NavigateDirection_PreviousSibling)
      return child(index_ - 1, value);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **value) override {
    if (!value) return E_POINTER;
    *value = SafeArrayCreateVector(VT_I4, 0, 3);
    if (!*value) return E_OUTOFMEMORY;
    LONG values[3] = { UiaAppendRuntimeId, 0x475243, index_ };
    for (LONG i = 0; i < 3; ++i) SafeArrayPutElement(*value, &i, &values[i]);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *value) override {
    if (!value) return E_POINTER;
    RECT rect{};
    GetWindowRect(hwnd_, &rect);
    value->left = rect.left;
    value->top = rect.top + index_ * 32;
    value->width = rect.right - rect.left;
    value->height = index_ == 0 ? 32 : 28;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE SetFocus() override {
    ::SetFocus(hwnd_);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (index_ != 0 && parent_)
      return parent_->QueryInterface(__uuidof(IRawElementProviderFragmentRoot),
                                     reinterpret_cast<void **>(value));
    return QueryInterface(__uuidof(IRawElementProviderFragmentRoot),
                          reinterpret_cast<void **>(value));
  }

  HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double, double,
                                                      IRawElementProviderFragment **value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    return QueryInterface(__uuidof(IRawElementProviderFragment),
                          reinterpret_cast<void **>(value));
  }

  HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **value) override {
    return ElementProviderFromPoint(0, 0, value);
  }

  HRESULT STDMETHODCALLTYPE Invoke() override {
    const int command = index_ == 0 ? 6 : index_;
    PostMessageW(hwnd_, WM_COMMAND, static_cast<WPARAM>(command), 0);
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
    *value = nullptr;
    return S_OK;
  }

private:
  static constexpr int kChildCount = 10;

  HRESULT child(int index, IRawElementProviderFragment **value) {
    Node *child = new Node(hwnd_, index, this);
    if (!child) return E_OUTOFMEMORY;
    *value = static_cast<IRawElementProviderFragment *>(child);
    return S_OK;
  }

  const wchar_t *name() const {
    static const wchar_t *names[kChildCount + 1] = {
        L"GraphCode UIA Root", L"Projects", L"Loops", L"Worktrees",
        L"Graph", L"Actions", L"Inspect worktrees",
        L"Reclaim selected worktrees", L"Reveal in Explorer",
        L"Terminal", L"Status"};
    return names[index_ <= kChildCount ? index_ : 0];
  }

  CONTROLTYPEID controlType() const {
    if (index_ == 0) return UIA_WindowControlTypeId;
    if (index_ == 5) return UIA_MenuControlTypeId;
    if (index_ >= 6 && index_ <= 8) return UIA_ButtonControlTypeId;
    if (index_ == 9) return UIA_PaneControlTypeId;
    if (index_ == 10) return UIA_StatusBarControlTypeId;
    return UIA_ListControlTypeId;
  }

  HWND hwnd_;
  int index_;
  Node *parent_;
  volatile LONG refs_;
};

} // namespace

extern "C" IRawElementProviderSimple *gc_uia_create(HWND hwnd) {
  return new Node(hwnd, 0, nullptr);
}

extern "C" void gc_uia_release(IRawElementProviderSimple *provider) {
  if (provider) provider->Release();
}

extern "C" LRESULT gc_uia_get_object(HWND hwnd, WPARAM wparam, LPARAM lparam,
                                      IRawElementProviderSimple *provider) {
  if (!provider) return 0;
  return UiaReturnRawElementProvider(hwnd, wparam, lparam, provider);
}

extern "C" HRESULT gc_uia_notify(IRawElementProviderSimple *provider) {
  if (!provider) return E_INVALIDARG;
  return UiaRaiseAutomationEvent(provider, UIA_LiveRegionChangedEventId);
}
