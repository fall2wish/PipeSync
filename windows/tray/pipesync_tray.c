#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdbool.h>

#define WM_TRAYICON       (WM_USER + 1)
#define ID_TIMER_POLL     1001

#define ID_TRAY_STATUS    2001
#define ID_TRAY_CONSOLE   2002
#define ID_TRAY_AUTOSTART 2003
#define ID_TRAY_SYNC_NOW  2004
#define ID_TRAY_RESTART   2005
#define ID_TRAY_EXIT      2006

static const wchar_t *CLASS_NAME = L"PipeSyncTrayWindowClass";
static const wchar_t *RUN_KEY_PATH = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static const wchar_t *RUN_VALUE_NAME = L"PipeSync";
static const wchar_t *DEFAULT_CONSOLE_URL = L"http://127.0.0.1:8384";

static NOTIFYICONDATAW g_nid;
static PROCESS_INFORMATION g_daemonPi;
static BOOL g_daemonRunning = FALSE;
static int g_daemonPort = 8384;

/**
 * 检查当前是否已在注册表中设置开机自启动
 */
BOOL IsAutostartEnabled(void) {
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY_PATH, 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
        return FALSE;
    }
    DWORD type = 0;
    DWORD dataSize = 0;
    LONG res = RegQueryValueExW(hKey, RUN_VALUE_NAME, NULL, &type, NULL, &dataSize);
    RegCloseKey(hKey);
    return (res == ERROR_SUCCESS);
}

/**
 * 切换开机自启动设置 (写入或删除注册表项)
 */
BOOL ToggleAutostart(void) {
    HKEY hKey;
    if (IsAutostartEnabled()) {
        if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY_PATH, 0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
            RegDeleteValueW(hKey, RUN_VALUE_NAME);
            RegCloseKey(hKey);
            return FALSE;
        }
    } else {
        if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY_PATH, 0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
            wchar_t exePath[MAX_PATH];
            GetModuleFileNameW(NULL, exePath, MAX_PATH);
            wchar_t cmdLine[MAX_PATH + 32];
            wsprintfW(cmdLine, L"\"%s\" --minimized", exePath);
            RegSetValueExW(
                hKey,
                RUN_VALUE_NAME,
                0,
                REG_SZ,
                (const BYTE *)cmdLine,
                (DWORD)((lstrlenW(cmdLine) + 1) * sizeof(wchar_t))
            );
            RegCloseKey(hKey);
            return TRUE;
        }
    }
    return IsAutostartEnabled();
}

/**
 * 启动后台 PipeSync 守护进程 (无命令行黑框 CREATE_NO_WINDOW)
 */
void StartDaemonProcess(void) {
    if (g_daemonRunning && g_daemonPi.hProcess != NULL) {
        DWORD exitCode = 0;
        if (GetExitCodeProcess(g_daemonPi.hProcess, &exitCode) && exitCode == STILL_ACTIVE) {
            return; // 进程已在运行
        }
    }

    wchar_t currentDir[MAX_PATH];
    GetModuleFileNameW(NULL, currentDir, MAX_PATH);
    wchar_t *lastSlash = wcsrchr(currentDir, L'\\');
    if (lastSlash) {
        *lastSlash = L'\0';
    }

    // 优先寻找同一目录下的 pipesync.exe，其次检查上一级目录
    wchar_t daemonPath[MAX_PATH];
    wsprintfW(daemonPath, L"%s\\pipesync.exe", currentDir);
    if (GetFileAttributesW(daemonPath) == INVALID_FILE_ATTRIBUTES) {
        wsprintfW(daemonPath, L"%s\\..\\build\\pipesync.exe", currentDir);
    }
    if (GetFileAttributesW(daemonPath) == INVALID_FILE_ATTRIBUTES) {
        // 回退为从 PATH 查找 pipesync
        lstrcpyW(daemonPath, L"pipesync.exe");
    }

    wchar_t cmdLine[MAX_PATH + 128];
    wsprintfW(cmdLine, L"\"%s\" serve --port %d --no-browser", daemonPath, g_daemonPort);

    STARTUPINFOW si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    ZeroMemory(&g_daemonPi, sizeof(g_daemonPi));

    BOOL success = CreateProcessW(
        NULL,
        cmdLine,
        NULL,
        NULL,
        FALSE,
        CREATE_NO_WINDOW,
        NULL,
        currentDir,
        &si,
        &g_daemonPi
    );

    if (success) {
        g_daemonRunning = TRUE;
    } else {
        g_daemonRunning = FALSE;
    }
}

/**
 * 终止后台守护进程
 */
void StopDaemonProcess(void) {
    if (g_daemonRunning && g_daemonPi.hProcess != NULL) {
        TerminateProcess(g_daemonPi.hProcess, 0);
        CloseHandle(g_daemonPi.hProcess);
        CloseHandle(g_daemonPi.hThread);
        g_daemonPi.hProcess = NULL;
        g_daemonPi.hThread = NULL;
        g_daemonRunning = FALSE;
    }
}

/**
 * 更新托盘悬浮提示文字
 */
void UpdateTrayTooltip(const wchar_t *statusText) {
    g_nid.uFlags = NIF_TIP | NIF_INFO;
    lstrcpynW(g_nid.szTip, statusText, sizeof(g_nid.szTip) / sizeof(wchar_t));
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}

/**
 * 弹出右键菜单
 */
void ShowContextMenu(HWND hwnd) {
    POINT pt;
    GetCursorPos(&pt);

    HMENU hMenu = CreatePopupMenu();
    if (!hMenu) return;

    // 1. 服务状态指示标题
    wchar_t statusBuf[128];
    if (g_daemonRunning) {
        wsprintfW(statusBuf, L"● PipeSync: 运行中 (端口 %d)", g_daemonPort);
    } else {
        wsprintfW(statusBuf, L"○ PipeSync: 已停止");
    }
    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_STRING | MF_DISABLED | MF_GRAYED, ID_TRAY_STATUS, statusBuf);
    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_SEPARATOR, 0, NULL);

    // 2. 打开控制台 (默认粗体项)
    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_STRING, ID_TRAY_CONSOLE, L"🌐 打开 Web 管理控制台");
    SetMenuDefaultItem(hMenu, ID_TRAY_CONSOLE, FALSE);

    // 3. 开机自启开关 (带勾选框)
    BOOL autostart = IsAutostartEnabled();
    UINT autostartFlags = MF_BYPOSITION | MF_STRING | (autostart ? MF_CHECKED : MF_UNCHECKED);
    InsertMenuW(hMenu, -1, autostartFlags, ID_TRAY_AUTOSTART, L"⚙ 开机自动启动");

    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_SEPARATOR, 0, NULL);

    // 4. 操作项
    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_STRING, ID_TRAY_SYNC_NOW, L"⟳ 立即同步全部文件夹");
    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_STRING, ID_TRAY_RESTART, L"🔄 重启后台服务");

    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_SEPARATOR, 0, NULL);

    // 5. 退出
    InsertMenuW(hMenu, -1, MF_BYPOSITION | MF_STRING, ID_TRAY_EXIT, L"✕ 退出 PipeSync");

    // 保证托盘右键菜单能正常关闭
    SetForegroundWindow(hwnd);
    TrackPopupMenu(hMenu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, NULL);
    PostMessageW(hwnd, WM_NULL, 0, 0);
    DestroyMenu(hMenu);
}

/**
 * 窗口消息处理函数
 */
LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE: {
            // 初始化系统托盘图标
            ZeroMemory(&g_nid, sizeof(g_nid));
            g_nid.cbSize = sizeof(NOTIFYICONDATAW);
            g_nid.hWnd = hwnd;
            g_nid.uID = 1;
            g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
            g_nid.uCallbackMessage = WM_TRAYICON;
            g_nid.hIcon = LoadIcon(NULL, IDI_APPLICATION);
            lstrcpyW(g_nid.szTip, L"PipeSync 数据管道: 正在初始化...");
            Shell_NotifyIconW(NIM_ADD, &g_nid);

            // 启动后台守护进程
            StartDaemonProcess();

            // 定时检测后台进程健康状态
            SetTimer(hwnd, ID_TIMER_POLL, 3000, NULL);
            return 0;
        }

        case WM_TIMER: {
            if (wParam == ID_TIMER_POLL) {
                if (g_daemonPi.hProcess != NULL) {
                    DWORD exitCode = 0;
                    if (GetExitCodeProcess(g_daemonPi.hProcess, &exitCode)) {
                        if (exitCode != STILL_ACTIVE) {
                            g_daemonRunning = FALSE;
                            UpdateTrayTooltip(L"PipeSync 数据管道: 服务异常退出，准备重启...");
                            StartDaemonProcess();
                        } else {
                            g_daemonRunning = TRUE;
                            wchar_t tip[128];
                            wsprintfW(tip, L"PipeSync 数据管道: 运行中 (端口 %d)\n双击打开 Web 控制台", g_daemonPort);
                            UpdateTrayTooltip(tip);
                        }
                    }
                }
            }
            return 0;
        }

        case WM_TRAYICON: {
            if (lParam == WM_RBUTTONUP) {
                ShowContextMenu(hwnd);
            } else if (lParam == WM_LBUTTONDBLCLK || lParam == WM_LBUTTONUP) {
                // 左键单击或双击均打开 Web 控制台
                ShellExecuteW(NULL, L"open", DEFAULT_CONSOLE_URL, NULL, NULL, SW_SHOWNORMAL);
            }
            return 0;
        }

        case WM_COMMAND: {
            switch (LOWORD(wParam)) {
                case ID_TRAY_CONSOLE: {
                    ShellExecuteW(NULL, L"open", DEFAULT_CONSOLE_URL, NULL, NULL, SW_SHOWNORMAL);
                    break;
                }
                case ID_TRAY_AUTOSTART: {
                    BOOL enabled = ToggleAutostart();
                    wchar_t msg[128];
                    wsprintfW(msg, L"PipeSync 开机自启动已%s！", enabled ? L"开启" : L"取消");
                    MessageBoxW(hwnd, msg, L"自启动设置", MB_OK | MB_ICONINFORMATION);
                    break;
                }
                case ID_TRAY_SYNC_NOW: {
                    // 打开控制台并提示
                    ShellExecuteW(NULL, L"open", DEFAULT_CONSOLE_URL, NULL, NULL, SW_SHOWNORMAL);
                    break;
                }
                case ID_TRAY_RESTART: {
                    StopDaemonProcess();
                    Sleep(500);
                    StartDaemonProcess();
                    MessageBoxW(hwnd, L"PipeSync 后台守护进程已重新拉起！", L"服务提示", MB_OK | MB_ICONINFORMATION);
                    break;
                }
                case ID_TRAY_EXIT: {
                    DestroyWindow(hwnd);
                    break;
                }
            }
            return 0;
        }

        case WM_DESTROY: {
            KillTimer(hwnd, ID_TIMER_POLL);
            StopDaemonProcess();
            Shell_NotifyIconW(NIM_DELETE, &g_nid);
            PostQuitMessage(0);
            return 0;
        }
    }
    return DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

/**
 * Windows WinMain 入口点
 */
int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, PWSTR pCmdLine, int nCmdShow) {
    (void)hPrevInstance;
    (void)pCmdLine;
    (void)nCmdShow;

    // 单实例互斥体 (防止重复启动托盘)
    HANDLE hMutex = CreateMutexW(NULL, TRUE, L"Global\\PipeSyncTrayApplicationMutex");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        // 已有实例在运行，直接唤起浏览器控制台
        ShellExecuteW(NULL, L"open", DEFAULT_CONSOLE_URL, NULL, NULL, SW_SHOWNORMAL);
        if (hMutex) CloseHandle(hMutex);
        return 0;
    }

    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = CLASS_NAME;
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);

    if (!RegisterClassExW(&wc)) {
        if (hMutex) CloseHandle(hMutex);
        return 1;
    }

    // 创建隐藏消息接收窗口
    HWND hwnd = CreateWindowExW(
        0,
        CLASS_NAME,
        L"PipeSync Tray Host",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        0, 0,
        NULL,
        NULL,
        hInstance,
        NULL
    );

    if (!hwnd) {
        if (hMutex) CloseHandle(hMutex);
        return 1;
    }

    // 主消息循环
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (hMutex) {
        ReleaseMutex(hMutex);
        CloseHandle(hMutex);
    }
    return (int)msg.wParam;
}
