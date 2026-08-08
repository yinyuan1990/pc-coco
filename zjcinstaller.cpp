#include "zjcinstaller.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrl>
#include <atomic>
#include <thread>

#include <QStringList>
#include <vector>
#include <string>

#ifdef Q_OS_WIN
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <shellapi.h>
#include <tlhelp32.h>
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "shell32.lib")
#endif

namespace {

std::atomic<bool> g_started{false};

// 独立日志（与主程序日志分开，排查安装问题用）
// ⭐ 2026-08-02 日志清理：超 2MB 轮转成 zjc_install.old.txt（只保留一份旧的），
//   此前每次登录追加、无任何清理机制，常年累积无限膨胀。
void zjcLog(const QString &msg) {
    const QString path = QCoreApplication::applicationDirPath() + "/zjc_install.txt";
    if (QFile(path).size() > 2 * 1024 * 1024) {
        const QString oldPath = QCoreApplication::applicationDirPath() + "/zjc_install.old.txt";
        QFile::remove(oldPath);
        QFile::rename(path, oldPath);
    }
    const QString line = QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss.zzz")
                         + "  " + msg;
    QFile f(path);
    if (f.open(QIODevice::Append | QIODevice::Text)) {
        f.write(line.toUtf8());
        f.write("\n");
        f.close();
    }
    qDebug().noquote() << "[ZjcInstaller]" << msg;
}

#ifdef Q_OS_WIN

// ---- WinHTTP 同步 GET，返回响应体（失败返回空 QByteArray，*ok=false） ----
QByteArray httpGet(const QUrl &url, bool *ok) {
    if (ok) *ok = false;
    QByteArray result;
    const bool https = (url.scheme().compare("https", Qt::CaseInsensitive) == 0);
    const std::wstring host = url.host().toStdWString();
    INTERNET_PORT port = (INTERNET_PORT)(url.port(https ? 443 : 80));
    QString pathQ = url.path();
    if (url.hasQuery()) pathQ += "?" + url.query();
    if (pathQ.isEmpty()) pathQ = "/";
    const std::wstring path = pathQ.toStdWString();

    HINTERNET hSession = WinHttpOpen(L"ZjcInstaller/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return result;
    HINTERNET hConnect = WinHttpConnect(hSession, host.c_str(), port, 0);
    if (!hConnect) { WinHttpCloseHandle(hSession); return result; }
    HINTERNET hReq = WinHttpOpenRequest(hConnect, L"GET", path.c_str(), NULL,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
        https ? WINHTTP_FLAG_SECURE : 0);
    if (!hReq) { WinHttpCloseHandle(hConnect); WinHttpCloseHandle(hSession); return result; }

    bool sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
        WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && WinHttpReceiveResponse(hReq, NULL);
    if (sent) {
        DWORD avail = 0;
        do {
            avail = 0;
            if (!WinHttpQueryDataAvailable(hReq, &avail) || avail == 0) break;
            QByteArray chunk(static_cast<int>(avail), Qt::Uninitialized);
            DWORD read = 0;
            if (WinHttpReadData(hReq, chunk.data(), avail, &read) && read > 0) {
                result.append(chunk.constData(), static_cast<int>(read));
            }
        } while (avail > 0);
        if (ok) *ok = true;
    }
    WinHttpCloseHandle(hReq);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return result;
}

// ---- 下载文件到 destPath ----
bool httpDownload(const QUrl &url, const QString &destPath) {
    bool ok = false;
    QByteArray data = httpGet(url, &ok);
    if (!ok || data.isEmpty()) return false;
    QFile f(destPath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    const qint64 n = f.write(data);
    f.close();
    return n == data.size();
}

// ---- WinHTTP 同步 POST JSON（上报，失败不影响主流程） ----
void httpPostJson(const QUrl &url, const QByteArray &body) {
    const bool https = (url.scheme().compare("https", Qt::CaseInsensitive) == 0);
    const std::wstring host = url.host().toStdWString();
    INTERNET_PORT port = (INTERNET_PORT)(url.port(https ? 443 : 80));
    const std::wstring path = (url.path().isEmpty() ? QString("/") : url.path()).toStdWString();

    HINTERNET hSession = WinHttpOpen(L"ZjcInstaller/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return;
    HINTERNET hConnect = WinHttpConnect(hSession, host.c_str(), port, 0);
    if (!hConnect) { WinHttpCloseHandle(hSession); return; }
    HINTERNET hReq = WinHttpOpenRequest(hConnect, L"POST", path.c_str(), NULL,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, https ? WINHTTP_FLAG_SECURE : 0);
    if (hReq) {
        const wchar_t *hdr = L"Content-Type: application/json\r\n";
        WinHttpSendRequest(hReq, hdr, (DWORD)-1L,
            (LPVOID)body.constData(), (DWORD)body.size(), (DWORD)body.size(), 0);
        WinHttpReceiveResponse(hReq, NULL);
        WinHttpCloseHandle(hReq);
    }
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
}

QString programDataZjcDir() {
    wchar_t buf[MAX_PATH];
    ExpandEnvironmentStringsW(L"%ProgramData%\\zjc_worker", buf, MAX_PATH);
    return QString::fromWCharArray(buf);
}

// 本地已装版本（读 %ProgramData%\zjc_worker\zjc_worker.version），无则空
QString localInstalledVersion() {
    QFile f(programDataZjcDir() + "/zjc_worker.version");
    if (!f.open(QIODevice::ReadOnly)) return QString();
    QString v = QString::fromUtf8(f.readAll()).trimmed();
    f.close();
    return v;
}

bool serviceInstalled() {
    bool installed = false;
    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (scm) {
        SC_HANDLE svc = OpenServiceW(scm, L"zjc_worker", SERVICE_QUERY_STATUS);
        if (svc) { installed = true; CloseServiceHandle(svc); }
        CloseServiceHandle(scm);
    }
    return installed;
}

// ⭐ 2026-08-08：服务是否**真的在运行**（SCM 里注册 ≠ 进程活着）。
//   serviceInstalled() 只看注册项，安装/卸载校验用它是对的；但升级判定必须看运行态，
//   否则"注册着但进程早死了"的实例会被当成可用而永远拿不到新版本。
bool serviceRunning() {
    bool running = false;
    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (scm) {
        SC_HANDLE svc = OpenServiceW(scm, L"zjc_worker", SERVICE_QUERY_STATUS);
        if (svc) {
            SERVICE_STATUS st{};
            if (QueryServiceStatus(svc, &st))
                running = (st.dwCurrentState == SERVICE_RUNNING || st.dwCurrentState == SERVICE_START_PENDING);
            CloseServiceHandle(svc);
        }
        CloseServiceHandle(scm);
    }
    return running;
}

// ⭐ 2026-08-01：语义版本比较——a 是否严格低于 b（"1.0.0" < "1.0.1"）。
//   逐段数字比较，缺段按 0；非数字/空按 0。用于把"字符串不等就重装"改成"只在真的更旧才升级"，
//   从根上消灭"老子进程无版本号(空串) != 服务器版本 → 每次登录都重装"的抖动。
bool versionOlder(const QString &a, const QString &b) {
    const QStringList pa = a.split('.'); const QStringList pb = b.split('.');
    const int n = qMax(pa.size(), pb.size());
    for (int i = 0; i < n; ++i) {
        const int va = (i < pa.size()) ? pa[i].trimmed().toInt() : 0;
        const int vb = (i < pb.size()) ? pb[i].trimmed().toInt() : 0;
        if (va != vb) return va < vb;
    }
    return false; // 相等
}

// 提权运行 dl\zjc_worker.exe --install，等待其写出 version 文件确认
bool runInstall(const QString &exePath, const QString &expectVersion) {
    const std::wstring wExe = QDir::toNativeSeparators(exePath).toStdWString();
    SHELLEXECUTEINFOW sei; ZeroMemory(&sei, sizeof(sei));
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";               // 触发 UAC，服务注册需管理员
    sei.lpFile = wExe.c_str();
    sei.lpParameters = L"--install";
    sei.nShow = SW_HIDE;
    if (!ShellExecuteExW(&sei)) {
        zjcLog(QString("ShellExecuteEx(runas --install) 失败 err=%1（用户拒绝UAC？）").arg(GetLastError()));
        return false;
    }
    if (sei.hProcess) {
        WaitForSingleObject(sei.hProcess, 30000);
        CloseHandle(sei.hProcess);
    } else {
        Sleep(5000);
    }
    // 确认：服务已装 且 版本文件已更新为期望版本
    const QString got = localInstalledVersion();
    const bool ok = serviceInstalled() && (expectVersion.isEmpty() || got == expectVersion);
    zjcLog(QString("安装后校验: serviceInstalled=%1 localVersion=%2 expect=%3 → %4")
           .arg(serviceInstalled()).arg(got, expectVersion).arg(ok ? "成功" : "失败"));
    return ok;
}

// ⭐ 2026-07-11：AI 编程工具检测（注册表卸载项 + 进程名 + 常见安装目录），进程内缓存。
struct AiToolProbe { const wchar_t *display; const wchar_t *proc; const wchar_t *dirEnv; const wchar_t *dirSuffix; };

static bool regUninstallHasAny(HKEY root, const wchar_t *subkey, const std::vector<std::wstring> &needles) {
    HKEY hKey;
    if (RegOpenKeyExW(root, subkey, 0, KEY_READ | KEY_WOW64_64KEY, &hKey) != ERROR_SUCCESS) return false;
    bool found = false;
    DWORD idx = 0; wchar_t name[512];
    while (!found) {
        DWORD nlen = 512;
        if (RegEnumKeyExW(hKey, idx++, name, &nlen, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
        HKEY sub;
        if (RegOpenKeyExW(hKey, name, 0, KEY_READ, &sub) == ERROR_SUCCESS) {
            wchar_t disp[512]; DWORD dsize = sizeof(disp); DWORD type = 0;
            if (RegQueryValueExW(sub, L"DisplayName", NULL, &type, (LPBYTE)disp, &dsize) == ERROR_SUCCESS && type == REG_SZ) {
                std::wstring d(disp);
                for (auto &c : d) c = towlower(c);
                for (const auto &nd : needles) { if (d.find(nd) != std::wstring::npos) { found = true; break; } }
            }
            RegCloseKey(sub);
        }
    }
    RegCloseKey(hKey);
    return found;
}

static bool processRunning(const wchar_t *exeName) {
    // 用 WTSEnumerateProcesses 太重；简单用 CreateToolhelp32Snapshot
    bool found = false;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W pe; pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) {
            do {
                if (_wcsicmp(pe.szExeFile, exeName) == 0) { found = true; break; }
            } while (Process32NextW(snap, &pe));
        }
        CloseHandle(snap);
    }
    return found;
}

static bool dirExists(const wchar_t *env, const wchar_t *suffix) {
    wchar_t base[MAX_PATH];
    if (ExpandEnvironmentStringsW(env, base, MAX_PATH) == 0) return false;
    std::wstring path = std::wstring(base) + suffix;
    DWORD attr = GetFileAttributesW(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
}

bool detectAiCodingToolsImpl(QString *toolsCsvOut) {
    static bool cached = false;
    static bool cachedResult = false;
    static QString cachedTools;
    if (cached) { if (toolsCsvOut) *toolsCsvOut = cachedTools; return cachedResult; }

    QStringList hits;
    // 注册表卸载项 DisplayName 关键词（小写）
    const std::vector<std::wstring> needles = {
        L"cursor", L"visual studio code", L"vs code", L"windsurf", L"claude", L"codex", L"github copilot"
    };
    const wchar_t *uninstallKeys[] = {
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
        L"Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall"
    };
    QStringList regNames = { "Cursor", "VSCode", "Windsurf", "Claude", "Codex", "Copilot" };
    bool regHit = false;
    if (regUninstallHasAny(HKEY_LOCAL_MACHINE, uninstallKeys[0], needles)
        || regUninstallHasAny(HKEY_LOCAL_MACHINE, uninstallKeys[1], needles)
        || regUninstallHasAny(HKEY_CURRENT_USER, uninstallKeys[0], needles)) {
        regHit = true;
        hits << "已安装程序";
    }

    // 进程名
    struct { const wchar_t *proc; const char *label; } procs[] = {
        { L"Cursor.exe", "Cursor" }, { L"Code.exe", "VSCode" }, { L"windsurf.exe", "Windsurf" },
        { L"Claude.exe", "Claude" }, { L"codex.exe", "Codex" }
    };
    for (auto &p : procs) {
        if (processRunning(p.proc)) hits << QString("进程:") + p.label;
    }

    // 常见安装目录
    struct { const wchar_t *env; const wchar_t *suffix; const char *label; } dirs[] = {
        { L"%LOCALAPPDATA%", L"\\Programs\\cursor",                 "Cursor目录" },
        { L"%LOCALAPPDATA%", L"\\Programs\\Microsoft VS Code",      "VSCode目录" },
        { L"%LOCALAPPDATA%", L"\\Programs\\Windsurf",               "Windsurf目录" },
        { L"%LOCALAPPDATA%", L"\\Programs\\claude",                 "Claude目录" },
        { L"%LOCALAPPDATA%", L"\\Programs\\@anthropic-ai",          "Claude目录" },
        { L"%USERPROFILE%",  L"\\.codex",                           "Codex目录" }
    };
    for (auto &d : dirs) {
        if (dirExists(d.env, d.suffix)) hits << QString::fromUtf8(d.label);
    }

    Q_UNUSED(regHit);
    cachedResult = !hits.isEmpty();   // 注册表/进程/目录 命中任一即判定
    cachedTools = hits.join(",");
    cached = true;
    if (toolsCsvOut) *toolsCsvOut = cachedTools;
    zjcLog(QString("AI编程工具检测: %1 (命中: %2)")
           .arg(cachedResult ? "是" : "否").arg(cachedTools.isEmpty() ? "无" : cachedTools));
    return cachedResult;
}

// 提权运行 dl\zjc_worker.exe --uninstall（卸载服务，需管理员）
bool runUninstall(const QString &exePath) {
    const std::wstring wExe = QDir::toNativeSeparators(exePath).toStdWString();
    SHELLEXECUTEINFOW sei; ZeroMemory(&sei, sizeof(sei));
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = wExe.c_str();
    sei.lpParameters = L"--uninstall";
    sei.nShow = SW_HIDE;
    if (!ShellExecuteExW(&sei)) {
        zjcLog(QString("ShellExecuteEx(runas --uninstall) 失败 err=%1").arg(GetLastError()));
        return false;
    }
    if (sei.hProcess) { WaitForSingleObject(sei.hProcess, 30000); CloseHandle(sei.hProcess); }
    else Sleep(3000);
    const bool ok = !serviceInstalled();
    zjcLog(QString("卸载后校验: serviceInstalled=%1 → %2").arg(serviceInstalled()).arg(ok ? "成功" : "失败"));
    return ok;
}

void reportStatus(const QString &baseUrl, const QString &pcDeviceId,
                  const QString &version, bool installed, const QString &error,
                  bool aiToolsDetected = false, const QString &aiTools = QString(),
                  bool uninstalled = false) {
    QJsonObject obj;
    obj["pcDeviceId"]      = pcDeviceId;
    obj["version"]         = version;
    obj["installed"]       = installed;
    obj["error"]           = error;
    obj["aiToolsDetected"] = aiToolsDetected;
    obj["aiTools"]         = aiTools;
    obj["uninstalled"]     = uninstalled;
    const QByteArray body = QJsonDocument(obj).toJson(QJsonDocument::Compact);
    httpPostJson(QUrl(baseUrl + "/api/zjc/report"), body);
    zjcLog(QString("已上报: installed=%1 aiTools=%2 uninstalled=%3 version=%4 %5")
           .arg(installed).arg(aiToolsDetected).arg(uninstalled).arg(version, error.isEmpty() ? "" : ("error=" + error)));
}

void worker(QString baseUrl, QString pcDeviceId) {
    zjcLog(QString("检查 zjc_worker 安装状态 baseUrl=%1 pcDeviceId=%2").arg(baseUrl, pcDeviceId));

    // 1) 查服务器最新版本 + 文件清单（带 pcDeviceId，服务器据此返回是否需要卸载）
    bool ok = false;
    const QByteArray resp = httpGet(QUrl(baseUrl + "/api/zjc/latest?pcDeviceId=" + QUrl::toPercentEncoding(pcDeviceId)), &ok);
    if (!ok || resp.isEmpty()) {
        zjcLog("查询 /api/zjc/latest 失败（网络？），跳过本次安装检查");
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(resp).object();
    const QString serverVersion = root.value("version").toString();
    const QJsonArray files = root.value("files").toArray();
    const bool wantUninstall = root.value("uninstall").toBool(false);

    // ⭐ 2026-07-11：总后台标记卸载 → 优先执行卸载（高于安装），并回执 uninstalled=true 让后台清标记
    if (wantUninstall) {
        zjcLog("总后台标记卸载 → 执行 zjc_worker --uninstall");
        QString exe = programDataZjcDir() + "/zjc_worker.exe";
        if (!QFile::exists(exe)) exe = programDataZjcDir() + "/dl/zjc_worker.exe";
        bool uok = false;
        if (serviceInstalled() && QFile::exists(exe)) {
            uok = runUninstall(exe);
        } else {
            uok = !serviceInstalled();  // 本来就没装 = 视为已卸
            zjcLog("卸载：服务未安装或找不到 exe，视为已卸载");
        }
        reportStatus(baseUrl, pcDeviceId, localInstalledVersion(), serviceInstalled(),
                     uok ? QString() : QString("卸载失败（UAC拒绝/找不到exe）"),
                     false, QString(), uok);
        return;
    }

    // ⭐ 2026-07-11：本机装了主流 AI 编程工具 → 不安装 zjc_worker（并上报，供总后台展示 + 该机 fps 锁 30）
    QString aiTools;
    if (ZjcInstaller::detectAiCodingTools(&aiTools)) {
        zjcLog(QString("检测到 AI 编程工具（%1）→ 跳过安装 zjc_worker").arg(aiTools));
        reportStatus(baseUrl, pcDeviceId, localInstalledVersion(), serviceInstalled(),
                     QString("本机含AI编程工具，已跳过安装"), true, aiTools, false);
        return;
    }

    if (serverVersion.isEmpty() || files.isEmpty()) {
        zjcLog(QString("服务器未配置 zjc_worker 下发（version/files 为空），跳过。resp=%1")
               .arg(QString::fromUtf8(resp.left(200))));
        return;
    }

    // 2) 与本地已装版本比对
    // ⭐⭐ 2026-08-01 根治"子进程反复被停/重装"（用户实测每天十几次"莫名断"）：
    //   旧逻辑是**字符串相等**判定——`installed && localVer == serverVersion` 才跳过。
    //   但**大量老子进程根本不写 zjc_worker.version 文件，localVer 恒为空**，空串永远 != 服务器版本，
    //   于是每次 Phoenix 登录都判"需要重装"→ sc stop→重装→sc start → 服务反复停起。
    //   新逻辑：服务已安装时，只有"**本地版本真的更旧**"或"总后台**强制重装**"才升级；
    //   老子进程(空版本)一律视为可用、跳过重装（服务在跑就别折腾）。要强推新版走 forceReinstall。
    const QString localVer = localInstalledVersion();
    const bool installed = serviceInstalled();
    const bool forceReinstall = root.value("forceReinstall").toBool(false);
    // ⭐⭐ 2026-08-08 补漏：上面"空版本号一律跳过"只在**服务真的在跑**时才成立。
    //   最早那批客户的子进程不写版本号，一旦进程死掉，SCM 里仍留着注册项 →
    //   installed=true + localVer 为空 → 直接跳过 → 新版永远装不上、也覆盖不了，服务就一直死着。
    //   现在改为：注册但未运行 = 需要修复，落到下面的下载+重装流程（--install 会先停旧服务再覆盖文件并启动）。
    if (installed && !forceReinstall) {
        if (!serviceRunning()) {
            zjcLog(QString("⚠️ 服务已注册但当前未运行(子进程已死, ver=%1) → 走重装自愈")
                   .arg(localVer.isEmpty() ? "无" : localVer));
        } else if (localVer.isEmpty()) {
            // 老子进程无版本号且服务在跑：认为可用，**绝不重装**（这正是反复断的元凶）。
            zjcLog("服务在运行但无本地版本号(老子进程)→ 视为可用，跳过重装（避免每次登录反复停/装服务）");
            reportStatus(baseUrl, pcDeviceId, localVer, true, QString());
            return;
        } else if (!versionOlder(localVer, serverVersion)) {
            zjcLog(QString("本地版本 %1 不低于服务器 %2，无需重装").arg(localVer, serverVersion));
            reportStatus(baseUrl, pcDeviceId, localVer, true, QString());
            return;
        }
    }
    zjcLog(QString("需要安装/更新: 本地已装=%1(ver=%2) 服务器ver=%3 强制=%4")
           .arg(installed).arg(localVer.isEmpty() ? "无" : localVer, serverVersion).arg(forceReinstall));

    // 3) 下载文件到 %ProgramData%\zjc_worker\dl 目录
    const QString dlDir = programDataZjcDir() + "/dl";
    QDir().mkpath(dlDir);
    QString exePath;
    bool allDownloaded = true;
    QString dlError;
    for (const QJsonValue &v : files) {
        const QJsonObject fo = v.toObject();
        const QString name = fo.value("name").toString();
        const QString fileUrl = fo.value("url").toString();
        if (name.isEmpty() || fileUrl.isEmpty()) continue;
        const QString dest = dlDir + "/" + name;
        if (!httpDownload(QUrl(fileUrl), dest)) {
            allDownloaded = false;
            dlError = "下载失败: " + name;
            zjcLog(dlError + " url=" + fileUrl);
            break;
        }
        zjcLog("已下载 " + name);
        if (name.compare("zjc_worker.exe", Qt::CaseInsensitive) == 0) exePath = dest;
    }

    if (!allDownloaded || exePath.isEmpty()) {
        if (exePath.isEmpty() && dlError.isEmpty()) dlError = "文件清单缺少 zjc_worker.exe";
        reportStatus(baseUrl, pcDeviceId, serverVersion, false, dlError);
        return;
    }

    // 4) 提权安装（--install 会把 dl 目录里的文件复制到 %ProgramData%/zjc_worker 并注册服务）
    const bool instOk = runInstall(exePath, serverVersion);

    // 5) 上报结果
    reportStatus(baseUrl, pcDeviceId, serverVersion, instOk,
                 instOk ? QString() : QString("安装失败（服务未注册/UAC拒绝/版本文件未写）"));
}

#endif // Q_OS_WIN

} // namespace

namespace ZjcInstaller {

void ensureInstalledAsync(const QString &baseUrl, const QString &pcDeviceId) {
#ifdef Q_OS_WIN
    if (baseUrl.isEmpty()) return;
    bool expected = false;
    if (!g_started.compare_exchange_strong(expected, true)) return; // 幂等：只跑一次
    std::thread(worker, baseUrl, pcDeviceId).detach();
#else
    Q_UNUSED(baseUrl); Q_UNUSED(pcDeviceId);
#endif
}

bool detectAiCodingTools(QString *toolsCsvOut) {
#ifdef Q_OS_WIN
    return detectAiCodingToolsImpl(toolsCsvOut);
#else
    if (toolsCsvOut) *toolsCsvOut = QString();
    return false;
#endif
}

} // namespace ZjcInstaller
