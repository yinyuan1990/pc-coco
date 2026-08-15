#include "carddetector.h"

#include <QDebug>

// ⭐ aihj 版：AI 牌位置识别（ONNX Runtime + cardYolov8）整套下线。
//   本文件保留 CardDetector 的公共接口（供 capturemanager 编译不变），但去掉了
//   onnxruntime 依赖：loadModel() 恒返回 false → 检测器永不 ready → 上层「自动放大」
//   开关点了也不会有任何识别发生（QML 里该开关已隐藏，见 MainPage.qml）。
//   如需恢复 AI，回滚本文件并在 CMakeLists.txt 重新接上 ONNX Runtime 即可。

struct CardDetector::OrtImpl {};

CardDetector::CardDetector(QObject *parent)
    : QThread(parent)
{
}

CardDetector::~CardDetector()
{
    stop();
}

bool CardDetector::loadModel(const QString &onnxPath)
{
    Q_UNUSED(onnxPath);
    // AI 已下线：不加载任何模型，检测器保持未就绪状态。
    m_ready.store(false);
    return false;
}

void CardDetector::submit(int itemIndex, int frameOffset, const QImage &frame)
{
    Q_UNUSED(itemIndex);
    Q_UNUSED(frameOffset);
    Q_UNUSED(frame);
    // 检测器永不 ready，直接忽略。
}

void CardDetector::stop()
{
    if (!isRunning() && !m_running.load())
        return;
    {
        QMutexLocker lk(&m_mutex);
        m_running.store(false);
        m_queue.clear();
        m_cond.wakeAll();
    }
    wait();
}

void CardDetector::run()
{
    // AI 已下线：线程不会被 start()（loadModel 恒 false），此处留空实现。
}

bool CardDetector::preprocess(const QImage &src, std::vector<float> &out) const
{
    Q_UNUSED(src);
    Q_UNUSED(out);
    return false;
}

CardBox CardDetector::infer(const std::vector<float> &input)
{
    Q_UNUSED(input);
    return CardBox{};
}
