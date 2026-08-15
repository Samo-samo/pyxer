/*
 * launcher_onefile.c - Self-extracting single-file launcher for the mini packager.
 *
 * Layout of the produced <app>_onefile.exe:
 *   [ launcher code ] [ payload.zip (runtime + apps\<app> ) ] [ footer ]
 *
 * Footer (last 21 bytes):
 *   bytes 0..8   9-byte signature "MINI1FEXE"
 *   bytes 9..12   reserved (zero)
 *   bytes 13..20  little-endian uint64 = payload size (the zip before the footer)
 *
 * On startup the launcher:
 *   1. reads its own file and locates payload.zip from the footer,
 *   2. writes payload.zip to %TEMP%\mini_<app>_<exefilesize>\payload.zip,
 *   3. extracts it using Windows' built-in tar.exe (Win10 1803+, reads zip),
 *   4. runs runtime\python.exe -c runpy... like the onedir launcher, with
 *      APP_DATA_DIR set to the exe's own directory (DBs stay next to the exe).
 *
 * The cache dir is keyed by the exe's file size, so a new build automatically
 * re-extracts; repeating the same exe is fast (extraction happens once).
 *
 * Build:
 *   cl /nologo /O2 /MT launcher_onefile.c /Fe:launcher_onefile.exe
 *      /link /SUBSYSTEM:CONSOLE|WINDOWS /MACHINE:X64
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#pragma comment(lib, "user32.lib")

#define SIG  "MINI1FEXE"
#define SIGLEN 9
#define FOOTER_LEN 21   /* SIG(9) + reserved(4) + payload size(8) */

/* -NoConsole (PKG_NoConsole): use pythonw.exe and suppress the new console */
#ifdef PKG_NoConsole
#define PY_NAME "pythonw.exe"
#define CREATE_FLAGS (CREATE_NO_WINDOW | 0)
#else
#define PY_NAME "python.exe"
#define CREATE_FLAGS 0
#endif

static char* skip_exe_part(char* cmd)
{
    if (cmd[0] == '"') {
        char* q = strchr(cmd + 1, '"');
        if (q) cmd = q + 1;
    } else {
        char* sp = strchr(cmd, ' ');
        if (sp) cmd = sp;
    }
    while (*cmd == ' ') cmd++;
    return cmd;
}

static void errbox(const char* msg)
{
    MessageBoxA(NULL, msg, "Mini Packager (onefile)", MB_OK | MB_ICONERROR);
}

/* returns 0 on success; fills *payptr (malloc'd) and *paysize */
static int read_payload(const WCHAR* selfPath, unsigned char** payptr, __int64* paysize)
{
    HANDLE h = CreateFileW(selfPath, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return -1;

    LARGE_INTEGER sz;
    if (!GetFileSizeEx(h, &sz)) { CloseHandle(h); return -1; }

    unsigned char footer[FOOTER_LEN];
    LARGE_INTEGER off;
    off.QuadPart = sz.QuadPart - FOOTER_LEN;
    if (off.QuadPart <= 0) { CloseHandle(h); return -1; }
    if (!SetFilePointerEx(h, off, NULL, FILE_BEGIN)) { CloseHandle(h); return -1; }

    DWORD rd = 0, tot = 0;
    while (tot < FOOTER_LEN) {
        if (!ReadFile(h, footer + tot, (DWORD)(FOOTER_LEN - tot), &rd, NULL) || rd == 0) break;
        tot += rd;
    }
    if (tot != FOOTER_LEN) { CloseHandle(h); return -1; }

    if (memcmp(footer, SIG, SIGLEN) != 0) { CloseHandle(h); return -1; }

    __int64 paySize = 0;
    for (int i = 0; i < 8; i++) paySize |= ((__int64)footer[13 + i]) << (8 * i);
    if (paySize <= 0 || paySize >= sz.QuadPart) { CloseHandle(h); return -1; }

    __int64 payOff = sz.QuadPart - FOOTER_LEN - paySize;
    if (payOff < 0x4000) { CloseHandle(h); return -1; } /* enough for a real PE */

    unsigned char* buf = (unsigned char*)malloc((size_t)paySize);
    if (!buf) { CloseHandle(h); return -1; }

    LARGE_INTEGER o2; o2.QuadPart = payOff;
    if (!SetFilePointerEx(h, o2, NULL, FILE_BEGIN)) { free(buf); CloseHandle(h); return -1; }

    tot = 0;
    while (tot < (DWORD)paySize) {
        if (!ReadFile(h, buf + tot, (DWORD)(paySize - tot), &rd, NULL) || rd == 0) break;
        tot += rd;
    }
    CloseHandle(h);
    if (tot != (DWORD)paySize) { free(buf); return -1; }

    *payptr = buf;
    *paysize = paySize;
    return 0;
}

int PKG_RunOnefile(int nShow)
{
    WCHAR exe_path[MAX_PATH];
    if (GetModuleFileNameW(NULL, exe_path, MAX_PATH) == 0) {
        errbox("Could not determine launcher path."); return 1;
    }

    char appname[MAX_PATH];
    {
        char base[MAX_PATH];
        WideCharToMultiByte(CP_ACP, 0, exe_path, -1, base, MAX_PATH, NULL, NULL);
        char* ls = strrchr(base, '\\');
        const char* name = ls ? ls + 1 : base;
        strcpy(appname, name);
        char* dot = strrchr(appname, '.');
        if (dot) *dot = 0;
        if (appname[0] == 0) { errbox("Could not derive app name."); return 4; }
    }

    unsigned char* payload = NULL;
    __int64 paySize = 0;
    if (read_payload(exe_path, &payload, &paySize) != 0) {
        errbox("Embedded payload not found (not a onefile build)."); return 6;
    }

    /* Exe dir stays the app-data dir (DBs written next to the exe). */
    WCHAR dirW[MAX_PATH];
    wcscpy(dirW, exe_path);
    WCHAR* ws = wcsrchr(dirW, L'\\');
    if (ws) *ws = 0;
    SetEnvironmentVariableW(L"APP_DATA_DIR", dirW);

    /* Cache dir keyed by exe file size so new builds re-extract. */
    LARGE_INTEGER fsz;
    {
        HANDLE h = CreateFileW(exe_path, GENERIC_READ, FILE_SHARE_READ, NULL,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) { free(payload); errbox("Cannot stat own exe."); return 7; }
        GetFileSizeEx(h, &fsz); CloseHandle(h);
    }

    char tdir[MAX_PATH + 40];
    {
        const char* tmp = getenv("TEMP");
        if (!tmp) tmp = ".";
        wsprintfA(tdir, "%s\\mini_%s_%I64d", tmp, appname, fsz.QuadPart);
    }

    char marker[MAX_PATH + 70];
    wsprintfA(marker, "%s\\.done", tdir);
    if (GetFileAttributesA(marker) == INVALID_FILE_ATTRIBUTES) {
        CreateDirectoryA(tdir, NULL);
        char zipPath[MAX_PATH + 70];
        wsprintfA(zipPath, "%s\\payload.zip", tdir);

        HANDLE hz = CreateFileA(zipPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, NULL);
        if (hz == INVALID_HANDLE_VALUE) { free(payload); errbox("Cannot write temp payload."); return 8; }
        DWORD wrt = 0, total = 0;
        while (total < (DWORD)paySize) {
            if (!WriteFile(hz, payload + total, (DWORD)(paySize - total), &wrt, NULL) || wrt == 0) break;
            total += wrt;
        }
        CloseHandle(hz);
        if (total != (DWORD)paySize) { free(payload); errbox("Failed writing temp payload."); return 9; }

        /* The zip holds the *contents* of runtime\ (python.exe, apps\, ...)
         * so extract it into tdir\runtime to rebuild the expected layout. */
        char rtDir[MAX_PATH + 70];
        wsprintfA(rtDir, "%s\\runtime", tdir);
        CreateDirectoryA(rtDir, NULL);

        /* Windows built-in tar reads zip archives. */
        char tarCmd[MAX_PATH * 2];
        const char* sysroot = getenv("SystemRoot");
        if (!sysroot) sysroot = "C:\\Windows";
        wsprintfA(tarCmd, "%s\\system32\\tar.exe -xf \"%s\" -C \"%s\"",
                  sysroot, zipPath, rtDir);

        STARTUPINFOA si; PROCESS_INFORMATION pi;
        memset(&si, 0, sizeof(si)); memset(&pi, 0, sizeof(pi));
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        if (!CreateProcessA(NULL, tarCmd, NULL, NULL, FALSE, 0, NULL, rtDir, &si, &pi)) {
            free(payload); errbox("tar.exe extraction failed."); return 10;
        }
        WaitForSingleObject(pi.hProcess, INFINITE);
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);

        HANDLE hm = CreateFileA(marker, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                                FILE_ATTRIBUTE_NORMAL, NULL);
        if (hm != INVALID_HANDLE_VALUE) CloseHandle(hm);
    }
    free(payload);

    char pyexe[MAX_PATH + 40];
    wsprintfA(pyexe, "%s\\runtime\\%s", tdir, PY_NAME);

    /* A onefile exe carries exactly one app; the payload keeps it under
     * runtime\apps\<AppName>\ but we don't rely on the exe's own name here,
     * (it would be "<AppName>_onefile"). Instead scan for the first folder
     * under runtime\apps\ and use it. */
    char appdir[MAX_PATH + 70];
    char appmain[MAX_PATH + 70];
    {
        char appsDir[MAX_PATH + 70];
        wsprintfA(appsDir, "%s\\runtime\\apps", tdir);
        WIN32_FIND_DATAA fd;
        char pat[MAX_PATH + 70];
        wsprintfA(pat, "%s\\*", appsDir);
        HANDLE hf = FindFirstFileA(pat, &fd);
        if (hf == INVALID_HANDLE_VALUE || (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
            errbox("Extracted runtime\\apps is empty."); return 12;
        }
        /* skip '.' and '..' until the first real directory */
        while (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0) {
            if (!FindNextFileA(hf, &fd)) { FindClose(hf); errbox("Extracted app missing."); return 12; }
        }
        FindClose(hf);
        wsprintfA(appdir, "%s\\%s", appsDir, fd.cFileName);
        wsprintfA(appmain, "%s\\main.py", appdir);
    }

    if (GetFileAttributesA(pyexe) == INVALID_FILE_ATTRIBUTES) {
        errbox("Extracted runtime missing python.exe."); return 11;
    }
    if (GetFileAttributesA(appmain) == INVALID_FILE_ATTRIBUTES) {
        errbox("Extracted app missing main.py."); return 12;
    }

    char* args = skip_exe_part(GetCommandLineA());
    char pycode[16384];
    wsprintfA(pycode,
              "import sys;sys.path.insert(0,r'%s');import runpy;runpy.run_path(r'%s',run_name='__main__')",
              appdir, appmain);

    char cmd[16384];
    {
        int n = wsprintfA(cmd, "\"%s\" -c \"%s\"", pyexe, pycode);
        if (args && *args) wsprintfA(cmd + n, " %s", args);
    }

    STARTUPINFOA si2; PROCESS_INFORMATION pi2;
    memset(&si2, 0, sizeof(si2)); memset(&pi2, 0, sizeof(pi2));
    si2.cb = sizeof(si2);
    char dirA[MAX_PATH];
    WideCharToMultiByte(CP_ACP, 0, dirW, -1, dirA, MAX_PATH, NULL, NULL);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_FLAGS, NULL, dirA, &si2, &pi2)) {
        errbox("Could not start the packaged application."); return 3;
    }

    CloseHandle(pi2.hThread);
    WaitForSingleObject(pi2.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi2.hProcess, &code);
    CloseHandle(pi2.hProcess);
    return (int)code;
}

int main(void)
{
    return PKG_RunOnefile(SW_SHOWNORMAL);
}

int WINAPI WinMain(HINSTANCE h, HINSTANCE hp, LPSTR l, int n)
{
    return PKG_RunOnefile(n);
}