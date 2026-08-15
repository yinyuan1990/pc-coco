#include "gstplayer.h"
#include "capturedebuglog.h"
#include "p2ploguploader.h"
#include "h265support.h"   // ⭐ H265 专属逻辑（元素工厂/关键帧判断/独立日志），与本文件 H264 链路解耦
#include <QDebug>
#include <QVideoFrameFormat>
#include <QDir>
#include <QFile>
#include <QTextStream>
#include <QMutex>
#include <QCoreApplication>
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QNetworkRequest>
#include <QTimer>
#include <QUrl>
#include <QtConcurrent>
#include <QThreadPool>
#include <QHash>
#include <QList>
#include <climits>
#include <cmath>
#include <thread>

#ifdef Q_OS_WIN
#include <windows.h>
#include <psapi.h>
#endif

// GStreamer WebRTC 相关 (GST_USE_UNSTABLE_API 已在 CMakeLists.txt 中定义)
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>
#include <gst/video/video.h>  // gst_video_event_new_upstream_force_key_unit

// ========== 诊断日志文件（独立输出，便于分析马赛克问题）==========
static QMutex g_diagLogMutex;
static QFile* g_diagLogFile = nullptr;
static QTextStream* g_diagLogStream = nullptr;

// §23.19：全部诊断 txt（gst_diag/nack/srt/srs/p2p/sh）写盘统一挪单线程后台池（FIFO 保序）。
//   原来在调用线程同步 write+flush——调用方遍布主线程（connect 入口/信令处理）与 GST 流水线线程
//   （每秒统计/appsink 回调），磁盘忙时单次 flush 可挂调用线程数百 ms~1s：挂主线程=UI 冻结，
//   挂 GST 线程=收帧/解码停摆=实时流卡（用户「点截图偶尔卡实时流」的同款机理）。
static QThreadPool* gstDiagWritePool() {
    static QThreadPool* pool = []() {
        auto* p = new QThreadPool();
        p->setMaxThreadCount(1);
        return p;
    }();
    return pool;
}

// ========== GStreamer 属性安全设置 ==========
static bool setBoolIfExists(GstElement* elem, const char* prop, gboolean value) {
    if (g_object_class_find_property(G_OBJECT_GET_CLASS(elem), prop)) {
        g_object_set(elem, prop, value, nullptr);
        return true;
    }
    return false;
}

static bool setIntIfExists(GstElement* elem, const char* prop, int value) {
    if (g_object_class_find_property(G_OBJECT_GET_CLASS(elem), prop)) {
        g_object_set(elem, prop, value, nullptr);
        return true;
    }
    return false;
}

static bool setUIntIfExists(GstElement* elem, const char* prop, guint value) {
    if (g_object_class_find_property(G_OBJECT_GET_CLASS(elem), prop)) {
        g_object_set(elem, prop, value, nullptr);
        return true;
    }
    return false;
}

static bool setStringIfExists(GstElement* elem, const char* prop, const char *value) {
    GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(elem), prop);
    if (!spec) return false;
    if (G_IS_PARAM_SPEC_ENUM(spec)) {
        GEnumClass *klass = G_ENUM_CLASS(g_type_class_ref(G_PARAM_SPEC_VALUE_TYPE(spec)));
        GEnumValue *enumValue = g_enum_get_value_by_nick(klass, value);
        if (!enumValue) enumValue = g_enum_get_value_by_name(klass, value);
        if (enumValue) {
            g_object_set(elem, prop, enumValue->value, nullptr);
            g_type_class_unref(klass);
            return true;
        }
        g_type_class_unref(klass);
        return false;
    }
    g_object_set(elem, prop, value, nullptr);
    return true;
}

static bool hasIdrInBuffer(GstBuffer* buf) {
    GstMapInfo map;
    if (!buf || !gst_buffer_map(buf, &map, GST_MAP_READ) || !map.data || map.size < 5) {
        return false;
    }
    const guint8* data = map.data;
    const gsize size = map.size;

    auto isIdrNal = [](guint8 nalHeader) {
        return (nalHeader & 0x1F) == 5; // IDR
    };

    // 1) 尝试 Annex-B（start code）
    for (gsize i = 0; i + 4 < size; ++i) {
        if (data[i] == 0x00 && data[i + 1] == 0x00 &&
            ((data[i + 2] == 0x01) || (data[i + 2] == 0x00 && data[i + 3] == 0x01))) {
            gsize nalIndex = (data[i + 2] == 0x01) ? (i + 3) : (i + 4);
            if (nalIndex < size && isIdrNal(data[nalIndex])) {
                gst_buffer_unmap(buf, &map);
                return true;
            }
            i = nalIndex;
        }
    }

    // 2) 尝试 AVCC（length-prefixed，4字节大端长度）
    gsize pos = 0;
    while (pos + 4 < size) {
        guint32 nalLen = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
        pos += 4;
        if (nalLen == 0 || pos + nalLen > size) break;
        if (isIdrNal(data[pos])) {
            gst_buffer_unmap(buf, &map);
            return true;
        }
        pos += nalLen;
    }

    gst_buffer_unmap(buf, &map);
    return false;
}

static void initDiagLog() {
    if (g_diagLogFile) return;
    
    QMutexLocker locker(&g_diagLogMutex);
    if (g_diagLogFile) return;
    
    QString logPath = QCoreApplication::applicationDirPath() + "/gst_diag.log";
    g_diagLogFile = new QFile(logPath);
    if (g_diagLogFile->open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        g_diagLogStream = new QTextStream(g_diagLogFile);
        *g_diagLogStream << "========== GStreamer 诊断日志 ==========" << Qt::endl;
        *g_diagLogStream << "启动时间: " << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << Qt::endl;
        *g_diagLogStream << "========================================" << Qt::endl << Qt::endl;
        g_diagLogStream->flush();
        qDebug() << "📝 诊断日志文件:" << logPath;
    }
}

static void diagLog(const QString& msg) {
    const QString timestamp = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
    gstDiagWritePool()->start([timestamp, msg]() {
        initDiagLog();
        if (!g_diagLogStream) return;
        QMutexLocker locker(&g_diagLogMutex);
        *g_diagLogStream << "[" << timestamp << "] " << msg << Qt::endl;
        g_diagLogStream->flush();
    });
}

// ========== NACK 专项诊断日志（独立 txt，便于发出来快速判断 NACK/重传是否生效）==========
static QMutex g_nackLogMutex;
static QFile* g_nackLogFile = nullptr;
static QTextStream* g_nackLogStream = nullptr;

static void nackLogWrite(const QString& timestamp, const QString& msg) {
    QMutexLocker locker(&g_nackLogMutex);
    if (!g_nackLogFile) {
        QString logPath = QCoreApplication::applicationDirPath() + "/nack_diag.txt";
        g_nackLogFile = new QFile(logPath);
        if (g_nackLogFile->open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            g_nackLogStream = new QTextStream(g_nackLogFile);
            *g_nackLogStream << "========== NACK / 重传 专项诊断 ==========" << Qt::endl;
            *g_nackLogStream << "启动时间: " << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << Qt::endl;
            *g_nackLogStream << "判定要点：" << Qt::endl;
            *g_nackLogStream << "  1) SDP 出现 'a=rtcp-fb:96 nack' = NACK 协商成功" << Qt::endl;
            *g_nackLogStream << "  2) do-nack=TRUE / do-retransmission=TRUE / mode=1 = 配置已生效" << Qt::endl;
            *g_nackLogStream << "  3) 运行中 nack-count 持续增长 = NACK 真在发（弱网时）" << Qt::endl;
            *g_nackLogStream << "  4) rtx-packets-received>0 = 重传包真被收到（补包成功）" << Qt::endl;
            *g_nackLogStream << "==========================================" << Qt::endl << Qt::endl;
            g_nackLogStream->flush();
            qDebug() << "📝 NACK 诊断日志文件:" << logPath;
        }
    }
    if (!g_nackLogStream) return;
    *g_nackLogStream << "[" << timestamp << "] " << msg << Qt::endl;
    g_nackLogStream->flush();
}

static void nackLog(const QString& msg) {
    const QString timestamp = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
    gstDiagWritePool()->start([timestamp, msg]() { nackLogWrite(timestamp, msg); });
}

// ========== SRT 专项诊断日志（独立 txt，便于发出来快速定位 SRT 拉流问题）==========
//   覆盖：连接 URI/streamid、pipeline 创建耗时、首帧、分辨率、队列深度/延迟、
//        裁帧、UNDERRUN 频率、SRT 重连等。只在 SRT 模式写，文件名 srt_diag.txt。
static QMutex g_srtLogMutex;
static QFile* g_srtLogFile = nullptr;
static QTextStream* g_srtLogStream = nullptr;

// UNDERRUN/OVERRUN 每秒汇总计数（避免逐条刷屏，由 SRT 每秒 stats 读取并清零）。
static std::atomic<int> g_srtDepayUnderrun{0};
static std::atomic<int> g_srtDecodeUnderrun{0};
static std::atomic<int> g_srtDepayOverrun{0};

static void srtLogWrite(const QString& timestamp, const QString& msg) {
    QMutexLocker locker(&g_srtLogMutex);
    if (!g_srtLogFile) {
        QString logPath = QCoreApplication::applicationDirPath() + "/srt_diag.txt";
        g_srtLogFile = new QFile(logPath);
        if (g_srtLogFile->open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            g_srtLogStream = new QTextStream(g_srtLogFile);
            *g_srtLogStream << "========== SRT 拉流专项诊断 ==========" << Qt::endl;
            *g_srtLogStream << "启动时间: " << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << Qt::endl;
            *g_srtLogStream << "判定要点：" << Qt::endl;
            *g_srtLogStream << "  1) [build] 出现 baseUri/streamid 明文 = streamid 解析正确" << Qt::endl;
            *g_srtLogStream << "  2) [首帧] + [分辨率] 出现 = SRT 收到数据并解码成功" << Qt::endl;
            *g_srtLogStream << "  3) [stats] 队列深度/延迟 = 实际端到端延迟（队列×帧间隔 + 缓冲）" << Qt::endl;
            *g_srtLogStream << "  4) [裁帧] 频繁 = gop_cache 历史帧灌入，裁帧在生效降延迟" << Qt::endl;
            *g_srtLogStream << "  5) [pipeline] 创建耗时 = 主线程卡顿时长（>1s 会卡 UI）" << Qt::endl;
            *g_srtLogStream << "=====================================" << Qt::endl << Qt::endl;
            g_srtLogStream->flush();
            qDebug() << "📝 SRT 诊断日志文件:" << logPath;
        }
    }
    if (!g_srtLogStream) return;
    *g_srtLogStream << "[" << timestamp << "] " << msg << Qt::endl;
    g_srtLogStream->flush();
}

static void srtLog(const QString& msg) {
    const QString timestamp = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
    gstDiagWritePool()->start([timestamp, msg]() { srtLogWrite(timestamp, msg); });
}

// ========== SRS(WebRTC) 专项诊断日志（独立 txt，定位「SRS 偶尔第一次画面出不来」）==========
//   覆盖：connectWebRTC 入口、会话/熔断标志状态、Offer 创建/发送、SRS HTTP 响应码、
//        重试、Answer、ICE/连接状态、首帧、断开/重置。只在 SRS(WebRTC 非 P2P) 路径写，
//        文件名 srs_diag.txt。用于判断画面出不来时卡在哪一步（尤其 m_srsError / m_offerSentForSession 熔断）。
static QMutex g_srsLogMutex;
static QFile* g_srsLogFile = nullptr;
static QTextStream* g_srsLogStream = nullptr;

static void srsLogWrite(const QString& timestamp, const QString& msg) {
    QMutexLocker locker(&g_srsLogMutex);
    if (!g_srsLogFile) {
        QString logPath = QCoreApplication::applicationDirPath() + "/srs_diag.txt";
        g_srsLogFile = new QFile(logPath);
        if (g_srsLogFile->open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            g_srsLogStream = new QTextStream(g_srsLogFile);
            *g_srsLogStream << "========== SRS(WebRTC) 拉流专项诊断 ==========" << Qt::endl;
            *g_srsLogStream << "启动时间: " << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << Qt::endl;
            *g_srsLogStream << "判定要点（画面出不来时按时间顺序看卡在哪步）：" << Qt::endl;
            *g_srsLogStream << "  1) [connect] 每次连接入口，含 host/stream + 进入时的熔断标志状态" << Qt::endl;
            *g_srsLogStream << "  2) [熔断] srsError/offerSent/offerInProgress 三标志 —— 若进入时已是 true 且没被重置 = 卡死根因" << Qt::endl;
            *g_srsLogStream << "  3) [offer] Offer 创建/发送；[http] SRS 返回 code（0=成功，400/404=流未就绪重试）" << Qt::endl;
            *g_srsLogStream << "  4) [retry] 重试次数；§54(2026-07-31)起 400/404 每 2s 常驻重试**永不放弃**（旧版 5 次即死已删除）" << Qt::endl;
            *g_srsLogStream << "  5) [answer]/[ice]/[首帧] 出现 = 链路打通；缺哪步就是卡在前一步" << Qt::endl;
            *g_srsLogStream << "==============================================" << Qt::endl << Qt::endl;
            g_srsLogStream->flush();
            qDebug() << "📝 SRS 诊断日志文件:" << logPath;
        }
    }
    if (!g_srsLogStream) return;
    *g_srsLogStream << "[" << timestamp << "] " << msg << Qt::endl;
    g_srsLogStream->flush();
}

static void srsLog(const QString& msg) {
    const QString timestamp = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
    gstDiagWritePool()->start([timestamp, msg]() { srsLogWrite(timestamp, msg); });
}

// ========== P2P 直连专项诊断日志（独立 txt，定位「P2P 出不来画面，尤其手机连手机热点」）==========
//   覆盖：connectP2P 入口、ICE 服务器(STUN/TURN)配置、收到/发送的 ICE 候选者(按 host/srflx/relay 分类)、
//        WEBRTC_REQUEST/Offer/Answer 时序、ICE 连接状态机、首帧。只在 P2P 模式写，文件名 p2p_diag.txt。
//   核心判断：手机热点= 运营商级 NAT(CGNAT)/对称 NAT，host/srflx 大概率打不通，必须走 TURN relay 候选者。
//        若日志里【本地或远端都没有 typ relay 候选者】或 TURN 添加失败 → 这就是「热点出不来」的根因。
static QMutex g_p2pLogMutex;
static QFile* g_p2pLogFile = nullptr;
static QTextStream* g_p2pLogStream = nullptr;

static void p2pLogWrite(const QString& timestamp, const QString& msg) {
    QMutexLocker locker(&g_p2pLogMutex);
    if (!g_p2pLogFile) {
        QString logPath = QCoreApplication::applicationDirPath() + "/p2p_diag.txt";
        g_p2pLogFile = new QFile(logPath);
        if (g_p2pLogFile->open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            g_p2pLogStream = new QTextStream(g_p2pLogFile);
            *g_p2pLogStream << "========== P2P 直连专项诊断 ==========" << Qt::endl;
            *g_p2pLogStream << "启动时间: " << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << Qt::endl;
            *g_p2pLogStream << "判定要点（手机连手机热点出不来画面时，按时间顺序看卡在哪步）：" << Qt::endl;
            *g_p2pLogStream << "  1) [connect] P2P 入口；[ice-server] 看 STUN/TURN 是否都配上了（无 TURN → 热点必失败）" << Qt::endl;
            *g_p2pLogStream << "  2) [本地候选] / [远端候选] 按 typ 分类统计：手机热点是 CGNAT/对称NAT，" << Qt::endl;
            *g_p2pLogStream << "     host/srflx 多半打不通，【两端必须各自至少有 1 个 typ relay(TURN中继)候选者】才有戏" << Qt::endl;
            *g_p2pLogStream << "  3) [offer]/[answer] 出现 = 信令通了；只有 request 无 offer = iOS 没上线/没回 Offer" << Qt::endl;
            *g_p2pLogStream << "  4) [ice] Checking→Connected = ICE 打通；卡在 Checking 后 Failed = NAT 穿透失败(常见于热点无 relay)" << Qt::endl;
            *g_p2pLogStream << "  5) [首帧] 出现 = 真出画面；ICE Connected 但无首帧 = 媒体未流动(检查 PLI/关键帧)" << Qt::endl;
            *g_p2pLogStream << "=====================================" << Qt::endl << Qt::endl;
            g_p2pLogStream->flush();
            qDebug() << "📝 P2P 诊断日志文件:" << logPath;
        }
    }
    if (!g_p2pLogStream) return;
    *g_p2pLogStream << "[" << timestamp << "] " << msg << Qt::endl;
    g_p2pLogStream->flush();
}

static void p2pLog(const QString& msg) {
    // ⭐ H265 会话：整条 P2P 事件日志改道 h265 独立通道（本地 h265_diag.txt +
    //   上报前缀 pc-gstream-p2p-h265），与 H264 的 p2p_diag.txt 完全分开，便于分开下载分析卡顿。
    if (H265Support::isActive()) {
        H265Support::log(msg);
        return;
    }

    const QString timestamp = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
    gstDiagWritePool()->start([timestamp, msg]() { p2pLogWrite(timestamp, msg); });

    // ⭐ 第二十二章：总后台「P2P日志」开关打开时同步上报服务器（按推流ID分流，前缀 pc-gstream-p2p）。
    //   append 只进内存缓冲（线程安全、无磁盘操作），留在调用线程即可。
    P2PLogUploader::instance()->append(QStringLiteral("pc-gstream-p2p"),
                                       "[" + timestamp + "] " + msg);
}

// 从一条 ICE candidate 文本里提取类型（host/srflx/prflx/relay/unknown）。
// 这是判断「热点能不能打通」的关键：relay = 经 TURN 中继，CGNAT/对称 NAT 下唯一可靠的通道。
static QString p2pCandidateType(const QString& candidate) {
    int idx = candidate.indexOf("typ ");
    if (idx < 0) return "unknown";
    QString rest = candidate.mid(idx + 4).trimmed();
    QString typ = rest.section(' ', 0, 0);
    if (typ == "host" || typ == "srflx" || typ == "prflx" || typ == "relay") return typ;
    return typ.isEmpty() ? "unknown" : typ;
}

// ========== 系统信息获取函数 ==========
static long getSystemMemoryGB() {
#ifdef Q_OS_WIN
    MEMORYSTATUSEX memInfo;
    memInfo.dwLength = sizeof(MEMORYSTATUSEX);
    if (GlobalMemoryStatusEx(&memInfo)) {
        long totalMemoryGB = memInfo.ullTotalPhys / (1024 * 1024 * 1024);
        qDebug() << "💾 系统物理内存:" << totalMemoryGB << "GB";
        return totalMemoryGB;
    }
#endif
    qDebug() << "⚠️ 无法获取系统内存，默认按8GB处理";
    return 8; // 默认按低端机处理
}

static int getCore() {
#ifdef Q_OS_WIN
    SYSTEM_INFO sysInfo;
    GetSystemInfo(&sysInfo);
    int cores = sysInfo.dwNumberOfProcessors;
    qDebug() << "💻 CPU 核心数:" << cores;
    return cores;
#endif
    return 4; // 默认值
}

// ========== 截图独立帧 H.264 编码画质：按机型分档 ==========
//   只影响 .h264 帧文件的大小/清晰度，不动缓存/预取等其它逻辑。
//   qpI 越小越清晰、文件越大；max-bitrate 是码率上限（沿用原单位，相对原值缩放）。
//   恒定 QP → 文件大小随分辨率自然伸缩（640x480 ~ 1920x1440 各档统一画质）。
struct H264FrameQuality { int qpI; int bitrateKbps; int maxBitrateKbps; const char *tier; };
static H264FrameQuality chooseH264FrameQuality() {
    long memGB = getSystemMemoryGB();
    int cores = getCore();
    bool lowCPU = cores <= 6;
    if (memGB <= 8 || lowCPU) {
        return { 22, 20000,  80000, "低端(≤8G/≤6核): 省盘+解码快" };
    } else if (memGB < 16) {
        return { 18, 30000, 120000, "中端(8-16G): 标准画质" };
    } else if (memGB < 32) {
        return { 17, 40000, 200000, "高端(16-32G): 更清晰" };
    } else {
        return { 16, 50000, 300000, "超高端(≥32G): 最清晰" };
    }
}

GstPlayer::GstPlayer(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
{
    qDebug() << "📦 GstPlayer 构造函数 (WebRTCBin 版本)";
    
    // NALU 帧存储（H.264 ring buffer，零格式转换）
    m_naluStore = new NaluFrameStore(NaluFrameStore::DEFAULT_CAPACITY, this);
    
    // ⭐⭐⭐ 创建自适应渲染定时器（应用层 Jitter Buffer 方案）
    m_renderTimer = new QTimer(this);
    m_renderTimer->setTimerType(Qt::PreciseTimer);  // 高精度定时器
    connect(m_renderTimer, &QTimer::timeout, this, &GstPlayer::onRenderTick);
    m_renderTimer->start(33);  // 初始 33ms（目标30fps）
    m_bufferingStarted.store(false);
    
    // 🔥🔥🔥 v11.3 动态队列策略（初始化时损坏率为0）
    int queueMin, queueOptimal, queueMax;
    getQueueSizeByFps(m_configFps, queueMin, queueOptimal, queueMax, 0.0, m_useP2P);
    m_queueTarget = queueOptimal;
    m_queueTargetSmooth = m_queueTarget;
    
    int targetDelayMs = (m_configFps > 0) ? static_cast<int>(queueOptimal * 1000.0 / m_configFps) : 100;
    int totalDelay = targetDelayMs + GST_JITTER_LATENCY;
    
    qDebug().noquote() << QString("⏱️ v11动态队列 | FPS=%1 | 队列=%2帧(范围%3-%4) | 延迟=%5ms+%6ms=%7ms")
        .arg((int)m_configFps).arg(m_queueTarget).arg(queueMin).arg(queueMax)
        .arg(targetDelayMs).arg(GST_JITTER_LATENCY).arg(totalDelay);

    // ⭐ 治「SRT 首屏卡 3.3s」关键：在 App 启动构造时就【尽早】后台预热解码器/编码器，
    //   远早于 connectSRT，让首次建管线时 CUDA/MediaFoundation 已热（之前放在 connectSRT
    //   入口与 createPipeline 并行赛跑、抢同一硬件初始化锁，等于没提前 —— 日志实证无效）。
    //   预热是全局硬件初始化，对 SRS/P2P 同样有利，不改它们任何代码路径。
    //   用 singleShot(0) 推到事件循环启动后执行，避免阻塞构造与 gst 初始化次序问题。
    QTimer::singleShot(0, this, [this]() { warmupDecoderEncoderAsync(); });
}

GstPlayer::~GstPlayer()
{
    stopAutoKeyFrameRequest();  // 停止周期性关键帧请求
    
    // ⭐ 停止渲染定时器
    if (m_renderTimer) {
        m_renderTimer->stop();
    }
    
    // ⭐ 释放队列中所有帧
    {
        QMutexLocker lock(&m_queueMutex);
        for (GstSample *sample : m_frameQueue) {
            gst_sample_unref(sample);
        }
        m_frameQueue.clear();
    }
    
    // ⭐ 释放最后有效帧
    if (m_lastValidSample) {
        gst_sample_unref(m_lastValidSample);
        m_lastValidSample = nullptr;
    }
    
    stop();
    destroyPipeline();
    qDebug() << "📦 GstPlayer 析构完成";
}

void GstPlayer::setVideoSink(QVideoSink *sink)
{
    if (m_videoSink != sink) {
        m_videoSink = sink;
        emit videoSinkChanged();
    }
}

// 缓存最近一次检测到的 GPU 原始信息（小写），供强制软解判断使用
static QString g_lastGpuRawInfo;

// 判断是否为"老旧 Intel 核显"(Sandy/Ivy 等 legacy DXVA)。
// 这类机器 d3d11 硬解会在协商序列头时报 "Could not determine decoder config" → not-negotiated → 黑屏，
// 必须直接走 avdec_h264 软解。较新核显(uhd/iris/HD 5xx+/44xx+)硬解正常，不在此列。
static bool isLegacyIntelGpu(const QString& lower) {
    int idx = lower.indexOf("hd graphics");
    if (idx < 0) return false;
    if (lower.contains("uhd") || lower.contains("iris")) return false;  // 较新核显
    int p = idx + 11;  // strlen("hd graphics")
    while (p < lower.size() && lower[p] == QChar(' ')) p++;
    QString num;
    while (p < lower.size() && lower[p].isDigit()) { num.append(lower[p]); p++; }
    if (num.isEmpty()) return true;                                // 裸 "hd graphics"（通用驱动名，多为 Sandy/Ivy）
    int n = num.toInt();
    if (num.size() == 4 && n >= 2000 && n <= 4000) return true;    // 2000/2500/3000/4000 = Sandy/Ivy
    return false;                                                  // 3位(5xx/6xx) 或 44xx+ (Haswell+) 硬解正常
}

// 是否需要对本机强制软解：环境变量手动开 / 或 (无独显 且 老旧 Intel 核显)
static bool shouldForceSoftwareDecode(const QString& gpuRawLower) {
    QByteArray env = qgetenv("PHOENIX_FORCE_SOFTWARE_DECODE");
    if (env == "1" || env.toLower() == "true") return true;
    bool hasDiscrete = gpuRawLower.contains("nvidia") || gpuRawLower.contains("geforce")
                    || gpuRawLower.contains("rtx") || gpuRawLower.contains("gtx")
                    || gpuRawLower.contains("radeon") || gpuRawLower.contains("amd");
    if (hasDiscrete) return false;  // 有独显 → nvh264dec/amf 硬解正常，不强制
    return isLegacyIntelGpu(gpuRawLower);
}

// ========== GPU 类型检测（与 Java 一致）==========
QString GstPlayer::detectGpuType()
{
    // ⭐ 缓存：GPU 类型在一个进程生命周期内不会变化。
    // 原实现每次 createPipeline（每次拉流/重连/切流）都同步跑 wmic + waitForFinished(3000)，
    // 而 wmic 在新版 Windows 启动极慢（数百 ms ~ 数秒），直接阻塞 GUI 主线程 → 界面卡死拖不动。
    // 改为仅首次检测，之后直接返回缓存值。
    static QString s_cachedGpuType;
    if (!s_cachedGpuType.isEmpty()) {
        return s_cachedGpuType;
    }

    // Windows: 用 EnumDisplayDevices 纯 API 取显卡名（微秒级，无子进程）。
    // ⚠️ 原实现起 wmic 子进程 + waitForFinished(3000)——新版 Windows 上 wmic 启动极慢，
    // freeze_diag 栈捕获实锤首次调用挂主线程 2.8s（QProcess::waitForFinished，§23.15），故弃用。
#ifdef Q_OS_WIN
    QString output;
    DISPLAY_DEVICEW dd;
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); ++i) {
        output += QString::fromWCharArray(dd.DeviceString).toLower() + QLatin1Char('\n');
        dd.cb = sizeof(dd);
    }
    g_lastGpuRawInfo = output;
    qDebug() << "🖥️ 检测到 GPU:" << output.trimmed();
    
    // 判断 GPU 类型（按优先级）
    if (output.contains("nvidia") || output.contains("geforce") || 
        output.contains("rtx") || output.contains("gtx")) {
        s_cachedGpuType = "NVIDIA";
    } else if (output.contains("amd") || output.contains("radeon") || output.contains("rx ")) {
        s_cachedGpuType = "AMD";
    } else if (output.contains("intel") || output.contains("uhd") || output.contains("iris")) {
        s_cachedGpuType = "Intel";
    } else {
        s_cachedGpuType = "Unknown";
    }
    return s_cachedGpuType;
#else
    s_cachedGpuType = "Unknown";
    return s_cachedGpuType;
#endif
}

bool GstPlayer::createPipeline()
{
    QMutexLocker lock(&m_mutex);
    
    if (m_pipeline) {
        // 安全网：正常切换路径里 connectXXX 已先 destroyPipeline()，进来时应为 nullptr。
        // 但链路频繁来回切换时，残留的异步重活/重连定时器可能在 m_pipeline 仍非空时
        // 触发本函数。此处必须能正确销毁旧管线——依赖 m_mutex 为递归锁（QRecursiveMutex），
        // 否则此处二次加锁会死锁（这正是「切换多了卡死」的根因，已修）。
        qDebug() << "⚠️ Pipeline 已存在，先销毁";
        destroyPipeline();
    }
    
    if (m_useWebRTC) {
        qDebug() << "🔧 创建 GStreamer Pipeline (WebRTCBin 模式)...";
    } else {
        qDebug() << "🔧 创建 GStreamer Pipeline (AppSrc 模式)...";
    }
    
    // 创建 Pipeline
    m_pipeline = gst_pipeline_new("webrtc-player");
    if (!m_pipeline) {
        qCritical() << "❌ 创建 Pipeline 失败";
        emit error("创建 GStreamer Pipeline 失败");
        return false;
    }
    
    // ========== 创建源元素（根据模式选择）==========
    // MARK: SRT (independent)
    // SRT 模式：源元素（srtsrc/tsdemux）由独立的 GstSrtSource 在下面的链接阶段创建并加入，
    // 这里不创建 webrtcbin/appsrc，直接跳到共享的 h264parse 及尾段。
    if (m_useSRT) {
        qDebug() << "🔧 创建 GStreamer Pipeline (SRT 模式)...";
        // 仅校验插件，源元素稍后由 GstSrtSource::build 创建。
        QString srtMissing;
        if (!GstSrtSource::pluginsAvailable(&srtMissing)) {
            qCritical() << "❌ SRT 插件不可用:" << srtMissing;
            emit error(QString("SRT 插件不可用：%1（请安装 gst-plugins-bad）").arg(srtMissing));
            gst_object_unref(m_pipeline);
            m_pipeline = nullptr;
            return false;
        }
    } else if (m_useWebRTC) {
        // WebRTC 模式：使用 webrtcbin + rtph264depay（H265 会话换 rtph265depay，逻辑在 h265support.cpp）
        m_webrtcbin = gst_element_factory_make("webrtcbin", "webrtcbin");
        m_rtph264depay = m_useH265 ? H265Support::createDepay()
                                   : gst_element_factory_make("rtph264depay", "depay");
        
        if (!m_webrtcbin) {
            qCritical() << "❌ webrtcbin 不可用，请检查 GStreamer 插件安装";
            emit error("webrtcbin 不可用，请安装 gst-plugins-bad");
            gst_object_unref(m_pipeline);
            m_pipeline = nullptr;
            return false;
        }
        
        if (!m_rtph264depay) {
            qCritical() << "❌ rtph264depay 不可用";
            emit error("rtph264depay 不可用");
            gst_object_unref(m_pipeline);
            m_pipeline = nullptr;
            return false;
        }
        
        // ⭐⭐⭐ 机型自适应配置（与 Java 完全一致）
        long memoryGB = getSystemMemoryGB();
        int cpuCores = getCore();
        bool isLowEndCPU = cpuCores <= 6;
        
        // ⭐ §25.5-3（2026-07-03）虚假 NACK 风暴治理：25→120ms。
        //   25ms 是同 WiFi（零抖动）调出来的值；跨 WiFi 实测到达抖动 51~79ms，大量正常包
        //   「迟到」>25ms 被当丢包狂发 NACK（实测每秒 +100~345，真丢仅个位数），
        //   无效重传占上行且污染 RTCP 反馈（iOS 读 RR-RTT 恒 450ms → 自适应误杀码率）。
        //   120ms > 最大正常抖动，真丢包补回慢 ~100ms 由 jitterbuffer 300ms 缓冲吸收。
        int retryTimeoutMs = 120;
        int dropoutMs = 1200;
        int misorderMs = 800;
        QString machineType;
        int p2pJitterMs;   // §23.18（用户定）：P2P 缓冲按机型分档，机型越好越低（300ms 最低、800ms 封顶）

        if (memoryGB <= 8 || isLowEndCPU) {
            machineType = (memoryGB <= 8 && isLowEndCPU) ? "极低端机(≤8GB+≤6核)" :
                          (memoryGB <= 8 ? "低端机(≤8GB)" : "低端CPU(≤6核)");
            p2pJitterMs = 800;
        } else if (memoryGB < 16) {
            machineType = "中端机(8-16GB)";
            p2pJitterMs = 550;
        } else if (memoryGB < 32) {
            machineType = "高端机(16-32GB)";
            p2pJitterMs = 400;
        } else {
            machineType = "超高端机(≥32GB)";
            p2pJitterMs = 300;
        }

        // ⭐ P2P 低延迟特化（2026-07-02）+ §23.18 机型分档（2026-07-03 用户定）：
        //    P2P 直连网络抖动小（netJitter 实测 ~30ms），大缓冲纯属浪费延迟——但低配机主线程/解码
        //    更易卡，缓冲小了小冻结直接见底前跳，故按机型取 300(超高端)/400(高端)/550(中端)/800(低端)。
        //    SRS/中继链路保持 600ms 不变。createPipeline 在 connectP2P 里于 m_useP2P=true 之后调用，此处可靠。
        int jitterLatencyMs = m_useP2P ? p2pJitterMs : 600;
        
        diagLog(QString("🎯 机型自适应配置 [%1, %2GB内存, %3核]:").arg(machineType).arg(memoryGB).arg(cpuCores));
        diagLog(QString("   - jitter=%1ms, retry=15×%2ms, dropout=%3ms, misorder=%4ms")
            .arg(jitterLatencyMs).arg(retryTimeoutMs).arg(dropoutMs).arg(misorderMs));
        
        // 配置 webrtcbin
        g_object_set(m_webrtcbin,
            "bundle-policy", 3,  // max-bundle
            "latency", jitterLatencyMs,
            nullptr);
        
        // ⭐ 配置 rtph264depay（防马赛克关键！）——H265 会话的 depay 配置已在 H265Support::createDepay 内完成
        if (!m_useH265) {
            bool setWait = setBoolIfExists(m_rtph264depay, "wait-for-keyframe", TRUE);           // ⭐ 必须！等待关键帧才开始解包
            bool setReq = setBoolIfExists(m_rtph264depay, "request-keyframe", TRUE);             // 启用关键帧请求
            bool setDiscont = setBoolIfExists(m_rtph264depay, "request-keyframe-on-discont", TRUE); // ⚡ 发现不连续时立即请求关键帧
            diagLog(QString("✅ rtph264depay: wait=%1, request=%2, on-discont=%3")
                .arg(setWait).arg(setReq).arg(setDiscont));
        }
        
        // ⭐⭐⭐ 关键：监听 webrtcbin 内部元素添加，配置 jitterbuffer（防马赛克核心！）
        // 使用结构体传递参数给回调
        struct JitterConfig {
            int latency;
            int retryTimeout;
            int dropout;
            int misorder;
        };
        static JitterConfig jitterConfig;
        jitterConfig = {jitterLatencyMs, retryTimeoutMs, dropoutMs, misorderMs};
        
        // ⭐⭐⭐ 关键修复：rtpjitterbuffer 是 webrtcbin → 内层 rtpbin 动态创建的【深层嵌套】子元素，
        //   普通 element-added 只对 webrtcbin 的【直接】子元素触发，收不到内层 jitterbuffer，
        //   导致 do-retransmission/mode 改造从未执行（日志里看不到“发现 jitterbuffer”/v11 即是此因）。
        //   deep-element-added 会对所有后代元素递归触发，确保内层 jitterbuffer 一定被捕获并配置。
        //   回调签名：(GstBin* topbin, GstBin* subbin, GstElement* element, gpointer userData)
        g_signal_connect(m_webrtcbin, "deep-element-added", G_CALLBACK(+[](GstBin*, GstBin*, GstElement* element, gpointer userData) {
            GstPlayer* self = static_cast<GstPlayer*>(userData);
            const gchar* name = GST_ELEMENT_NAME(element);
            if (name && g_strstr_len(name, -1, "jitterbuffer")) {
                // 幂等保护：同一 jitterbuffer 只配置一次（deep-element-added 可能多元素触发）
                if (self && self->m_rtpJitterBuffer == element) return;
                // 记下 jitterbuffer 指针，供每秒统计读取 NACK/重传 stats（仅诊断，不持有所有权）
                if (self) self->m_rtpJitterBuffer = element;
                diagLog(QString("🎯 发现 jitterbuffer(deep): %1，配置防马赛克参数...").arg(name));
                
                // ⭐⭐⭐ v11 防花屏配置（对标 Chrome：开 NACK/RTX 重传）
                // 🔥 关键修改（本次）：
                //   1) do-retransmission FALSE→TRUE：开重传，配合 transceiver do-nack，丢包先 NACK 补回。
                //   2) mode 0(none)→1(slave)：none 会禁用重排序/重传调度；slave 是 webrtcbin 默认，
                //      jitterbuffer 才会真正按序等待重传包（重传调度依赖非 none 模式）。
                // drop-on-latency=FALSE 保留：不丢 I 帧，延迟控制仍在应用层做 P 帧追帧。
                g_object_set(element,
                    "latency", jitterConfig.latency,   // P2P=300ms / SRS=600ms（均容纳一次重传往返）
                    "drop-on-latency", FALSE,          // 不丢包，防止丢 I 帧花屏
                    "max-dropout-time", jitterConfig.dropout,
                    "max-misorder-time", jitterConfig.misorder,
                    "do-retransmission", TRUE,         // 🔥🔥🔥 v11: 开 NACK/RTX 重传（对标 Chrome，丢包补回不花屏）
                    "do-lost", TRUE,                   // 发送丢包事件（重传补不回时仍触发请求关键帧兜底）
                    "mode", 1,                         // 🔥 v11: slave 模式（none 不重传调度），启用重排序+重传等待
                    "max-rtcp-rtp-time-diff", -1,      // 禁用 RTCP 检查
                    nullptr);
                
                // 🔥 2026-07-02 修复：retryTimeoutMs(25ms) 一直只进了 jitterConfig 没写进元素，
                //    NACK 重传节奏一直是 GStreamer 默认。属性名是 rtx-retry-timeout（不是 retry-timeout），
                //    带存在性保护（老版本插件无此属性时跳过，不产生 GObject 警告）。
                if (g_object_class_find_property(G_OBJECT_GET_CLASS(element), "rtx-retry-timeout")) {
                    g_object_set(element, "rtx-retry-timeout", jitterConfig.retryTimeout, nullptr);
                    diagLog(QString("✅ jitterbuffer rtx-retry-timeout=%1ms 已写入").arg(jitterConfig.retryTimeout));
                }

                // ⭐ §25.5-3（2026-07-03）虚假 NACK 风暴治理（配合 retryTimeoutMs 25→120）：
                //   rtx-delay=80ms：首次发 NACK 前先等 80ms（默认自动值被激进 retry 架空），
                //     容忍跨网正常抖动（实测 51~79ms），包只是晚到就不催重传。
                //   rtx-delay-reorder=15：默认 3 个包乱序即触发 NACK，公网多跳路径乱序是常态，
                //     放宽到 15 个包，真丢包仍由 rtx-delay 超时兜底。
                //   均带属性存在性保护（老版本插件无此属性时静默跳过）。
                if (g_object_class_find_property(G_OBJECT_GET_CLASS(element), "rtx-delay")) {
                    g_object_set(element, "rtx-delay", 80, nullptr);
                    diagLog("✅ jitterbuffer rtx-delay=80ms 已写入（跨网抖动容忍）");
                }
                if (g_object_class_find_property(G_OBJECT_GET_CLASS(element), "rtx-delay-reorder")) {
                    g_object_set(element, "rtx-delay-reorder", 15, nullptr);
                    diagLog("✅ jitterbuffer rtx-delay-reorder=15包 已写入（乱序不触发 NACK）");
                }
                
                diagLog(QString("✅ v11 jitterbuffer: latency=%1ms, do-retransmission=TRUE(NACK重传), mode=1(slave), drop-on-latency=FALSE")
                    .arg(jitterConfig.latency));

                // NACK 专项日志：回读 jitterbuffer 关键属性，确认真的生效
                {
                    gboolean doRtx = FALSE; gint jbMode = -1; guint jbLatency = 0;
                    g_object_get(element, "do-retransmission", &doRtx, "mode", &jbMode, "latency", &jbLatency, nullptr);
                    nackLog(QString("[配置] jitterbuffer 回读: do-retransmission=%1(1=开), mode=%2(1=slave), latency=%3ms")
                        .arg(doRtx ? 1 : 0).arg(jbMode).arg(jbLatency));
                }
            }
        }), this);
        
        qDebug() << "✅ WebRTCBin 创建成功 [" << machineType << "]";
    } else {
        // 传统模式：使用 appsrc
        m_appsrc = gst_element_factory_make("appsrc", "src");
    }
    
    // ⭐ H265 会话：parse 元素换 h265parse（配置在 h265support.cpp，参数策略与 h264parse 对齐）
    m_h264parse = m_useH265 ? H265Support::createParse()
                            : gst_element_factory_make("h264parse", "parse");
    
    // ⭐ 配置 h264parse（与 Java 完全一致）
    if (m_h264parse && !m_useH265) {
        g_object_set(m_h264parse,
            "config-interval", 1,     // 1 = 每个关键帧前插入SPS/PPS（与Java一致）
            "update-timecode", FALSE, // 不更新时间码，避免时间戳问题
            nullptr);
        
        // ⭐⭐⭐ 关键：与 Java 一致的额外配置（防止绿幕）
        // output-format: 强制输出 byte-stream 格式
        // disable-passthrough: 强制处理每一帧，不跳过（防止档位切换绿幕）
        GstElementFactory *factory = gst_element_get_factory(m_h264parse);
        if (factory) {
            // 检查属性是否存在再设置
            GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(m_h264parse), "disable-passthrough");
            if (spec) {
                g_object_set(m_h264parse, "disable-passthrough", TRUE, nullptr);
                qDebug() << "✅ h264parse: disable-passthrough=true（防止绿幕）";
            }
        }
        bool setOutputFormat = setIntIfExists(m_h264parse, "output-format", 1); // 1=byte-stream
        if (setOutputFormat) {
            qDebug() << "✅ h264parse: output-format=byte-stream";
        }
        qDebug() << "✅ h264parse: config-interval=1（关键帧前插入SPS/PPS）";
    }

    // NALU 存储分支（tee + leaky queue + appsink，不阻塞直播主路径）
    m_naluTee = gst_element_factory_make("tee", "nalu_tee");
    m_naluQueue = gst_element_factory_make("queue", "nalu_store_queue");
    m_naluAppsink = gst_element_factory_make("appsink", "nalu_store_sink");
    if (m_naluQueue) {
        g_object_set(m_naluQueue,
            "max-size-buffers", 5,
            "max-size-bytes", 0,
            "max-size-time", 0,
            "leaky", 2,   // downstream leaky：存储慢则丢旧帧
            "silent", TRUE,
            nullptr);
    }
    if (m_naluAppsink) {
        g_object_set(m_naluAppsink,
            "emit-signals", TRUE,
            "sync", FALSE,
            "async", FALSE,
            "max-buffers", 2,
            "drop", TRUE,
            nullptr);
        GstCaps *naluCaps = gst_caps_from_string(
            m_useH265 ? H265Support::naluCapsString()
                      : "video/x-h264, stream-format=(string)byte-stream, alignment=(string)au");
        gst_app_sink_set_caps(GST_APP_SINK(m_naluAppsink), naluCaps);
        gst_caps_unref(naluCaps);
        g_signal_connect(m_naluAppsink, "new-sample", G_CALLBACK(onNaluStoreSample), this);
    }
    if (m_naluTee && m_naluQueue && m_naluAppsink) {
        qDebug() << "✅ NALU tee branch: nalu_queue(leaky=2) → nalu_appsink";
        captureDebugLog("GST", "NALU tee branch created (leaky queue + async appsink)");
    }

    // ⭐⭐⭐ v10超低延迟：小队列（配合 QUEUE_ABSOLUTE_MAX）
    // 方案B（平衡）：5帧缓冲，兼顾低延迟和平滑
    m_queueDepay = gst_element_factory_make("queue", "queue_depay");
    if (m_queueDepay) {
        // 🔥 v10: 队列大小与 QUEUE_ABSOLUTE_MAX 保持一致
        g_object_set(m_queueDepay,
            "max-size-buffers", QUEUE_ABSOLUTE_MAX, // 🔥 v10: 与应用层队列一致
            "max-size-bytes", 0,              // 不限制字节
            "max-size-time", (guint64)200000000, // 🔥 200ms（纳秒），平衡延迟和平滑
            "leaky", 2,                       // 丢弃老帧，保持最新帧
            "silent", FALSE,                  // 开启日志
            "flush-on-eos", TRUE,
            nullptr);
        
        // ⭐ 监听 overrun 信号（队列满时触发）
        g_signal_connect(m_queueDepay, "overrun", G_CALLBACK(+[](GstElement*, gpointer) {
            g_srtDepayOverrun.fetch_add(1);
            diagLog("⚠️ queueDepay OVERRUN - 队列满，可能丢帧！");
        }), nullptr);
        g_signal_connect(m_queueDepay, "underrun", G_CALLBACK(+[](GstElement*, gpointer) {
            g_srtDepayUnderrun.fetch_add(1);
            diagLog("⚠️ queueDepay UNDERRUN - 队列空，数据不足！");
        }), nullptr);
        
        qDebug() << "⭐ v10 queueDepay: buffers=" << QUEUE_ABSOLUTE_MAX << ", time=200ms, leaky=2（平衡方案）";
        diagLog(QString("✅ v10 queueDepay: buffers=%1, time=200ms, leaky=2（平衡方案）").arg(QUEUE_ABSOLUTE_MAX));
    }
    
    // ========== 解码器智能选择（与 Java 一致）==========
    // 根据 GPU 类型选择解码器优先级
    m_useHardwareDecoder = false;
    
    // 检测 GPU 类型
    QString gpuType = detectGpuType();
    qDebug() << "🎮 检测到 GPU 类型:" << gpuType;
    
    // 根据 GPU 类型确定解码器优先级（与 Java 一致）
    QStringList decoderPriority;
    if (m_useH265) {
        // ⭐ H265 解码器优先级表在 h265support.cpp（nvh265dec/d3d11h265dec，软解 avdec_h265）
        decoderPriority = H265Support::decoderPriority(gpuType);
        qDebug() << "📋 H265 会话 - 解码器优先级:" << decoderPriority.join(" > ");
        H265Support::log(QString("解码器优先级 [%1 GPU]: %2 → 软解 %3")
            .arg(gpuType, decoderPriority.join(" > "), H265Support::softwareDecoderName()));
    } else if (gpuType == "NVIDIA") {
        decoderPriority << "nvh264dec" << "d3d11h264dec";
        qDebug() << "📋 NVIDIA GPU - 解码器优先级: nvh264dec > d3d11h264dec";
    } else if (gpuType == "AMD") {
        decoderPriority << "d3d11h264dec" << "amfh264dec";
        qDebug() << "📋 AMD GPU - 解码器优先级: d3d11h264dec > amfh264dec";
    } else if (gpuType == "Intel") {
        decoderPriority << "msdkh264dec" << "d3d11h264dec";
        qDebug() << "📋 Intel GPU - 解码器优先级: msdkh264dec > d3d11h264dec";
    } else {
        decoderPriority << "d3d11h264dec" << "nvh264dec" << "msdkh264dec";
        qDebug() << "📋 未知 GPU - 解码器优先级: d3d11h264dec > nvh264dec > msdkh264dec";
    }

    // 🔧 老旧 Intel 核显(legacy DXVA)/手动开关 → 强制软解：清空硬解优先级，直接落到 avdec_h264 回退分支
    //    (这类机器 d3d11 硬解会 "Could not determine decoder config" 黑屏；640x480 软解毫无压力)
    //    仅改解码器选择，下游显示/截图/慢放/NALU 支路逻辑完全不动
    if (shouldForceSoftwareDecode(g_lastGpuRawInfo)) {
        decoderPriority.clear();
        qDebug() << "🔧 强制软解：检测到老旧 Intel 核显或手动开关，跳过 d3d11 硬解，使用 avdec_h264";
        diagLog("🔧 强制软解：老旧 Intel 核显/手动开关 → 跳过硬解，使用 avdec_h264 软解");
    }
    
    // ⭐ 诊断：检查 GStreamer 插件注册表
    GstRegistry *registry = gst_registry_get();
    qDebug() << "📋 检查 GStreamer 插件注册表...";
    diagLog("📋 检查 GStreamer 插件注册表...");
    
    // ⭐ 列出所有已加载的插件
    GList *plugins = gst_registry_get_plugin_list(registry);
    int pluginCount = g_list_length(plugins);
    qDebug() << "📦 已加载插件总数:" << pluginCount;
    diagLog(QString("📦 已加载插件总数: %1").arg(pluginCount));
    
    // 列出前20个插件名称（诊断用）
    int i = 0;
    for (GList *l = plugins; l != nullptr && i < 20; l = l->next, i++) {
        GstPlugin *p = (GstPlugin *)l->data;
        const gchar *name = gst_plugin_get_name(p);
        const gchar *filename = gst_plugin_get_filename(p);
        diagLog(QString("   [%1] %2 -> %3").arg(i).arg(name, filename ? filename : "内置"));
    }
    if (pluginCount > 20) {
        diagLog(QString("   ... 还有 %1 个插件").arg(pluginCount - 20));
    }
    gst_plugin_list_free(plugins);
    
    // 检查关键插件是否已注册
    QStringList checkPlugins = {"libav", "nvcodec", "d3d11"};
    for (const QString &pluginName : checkPlugins) {
        GstPlugin *plugin = gst_registry_find_plugin(registry, pluginName.toUtf8().constData());
        if (plugin) {
            const gchar *filename = gst_plugin_get_filename(plugin);
            qDebug() << "   ✅ 插件" << pluginName << "已注册:" << (filename ? filename : "内置");
            diagLog(QString("   ✅ 插件 %1 已注册: %2").arg(pluginName, filename ? filename : "内置"));
            gst_object_unref(plugin);
        } else {
            qDebug() << "   ❌ 插件" << pluginName << "未注册！";
            diagLog(QString("   ❌ 插件 %1 未注册！").arg(pluginName));
        }
    }
    
    // 检查关键 element factory 是否存在
    QStringList checkElements = {"avdec_h264", "nvh264dec", "d3d11h264dec"};
    for (const QString &elementName : checkElements) {
        GstElementFactory *factory = gst_element_factory_find(elementName.toUtf8().constData());
        if (factory) {
            qDebug() << "   ✅ Element" << elementName << "可用";
            diagLog(QString("   ✅ Element %1 可用").arg(elementName));
            gst_object_unref(factory);
        } else {
            qDebug() << "   ❌ Element" << elementName << "不可用！";
            diagLog(QString("   ❌ Element %1 不可用！").arg(elementName));
        }
    }
    
    // 按优先级尝试硬件解码器
    for (const QString &decoderName : decoderPriority) {
        qDebug() << "   🔍 尝试:" << decoderName << "...";
        m_decoder = gst_element_factory_make(decoderName.toUtf8().constData(), "decoder");
        if (m_decoder) {
            m_decoderName = QString("%1 (%2 硬解)").arg(decoderName).arg(gpuType);
            m_useHardwareDecoder = true;
            qDebug() << "   ✅ 成功:" << decoderName;
            
            // ⭐ 防马赛克配置（按属性存在性设置）
            bool setDiscard = setBoolIfExists(m_decoder, "discard-corrupted-frames", TRUE);
            bool setOutput = setBoolIfExists(m_decoder, "output-corrupt", FALSE);
            
            // ⭐⭐⭐ 关键：自动请求同步点（与 Java 一致，防止微卡顿）
            GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(m_decoder), "automatic-request-sync-points");
            if (spec) {
                g_object_set(m_decoder, "automatic-request-sync-points", TRUE, nullptr);
                qDebug() << "✅ 解码器: automatic-request-sync-points=true（自动请求关键帧）";
            }
            
            qDebug() << "✅ 解码器防马赛克配置：丢弃损坏帧"
                     << "(discard=" << setDiscard << "output-corrupt=" << setOutput << ")";
            break;
        } else {
            qDebug() << "   ⚠️ 跳过:" << decoderName << "(不可用)";
        }
    }
    
    // 所有硬解都失败，回退到软解（H265 会话回退 avdec_h265）
    if (!m_decoder) {
        const char *swDec = m_useH265 ? H265Support::softwareDecoderName() : "avdec_h264";
        qDebug() << "⚠️ 所有硬件解码器不可用，回退到软件解码" << swDec << "...";
        m_decoder = gst_element_factory_make(swDec, "decoder");
        if (m_decoder) {
            m_decoderName = QString("%1 (FFmpeg 软解)").arg(swDec);
            m_useHardwareDecoder = false;
            qDebug() << "✅ 使用" << swDec << "软件解码";
            
            // 软解配置（按属性存在性设置）
            bool setSkip = setIntIfExists(m_decoder, "skip-frame", 0);      // 不跳帧
            bool setLowres = setIntIfExists(m_decoder, "lowres", 0);        // 不降低分辨率
            bool setOutput = setBoolIfExists(m_decoder, "output-corrupt", FALSE); // 不输出损坏帧
            qDebug() << "✅ 软解配置"
                     << "(skip=" << setSkip << "lowres=" << setLowres
                     << "output-corrupt=" << setOutput << ")";
            
            // ⭐⭐⭐ 关键：自动请求同步点（与 Java 一致，防止微卡顿）
            GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(m_decoder), "automatic-request-sync-points");
            if (spec) {
                g_object_set(m_decoder, "automatic-request-sync-points", TRUE, nullptr);
                qDebug() << "✅ 软解码器: automatic-request-sync-points=true（自动请求关键帧）";
            }
        }
    }
    
    if (!m_decoder) {
        qCritical() << "❌ 所有解码器都不可用！";
        diagLog("❌ 所有解码器都不可用！检查 GST_PLUGIN_PATH 和插件 DLL 依赖");
        emit error(m_useH265 ? "无可用的 H265 解码器" : "无可用的 H264 解码器");
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
        return false;
    }
    
    qDebug() << "🎯 最终解码器:" << m_decoderName;
    if (m_useH265) {
        H265Support::log(QString("最终解码器: %1").arg(m_decoderName));
    }
    
    // ⭐⭐⭐ 关键防马赛克队列 2：解码后缓冲（与 Java 一致）
    m_queueDecode = gst_element_factory_make("queue", "queue_decode");
    if (m_queueDecode) {
        // 至少25帧缓冲（与 Java 一致）
        g_object_set(m_queueDecode,
            "max-size-buffers", 25,           // ⭐ 25帧缓冲（平滑解码波动）
            "max-size-bytes", 0,              // 不限制字节
            "max-size-time", 0,               // 不限制时间，只限制帧数
            "leaky", 2,                       // 丢弃老帧，保持最新帧
            "silent", FALSE,                  // ⭐ 开启日志，诊断丢帧
            "flush-on-eos", TRUE,
            nullptr);
        
        // ⭐ 监听 overrun 信号（队列满时触发）
        g_signal_connect(m_queueDecode, "overrun", G_CALLBACK(+[](GstElement*, gpointer) {
            diagLog("⚠️ queueDecode OVERRUN - 解码队列满，可能丢帧！");
        }), nullptr);
        g_signal_connect(m_queueDecode, "underrun", G_CALLBACK(+[](GstElement*, gpointer) {
            g_srtDecodeUnderrun.fetch_add(1);
            diagLog("⚠️ queueDecode UNDERRUN - 解码队列空！");
        }), nullptr);
        
        qDebug() << "⭐ queueDecode: buffers=25, leaky=2（防马赛克关键）";
        diagLog("✅ queueDecode 已创建: buffers=25, leaky=2");
    }
    
    // ⭐ 硬解需要 d3d11download（GPU→CPU），软解不需要
    if (m_useHardwareDecoder) {
        m_download = gst_element_factory_make("d3d11download", "download");
        if (!m_download) {
            qWarning() << "⚠️ d3d11download 不可用，回退到软解...";
            // 释放硬解解码器，重新尝试软解（H265 会话回退 avdec_h265）
            const char *swDec2 = m_useH265 ? H265Support::softwareDecoderName() : "avdec_h264";
            gst_object_unref(m_decoder);
            m_decoder = gst_element_factory_make(swDec2, "decoder");
            if (!m_decoder) {
                qCritical() << "❌" << swDec2 << "也不可用";
                emit error(m_useH265 ? "无可用的 H265 解码器" : "无可用的 H264 解码器");
                gst_object_unref(m_pipeline);
                m_pipeline = nullptr;
                return false;
            }
            m_decoderName = QString("%1 (FFmpeg 软解)").arg(swDec2);
            m_useHardwareDecoder = false;
            qDebug() << "✅ 回退到" << swDec2 << "软件解码";
        } else {
            qDebug() << "✅ d3d11download 创建成功（硬解 GPU→CPU）";
        }
    } else {
        m_download = nullptr;  // 软解不需要 download
        qDebug() << "ℹ️ 软解模式，跳过 d3d11download";
    }
    
    // ========== 创建 videoscale（处理动态分辨率变化，防绿幕）==========
    m_videoScale = gst_element_factory_make("videoscale", "video_scale");
    if (!m_videoScale) {
        qWarning() << "⚠️ 创建 videoscale 元素失败，分辨率变化时可能绿幕";
    } else {
        // 配置 videoscale：使用双线性插值，允许任意分辨率
        g_object_set(m_videoScale,
            "method", 1,  // 1 = bilinear（双线性插值，质量/速度平衡）
            "add-borders", FALSE,  // 不添加黑边
            nullptr);
        qDebug() << "✅ videoscale 创建成功（处理动态分辨率变化）";
    }
    
    // ========== 创建图像调节元素 ==========
    m_videoBalance = gst_element_factory_make("videobalance", "video_balance");
    m_gamma = gst_element_factory_make("gamma", "gamma");
    if (!m_videoBalance || !m_gamma) {
        qCritical() << "❌ 创建 videobalance 或 gamma 元素失败";
        emit error("创建图像调节元素失败");
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
        return false;
    }
    
    // ⭐ 临时禁用 PC 端后期色彩调整 — 用于对比 iOS 原画效果, 代码保留可随时恢复
    //   videobalance / gamma 元素仍在管线中, 但走 GStreamer 默认中性值
    //   (brightness=0, contrast=1.0, saturation=1.0, hue=0, gamma=1.0) → 不做任何颜色处理
    qDebug() << "⚪ [Filter] PC 后期色彩调整已禁用 (videobalance/gamma 走中性默认值)";
    /*
    // 初始化默认值（与 CaptureManager 保持一致）
    g_object_set(m_videoBalance,
        "brightness", -0.02, // -1.0 ~ 1.0（默认 -0.02）
        "contrast", 1.10,    // 0.0 ~ 2.0（默认 1.10）
        "saturation", 1.10,  // 0.0 ~ 2.0（默认 1.10）
        "hue", -0.02,        // -1.0 ~ 1.0（默认 -0.02）
        nullptr);
    g_object_set(m_gamma,
        "gamma", 1.08,       // 0.01 ~ 10.0（默认 1.08）
        nullptr);
    qDebug() << "✅ videobalance 和 gamma 元素已创建并初始化（对比度=1.10, 饱和度=1.10, 伽马=1.08）";
    */
    
    // ========== 显示分支元素 ==========
    m_displayQueue = gst_element_factory_make("queue", "display_queue");
    m_clockSync = nullptr;
    m_convert = gst_element_factory_make("videoconvert", "convert");
    m_appsink = gst_element_factory_make("appsink", "sink");

    if (!createH264FrameBranch()) {
        destroyPipeline();
        return false;
    }

    // 检查所有元素
    // MARK: SRT (independent)
    // SRT 模式：源元素（srtsrc/tsdemux）由 GstSrtSource::build 在链接阶段创建，
    // 此处无 webrtcbin/appsrc，源可用性已在上方 pluginsAvailable 校验过，故视为 OK。
    bool srcOk = m_useSRT ? true
                          : (m_useWebRTC ? (m_webrtcbin && m_rtph264depay) : (m_appsrc != nullptr));
    if (!srcOk || !m_h264parse || !m_naluTee || !m_naluQueue || !m_naluAppsink
        || !m_queueDepay || !m_decoder || !m_queueDecode ||
        !m_displayQueue || !m_convert || !m_appsink ||
        !m_rawFrameTee || !m_h264FrameQueue || !m_h264FrameConvert || !m_h264FrameEncoder
        || !m_h264FrameParse || !m_h264FrameCaps || !m_h264FrameAppsink ||
        !m_videoBalance || !m_gamma) {
        qCritical() << "❌ 创建 GStreamer 元素失败";
        emit error("创建 GStreamer 元素失败");
        destroyPipeline();
        return false;
    }
    
    // ========== 配置源元素 ==========
    // MARK: SRT (independent)
    // SRT 模式：源（srtsrc/tsdemux）由 GstSrtSource::build 创建/配置，此处不配置 appsrc/webrtcbin。
    if (m_useSRT) {
        // no-op：SRT 源在链接阶段由 m_srtSource.build() 配置。
    } else if (m_useWebRTC) {
        // WebRTC 模式：设置 webrtcbin 信号
        setupWebRTCSignals();
    } else {
        // 传统模式：配置 appsrc
        g_object_set(m_appsrc,
            "stream-type", 0,
            "format", GST_FORMAT_TIME,
            "is-live", TRUE,
            "do-timestamp", TRUE,
            nullptr);
        
        GstCaps *srcCaps = gst_caps_new_simple("video/x-h264",
            "stream-format", G_TYPE_STRING, "byte-stream",
            "alignment", G_TYPE_STRING, "au",
            nullptr);
        g_object_set(m_appsrc, "caps", srcCaps, nullptr);
        gst_caps_unref(srcCaps);
    }
    
    // ========== 配置显示分支（根据机型自适应配置）==========
    // ⚡ 优化延迟与抖动容忍度的平衡
    // 根据内存和 CPU 动态调整显示缓冲
    long memoryGB = getSystemMemoryGB();
    int cpuCores = getCore();
    bool isLowEndCPU = cpuCores <= 6;
    
    int displayBuffers;
    if (memoryGB <= 8 || isLowEndCPU) {
        displayBuffers = 5;   // 🔥 低端机：5帧=166ms@30fps（最小稳定缓冲）
        qDebug() << "🔥 低端机配置: 显示缓冲=" << displayBuffers << "帧";
        diagLog(QString("📺 displayQueue: %1 帧（低端机配置）").arg(displayBuffers));
    } else if (memoryGB < 16) {
        displayBuffers = 3;   // 🔧 中端机：3帧=50ms@60fps（与Java一致）
        qDebug() << "🔧 中端机配置: 显示缓冲=" << displayBuffers << "帧";
        diagLog(QString("📺 displayQueue: %1 帧（中端机配置）").arg(displayBuffers));
    } else {
        displayBuffers = 2;   // 🎯 高端机：2帧=33ms@60fps（与Java一致）
        qDebug() << "🎯 高端机配置: 显示缓冲=" << displayBuffers << "帧";
        diagLog(QString("📺 displayQueue: %1 帧（高端机配置）").arg(displayBuffers));
    }
    
    g_object_set(m_displayQueue,
        "max-size-buffers", displayBuffers,
        "max-size-bytes", 0,
        "max-size-time", 0,  // 不限制时间
        "leaky", 2,  // ⭐ 保持leaky=2，防止延迟累积
        "silent", TRUE,
        "flush-on-eos", TRUE,
        nullptr);
    
    // 🔥🔥🔥 v10超低延迟方案（平衡版）：150-300ms延迟，兼顾平滑
    // 核心：小缓冲 + PTS漂移检测 + 定时渲染
    // jitterbuffer(100ms) + 应用层(≤5帧) = 目标延迟 ~200-300ms
    qDebug() << "⭐ v10平衡方案: jitterbuffer(100ms) + appsink(max-buffers=" << QUEUE_ABSOLUTE_MAX << ")";
    diagLog(QString("✅ v10平衡方案: jitterbuffer(100ms) → 解码 → appsink(max-buffers=%1)").arg(QUEUE_ABSOLUTE_MAX));
    
    // 🔥 v10: appsink 缓冲与应用层队列一致
    g_object_set(m_appsink,
        "emit-signals", TRUE,
        "sync", FALSE,            // 不做时间戳同步（在应用层用定时器+PTS校准）
        "async", FALSE,
        "max-buffers", QUEUE_ABSOLUTE_MAX,  // 🔥 v10: 与 QUEUE_ABSOLUTE_MAX 保持一致
        "drop", TRUE,             // 满了丢弃老帧，防止堆积
        nullptr);
    
    qDebug() << "⭐ v10配置: appsink max-buffers=" << QUEUE_ABSOLUTE_MAX << " + PTS漂移检测 + 定时渲染";
    diagLog(QString("✅ v10方案: appsink(max-buffers=%1) + jitterbuffer(100ms) + 定时渲染").arg(QUEUE_ABSOLUTE_MAX));
    
    GstCaps *sinkCaps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "BGRA",
        "colorimetry", G_TYPE_STRING, "4:4:7:1",
        nullptr);
    gst_app_sink_set_caps(GST_APP_SINK(m_appsink), sinkCaps);
    gst_caps_unref(sinkCaps);
    qDebug() << "✅ appsink caps: BGRA + BT.709 full-range (4:4:7:1)";
    
    g_signal_connect(m_appsink, "new-sample", G_CALLBACK(onNewSample), this);
    
    // ========== Bus Sync Handler ==========
    GstBus *bus = gst_element_get_bus(m_pipeline);
    gst_bus_set_sync_handler(bus, onBusSyncMessage, this, nullptr);
    gst_object_unref(bus);
    
    // ========== 添加所有元素到 Pipeline ==========
    // MARK: SRT (independent)
    if (m_useSRT) {
        // SRT 模式：共享尾段（h264parse→naluTee→解码→显示+截图/慢放）与 WebRTC 完全一致，
        // 仅源头换成 srtsrc→tsdemux（由 GstSrtSource 创建/链接，封装在独立文件）。
        if (m_useHardwareDecoder && m_download) {
            gst_bin_add_many(GST_BIN(m_pipeline),
                m_h264parse, m_naluTee, m_naluQueue, m_naluAppsink,
                m_queueDepay, m_decoder, m_queueDecode,
                m_download, m_videoScale, m_videoBalance, m_gamma, m_rawFrameTee,
                m_displayQueue, m_convert, m_appsink,
                m_h264FrameQueue, m_h264FrameConvert, m_h264FrameEncoder, m_h264FrameParse,
                m_h264FrameCaps, m_h264FrameAppsink,
                nullptr);

            if (!linkNaluTeeBranch()
                || !gst_element_link_many(m_queueDepay, m_decoder, m_queueDecode,
                                       m_download, m_videoScale, m_videoBalance, m_gamma, nullptr)
                || !linkRawFrameTeeBranch(m_gamma, m_displayQueue)) {
                qCritical() << "❌ 链接主路径失败 (SRT 硬解模式)";
                emit error("链接主路径失败");
                destroyPipeline();
                return false;
            }
            qDebug() << "✅ SRT 硬解尾段就绪：parse→tee(main→decode, store→appsink)";
        } else {
            gst_bin_add_many(GST_BIN(m_pipeline),
                m_h264parse, m_naluTee, m_naluQueue, m_naluAppsink,
                m_queueDepay, m_decoder, m_queueDecode,
                m_videoScale, m_videoBalance, m_gamma, m_rawFrameTee,
                m_displayQueue, m_convert, m_appsink,
                m_h264FrameQueue, m_h264FrameConvert, m_h264FrameEncoder, m_h264FrameParse,
                m_h264FrameCaps, m_h264FrameAppsink,
                nullptr);

            if (!linkNaluTeeBranch()
                || !gst_element_link_many(m_queueDepay, m_decoder, m_queueDecode,
                                       m_videoScale, m_videoBalance, m_gamma, nullptr)
                || !linkRawFrameTeeBranch(m_gamma, m_displayQueue)) {
                qCritical() << "❌ 链接主路径失败 (SRT 软解模式)";
                emit error("链接主路径失败");
                destroyPipeline();
                return false;
            }
            qDebug() << "✅ SRT 软解尾段就绪：parse→tee(main→decode, store→appsink)";
        }

        // 源头：srtsrc→tsdemux，动态把视频 pad 链到 m_h264parse（独立文件实现）。
        srtLog(QString("[build] 调用 GstSrtSource::build uri=%1").arg(m_srtUri));
        if (!m_srtSource.build(GST_BIN(m_pipeline), m_h264parse, m_srtUri)) {
            qCritical() << "❌ 创建 SRT 源失败";
            srtLog("[build] ❌ GstSrtSource::build 失败");
            emit error("创建 SRT 源失败");
            destroyPipeline();
            return false;
        }
        srtLog("[build] ✅ srtsrc→tsdemux 就绪，等待视频 pad");

        // ⭐⭐⭐ 关键修复：SRT 模式的「帧到达统计」probe 必须挂在 h264parse 的 src pad。
        // 原 WebRTC 把统计 probe 挂在 rtph264depay（SRT 无此元素），导致 SRT 模式
        // m_currentSecondFrames 永远=0 → 收=0fps → 自适应队列目标乱跳 → 队列震荡 → 碎花。
        // 挂在 h264parse src（解码前、已分帧）位置统计帧数 + IDR，与 WebRTC 等价。
        {
            GstPad *parseSrcPad = gst_element_get_static_pad(m_h264parse, "src");
            if (parseSrcPad) {
                // 用 SRT 专用的 m_srtParseProbeId（不复用 WebRTC 的 m_depayProbeId），彻底解耦。
                m_srtParseProbeId = gst_pad_add_probe(parseSrcPad, GST_PAD_PROBE_TYPE_BUFFER,
                    [](GstPad*, GstPadProbeInfo* info, gpointer userData) -> GstPadProbeReturn {
                        GstPlayer* self = static_cast<GstPlayer*>(userData);
                        GstBuffer* buffer = GST_PAD_PROBE_INFO_BUFFER(info);
                        if (!buffer) return GST_PAD_PROBE_OK;
                        self->m_totalFrameCount.fetch_add(1);
                        self->m_currentSecondFrames++;
                        if (hasIdrInBuffer(buffer)) {
                            self->m_preDecodeIdr.store(true);
                        }
                        return GST_PAD_PROBE_OK;  // 不丢帧，只统计
                    }, this, nullptr);
                gst_object_unref(parseSrcPad);
                qDebug() << "✅ SRT 统计probe挂在 h264parse src（修复 收=0fps）";
                srtLog("[build] ✅ 统计probe已挂 h264parse src（fps/IDR 统计生效）");
            }
        }

        captureDebugLog("GST", "SRT pipeline linked (srtsrc→tsdemux→parse→naluTee, shared tail)");
        qDebug() << "✅ GStreamer SRT Pipeline 创建成功，解码器:" << m_decoderName;
        emit decoderChanged();
        return true;
    }

    if (m_useWebRTC) {
        // WebRTC 模式（配合 200ms + videorate 方案）
        if (m_useHardwareDecoder && m_download) {
            // 硬解：webrtcbin → rtph264depay → h264parse → queueDepay → decoder → queueDecode → download → videoscale → ...
            gst_bin_add_many(GST_BIN(m_pipeline),
                m_webrtcbin, m_rtph264depay, m_h264parse, m_naluTee, m_naluQueue, m_naluAppsink,
                m_queueDepay, m_decoder, m_queueDecode,
                m_download, m_videoScale, m_videoBalance, m_gamma, m_rawFrameTee,
                m_displayQueue, m_convert, m_appsink,
                m_h264FrameQueue, m_h264FrameConvert, m_h264FrameEncoder, m_h264FrameParse,
                m_h264FrameCaps, m_h264FrameAppsink,
                nullptr);

            if (!gst_element_link(m_rtph264depay, m_h264parse) || !linkNaluTeeBranch()
                || !gst_element_link_many(m_queueDepay, m_decoder, m_queueDecode,
                                       m_download, m_videoScale, m_videoBalance, m_gamma, nullptr)
                || !linkRawFrameTeeBranch(m_gamma, m_displayQueue)) {
                qCritical() << "❌ 链接主路径失败 (WebRTC 硬解模式)";
                emit error("链接主路径失败");
                destroyPipeline();
                return false;
            }
            qDebug() << "✅ WebRTC 硬解：depay→parse→tee(main→decode, store→appsink)";
        } else {
            // 软解：webrtcbin → rtph264depay → h264parse → queueDepay → decoder → queueDecode → videoscale → videoBalance → ...
            gst_bin_add_many(GST_BIN(m_pipeline),
                m_webrtcbin, m_rtph264depay, m_h264parse, m_naluTee, m_naluQueue, m_naluAppsink,
                m_queueDepay, m_decoder, m_queueDecode,
                m_videoScale, m_videoBalance, m_gamma, m_rawFrameTee,
                m_displayQueue, m_convert, m_appsink,
                m_h264FrameQueue, m_h264FrameConvert, m_h264FrameEncoder, m_h264FrameParse,
                m_h264FrameCaps, m_h264FrameAppsink,
                nullptr);

            if (!gst_element_link(m_rtph264depay, m_h264parse) || !linkNaluTeeBranch()
                || !gst_element_link_many(m_queueDepay, m_decoder, m_queueDecode,
                                       m_videoScale, m_videoBalance, m_gamma, nullptr)
                || !linkRawFrameTeeBranch(m_gamma, m_displayQueue)) {
                qCritical() << "❌ 链接主路径失败 (WebRTC 软解模式)";
                emit error("链接主路径失败");
                destroyPipeline();
                return false;
            }
            qDebug() << "✅ WebRTC 软解：depay→parse→tee(main→decode, store→appsink)";
        }
        
        // 🔥🔥🔥 v9.3双缓冲：简化probe，只做统计，不丢帧（对齐copygstream）
        // copygstream 版本不做帧丢弃，依赖解码器自身处理
        GstPad *depaySrcPad = gst_element_get_static_pad(m_rtph264depay, "src");
        if (depaySrcPad) {
            m_depayProbeId = gst_pad_add_probe(depaySrcPad, GST_PAD_PROBE_TYPE_BUFFER,
                [](GstPad*, GstPadProbeInfo* info, gpointer userData) -> GstPadProbeReturn {
                    GstPlayer* self = static_cast<GstPlayer*>(userData);
                    GstBuffer* buffer = GST_PAD_PROBE_INFO_BUFFER(info);
                    if (!buffer) return GST_PAD_PROBE_OK;
                    
                    // 统计（始终执行）
                    self->m_totalFrameCount.fetch_add(1);
                    self->m_currentSecondFrames++;  // 帧到达计数
                    
                    // 检测 IDR 帧（仅用于统计；H265 会话用 IRAP 判断，见 h265support.cpp）
                    bool isIdr = self->m_useH265 ? H265Support::hasKeyframeInBuffer(buffer)
                                                 : hasIdrInBuffer(buffer);
                    if (isIdr) {
                        self->m_preDecodeIdr.store(true);
                    }

                    // ⭐ H265 收流诊断：确认 RTP 是否到达 rtph265depay src、是否收到关键帧(IRAP)。
                    //   若「已收 N 帧」一直涨但从没「关键帧(IRAP)」→ iOS 没发 IDR / PC PLI 没生效
                    //     → rtph265depay(wait-for-keyframe=TRUE) 会一直等、不往下解码 = 无首帧。
                    //   若连「已收 N 帧」都不出现 → H265 RTP 根本没到 depay（协商/收流问题）。
                    if (self->m_useH265) {
                        H265Support::noteDepayOutput();  // 喂收流入口探针的“零输出”兜底判断
                        // ⭐ 兜底放行后仍未见 IRAP：每秒催一次 PLI。
                        //   否则只能干等 Android 的周期关键帧（实测 pad-added→首帧要 12s，
                        //   其中 9s 是放行后没人催帧在空等），催帧后应缩到 2~3s。
                        if (!self->m_preDecodeIdr.load()) {
                            const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
                            if (nowMs - self->m_h265NoIrapPliMs >= 1000) {
                                self->m_h265NoIrapPliMs = nowMs;
                                QMetaObject::invokeMethod(self, "requestKeyFrame", Qt::QueuedConnection);
                                H265Support::log("[催帧] depay 已放行但尚未解出 IRAP → 发 PLI 催发送端出关键帧");
                            }
                        }
                        const int total = self->m_totalFrameCount.load();
                        const gsize sz = gst_buffer_get_size(buffer);
                        if (isIdr) {
                            H265Support::log(QString("[收流] rtph265depay 收到关键帧(IRAP)! 累计=%1帧 本帧=%2字节 → 应可开始解码").arg(total).arg(sz));
                        } else if (total <= 3 || (total % 120) == 0) {
                            H265Support::log(QString("[收流] rtph265depay 已收 %1 帧(本帧%2字节)，尚未见IRAP → 若持续无IRAP=iOS未发IDR/PLI未生效，depay 一直等关键帧不解码").arg(total).arg(sz));
                        }
                    }
                    
                    // 🔥 v9.3: 所有帧都通过，不丢弃任何帧
                    return GST_PAD_PROBE_OK;
                    
                }, this, nullptr);
            gst_object_unref(depaySrcPad);
            qDebug() << "✅ v9.3 简化probe（只统计不丢帧）";
        }

        // ⭐ H265 收流入口探针（depay sink）：逐包解析 RTP 载荷 NAL 类型 + 零输出兜底
        //   （2026-07-08 Android H265 黑屏定位：pad-added 有流但 depay 零输出，看它到底收到了什么）
        if (m_useH265 && m_rtph264depay) {
            H265Support::attachRtpInputProbe(m_rtph264depay);
        }

        captureDebugLog("GST", "WebRTC pipeline linked with NALU tee branch (no sync probe on live path)");
        
        diagLog(QString("✅ 管道已创建, 解码器: %1").arg(m_decoderName));
    } else {
        // 传统模式（AppSrc，配合 200ms + videorate 方案）
        if (m_useHardwareDecoder && m_download) {
            gst_bin_add_many(GST_BIN(m_pipeline),
                m_appsrc, m_h264parse, m_naluTee, m_naluQueue, m_naluAppsink,
                m_queueDepay, m_decoder, m_queueDecode,
                m_download, m_videoScale, m_videoBalance, m_gamma, m_rawFrameTee,
                m_displayQueue, m_convert, m_appsink,
                m_h264FrameQueue, m_h264FrameConvert, m_h264FrameEncoder, m_h264FrameParse,
                m_h264FrameCaps, m_h264FrameAppsink,
                nullptr);

            if (!gst_element_link(m_appsrc, m_h264parse) || !linkNaluTeeBranch()
                || !gst_element_link_many(m_queueDepay, m_decoder, m_queueDecode,
                                       m_download, m_videoScale, m_videoBalance, m_gamma, nullptr)
                || !linkRawFrameTeeBranch(m_gamma, m_displayQueue)) {
                qCritical() << "❌ 链接主路径失败 (AppSrc 硬解模式)";
                emit error("链接主路径失败");
                destroyPipeline();
                return false;
            }
            qDebug() << "✅ AppSrc 硬解：src→parse→tee(main→decode, store→appsink)";
        } else {
            gst_bin_add_many(GST_BIN(m_pipeline),
                m_appsrc, m_h264parse, m_naluTee, m_naluQueue, m_naluAppsink,
                m_queueDepay, m_decoder, m_queueDecode,
                m_videoScale, m_videoBalance, m_gamma, m_rawFrameTee,
                m_displayQueue, m_convert, m_appsink,
                m_h264FrameQueue, m_h264FrameConvert, m_h264FrameEncoder, m_h264FrameParse,
                m_h264FrameCaps, m_h264FrameAppsink,
                nullptr);

            if (!gst_element_link(m_appsrc, m_h264parse) || !linkNaluTeeBranch()
                || !gst_element_link_many(m_queueDepay, m_decoder, m_queueDecode,
                                       m_videoScale, m_videoBalance, m_gamma, nullptr)
                || !linkRawFrameTeeBranch(m_gamma, m_displayQueue)) {
                qCritical() << "❌ 链接主路径失败 (AppSrc 软解模式)";
                emit error("链接主路径失败");
                destroyPipeline();
                return false;
            }
            qDebug() << "✅ AppSrc 软解：src→parse→tee(main→decode, store→appsink)";
        }
        captureDebugLog("GST", "AppSrc pipeline linked with NALU tee branch");
    }

    qDebug() << "✅ GStreamer Pipeline 创建成功，解码器:" << m_decoderName;
    emit decoderChanged();

    return true;
}

QImage GstPlayer::grabCurrentFrame()
{
    if (!m_lastValidSample) return QImage();

    GstBuffer *buffer = gst_sample_get_buffer(m_lastValidSample);
    GstCaps *caps = gst_sample_get_caps(m_lastValidSample);
    if (!buffer || !caps) return QImage();

    GstStructure *s = gst_caps_get_structure(caps, 0);
    int w = 0, h = 0;
    gst_structure_get_int(s, "width", &w);
    gst_structure_get_int(s, "height", &h);
    if (w <= 0 || h <= 0) return QImage();

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) return QImage();

    QImage img(w, h, QImage::Format_ARGB32);
    int srcStride = w * 4;
    int dstStride = img.bytesPerLine();
    if (srcStride == dstStride) {
        memcpy(img.bits(), map.data, qMin(map.size, (gsize)(h * dstStride)));
    } else {
        for (int y = 0; y < h; y++) {
            memcpy(img.bits() + y * dstStride, map.data + y * srcStride, srcStride);
        }
    }
    gst_buffer_unmap(buffer, &map);
    return img;
}

// ⭐⭐⭐ §56.7（2026-08-06）后台销毁管线 —— 治「退出登录/切换后主程序整个卡死」：
//   客户实测 bk.txt：14:33:11 退出登录打印「⏹️ GstPlayer 停止播放」后主线程再无任何日志，
//   81 秒后仅剩 GStreamer 回调线程一条「WebRTC 连接状态: Failed」→ 主线程冻死在
//   gst_element_set_state(pipeline, GST_STATE_NULL) 里（webrtcbin 的 DTLS/ICE 拆除 +
//   内部线程 join 可能无限期阻塞）。
//   修法：WebRTC 管线的 NULL 切换 + unref 全部移交独立后台线程，GUI 主线程永不等待；
//   线程自持引用，管线生命周期安全。SRT/普通管线保持原同步行为（多年验证无此问题）。
//  （定义必须在 destroyPipeline/stop 两个调用点之前，否则 C3861 找不到标识符）
static void asyncStopAndUnrefPipeline(GstElement *pipeline, const char *tag)
{
    if (!pipeline) return;
    std::thread([pipeline, tag]() {
        qDebug() << "🧹 [异步销毁]" << tag << ": 后台线程开始 set_state(NULL)...";
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        qDebug() << "🧹 [异步销毁]" << tag << ": 管线已停止并释放";
    }).detach();
}

void GstPlayer::destroyPipeline()
{
    QMutexLocker lock(&m_mutex);
    
    // 🔥 v10.4: 移除解码前 probe（WebRTC/SRS 路径）
    if (m_depayProbeId != 0 && m_rtph264depay) {
        GstPad *depaySrcPad = gst_element_get_static_pad(m_rtph264depay, "src");
        if (depaySrcPad) {
            gst_pad_remove_probe(depaySrcPad, m_depayProbeId);
            gst_object_unref(depaySrcPad);
        }
        m_depayProbeId = 0;
    }

    // SRT 专用：移除挂在 h264parse src 的统计 probe（与 WebRTC 清理解耦，互不影响）
    if (m_srtParseProbeId != 0 && m_h264parse) {
        GstPad *parseSrcPad = gst_element_get_static_pad(m_h264parse, "src");
        if (parseSrcPad) {
            gst_pad_remove_probe(parseSrcPad, m_srtParseProbeId);
            gst_object_unref(parseSrcPad);
        }
        m_srtParseProbeId = 0;
    }
    m_srtInitialCropDone = false;

    if (m_naluTee && m_naluTeePadMain) {
        gst_element_release_request_pad(m_naluTee, m_naluTeePadMain);
        gst_object_unref(m_naluTeePadMain);
        m_naluTeePadMain = nullptr;
    }
    if (m_naluTee && m_naluTeePadStore) {
        gst_element_release_request_pad(m_naluTee, m_naluTeePadStore);
        gst_object_unref(m_naluTeePadStore);
        m_naluTeePadStore = nullptr;
    }
    if (m_rawFrameTee && m_rawFrameTeePadDisplay) {
        gst_element_release_request_pad(m_rawFrameTee, m_rawFrameTeePadDisplay);
        gst_object_unref(m_rawFrameTeePadDisplay);
        m_rawFrameTeePadDisplay = nullptr;
    }
    if (m_rawFrameTee && m_rawFrameTeePadSave) {
        gst_element_release_request_pad(m_rawFrameTee, m_rawFrameTeePadSave);
        gst_object_unref(m_rawFrameTeePadSave);
        m_rawFrameTeePadSave = nullptr;
    }

    // MARK: SRT (independent) —— pipeline 置 NULL 前先让 SRT 源置空内部指针
    m_srtSource.teardown(m_pipeline ? GST_BIN(m_pipeline) : nullptr);

    if (m_pipeline) {
        if (m_webrtcbin) {
            // §56.7 WebRTC 管线改后台异步销毁（同步 NULL 会冻死 GUI 主线程，见 stop() 注释）。
            //   移交前摘掉所有指回 this 的回调/总线处理器——旧管线在后台垂死期间
            //   不得再回调进本对象，避免污染紧接着重建的新会话。
            if (m_appsink)          g_signal_handlers_disconnect_by_data(m_appsink, this);
            if (m_naluAppsink)      g_signal_handlers_disconnect_by_data(m_naluAppsink, this);
            if (m_encodeAppsink)    g_signal_handlers_disconnect_by_data(m_encodeAppsink, this);
            if (m_h264FrameAppsink) g_signal_handlers_disconnect_by_data(m_h264FrameAppsink, this);
            g_signal_handlers_disconnect_by_data(m_webrtcbin, this);
            GstBus *bus = gst_element_get_bus(m_pipeline);
            if (bus) {
                gst_bus_set_sync_handler(bus, nullptr, nullptr, nullptr);
                gst_object_unref(bus);
            }
            asyncStopAndUnrefPipeline(m_pipeline, "destroy(webrtc)");  // 接管所有权
            m_pipeline = nullptr;
        } else {
            gst_element_set_state(m_pipeline, GST_STATE_NULL);
            gst_object_unref(m_pipeline);
            m_pipeline = nullptr;
        }
    }
    
    // 元素已经被 Pipeline 管理，不需要单独释放
    m_appsrc = nullptr;
    m_webrtcbin = nullptr;     // ⭐ WebRTC 元素
    m_rtpJitterBuffer = nullptr; // ⭐ 随管线销毁置空，避免悬空（不持有所有权）
    m_rtph264depay = nullptr;  // ⭐ WebRTC 元素
    m_currentRemoteIceUfrag.clear();  // ⭐ 重建后首个 fresh offer 不被误判为切网重协商
    m_h264parse = nullptr;
    m_naluTee = nullptr;
    m_naluQueue = nullptr;
    m_naluAppsink = nullptr;
    m_queueDepay = nullptr;    // ⭐ 解码前缓冲队列
    m_decoder = nullptr;
    m_queueDecode = nullptr;   // ⭐ 解码后缓冲队列
    m_download = nullptr;
    m_videoScale = nullptr;    // ⭐ 动态分辨率处理
    m_videoBalance = nullptr;
    m_gamma = nullptr;
    m_displayQueue = nullptr;
    m_clockSync = nullptr;
    m_rawFrameTee = nullptr;
    m_h264FrameQueue = nullptr;
    m_h264FrameConvert = nullptr;
    m_h264FrameEncoder = nullptr;
    m_h264FrameParse = nullptr;
    m_h264FrameCaps = nullptr;
    m_h264FrameAppsink = nullptr;
    m_h264FrameEncoderName.clear();
    m_convert = nullptr;
    m_appsink = nullptr;
    
    // ⭐ 重置 transceiver 标志（下次连接需要重新添加）
    m_transceiverAdded = false;
    
    // 重置 AVCC→Annex-B 状态（下次连接重新提取 SPS/PPS）
    m_spsPpsAnnexB.clear();
    m_nalLengthSize = 4;

    // 🔥 v10.3: 重置防花屏状态
    m_waitingForKeyframe.store(false);
    m_preDecodeDiscont.store(false);
    m_preDecodeIdr.store(false);
    m_consecutiveGoodFrames.store(0);
    m_pliRequestCount = 0;
    
    m_videoWidth = 0;
    m_videoHeight = 0;
    m_frameIndex = 0;
    m_naluFrameIndex.store(0, std::memory_order_release);
    m_firstFrame = false;
    resetH264FrameState();

    destroyEncodePipeline();
}

void GstPlayer::createEncodePipeline()
{
    if (m_encodePipeline) return;

    QString desc =
        "appsrc name=enc_src is-live=true format=3 "
        "! h264parse "
        "! avdec_h264 "
        "! videoconvert "
        "! mfh264enc gop-size=1 bitrate=30000 max-bitrate=120000 qp-i=18 low-latency=true quality-vs-speed=0 "
        "! h264parse name=enc_parse config-interval=-1 "
        "! appsink name=enc_sink emit-signals=true sync=false async=false max-buffers=2 drop=true";

    GError *err = nullptr;
    m_encodePipeline = gst_parse_launch(desc.toUtf8().constData(), &err);
    if (err) {
        captureDebugLog("GST", QString("createEncodePipeline FAIL: %1").arg(err->message));
        qDebug() << "❌ Encode pipeline failed:" << err->message;
        g_error_free(err);
        if (m_encodePipeline) { gst_object_unref(m_encodePipeline); m_encodePipeline = nullptr; }
        return;
    }

    m_encodeAppsrc = gst_bin_get_by_name(GST_BIN(m_encodePipeline), "enc_src");
    m_encodeAppsink = gst_bin_get_by_name(GST_BIN(m_encodePipeline), "enc_sink");

    GstCaps *srcCaps = gst_caps_from_string(
        "video/x-h264, stream-format=byte-stream, alignment=au");
    g_object_set(m_encodeAppsrc, "caps", srcCaps, nullptr);
    gst_caps_unref(srcCaps);

    GstCaps *sinkCaps = gst_caps_from_string(
        "video/x-h264, stream-format=byte-stream, alignment=au");
    gst_app_sink_set_caps(GST_APP_SINK(m_encodeAppsink), sinkCaps);
    gst_caps_unref(sinkCaps);

    g_signal_connect(m_encodeAppsink, "new-sample", G_CALLBACK(onEncodedSample), this);

    GstStateChangeReturn ret = gst_element_set_state(m_encodePipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        captureDebugLog("GST", "createEncodePipeline FAIL: set_state PLAYING failed");
        destroyEncodePipeline();
        return;
    }

    m_useIntraEncode = true;
    m_encodePts = 0;
    captureDebugLog("GST", "createEncodePipeline OK (separate pipeline: mfh264enc gop=1)");
    qDebug() << "✅ Separate intra-encode pipeline created (mfh264enc)";
}

void GstPlayer::destroyEncodePipeline()
{
    m_useIntraEncode = false;
    if (m_encodePipeline) {
        gst_element_set_state(m_encodePipeline, GST_STATE_NULL);
    }
    if (m_encodeAppsrc) { gst_object_unref(m_encodeAppsrc); m_encodeAppsrc = nullptr; }
    if (m_encodeAppsink) { gst_object_unref(m_encodeAppsink); m_encodeAppsink = nullptr; }
    if (m_encodePipeline) { gst_object_unref(m_encodePipeline); m_encodePipeline = nullptr; }
    m_encodePts = 0;
}

GstFlowReturn GstPlayer::onEncodedSample(GstAppSink *sink, gpointer userData)
{
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_OK;

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    if (buffer && self->m_naluStore) {
        GstMapInfo map;
        if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
            QByteArray encoded(reinterpret_cast<const char*>(map.data), static_cast<int>(map.size));
            gst_buffer_unmap(buffer, &map);

            qint64 idx = self->m_naluFrameIndex.fetch_add(1, std::memory_order_relaxed);
            self->m_naluStore->addFrame(encoded, idx, true);

            static std::atomic<int> s_encLogCounter{0};
            int n = s_encLogCounter.fetch_add(1) + 1;
            if (n <= 3 || (n % 300) == 0) {
                captureDebugLog("GST", QString("onEncodedSample idx=%1 size=%2 (IDR)")
                    .arg(idx).arg(encoded.size()));
            }
        }
    }

    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

void GstPlayer::start()
{
    qDebug() << "🚀 GstPlayer::start() 调用, m_playing=" << m_playing;
    
    if (m_playing) {
        qDebug() << "⚠️ GstPlayer 已在播放中";
        return;
    }
    
    if (!m_pipeline && !createPipeline()) {
        qCritical() << "❌ GstPlayer::start() createPipeline 失败";
        return;
    }
    
    qDebug() << "▶️ GstPlayer 开始播放, Pipeline 已创建";
    
    GstStateChangeReturn ret = gst_element_set_state(m_pipeline, GST_STATE_PLAYING);
    qDebug() << "▶️ GstPlayer set_state 返回:" << ret 
             << "(0=FAILURE, 1=SUCCESS, 2=ASYNC, 3=NO_PREROLL)";
    
    if (ret == GST_STATE_CHANGE_FAILURE) {
        qCritical() << "❌ Pipeline 启动失败";
        emit error("GStreamer Pipeline 启动失败");
        return;
    }
    
    m_playing = true;
    qDebug() << "✅ GstPlayer 已启动, m_playing=true";
    emit playingChanged();
}

void GstPlayer::stop()
{
    if (!m_playing) {
        return;
    }
    
    qDebug() << "⏹️ GstPlayer 停止播放";
    
    if (m_pipeline) {
        if (m_webrtcbin) {
            // §56.7 WebRTC 管线：阻塞的 NULL 切换交给后台线程（成员指针保留，
            //   随后 destroyPipeline() 移交所有权；这里取一个自己的引用保证安全）
            gst_object_ref(m_pipeline);
            asyncStopAndUnrefPipeline(m_pipeline, "stop(webrtc)");
        } else {
            gst_element_set_state(m_pipeline, GST_STATE_NULL);
        }
    }
    
    m_playing = false;
    m_firstFrame = false;
    
    // 🔥 v10: 重置 PTS 基准
    m_startPts = -1;
    m_startSystemTime = 0;
    
    // 🔥 v10.1: 重置等待关键帧状态
    m_waitingForKeyframe.store(false);
    m_lastKeyframeRequestMs = 0;
    m_pliRequestCount = 0;
    
    // 🔥🔥🔥 v11.2: 清除最后有效帧 + 显示黑屏
    if (m_lastValidSample) {
        gst_sample_unref(m_lastValidSample);
        m_lastValidSample = nullptr;
    }
    // 清空帧队列
    {
        QMutexLocker lock(&m_queueMutex);
        while (!m_frameQueue.isEmpty()) {
            GstSample *s = m_frameQueue.takeFirst();
            gst_sample_unref(s);
        }
    }
    // 显示黑屏
    if (m_videoSink) {
        QVideoFrame emptyFrame;
        m_videoSink->setVideoFrame(emptyFrame);
    }
    
    // 🔥🔥🔥 v14: 重置缓冲状态（修复重连时帧积压问题）
    // 问题：之前重连时 m_bufferingStarted 保持 true，导致跳过"首帧即播"逻辑
    m_bufferingStarted.store(false);
    m_renderFrameCounter.store(0);
    m_emergencyHold = false;
    m_emptyQueueCount = 0;
    m_corruptRatioEma = 0.0;
    m_intervalEma = 33.0;  // 重置为 30fps 默认值
    m_arrivalRateEma = 30.0;  // 重置为默认值
    m_playbackRate = 1.0;  // 重置播放速度
    m_currentSecondFrames = 0;
    m_lastSecondFps = 0;
    m_queueTarget = 9;  // 🔥 v9.3双缓冲：重置为30fps×300ms=9帧
    
    // ⭐ 重置 FPS 统计
    m_fpsFrameCounter = 0;
    m_fpsEma = 0.0;
    m_fpsEmaInitialized = false;
    if (m_receiveFps.load() != 0) {
        m_receiveFps = 0;
        emit receiveFpsChanged();
    }
    
    emit playingChanged();
}

void GstPlayer::reset()
{
    qDebug() << "🔄 GstPlayer 重置";
    stop();
    destroyPipeline();
    
    // ⭐ 释放最后有效帧
    if (m_lastValidSample) {
        gst_sample_unref(m_lastValidSample);
        m_lastValidSample = nullptr;
    }
    m_emergencyHold = false;
    
    m_frameIndex = 0;
}

void GstPlayer::pushNalu(const QByteArray &nalu)
{
    if (!m_playing || !m_appsrc || nalu.isEmpty()) {
        return;
    }
    
    // 创建 GstBuffer
    GstBuffer *buffer = gst_buffer_new_allocate(nullptr, nalu.size(), nullptr);
    if (!buffer) {
        qWarning() << "⚠️ 分配 GstBuffer 失败";
        return;
    }
    
    // 复制数据
    GstMapInfo map;
    if (gst_buffer_map(buffer, &map, GST_MAP_WRITE)) {
        memcpy(map.data, nalu.constData(), nalu.size());
        gst_buffer_unmap(buffer, &map);
    }
    
    // 推送到 appsrc
    GstFlowReturn ret = gst_app_src_push_buffer(GST_APP_SRC(m_appsrc), buffer);
    if (ret != GST_FLOW_OK) {
        qWarning() << "⚠️ 推送数据到 appsrc 失败:" << ret;
    }
}

static bool hasAnnexBNalType(const guint8 *raw, int rawSize, quint8 nalType)
{
    for (int i = 0; i + 4 < rawSize; ++i) {
        if (raw[i] == 0 && raw[i + 1] == 0 &&
            ((raw[i + 2] == 0 && raw[i + 3] == 1) || raw[i + 2] == 1)) {
            const int nalIndex = (raw[i + 2] == 1) ? (i + 3) : (i + 4);
            if (nalIndex < rawSize && (raw[nalIndex] & 0x1F) == nalType) {
                return true;
            }
        }
    }
    return false;
}

static QByteArray extractSpsPpsFromAnnexB(const guint8 *raw, int rawSize)
{
    static const char sc[4] = {0, 0, 0, 1};
    QByteArray result;
    for (int i = 0; i + 5 <= rawSize; ++i) {
        if (raw[i] == 0 && raw[i + 1] == 0 && raw[i + 2] == 0 && raw[i + 3] == 1) {
            const quint8 nalType = raw[i + 4] & 0x1F;
            if (nalType == 7 || nalType == 8) {
                int j = i + 4;
                while (j + 4 <= rawSize) {
                    if (raw[j] == 0 && raw[j + 1] == 0 && raw[j + 2] == 0 && raw[j + 3] == 1) {
                        break;
                    }
                    ++j;
                }
                result.append(sc, 4);
                result.append(reinterpret_cast<const char*>(raw + i + 4), j - (i + 4));
            }
        }
    }
    return result;
}

bool GstPlayer::createH264FrameBranch()
{
    m_rawFrameTee = gst_element_factory_make("tee", "raw_frame_tee");
    m_h264FrameQueue = gst_element_factory_make("queue", "h264_frame_queue");
    m_h264FrameConvert = gst_element_factory_make("videoconvert", "h264_frame_convert");
    const H264FrameQuality q = chooseH264FrameQuality();
    qDebug() << "🎚️ 截图帧编码画质档位:" << q.tier
             << " qp-i=" << q.qpI << " max-bitrate=" << q.maxBitrateKbps;
    m_h264FrameEncoder = gst_element_factory_make("mfh264enc", "h264_frame_encoder");
    if (m_h264FrameEncoder) {
        m_h264FrameEncoderName = "mfh264enc";
        setIntIfExists(m_h264FrameEncoder, "gop-size", 1);
        setIntIfExists(m_h264FrameEncoder, "bitrate", q.bitrateKbps);
        setIntIfExists(m_h264FrameEncoder, "max-bitrate", q.maxBitrateKbps);
        setIntIfExists(m_h264FrameEncoder, "qp-i", q.qpI);
        setBoolIfExists(m_h264FrameEncoder, "low-latency", TRUE);
        setIntIfExists(m_h264FrameEncoder, "quality-vs-speed", 0);
    } else {
        m_h264FrameEncoder = gst_element_factory_make("x264enc", "h264_frame_encoder");
        if (m_h264FrameEncoder) {
            m_h264FrameEncoderName = "x264enc";
            setIntIfExists(m_h264FrameEncoder, "key-int-max", 1);
            // 软编：恒定量化(QP)，与硬编同档对齐，文件大小随分辨率自然伸缩
            setStringIfExists(m_h264FrameEncoder, "pass", "quant");
            setUIntIfExists(m_h264FrameEncoder, "quantizer", q.qpI);
            setStringIfExists(m_h264FrameEncoder, "tune", "zerolatency");
            setStringIfExists(m_h264FrameEncoder, "speed-preset", "veryfast");
        }
    }
    m_h264FrameParse = gst_element_factory_make("h264parse", "h264_frame_parse");
    m_h264FrameCaps = gst_element_factory_make("capsfilter", "h264_frame_caps");
    m_h264FrameAppsink = gst_element_factory_make("appsink", "h264_frame_sink");

    if (!m_rawFrameTee || !m_h264FrameQueue || !m_h264FrameConvert || !m_h264FrameEncoder
        || !m_h264FrameParse || !m_h264FrameCaps || !m_h264FrameAppsink) {
        qCritical() << "❌ 创建 H.264 独立帧保存支路失败";
        emit error("创建 H.264 独立帧保存支路失败");
        return false;
    }

    // §23.17b（用户定）：leaky 一律 downstream，不区分分辨率——落盘支路（mfh264enc 每帧 IDR + 写盘）
    //   磁盘忙跟不上时丢最旧落盘帧腾位置，永不反压 tee/解码线程/实时显示支路。
    //   代价=磁盘忙的那几秒慢放/截图帧序可能出现空洞（跳一帧），换实时流永不被落盘拖卡。
    g_object_set(m_h264FrameQueue,
        "max-size-buffers", 30,
        "max-size-bytes", 0,
        "max-size-time", 0,
        "leaky", 2,
        "silent", TRUE,
        nullptr);
    setIntIfExists(m_h264FrameParse, "config-interval", -1);

    GstCaps *caps = gst_caps_from_string("video/x-h264,stream-format=(string)byte-stream,alignment=(string)au");
    g_object_set(m_h264FrameCaps, "caps", caps, nullptr);
    gst_app_sink_set_caps(GST_APP_SINK(m_h264FrameAppsink), caps);
    gst_caps_unref(caps);

    g_object_set(m_h264FrameAppsink,
        "emit-signals", TRUE,
        "sync", FALSE,
        "async", FALSE,
        "max-buffers", 30,
        "drop", FALSE,
        nullptr);
    g_signal_connect(m_h264FrameAppsink, "new-sample", G_CALLBACK(onH264FrameSample), this);

    m_h264FrameDirectory = QCoreApplication::applicationDirPath() + "/captures/frames";
    QDir().mkpath(m_h264FrameDirectory);
    m_h264SessionPrefix = QString("s_%1").arg(QDateTime::currentMSecsSinceEpoch());
    // ⭐ 清理上一会话残留的 .h264 帧：文件名带 session 前缀(s_<时间戳>_)，重连/重建管线后
    //    旧前缀文件无人引用，原清理只遍历内存集合够不到它们 → 会无限累积(无盘网吧网络目录越来越大越来越卡)。
    // §23.16：清理整体移到后台线程——原来在主线程枚举+逐个删除上百文件，freeze_diag 实锤单次挂主线程
    //    1.4~2.0s（createH264FrameBranch 在主线程被调用）。先定好本会话前缀，后台只删「非本前缀」的
    //    孤儿文件，与本会话并发写入的新帧天然无冲突。
    {
        const QString dir = m_h264FrameDirectory;
        const QString keepPrefix = m_h264SessionPrefix;
        QThreadPool::globalInstance()->start([dir, keepPrefix]() {
            QDir frameDir(dir);
            const QStringList staleFrames = frameDir.entryList(QStringList() << "*.h264", QDir::Files);
            int removed = 0;
            for (const QString &f : staleFrames) {
                if (f.startsWith(keepPrefix)) continue;
                if (frameDir.remove(f)) removed++;
            }
            if (removed > 0) {
                qDebug() << "🗑️ H.264 帧支路: 后台清理上一会话残留" << removed << "个 .h264 文件";
            }
        });
    }
    resetH264FrameState();
    qDebug() << "✅ H.264 独立帧保存支路:" << m_h264FrameEncoderName << "目录:" << m_h264FrameDirectory << "前缀:" << m_h264SessionPrefix;
    return true;
}

bool GstPlayer::linkRawFrameTeeBranch(GstElement *upstreamTail, GstElement *displayHead)
{
    if (!upstreamTail || !displayHead || !m_rawFrameTee || !m_h264FrameQueue || !m_h264FrameAppsink) {
        captureDebugLog("GST", "linkRawFrameTeeBranch FAIL missing elements");
        return false;
    }
    if (!gst_element_link(upstreamTail, m_rawFrameTee)) {
        captureDebugLog("GST", "linkRawFrameTeeBranch FAIL upstream->rawTee");
        return false;
    }

    if (!gst_element_link_many(m_h264FrameQueue, m_h264FrameConvert, m_h264FrameEncoder,
                               m_h264FrameParse, m_h264FrameCaps, m_h264FrameAppsink, nullptr)) {
        captureDebugLog("GST", "linkRawFrameTeeBranch FAIL save branch link");
        return false;
    }
    if (!gst_element_link_many(displayHead, m_convert, m_appsink, nullptr)) {
        captureDebugLog("GST", "linkRawFrameTeeBranch FAIL display branch link");
        return false;
    }

    m_rawFrameTeePadDisplay = gst_element_request_pad_simple(m_rawFrameTee, "src_%u");
    GstPad *displaySink = gst_element_get_static_pad(displayHead, "sink");
    if (!m_rawFrameTeePadDisplay || !displaySink
        || gst_pad_link(m_rawFrameTeePadDisplay, displaySink) != GST_PAD_LINK_OK) {
        if (displaySink) gst_object_unref(displaySink);
        captureDebugLog("GST", "linkRawFrameTeeBranch FAIL rawTee->display");
        return false;
    }
    gst_object_unref(displaySink);

    m_rawFrameTeePadSave = gst_element_request_pad_simple(m_rawFrameTee, "src_%u");
    GstPad *saveSink = gst_element_get_static_pad(m_h264FrameQueue, "sink");
    if (!m_rawFrameTeePadSave || !saveSink
        || gst_pad_link(m_rawFrameTeePadSave, saveSink) != GST_PAD_LINK_OK) {
        if (saveSink) gst_object_unref(saveSink);
        captureDebugLog("GST", "linkRawFrameTeeBranch FAIL rawTee->save");
        return false;
    }
    gst_pad_add_probe(saveSink, GST_PAD_PROBE_TYPE_BUFFER,
        [](GstPad*, GstPadProbeInfo *info, gpointer userData) -> GstPadProbeReturn {
            GstPlayer *self = static_cast<GstPlayer*>(userData);
            if (GST_PAD_PROBE_INFO_BUFFER(info)) {
                const qint64 frameIndex = self->m_nextH264FrameIndex.fetch_add(1, std::memory_order_relaxed);
                self->queuePendingH264FrameIndex(frameIndex);
            }
            return GST_PAD_PROBE_OK;
        }, this, nullptr);
    gst_object_unref(saveSink);
    captureDebugLog("GST", QString("linkRawFrameTeeBranch OK encoder=%1").arg(m_h264FrameEncoderName));
    return true;
}

bool GstPlayer::hasH264Frame(qint64 frameIndex) const
{
    QMutexLocker lock(&m_h264FrameMutex);
    return m_h264AvailableFrames.contains(frameIndex);
}

QString GstPlayer::h264FramePath(qint64 frameIndex) const
{
    return m_h264FrameDirectory + QString("/%1_%2.h264").arg(m_h264SessionPrefix).arg(frameIndex, 9, 10, QChar('0'));
}

QByteArray GstPlayer::readH264Frame(qint64 frameIndex) const
{
    const QString path = h264FramePath(frameIndex);
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return QByteArray();
    return file.readAll();
}

int GstPlayer::registerH264ValidRange(qint64 start, qint64 end)
{
    QMutexLocker lock(&m_h264FrameMutex);
    const int id = m_nextH264ValidRangeId++;
    m_h264ValidRanges.insert(id, qMakePair(start, end));
    return id;
}

void GstPlayer::updateH264ValidRange(int id, qint64 start, qint64 end)
{
    QStringList doomed;
    {
        QMutexLocker lock(&m_h264FrameMutex);
        if (m_h264ValidRanges.contains(id)) {
            m_h264ValidRanges[id] = qMakePair(start, end);
            doomed = cleanupH264FramesLocked();
        }
    }
    removeH264FilesAsync(doomed);  // 本函数常被主线程调用，删除必须离主线程
}

void GstPlayer::unregisterH264ValidRange(int id)
{
    QStringList doomed;
    {
        QMutexLocker lock(&m_h264FrameMutex);
        m_h264ValidRanges.remove(id);
        doomed = cleanupH264FramesLocked();
    }
    removeH264FilesAsync(doomed);  // 本函数常被主线程调用，删除必须离主线程
}

void GstPlayer::resetH264FrameState()
{
    QMutexLocker lock(&m_h264FrameMutex);
    m_pendingH264FrameIndexes.clear();
    m_h264AvailableFrames.clear();
    m_h264ValidRanges.clear();
    m_nextH264ValidRangeId = 1;
    m_nextH264FrameIndex.store(0, std::memory_order_release);
    m_oldestH264Frame.store(-1, std::memory_order_release);
    m_newestH264Frame.store(-1, std::memory_order_release);
}

void GstPlayer::queuePendingH264FrameIndex(qint64 frameIndex)
{
    QMutexLocker lock(&m_h264FrameMutex);
    m_pendingH264FrameIndexes.append(frameIndex);
}

qint64 GstPlayer::takePendingH264FrameIndex()
{
    QMutexLocker lock(&m_h264FrameMutex);
    if (m_pendingH264FrameIndexes.isEmpty()) return -1;
    return m_pendingH264FrameIndexes.takeFirst();
}

// §23.11 P0-1：持锁期间不再做磁盘删除（原来每 600 帧/24s 一次、一批可达上百个文件，
//   持锁删除会把同抢 m_h264FrameMutex 的主线程调用方挂住）。锁内只摘索引，
//   返回待删文件路径，调用方在锁外经 removeH264FilesAsync 丢后台线程删除。
QStringList GstPlayer::cleanupH264FramesLocked()
{
    QStringList doomedPaths;
    const qint64 newest = m_newestH264Frame.load(std::memory_order_acquire);
    if (newest < 0) return doomedPaths;

    const qint64 cleanupBelow = newest - H264_FRAME_KEEP_COUNT;
    const qint64 safeBelow = newest - H264_SAFETY_MARGIN;
    const qint64 cutoff = qMin(cleanupBelow, safeBelow);
    if (cutoff < 0) return doomedPaths;

    QList<qint64> toRemove;
    for (qint64 frameIndex : m_h264AvailableFrames) {
        if (frameIndex <= cutoff && !isH264FrameProtectedLocked(frameIndex)) {
            toRemove.append(frameIndex);
        }
    }

    for (qint64 frameIndex : toRemove) {
        doomedPaths.append(h264FramePath(frameIndex));
        doomedPaths.append(h264FramePath(frameIndex) + ".tmp");
        m_h264AvailableFrames.remove(frameIndex);
    }

    if (!toRemove.isEmpty()) {
        recomputeOldestH264FrameLocked();
        captureDebugLog("GST", QString("cleanupH264Frames removed=%1 oldest=%2 newest=%3 protectedRanges=%4")
            .arg(toRemove.size())
            .arg(m_oldestH264Frame.load(std::memory_order_acquire))
            .arg(newest)
            .arg(m_h264ValidRanges.size()));
    }
    return doomedPaths;
}

// §23.11 P0-1：批量文件删除统一走全局线程池（低频、无顺序要求，删不掉的下轮清理再收）
void GstPlayer::removeH264FilesAsync(const QStringList &paths)
{
    if (paths.isEmpty()) return;
    QThreadPool::globalInstance()->start([paths]() {
        for (const QString &p : paths) {
            QFile::remove(p);
        }
    });
}

bool GstPlayer::isH264FrameProtectedLocked(qint64 frameIndex) const
{
    for (auto it = m_h264ValidRanges.constBegin(); it != m_h264ValidRanges.constEnd(); ++it) {
        if (frameIndex >= it.value().first && frameIndex <= it.value().second) {
            return true;
        }
    }
    return false;
}

void GstPlayer::recomputeOldestH264FrameLocked()
{
    if (m_h264AvailableFrames.isEmpty()) {
        m_oldestH264Frame.store(-1, std::memory_order_release);
        return;
    }
    qint64 oldest = LLONG_MAX;
    for (qint64 frameIndex : m_h264AvailableFrames) {
        oldest = qMin(oldest, frameIndex);
    }
    m_oldestH264Frame.store(oldest, std::memory_order_release);
}

bool GstPlayer::writeH264Frame(qint64 frameIndex, const QByteArray &data)
{
    if (frameIndex < 0 || data.isEmpty()) return false;
    const QString path = h264FramePath(frameIndex);
    const QString tmpPath = path + ".tmp";
    QFile::remove(tmpPath);
    QFile file(tmpPath);
    if (!file.open(QIODevice::WriteOnly)) {
        // §23.11 P0-1：mkpath 从每帧必调改为仅 open 失败时兜底（目录不存在是唯一常见失败因）
        QDir().mkpath(m_h264FrameDirectory);
        if (!file.open(QIODevice::WriteOnly)) return false;
    }
    if (file.write(data) != data.size()) {
        file.close();
        QFile::remove(tmpPath);
        return false;
    }
    file.close();
    QFile::remove(path);
    if (!QFile::rename(tmpPath, path)) {
        QFile::remove(tmpPath);
        return false;
    }

    QStringList doomed;
    {
        QMutexLocker lock(&m_h264FrameMutex);
        m_h264AvailableFrames.insert(frameIndex);
        if (m_oldestH264Frame.load(std::memory_order_acquire) < 0 || frameIndex < m_oldestH264Frame.load(std::memory_order_acquire)) {
            m_oldestH264Frame.store(frameIndex, std::memory_order_release);
        }
        if (frameIndex > m_newestH264Frame.load(std::memory_order_acquire)) {
            m_newestH264Frame.store(frameIndex, std::memory_order_release);
        }
        if ((frameIndex % H264_CLEANUP_INTERVAL) == 0) {
            doomed = cleanupH264FramesLocked();
        }
    }
    removeH264FilesAsync(doomed);
    return true;
}

GstFlowReturn GstPlayer::onH264FrameSample(GstAppSink *sink, gpointer userData)
{
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_OK;

    const qint64 frameIndex = self->takePendingH264FrameIndex();
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    QByteArray data;
    if (buffer) {
        GstMapInfo map;
        if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
            data = QByteArray(reinterpret_cast<const char*>(map.data), static_cast<int>(map.size));
            gst_buffer_unmap(buffer, &map);
        }
    }
    gst_sample_unref(sample);

    if (frameIndex < 0 || data.isEmpty() || !self->writeH264Frame(frameIndex, data)) {
        if (frameIndex >= 0) emit self->h264FrameMissing(frameIndex);
        return GST_FLOW_OK;
    }

    static std::atomic<int> s_h264FileLogCounter{0};
    int n = s_h264FileLogCounter.fetch_add(1) + 1;
    if (n <= 3 || (n % 300) == 0) {
        captureDebugLog("GST", QString("h264FrameStored idx=%1 size=%2 path=%3")
            .arg(frameIndex).arg(data.size()).arg(self->h264FramePath(frameIndex)));
    }
    emit self->h264FrameStored(frameIndex);
    return GST_FLOW_OK;
}

bool GstPlayer::linkNaluTeeBranch()
{
    if (!m_h264parse || !m_naluTee || !m_naluQueue || !m_naluAppsink || !m_queueDepay) {
        captureDebugLog("GST", "linkNaluTeeBranch FAIL missing elements");
        return false;
    }

    if (!gst_element_link(m_h264parse, m_naluTee)) {
        captureDebugLog("GST", "linkNaluTeeBranch FAIL h264parse->tee");
        return false;
    }

    m_naluTeePadMain = gst_element_request_pad_simple(m_naluTee, "src_%u");
    GstPad *depaySink = gst_element_get_static_pad(m_queueDepay, "sink");
    if (!m_naluTeePadMain || !depaySink
        || gst_pad_link(m_naluTeePadMain, depaySink) != GST_PAD_LINK_OK) {
        captureDebugLog("GST", "linkNaluTeeBranch FAIL tee->queueDepay");
        if (depaySink) gst_object_unref(depaySink);
        return false;
    }
    gst_object_unref(depaySink);

    if (!gst_element_link(m_naluQueue, m_naluAppsink)) {
        captureDebugLog("GST", "linkNaluTeeBranch FAIL naluQueue->appsink");
        return false;
    }

    m_naluTeePadStore = gst_element_request_pad_simple(m_naluTee, "src_%u");
    GstPad *naluQueueSink = gst_element_get_static_pad(m_naluQueue, "sink");
    if (!m_naluTeePadStore || !naluQueueSink
        || gst_pad_link(m_naluTeePadStore, naluQueueSink) != GST_PAD_LINK_OK) {
        captureDebugLog("GST", "linkNaluTeeBranch FAIL tee->naluQueue");
        if (naluQueueSink) gst_object_unref(naluQueueSink);
        return false;
    }
    gst_object_unref(naluQueueSink);

    captureDebugLog("GST", "linkNaluTeeBranch OK main=queueDepay store=appsink(leaky)");
    return true;
}

void GstPlayer::extractSpsPpsFromCaps()
{
    // ⭐ H265：codec_data 是 hvcC 格式（非 avcC），且 h265parse config-interval=1 已内联
    //   VPS/SPS/PPS 到码流，无需单独提取——直接跳过（storeNaluFromBuffer 有 H265 分支）。
    if (m_useH265) {
        return;
    }
    if (!m_h264parse || !m_spsPpsAnnexB.isEmpty()) {
        return;
    }

    GstPad *pad = gst_element_get_static_pad(m_h264parse, "src");
    if (!pad) return;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    gst_object_unref(pad);
    if (!caps) return;

    GstStructure *s = gst_caps_get_structure(caps, 0);
    const GValue *cdVal = gst_structure_get_value(s, "codec_data");
    if (!cdVal) {
        gst_caps_unref(caps);
        return;
    }

    GstBuffer *cdBuf = gst_value_get_buffer(cdVal);
    GstMapInfo cdMap;
    if (!gst_buffer_map(cdBuf, &cdMap, GST_MAP_READ)) {
        gst_caps_unref(caps);
        return;
    }

    const guint8 *cd = cdMap.data;
    const int cdSize = static_cast<int>(cdMap.size);
    if (cdSize >= 7) {
        static const char sc[4] = {0, 0, 0, 1};
        m_nalLengthSize = (cd[4] & 0x03) + 1;
        int numSPS = cd[5] & 0x1F;
        int pos = 6;
        QByteArray annexB;
        for (int i = 0; i < numSPS && pos + 2 <= cdSize; i++) {
            int len = (cd[pos] << 8) | cd[pos + 1]; pos += 2;
            if (pos + len <= cdSize) {
                annexB.append(sc, 4);
                annexB.append(reinterpret_cast<const char*>(cd + pos), len);
                pos += len;
            }
        }
        if (pos < cdSize) {
            int numPPS = cd[pos] & 0xFF; pos++;
            for (int i = 0; i < numPPS && pos + 2 <= cdSize; i++) {
                int len = (cd[pos] << 8) | cd[pos + 1]; pos += 2;
                if (pos + len <= cdSize) {
                    annexB.append(sc, 4);
                    annexB.append(reinterpret_cast<const char*>(cd + pos), len);
                    pos += len;
                }
            }
        }
        m_spsPpsAnnexB = annexB;
        captureDebugLog("GST", QString("extractSpsPps OK size=%1 nalLenSize=%2")
            .arg(annexB.size()).arg(m_nalLengthSize));
        qDebug() << "NALU store: 提取 SPS/PPS" << annexB.size() << "bytes";
    }
    gst_buffer_unmap(cdBuf, &cdMap);
    gst_caps_unref(caps);
}

void GstPlayer::storeNaluFromBuffer(GstBuffer *buffer)
{
    if (!buffer || !m_naluStore) {
        return;
    }

    if (m_spsPpsAnnexB.isEmpty()) {
        extractSpsPpsFromCaps();
    }

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        return;
    }

    const guint8 *raw = map.data;
    const int rawSize = static_cast<int>(map.size);
    const bool isAnnexB = (rawSize >= 4 && raw[0] == 0 && raw[1] == 0 &&
                           ((raw[2] == 0 && raw[3] == 1) || raw[2] == 1));

    if (m_spsPpsAnnexB.isEmpty() && isAnnexB) {
        const QByteArray ps = extractSpsPpsFromAnnexB(raw, rawSize);
        if (!ps.isEmpty()) {
            m_spsPpsAnnexB = ps;
            captureDebugLog("GST", QString("extractSpsPps from Annex-B stream size=%1").arg(ps.size()));
        }
    }

    bool isKeyFrame = !GST_BUFFER_FLAG_IS_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT);
    if (!isKeyFrame) {
        isKeyFrame = m_useH265 ? H265Support::hasKeyframeInBuffer(buffer)
                               : hasIdrInBuffer(buffer);
    }

    QByteArray naluData;
    if (m_useH265 && isAnnexB) {
        // ⭐ H265：h265parse(config-interval=1) 已保证关键帧前带 VPS/SPS/PPS，
        //   直接原样存储；关键帧判断用 IRAP（上面已判），不做 H264 的 NAL type 5/7 细化。
        naluData.append(reinterpret_cast<const char*>(raw), rawSize);
    } else if (isAnnexB) {
        naluData.reserve(rawSize + m_spsPpsAnnexB.size() + 16);
        if (isKeyFrame && !m_spsPpsAnnexB.isEmpty()
            && !hasAnnexBNalType(raw, rawSize, 7)) {
            naluData.append(m_spsPpsAnnexB);
        }
        naluData.append(reinterpret_cast<const char*>(raw), rawSize);
        if (!isKeyFrame && isAnnexB) {
            isKeyFrame = hasAnnexBNalType(raw, rawSize, 5) || hasAnnexBNalType(raw, rawSize, 7);
        }
    } else {
        static const char sc[4] = {0, 0, 0, 1};
        const int nlSize = m_nalLengthSize;
        naluData.reserve(rawSize + 128);

        if (isKeyFrame && !m_spsPpsAnnexB.isEmpty()) {
            naluData.append(m_spsPpsAnnexB);
        }

        int pos = 0;
        while (pos + nlSize <= rawSize) {
            quint32 nalLen = 0;
            for (int i = 0; i < nlSize; i++) {
                nalLen = (nalLen << 8) | raw[pos + i];
            }
            pos += nlSize;
            if (nalLen == 0 || pos + static_cast<int>(nalLen) > rawSize) {
                break;
            }
            if ((raw[pos] & 0x1F) == 5) {
                isKeyFrame = true;
            }
            naluData.append(sc, 4);
            naluData.append(reinterpret_cast<const char*>(raw + pos), static_cast<int>(nalLen));
            pos += static_cast<int>(nalLen);
        }
    }

    const qint64 idx = m_naluFrameIndex.fetch_add(1, std::memory_order_relaxed);
    gst_buffer_unmap(buffer, &map);
    m_naluStore->addFrame(naluData, idx, isKeyFrame);

    static std::atomic<int> s_storeLogCounter{0};
    const int n = s_storeLogCounter.fetch_add(1) + 1;
    if (n <= 3 || (n % 300) == 0) {
        captureDebugLog("GST", QString("storeNalu idx=%1 key=%2 size=%3 annexB=%4")
            .arg(idx).arg(isKeyFrame ? "Y" : "N").arg(naluData.size()).arg(isAnnexB ? "Y" : "N"));
    }
}

GstFlowReturn GstPlayer::onNaluStoreSample(GstAppSink *sink, gpointer userData)
{
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) {
        return GST_FLOW_OK;
    }

    {
        GstBuffer *kfBuf = gst_sample_get_buffer(sample);
        const bool kf = self->m_useH265 ? H265Support::hasKeyframeInBuffer(kfBuf)
                                        : hasIdrInBuffer(kfBuf);
        if (kf) {
            self->m_preDecodeIdr.store(true);
        }
    }

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    if (buffer) {
        self->storeNaluFromBuffer(buffer);
    }

    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

GstFlowReturn GstPlayer::onNewSample(GstAppSink *sink, gpointer userData)
{
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) {
        return GST_FLOW_OK;
    }
    
    // §56.7 停止后旧管线在后台异步销毁，销毁完成前可能还会吐几帧 —— 直接丢弃，
    //   防止已清空的队列被重新填入陈旧帧
    if (!self->m_playing) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }
    
    // 🔥🔥🔥 v12 简化：坏帧已在 probe 中被 DROP，这里收到的帧都是干净的！
    // probe 已处理：
    // 1. 坏帧统计 (m_corruptFrameCount)
    // 2. 帧到达计数 (m_currentSecondFrames)
    // 3. 等待 IDR 逻辑（坏帧 DROP，非 IDR 在等待期间也 DROP）
    // 4. IDR 检测和等待模式退出
    
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstCaps *caps = gst_sample_get_caps(sample);
    
    // 首帧和分辨率检测
    if (buffer && caps) {
        GstStructure *structure = gst_caps_get_structure(caps, 0);
        int width = 0, height = 0;
        gst_structure_get_int(structure, "width", &width);
        gst_structure_get_int(structure, "height", &height);
        
        // 更新分辨率
        if (width != self->m_videoWidth || height != self->m_videoHeight) {
            int oldW = self->m_videoWidth;
            int oldH = self->m_videoHeight;
            self->m_videoWidth = width;
            self->m_videoHeight = height;
            qDebug() << "🎬 视频分辨率:" << width << "x" << height;
            if (self->m_useSRT) srtLog(QString("[分辨率] %1x%2").arg(width).arg(height));
            emit self->videoSizeChanged();


            // ⭐ 兜底「切超高清条纹 / 切挡位短暂花屏」（2026-06-24）：
            //   分辨率中途变化(oldW/oldH 已非 0)= iOS 切挡位/超高清后新的 SPS/PPS 序列开始，
            //   首批新分辨率帧若不完整会出条纹。主动请求一次关键帧(PLI)逼 iOS 尽快补一个干净 IDR，
            //   让条纹「一闪而过」而非等下一个周期 IDR。
            //   仅 WebRTC(SRS/P2P) 有效：sendPLIRequest 内部 !m_webrtcbin 直接返回，SRT 模式天然 no-op，
            //   且自带 PLI_INTERVAL_WEAK_MS 节流，不会狂发。首帧(old=0)不算「切换」，跳过。
            if (oldW > 0 && oldH > 0 && (oldW != width || oldH != height)) {
                self->sendPLIRequest();
                qDebug() << "🔑 [分辨率变化] " << oldW << "x" << oldH << "→" << width << "x" << height
                         << " 主动请求关键帧冲刷条纹（WebRTC 路径，SRT 自动跳过）";
            }
        }
        
        // 首帧通知
        if (!self->m_firstFrame.exchange(true)) {
            qDebug() << "🎬 首帧已接收";
            if (self->m_useSRT) srtLog(QString("[首帧] ✅ SRT 已解码出首帧 %1x%2").arg(width).arg(height));
            if (self->m_useP2P) p2pLog(QString("[首帧] ✅ P2P 已解码出首帧 %1x%2 → 真正出画面，全链路打通").arg(width).arg(height));
            // ⭐ H265：首帧解码成功 = 全链路(收流→解码→显示)打通，H265 真出画面
            if (self->m_useH265) H265Support::log(QString("[首帧] ✅ H265 已解码出首帧 %1x%2 → 解码器(nvh265dec)正常，全链路打通").arg(width).arg(height));
            emit self->firstFrameReceived();
        }
    }
    
    // ⭐⭐⭐ 应用层 Jitter Buffer：将帧放入队列（FIFO）
    // 🔥🔥🔥 v11.3 核心原则：不跳帧！靠追帧速度消耗队列
    // 只在极端异常时（队列 > 2×硬限制 = 60帧 = 1秒@60fps）才强制丢帧
    {
        QMutexLocker lock(&self->m_queueMutex);
        
        // 🔥 v11.3: 只在极端情况（2×限制 = 60帧）才丢帧，正常靠追帧消耗
        int extremeLimit = QUEUE_ABSOLUTE_MAX * 2;  // 60帧
        if (self->m_frameQueue.size() >= extremeLimit) {
            int dropCount = 0;
        while (self->m_frameQueue.size() >= QUEUE_ABSOLUTE_MAX) {
                GstSample *oldest = self->m_frameQueue.takeFirst();
                gst_sample_unref(oldest);
                dropCount++;
            }
            
            qWarning() << "⚠️⚠️⚠️ v11.3 队列异常积压，强制丢弃" << dropCount << "帧！";
            qWarning() << "    原因：队列超过" << extremeLimit << "帧（正常应<" << QUEUE_ABSOLUTE_MAX << "帧）";
            
            // 丢帧后请求关键帧
            QMetaObject::invokeMethod(self, "requestKeyFrame", Qt::QueuedConnection);
        }
        
        // 直接入队（pull_sample 返回的已有引用计数，由队列接管）
        self->m_frameQueue.append(sample);
        
        // ⭐⭐⭐ v8.3 帧间隔抖动检测（预测式降帧）
        qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        if (self->m_lastFrameArrivalMs > 0) {
            double fps = self->m_configFps > 0 ? self->m_configFps : 30.0;
            double expectedInterval = 1000.0 / fps;  // 期望间隔（如16.7ms@60fps）
            double actualInterval = static_cast<double>(nowMs - self->m_lastFrameArrivalMs);
            double jitter = std::abs(actualInterval - expectedInterval);  // 瞬时抖动
            
            // 抖动EMA：J_ema = α × J + (1-α) × J_ema
            self->m_jitterEma = JITTER_ALPHA * jitter + (1.0 - JITTER_ALPHA) * self->m_jitterEma;
        }
        self->m_lastFrameArrivalMs = nowMs;
    }
    
    // 显示帧计数
    self->m_frameIndex++;
    
    // ⭐ 帧率统计：EMA 指数移动平均（极度平滑，避免跳动）
    self->m_fpsFrameCounter.fetch_add(1);
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - self->m_fpsLastSecondMs >= 1000) {
        int currentSecondFps = self->m_fpsFrameCounter.exchange(0);
        self->m_fpsLastSecondMs = now;
        
        // EMA 计算：newEma = alpha * current + (1-alpha) * oldEma
        // alpha=0.2 意味着当前值只占 20%，历史值占 80%（非常平滑）
        if (!self->m_fpsEmaInitialized) {
            self->m_fpsEma = currentSecondFps;  // 第一次直接赋值
            self->m_fpsEmaInitialized = true;
        } else {
            self->m_fpsEma = FPS_EMA_ALPHA * currentSecondFps + (1.0 - FPS_EMA_ALPHA) * self->m_fpsEma;
        }
        
        // ⭐⭐⭐ 更新帧到达速率EMA（区分配置变化 vs 网络波动）
        // 
        // 三种情况：
        // 1. iOS固定fps：configFps稳定，只有网络波动 → EMA平滑
        // 2. PC手动改fps：configFps变化 → setConfigFps()已处理
        // 3. 网络波动：实测fps短暂波动 → EMA平滑，不过度反应
        //
        // 检测网络质量：实测fps与配置fps的偏差
        double configFps = self->m_configFps > 1.0 ? self->m_configFps : 30.0;
        double deliveryRatio = currentSecondFps / configFps;  // 实际/配置
        
        // ⭐⭐⭐ 关键修复：FPS突变时立即重置EMA（不等待3秒检测期）
        // 当实测fps与当前EMA差距>50%时，说明FPS发生了突变
        // 此时应立即重置EMA，让播放间隔快速跟随新帧率
        double fpsChangeRatio = (self->m_arrivalRateEma > 1.0) 
            ? currentSecondFps / self->m_arrivalRateEma 
            : 1.0;
        
        if (fpsChangeRatio < 0.5 || fpsChangeRatio > 2.0) {
            // FPS突变（变化超过50%），立即重置EMA
            self->m_arrivalRateEma = currentSecondFps;
            qDebug().noquote() << QString("⚡ FPS突变检测 | EMA立即重置为%1fps (比例=%2)")
                .arg(currentSecondFps).arg(fpsChangeRatio, 0, 'f', 2);
        } else {
            // 正常平滑更新EMA
            self->m_arrivalRateEma = ALPHA_RATE * currentSecondFps + (1.0 - ALPHA_RATE) * self->m_arrivalRateEma;
        }
        
        // 防止EMA过低/过高（最小10fps，保证播放流畅）
        if (self->m_arrivalRateEma < 10.0) self->m_arrivalRateEma = 10.0;  // 最小10fps
        if (self->m_arrivalRateEma > 240.0) self->m_arrivalRateEma = 240.0;
        
        // ⭐⭐⭐ 自动检测fps变化并同步调整（自动唤醒机制）
        // 当实测fps稳定在不同于配置fps的值时，自动调整
        static int stableFpsCount = 0;
        static double lastStableFps = 0;
        
        // 检测实测fps是否稳定（与上一秒差距<20%）
        if (lastStableFps > 0 && std::abs(currentSecondFps - lastStableFps) / lastStableFps < 0.2) {
            stableFpsCount++;
        } else {
            stableFpsCount = 0;
        }
        lastStableFps = currentSecondFps;
        
        // 实测fps稳定3秒，且与配置fps差距>30%，自动调整
        if (stableFpsCount >= 3) {
            double fpsRatio = currentSecondFps / configFps;
            if (fpsRatio < 0.7 || fpsRatio > 1.3) {
                // ⭐⭐⭐ 自动调整配置fps（最小10fps）
                int newConfigFps = qRound(currentSecondFps / 5.0) * 5;
                if (newConfigFps < 10) newConfigFps = 10;  // 最低10fps
                newConfigFps = qBound(10, newConfigFps, 120);  // 最小10fps
                
                qDebug().noquote() << QString("🔄 EMA检测FPS变化 | 配置%1fps 实测%2fps | 新配置=%3fps")
                    .arg((int)configFps).arg(currentSecondFps).arg(newConfigFps);
                
                // 调用 setConfigFps 同步调整所有参数
                self->setConfigFps(newConfigFps);
                stableFpsCount = 0;
            }
        }
        
        // ⭐ 网络质量检测日志
        static int poorNetworkCount = 0;
        if (deliveryRatio < 0.7 && stableFpsCount < 3) {
            // 只有在fps还未稳定时才报警（排除fps变化情况）
            poorNetworkCount++;
            if (poorNetworkCount == 3) {
                qDebug().noquote() << QString("⚠️ 网络质量差 | 配置%1fps 实收%2fps (%3%)")
                    .arg((int)configFps).arg(currentSecondFps).arg((int)(deliveryRatio*100));
            }
        } else {
            poorNetworkCount = 0;
        }
        
        // ⭐ 自带摄像头 ×4（营销口径）；OTG 外接摄像头是真实帧率、是多少显多少（2026-08-02）
        int newFps = qRound(self->m_fpsEma * (self->m_otgSource.load() ? 1 : 4));

        // ⭐ 真实 ICE 线路（relay/直连）：异步 get-stats，回调里解析选中候选对的 local/remote candidate-type。
        if (self->m_useWebRTC && self->m_webrtcbin) {
            GstPromise *statsPromise = gst_promise_new_with_change_func(
                GstPlayer::onWebRtcStatsReady, self, nullptr);
            g_signal_emit_by_name(self->m_webrtcbin, "get-stats", nullptr, statsPromise);
        }

        // ⭐ NACK / 重传 专项统计（每秒读 jitterbuffer stats，证明 NACK 是否真在工作）
        if (self->m_rtpJitterBuffer) {
            GstStructure *jbStats = nullptr;
            g_object_get(self->m_rtpJitterBuffer, "stats", &jbStats, nullptr);
            if (jbStats) {
                guint64 numPushed = 0, numLost = 0, numLate = 0, numDup = 0;
                guint64 rtxCount = 0, rtxSuccess = 0, rtxRtt = 0;
                gst_structure_get_uint64(jbStats, "num-pushed", &numPushed);
                gst_structure_get_uint64(jbStats, "num-lost", &numLost);
                gst_structure_get_uint64(jbStats, "num-late", &numLate);
                gst_structure_get_uint64(jbStats, "num-duplicates", &numDup);
                gst_structure_get_uint64(jbStats, "rtx-count", &rtxCount);            // 发出的重传请求数（NACK）
                gst_structure_get_uint64(jbStats, "rtx-success-count", &rtxSuccess);  // 成功补回的重传包数
                gst_structure_get_uint64(jbStats, "rtx-rtt", &rtxRtt);               // 重传平均往返时间（GStreamer 单位为纳秒）

                // 增量（相比上一秒），更直观看“这一秒发了多少 NACK / 补回多少”
                static guint64 s_lastRtxCount = 0, s_lastRtxSuccess = 0, s_lastLost = 0, s_lastPushed = 0;
                guint64 dRtx = rtxCount >= s_lastRtxCount ? rtxCount - s_lastRtxCount : 0;
                guint64 dSucc = rtxSuccess >= s_lastRtxSuccess ? rtxSuccess - s_lastRtxSuccess : 0;
                guint64 dLost = numLost >= s_lastLost ? numLost - s_lastLost : 0;
                guint64 dPushed = numPushed >= s_lastPushed ? numPushed - s_lastPushed : 0;
                s_lastRtxCount = rtxCount; s_lastRtxSuccess = rtxSuccess; s_lastLost = numLost; s_lastPushed = numPushed;

                // ⭐ B 档面板快照：本秒 NACK/重传补回/丢包 + 丢包率%
                self->m_statNackPerSec.store((int)dRtx);
                self->m_statRtxOkPerSec.store((int)dSucc);
                self->m_statLostPerSec.store((int)dLost);
                {
                    const guint64 denom = dPushed + dLost;
                    const int lossPctX100 = denom > 0 ? (int)((dLost * 10000ULL) / denom) : 0;
                    self->m_statLossPctX100.store(lossPctX100);
                }

                // rtx-rtt 是纳秒，转毫秒打印（之前误标为 ms，导致 126000000ns 被读成天文数字）
                double rtxRttMs = rtxRtt / 1000000.0;
                nackLog(QString("[stats] 本秒: NACK请求+%1 重传补回+%2 丢失+%3 | 累计: pushed=%4 lost=%5 late=%6 dup=%7 rtx发=%8 rtx成功=%9 rtxRtt=%10ms")
                    .arg(dRtx).arg(dSucc).arg(dLost)
                    .arg(numPushed).arg(numLost).arg(numLate).arg(numDup)
                    .arg(rtxCount).arg(rtxSuccess).arg(rtxRttMs, 0, 'f', 1));

                // ⭐⭐⭐ 应用层「伪自适应」抗撕裂（对标棱镜OS第2层 / Chromium 内核自适应在 GStreamer 上的等价物）
                //   背景：GStreamer rtpjitterbuffer 不支持运行时动态改 latency（官方明确），无法像 Chromium
                //         那样真·自适应缓冲。弱网实测：重传 RTT 高达 500ms > latency 600ms，重传包太晚被丢
                //         → rtx成功=0 → GOP 内丢的 P 帧补不回 → 持续撕裂/马赛克。
                //   对策：检测到「本秒真丢包」即主动请求关键帧（sendPLIRequest 自带节流，不会狂发），
                //         让 iOS 尽快推一个新 I 帧把撕裂冲刷掉 —— 这是 WebRTC 相对 SRT 独有的自愈手段。
                //   纯增量逻辑，不碰现有追帧/队列/双缓冲；仅 P2P/SRS(WebRTC) 路径有 jitterbuffer 才会进来。
                {
                    static int s_weakNetSeconds = 0;   // 连续弱网秒数
                    static int s_goodNetSeconds = 0;    // 连续良好秒数
                    if (dLost > 0) {
                        s_weakNetSeconds++;
                        s_goodNetSeconds = 0;
                        // 🔥 2026-07-02 收敛：持续丢包时不再每秒逼一个大 IDR（IDR 是 P 帧 5~10 倍大，
                        //    每秒强刷会进一步压垮弱网上行——与发送端周期 IDR 攒帧问题同机理）。
                        //    首个丢包秒立即请求（冲刷撕裂），之后每 3 秒一次。
                        if (s_weakNetSeconds == 1 || s_weakNetSeconds % 3 == 0) {
                            self->sendPLIRequest();
                            nackLog(QString("[自适应] 本秒丢包=%1(连续弱网%2s) → 主动请求关键帧冲刷撕裂")
                                    .arg(dLost).arg(s_weakNetSeconds));
                        } else {
                            nackLog(QString("[自适应] 本秒丢包=%1(连续弱网%2s) → PLI 收敛期跳过(每3s一次)")
                                    .arg(dLost).arg(s_weakNetSeconds));
                        }
                    } else {
                        s_goodNetSeconds++;
                        if (s_weakNetSeconds > 0 && s_goodNetSeconds >= 3) {
                            nackLog(QString("[自适应] 网络恢复（连续%1s无丢包），退出弱网自愈").arg(s_goodNetSeconds));
                            s_weakNetSeconds = 0;
                        }
                    }
                }

                gst_structure_free(jbStats);
            }
        }
        
        // ⭐⭐⭐ 统计日志（每秒写入 yh.txt）
        {
            static bool yhHeaderWritten = false;
            
            QString timestamp = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
            int renderFps = self->m_renderFrameCounter.exchange(0);  // 获取并重置渲染帧计数
            
            // 应用层 Jitter Buffer 队列深度
            int appQueueDepth = 0;
            {
                QMutexLocker lock(&self->m_queueMutex);
                appQueueDepth = self->m_frameQueue.size();
            }
            // ⭐ B 档面板快照：抖动(ms)/PLI 累计/队列深度（每秒刷新供 QML 轮询）
            self->m_statJitterMs.store((int)(self->m_jitterEma + 0.5));
            self->m_statPli.store(self->m_pliRequestCount);
            self->m_statQueueDepth.store(appQueueDepth);
            int currentInterval = self->m_renderTimer ? self->m_renderTimer->interval() : 0;
            
            // 计算总延迟（GStreamer固定100ms + 实际队列深度 × 配置帧间隔）
            // ⭐ 使用配置fps计算延迟（更稳定，不受网络波动影响）
            int gstLatencyMs = GST_JITTER_LATENCY;
            double fps = self->m_configFps > 1.0 ? self->m_configFps : 30.0;
            int appLatencyMs = static_cast<int>(appQueueDepth * (1000.0 / fps));
            int totalLatencyMs = gstLatencyMs + appLatencyMs;
            
            // 计算水位状态
            double waterLevel = (self->m_queueTarget > 0) ? 
                (double)appQueueDepth / self->m_queueTarget * 100.0 : 0.0;
            QString waterStatus;
            if (waterLevel < W_EMERGENCY * 100) {
                waterStatus = "🛑";  // 紧急
            } else if (waterLevel < W_EXPAND * 100) {
                waterStatus = "⚠️";  // 恢复中
            } else if (waterLevel > W_CATCHUP * 100) {
                waterStatus = "🚀";  // 追帧
            } else {
                waterStatus = "✅";  // 正常
            }
            
            // ⭐⭐⭐ v9核心：基于实际到达帧率EMA计算所有指标
            double arrivalEma = qMax(10.0, self->m_arrivalRateEma);  // 到达帧率EMA（核心指标）
            double playbackRate = self->m_playbackRate;
            double intervalEma = self->m_intervalEma;
            // 🔥 v11.3：动态队列（根据帧率+损坏率）
            int qMin, qOptimal, qMax;
            GstPlayer::getQueueSizeByFps(arrivalEma, qMin, qOptimal, qMax, self->m_corruptRatioEma, self->m_useP2P);
            int optimalQueue = qOptimal;
            int appDelayMs = (arrivalEma > 0) ? static_cast<int>(appQueueDepth * 1000.0 / arrivalEma) : 0;
            
            // 播放速度状态
            QString speedIcon = playbackRate > 1.01 ? "🚀" : (playbackRate < 0.99 ? "🐢" : "");
            
            // 状态标识
            QString emergencyStr = self->m_emergencyHold ? "🛑紧急" : "";
            // 🔥 v13：PC端不再控制帧率，移除降帧显示
            QString fpsReqStr = "";
            
            // 主日志：收/渲/队列/间隔/速度
            QString statsMsg = QString("[%1] 收=%2 渲=%3 | 队列=%4/%5帧(%6) 最佳=%7帧 | 间隔=%8ms(EMA=%9) | 速度=%10%%11")
                .arg(timestamp)
                .arg(currentSecondFps)      // 实际接收fps
                .arg(renderFps)             // 渲染fps
                .arg(appQueueDepth)         // 当前队列
                .arg(self->m_queueTarget)   // 目标队列
                .arg(waterStatus)           // 水位状态
                .arg(optimalQueue)          // 最佳队列（基于到达帧率EMA）
                .arg(currentInterval)       // 当前渲染间隔
                .arg((int)intervalEma)      // 间隔EMA
                .arg((int)(playbackRate * 100))  // 播放速度
                .arg(speedIcon);
            
            // 附加信息：到达EMA/配置fps/应用延迟/状态/损坏率
            // 🔥 v13 显示损坏率（仅用于监控网络质量）
            QString corruptIcon = "";
            if (self->m_corruptRatioEma >= CORRUPT_RATIO_CRITICAL) {
                corruptIcon = "🔴";  // >=30% 弱网
            } else if (self->m_corruptRatioEma >= CORRUPT_RATIO_WEAK) {
                corruptIcon = "🟡";  // >=10% 轻度弱网
            } else if (self->m_corruptRatioEma < 0.05) {
                corruptIcon = "🟢";  // <5% 正常
            }
            QString corruptStr = QString(" %1损坏=%2%").arg(corruptIcon).arg((int)(self->m_corruptRatioEma * 100));
            QString extraMsg = QString(" | 配置=%1fps 到达EMA=%2fps 应延=%3ms%4 %5%6")
                .arg((int)self->m_configFps)  // 配置fps（参考）
                .arg((int)arrivalEma)         // 到达帧率EMA（核心）
                .arg(appDelayMs)              // 应用层延迟
                .arg(corruptStr)              // 🔥 损坏帧比例（网络质量）
                .arg(emergencyStr)            // 紧急状态
                .arg(fpsReqStr);              // 降帧状态
            
            // GStreamer 队列统计
            QString queueMsg;
            if (self->m_queueDepay) {
                guint lvl = 0;
                g_object_get(self->m_queueDepay, "current-level-buffers", &lvl, nullptr);
                queueMsg += QString(" | GST=%1").arg(lvl);
            }
            
            // 控制台每秒打印
            qDebug().noquote() << "📊" << statsMsg << extraMsg << queueMsg;
            
            // ⭐⭐⭐ v12.1 每秒写入 sh.txt（包含完整状态）
            // §23.19：写盘挪后台——本块跑在 GST 流水线线程，磁盘忙时同步 open/flush/close
            //   会把收帧/解码整条流水线挂住（=实时流卡）。调用线程只拼行，写盘入队后台单线程。
            {
                // 🔥 v12.1 简化格式：关键指标一目了然
                QString shLog = QString("[%1] 收=%2 渲=%3 速度=%4% | 队列=%5/%6 损坏=%7% 抖动=%8ms | 到达EMA=%9fps 配置=%10fps")
                    .arg(timestamp)
                    .arg(currentSecondFps)                              // 接收帧数
                    .arg(renderFps)                                     // 渲染帧数
                    .arg((int)(playbackRate * 100))                     // 播放速度
                    .arg(appQueueDepth)                                 // 队列深度
                    .arg(self->m_queueTarget)                           // 目标队列
                    .arg((int)(self->m_corruptRatioEma * 100))          // 损坏率
                    .arg((int)intervalEma)                              // 抖动
                    .arg((int)arrivalEma)                               // 到达帧率EMA
                    .arg((int)self->m_configFps);                       // 配置帧率
                
                // 状态标识
                QString statusStr;
                if (self->m_emergencyHold) {
                    statusStr += " [紧急保护]";
                }
                // 🔥 v13：PC端不再控制帧率，只显示弱网状态
                if (self->m_corruptRatioEma >= CORRUPT_RATIO_WEAK) {
                    statusStr += " [弱网]";
                }

                const QString shLine = shLog + statusStr;
                // ⭐ H265 会话每秒统计写 sh_h265.txt（与 H264 的 sh.txt 分开，便于分开下载分析卡顿）
                const bool shH265 = self->m_useH265;
                gstDiagWritePool()->start([shLine, shH265]() {
                    QFile shFile(shH265 ? "sh_h265.txt" : "sh.txt");
                    if (!shFile.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) return;
                    QTextStream ts(&shFile);
                    // 首次写入添加会话头（只有后台单线程写，无竞争）
                    if (!yhHeaderWritten) {
                        ts << "\n";
                        ts << "╔══════════════════════════════════════════════════════════════════════════════╗\n";
                        ts << "║  v12.1 自适应播放日志 - " << QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") << "  ║\n";
                        ts << "╠══════════════════════════════════════════════════════════════════════════════╣\n";
                        ts << "║ 字段说明:                                                                     ║\n";
                        ts << "║   收=每秒接收帧数  渲=每秒渲染帧数  速度=播放速度(100%=正常,>100追帧,<100慢放) ║\n";
                        ts << "║   队列=当前帧数/目标帧数  损坏=损坏帧比例(网络质量指标,iOS自适应)             ║\n";
                        ts << "║   抖动=帧间隔抖动(ms)  到达EMA=平滑后的到达帧率                               ║\n";
                        ts << "╚══════════════════════════════════════════════════════════════════════════════╝\n\n";
                        yhHeaderWritten = true;
                    }
                    ts << shLine << "\n";
                    ts.flush();
                    shFile.close();
                });
            }

            // ⭐ 第二十二章补强：每秒统计行同步上报服务器（前缀 pc-gstream-p2p）。
            //   此前只上报事件行（候选/首帧等），后台日志里没有 PC 的每秒时间轴，
            //   「队列突增 30+ 帧」这类问题定不到精确时刻。仅 WebRTC(P2P/SRS) 路径上报；
            //   开关关闭时 append 零成本丢弃，不影响本地 sh.txt。
            if (self->m_useWebRTC) {
                const QString routeStr = iceCodeStr(self->m_routeLocalCode.load())
                    + QStringLiteral("/") + iceCodeStr(self->m_routeRemoteCode.load());
                const QString speedStr = QString::number((int)(playbackRate * 100)) + QStringLiteral("%");
                const QString corruptPct = QString::number((int)(self->m_corruptRatioEma * 100)) + QStringLiteral("%");
                QString statLine = QString("[%1] [stat] 收=%2 渲=%3 速度=%4 队列=%5/%6 | nack+%7 rtx回+%8 丢+%9 损坏=%10 抖动=%11ms | 线路=%12 到达EMA=%13fps 应延=%14ms")
                    .arg(timestamp)
                    .arg(currentSecondFps)
                    .arg(renderFps)
                    .arg(speedStr)
                    .arg(appQueueDepth)
                    .arg(self->m_queueTarget)
                    .arg(self->m_statNackPerSec.load())
                    .arg(self->m_statRtxOkPerSec.load())
                    .arg(self->m_statLostPerSec.load())
                    .arg(corruptPct)
                    .arg((int)intervalEma)
                    .arg(routeStr)
                    .arg((int)arrivalEma)
                    .arg(appDelayMs);
                // ⭐ H265 会话上报前缀带 -h265 后缀（总后台分文件落盘，与 H264 分开下载）
                P2PLogUploader::instance()->append(
                    H265Support::uploadPrefix(QStringLiteral("pc-gstream-p2p")), statLine);
            }

            // 🔥 v14: 同步更新 QML 显示的队列状态（和 sh.txt 日志保持一致）
            if (self->m_bufferSize.load() != appQueueDepth) {
                self->m_bufferSize.store(appQueueDepth);
                emit self->bufferSizeChanged();
            }
            // 🔥 v14: 使用最佳队列作为目标（而不是 m_queueTarget）
            if (self->m_bufferTarget.load() != optimalQueue) {
                self->m_bufferTarget.store(optimalQueue);
                emit self->bufferTargetChanged();
            }
        }
        
        if (newFps != self->m_receiveFps.load()) {
            self->m_receiveFps = newFps;
            emit self->receiveFpsChanged();
        }
    }
    
    return GST_FLOW_OK;
}

// ========== GStreamer Bus 同步消息处理（JPEG 保存成功回调）==========
GstBusSyncReply GstPlayer::onBusSyncMessage(GstBus *bus, GstMessage *message, gpointer userData)
{
    Q_UNUSED(bus);
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    
    switch (GST_MESSAGE_TYPE(message)) {
    case GST_MESSAGE_ERROR: {
        GError *err = nullptr;
        gchar *debug = nullptr;
        gst_message_parse_error(message, &err, &debug);

        const gchar *srcName = GST_MESSAGE_SRC(message) ?
            GST_OBJECT_NAME(GST_MESSAGE_SRC(message)) : "";
        bool isStoreBranch = (g_str_has_prefix(srcName, "store_") ||
                              g_strcmp0(srcName, "nalu_store_queue") == 0 ||
                              g_strcmp0(srcName, "nalu_store_sink") == 0);

        if (isStoreBranch) {
            captureDebugLog("GST", QString("Store branch error (IGNORED): %1 | src=%2 | debug=%3")
                .arg(err->message).arg(srcName).arg(debug));
            qDebug() << "⚠️ Store branch error (ignored):" << err->message << "src=" << srcName;
            g_error_free(err);
            g_free(debug);
            return GST_BUS_DROP;
        }

        captureDebugLog("GST", QString("ERROR src=%1 msg=%2 debug=%3").arg(srcName).arg(err->message).arg(debug));
        diagLog(QString("❌ ERROR src=%1: %2 | debug: %3").arg(srcName).arg(err->message).arg(debug));
        if (self && self->m_useSRT) {
            srtLog(QString("[ERROR] src=%1: %2 | debug: %3").arg(srcName).arg(err->message).arg(debug));
        }
        // ⭐ H265：解码器/管线报错记到 h265 日志（nvh265dec not-negotiated / 解码失败等是无首帧的常见根因）
        if (self && self->m_useH265) {
            H265Support::log(QString("[ERROR] src=%1: %2 | debug: %3").arg(srcName, err->message, debug ? debug : ""));
        }
        qCritical() << "❌ GStreamer 错误:" << err->message << "src=" << srcName;
        g_error_free(err);
        g_free(debug);
        break;
    }
    case GST_MESSAGE_WARNING: {
        GError *err = nullptr;
        gchar *debug = nullptr;
        gst_message_parse_warning(message, &err, &debug);
        diagLog(QString("⚠️ WARNING: %1 | debug: %2").arg(err->message).arg(debug));
        if (self && self->m_useSRT) {
            srtLog(QString("[WARNING] %1 | debug: %2").arg(err->message).arg(debug));
        }
        // ⭐ H265：管线告警也记 h265 日志（解码器 caps/协商告警常在此）
        if (self && self->m_useH265) {
            H265Support::log(QString("[WARNING] %1 | debug: %2").arg(err->message, debug ? debug : ""));
        }
        g_error_free(err);
        g_free(debug);
        break;
    }
    case GST_MESSAGE_QOS: {
        // QoS 消息表示丢帧
        gboolean live = FALSE;
        guint64 running_time = 0, stream_time = 0, timestamp = 0, duration = 0;
        gst_message_parse_qos(message, &live, &running_time, &stream_time, &timestamp, &duration);
        
        gint64 jitter = 0;
        gdouble proportion = 0;
        gint quality = 0;
        gst_message_parse_qos_values(message, &jitter, &proportion, &quality);
        
        guint64 processed = 0, dropped = 0;
        gst_message_parse_qos_stats(message, nullptr, &processed, &dropped);
        
        // 记录所有 QoS 消息
        diagLog(QString("📉 QOS: processed=%1 dropped=%2 jitter=%3 来源=%4")
            .arg(processed).arg(dropped).arg(jitter).arg(GST_MESSAGE_SRC_NAME(message)));
        break;
    }
    case GST_MESSAGE_STREAM_STATUS: {
        GstStreamStatusType type;
        GstElement *owner = nullptr;
        gst_message_parse_stream_status(message, &type, &owner);
        if (type == GST_STREAM_STATUS_TYPE_ENTER || type == GST_STREAM_STATUS_TYPE_LEAVE) {
            diagLog(QString("📺 STREAM_STATUS: type=%1 owner=%2")
                .arg((int)type).arg(owner ? GST_ELEMENT_NAME(owner) : "null"));
        }
        break;
    }
    case GST_MESSAGE_ELEMENT: {
        const GstStructure *s = gst_message_get_structure(message);
        if (!s) break;
        
        const gchar *name = gst_structure_get_name(s);
        
        // ⭐ 检测 H264 解码器/RTP 相关消息
        if (g_str_has_prefix(name, "GstVideoDecoder") || 
            g_str_has_prefix(name, "d3d11") ||
            g_str_has_prefix(name, "h264") ||
            g_str_has_prefix(name, "rtp") ||
            g_str_has_prefix(name, "Rtp")) {
            diagLog(QString("🎬 ELEMENT: %1").arg(name));
        }
        
        break;
    }
    default:
        break;
    }
    
    return GST_BUS_PASS;  // 继续传递消息
}

// ========== 图像调节方法（使用 GStreamer videobalance 和 gamma）==========

void GstPlayer::setBrightness(double value)
{
    value = qBound(-1.0, value, 1.0);
    if (m_videoBalance) {
        g_object_set(m_videoBalance, "brightness", value, nullptr);
        qDebug() << "✅ 亮度已设置:" << value;
    }
}

void GstPlayer::setContrast(double value)
{
    value = qBound(0.0, value, 2.0);
    if (m_videoBalance) {
        g_object_set(m_videoBalance, "contrast", value, nullptr);
        qDebug() << "✅ 对比度已设置:" << value;
    }
}

void GstPlayer::setSaturation(double value)
{
    value = qBound(0.0, value, 2.0);
    if (m_videoBalance) {
        g_object_set(m_videoBalance, "saturation", value, nullptr);
        qDebug() << "✅ 饱和度已设置:" << value;
    }
}

void GstPlayer::setHue(double value)
{
    value = qBound(-1.0, value, 1.0);
    if (m_videoBalance) {
        g_object_set(m_videoBalance, "hue", value, nullptr);
        qDebug() << "✅ 色调已设置:" << value;
    }
}

void GstPlayer::setGamma(double value)
{
    value = qBound(0.01, value, 10.0);
    if (m_gamma) {
        g_object_set(m_gamma, "gamma", value, nullptr);
        qDebug() << "✅ 伽马已设置:" << value;
    }
}

void GstPlayer::setAllImageParams(double brightness, double contrast, double saturation, double hue, double gamma)
{
    // ⭐ 临时禁用 PC 端后期色彩调整 — 用于对比 iOS 原画效果, 代码保留可随时恢复
    //   syncColorToJpegEncoder 启动/参数变化时会调到这里, short-circuit 后
    //   videobalance/gamma 永远停在 GStreamer 中性默认值
    qDebug() << "⚪ [Filter] setAllImageParams 已禁用 (传入值忽略: b=" << brightness
             << "c=" << contrast << "s=" << saturation << "h=" << hue << "g=" << gamma << ")";
    return;
    /*
    setBrightness(brightness);
    setContrast(contrast);
    setSaturation(saturation);
    setHue(hue);
    setGamma(gamma);
    */
}

void GstPlayer::applyColorFilter(double brightness, double contrast, double saturation, double gamma)
{
    // Android 本地滤镜落地：videobalance(亮度/对比度/饱和度) + gamma。
    //   与被禁用的 setAllImageParams（"对比 iOS 原画"开关）互不影响——这是独立的 Android 滤镜链路。
    //   仅 g_object_set 属性（轻量）；实际像素处理在 GStreamer 管线线程，不卡 Qt 主线程。
    setBrightness(brightness);
    setContrast(contrast);
    setSaturation(saturation);
    if (gamma > 0.0) setGamma(gamma);
    qDebug() << "🎨 [Android本地滤镜] videobalance b=" << brightness
             << "c=" << contrast << "s=" << saturation << "gamma=" << gamma;
}

void GstPlayer::clearColorFilter()
{
    setBrightness(0.0);
    setContrast(1.0);
    setSaturation(1.0);
    setGamma(1.0);
    qDebug() << "🎨 [Android本地滤镜] videobalance 复位中性";
}

void GstPlayer::setConfigFps(double fps)
{
    // 🔥🔥🔥 v11 防抖动：限制 FPS 设置频率，避免 UI 卡顿
    static qint64 lastSetTime = 0;
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - lastSetTime < 100) {  // 100ms 内只处理一次
        return;  // 忽略过于频繁的调用
    }
    lastSetTime = now;
    
    // ⭐⭐⭐ v8客户方案：FPS变化时重新计算队列目标
    fps = qBound(10.0, fps, 240.0);
    
    if (std::abs(m_configFps - fps) > 1.0) {
        double oldFps = m_configFps;
        int oldQueueTarget = m_queueTarget;
        
        m_configFps = fps;
        
        // 🔥🔥🔥 v11 修复：不要重置 m_arrivalRateEma！
        // arrivalRateEma 应该反映实际到达帧率，而不是配置帧率
        // 重置它会导致定时器间隔变得很短，引起 UI 卡顿
        // m_arrivalRateEma = fps;  // ❌ 删除这行！
        
        // 🔥🔥🔥 v11.3 动态队列策略（手动调整时使用当前损坏率）
        int queueMin, queueOptimal, queueMax;
        getQueueSizeByFps(fps, queueMin, queueOptimal, queueMax, m_corruptRatioEma, m_useP2P);
        int newQueueTarget = queueOptimal;
        
        m_queueTarget = newQueueTarget;
        m_queueTargetSmooth = newQueueTarget;
        
        // ⭐⭐⭐ 重置所有状态（新fps基准）
        m_playbackRate = 1.0;
        m_targetRate = 1.0;
        m_emergencyHold = false;
        m_slowdownActive = false;
        m_stableCounter = 0;
        m_fpsChangeCounter = 0;
        
        // 🔥 v13：PC端不再自动升降帧，这些变量保留但不再使用
        m_requestedFps = 0;
        m_originalFps = 0;
        m_fpsAdjustCooldownMs = 0;
        qDebug() << "🔄 手动调整FPS→" << fps;
        
        int targetDelayMs = 150;  // 标准延迟150ms
        int totalDelayMs = targetDelayMs + GST_JITTER_LATENCY;
        
        qDebug().noquote() << QString("⚙️ v8 FPS变更 | %1→%2fps | 最佳缓冲%3→%4帧(15%) | 范围=%5-%6帧 | 延迟=%7ms+%8ms=%9ms")
            .arg((int)oldFps).arg((int)fps)
            .arg(oldQueueTarget).arg(m_queueTarget)
            .arg(queueMin).arg(queueMax)
            .arg(targetDelayMs).arg(GST_JITTER_LATENCY).arg(totalDelayMs);
    }
}

// ⭐ P2: 240fps 高速模式切换
void GstPlayer::setHighSpeedMode(bool enabled)
{
    if (m_highSpeedMode == enabled) return;
    m_highSpeedMode = enabled;

    if (enabled) {
        // 240fps 模式：调整渲染定时器和缓冲策略
        m_renderTimer->start(4);  // 4ms = 240fps
        setConfigFps(240.0);

        // appsink 不丢帧（240fps 模式下每帧都重要）
        if (m_appsink) {
            g_object_set(m_appsink,
                "drop", FALSE,
                "max-buffers", (guint)0,  // 不限制缓冲
                nullptr);
        }
        qDebug() << "✅ [240fps] 高速模式已启用 (4ms渲染, 不丢帧)";
    } else {
        // 恢复普通模式
        m_renderTimer->start(33);  // 33ms = 30fps
        setConfigFps(30.0);

        // 恢复 appsink 丢帧策略
        if (m_appsink) {
            g_object_set(m_appsink,
                "drop", TRUE,
                "max-buffers", (guint)QUEUE_ABSOLUTE_MAX,
                nullptr);
        }
        qDebug() << "✅ [普通模式] 已恢复 (33ms渲染, drop=true)";
    }
}

// ============================================================================
// WebRTCBin 实现（替代 libdatachannel）
// ============================================================================

void GstPlayer::connectWebRTC(const QString &host, const QString &app, const QString &stream)
{
    qDebug() << "🌐 WebRTC 连接:" << host << "/" << app << "/" << stream;

    // ⭐ H265（第四十九章）：SRS/WHEP 不再写死 H264。m_useH265 由 QML 在 connect 前 setVideoCodec(videoCodec)
    //   按设备心跳上报的 codec 设定（H264 会话保持原样；H265 会话下方 add-transceiver 用 H265 caps + rtph265depay）。
    H265Support::setActive(m_useH265);
    qDebug() << (m_useH265 ? "🎬 [SRS] H265 拉流管线" : "🎬 [SRS] H264 拉流管线")
             << " m_useH265=" << m_useH265;

    // [SRS诊断] 记录连接入口 + 进入时的熔断标志（用于定位「偶尔第一次画面出不来」）。
    srsLog(QString("==== connectWebRTC 入口 ===="));
    srsLog(QString("[connect] host=%1 app=%2 stream=%3").arg(host, app, stream));
    srsLog(QString("[熔断·入口前] srsError=%1 offerSent=%2 offerInProgress=%3 retryCount=%4 pipeline=%5")
           .arg(m_srsError.load()).arg(m_offerSentForSession.load())
           .arg(m_offerInProgress.load()).arg(m_srsRetryCount.load())
           .arg(m_pipeline ? "存在(将销毁重建)" : "无"));

    m_webrtcHost = host;
    m_webrtcApp = app;
    m_webrtcStream = stream;
    m_useWebRTC = true;
    m_useP2P = false;  // 🔥 2026-07-02: SRS 路径明确清 P2P 标志（disconnectWebRTC 不清），保证 jitter 参数按 SRS(600ms) 走
    
    // 🔥 重置错误标志和无帧计数
    m_srsError.store(false);
    m_srsRetryCount.store(0);  // 🔥 重置重试计数
    m_pendingOfferSdp.clear();
    m_noFpsSeconds.store(0);
    m_reconnectScheduled.store(false);
    m_offerSentForSession.store(false);  // 🔥 重置会话级 Offer 标志
    m_offerInProgress.store(false);      // 🔥 重置 Offer 进行中标志
    srsLog(QString("[熔断·已重置] 三标志清零，开始建管线"));
    
    m_webrtcStatus = "Connecting...";
    emit webrtcStatusChanged(m_webrtcStatus);
    
    // 停止现有管道
    if (m_pipeline) {
        stop();
        destroyPipeline();
    }
    
    // 创建 WebRTC 管道
    if (!createPipeline()) {
        m_webrtcStatus = "Pipeline creation failed";
        emit webrtcStatusChanged(m_webrtcStatus);
        emit error("Failed to create WebRTC pipeline");
        srsLog(QString("[pipeline] ❌ createPipeline 失败 → 画面必然出不来"));
        return;
    }
    srsLog(QString("[pipeline] ✅ createPipeline 成功，webrtcbin=%1").arg(m_webrtcbin ? "有" : "无"));

    // 启动管道
    start();
    
    // 对于接收端 WebRTC，需要主动创建 offer（on-negotiation-needed 可能不会自动触发）
    if (m_webrtcbin) {
        qDebug() << "📞 主动创建 WebRTC Offer（接收端模式）...";
        srsLog(QString("[offer] 100ms 后将主动 createWebRTCOffer"));
        // 稍微延迟以确保管道完全启动
        QTimer::singleShot(100, this, &GstPlayer::createWebRTCOffer);
    } else {
        srsLog(QString("[offer] ⚠️ webrtcbin 为空，不会创建 Offer → 画面出不来"));
    }
}

void GstPlayer::disconnectWebRTC()
{
    qDebug() << "🔌 WebRTC 断开连接";
    
    stop();
    destroyPipeline();
    
    m_webrtcConnected = false;
    m_noFpsSeconds.store(0);  // 🔥 重置无帧计数
    m_offerSentForSession.store(false);  // 🔥 重置会话级 Offer 标志
    m_offerInProgress.store(false);      // 🔥 重置 Offer 进行中标志
    m_webrtcStatus = "Disconnected";
    emit webrtcStatusChanged(m_webrtcStatus);
    emit webrtcDisconnected();
}

// ★★★ MARK: SRT (independent) BEGIN ★★★ —— 方案 B：PC 端独立 SRT 拉流

// ⭐ 治「首屏卡 3.3s」：解码器/编码器冷启动预热。
//   根因——首次 createPipeline 时 nvh264dec(NVIDIA CUDA context) + mfh264enc(MediaFoundation)
//   首次创建/初始化同步占用主线程 ~3.3s（SRS/P2P 不卡是因为运行时这些已热缓存）。
//   做法——在后台线程提前跑一个最小数据流，强制 GStreamer 完成 CUDA/MF 的一次性初始化，
//   之后真正 createPipeline 走热路径。进程级只跑一次；不阻塞主线程；不改 SRS/P2P 逻辑。
void GstPlayer::warmupDecoderEncoderAsync()
{
    bool expected = false;
    if (!m_warmupStarted.compare_exchange_strong(expected, true)) {
        return;  // 已预热过（或正在预热），不重复
    }

    // 一个最小预热 pipeline 跑通的通用工具：set PLAYING → 等 EOS（或超时）→ set NULL 销毁。
    //   注意：在 QtConcurrent 线程池线程执行（无 Qt 事件循环），故用 gst_bus_timed_pop_filtered 阻塞等。
    auto runWarmup = [](const QString &desc, int timeoutSec) -> bool {
        GError *err = nullptr;
        GstElement *p = gst_parse_launch(desc.toUtf8().constData(), &err);
        if (!p || err) {
            if (err) g_error_free(err);
            if (p) gst_object_unref(p);
            return false;
        }
        gst_element_set_state(p, GST_STATE_PLAYING);
        GstBus *bus = gst_element_get_bus(p);
        GstMessage *msg = gst_bus_timed_pop_filtered(
            bus, (GstClockTime)timeoutSec * GST_SECOND,
            (GstMessageType)(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
        bool ok = (msg && GST_MESSAGE_TYPE(msg) == GST_MESSAGE_EOS);
        if (msg) gst_message_unref(msg);
        gst_object_unref(bus);
        gst_element_set_state(p, GST_STATE_NULL);
        gst_object_unref(p);
        return ok;
    };

    // ⭐ 解码器与编码器并行预热（各占一个线程池任务），墙钟时间取两者较大者而非相加，
    //   尽量在用户真正 connectSRT 之前热完（MediaFoundation 首次初始化约 2s 是瓶颈）。
    //   §56.7 QtConcurrent::run 丢弃 QFuture 触发 C4858 → 按编译器建议改 QThreadPool::start（语义相同：射后不理）
    // 解码器预热：videotestsrc → x264enc(软编造码流) → h264parse → <硬解> → fakesink
    QThreadPool::globalInstance()->start([this, runWarmup]() {
        qint64 t0 = QDateTime::currentMSecsSinceEpoch();
        srtLog(QString("[warmup] 解码器预热开始"));
        // 不调用 detectGpuType()（其 QProcess::waitForFinished 在无事件循环线程不可靠），
        // 直接按通用优先级探测可用硬解工厂——NVIDIA 上真实 pipeline 选 nvh264dec，此处同样优先命中。
        const QStringList decoderCandidates = {"nvh264dec", "d3d11h264dec", "msdkh264dec", "amfh264dec"};
        bool decWarmed = false;
        for (const QString &dec : decoderCandidates) {
            if (!gst_element_factory_find(dec.toUtf8().constData())) continue;
            QString desc = QString(
                "videotestsrc num-buffers=2 ! video/x-raw,width=320,height=240,framerate=30/1 ! "
                "x264enc tune=zerolatency speed-preset=ultrafast ! h264parse ! %1 ! fakesink sync=false")
                .arg(dec);
            if (runWarmup(desc, 8)) {
                decWarmed = true;
                srtLog(QString("[warmup] 解码器预热完成: %1，耗时 %2ms")
                       .arg(dec).arg(QDateTime::currentMSecsSinceEpoch() - t0));
                break;
            }
            srtLog(QString("[warmup] 解码器预热尝试失败: %1（继续下一候选）").arg(dec));
        }
        if (!decWarmed)
            srtLog(QString("[warmup] ⚠️ 解码器预热未成功（不影响功能，首屏可能仍偏慢）"));
    });

    // 编码器预热：videotestsrc(NV12) → mfh264enc → h264parse → fakesink（触发 MediaFoundation 初始化）
    QThreadPool::globalInstance()->start([this, runWarmup]() {
        qint64 t0 = QDateTime::currentMSecsSinceEpoch();
        srtLog(QString("[warmup] 编码器预热开始（mfh264enc / MediaFoundation 冷启动约 2s）"));
        if (gst_element_factory_find("mfh264enc")) {
            QString encDesc =
                "videotestsrc num-buffers=2 ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 ! "
                "mfh264enc low-latency=true ! h264parse ! fakesink sync=false";
            bool ok = runWarmup(encDesc, 8);
            srtLog(QString("[warmup] 编码器预热完成: mfh264enc（%1），耗时 %2ms")
                   .arg(ok ? "EOS" : "超时/错误").arg(QDateTime::currentMSecsSinceEpoch() - t0));
        } else {
            srtLog(QString("[warmup] mfh264enc 不可用，跳过编码器预热"));
        }
    });
}

void GstPlayer::connectSRT(const QString &uri)
{
    qDebug() << "[SRT] 启动 SRT 拉流，uri=" << uri;
    srtLog(QString("==== connectSRT 开始 ===="));
    srtLog(QString("[uri] %1").arg(uri));

    // 兜底预热（若 QML 已提前 warmupSRT() 则此处 compare_exchange 直接跳过，不重复）。
    warmupDecoderEncoderAsync();

    m_srtUri = uri;
    m_useSRT = true;
    // SRT 与 WebRTC/P2P 互斥：明确关掉另两条，走独立尾段。
    m_useWebRTC = false;
    m_useP2P = false;

    m_noFpsSeconds.store(0);
    m_reconnectScheduled.store(false);

    m_webrtcStatus = "SRT Connecting...";
    emit webrtcStatusChanged(m_webrtcStatus);

    // ⭐ 解耦 UI 冻结：createPipeline（解码器/编码器冷启动初始化，首次可达 ~2.8s）很重，
    //   若在此同步执行会冻结 GUI（"卡死拖不动"）。这里立即返回，把重活推到下一个事件循环，
    //   让 QML 先把"正在连接 SRT..."渲染出来、UI 先响应一拍。仅影响 SRT 路径，SRS/P2P 不动。
    int epoch = m_srtConnectEpoch.fetch_add(1) + 1;
    srtLog(QString("[pipeline] connectSRT 入口立即返回（epoch=%1），重活异步执行").arg(epoch));
    QTimer::singleShot(0, this, [this, epoch]() {
        // 若期间又发起了新的连接或已断开（epoch 变化 / 退出 SRT），放弃本次。
        if (!m_useSRT || m_srtConnectEpoch.load() != epoch) {
            srtLog(QString("[pipeline] 异步重活已过期（epoch=%1，当前=%2），放弃")
                   .arg(epoch).arg(m_srtConnectEpoch.load()));
            return;
        }
        doConnectSRTPipeline();
    });
}

void GstPlayer::doConnectSRTPipeline()
{
    qint64 t0 = QDateTime::currentMSecsSinceEpoch();

    if (m_pipeline) {
        stop();
        destroyPipeline();
    }

    qint64 tBeforeCreate = QDateTime::currentMSecsSinceEpoch();
    srtLog(QString("[pipeline] 开始 createPipeline（前置清理耗时 %1ms）").arg(tBeforeCreate - t0));
    if (!createPipeline()) {
        srtLog(QString("[pipeline] ❌ createPipeline 失败，耗时 %1ms")
               .arg(QDateTime::currentMSecsSinceEpoch() - tBeforeCreate));
        m_webrtcStatus = "SRT Pipeline creation failed";
        emit webrtcStatusChanged(m_webrtcStatus);
        emit error("Failed to create SRT pipeline");
        m_useSRT = false;
        return;
    }

    qint64 tAfterCreate = QDateTime::currentMSecsSinceEpoch();
    srtLog(QString("[pipeline] ✅ createPipeline 完成，耗时 %1ms（仍在主线程，但已让首屏先响应）")
           .arg(tAfterCreate - tBeforeCreate));

    start();
    qint64 tAfterStart = QDateTime::currentMSecsSinceEpoch();
    srtLog(QString("[pipeline] ✅ start(set_state PLAYING) 完成，耗时 %1ms | 重活总耗时 %2ms")
           .arg(tAfterStart - tAfterCreate).arg(tAfterStart - t0));
    qDebug() << "[SRT] 管线已启动，等待 srtsrc 收流...";
}

void GstPlayer::disconnectSRT()
{
    qDebug() << "[SRT] 断开 SRT 连接";

    // 让在途的 connectSRT 异步重活失效（断开后不应再把 pipeline 建起来）。
    m_srtConnectEpoch.fetch_add(1);
    m_useSRT = false;

    stop();
    destroyPipeline();

    m_srtUri.clear();
    m_noFpsSeconds.store(0);
    m_webrtcStatus = "SRT Disconnected";
    emit webrtcStatusChanged(m_webrtcStatus);
    emit webrtcDisconnected();
}

// ★★★ MARK: SRT (independent) END ★★★

// ★★★ P2P 直连模式 BEGIN ★★★

// ⭐ H265：QML 收到 CONFIG_STATE.videoCodec 后、playP2P 前调用。
//   仅记录标志；真正的元素切换在 createPipeline 各分叉点（见 h265support.h 说明）。
void GstPlayer::setVideoCodec(const QString &codec)
{
    const bool useH265 = H265Support::isH265CodecName(codec);
    if (useH265 == m_useH265) {
        return;
    }
    m_useH265 = useH265;
    // ⭐ 立即同步全局会话标志：网页内核模式不走 connectP2P，
    //   kernelbridge 的日志分流（nh_h265.txt / pc-web-p2p-h265）依赖此标志。
    H265Support::setActive(useH265);
    qDebug() << "[H265] 视频编码切换 →" << (useH265 ? "H265" : "H264");
    if (useH265) {
        H265Support::log("PC 端进入 H265 模式（下次 connectP2P 建 rtph265depay/h265parse/h265 解码器管线）");
    }
}

void GstPlayer::connectP2P(const QString &pairedIosDeviceId, const QJsonArray &iceServers)
{
    // ⭐ 内核测试模式下，GStreamer 必须让出 P2P：拦截任何（含自动重连触发的）P2P 启动，
    //   否则会和内核(Chromium)抢同一 iOS 会话，导致内核侧出不来画面。
    if (m_kernelTestMode.load()) {
        qDebug() << "[P2P] 内核测试模式启用中 → 跳过 GStreamer connectP2P（让内核独占）";
        return;
    }

    qDebug() << "[P2P] 启动 P2P 直连模式，配对设备:" << pairedIosDeviceId;

    // ⭐ H265：会话开关（p2pLog/stat 上报前缀按此路由到 -h265 通道，与 H264 日志分开）
    H265Support::setActive(m_useH265);
    if (m_useH265) {
        H265Support::log(QString("[connect] H265 P2P 会话启动 配对设备=%1 iceServers=%2")
                         .arg(pairedIosDeviceId).arg(iceServers.size()));
    }

    // ⭐ P2P 独立诊断日志：记录入口（含 ICE 服务器数量，0 个 = 热点必失败的早期信号）
    p2pLog(QString("[connect] 启动 P2P 直连 配对设备=%1 iceServers数量=%2 %3")
           .arg(pairedIosDeviceId)
           .arg(iceServers.size())
           .arg(iceServers.isEmpty() ? "⚠️ 后端没下发任何 ICE 服务器！无 TURN → 手机热点(CGNAT)必然出不来画面" : ""));
    // 重置 P2P 候选者统计（本次连接重新计数）
    m_p2pLocalCand[0] = m_p2pLocalCand[1] = m_p2pLocalCand[2] = m_p2pLocalCand[3] = 0;
    m_p2pRemoteCand[0] = m_p2pRemoteCand[1] = m_p2pRemoteCand[2] = m_p2pRemoteCand[3] = 0;

    m_pairedIosDeviceId = pairedIosDeviceId;
    m_p2pIceServers = iceServers;   // §25.7e：留存，切中继重建 pipeline 时复用
    m_useP2P = true;
    m_useWebRTC = true;
    
    m_srsError.store(false);
    m_srsRetryCount.store(0);
    m_pendingOfferSdp.clear();
    // ⭐ §53.24：新一轮 P2P 连接，清掉上一轮的 Offer 防抖残留（防旧 Offer 被误应用到新会话）
    m_pendingP2POfferSdp.clear();
    m_lastOfferAppliedMs = 0;
    if (m_offerDebounceTimer) m_offerDebounceTimer->stop();
    m_noFpsSeconds.store(0);
    m_reconnectScheduled.store(false);
    m_offerSentForSession.store(false);
    m_offerInProgress.store(false);
    m_waitingForP2POffer.store(false);
    m_p2pViewRequestRetryCount.store(0);
    
    // ⭐⭐ §53.25：会话 epoch——**一轮协商一个**（重发不换，重建 pipeline 才换新轮次）。
    //   REQUEST 带出去，设备端该会话所有 Offer/ICE 回带；PC 只收当前 epoch 的信令。
    //   幽灵会话/幽灵 Offer/Answer 错配整类问题从协议层根绝（时间窗/防抖降级为纯保险）。
    m_p2pEpoch = QDateTime::currentMSecsSinceEpoch();
    p2pLog(QString("[epoch] 新一轮协商 epoch=%1").arg(m_p2pEpoch));
    
    m_webrtcStatus = "P2P Connecting...";
    emit webrtcStatusChanged(m_webrtcStatus);

    // ⭐ §54.6（2026-07-31 日志实锤）：新一轮连接必须清掉上一轮的"已连接"残留。
    //   旧代码 disconnectP2P/connectP2P 都不复位 m_p2pConnected → 上一轮连通过之后，
    //   新一轮的**首个** fresh Offer 会被 handleP2POffer 误判为"重协商 reoffer"
    //   （判据 m_p2pConnected || ufrag 非空），把刚建好的 pipeline 又拆一遍重建，
    //   白白撑大与 iOS trickle ICE 的竞态窗（21:22:28 轮实录）。
    m_p2pConnected = false;

    if (m_pipeline) {
        stop();
        destroyPipeline();
    }
    
    if (!createPipeline()) {
        m_webrtcStatus = "P2P Pipeline creation failed";
        emit webrtcStatusChanged(m_webrtcStatus);
        emit error("Failed to create P2P WebRTC pipeline");
        return;
    }
    
    addP2PIceServers(iceServers);
    
    start();
    
    m_waitingForP2POffer.store(true);
    emit sendViewRequest(m_pairedIosDeviceId);
    qDebug() << "[P2P] 已发送 WEBRTC_REQUEST，等待 iOS Offer...";
    p2pLog("[request] 已发送 WEBRTC_REQUEST，等待 iOS 回 Offer（若长时间无 [offer] = iOS 不在线/未响应）");
    scheduleP2PViewRequestRetry();
}

void GstPlayer::disconnectP2P()
{
    qDebug() << "[P2P] 断开 P2P 连接";
    stopP2PViewRequestRetry("本地主动断开");
    
    if (!m_pairedIosDeviceId.isEmpty()) {
        emit sendHangup("pc_disconnect", m_pairedIosDeviceId);
    }
    
    stop();
    destroyPipeline();
    
    m_webrtcConnected = false;
    m_p2pConnected = false;   // §54.6：不复位会让下一轮首个 Offer 被误判成 reoffer（见 connectP2P 注释）
    m_useP2P = false;
    m_pairedIosDeviceId.clear();
    m_noFpsSeconds.store(0);
    m_offerSentForSession.store(false);
    m_offerInProgress.store(false);
    m_webrtcStatus = "P2P Disconnected";
    emit webrtcStatusChanged(m_webrtcStatus);
    emit webrtcDisconnected();
}

void GstPlayer::setKernelTestMode(bool on)
{
    const bool was = m_kernelTestMode.exchange(on);
    if (was == on) return;
    qDebug() << "[P2P] 内核测试模式" << (on ? "开启 → GStreamer 让出 P2P（停拉流/停渲染/停信令）"
                                            : "关闭 → 恢复 GStreamer P2P 接管");
    if (on) {
        // 彻底停掉当前 GStreamer P2P：停止重试、关闭管线、清状态（不再向 iOS 发 HANGUP，
        //   避免误伤——内核会用同一 username 继续协商；让出会话仅靠不再处理信令/不重启即可）。
        stopP2PViewRequestRetry("内核测试接管");
        stop();
        destroyPipeline();
        m_webrtcConnected = false;
        m_useP2P = false;
        m_noFpsSeconds.store(0);
        m_offerSentForSession.store(false);
        m_offerInProgress.store(false);
        m_reconnectScheduled.store(true);   // 顺带压制 watchdog 自动重连
        m_webrtcStatus = "P2P 已让给内核测试";
        emit webrtcStatusChanged(m_webrtcStatus);
    } else {
        m_reconnectScheduled.store(false);
    }
}

void GstPlayer::handleWebRTCSignaling(const QJsonObject &message)
{
    // ⭐ 内核测试模式下，所有 WebRTC 信令交给内核处理，GStreamer 不碰，避免双端抢会话。
    if (m_kernelTestMode.load()) {
        return;
    }

    QString type = message.value("type").toString();
    
    // ⭐⭐ §53.25：会话 epoch 校验——设备端回带的 epoch 与当前轮次不符 = 上一轮的过期信令
    //  （幽灵 Offer / 迟到 ICE / 旧会话 HANGUP），直接丢弃。缺字段（老版本设备端）= 放行。
    {
        const qint64 msgEpoch = static_cast<qint64>(message.value("epoch").toDouble(0));
        if (msgEpoch > 0 && m_p2pEpoch > 0 && msgEpoch != m_p2pEpoch
            && (type == "WEBRTC_SDP" || type == "WEBRTC_ICE" || type == "WEBRTC_HANGUP")) {
            p2pLog(QString("[epoch] 🗑 丢弃过期轮次信令 type=%1 msgEpoch=%2 当前=%3")
                   .arg(type).arg(msgEpoch).arg(m_p2pEpoch));
            return;
        }
    }
    
    if (type == "WEBRTC_SDP") {
        QString sdpType = message.value("sdpType").toString();
        QString sdp = message.value("sdp").toString();
        
        if (sdpType == "offer") {
            qDebug() << "[P2P] 收到 iOS Offer";
            stopP2PViewRequestRetry("收到 iOS Offer");
            handleP2POffer(sdp);
        } else if (sdpType == "answer") {
            qDebug() << "[P2P] 意外收到 Answer，忽略";
        }
        
    } else if (type == "WEBRTC_ICE") {
        QString candidate = message.value("candidate").toString();
        QString sdpMid = message.value("sdpMid").toString();
        int sdpMLineIndex = message.value("sdpMLineIndex").toInt(0);
        handleP2PIce(candidate, sdpMid, sdpMLineIndex);
        
    } else if (type == "WEBRTC_HANGUP") {
        QString reason = message.value("reason").toString();
        qDebug() << "[P2P] iOS 端挂断:" << reason;
        // iOS 切网主动重连：iOS 拆掉旧会话并要 PC 重新发起，这里【不彻底拆 pipeline】，
        // 直接主动重连（重发 WEBRTC_REQUEST 让 iOS 重新发 Offer），避免“PC 拆了又没人请求”的死锁。
        if (reason == "network_switch_reconnect" && m_useP2P && !m_pairedIosDeviceId.isEmpty()) {
            qWarning() << "[P2P] iOS 切网重连信号 → PC 主动重发观看请求";
            m_p2pConnected = false;
            m_iceReconnecting = false;           // 允许本次重连
            m_iceReconnectEpoch.fetch_add(1);    // 让待定的 DISCONNECTED 延迟检查失效
            attemptP2PIceReconnect("iOS 切网(network_switch_reconnect)");
        } else {
            stopP2PViewRequestRetry("收到远端挂断");
            if (reason == "ice_failed") {
                m_webrtcStatus = "P2P connection failed (ICE)";
                emit webrtcStatusChanged(m_webrtcStatus);
                emit error("P2P 直连失败：NAT穿透失败，请检查网络环境");
            }
            handleP2PHangup();
        }
        
    } else if (type == "WEBRTC_REJECT") {
        stopP2PViewRequestRetry("收到观看请求拒绝");
        QString reason = message.value("reason").toString();
        qDebug() << "[P2P] 观看请求被拒绝:" << reason;
        
        if (reason == "max_viewers_reached") {
            m_webrtcStatus = "P2P rejected: max viewers";
            emit error("该设备已达到最大观看人数上限");
        } else if (reason == "single_mode_occupied") {
            // ⭐ §53.20.3：设备处于 P2P 单人直连、已被先来的 PC 占用（先到先得）。
            //   不自动重试——占线状态短时间不会变，重试只会刷屏；用户看提示自行决定。
            // ⭐ 2026-08-01：改发专用信号，QML 弹框提示 + 置"单人占用"标记停掉 §54 自愈重连
            //   （只 emit error 的话 QML 看门狗 8s 后又 playP2P 重连、又被拒 → 反复卡死）。
            m_webrtcStatus = "P2P rejected: single mode occupied";
            emit p2pRejectedSingleMode();
        } else if (reason == "not_ready") {
            m_webrtcStatus = "P2P rejected: not ready";
            emit error("设备未就绪，请稍后重试");
            QTimer::singleShot(3000, this, [this]() {
                if (m_useP2P && !m_pairedIosDeviceId.isEmpty()) {
                    qDebug() << "[P2P] 自动重试 WEBRTC_REQUEST...";
                    emit sendViewRequest(m_pairedIosDeviceId);
                }
            });
        }
        emit webrtcStatusChanged(m_webrtcStatus);
    }
}

void GstPlayer::handleP2POffer(const QString &sdp)
{
    // ⭐⭐ §53.24：Offer 风暴防抖（2026-07-30 01:46 实测：700ms 内连收 4 个 Offer）。
    //   设备端会话抖动（请求→断开→再请求）时可能连发多个 Offer（含被拆会话的过期 Offer），
    //   每个新 ufrag 都触发下面的「整条 pipeline 重建」——重建风暴中两端互相打断永远连不通。
    //   收敛策略 = 只应用最后一个：距上次应用 <800ms 的 Offer 先暂存（新的覆盖旧的），
    //   300ms 无更新后统一应用最新那份。正常单发 Offer 完全不受影响（间隔远大于 800ms）。
    {
        qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        if (m_lastOfferAppliedMs > 0 && nowMs - m_lastOfferAppliedMs < 800) {
            m_pendingP2POfferSdp = sdp;   // 注意：与 SRS 路径的 m_pendingOfferSdp 无关，专用成员
            if (!m_offerDebounceTimer) {
                m_offerDebounceTimer = new QTimer(this);
                m_offerDebounceTimer->setSingleShot(true);
                connect(m_offerDebounceTimer, &QTimer::timeout, this, [this]() {
                    if (m_pendingP2POfferSdp.isEmpty()) return;
                    QString latest = m_pendingP2POfferSdp;
                    m_pendingP2POfferSdp.clear();
                    m_lastOfferAppliedMs = 0;   // 放行本次应用（防抖窗口只针对风暴期间）
                    p2pLog("[offer] 防抖窗口结束 → 应用暂存的最新 Offer");
                    handleP2POffer(latest);
                });
            }
            m_offerDebounceTimer->start(300);
            p2pLog(QString("[offer] 距上次应用仅 %1ms（Offer 风暴）→ 暂存最新、300ms 后统一应用")
                   .arg(nowMs - m_lastOfferAppliedMs));
            return;
        }
        m_lastOfferAppliedMs = nowMs;
    }
    
    if (!m_webrtcbin) {
        qWarning() << "[P2P] webrtcbin 未初始化，无法处理 Offer";
        return;
    }
    
    GstSDPMessage *sdpMsg;
    gst_sdp_message_new(&sdpMsg);
    
    QByteArray sdpBytes = sdp.toUtf8();
    if (gst_sdp_message_parse_buffer((const guint8*)sdpBytes.constData(), sdpBytes.size(), sdpMsg) != GST_SDP_OK) {
        qWarning() << "[P2P] 解析 Offer SDP 失败";
        gst_sdp_message_free(sdpMsg);
        return;
    }
    
    GstWebRTCSessionDescription *offer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_OFFER, sdpMsg);

    // ⭐ H265 会话：把 iOS 完整 Offer SDP dump 到 h265_diag.txt，定位「无 BUNDLE / 编码协商」问题。
    //   重点看：① a=group:BUNDLE 是否存在；② m=video 行；③ 有哪些 a=rtpmap（H265? H264 还在吗?）。
    if (m_useH265) {
        H265Support::log("========== 收到 iOS Offer（H265 会话）完整 SDP ↓↓↓ ==========");
        H265Support::log(sdp);
        H265Support::log("========== iOS Offer SDP ↑↑↑ ==========");
        bool offerBundle = sdp.contains("a=group:BUNDLE", Qt::CaseInsensitive);
        bool offerH265 = sdp.contains("H265", Qt::CaseInsensitive) || sdp.contains("HEVC", Qt::CaseInsensitive);
        bool offerH264 = sdp.contains("H264", Qt::CaseInsensitive);
        H265Support::log(QString("[Offer分析] 含BUNDLE=%1 含H265=%2 含H264(兜底)=%3 %4")
            .arg(offerBundle ? "是" : "否❌").arg(offerH265 ? "是" : "否").arg(offerH264 ? "是" : "否❌")
            .arg(!offerH264 ? "→ Offer 无 H264 兜底，PC 若不支持 H265 接收就会拒绝 m-line 导致无 BUNDLE" : ""));
    }

    // ⭐ 诊断：Offer 里是否已内联 relay 候选者（iOS 可能把候选者写进 Offer 而非单独发）
    {
        int offerRelay = sdp.count("typ relay", Qt::CaseInsensitive);
        int offerSrflx = sdp.count("typ srflx", Qt::CaseInsensitive);
        int offerHost  = sdp.count("typ host", Qt::CaseInsensitive);
        p2pLog(QString("[offer] 收到 iOS Offer SDP（长度=%1）。内联候选者统计：host=%2 srflx=%3 relay=%4 %5")
               .arg(sdp.size()).arg(offerHost).arg(offerSrflx).arg(offerRelay)
               .arg(offerRelay == 0 && offerSrflx == 0 && offerHost == 0
                    ? "（Offer 无内联候选者，靠后续 [远端候选] trickle）"
                    : (offerRelay > 0 ? "✅ Offer 含 relay" : "")));
    }

    // ⭐⭐⭐ 切网重协商防卡死（2026-07-09 修「切网后必须手动重登才出画面」根因）：
    //   手机切网时若其 PeerConnection 尚未 FAILED，会发 ICE Restart re-offer（新 ice-ufrag）。
    //   GStreamer webrtcbin 不会在旧实例上重启 libnice/重新收集候选 → 新 ICE 永远配不通、卡死。
    //   检测「已建立会话 + ufrag 变化」= 重协商 → 先整体重建 pipeline，再把本 offer apply 到全新
    //   webrtcbin（等价一次干净重连，与手动重登的效果一致，但全自动）。
    {
        QString newUfrag;
        for (const QString &line : sdp.split('\n')) {
            const QString t = line.trimmed();
            if (t.startsWith("a=ice-ufrag:")) { newUfrag = t.mid(12).trimmed(); break; }
        }
        const bool isRenegotiation = (m_p2pConnected || !m_currentRemoteIceUfrag.isEmpty())
                                     && !newUfrag.isEmpty() && newUfrag != m_currentRemoteIceUfrag;
        if (isRenegotiation) {
            p2pLog(QString("[reoffer] 检测到重协商 Offer(ufrag %1→%2, 已连接=%3) → 重建 pipeline 再应用"
                           "（GStreamer 无法在旧 webrtcbin 上 ICE Restart，复用必卡死）")
                   .arg(m_currentRemoteIceUfrag.isEmpty() ? "-" : m_currentRemoteIceUfrag, newUfrag)
                   .arg(m_p2pConnected));
            m_p2pConnected = false;
            m_webrtcStatus = "P2P: 切网重连中...";
            emit webrtcStatusChanged(m_webrtcStatus);
            stop();
            destroyPipeline();   // 内部会清空 m_currentRemoteIceUfrag
            m_offerSentForSession.store(false);
            m_offerInProgress.store(false);
            m_noFpsSeconds.store(0);
            if (!createPipeline()) {
                qWarning() << "[P2P] 重协商重建 pipeline 失败";
                gst_webrtc_session_description_free(offer);
                return;
            }
            addP2PIceServers(m_p2pIceServers);
            start();
        }
        m_currentRemoteIceUfrag = newUfrag;
    }

    GstPromise *setPromise = gst_promise_new();
    g_signal_emit_by_name(m_webrtcbin, "set-remote-description", offer, setPromise);
    // ⭐⭐⭐ 2026-07-19 修「H265 十次约三次黑屏」：必须等 set-remote-description 真正执行完。
    //   原来 gst_promise_interrupt 不等待——SRD 是 webrtcbin 内部线程的异步操作，transceiver
    //   由它创建；下面紧接着的 get-transceivers 是同步取值，赶在 SRD 完成前调用就拿到 0 个
    //   → codec-preferences=H265 / do-nack 全都没设上 → webrtcbin 默认偏好回 H264 Answer
    //   → H264 流喂进 rtph265depay = not-negotiated → 黑屏。是否黑屏取决于线程调度先后，
    //   与实测「10 次约 7 次能出画面」吻合（nack_diag 里失败场次应有「transceiver 数量=0」）。
    //   SRD 为进程内 CPU 操作（解析 SDP/建 transceiver），等待通常几 ms，可接受。
    //   H264 P2P 同样受益：do-nack 不再有概率漏设（漏设=弱网无重传，花屏概率高）。
    gst_promise_wait(setPromise);
    gst_promise_unref(setPromise);
    gst_webrtc_session_description_free(offer);
    
    qDebug() << "[P2P] 已设置远端 Offer SDP（SRD 已确认完成）";

    // ⭐⭐⭐ P2P 对标 Chrome：在 Answerer 侧的 transceiver 上启用 NACK 重传（核心！）
    //   P2P 模式 PC 是 Answerer，不走 createWebRTCOffer()，transceiver 是 set-remote-description
    //   后由远端 Offer 协商产生。必须在 create-answer 之前对这些 transceiver 设 do-nack=TRUE，
    //   否则 Answer 不会带 a=rtcp-fb nack，丢包只能等关键帧 → 花屏（与 SRS 路径行为对齐）。
    {
        // 诊断：把收到的 Offer SDP 关键行写入 nack_diag.txt
        bool offerHasNack = sdp.contains("nack", Qt::CaseInsensitive);
        bool offerHasRtx = sdp.contains("rtx", Qt::CaseInsensitive) || sdp.contains("apt=", Qt::CaseInsensitive);
        nackLog(QString("[P2P Offer来自iOS] 含 nack=%1, 含 rtx=%2  %3")
                .arg(offerHasNack ? "是✅" : "否❌")
                .arg(offerHasRtx ? "是✅" : "否❌")
                .arg(offerHasNack ? "→ iOS 已协商 NACK" : "→ iOS 未在 Offer 写 nack，Answerer 也开不了，需改 iOS"));
        for (const QString &line : sdp.split('\n')) {
            if (line.contains("rtcp-fb", Qt::CaseInsensitive) || line.startsWith("a=rtpmap", Qt::CaseInsensitive)) {
                nackLog(QString("[P2P Offer行] %1").arg(line.trimmed()));
            }
        }

        GArray *transceivers = nullptr;
        g_signal_emit_by_name(m_webrtcbin, "get-transceivers", &transceivers);
        if (transceivers) {
            nackLog(QString("[配置] P2P transceiver 数量=%1").arg(transceivers->len));
            for (guint i = 0; i < transceivers->len; i++) {
                GstWebRTCRTPTransceiver *trans = g_array_index(transceivers, GstWebRTCRTPTransceiver*, i);
                if (!trans) continue;
                GObjectClass *tcls = G_OBJECT_GET_CLASS(trans);
                // ⭐⭐⭐ H265 关键修复：强制该 transceiver 只用 H265 应答。
                //   根因：iOS Offer 同时含 H265+H264，webrtcbin 默认偏好 H264 → Answer 回 H264，
                //   但 PC 管线是 rtph265depay(只解H265) → H264 流喂进 rtph265depay = not-negotiated。
                //   设 codec-preferences=H265 后 webrtcbin 必回 H265 Answer，与 rtph265depay 对上。
                if (m_useH265 && g_object_class_find_property(tcls, "codec-preferences")) {
                    GstCaps *h265Caps = gst_caps_from_string(
                        "application/x-rtp, media=(string)video, encoding-name=(string)H265, clock-rate=(int)90000");
                    g_object_set(trans, "codec-preferences", h265Caps, nullptr);
                    gst_caps_unref(h265Caps);
                    H265Support::log(QString("[协商] transceiver[%1] codec-preferences=H265 → 强制 Answer 用 H265(匹配 rtph265depay)").arg(i));
                } else if (m_useH265) {
                    H265Support::log(QString("⚠️ transceiver[%1] 无 codec-preferences 属性，无法强制 H265").arg(i));
                }
                if (g_object_class_find_property(tcls, "do-nack")) {
                    g_object_set(trans, "do-nack", TRUE, nullptr);
                    gboolean nackOn = FALSE;
                    g_object_get(trans, "do-nack", &nackOn, nullptr);
                    qDebug() << "✅ [P2P] transceiver[" << i << "] do-nack=TRUE（Answerer 启用 NACK 重传）";
                    diagLog(QString("✅ [P2P] transceiver[%1] do-nack=TRUE（Answerer 启用 NACK 重传，对标 Chrome）").arg(i));
                    nackLog(QString("[配置] P2P transceiver[%1] do-nack 设置成功，回读=%2 (1=已启用)").arg(i).arg(nackOn ? 1 : 0));
                } else {
                    qWarning() << "⚠️ [P2P] transceiver 无 do-nack 属性（GStreamer 版本过旧？）";
                    diagLog("⚠️ [P2P] transceiver 无 do-nack 属性，NACK 未启用（建议升级 GStreamer ≥1.20）");
                    nackLog("⚠️ [配置] P2P transceiver 无 do-nack 属性 → NACK 未启用！请升级 GStreamer ≥1.20");
                }
            }
            g_array_unref(transceivers);
        } else {
            nackLog("⚠️ [配置] P2P get-transceivers 返回空，无法设置 do-nack");
        }
    }

    qDebug() << "[P2P] 创建 Answer...";
    GstPromise *answerPromise = gst_promise_new_with_change_func(
        [](GstPromise *promise, gpointer userData) {
            GstPlayer *self = static_cast<GstPlayer*>(userData);
            
            const GstStructure *reply = gst_promise_get_reply(promise);
            if (!reply) {
                qWarning() << "[P2P] 创建 Answer 失败：无回复";
                return;
            }
            
            GstWebRTCSessionDescription *answer = nullptr;
            gst_structure_get(reply, "answer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &answer, nullptr);
            
            if (answer) {
                self->onP2PAnswerCreated(answer);
                gst_webrtc_session_description_free(answer);
            } else {
                qWarning() << "[P2P] 创建 Answer 失败：无 SDP";
            }
        },
        this, nullptr);
    
    g_signal_emit_by_name(m_webrtcbin, "create-answer", nullptr, answerPromise);
}

void GstPlayer::onP2PAnswerCreated(GstWebRTCSessionDescription *answer)
{
    qDebug() << "[P2P] Answer 创建成功";
    
    GstPromise *localPromise = gst_promise_new();
    g_signal_emit_by_name(m_webrtcbin, "set-local-description", answer, localPromise);
    gst_promise_interrupt(localPromise);
    gst_promise_unref(localPromise);
    
    gchar *sdpText = gst_sdp_message_as_text(answer->sdp);
    QString sdpStr = QString::fromUtf8(sdpText);
    g_free(sdpText);
    
    p2pLog(QString("[answer] Answer 已创建并设为本地描述（长度=%1），发送给 iOS。"
                   "信令至此双向打通，接下来看 [本地候选]/[远端候选] 和 [ice] 状态")
           .arg(sdpStr.size()));

    // ⭐ H265 会话：dump PC 生成的完整 Answer SDP + 关键分析（iOS 报「no BUNDLE group」时看这里）。
    if (m_useH265) {
        H265Support::log("========== PC 生成的 Answer（H265 会话）完整 SDP ↓↓↓ ==========");
        H265Support::log(sdpStr);
        H265Support::log("========== PC Answer SDP ↑↑↑ ==========");
        bool ansBundle = sdpStr.contains("a=group:BUNDLE", Qt::CaseInsensitive);
        bool ansH265 = sdpStr.contains("H265", Qt::CaseInsensitive) || sdpStr.contains("HEVC", Qt::CaseInsensitive);
        bool ansH264 = sdpStr.contains("H264", Qt::CaseInsensitive);
        bool videoRejected = sdpStr.contains("m=video 0 ", Qt::CaseInsensitive);
        H265Support::log(QString("[Answer分析] 含BUNDLE=%1 协商到H265=%2 协商到H264=%3 视频m-line被拒(端口0)=%4 %5")
            .arg(ansBundle ? "是" : "否❌").arg(ansH265 ? "是" : "否").arg(ansH264 ? "是" : "否").arg(videoRejected ? "是❌" : "否")
            .arg(!ansBundle ? "→ 这就是 iOS 报 no BUNDLE group 的原因：webrtcbin 拒绝了视频 m-line（对 iOS Offer 里的编码不支持接收）" : ""));
    }

    QMetaObject::invokeMethod(this, [this, sdpStr]() {
        qDebug() << "[P2P] 发送 Answer SDP 给 iOS";
        emit sendSdpAnswer(sdpStr, m_pairedIosDeviceId);
    }, Qt::QueuedConnection);
}

void GstPlayer::handleP2PIce(const QString &candidate, const QString &sdpMid, int sdpMLineIndex)
{
    if (!m_webrtcbin) {
        qWarning() << "[P2P] webrtcbin 未初始化，缓存 ICE 候选者";
        p2pLog("[远端候选] ⚠️ webrtcbin 未初始化，丢弃了一条远端 ICE 候选者（时序问题）");
        return;
    }

    // ⭐ 诊断：远端(iOS)候选者按 typ 分类统计。iOS 在手机热点时，它自己的 host/srflx 也多半无效，
    //    关键看 iOS 有没有给出 typ relay（说明 iOS 侧 TURN 也配好了）。
    QString typ = p2pCandidateType(candidate);
    int slot = (typ == "host") ? 0 : (typ == "srflx") ? 1 : (typ == "relay") ? 2 : 3;
    int n = ++m_p2pRemoteCand[slot];
    p2pLog(QString("[远端候选 #%1] typ=%2  %3")
           .arg(n).arg(typ)
           .arg(typ == "relay" ? "✅ iOS 给出了 TURN relay 候选者（热点下两端都需要 relay 才能配对）" : ""));

    qDebug() << "[P2P] 添加远端 ICE:" << candidate.left(50) << "...";
    g_signal_emit_by_name(m_webrtcbin, "add-ice-candidate", (guint)sdpMLineIndex,
                          candidate.toUtf8().constData());
}

// ⭐ webrtcbin get-stats 异步回调：解析「选中候选对」的 local/remote candidate-type，
//   缓存到 m_routeLocalCode/m_routeRemoteCode，供面板显示真实 relay/直连。
//   选对策略：优先 nominated；否则取收发字节数最大的活跃对。candidate-type 为 webrtc-stats
//   标准字符串 host/srflx/prflx/relay。回调在 webrtcbin 线程触发，只写 atomic，线程安全。
void GstPlayer::onWebRtcStatsReady(GstPromise *promise, gpointer userData)
{
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    if (!promise) return;
    const GstStructure *reply = gst_promise_get_reply(promise);
    if (!self || !reply) { gst_promise_unref(promise); return; }

    QHash<QString, int> idToType;   // 候选 id → 类型码
    struct PairInfo { QString lid, rid; quint64 bytes; bool nominated; };
    QList<PairInfo> pairs;

    const int n = gst_structure_n_fields(reply);
    for (int i = 0; i < n; ++i) {
        const char *fname = gst_structure_nth_field_name(reply, i);
        const GValue *v = gst_structure_get_value(reply, fname);
        if (!v || !GST_VALUE_HOLDS_STRUCTURE(v)) continue;
        const GstStructure *sub = gst_value_get_structure(v);
        if (!sub) continue;

        const gchar *ctype = gst_structure_get_string(sub, "candidate-type");
        if (ctype) {
            idToType.insert(QString::fromUtf8(fname), GstPlayer::iceCandTypeCode(ctype));
            continue;
        }
        if (gst_structure_has_field(sub, "local-candidate-id") &&
            gst_structure_has_field(sub, "remote-candidate-id")) {
            PairInfo p;
            const gchar *lid = gst_structure_get_string(sub, "local-candidate-id");
            const gchar *rid = gst_structure_get_string(sub, "remote-candidate-id");
            p.lid = lid ? QString::fromUtf8(lid) : QString();
            p.rid = rid ? QString::fromUtf8(rid) : QString();
            guint64 br = 0, bs = 0;
            gst_structure_get_uint64(sub, "bytes-received", &br);
            gst_structure_get_uint64(sub, "bytes-sent", &bs);
            p.bytes = br + bs;
            gboolean nom = FALSE;
            gst_structure_get_boolean(sub, "nominated", &nom);
            p.nominated = nom;
            pairs.append(p);
        }
    }

    int best = -1; quint64 bestBytes = 0;
    for (int i = 0; i < pairs.size(); ++i) { if (pairs[i].nominated) { best = i; break; } }
    if (best < 0) {
        for (int i = 0; i < pairs.size(); ++i) {
            if (best < 0 || pairs[i].bytes > bestBytes) { best = i; bestBytes = pairs[i].bytes; }
        }
    }
    if (best >= 0) {
        self->m_routeLocalCode.store(idToType.value(pairs[best].lid, 0));
        self->m_routeRemoteCode.store(idToType.value(pairs[best].rid, 0));
    }
    gst_promise_unref(promise);
}

void GstPlayer::handleP2PHangup()
{
    qDebug() << "[P2P] 处理挂断";
    stopP2PViewRequestRetry("处理挂断");
    
    stop();
    destroyPipeline();
    
    m_webrtcConnected = false;
    m_webrtcStatus = "P2P Hangup";
    emit webrtcStatusChanged(m_webrtcStatus);
    emit webrtcDisconnected();
}

void GstPlayer::scheduleP2PViewRequestRetry()
{
    QTimer::singleShot(P2P_VIEW_REQUEST_RETRY_INTERVAL_MS, this, [this]() {
        if (!m_waitingForP2POffer.load() || !m_useP2P || m_pairedIosDeviceId.isEmpty()) {
            return;
        }

        int retry = m_p2pViewRequestRetryCount.fetch_add(1) + 1;
        // ⭐ §54（2026-07-31）权威修复：等 Offer 改为**常驻循环，永不放弃**。
        //   原来 5 次(7.5s)耗尽 → "waiting offer timeout" 终态，之后 iOS 心跳照来但流名不变
        //   → 没有任何"边沿"再触发连接 → 两端都在线却永久黑屏（iOS 重进的就绪窗口正好
        //   盖过这 7.5s = 客户现场黑屏的头号成因）。
        //   现在：同 epoch 每 1.5s 重发（iOS 端幂等：正在服务同轮次则忽略，无会话则建新回 Offer），
        //   停止条件只有：收到 Offer / HANGUP / REJECT / QML 主动断开（设备停推、心跳超时、用户操作）。
        //   信令包几百字节，1.5s 一发零成本；设备真离线时 QML 心跳超时(6s)会 disconnectP2P 终止本循环。
        if (retry % 10 == 0) {
            m_webrtcStatus = QString("P2P 等待设备响应(%1s)...")
                                 .arg(retry * P2P_VIEW_REQUEST_RETRY_INTERVAL_MS / 1000);
            emit webrtcStatusChanged(m_webrtcStatus);
            p2pLog(QString("[request] 已重发 %1 次仍未收到 Offer，继续常驻重发"
                           "（§54：设备在线则其就绪后的第一次重发即会得到 Offer）").arg(retry));
        }
        qDebug() << "[P2P] 未收到 Offer，重发 WEBRTC_REQUEST (#" << retry << ")";
        emit sendViewRequest(m_pairedIosDeviceId);
        scheduleP2PViewRequestRetry();
    });
}

void GstPlayer::stopP2PViewRequestRetry(const QString &reason)
{
    bool wasWaiting = m_waitingForP2POffer.exchange(false);
    m_p2pViewRequestRetryCount.store(0);
    if (wasWaiting && !reason.isEmpty()) {
        qDebug() << "[P2P] 停止 WEBRTC_REQUEST 重试:" << reason;
    }
}

// ICE 断线/失败（典型场景：iOS 切换网络换 WiFi / iOS 硬切中继拆会话）后的主动重连。
// PC 是 Answerer，恢复方式是重发 WEBRTC_REQUEST，让 iOS 重新发起 Offer。
// ⭐ §25.7e 修复（2026-07-04 日志实锤）：旧实现在【现有 webrtcbin】上收新 ufrag 的 Offer，
//   但 GStreamer webrtcbin 不会重启 libnice、不重新收集候选（回 Answer 却零新增 [本地候选]），
//   新会话的连通性检查永远配不成 → 25s 后 ICE FAILED 白等一轮。
//   改为重连前【整体重建 pipeline】（销毁旧 webrtcbin → 新建 → 重配 ICE 服务器），
//   新 webrtcbin 对新 Offer 全量收集候选，一次配通。
void GstPlayer::attemptP2PIceReconnect(const QString &reason)
{
    if (!m_useP2P || m_pairedIosDeviceId.isEmpty()) return;
    if (m_p2pConnected) return;            // 已恢复，无需重连
    if (m_iceReconnecting) {
        qDebug() << "[P2P] 已在重连中，忽略重复触发:" << reason;
        return;
    }

    // ⭐ §54（2026-07-31）：重连**无上限**——原 5 次耗尽后"请手动重试"是三条永久放弃终态之一
    //   （另两条：等 Offer 5 次超时、SRS 400 重试用尽），命中即"两端都在线却永久黑屏"。
    //   现在：只要 QML 还认为该看这台设备（设备心跳在、publishStatus=1），重连就一直进行；
    //   设备真离线/停推时 QML 会 disconnectP2P，m_useP2P=false 自动终止。
    //   节奏：首次立即、之后 1s → 2s 封顶（每次重建都换新 epoch，iOS 幂等拆旧建新，无风暴）。
    m_iceReconnecting = true;
    int attempt = ++m_iceRetryCount;
    qWarning() << "[P2P] ICE 主动重连 (#" << attempt << ") 原因:" << reason;
    p2pLog(QString("[reconnect] 主动重连 (#%1) 原因=%2（重发 WEBRTC_REQUEST 让 iOS 带新候选者重协商；"
                   "§54 常驻重连，不再有次数上限）")
           .arg(attempt).arg(reason));
    m_webrtcStatus = QString("P2P: 重连中(#%1)...").arg(attempt);
    emit webrtcStatusChanged(m_webrtcStatus);

    // 节奏：首次立即，之后 1s、2s、2s...（封顶 2s，保证恢复窗口 ≤3s 目标）
    int delayMs = (attempt <= 1) ? 0 : qMin(500 << qMin(attempt - 1, 2), 2000);
    QTimer::singleShot(delayMs, this, [this, reason]() {
        if (!m_useP2P || m_pairedIosDeviceId.isEmpty()) { m_iceReconnecting = false; return; }
        if (m_p2pConnected) { m_iceReconnecting = false; return; }

        // ⭐ §25.7e：重建 pipeline（旧 webrtcbin 不认新 ufrag Offer / 不重新收集候选，必须换新）
        p2pLog("[reconnect] 重建 pipeline（旧 webrtcbin 不重启 libnice，复用必配不成 → 整体换新）");
        if (m_pipeline) {
            stop();
            destroyPipeline();
        }
        m_offerSentForSession.store(false);
        m_offerInProgress.store(false);
        m_noFpsSeconds.store(0);
        if (!createPipeline()) {
            qWarning() << "[P2P] 重连时重建 pipeline 失败";
            p2pLog("[reconnect] ❌ 重建 pipeline 失败，放弃本次重连");
            m_iceReconnecting = false;
            return;
        }
        addP2PIceServers(m_p2pIceServers);
        start();

        // 重置等待状态并重发观看请求；scheduleP2PViewRequestRetry 提供兜底重试
        m_waitingForP2POffer.store(true);
        m_p2pViewRequestRetryCount.store(0);
        // ⭐ §53.25：重建 pipeline = 新一轮协商 → 换新 epoch（旧轮次的 Offer/ICE 自动作废）
        m_p2pEpoch = QDateTime::currentMSecsSinceEpoch();
        p2pLog(QString("[epoch] 重建重连，新轮次 epoch=%1").arg(m_p2pEpoch));
        emit sendViewRequest(m_pairedIosDeviceId);
        qWarning() << "[P2P] 已重建 pipeline 并重发 WEBRTC_REQUEST 触发 iOS 重新协商:" << reason;
        scheduleP2PViewRequestRetry();
        m_iceReconnecting = false;  // 允许后续 ICE 事件再次触发（§54：无次数上限，计数仅用于日志/节奏）
    });
}

void GstPlayer::addP2PIceServers(const QJsonArray &iceServers)
{
    if (!m_webrtcbin || iceServers.isEmpty()) {
        p2pLog(QString("[ice-server] ⚠️ 未配置任何 ICE 服务器（webrtcbin=%1, iceServers空=%2）"
                       "→ 只能用 host/srflx 候选者，手机热点(CGNAT)下基本打不通")
               .arg(m_webrtcbin ? "有" : "无").arg(iceServers.isEmpty() ? "是" : "否"));
        return;
    }

    qDebug() << "[P2P] 配置 ICE 服务器，共" << iceServers.size() << "个";

    int stunCount = 0, turnCount = 0, turnFail = 0;
    for (const auto &server : iceServers) {
        QJsonObject obj = server.toObject();
        QJsonArray urls = obj["urls"].toArray();
        QString username = obj["username"].toString();
        QString credential = obj["credential"].toString();
        
        for (const auto &urlVal : urls) {
            QString urlStr = urlVal.toString();
            
            if (urlStr.startsWith("stun:")) {
                g_object_set(m_webrtcbin, "stun-server",
                             urlStr.toUtf8().constData(), nullptr);
                qDebug() << "  STUN:" << urlStr;
                stunCount++;
                p2pLog(QString("[ice-server] STUN = %1").arg(urlStr));
            } else if (urlStr.startsWith("turn:") || urlStr.startsWith("turns:")) {
                QString prefix = urlStr.startsWith("turns:") ? "turns:" : "turn:";
                QString encodedUser = QString::fromUtf8(QUrl::toPercentEncoding(username));
                QString encodedPass = QString::fromUtf8(QUrl::toPercentEncoding(credential));
                QString turnUri = QString("turn://%1:%2@%3")
                    .arg(encodedUser, encodedPass,
                         urlStr.mid(prefix.length()));
                
                gboolean addResult = FALSE;
                g_signal_emit_by_name(m_webrtcbin, "add-turn-server", 
                                      turnUri.toUtf8().constData(), &addResult);
                if (addResult) {
                    qDebug() << "  TURN (add-turn-server):" << turnUri.left(60) << "...";
                    turnCount++;
                    p2pLog(QString("[ice-server] TURN(add-turn-server 成功) = %1").arg(urlStr));
                } else {
                    g_object_set(m_webrtcbin, "turn-server",
                                 turnUri.toUtf8().constData(), nullptr);
                    qDebug() << "  TURN (property fallback):" << turnUri.left(60) << "...";
                    turnFail++;
                    p2pLog(QString("[ice-server] ⚠️ TURN add-turn-server 返回失败，已回退 property 方式 = %1 "
                                   "（若 relay 候选者收不到，多半是这里没真正生效）").arg(urlStr));
                }
            }
        }
    }

    p2pLog(QString("[ice-server] 汇总：STUN=%1 个, TURN成功=%2 个, TURN回退=%3 个  %4")
           .arg(stunCount).arg(turnCount).arg(turnFail)
           .arg(turnCount + turnFail == 0
                ? "❌ 没有任何 TURN！手机热点(CGNAT/对称NAT)下几乎不可能直连 → 这就是出不来的根因"
                : "✅ 有 TURN，热点下应能走 relay 候选者，继续看下面是否真收到 typ relay"));
}

QString GstPlayer::p2pCandSummary() const
{
    return QString("本地[host=%1 srflx=%2 relay=%3 其它=%4] 远端[host=%5 srflx=%6 relay=%7 其它=%8]")
        .arg(m_p2pLocalCand[0].load()).arg(m_p2pLocalCand[1].load())
        .arg(m_p2pLocalCand[2].load()).arg(m_p2pLocalCand[3].load())
        .arg(m_p2pRemoteCand[0].load()).arg(m_p2pRemoteCand[1].load())
        .arg(m_p2pRemoteCand[2].load()).arg(m_p2pRemoteCand[3].load());
}

void GstPlayer::onIceConnectionStateChanged(GstElement *webrtcbin, GParamSpec *pspec, gpointer userData)
{
    Q_UNUSED(pspec);
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    
    GstWebRTCICEConnectionState state;
    g_object_get(webrtcbin, "ice-connection-state", &state, nullptr);
    
    QMetaObject::invokeMethod(self, [self, state]() {
        switch (state) {
        case GST_WEBRTC_ICE_CONNECTION_STATE_NEW:
            qDebug() << "[P2P] ICE Connection: New";
            break;
        case GST_WEBRTC_ICE_CONNECTION_STATE_CHECKING:
            qDebug() << "[P2P] ICE Connection: Checking...";
            self->m_webrtcStatus = "P2P: ICE Checking...";
            p2pLog(QString("[ice] Checking... 开始 NAT 穿透配对。当前候选者：%1").arg(self->p2pCandSummary()));
            emit self->webrtcStatusChanged(self->m_webrtcStatus);
            break;
        case GST_WEBRTC_ICE_CONNECTION_STATE_CONNECTED:
            qDebug() << "[P2P] ICE Connection: Connected!";
            self->m_webrtcStatus = "P2P Connected";
            p2pLog(QString("[ice] ✅ Connected！NAT 穿透成功。候选者：%1。接下来等 [首帧] 才算真出画面")
                   .arg(self->p2pCandSummary()));
            self->m_p2pConnected = true;
            self->m_iceRetryCount = 0;
            // 连接恢复：清除重连状态，并推进 epoch 让待定的 DISCONNECTED 延迟检查失效
            self->m_iceReconnecting = false;
            self->m_iceReconnectEpoch.fetch_add(1);
            emit self->webrtcStatusChanged(self->m_webrtcStatus);
            break;
        case GST_WEBRTC_ICE_CONNECTION_STATE_COMPLETED:
            qDebug() << "[P2P] ICE Connection: Completed!";
            break;
        case GST_WEBRTC_ICE_CONNECTION_STATE_FAILED: {
            qDebug() << "[P2P] ICE Connection: FAILED!";
            self->m_webrtcStatus = "P2P: ICE Failed";
            // ⭐ 这里是「手机热点出不来」最常见的终点：dump 候选者汇总判定根因
            QString summary = self->p2pCandSummary();
            bool noLocalRelay = (self->m_p2pLocalCand[2].load() == 0);
            bool noRemoteRelay = (self->m_p2pRemoteCand[2].load() == 0);
            p2pLog(QString("[ice] ❌ FAILED！NAT 穿透失败。候选者：%1").arg(summary));
            if (noLocalRelay || noRemoteRelay) {
                p2pLog(QString("[ice] 🔴 根因高度可疑：%1%2 → 手机热点是 CGNAT/对称 NAT，"
                               "没有 relay 候选者就只能靠 host/srflx 直连，热点下基本打不通。"
                               "对策：①确认后端给 P2P 下发了可用 TURN；②确认 iOS 侧也配了同一组 TURN；"
                               "③TURN 服务器(47.122.115.33)的 UDP 端口对手机网络放行。")
                       .arg(noLocalRelay ? "本地无 relay 候选者 " : "")
                       .arg(noRemoteRelay ? "远端(iOS)无 relay 候选者" : ""));
            } else {
                p2pLog("[ice] 两端都有 relay 候选者却仍 FAILED → 可能 TURN 鉴权失败/中继端口被封，"
                       "检查 TURN 账号密码(credential)有效期与服务器可达性");
            }
            emit self->webrtcStatusChanged(self->m_webrtcStatus);
            // FAILED 不会自愈：P2P 模式立即主动重连（重发 WEBRTC_REQUEST 让 iOS 重发 Offer）
            self->attemptP2PIceReconnect("ICE FAILED");
            break;
        }
        case GST_WEBRTC_ICE_CONNECTION_STATE_DISCONNECTED:
            qDebug() << "[P2P] ICE Connection: Disconnected";
            self->m_webrtcStatus = "P2P: Reconnecting...";
            p2pLog("[ice] Disconnected（链路中断，可能 iOS 切网/热点掉线）。6s 内未恢复将主动重连");
            emit self->webrtcStatusChanged(self->m_webrtcStatus);
            // DISCONNECTED 可能短暂自愈：推进 epoch，延迟 6s 后若仍未恢复（epoch 未变）才主动重连。
            // iOS 换 WiFi 等场景多走到这里，避免干等 iOS 端 8s+15s 的被动超时。
            if (self->m_useP2P) {
                int myEpoch = self->m_iceReconnectEpoch.fetch_add(1) + 1;
                QTimer::singleShot(6000, self, [self, myEpoch]() {
                    if (!self->m_useP2P) return;
                    // epoch 变了说明期间已恢复或有新状态事件，放弃本次延迟重连
                    if (self->m_iceReconnectEpoch.load() != myEpoch) return;
                    if (self->m_p2pConnected) return;
                    self->attemptP2PIceReconnect("ICE DISCONNECTED 超时未恢复");
                });
            }
            break;
        case GST_WEBRTC_ICE_CONNECTION_STATE_CLOSED:
            qDebug() << "[P2P] ICE Connection: Closed";
            break;
        }
    }, Qt::QueuedConnection);
}

// ★★★ P2P 直连模式 END ★★★

void GstPlayer::setupWebRTCSignals()
{
    if (!m_webrtcbin) return;
    
    qDebug() << "📡 设置 WebRTCBin 信号...";
    
    // on-negotiation-needed：当需要协商时创建 offer
    g_signal_connect(m_webrtcbin, "on-negotiation-needed",
                     G_CALLBACK(onNegotiationNeeded), this);
    
    // on-ice-candidate：收集到 ICE 候选者
    g_signal_connect(m_webrtcbin, "on-ice-candidate",
                     G_CALLBACK(onIceCandidate), this);
    
    // pad-added：新的媒体 pad 添加时连接到解码器
    g_signal_connect(m_webrtcbin, "pad-added",
                     G_CALLBACK(onWebRTCPadAdded), this);
    
    // 连接状态变化
    g_signal_connect(m_webrtcbin, "notify::connection-state",
                     G_CALLBACK(onConnectionStateChanged), this);
    
    // ICE 收集状态变化
    g_signal_connect(m_webrtcbin, "notify::ice-gathering-state",
                     G_CALLBACK(onIceGatheringStateChanged), this);
    
    // ICE 连接状态变化（P2P 模式需要）
    g_signal_connect(m_webrtcbin, "notify::ice-connection-state",
                     G_CALLBACK(onIceConnectionStateChanged), this);
    
    qDebug() << "✅ WebRTCBin 信号设置完成";
}

// 静态回调：需要协商
void GstPlayer::onNegotiationNeeded(GstElement *webrtcbin, gpointer userData)
{
    Q_UNUSED(webrtcbin);
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    qDebug() << "🔄 on-negotiation-needed 触发";
    
    // 在主线程中创建 offer
    QMetaObject::invokeMethod(self, "createWebRTCOffer", Qt::QueuedConnection);
}

// 静态回调：ICE 候选者
void GstPlayer::onIceCandidate(GstElement *webrtcbin, guint mlineindex, gchar *candidate, gpointer userData)
{
    Q_UNUSED(webrtcbin);
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    qDebug() << "🧊 ICE 候选者:" << mlineindex << candidate;
    
    // P2P 模式：发送本地 ICE 候选者给远端
    if (self->m_useP2P && !self->m_pairedIosDeviceId.isEmpty()) {
        QString candidateStr = QString::fromUtf8(candidate);
        // ⭐ 诊断：本地候选者按 typ 分类统计（relay = 走 TURN 中继，热点下唯一可靠通道）
        QString typ = p2pCandidateType(candidateStr);
        int slot = (typ == "host") ? 0 : (typ == "srflx") ? 1 : (typ == "relay") ? 2 : 3;
        int n = ++self->m_p2pLocalCand[slot];
        p2pLog(QString("[本地候选 #%1] typ=%2  %3")
               .arg(n).arg(typ)
               .arg(typ == "relay" ? "✅ 本地拿到 TURN relay 候选者（热点下的救命通道）" : ""));
        QMetaObject::invokeMethod(self, [self, candidateStr, mlineindex]() {
            emit self->sendIceCandidate(candidateStr, "0", (int)mlineindex, self->m_pairedIosDeviceId);
        }, Qt::QueuedConnection);
    }
    // SRS 模式使用 ice-lite，不需要发送本地候选者
}

// 静态回调：新 pad 添加（连接到解码链）
void GstPlayer::onWebRTCPadAdded(GstElement *webrtcbin, GstPad *pad, gpointer userData)
{
    Q_UNUSED(webrtcbin);
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    
    gchar *padName = gst_pad_get_name(pad);
    qDebug() << "🔥 WebRTCBin pad-added:" << padName;
    
    // 检查是否是视频 RTP pad
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) {
        caps = gst_pad_query_caps(pad, nullptr);
    }
    
    if (caps) {
        GstStructure *s = gst_caps_get_structure(caps, 0);
        const gchar *mediaType = gst_structure_get_string(s, "media");
        const gchar *encoding = gst_structure_get_string(s, "encoding-name");
        
        qDebug() << "   媒体类型:" << (mediaType ? mediaType : "unknown")
                 << "编码:" << (encoding ? encoding : "unknown");
        
        // 只处理视频 H264 / H265
        bool isVideo = mediaType && g_strcmp0(mediaType, "video") == 0;
        bool isH264 = encoding && g_strcmp0(encoding, "H264") == 0;
        bool isH265 = H265Support::isH265EncodingName(encoding);
        if (isH265) {
            H265Support::log(QString("pad-added: 收到 H265 RTP pad（encoding=%1）").arg(encoding));
        }
        // ⭐ 防错接：H265 会话收到 H264 pad（或反过来）说明两端 codec 没对齐，打日志便于定位
        if (self->m_useH265 && isH264) {
            H265Support::log("⚠️ H265 会话收到 H264 pad！iOS 实际推的是 H264（SDK 不支持/回落），下游 h265 管线将解不出");
        } else if (!self->m_useH265 && isH265) {
            qWarning() << "⚠️ H264 会话收到 H265 pad！PC 未按 videoCodec 预建 H265 管线，画面将出不来";
        }
        
        if (isVideo || isH264 || isH265 || g_str_has_prefix(padName, "recv_rtp_src_")) {
            qDebug() << "✅ 发现视频 RTP pad，连接到解码器...";
            
            // 获取 rtph264depay 的 sink pad
            if (self->m_rtph264depay) {
                GstPad *sinkPad = gst_element_get_static_pad(self->m_rtph264depay, "sink");
                if (sinkPad && !gst_pad_is_linked(sinkPad)) {
                    GstPadLinkReturn ret = gst_pad_link(pad, sinkPad);
                    if (ret == GST_PAD_LINK_OK) {
                        qDebug() << "✅ 视频 pad 连接成功";
                        
                        // ⭐ pad 连接后请求首个关键帧（防止黑屏/绿幕）
                        // 🔥 2026-07-02 收敛：原 0/100/300ms 3 连改为立即 1 次 + 300ms 兜底 1 次，
                        //    避免与 onConnectionStateChanged 的 PLI 叠成初始 IDR 风暴。
                        qDebug() << "🔥 视频流已连接，立即请求首个关键帧...";
                        QMetaObject::invokeMethod(self, "requestKeyFrame", Qt::QueuedConnection);
                        QTimer::singleShot(300, self, [self]() {
                            if (self->m_pipeline) {
                                self->sendPLIRequest();
                            }
                        });
                    } else {
                        qWarning() << "❌ 视频 pad 连接失败:" << ret;
                    }
                }
                if (sinkPad) gst_object_unref(sinkPad);
            }
        }
        
        gst_caps_unref(caps);
    }
    
    g_free(padName);
}

// 静态回调：连接状态变化
void GstPlayer::onConnectionStateChanged(GstElement *webrtcbin, GParamSpec *pspec, gpointer userData)
{
    Q_UNUSED(pspec);
    GstPlayer *self = static_cast<GstPlayer*>(userData);
    
    GstWebRTCPeerConnectionState state;
    g_object_get(webrtcbin, "connection-state", &state, nullptr);
    
    QString stateStr;
    switch (state) {
        case GST_WEBRTC_PEER_CONNECTION_STATE_NEW:
            stateStr = "New";
            break;
        case GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTING:
            stateStr = "Connecting";
            break;
        case GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED:
            stateStr = "Connected";
            self->m_webrtcConnected = true;
            QMetaObject::invokeMethod(self, "webrtcConnected", Qt::QueuedConnection);
            // ⭐ 连接成功后请求关键帧（防止绿幕）。
            // 🔥 2026-07-02 收敛：原 0/100/300ms 3 连 PLI 逼发送端连出 3 个大 IDR，初始协商期就挤占上行。
            //    改为立即 1 次 + 300ms 兜底 1 次（RTCP PLI 在已建立连接上很可靠）。
            QMetaObject::invokeMethod(self, "requestKeyFrame", Qt::QueuedConnection);
            QTimer::singleShot(300, self, [self]() {
                if (self->m_webrtcConnected) {
                    self->sendPLIRequest();
                    qDebug() << "📨 PLI 兜底请求 (300ms)";
                }
            });
            qDebug() << "✅ WebRTC 连接已建立，已发送 PLI 请求（1+1 兜底）";
            break;
        case GST_WEBRTC_PEER_CONNECTION_STATE_DISCONNECTED:
            stateStr = "Disconnected";
            self->m_webrtcConnected = false;
            break;
        case GST_WEBRTC_PEER_CONNECTION_STATE_FAILED:
            stateStr = "Failed";
            self->m_webrtcConnected = false;
            // 🔥 只断开，不自动重连（由 QML 层决定是否重连）
            QMetaObject::invokeMethod(self, "disconnectWebRTC", Qt::QueuedConnection);
            break;
        case GST_WEBRTC_PEER_CONNECTION_STATE_CLOSED:
            stateStr = "Closed";
            self->m_webrtcConnected = false;
            // 🔥 只断开，不自动重连
            QMetaObject::invokeMethod(self, "disconnectWebRTC", Qt::QueuedConnection);
            break;
        default:
            stateStr = "Unknown";
    }
    
    qDebug() << "🔗 WebRTC 连接状态:" << stateStr;
    self->m_webrtcStatus = stateStr;
    
    QMetaObject::invokeMethod(self, [self, stateStr]() {
        emit self->webrtcStatusChanged(stateStr);
    }, Qt::QueuedConnection);
}

// 静态回调：ICE 收集状态变化
void GstPlayer::onIceGatheringStateChanged(GstElement *webrtcbin, GParamSpec *pspec, gpointer userData)
{
    Q_UNUSED(pspec);
    Q_UNUSED(userData);
    
    GstWebRTCICEGatheringState state;
    g_object_get(webrtcbin, "ice-gathering-state", &state, nullptr);
    
    QString stateStr;
    switch (state) {
        case GST_WEBRTC_ICE_GATHERING_STATE_NEW:
            stateStr = "New";
            break;
        case GST_WEBRTC_ICE_GATHERING_STATE_GATHERING:
            stateStr = "Gathering";
            break;
        case GST_WEBRTC_ICE_GATHERING_STATE_COMPLETE:
            stateStr = "Complete";
            break;
        default:
            stateStr = "Unknown";
    }
    
    qDebug() << "🧊 ICE 收集状态:" << stateStr;
}

void GstPlayer::createWebRTCOffer()
{
    // P2P 模式：PC 是 Answerer，不主动创建 Offer
    if (m_useP2P) {
        qDebug() << "[P2P] P2P 模式：跳过自动 Offer 创建（等待 iOS Offer）";
        return;
    }
    
    // 🔥 会话级防重：同一次 connectWebRTC() 只允许发送一个 Offer
    // 防止 on-negotiation-needed 和 QTimer 双重触发导致发送两个 Offer 到 SRS
    if (m_offerSentForSession.exchange(true)) {
        qDebug() << "⚠️ 本次连接已发送过 Offer，跳过重复请求";
        srsLog(QString("[offer] ⚠️ 跳过：offerSentForSession 已是 true（本次连接发过 Offer）。"
                       "若此时画面没出来 = 上次 Offer 没成功但标志没回退 → 卡死根因"));
        return;
    }

    if (m_offerInProgress.exchange(true)) {
        qDebug() << "⚠️ Offer 正在创建中，跳过重复请求";
        srsLog(QString("[offer] ⚠️ 跳过：offerInProgress 已是 true（Offer 创建中）"));
        m_offerSentForSession.store(false);  // 回退会话标志
        return;
    }

    if (!m_webrtcbin) {
        qWarning() << "❌ webrtcbin 未初始化";
        srsLog(QString("[offer] ❌ webrtcbin 未初始化 → 画面出不来"));
        m_offerInProgress.store(false);
        m_offerSentForSession.store(false);  // 回退会话标志
        return;
    }
    
    qDebug() << "📝 创建 WebRTC Offer...";
    srsLog(QString("[offer] 开始创建 Offer（transceiverAdded=%1）").arg(m_transceiverAdded));
    
    // ⭐ 添加 recvonly transceiver（与 Java 版本一致）
    // 这是接收端 WebRTC 的关键：必须告诉 SRS 我们只接收视频
    if (!m_transceiverAdded) {
        // ⭐ 移除 profile-level-id 限制，让 WebRTC 自动协商
        // 支持所有 Profile (Baseline/Main/High) 和 Level (3.1~5.2+)
        // 解决 iPhone 16 等新设备可能使用不同编码参数的问题
        // ⭐ H265（第四十九章）：H265 会话 recvonly transceiver 用 H265 caps（与 H264 路径对称）。
        //   ⭐⭐⭐ 2026-07-24 空 Offer 根因：add-transceiver 的 caps 必须「完整到能生成 SDP」
        //   （GStreamer 官方 gstsdpmessage 的 caps→SDP 转换要求 payload 字段；官方示例均带 payload=96）。
        //   上一版故意不带 payload（误以为 PT 会动态分配）→ webrtcbin 构不出 m=video → Offer 为空
        //   （"v=0...a=group:BUNDLE" 无媒体行）→ SRS 400。补上 payload=106（动态 PT 区间，含义与
        //   H264 路径的 payload=109 相同，SRS 应答会沿用我们 Offer 里的 PT）。
        GstCaps *videoCaps = m_useH265
            ? gst_caps_from_string(
                "application/x-rtp,media=(string)video,payload=(int)106,"
                "encoding-name=(string)H265,clock-rate=(int)90000")
            : gst_caps_from_string(
                "application/x-rtp,media=video,payload=109,encoding-name=H264,"
                "clock-rate=90000,packetization-mode=(string)1,"
                "level-asymmetry-allowed=(string)1"
            );
        
        if (videoCaps) {
            GstWebRTCRTPTransceiver *transceiver = nullptr;
            g_signal_emit_by_name(m_webrtcbin, "add-transceiver", 
                                  GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_RECVONLY,
                                  videoCaps, &transceiver);
            gst_caps_unref(videoCaps);
            
            if (transceiver) {
                qDebug() << (m_useH265 ? "✅ 已添加 recvonly H265 视频 transceiver"
                                       : "✅ 已添加 recvonly H264 视频 transceiver");

                // ⭐⭐⭐ 对标 Chrome：在 transceiver 上启用 NACK 重传（核心！）
                //   - do-nack 默认 FALSE，不显式设永远不发 NACK → 丢包只能等关键帧 → 花屏。
                //   - 设 TRUE 后 SDP 会协商出 a=rtcp-fb:96 nack / nack pli，丢包先重传补回，补不回才请求关键帧。
                //   - 必须在 SDP 协商前设（此处 add-transceiver 返回值正是协商前，时机正确）。
                //   FEC（fec-type=UlpRed）作为第二步，需与 iOS 端协商一致，暂不开，先验证 NACK 效果。
                {
                    GObjectClass *tcls = G_OBJECT_GET_CLASS(transceiver);
                    if (g_object_class_find_property(tcls, "do-nack")) {
                        g_object_set(transceiver, "do-nack", TRUE, nullptr);
                        // 回读确认真的写进去了
                        gboolean nackOn = FALSE;
                        g_object_get(transceiver, "do-nack", &nackOn, nullptr);
                        qDebug() << "✅ transceiver: do-nack=TRUE（启用 NACK 重传，对标 Chrome）";
                        diagLog("✅ NACK 已启用：transceiver do-nack=TRUE（丢包重传，对标 Chrome）");
                        nackLog(QString("[配置] transceiver do-nack 设置成功，回读=%1 (1=已启用)").arg(nackOn ? 1 : 0));
                    } else {
                        qWarning() << "⚠️ transceiver 无 do-nack 属性（GStreamer 版本过旧？NACK 未启用）";
                        diagLog("⚠️ transceiver 无 do-nack 属性，NACK 未启用（建议升级 GStreamer ≥1.20）");
                        nackLog("⚠️ [配置] transceiver 无 do-nack 属性 → NACK 未启用！请升级 GStreamer ≥1.20");
                    }
                }

                gst_object_unref(transceiver);
                m_transceiverAdded = true;
            } else {
                qWarning() << "⚠️ 添加 transceiver 失败";
            }
        }
    }
    
    // 使用 GStreamer promise 创建 offer
    GstPromise *promise = gst_promise_new_with_change_func(
        [](GstPromise *promise, gpointer userData) {
            GstPlayer *self = static_cast<GstPlayer*>(userData);
            
            const GstStructure *reply = gst_promise_get_reply(promise);
            if (!reply) {
                qWarning() << "❌ 创建 offer 失败：无回复";
                self->m_offerInProgress.store(false);
                self->m_offerSentForSession.store(false);  // 🔥 允许重试
                return;
            }
            
            GstWebRTCSessionDescription *offer = nullptr;
            gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, nullptr);
            
            if (offer) {
                self->onOfferCreated(offer);
                gst_webrtc_session_description_free(offer);
            } else {
                qWarning() << "❌ 创建 offer 失败：无 SDP";
                self->m_offerInProgress.store(false);
                self->m_offerSentForSession.store(false);  // 🔥 允许重试
            }
        },
        this, nullptr);
    
    // 发出 create-offer 信号
    g_signal_emit_by_name(m_webrtcbin, "create-offer", nullptr, promise);
}

void GstPlayer::onOfferCreated(GstWebRTCSessionDescription *offer)
{
    qDebug() << "✅ Offer 创建成功";
    
    // 设置本地描述
    GstPromise *localPromise = gst_promise_new();
    g_signal_emit_by_name(m_webrtcbin, "set-local-description", offer, localPromise);
    gst_promise_interrupt(localPromise);
    gst_promise_unref(localPromise);
    
    // 获取 SDP 文本
    gchar *sdpText = gst_sdp_message_as_text(offer->sdp);
    QString sdpStr = QString::fromUtf8(sdpText);
    g_free(sdpText);

    // NACK 专项：检测本地 Offer SDP 是否协商出 nack / rtx（验证 NACK 是否真的进 SDP）
    {
        bool hasNack = sdpStr.contains("nack", Qt::CaseInsensitive);
        bool hasRtx  = sdpStr.contains("rtx", Qt::CaseInsensitive) || sdpStr.contains("apt=", Qt::CaseInsensitive);
        bool hasPli  = sdpStr.contains("nack pli", Qt::CaseInsensitive);
        nackLog(QString("[Offer SDP] 含 nack=%1, 含 rtx=%2, 含 nack-pli=%3  %4")
                .arg(hasNack ? "是✅" : "否❌")
                .arg(hasRtx ? "是✅" : "否❌")
                .arg(hasPli ? "是" : "否")
                .arg(hasNack ? "→ NACK 协商成功" : "→ NACK 未进 SDP，检查 do-nack 是否在协商前设置"));
        // 把含 rtcp-fb 的行摘出来，方便核对
        for (const QString &line : sdpStr.split('\n')) {
            if (line.contains("rtcp-fb", Qt::CaseInsensitive) || line.startsWith("a=rtpmap", Qt::CaseInsensitive)) {
                nackLog(QString("[Offer SDP行] %1").arg(line.trimmed()));
            }
        }
    }
    
    qDebug() << "📤 发送 Offer 到 SRS...";
    
    // ⭐ 在主线程中发送 HTTP 请求（GStreamer 回调在其他线程）
    QMetaObject::invokeMethod(this, [this, sdpStr]() {
        sendOfferToSRS(sdpStr);
        // 等待 HTTP 回包后再释放 m_offerInProgress
    }, Qt::QueuedConnection);
}

void GstPlayer::sendOfferToSRS(const QString &sdp)
{
    // 🔥 保存 SDP 用于重试
    m_pendingOfferSdp = sdp;
    
    // 构建 API URL
    // ⭐ H265（第四十九章）：SRS 6.0 的 RTC H265 协商由 API 请求参数 codec=hevc 开启
    //   （srs_app_rtc_api.cpp: r->query_get("codec")；不带则走 H264 分支，H265 Offer 会被拒）
    QString apiUrl = m_useH265
        ? QString("http://%1:1985/rtc/v1/play/?codec=hevc").arg(m_webrtcHost)
        : QString("http://%1:1985/rtc/v1/play/").arg(m_webrtcHost);
    
    // SRS streamurl 格式：webrtc://host/app/stream?vhost=xxx&eip=xxx
    // 与 Java 版本保持一致
    QString vhost = "vid-7gg4748";  // 默认 vhost
    QString streamUrl = QString("webrtc://%1/%2/%3?vhost=%4&eip=%1")
        .arg(m_webrtcHost, m_webrtcApp, m_webrtcStream, vhost);
    
    // 确保 SDP 使用 CRLF 行尾（SRS 要求）
    QString sdpCRLF = sdp;
    sdpCRLF.replace("\r\n", "\n");  // 先统一为 LF
    sdpCRLF.replace("\n", "\r\n");  // 再转为 CRLF
    
    int retryCount = m_srsRetryCount.load();
    qDebug() << "📤 API URL:" << apiUrl << "(已重试:" << retryCount << ")";
    qDebug() << "📤 Stream URL:" << streamUrl;
    
    // 调试：检查 SDP 是否包含视频 m-line
    bool hasVideo = sdpCRLF.contains("m=video");
    bool hasAudio = sdpCRLF.contains("m=audio");
    qDebug() << "📋 SDP 检查: hasVideo=" << hasVideo << "hasAudio=" << hasAudio;
    qDebug() << "📄 SDP 预览:" << sdpCRLF.left(300);
    
    // 构建 JSON 请求体
    QJsonObject json;
    json["api"] = apiUrl;
    json["streamurl"] = streamUrl;
    json["sdp"] = sdpCRLF;
    
    QJsonDocument doc(json);
    QByteArray jsonData = doc.toJson(QJsonDocument::Compact);
    
    // 发送 HTTP POST 请求
    QUrl url(apiUrl);
    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("Accept", "application/json");
    
    QNetworkReply *reply = m_networkManager->post(request, jsonData);
    
    srsLog(QString("[http] POST Offer 到 SRS（已重试 %1 次，§54 常驻重试无上限）").arg(retryCount));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            // ⭐ §54：HTTP 传输失败（网络抖动/服务器瞬断）不再一次失败即死，2s 后常驻重试。
            //   设备停推/离线时 QML 会 disconnectWebRTC → m_useWebRTC=false 自动终止循环。
            qWarning() << "❌ HTTP 请求失败:" << reply->errorString() << "→ 2s 后重试";
            srsLog(QString("[http] ❌ HTTP 请求失败: %1 → 2s 后重试（§54 常驻重试）")
                   .arg(reply->errorString()));
            m_webrtcStatus = "HTTP Error, retrying...";
            emit webrtcStatusChanged(m_webrtcStatus);
            m_offerInProgress.store(false);
            QTimer::singleShot(2000, this, [this]() {
                if (!m_pendingOfferSdp.isEmpty() && m_useWebRTC) {
                    qDebug() << "🔄 HTTP 失败后重试发送 Offer 到 SRS...";
                    sendOfferToSRS(m_pendingOfferSdp);
                }
            });
            reply->deleteLater();
            return;
        }
        
        QByteArray responseData = reply->readAll();
        qDebug() << "📥 收到 SRS 响应:" << responseData.left(500);
        
        // 解析响应
        QJsonDocument responseDoc = QJsonDocument::fromJson(responseData);
        if (responseDoc.isObject()) {
            QJsonObject responseObj = responseDoc.object();
            
            // 检查错误
            if (responseObj.contains("code") && responseObj["code"].toInt() != 0) {
                int errorCode = responseObj["code"].toInt();
                QString errorMsg = responseObj["msg"].toString();
                int retryCount = m_srsRetryCount.load();
                
                qWarning() << "❌ SRS 返回错误 code=" << errorCode << ":" << errorMsg << "(已重试:" << retryCount << ")";
                
                // ⭐ §54（2026-07-31）权威修复：400/404（流未就绪/被拒）改为**固定 2s 常驻重试，永不放弃**。
                //   原来 1~5s 递增×5 次（15s 窗口）耗尽 → m_srsError=true「必须切账号/重登才恢复」终态。
                //   iOS 重进/重协商的"流名注册到 SRS"时刻只要落在这 15s 之外，就永久黑屏。
                //   现在：设备心跳还说在推流，QML 就不会断开本会话，这里每 2s 一次 HTTP POST
                //   （几百字节）直到 SRS 放行；设备真停推/离线时 QML 会 disconnectWebRTC，
                //   m_useWebRTC=false 自动终止循环。§53.8 已把后端 on_play 改为"宁放行不误拒"，
                //   正常情况下 1~2 次重试内必然放行。
                if (errorCode == 400 || errorCode == 404) {
                    int n = m_srsRetryCount.fetch_add(1) + 1;
                    if (n <= 3 || n % 5 == 0) {
                        qDebug() << "🔄 SRS 流未就绪/拒播(code=" << errorCode << ")，2s 后第" << (n + 1) << "次重试...";
                        srsLog(QString("[retry] code=%1 第 %2 次，2s 后继续（§54 常驻重试，不再放弃）")
                               .arg(errorCode).arg(n));
                    }
                    m_webrtcStatus = QString("等待流就绪(%1)...").arg(n);
                    emit webrtcStatusChanged(m_webrtcStatus);
                    QTimer::singleShot(2000, this, [this]() {
                        if (!m_pendingOfferSdp.isEmpty() && m_useWebRTC) {
                            sendOfferToSRS(m_pendingOfferSdp);
                        }
                    });
                    m_offerInProgress.store(false);
                    reply->deleteLater();
                    return;
                }
                
                // 非 400/404 的硬错误（token 无效等）：保留终态提示；QML §54 看门狗仍会整会话重建再试
                m_webrtcStatus = "SRS Error";
                emit webrtcStatusChanged(m_webrtcStatus);
                m_srsError.store(true);
                qDebug() << "⚠️ SRS 硬错误 code=" << errorCode;

                // ⭐ §53.3②：把拒播翻译成人话。SRS 不会把 on_play 钩子的原因回传给客户端，
                //   403 最常见的成因是鉴权/后端拒绝，给现场一个可读原因。
                if (errorCode == 403) {
                    emit error(QString("服务器拒绝播放(code=%1)。常见原因：该设备的观看人数已满"
                                       "（含上一次未正常退出的残留观看者），或鉴权失败。"
                                       "可让设备重新推流一次，或联系后台清理观看者。").arg(errorCode));
                } else {
                    emit error(errorMsg.isEmpty() ? QString("SRS 错误 code=%1").arg(errorCode) : errorMsg);
                }
                m_offerInProgress.store(false);
                reply->deleteLater();
                return;
            }
            
            // 🔥 成功，重置重试计数
            m_srsRetryCount.store(0);
            m_pendingOfferSdp.clear();
            
            // 获取 Answer SDP
            QString answerSdp = responseObj["sdp"].toString();
            if (!answerSdp.isEmpty()) {
                onAnswerReceived(answerSdp);
            } else {
                qWarning() << "❌ 响应中没有 SDP";
            }
        }
        
        m_offerInProgress.store(false);
        reply->deleteLater();
    });
}

void GstPlayer::onAnswerReceived(const QString &sdp)
{
    qDebug() << "📥 收到 Answer SDP，设置远程描述...";
    
    // 解析 SDP
    GstSDPMessage *sdpMsg;
    gst_sdp_message_new(&sdpMsg);
    
    QByteArray sdpBytes = sdp.toUtf8();
    if (gst_sdp_message_parse_buffer((const guint8*)sdpBytes.constData(), sdpBytes.size(), sdpMsg) != GST_SDP_OK) {
        qWarning() << "❌ 解析 Answer SDP 失败";
        gst_sdp_message_free(sdpMsg);
        return;
    }
    
    // 创建 WebRTC Session Description
    GstWebRTCSessionDescription *answer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdpMsg);
    
    // 设置远程描述
    GstPromise *promise = gst_promise_new();
    g_signal_emit_by_name(m_webrtcbin, "set-remote-description", answer, promise);
    gst_promise_interrupt(promise);
    gst_promise_unref(promise);
    
    gst_webrtc_session_description_free(answer);
    
    qDebug() << "✅ 远程 SDP 描述设置完成";
    
    m_webrtcStatus = "Negotiating...";
    emit webrtcStatusChanged(m_webrtcStatus);
}

void GstPlayer::requestKeyFrame()
{
    sendPLIRequest();
}

void GstPlayer::sendPLIRequest()
{
    if (!m_webrtcbin) {
        qDebug() << "⚠️ webrtcbin 未初始化，无法发送 PLI";
        return;
    }
    
    // 🔥 v10.4: 统一 PLI 速率限制，避免疯狂请求导致卡死
    qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    if (m_lastKeyframeRequestMs > 0 && (nowMs - m_lastKeyframeRequestMs) < PLI_INTERVAL_WEAK_MS) {
        return;
    }
    m_lastKeyframeRequestMs = nowMs;
    m_pliRequestCount++;  // 🔥 2026-07-02 修复：此前从未递增，统计面板 PLI 恒 0（诊断误导）
    
    // 🔥🔥🔥 P0-1 修复：upstream force-key-unit 必须送到「最靠近 webrtcbin 的元素的 sinkpad」，
    //     事件沿 sinkpad → peer(webrtcbin 的 recv srcpad) 向【上游】传递，webrtcbin 收到后才会生成 RTCP PLI/FIR。
    //     旧实现从 srcpad 发，等于把 upstream 事件丢给【下游】(parse/decoder 方向)，永远到不了 webrtcbin
    //     → iOS 端收不到 PLI、丢包后迟迟不出 I 帧 → 长时间花屏/碎屏修不回来（本次根因）。
    
    bool sent = false;
    
    // 方法1（首选）：直接遍历 webrtcbin 的所有 src pad（动态 recv pad），逐个发 upstream force-key-unit。
    //     这是 webrtcbin 触发 PLI 最直接、最可靠的官方方式。
    {
        GstIterator *it = gst_element_iterate_src_pads(m_webrtcbin);
        GValue item = G_VALUE_INIT;
        bool done = false;
        while (!done) {
            switch (gst_iterator_next(it, &item)) {
            case GST_ITERATOR_OK: {
                GstPad *pad = GST_PAD(g_value_get_object(&item));
                if (pad) {
                    GstEvent *event = gst_video_event_new_upstream_force_key_unit(GST_CLOCK_TIME_NONE, TRUE, 0);
                    if (gst_pad_send_event(pad, event)) {
                        sent = true;
                        qDebug() << "🔑 PLI 请求已发送（webrtcbin srcpad:" << GST_PAD_NAME(pad) << "）";
                    }
                }
                g_value_reset(&item);
                break;
            }
            case GST_ITERATOR_RESYNC:
                gst_iterator_resync(it);
                break;
            case GST_ITERATOR_ERROR:
            case GST_ITERATOR_DONE:
            default:
                done = true;
                break;
            }
        }
        g_value_unset(&item);
        gst_iterator_free(it);
        if (sent) {
            return;
        }
    }
    
    // 方法2（兜底）：通过 rtph264depay 的 sinkpad 发送（其 peer 即 webrtcbin 的 recv srcpad），
    //     upstream 事件经 sinkpad → peer 向上游进入 webrtcbin。
    if (m_rtph264depay) {
        GstPad *sinkpad = gst_element_get_static_pad(m_rtph264depay, "sink");
        if (sinkpad) {
            GstEvent *event = gst_video_event_new_upstream_force_key_unit(GST_CLOCK_TIME_NONE, TRUE, 0);
            sent = gst_pad_send_event(sinkpad, event);
            gst_object_unref(sinkpad);
            if (sent) {
                qDebug() << "🔑 PLI 请求已发送（rtph264depay sinkpad → webrtcbin）";
                return;
            }
        }
    }
    
    // 方法3（兜底）：通过 h264parse 的 sinkpad 向上游传递。
    if (m_h264parse) {
        GstPad *sinkpad = gst_element_get_static_pad(m_h264parse, "sink");
        if (sinkpad) {
            GstEvent *event = gst_video_event_new_upstream_force_key_unit(GST_CLOCK_TIME_NONE, TRUE, 0);
            sent = gst_pad_send_event(sinkpad, event);
            gst_object_unref(sinkpad);
            if (sent) {
                qDebug() << "🔑 PLI 请求已发送（h264parse sinkpad → 上游）";
                return;
            }
        }
    }
    
    qDebug() << "⚠️ PLI 请求发送失败，所有方法都不可用";
}

void GstPlayer::startAutoKeyFrameRequest(int intervalMs)
{
    if (m_autoKeyFrameEnabled) {
        qDebug() << "⚠️ 周期性关键帧请求已在运行";
        return;
    }
    
    qDebug() << "🔄 启动周期性关键帧请求，间隔:" << intervalMs << "ms";
    
    if (!m_keyFrameTimer) {
        m_keyFrameTimer = new QTimer(this);
        connect(m_keyFrameTimer, &QTimer::timeout, this, &GstPlayer::sendPLIRequest);
    }
    
    m_keyFrameTimer->start(intervalMs);
    m_autoKeyFrameEnabled = true;
}

void GstPlayer::stopAutoKeyFrameRequest()
{
    if (!m_autoKeyFrameEnabled) {
        return;
    }
    
    qDebug() << "⏹️ 停止周期性关键帧请求";
    
    if (m_keyFrameTimer) {
        m_keyFrameTimer->stop();
    }
    m_autoKeyFrameEnabled = false;
}

void GstPlayer::flushDecoder()
{
    if (!m_pipeline) {
        qDebug() << "⚠️ Pipeline 未初始化，无法 flush";
        return;
    }
    
    qDebug() << "🔄 执行 flush 解码器...";
    
    // 向 pipeline 发送 flush 事件
    // 这会清空所有元素的缓冲区，包括解码器的参考帧
    GstEvent *flushStart = gst_event_new_flush_start();
    GstEvent *flushStop = gst_event_new_flush_stop(TRUE);  // TRUE = 重置运行时间
    
    // 发送 flush-start
    if (m_rtph264depay) {
        GstPad *sinkpad = gst_element_get_static_pad(m_rtph264depay, "sink");
        if (sinkpad) {
            gst_pad_send_event(sinkpad, flushStart);
            gst_object_unref(sinkpad);
        }
    }
    
    // 发送 flush-stop（重新开始处理）
    if (m_rtph264depay) {
        GstPad *sinkpad = gst_element_get_static_pad(m_rtph264depay, "sink");
        if (sinkpad) {
            gst_pad_send_event(sinkpad, flushStop);
            gst_object_unref(sinkpad);
        }
    }
    
    qDebug() << "✅ 解码器 flush 完成";
}

// ⭐⭐⭐ v8.1 简单版本：计算消费间隔
// 核心：基于到达帧率EMA计算渲染间隔，EMA本身已经平滑
double GstPlayer::calcSmoothInterval(int queueDepth)
{
    // 1. 更新队列深度EMA（用于日志和播放速度调整）
    m_depthEma = BETA_DEPTH * queueDepth + (1.0 - BETA_DEPTH) * m_depthEma;
    
    // 2. 目标平滑过渡（防止跳变）
    double targetDiff = m_queueTarget - m_queueTargetSmooth;
    if (std::abs(targetDiff) > 0.5) {
        m_queueTargetSmooth += (targetDiff > 0) ? 0.5 : -0.5;
    } else {
        m_queueTargetSmooth = m_queueTarget;
    }
    
    // 3. ⭐⭐⭐ v8.1核心：基于到达帧率EMA计算基础间隔
    // 到达帧率EMA本身已经有平滑效果，不需要额外处理
    double safeArrivalRate = qMax(10.0, m_arrivalRateEma);
    double safePlaybackRate = qMax(0.5, m_playbackRate);
    double baseInterval = 1000.0 / safeArrivalRate / safePlaybackRate;
    
    // 4. 队列积压时稍微加速消费（温和追赶）
    double waterLevel = (m_queueTargetSmooth > 0) ? (double)queueDepth / m_queueTargetSmooth : 1.0;
    double rawInterval = baseInterval;
    if (waterLevel > 1.2) {
        // 队列积压超过120%：轻微加速追赶（最多8%）
        rawInterval = baseInterval / R_MAX;  // 🔥 v11: 使用 R_MAX (1.08)
    }
    
    // 5. EMA平滑（α=0.3，约3帧平滑）
    m_intervalEma = GAMMA_INTERVAL * rawInterval + (1.0 - GAMMA_INTERVAL) * m_intervalEma;
    
    // 6. 检查 NaN/Inf
    if (std::isnan(m_intervalEma) || std::isinf(m_intervalEma)) {
        m_intervalEma = 1000.0 / safeArrivalRate;
    }
    
    // 7. 间隔变化速度限制（每次最多变化15%，防止跳帧）
    static double lastInterval = 33.0;
    double maxChange = lastInterval * 0.15;
    double finalInterval = m_intervalEma;
    if (finalInterval > lastInterval + maxChange) {
        finalInterval = lastInterval + maxChange;
    } else if (finalInterval < lastInterval - maxChange) {
        finalInterval = lastInterval - maxChange;
    }
    lastInterval = finalInterval;
    
    // 8. 绝对边界：8ms(120fps)~200ms(5fps)
    finalInterval = qBound(8.0, finalInterval, 200.0);
    
    return finalInterval;
}

// ⭐⭐⭐ 分段函数：水位 → 目标播放速率
// 数学模型：
//   W < 0.15:           R = 0.7 (紧急)
//   0.15 ≤ W < 0.35:    R = 0.7 + 0.3×(W-0.15)/0.2 (线性恢复)
//   0.35 ≤ W < 1.05:    R = 1.0 (正常)
//   1.05 ≤ W < 1.5:     R = 1.0 + 0.2×(W-1.05)/0.45 (线性追帧)
//   W ≥ 1.5:            R = 1.2 (最大追帧)
double GstPlayer::piecewiseRate(double W)
{
    if (W < W_EMERGENCY) {
        // 紧急：最低速度
        return R_MIN;
    } else if (W < W_EXPAND) {
        // 恢复中：线性从0.7升到1.0
        double t = (W - W_EMERGENCY) / (W_EXPAND - W_EMERGENCY);
        return R_MIN + (1.0 - R_MIN) * t;
    } else if (W < W_CATCHUP) {
        // 正常：标准速度
        return 1.0;
    } else if (W < W_CATCHUP_MAX) {
        // 追帧：线性从1.0升到1.2
        double t = (W - W_CATCHUP) / (W_CATCHUP_MAX - W_CATCHUP);
        return 1.0 + (R_MAX - 1.0) * t;
    } else {
        // 最大追帧
        return R_MAX;
    }
}

// ⭐⭐⭐ FPS变化检测（自动唤醒机制）
// 当检测到实际FPS与配置FPS差异超过30%持续3秒，自动重配置
void GstPlayer::detectFpsChange()
{
    if (m_lastSecondFps < 1.0) return;  // 数据不足
    
    double ratio = m_lastSecondFps / m_configFps;
    double deviation = std::abs(ratio - 1.0);
    
    if (deviation > FPS_CHANGE_THRESHOLD) {
        // FPS变化超过阈值
        m_fpsChangeCounter++;
        
        if (m_fpsChangeCounter >= FPS_CHANGE_STABLE_SEC) {
            // 持续3秒，触发自动重配置
            double newFps = m_lastSecondFps;
            qDebug().noquote() << QString("🔄 自动检测FPS变化 | %1fps→%2fps | 差异=%3% | 触发重配置")
                .arg((int)m_configFps).arg((int)newFps).arg((int)(deviation*100));
            
            setConfigFps(newFps);
            m_fpsChangeCounter = 0;
        } else {
            qDebug().noquote() << QString("⏳ FPS变化检测中 | 当前%1fps 配置%2fps | 差异=%3% | 计数=%4/%5秒")
                .arg((int)m_lastSecondFps).arg((int)m_configFps)
                .arg((int)(deviation*100))
                .arg(m_fpsChangeCounter).arg(FPS_CHANGE_STABLE_SEC);
        }
    } else {
        // FPS正常，重置计数器
        if (m_fpsChangeCounter > 0) {
            qDebug().noquote() << QString("✅ FPS恢复正常 | %1fps ≈ 配置%2fps | 计数器重置")
                .arg((int)m_lastSecondFps).arg((int)m_configFps);
        }
        m_fpsChangeCounter = 0;
    }
}

// ⭐⭐⭐ v13 PC端不再控制帧率升降，改由iOS自己控制
// 
// 原v11-v12逻辑已禁用：
//   - PC端不再根据损坏帧比例发送 set_fps 命令给iOS
//   - iOS端自己根据网络状况进行自适应帧率调整
//
// 保留的功能：
//   - 损坏帧统计（用于日志显示和队列调整）
//   - 队列控制（adjustQueueTarget）
//   - 播放速度控制（onRenderTick中的速率调整）
void GstPlayer::checkPushFpsControl(double W)
{
    Q_UNUSED(W);
    
    // 🔥 v13：PC端不再发送升降帧命令，由iOS自己控制
    // 只保留计数器重置，其他逻辑全部移除
        m_lowWaterHoldSec = 0;
        m_highWaterHoldSec = 0;
}

// ⭐⭐⭐ v8客户方案第一道保险：通过队列控制延迟
// 核心公式：
//   最佳缓冲 = fps × 15%（150ms）
//   队列下限 = fps × 8%（80ms）
//   队列上限 = fps × 40%（400ms）
void GstPlayer::adjustQueueTarget(int queueDepth)
{
    if (!m_bufferingStarted.load()) return;
    
    // ⭐⭐⭐ v9核心修改：使用实际到达帧率EMA而非配置帧率
    // 这样当配置fps=15但实际到达fps=30时，队列目标会基于30fps计算
    double fps = qMax(10.0, m_arrivalRateEma);  // 使用到达帧率EMA，最小10fps
    
    // 🔥🔥🔥 v11.3：动态队列（根据帧率+损坏率）
    int queueMin, queueOptimal, queueMax;
    getQueueSizeByFps(fps, queueMin, queueOptimal, queueMax, m_corruptRatioEma, m_useP2P);
    
    int oldTarget = m_queueTarget;
    
    // ⭐⭐⭐ FPS变化时自动调整队列目标到最佳值
    if (m_queueTarget != queueOptimal && std::abs(m_queueTarget - queueOptimal) > 1) {
        // 渐进调整到最佳值
        int step = (queueOptimal > m_queueTarget) ? 1 : -1;
        m_queueTarget += step;
        m_queueTarget = qBound(queueMin, m_queueTarget, queueMax);
        
        if (m_queueTarget != oldTarget) {
            int delayMs = static_cast<int>(m_queueTarget * 1000.0 / fps);
            qDebug().noquote() << QString("⚡ v9队列调整 | %1→%2帧 | 最佳=%3帧 | 延迟=%4ms | 到达fps=%5 配置fps=%6")
                .arg(oldTarget).arg(m_queueTarget).arg(queueOptimal).arg(delayMs).arg((int)fps).arg((int)m_configFps);
        }
    }
    
    // 计算当前延迟（用于第二道保险判断）
    int currentDelayMs = (fps > 0) ? static_cast<int>(queueDepth * 1000.0 / fps) : 150;
    
    // ⭐⭐⭐ v9.1紧急保护：只在队列=0时触发（避免过早停止消耗导致堆积）
    if (queueDepth == 0 && !m_emergencyHold) {
        m_emergencyHold = true;
        qDebug().noquote() << QString("🛑 v9.1紧急保护 | 队列=0帧 | 停止消耗等待帧到达")
            .arg(currentDelayMs);
    }
    
    // ⭐⭐⭐ 更新队列目标平滑值（用于水位计算）
    m_queueTargetSmooth = m_queueTarget;
}

// ⭐⭐⭐ v9.1核心方案：基于实际到达帧率EMA计算播放速度
// v9.1修复：
//   - 紧急恢复后快速回升（不再慢慢+5%）
//   - 队列堆积时立即追帧（不等堆积到2倍）
//   - 只在队列=0时才真正紧急降速
void GstPlayer::adjustPlaybackRate(int queueDepth)
{
    if (!m_bufferingStarted.load()) return;
    
    // ⭐⭐⭐ v9核心：使用实际到达帧率EMA（已在onNewSample中平滑更新）
    double fps = qMax(10.0, m_arrivalRateEma);  // 到达帧率EMA，最小10fps
    double oldRate = m_playbackRate;
    
    // ⭐⭐⭐ v9.1: 队列深度EMA平滑（系数改小，更快响应）
    if (m_queueDepthEma < 1.0) {
        m_queueDepthEma = queueDepth;  // 初始化
    } else {
        // 系数0.3：更快响应队列变化
        m_queueDepthEma = 0.3 * queueDepth + 0.7 * m_queueDepthEma;
    }
    double smoothQueueDepth = m_queueDepthEma;
    
    // 🔥🔥🔥 v11.3：动态队列（根据帧率+损坏率）
    int queueMin, queueOptimal, queueMax;
    getQueueSizeByFps(fps, queueMin, queueOptimal, queueMax, m_corruptRatioEma, m_useP2P);
    
    // 计算当前延迟
    int currentDelayMs = (fps > 0) ? static_cast<int>(smoothQueueDepth * 1000.0 / fps) : 150;
    
    // 🔥🔥🔥 v11 播放速度控制（更平滑，减少跳动）
    // 核心原则：
    //   1. 速度变化要平滑，避免大幅跳动
    //   2. 根据队列偏离程度线性调整目标速度
    //   3. 最小范围：85%-108%（比之前70%-110%更窄）
    
    // 计算队列偏离度（-1.0 = 空, 0 = 最佳, 1.0 = 满）
    double deviation = 0.0;
    if (queueDepth < queueOptimal) {
        // 队列偏少：deviation 为负数
        deviation = (double)(queueDepth - queueOptimal) / qMax(1, queueOptimal);
    } else if (queueDepth > queueOptimal) {
        // 队列偏多：deviation 为正数
        int range = qMax(1, queueMax - queueOptimal);
        deviation = (double)(queueDepth - queueOptimal) / range;
        if (deviation > 1.0) deviation = 1.0;
    }
    
    // 根据偏离度计算目标速度（更平滑的线性映射）
    // deviation = -1.0 → 目标 85%
    // deviation = 0    → 目标 100%
    // deviation = 1.0  → 目标 108%
    if (deviation < 0) {
        // 队列偏少：减速 (85% - 100%)
        m_targetRate = 1.0 + deviation * 0.15;  // -1.0 → 0.85
    } else {
        // 队列偏多或正常：加速 (100% - 108%)
        m_targetRate = 1.0 + deviation * 0.08;  // 1.0 → 1.08
    }
    
    // 特殊情况：队列完全空 → 紧急保护（但不要跳动太大）
    bool isEmergency = false;
    if (queueDepth == 0) {
        m_targetRate = 0.85;  // 🔥 v11: 85% 而不是 70%，减少跳动
        isEmergency = true;
    }
    
    // ========== 平滑速度调整（始终渐变，不直接跳）==========
    double newRate;
        double delta = m_targetRate - m_playbackRate;
    
    // 🔥 v11: 无论什么情况都平滑过渡，最大每次 ±3%
    double maxChange = 0.03;  // 每次最多变化 3%
    if (delta > maxChange) delta = maxChange;
    else if (delta < -maxChange) delta = -maxChange;
        newRate = m_playbackRate + delta;
    
    // 快速恢复：如果速度太低且队列已恢复，稍微加快恢复
    bool isFastRecover = false;
    if (m_playbackRate < 0.95 && queueDepth >= queueOptimal) {
        delta = m_targetRate - m_playbackRate;
        maxChange = 0.05;  // 恢复时可以快一点
        if (delta > maxChange) delta = maxChange;
        newRate = m_playbackRate + delta;
        isFastRecover = true;
    }
    
    // ========== 边界保护 ==========
    if (newRate < R_MIN) newRate = R_MIN;
    if (newRate > R_MAX) newRate = R_MAX;
    
    // ========== 日志输出（速度变化时）==========
    if (std::abs(newRate - oldRate) > 0.01) {
        QString statusIcon;
        QString statusText;
        
        if (queueDepth == 0) {
            statusIcon = "🛑"; statusText = "紧急";
        } else if (queueDepth <= 2) {
            statusIcon = "⚠️"; statusText = "危险";
        } else if (queueDepth < queueMin) {
            statusIcon = "⬆️"; statusText = "恢复中";
        } else if (queueDepth <= queueMax) {
            statusIcon = "✅"; statusText = "正常";
        } else {
            statusIcon = "🚀"; statusText = "追帧";
        }
        
        int totalDelayMs = currentDelayMs + GST_JITTER_LATENCY;
        QString modeTag = isEmergency ? " ⚡直调" : (isFastRecover ? " ⚡快恢" : "");
        
        qDebug().noquote() << QString("%1 v9.1速率[%2] | 队列=%3帧(最佳%4,范围%5-%6) | 到达=%7fps | 延迟=%8ms | 速度%9%→%10%%11")
            .arg(statusIcon).arg(statusText)
            .arg(queueDepth).arg(queueOptimal).arg(queueMin).arg(queueMax)
            .arg((int)fps)
            .arg(totalDelayMs)
            .arg((int)(oldRate*100)).arg((int)(newRate*100))
            .arg(modeTag);
    }
    
    m_playbackRate = newRate;
}

// ⭐⭐⭐ 自适应渲染定时器回调（双缓冲策略核心）
// v9.3 优化：帧率<15fps时跳过缓冲，直接渲染（避免卡顿）
void GstPlayer::onRenderTick()
{
    GstSample *sample = nullptr;
    int queueDepth = 0;
    qint64 now = QDateTime::currentMSecsSinceEpoch();

    // P2: 240fps 验证日志（每100ms打印一次收帧数）
    if (m_highSpeedMode) {
        m_hsWindowFrameCount++;
        if (m_hsWindowStartMs == 0) m_hsWindowStartMs = now;
        qint64 elapsed = now - m_hsWindowStartMs;
        if (elapsed >= 100) {
            qDebug() << QString("⚡ [240fps] 100ms窗口: 收=%1帧 (期望24帧) 间隔=%2ms")
                .arg(m_hsWindowFrameCount).arg(elapsed);
            m_hsWindowFrameCount = 0;
            m_hsWindowStartMs = now;
        }
    }
    
    if (m_useWebRTC && !m_webrtcConnected.load()) {
        return;
    }
    
    // ⭐⭐⭐ v9.3 低帧率直通模式：帧率<15fps时跳过缓冲，直接渲染
    // 原因：极弱网下缓冲机制会增加延迟和卡顿，不如直接渲染收到的帧
    bool lowFpsMode = (m_arrivalRateEma < 15.0 && m_bufferingStarted.load());
    if (lowFpsMode) {
        // 🔥🔥🔥 v13 修复：弱网模式也需要队列控制！
        // 不再强制重置为100%，让队列积压时能通过加速消耗
        // 之前的问题：重置为100%后队列无法消耗
        
        // 获取队列深度
        QMutexLocker lock(&m_queueMutex);
        int weakQueueDepth = m_frameQueue.size();
        if (!m_frameQueue.isEmpty()) {
            sample = m_frameQueue.takeFirst();
            // 🔥 v11.3: 移除跳帧逻辑！队列积压用速度控制
            // 之前这里清空队列导致跳帧
        }
        lock.unlock();
        
        if (sample) {
            // 🔥🔥🔥 v12 简化：坏帧已在 probe 中被 DROP，这里的帧都是干净的！
            // 浏览器模式：解码前就过滤掉坏帧，解码器永远看不到损坏数据
            
            GstBuffer *buffer = gst_sample_get_buffer(sample);
            GstCaps *caps = gst_sample_get_caps(sample);
            
            // 保存为有效帧
            if (m_lastValidSample) {
                gst_sample_unref(m_lastValidSample);
            }
            m_lastValidSample = gst_sample_ref(sample);
            
            if (buffer && caps) {
                GstStructure *structure = gst_caps_get_structure(caps, 0);
                int width = 0, height = 0;
                gst_structure_get_int(structure, "width", &width);
                gst_structure_get_int(structure, "height", &height);
                
                GstMapInfo map;
                if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
                    if (m_videoSink && width > 0 && height > 0) {
                        QVideoFrameFormat format(QSize(width, height), QVideoFrameFormat::Format_BGRA8888);
                        QVideoFrame frame(format);
                        
                        if (frame.map(QVideoFrame::WriteOnly)) {
                            int srcStride = width * 4;
                            int dstStride = frame.bytesPerLine(0);
                            
                            if (srcStride == dstStride) {
                                memcpy(frame.bits(0), map.data, map.size);
                            } else {
                                for (int y = 0; y < height; y++) {
                                    memcpy(frame.bits(0) + y * dstStride, 
                                           map.data + y * srcStride, srcStride);
                                }
                            }
                            frame.unmap();
                            m_videoSink->setVideoFrame(frame);
                            
                            // 🔥🔥🔥 v11 修复：弱网模式也更新渲染计数器！
                            m_renderFrameCounter++;
                        }
                    }
                    gst_buffer_unmap(buffer, &map);
                }
            }
            if (sample) {
                gst_sample_unref(sample);
            }
        }
        // 🔥🔥🔥 v10.5 修复：如果队列空且有上一帧，显示冻结画面
        else if (m_lastValidSample) {
            GstBuffer *lastBuffer = gst_sample_get_buffer(m_lastValidSample);
            GstCaps *lastCaps = gst_sample_get_caps(m_lastValidSample);
            if (lastBuffer && lastCaps) {
                GstStructure *structure = gst_caps_get_structure(lastCaps, 0);
                int width = 0, height = 0;
                gst_structure_get_int(structure, "width", &width);
                gst_structure_get_int(structure, "height", &height);
                
                GstMapInfo map;
                if (gst_buffer_map(lastBuffer, &map, GST_MAP_READ)) {
                    if (m_videoSink && width > 0 && height > 0) {
                        QVideoFrameFormat format(QSize(width, height), QVideoFrameFormat::Format_BGRA8888);
                        QVideoFrame frame(format);
                        
                        if (frame.map(QVideoFrame::WriteOnly)) {
                            int srcStride = width * 4;
                            int dstStride = frame.bytesPerLine(0);
                            
                            if (srcStride == dstStride) {
                                memcpy(frame.bits(0), map.data, map.size);
                            } else {
                                for (int y = 0; y < height; y++) {
                                    memcpy(frame.bits(0) + y * dstStride, 
                                           map.data + y * srcStride, srcStride);
                                }
                            }
                            frame.unmap();
                            m_videoSink->setVideoFrame(frame);
                        }
                    }
                    gst_buffer_unmap(lastBuffer, &map);
                }
            }
            // 静默冻结，不频繁打印日志
        }
        
        // 低帧率模式下仍然需要定时检测
        if (now - m_lastQualityCheckMs >= 1000) {
            m_lastSecondFps = m_currentSecondFrames;
            m_currentSecondFrames = 0;
            m_lastQualityCheckMs = now;
            
            // 更新 EMA
            if (m_lastSecondFps > 0) {
                m_arrivalRateEma = 0.3 * m_lastSecondFps + 0.7 * m_arrivalRateEma;
            } else {
                m_arrivalRateEma = qMax(5.0, m_arrivalRateEma * 0.5);
            }

            // ⭐ §65（2026-08-15）「杀手机进程后画面留最后一帧」修复：
            //   m_receiveFps 原本只在收帧回调里更新，断流后冻结在最后的非零值；
            //   而 QML §53.10 的「心跳超时清屏」要求 currentPlayingFps()===0 才敢清
            //   （防止 P2P 下 STOMP 抖动误清正常画面）→ fps 永远非零 = 永远不清屏。
            //   设备被杀进程时 EMA 衰减必进本低帧率分支且提前 return（连 15s 无帧看门狗
            //   都跳过），所以这里必须把"上一秒 0 帧"如实反映到 receiveFps。
            if (m_lastSecondFps == 0 && m_receiveFps.load() != 0) {
                m_receiveFps = 0;
                emit receiveFpsChanged();
            }
            
            qDebug().noquote() << QString("🔴 v9.3低帧率直通 | 收=%1fps EMA=%2fps | 跳过缓冲直接渲染")
                .arg((int)m_lastSecondFps).arg((int)m_arrivalRateEma);
            
            // ⭐⭐⭐ v9.3 防马赛克：低帧率时每秒请求一次关键帧
            // 确保即使网络差，也能定期获得完整的 I 帧
            if (m_webrtcConnected) {
                QMetaObject::invokeMethod(this, "requestKeyFrame", Qt::QueuedConnection);
                qDebug() << "🔑 低帧率模式：请求关键帧(防马赛克)";
            }
            
            // 检查是否恢复到正常模式
            if (m_arrivalRateEma >= 15.0) {
                qDebug().noquote() << QString("🟢 帧率恢复 %1fps >= 15fps | 恢复缓冲模式")
                    .arg((int)m_arrivalRateEma);
            }
        }
        
        return;  // 低帧率模式直接返回，跳过后续缓冲逻辑
    }
    
    // ========== 每秒执行：FPS检测 + 双缓冲策略调整 ==========
    if (now - m_lastQualityCheckMs >= 1000) {
        // 计算上一秒的实际到达帧数
        m_lastSecondFps = m_currentSecondFrames;
        m_currentSecondFrames = 0;  // 重置计数
        m_lastQualityCheckMs = now;

        // ⭐ §65：无帧一秒即把 receiveFps 归零（与低帧率直通分支同款，理由见那边注释）——
        //   QML 才能看见"真没画面"，§53.10 心跳超时清屏/§54 对账才有正确事实源。
        if (m_lastSecondFps == 0 && m_receiveFps.load() != 0) {
            m_receiveFps = 0;
            emit receiveFpsChanged();
        }
        
        // 🔥🔥🔥 v12.1 计算损坏帧比例（网络质量核心指标）
        m_lastSecondCorruptFrames = m_corruptFrameCount.exchange(0);
        m_lastSecondTotalFrames = m_totalFrameCount.exchange(0);
        static int s_consecutiveCleanSeconds = 0;  // 连续无损坏帧秒数
        
        if (m_lastSecondTotalFrames > 0) {
            double currentCorruptRatio = (double)m_lastSecondCorruptFrames / m_lastSecondTotalFrames;
            
            // 🔥 v12.1 修复：当没有损坏帧时，更快地衰减 EMA
            // 问题：之前 EMA 衰减太慢，导致网络恢复后仍长时间处于弱网模式
            // 解决：当前损坏率=0 时，使用更激进的衰减系数
            if (currentCorruptRatio < 0.01) {
                // 当前几乎没有损坏帧，快速衰减（每秒衰减 50%）
                m_corruptRatioEma = 0.5 * m_corruptRatioEma;
                s_consecutiveCleanSeconds++;
                
                // 如果连续 3 秒无损坏帧，直接清零
                if (s_consecutiveCleanSeconds >= 3) {
                    m_corruptRatioEma = 0.0;
                    s_consecutiveCleanSeconds = 0;
                }
            } else {
                // 有损坏帧，正常 EMA 更新
                m_corruptRatioEma = 0.3 * currentCorruptRatio + 0.7 * m_corruptRatioEma;
                s_consecutiveCleanSeconds = 0;  // 重置连续清洁计数
            }
        } else {
            // 没有帧到达，保持上一秒的值
        }
        
        // ⭐⭐⭐ 关键修复：强制同步 EMA 与实际到达帧率
        // 解决网络断开时 m_arrivalRateEma 不更新导致队列目标错误的问题
        if (m_bufferingStarted.load()) {
            if (m_lastSecondFps == 0) {
                // 网络完全断开：快速衰减 EMA 到最小值
                if (m_arrivalRateEma > 10.0) {
                    double oldEma = m_arrivalRateEma;
                    m_arrivalRateEma = qMax(10.0, m_arrivalRateEma * 0.3);  // 每秒衰减70%，最低10fps
                    qDebug().noquote() << QString("📉 网络断开检测 | EMA衰减 %1→%2fps | 到达=0帧")
                        .arg((int)oldEma).arg((int)m_arrivalRateEma);
                }
                
                // 🔥 2026-07-02 无帧分级兜底（原 5 秒直接 destroy 整条管线，代价极大且不给自愈机会）：
                //    最常见的无帧原因是丢参考帧后解码器在等 IDR（数据仍在收），PLI 即可自愈——
                //    2s 起每 2s 请求一次关键帧；连续 15s 仍无帧（真断网/对端消失）才断开。
                int noFpsCount = m_noFpsSeconds.fetch_add(1) + 1;
                qDebug().noquote() << QString("⚠️ 连续无帧 %1/15 秒").arg(noFpsCount);
                if (noFpsCount >= 2 && noFpsCount < 15 && (noFpsCount % 2) == 0 && m_webrtcConnected.load()) {
                    qDebug().noquote() << QString("🔑 无帧 %1s → 请求关键帧自愈").arg(noFpsCount);
                    QMetaObject::invokeMethod(this, "requestKeyFrame", Qt::QueuedConnection);
                }
                if (noFpsCount >= 15 && m_webrtcConnected.load()) {
                    qWarning() << "❌ 连续15秒无帧（关键帧自愈无效），自动断开连接";
                    m_srsError.store(true);  // 防止自动重连
                    QMetaObject::invokeMethod(this, "disconnectWebRTC", Qt::QueuedConnection);
                    // 通知QML层
                    QMetaObject::invokeMethod(this, [this]() {
                        emit webrtcStatusChanged("No Frames");
                        emit error("连续15秒无帧，已自动断开");
                    }, Qt::QueuedConnection);
                }
            } else if (m_lastSecondFps > 0 && m_arrivalRateEma > 0) {
                // 有帧到达：重置无帧计数器
                m_noFpsSeconds.store(0);
                // 有帧到达：检查 EMA 与实际到达帧率的偏差
                double ratio = m_lastSecondFps / m_arrivalRateEma;
                if (ratio < 0.3 || ratio > 3.0) {
                    // 偏差超过3倍：立即重置 EMA
                    double oldEma = m_arrivalRateEma;
                    m_arrivalRateEma = m_lastSecondFps;
                    qDebug().noquote() << QString("⚡ EMA强制重置 | %1→%2fps | 偏差=%3x")
                        .arg((int)oldEma).arg((int)m_arrivalRateEma).arg(ratio, 0, 'f', 1);
                }
            }
        }
        
        // 获取当前队列深度用于决策
        {
            QMutexLocker lock(&m_queueMutex);
            queueDepth = m_frameQueue.size();
        }

        // ⭐ SRT 专项每秒诊断（无论是否缓冲完成都打，便于看"为什么队列一直空"）：
        //   端到端延迟 ≈ srtsrc latency(300ms) + netQueue(120ms) + 应用层队列延迟。
        //   UNDERRUN 频繁 + 队列长期空 = 数据供给不连续（SRT 突发到达或上行不足）。
        if (m_useSRT) {
            // SRT 路径的实际协议层缓冲，与 gstsrtsource.cpp 保持一致（不用 GST_JITTER_LATENCY，
            //   那是 SRS WebRTC 的默认估值，对 SRT 不准、会高估端到端延迟）。
            static constexpr int SRT_LATENCY_MS = 300;   // srtsrc latency
            static constexpr int SRT_NETQUEUE_MS = 120;  // netQueue 缓冲
            double arrivalFpsSrt = qMax(1.0, m_arrivalRateEma);
            int appDelaySrt = static_cast<int>(queueDepth * 1000.0 / arrivalFpsSrt);
            int e2eDelaySrt = SRT_LATENCY_MS + SRT_NETQUEUE_MS + appDelaySrt;
            int depayUn = g_srtDepayUnderrun.exchange(0);
            int decUn = g_srtDecodeUnderrun.exchange(0);
            int depayOv = g_srtDepayOverrun.exchange(0);
            srtLog(QString("[stats] 缓冲%1 | 收=%2fps 到达=%3fps | 队列=%4帧 目标=%5 | 速度=%6%% | 应用延迟=%7ms 估端到端≈%8ms | UNDERRUN(depay=%9,decode=%10) OVERRUN(depay=%11)")
                .arg(m_bufferingStarted.load() ? "完成" : "等待")
                .arg((int)m_lastSecondFps)
                .arg((int)arrivalFpsSrt)
                .arg(queueDepth)
                .arg(m_queueTarget)
                .arg((int)(m_playbackRate*100))
                .arg(appDelaySrt)
                .arg(e2eDelaySrt)
                .arg(depayUn).arg(decUn).arg(depayOv));
        }
        
        // ⭐⭐⭐ FPS变化检测（自动唤醒机制）
        // 当实际FPS与配置FPS差异>30%持续3秒，自动重配置
        if (m_bufferingStarted.load() && m_lastSecondFps > 0) {
            detectFpsChange();
        }
        
        // 第一道防线：动态调整队列目标
        adjustQueueTarget(queueDepth);
        
        // 第二道防线：播放速率调整（分段函数 + 导数限制）
        adjustPlaybackRate(queueDepth);
        
        // 第三道防线：推流帧率控制（边缘化触发）
        {
            double W = (m_queueTarget > 0) ? (double)queueDepth / m_queueTarget : 1.0;
            checkPushFpsControl(W);
        }
        
        // ⭐⭐⭐ v9.1状态日志（每秒输出一次）
        if (m_bufferingStarted.load()) {
            // 基于实际到达帧率EMA计算所有指标
            double arrivalFps = qMax(10.0, m_arrivalRateEma);
            
            // 🔥 v11.3：动态队列（根据帧率+损坏率）
            int queueMin, optimalQueue, queueMax;
            getQueueSizeByFps(arrivalFps, queueMin, optimalQueue, queueMax, m_corruptRatioEma, m_useP2P);
            
            int appDelayMs = static_cast<int>(queueDepth * 1000.0 / arrivalFps);
            int totalDelayMs = appDelayMs + GST_JITTER_LATENCY;
            
            // 状态判断（根据动态队列范围）
            QString status;
            if (m_emergencyHold || queueDepth == 0) status = "🛑紧急";
            else if (queueDepth < queueMin) status = "⚠️偏少";
            else if (queueDepth > queueMax) status = "🚀追帧";
            else status = "✅正常";
            
            // 降帧状态
            QString fpsStatus = m_requestedFps > 0 ? QString(" | 📉已降帧→%1fps").arg(m_requestedFps) : "";
            
            // 队列健康诊断（根据动态队列范围）
            QString healthInfo;
            if (queueDepth == 0) healthInfo = " ⚠️队列空";
            else if (queueDepth < queueMin) healthInfo = " ⚠️队列偏少";
            else if (queueDepth > queueMax) healthInfo = " ⚠️队列积压";
            
            qDebug().noquote() << QString("📊 v9.1[%1] | 收=%2fps 到达=%3fps | 队列=%4帧(最佳%5,范围%6-%7) | 速度=%8% | 延迟=%9ms%10%11")
                .arg(status)
                .arg((int)m_lastSecondFps)       // 实际接收fps
                .arg((int)arrivalFps)            // 到达帧率EMA
                .arg(queueDepth)                 // 当前队列
                .arg(optimalQueue)               // 最佳队列
                .arg(queueMin)                   // 最小队列
                .arg(queueMax)                   // 最大队列
                .arg((int)(m_playbackRate*100))  // 播放速度
                .arg(totalDelayMs)               // 总延迟
                .arg(fpsStatus)                  // 降帧状态
                .arg(healthInfo);                // 队列健康诊断
            
            // ⭐ 更新缓冲队列状态（供 QML 显示）
            if (m_bufferSize.load() != queueDepth) {
                m_bufferSize.store(queueDepth);
                emit bufferSizeChanged();
            }
            if (m_bufferTarget.load() != m_queueTarget) {
                m_bufferTarget.store(m_queueTarget);
                emit bufferTargetChanged();
            }
        }
    }
    
    // ========== 取帧逻辑 ==========
    bool lowWaterHold = false;
    int burstDropCount = 0;      // §23.11 P0-4：突发积压快排空统计（锁外记日志用）
    int burstDropOptimal = 0;
    {
        QMutexLocker lock(&m_queueMutex);
        queueDepth = m_frameQueue.size();
        
        // 🔥🔥🔥 v9.3 双缓冲策略：等待积累到目标深度再开始播放
        // 核心：用 ~200ms 额外延迟换取流畅体验
        if (!m_bufferingStarted.load()) {
            if (queueDepth >= m_queueTarget) {  // 🔥 v9.3: 等待缓冲完成
                m_bufferingStarted.store(true);
                double fps = m_configFps > 1.0 ? m_configFps : 30.0;
                int delayMs = static_cast<int>(m_queueTarget * 1000.0 / fps) + GST_JITTER_LATENCY;
                qDebug().noquote() << QString("🎬 v9.3缓冲完成 | 队列=%1帧 目标=%2帧 | 延迟≈%3ms @%4fps")
                    .arg(queueDepth).arg(m_queueTarget).arg(delayMs).arg((int)fps);
                
                // 初始化FPS统计
                m_currentSecondFrames = 0;
                m_fpsChangeCounter = 0;
            } else {
                return;  // 继续等待缓冲
            }
        }

        // ⭐⭐⭐ SRT 专用：仅在「首次缓冲完成」裁一次 gop_cache 历史积压（仅 SRT 模式，
        // 完全不影响 P2P/SRS/WebRTC）。
        // 原因：SRS 对 SRT 拉流连接瞬间会灌入 gop_cache 的大量历史帧（秒开用），造成首帧高延迟。
        // 说明：此处 m_frameQueue 存的是「解码后 BGRA 帧」（appsink 之后），帧间无 H.264 依赖，
        //   丢弃任意帧只会跳帧、不会花屏。故安全。
        // 关键教训（上一版 bug）：若「每 tick 持续裁」会与 SRT 突发到达节奏对抗 → 队列剧烈震荡、
        //   每秒裁 4~5 次、UNDERRUN 暴涨。正确做法：只在首帧那一刻裁一次清掉历史积压，
        //   之后完全交给现有「追帧速度」机制温和消化，不再丢帧。
        if (m_useSRT && m_bufferingStarted.load() && !m_srtInitialCropDone) {
            m_srtInitialCropDone = true;
            if (queueDepth > m_queueTarget) {
                int dropCount = 0;
                while (m_frameQueue.size() > m_queueTarget) {
                    GstSample *oldest = m_frameQueue.takeFirst();
                    gst_sample_unref(oldest);
                    dropCount++;
                }
                queueDepth = m_frameQueue.size();
                qWarning().noquote() << QString("⚡ [SRT] 首帧裁掉 gop_cache 历史积压 %1 帧 | 队列 %2→%3（目标%4）")
                    .arg(dropCount).arg(dropCount + queueDepth).arg(queueDepth).arg(m_queueTarget);
                srtLog(QString("[裁帧] 首次裁掉历史积压 %1 帧 | 队列 %2→%3（目标%4）")
                    .arg(dropCount).arg(dropCount + queueDepth).arg(queueDepth).arg(m_queueTarget));
            }
        }
        
        // ⭐ §23.11 P0-4：突发积压快排空。主线程冻结 ~1s 解除后队列瞬时 30+ 帧，
        //   1.07x 追帧上限要 ~10s 才排空（全程慢动作+高延迟）。此处队列存的是
        //   解码后 BGRA 帧、帧间无 H.264 依赖（同 SRT 首帧裁帧的论证），一次性丢
        //   最旧帧回到最佳水位只会画面前跳、不花屏。阈值=动态 queueMax×2（30fps
        //   时约 28 帧），正常网络波动到不了，只有冻结/突发才触发；不与 onNewSample
        //   的 60 帧极端保护、SRT 首帧裁帧冲突（先于两者的语义：温和一档的兜底）。
        if (m_bufferingStarted.load() && !m_useSRT) {
            int bMin = 0, bOpt = 0, bMax = 0;
            getQueueSizeByFps(qMax(10.0, m_arrivalRateEma), bMin, bOpt, bMax, m_corruptRatioEma, m_useP2P);
            if (queueDepth > bMax * 2 && bOpt > 0) {
                while (m_frameQueue.size() > bOpt) {
                    GstSample *oldest = m_frameQueue.takeFirst();
                    gst_sample_unref(oldest);
                    burstDropCount++;
                }
                queueDepth = m_frameQueue.size();
                burstDropOptimal = bOpt;
            }
        }
        
        // ⭐⭐⭐ v9.1紧急保护解除：只要队列>0就立即恢复（不等水位）
        if (m_emergencyHold && queueDepth > 0) {
            m_emergencyHold = false;
            m_emergencyFpsLowered = false;
            
            qint64 recoveryTime = QDateTime::currentMSecsSinceEpoch() - m_emptyQueueStartMs;
            qDebug().noquote() << QString("✅ v9.1紧急保护解除 | 队列=%1帧 | 立即恢复消耗")
                .arg(queueDepth);
        }
        
        // ⭐⭐⭐ v9.3取帧决策（简化版，对齐copygstream）
        // 简化逻辑：只在队列=0时停止消耗，其他情况正常取帧
        // 播放速度调整已经会根据队列深度自动调节消耗速度
        // 🔥 v9.3: 去掉等待IDR逻辑，所有帧正常消耗
        
        if (m_emergencyHold) {
            // 紧急保护中：停止消耗
            lowWaterHold = true;
        } else if (queueDepth >= 1) {
            // 正常：取帧消耗
            sample = m_frameQueue.takeFirst();
            
            // 保存最后有效帧（用于紧急时重复显示）
            if (m_lastValidSample) {
                gst_sample_unref(m_lastValidSample);
            }
            m_lastValidSample = gst_sample_ref(sample);
        } else if (queueDepth == 0) {
            // ⭐⭐⭐ v11.4 修复：队列频繁空也算作"问题"（网络不稳定的信号）
            if (!m_emergencyHold) {
                m_emergencyHold = true;
                m_emptyQueueCount++;
                
                // 🔥🔥🔥 v11.4: 每 5 次队列空计入 1 次损坏帧（避免过度计数）
                // 原因：偶尔队列空是正常的，频繁才是问题
                if (m_emptyQueueCount % 5 == 0) {
                    m_corruptFrameCount.fetch_add(1);
                    m_totalFrameCount.fetch_add(1);
                    qDebug().noquote() << QString("🔴 v11.4队列频繁空 | 次数=%1 | 损坏率=%2% | 计入问题帧")
                        .arg(m_emptyQueueCount).arg((int)(m_corruptRatioEma * 100));
                } else {
                    qDebug().noquote() << QString("⚠️ v11.4队列=0 | 次数=%1 | 损坏率=%2%")
                        .arg(m_emptyQueueCount).arg((int)(m_corruptRatioEma * 100));
                    }
                
                // 请求关键帧（有助于快速恢复）
                    QMetaObject::invokeMethod(this, "requestKeyFrame", Qt::QueuedConnection);
            }
            lowWaterHold = true;  // 标记使用最后有效帧
        }
    }
    
    // §23.11 P0-4：突发裁帧日志（放锁外，p2pLog 的文件 flush 不能在持锁时做）
    if (burstDropCount > 0) {
        qWarning().noquote() << QString("⚡ [burst-drop] 突发积压快排空：丢 %1 帧 | 队列 %2→%3（回到最佳水位%4）")
            .arg(burstDropCount).arg(queueDepth + burstDropCount).arg(queueDepth).arg(burstDropOptimal);
        if (m_useP2P) {
            p2pLog(QString("[burst-drop] 冻结/突发后快排空 丢=%1 队列→%2（最佳%3）")
                .arg(burstDropCount).arg(queueDepth).arg(burstDropOptimal));
        }
    }
    
    // 根据队列深度计算极致平滑间隔
    double smoothInterval = calcSmoothInterval(queueDepth);
    int nextInterval = qRound(smoothInterval);
    if (m_renderTimer->interval() != nextInterval) {
        m_renderTimer->setInterval(nextInterval);
    }
    
    if (sample) {
        // 🔥🔥🔥 v12 简化：坏帧已在 probe 中被 DROP，这里的帧都是干净的！
        GstBuffer *buffer = gst_sample_get_buffer(sample);
        GstCaps *caps = gst_sample_get_caps(sample);
        
        if (buffer && caps) {
            // 🔥🔥🔥 v10超低延迟：PTS 漂移检测 + 定时渲染（保证平滑）
            // 核心：不阻塞线程，而是通过调整渲染间隔来平滑播放
            GstClockTime pts = GST_BUFFER_PTS(buffer);
            qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
            
            if (GST_CLOCK_TIME_IS_VALID(pts)) {
                qint64 ptsMs = pts / GST_MSECOND;  // 纳秒转毫秒
                
                // 首帧：记录 PTS 基准
                if (m_startPts < 0) {
                    m_startPts = ptsMs;
                    m_startSystemTime = nowMs;
                    qDebug().noquote() << QString("🎬 v10 PTS基准设置 | startPts=%1ms | systemTime=%2")
                        .arg(m_startPts).arg(m_startSystemTime);
                }
                
                // 计算漂移量（正值=播放慢了，负值=播放快了）
                qint64 expectedPts = (nowMs - m_startSystemTime) + m_startPts - PTS_OFFSET_MS;
                qint64 drift = ptsMs - expectedPts;
                
                // 🔥 v10平滑策略：不阻塞，而是记录漂移用于间隔调整
                // 大漂移（>200ms）说明网络恢复或严重延迟，重置基准
                if (qAbs(drift) > 200) {
                    m_startPts = ptsMs;
                    m_startSystemTime = nowMs;
                    qDebug().noquote() << QString("⚡ v10 PTS重校准 | drift=%1ms | 重置基准").arg(drift);
                }
                // 其他情况：正常渲染，漂移会被 calcSmoothInterval 的速度调整机制吸收
            }
            
            GstStructure *structure = gst_caps_get_structure(caps, 0);
            int width = 0, height = 0;
            gst_structure_get_int(structure, "width", &width);
            gst_structure_get_int(structure, "height", &height);
            
            GstMapInfo map;
            if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
                // 创建 QVideoFrame 并显示
                if (m_videoSink && width > 0 && height > 0) {
                    QVideoFrameFormat format(QSize(width, height), QVideoFrameFormat::Format_BGRA8888);
                    QVideoFrame frame(format);
                    
                    if (frame.map(QVideoFrame::WriteOnly)) {
                        // 复制 BGRA 数据
                        int srcStride = width * 4;
                        int dstStride = frame.bytesPerLine(0);
                        
                        if (srcStride == dstStride) {
                            memcpy(frame.bits(0), map.data, map.size);
                        } else {
                            // 逐行复制
                            for (int y = 0; y < height; y++) {
                                memcpy(frame.bits(0) + y * dstStride, 
                                       map.data + y * srcStride, 
                                       srcStride);
                            }
                        }
                        
                        frame.unmap();
                        m_videoSink->setVideoFrame(frame);
                        
                        // 渲染帧计数（用于日志）
                        m_renderFrameCounter.fetch_add(1);
                    }
                }
                gst_buffer_unmap(buffer, &map);
            }
        }
        
        gst_sample_unref(sample);
    } else if (lowWaterHold && m_lastValidSample) {
        // ⭐ 紧急保护：使用最后有效帧重复渲染（防止马赛克）
        GstBuffer *buffer = gst_sample_get_buffer(m_lastValidSample);
        GstCaps *caps = gst_sample_get_caps(m_lastValidSample);
        
        if (buffer && caps) {
            GstStructure *structure = gst_caps_get_structure(caps, 0);
            int width = 0, height = 0;
            gst_structure_get_int(structure, "width", &width);
            gst_structure_get_int(structure, "height", &height);
            
            GstMapInfo map;
            if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
                if (m_videoSink && width > 0 && height > 0) {
                    QVideoFrameFormat format(QSize(width, height), QVideoFrameFormat::Format_BGRA8888);
                    QVideoFrame frame(format);
                    
                    if (frame.map(QVideoFrame::WriteOnly)) {
                        int srcStride = width * 4;
                        int dstStride = frame.bytesPerLine(0);
                        
                        if (srcStride == dstStride) {
                            memcpy(frame.bits(0), map.data, map.size);
                        } else {
                            for (int y = 0; y < height; y++) {
                                memcpy(frame.bits(0) + y * dstStride, 
                                       map.data + y * srcStride, 
                                       srcStride);
                            }
                        }
                        
                        frame.unmap();
                        m_videoSink->setVideoFrame(frame);
                        // 注意：不增加渲染帧计数，因为是重复帧
                    }
                }
                gst_buffer_unmap(buffer, &map);
            }
        }
    }
    // 没有帧也没有备份：保持上一帧显示（什么都不做，画面自然保持）
}