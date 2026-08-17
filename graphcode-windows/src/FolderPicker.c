#include "FolderPicker.h"

#include <shobjidl.h>

int graphcode_pick_folder(HWND owner, wchar_t *buffer, DWORD capacity) {
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
      dialog, options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
  dialog->lpVtbl->SetTitle(dialog, L"Open GraphCode folder or Git repository");
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

  IShellItem *item = NULL;
  result = dialog->lpVtbl->GetResult(dialog, &item);
  if (SUCCEEDED(result)) {
    PWSTR path = NULL;
    result = item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &path);
    if (SUCCEEDED(result) && path != NULL) {
      lstrcpynW(buffer, path, (int)capacity);
      CoTaskMemFree(path);
    }
    item->lpVtbl->Release(item);
  }
  dialog->lpVtbl->Release(dialog);
  if (SUCCEEDED(initialized)) CoUninitialize();
  return SUCCEEDED(result) ? 1 : -1;
}
