#include "capturemanager.h"
#include "gpupipeline.h"
#include "imageprovider.h"
#include "slowmotionplayer.h"
#include "webframesource.h"
#include "capturedebuglog.h"
#include <QtConcurrent>
#include <QThreadPool>
#include <QStandardPaths>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QDir>
#include <QFile>
#include <QBuffer>
#include <QTimer>
#include <QDebug>
#include <QTextStream>
#include <QDateTime>
#include <QTransform>

#ifdef Q_OS_WIN
#include <windows.h>
#include <psapi.h>
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

// ============== 内存监控 ==============
static double getMemoryUsageMB() {
#ifdef Q_OS_WIN
    PROCESS_MEMORY_COUNTERS pmc;
    if (GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        return pmc.WorkingSetSize / (1024.0 * 1024.0);
    }
#endif
    return 0.0;
}

// ============== JpegRingBuffer ==============

JpegRingBuffer::JpegRingBuffer(int capacity)
    : m_capacity(capacity)
{
    m_buffer.resize(capacity);
}

void JpegRingBuffer::addFrame(const QByteArray &jpegData, qint64 frameIndex)
{
    QMutexLocker lock(&m_mutex);
    
    // 直接移动数据，避免复制
    m_buffer[m_head].data = jpegData;
    m_buffer[m_head].frameIndex = frameIndex;
    m_head = (m_head + 1) % m_capacity;
    if (m_count < m_capacity) {
        m_count++;
    }
}

JpegFrame JpegRingBuffer::getFrame(int offset) const
{
    QMutexLocker lock(&m_mutex);
    
    if (m_count == 0 || offset > 0 || -offset >= m_count) {
        return JpegFrame();
    }
    
    // offset: 0=最新, -1=前一帧, ...
    int pos = (m_head - 1 + offset + m_capacity) % m_capacity;
    return m_buffer[pos];
}

JpegFrame JpegRingBuffer::getFrameByIndex(qint64 frameIndex) const
{
    QMutexLocker lock(&m_mutex);
    
    if (m_count == 0) return JpegFrame();
    
    // 查找帧
    for (int i = 0; i < m_count; i++) {
        int pos = (m_head - 1 - i + m_capacity) % m_capacity;
        if (m_buffer[pos].frameIndex == frameIndex) {
            return m_buffer[pos];
        }
    }
    
    return JpegFrame();
}

bool JpegRingBuffer::hasFrame(qint64 frameIndex) const
{
    QMutexLocker lock(&m_mutex);
    
    if (m_count == 0) return false;
    
    qint64 newest = newestIndex();
    qint64 oldest = oldestIndex();
    
    return frameIndex >= oldest && frameIndex <= newest;
}

int JpegRingBuffer::size() const
{
    QMutexLocker lock(&m_mutex);
    return m_count;
}

qint64 JpegRingBuffer::oldestIndex() const
{
    // 注意：调用者应该已经持有锁
    if (m_count == 0) return -1;
    int pos = (m_head - m_count + m_capacity) % m_capacity;
    return m_buffer[pos].frameIndex;
}

qint64 JpegRingBuffer::newestIndex() const
{
    // 注意：调用者应该已经持有锁
    if (m_count == 0) return -1;
    int pos = (m_head - 1 + m_capacity) % m_capacity;
    return m_buffer[pos].frameIndex;
}

void JpegRingBuffer::clear()
{
    QMutexLocker lock(&m_mutex);
    m_head = 0;
    m_count = 0;
    for (auto &frame : m_buffer) {
        frame = JpegFrame();
    }
}

// ============== JpegEncoder ==============

JpegEncoder::JpegEncoder(JpegRingBuffer *buffer, QObject *parent)
    : QThread(parent)
    , m_ringBuffer(buffer)
{
    start(QThread::LowPriority);  // 低优先级，不抢占主线程
}

JpegEncoder::~JpegEncoder()
{
    stop();
    wait();
}

void JpegEncoder::stop()
{
    m_running = false;
    m_condition.wakeAll();
}

void JpegEncoder::submitFrame(const QImage &frame, qint64 frameIndex)
{
    if (frame.isNull() || !m_running) return;
    
    // 尝试获取锁，如果锁被占用则跳过这帧（避免阻塞主线程）
    if (!m_mutex.tryLock()) {
        return;  // 编码器忙，跳过这帧
    }
    
    // 队列满时丢弃最老的帧
    while (m_queue.size() >= MAX_QUEUE_SIZE) {
        m_queue.dequeue();
    }
    
    m_queue.enqueue({frame, frameIndex});
    m_condition.wakeOne();
    m_mutex.unlock();
}

bool JpegEncoder::initEncoder(int width, int height)
{
    if (m_codecCtx && m_encoderWidth == width && m_encoderHeight == height) {
        return true;
    }
    
    cleanupEncoder();
    
    // 列出所有可用的 MJPEG 编码器
    qDebug() << "=== Searching for MJPEG encoders ===";
    void *iter = nullptr;
    const AVCodec *c;
    while ((c = av_codec_iterate(&iter))) {
        if (av_codec_is_encoder(c) && c->id == AV_CODEC_ID_MJPEG) {
            qDebug() << "Found MJPEG encoder:" << c->name << "-" << (c->long_name ? c->long_name : "");
        }
    }
    qDebug() << "=== End encoder search ===";
    
    // 尝试硬件加速编码器
    const AVCodec *codec = nullptr;
    bool useHardware = false;
    
    // 1. 尝试 Intel QSV (mjpeg_qsv) - 需要 Intel GPU
    codec = avcodec_find_encoder_by_name("mjpeg_qsv");
    if (codec) {
        qDebug() << "Trying Intel QSV MJPEG encoder";
        useHardware = true;
    }
    
    // 2. 尝试 VAAPI (Linux/一些 Windows)
    if (!codec) {
        codec = avcodec_find_encoder_by_name("mjpeg_vaapi");
        if (codec) {
            qDebug() << "Trying VAAPI MJPEG encoder";
            useHardware = true;
        }
    }
    
    // 3. 回退到软件编码器
    if (!codec) {
        codec = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
        qDebug() << "Using software MJPEG encoder";
    }
    
    if (!codec) {
        qWarning() << "No MJPEG encoder found";
        return false;
    }
    
    m_codecCtx = avcodec_alloc_context3(codec);
    if (!m_codecCtx) return false;
    
    m_codecCtx->width = width;
    m_codecCtx->height = height;
    m_codecCtx->time_base = {1, 60};
    
    if (useHardware) {
        // QSV 使用 NV12 格式
        m_codecCtx->pix_fmt = AV_PIX_FMT_NV12;
    } else {
        m_codecCtx->pix_fmt = AV_PIX_FMT_YUVJ444P;
    }
    
    // 使用多线程加速（软件编码时）
    if (!useHardware) {
        m_codecCtx->thread_count = 4;
        m_codecCtx->thread_type = FF_THREAD_SLICE;  // 使用 slice 线程避免警告
    }
    
    // 固定质量
    m_codecCtx->flags |= AV_CODEC_FLAG_QSCALE;
    m_codecCtx->global_quality = FF_QP2LAMBDA * 5;
    
    if (avcodec_open2(m_codecCtx, codec, nullptr) < 0) {
        qWarning() << "Failed to open encoder, trying software fallback";
        avcodec_free_context(&m_codecCtx);
        
        // 回退到软件
        codec = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
        if (!codec) return false;
        
        m_codecCtx = avcodec_alloc_context3(codec);
        m_codecCtx->width = width;
        m_codecCtx->height = height;
        m_codecCtx->time_base = {1, 60};
        m_codecCtx->pix_fmt = AV_PIX_FMT_YUVJ444P;
        m_codecCtx->thread_count = 4;
        m_codecCtx->thread_type = FF_THREAD_SLICE;
        m_codecCtx->flags |= AV_CODEC_FLAG_QSCALE;
        m_codecCtx->global_quality = FF_QP2LAMBDA * 5;
        
        if (avcodec_open2(m_codecCtx, codec, nullptr) < 0) {
            avcodec_free_context(&m_codecCtx);
            return false;
        }
        useHardware = false;
    }
    
    m_frame = av_frame_alloc();
    m_frame->format = m_codecCtx->pix_fmt;
    m_frame->width = width;
    m_frame->height = height;
    if (!useHardware) {
        m_frame->color_range = AVCOL_RANGE_JPEG;
    }
    av_frame_get_buffer(m_frame, 32);
    
    m_packet = av_packet_alloc();
    
    // 设置色彩空间转换
    AVPixelFormat dstFmt = useHardware ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUVJ444P;
    m_swsCtx = sws_getContext(
        width, height, AV_PIX_FMT_RGB32,
        width, height, dstFmt,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
    
    m_encoderWidth = width;
    m_encoderHeight = height;
    m_useHardware = useHardware;
    
    qDebug() << "MJPEG encoder initialized:" << width << "x" << height 
             << (useHardware ? "(Hardware)" : "(Software)");
    
    return true;
}

void JpegEncoder::cleanupEncoder()
{
    if (m_swsCtx) {
        sws_freeContext(m_swsCtx);
        m_swsCtx = nullptr;
    }
    if (m_packet) {
        av_packet_free(&m_packet);
        m_packet = nullptr;
    }
    if (m_frame) {
        av_frame_free(&m_frame);
        m_frame = nullptr;
    }
    if (m_codecCtx) {
        avcodec_free_context(&m_codecCtx);
        m_codecCtx = nullptr;
    }
    m_encoderWidth = 0;
    m_encoderHeight = 0;
}

QByteArray JpegEncoder::encodeJpeg(const QImage &image)
{
    if (image.isNull()) return QByteArray();
    
    QImage img = image;
    if (img.format() != QImage::Format_RGB32 && img.format() != QImage::Format_ARGB32) {
        img = img.convertToFormat(QImage::Format_RGB32);
    }
    
    if (!initEncoder(img.width(), img.height())) {
        // 回退到 Qt 编码
        QByteArray data;
        QBuffer buffer(&data);
        buffer.open(QIODevice::WriteOnly);
        img.save(&buffer, "JPEG", JPEG_QUALITY);
        return data;
    }
    
    // RGB -> YUV
    const uint8_t *srcData[1] = {img.constBits()};
    int srcLinesize[1] = {static_cast<int>(img.bytesPerLine())};
    
    sws_scale(m_swsCtx, srcData, srcLinesize, 0, img.height(),
              m_frame->data, m_frame->linesize);
    
    m_frame->pts = m_currentIndex.load();
    
    // 编码
    int ret = avcodec_send_frame(m_codecCtx, m_frame);
    if (ret < 0) return QByteArray();
    
    ret = avcodec_receive_packet(m_codecCtx, m_packet);
    if (ret < 0) return QByteArray();
    
    QByteArray result(reinterpret_cast<char*>(m_packet->data), m_packet->size);
    av_packet_unref(m_packet);
    
    return result;
}

void JpegEncoder::run()
{
    while (m_running) {
        Task task;
        
        {
            QMutexLocker lock(&m_mutex);
            while (m_queue.isEmpty() && m_running) {
                m_condition.wait(&m_mutex);
            }
            
            if (!m_running && m_queue.isEmpty()) {
                break;
            }
            
            task = m_queue.dequeue();
        }
        
        if (task.frame.isNull()) continue;
        
        // 编码 JPEG
        QByteArray jpeg = encodeJpeg(task.frame);
        
        if (!jpeg.isEmpty()) {
            // 存入 Ring Buffer
            m_ringBuffer->addFrame(jpeg, task.frameIndex);
            m_currentIndex = task.frameIndex;
            emit frameEncoded(task.frameIndex);
        }
    }
    
    cleanupEncoder();
}

// ============== NaluDiskWriter ==============

NaluDiskWriter::NaluDiskWriter(QObject *parent)
    : QThread(parent)
{
    start();  // 普通优先级，及时落盘
}

NaluDiskWriter::~NaluDiskWriter()
{
    stop();
    wait();
}

void NaluDiskWriter::stop()
{
    m_running = false;
    m_condition.wakeAll();
}

void NaluDiskWriter::submit(const QString &path, const QByteArray &data)
{
    if (path.isEmpty() || data.isEmpty()) return;
    QMutexLocker lock(&m_mutex);
    m_queue.enqueue({path, data, -1});
    m_condition.wakeOne();
}

void NaluDiskWriter::submitBatch(const QVector<QPair<QString, QByteArray>> &tasks, int tag)
{
    if (tasks.isEmpty()) return;
    QMutexLocker lock(&m_mutex);
    for (int i = 0; i < tasks.size(); ++i) {
        const int t = (i == tasks.size() - 1) ? tag : -1;  // 最后一帧带 tag
        m_queue.enqueue({tasks[i].first, tasks[i].second, t});
    }
    m_condition.wakeOne();
}

void NaluDiskWriter::run()
{
    while (m_running) {
        WriteTask task;
        {
            QMutexLocker lock(&m_mutex);
            while (m_queue.isEmpty() && m_running) {
                m_condition.wait(&m_mutex);
            }
            if (!m_running && m_queue.isEmpty()) break;
            task = m_queue.dequeue();
        }

        if (!task.path.isEmpty() && !task.data.isEmpty()) {
            QFile file(task.path);
            if (file.open(QIODevice::WriteOnly)) {
                file.write(task.data);
                file.close();
            }
        }

        if (task.batchTag >= 0) {
            emit batchWritten(task.batchTag);
        }
    }
}

// ============== CaptureManager ==============

CaptureManager::CaptureManager(QObject *parent)
    : QObject(parent)
    , m_settings(new QSettings("Acard", "HuanJing", this))
{
    qDebug() << "📦 CaptureManager 构造开始...";
    loadSettings();
    ensureCapturesDir();

    // §2026-07-19：帧解码专用单线程池（FIFO；单线程=天然把解码/换图节奏限到机器能力内，
    //   不再堵 QtConcurrent 全局池、不再多线程抢 m_decodeMutex）
    m_decodePool.setMaxThreadCount(1);

    // 后台 NALU 落盘线程（跨线程信号自动走 QueuedConnection 回到主线程）
    m_diskWriter = new NaluDiskWriter(this);
    connect(m_diskWriter, &NaluDiskWriter::batchWritten,
            this, &CaptureManager::onBatchWritten);

    qDebug() << "📦 CaptureManager 设置和目录完成";

    // 自动注册到 ImageProvider（因为通过 Loader 加载，main.cpp 的 findChild 找不到）
    if (CaptureImageProvider::instance()) {
        CaptureImageProvider::instance()->setCaptureManager(this);
        qDebug() << "CaptureManager: registered to ImageProvider";
    }
}

CaptureManager::~CaptureManager()
{
    // 解码任务捕获了 this，必须先等在飞任务结束（同 WebFrameSource §23.17 做法）
    m_decodePool.clear();
    m_decodePool.waitForDone(3000);

    if (m_diskWriter) {
        m_diskWriter->stop();  // 子对象析构时会 wait()，这里先唤醒退出
    }
    if (m_cardDetector) {
        m_cardDetector->stop();  // 停止后台推理线程并 wait()
    }
    for (auto &state : m_itemDecoders) {
        delete state.decoder;
    }
    m_itemDecoders.clear();
}

// ── AI 牌位置识别放大 ───────────────────────────────────────
void CaptureManager::setAiCardZoomEnabled(bool enabled)
{
    if (m_aiCardZoomEnabled == enabled)
        return;
    m_aiCardZoomEnabled = enabled;
    if (enabled)
        ensureCardDetector();
    emit aiCardZoomEnabledChanged();
    qDebug() << "🃏 AI牌位置放大:" << (enabled ? "开启" : "关闭");
    aiZoomLog(QString("🃏 自动放大开关: %1 (每帧独立识别：滚动到哪帧就识别哪帧)")
                  .arg(enabled ? "开启" : "关闭"));

    // 关闭时通知 QML 复位所有放大，并清掉每个 item 的每帧识别缓存
    if (!enabled) {
        for (int i = 0; i < m_items.size(); ++i) {
            m_items[i].aiFrames.clear();
            emit cardZoomCleared(i);
        }
    } else {
        // 开启时立即对当前 item 正显示的那一帧识别一次（每帧模式）
        if (m_currentItemIndex >= 0 && m_currentItemIndex < m_items.size()) {
            const int off = m_items[m_currentItemIndex].currentOffset;
            m_aiPendingCaptureItem = m_currentItemIndex;
            m_aiPendingCaptureFrame = off;
            requestCardDetect(m_currentItemIndex, off);
        }
    }
}

QVariantMap CaptureManager::aiZoomForFrame(int itemIndex, int frameOffset) const
{
    QVariantMap r;
    r["valid"] = false;
    // anchored 保留字段名以兼容 QML；每帧模式下恒为 false → 未识别帧由 QML 保持上一帧放大(keep_prev)。
    r["anchored"] = false;
    if (!m_aiCardZoomEnabled) return r;
    if (itemIndex < 0 || itemIndex >= m_items.size()) return r;
    const CaptureItem &item = m_items[itemIndex];
    if (item.aiDisabled) return r;                       // §19 该格被标记识别失败 → 不放大

    auto it = item.aiFrames.constFind(frameOffset);
    if (it == item.aiFrames.constEnd() || !it.value().valid)
        return r;                                        // 该帧尚未识别/未检出 → keep_prev

    const AiFrameZoom &z = it.value();
    r["valid"] = true;
    r["zoom"]  = z.zoom;
    // §26-② 旋转错位修复：cx/cy 存的是「识别那一刻旋转角」空间的坐标；用户切旋转后
    // 帧图按新角度重新解码显示，这里把坐标旋转到当前空间（δ=顺时针补转角，归一化坐标系）。
    double cx = z.cx, cy = z.cy;
    const int delta = ((m_videoRotation - z.rotation) % 360 + 360) % 360;
    if (delta == 90)       { const double t = cx; cx = 1.0 - cy; cy = t; }
    else if (delta == 180) { cx = 1.0 - cx; cy = 1.0 - cy; }
    else if (delta == 270) { const double t = cx; cx = cy; cy = 1.0 - t; }
    r["cx"]    = cx;
    r["cy"]    = cy;
    return r;
}

void CaptureManager::ensureCardDetector()
{
    if (m_cardDetector)
        return;

    m_cardDetector = new CardDetector(this);
    connect(m_cardDetector, &CardDetector::detected,
            this, &CaptureManager::onCardDetected);

    // 截图刚完成时事件帧可能还没解码好，等它解码就绪(frameImageReady)再触发一次检测
    connect(this, &CaptureManager::frameImageReady, this,
            [this](int itemIndex, int frameOffset) {
        if (!m_aiCardZoomEnabled) return;
        if (m_aiPendingCaptureItem == itemIndex && m_aiPendingCaptureFrame == frameOffset) {
            m_aiPendingCaptureItem = -1;
            m_aiPendingCaptureFrame = -1;
            requestCardDetect(itemIndex, frameOffset);
        }
    });

    const QString modelPath = QCoreApplication::applicationDirPath() + "/models/cardYolov8.onnx";
    if (m_cardDetector->loadModel(modelPath)) {
        m_cardDetector->start();
    } else {
        qWarning() << "🃏 AI模型加载失败，AI放大不可用:" << modelPath;
    }

    // 滚动切帧防抖：连续滚动只对停下那帧推理
    m_aiDebounceTimer = new QTimer(this);
    m_aiDebounceTimer->setSingleShot(true);
    m_aiDebounceTimer->setInterval(80);
    connect(m_aiDebounceTimer, &QTimer::timeout, this, [this]() {
        if (m_aiPendingItem >= 0)
            requestCardDetect(m_aiPendingItem, m_aiPendingFrame);
    });
}

void CaptureManager::requestCardDetect(int itemIndex, int frameOffset, int attempt)
{
    if (!m_aiCardZoomEnabled)
        return;
    if (!m_cardDetector || !m_cardDetector->isReady()) {
        aiZoomLog(QString("⛔ 跳过识别: 检测器未就绪(模型未加载?) itemIndex=%1 frameOffset=%2")
                      .arg(itemIndex).arg(frameOffset));
        return;
    }
    if (itemIndex < 0 || itemIndex >= m_items.size())
        return;

    // 只处理"这一张"：取当前帧 QImage（已有内存/磁盘解码与缓存），深拷贝交给后台线程
    QImage img = getFrameImage(itemIndex, frameOffset);
    if (img.isNull()) {
        aiZoomLog(QString("⛔ 取帧图像为空(未解码就绪) itemIndex=%1 frameOffset=%2 第%3次尝试")
                      .arg(itemIndex).arg(frameOffset).arg(attempt + 1));
        // 重挂 pending：frameImageReady(该帧解码就绪) 到达时会再触发一次识别
        m_aiPendingCaptureItem = itemIndex;
        m_aiPendingCaptureFrame = frameOffset;
        // ⭐ 限次定时重试兜底：截图瞬间事件帧可能还没落盘，首次解码任务会在文件写入前
        //   抢跑失败（decodeFromDisk 返回空 → 不发 frameImageReady），而 onBatchWritten 的
        //   补解码又可能因同 key 任务仍在飞被 scheduleFrameDecode 静默丢弃 → 该格识别
        //   永远不触发（= "同一位置偶尔 1 张识别不了"的逻辑空窗）。这里不依赖任何信号，
        //   每 150ms 主动重试一次（getFrameImage 每次都会重新调度解码），最多 ~1.8s。
        static constexpr int MAX_DETECT_ATTEMPTS = 12;
        if (attempt < MAX_DETECT_ATTEMPTS) {
            QTimer::singleShot(150, this, [this, itemIndex, frameOffset, attempt]() {
                // pending 已被清（frameImageReady 已补触发）或被新截图顶掉 → 不再重试
                if (m_aiPendingCaptureItem == itemIndex && m_aiPendingCaptureFrame == frameOffset)
                    requestCardDetect(itemIndex, frameOffset, attempt + 1);
            });
        } else {
            aiZoomLog(QString("🛑 放弃识别: 重试%1次后取帧仍为空(解码/落盘异常) itemIndex=%2 frameOffset=%3")
                          .arg(MAX_DETECT_ATTEMPTS).arg(itemIndex).arg(frameOffset));
        }
        return;
    }
    // 提交成功 → 清 pending，避免 frameImageReady 再补触发一次重复推理
    if (m_aiPendingCaptureItem == itemIndex && m_aiPendingCaptureFrame == frameOffset) {
        m_aiPendingCaptureItem = -1;
        m_aiPendingCaptureFrame = -1;
    }
    aiZoomLog(QString("📤 提交识别: itemIndex=%1 frameOffset=%2 图像=%3x%4%5")
                  .arg(itemIndex).arg(frameOffset).arg(img.width()).arg(img.height())
                  .arg(attempt > 0 ? QString(" (第%1次尝试才取到帧)").arg(attempt + 1) : QString()));
    m_cardDetector->submit(itemIndex, frameOffset, img);
}

void CaptureManager::onCardDetected(int itemIndex, int frameOffset, CardBox box, int origW, int origH)
{
    if (!m_aiCardZoomEnabled) {
        aiZoomLog(QString("⚠️ 识别结果被丢弃: AI已关闭 itemIndex=%1 frameOffset=%2").arg(itemIndex).arg(frameOffset));
        return;
    }
    if (itemIndex < 0 || itemIndex >= m_items.size()) {
        // item 在推理期间被删除/清空 → 结果无处安放（若频繁出现=索引漂移问题）
        aiZoomLog(QString("⚠️ 识别结果被丢弃: item已不存在 itemIndex=%1 (当前共%2格) frameOffset=%3")
                      .arg(itemIndex).arg(m_items.size()).arg(frameOffset));
        return;
    }

    CaptureItem &item = m_items[itemIndex];

    // §19：该格被用户拖动标记为识别失败 → 忽略后续所有识别结果
    if (item.aiDisabled) {
        aiZoomLog(QString("⚠️ 识别结果被丢弃: 该格已标记识别失败 itemIndex=%1 frameOffset=%2").arg(itemIndex).arg(frameOffset));
        return;
    }

    // 该帧未识别到牌 → keep_prev：不改动该帧显示（保持上一帧放大），也不缓存结果。
    if (!box.valid || origW <= 0 || origH <= 0) {
        // conf 现在=全体候选最高分（含低于阈值 0.5 的）：
        //   conf≈0.4x = 模型临界抖动(差一点过阈值，属模型问题，可考虑降阈值/补训练)
        //   conf≈0.0x = 该帧画面确实没识别到牌(取错帧/画面异常)
        aiZoomLog(QString("❌ 识别失败: itemIndex=%1 frameOffset=%2 原因=%3 (最高conf=%4 阈值=0.5 原图=%5x%6 推理耗时=%7ms) → 保持上一帧放大")
                      .arg(itemIndex).arg(frameOffset)
                      .arg(!box.valid ? "未检出牌(全部候选低于阈值)" : "原图尺寸无效")
                      .arg(QString::number(box.confidence, 'f', 3))
                      .arg(origW).arg(origH).arg(box.inferMs));
        return;
    }

    // 640 空间牌中心 → 原图像素 → 归一化(0~1)，与显示控件尺寸解耦
    const double sx = double(origW) / 640.0;
    const double sy = double(origH) / 640.0;
    const double cardCx = (box.x + box.w / 2.0) * sx;
    const double cardCy = (box.y + box.h / 2.0) * sy;
    double nx = cardCx / origW;
    double ny = cardCy / origH;
    nx = qBound(0.0, nx, 1.0);
    ny = qBound(0.0, ny, 1.0);

    // ── 每帧独立：把该帧的识别结果缓存到 aiFrames[frameOffset] ──
    AiFrameZoom z;
    z.valid = true;
    z.zoom = m_aiZoomScale;
    z.cx = nx;
    z.cy = ny;
    z.rotation = m_videoRotation;  // §26-②：坐标属于当前旋转空间，记录供切旋转后换算
    item.aiFrames.insert(frameOffset, z);

    aiZoomLog(QString("✅ 识别成功: itemIndex=%1 frameOffset=%2 conf=%3 候选数=%4 推理耗时=%5ms 牌中心(归一化)=(%6,%7) 放大=%8x 旋转=%9°")
                  .arg(itemIndex).arg(frameOffset)
                  .arg(QString::number(box.confidence, 'f', 3))
                  .arg(box.candidates).arg(box.inferMs)
                  .arg(QString::number(nx, 'f', 3)).arg(QString::number(ny, 'f', 3))
                  .arg(QString::number(m_aiZoomScale, 'f', 1))
                  .arg(m_videoRotation));

    // 只对当前正显示的那一帧立即放大（识别的是哪帧、结果就用在哪帧）
    if (item.currentOffset == frameOffset)
        emit cardZoomReady(itemIndex, frameOffset, m_aiZoomScale, nx, ny);
}

void CaptureManager::ensureCapturesDir()
{
    // 帧文件由 GpuJpegEncoder 管理在 captures/frames/
    // CaptureManager 不再需要单独的目录
    m_capturesDir = QCoreApplication::applicationDirPath() + "/captures";
}

void CaptureManager::loadSettings()
{
    m_gridRows = m_settings->value("capture/gridRows", DEFAULT_GRID_ROWS).toInt();
    m_gridCols = m_settings->value("capture/gridCols", DEFAULT_GRID_COLS).toInt();
    m_isHorizontalLayout = m_settings->value("capture/horizontalLayout", true).toBool();
    m_preFrameCount = m_settings->value("capture/preFrames", DEFAULT_PRE_FRAMES).toInt();
    m_postFrameCount = m_settings->value("capture/postFrames", DEFAULT_POST_FRAMES).toInt();
    
    m_gridRows = qBound(1, m_gridRows, MAX_GRID_SIZE);
    m_gridCols = qBound(1, m_gridCols, MAX_GRID_SIZE);
    m_preFrameCount = qBound(10, m_preFrameCount, MAX_PRE_POST_FRAMES);
    m_postFrameCount = qBound(10, m_postFrameCount, MAX_PRE_POST_FRAMES);

    // 相机设定
    m_brightness = m_settings->value("camera/brightness", DEFAULT_BRIGHTNESS).toDouble();
    m_contrast = m_settings->value("camera/contrast", DEFAULT_CONTRAST).toDouble();
    m_saturation = m_settings->value("camera/saturation", DEFAULT_SATURATION).toDouble();
    m_hue = m_settings->value("camera/hue", DEFAULT_HUE).toDouble();
    m_gamma = m_settings->value("camera/gamma", DEFAULT_GAMMA).toDouble();
    m_exposure = m_settings->value("camera/exposure", DEFAULT_EXPOSURE).toDouble();
    
    // 范围限制
    m_brightness = qBound(-1.0, m_brightness, 1.0);
    m_contrast = qBound(0.0, m_contrast, 2.0);
    m_saturation = qBound(0.0, m_saturation, 2.0);
    m_hue = qBound(-1.0, m_hue, 1.0);
    m_gamma = qBound(0.01, m_gamma, 10.0);
    // 曝光值存储的是0-100百分比
    m_exposure = qBound(0.0, m_exposure, 100.0);
    
    // ★ 根据曝光值计算联动参数（启动时必须执行）
    // ⚠️ 亮度、色调不再联动，使用独立保存的值
    double slider = m_exposure;  // 0-100
    // m_brightness 不再联动，保持从配置文件读取的值
    
    // ★ 饱和度线性公式：20→1.10, 100→1.35
    m_saturation = 1.0375 + 0.003125 * slider;
    
    // ★ 对比度线性公式：20→1.10, 100→1.35
    m_contrast = 1.0375 + 0.003125 * slider;
    
    // m_hue 不再联动，保持从配置文件读取的值
    
    // ★ 伽马线性公式：20→1.08, 100→1.35
    m_gamma = 1.0125 + 0.003375 * slider;
    
    // 范围保护
    // m_brightness 保持独立设置的值
    m_saturation = qBound(1.0, m_saturation, 1.35);   // 饱和度范围
    m_contrast = qBound(1.0, m_contrast, 1.35);       // 对比度范围
    // m_hue 已在上面 qBound 过，不需要重复
    m_gamma = qBound(1.0, m_gamma, 1.35);             // 伽马范围
    
    qDebug() << "[CaptureManager] loadSettings: exposure =" << m_exposure << "%"
             << "→ 联动: 饱和度=" << m_saturation << ", 对比度=" << m_contrast << ", 伽马=" << m_gamma
             << " | 独立: 亮度=" << m_brightness << ", 色调=" << m_hue;
    
    // 通知 QML 设置已加载
    emit cameraSettingsChanged();
}

void CaptureManager::saveSettings()
{
    m_settings->setValue("capture/gridRows", m_gridRows);
    m_settings->setValue("capture/gridCols", m_gridCols);
    m_settings->setValue("capture/horizontalLayout", m_isHorizontalLayout);
    m_settings->setValue("capture/preFrames", m_preFrameCount);
    m_settings->setValue("capture/postFrames", m_postFrameCount);
    
    // 相机设定
    m_settings->setValue("camera/brightness", m_brightness);
    m_settings->setValue("camera/contrast", m_contrast);
    m_settings->setValue("camera/saturation", m_saturation);
    m_settings->setValue("camera/hue", m_hue);
    m_settings->setValue("camera/gamma", m_gamma);
    m_settings->setValue("camera/exposure", m_exposure);
    
    // 立即写入磁盘
    m_settings->sync();
    
    qDebug() << "[CaptureManager] saveSettings: exposure =" << m_exposure;
}

void CaptureManager::setGridRows(int rows)
{
    rows = qBound(1, rows, MAX_GRID_SIZE);
    if (m_gridRows != rows) {
        m_gridRows = rows;
        saveSettings();
        emit gridSettingsChanged();
    }
}

void CaptureManager::setGridCols(int cols)
{
    cols = qBound(1, cols, MAX_GRID_SIZE);
    if (m_gridCols != cols) {
        m_gridCols = cols;
        saveSettings();
        emit gridSettingsChanged();
    }
}

void CaptureManager::setIsHorizontalLayout(bool horizontal)
{
    if (m_isHorizontalLayout != horizontal) {
        m_isHorizontalLayout = horizontal;
        saveSettings();
        emit gridSettingsChanged();
        qDebug() << "Grid layout:" << (horizontal ? "横向(行优先)" : "纵向(列优先)");
    }
}

int CaptureManager::getGridRow(int index) const
{
    if (m_isHorizontalLayout) {
        // 横向（行优先）：从左到右填满一行，再填下一行
        return index / m_gridCols;
    } else {
        // 纵向（列优先）：从上到下填满一列，再填下一列
        return index % m_gridRows;
    }
}

int CaptureManager::getGridCol(int index) const
{
    if (m_isHorizontalLayout) {
        // 横向（行优先）
        return index % m_gridCols;
    } else {
        // 纵向（列优先）
        return index / m_gridRows;
    }
}

void CaptureManager::setPreFrameCount(int count)
{
    count = qBound(10, count, MAX_PRE_POST_FRAMES);  // 最小值 10
    if (m_preFrameCount != count) {
        m_preFrameCount = count;
        saveSettings();
        emit captureSettingsChanged();
    }
}

void CaptureManager::setPostFrameCount(int count)
{
    count = qBound(10, count, MAX_PRE_POST_FRAMES);  // 最小值 10
    if (m_postFrameCount != count) {
        m_postFrameCount = count;
        saveSettings();
        emit captureSettingsChanged();
    }
}

void CaptureManager::setCurrentItemIndex(int index)
{
    if (m_currentItemIndex != index) {
        m_currentItemIndex = index;
        emit currentItemChanged();
    }
}

void CaptureManager::setGpuPipeline(GpuPipeline *pipeline)
{
    if (m_gpuPipeline != pipeline) {
        m_gpuPipeline = pipeline;
        // 同步已加载的颜色参数到 JPEG 编码器
        syncColorToJpegEncoder();
        emit gpuPipelineChanged();
        qDebug() << "CaptureManager: GpuPipeline set, color params synced";
    }
}

void CaptureManager::setGstPlayer(GstPlayer *player)
{
    // QML 默认绑定走这里（GStreamer 帧源）；统一委托给 setFrameSource。
    setFrameSource(player);
}

void CaptureManager::setFrameSource(IFrameSource *source)
{
    if (m_frameSource == source) return;

    // ⭐ 信号统一用 SIGNAL/SLOT 宏经 asQObject() 连接：GstPlayer 与 WebFrameSource
    //   都声明同名信号 h264FrameStored(qint64)，接口层无需知道具体类型。
    if (m_frameSource) {
        disconnect(m_frameSource->asQObject(), SIGNAL(h264FrameStored(qint64)),
                   this, SLOT(onFrameEncoded(qint64)));
    }

    m_frameSource = source;

    if (m_frameSource) {
        connect(m_frameSource->asQObject(), SIGNAL(h264FrameStored(qint64)),
                this, SLOT(onFrameEncoded(qint64)), Qt::QueuedConnection);
    }
    qDebug() << "CaptureManager: frame source ready, format="
             << (m_frameSource && m_frameSource->frameFormat() == IFrameSource::FrameFormat::JPEG ? "JPEG" : "H264");

    emit gstPlayerChanged();
}

void CaptureManager::setFrameSourceObject(QObject *source)
{
    IFrameSource *fs = nullptr;
    if (GstPlayer *gst = qobject_cast<GstPlayer*>(source)) {
        fs = gst;
    } else if (WebFrameSource *web = qobject_cast<WebFrameSource*>(source)) {
        fs = web;
    }
    setFrameSource(fs);
}

void CaptureManager::onFrameReceived(const QImage &frame, qint64 frameIndex)
{
    Q_UNUSED(frame);
    Q_UNUSED(frameIndex);
}

void CaptureManager::onFrameIndexReady(qint64 frameIndex)
{
    // 更新当前帧索引
    m_currentFrameIdx = frameIndex;
    
    // 检查待完成的抓拍（等待后续帧）
    checkPendingCaptures(frameIndex);
}

void CaptureManager::onFrameEncoded(qint64 index)
{
    checkPendingCaptures(index);
}

void CaptureManager::checkPendingCaptures(qint64 frameIndex)
{
    QMutexLocker lock(&m_mutex);

    for (int i = m_pendingCaptures.size() - 1; i >= 0; i--) {
        PendingCapture &pending = m_pendingCaptures[i];

        if (pending.itemIndex < 0 || pending.itemIndex >= m_items.size()) {
            m_pendingCaptures.removeAt(i);
            continue;
        }

        if (frameIndex >= pending.targetEndIndex) {
            m_pendingCaptures.removeAt(i);
        }
    }
}

void CaptureManager::capture()
{
    // ⭐ 2026-07-19：截图节流（按住空格 = 键盘自动重复 ~30 次/s，低端机主线程被
    //   item 创建+grid 重排+解码+纹理上传顶死 → 实时流卡）。8 张/s 上限，快于人手连点。
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    if (m_lastCaptureMs > 0 && nowMs - m_lastCaptureMs < MIN_CAPTURE_INTERVAL_MS) {
        captureDebugLog("CAP", QString("capture throttled (%1ms < %2ms)")
            .arg(nowMs - m_lastCaptureMs).arg(MIN_CAPTURE_INTERVAL_MS));
        return;
    }
    m_lastCaptureMs = nowMs;

    qint64 eventIndex = -1;
    
    qDebug() << "📷 Capture: slowMotionActive=" << m_slowMotionActive
             << ", slowMotionPlayer=" << (m_slowMotionPlayer ? "有效" : "NULL");

    if (m_frameSource) {
        qDebug() << "📷 Capture: frame newest=" << m_frameSource->newestH264Frame()
                 << ", oldest=" << m_frameSource->oldestH264Frame()
                 << ", dir=" << m_frameSource->h264FrameDirectory();
    }
    
    // 根据慢放模式选择事件帧来源
    if (m_slowMotionActive && m_slowMotionPlayer) {
        eventIndex = m_slowMotionPlayer->currentGlobalFrameIndex();
        qDebug() << "📷 Capture (SlowMotion): eventIndex=" << eventIndex
                 << "currentFrame=" << m_slowMotionPlayer->currentFrame()
                 << "startIndex=" << m_slowMotionPlayer->startIndex()
                 << "endIndex=" << m_slowMotionPlayer->endIndex()
                 << "recordedFrames=" << m_slowMotionPlayer->recordedFrames();
    } else {
        // 实时流模式：从独立 H.264 帧文件索引获取最新帧
        if (m_frameSource) {
            qint64 newestIdx = m_frameSource->newestH264Frame();
            int queueDepth = m_frameSource->bufferSize();
            qint64 oldestIdx = m_frameSource->oldestH264Frame();
            if (newestIdx < 0 || oldestIdx < 0) {
                eventIndex = -1;
            } else {
                eventIndex = newestIdx - queueDepth;
                eventIndex = qMax(oldestIdx, eventIndex);
            }

            qDebug() << "📷 Capture (H264File): newest=" << newestIdx
                     << "队列=" << queueDepth
                     << "eventIndex=" << eventIndex;
        } else if (m_gpuPipeline) {
            eventIndex = m_gpuPipeline->newestFrame();
        }
    }
    
    if (eventIndex < 1) {
        qDebug() << "❌ Capture: no frames yet (eventIndex=" << eventIndex << ")";
        return;
    }

    // ⭐ 连续截图卡实时流修复（2026-07-19）：去掉「截图前发 PLI」。
    //   这是旧方案（截图直存流上 NALU，需 IDR 才能起解）的遗留——改成「解码后重编码、
    //   每帧独立 IDR 的 .h264 文件」后，截图/慢放解码完全不依赖网络流关键帧。
    //   而 PLI 节流窗仅 200ms，连点截图会逼推流端每 200ms 出一个大 IDR：
    //   码率/包突发 → jitterbuffer 抖动 → 实时流一顿一顿（且影响所有观看端）。
    //   花屏场景的 PLI 自愈仍由 gstplayer 的坏帧/无帧检测路径负责，与截图无关。

    if (m_items.size() >= MAX_ITEMS) {
        removeOldest();
    }
    
    // 计算索引范围
    qint64 rawStartIndex = eventIndex - m_preFrameCount;
    qint64 rawEndIndex = eventIndex + m_postFrameCount;
    qint64 startIndex = qMax(0LL, rawStartIndex);
    qint64 endIndex = rawEndIndex;
    
    qDebug() << "📷 Capture: eventIndex=" << eventIndex 
             << "preCount=" << m_preFrameCount << "postCount=" << m_postFrameCount
             << "rawRange=" << rawStartIndex << "-" << rawEndIndex;
    
    // 确保范围在可用帧内
    qint64 oldestAvailable = 0;

    if (m_slowMotionActive && m_slowMotionPlayer) {
        oldestAvailable = m_slowMotionPlayer->startIndex();
        startIndex = qMax(startIndex, oldestAvailable);
        // 跟实时流同步时不在慢放尾部压 endIndex，否则 endIndex==eventIndex，后抓拍帧无法滚动
        if (!m_slowMotionPlayer->followLive()) {
            qint64 newestAvailable = m_slowMotionPlayer->endIndex();
            qDebug() << "📷 Capture (SlowMotion): 回放范围" << oldestAvailable << "-" << newestAvailable;
            endIndex = qMin(endIndex, newestAvailable);
        } else {
            qDebug() << "📷 Capture (SlowMotion): followLive，endIndex=" << endIndex << "(不压到慢放 endIndex)";
        }
    } else if (m_frameSource) {
        oldestAvailable = m_frameSource->oldestH264Frame();
        startIndex = qMax(startIndex, oldestAvailable);
    } else if (m_gpuPipeline) {
        oldestAvailable = m_gpuPipeline->oldestFrame();
        startIndex = qMax(startIndex, oldestAvailable);
    }
    
    qDebug() << "📷 Capture: 最终范围" << startIndex << "-" << endIndex 
             << "总帧数=" << (endIndex - startIndex + 1);
    
    CaptureItem item;
    item.id = m_nextId++;
    item.startIndex = startIndex;
    item.eventIndex = eventIndex;
    item.endIndex = endIndex;
    item.currentOffset = item.eventOffset();
    item.timestamp = QDateTime::currentMSecsSinceEpoch();

    item.naluDir.clear();
    item.savedFrameCount = item.totalFrames();
    if (m_frameSource) {
        item.h264ValidRangeId = m_frameSource->registerH264ValidRange(startIndex, endIndex);
    }

    // ⭐ 连续截图卡实时流修复（2026-07-19）：去掉 liveSnapshot 抓取。
    //   原来每次截图在主线程做整帧 BGRA 拷贝（1080p≈8MB、4K≈33MB）+ 旋转时再 transformed
    //   一次，但 liveSnapshot 自「独立全-I .h264 文件」重构后全工程无任何读取方（死代码）；
    //   除每击 5~50ms 主线程开销外，每个 item 还常驻一张全分辨率 QImage——连拍几十张
    //   即数百 MB~GB 级内存，内存压力反过来造成整机停顿。缩略图本就走 image://capture
    //   的异步解码路径，不需要这份快照。

    m_items.append(item);
    int newIndex = m_items.size() - 1;

    qDebug() << "Capture: item" << item.id
             << "range:" << startIndex << "-" << endIndex
             << "source:" << (m_frameSource ? m_frameSource->h264FrameDirectory() : QString())
             << "frames:" << item.totalFrames();

    emit countChanged();
    emit itemAdded(newIndex);
    emit captureComplete(newIndex);
    {
        QMutexLocker lock(&m_decodeMutex);
        m_wantedOffset[newIndex] = item.currentOffset;
    }
    scheduleFrameDecode(newIndex, item.currentOffset);

    // ⭐ AI 牌位置识别：对截图的事件帧识别一次（异步、后台线程，不卡实时流）
    //   事件帧此刻可能还没解码好 → 标记 pending，等 frameImageReady 再触发；
    //   若已缓存则 requestCardDetect 立即就能拿到图直接识别。
    if (m_aiCardZoomEnabled) {
        // 链路起点埋点：每次截图一行，与后续 提交识别/识别成功/识别失败 对账，
        // 哪一张"消失"了（截图有、提交没有）一眼可见
        aiZoomLog(QString("📸 截图: itemIndex=%1 id=%2 eventOffset=%3 总帧数=%4 事件帧已缓存=%5")
                      .arg(newIndex).arg(item.id).arg(item.currentOffset)
                      .arg(item.totalFrames())
                      .arg(isFrameCached(newIndex, item.currentOffset) ? "是" : "否(等解码)"));
        m_aiPendingCaptureItem = newIndex;
        m_aiPendingCaptureFrame = item.currentOffset;
        requestCardDetect(newIndex, item.currentOffset);
    }
}

void CaptureManager::onBatchWritten(int tag)
{
    // tag == CaptureItem.id，后台落盘完成 → 文件已就绪，触发可见帧解码刷新
    int itemIndex = -1;
    int currentOffset = 0;
    int totalFrames = 0;
    {
        QMutexLocker lock(&m_mutex);
        for (int i = 0; i < m_items.size(); ++i) {
            if (m_items[i].id == tag) {
                itemIndex = i;
                currentOffset = m_items[i].currentOffset;
                totalFrames = m_items[i].totalFrames();
                break;
            }
        }
    }
    if (itemIndex < 0) return;

    scheduleFrameDecode(itemIndex, currentOffset);
    for (int d = -3; d <= 3; ++d) {
        if (d == 0) continue;
        const int off = currentOffset + d;
        if (off >= 0 && off < totalFrames) {
            scheduleFrameDecode(itemIndex, off);
        }
    }
}


QByteArray CaptureManager::readNaluFile(const QString &dir, int frameOffset)
{
    QString path = dir + QString("/%1.nalu").arg(frameOffset, 6, 10, QChar('0'));
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return QByteArray();
    return file.readAll();
}

QImage CaptureManager::decodeFromDisk(int itemIndex, int frameOffset)
{
    CaptureDebugScope scope("CAP", QString("decodeFromDisk item=%1 frame=%2").arg(itemIndex).arg(frameOffset), 80);

    const int gen = m_clearGeneration.load(std::memory_order_acquire);

    qint64 globalIndex = -1;
    {
        QMutexLocker lock(&m_mutex);
        if (itemIndex < 0 || itemIndex >= m_items.size()) return QImage();
        const CaptureItem &item = m_items[itemIndex];
        if (frameOffset < 0 || frameOffset >= item.totalFrames()) return QImage();
        globalIndex = item.startIndex + frameOffset;
    }

    if (m_clearGeneration.load(std::memory_order_acquire) != gen) return QImage();
    if (!m_frameSource) return QImage();

    QByteArray data = m_frameSource->readH264Frame(globalIndex);
    if (data.isEmpty()) {
        captureDebugLog("CAP", QString("decodeFromDisk file MISSING item=%1 frame=%2 global=%3")
            .arg(itemIndex).arg(frameOffset).arg(globalIndex));
        return QImage();
    }

    // ⭐ 2026-07-24 主线程冻结修复（freeze_diag 实锤）：此前从这里到函数结尾整段抱着
    //   m_decodeMutex 做 H264 软解/建 GStreamer 管线/整帧旋转，快速拖进度条/Ctrl滚帧时
    //   解码线程几乎全程持锁，主线程四个入口（getFrameImage/scheduleFrameDecode/
    //   isFrameCached/gotoFrame 写 m_wantedOffset）抢锁被饿 1~5s → UI 与实时流一起冻。
    //   改为「短锁取走解码器实例 → 锁外干重活 → 短锁归还」，m_decodeMutex 只护轻量结构。
    //   安全性：解码池是单线程（同一时刻最多一个 checkout）；主线程 removeItem/clearAll
    //   在 checkout 期间看不到该实例（map 里已置空），不会 double-delete；归还时若条目
    //   已被删/清空则由本线程自行销毁，过期解码结果由调用方的 generation 校验丢弃。
    QImage result;
    // ⭐ 按帧源格式分支：网页内核(JPEG)直接 QImage 解，GStreamer(H264) 走软解码器。
    if (m_frameSource->frameFormat() == IFrameSource::FrameFormat::JPEG) {
        // JPEG 解码不碰任何共享状态，全程锁外
        if (!result.loadFromData(data, "JPEG")) {
            captureDebugLog("CAP", QString("decodeFromDisk JPEG FAIL item=%1 frame=%2 global=%3 bytes=%4")
                .arg(itemIndex).arg(frameOffset).arg(globalIndex).arg(data.size()));
            return QImage();
        }
    } else {
        // checkout：短锁取走该 item 的解码器实例
        GstCaptureDecoder *decoder = nullptr;
        {
            QMutexLocker decodeLock(&m_decodeMutex);
            if (m_clearGeneration.load(std::memory_order_acquire) != gen) return QImage();
            ItemDecodeState &state = m_itemDecoders[itemIndex];
            decoder = state.decoder;
            state.decoder = nullptr;
        }
        if (!decoder) {
            decoder = new GstCaptureDecoder();  // 建管线是重活，锁外做
            captureDebugLog("CAP", QString("decodeFromDisk create decoder item=%1").arg(itemIndex));
        }

        decoder->flush();
        result = decoder->decodeNalu(data);

        // checkin：item 还在就归还实例；期间被 removeItem/clearAll 删掉则自行销毁
        bool returned = false;
        {
            QMutexLocker decodeLock(&m_decodeMutex);
            auto decIt = m_itemDecoders.find(itemIndex);
            if (decIt != m_itemDecoders.end() && !decIt.value().decoder) {
                decIt.value().decoder = decoder;
                decIt.value().lastOffset = result.isNull() ? -1 : frameOffset;
                returned = true;
            }
        }
        if (!returned) {
            delete decoder;  // 销毁 GStreamer 管线同样是重活，锁外做
            captureDebugLog("CAP", QString("decodeFromDisk item GONE mid-decode item=%1 frame=%2")
                .arg(itemIndex).arg(frameOffset));
            return QImage();
        }
        if (result.isNull()) {
            captureDebugLog("CAP", QString("decodeFromDisk H264 FAIL item=%1 frame=%2 global=%3 %4")
                .arg(itemIndex).arg(frameOffset).arg(globalIndex).arg(captureDebugNaluPreview(data)));
            return QImage();
        }
    }

    if (m_videoRotation != 0) {
        QTransform t;
        t.rotate(m_videoRotation);
        result = result.transformed(t, Qt::FastTransformation);  // 整帧旋转也在锁外
    }

    captureDebugLog("CAP", QString("decodeFromDisk OK item=%1 frame=%2 size=%3x%4")
        .arg(itemIndex).arg(frameOffset).arg(result.width()).arg(result.height()));
    return result;
}

void CaptureManager::evictFrameCache()
{
    // ⭐ 2026-07-19：张数上限之外加字节预算（全分辨率帧 4K≈33MB/张，纯按张数封顶
    //   会吃掉数 GB 内存，低端机换页→整机停顿→实时流卡）
    while (m_frameCache.size() > 1
           && (m_frameCache.size() >= MAX_FRAME_CACHE || m_frameCacheBytes > MAX_FRAME_CACHE_BYTES)) {
        qint64 lruKey = -1;
        qint64 lruOrder = INT64_MAX;
        for (auto it = m_frameCache.begin(); it != m_frameCache.end(); ++it) {
            if (it.value().accessOrder < lruOrder) {
                lruOrder = it.value().accessOrder;
                lruKey = it.key();
            }
        }
        if (lruKey >= 0) {
            m_frameCacheBytes -= m_frameCache[lruKey].image.sizeInBytes();
            m_frameCache.remove(lruKey);
        } else {
            break;
        }
    }
}

void CaptureManager::clearAll()
{
    m_clearGeneration.fetch_add(1, std::memory_order_release);

    QMutexLocker lock(&m_mutex);
    m_pendingCaptures.clear();

    QStringList dirsToDelete;
    QList<int> rangesToRelease;
    for (int i = 0; i < m_items.size(); i++) {
        if (!m_items[i].naluDir.isEmpty()) {
            dirsToDelete.append(m_items[i].naluDir);
        }
        if (m_items[i].h264ValidRangeId >= 0) {
            rangesToRelease.append(m_items[i].h264ValidRangeId);
        }
    }

    m_items.clear();
    m_cachedItemIndex = -1;
    m_cachedImage = QImage();
    {
        QMutexLocker decodeLock(&m_decodeMutex);
        m_frameCache.clear();
        m_frameCacheBytes = 0;
        m_frameCacheCounter = 0;
        m_pendingDecodes.clear();
        m_wantedOffset.clear();
        for (auto &state : m_itemDecoders) delete state.decoder;
        m_itemDecoders.clear();
    }

    emit countChanged();
    setCurrentItemIndex(-1);

    IFrameSource *player = m_frameSource;
    for (int rangeId : rangesToRelease) {
        if (player) player->unregisterH264ValidRange(rangeId);
    }

    if (!dirsToDelete.isEmpty()) {
        (void)QtConcurrent::run([dirsToDelete]() {
            for (const QString &dir : dirsToDelete) {
                QDir(dir).removeRecursively();
            }
        });
    }
}

void CaptureManager::removeItem(int index)
{
    m_clearGeneration.fetch_add(1, std::memory_order_release);

    QMutexLocker lock(&m_mutex);
    if (index < 0 || index >= m_items.size()) return;

    {
        QMutexLocker decodeLock(&m_decodeMutex);
        auto decIt = m_itemDecoders.find(index);
        if (decIt != m_itemDecoders.end()) {
            delete decIt.value().decoder;
            m_itemDecoders.erase(decIt);
        }
        for (auto it = m_frameCache.begin(); it != m_frameCache.end(); ) {
            if (static_cast<int>(it.key() / 100000) == index) {
                m_frameCacheBytes -= it.value().image.sizeInBytes();
                it = m_frameCache.erase(it);
            } else {
                ++it;
            }
        }
        // item 索引整体前移，按旧索引记的「想看的帧」全部失效（只是预取提示，清掉即可）
        m_wantedOffset.clear();
    }

    QString dirToDelete = m_items[index].naluDir;
    int rangeToRelease = m_items[index].h264ValidRangeId;

    m_items.removeAt(index);
    m_cachedItemIndex = -1;
    m_cachedImage = QImage();

    for (auto &pending : m_pendingCaptures) {
        if (pending.itemIndex > index) {
            pending.itemIndex--;
        } else if (pending.itemIndex == index) {
            pending.itemIndex = -1;
        }
    }

    lock.unlock();
    emit itemRemoved(index);
    emit countChanged();

    if (rangeToRelease >= 0 && m_frameSource) {
        m_frameSource->unregisterH264ValidRange(rangeToRelease);
    }

    if (!dirToDelete.isEmpty()) {
        (void)QtConcurrent::run([dirToDelete]() {
            QDir(dirToDelete).removeRecursively();
        });
    }
}

void CaptureManager::removeOldest()
{
    if (m_items.isEmpty()) return;
    removeItem(0);
}

void CaptureManager::reset()
{
    clearAll();
    m_nextId = 1;
    qDebug() << "CaptureManager: reset complete";
}

int CaptureManager::getTotalFrames(int itemIndex) const
{
    if (itemIndex < 0 || itemIndex >= m_items.size()) return 0;
    return m_items[itemIndex].totalFrames();
}

int CaptureManager::getEventOffset(int itemIndex) const
{
    if (itemIndex < 0 || itemIndex >= m_items.size()) return 0;
    return m_items[itemIndex].eventOffset();
}

int CaptureManager::getCurrentOffset(int itemIndex) const
{
    if (itemIndex < 0 || itemIndex >= m_items.size()) return 0;
    return m_items[itemIndex].currentOffset;
}

bool CaptureManager::isItemReady(int itemIndex) const
{
    if (itemIndex < 0 || itemIndex >= m_items.size()) return false;
    // GPU 模式下，帧文件已经在磁盘，只要有帧就可以滚轮浏览
    // 检查是否有至少一帧
    return m_items[itemIndex].totalFrames() > 0;
}

void CaptureManager::gotoFrame(int itemIndex, int frameOffset)
{
    int totalFrames = 0;
    {
        QMutexLocker lock(&m_mutex);
        if (itemIndex < 0 || itemIndex >= m_items.size()) return;

        CaptureItem &item = m_items[itemIndex];
        totalFrames = item.totalFrames();
        frameOffset = qBound(0, frameOffset, totalFrames - 1);

        if (item.currentOffset != frameOffset) {
            item.currentOffset = frameOffset;
        }
    }

    // ⭐ 2026-07-19：登记该 item 最新想看的帧——解码队列里偏离此帧 ±DECODE_KEEP_WINDOW
    //   的陈旧任务出队时直接作废（快速滚动防积压）。
    {
        QMutexLocker lock(&m_decodeMutex);
        m_wantedOffset[itemIndex] = frameOffset;
    }

    emit frameChanged(itemIndex, frameOffset);

    scheduleFrameDecode(itemIndex, frameOffset);
    for (int d = -1; d <= 1; ++d) {
        if (d == 0) continue;
        const int off = frameOffset + d;
        if (off >= 0 && off < totalFrames) {
            scheduleFrameDecode(itemIndex, off);
        }
    }

    // ⭐ AI 牌位置放大（2026-07-06 每帧识别）：滚动到某帧就对该帧推理。
    //   已缓存过的帧无需重推（QML onCurrentFrameChanged 会直接查表应用）；
    //   未缓存的帧挂 pending + 防抖 80ms（连续滚动只识别停下那帧），停下后 requestCardDetect。
    if (m_aiCardZoomEnabled && itemIndex >= 0 && itemIndex < m_items.size()) {
        const CaptureItem &it = m_items[itemIndex];
        if (!it.aiDisabled && !it.aiFrames.contains(frameOffset)) {
            m_aiPendingItem = itemIndex;
            m_aiPendingFrame = frameOffset;
            if (m_aiDebounceTimer)
                m_aiDebounceTimer->start();
        }
    }
}

bool CaptureManager::tryGetFrameCache(int itemIndex, int frameOffset, QImage *out) const
{
    if (!out) return false;

    if (m_cachedItemIndex == itemIndex && m_cachedFrameOffset == frameOffset
        && m_cachedRotation == m_videoRotation
        && !m_cachedImage.isNull()) {
        *out = m_cachedImage;
        return true;
    }

    const qint64 key = qint64(itemIndex) * 100000 + frameOffset;
    auto cacheIt = m_frameCache.find(key);
    if (cacheIt != m_frameCache.end()) {
        *out = cacheIt.value().image;
        return true;
    }
    return false;
}

void CaptureManager::putFrameCache(int itemIndex, int frameOffset, const QImage &img)
{
    if (img.isNull()) return;

    const qint64 key = qint64(itemIndex) * 100000 + frameOffset;
    auto oldIt = m_frameCache.find(key);
    if (oldIt != m_frameCache.end()) {
        m_frameCacheBytes -= oldIt.value().image.sizeInBytes();
    }
    m_frameCache[key] = {img, ++m_frameCacheCounter};
    m_frameCacheBytes += img.sizeInBytes();
    // 先插入后逐出：新条目 accessOrder 最大，LRU 逐出永远轮不到它
    evictFrameCache();
    m_cachedItemIndex = itemIndex;
    m_cachedFrameOffset = frameOffset;
    m_cachedRotation = m_videoRotation;
    m_cachedImage = img;
}

void CaptureManager::scheduleFrameDecode(int itemIndex, int frameOffset)
{
    {
        QMutexLocker lock(&m_mutex);
        if (itemIndex < 0 || itemIndex >= m_items.size()) return;
        if (frameOffset < 0 || frameOffset >= m_items[itemIndex].totalFrames()) return;
    }

    const qint64 jobKey = qint64(itemIndex) * 1000000 + frameOffset;
    {
        QMutexLocker lock(&m_decodeMutex);
        QImage cached;
        if (tryGetFrameCache(itemIndex, frameOffset, &cached)) {
            return;
        }
        if (m_pendingDecodes.contains(jobKey)) {
            return;
        }
        m_pendingDecodes.insert(jobKey);
    }

    const int gen = m_clearGeneration.load(std::memory_order_acquire);

    // ⭐ 2026-07-19：改专用单线程池 + 出队时作废陈旧任务（见头文件 m_wantedOffset 注释）。
    //   快速滚动时积压的「早已滚过去的帧」在这里被微秒级跳过，不再全分辨率解码+换图，
    //   解码/纹理上传只跟得上机器能力，实时流（同主线程/渲染线程）不再被拖卡。
    m_decodePool.start([this, itemIndex, frameOffset, jobKey, gen]() {
        if (m_clearGeneration.load(std::memory_order_acquire) != gen) {
            QMutexLocker lock(&m_decodeMutex);
            m_pendingDecodes.remove(jobKey);
            return;
        }

        {
            QMutexLocker lock(&m_decodeMutex);
            const int wanted = m_wantedOffset.value(itemIndex, frameOffset);
            if (qAbs(frameOffset - wanted) > DECODE_KEEP_WINDOW) {
                m_pendingDecodes.remove(jobKey);
                return;   // 用户已滚到别处，此帧作废
            }
        }

        const QImage img = decodeFromDisk(itemIndex, frameOffset);
        bool shouldNotify = false;
        {
            QMutexLocker lock(&m_decodeMutex);
            m_pendingDecodes.remove(jobKey);
            // ⭐ 2026-07-24：解码期间不再持锁，removeItem/clearAll 可能已清过缓存，
            //   generation 变了的过期帧禁止回填（否则按旧索引写入=脏缓存）
            if (!img.isNull() && m_clearGeneration.load(std::memory_order_acquire) == gen) {
                putFrameCache(itemIndex, frameOffset, img);
                shouldNotify = true;
            }
        }
        if (shouldNotify) {
            QMetaObject::invokeMethod(this, [this, itemIndex, frameOffset]() {
                emit frameImageReady(itemIndex, frameOffset);
            }, Qt::QueuedConnection);
        }
    });
}

void CaptureManager::nextFrame(int itemIndex)
{
    int newOffset;
    {
        QMutexLocker lock(&m_mutex);
        if (itemIndex < 0 || itemIndex >= m_items.size()) return;
        newOffset = m_items[itemIndex].currentOffset + 1;
    }
    gotoFrame(itemIndex, newOffset);
}

void CaptureManager::prevFrame(int itemIndex)
{
    int newOffset;
    {
        QMutexLocker lock(&m_mutex);
        if (itemIndex < 0 || itemIndex >= m_items.size()) return;
        newOffset = m_items[itemIndex].currentOffset - 1;
    }
    gotoFrame(itemIndex, newOffset);
}

void CaptureManager::gotoEventFrame(int itemIndex)
{
    int eventOff;
    {
        QMutexLocker lock(&m_mutex);
        if (itemIndex < 0 || itemIndex >= m_items.size()) return;
        eventOff = m_items[itemIndex].eventOffset();
    }
    gotoFrame(itemIndex, eventOff);
}

QImage CaptureManager::getFrameImage(int itemIndex, int frameOffset)
{
    CaptureDebugScope scope("CAP", QString("getFrameImage item=%1 frame=%2").arg(itemIndex).arg(frameOffset), 80);

    if (itemIndex < 0 || itemIndex >= m_items.size()) {
        captureDebugLog("CAP", QString("getFrameImage invalid item=%1").arg(itemIndex));
        return QImage();
    }

    QImage cached;
    {
        QMutexLocker decodeLock(&m_decodeMutex);
        if (itemIndex < 0 || itemIndex >= m_items.size()) return QImage();

        if (tryGetFrameCache(itemIndex, frameOffset, &cached)) {
            auto cacheIt = m_frameCache.find(qint64(itemIndex) * 100000 + frameOffset);
            if (cacheIt != m_frameCache.end()) {
                cacheIt.value().accessOrder = ++m_frameCacheCounter;
            }
            captureDebugLog("CAP", "getFrameImage HIT cache");
            return cached;
        }
    }

    scheduleFrameDecode(itemIndex, frameOffset);

    captureDebugLog("CAP", QString("getFrameImage ASYNC pending return empty item=%1 frame=%2")
        .arg(itemIndex).arg(frameOffset));
    return QImage();
}

bool CaptureManager::isFrameCached(int itemIndex, int frameOffset)
{
    if (itemIndex < 0 || itemIndex >= m_items.size()) return false;
    QMutexLocker decodeLock(&m_decodeMutex);
    QImage tmp;
    return tryGetFrameCache(itemIndex, frameOffset, &tmp);
}

void CaptureManager::setVideoRotation(int rotation)
{
    rotation = ((rotation % 360) + 360) % 360;
    if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270) {
        rotation = 0;
    }

    if (m_videoRotation != rotation) {
        m_videoRotation = rotation;
        m_cachedImage = QImage();
        {
            QMutexLocker decodeLock(&m_decodeMutex);
            m_frameCache.clear();
            m_frameCacheBytes = 0;
            m_frameCacheCounter = 0;
        }
        emit videoRotationChanged();
    }
}

void CaptureManager::setVideoZoom(double zoom)
{
    zoom = qBound(1.0, zoom, 5.0);
    if (!qFuzzyCompare(m_videoZoom, zoom)) {
        m_videoZoom = zoom;
        m_cachedImage = QImage();  // 清除缓存
        emit videoZoomChanged();
    }
}

void CaptureManager::setVideoOffsetX(double offsetX)
{
    if (!qFuzzyCompare(m_videoOffsetX, offsetX)) {
        m_videoOffsetX = offsetX;
        m_cachedImage = QImage();
        emit videoZoomChanged();
    }
}

void CaptureManager::setVideoOffsetY(double offsetY)
{
    if (!qFuzzyCompare(m_videoOffsetY, offsetY)) {
        m_videoOffsetY = offsetY;
        m_cachedImage = QImage();
        emit videoZoomChanged();
    }
}

void CaptureManager::setDisplayWidth(double width)
{
    if (width > 0 && !qFuzzyCompare(m_displayWidth, width)) {
        m_displayWidth = width;
        m_cachedImage = QImage();
        emit videoZoomChanged();
    }
}

void CaptureManager::setDisplayHeight(double height)
{
    if (height > 0 && !qFuzzyCompare(m_displayHeight, height)) {
        m_displayHeight = height;
        m_cachedImage = QImage();
        emit videoZoomChanged();
    }
}

void CaptureManager::setSlowMotionActive(bool active)
{
    if (m_slowMotionActive != active) {
        m_slowMotionActive = active;
        qDebug() << "CaptureManager: slowMotionActive changed to" << active;
        emit slowMotionActiveChanged();
    }
}

void CaptureManager::setSlowMotionPlayer(SlowMotionPlayer* player)
{
    if (m_slowMotionPlayer != player) {
        m_slowMotionPlayer = player;
        emit slowMotionPlayerChanged();
    }
}

qint64 CaptureManager::currentFrameIndex() const
{
    if (m_frameSource) {
        return m_frameSource->newestH264Frame();
    }
    if (m_gpuPipeline) {
        return m_gpuPipeline->newestFrame();
    }
    return 0;
}

// ============ 相机设定 ============

void CaptureManager::setBrightness(double value)
{
    value = qBound(-1.0, value, 1.0);
    if (!qFuzzyCompare(m_brightness, value)) {
        m_brightness = value;
        saveSettings();
        syncColorToJpegEncoder();
        emit cameraSettingsChanged();
    }
}

void CaptureManager::setContrast(double value)
{
    value = qBound(0.0, value, 2.0);
    if (!qFuzzyCompare(m_contrast, value)) {
        m_contrast = value;
        saveSettings();
        syncColorToJpegEncoder();
        emit cameraSettingsChanged();
    }
}

void CaptureManager::setSaturation(double value)
{
    value = qBound(0.0, value, 2.0);
    if (!qFuzzyCompare(m_saturation, value)) {
        m_saturation = value;
        saveSettings();
        syncColorToJpegEncoder();
        emit cameraSettingsChanged();
    }
}

void CaptureManager::setHue(double value)
{
    value = qBound(-1.0, value, 1.0);
    if (!qFuzzyCompare(m_hue, value)) {
        m_hue = value;
        saveSettings();
        syncColorToJpegEncoder();
        emit cameraSettingsChanged();
    }
}

void CaptureManager::setGamma(double value)
{
    value = qBound(0.01, value, 10.0);
    if (!qFuzzyCompare(m_gamma, value)) {
        m_gamma = value;
        saveSettings();
        syncColorToJpegEncoder();
        emit cameraSettingsChanged();
    }
}

// 只应用曝光效果，不保存（用于滑动预览）
void CaptureManager::applyExposurePreview(double value)
{
    value = qBound(0.0, value, 100.0);
    m_exposure = value;
    
    // ⭐ 曝光值联动计算3个参数（亮度、色调不再联动）
    double slider = value;  // 0-100
    // m_brightness 不再联动，保持用户独立设置的值
    
    // ★ 饱和度线性公式：20→1.10, 100→1.35
    m_saturation = 1.0375 + 0.003125 * slider;
    
    // ★ 对比度线性公式：20→1.10, 100→1.35
    m_contrast = 1.0375 + 0.003125 * slider;
    
    // m_hue 不再联动，保持用户独立设置的值
    
    // ★ 伽马线性公式：20→1.08, 100→1.35
    m_gamma = 1.0125 + 0.003375 * slider;
    
    // 范围保护
    // m_brightness 保持独立设置的值
    m_saturation = qBound(1.0, m_saturation, 1.35);   // 饱和度范围
    m_contrast = qBound(1.0, m_contrast, 1.35);       // 对比度范围
    // m_hue 保持不变
    m_gamma = qBound(1.0, m_gamma, 1.35);             // 伽马范围
    
    // 只同步渲染到 GStreamer，不保存
    syncColorToJpegEncoder();
    emit cameraSettingsChanged();
}

void CaptureManager::setExposure(double value)
{
    // 曝光范围 0-100（百分比），与 Java 一致
    value = qBound(0.0, value, 100.0);
    if (!qFuzzyCompare(m_exposure, value)) {
        m_exposure = value;
        
        // ⭐ 曝光值联动计算3个参数（亮度、色调不再联动）
        double slider = value;  // 0-100
        // m_brightness 不再联动，保持用户独立设置的值
        
        // ★ 饱和度线性公式：20→1.10, 100→1.35
        m_saturation = 1.0375 + 0.003125 * slider;
        
        // ★ 对比度线性公式：20→1.10, 100→1.35
        m_contrast = 1.0375 + 0.003125 * slider;
        
        // m_hue 不再联动，保持用户独立设置的值
        
        // ★ 伽马线性公式：20→1.08, 100→1.35
        m_gamma = 1.0125 + 0.003375 * slider;
        
        // 范围保护
        // m_brightness 保持独立设置的值
        m_saturation = qBound(1.0, m_saturation, 1.35);   // 饱和度范围
        m_contrast = qBound(1.0, m_contrast, 1.35);       // 对比度范围
        // m_hue 保持不变
        m_gamma = qBound(1.0, m_gamma, 1.35);             // 伽马范围
        
        saveSettings();
        syncColorToJpegEncoder();  // 同步到 GStreamer videobalance 和 gamma
        emit cameraSettingsChanged();
        qDebug() << "📷 曝光联动更新: 曝光=" << value << "% → 饱和度=" << m_saturation 
                 << ", 对比度=" << m_contrast << ", 伽马=" << m_gamma
                 << " | 独立参数: 亮度=" << m_brightness << ", 色调=" << m_hue;
    }
}

void CaptureManager::resetCameraSettings()
{
    m_brightness = DEFAULT_BRIGHTNESS;
    m_contrast = DEFAULT_CONTRAST;
    m_saturation = DEFAULT_SATURATION;
    m_hue = DEFAULT_HUE;
    m_gamma = DEFAULT_GAMMA;
    m_exposure = DEFAULT_EXPOSURE;
    saveSettings();
    syncColorToJpegEncoder();
    emit cameraSettingsChanged();
    qDebug() << "Camera: settings reset to default";
}

// §23.19：zp.txt / ai_zoom.txt 写盘统一挪单线程后台池（FIFO 保序）。
// 两个日志的调用方都在主线程（滚轮缩放 / 截图点击），原同步 write+flush 磁盘忙时会挂主线程。
static QThreadPool *diagTxtLogPool()
{
    static QThreadPool *pool = []() {
        auto *p = new QThreadPool();
        p->setMaxThreadCount(1);
        return p;
    }();
    return pool;
}

void CaptureManager::zoomLog(const QString &msg)
{
    // 写入缩放调试日志到 zp.txt（主线程只拼行+入队，写盘在后台）
    const QString line = QDateTime::currentDateTime().toString("[hh:mm:ss.zzz] ") + msg + "\n";
    diagTxtLogPool()->start([line]() {
        static QFile file(QCoreApplication::applicationDirPath() + "/zp.txt");
        static bool opened = false;
        if (!opened) {
            opened = file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text);
        }
        if (file.isOpen()) {
            QTextStream stream(&file);
            stream << line;
            stream.flush();
        }
    });
}

void CaptureManager::aiZoomLog(const QString &msg)
{
    // 自动放大(AI 牌识别)专用调试日志，与 zp.txt 分开，便于排查"为什么识别失败"。
    // ⭐ Append 追加 + 会话分隔行（原 Truncate 会在重启时把失败证据抹掉——
    //   "偶尔 1 张识别不了"这类低频问题往往复现后先重启了程序，日志就没了）。
    //   main.cpp 启动清日志白名单里也已移除 ai_zoom.txt。
    // §23.19：写盘挪后台（截图点击路径在主线程调本函数，磁盘忙时同步 flush 会卡实时流）。
    const QString line = QDateTime::currentDateTime().toString("[hh:mm:ss.zzz] ") + msg + "\n";
    diagTxtLogPool()->start([line]() {
        static QFile file(QCoreApplication::applicationDirPath() + "/ai_zoom.txt");
        static bool opened = false;
        if (!opened) {
            opened = file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);
            if (file.isOpen()) {
                QTextStream s(&file);
                s << QDateTime::currentDateTime().toString("[yyyy-MM-dd hh:mm:ss] ")
                  << "=== 自动放大(AI) 会话开始 ===\n";
                s.flush();
            }
        }
        if (file.isOpen()) {
            QTextStream stream(&file);
            stream << line;
            stream.flush();
        }
    });
}

void CaptureManager::markAiRecognitionFailed(int itemIndex)
{
    if (itemIndex < 0 || itemIndex >= m_items.size())
        return;
    CaptureItem &item = m_items[itemIndex];
    // 已标记失败就无需重复处理（避免误把手动缩放也当识别失败刷日志）
    if (item.aiDisabled)
        return;
    aiZoomLog(QString("🖐️ 用户拖动 → 标记识别失败: itemIndex=%1 (牌不在识别框内, 该格退回非自动放大, 清空每帧识别缓存)")
                  .arg(itemIndex));
    item.aiDisabled = true;
    item.aiFrames.clear();
}

void CaptureManager::syncColorToJpegEncoder()
{
    // 同步颜色参数到 GStreamer（使用 videobalance 和 gamma，不再使用 shader）。
    // ⭐ 仅 GStreamer 帧源有此能力；网页内核帧源(WebFrameSource)无 GStreamer 管线，跳过。
    if (GstPlayer *gst = qobject_cast<GstPlayer*>(m_frameSource ? m_frameSource->asQObject() : nullptr)) {
        gst->setAllImageParams(m_brightness, m_contrast, m_saturation, m_hue, m_gamma);
    }
    // 保留 GpuPipeline 的调用（如果存在）用于兼容
    if (m_gpuPipeline) {
        m_gpuPipeline->setJpegColorParams(m_brightness, m_contrast, m_saturation, m_hue, m_gamma);
    }
}

