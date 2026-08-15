#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QIcon>
#include <QFile>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QMutex>
#include <QWaitCondition>
#include <QDeadlineTimer>
#include <QTimer>
#include <QTextStream>
#include <thread>
#include <utility>
#include <atomic>
#include <chrono>
#ifdef Q_OS_WIN
#include <windows.h>
#include <tlhelp32.h>
#include <shellapi.h>
#endif
#include "videoplayer.h"
// #include "webrtcclient.h"  // ⭐ 废弃，改用 GstPlayer WebRTCBin
#include "capturemanager.h"
#include "slowmotionplayer.h"
#include "imageprovider.h"
#include "eventbus.h"
#include "gpupipeline.h"
#include "gstplayer.h"
#include "httpclient.h"
#include "websocketclient.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include "shortcutstore.h"
#include "qrcodegenerator.h"
#include "autoupdater.h"
#include "p2ploguploader.h"

// ⭐ Qt WebEngine（Chromium 内核）—— 仅当 CMake 检测到 WebEngine 时启用（HAVE_WEBENGINE）
#ifdef HAVE_WEBENGINE
#include <QtWebEngineQuick/QtWebEngineQuick>
#include "kernelbridge.h"
#include "webframesource.h"   // ⭐ 网页内核截图/慢放帧源
#endif

// GStreamer
#include <gst/gst.h>

// 全局日志文件
static QFile *g_logFile = nullptr;

// ⭐ §23.11 P0-2：phoenix 日志写盘异步化。
//   旧实现在调用线程（多为 GUI 主线程）同步 write+flush——磁盘忙时（恰逢 H264 支路
//   每 12s 的大块写盘）一次 flush 可挂主线程近 1 秒，就是「渲=0 队列堆 30+」的冻结源。
//   现 handler 只把行推入内存队列立即返回，后台专职线程批量写文件+flush。
static QMutex g_logQueueMutex;
static QWaitCondition g_logQueueCond;
static QStringList g_logQueue;
static bool g_logThreadStop = false;
static std::thread *g_logThread = nullptr;

// 后台日志写线程：批量取队列 → 写 stderr + 文件（磁盘阻塞只影响本线程）
static void logWriterLoop()
{
    for (;;) {
        QStringList batch;
        {
            QMutexLocker lock(&g_logQueueMutex);
            while (g_logQueue.isEmpty() && !g_logThreadStop) {
                g_logQueueCond.wait(&g_logQueueMutex, QDeadlineTimer(200));
            }
            batch.swap(g_logQueue);
            if (batch.isEmpty() && g_logThreadStop) {
                return;
            }
        }
        QByteArray blob;
        blob.reserve(batch.size() * 128);
        for (const QString &line : std::as_const(batch)) {
            blob += line.toUtf8();
        }
        fwrite(blob.constData(), 1, static_cast<size_t>(blob.size()), stderr);
        fflush(stderr);
        if (g_logFile && g_logFile->isOpen()) {
            g_logFile->write(blob);
            g_logFile->flush();
        }
    }
}

static void startLogWriterThread()
{
    if (!g_logThread) {
        g_logThreadStop = false;
        g_logThread = new std::thread(logWriterLoop);
    }
}

// 停止日志线程并冲刷剩余日志（程序退出/Fatal 前调用）
static void stopLogWriterThread()
{
    if (!g_logThread) return;
    {
        QMutexLocker lock(&g_logQueueMutex);
        g_logThreadStop = true;
    }
    g_logQueueCond.wakeAll();
    g_logThread->join();
    delete g_logThread;
    g_logThread = nullptr;
}

// 自定义日志处理函数 - 入队即返回（不在调用线程碰磁盘）
void customMessageHandler(QtMsgType type, const QMessageLogContext &context, const QString &msg)
{
    QString timestamp = QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss.zzz");
    QString typeStr;
    
    switch (type) {
        case QtDebugMsg:    typeStr = "DEBUG"; break;
        case QtInfoMsg:     typeStr = "INFO "; break;
        case QtWarningMsg:  typeStr = "WARN "; break;
        case QtCriticalMsg: typeStr = "ERROR"; break;
        case QtFatalMsg:    typeStr = "FATAL"; break;
    }
    
    QString logLine = QString("[%1] [%2] %3\n").arg(timestamp, typeStr, msg);
    
    {
        QMutexLocker lock(&g_logQueueMutex);
        g_logQueue.append(logLine);
    }
    g_logQueueCond.wakeOne();
    
    // Fatal：排干队列（后台线程负责真正落盘）后中止
    if (type == QtFatalMsg) {
        stopLogWriterThread();
        abort();
    }
}

// ⭐ §23.12 冻结取证看门狗：把「渲=0 主线程冻结」的来源一锤定音。
//   三件套：主线程 100ms 心跳（QTimer 写原子时间戳）+ 后台纯睡眠参照线程（不碰磁盘/锁）
//   + 看门狗线程。主线程心跳断 >500ms = 冻结；恢复后比对参照线程同窗是否也停：
//   都停 = 整机/整进程停顿（磁盘IO风暴/杀毒/远控/换页，应用代码无关）；
//   只有主线程停 = 应用内同步阻塞（需进一步抓主线程栈）。
//   结果写 freeze_diag.txt（Append）+ qWarning + P2P 日志上报。
static std::atomic<qint64> g_mainHeartbeatMs{0};
static std::atomic<qint64> g_refHeartbeatMs{0};
static std::atomic<bool> g_watchdogStop{false};
static std::thread *g_refThread = nullptr;
static std::thread *g_watchdogThread = nullptr;

void updateMainHeartbeat()
{
    g_mainHeartbeatMs.store(QDateTime::currentMSecsSinceEpoch());
}

#ifdef Q_OS_WIN
// ⭐ §23.13 冻结时主线程栈捕获（定位「应用内同步调用堵主线程」的具体函数）。
//   安全套路：SuspendThread → GetThreadContext → 仅 memcpy 拷 RSP 起 32KB 栈内存 → ResumeThread。
//   挂起窗口内零分配/零锁（若在挂起窗口调 dbghelp/malloc，对方若正持堆锁会整程序死锁）；
//   符号解析放在恢复之后离线做（dbghelp 只在看门狗线程用，天然串行）。
#include <dbghelp.h>
#pragma comment(lib, "dbghelp.lib")

static HANDLE g_mainThreadHandle = nullptr;   // 主线程句柄（main() 里 DuplicateHandle 得到）
static constexpr int STACK_SNAP_BYTES = 32 * 1024;
static quint8 g_stackSnapBuf[STACK_SNAP_BYTES];
static DWORD64 g_snapRip = 0, g_snapRsp = 0;
static int g_snapBytes = 0;
static bool g_snapValid = false;

// 挂起主线程拍一份原始栈（只 memcpy，不解析）。
static void captureMainThreadStackRaw()
{
    g_snapValid = false;
    if (!g_mainThreadHandle) return;
    if (SuspendThread(g_mainThreadHandle) == (DWORD)-1) return;

    CONTEXT ctx;
    ZeroMemory(&ctx, sizeof(ctx));
    ctx.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
    if (GetThreadContext(g_mainThreadHandle, &ctx)) {
#ifdef _M_X64
        g_snapRip = ctx.Rip;
        g_snapRsp = ctx.Rsp;
#else
        g_snapRip = ctx.Eip;
        g_snapRsp = ctx.Esp;
#endif
        // 用 VirtualQuery 夹取可读范围后 memcpy（栈顶向高地址方向拷）
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T want = STACK_SNAP_BYTES;
        if (VirtualQuery(reinterpret_cast<LPCVOID>(g_snapRsp), &mbi, sizeof(mbi)) == sizeof(mbi)
            && (mbi.State & MEM_COMMIT)) {
            const DWORD64 regionEnd = reinterpret_cast<DWORD64>(mbi.BaseAddress) + mbi.RegionSize;
            const DWORD64 avail = regionEnd > g_snapRsp ? (regionEnd - g_snapRsp) : 0;
            if (avail < want) want = static_cast<SIZE_T>(avail);
            if (want > 0) {
                memcpy(g_stackSnapBuf, reinterpret_cast<const void*>(g_snapRsp), want);
                g_snapBytes = static_cast<int>(want);
                g_snapValid = true;
            }
        }
    }
    ResumeThread(g_mainThreadHandle);
}

// 恢复后离线解析快照：RIP + 栈里疑似返回地址（落在任意已加载模块代码里的 qword）。
static QString resolveFrozenStack()
{
    if (!g_snapValid) return QStringLiteral("(栈快照捕获失败)");

    static bool symInited = false;
    if (!symInited) {
        // SYMOPT_LOAD_LINES：Phoenix.pdb 在场时能给出 源文件:行号（§23.14）
        SymSetOptions(SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME | SYMOPT_LOAD_LINES);
        SymInitialize(GetCurrentProcess(), nullptr, TRUE);
        symInited = true;
    }

    auto describe = [](DWORD64 addr) -> QString {
        // 模块名 + RVA
        HMODULE mod = nullptr;
        QString modStr = QStringLiteral("?");
        if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                               | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCWSTR>(addr), &mod) && mod) {
            wchar_t path[MAX_PATH];
            if (GetModuleFileNameW(mod, path, MAX_PATH)) {
                modStr = QFileInfo(QString::fromWCharArray(path)).fileName();
            }
            modStr += QString("+0x%1").arg(addr - reinterpret_cast<DWORD64>(mod), 0, 16);
        } else {
            return QString();  // 不在任何模块内 → 不是代码地址
        }
        // 符号名（系统/Qt DLL 有导出符号；Phoenix.exe 需 PDB 在 exe 同级）。
        // §23.14 修复：必须用显式 W 版——UNICODE 工程里 SymFromAddr 可能映射到宽版，
        // 返回 UTF-16 却按 char* 读会在第 2 字节(0) 截断，符号只剩首字母（Z/W/Q/N/R）。
        alignas(SYMBOL_INFOW) char symBuf[sizeof(SYMBOL_INFOW) + 256 * sizeof(WCHAR)] = {};
        SYMBOL_INFOW *sym = reinterpret_cast<SYMBOL_INFOW*>(symBuf);
        sym->SizeOfStruct = sizeof(SYMBOL_INFOW);
        sym->MaxNameLen = 255;
        DWORD64 disp = 0;
        if (SymFromAddrW(GetCurrentProcess(), addr, &disp, sym)) {
            QString out = modStr + QStringLiteral("!") + QString::fromWCharArray(sym->Name)
                          + QString("+0x%1").arg(disp, 0, 16);
            // PDB 在场时补 源文件:行号（直接定位到函数内具体语句）
            IMAGEHLP_LINEW64 lineInfo;
            ZeroMemory(&lineInfo, sizeof(lineInfo));
            lineInfo.SizeOfStruct = sizeof(lineInfo);
            DWORD lineDisp = 0;
            if (SymGetLineFromAddrW64(GetCurrentProcess(), addr, &lineDisp, &lineInfo)) {
                out += QString(" [%1:%2]")
                       .arg(QFileInfo(QString::fromWCharArray(lineInfo.FileName)).fileName())
                       .arg(lineInfo.LineNumber);
            }
            return out;
        }
        return modStr;
    };

    QStringList frames;
    const QString ripDesc = describe(g_snapRip);
    frames << QStringLiteral("  [RIP] ") + (ripDesc.isEmpty() ? QString("0x%1(非模块)").arg(g_snapRip, 0, 16) : ripDesc);

    const int qwords = g_snapBytes / 8;
    const quint64 *stack = reinterpret_cast<const quint64*>(g_stackSnapBuf);
    int found = 0;
    for (int i = 0; i < qwords && found < 14; i++) {
        const quint64 v = stack[i];
        if (v < 0x10000 || v > 0x7FFFFFFFFFFFULL) continue;  // 明显不是用户态代码地址
        const QString d = describe(v);
        if (!d.isEmpty()) {
            frames << QStringLiteral("  [+0x") + QString::number(i * 8, 16) + QStringLiteral("] ") + d;
            found++;
        }
    }
    return frames.join(QStringLiteral("\n"));
}
#else
static void captureMainThreadStackRaw() {}
static QString resolveFrozenStack() { return QString(); }
#endif

static void freezeDiagWrite(const QString &line)
{
    static bool headerWritten = false;
    QFile f(QCoreApplication::applicationDirPath() + "/freeze_diag.txt");
    if (f.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        QTextStream ts(&f);
        if (!headerWritten) {
            ts << "\n===== [" << QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss")
               << "] 冻结取证会话开始（判定说明：后台心跳同窗也停=整机停顿；后台正常=应用内主线程阻塞）=====\n";
            headerWritten = true;
        }
        ts << line << "\n";
    }
}

static void startFreezeWatchdog()
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    g_mainHeartbeatMs.store(now);
    g_refHeartbeatMs.store(now);

    // 参照线程：只睡眠+写时间戳，不碰任何磁盘/锁。若它也停 = 整个进程被挂起。
    g_refThread = new std::thread([]() {
        while (!g_watchdogStop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            g_refHeartbeatMs.store(QDateTime::currentMSecsSinceEpoch());
        }
    });

    g_watchdogThread = new std::thread([]() {
        bool inFreeze = false;
        qint64 freezeStartMs = 0;
        qint64 maxRefGap = 0;
        qint64 maxSelfGap = 0;
        qint64 lastPoll = QDateTime::currentMSecsSinceEpoch();
        // §23.13：冻结期间的主线程栈样本（最多 3 份，间隔 ≥400ms）
        QStringList stackSamples;
        qint64 lastStackSampleMs = 0;
        while (!g_watchdogStop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            const qint64 pollNow = QDateTime::currentMSecsSinceEpoch();
            const qint64 selfGap = pollNow - lastPoll;
            lastPoll = pollNow;
            const qint64 mainAge = pollNow - g_mainHeartbeatMs.load();
            const qint64 refAge = pollNow - g_refHeartbeatMs.load();

            if (!inFreeze) {
                if (mainAge > 500) {
                    inFreeze = true;
                    freezeStartMs = g_mainHeartbeatMs.load();
                    maxRefGap = refAge;
                    maxSelfGap = selfGap;
                    stackSamples.clear();
                    // §23.13：立即拍第一份主线程栈（挂起→memcpy→恢复，解析在恢复后做）
                    captureMainThreadStackRaw();
                    stackSamples << resolveFrozenStack();
                    lastStackSampleMs = pollNow;
                }
            } else {
                maxRefGap = qMax(maxRefGap, refAge);
                maxSelfGap = qMax(maxSelfGap, selfGap);
                if (mainAge >= 300 && stackSamples.size() < 3
                    && pollNow - lastStackSampleMs >= 400) {
                    captureMainThreadStackRaw();
                    stackSamples << resolveFrozenStack();
                    lastStackSampleMs = pollNow;
                }
                if (mainAge < 300) {
                    // 冻结结束，出报告
                    inFreeze = false;
                    const qint64 durMs = pollNow - freezeStartMs;
                    const bool wholeProcess = (maxRefGap > 400 || maxSelfGap > 400);
                    const QString verdict = wholeProcess
                        ? QStringLiteral("整机/整进程停顿(后台线程同窗也停) → 查磁盘IO风暴/杀毒扫描/远控软件/内存换页，与应用代码无关")
                        : QStringLiteral("仅主线程阻塞(后台线程正常) → 应用内同步调用堵住主线程");
                    QString line = QString("[%1] 主线程冻结 %2ms | 后台心跳最大间隔=%3ms 看门狗自身最大间隔=%4ms | 判定: %5")
                        .arg(QDateTime::currentDateTime().toString("hh:mm:ss.zzz"))
                        .arg(durMs).arg(maxRefGap).arg(maxSelfGap).arg(verdict);
                    for (int s = 0; s < stackSamples.size(); s++) {
                        line += QString("\n  --- 冻结时主线程栈样本 #%1 ---\n%2")
                            .arg(s + 1).arg(stackSamples[s]);
                    }
                    freezeDiagWrite(line);
                    qWarning().noquote() << "🧊 [freeze]" << line;
                    P2PLogUploader::instance()->append(QStringLiteral("pc-gstream-p2p"),
                                                       QStringLiteral("[freeze] ") + line);
                    stackSamples.clear();
                }
            }
        }
    });
}

static void stopFreezeWatchdog()
{
    g_watchdogStop.store(true);
    if (g_refThread) { g_refThread->join(); delete g_refThread; g_refThread = nullptr; }
    if (g_watchdogThread) { g_watchdogThread->join(); delete g_watchdogThread; g_watchdogThread = nullptr; }
}

// ⭐ 清理 frames 目录（启动、退出、切换账号时调用）
void clearFramesDirectory()
{
    QString framesDir = QCoreApplication::applicationDirPath() + "/captures/frames";
    QDir dir(framesDir);
    
    if (!dir.exists()) {
        qDebug() << "🗑️ frames 目录不存在，无需清理";
        return;
    }
    
    QStringList files = dir.entryList(QStringList() << "*.jpg" << "*.jpeg" << "*.h264", QDir::Files);
    int count = files.count();
    
    for (const QString &file : files) {
        dir.remove(file);
    }
    
    qDebug() << "🗑️ 清理 frames 目录:" << framesDir << "删除" << count << "个文件";
}

// ⭐ 早期诊断日志（Qt 日志系统初始化前使用）
static QFile *g_earlyLogFile = nullptr;

void earlyLog(const char *msg) {
    fprintf(stderr, "%s\n", msg);
    fflush(stderr);
    if (g_earlyLogFile && g_earlyLogFile->isOpen()) {
        g_earlyLogFile->write(msg);
        g_earlyLogFile->write("\n");
        g_earlyLogFile->flush();
    }
}

int main(int argc, char *argv[])
{
    // ⭐ 设置 GStreamer 环境变量（必须在 gst_init 之前）
    // 优先使用应用目录的 runtime/gstreamer，否则使用 C 盘安装
    QString appDir;
    {
        // Windows: 使用 GetModuleFileName 获取精确路径
        #ifdef Q_OS_WIN
        wchar_t path[MAX_PATH];
        GetModuleFileNameW(NULL, path, MAX_PATH);
        appDir = QFileInfo(QString::fromWCharArray(path)).absolutePath();
        #else
        appDir = QFileInfo(QString::fromLocal8Bit(argv[0])).absolutePath();
        #endif
    }
    
    // ⭐ 创建早期诊断日志文件（写入到应用目录）
    g_earlyLogFile = new QFile(appDir + "/gst_bootstrap.log");
    g_earlyLogFile->open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text);
    
    QString gstRoot;
    
    // 检查本地 GStreamer（发布版本）
    QString localGst = appDir + "/runtime/gstreamer";
    QString localBin = localGst + "/bin";
    bool hasLocalGst = QDir(localBin).exists();
    
    // 诊断输出（同时写入 stderr 和 gst_bootstrap.log）
    earlyLog(QString("[GStreamer] appDir: %1").arg(appDir).toUtf8().constData());
    earlyLog(QString("[GStreamer] checking: %1").arg(localBin).toUtf8().constData());
    earlyLog(QString("[GStreamer] localBin exists: %1").arg(hasLocalGst ? "YES" : "NO").toUtf8().constData());
    
    if (hasLocalGst) {
        gstRoot = localGst;
        earlyLog(QString("[GStreamer] Using LOCAL: %1").arg(gstRoot).toUtf8().constData());
    } else {
        // 使用 C 盘安装（开发版本）
        gstRoot = "C:/Program Files/gstreamer/1.0/msvc_x86_64";
        earlyLog(QString("[GStreamer] Using SYSTEM: %1").arg(gstRoot).toUtf8().constData());
    }
    
    // ⭐⭐⭐ 关键！使用 Windows 原生路径格式（与 Java 版本一致）
    QString pluginPath = QDir::toNativeSeparators(gstRoot + "/lib/gstreamer-1.0");
    QString pluginScanner = QDir::toNativeSeparators(gstRoot + "/libexec/gstreamer-1.0/gst-plugin-scanner.exe");
    QString gstBin = QDir::toNativeSeparators(gstRoot + "/bin");
    QString gstLib = QDir::toNativeSeparators(gstRoot + "/lib");
    
    // ⭐⭐⭐ 关键！与 Java 版本一致：设置 GST_REGISTRY（插件缓存文件）
    // 使用用户目录下的缓存（与 Java 完全一致）
    QString registryPath = QDir::toNativeSeparators(
        QDir::homePath() + "/.gst-registry-1.0.bin"
    );
    
    qputenv("GST_PLUGIN_PATH", pluginPath.toLocal8Bit());
    qputenv("GST_PLUGIN_SYSTEM_PATH", pluginPath.toLocal8Bit());
    qputenv("GST_PLUGIN_SCANNER", pluginScanner.toLocal8Bit());
    qputenv("GST_REGISTRY", registryPath.toLocal8Bit());  // ⭐ 与 Java 一致
    
    // 添加 GStreamer bin 和 lib 到 PATH（插件依赖 DLL）
    // ⭐⭐⭐ 关键！bin 和 lib 都要添加到 PATH 最前面（与 Java 一致）
    QString currentPath = qEnvironmentVariable("PATH");
    qputenv("PATH", (gstBin + ";" + gstLib + ";" + currentPath).toLocal8Bit());
    
    // ⭐ 打印详细的环境变量诊断信息
    earlyLog(QString("[GStreamer] GST_PLUGIN_PATH: %1").arg(pluginPath).toUtf8().constData());
    earlyLog(QString("[GStreamer] GST_REGISTRY: %1").arg(registryPath).toUtf8().constData());
    earlyLog(QString("[GStreamer] PATH prepend: %1;%2").arg(gstBin, gstLib).toUtf8().constData());
    earlyLog(QString("[GStreamer] Plugin dir exists: %1").arg(QDir(pluginPath).exists() ? "YES" : "NO").toUtf8().constData());
    earlyLog(QString("[GStreamer] gstlibav.dll exists: %1").arg(QFile::exists(pluginPath + "\\gstlibav.dll") ? "YES" : "NO").toUtf8().constData());
    earlyLog(QString("[GStreamer] gstnvcodec.dll exists: %1").arg(QFile::exists(pluginPath + "\\gstnvcodec.dll") ? "YES" : "NO").toUtf8().constData());
    earlyLog(QString("[GStreamer] gstd3d11.dll exists: %1").arg(QFile::exists(pluginPath + "\\gstd3d11.dll") ? "YES" : "NO").toUtf8().constData());
    earlyLog(QString("[GStreamer] gst-plugin-scanner exists: %1").arg(QFile::exists(pluginScanner) ? "YES" : "NO").toUtf8().constData());
    earlyLog(QString("[GStreamer] gstBin dir exists: %1").arg(QDir(gstBin).exists() ? "YES" : "NO").toUtf8().constData());
    
    // ⭐ 删除旧的注册表缓存，强制重新扫描插件（解决缓存不一致问题）
    if (QFile::exists(registryPath)) {
        QFile::remove(registryPath);
        earlyLog("[GStreamer] Removed old registry cache, will rescan plugins");
    }
    
    // ⭐ 初始化 GStreamer（必须在 Qt 之前，否则太慢）
    earlyLog("[GStreamer] Calling gst_init()...");
    gst_init(&argc, &argv);
    earlyLog("[GStreamer] gst_init() completed.");
    
    // 关闭早期日志文件
    if (g_earlyLogFile) {
        g_earlyLogFile->close();
        delete g_earlyLogFile;
        g_earlyLogFile = nullptr;
    }
    
    // 设置 Qt Quick Controls 2 风格为 Fusion，避免原生风格自定义警告
    QQuickStyle::setStyle("Fusion");

    // ⭐ Qt WebEngine（Chromium 内核）初始化 —— 必须在 QGuiApplication 之前。
    //   仅「内核测试」按钮会用到；未启用 WebEngine 编译时此段不存在，主程序不受影响。
#ifdef HAVE_WEBENGINE
    //   --disable-web-security：SRS WHEP 是 http 明文 + 跨域 fetch，浏览器默认会被 CORS/混合内容拦，
    //     竞品 CefSharp 直连无此限。测试场景关掉 Web 安全策略，确保只要网络通就能拉到流。
    //   --autoplay-policy：允许无用户手势自动播放（视频自动播）。
    //   --use-gl=angle / d3d11：尽量走硬件解码，降低 CPU（不影响画质）。
    //   --disable-features=WebRtcHideLocalIpsWithMdns：⭐ 关掉 Chromium 默认的 mDNS 本地 IP 隐藏。
    //     默认开启时，内核会把 host 候选的真实局域网 IP 藏成 xxxx.local mDNS 名；iOS/链路若解析不了该
    //     .local 名，host 候选就配不上对 → 退回 relay(TURN 中继)。这正是「同一局域网，内核走中继、
    //     GStreamer(无 mDNS) 走直连」的根因。关掉后内核暴露真实 host IP，与 GStreamer 一样直连优先。
    //   ⭐ GPU 硬件加速（治"网络好却画面顿住/PRESENT GAP + 主线程事件循环漂移"）：
    //     诊断确认顿在呈现层——1500ms 大缓冲、零丢包、freeze=0 仍有 PRESENT GAP，且连 1s STAT 定时器
    //     都漂到 1.8s，说明渲染进程/合成在 CPU 上扛不住。之前注释说要硬件解码但 flags 里没加，这里补上：
    //     --use-gl=angle + --use-angle=d3d11：ANGLE 走 D3D11，启用 GPU 合成（Windows 最稳的硬件后端）。
    //     --enable-gpu-rasterization + --enable-zero-copy：GPU 光栅化 + 零拷贝，减轻主线程/CPU。
    //     --enable-accelerated-video-decode + 相关 features：启用硬件视频解码（H.264 走 GPU，卸掉 CPU 解码）。
    //     --ignore-gpu-blocklist：Qt WebEngine 常因驱动在黑名单里回退软件渲染，强制启用 GPU。
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS",
            "--disable-web-security "
            "--autoplay-policy=no-user-gesture-required "
            "--ignore-certificate-errors "
            "--use-gl=angle "
            "--use-angle=d3d11 "
            "--ignore-gpu-blocklist "
            "--enable-gpu-rasterization "
            "--enable-zero-copy "
            "--enable-accelerated-video-decode "
            // ⭐ H265：Qt 6.10.3 的 WebEngine 是 Chromium 134（M136 才原生开 WebRTC H265）。
            //   M135 及以下按官方说法必须「两个参数同时给」：
            //   ① --enable-features=WebRtcAllowH265Receive（允许接收 H265）
            //   ② --force-fieldtrials=WebRTC-Video-H26xPacketBuffer/Enabled（H26x 包缓冲 field trial，
            //     缺它 H265 接收在 M134 不激活——2026-07-24 实测内核报「不支持 H265」的原因）。
            //   另需平台 HEVC 硬解（PlatformHEVCDecoderSupport + GPU）；不满足时协商回落 H264，
            //   webplayer_test.html 的 SRS H265 CHECK 日志可看 kernelSupportsH265 实际值。
            "--enable-features=D3D11VideoDecoder,AcceleratedVideoDecodeLinuxGL,PlatformHEVCDecoderSupport,WebRtcAllowH265Receive "
            "--force-fieldtrials=WebRTC-Video-H26xPacketBuffer/Enabled "
            "--disable-features=WebRtcHideLocalIpsWithMdns");
    QtWebEngineQuick::initialize();
    earlyLog("[WebEngine] QtWebEngineQuick::initialize() done");
#endif

    QGuiApplication app(argc, argv);
    
    // 设置应用程序信息（QML Settings 需要）
    app.setOrganizationName("Acard");
    app.setApplicationName("HuanJing");
    
    // ⭐ 初始化日志文件（保存到运行目录）
    // ⭐⭐⭐ 启动时清空所有日志文件
    QString appDirPath = QCoreApplication::applicationDirPath();
    // ⭐ 2026-08-14 aihj 品牌：主日志 phoenix_log.txt → huanjing_log.txt
    QString logPath = appDirPath + "/huanjing_log.txt";
    
    // 清空 yh.txt（统计日志）
    QFile yhFile(appDirPath + "/yh.txt");
    if (yhFile.exists()) {
        if (yhFile.open(QIODevice::WriteOnly | QIODevice::Truncate))
            yhFile.close();
    }
    
    // 清空 zp.txt（缩放日志）
    QFile zpFile(appDirPath + "/zp.txt");
    if (zpFile.exists()) {
        if (zpFile.open(QIODevice::WriteOnly | QIODevice::Truncate))
            zpFile.close();
    }

    // 清空 nh.txt（webview 内核「实时流/卡顿」诊断日志）
    QFile nhFile(appDirPath + "/nh.txt");
    if (nhFile.exists()) {
        if (nhFile.open(QIODevice::WriteOnly | QIODevice::Truncate))
            nhFile.close();
    }

    // ⭐ 启动时统一清空所有诊断日志 txt（推流复现卡顿前一键干净，只保留本次运行）。
    //   注意：只清 exe 同级目录下的诊断日志，白名单方式列全，避免误删 CMakeCache.txt 等构建产物。
    {
        const QStringList diagLogs = {
            // ai_zoom.txt 不清空：Append+会话分隔（低频识别失败的证据要跨重启保留）
            "capture_debug.txt",// GStreamer 截图/慢放链路计时
            "nack_diag.txt",    // NACK/重传诊断
            "p2p_diag.txt",     // P2P 信令/连接诊断
            "srs_diag.txt",     // SRS/WHEP 诊断
            "srt_diag.txt",     // SRT 诊断
            "sh.txt",           // 其它诊断
            "qlgx.txt"          // 其它诊断
        };
        for (const QString &name : diagLogs) {
            QFile df(appDirPath + "/" + name);
            if (df.exists() && df.open(QIODevice::WriteOnly | QIODevice::Truncate))
                df.close();
        }
    }
    
    // 清空 huanjing_log.txt（主日志）- 使用 Truncate 而非 Append
    g_logFile = new QFile(logPath);
    if (g_logFile->open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        qInstallMessageHandler(customMessageHandler);
        startLogWriterThread();  // §23.11 P0-2：日志落盘走后台线程
        
        // 写入启动信息
        QString startLine = QString("========== 程序启动 %1 ==========\n")
            .arg(QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss"));
        g_logFile->write(startLine.toUtf8());
        g_logFile->flush();
        
        qDebug() << "📄 日志文件已清空并重新创建:" << logPath;
        
        // ⭐ 打印 GStreamer 配置信息（日志系统已就绪）
        qDebug() << "🔧 GStreamer 根目录:" << gstRoot;
        qDebug() << "🔧 GStreamer 版本:" << gst_version_string();
        qDebug() << "🔧 GST_PLUGIN_PATH:" << qEnvironmentVariable("GST_PLUGIN_PATH");
        qDebug() << "🔧 GST_PLUGIN_SCANNER:" << qEnvironmentVariable("GST_PLUGIN_SCANNER");
        
        // 检查 d3d11h264dec 插件
        GstElementFactory *d3d11Factory = gst_element_factory_find("d3d11h264dec");
        if (d3d11Factory) {
            qDebug() << "✅ d3d11h264dec 插件可用（D3D11 硬件解码）";
            gst_object_unref(d3d11Factory);
        } else {
            qWarning() << "⚠️ d3d11h264dec 插件不可用";
        }
        
        // 检查 jpegenc 插件
        GstElementFactory *jpegFactory = gst_element_factory_find("jpegenc");
        if (jpegFactory) {
            qDebug() << "✅ jpegenc 插件可用（JPEG 编码）";
            gst_object_unref(jpegFactory);
        } else {
            qWarning() << "⚠️ jpegenc 插件不可用";
        }
        
        // ⭐ 检查 webrtcbin 插件（替代 libdatachannel）
        GstElementFactory *webrtcFactory = gst_element_factory_find("webrtcbin");
        if (webrtcFactory) {
            qDebug() << "✅ webrtcbin 插件可用（GStreamer WebRTC）";
            gst_object_unref(webrtcFactory);
        } else {
            qWarning() << "⚠️ webrtcbin 插件不可用，请检查 GStreamer gst-plugins-bad 安装";
        }
        
        // 检查 rtph264depay 插件
        GstElementFactory *depayFactory = gst_element_factory_find("rtph264depay");
        if (depayFactory) {
            qDebug() << "✅ rtph264depay 插件可用（RTP H264 解包）";
            gst_object_unref(depayFactory);
        } else {
            qWarning() << "⚠️ rtph264depay 插件不可用";
        }
        
        // ⭐ 启动时清理 frames 目录
        clearFramesDirectory();
    } else {
        qWarning() << "无法创建日志文件:" << logPath;
    }
    
    // 设置应用图标（任务栏和窗口标题栏）
    app.setWindowIcon(QIcon(":/qt/qml/Aifs/images/icon.png"));
    
    // 注册自定义 QML 类型
    qmlRegisterType<VideoPlayer>("Aifs.Components", 1, 0, "VideoPlayer");
    // ⭐ WebRTCClient 已废弃，改用 GstPlayer.connectWebRTC()
    // qmlRegisterType<WebRTCClient>("Aifs.Components", 1, 0, "WebRTCClient");
    qmlRegisterType<CaptureManager>("Aifs.Components", 1, 0, "CaptureManager");
    qmlRegisterType<SlowMotionPlayer>("Aifs.Components", 1, 0, "SlowMotionPlayer");
    
    // GPU 加速组件
    qmlRegisterType<GpuPipeline>("Aifs.Components", 1, 0, "GpuPipeline");
    qmlRegisterType<GpuVideoSink>("Aifs.Components", 1, 0, "GpuVideoSink");
    
    // GStreamer 播放器（通用硬解）
    qmlRegisterType<GstPlayer>("Aifs.Components", 1, 0, "GstPlayer");
    
    // 二维码生成器
    qmlRegisterType<QRCodeGenerator>("Aifs.Components", 1, 0, "QRCodeGenerator");
    
    // 注册 EventBus 单例
    qmlRegisterSingletonInstance("Aifs.Components", 1, 0, "EventBus", EventBus::instance());
    
    // 注册 HttpClient 单例
    qmlRegisterSingletonInstance("Aifs.Components", 1, 0, "HttpClient", HttpClient::instance());
    
    // 注册 WebSocketClient 单例
    qmlRegisterSingletonInstance("Aifs.Components", 1, 0, "WebSocketClient", WebSocketClient::instance());
    
    // 注册 ShortcutStore 单例（快捷键管理）
    qmlRegisterSingletonInstance("Aifs.Components", 1, 0, "ShortcutStore", ShortcutStore::instance());
    
    // 注册 AutoUpdater 单例（自动更新）
    qmlRegisterSingletonInstance("Aifs.Components", 1, 0, "AutoUpdater", AutoUpdater::instance());

    // 注册 P2PLogUploader 单例（P2P诊断日志上报，总后台开关控制，按推流ID分流）
    qmlRegisterSingletonInstance("Aifs.Components", 1, 0, "P2PLogUploader", P2PLogUploader::instance());

    QQmlApplicationEngine engine;

    // ⭐ 内核测试桥（QWebChannel）：把 P2P 信令暴露给 WebEngine JS。仅启用 WebEngine 时存在。
#ifdef HAVE_WEBENGINE
    KernelBridge *kernelBridge = new KernelBridge(&app);
    // ⭐ QML WebChannel.registeredObjects 用 objectName 作为 JS 侧的发布标识；
    //   不设则 JS 的 channel.objects.kernelBridge 取不到（即使 transport 已注入）。
    kernelBridge->setObjectName("kernelBridge");
    engine.rootContext()->setContextProperty("kernelBridge", kernelBridge);

    // ⭐ 网页内核作主播放器时的截图/慢放帧源（JS 经 kernelBridge 回传 JPEG 落盘）。
    //   app 级单例：模式切换时 QML 调 captureManager/slowMotionPlayer.setFrameSourceObject(webFrameSource)。
    WebFrameSource *webFrameSource = new WebFrameSource(&app);
    webFrameSource->setObjectName("webFrameSource");
    kernelBridge->setWebFrameSource(webFrameSource);
    engine.rootContext()->setContextProperty("webFrameSource", webFrameSource);
#endif
    
    // 连接 QML 的 Qt.quit() 到应用退出
    QObject::connect(&engine, &QQmlApplicationEngine::quit, &app, &QGuiApplication::quit);
    
    // 程序退出前主动关闭 WebSocket，让后端立刻收到 DISCONNECT 并清除在线状态
    QObject::connect(&app, &QCoreApplication::aboutToQuit, []() {
        WebSocketClient::instance()->disconnectFromServer();
    });

    // 创建并添加图像提供者
    CaptureImageProvider *captureProvider = new CaptureImageProvider();
    engine.addImageProvider("capture", captureProvider);
    
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    
    // 连接对象创建完成信号，用于设置图像提供者的引用和事件连接
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
        [captureProvider](QObject *obj, const QUrl &objUrl) {
            if (!obj) return;
            
            // 查找 CaptureManager 和 SlowMotionPlayer
            CaptureManager *capMgr = obj->findChild<CaptureManager*>("captureManager");
            SlowMotionPlayer *slowMo = obj->findChild<SlowMotionPlayer*>("slowMotionPlayer");
            
            if (capMgr) {
                captureProvider->setCaptureManager(capMgr);
                
                // 连接事件总线信号到 CaptureManager
                QObject::connect(EventBus::instance(), &EventBus::captureTriggered,
                                 capMgr, &CaptureManager::capture);
                QObject::connect(EventBus::instance(), &EventBus::clearTriggered,
                                 capMgr, &CaptureManager::clearAll);
                
                qDebug() << "CaptureManager connected to EventBus";
            }
            if (slowMo) {
                captureProvider->setSlowMotionPlayer(slowMo);
                
                // 连接事件总线信号到 SlowMotionPlayer
                QObject::connect(EventBus::instance(), &EventBus::slowmoToggleTriggered,
                                 slowMo, &SlowMotionPlayer::togglePlay);
                QObject::connect(EventBus::instance(), &EventBus::nextFrameTriggered,
                                 slowMo, &SlowMotionPlayer::nextFrame);
                QObject::connect(EventBus::instance(), &EventBus::prevFrameTriggered,
                                 slowMo, &SlowMotionPlayer::prevFrame);
                
                qDebug() << "SlowMotionPlayer connected to EventBus";
            }
        });
    
    engine.loadFromModule("Aifs", "Main");
    
    qDebug() << "========== QML 加载完成，进入主循环 ==========";

    // ⭐ §23.13：取主线程真句柄（GetCurrentThread 是伪句柄，跨线程无效）供看门狗挂起拍栈
#ifdef Q_OS_WIN
    DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(),
                    &g_mainThreadHandle, 0, FALSE, DUPLICATE_SAME_ACCESS);
#endif

    // ⭐ §23.12 冻结取证看门狗：主线程 100ms 心跳 + 参照线程 + 看门狗（结果见 freeze_diag.txt）
    QTimer mainHeartbeatTimer;
    mainHeartbeatTimer.setInterval(100);
    mainHeartbeatTimer.setTimerType(Qt::PreciseTimer);
    QObject::connect(&mainHeartbeatTimer, &QTimer::timeout, []() { updateMainHeartbeat(); });
    mainHeartbeatTimer.start();
    startFreezeWatchdog();

    int result = app.exec();
    
    stopFreezeWatchdog();
    
    // ⭐ 程序退出时清理 frames 目录
    clearFramesDirectory();
    
    // 程序退出，关闭日志文件（先停日志线程冲刷余量，再关文件）
    qDebug() << "========== 程序退出 ==========";
    stopLogWriterThread();
    if (g_logFile) {
        g_logFile->close();
        delete g_logFile;
        g_logFile = nullptr;
    }
    
    return result;
}
