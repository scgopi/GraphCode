#pragma once

#include <windows.h>

// Fills `buffer` with up to `max_files` selected paths, each occupying its own
// `stride`-wide (in wchar_t units), null-terminated slot: file i's path starts at
// `buffer + i * stride`. Returns the number of paths written, 0 if the user cancelled,
// or -1 on failure.
int graphcode_pick_files(HWND owner, wchar_t *buffer, DWORD stride, DWORD max_files);

// Single ZIP selection: 1 selected, 0 cancelled, -1 failed with `error` set.
// Replacement approval is an actual overwrite confirmation for the returned path.
int graphcode_pick_zip(HWND owner, BOOL saving, const wchar_t *suggested_name,
                       wchar_t *buffer, DWORD capacity,
                       BOOL *replacement_approved, HRESULT *error);
