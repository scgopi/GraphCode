#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <consoleapi.h>

#define BASE_DIR L"."
#define PIPE_NAME L"\\\\.\\pipe\\zmx-conpty-spike"
#define READY_FILE L"ready.txt"
#define LOG_FILE L"daemon.log"
#define OUTPUT_CAP 262144

typedef struct Server {
    HANDLE hpc;
    HANDLE in_read;
    HANDLE in_write;
    HANDLE out_read;
    HANDLE out_write;
    HANDLE child;
    DWORD child_pid;
    HANDLE job;
    HANDLE reader;
    CRITICAL_SECTION lock;
    char output[OUTPUT_CAP];
    size_t output_len;
    volatile LONG running;
    FILE *log;
    int lock_initialized;
} Server;

static void log_line(Server *s, const char *prefix, const char *data, size_t len) {
    if (!s->log) return;
    EnterCriticalSection(&s->lock);
    fprintf(s->log, "%s", prefix);
    fwrite(data, 1, len, s->log);
    fputs("\n", s->log);
    fflush(s->log);
    LeaveCriticalSection(&s->lock);
}

static DWORD WINAPI reader_thread(void *arg) {
    Server *s = (Server *)arg;
    EnterCriticalSection(&s->lock);
    fprintf(s->log, "[reader] started\n");
    fflush(s->log);
    LeaveCriticalSection(&s->lock);
    char buf[4096];
    DWORD n = 0;
    while (ReadFile(s->out_read, buf, sizeof(buf), &n, NULL) && n > 0) {
        EnterCriticalSection(&s->lock);
        size_t keep = n;
        if (keep > OUTPUT_CAP - s->output_len) keep = OUTPUT_CAP - s->output_len;
        if (keep) {
            memcpy(s->output + s->output_len, buf, keep);
            s->output_len += keep;
        }
        LeaveCriticalSection(&s->lock);
        log_line(s, "[output] ", buf, n);
    }
    DWORD err = GetLastError();
    EnterCriticalSection(&s->lock);
    fprintf(s->log, "[reader] exited gle=%lu\n", (unsigned long)err);
    fflush(s->log);
    LeaveCriticalSection(&s->lock);
    InterlockedExchange(&s->running, 0);
    return 0;
}

static int write_all(HANDLE h, const void *data, DWORD len) {
    const char *p = (const char *)data;
    while (len) {
        DWORD n = 0;
        if (!WriteFile(h, p, len, &n, NULL) || n == 0) return 0;
        p += n;
        len -= n;
    }
    return 1;
}

static int write_ready(Server *s) {
    FILE *f = _wfopen(READY_FILE, L"w, ccs=UTF-8");
    if (!f) return 0;
    fwprintf(f, L"pid=%lu\npipe=%s\nconpty=ok\njob=kill-on-close\n", (unsigned long)s->child_pid, PIPE_NAME);
    fclose(f);
    return 1;
}

static void remove_ready(void) {
    DeleteFileW(READY_FILE);
}

static int create_server(Server *s) {
#define STEP_FAIL(msg) do { fprintf(stderr, "create_server: %s gle=%lu\n", msg, (unsigned long)GetLastError()); return 0; } while (0)
    SECURITY_ATTRIBUTES sa;
    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = FALSE;

    s->job = CreateJobObjectW(NULL, NULL);
    if (!s->job) STEP_FAIL("CreateJobObject");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION ji;
    memset(&ji, 0, sizeof(ji));
    ji.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(s->job, JobObjectExtendedLimitInformation, &ji, sizeof(ji))) STEP_FAIL("SetInformationJobObject");

    if (!CreatePipe(&s->in_read, &s->in_write, &sa, 0)) STEP_FAIL("CreatePipe input");
    if (!CreatePipe(&s->out_read, &s->out_write, &sa, 0)) STEP_FAIL("CreatePipe output");
    SetHandleInformation(s->in_read, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(s->in_write, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(s->out_read, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(s->out_write, HANDLE_FLAG_INHERIT, 0);

    HRESULT hr = CreatePseudoConsole((COORD){80, 25}, s->in_read, s->out_write, 0, &s->hpc);
    if (FAILED(hr)) STEP_FAIL("CreatePseudoConsole");

    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
    if (!attrs) STEP_FAIL("HeapAlloc attrs");
    if (!InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size)) STEP_FAIL("InitializeProcThreadAttributeList");
    if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   s->hpc, sizeof(s->hpc), NULL, NULL)) STEP_FAIL("UpdateProcThreadAttribute");

    STARTUPINFOEXW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.StartupInfo.cb = sizeof(si);
    si.lpAttributeList = attrs;
    wchar_t cmdline[] = L"cmd.exe /Q /K";
    DWORD flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;
    BOOL ok = CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, flags, NULL, NULL,
                             &si.StartupInfo, &pi);
    DeleteProcThreadAttributeList(attrs);
    HeapFree(GetProcessHeap(), 0, attrs);
    if (!ok) STEP_FAIL("CreateProcessW child");

    s->child = pi.hProcess;
    s->child_pid = pi.dwProcessId;
    CloseHandle(pi.hThread);
    // The handles supplied to CreatePseudoConsole must be released after the
    // hosted process is created; retain only the host-side pipe ends.
    CloseHandle(s->in_read); s->in_read = NULL;
    CloseHandle(s->out_write); s->out_write = NULL;
    if (!AssignProcessToJobObject(s->job, s->child)) STEP_FAIL("AssignProcessToJobObject");

    s->log = _wfopen(LOG_FILE, L"w");
    if (!s->log) STEP_FAIL("open log");
    fprintf(s->log, "[daemon] child_pid=%lu\n", (unsigned long)s->child_pid);
    fprintf(s->log, "[daemon] ConPTY=CreatePseudoConsole(80x25)\n");
    fprintf(s->log, "[daemon] JobObject=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE\n");
    fprintf(s->log, "[daemon] NamedPipe=%ls\n", PIPE_NAME);
    fflush(s->log);

    InitializeCriticalSection(&s->lock);
    s->lock_initialized = 1;
    InterlockedExchange(&s->running, 1);
    s->reader = CreateThread(NULL, 0, reader_thread, s, 0, NULL);
    if (!s->reader) STEP_FAIL("CreateThread reader");
    if (!write_ready(s)) STEP_FAIL("write_ready");
    return 1;
}

static int read_line(HANDLE h, char *buf, DWORD cap) {
    DWORD used = 0;
    while (used + 1 < cap) {
        DWORD n = 0;
        if (!ReadFile(h, buf + used, 1, &n, NULL) || n == 0) return 0;
        if (buf[used++] == '\n') break;
    }
    buf[used] = 0;
    return 1;
}

static void trim_line(char *line) {
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\r' || line[n - 1] == '\n')) line[--n] = 0;
}

static void respond(HANDLE pipe, const char *data, DWORD len) {
    write_all(pipe, data, len);
    FlushFileBuffers(pipe);
}

static void handle_request(Server *s, HANDLE pipe, char *line) {
    trim_line(line);
    if (strncmp(line, "WRITE ", 6) == 0) {
        const char *text = line + 6;
        char command[4096];
        int n = _snprintf_s(command, sizeof(command), _TRUNCATE, "%s\r", text);
        int wrote = (n > 0) && write_all(s->in_write, command, (DWORD)n);
        EnterCriticalSection(&s->lock);
        fprintf(s->log, "[ipc] WRITE bytes=%d ok=%d gle=%lu text=%s\n", n, wrote, (unsigned long)GetLastError(), text);
        fflush(s->log);
        LeaveCriticalSection(&s->lock);
        if (wrote) respond(pipe, "OK write\n", 9);
        else respond(pipe, "ERR write\n", 10);
        return;
    }
    if (strcmp(line, "DETACH") == 0) {
        respond(pipe, "OK detached\n", 13);
        log_line(s, "[ipc] ", "DETACH", 6);
        return;
    }
    if (strcmp(line, "SNAPSHOT") == 0) {
        EnterCriticalSection(&s->lock);
        char header[64];
        int hn = _snprintf_s(header, sizeof(header), _TRUNCATE, "SNAPSHOT %zu\n", s->output_len);
        write_all(pipe, header, (DWORD)hn);
        if (s->output_len) write_all(pipe, s->output, (DWORD)s->output_len);
        LeaveCriticalSection(&s->lock);
        FlushFileBuffers(pipe);
        return;
    }
    if (strcmp(line, "STATUS") == 0) {
        char status[256];
        EnterCriticalSection(&s->lock);
        size_t len = s->output_len;
        LeaveCriticalSection(&s->lock);
        int n = _snprintf_s(status, sizeof(status), _TRUNCATE,
                            "STATUS pid=%lu running=%ld output=%zu conpty=1 named_pipe=1 job=1\n",
                            (unsigned long)s->child_pid, (long)s->running, len);
        respond(pipe, status, (DWORD)n);
        return;
    }
    if (strcmp(line, "QUIT") == 0) {
        respond(pipe, "OK stopping\n", 13);
        InterlockedExchange(&s->running, 0);
        return;
    }
    respond(pipe, "ERR unknown\n", 13);
}

static int server_loop(Server *s) {
    while (s->running) {
        HANDLE pipe = CreateNamedPipeW(
            PIPE_NAME, PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1, 65536, 65536, 0, NULL);
        if (pipe == INVALID_HANDLE_VALUE) return 0;
        BOOL connected = ConnectNamedPipe(pipe, NULL);
        if (!connected && GetLastError() != ERROR_PIPE_CONNECTED) {
            CloseHandle(pipe);
            continue;
        }
        char line[8192];
        if (read_line(pipe, line, sizeof(line))) handle_request(s, pipe, line);
        FlushFileBuffers(pipe);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }
    return 1;
}

static void cleanup_server(Server *s) {
    InterlockedExchange(&s->running, 0);
    if (s->child) {
        WaitForSingleObject(s->child, 200);
        DWORD code = STILL_ACTIVE;
        if (GetExitCodeProcess(s->child, &code) && code == STILL_ACTIVE) TerminateProcess(s->child, 0);
        WaitForSingleObject(s->child, 1000);
        CloseHandle(s->child);
    }
    if (s->reader) {
        CloseHandle(s->out_write);
        WaitForSingleObject(s->reader, 1000);
        CloseHandle(s->reader);
    }
    if (s->hpc) ClosePseudoConsole(s->hpc);
    if (s->in_read) CloseHandle(s->in_read);
    if (s->in_write) CloseHandle(s->in_write);
    if (s->out_read) CloseHandle(s->out_read);
    if (s->out_write) CloseHandle(s->out_write);
    if (s->job) CloseHandle(s->job);
    if (s->log) fclose(s->log);
    DeleteFileW(READY_FILE);
    DeleteCriticalSection(&s->lock);
}

static int connect_pipe(HANDLE *out) {
    for (int i = 0; i < 100; ++i) {
        HANDLE h = CreateFileW(PIPE_NAME, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (h != INVALID_HANDLE_VALUE) { *out = h; return 1; }
        Sleep(50);
    }
    return 0;
}

static int client_request(const char *request, int raw_snapshot) {
    HANDLE pipe;
    if (!connect_pipe(&pipe)) { fprintf(stderr, "connect failed gle=%lu\n", (unsigned long)GetLastError()); return 2; }
    if (!write_all(pipe, request, (DWORD)strlen(request))) { CloseHandle(pipe); return 3; }
    FlushFileBuffers(pipe);
    char buf[8192];
    DWORD n;
    int rc = 0;
    while (ReadFile(pipe, buf, sizeof(buf), &n, NULL) && n) {
        if (raw_snapshot) {
            DWORD out_n = 0;
            WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), buf, n, &out_n, NULL);
        } else {
            fwrite(buf, 1, n, stdout);
            fflush(stdout);
        }
    }
    CloseHandle(pipe);
    return rc;
}

static int wait_ready(void) {
    for (int i = 0; i < 100; ++i) {
        if (GetFileAttributesW(READY_FILE) != INVALID_FILE_ATTRIBUTES) return 1;
        Sleep(50);
    }
    return 0;
}

static int start_daemon(void) {
    DeleteFileW(READY_FILE);
    DeleteFileW(LOG_FILE);
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return 2;
    wchar_t cmdline[2 * MAX_PATH];
    _snwprintf_s(cmdline, _countof(cmdline), _TRUNCATE, L"\"%s\" daemon", path);
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = sizeof(si);
    if (!CreateProcessW(path, cmdline, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                        NULL, BASE_DIR, &si, &pi)) {
        fprintf(stderr, "CreateProcess daemon failed gle=%lu\n", (unsigned long)GetLastError());
        return 3;
    }
    printf("daemon_process_pid=%lu\n", (unsigned long)pi.dwProcessId);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (!wait_ready()) { fprintf(stderr, "daemon did not become ready\n"); return 4; }
    printf("ready=%ls\n", READY_FILE);
    return 0;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 2) {
        fwprintf(stderr, L"usage: start|daemon|send <text>|detach|attach|snapshot|status|stop\n");
        return 1;
    }
    if (wcscmp(argv[1], L"daemon") == 0) {
        Server s;
        memset(&s, 0, sizeof(s));
        if (!create_server(&s)) {
            fprintf(stderr, "create_server failed gle=%lu\n", (unsigned long)GetLastError());
            cleanup_server(&s);
            return 10;
        }
        server_loop(&s);
        cleanup_server(&s);
        return 0;
    }
    if (wcscmp(argv[1], L"start") == 0) return start_daemon();
    if (wcscmp(argv[1], L"send") == 0 && argc >= 3) {
        char text[4096];
        int n = WideCharToMultiByte(CP_UTF8, 0, argv[2], -1, text, sizeof(text), NULL, NULL);
        if (!n) return 2;
        char req[4200];
        _snprintf_s(req, sizeof(req), _TRUNCATE, "WRITE %s\n", text);
        return client_request(req, 0);
    }
    if (wcscmp(argv[1], L"detach") == 0) return client_request("DETACH\n", 0);
    if (wcscmp(argv[1], L"attach") == 0 || wcscmp(argv[1], L"snapshot") == 0) return client_request("SNAPSHOT\n", 1);
    if (wcscmp(argv[1], L"status") == 0) return client_request("STATUS\n", 0);
    if (wcscmp(argv[1], L"stop") == 0) return client_request("QUIT\n", 0);
    fwprintf(stderr, L"unknown command\n");
    return 1;
}
