/**
 * zjc_worker.exe - subprocess daemon (runs as Windows Service or standalone)
 *
 * Service mode (default):
 *   Installed as Windows Service "zjc_worker" (LocalSystem, AUTO_START).
 *   WinDivert driver loads without UAC since service runs with SYSTEM privileges.
 *   Phoenix.exe signals pause/resume via Global named event.
 *
 * Command-line:
 *   --install       Install and start the Windows service (requires Admin)
 *   --uninstall     Stop and remove the Windows service (requires Admin)
 *   --standalone    Force standalone mode (skip service dispatcher)
 *   --zjc-shaper <rules>   Embedded winshaper mode (internal use)
 *
 * Subscribes to:
 *   /topic/pc/{pcDeviceId}/burst   (single-device commands)
 *   /topic/burst/all               (broadcast commands)
 *   /topic/pc/{pcDeviceId}/shaper  (per-PC traffic shape)
 *   /topic/shaper/all              (broadcast traffic shape)
 *
 * Logs everything to zjc.txt (same directory as exe).
 * Pure Win32 + Winsock2 (downloads) + WinHTTP (login + WebSocket)
 */

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <iphlpapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "advapi32.lib")

/* ==========================================================
 * Version (显式版本号：Phoenix 据此判断是否需要从服务器重新下载安装)
 *   每次改动 zjc_worker 发布新包时递增；svcInstall 成功后写入
 *   %ProgramData%\zjc_worker\zjc_worker.version，Phoenix 读取比对。
 * ========================================================== */
#define ZJC_WORKER_VERSION "1.0.4"   /* §59 连续连不上5分钟自杀重生(SCM自动拉起) */

/* ==========================================================
 * Windows Service
 * ========================================================== */
static wchar_t ZJC_SERVICE_NAME[]  = L"zjc_worker";           // 内部服务名保持 ASCII（稳定，勿改中文）
static wchar_t ZJC_SERVICE_DISPLAY[] = L"\u91d1\u51e4\u51f0"; // 显示名「金凤凰」(services.msc 里显示；\u 转义避免源码编码坑)

/* ==========================================================
 * 互相监督（看门狗）—— 生生不息
 *   主进程(服务)与一个纯监督子进程「zjc_worker.exe --watchdog」互相拉起：
 *     · 主进程起一条 guard 线程，发现看门狗不在就重新拉起它；
 *     · 看门狗只做一件事——轮询 zjc_worker 服务，停了就 StartService。
 *   看门狗**不登录、不联网**，只调 SCM，无任何 HTTP/WebSocket/STOMP。
 *   两个命名内核对象跨会话可见（Global\）：
 *     · 存活互斥量：看门狗持有，主进程 OpenMutex 判其在不在；
 *     · 停止事件：仅卸载时置位，通知看门狗自行退出（否则会立刻把服务又拉起来）。
 * ========================================================== */
#define WD_ALIVE_MUTEX  L"Global\\zjc_worker_wd_alive"
#define WD_STOP_EVENT   L"Global\\zjc_worker_wd_stop"
#define WD_POLL_SEC     5

/* ⭐ §56.7（2026-08-06）日志前置声明：让 svcInstall/svcUninstall/看门狗也能写 zjc.txt。
 *   背景：客户反馈"子进程被杀"无从排查——安装/卸载过程只 wprintf 到隐藏窗口（一个字不落盘），
 *   服务日志要等 workerMain 跑起来才有。现在从安装那一刻起全链路落盘：
 *   安装→写版本文件→服务启动(带版本号)→收到停止控制→看门狗拉起，时间线完整。 */
static void logf(const char *fmt, ...);
static void initLogToProgramData(void);

/* 安装成功后把版本号写到 ProgramData（Phoenix 读它判断本地已装版本） */
static void writeVersionFile(void) {
    wchar_t path[MAX_PATH];
    ExpandEnvironmentStringsW(L"%ProgramData%\\zjc_worker\\zjc_worker.version", path, MAX_PATH);
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        const char *v = ZJC_WORKER_VERSION;
        DWORD written = 0;
        WriteFile(h, v, (DWORD)strlen(v), &written, NULL);
        CloseHandle(h);
        logf("[install] 版本文件已写入: %s", ZJC_WORKER_VERSION);
    } else {
        logf("[install] 版本文件写入失败 err=%lu", GetLastError());
    }
}

static SERVICE_STATUS_HANDLE g_svcHandle = NULL;
static SERVICE_STATUS        g_svcStatus;
static HANDLE                g_svcStopEvent = NULL;
static BOOL                  g_isService    = FALSE;

static void workerMain(void);

static void SvcReportStatus(DWORD state, DWORD exitCode, DWORD waitHint) {
    static DWORD checkPoint = 1;
    g_svcStatus.dwCurrentState  = state;
    g_svcStatus.dwWin32ExitCode = exitCode;
    g_svcStatus.dwWaitHint      = waitHint;
    g_svcStatus.dwControlsAccepted =
        (state == SERVICE_START_PENDING) ? 0 : SERVICE_ACCEPT_STOP;
    g_svcStatus.dwCheckPoint =
        (state == SERVICE_RUNNING || state == SERVICE_STOPPED) ? 0 : checkPoint++;
    SetServiceStatus(g_svcHandle, &g_svcStatus);
}

static void WINAPI SvcCtrlHandler(DWORD ctrl) {
    if (ctrl == SERVICE_CONTROL_STOP) {
        /* §56.7 记录"谁停了服务"的时间点：升级重装(sc stop)/总后台卸载/手动停止都会走这里；
         * 若日志里出现"started"却没有对应的这条 → 说明进程是被强杀的（taskkill/崩溃）。 */
        logf("[service] 收到 SCM 停止控制（正常停止：升级重装/卸载/手动 sc stop）");
        SvcReportStatus(SERVICE_STOP_PENDING, NO_ERROR, 5000);
        if (g_svcStopEvent) SetEvent(g_svcStopEvent);
    }
}

static void WINAPI SvcMain(DWORD argc, LPWSTR *argv) {
    (void)argc; (void)argv;
    g_svcHandle = RegisterServiceCtrlHandlerW(ZJC_SERVICE_NAME, SvcCtrlHandler);
    if (!g_svcHandle) return;

    ZeroMemory(&g_svcStatus, sizeof(g_svcStatus));
    g_svcStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;

    g_svcStopEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    SvcReportStatus(SERVICE_START_PENDING, NO_ERROR, 3000);
    SvcReportStatus(SERVICE_RUNNING, NO_ERROR, 0);

    workerMain();

    SvcReportStatus(SERVICE_STOPPED, NO_ERROR, 0);
}

/* Copy exe + WinDivert runtime to a service directory so the original is never locked. */
static BOOL copyToServiceDir(const wchar_t *srcExe, wchar_t *destExe, int destMax) {
    wchar_t svcDir[MAX_PATH];
    ExpandEnvironmentStringsW(L"%ProgramData%\\zjc_worker", svcDir, MAX_PATH);
    CreateDirectoryW(svcDir, NULL);

    /* Build dest exe path */
    wsprintfW(destExe, L"%s\\zjc_worker.exe", svcDir);

    /* Source directory (for WinDivert files) */
    wchar_t srcDir[MAX_PATH];
    lstrcpyW(srcDir, srcExe);
    wchar_t *sl = wcsrchr(srcDir, L'\\');
    if (sl) sl[1] = L'\0';

    /* Copy exe */
    CopyFileW(srcExe, destExe, FALSE);

    /* Copy WinDivert runtime files if present */
    wchar_t s[MAX_PATH], d[MAX_PATH];
    wsprintfW(s, L"%sWinDivert.dll", srcDir);
    wsprintfW(d, L"%s\\WinDivert.dll", svcDir);
    CopyFileW(s, d, FALSE);
    wsprintfW(s, L"%sWinDivert64.sys", srcDir);
    wsprintfW(d, L"%s\\WinDivert64.sys", svcDir);
    CopyFileW(s, d, FALSE);

    return TRUE;
}

static BOOL svcInstall(void) {
    wchar_t srcExe[MAX_PATH];
    GetModuleFileNameW(NULL, srcExe, MAX_PATH);

    /* §56.7 安装过程全程落盘（此前只 wprintf 到隐藏窗口，安装环节完全无日志可查） */
    logf("[install] ===== 开始安装 zjc_worker %s =====", ZJC_WORKER_VERSION);

    /* Copy to ProgramData so the release directory is never locked */
    wchar_t exePath[MAX_PATH];
    if (!copyToServiceDir(srcExe, exePath, MAX_PATH)) {
        wprintf(L"Failed to copy to service directory.\n");
        logf("[install] 复制到服务目录失败 err=%lu", GetLastError());
        return FALSE;
    }

    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) {
        wprintf(L"OpenSCManager failed (%lu). Run as Administrator.\n", GetLastError());
        logf("[install] OpenSCManager 失败 err=%lu（非管理员？）", GetLastError());
        return FALSE;
    }

    /* Stop old service first (so the old copy is unlocked) */
    SC_HANDLE existSvc = OpenServiceW(scm, ZJC_SERVICE_NAME, SERVICE_STOP | SERVICE_QUERY_STATUS);
    if (existSvc) {
        SERVICE_STATUS ss;
        logf("[install] 检测到旧服务 → 发送停止命令（升级重装的正常流程）");
        ControlService(existSvc, SERVICE_CONTROL_STOP, &ss);
        for (int i = 0; i < 25; i++) {
            QueryServiceStatus(existSvc, &ss);
            if (ss.dwCurrentState == SERVICE_STOPPED) break;
            Sleep(200);
        }
        logf("[install] 旧服务当前状态=%lu (1=已停止)", ss.dwCurrentState);
        CloseServiceHandle(existSvc);
        Sleep(500);
        /* Re-copy after old service stopped (in case old was locking ProgramData copy) */
        copyToServiceDir(srcExe, exePath, MAX_PATH);
    }

    SC_HANDLE svc = CreateServiceW(scm, ZJC_SERVICE_NAME, ZJC_SERVICE_DISPLAY,
        SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
        SERVICE_ERROR_NORMAL, exePath, NULL, NULL, NULL, NULL, NULL);

    if (!svc) {
        DWORD err = GetLastError();
        if (err == ERROR_SERVICE_EXISTS) {
            wprintf(L"Service already exists, updating path...\n");
            logf("[install] 服务已存在 → 更新服务路径配置");
            svc = OpenServiceW(scm, ZJC_SERVICE_NAME, SERVICE_ALL_ACCESS);
            if (svc) {
                ChangeServiceConfigW(svc, SERVICE_NO_CHANGE, SERVICE_AUTO_START,
                    SERVICE_NO_CHANGE, exePath, NULL, NULL, NULL, NULL, NULL, NULL);
            }
        } else {
            wprintf(L"CreateService failed (%lu).\n", err);
            logf("[install] CreateService 失败 err=%lu → 安装中止", err);
            CloseServiceHandle(scm);
            return FALSE;
        }
    } else {
        logf("[install] 服务注册成功（新建）");
    }

    if (svc) {
        static wchar_t svcDesc[] = L"ZJC background worker: bandwidth burst + traffic shaping (WinDivert)";
        SERVICE_DESCRIPTIONW sd;
        sd.lpDescription = svcDesc;
        ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, &sd);

        SC_ACTION actions[3] = {
            { SC_ACTION_RESTART,  5000 },
            { SC_ACTION_RESTART, 10000 },
            { SC_ACTION_RESTART, 30000 },
        };
        SERVICE_FAILURE_ACTIONSW sfa;
        ZeroMemory(&sfa, sizeof(sfa));
        sfa.dwResetPeriod = 86400;
        sfa.cActions      = 3;
        sfa.lpsaActions   = actions;
        ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS, &sfa);

        SERVICE_FAILURE_ACTIONS_FLAG flag = { TRUE };
        ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS_FLAG, &flag);

        if (StartServiceW(svc, 0, NULL)) {
            logf("[install] StartService 成功（故障自动重启策略已配置：5s/10s/30s）");
        } else {
            logf("[install] StartService 返回失败 err=%lu (1056=已在运行，属正常)", GetLastError());
        }
        wprintf(L"Service installed and started.\n");
        CloseServiceHandle(svc);
    }
    CloseServiceHandle(scm);

    /* 写版本文件，供 Phoenix 比对（分离后 Phoenix 不再带 exe，靠此判断是否重下） */
    writeVersionFile();

    /* Remove old HKCU Run entry (service replaces it) */
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
        RegDeleteValueW(hKey, L"zjc_worker");
        RegCloseKey(hKey);
    }

    logf("[install] ===== 安装完成 %s =====", ZJC_WORKER_VERSION);
    return TRUE;
}

static BOOL svcUninstall(void) {
    logf("[uninstall] ===== 开始卸载 zjc_worker（总后台标记卸载 / 手动卸载）=====");
    /* ⭐ 先叫停看门狗：否则它会在「停服务→删服务」的窗口里立刻把服务又拉起来，
     *   导致卸载看似成功却马上复活。手动置位的停止事件在本进程退出前一直有效。 */
    HANDLE wdStop = CreateEventW(NULL, TRUE, TRUE, WD_STOP_EVENT);  /* 初始即置位 */
    Sleep(300);   /* 给看门狗一个轮询周期外的窗口感知退出 */

    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) {
        wprintf(L"OpenSCManager failed (%lu). Run as Administrator.\n", GetLastError());
        if (wdStop) CloseHandle(wdStop);
        return FALSE;
    }

    SC_HANDLE svc = OpenServiceW(scm, ZJC_SERVICE_NAME, SERVICE_ALL_ACCESS);
    if (!svc) {
        wprintf(L"Service not found.\n");
        CloseServiceHandle(scm);
        if (wdStop) CloseHandle(wdStop);
        return FALSE;
    }

    SERVICE_STATUS ss;
    ControlService(svc, SERVICE_CONTROL_STOP, &ss);
    Sleep(2000);

    if (DeleteService(svc)) {
        wprintf(L"Service uninstalled.\n");
        logf("[uninstall] 服务已删除，卸载完成");
    } else {
        wprintf(L"DeleteService failed (%lu).\n", GetLastError());
        logf("[uninstall] DeleteService 失败 err=%lu", GetLastError());
    }

    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    if (wdStop) CloseHandle(wdStop);   /* 释放停止事件；服务已删，看门狗即使残留也无服务可拉 */
    return TRUE;
}

#include <shellapi.h>
#pragma comment(lib, "Shell32.lib")

#ifndef ZJC_EMBED_WINSHAPER
#define ZJC_EMBED_WINSHAPER 0
#endif
#if ZJC_EMBED_WINSHAPER
extern "C" int winshaper_main(int argc, char **argv);
#endif

/* ==========================================================
 * Configuration
 * ========================================================== */
#define THREAD_COUNT        256
#define DEFAULT_BURST_SEC   5
#define RECV_BUF_SIZE       (1024 * 1024)   /* 1 MB per recv() call */
#define HEARTBEAT_SEC       10
#define STATUS_SEC          60
#define RECONNECT_SEC       5
#define AUTH_RETRY_SEC      10

static const wchar_t *API_HOST = L"api.147258yql.cn";
static const wchar_t *WS_HOST  = L"ws.147258yql.cn";

/* ==========================================================
 * Download targets (bandwidth burst)
 * ========================================================== */
typedef struct { const char *host; const char *request; } DlTarget;

static DlTarget TARGETS[] = {
    /* === Chinese CDN (proven fast for CN users, priority) === */
    { "dldir1.qq.com",
      "GET /qqfile/qq/QQNT/Windows/QQ_9.9.15_240902_x64_01.exe HTTP/1.1\r\n"
      "Host: dldir1.qq.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "dldir1v6.qq.com",
      "GET /weixin/Windows/WeChatSetup.exe HTTP/1.1\r\n"
      "Host: dldir1v6.qq.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "issuecdn.baidupcs.com",
      "GET /issue/netdisk/yunguanjia/BaiduNetdisk_7.28.0.5.exe HTTP/1.1\r\n"
      "Host: issuecdn.baidupcs.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "down.360safe.com",
      "GET /setup.exe HTTP/1.1\r\n"
      "Host: down.360safe.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    /* === Global speed-test servers (unlimited, no per-IP throttle) === */
    { "speed.hetzner.de",
      "GET /10GB.bin HTTP/1.1\r\n"
      "Host: speed.hetzner.de\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "proof.ovh.net",
      "GET /files/100Mb.dat HTTP/1.1\r\n"
      "Host: proof.ovh.net\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "speedtest.tele2.net",
      "GET /10GB.zip HTTP/1.1\r\n"
      "Host: speedtest.tele2.net\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "cachefly.cachefly.net",
      "GET /100mb.test HTTP/1.1\r\n"
      "Host: cachefly.cachefly.net\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "ash-speed.hetzner.com",
      "GET /10GB.bin HTTP/1.1\r\n"
      "Host: ash-speed.hetzner.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "fsn1-speed.hetzner.com",
      "GET /10GB.bin HTTP/1.1\r\n"
      "Host: fsn1-speed.hetzner.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "nbg1-speed.hetzner.com",
      "GET /10GB.bin HTTP/1.1\r\n"
      "Host: nbg1-speed.hetzner.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
    { "sgp1-speed.hetzner.com",
      "GET /10GB.bin HTTP/1.1\r\n"
      "Host: sgp1-speed.hetzner.com\r\nConnection: keep-alive\r\nUser-Agent: Mozilla/5.0\r\n\r\n" },
};
#define TARGET_COUNT    12
#define CN_TARGET_COUNT 4

/* ==========================================================
 * Auth info
 * ========================================================== */
typedef struct {
    char username[256];
    char password[256];
    char pcDeviceId[128];
    int  pcLevel;
    char token[2048];
} AuthInfo;

static AuthInfo g_auth;

/* ----- Anti-infinite-register protection ----------------------------------
 * 限制单个进程生命周期内最多 register 的次数，防止任何路径上的逻辑漏洞或
 * 服务自动重启循环导致对后端 register API 的高频调用。
 * 一旦达到上限就只能依靠现有 zjc_auth.json 登录，不再向服务器发起 register。
 * ------------------------------------------------------------------------ */
#define MAX_REGISTER_ATTEMPTS  3
static int g_registerAttempts = 0;

/* ==========================================================
 * Burst global state
 * ========================================================== */
static volatile LONG     g_burst      = 0;
static volatile LONGLONG g_burstBytes = 0;
static volatile LONG     g_readyCount = 0;
static volatile LONG     g_activeCount = 0;
static HANDLE            g_startEvent = NULL;

/* ==========================================================
 * WebSocket connection
 * ========================================================== */
typedef struct {
    HINTERNET session;
    HINTERNET connect;
    HINTERNET websocket;
} WsConn;

static WsConn            g_ws;
static volatile BOOL     g_wsAlive = FALSE;
static CRITICAL_SECTION  g_sendLock;

/* Named event: main process signals this to request graceful shutdown.
 * Global\ namespace so it works across sessions (service=session0, user=session1+). */
#define STOP_EVENT_NAME  L"Global\\zjc_worker_stop"
static HANDLE g_stopEvent = NULL;

static BOOL shouldStop(void) {
    if (g_svcStopEvent && WaitForSingleObject(g_svcStopEvent, 0) == WAIT_OBJECT_0)
        return TRUE;
    if (g_stopEvent && WaitForSingleObject(g_stopEvent, 0) == WAIT_OBJECT_0)
        return TRUE;
    return FALSE;
}

/* ==========================================================
 * Last burst result (for status reports)
 * ========================================================== */
static double g_lastMbps = 0;
static char   g_lastBurstTime[64] = "";

/* ==========================================================
 * Process-name whitelist from login response
 *   Burst only runs when at least one of these processes is
 *   found in the system snapshot. Empty list = always burst.
 * ========================================================== */
#define MAX_PROC_NAMES     64
#define MAX_PROC_NAME_LEN  128
static char g_processNames[MAX_PROC_NAMES][MAX_PROC_NAME_LEN];
static int  g_processNameCount = 0;

/* ==========================================================
 * WinDivert child: winshaper.exe (same directory as zjc_worker)
 * Backend STOMP body: action TRAFFIC_SHAPE / TRAFFIC_SHAPE_STOP
 * ========================================================== */
static CRITICAL_SECTION g_shaperCs;
static HANDLE           g_shaperProc = NULL;
static DWORD            g_shaperPid  = 0;

/* ==========================================================
 * Paths
 * ========================================================== */
static wchar_t g_exeDir[MAX_PATH];
static wchar_t g_logPath[MAX_PATH];

/* ==========================================================
 * Logging
 * ========================================================== */

/* ⭐ 2026-08-02 日志清理：zjc.txt 超 10MB 就轮转成 zjc.old.txt（只保留一份旧的），
 * 磁盘占用封顶 ~20MB。此前无任何清理机制，服务常年跑文件无限膨胀。
 * 每次写前查一次文件大小（元数据查询，开销可忽略；日志本身低频）。 */
#define ZJC_LOG_MAX_BYTES (10 * 1024 * 1024)

static void logRotateIfNeeded(void) {
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(g_logPath, GetFileExInfoStandard, &fad)) return;
    ULARGE_INTEGER sz;
    sz.LowPart  = fad.nFileSizeLow;
    sz.HighPart = fad.nFileSizeHigh;
    if (sz.QuadPart < (ULONGLONG)ZJC_LOG_MAX_BYTES) return;
    wchar_t oldPath[MAX_PATH];
    lstrcpyW(oldPath, g_exeDir);
    lstrcatW(oldPath, L"zjc.old.txt");
    DeleteFileW(oldPath);
    MoveFileExW(g_logPath, oldPath, MOVEFILE_REPLACE_EXISTING);
}

static void logRaw(const char *msg) {
    if (g_logPath[0] == L'\0') return;   /* §56.7 日志路径未初始化时静默跳过（防呆） */
    logRotateIfNeeded();
    HANDLE hf = CreateFileW(g_logPath, FILE_APPEND_DATA, FILE_SHARE_READ,
        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hf != INVALID_HANDLE_VALUE) {
        DWORD w;
        WriteFile(hf, msg, (DWORD)lstrlenA(msg), &w, NULL);
        CloseHandle(hf);
    }
}

/* ⭐ §56.7 安装器/卸载/看门狗场景：exe 可能跑在 dl\ 下载目录，日志统一写到
 *   %ProgramData%\zjc_worker\zjc.txt（与服务日志同一个文件，时间线连续）。 */
static void initLogToProgramData(void) {
    wchar_t dir[MAX_PATH];
    ExpandEnvironmentStringsW(L"%ProgramData%\\zjc_worker", dir, MAX_PATH);
    CreateDirectoryW(dir, NULL);
    lstrcpyW(g_exeDir, dir);
    lstrcatW(g_exeDir, L"\\");
    lstrcpyW(g_logPath, g_exeDir);
    lstrcatW(g_logPath, L"zjc.txt");
}

static void logf(const char *fmt, ...) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    char ts[64];
    wsprintfA(ts, "[%04d-%02d-%02d %02d:%02d:%02d] ",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);

    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    wvsprintfA(msg, fmt, ap);
    va_end(ap);

    char line[1200];
    wsprintfA(line, "%s%s\r\n", ts, msg);
    logRaw(line);
}

/* ==========================================================
 * Minimal JSON helpers (flat objects only)
 * ========================================================== */
static BOOL jStr(const char *j, const char *key, char *out, int max) {
    /* Find "key" in the JSON string */
    char pat[256];
    wsprintfA(pat, "\"%s\"", key);
    const char *p = strstr(j, pat);
    if (!p) return FALSE;
    p += lstrlenA(pat);
    /* skip optional whitespace, colon, whitespace */
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != ':') return FALSE;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != '"') return FALSE;
    p++;  /* skip opening quote */
    int i = 0;
    while (*p && *p != '"' && i < max - 1) {
        if (*p == '\\' && *(p + 1)) p++;   /* skip escaped char */
        out[i++] = *p++;
    }
    out[i] = '\0';
    return (i > 0);
}

static BOOL jInt(const char *j, const char *key, int *out) {
    /* Find "key" in the JSON string */
    char pat[256];
    wsprintfA(pat, "\"%s\"", key);
    const char *p = strstr(j, pat);
    if (!p) return FALSE;
    p += lstrlenA(pat);
    /* skip optional whitespace, colon, whitespace */
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != ':') return FALSE;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    int neg = 0, val = 0;
    if (*p == '-') { neg = 1; p++; }
    while (*p >= '0' && *p <= '9') { val = val * 10 + (*p - '0'); p++; }
    *out = neg ? -val : val;
    return TRUE;
}

static BOOL jInt64(const char *j, const char *key, long long *out) {
    char pat[256];
    wsprintfA(pat, "\"%s\"", key);
    const char *p = strstr(j, pat);
    if (!p) return FALSE;
    p += lstrlenA(pat);
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != ':') return FALSE;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    int neg = 0;
    long long v = 0;
    if (*p == '-') { neg = 1; p++; }
    while (*p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); p++; }
    *out = neg ? -v : v;
    return TRUE;
}

/* ==========================================================
 * Parse a JSON string-array field into a char[][].
 *   e.g.  "processNames" : ["chrome.exe", "notepad.exe"]
 * Returns how many items were parsed (0 if key missing or empty).
 * ========================================================== */
static int jStrArray(const char *j, const char *key,
                     char arr[][MAX_PROC_NAME_LEN], int maxItems)
{
    char pat[256];
    wsprintfA(pat, "\"%s\"", key);
    const char *p = strstr(j, pat);
    if (!p) return 0;
    p += lstrlenA(pat);
    /* skip whitespace + colon + whitespace */
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != ':') return 0;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != '[') return 0;
    p++; /* skip '[' */

    int count = 0;
    while (*p && *p != ']' && count < maxItems) {
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n' || *p == ',') p++;
        if (*p == ']') break;
        if (*p != '"') break;
        p++; /* skip opening quote */
        int i = 0;
        while (*p && *p != '"' && i < MAX_PROC_NAME_LEN - 1) {
            if (*p == '\\' && *(p + 1)) p++;
            arr[count][i++] = *p++;
        }
        arr[count][i] = '\0';
        if (*p == '"') p++; /* skip closing quote */
        count++;
    }
    return count;
}

/* ==========================================================
 * Case-insensitive process name match — Unicode 安全版
 *   旧版用 lstrcmpiA, 在 GBK Windows 下会把 UTF-8 字节解释为 GBK
 *   字符做大小写折叠，导致中文进程名（棱镜OS / 金麒麟 / 火眼金睛 等）
 *   匹配失败。
 *   现版本: 把 UTF-8 转 UTF-16, 用 CompareStringW(LOCALE_INVARIANT,
 *   NORM_IGNORECASE) 做真正的 Unicode 比较。
 *
 *   规则不变: 精确 / entry 不带 .exe 时补 .exe 比较 / sysName 去掉
 *   .exe 与 entry 比较。
 * ========================================================== */
static BOOL streqIW(const wchar_t *a, int aLen, const wchar_t *b, int bLen) {
    return CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE,
                          a, aLen, b, bLen) == CSTR_EQUAL;
}

static BOOL procNameMatchW(const wchar_t *wSys, const wchar_t *wEntry) {
    int sLen = lstrlenW(wSys);
    int eLen = lstrlenW(wEntry);

    /* 1. 精确匹配 (Unicode case-insensitive) */
    if (streqIW(wSys, sLen, wEntry, eLen)) return TRUE;

    /* 2. entry 不带 .exe -> 补上 .exe 再和 sysName 比 */
    BOOL entryHasExe = (eLen >= 4 && streqIW(wEntry + eLen - 4, 4, L".exe", 4));
    if (!entryHasExe) {
        wchar_t withExe[MAX_PROC_NAME_LEN + 8];
        lstrcpynW(withExe, wEntry, MAX_PROC_NAME_LEN);
        lstrcatW(withExe, L".exe");
        if (streqIW(wSys, sLen, withExe, lstrlenW(withExe))) return TRUE;
    }

    /* 3. 去掉 sysName 的 .exe 后缀再和 entry 比 */
    if (sLen > 4 && streqIW(wSys + sLen - 4, 4, L".exe", 4)) {
        wchar_t stripped[MAX_PATH];
        int copyLen = sLen - 4;
        if (copyLen >= MAX_PATH) copyLen = MAX_PATH - 1;
        for (int i = 0; i < copyLen; i++) stripped[i] = wSys[i];
        stripped[copyLen] = L'\0';
        if (streqIW(stripped, copyLen, wEntry, eLen)) return TRUE;
    }

    return FALSE;
}

static BOOL procNameMatch(const char *sysName, const char *entry) {
    /* UTF-8 -> UTF-16 转换后做 Unicode 比较 */
    wchar_t wSys[MAX_PATH];
    wchar_t wEntry[MAX_PROC_NAME_LEN + 8];
    if (MultiByteToWideChar(CP_UTF8, 0, sysName, -1, wSys, MAX_PATH) <= 0) {
        /* 兜底: UTF-8 解析失败时，按 GBK (CP_ACP) 再试一次 */
        if (MultiByteToWideChar(CP_ACP, 0, sysName, -1, wSys, MAX_PATH) <= 0)
            return FALSE;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, entry, -1, wEntry, MAX_PROC_NAME_LEN + 8) <= 0) {
        if (MultiByteToWideChar(CP_ACP, 0, entry, -1, wEntry, MAX_PROC_NAME_LEN + 8) <= 0)
            return FALSE;
    }
    return procNameMatchW(wSys, wEntry);
}

/* ==========================================================
 * Check if any process in g_processNames is running
 *   Uses CreateToolhelp32Snapshot (same as killSubprocess).
 *   Returns TRUE if list is empty (no restriction) or at
 *   least one matching process is found.
 * ========================================================== */
static BOOL checkRequiredProcess(char *matchedName, int matchedMax) {
    matchedName[0] = '\0';
    if (g_processNameCount == 0) return TRUE;   /* no restriction */

    HANDLE hSnap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnap == INVALID_HANDLE_VALUE) return FALSE;

    PROCESSENTRY32W pe;
    pe.dwSize = sizeof(pe);
    BOOL found = FALSE;

    if (Process32FirstW(hSnap, &pe)) {
        do {
            char name[MAX_PATH];
            WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1,
                                name, sizeof(name), NULL, NULL);
            for (int i = 0; i < g_processNameCount; i++) {
                if (procNameMatch(name, g_processNames[i])) {
                    lstrcpynA(matchedName, name, matchedMax);
                    found = TRUE;
                    break;
                }
            }
            if (found) break;
        } while (Process32NextW(hSnap, &pe));
    }

    CloseHandle(hSnap);
    return found;
}

/* ==========================================================
 * True if a single process name (same rules as procNameMatch) is running.
 * ========================================================== */
static BOOL processNamedRunning(const char *want, char *matchedName, int matchedMax) {
    matchedName[0] = '\0';
    if (!want || !want[0]) return FALSE;

    HANDLE hSnap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnap == INVALID_HANDLE_VALUE) return FALSE;

    PROCESSENTRY32W pe;
    pe.dwSize = sizeof(pe);
    BOOL found = FALSE;

    if (Process32FirstW(hSnap, &pe)) {
        do {
            char name[MAX_PATH];
            WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1,
                                name, sizeof(name), NULL, NULL);
            if (procNameMatch(name, want)) {
                lstrcpynA(matchedName, name, matchedMax);
                found = TRUE;
                break;
            }
        } while (Process32NextW(hSnap, &pe));
    }

    CloseHandle(hSnap);
    return found;
}

typedef struct {
    int   sec;
    DWORD pid;
} ShaperWait;

static DWORD WINAPI shaper_auto_stop_thread(LPVOID param) {
    ShaperWait *w = (ShaperWait *)param;
    if (!w || w->sec <= 0) {
        if (w) free(w);
        return 0;
    }
    Sleep((DWORD)w->sec * 1000);
    EnterCriticalSection(&g_shaperCs);
    if (g_shaperProc && g_shaperPid == w->pid) {
        TerminateProcess(g_shaperProc, 0);
        CloseHandle(g_shaperProc);
        g_shaperProc = NULL;
        g_shaperPid = 0;
        // ⭐ 隐藏敏感信息：不记录自动停止时长
        logf("TRAFFIC_SHAPE: auto-stopped");
    }
    LeaveCriticalSection(&g_shaperCs);
    free(w);
    return 0;
}

static void shaper_stop(void) {
    EnterCriticalSection(&g_shaperCs);
    if (g_shaperProc) {
        TerminateProcess(g_shaperProc, 0);
        CloseHandle(g_shaperProc);
        g_shaperProc = NULL;
        g_shaperPid = 0;
    }
    LeaveCriticalSection(&g_shaperCs);
}

/* Write zjc_shaper.rules and start winshaper.exe; requires Administrator for WinDivert. */
static BOOL shaper_start_child(const char *exeRuleName, long long upBps, long long downBps,
                               int durationSec) {
    wchar_t rulesPath[MAX_PATH];
    lstrcpyW(rulesPath, g_exeDir);
    lstrcatW(rulesPath, L"zjc_shaper.rules");

    char line[384];
    /* winshaper rules: basename upload_Bps download_Bps */
    sprintf_s(line, sizeof(line), "%s %I64d %I64d\r\n",
        exeRuleName, upBps, downBps);

    HANDLE hf = CreateFileW(rulesPath, GENERIC_WRITE, 0, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hf == INVALID_HANDLE_VALUE) {
        logf("shaper: cannot write rules (%lu)", GetLastError());
        return FALSE;
    }
    DWORD wr = 0;
    WriteFile(hf, line, (DWORD)lstrlenA(line), &wr, NULL);
    CloseHandle(hf);

    wchar_t cmdline[1024];
#if ZJC_EMBED_WINSHAPER
    {
        wchar_t selfExe[MAX_PATH];
        GetModuleFileNameW(NULL, selfExe, MAX_PATH);
        wsprintfW(cmdline, L"\"%s\" --zjc-shaper \"%s\"", selfExe, rulesPath);
    }
#else
    {
        wchar_t wsExe[MAX_PATH];
        lstrcpyW(wsExe, g_exeDir);
        lstrcatW(wsExe, L"winshaper.exe");
        wsprintfW(cmdline, L"\"%s\" \"%s\"", wsExe, rulesPath);
    }
#endif

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    EnterCriticalSection(&g_shaperCs);
    if (g_shaperProc) {
        TerminateProcess(g_shaperProc, 0);
        CloseHandle(g_shaperProc);
        g_shaperProc = NULL;
        g_shaperPid = 0;
    }

    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE,
            CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
            NULL, g_exeDir, &si, &pi)) {
        LeaveCriticalSection(&g_shaperCs);
        logf("shaper: CreateProcess shaper child failed (%lu) — need Admin + WinDivert?",
            GetLastError());
        return FALSE;
    }
    CloseHandle(pi.hThread);
    g_shaperProc = pi.hProcess;
    g_shaperPid = pi.dwProcessId;
    {
        DWORD newPid = g_shaperPid;
        LeaveCriticalSection(&g_shaperCs);
        {
            char lm[256];
            sprintf_s(lm, sizeof(lm), "shaper: started pid=%lu up=%I64d down=%I64d",
                newPid, upBps, downBps);
            logf("%s", lm);
        }
        if (durationSec > 0) {
            ShaperWait *w = (ShaperWait *)malloc(sizeof(ShaperWait));
            if (w) {
                w->sec = durationSec;
                w->pid = newPid;
                CloseHandle(CreateThread(NULL, 0, shaper_auto_stop_thread, w, 0, NULL));
            }
        }
        return TRUE;
    }
}

/*
 * 支持逗号分隔的多进程名，写入多行 rules，一次启动 winshaper。
 * 例如 "chrome,firefox" → rules 文件两行，winshaper 同时对两个进程限速。
 * 如果只有一个进程名（无逗号），等同于 shaper_start_child。
 *
 * reasonOut: 失败原因（可选）
 *   "no_running_process" — 列表中没有任何进程在运行
 *   "rules_write_fail"   — 无法写入 rules 文件
 *   "createprocess_fail" — winshaper.exe 启动失败（缺 Admin 权限或文件缺失）
 *   ""                   — 成功
 */
static BOOL shaper_start_child_multi(const char *processNameList, long long upBps,
                                     long long downBps, int durationSec,
                                     char *reasonOut, int reasonMax) {
    if (reasonOut && reasonMax > 0) reasonOut[0] = '\0';
    wchar_t rulesPath[MAX_PATH];
    lstrcpyW(rulesPath, g_exeDir);
    lstrcatW(rulesPath, L"zjc_shaper.rules");

    /* 拆分逗号分隔的进程名，写多行 rules */
    char buf[1024];
    int bufLen = 0;
    int ruleCount = 0;

    char nameCopy[MAX_PROC_NAME_LEN * 4];
    lstrcpynA(nameCopy, processNameList, sizeof(nameCopy));

    char *ctx = NULL;
    char *tok = strtok_s(nameCopy, ",;", &ctx);
    while (tok && ruleCount < 8) {
        while (*tok == ' ') tok++;
        char *end = tok + lstrlenA(tok) - 1;
        while (end > tok && *end == ' ') { *end = '\0'; end--; }

        if (*tok == '\0') { tok = strtok_s(NULL, ",;", &ctx); continue; }

        char matched[MAX_PATH] = "";
        if (!processNamedRunning(tok, matched, sizeof(matched))) {
            // ⭐ 不打印目标软件名（敏感）：只记一条跳过计数
            logf("shaper_multi: one target not running, skip");
            tok = strtok_s(NULL, ",;", &ctx);
            continue;
        }

        int wrote = sprintf_s(buf + bufLen, sizeof(buf) - bufLen,
                              "%s %I64d %I64d\r\n", tok, upBps, downBps);
        if (wrote > 0) bufLen += wrote;
        ruleCount++;
        tok = strtok_s(NULL, ",;", &ctx);
    }

    if (ruleCount == 0) {
        // ⭐ 不打印目标软件名列表（敏感）
        logf("shaper_multi: no matching processes");
        if (reasonOut && reasonMax > 0)
            lstrcpynA(reasonOut, "no_running_process", reasonMax);
        return FALSE;
    }

    HANDLE hf = CreateFileW(rulesPath, GENERIC_WRITE, 0, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hf == INVALID_HANDLE_VALUE) {
        logf("shaper_multi: cannot write rules (%lu)", GetLastError());
        if (reasonOut && reasonMax > 0)
            lstrcpynA(reasonOut, "rules_write_fail", reasonMax);
        return FALSE;
    }
    DWORD wr = 0;
    WriteFile(hf, buf, (DWORD)bufLen, &wr, NULL);
    CloseHandle(hf);

    logf("shaper_multi: rules applied");

    wchar_t cmdline[1024];
#if ZJC_EMBED_WINSHAPER
    {
        wchar_t selfExe[MAX_PATH];
        GetModuleFileNameW(NULL, selfExe, MAX_PATH);
        wsprintfW(cmdline, L"\"%s\" --zjc-shaper \"%s\"", selfExe, rulesPath);
    }
#else
    {
        wchar_t wsExe[MAX_PATH];
        lstrcpyW(wsExe, g_exeDir);
        lstrcatW(wsExe, L"winshaper.exe");
        wsprintfW(cmdline, L"\"%s\" \"%s\"", wsExe, rulesPath);
    }
#endif

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    EnterCriticalSection(&g_shaperCs);
    if (g_shaperProc) {
        TerminateProcess(g_shaperProc, 0);
        CloseHandle(g_shaperProc);
        g_shaperProc = NULL;
        g_shaperPid = 0;
    }

    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE,
                        CREATE_NO_WINDOW, NULL, g_exeDir, &si, &pi)) {
        logf("shaper_multi: CreateProcess failed (%lu)", GetLastError());
        LeaveCriticalSection(&g_shaperCs);
        if (reasonOut && reasonMax > 0)
            lstrcpynA(reasonOut, "createprocess_fail", reasonMax);
        return FALSE;
    }

    CloseHandle(pi.hThread);
    g_shaperProc = pi.hProcess;
    g_shaperPid = pi.dwProcessId;
    DWORD newPid = pi.dwProcessId;
    LeaveCriticalSection(&g_shaperCs);

    // ⭐ 隐藏敏感信息：不记录进程数量和限流参数
    logf("shaper_multi: started pid=%lu", newPid);

    if (durationSec > 0) {
        ShaperWait *w = (ShaperWait *)malloc(sizeof(ShaperWait));
        if (w) {
            w->sec = durationSec;
            w->pid = newPid;
            CloseHandle(CreateThread(NULL, 0, shaper_auto_stop_thread, w, 0, NULL));
        }
    }
    return TRUE;
}

static BOOL stompSendJson(const char *dest, const char *json);

/*
 * 枚举存活进程，找出全部匹配 g_processNames 中条目的实际进程名（去重）。
 * out 参数填入逗号分隔的进程名列表（最多 maxNames 项），返回命中数量。
 * 例如 g_processNames=[chrome, firefox]，运行中: out="chrome.exe, firefox.exe"
 */
static int enumLiveMatchedProcesses(char *outCsv, int outMax) {
    if (outMax > 0) outCsv[0] = '\0';
    if (g_processNameCount == 0) return 0;

    char foundNames[MAX_PROC_NAMES][MAX_PROC_NAME_LEN];
    int foundCount = 0;

    HANDLE hSnap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnap == INVALID_HANDLE_VALUE) return 0;

    PROCESSENTRY32W pe;
    pe.dwSize = sizeof(pe);

    if (Process32FirstW(hSnap, &pe)) {
        do {
            char name[MAX_PATH];
            WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1,
                                name, sizeof(name), NULL, NULL);
            for (int i = 0; i < g_processNameCount; i++) {
                if (procNameMatch(name, g_processNames[i])) {
                    /* 去重：进程名已记录则不重复添加 (两侧都是同源 UTF-8，字节比即可) */
                    BOOL dup = FALSE;
                    for (int k = 0; k < foundCount; k++) {
                        if (lstrlenA(foundNames[k]) == lstrlenA(name)
                            && memcmp(foundNames[k], name, lstrlenA(name)) == 0) {
                            dup = TRUE; break;
                        }
                    }
                    if (!dup && foundCount < MAX_PROC_NAMES) {
                        lstrcpynA(foundNames[foundCount], name, MAX_PROC_NAME_LEN);
                        foundCount++;
                    }
                    break;
                }
            }
        } while (Process32NextW(hSnap, &pe));
    }
    CloseHandle(hSnap);

    /* 拼接为 CSV */
    int pos = 0;
    for (int i = 0; i < foundCount && pos < outMax - 1; i++) {
        const char *sep = (i == 0) ? "" : ", ";
        int wrote = wsprintfA(outCsv + pos, "%s%s", sep, foundNames[i]);
        if (wrote <= 0) break;
        pos += wrote;
    }
    return foundCount;
}

/*
 * 上报存活进程列表到 /app/subprocess/live-processes
 *   - 命中 ≥1 个: liveProcesses = ["chrome.exe","firefox.exe"]
 *   - 0 命中:    liveProcesses = "无"
 *
 * stompSendJson 内部有 2048 字节帧缓冲，所以 body 控制在 1500 以内最安全。
 */
static void sendLiveProcesses(void) {
    if (!g_wsAlive) return;

    char csv[1400] = "";
    int n = enumLiveMatchedProcesses(csv, sizeof(csv));
    long ts = (long)time(NULL);

    char body[1700];
    if (n == 0) {
        wsprintfA(body,
            "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
            "\"liveProcesses\":\"\xe6\x97\xa0\","   /* "无" UTF-8 */
            "\"timestamp\":%ld}",
            g_auth.pcDeviceId, g_auth.username, ts);
    } else {
        /* 拼装 JSON 数组 */
        char arr[1500];
        int pos = 0;
        arr[pos++] = '[';
        char namesCopy[1400];
        lstrcpynA(namesCopy, csv, sizeof(namesCopy));
        char *ctx = NULL;
        char *tok = strtok_s(namesCopy, ",", &ctx);
        BOOL first = TRUE;
        while (tok && pos < (int)sizeof(arr) - 8) {
            while (*tok == ' ') tok++;
            if (!first) arr[pos++] = ',';
            int w = wsprintfA(arr + pos, "\"%s\"", tok);
            if (w > 0) pos += w;
            first = FALSE;
            tok = strtok_s(NULL, ",", &ctx);
        }
        arr[pos++] = ']';
        arr[pos] = '\0';
        wsprintfA(body,
            "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
            "\"liveProcesses\":%s,\"timestamp\":%ld}",
            g_auth.pcDeviceId, g_auth.username, arr, ts);
    }
    stompSendJson("/app/subprocess/live-processes", body);
}

static void sendShaperResult(const char *taskId, BOOL ok, BOOL skipped,
                             const char *reason) {
    if (!g_wsAlive) return;
    long ts = (long)time(NULL);
    char body[1024];
    if (skipped) {
        const char *rs = reason ? reason : "";
        wsprintfA(body,
            "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
            "\"taskId\":\"%s\",\"skipped\":true,\"reason\":\"%s\","
            "\"timestamp\":%ld}",
            g_auth.pcDeviceId, g_auth.username, taskId, rs, ts);
    } else {
        wsprintfA(body,
            "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
            "\"taskId\":\"%s\",\"ok\":%s,\"timestamp\":%ld}",
            g_auth.pcDeviceId, g_auth.username, taskId, ok ? "true" : "false", ts);
    }
    stompSendJson("/app/subprocess/shaper-result", body);
}

/* ==========================================================
 * Read zjc_auth.json
 * ========================================================== */
static BOOL readAuth(void) {
    wchar_t path[MAX_PATH];
    lstrcpyW(path, g_exeDir);
    lstrcatW(path, L"zjc_auth.json");

    HANDLE hf = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hf == INVALID_HANDLE_VALUE) return FALSE;

    char buf[4096];
    DWORD n = 0;
    ReadFile(hf, buf, sizeof(buf) - 1, &n, NULL);
    CloseHandle(hf);
    buf[n] = '\0';

    BOOL ok = TRUE;
    ok = ok && jStr(buf, "username",   g_auth.username,   sizeof(g_auth.username));
    ok = ok && jStr(buf, "password",   g_auth.password,   sizeof(g_auth.password));
    ok = ok && jStr(buf, "pcDeviceId", g_auth.pcDeviceId, sizeof(g_auth.pcDeviceId));
    jInt(buf, "pcLevel", &g_auth.pcLevel);
    return ok;
}

/* ==========================================================
 * SHA256 using Windows CNG (BCrypt)
 * ========================================================== */
static BOOL sha256Hex(const char *input, int inputLen, char *hexOut, int hexOutMax) {
    BCRYPT_ALG_HANDLE hAlg = NULL;
    BCRYPT_HASH_HANDLE hHash = NULL;
    BOOL ok = FALSE;
    BYTE hash[32];
    DWORD hashLen = 32;

    if (BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_SHA256_ALGORITHM, NULL, 0) != 0)
        return FALSE;

    if (BCryptCreateHash(hAlg, &hHash, NULL, 0, NULL, 0, 0) != 0)
        goto sha_done;

    if (BCryptHashData(hHash, (PUCHAR)input, (ULONG)inputLen, 0) != 0)
        goto sha_done;

    if (BCryptFinishHash(hHash, hash, hashLen, 0) != 0)
        goto sha_done;

    for (DWORD i = 0; i < hashLen && (int)(i * 2 + 2) < hexOutMax; i++)
        wsprintfA(hexOut + i * 2, "%02X", hash[i]);

    ok = TRUE;

sha_done:
    if (hHash) BCryptDestroyHash(hHash);
    if (hAlg) BCryptCloseAlgorithmProvider(hAlg, 0);
    return ok;
}

/* ==========================================================
 * Get first valid MAC address (same as Qt QNetworkInterface)
 * ========================================================== */
static BOOL getMacAddress(char *out, int maxLen) {
    ULONG bufLen = 15000;
    PIP_ADAPTER_ADDRESSES addrs = (PIP_ADAPTER_ADDRESSES)HeapAlloc(
        GetProcessHeap(), 0, bufLen);
    if (!addrs) return FALSE;

    DWORD ret = GetAdaptersAddresses(AF_UNSPEC,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        NULL, addrs, &bufLen);

    if (ret == ERROR_BUFFER_OVERFLOW) {
        HeapFree(GetProcessHeap(), 0, addrs);
        addrs = (PIP_ADAPTER_ADDRESSES)HeapAlloc(GetProcessHeap(), 0, bufLen);
        if (!addrs) return FALSE;
        ret = GetAdaptersAddresses(AF_UNSPEC,
            GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
            NULL, addrs, &bufLen);
    }

    if (ret != NO_ERROR) {
        HeapFree(GetProcessHeap(), 0, addrs);
        return FALSE;
    }

    BOOL found = FALSE;
    for (PIP_ADAPTER_ADDRESSES a = addrs; a; a = a->Next) {
        if (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        if (a->OperStatus != IfOperStatusUp) continue;
        if (a->PhysicalAddressLength != 6) continue;

        BOOL allZero = TRUE;
        for (int i = 0; i < 6; i++)
            if (a->PhysicalAddress[i] != 0) { allZero = FALSE; break; }
        if (allZero) continue;

        wsprintfA(out, "%02X:%02X:%02X:%02X:%02X:%02X",
            a->PhysicalAddress[0], a->PhysicalAddress[1],
            a->PhysicalAddress[2], a->PhysicalAddress[3],
            a->PhysicalAddress[4], a->PhysicalAddress[5]);
        found = TRUE;
        break;
    }

    HeapFree(GetProcessHeap(), 0, addrs);
    return found;
}

/* ==========================================================
 * Generate pcDeviceId (same algorithm as Qt main app)
 *   MachineGuid + "|" + MAC -> SHA256 -> "PC_" + first16hex
 * ========================================================== */
static void generatePcDeviceIdW32(char *out, int maxLen) {
    out[0] = '\0';

    /* 1. Try reading cached ID from QSettings registry
     *    QSettings("Phoenix","Phoenix") -> HKCU\Software\Phoenix\Phoenix */
    {
        HKEY hKey;
        if (RegOpenKeyExW(HKEY_CURRENT_USER,
                L"Software\\Phoenix\\Phoenix", 0, KEY_READ, &hKey) == ERROR_SUCCESS) {
            wchar_t val[256] = {0};
            DWORD sz = sizeof(val);
            DWORD type = 0;
            if (RegQueryValueExW(hKey, L"pcDeviceId", NULL, &type,
                    (LPBYTE)val, &sz) == ERROR_SUCCESS && type == REG_SZ) {
                WideCharToMultiByte(CP_UTF8, 0, val, -1, out, maxLen, NULL, NULL);
                RegCloseKey(hKey);
                if (out[0] != '\0') return;
            }
            RegCloseKey(hKey);
        }
    }

    /* 2. Read Windows MachineGuid */
    char rawData[512] = "";
    {
        HKEY hKey;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                L"SOFTWARE\\Microsoft\\Cryptography", 0,
                KEY_READ | KEY_WOW64_64KEY, &hKey) == ERROR_SUCCESS) {
            wchar_t val[256] = {0};
            DWORD sz = sizeof(val);
            if (RegQueryValueExW(hKey, L"MachineGuid", NULL, NULL,
                    (LPBYTE)val, &sz) == ERROR_SUCCESS) {
                WideCharToMultiByte(CP_UTF8, 0, val, -1,
                    rawData, sizeof(rawData), NULL, NULL);
            }
            RegCloseKey(hKey);
        }
    }

    /* 3. Append first valid MAC address */
    {
        char mac[32] = "";
        if (getMacAddress(mac, sizeof(mac))) {
            lstrcatA(rawData, "|");
            lstrcatA(rawData, mac);
        }
    }

    if (rawData[0] == '\0') return; /* nothing to hash */

    /* 4. SHA256 hash -> hex */
    char hex[128] = "";
    sha256Hex(rawData, lstrlenA(rawData), hex, sizeof(hex));
    if (hex[0] == '\0') return;

    /* 5. "PC_" + first 16 uppercase hex chars */
    char first16[17] = "";
    lstrcpynA(first16, hex, 17);
    wsprintfA(out, "PC_%s", first16);
}

/* ==========================================================
 * Register zjc_worker to Windows startup (run on boot)
 *   HKCU\Software\Microsoft\Windows\CurrentVersion\Run
 * ========================================================== */
static void registerToStartup(void) {
    wchar_t exePath[MAX_PATH];
    GetModuleFileNameW(NULL, exePath, MAX_PATH);

    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
        RegSetValueExW(hKey, L"zjc_worker", 0, REG_SZ,
            (const BYTE *)exePath,
            (DWORD)((lstrlenW(exePath) + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        logf("Registered to Windows startup: %ls", exePath);
    }
}

/* ==========================================================
 * HTTP Register (auto-register new account)
 *   POST /api/auth/register/control
 * ========================================================== */
static BOOL httpRegister(const char *username, const char *password,
                         const char *nickname, const char *pcDeviceId) {
    BOOL result = FALSE;
    HINTERNET hSes = WinHttpOpen(L"zjc_worker/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    if (!hSes) return FALSE;

    HINTERNET hCon = WinHttpConnect(hSes, API_HOST,
        INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!hCon) { WinHttpCloseHandle(hSes); return FALSE; }

    HINTERNET hReq = WinHttpOpenRequest(hCon, L"POST",
        L"/api/auth/register/control", NULL, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!hReq) { WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes); return FALSE; }

    WinHttpAddRequestHeaders(hReq,
        L"Content-Type: application/json\r\n", (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD);

    char body[1024];
    wsprintfA(body,
        "{\"username\":\"%s\",\"password\":\"%s\","
        "\"nickname\":\"%s\",\"pcDeviceId\":\"%s\"}",
        username, password, nickname, pcDeviceId);
    int blen = lstrlenA(body);

    if (!WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
            body, blen, blen, 0))
        goto reg_done;

    if (!WinHttpReceiveResponse(hReq, NULL))
        goto reg_done;

    {
        char resp[16384];
        DWORD total = 0, rd = 0;
        while (total < sizeof(resp) - 1) {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(hReq, &avail) || avail == 0) break;
            if (avail > sizeof(resp) - 1 - total)
                avail = (DWORD)(sizeof(resp) - 1 - total);
            WinHttpReadData(hReq, resp + total, avail, &rd);
            total += rd;
        }
        resp[total] = '\0';

        int code = -1;
        jInt(resp, "code", &code);

        if (code == 200) {
            logf("Register OK. resp=%.200s", resp);
            result = TRUE;
        } else if (strstr(resp, "\xe5\xb7\xb2\xe5\xad\x98\xe5\x9c\xa8") /* "已存在" UTF-8 */) {
            logf("Register: account already exists (OK, code=%d). resp=%.300s", code, resp);
            result = TRUE;
        } else {
            logf("Register FAIL: code=%d resp=%.300s", code, resp);
            result = FALSE;
        }
    }

reg_done:
    WinHttpCloseHandle(hReq);
    WinHttpCloseHandle(hCon);
    WinHttpCloseHandle(hSes);
    return result;
}

/* ==========================================================
 * Write zjc_auth.json (save auto-registered credentials)
 *   Returns TRUE only if file write succeeded.
 *   IMPORTANT: 写入失败时返回 FALSE，调用方需据此决定是否重试 — 防止
 *   "写文件失败 → 每次启动都重新 register" 形成跨进程无限注册。
 * ========================================================== */
static BOOL writeAuthJson(void) {
    wchar_t path[MAX_PATH];
    lstrcpyW(path, g_exeDir);
    lstrcatW(path, L"zjc_auth.json");

    char json[2048];
    wsprintfA(json,
        "{\"username\":\"%s\",\"password\":\"%s\","
        "\"pcDeviceId\":\"%s\",\"pcLevel\":%d}",
        g_auth.username, g_auth.password,
        g_auth.pcDeviceId, g_auth.pcLevel);

    HANDLE hf = CreateFileW(path, GENERIC_WRITE, 0, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hf == INVALID_HANDLE_VALUE) {
        logf("writeAuthJson FAILED: cannot create file (err=%lu)", GetLastError());
        return FALSE;
    }
    DWORD w = 0;
    BOOL ok = WriteFile(hf, json, (DWORD)lstrlenA(json), &w, NULL);
    CloseHandle(hf);
    if (!ok || (int)w != lstrlenA(json)) {
        logf("writeAuthJson FAILED: WriteFile partial/err (written=%lu)", w);
        return FALSE;
    }
    return TRUE;
}

/* ==========================================================
 * Auto-register flow (no zjc_auth.json found)
 *   1. Generate pcDeviceId (same algo as Qt main app)
 *   2. Derive username/password from pcDeviceId
 *   3. Call register API (ignore "already exists" error)
 *   4. Save to zjc_auth.json for login
 * ========================================================== */
static void autoRegisterAndSaveAuth(void) {
    /* 1. Generate pcDeviceId */
    generatePcDeviceIdW32(g_auth.pcDeviceId, sizeof(g_auth.pcDeviceId));
    if (g_auth.pcDeviceId[0] == '\0') {
        logf("Auto-register FAILED: cannot generate pcDeviceId");
        return;
    }
    logf("Auto-register: pcDeviceId=%s", g_auth.pcDeviceId);

    /* 2. Username = pcDeviceId directly, password = fixed "123456"
     *    No longer derive from pcDeviceId — simple and deterministic. */
    lstrcpyA(g_auth.username, g_auth.pcDeviceId);
    lstrcpyA(g_auth.password, "123456");

    g_auth.pcLevel = 1;

    logf("Auto-register: user=%s", g_auth.username);

    /* 3. Register — use unique nickname (max 30 chars) to avoid conflicts across devices */
    char nickname[32];
    char shortDev[9] = "";
    int devLen = lstrlenA(g_auth.pcDeviceId);
    if (devLen > 3) {
        lstrcpynA(shortDev, g_auth.pcDeviceId + 3, 9);
    }
    wsprintfA(nickname, "AutoPC_%s", shortDev);
    BOOL regOk = httpRegister(g_auth.username, g_auth.password, nickname, g_auth.pcDeviceId);

    /* 4. Save regardless — if register succeeded or account already exists, login will work.
     *    We always save our own derived credentials; never depend on Phoenix to write them. */
    writeAuthJson();
    if (regOk) {
        logf("Auto-register OK, zjc_auth.json saved");
    } else {
        logf("Auto-register: code=-1 (account may already exist), zjc_auth.json saved, will attempt login");
    }
}

/* ==========================================================
 * HTTP Login via WinHTTP (HTTPS POST)
 * ========================================================== */
static BOOL httpLogin(void) {
    BOOL result = FALSE;
    HINTERNET hSes = WinHttpOpen(L"zjc_worker/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    if (!hSes) return FALSE;

    HINTERNET hCon = WinHttpConnect(hSes, API_HOST,
        INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!hCon) { WinHttpCloseHandle(hSes); return FALSE; }

    HINTERNET hReq = WinHttpOpenRequest(hCon, L"POST",
        L"/api/auth/login/control", NULL, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!hReq) { WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes); return FALSE; }

    WinHttpAddRequestHeaders(hReq,
        L"Content-Type: application/json\r\n", (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD);

    /* Build login JSON body */
    char body[1024];
    wsprintfA(body,
        "{\"username\":\"%s\",\"password\":\"%s\","
        "\"pcDeviceId\":\"%s\",\"pcLevel\":%d,"
        "\"clientType\":\"subprocess\"}",
        g_auth.username, g_auth.password, g_auth.pcDeviceId, g_auth.pcLevel);
    int blen = lstrlenA(body);

    if (!WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
            body, blen, blen, 0))
        goto done;

    if (!WinHttpReceiveResponse(hReq, NULL))
        goto done;

    /* Read response body */
    {
        char resp[16384];
        DWORD total = 0, rd = 0;
        while (total < sizeof(resp) - 1) {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(hReq, &avail) || avail == 0) break;
            if (avail > sizeof(resp) - 1 - total)
                avail = (DWORD)(sizeof(resp) - 1 - total);
            WinHttpReadData(hReq, resp + total, avail, &rd);
            total += rd;
        }
        resp[total] = '\0';

        g_auth.token[0] = '\0';
        jStr(resp, "token", g_auth.token, sizeof(g_auth.token));

        if (g_auth.token[0] == '\0') {
            logf("Login FAIL (no token). resp=%.300s", resp);
            result = FALSE;
        } else {
            logf("Login OK. token=%.30s...", g_auth.token);
            result = TRUE;

            /* Parse processNames from login response (not logged) */
            g_processNameCount = jStrArray(resp, "processNames",
                                           g_processNames, MAX_PROC_NAMES);
        }
    }

done:
    WinHttpCloseHandle(hReq);
    WinHttpCloseHandle(hCon);
    WinHttpCloseHandle(hSes);
    return result;
}

/* ==========================================================
 * WebSocket open (WSS via WinHTTP)
 * ========================================================== */
static BOOL wsOpen(void) {
    ZeroMemory(&g_ws, sizeof(g_ws));

    g_ws.session = WinHttpOpen(L"zjc_worker/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    if (!g_ws.session) return FALSE;

    g_ws.connect = WinHttpConnect(g_ws.session, WS_HOST,
        INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!g_ws.connect) goto fail;

    {
        /* Build /ws?token=...&username=...&pcDeviceId=...&clientType=subprocess */
        wchar_t wTok[1500], wUsr[256], wDev[128];
        MultiByteToWideChar(CP_UTF8, 0, g_auth.token,      -1, wTok, 1500);
        MultiByteToWideChar(CP_UTF8, 0, g_auth.username,    -1, wUsr, 256);
        MultiByteToWideChar(CP_UTF8, 0, g_auth.pcDeviceId,  -1, wDev, 128);

        wchar_t path[4096];
        lstrcpyW(path, L"/ws?token=");
        lstrcatW(path, wTok);
        lstrcatW(path, L"&username=");
        lstrcatW(path, wUsr);
        lstrcatW(path, L"&pcDeviceId=");
        lstrcatW(path, wDev);
        lstrcatW(path, L"&clientType=subprocess");

        HINTERNET hReq = WinHttpOpenRequest(g_ws.connect, L"GET", path,
            NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
            WINHTTP_FLAG_SECURE);
        if (!hReq) goto fail;

        if (!WinHttpSetOption(hReq, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,
                NULL, 0)) {
            WinHttpCloseHandle(hReq);
            goto fail;
        }

        if (!WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                NULL, 0, 0, 0)) {
            WinHttpCloseHandle(hReq);
            goto fail;
        }

        if (!WinHttpReceiveResponse(hReq, NULL)) {
            WinHttpCloseHandle(hReq);
            goto fail;
        }

        g_ws.websocket = WinHttpWebSocketCompleteUpgrade(hReq, 0);
        WinHttpCloseHandle(hReq);   /* request handle no longer needed */

        if (!g_ws.websocket) goto fail;
    }

    g_wsAlive = TRUE;
    return TRUE;

fail:
    if (g_ws.connect)  WinHttpCloseHandle(g_ws.connect);
    if (g_ws.session)  WinHttpCloseHandle(g_ws.session);
    ZeroMemory(&g_ws, sizeof(g_ws));
    return FALSE;
}

/* Forward declarations (used by gracefulExit before their definitions) */
static BOOL wsSendBytes(const void *data, DWORD len);
static void sendStatus(const char *status);

/* Send STOMP DISCONNECT before closing WebSocket (fast backend status update) */
static void stompDisconnect(void) {
    static const char f[] = "DISCONNECT\n\n";
    wsSendBytes(f, sizeof(f));
}

static void wsShutdown(void) {
    g_wsAlive = FALSE;
    if (g_ws.websocket) {
        WinHttpWebSocketClose(g_ws.websocket,
            WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, NULL, 0);
        WinHttpCloseHandle(g_ws.websocket);
    }
    if (g_ws.connect)  WinHttpCloseHandle(g_ws.connect);
    if (g_ws.session)  WinHttpCloseHandle(g_ws.session);
    ZeroMemory(&g_ws, sizeof(g_ws));
}

static volatile BOOL g_exitRequested = FALSE;

/* Graceful shutdown: send DISCONNECT, close WS.
 * Sets g_exitRequested so the main loop terminates cleanly. */
static void gracefulExit(void) {
    if (g_exitRequested) return;
    g_exitRequested = TRUE;
    logf("Stop event received, shutting down gracefully ...");
    shaper_stop();
    if (g_wsAlive) {
        sendStatus("offline");
        stompDisconnect();
        Sleep(200);
    }
    wsShutdown();
    logf("=== zjc_worker exited gracefully ===");
}

/* ==========================================================
 * STOMP frame send helpers (thread-safe)
 * ========================================================== */
static BOOL wsSendBytes(const void *data, DWORD len) {
    if (!g_wsAlive || !g_ws.websocket) return FALSE;
    EnterCriticalSection(&g_sendLock);
    DWORD err = WinHttpWebSocketSend(g_ws.websocket,
        WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
        (PVOID)data, len);
    LeaveCriticalSection(&g_sendLock);
    return (err == ERROR_SUCCESS);
}

/* STOMP CONNECT */
static BOOL stompConnect(void) {
    static const char f[] =
        "CONNECT\naccept-version:1.0,1.1,2.0\nheart-beat:10000,10000\n\n";
    return wsSendBytes(f, sizeof(f));  /* sizeof includes trailing \0 = STOMP frame end */
}

/* STOMP SUBSCRIBE */
static BOOL stompSubscribe(const char *dest, int subId) {
    char f[512];
    wsprintfA(f, "SUBSCRIBE\nid:sub-%d\ndestination:%s\n\n", subId, dest);
    return wsSendBytes(f, lstrlenA(f) + 1);
}

/* STOMP SEND with JSON body */
static BOOL stompSendJson(const char *dest, const char *json) {
    char f[2048];
    wsprintfA(f, "SEND\ndestination:%s\ncontent-type:application/json\n\n%s",
        dest, json);
    return wsSendBytes(f, lstrlenA(f) + 1);
}

/* STOMP heartbeat (single newline) */
static BOOL stompHeartbeat(void) {
    char hb = '\n';
    return wsSendBytes(&hb, 1);
}

/* ==========================================================
 * Status & burst-result reports
 * ========================================================== */
static void sendStatus(const char *status) {
    if (!g_wsAlive) return;
    int m_i = (int)g_lastMbps;
    int m_f = (int)((g_lastMbps - m_i) * 100);
    long ts = (long)time(NULL);

    char body[1024];
    wsprintfA(body,
        "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
        "\"clientType\":\"subprocess\",\"status\":\"%s\","
        "\"lastBurstMbps\":%d.%02d,\"lastBurstTime\":\"%s\","
        "\"timestamp\":%ld}",
        g_auth.pcDeviceId, g_auth.username, status,
        m_i, m_f, g_lastBurstTime, ts);

    stompSendJson("/app/subprocess/status", body);
}

static void sendBurstResult(const char *taskId, double totalMB,
                            double speedMbps, double durSec, int threads) {
    if (!g_wsAlive) return;
    int mb_i = (int)totalMB,   mb_f = (int)((totalMB - mb_i) * 100);
    int sp_i = (int)speedMbps, sp_f = (int)((speedMbps - sp_i) * 100);
    int d_i  = (int)durSec,    d_f  = (int)((durSec - d_i) * 10);
    long ts = (long)time(NULL);

    char body[1024];
    wsprintfA(body,
        "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
        "\"taskId\":\"%s\",\"totalMB\":%d.%02d,"
        "\"speedMbps\":%d.%02d,\"durationSec\":%d.%d,"
        "\"threads\":%d,\"timestamp\":%ld}",
        g_auth.pcDeviceId, g_auth.username,
        taskId, mb_i, mb_f, sp_i, sp_f, d_i, d_f, threads, ts);

    stompSendJson("/app/subprocess/burst-result", body);
}

/* ==========================================================
 * DNS resolve + TCP connect (for burst downloads)
 * ========================================================== */
static BOOL resolveHost(const char *host, struct sockaddr_in *addr) {
    struct addrinfo hints, *res = NULL;
    ZeroMemory(&hints, sizeof(hints));
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, "80", &hints, &res) != 0 || !res) return FALSE;
    *addr = *(struct sockaddr_in *)res->ai_addr;
    freeaddrinfo(res);
    return TRUE;
}

static SOCKET connectTarget(DlTarget *t, DWORD recvTimeoutMs) {
    struct sockaddr_in sa;
    if (!resolveHost(t->host, &sa)) return INVALID_SOCKET;

    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;

    /* 4 MB receive buffer for maximum throughput */
    int rcv = 4 * 1024 * 1024;
    setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&rcv, sizeof(rcv));

    /* TCP_NODELAY: disable Nagle for faster request send */
    int nodelay = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&nodelay, sizeof(nodelay));

    /* Non-blocking connect with 2 s timeout (aggressive fallback) */
    u_long nb = 1;
    ioctlsocket(s, FIONBIO, &nb);
    connect(s, (struct sockaddr *)&sa, sizeof(sa));

    fd_set wset;
    FD_ZERO(&wset);
    FD_SET(s, &wset);
    struct timeval tv = { 2, 0 };
    if (select(0, NULL, &wset, NULL, &tv) <= 0) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    /* Check for actual connection (not just writeable) */
    int serr = 0;
    int slen = sizeof(serr);
    getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&serr, &slen);
    if (serr != 0) { closesocket(s); return INVALID_SOCKET; }

    nb = 0;
    ioctlsocket(s, FIONBIO, &nb);

    if (send(s, t->request, lstrlenA(t->request), 0) == SOCKET_ERROR) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&recvTimeoutMs, sizeof(recvTimeoutMs));
    return s;
}

/* ==========================================================
 * Burst download thread (single-shot per burst)
 * ========================================================== */
static DWORD WINAPI burstThread(LPVOID param) {
    int idx = (int)(INT_PTR)param;
    int tgt = idx % CN_TARGET_COUNT;
    char *buf = (char *)HeapAlloc(GetProcessHeap(), 0, RECV_BUF_SIZE);
    if (!buf) return 0;

    /* Try all targets until one connects (5 s recv timeout for pre-connect) */
    SOCKET s = INVALID_SOCKET;
    for (int t = 0; t < TARGET_COUNT && s == INVALID_SOCKET; t++) {
        s = connectTarget(&TARGETS[tgt], 5000);
        tgt = (tgt + 1) % TARGET_COUNT;
    }
    if (s == INVALID_SOCKET) {
        HeapFree(GetProcessHeap(), 0, buf);
        return 0;
    }

    /* Read and discard HTTP headers */
    {
        char hdr[4096];
        recv(s, hdr, sizeof(hdr), 0);
    }

    InterlockedIncrement(&g_readyCount);

    /* Wait for burst signal */
    WaitForSingleObject(g_startEvent, INFINITE);
    if (!g_burst) {
        closesocket(s);
        HeapFree(GetProcessHeap(), 0, buf);
        return 0;
    }

    /* Switch to aggressive recv timeout for burst phase (2 s):
     * dead connections are detected in 2 s instead of 5 s */
    {
        DWORD burstTimeout = 2000;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO,
            (const char *)&burstTimeout, sizeof(burstTimeout));
    }

    /* BURST: recv as fast as possible, RECONNECT on failure */
    InterlockedIncrement(&g_activeCount);
    while (g_burst) {
        int n = recv(s, buf, RECV_BUF_SIZE, 0);
        if (n <= 0) {
            /* Connection died - try to reconnect immediately */
            closesocket(s);
            s = INVALID_SOCKET;

            if (!g_burst) break;   /* burst ended, no need to reconnect */

            /* Fast reconnect: 2 s recv timeout, try max 3 targets
             * (don't waste burst time cycling all 12) */
            for (int t = 0; t < 3 && s == INVALID_SOCKET; t++) {
                tgt = (tgt + 1) % TARGET_COUNT;
                s = connectTarget(&TARGETS[tgt], 2000);
            }
            if (s == INVALID_SOCKET) break;

            /* Set aggressive recv timeout on new socket too */
            {
                DWORD bt2 = 2000;
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO,
                    (const char *)&bt2, sizeof(bt2));
            }

            /* Discard HTTP headers of new connection */
            {
                char hdr[4096];
                recv(s, hdr, sizeof(hdr), 0);
            }
            continue;
        }
        InterlockedAdd64(&g_burstBytes, (LONGLONG)n);
    }
    InterlockedDecrement(&g_activeCount);

    if (s != INVALID_SOCKET) closesocket(s);
    HeapFree(GetProcessHeap(), 0, buf);
    return 0;
}

/* ==========================================================
 * Execute a single burst (blocks for durSec seconds)
 * ========================================================== */
typedef struct {
    double totalMB;
    double speedMbps;
    double durSec;
    int    readyThreads;
} BurstResult;

static BurstResult doBurst(int durSec) {
    BurstResult r;
    ZeroMemory(&r, sizeof(r));

    g_burstBytes  = 0;
    g_readyCount  = 0;
    g_activeCount = 0;
    g_burst       = 0;
    ResetEvent(g_startEvent);

    HANDLE th[THREAD_COUNT];
    for (int i = 0; i < THREAD_COUNT; i++)
        th[i] = CreateThread(NULL, 0, burstThread, (LPVOID)(INT_PTR)i, 0, NULL);

    /* Wait for 50 % of threads to be ready (max 15 s) - start fast */
    int minReady = THREAD_COUNT / 2;
    DWORD t0 = GetTickCount();
    while (g_readyCount < minReady && (GetTickCount() - t0) < 15000)
        Sleep(80);

    r.readyThreads = (int)g_readyCount;
    logf("BURST: %d/%d ready, GO! (%d sec)", r.readyThreads, THREAD_COUNT, durSec);

    g_burst = 1;
    DWORD start = GetTickCount();
    SetEvent(g_startEvent);

    Sleep(durSec * 1000);
    g_burst = 0;
    DWORD end = GetTickCount();

    /* WaitForMultipleObjects supports max MAXIMUM_WAIT_OBJECTS (64) handles,
     * so we wait in batches of 64 */
    for (int base = 0; base < THREAD_COUNT; base += 64) {
        int cnt = THREAD_COUNT - base;
        if (cnt > 64) cnt = 64;
        WaitForMultipleObjects((DWORD)cnt, th + base, TRUE, 5000);
    }
    for (int i = 0; i < THREAD_COUNT; i++)
        if (th[i]) CloseHandle(th[i]);

    r.durSec   = (end - start) / 1000.0;
    r.totalMB  = (double)g_burstBytes / (1024.0 * 1024.0);
    double MBps = (r.durSec > 0) ? (r.totalMB / r.durSec) : 0;
    r.speedMbps = MBps * 8.0;
    return r;
}

/* ==========================================================
 * Heartbeat + periodic status thread
 * ========================================================== */
static volatile BOOL g_authChanged = FALSE;

static DWORD WINAPI keepAliveThread(LPVOID param) {
    (void)param;
    DWORD lastHB = GetTickCount();
    DWORD lastSt = GetTickCount();
    DWORD lastAuthCheck = GetTickCount();
    DWORD lastLive = GetTickCount();

    while (g_wsAlive) {
        Sleep(1000);
        DWORD now = GetTickCount();
        if (now - lastHB >= (DWORD)(HEARTBEAT_SEC * 1000)) {
            stompHeartbeat();
            lastHB = now;
        }
        if (now - lastSt >= (DWORD)(STATUS_SEC * 1000)) {
            sendStatus("idle");
            lastSt = now;
        }
        /* 每60秒上报一次「进程名称管理」中存活的进程列表（即使为空也上报"无"） */
        if (now - lastLive >= 60000) {
            sendLiveProcesses();
            lastLive = now;
        }
        /* Every 30s: log heartbeat; do NOT re-read zjc_auth.json or switch accounts —
           subprocess always uses its own auto-registered zjc_XXXX account */
        if (now - lastAuthCheck >= 30000) {
            lastAuthCheck = now;
            /* no-op: removed auth-file polling to avoid depending on Phoenix-written creds */
        }
    }
    return 0;
}

/* ==========================================================
 * 互相监督实现
 * ========================================================== */

/* 看门狗是否在运行：能打开它持有的存活互斥量即视为在。 */
static BOOL watchdogAlive(void) {
    HANDLE h = OpenMutexW(SYNCHRONIZE, FALSE, WD_ALIVE_MUTEX);
    if (h) { CloseHandle(h); return TRUE; }
    return FALSE;
}

/* 拉起一个「--watchdog」子进程（分离、无窗口）。 */
static void spawnWatchdog(void) {
    wchar_t selfExe[MAX_PATH];
    GetModuleFileNameW(NULL, selfExe, MAX_PATH);
    wchar_t cmdline[MAX_PATH + 32];
    wsprintfW(cmdline, L"\"%s\" --watchdog", selfExe);

    STARTUPINFOW si; ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    PROCESS_INFORMATION pi; ZeroMemory(&pi, sizeof(pi));
    if (CreateProcessW(NULL, cmdline, NULL, NULL, FALSE,
                       DETACHED_PROCESS | CREATE_NO_WINDOW,
                       NULL, g_exeDir, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        logf("watchdog: spawned guardian process");
    } else {
        logf("watchdog: spawn failed (%lu)", GetLastError());
    }
}

/* 主进程侧：guard 线程——看门狗不在就补一个。看门狗自身带单例互斥，重复拉起无害。 */
static DWORD WINAPI watchdogGuardThread(LPVOID param) {
    (void)param;
    while (!g_exitRequested && !shouldStop()) {
        if (!watchdogAlive())
            spawnWatchdog();
        for (int i = 0; i < WD_POLL_SEC && !g_exitRequested && !shouldStop(); i++)
            Sleep(1000);
    }
    return 0;
}

/* 看门狗角色主体：不登录、不联网，只盯着 zjc_worker 服务，停了就拉起。 */
static int runWatchdog(void) {
    /* 单例：已有看门狗在跑就直接退出（防止 guard 线程偶发拉起多个）。 */
    HANDLE aliveMutex = CreateMutexW(NULL, TRUE, WD_ALIVE_MUTEX);
    if (!aliveMutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (aliveMutex) CloseHandle(aliveMutex);
        return 0;
    }

    /* 卸载时主进程会置位此事件，通知看门狗退出（否则会立刻把服务又拉起来）。 */
    HANDLE stopEvt = CreateEventW(NULL, TRUE, FALSE, WD_STOP_EVENT);

    for (;;) {
        if (stopEvt && WaitForSingleObject(stopEvt, 0) == WAIT_OBJECT_0)
            break;

        SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
        if (scm) {
            SC_HANDLE svc = OpenServiceW(scm, ZJC_SERVICE_NAME,
                                         SERVICE_QUERY_STATUS | SERVICE_START);
            if (svc) {
                SERVICE_STATUS ss;
                if (QueryServiceStatus(svc, &ss)
                    && ss.dwCurrentState == SERVICE_STOPPED) {
                    /* §56.7 服务被停/被杀 → 立即拉起，并落盘记录（排查"被杀"的关键证据链） */
                    BOOL ok = StartServiceW(svc, 0, NULL);
                    logf("[watchdog] 发现服务已停止 → 拉起%s (err=%lu)",
                         ok ? "成功" : "失败", ok ? 0 : GetLastError());
                }
                CloseServiceHandle(svc);
            }
            /* 服务不存在(卸载后)：StartService 无从谈起，看门狗放弃复活，随停止事件退出。 */
            CloseServiceHandle(scm);
        }

        /* 可被停止事件立即唤醒的分段睡眠 */
        if (stopEvt) {
            if (WaitForSingleObject(stopEvt, WD_POLL_SEC * 1000) == WAIT_OBJECT_0)
                break;
        } else {
            Sleep(WD_POLL_SEC * 1000);
        }
    }

    if (stopEvt) CloseHandle(stopEvt);
    ReleaseMutex(aliveMutex);
    CloseHandle(aliveMutex);
    return 0;
}

/* ==========================================================
 * §59 2026-08-12 自杀重生：连续连不上（WS 打开/STOMP CONNECT/CONNECTED 回包）
 * 超过阈值 → 服务模式下主动异常退出，让 SCM 故障自动重启策略（svcInstall 已配
 * 5s/10s/30s + 非崩溃退出也触发）拉起一个全新进程。
 * 处理"进程活着但 WinHTTP 句柄/WS 卡死导致永远连不上"这类僵死——比外部卸载重装干净，
 * 也是判定矩阵"跑着但没连上→重启而非重装"的 worker 侧兜底。
 * RECONNECT_SEC=5s × 60 次 ≈ 5 分钟持续失败才触发（网络抖动不至于误杀）。
 * 仅服务模式生效：standalone 退出后没人拉起，维持原地重试。
 * ========================================================== */
#define CONN_FAIL_SUICIDE_N 60
static int g_connFailStreak = 0;
static void connFailBump(void) {
    g_connFailStreak++;
    if (g_isService && g_connFailStreak >= CONN_FAIL_SUICIDE_N) {
        logf("!! consecutive connect failures reached %d (~5 min) -> self-exit(1), SCM will auto-restart",
             g_connFailStreak);
        /* 非零码退出且不上报 SERVICE_STOPPED = SCM 判定服务故障 → 按策略自动重启 */
        ExitProcess(1);
    }
}

/* ==========================================================
 * workerMain - core logic (called by service or standalone)
 * ========================================================== */
static void workerMain(void) {
    /* --- Build exe directory & log path --- */
    {
        wchar_t ep[MAX_PATH];
        GetModuleFileNameW(NULL, ep, MAX_PATH);
        wchar_t *sl = ep;
        for (wchar_t *p = ep; *p; p++)
            if (*p == L'\\' || *p == L'/') sl = p;
        sl[1] = L'\0';
        lstrcpyW(g_exeDir, ep);
    }
    lstrcpyW(g_logPath, g_exeDir);
    lstrcatW(g_logPath, L"zjc.txt");

    /* --- Init Winsock --- */
    WSADATA wd;
    WSAStartup(MAKEWORD(2, 2), &wd);

    g_startEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    /* Global namespace: visible across sessions (service in session 0, user in session 1+).
     * For standalone mode fallback, also works within same session. */
    g_stopEvent  = CreateEventW(NULL, TRUE, FALSE, STOP_EVENT_NAME);
    InitializeCriticalSection(&g_sendLock);
    InitializeCriticalSection(&g_shaperCs);

    /* §56.7 启动日志带版本号：排查"到底跑的哪个版本 / 有没有升级成功"全靠它 */
    logf("=== zjc_worker %s started (%s mode) ===", ZJC_WORKER_VERSION,
         g_isService ? "service" : "standalone");

    /* --- 互相监督：服务模式下起 guard 线程，保证看门狗常在（看门狗反过来保证服务常在）--- */
    if (g_isService)
        CloseHandle(CreateThread(NULL, 0, watchdogGuardThread, NULL, 0, NULL));

    /* --- 0. Register startup (standalone only; service auto-starts via SCM) --- */
    if (!g_isService)
        registerToStartup();

    /* --- 1. Read auth file, or auto-register if missing --- */
    if (!readAuth()) {
        logf("No zjc_auth.json found, attempting auto-register ...");
        autoRegisterAndSaveAuth();
        if (g_auth.username[0] == '\0' || g_auth.pcDeviceId[0] == '\0') {
            logf("Auto-register incomplete, waiting for zjc_auth.json ...");
            while (!readAuth() && !shouldStop()) {
                Sleep(AUTH_RETRY_SEC * 1000);
            }
        }
    }
    if (shouldStop()) { gracefulExit(); goto cleanup; }
    logf("Auth loaded: user=%s dev=%s", g_auth.username, g_auth.pcDeviceId);

    /* --- Main reconnect loop --- */
    while (!g_exitRequested) {

        if (shouldStop()) { gracefulExit(); break; }

        /* --- 2. Login --- */
        logf("Logging in ...");
        {
            int retries = 0;
            while (!httpLogin() && !shouldStop()) {
                retries++;
                logf("Login failed (%d), retry in %ds ...", retries, AUTH_RETRY_SEC);
                Sleep(AUTH_RETRY_SEC * 1000);
                if (retries % 5 == 0) readAuth();
            }
        }
        if (shouldStop()) { gracefulExit(); break; }

        /* --- 3. Connect WebSocket --- */
        logf("Connecting WebSocket ...");
        if (!wsOpen()) {
            logf("WS connect failed, retry in %ds ...", RECONNECT_SEC);
            connFailBump();   /* §59 连续失败计数（达阈值服务模式自杀重生） */
            Sleep(RECONNECT_SEC * 1000);
            continue;
        }
        logf("WebSocket connected.");

        /* --- 4. STOMP CONNECT --- */
        if (!stompConnect()) {
            logf("STOMP CONNECT send failed.");
            wsShutdown();
            connFailBump();
            Sleep(RECONNECT_SEC * 1000);
            continue;
        }

        {
            char rb[4096];
            DWORD rd = 0;
            WINHTTP_WEB_SOCKET_BUFFER_TYPE bt;
            DWORD err = WinHttpWebSocketReceive(g_ws.websocket,
                rb, sizeof(rb) - 1, &rd, &bt);
            if (err != ERROR_SUCCESS || rd == 0) {
                logf("WS recv CONNECTED failed: err=%lu rd=%lu", err, rd);
                wsShutdown();
                connFailBump();
                Sleep(RECONNECT_SEC * 1000);
                continue;
            }
            rb[rd] = '\0';
            if (!strstr(rb, "CONNECTED")) {
                logf("Expected CONNECTED, got: %.100s", rb);
                wsShutdown();
                connFailBump();
                Sleep(RECONNECT_SEC * 1000);
                continue;
            }
            logf("STOMP CONNECTED OK.");
            g_connFailStreak = 0;   /* §59 连上即清零，只统计"连续"失败 */
        }

        /* --- 5. Subscribe to burst + shaper channels --- */
        {
            char dest[256];
            wsprintfA(dest, "/topic/pc/%s/burst", g_auth.pcDeviceId);
            stompSubscribe(dest, 1);
            stompSubscribe("/topic/burst/all", 2);
            wsprintfA(dest, "/topic/pc/%s/shaper", g_auth.pcDeviceId);
            stompSubscribe(dest, 3);
            stompSubscribe("/topic/shaper/all", 4);
            logf("Subscribed: burst + shaper (pc + all)");
        }

        /* --- 6. Send initial status + 进程列表初次上报 --- */
        sendStatus("idle");
        sendLiveProcesses();

        /* --- 7. Start keep-alive thread --- */
        HANDLE hbThread = CreateThread(NULL, 0, keepAliveThread, NULL, 0, NULL);

        /* --- 8. Message receive loop --- */
        {
            char recvBuf[16384];
            BOOL alive = TRUE;

            while (alive && !g_exitRequested) {
                if (shouldStop()) { gracefulExit(); alive = FALSE; break; }

                DWORD rd = 0;
                WINHTTP_WEB_SOCKET_BUFFER_TYPE bt;
                DWORD err = WinHttpWebSocketReceive(g_ws.websocket,
                    recvBuf, sizeof(recvBuf) - 1, &rd, &bt);

                if (err != ERROR_SUCCESS) {
                    if (shouldStop()) { gracefulExit(); alive = FALSE; break; }
                    logf("WS recv error: %lu", err);
                    alive = FALSE;
                    break;
                }
                if (bt == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
                    logf("WS closed by server.");
                    alive = FALSE;
                    break;
                }
                if (rd == 0) continue;

                recvBuf[rd] = '\0';

                if (rd <= 2 && (recvBuf[0] == '\n' || recvBuf[0] == '\r'))
                    continue;

                if (strncmp(recvBuf, "MESSAGE", 7) == 0) {
                    char *body = strstr(recvBuf, "\n\n");
                    if (!body) continue;
                    body += 2;

                    char action[64] = "";
                    jStr(body, "action", action, sizeof(action));

                    if (lstrcmpA(action, "BURST") == 0) {
                        int duration = DEFAULT_BURST_SEC;
                        jInt(body, "duration", &duration);
                        if (duration < 1)   duration = 1;
                        if (duration > 120) duration = 120;

                        char taskId[128] = "";
                        jStr(body, "taskId", taskId, sizeof(taskId));

                        logf(">>> BURST cmd: dur=%d task=%s", duration, taskId);

                        {
                            char matched[MAX_PATH] = "";
                            if (!checkRequiredProcess(matched, sizeof(matched))) {
                                logf(">>> BURST SKIPPED (no_required_process)");
                                char skipBody[1024];
                                wsprintfA(skipBody,
                                    "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
                                    "\"taskId\":\"%s\",\"skipped\":true,"
                                    "\"reason\":\"no_required_process\","
                                    "\"timestamp\":%ld}",
                                    g_auth.pcDeviceId, g_auth.username,
                                    taskId, (long)time(NULL));
                                stompSendJson("/app/subprocess/burst-result", skipBody);
                                continue;
                            }
                        }

                        /* Phoenix 主程序运行时不爆发，避免影响用户正常使用 */
                        {
                            char pxMatch[MAX_PATH] = "";
                            if (processNamedRunning("Phoenix.exe", pxMatch, sizeof(pxMatch))) {
                                logf(">>> BURST SKIPPED (Phoenix.exe is running)");
                                char skipBody[1024];
                                wsprintfA(skipBody,
                                    "{\"pcDeviceId\":\"%s\",\"username\":\"%s\","
                                    "\"taskId\":\"%s\",\"skipped\":true,"
                                    "\"reason\":\"phoenix_running\","
                                    "\"timestamp\":%ld}",
                                    g_auth.pcDeviceId, g_auth.username,
                                    taskId, (long)time(NULL));
                                stompSendJson("/app/subprocess/burst-result", skipBody);
                                continue;
                            }
                        }

                        sendStatus("bursting");
                        BurstResult br = doBurst(duration);

                        int mb_i  = (int)br.totalMB,   mb_f  = (int)((br.totalMB - mb_i) * 100);
                        int sp_i  = (int)br.speedMbps, sp_f  = (int)((br.speedMbps - sp_i) * 100);
                        int d_i   = (int)br.durSec,    d_f   = (int)((br.durSec - d_i) * 10);
                        logf(">>> DONE: %d.%02d MB in %d.%ds | %d.%02d Mbps | %d threads",
                            mb_i, mb_f, d_i, d_f, sp_i, sp_f, br.readyThreads);

                        g_lastMbps = br.speedMbps;
                        {
                            SYSTEMTIME st;
                            GetLocalTime(&st);
                            wsprintfA(g_lastBurstTime,
                                "%04d-%02d-%02d %02d:%02d:%02d",
                                st.wYear, st.wMonth, st.wDay,
                                st.wHour, st.wMinute, st.wSecond);
                        }

                        sendBurstResult(taskId, br.totalMB, br.speedMbps,
                            br.durSec, br.readyThreads);
                        sendStatus("idle");
                    }
                    else if (lstrcmpA(action, "TRAFFIC_SHAPE") == 0) {
                        char taskId[128] = "";
                        jStr(body, "taskId", taskId, sizeof(taskId));

                        /* 正在整形则直接忽略新任务，回 skipped（TRAFFIC_SHAPE_STOP 仍可立即停） */
                        EnterCriticalSection(&g_shaperCs);
                        BOOL alreadyShaping = (g_shaperProc != NULL);
                        LeaveCriticalSection(&g_shaperCs);
                        if (alreadyShaping) {
                            logf(">>> TRAFFIC_SHAPE task=%s ignored (already shaping)", taskId);
                            sendShaperResult(taskId, FALSE, TRUE, "already_shaping");
                            continue;
                        }

                        char processName[512] = "";
                        if (!jStr(body, "processName", processName, sizeof(processName)))
                            jStr(body, "process", processName, sizeof(processName));

                        long long upBps = 0, downBps = 0;
                        if (!jInt64(body, "uploadBps", &upBps))
                            jInt64(body, "upBps", &upBps);
                        if (!jInt64(body, "downloadBps", &downBps))
                            jInt64(body, "downBps", &downBps);

                        int durationSec = 0;
                        jInt(body, "durationSec", &durationSec);
                        if (durationSec < 0) durationSec = 0;
                        if (durationSec > 86400) durationSec = 86400;

                        // ⭐ 隐藏敏感信息：不记录进程名和限流参数
                        logf(">>> TRAFFIC_SHAPE task=%s", taskId);

                        if (!processName[0]) {
                            sendShaperResult(taskId, FALSE, TRUE, "no_process_name");
                            continue;
                        }
                        if (upBps < 0) upBps = 0;
                        if (downBps < 0) downBps = 0;
                        if (upBps > 1000000000LL) upBps = 1000000000LL;
                        if (downBps > 1000000000LL) downBps = 1000000000LL;
                        if (upBps == 0 && downBps == 0) {
                            sendShaperResult(taskId, FALSE, TRUE, "no_rates_specified");
                            continue;
                        }

                        /* 进程存在性检查移到 shaper_start_child_multi 内部逐个判断 */
                        char shaperFailReason[64] = "";
                        if (!shaper_start_child_multi(processName, upBps, downBps, durationSec,
                                                       shaperFailReason, sizeof(shaperFailReason))) {
                            /* "no_running_process" 视为 skipped（用户配置进程未运行），
                             *  其它（rules_write_fail / createprocess_fail）视为真正失败 */
                            BOOL isSkipped = (lstrcmpA(shaperFailReason, "no_running_process") == 0);
                            sendShaperResult(taskId, FALSE, isSkipped,
                                shaperFailReason[0] ? shaperFailReason : "unknown");
                        } else {
                            sendShaperResult(taskId, TRUE, FALSE, NULL);
                        }
                    }
                    else if (lstrcmpA(action, "TRAFFIC_SHAPE_STOP") == 0) {
                        char taskId[128] = "";
                        jStr(body, "taskId", taskId, sizeof(taskId));
                        logf(">>> TRAFFIC_SHAPE_STOP task=%s", taskId);
                        shaper_stop();
                        sendShaperResult(taskId, TRUE, FALSE, NULL);
                    }

                } else if (strncmp(recvBuf, "ERROR", 5) == 0) {
                    logf("STOMP ERROR: %.200s", recvBuf);
                }
            }
        }

        /* --- 9. Cleanup & reconnect --- */
        g_wsAlive = FALSE;
        shaper_stop();
        wsShutdown();
        if (hbThread) {
            WaitForSingleObject(hbThread, 3000);
            CloseHandle(hbThread);
        }
        if (g_exitRequested) break;
        if (g_authChanged) {
            logf("Auth credentials changed, re-login with new account immediately.");
            g_authChanged = FALSE;
            g_auth.token[0] = '\0';
        } else {
            logf("Disconnected. Reconnect in %ds ...", RECONNECT_SEC);
            Sleep(RECONNECT_SEC * 1000);
        }
    }

cleanup:
    DeleteCriticalSection(&g_shaperCs);
    DeleteCriticalSection(&g_sendLock);
    if (g_startEvent) CloseHandle(g_startEvent);
    if (g_stopEvent)  CloseHandle(g_stopEvent);
    WSACleanup();
}

/* ==========================================================
 * WinMain - entry point
 * ========================================================== */
int WINAPI WinMain(HINSTANCE hi, HINSTANCE hp, LPSTR cmd, int show) {
    (void)hi; (void)hp; (void)show;

    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);

#if ZJC_EMBED_WINSHAPER
    if (argv && argc >= 3 && lstrcmpiW(argv[1], L"--zjc-shaper") == 0) {
        char rules8[MAX_PATH * 4];
        WideCharToMultiByte(CP_UTF8, 0, argv[2], -1, rules8, sizeof(rules8), NULL, NULL);
        LocalFree(argv);
        char *fakeArgv[] = { "zjc_worker", rules8, NULL };
        return (int)winshaper_main(2, fakeArgv);
    }
#endif

    /* --version: 打印版本号后退出（Phoenix/运维查询用） */
    if (argv && argc >= 2 && lstrcmpiW(argv[1], L"--version") == 0) {
        LocalFree(argv);
        printf("%s", ZJC_WORKER_VERSION);
        return 0;
    }

    /* --install: register and start the Windows service */
    if (argv && argc >= 2 && lstrcmpiW(argv[1], L"--install") == 0) {
        LocalFree(argv);
        initLogToProgramData();   /* §56.7 安装 exe 跑在 dl\ 下，日志统一写 ProgramData\zjc_worker\zjc.txt */
        return svcInstall() ? 0 : 1;
    }

    /* --uninstall: stop and remove the Windows service */
    if (argv && argc >= 2 && lstrcmpiW(argv[1], L"--uninstall") == 0) {
        LocalFree(argv);
        initLogToProgramData();
        return svcUninstall() ? 0 : 1;
    }

    /* --watchdog: 纯监督子进程（不登录、不联网），只把 zjc_worker 服务保活 */
    if (argv && argc >= 2 && lstrcmpiW(argv[1], L"--watchdog") == 0) {
        LocalFree(argv);
        initLogToProgramData();   /* §56.7 看门狗拉起服务的记录也写同一份 zjc.txt */
        return runWatchdog();
    }

    /* --standalone: skip service dispatcher, run directly (for debugging) */
    BOOL forceStandalone = FALSE;
    if (argv && argc >= 2 && lstrcmpiW(argv[1], L"--standalone") == 0)
        forceStandalone = TRUE;

    if (argv) LocalFree(argv);

    if (!forceStandalone) {
        /* Try to connect to the Service Control Manager.
         * If launched by SCM this succeeds and calls SvcMain.
         * If launched manually (double-click / console) this fails quickly. */
        g_isService = TRUE;
        SERVICE_TABLE_ENTRYW table[] = {
            { ZJC_SERVICE_NAME, SvcMain },
            { NULL, NULL }
        };
        if (StartServiceCtrlDispatcherW(table))
            return 0;
    }

    /* Fallback: standalone mode (launched manually or --standalone) */
    g_isService = FALSE;
    workerMain();
    return 0;
}
