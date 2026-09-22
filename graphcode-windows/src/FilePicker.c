#include "FilePicker.h"

#include <shobjidl.h>

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
