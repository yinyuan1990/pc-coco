#ifndef GSTPLAYER_H
#define GSTPLAYER_H

#include <QObject>
#include <QVideoSink>
#include <QVideoFrame>
#include <QJsonArray>
#include <QMutex>
#include <QRecursiveMutex>
#include <QThread>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QProcess>
#include <QTimer>
#include <atomic>
#include <QSet>
#include <QHash>
#include "naluframestore.h"
#include "iframesource.h"   // ⭐ 帧源抽象接口（截图/慢放数据源解耦）
#include "gstsrtsource.h"   // MARK: SRT (independent)
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
// WebRTC 头文件使用 #warning 指令，MSVC 不支持
// 移到 .cpp 文件中包含，这里使用前向声明
// #include <gst/sdp/sdp.h>
// #include <gst/webrtc/webrtc.h>
typedef struct _GstWebRTCSessionDescription GstWebRTCSessionDescription;

/**
 * GStreamer 实时流播放器（WebRTCBin 版本）
 *
 * Pipeline: webrtcbin → rtph264depay → h264parse → tee
 *   ├→ queueDepay → decoder → ... → appsink（直播主路径）
 *   └→ nalu_queue(leaky) → nalu_appsink → NaluFrameStore（异步存储，不阻塞直播）
 */
class GstPlayer : public QObject, public IFrameSource
{
    Q_OBJECT
    Q_PROPERTY(QVideoSink* videoSink READ videoSink WRITE setVideoSink NOTIFY videoSinkChanged)
    Q_PROPERTY(bool playing READ isPlaying NOTIFY playingChanged)
    Q_PROPERTY(int videoWidth READ videoWidth NOTIFY videoSizeChanged)
    Q_PROPERTY(int videoHeight READ videoHeight NOTIFY videoSizeChanged)
    Q_PROPERTY(QString decoderName READ decoderName NOTIFY decoderChanged)
    Q_PROPERTY(int receiveFps READ receiveFps NOTIFY receiveFpsChanged)
    // ⭐ 2026-08-02：OTG 外接摄像头源标志。自带摄像头的 fps 显示做了 ×4（营销口径），
    //   OTG 是真实帧率、是多少显多少——QML 把 CameraCapsStore.isOtg 绑到这里。
    Q_PROPERTY(bool otgSource READ otgSource WRITE setOtgSource NOTIFY otgSourceChanged)
    Q_PROPERTY(int bufferSize READ bufferSize NOTIFY bufferSizeChanged)
    Q_PROPERTY(int bufferTarget READ bufferTarget NOTIFY bufferTargetChanged)
    // ⭐ P2P 连接阶段文字（连接中/切网重连中/重连中n/5/等待手机/已连接/失败），供 QML 面板+顶栏绑定
    Q_PROPERTY(QString webrtcStatus READ webrtcStatus NOTIFY webrtcStatusChanged)
    
public:
    explicit GstPlayer(QObject *parent = nullptr);
    ~GstPlayer();
    
    // QML 属性
    QVideoSink* videoSink() const { return m_videoSink; }
    void setVideoSink(QVideoSink *sink);
    
    bool isPlaying() const { return m_playing; }
    int videoWidth() const { return m_videoWidth; }
    int videoHeight() const { return m_videoHeight; }
    QString decoderName() const { return m_decoderName; }
    
    
    // FPS 统计（EMA 平滑后的帧率；自带摄像头 ×4，OTG 源真实值）
    int receiveFps() const { return m_receiveFps; }

    // ⭐ 2026-08-02：OTG 源不做 ×4
    bool otgSource() const { return m_otgSource.load(); }
    void setOtgSource(bool v) {
        if (m_otgSource.load() == v) return;
        m_otgSource = v;
        emit otgSourceChanged();
    }
    
    // ⭐ 缓冲队列信息（供 QML 显示）
    int bufferSize() const override { return m_bufferSize; }
    int bufferTarget() const { return m_bufferTarget; }
    
    // NALU 帧存储（H.264 ring buffer，替代 JPEG 文件）
    NaluFrameStore* naluFrameStore() const { return m_naluStore; }
    QByteArray spsPpsAnnexB() const { return m_spsPpsAnnexB; }

    QString h264FrameDirectory() const override { return m_h264FrameDirectory; }
    QString h264SessionPrefix() const { return m_h264SessionPrefix; }
    QString h264FramePath(qint64 frameIndex) const;
    bool hasH264Frame(qint64 frameIndex) const;
    QByteArray readH264Frame(qint64 frameIndex) const override;
    qint64 newestH264Frame() const override { return m_newestH264Frame.load(std::memory_order_acquire); }
    qint64 oldestH264Frame() const override { return m_oldestH264Frame.load(std::memory_order_acquire); }
    int registerH264ValidRange(qint64 start, qint64 end) override;
    void updateH264ValidRange(int id, qint64 start, qint64 end) override;
    void unregisterH264ValidRange(int id) override;
    // §88：观看会话结束（切设备/切账号/退登录）时显式清截图/慢放帧库。
    //   管线重建（看门狗自愈/心跳清屏重连/切网重协商）不再清帧库——否则截图格子全成假图。
    Q_INVOKABLE void resetCaptureSession();

    QImage grabCurrentFrame() override;

    // ⭐ IFrameSource 接口实现（GStreamer 帧源）
    QObject *asQObject() override { return this; }
    IFrameSource::FrameFormat frameFormat() const override { return IFrameSource::FrameFormat::H264; }

    // 推送 H.264 NALU 数据（保留用于兼容，WebRTCBin 模式下不使用）
    Q_INVOKABLE void pushNalu(const QByteArray &nalu);
    
    // 控制
    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void reset();
    
    // ⭐ WebRTC 连接（使用 GStreamer WebRTCBin）
    Q_INVOKABLE void connectWebRTC(const QString &host, const QString &app, const QString &stream);
    Q_INVOKABLE void disconnectWebRTC();
    Q_INVOKABLE bool isWebRTCConnected() const { return m_webrtcConnected; }
    Q_INVOKABLE QString webrtcStatus() const { return m_webrtcStatus; }
    Q_INVOKABLE void requestKeyFrame() override;  // 请求关键帧（发送 PLI）
    Q_INVOKABLE void startAutoKeyFrameRequest(int intervalMs = 1000);  // 周期性请求关键帧
    Q_INVOKABLE void stopAutoKeyFrameRequest();  // 停止周期性请求
    Q_INVOKABLE bool isAutoKeyFrameEnabled() const { return m_autoKeyFrameEnabled; }
    Q_INVOKABLE void flushDecoder();  // 清空解码器缓冲（档位切换防绿幕）
    
    // P2P 直连模式（不经过 SRS）
    Q_INVOKABLE void connectP2P(const QString &pairedIosDeviceId, const QJsonArray &iceServers);
    Q_INVOKABLE void disconnectP2P();
    Q_INVOKABLE void handleWebRTCSignaling(const QJsonObject &message);
    Q_INVOKABLE bool isP2PMode() const { return m_useP2P; }
    // ⭐ §53.25：当前协商轮次 epoch（QML 桥接发信令时带上，0=非 P2P 会话）
    Q_INVOKABLE qlonglong p2pEpoch() const { return m_p2pEpoch; }

    // ⭐ H265：CONFIG_STATE.videoCodec 下发（"h264"/"h265"），QML 在 playP2P 前调用。
    //   仅 P2P 生效；具体 H265 逻辑全部在 h265support.h/.cpp（与 H264 主链路解耦）。
    Q_INVOKABLE void setVideoCodec(const QString &codec);
    Q_INVOKABLE QString videoCodec() const { return m_useH265 ? QStringLiteral("h265") : QStringLiteral("h264"); }
    Q_INVOKABLE bool isH265Mode() const { return m_useH265; }

    // ⭐ 内核测试模式：内核（Chromium）独占 P2P 时，GStreamer 必须彻底退场——
    //   不拉流、不渲染、不处理任何 WebRTC 信令、且任何自动重连/重启 P2P 都被拦截，
    //   否则两端都向同一 username 抢 iOS 会话，导致内核侧出不来画面。
    Q_INVOKABLE void setKernelTestMode(bool on);
    Q_INVOKABLE bool isKernelTestMode() const { return m_kernelTestMode.load(); }

    // MARK: SRT (independent) —— 方案 B：PC 端独立 SRT 拉流（GStreamer srtsrc，与 WebRTC/P2P 解耦）
    Q_INVOKABLE void connectSRT(const QString &uri);
    Q_INVOKABLE void disconnectSRT();
    // ⭐ 供 QML 在确定 SRT 模式时尽早调用，提前预热解码器/编码器（消除首屏卡 3.3s）。进程级只跑一次。
    Q_INVOKABLE void warmupSRT() { warmupDecoderEncoderAsync(); }

    // ⭐ B 档统计（GStreamer 左上角面板用；数据复用现有内部统计，每秒在统计定时器刷新到 atomic 快照，
    //   QML 用 1s Timer 轮询读取，避免跨线程 NOTIFY）。
    Q_INVOKABLE int statJitterMs() const { return m_statJitterMs.load(); }          // 抖动 EMA(ms)
    Q_INVOKABLE int statPliCount() const { return m_statPli.load(); }               // 累计 PLI 请求数
    Q_INVOKABLE int statStallSeconds() const { return m_noFpsSeconds.load(); }      // 连续 0fps 秒数（卡顿）
    Q_INVOKABLE int statNackPerSec() const { return m_statNackPerSec.load(); }      // 本秒 NACK 请求数
    Q_INVOKABLE int statRtxOkPerSec() const { return m_statRtxOkPerSec.load(); }    // 本秒重传补回数
    Q_INVOKABLE int statLostPerSec() const { return m_statLostPerSec.load(); }      // 本秒丢包数
    Q_INVOKABLE double statLossPct() const { return m_statLossPctX100.load() / 100.0; } // 丢包率%
    Q_INVOKABLE int statQueueDepth() const { return m_statQueueDepth.load(); }      // 应用层抖动缓冲队列深度(帧)
    // 仅表示连接模式（P2P 直连链路 / SRS 服务器中转），不代表 ICE 是否走 relay。
    Q_INVOKABLE QString statConnMode() const { return m_useP2P ? QStringLiteral("P2P") : QStringLiteral("SRS"); }
    // ⭐ 真实 ICE 线路（webrtcbin get-stats 读选中候选对的 local/remote candidate-type）
    Q_INVOKABLE QString statRoute() const {
        const int l = m_routeLocalCode.load(), r = m_routeRemoteCode.load();
        if (l == 0 && r == 0) return QStringLiteral("探测中…");
        if (l == 4 || r == 4) return QStringLiteral("中继(relay)");
        return QStringLiteral("直连");
    }
    Q_INVOKABLE QString statRouteDetail() const {  // 例：本端 host / 远端 srflx
        return QStringLiteral("本端 ") + iceCodeStr(m_routeLocalCode.load())
             + QStringLiteral(" / 远端 ") + iceCodeStr(m_routeRemoteCode.load());
    }
private:
    static QString iceCodeStr(int c) {
        switch (c) { case 1: return QStringLiteral("host"); case 2: return QStringLiteral("srflx");
                     case 3: return QStringLiteral("prflx"); case 4: return QStringLiteral("relay");
                     default: return QStringLiteral("?"); }
    }
    static int iceCandTypeCode(const char *t) {
        if (!t) return 0;
        if (!qstrcmp(t, "host")) return 1; if (!qstrcmp(t, "srflx")) return 2;
        if (!qstrcmp(t, "prflx")) return 3; if (!qstrcmp(t, "relay")) return 4; return 0;
    }
    // webrtcbin get-stats 异步回调：解析选中候选对的 local/remote candidate-type → 缓存到 m_routeLocalCode/m_routeRemoteCode
    static void onWebRtcStatsReady(GstPromise *promise, gpointer userData);
    // SRT 专用：真正的 pipeline 创建+启动（重活），由 connectSRT 异步触发，避免冻结 GUI 首屏。
    void doConnectSRTPipeline();
    // 标记本次 SRT 连接会话，异步触发时校验是否已被新的连接/断开取代。
    std::atomic<int> m_srtConnectEpoch{0};
    // ⭐ 解码器/编码器预热（治「首屏卡 3.3s」）：在后台线程提前初始化 NVIDIA CUDA 解码器
    //   + MediaFoundation 截图编码器，使后续真正 createPipeline 走热路径。进程级只跑一次。
    //   预热是「全局」的硬件初始化，对 SRS/P2P 同样有利，但不改它们任何代码路径。
    void warmupDecoderEncoderAsync();
    std::atomic<bool> m_warmupStarted{false};
public:
    Q_INVOKABLE bool isSRTMode() const { return m_useSRT; }
    
    // QML 兼容（JPEG 管线已移除，保留空方法避免 QML 报错）
    Q_INVOKABLE void clearJpegFiles() {}
    Q_INVOKABLE void setJpegQuality(int) {}
    
    // 图像调节方法（使用 GStreamer videobalance 和 gamma）
    Q_INVOKABLE void setBrightness(double value);   // -1.0 ~ 1.0
    Q_INVOKABLE void setContrast(double value);     // 0.0 ~ 2.0
    Q_INVOKABLE void setSaturation(double value);   // 0.0 ~ 2.0
    Q_INVOKABLE void setHue(double value);          // -1.0 ~ 1.0
    Q_INVOKABLE void setGamma(double value);        // 0.01 ~ 10.0
    Q_INVOKABLE void setAllImageParams(double brightness, double contrast, double saturation, double hue, double gamma);

    // ⭐ Android 本地滤镜 sink：iOS 走设备端滤镜，Android 不支持滤镜 → 由 PC 端 GStreamer
    //   videobalance/gamma 落地。像素处理在 GStreamer 管线线程完成，绝不占用 Qt 主线程
    //   （此处仅做轻量 g_object_set 属性写入）。gamma<=0 表示保持不变。
    Q_INVOKABLE void applyColorFilter(double brightness, double contrast, double saturation, double gamma);
    Q_INVOKABLE void clearColorFilter();  // 复位中性（b=0, c=1, s=1, gamma=1）

    // PC 本地亮度（相机设定「亮度」滑条，iOS/Android 通用，不下发设备）：level -1..1，0=中性。
    //   与上面的 Android 滤镜值叠加后写入 videobalance/gamma，管线重建后自动重新套用。
    Q_INVOKABLE void setLocalBrightness(double level);
    
    // ⭐ 配置fps（PC手动设置时调用，用于延迟计算）
    Q_INVOKABLE void setConfigFps(double fps);
    Q_INVOKABLE double configFps() const { return m_configFps; }

    // ⭐ P2: 240fps 高速模式切换
    Q_INVOKABLE void setHighSpeedMode(bool enabled);
    Q_INVOKABLE bool isHighSpeedMode() const { return m_highSpeedMode; }
    
signals:
    void videoSinkChanged();
    void playingChanged();
    void videoSizeChanged();
    void decoderChanged();
    void error(const QString &message);
    void firstFrameReceived();
    
    // FPS 统计信号
    void receiveFpsChanged();
    void otgSourceChanged();
    
    // 缓冲队列信号
    void bufferSizeChanged();
    void bufferTargetChanged();
    
    // ⭐⭐⭐ 第二道防线：请求前端调整推流帧率
    // targetFps: 建议的目标帧率（0表示恢复原始帧率）
    // urgency: 紧急度 "critical"/"high"/"normal"/"low"
    // reason: 触发原因（调试用）
    void requestFpsChange(int targetFps, const QString &urgency, const QString &reason);
    
    // ⭐ WebRTC 信号
    void webrtcConnected();
    void webrtcDisconnected();
    void webrtcStatusChanged(const QString &status);
    // ⭐ 2026-08-01：P2P 被设备端以"单人直连已占用"拒绝——QML 据此弹框提示 + 停止自愈重连
    //   （否则 §54 看门狗每 8s 又重连一次、又被拒 → 反复卡死，第二/三台 PC 都进不来）。
    void p2pRejectedSingleMode();
    void naluReady(const QByteArray &nalu, bool isKeyFrame);  // 兼容旧接口
    void h264FrameStored(qint64 frameIndex);
    void h264FrameMissing(qint64 frameIndex);

    // P2P 信令信号（发给 WebSocket 中转）
    void sendSdpAnswer(const QString &sdp, const QString &toDevice);
    void sendIceCandidate(const QString &candidate, const QString &sdpMid, int sdpMLineIndex, const QString &toDevice);
    void sendHangup(const QString &reason, const QString &toDevice);
    void sendViewRequest(const QString &toDevice);

public slots:
    void createWebRTCOffer();  // ⭐ 需要作为 slot 以便跨线程调用
    
private:
    bool createPipeline();
    void destroyPipeline();
    QString detectGpuType();  // ⭐ GPU 类型检测（与 Java 一致）
    
    // ⭐ WebRTC 相关方法
    void setupWebRTCSignals();
    void onOfferCreated(GstWebRTCSessionDescription *offer);
    void sendOfferToSRS(const QString &sdp);
    void onAnswerReceived(const QString &sdp);
    void sendPLIRequest();
    
    // P2P 相关方法
    void handleP2POffer(const QString &sdp);
    void handleP2PIce(const QString &candidate, const QString &sdpMid, int sdpMLineIndex);
    void handleP2PHangup();
    void onP2PAnswerCreated(GstWebRTCSessionDescription *answer);
    void addP2PIceServers(const QJsonArray &iceServers);
    void scheduleP2PViewRequestRetry();
    void stopP2PViewRequestRetry(const QString &reason = QString());
    // ICE 断线/失败（如 iOS 切网换 WiFi）后，P2P 主动重连：重发 WEBRTC_REQUEST 让 iOS 重新发 Offer
    void attemptP2PIceReconnect(const QString &reason);
    // P2P 诊断：返回本地/远端候选者按类型(host/srflx/relay/other)的汇总字符串，供 p2p_diag.txt 在关键节点打印
    QString p2pCandSummary() const;
    
    // GStreamer 回调
    static GstFlowReturn onNewSample(GstAppSink *sink, gpointer userData);
    static GstFlowReturn onNaluStoreSample(GstAppSink *sink, gpointer userData);

    bool linkNaluTeeBranch();
    bool createH264FrameBranch();
    bool linkRawFrameTeeBranch(GstElement *upstreamTail, GstElement *displayHead);
    void extractSpsPpsFromCaps();
    void storeNaluFromBuffer(GstBuffer *buffer);
    static void onPadAdded(GstElement *element, GstPad *pad, gpointer userData);
    static GstBusSyncReply onBusSyncMessage(GstBus *bus, GstMessage *message, gpointer userData);
    
    // ⭐ WebRTCBin 回调（静态）
    static void onNegotiationNeeded(GstElement *webrtcbin, gpointer userData);
    static void onIceCandidate(GstElement *webrtcbin, guint mlineindex, gchar *candidate, gpointer userData);
    static void onWebRTCPadAdded(GstElement *webrtcbin, GstPad *pad, gpointer userData);
    static void onConnectionStateChanged(GstElement *webrtcbin, GParamSpec *pspec, gpointer userData);
    static void onIceGatheringStateChanged(GstElement *webrtcbin, GParamSpec *pspec, gpointer userData);
    static void onIceConnectionStateChanged(GstElement *webrtcbin, GParamSpec *pspec, gpointer userData);
    
    // Pipeline 元素
    GstElement *m_pipeline = nullptr;
    GstElement *m_appsrc = nullptr;       // 保留用于兼容模式
    GstElement *m_webrtcbin = nullptr;    // ⭐ WebRTCBin 元素
    GstElement *m_rtpJitterBuffer = nullptr; // ⭐ webrtcbin 内部 rtpjitterbuffer（NACK/重传 stats 读取，仅诊断用，不持引用所有权）
    GstElement *m_rtph264depay = nullptr; // ⭐ RTP H264 解包
    GstElement *m_h264parse = nullptr;
    GstElement *m_naluTee = nullptr;      // NALU 存储 tee（与直播主路径分离）
    GstElement *m_naluQueue = nullptr;    // 存储分支 leaky queue
    GstElement *m_naluAppsink = nullptr;  // 异步拉取 NALU 写入 ring buffer
    GstPad *m_naluTeePadMain = nullptr;
    GstPad *m_naluTeePadStore = nullptr;
    GstElement *m_queueDepay = nullptr;   // ⭐ 解码前缓冲队列（防马赛克关键）
    GstElement *m_decoder = nullptr;
    GstElement *m_queueDecode = nullptr;  // ⭐ 解码后缓冲队列（防马赛克关键）
    GstElement *m_download = nullptr;    // d3d11download（硬解时使用）
    bool m_useHardwareDecoder = false;    // 是否使用硬件解码
    GstElement *m_videoScale = nullptr;   // ⭐ videoscale（处理动态分辨率变化，防绿幕）
    GstElement *m_videoBalance = nullptr;  // videobalance（亮度、对比度、饱和度、色调）
    GstElement *m_gamma = nullptr;         // gamma（伽马值）
    double m_filterBrightness = 0.0;       // applyColorFilter 设的亮度（Android 本地滤镜）
    double m_filterGamma = 1.0;            // applyColorFilter 设的伽马
    double m_localBrightness = 0.0;        // setLocalBrightness 设的 PC 本地亮度 -1..1
    void applyEffectiveBrightness();       // 合成 filter + local 后写 videobalance.brightness / gamma.gamma
    GstElement *m_convert = nullptr;     // videoconvert
    GstElement *m_appsink = nullptr;
    
    // 显示分支
    GstElement *m_displayQueue = nullptr;  // 显示队列
    GstElement *m_clockSync = nullptr;

    // 独立 H.264 帧文件保存分支（raw frame 同源 tee → all-I encoder → appsink writer）
    GstElement *m_rawFrameTee = nullptr;
    GstElement *m_h264FrameQueue = nullptr;
    GstElement *m_h264FrameConvert = nullptr;
    GstElement *m_h264FrameEncoder = nullptr;
    GstElement *m_h264FrameParse = nullptr;
    GstElement *m_h264FrameCaps = nullptr;
    GstElement *m_h264FrameAppsink = nullptr;
    GstPad *m_rawFrameTeePadDisplay = nullptr;
    GstPad *m_rawFrameTeePadSave = nullptr;
    // §90：本机拿不到任何 H264 编码器时置 true——截图/慢放帧保存停用，实时画面不受影响
    //   （原来编码器缺失=整条管线建不起来=永久黑屏，见 2026-08-25 客户日志）
    bool m_frameSaveDisabled = false;
    QString m_h264FrameEncoderName;
    QString m_h264FrameDirectory;
    QString m_h264SessionPrefix;
    mutable QMutex m_h264FrameMutex;
    QList<qint64> m_pendingH264FrameIndexes;
    QSet<qint64> m_h264AvailableFrames;
    QHash<int, QPair<qint64, qint64>> m_h264ValidRanges;
    int m_nextH264ValidRangeId = 1;
    std::atomic<qint64> m_nextH264FrameIndex{0};
    std::atomic<qint64> m_oldestH264Frame{-1};
    std::atomic<qint64> m_newestH264Frame{-1};
    static GstFlowReturn onH264FrameSample(GstAppSink *sink, gpointer userData);
    bool writeH264Frame(qint64 frameIndex, const QByteArray &data);
    void resetH264FrameState();
    // §23.11 P0-1：锁内只摘索引并返回待删文件路径，真正的 QFile::remove 由调用方
    // 丢 QThreadPool 后台执行（removeH264FilesAsync），避免持锁/在主线程做批量磁盘删除。
    QStringList cleanupH264FramesLocked();
    static void removeH264FilesAsync(const QStringList &paths);
    bool isH264FrameProtectedLocked(qint64 frameIndex) const;
    void recomputeOldestH264FrameLocked();
    qint64 takePendingH264FrameIndex();
    void queuePendingH264FrameIndex(qint64 frameIndex);

    // Qt 显示
    QVideoSink *m_videoSink = nullptr;
    
    // 状态
    std::atomic<bool> m_playing{false};
    std::atomic<bool> m_firstFrame{false};
    int m_videoWidth = 0;
    int m_videoHeight = 0;
    QString m_decoderName;
    qint64 m_frameIndex = 0;
    
    // 🔥 v10超低延迟：PTS 时间戳控帧
    qint64 m_startPts = -1;              // 首帧 PTS（用于时序基准）
    qint64 m_startSystemTime = 0;        // 首帧系统时间（毫秒）
    static constexpr int PTS_OFFSET_MS = 80; // 🔥 固定偏移量（80ms目标延迟）
    
    // ⭐ WebRTC 状态
    QNetworkAccessManager *m_networkManager = nullptr;
    QString m_webrtcHost;
    QString m_webrtcApp;
    QString m_webrtcStream;
    std::atomic<bool> m_webrtcConnected{false};
    QString m_webrtcStatus = "Ready";
    bool m_transceiverAdded = false;  // 防止重复添加 transceiver
    bool m_useWebRTC = false;  // 是否使用 WebRTC 模式
    bool m_useP2P = false;     // P2P 直连模式
    bool m_useH265 = false;    // ⭐ H265 会话（仅 P2P；元素/关键帧/日志分派见 h265support.h）
    std::atomic<bool> m_kernelTestMode{false};   // 内核测试模式：GStreamer 完全让出 P2P
    QString m_pairedIosDeviceId;  // 配对的 iOS 设备 ID

    // ⭐ P2P 独立诊断：ICE 候选者按类型计数（索引：0=host 1=srflx 2=relay 3=other）
    //   relay 计数=0 是「手机连手机热点出不来」的核心判据（CGNAT/对称 NAT 必须走 TURN relay）。
    //   仅 P2P 路径读写，对 SRS/SRT 无影响。
    std::atomic<int> m_p2pLocalCand[4]{};   // 本地（PC）收集到的候选者
    std::atomic<int> m_p2pRemoteCand[4]{};  // 远端（iOS）发来的候选者

    // MARK: SRT (independent) —— 方案 B：PC 端独立 SRT 拉流（与 WebRTC/P2P 互斥，只走一条）
    bool m_useSRT = false;        // 是否使用 SRT 拉流模式
    QString m_srtUri;             // SRT 完整地址（srt://ip:port?streamid=...）
    GstSrtSource m_srtSource;     // SRT 前段（srtsrc→tsdemux），元素创建/链接/销毁封装在独立文件
    gulong m_srtParseProbeId = 0; // SRT 专用：h264parse src 统计 probe（与 WebRTC 的 m_depayProbeId 解耦）
    bool m_srtInitialCropDone = false; // SRT 专用：首帧 gop_cache 历史帧是否已裁过一次
    bool m_p2pConnected = false;  // P2P ICE 连接是否已建立
    int m_iceRetryCount = 0;      // ICE 失败重试计数
    // ⭐ 切网重协商防卡死：记住当前会话的远端 ice-ufrag。收到 ufrag 变化的 re-offer(已连接态)=
    //   手机切网/ICE Restart，GStreamer webrtcbin 无法在旧实例上重启 ICE → 必须整体重建。
    //   destroyPipeline 时清空（重建后的首个 fresh offer 不误判为重协商）。
    QString m_currentRemoteIceUfrag;
    std::atomic<bool> m_waitingForP2POffer{false};  // 等待 iOS Offer
    std::atomic<int> m_p2pViewRequestRetryCount{0}; // WEBRTC_REQUEST 重发次数
    QJsonArray m_p2pIceServers;   // §25.7e：connectP2P 传入的 ICE 服务器，供切中继重建 pipeline 复用
    // ICE 断线主动重连：epoch 让“DISCONNECTED 延迟检查”在期间状态已恢复时自动失效
    std::atomic<int> m_iceReconnectEpoch{0};
    bool m_iceReconnecting = false;                 // 是否正在主动重连（防重复触发）
    // §54：等 Offer 重发**无上限**（常驻循环，停止条件=收到 Offer/HANGUP/REJECT/QML 主动断开），
    //   原 P2P_VIEW_REQUEST_RETRY_MAX=5 的"7.5s 耗尽即永久放弃"终态已删除。
    static constexpr int P2P_VIEW_REQUEST_RETRY_INTERVAL_MS = 1500;
    std::atomic<bool> m_offerInProgress{false};  // 防止重复创建 Offer
    std::atomic<bool> m_offerSentForSession{false};  // 🔥 本次连接已发送过 Offer（防止 timer 和 on-negotiation-needed 双重触发）
    std::atomic<bool> m_reconnectScheduled{false}; // 防止重复重连
    std::atomic<bool> m_srsError{false};  // 🔥 SRS错误标志（防止无效重连）
    std::atomic<int> m_srsRetryCount{0};  // 🔥 SRS 400错误重试计数
    // §92 SRS 会话代际守卫：connectWebRTC/disconnectWebRTC 时 +1。HTTP 应答/重试定时器
    //   携带发出时的代数，回来时代数不一致 = 上一条已销毁会话的迟到应答 → 丢弃。
    //   修「看门狗重建后 0.6s 又被『设备开始推流』触发二次重播，两个 SRS Answer(不同 ice-ufrag)
    //   先后灌进同一条新管线 → ICE 凭据错乱 → ICE FAILED 长时间黑屏」（8-28 日志实锤）。
    std::atomic<quint64> m_srsSessionGen{0};
    std::atomic<bool> m_srsAnswerApplied{false};  // §92 本会话已应用过 Answer（同会话双应答兜底）
    QString m_pendingOfferSdp;  // 🔥 待重试的 Offer SDP
    // ⭐ §53.24：P2P Offer 风暴防抖（设备端会话抖动时连发多个 Offer，只应用最后一个）
    qint64 m_lastOfferAppliedMs = 0;      // 上次真正应用 Offer 的时刻
    QString m_pendingP2POfferSdp;         // 风暴期间暂存的最新 Offer（与 SRS 的 m_pendingOfferSdp 无关）
    QTimer *m_offerDebounceTimer = nullptr;
    // ⭐ §53.25：会话 epoch——一轮协商一个（connectP2P/重建重连时更新，重发不换）。
    //   REQUEST 带出、设备端回带、PC 校验；不匹配的信令 = 过期轮次，直接丢弃。
    qint64 m_p2pEpoch = 0;
    std::atomic<int> m_noFpsSeconds{0};   // 🔥 连续0fps秒数（5秒自动断开）
    // ⭐ B 档面板统计快照（每秒在统计定时器里刷新；atomic 供 QML 线程安全读取）
    std::atomic<int> m_statJitterMs{0};
    std::atomic<int> m_statPli{0};
    std::atomic<int> m_statNackPerSec{0};
    std::atomic<int> m_statRtxOkPerSec{0};
    std::atomic<int> m_statLostPerSec{0};
    std::atomic<int> m_statLossPctX100{0};
    std::atomic<int> m_statQueueDepth{0};
    std::atomic<int> m_routeLocalCode{0};   // 选中候选对本端类型 0未知/1host/2srflx/3prflx/4relay
    std::atomic<int> m_routeRemoteCode{0};  // 选中候选对远端类型
    qint64 m_fpsAdjustCooldownMs{0};      // 🔥 手动调帧冷却期结束时间（防止误触发降帧）
    static constexpr int FPS_ADJUST_COOLDOWN_SEC = 5;   // 冷却5秒（配合送达率判断，不需要太长）
    
    // ⭐ 周期性关键帧请求
    QTimer *m_keyFrameTimer = nullptr;
    bool m_autoKeyFrameEnabled = false;
    
    
    // FPS 统计（EMA 指数移动平均，极度平滑）
    std::atomic<int> m_fpsFrameCounter{0};       // 当前秒帧计数
    qint64 m_fpsLastSecondMs = 0;                // 上次统计时间
    double m_fpsEma = 0.0;                       // EMA 值
    bool m_fpsEmaInitialized = false;            // EMA 是否已初始化
    std::atomic<int> m_receiveFps{0};            // 最终帧率值（自带 ×4 / OTG 真实值）
    std::atomic<bool> m_otgSource{false};        // ⭐ OTG 源：fps 统计不做 ×4（统计跑在流线程，用原子量）
    static constexpr double FPS_EMA_ALPHA = 0.2; // 平滑系数（越小越平滑）
    
    // ⭐ 缓冲队列状态（供 QML 显示）
    std::atomic<int> m_bufferSize{0};            // 当前队列大小
    std::atomic<int> m_bufferTarget{0};          // 目标队列大小
    
    // ⭐⭐⭐ 应用层 Jitter Buffer + 极致平滑方案
    // 核心：速率匹配 + EMA多重平滑 + 微调补偿 + 渐进式延迟调整
    QList<GstSample*> m_frameQueue;              // 帧队列（FIFO）
    QMutex m_queueMutex;                         // 保护队列
    QTimer *m_renderTimer = nullptr;             // 自适应渲染定时器
    std::atomic<int> m_renderFrameCounter{0};    // 渲染帧计数（用于日志）
    std::atomic<bool> m_bufferingStarted{false}; // 是否已开始缓冲
    
    // ========== 常量参数 ==========
    static constexpr double ALPHA_RATE = 0.3;    // 到达速率EMA系数（α）
    static constexpr double BETA_DEPTH = 0.2;    // 深度EMA系数（β）
    static constexpr double GAMMA_INTERVAL = 0.3;// 间隔EMA系数（γ）
    static constexpr double MAX_SPEEDUP = 1.3;   // 最大加速倍率（温和追赶）
    
    // 🔥🔥🔥 v11.3 动态队列配置
    // QUEUE_ABSOLUTE_MAX: 队列硬限制（仅用于异常保护，正常靠追帧消耗）
    // 公式：500ms最大延迟 × 60fps = 30帧
    // 正常情况下由 getQueueSizeByFps() 动态控制，不会触发硬限制
    static constexpr int QUEUE_ABSOLUTE_MAX = 30; // 🔥 v11.3: 提高到30帧（500ms@60fps）
    
    // ⭐⭐⭐ 双缓冲策略配置 ⭐⭐⭐
    // 核心原则：延迟按时间（ms）恒定，队列帧数根据 FPS 自动调整
    // ⭐⭐⭐ 动态延迟公式（FPS越低延迟越低）：
    // ⭐⭐⭐ 2025-01-26 优化：增加缓冲深度，减少极端网络卡顿
    // 应用层延迟(ms) = FPS × 10（范围100~600ms）
    // 队列帧数 = FPS × 应用层延迟 / 1000
    // 总延迟 = GStreamer(100ms) + 应用层延迟
    //
    // ⭐⭐⭐ v8客户方案：以当前帧率为中心计算所有参数
    // 🔥🔥🔥 v10超低延迟：80-400ms延迟，微队列控帧
    // 🔥🔥🔥 v11 动态队列策略：根据帧率分段设置队列大小
    // | 帧率        | 最小 | 最佳 | 最大 | 说明           |
    // |-------------|------|------|------|----------------|
    // ⭐⭐⭐ 延迟阈值（用于第二道保险：控制推流帧率）
    // v9.2调整：基于新缓冲策略（最佳220ms，最大470ms），延迟阈值需要相应调高
    // 降帧触发：延迟>500ms（超过最大缓冲）说明网络持续恶化
    // 升帧恢复：延迟在200-500ms之间说明网络恢复正常
    static constexpr int APP_DELAY_LOWER_START = 500;  // 应用层延迟>500ms开始降帧⭐v9.2调整
    static constexpr int APP_DELAY_LOWER_MAX = 800;    // 应用层延迟达到800ms时降到最低帧率⭐v9.2调整
    static constexpr int APP_DELAY_RESTORE = 200;      // 应用层延迟≥200ms可以考虑升帧⭐v9.2调整
    static constexpr int DELAY_MIN = 150;              // 最小延迟150ms⭐v9.2调整
    
    // 队列绝对下限（防止帧率极低时队列为0）
    // 🔥🔥🔥 v9.3双缓冲：恢复基于fps比例的队列计算（不依赖损坏率）
    // 核心公式：optimal = fps × 22%（约220ms延迟）
    static constexpr double BUFFER_RATIO_MIN = 0.15;     // 最低缓冲比例（150ms延迟）
    static constexpr double BUFFER_RATIO_OPTIMAL = 0.22; // 最佳缓冲比例（220ms延迟）
    static constexpr double BUFFER_RATIO_MAX = 0.47;     // 最大缓冲比例（470ms延迟）
    static constexpr int QUEUE_ABS_MIN = 1;              // 绝对最小1帧
    
    // (旧常量已移至分段函数阈值 W_EXPAND=0.35, W_NORMAL_HIGH=0.8)
    static constexpr int QUEUE_EXPAND_STEP = 3;        // 每次扩容3帧（快速响应）
    static constexpr int QUEUE_SHRINK_STEP = 1;        // 每次收缩1帧（平滑）
    static constexpr int SHRINK_STABLE_FRAMES = 90;    // ⭐ 60→90：稳定3秒才收缩（更保守）
    static constexpr int FAST_ADJUST_THRESHOLD = 6;    // ⭐ 新增：快速调整阈值（差距>6帧才触发）
    static constexpr int EXPAND_COOLDOWN_SEC = 3;      // ⭐ 新增：扩容后冷却3秒内禁止快速收缩
    
    // 🔥🔥🔥 v9.3双缓冲：基于fps比例计算队列参数（copygstream版本）
    // SRS模式：30fps → optimal=7帧(220ms), min=5帧(150ms), max=14帧(470ms)
    // P2P模式：30fps → optimal=3帧(100ms), min=2帧(67ms), max=6帧(200ms)
    static inline void getQueueSizeByFps(double fps, int &outMin, int &outOptimal, int &outMax, double /*corruptRatio*/ = 0.0, bool /*isP2P*/ = false) {
        // ⭐ P2P 与 SRS 统一使用同一套队列配置（都按 SRS 来，不再区分）
        // SRS模式：30fps → optimal=7帧(220ms), min=5帧(150ms), max=14帧(470ms)
        outOptimal = qMax(QUEUE_ABS_MIN, static_cast<int>(fps * BUFFER_RATIO_OPTIMAL + 0.5));
        outMin = qMax(QUEUE_ABS_MIN, static_cast<int>(fps * BUFFER_RATIO_MIN + 0.5));
        outMax = qMax(QUEUE_ABS_MIN, static_cast<int>(fps * BUFFER_RATIO_MAX + 0.5));
    }
    
    // (旧常量已移至速率范围 R_MIN=0.7, R_MAX=1.2)
    
    // ⭐ 分段函数阈值（数学模型关键参数）
    static constexpr double W_EMERGENCY = 0.15;       // 紧急水位（停止消耗）
    static constexpr double W_EXPAND = 0.35;          // 扩容水位
    static constexpr double W_NORMAL_LOW = 0.5;       // 正常低水位（恢复消耗）
    static constexpr double W_NORMAL_HIGH = 0.8;      // 正常高水位（触发收缩）
    static constexpr double W_CATCHUP = 1.05;         // 追帧水位
    static constexpr double W_CATCHUP_MAX = 1.5;      // 最大追帧水位
    static constexpr double W_DROP_THRESHOLD = 1.5;   // ⭐ 队列>150%时丢帧
    static constexpr double W_DROP_TARGET = 1.2;      // ⭐ 丢帧后目标120%
    
    // ⭐ 速率范围（收窄：减少人眼感知的忽快忽慢）
    static constexpr double R_MIN = 0.93;             // 最低93%（之前85%跳动太大）
    static constexpr double R_MAX = 1.07;             // 最高107%（之前115%跳动太大）
    static constexpr double R_CHANGE_LIMIT = 0.03;    // 每帧最大变化±3%（更平滑）
    
    // ⭐⭐⭐ 第二道防线：推流帧率控制（边缘化触发）
    // 2025-01-27 优化：更早触发（30%+1秒），快速响应网络恶化
    // 2025-01-27 优化：恢复阈值降低（50%+5秒），解决降帧后无法恢复问题
    // ⭐⭐⭐ 客户优化：动态阈值 + 预测式降帧
    static constexpr int FPS_PUSH_MAX = 60;               // 推流帧率上限60fps（实际）
    static constexpr int FPS_DELAY_MIN = 15;              // 延迟触发降帧的最低帧率15fps
    static constexpr int FPS_QUEUE_MIN = 20;              // 队列触发降帧的最低帧率20fps
    
    // 动态阈值比例（基于最佳缓冲）
    static constexpr double QUEUE_LOWER_RATIO = 0.35;     // 降帧阈值 = 最佳缓冲 × 35%
    static constexpr double QUEUE_UPPER_RATIO = 0.70;     // 升帧阈值 = 最佳缓冲 × 70%
    
    // 预测式降帧：队列下降速度阈值
    static constexpr int DROP_SPEED_WARNING = 3;          // 下降≥3帧/秒：预警
    static constexpr int DROP_SPEED_CRITICAL = 5;         // 下降≥5帧/秒：立即降帧
    static constexpr int FPS_LOWER_HOLD_SEC = 1;          // 持续1秒触发降帧
    static constexpr int FPS_RESTORE_HOLD_SEC = 1;        // ⭐ 3→1秒：升帧等待时间
    
    // ⭐ FPS变化检测配置
    static constexpr double FPS_CHANGE_THRESHOLD = 0.3;  // FPS变化阈值30%
    static constexpr int FPS_CHANGE_STABLE_SEC = 3;      // FPS变化持续3秒才触发
    
    // GStreamer 固定配置
    // ⭐ P2P 与 SRS 统一使用 SRS 的 600ms（队列/延迟都按 SRS 来，不再区分）
    static constexpr int GST_JITTER_LATENCY_P2P = 600;
    static constexpr int GST_JITTER_LATENCY_SRS = 600;
    static constexpr int GST_JITTER_LATENCY = 600;  // 兼容旧引用（SRS默认值）
    int getJitterLatency() const { return GST_JITTER_LATENCY_SRS; }
    
    // ========== 自适应状态变量 ==========
    double m_configFps = 30.0;                   // 配置fps（PC手动设置/iOS设备fps）
    bool m_highSpeedMode = false;                // P2: 240fps 高速模式标志
    // P2: 240fps 验证日志（100ms窗口计数）
    qint64 m_hsWindowStartMs = 0;
    int m_hsWindowFrameCount = 0;
    double m_arrivalRateEma = 30.0;              // 实测帧到达速率EMA（用于检测网络质量）
    double m_depthEma = 6.0;                     // 队列深度EMA D(t)
    double m_intervalEma = 33.0;                 // 消费间隔EMA I(t)
    int m_queueTarget = 9;                       // 当前目标缓冲帧数（动态，初始按30fps×300ms=9帧）
    double m_queueTargetSmooth = 9.0;            // 平滑目标缓冲（渐变过渡）
    double m_playbackRate = 1.0;                 // 播放速率（1.0=正常，<1.0=慢放）
    double m_targetRate = 1.0;                   // 目标速率（分段函数输出）
    bool m_slowdownActive = false;               // 极端网络状态标志
    bool m_emergencyHold = false;                // 紧急保护模式（停止消耗，保留最后帧）
    GstSample *m_lastValidSample = nullptr;      // 最后一个有效帧（用于紧急时重复显示）
    
    // 🔥🔥🔥 v10.3 等待关键帧模式（防花屏核心）
    std::atomic<bool> m_waitingForKeyframe{false}; // 等待关键帧模式
    std::atomic<bool> m_preDecodeDiscont{false};   // 🔥 解码前检测到 DISCONT（关键！）
    std::atomic<bool> m_preDecodeIdr{false};       // 🔥 解码前检测到 IDR 关键帧
    std::atomic<int> m_consecutiveGoodFrames{0};   // 🔥 连续正常帧计数（必须 >=5 才退出等待）
    qint64 m_lastKeyframeRequestMs = 0;            // 上次请求关键帧时间
    int m_pliRequestCount = 0;                     // PLI 请求计数
    qint64 m_h265NoIrapPliMs = 0;                  // H265 无IRAP催帧节流（wait-for-keyframe 兜底放行后每秒催一次）
    gulong m_depayProbeId = 0;                     // 🔥 解码前 probe ID
    static constexpr int PLI_INTERVAL_WEAK_MS = 200;  // 弱网 PLI 间隔 200ms
    static constexpr int PLI_INTERVAL_NORMAL_MS = 500; // 正常 PLI 间隔 500ms
    static constexpr int GOOD_FRAMES_TO_EXIT = 5;  // 🔥 连续 5 帧正常才退出等待模式
    int m_stableCounter = 0;                     // 稳定计数器（用于收缩/恢复判断）
    qint64 m_lastQualityCheckMs = 0;             // 上次质量检测时间
    
    // ⭐⭐⭐ FPS变化检测（自动唤醒机制）
    int m_fpsChangeCounter = 0;                  // FPS变化计数器（连续秒数）
    double m_lastSecondFps = 0.0;                // 上一秒实际到达帧数
    int m_currentSecondFrames = 0;               // 当前秒帧计数
    qint64 m_fpsSecondStartMs = 0;               // 当前秒起始时间
    
    // ⭐⭐⭐ 第二道防线：推流帧率控制状态
    int m_lowWaterHoldSec = 0;                   // 低水位持续秒数
    int m_highWaterHoldSec = 0;                  // 高水位持续秒数
    int m_requestedFps = 0;                      // 已请求的目标帧率（0=未请求）
    int m_lastQueueDepth = 0;                    // ⭐ 上一秒队列深度（用于计算下降速度）
    double m_queueDepthEma = 0;                  // ⭐ v8.4: 队列深度EMA（用于平滑速度调整）
    static constexpr double QUEUE_EMA_ALPHA = 0.2; // 队列深度EMA系数（更平滑）
    int m_originalFps = 0;                       // 原始帧率（降帧前的帧率）
    
    // ⭐⭐⭐ v8.3 帧间隔抖动检测（预测式降帧）
    qint64 m_lastFrameArrivalMs = 0;             // 上一帧到达时间戳
    double m_jitterEma = 0.0;                    // 抖动EMA（ms）
    static constexpr double JITTER_ALPHA = 0.3;  // 抖动EMA系数
    static constexpr double JITTER_LOWER_RATIO = 0.30;  // 抖动比例>30%开始降帧
    static constexpr double JITTER_UPPER_RATIO = 1.00;  // 抖动比例100%降到最低帧率
    static constexpr double JITTER_RESTORE_RATIO = 0.20; // 抖动比例<20%可升帧
    
    // ⭐⭐⭐ v9.3 趋势预测（提前 1-2 秒预知网络恶化）
    double m_lastJitterEma = 0.0;                // 上一秒抖动EMA（用于计算趋势）
    double m_lastArrivalRate = 1.0;              // 上一秒到达率（用于计算趋势）
    double m_jitterTrend = 0.0;                  // 抖动变化率 (ms/s)，正值表示恶化
    double m_arrivalSlope = 0.0;                 // 到达率斜率 (%/s)，负值表示恶化
    int m_queueDropSpeed = 0;                    // 队列下降速度 (帧/s)
    double m_riskScore = 0.0;                    // 综合风险分 (0~1)
    static constexpr double JITTER_TREND_THRESHOLD = 2.0;    // 抖动趋势 > 2ms/s 预警
    static constexpr double ARRIVAL_SLOPE_THRESHOLD = -0.05; // 到达率斜率 < -5%/s 预警
    static constexpr double RISK_SCORE_THRESHOLD = 0.5;      // 风险分 > 0.5 触发预警
    
    // ⭐⭐⭐ 队列为空紧急应对
    int m_emptyQueueCount = 0;                   // 队列见底次数（统计）
    qint64 m_emptyQueueStartMs = 0;              // 队列见底开始时间
    bool m_emergencyFpsLowered = false;          // 是否已紧急降帧
    static constexpr double R_EMERGENCY_MIN = 0.50; // 紧急时最低播放速度50%
    
    // 🔥🔥🔥 v10.5 网络质量核心指标：损坏帧统计
    std::atomic<int> m_corruptFrameCount{0};     // 当前秒损坏帧数
    std::atomic<int> m_totalFrameCount{0};       // 当前秒总帧数
    int m_lastSecondCorruptFrames = 0;           // 上一秒损坏帧数
    int m_lastSecondTotalFrames = 0;             // 上一秒总帧数
    double m_corruptRatioEma = 0.0;              // 损坏帧比例EMA（0~1）
    static constexpr double CORRUPT_RATIO_WEAK = 0.10;    // 损坏率 > 10% = 弱网
    static constexpr double CORRUPT_RATIO_CRITICAL = 0.30; // 损坏率 > 30% = 极弱网
    
    // ========== 核心算法函数 ==========
    void onRenderTick();                         // 定时器回调
    double calcSmoothInterval(int queueDepth);   // 计算消费间隔
    void adjustQueueTarget(int queueDepth);      // 第一道防线：调整队列目标
    void adjustPlaybackRate(int queueDepth);     // 第二道防线：调整播放速度
    double piecewiseRate(double waterLevel);     // ⭐ 分段函数：水位→目标速率
    void detectFpsChange();                      // ⭐ FPS变化检测（自动唤醒）
    void checkPushFpsControl(double waterLevel); // ⭐⭐⭐ 第二道防线：推流帧率控制
    
    
    // ⚠️ 必须是递归锁：createPipeline() 持有本锁后会内部调用 destroyPipeline()，
    //   而 destroyPipeline() 同样要锁本锁。普通 QMutex 不可重入 → 二次加锁直接死锁
    //   （表现为「链路来回切换多了，主线程卡死、UI 拖不动」）。改用 QRecursiveMutex 彻底消除。
    QRecursiveMutex m_mutex;

    static constexpr int H264_FRAME_KEEP_COUNT = 3000;
    static constexpr int H264_CLEANUP_INTERVAL = 600;
    static constexpr int H264_SAFETY_MARGIN = 300;

    // NALU 帧存储
    NaluFrameStore *m_naluStore = nullptr;
    std::atomic<qint64> m_naluFrameIndex{0};
    QByteArray m_spsPpsAnnexB;  // SPS/PPS Annex-B（从 codec_data 提取）
    int m_nalLengthSize = 4;    // AVCC NAL 长度字段大小

    // 独立 intra-only 编码管道（与直播 pipeline 完全隔离）
    GstElement *m_encodePipeline = nullptr;
    GstElement *m_encodeAppsrc = nullptr;
    GstElement *m_encodeAppsink = nullptr;
    bool m_useIntraEncode = false;
    quint64 m_encodePts = 0;
    void createEncodePipeline();
    void destroyEncodePipeline();
    static GstFlowReturn onEncodedSample(GstAppSink *sink, gpointer userData);
};

#endif // GSTPLAYER_H
