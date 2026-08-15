#include "slowmotionplayer.h"
#include "gpupipeline.h"
#include "gstplayer.h"
#include "webframesource.h"
#include "imageprovider.h"
#include "gstcapturedecoder.h"
#include "naluframestore.h"
#include "capturedebuglog.h"
#include <QCoreApplication>
#include <QFile>
#include <QDebug>
#include <QMutexLocker>
#include <QDateTime>
#include <QVideoFrame>
#include <QBuffer>

SlowMotionPlayer::SlowMotionPlayer(QObject *parent)
    : QObject(parent)
    , m_settings("Acard", "HuanJing")
    , m_frameCache(FRAME_CACHE_SIZE)  // 初始化帧缓存
{
    qDebug() << "📦 SlowMotionPlayer 构造开始...";
    m_playbackTimer = new QTimer(this);
    connect(m_playbackTimer, &QTimer::timeout, this, &SlowMotionPlayer::onPlaybackTimer);
    qDebug() << "📦 SlowMotionPlayer 播放定时器已创建";
    
    // 自动注册到 ImageProvider
    if (CaptureImageProvider::instance()) {
        CaptureImageProvider::instance()->setSlowMotionPlayer(this);
        qDebug() << "SlowMotionPlayer: registered to ImageProvider";
    }
    
    // 加载持久化设置
    loadSettings();
    qDebug() << "📦 SlowMotionPlayer 构造完成";
}

SlowMotionPlayer::~SlowMotionPlayer()
{
    m_playbackTimer->stop();

    if (m_decodeThread) {
        m_decodeThread->stop();
        delete m_decodeThread;
        m_decodeThread = nullptr;
    }

    delete m_gstDecoder;
    saveSettings();
}

void SlowMotionPlayer::loadSettings()
{
    m_playbackMultiplier = m_settings.value("slowmo/multiplier", 1.0).toDouble();
    m_maxFrameRate = m_settings.value("slowmo/maxFrameRate", 60).toInt();
    m_maxFrames = m_settings.value("slowmo/maxFrames", 5000).toInt();
    
    // 确保值在有效范围内
    m_playbackMultiplier = qBound(MULTIPLIER_MIN, m_playbackMultiplier, MULTIPLIER_MAX);
    m_maxFrameRate = qBound(1, m_maxFrameRate, 120);
    m_maxFrames = qBound(100, m_maxFrames, 10000);
    
    qDebug() << "SlowMotionPlayer: loaded settings - multiplier:" << m_playbackMultiplier
             << "maxFps:" << m_maxFrameRate << "maxFrames:" << m_maxFrames;
}

void SlowMotionPlayer::saveSettings()
{
    m_settings.setValue("slowmo/multiplier", m_playbackMultiplier);
    m_settings.setValue("slowmo/maxFrameRate", m_maxFrameRate);
    m_settings.setValue("slowmo/maxFrames", m_maxFrames);
    // ⚠️ 不要调 m_settings.sync()：Windows 注册表后端的 sync() 会 RegFlushKey 强制刷盘，
    // 磁盘忙时（H264 落盘支路持续写入）单次可挂主线程 700ms+（freeze_diag 实锤，§23.15）。
    // setValue 已实时写入注册表内存，由系统 lazy writer 落盘；进程退出时 QSettings 析构自会 sync。
}

void SlowMotionPlayer::setGpuPipeline(GpuPipeline* pipeline)
{
    if (m_gpuPipeline != pipeline) {
        m_gpuPipeline = pipeline;
        emit gpuPipelineChanged();
    }
}

GstPlayer* SlowMotionPlayer::gstPlayer() const
{
    return qobject_cast<GstPlayer*>(m_gstPlayer ? m_gstPlayer->asQObject() : nullptr);
}

void SlowMotionPlayer::setGstPlayer(GstPlayer* player)
{
    // QML 默认绑定走这里（GStreamer 帧源）；统一委托给 setFrameSource。
    setFrameSource(player);
}

void SlowMotionPlayer::setFrameSource(IFrameSource* source)
{
    if (m_gstPlayer == source) return;

    // 断开旧连接（SIGNAL/SLOT 宏经 asQObject，兼容 GstPlayer / WebFrameSource）
    if (m_gstPlayer) {
        disconnect(m_gstPlayer->asQObject(), SIGNAL(h264FrameStored(qint64)),
                   this, SLOT(onFrameEncoded(qint64)));
    }

    // 停止旧解码线程
    if (m_decodeThread) {
        m_decodeThread->stop();
        delete m_decodeThread;
        m_decodeThread = nullptr;
    }

    m_gstPlayer = source;

    if (m_gstPlayer) {
        connect(m_gstPlayer->asQObject(), SIGNAL(h264FrameStored(qint64)),
                this, SLOT(onFrameEncoded(qint64)), Qt::QueuedConnection);

        delete m_gstDecoder;
        m_gstDecoder = new GstCaptureDecoder();

        m_decodeThread = new SlowMotionDecodeThread(m_gstPlayer, this);
        connect(m_decodeThread, &SlowMotionDecodeThread::frameDecoded,
                this, &SlowMotionPlayer::onFrameDecoded, Qt::QueuedConnection);
        m_decodeThread->start();
        qDebug() << "SlowMotionPlayer: decoder thread created, format="
                 << (m_gstPlayer->frameFormat() == IFrameSource::FrameFormat::JPEG ? "JPEG" : "H264");
    }

    emit gstPlayerChanged();
}

void SlowMotionPlayer::setFrameSourceObject(QObject *source)
{
    IFrameSource *fs = nullptr;
    if (GstPlayer *gst = qobject_cast<GstPlayer*>(source)) {
        fs = gst;
    } else if (WebFrameSource *web = qobject_cast<WebFrameSource*>(source)) {
        fs = web;
    }
    setFrameSource(fs);
}

void SlowMotionPlayer::setVideoSink(QVideoSink* sink)
{
    if (m_videoSink != sink) {
        m_videoSink = sink;
        emit videoSinkChanged();
        qDebug() << "SlowMotionPlayer: videoSink set to" << sink;
    }
}

void SlowMotionPlayer::ensureJpegEncoderConnected()
{
    // No longer needed — using independent H.264 frame files instead of JPEG encoder
}

void SlowMotionPlayer::setState(State state)
{
    if (m_state != state) {
        m_state = state;
        emit stateChanged();
        emit hasContentChanged();
    }
}

void SlowMotionPlayer::setCurrentFrame(int frame)
{
    if (m_recordedFrames <= 0) return;
    
    frame = qBound(0, frame, m_recordedFrames - 1);
    if (m_currentFrame != frame) {
        m_currentFrame = frame;
        emit currentFrameChanged();
        
        // 如果有 videoSink，直接渲染
        if (m_videoSink) {
            renderToVideoSink(m_currentFrame);
        }
    }
}

void SlowMotionPlayer::setMaxFrames(int frames)
{
    frames = qBound(100, frames, 10000);
    if (m_maxFrames != frames) {
        m_maxFrames = frames;
        emit maxFramesChanged();
        saveSettings();
    }
}

void SlowMotionPlayer::setPlaybackMultiplier(double multiplier)
{
    multiplier = qBound(1.0, multiplier, 10.0);
    if (!qFuzzyCompare(m_playbackMultiplier, multiplier)) {
        double oldMultiplier = m_playbackMultiplier;
        m_playbackMultiplier = multiplier;
        emit playbackMultiplierChanged();
        saveSettings();
        
        // 录制状态下切换倍数：更新 followLive 和定时器
        if (m_state == RECORDING) {
            bool wasFollowLive = m_followLive;
            m_followLive = (multiplier <= 1.0);  // 使用 <= 1 确保 1x 模式正确启用
            
            Q_UNUSED(oldMultiplier);
            Q_UNUSED(wasFollowLive);
            
            if (multiplier <= 1.0) {
                // 切换到 1x：停止定时器，跟随实时流
                m_playbackTimer->stop();
                // 立即跳到最新帧
                if (m_recordedFrames > 0) {
                    m_currentFrame = m_recordedFrames - 1;
                    emit currentFrameChanged();
                    if (m_videoSink) {
                        renderToVideoSink(m_currentFrame);
                    }
                }
            } else {
                // 切换到 >1x：启动定时器，开始减速播放
                updateTimerInterval();
                if (!m_playbackTimer->isActive()) {
                    m_playbackTimer->start();
                }
            }
        } else if (m_isPlaying) {
            // 回放状态：只更新定时器间隔
            updateTimerInterval();
        }
    }
}

void SlowMotionPlayer::setMaxFrameRate(int fps)
{
    fps = qBound(1, fps, 120);
    if (m_maxFrameRate != fps) {
        m_maxFrameRate = fps;
        emit maxFrameRateChanged();
        saveSettings();
        
        if (m_isPlaying) {
            updateTimerInterval();
        }
    }
}

void SlowMotionPlayer::startRecording()
{
    qint64 newest = -1;
    if (m_gstPlayer) {
        newest = m_gstPlayer->newestH264Frame();
    }

    if (newest < 0) {
        qWarning() << "SlowMotionPlayer: cannot start recording - no frames available";
        return;
    }

    if (m_state != IDLE) {
        clear();
    }

    m_startIndex = newest;
    m_endIndex = m_startIndex;
    m_currentFrame = 0;
    m_recordedFrames = 0;

    m_followLive = (m_playbackMultiplier == 1);

    qDebug() << "SlowMotionPlayer: startIndex:" << m_startIndex << "multiplier:" << m_playbackMultiplier << "followLive:" << m_followLive;

    // 注册有效范围（保护 H.264 独立帧文件不被清理）
    if (m_gstPlayer) {
        m_validRangeId = m_gstPlayer->registerH264ValidRange(m_startIndex, m_startIndex + m_maxFrames);
    }
    
    setState(RECORDING);
    
    // 触发信号让 QML Image 刷新
    emit currentFrameChanged();
    emit recordedFramesChanged();
    
    // 开始播放
    m_isPlaying = true;
    updateTimerInterval();
    
    // 大于1x直接启动定时器慢放，1x跟随实时流不需要定时器
    if (!m_followLive) {
        m_playbackTimer->start();
    }
    emit playingChanged();
    
    qDebug() << "SlowMotionPlayer: started recording at index" << m_startIndex
             << "multiplier:" << m_playbackMultiplier
             << "followLive:" << m_followLive
             << "endIndex:" << m_endIndex;
}

void SlowMotionPlayer::stopRecording()
{
    if (m_state != RECORDING) return;
    
    pause();
    
    // ⭐ 进入回放模式，使用原图（不缩放）
    m_followLive = false;
    
    if (m_validRangeId >= 0 && m_gstPlayer) {
        m_gstPlayer->updateH264ValidRange(m_validRangeId, m_startIndex, m_endIndex);
    }
    
    setState(PLAYBACK);
    
    // 跳到第一帧
    setCurrentFrame(0);
    
    qDebug() << "SlowMotionPlayer: stopped recording, frames:" << m_recordedFrames
             << "range: [" << m_startIndex << "-" << m_endIndex << "]";
}

void SlowMotionPlayer::clear()
{
    pause();
    
    if (m_validRangeId >= 0 && m_gstPlayer) {
        m_gstPlayer->unregisterH264ValidRange(m_validRangeId);
        m_validRangeId = -1;
    }

    {
        QMutexLocker locker(&m_cacheMutex);
        m_frameCache.clear();
    }
    if (m_gstDecoder) m_gstDecoder->flush();

    m_startIndex = -1;
    m_endIndex = -1;
    m_currentFrame = 0;
    m_recordedFrames = 0;
    m_followLive = true;
    
    setState(IDLE);
    emit recordedFramesChanged();
    emit currentFrameChanged();
    
    qDebug() << "SlowMotionPlayer: cleared";
}

qint64 SlowMotionPlayer::currentGlobalFrameIndex() const
{
    if (m_startIndex < 0 || m_recordedFrames <= 0) {
        return -1;  // 无有效数据
    }
    
    // 当前帧的全局索引 = 起始索引 + 当前帧偏移
    qint64 globalIndex = m_startIndex + m_currentFrame;
    
    // 确保不超出范围
    if (globalIndex > m_endIndex) {
        globalIndex = m_endIndex;
    }
    
    return globalIndex;
}

void SlowMotionPlayer::play()
{
    if (m_recordedFrames <= 0 && m_state != RECORDING) return;
    
    if (!m_isPlaying) {
        m_isPlaying = true;
        
        // 根据状态和倍数决定播放方式
        if (m_state == RECORDING && m_playbackMultiplier <= 1.0) {
            // 录制中 + 1倍：恢复跟随实时流，不需要定时器
            m_followLive = true;
            // 立即跳到最新帧
            if (m_recordedFrames > 0) {
                m_currentFrame = m_recordedFrames - 1;
                emit currentFrameChanged();
                if (m_videoSink) {
                    renderToVideoSink(m_currentFrame);
                }
            }
        } else {
            // 其他情况：定时器播放
            updateTimerInterval();
            m_playbackTimer->start();
        }
        
        emit playingChanged();
    }
}

void SlowMotionPlayer::pause()
{
    if (m_isPlaying) {
        m_isPlaying = false;
        m_playbackTimer->stop();
        emit playingChanged();
    }
}

void SlowMotionPlayer::togglePlay()
{
    if (m_isPlaying) {
        pause();
    } else {
        play();
    }
}

void SlowMotionPlayer::nextFrame()
{
    captureDebugLog("SLW", QString("nextFrame cur=%1 recorded=%2 followLive=%3")
        .arg(m_currentFrame).arg(m_recordedFrames).arg(m_followLive));

    if (m_followLive) {
        m_followLive = false;
    }
    if (m_playbackTimer->isActive()) {
        m_playbackTimer->stop();
        m_isPlaying = false;
        emit playingChanged();
    }
    
    if (m_currentFrame < m_recordedFrames - 1) {
        setCurrentFrame(m_currentFrame + 1);
    }
}

void SlowMotionPlayer::prevFrame()
{
    captureDebugLog("SLW", QString("prevFrame cur=%1 recorded=%2 followLive=%3")
        .arg(m_currentFrame).arg(m_recordedFrames).arg(m_followLive));

    if (m_followLive) {
        m_followLive = false;
    }
    if (m_playbackTimer->isActive()) {
        m_playbackTimer->stop();
        m_isPlaying = false;
        emit playingChanged();
    }
    
    if (m_currentFrame > 0) {
        setCurrentFrame(m_currentFrame - 1);
    }
}

void SlowMotionPlayer::jumpToFrame(int frame)
{
    // 用户手动跳转（拖动滑块），停止跟随实时流
    m_followLive = false;
    setCurrentFrame(frame);
    
    // 如果正在播放但定时器没启动（1x倍速时），启动定时器
    if (m_isPlaying && !m_playbackTimer->isActive()) {
        updateTimerInterval();
        m_playbackTimer->start();
    }
}

QImage SlowMotionPlayer::getFrameImage(int frameOffset) const
{
    CaptureDebugScope scope("SLW", QString("getFrameImage local=%1 start=%2 end=%3 state=%4")
        .arg(frameOffset).arg(m_startIndex).arg(m_endIndex).arg(static_cast<int>(m_state)), 80);

    if (m_startIndex < 0) {
        captureDebugLog("SLW", "getFrameImage no startIndex");
        return QImage();
    }

    qint64 globalIndex = m_startIndex + frameOffset;

    if (m_state == RECORDING && globalIndex > m_endIndex) {
        globalIndex = m_endIndex;
    } else if (globalIndex > m_endIndex) {
        captureDebugLog("SLW", QString("getFrameImage out of range global=%1 end=%2")
            .arg(globalIndex).arg(m_endIndex));
        return QImage();
    }

    QImage img;

    if (m_gstPlayer) {
        QByteArray data = m_gstPlayer->readH264Frame(globalIndex);
        if (!data.isEmpty()) {
            // ⭐ 按帧源格式分支：网页内核(JPEG)直接 QImage 解；GStreamer(H264) 走软解码器。
            if (m_gstPlayer->frameFormat() == IFrameSource::FrameFormat::JPEG) {
                if (!img.loadFromData(data, "JPEG")) {
                    captureDebugLog("SLW", QString("getFrameImage JPEG decode NULL global=%1").arg(globalIndex));
                }
            } else if (m_gstDecoder) {
                m_gstDecoder->flush();
                img = const_cast<GstCaptureDecoder*>(m_gstDecoder)->decodeNalu(data);
                if (img.isNull()) {
                    captureDebugLog("SLW", QString("getFrameImage H264 decode NULL global=%1").arg(globalIndex));
                }
            }
        } else {
            captureDebugLog("SLW", QString("getFrameImage file missing global=%1").arg(globalIndex));
        }
    } else {
        captureDebugLog("SLW", "getFrameImage no decoder/player");
    }

    if (img.isNull()) return QImage();

    if (m_state == RECORDING && m_followLive && img.width() > 640) {
        int newWidth = 640;
        int newHeight = img.height() * 640 / img.width();
        return img.scaled(newWidth, newHeight, Qt::KeepAspectRatio, Qt::FastTransformation);
    }

    captureDebugLog("SLW", QString("getFrameImage OK %1x%2").arg(img.width()).arg(img.height()));
    return img;
}

bool SlowMotionPlayer::saveCurrentFrame(const QString &path)
{
    QImage img = getFrameImage(m_currentFrame);
    if (img.isNull()) {
        return false;
    }
    return img.save(path, "JPEG", 95);
}

void SlowMotionPlayer::onPlaybackTimer()
{
    // 慢放模式（非跟随实时流）：定时器推进帧
    if ((m_state == RECORDING && !m_followLive) || m_state == PLAYBACK) {
        // 检查是否有帧可以推进
        bool canAdvance = (m_recordedFrames > 0 && m_currentFrame < m_recordedFrames - 1);
        
        if (canAdvance) {
            m_currentFrame = m_currentFrame + 1;
            emit currentFrameChanged();
            // 如果有 videoSink，直接渲染
            if (m_videoSink) {
                renderToVideoSink(m_currentFrame);
            }
        } else if (m_state == PLAYBACK && m_currentFrame >= m_recordedFrames - 1) {
            // 回放模式到达末尾，停止
            pause();
        }
        // 录制模式追上进度时，等待新帧（定时器继续运行）
    }
}

void SlowMotionPlayer::onFrameEncoded(qint64 frameIndex)
{
    if (m_state != RECORDING) return;
    if (m_startIndex < 0) return;
    
    // 检查是否在我们的范围内
    if (frameIndex >= m_startIndex) {
        updateEndIndex(frameIndex);
    }
    
}

void SlowMotionPlayer::updateEndIndex(qint64 frameIndex)
{
    if (frameIndex >= m_startIndex && frameIndex > m_endIndex) {
        m_endIndex = frameIndex;
        int newRecorded = static_cast<int>(m_endIndex - m_startIndex + 1);
        
        if (newRecorded != m_recordedFrames) {
            bool wasEmpty = (m_recordedFrames == 0);
            m_recordedFrames = newRecorded;
            emit recordedFramesChanged();
            
            // 第一帧到达时，通知 hasContent 变化
            if (wasEmpty && m_recordedFrames > 0) {
                emit hasContentChanged();
            }
            
            // 1x跟随实时流模式：显示最新帧（必须正在播放状态才渲染）
            if (m_state == RECORDING && m_followLive && m_isPlaying && m_videoSink) {
                m_currentFrame = m_recordedFrames - 1;
                emit currentFrameChanged();
                renderToVideoSink(m_currentFrame);
            }
            
            // 检查是否达到最大帧数
            if (m_recordedFrames >= m_maxFrames) {
                qDebug() << "SlowMotionPlayer: reached max frames, stopping recording";
                stopRecording();
            }
        }
    }
}

void SlowMotionPlayer::updateTimerInterval()
{
    // 实际帧率 = 最大帧率 / 倍数
    double fps = static_cast<double>(m_maxFrameRate) / m_playbackMultiplier;
    int interval = static_cast<int>(1000.0 / fps);
    m_playbackTimer->setInterval(qMax(1, interval));
}

void SlowMotionPlayer::emitCurrentFrame()
{
    QImage img = getFrameImage(m_currentFrame);
    if (!img.isNull()) {
        emit frameReady(img);
    }
}

void SlowMotionPlayer::renderToVideoSink(int frameOffset)
{
    if (!m_videoSink || m_startIndex < 0) return;

    qint64 globalIndex = m_startIndex + frameOffset;

    if (m_state == RECORDING && globalIndex > m_endIndex) {
        globalIndex = m_endIndex;
    } else if (globalIndex > m_endIndex) {
        return;
    }

    if (m_decodeThread) {
        m_pendingFrameOffset = frameOffset;
        m_decodeThread->requestDecode(globalIndex, frameOffset, m_followLive);
    }
}

void SlowMotionPlayer::onFrameDecoded(int frameOffset, const QVideoFrame &frame)
{
    // 跳帧优化：如果已经有更新的请求，忽略旧帧
    // 但如果当前在 PLAYBACK 状态，不跳帧（需要顺序播放）
    if (m_state == RECORDING && m_followLive && frameOffset != m_pendingFrameOffset) {
        return;  // 跳过旧帧
    }
    
    if (m_videoSink && frame.isValid()) {
        m_videoSink->setVideoFrame(frame);
    }
}

// ============ SlowMotionDecodeThread 实现 ============

SlowMotionDecodeThread::SlowMotionDecodeThread(IFrameSource *player, QObject *parent)
    : QThread(parent)
    , m_player(player)
{
    m_decoder = new GstCaptureDecoder();
}

SlowMotionDecodeThread::~SlowMotionDecodeThread()
{
    stop();
    delete m_decoder;
}

void SlowMotionDecodeThread::stop()
{
    m_running = false;
    m_queueCondition.wakeAll();
    if (isRunning()) {
        wait(3000);
    }
}

void SlowMotionDecodeThread::requestDecode(qint64 globalFrameIndex, int frameOffset, bool scale)
{
    QMutexLocker locker(&m_queueMutex);
    m_decodeQueue.clear();
    m_decodeQueue.enqueue({globalFrameIndex, frameOffset, scale});
    m_queueCondition.wakeOne();
}

void SlowMotionDecodeThread::run()
{
    while (m_running) {
        DecodeRequest request{-1, -1, false};

        {
            QMutexLocker locker(&m_queueMutex);
            while (m_decodeQueue.isEmpty() && m_running) {
                m_queueCondition.wait(&m_queueMutex);
            }
            if (!m_running) break;
            request = m_decodeQueue.dequeue();
        }

        if (request.globalIndex >= 0 && m_decoder && m_player) {
            CaptureDebugScope scope("SLW", QString("decodeThread global=%1 local=%2")
                .arg(request.globalIndex).arg(request.frameOffset), 80);

            QImage img;
            QByteArray data = m_player->readH264Frame(request.globalIndex);
            if (!data.isEmpty()) {
                // ⭐ 按帧源格式分支：网页内核(JPEG)直接 QImage 解；GStreamer(H264) 走软解码器。
                if (m_player->frameFormat() == IFrameSource::FrameFormat::JPEG) {
                    if (!img.loadFromData(data, "JPEG")) {
                        captureDebugLog("SLW", QString("decodeThread JPEG decode NULL global=%1").arg(request.globalIndex));
                    }
                } else {
                    m_decoder->flush();
                    img = m_decoder->decodeNalu(data);
                }
            } else {
                captureDebugLog("SLW", QString("decodeThread file missing global=%1").arg(request.globalIndex));
            }

            if (img.isNull()) {
                captureDebugLog("SLW", QString("decodeThread NULL global=%1").arg(request.globalIndex));
            }

            if (!img.isNull()) {
                if (request.scale && (img.width() > 640 || img.height() > 480)) {
                    img = img.scaled(640, 480, Qt::KeepAspectRatio, Qt::FastTransformation);
                }

                QVideoFrame frame(QVideoFrameFormat(img.size(), QVideoFrameFormat::Format_BGRA8888));
                if (frame.map(QVideoFrame::WriteOnly)) {
                    QImage converted = img.convertToFormat(QImage::Format_ARGB32);
                    memcpy(frame.bits(0), converted.bits(), converted.sizeInBytes());
                    frame.unmap();
                    emit frameDecoded(request.frameOffset, frame);
                }
            }
        }
    }

    qDebug() << "SlowMotionDecodeThread: stopped";
}
