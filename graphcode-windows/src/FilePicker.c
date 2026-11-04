#include "FilePicker.h"

#include <shobjidl.h>
#include <string.h>
#include <wchar.h>

// Multi-select counterpart to FolderPicker.c's `graphcode_pick_folder`: same
// IFileOpenDialog/COM lifecycle, but FOS_ALLOWMULTISELECT plus a filter restricted to
// the extensions `DraftAttachments.zig`'s `isSupportedExtension` accepts, so a user
// can't pick a file the ingestion step is only going to reject afterwards.
int graphcode_pick_files(HWND owner, wchar_t *buffer, DWORD stride, DWORD max_files) {
  HRESULT initialized = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) return -1;

  IFileOpenDialog *dialog = NULL;
  HRESULT result = CoCreateInstance(
      &CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
      &IID_IFileOpenDialog, (void **)&dialog);
  if (FAILED(result)) {
    if (SUCCEEDED(initialized)) CoUninitialize();
    return -1;
  }

  DWORD options = 0;
  dialog->lpVtbl->GetOptions(dialog, &options);
  dialog->lpVtbl->SetOptions(
      dialog, options | FOS_ALLOWMULTISELECT | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
  dialog->lpVtbl->SetTitle(dialog, L"Attach files");

  static const COMDLG_FILTERSPEC filters[] = {
      {L"Supported attachments",
       L"*.png;*.jpg;*.jpeg;*.gif;*.heic;*.webp;*.tiff;*.tif;*.bmp;*.txt;*.md;*.log;*."
       L"json;*.csv;*.pdf"},
      {L"All files", L"*.*"},
  };
  dialog->lpVtbl->SetFileTypes(dialog, ARRAYSIZE(filters), filters);

  result = dialog->lpVtbl->Show(dialog, owner);
  if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    dialog->lpVtbl->Release(dialog);
    if (SUCCEEDED(initialized)) CoUninitialize();
    return 0;
  }
  if (FAILED(result)) {
    dialog->lpVtbl->Release(dialog);
    if (SUCCEEDED(initialized)) CoUninitialize();
    return -1;
  }

  int count = 0;
  IShellItemArray *items = NULL;
  result = dialog->lpVtbl->GetResults(dialog, &items);
  if (SUCCEEDED(result)) {
    DWORD item_count = 0;
    items->lpVtbl->GetCount(items, &item_count);
    DWORD limit = item_count < max_files ? item_count : max_files;
    for (DWORD i = 0; i < limit; i++) {
      IShellItem *item = NULL;
      if (FAILED(items->lpVtbl->GetItemAt(items, i, &item))) continue;
      PWSTR path = NULL;
      if (SUCCEEDED(item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &path)) &&
          path != NULL) {
        lstrcpynW(buffer + (size_t)i * stride, path, (int)stride);
        CoTaskMemFree(path);
        count++;
      }
      item->lpVtbl->Release(item);
    }
    items->lpVtbl->Release(items);
  }
  dialog->lpVtbl->Release(dialog);
  if (SUCCEEDED(initialized)) CoUninitialize();
  return count;
}

typedef struct ZipSaveEvents {
  IFileDialogEvents iface;
  LONG references;
  PWSTR approved_path;
  HRESULT failure;
} ZipSaveEvents;

static void zip_clear_approval(ZipSaveEvents *events) {
  CoTaskMemFree(events->approved_path);
  events->approved_path = NULL;
}

static ULONG STDMETHODCALLTYPE zip_add_ref(IFileDialogEvents *iface) {
  ZipSaveEvents *events = (ZipSaveEvents *)iface;
  return (ULONG)InterlockedIncrement(&events->references);
}

static ULONG STDMETHODCALLTYPE zip_release(IFileDialogEvents *iface) {
  ZipSaveEvents *events = (ZipSaveEvents *)iface;
  ULONG remaining = (ULONG)InterlockedDecrement(&events->references);
  if (remaining == 0) {
    zip_clear_approval(events);
    CoTaskMemFree(events);
  }
  return remaining;
}

static HRESULT STDMETHODCALLTYPE zip_query_interface(
    IFileDialogEvents *iface, REFIID iid, void **result) {
  if (result == NULL) return E_POINTER;
  *result = NULL;
  if (!IsEqualIID(iid, &IID_IUnknown) &&
      !IsEqualIID(iid, &IID_IFileDialogEvents))
    return E_NOINTERFACE;
  *result = iface;
  zip_add_ref(iface);
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE zip_file_ok(IFileDialogEvents *iface,
                                              IFileDialog *dialog) {
  (void)iface;
  (void)dialog;
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE zip_folder_changing(
    IFileDialogEvents *iface, IFileDialog *dialog, IShellItem *folder) {
  (void)dialog;
  (void)folder;
  zip_clear_approval((ZipSaveEvents *)iface);
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE zip_target_changed(IFileDialogEvents *iface,
                                                     IFileDialog *dialog) {
  (void)dialog;
  zip_clear_approval((ZipSaveEvents *)iface);
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE zip_share_violation(
    IFileDialogEvents *iface, IFileDialog *dialog, IShellItem *item,
    FDE_SHAREVIOLATION_RESPONSE *response) {
  (void)iface;
  (void)dialog;
  (void)item;
  if (response == NULL) return E_POINTER;
  *response = FDESVR_DEFAULT;
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE zip_overwrite(
    IFileDialogEvents *iface, IFileDialog *dialog, IShellItem *item,
    FDE_OVERWRITE_RESPONSE *response) {
  ZipSaveEvents *events = (ZipSaveEvents *)iface;
  if (response == NULL) return E_POINTER;
  *response = FDEOR_REFUSE;
  zip_clear_approval(events);
  PWSTR path = NULL;
  HRESULT result = item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &path);
  if (FAILED(result) || path == NULL) {
    events->failure = FAILED(result) ? result : E_FAIL;
    return events->failure;
  }
  IOleWindow *window = NULL;
  HWND owner = NULL;
  result = dialog->lpVtbl->QueryInterface(
      dialog, &IID_IOleWindow, (void **)&window);
  if (SUCCEEDED(result)) {
    result = window->lpVtbl->GetWindow(window, &owner);
    window->lpVtbl->Release(window);
  }
  if (FAILED(result) || owner == NULL) {
    CoTaskMemFree(path);
    events->failure = FAILED(result) ? result : E_FAIL;
    return events->failure;
  }
  static const wchar_t question[] = L"Replace the existing ZIP file?\n\n";
  size_t question_length = ARRAYSIZE(question) - 1;
  size_t path_length = wcslen(path);
  PWSTR message = CoTaskMemAlloc(
      (question_length + path_length + 1) * sizeof(wchar_t));
  if (message == NULL) {
    CoTaskMemFree(path);
    events->failure = E_OUTOFMEMORY;
    return events->failure;
  }
  memcpy(message, question, question_length * sizeof(wchar_t));
  memcpy(message + question_length, path, (path_length + 1) * sizeof(wchar_t));
  int answer = MessageBoxW(owner, message, L"Replace existing ZIP?",
                          MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
  DWORD answer_error = answer == 0 ? GetLastError() : ERROR_SUCCESS;
  CoTaskMemFree(message);
  if (answer == IDYES) {
    events->approved_path = path;
    *response = FDEOR_ACCEPT;
  } else {
    CoTaskMemFree(path);
    if (answer == 0) {
      events->failure =
          answer_error != 0 ? HRESULT_FROM_WIN32(answer_error) : E_FAIL;
      return events->failure;
    }
  }
  return S_OK;
}

static IFileDialogEventsVtbl zip_events_vtable = {
    zip_query_interface, zip_add_ref, zip_release, zip_file_ok,
    zip_folder_changing, zip_target_changed, zip_target_changed,
    zip_share_violation, zip_target_changed, zip_overwrite,
};

int graphcode_pick_zip(HWND owner, BOOL saving, const wchar_t *suggested_name,
                       wchar_t *buffer, DWORD capacity,
                       BOOL *replacement_approved, HRESULT *error) {
  if (error == NULL) return -1;
  *error = E_INVALIDARG;
  if (buffer == NULL || capacity == 0 || replacement_approved == NULL) return -1;
  buffer[0] = L'\0';
  *replacement_approved = FALSE;
  HRESULT initialized = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) {
    *error = initialized;
    return -1;
  }

  IFileDialog *dialog = NULL;
  ZipSaveEvents *events = NULL;
  DWORD cookie = 0;
  BOOL advised = FALSE;
  PWSTR path = NULL;
  int selected = -1;
  HRESULT result = CoCreateInstance(
      saving ? &CLSID_FileSaveDialog : &CLSID_FileOpenDialog, NULL,
      CLSCTX_INPROC_SERVER, &IID_IFileDialog, (void **)&dialog);
  if (FAILED(result)) goto cleanup;

  DWORD options = 0;
  result = dialog->lpVtbl->GetOptions(dialog, &options);
  if (FAILED(result)) goto cleanup;
  options &= ~(FOS_ALLOWMULTISELECT | FOS_PICKFOLDERS);
  options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR;
  options |= saving ? FOS_OVERWRITEPROMPT | FOS_STRICTFILETYPES : FOS_FILEMUSTEXIST;
  result = dialog->lpVtbl->SetOptions(dialog, options);
  if (FAILED(result)) goto cleanup;
  result = dialog->lpVtbl->SetTitle(
      dialog, saving ? L"Export Loop" : L"Import Loops Here");
  if (FAILED(result)) goto cleanup;
  static const COMDLG_FILTERSPEC filters[] = {{L"GraphCode ZIP bundles", L"*.zip"}};
  result = dialog->lpVtbl->SetFileTypes(dialog, ARRAYSIZE(filters), filters);
  if (FAILED(result)) goto cleanup;
  result = dialog->lpVtbl->SetDefaultExtension(dialog, L"zip");
  if (FAILED(result)) goto cleanup;
  if (saving) {
    result = dialog->lpVtbl->SetFileName(
        dialog, suggested_name != NULL ? suggested_name : L"Loop.zip");
    if (FAILED(result)) goto cleanup;
    events = CoTaskMemAlloc(sizeof(*events));
    if (events == NULL) {
      result = E_OUTOFMEMORY;
      goto cleanup;
    }
    memset(events, 0, sizeof(*events));
    events->iface.lpVtbl = &zip_events_vtable;
    events->references = 1;
    events->failure = S_OK;
    result = dialog->lpVtbl->Advise(dialog, &events->iface, &cookie);
    if (FAILED(result)) goto cleanup;
    advised = TRUE;
  }

  result = dialog->lpVtbl->Show(dialog, owner);
  if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    selected = 0;
    goto cleanup;
  }
  if (FAILED(result)) goto cleanup;
  if (events != NULL && FAILED(events->failure)) {
    result = events->failure;
    goto cleanup;
  }
  IShellItem *item = NULL;
  result = dialog->lpVtbl->GetResult(dialog, &item);
  if (FAILED(result)) goto cleanup;
  result = item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &path);
  item->lpVtbl->Release(item);
  if (FAILED(result)) goto cleanup;
  if (path == NULL || path[0] == L'\0') {
    result = E_FAIL;
    goto cleanup;
  }
  size_t length = wcslen(path);
  if (length >= capacity) {
    result = HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    goto cleanup;
  }
  memcpy(buffer, path, (length + 1) * sizeof(wchar_t));
  if (events != NULL && events->approved_path != NULL)
    *replacement_approved = lstrcmpW(path, events->approved_path) == 0;
  selected = 1;
  result = S_OK;

cleanup:
  if (advised) {
    HRESULT unadvised = dialog->lpVtbl->Unadvise(dialog, cookie);
    if (FAILED(unadvised)) {
      result = unadvised;
      selected = -1;
    }
  }
  CoTaskMemFree(path);
  if (dialog != NULL) dialog->lpVtbl->Release(dialog);
  if (events != NULL) zip_release(&events->iface);
  if (selected != 1) {
    buffer[0] = L'\0';
    *replacement_approved = FALSE;
  }
  *error = result;
  if (SUCCEEDED(initialized)) CoUninitialize();
  return selected;
}
