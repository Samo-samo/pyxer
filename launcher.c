/*
 * launcher.c - Mini packager launcher (onedir, shared-runtime layout)
 *
 * The packager ships:
 *   <dist>\
 *     <app>.exe                 this launcher (copy it per app)
 *     runtime\                  shared embeddable CPython + deps
 *       python.exe
 *       python312.dll
 *       python312.zip
 *       python312._pth
 *       apps\
 *         <app1>\main.py        packaged application entrypoint
 *         <app2>\main.py        (each exe = one folder)
 *
 * The launcher derives the app name from its own file name
 * (e.g. "not.exe" -> "not") and runs
 *   runtime\python.exe -c "sys.path.insert(0, <app_dir>);
 *                           import runpy;
 *                           runpy.run_path(<app_dir>\main.py, run_name='__main__')"
 * so every exe shares one runtime while keeping its own source folder.
 * Embeddable Python runs in isolated mode (a ._pth file exists), so the
 * script's own directory is NOT auto-added to sys.path; that is why the
 * launcher injects the app folder explicitly.
 *
 * User arguments passed to <app>.exe are forwarded to the Python app:
 * they become sys.argv[1:] (sys.argv[0] is '-c').
 *
 * Console output is forwarded only when the launcher itself is compiled as a
 * console subsystem binary (development mode). For release builds use
 *   /SUBSYSTEM:WINDOWS  -> no console, exit code still propagated.
 *
 * Build (console, dev):
 *   cl /nologo /O2 /MT launcher.c /Fe:launcher.exe /link /SUBSYSTEM:CONSOLE /MACHINE:X64
 * Build (windowed, release):
 *   cl /nologo /O2 /MT launcher.c /Fe:launcher.exe /link /SUBSYSTEM:WINDOWS /MACHINE:X64
 * Build (windowed, no console):
 *   cl /nologo /O2 /MT /D PKG_NoConsole launcher.c /Fe:launcher.exe
 *       /link /SUBSYSTEM:WINDOWS /MACHINE:X64
 *   -> uses pythonw.exe (GUI) instead of python.exe, so no console window.
 */

#include <windows.h>
#include <string.h>

#pragma comment(lib, "user32.lib")

/* pythonw.exe is the GUI (windowless-console) Python; python.exe spawns a
 * console window even when the parent is a GUI app, which is what shows the
 * black console next to the GUI. -NoConsole (PKG_NoConsole) selects pythonw
 * and suppresses the new console allocation. */
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

int PKG_Run(int nShow)
{
    char exe_path[MAX_PATH];
    if (GetModuleFileNameA(NULL, exe_path, MAX_PATH) == 0) {
        MessageBoxA(NULL, "Could not determine launcher path.", "Mini Packager", MB_OK | MB_ICONERROR);
        return 1;
    }

    /* <exe_dir> */
    char dir[MAX_PATH];
    strcpy(dir, exe_path);
    char* slash = strrchr(dir, '\\');
    if (slash) *slash = 0;

    /* <exe_dir>\<appname>.exe  ->  app name = file base name */
    char appname[MAX_PATH];
    {
        const char* base = exe_path;
        const char* ls = strrchr(base, '\\');
        if (ls) base = ls + 1;
        strcpy(appname, base);
        char* dot = strrchr(appname, '.');
        if (dot) *dot = 0;
        if (appname[0] == 0) {
            MessageBoxA(NULL, "Could not derive app name from launcher file name.",
                        "Mini Packager", MB_OK | MB_ICONERROR);
            return 4;
        }
    }

    char pyexe[MAX_PATH + 32];
    wsprintfA(pyexe, "%s\\runtime\\%s", dir, PY_NAME);

    /* Expose the launcher's own directory to the app: data (SQLite DB,
     * backups) must live next to the exe, not inside runtime\apps\<app>\
     * which the packager wipes on the next build. Apps read APP_DATA_DIR
     * (fall back to __file__/sys.executable when unset). */
    SetEnvironmentVariableA("APP_DATA_DIR", dir);

    char appdir[MAX_PATH + 64];
    wsprintfA(appdir, "%s\\runtime\\apps\\%s", dir, appname);

    char appmain[MAX_PATH + 64];
    wsprintfA(appmain, "%s\\main.py", appdir);

    if (GetFileAttributesA(pyexe) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxA(NULL, "Embedded Python not found (runtime\\python.exe is missing).",
                    "Mini Packager", MB_OK | MB_ICONERROR);
        return 2;
    }
    if (GetFileAttributesA(appmain) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxA(NULL, "Packed app not found for this exe (runtime\\apps\\<app>\\main.py).",
                    "Mini Packager", MB_OK | MB_ICONERROR);
        return 5;
    }

    /* User args (everything after the exe name). */
    char* args = skip_exe_part(GetCommandLineA());

    /* Python bootstrap: inject the app dir and run its main.py. */
    char pycode[16384];
    wsprintfA(pycode,
              "import sys;sys.path.insert(0,r'%s');import runpy;runpy.run_path(r'%s',run_name='__main__')",
              appdir, appmain);

    char cmd[16384];
    {
        int n = wsprintfA(cmd, "\"%s\" -c \"%s\"", pyexe, pycode);
        if (args && *args) wsprintfA(cmd + n, " %s", args);
    }

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = sizeof(si);

    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_FLAGS, NULL, dir, &si, &pi)) {
        MessageBoxA(NULL, "Could not start the packaged application.", "Mini Packager",
                    MB_OK | MB_ICONERROR);
        return 3;
    }

    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);

    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return (int)code;
}

/* Console build: plain main so printf/print output stays visible. */
int main(void)
{
    return PKG_Run(SW_SHOWNORMAL);
}

/* Windowed build: WinMain entry point, calls the same logic. */
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
                   LPSTR lpCmdLine, int nCmdShow)
{
    return PKG_Run(nCmdShow);
}