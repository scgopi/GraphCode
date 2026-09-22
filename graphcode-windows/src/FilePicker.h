#pragma once

#include <windows.h>

// Fills `buffer` with up to `max_files` selected paths, each occupying its own
// `stride`-wide (in wchar_t units), null-terminated slot: file i's path starts at
// `buffer + i * stride`. Returns the number of paths written, 0 if the user cancelled,
// or -1 on failure.
int graphcode_pick_files(HWND owner, wchar_t *buffer, DWORD stride, DWORD max_files);
