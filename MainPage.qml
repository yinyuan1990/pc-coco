import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import QtCore
import Aifs.Components 1.0

Rectangle {
    id: mainPage
    color: "#1F1F1F"  // ⭐ 2026-08-14 对齐 java gstream：主内容区深色底
    focus: true  // ⭐ 获取键盘焦点
    
    // ⭐ S键按下/释放检测（用于 S+滚轮 缩放）
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_S && !event.isAutoRepeat) {
            sKeyPressed = true
            event.accepted = false  // 允许事件继续传递（S键的其他快捷键仍可用）
        }
    }
    Keys.onReleased: function(event) {
        if (event.key === Qt.Key_S && !event.isAutoRepeat) {
            sKeyPressed = false
            event.accepted = false
        }
    }
    
    // 退出登录信号
    signal logoutRequested()
    
    // PC端激活等级：0=未激活，1=豪华版，2=AI全能版
    property int pcActivationLevel: 0
    onPcActivationLevelChanged: {
        console.log("[抓拍全屏] pcActivationLevel 变化: 新值=" + pcActivationLevel + ", 抓拍全屏菜单项应该显示:" + (pcActivationLevel >= 2))
    }
    property string pcLevelName: ""        // 等级名称："豪华版"或"AI全能版"
    property string pcExpireAt: ""         // AI全能版到期时间（豪华版为空）
    
    // 从 Main.qml 传入的参数
    property string srsServer: ""
    property string currentStream: "VID_59C9232BFF5576718C575E19EDE7"
    
    // ⭐ 测试开关（§21.11 iOS 自适应 fps 单测用，2026-07-02 测试结束已改回 false）：
    //   true = 屏蔽 PC 端所有【自动】下发 fps 的路径
    //   （双缓冲第二道防线 onRequestFpsChange / 切档后 fpsLimitPushTimer 补发 / 切档 fps 超限 clamp 下发）。
    //   手动路径不受影响（帧率滑块/滚轮/相机设定还原照常下发）。
    property bool fpsAutoPushDisabled: false

    // P2P 直连模式属性
    property int connectMode: 0                        // 0=SRS模式, 1=P2P直连模式, 2=SRT模式（来自CONFIG_STATE.state.connectstype）
    property string videoCodec: "h264"                 // ⭐ H265：P2P 实际编码（来自CONFIG_STATE.state.videoCodec，iOS 登录页二级选项）
    property string pairedIosDeviceId: ""              // 配对的 iOS 设备 ID
    property string pairedIosDisplay: ""               // ⭐ 当前设备的显示名（昵称/账号），顶部在线灯下显示
    property double _lastCfgMismatchLogMs: 0           // ⭐ 「非本设备 CONFIG_STATE」诊断日志节流
    property double _lastKeyframeWsMs: 0                // P0-1: WebSocket 关键帧兜底限流时间戳
    property double _lastSpaceCaptureMs: 0              // 2026-07-19: 空格连拍节流时间戳（按住=键盘自动重复~30次/s，低端机被顶死）
    property var iceServers: []                        // 从登录接口获取的 ICE 服务器列表
    
    // 行列调节防抖
    property int pendingRows: captureManager.gridRows
    property int pendingCols: captureManager.gridCols
    
    // 视频旋转角度 (0, 90, 180, 270)
    property int videoRotation: 0
    // 视频镜像: "none" / "horizontal" / "vertical"
    property string videoMirrorMode: "none"
    
    // 视频缩放相关属性
    property real videoZoom: 1.0           // 缩放倍数 1.0 - 5.0
    property real videoOffsetX: 0          // X轴偏移（相对于中心）
    property real videoOffsetY: 0          // Y轴偏移（相对于中心）

    // ⭐ 网页内核模式：本地变换变化时同步给 webview（CSS transform）。
    //   GStreamer 模式下 kernelSyncTransform 内部直接 return，无副作用。
    //   注意：videoZoom/videoOffsetX/videoOffsetY 的 kernelSyncTransform 已合并到
    //   下方对应的信号处理器中（QML 同一对象同名信号处理器只能声明一次）。
    onVideoRotationChanged: kernelSyncTransform()
    onVideoMirrorModeChanged: kernelSyncTransform()

    function clampVideoOffsets() {
        var maxOffsetX = videoContainer.width * (videoZoom - 1) / 2
        var maxOffsetY = videoContainer.height * (videoZoom - 1) / 2
        videoOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, videoOffsetX))
        videoOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, videoOffsetY))
    }

    // ⭐ P2P 连接阶段：把 GstPlayer::m_webrtcStatus（中英混合）归一成简短中文标签，
    //   只在过渡/异常态返回非空（正常「已连接」返回空 → 顶栏/面板不显示，避免刷屏）。
    function p2pPhaseText(s) {
        if (!s) return ""
        if (s.indexOf("切网重连") >= 0) return "切网重连中…"
        if (s.indexOf("重连中") >= 0) {
            var m = s.match(/\((\d+\/\d+)\)/)          // "P2P: 重连中(2/5)..."
            return "重连中" + (m ? " " + m[1] : "") + "…"
        }
        if (s.indexOf("Reconnecting") >= 0) return "重连中…"
        if (s.indexOf("waiting offer") >= 0 || s.indexOf("waiting") >= 0) return "等待手机响应…"
        if (s.indexOf("Checking") >= 0) return "连通中…"
        if (s.indexOf("Connecting") >= 0) return "连接中…"
        if (s.indexOf("重连失败") >= 0 || s.indexOf("手动重试") >= 0) return "重连失败,请重试"
        if (s.indexOf("Failed") >= 0 || s.indexOf("failed") >= 0) return "连接失败"
        if (s.indexOf("Hangup") >= 0 || s.indexOf("Disconnected") >= 0) return "已断开"
        return ""   // Connected / Playing / Ready 等正常态不显示
    }
    function p2pPhaseColor(s) {
        var t = p2pPhaseText(s)
        if (t.indexOf("失败") >= 0) return "#F44336"          // 红
        if (t.indexOf("断开") >= 0) return "#FF9800"          // 橙
        return "#FFC107"                                       // 过渡态：琥珀
    }

    function clampSlowmoOffsets() {
        var maxOffsetX = slowmoVideoContainer.width * (slowmoZoom - 1) / 2
        var maxOffsetY = slowmoVideoContainer.height * (slowmoZoom - 1) / 2
        slowmoOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, slowmoOffsetX))
        slowmoOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, slowmoOffsetY))
    }

    onVideoZoomChanged: {
        slowmoZoom = videoZoom
        clampVideoOffsets()
        kernelSyncTransform()
    }
    onVideoOffsetXChanged: {
        clampVideoOffsets()
        slowmoOffsetX = videoOffsetX
        kernelSyncTransform()
    }
    onVideoOffsetYChanged: {
        clampVideoOffsets()
        slowmoOffsetY = videoOffsetY
        kernelSyncTransform()
    }

    // ⭐ 慢放回放窗口的 独立 局部缩放 (S+滚轮 触发, 鼠标位置为中心)
    //    慢放跟实时流的 videoZoom 解耦, 满放跟随实时流同步.
    //    pcActivationLevel >= 2 才生效.
    property real slowmoZoom: 1.0          // 慢放本地缩放 1.0 - 5.0
    property real slowmoOffsetX: 0
    property real slowmoOffsetY: 0

    onSlowmoZoomChanged: { clampSlowmoOffsets() }
    onSlowmoOffsetXChanged: { clampSlowmoOffsets() }
    onSlowmoOffsetYChanged: { clampSlowmoOffsets() }
    
    // ⭐ 每个抓拍 item 的缩放状态。2026-07-11 统一模型：存「缩放 + 归一化平移分量」
    //   { itemIndex: { zoom, fx, fy } }，fx/fy ∈ [-1,1]（= 像素偏移 / 该缩放下的最大偏移）。
    //   归一化后与容器尺寸解耦 → item(任意行列大小) / 单个放大 / 列预览 三处共用同一套状态，
    //   改行列、进/出单个放大都能精确复现同样的取景（"效果一样"）。
    property var itemZoomMap: ({})

    // ⭐ 通知对应 dataIndex 的 gridCell 从 itemZoomMap 重新套用缩放（外部改了状态，如单个放大同步回来）
    signal itemZoomRestore(int idx)

    // 直接按归一化分量保存
    function saveItemZoomNorm(idx, zoom, fx, fy) {
        if (idx === undefined || idx < 0) return
        var m = mainPage.itemZoomMap
        m[idx] = { zoom: zoom, fx: fx, fy: fy }
        mainPage.itemZoomMap = m
    }

    // 由「像素偏移 + 容器尺寸」换算归一化后保存（拖动/滚轮缩放调用；contW/contH=所在容器尺寸）
    function saveItemZoom(idx, zoom, offX, offY, contW, contH) {
        var fx = 0, fy = 0
        if (zoom > 1.0 && contW > 0 && contH > 0) {
            var maxX = contW * (zoom - 1) / 2
            var maxY = contH * (zoom - 1) / 2
            fx = maxX > 0 ? Math.max(-1, Math.min(1, offX / maxX)) : 0
            fy = maxY > 0 ? Math.max(-1, Math.min(1, offY / maxY)) : 0
        }
        saveItemZoomNorm(idx, zoom, fx, fy)
    }

    // 归一化分量 → 指定容器下的像素偏移
    function itemZoomOffsetPx(zoom, frac, contSize) {
        if (zoom <= 1.0 || contSize <= 0) return 0
        return frac * (contSize * (zoom - 1) / 2)
    }

    // ⭐ Ctrl + 滚轮/单击 → 整 grid 所有 item 同步动作（联动模式广播 signal）
    //   gridCell delegate 用 Connections 监听, 收到就对自己执行同样操作.
    //   适用于"几张牌同时翻帧"、"同时缩放对比"的场景.
    signal gridSyncFrameStep(string direction)                 // direction: "prev" / "next"
    signal gridSyncZoomDelta(real deltaZoom)                   // 同步缩放增量 (各 item 以自己中心缩放)
    signal gridSyncDrag(real dx, real dy)                      // 同步拖拽偏移
    signal gridSyncResetZoom()                                  // 同步重置缩放到 1.0

    // ⭐ GStreamer 统计面板显隐（默认隐藏，点右上角 ⓘ 切换）
    property bool gstStatsVisible: false

    // ⭐ 本地设置存储（持久化）
    Settings {
        id: appSettings
        property int screenshotQuality: 100  // 截图质量，默认100
        property real panelColorH: 0     // 面板颜色色相 (0-1)，默认90%白色
        property real panelColorS: 0     // 面板颜色饱和度 (0-1)，默认90%白色
        property real panelColorV: 0.9   // 面板颜色明度 (0-1)，默认90%白色
        property bool halfScreenViewMode: false  // 放大查看模式：false=全屏，true=半屏（覆盖截图view）
        // ⭐ 播放内核选择（2026-06-24）：与 LoginPage 的 kernelSettings 同 app 域(Acard/Phoenix)、同名 key，
        //   登录页写入、这里读取，天然同步。默认 "gstreamer"。
        property string playbackKernel: "gstreamer"  // "gstreamer" | "webengine"
        // ⭐ 2026-07-14：iOS 低功率/高功率采集开关（相机设定面板"还原"按钮旁）。
        //   仅影响 iOS 端"采集"帧率（低功率=钉30fps），不改变本 PC 端既有的"推送fps下发"逻辑；
        //   iOS 收到 ptype=lowPowerCapture 后自行判断落地。默认 false=高功率（与现网行为一致）。
        //   Android 暂不处理该 ptype（Android 已是固定30fps采集，本开关对 Android 无意义）。
        property bool iosLowPowerCapture: false
    }

    // ⭐ 主播放内核是否为「网页内核(Chromium WebEngine)」。
    //   第二步会据此决定 livePanel 走 GStreamer VideoOutput 还是全屏 webview。
    property bool useWebEngineKernel: (appSettings.playbackKernel === "webengine")
    // 切内核后把 Android 本地滤镜重新落到新的活动 sink（GStreamer/网页内核）
    onUseWebEngineKernelChanged: refreshFilterRouting()
    
    // ⭐ 面板背景色 — 2026-08-14 对齐 java gstream 固定深色（截图/慢放区 #1F1F1F），
    //   不再跟随「面板色」滑块（该菜单已下线）；实时流窗口单独用 #292929（java 的 element2_1）
    property color panelBgColor: "#1F1F1F"
    
    // ⭐ 面板文字颜色（根据背景亮度自动选择）
    property color panelTextColor: {
        // 计算背景亮度
        var c = panelBgColor
        var luminance = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return luminance > 0.5 ? "#263238" : "#FFFFFF"
    }
    
    // 全屏查看相关属性
    property bool fullscreenViewerVisible: false
    property int fullscreenItemIndex: -1
    property int fullscreenFrameIndex: 0
    property int fullscreenDisplayFrame: 0  // ⭐ 实际显示的帧（缓存好才前进, 防白屏闪烁）
    property real fullscreenZoom: 1.0
    property real fullscreenOffsetX: 0  // ⭐ 缩放偏移X
    property real fullscreenOffsetY: 0  // ⭐ 缩放偏移Y
    property int fullscreenRefreshToken: 0  // ⭐ 强制刷新令牌
    property int fullscreenViewerMode: 0  // ⭐ 0=全屏, 1=半屏（只覆盖截图区域）
    
    // ⭐ 列预览相关属性（数字键0-9触发，0代表第10列）
    property bool columnPreviewVisible: false
    property int columnPreviewCol: -1  // 当前预览的列号（0-based）
    property var columnPreviewItems: []  // 该列所有有数据的 dataIndex 列表
    property int columnPreviewRefreshToken: 0
    property var columnPreviewFrames: []   // 每张图的当前帧index
    property var columnPreviewDisplayFrames: []  // ⭐ 每张图实际显示的帧（缓存好才前进, 防白屏闪烁）
    property var columnPreviewZooms: []    // 每张图的缩放倍率
    property var columnPreviewOffsetX: []  // 每张图的X偏移
    property var columnPreviewOffsetY: []  // 每张图的Y偏移
    property bool columnPreviewStretch: true   // 拉伸开关（true=铺满，false=等比适应）
    property int columnPreviewHoveredIndex: -1 // 鼠标悬停的图片索引
    property int columnPreviewZoomItemIdx: -1  // A键放大的图片索引（-1=无）
    property int columnPreviewZoomFrame: 0     // A键放大图片的帧index
    property int columnPreviewZoomDisplayFrame: 0  // ⭐ A键放大实际显示的帧（缓存好才前进, 防白屏闪烁）
    property real columnPreviewZoomScale: 1.0  // A键放大图片的缩放
    property real columnPreviewZoomOffX: 0     // A键放大图片的X偏移
    property real columnPreviewZoomOffY: 0     // A键放大图片的Y偏移
    
    // S键按下状态（用于 S+滚轮 缩放）
    property bool sKeyPressed: false

    // ⭐ 上下帧跳跃步长 — F5=1 / F6=2 / F7=3 / F8=4. 单 item / Ctrl 同步 / 列预览 / 全屏 都生效, 不影响慢放
    property int frameStep: 1
    
    // 窗口布局模式
    // 0 = 默认：左侧抓拍grid，右侧上实时下慢放
    // 1 = 实时窗口切换：左侧实时流，右侧上抓拍grid下慢放
    // 2 = 慢放窗口切换：左侧慢放，右侧上实时下抓拍grid
    property int windowLayoutMode: 0
    
    // Grid全屏模式（左侧占满宽度，右侧隐藏）
    property bool gridFullscreenMode: false
    
    // 抓拍全屏开关（当抓拍个数达到行×列时自动全屏）
    property bool autoFullscreenOnCaptureFull: false
    
    // 设备状态（来自 CONFIG_STATE 消息）
    property int deviceKbps: 0              // 码率
    property int deviceBattery: -1          // 电量（-1表示未知）
    property string deviceNetworkQuality: ""  // 网络质量（excellent/good/fair/poor）
    property string deviceNetworkType: ""   // 网络类型（WiFi/5G等）
    // ⭐ 2026-07-14：iOS 低功率采集回报（此前只下发不回报，PC 端看不到有没有生效）
    property int deviceCaptureFps: 0            // iOS 当前实际采集fps（0=未知/未上报，多为Android等非iOS设备）
    property bool deviceLowPowerCapture: false  // iOS 当前是否处于低功率采集模式
    
    // 会员等级控制（来自 CONFIG_STATE 消息）
    property bool memberActivated: false           // 是否已激活
    property int memberActivationLevel: 0          // 激活等级 (对齐 java gstream：0=试用全开放, 1=高清, 2=4K；只区分分辨率)
    property string memberActivationLevelName: ""  // 等级名称（后端下发："高清"/"4K"）
    property var levelFps: [240, 120, 180, 180, 240]  // ⭐ 各等级FPS上限（从登录接口获取；现仅用下标0=试用，会员不限制）
    property var levelExposureFps: [600, 120, 180, 240, 600]  // ⭐ 各等级超级帧率上限（从登录接口获取；现仅用下标0=试用，会员不限制）
    // ⭐ 快门(超级帧率cjfps)后台可配（总后台「App配置」，GET /api/config/camera-shutter）：
    //   {min,max,step,default} 按 iOS/Android 分组，shutterCfg = 当前连接设备平台生效的一组。
    //   拉取失败/未配置时维持内置默认（与原写死值一致：60~600 步进1 默认120）。
    property var shutterCfgIos: ({ "min": 60, "max": 600, "step": 1, "default": 120 })
    property var shutterCfgAndroid: ({ "min": 60, "max": 600, "step": 1, "default": 120 })
    property var shutterCfg: ({ "min": 60, "max": 600, "step": 1, "default": 120 })
    function applyShutterCfgForDevice() {
        var isAndroid = HttpClient.currentIsAndroid()
        shutterCfg = isAndroid ? shutterCfgAndroid : shutterCfgIos
        console.log("📷 [快门配置] 平台=" + (isAndroid ? "Android" : "iOS")
                    + " min=" + shutterCfg.min + " max=" + shutterCfg.max
                    + " step=" + shutterCfg.step + " default=" + shutterCfg["default"])
    }
    property var memberQualityAccess: []           // 可用画质列表
    property bool isDailyTrial: false              // 是否日试用
    property int activationRemainingSeconds: 0     // 剩余有效秒数
    property bool highSpeed240Enabled: false       // 240fps高速模式开关（从登录接口获取）
    
    // 保存右侧上下分割的高度比例 (topHeight / totalHeight)
    property real savedHeightRatio: 0.5
    
    // ⭐ 保存左右分割的宽度比例 (rightPanelWidth / totalWidth)
    property real savedWidthRatio: 0.25  // 默认右侧占25%
    
    // ⭐ 标记是否正在恢复比例（避免在恢复时触发保存）
    property bool isRestoringRatio: false
    property bool isRestoringWidthRatio: false  // 标记是否正在恢复宽度比例
    
    Timer {
        id: gridUpdateTimer
        interval: 100
        onTriggered: {
            if (pendingRows !== captureManager.gridRows) {
                captureManager.gridRows = pendingRows
            }
            if (pendingCols !== captureManager.gridCols) {
                captureManager.gridCols = pendingCols
            }
        }
    }
    
    // ⭐ 防抖保存高度比例的 Timer（用户拖动后延迟保存）
    Timer {
        id: saveHeightRatioTimer
        interval: 300  // 300ms 防抖
        onTriggered: {
            if (!gridFullscreenMode && !isRestoringRatio) {
                var topH = rightTopHolder.height
                var middleH = rightMiddleHolder.height
                var total = topH + middleH
                if (total > 0) {
                    savedHeightRatio = topH / total
                    console.log("💾 用户拖动后自动保存高度比例:", savedHeightRatio)
                }
            }
        }
    }
    
    // ⭐ 防抖保存宽度比例的 Timer（用户拖动后延迟保存）
    Timer {
        id: saveWidthRatioTimer
        interval: 300  // 300ms 防抖
        onTriggered: {
            if (!gridFullscreenMode && !isRestoringWidthRatio && rightPanel.width > 0 && mainSplitView.width > 0) {
                savedWidthRatio = rightPanel.width / mainSplitView.width
                console.log("💾 用户拖动后自动保存宽度比例:", savedWidthRatio, "rightPanel=", rightPanel.width, "total=", mainSplitView.width)
            }
        }
    }
    
    // FPS 显示（来自 GstPlayer 统计的实际接收帧率；自带摄像头 ×4，OTG 真实值）
    //   ⭐ 网页内核作主播放器时改用 webview 上报的 kernelViewerFps（GStreamer receiveFps 此时恒为 0）。
    //   ⭐ 2026-08-02：网页内核在 html 里统一 ×4（对齐 GStreamer 口径），OTG 源在这里除回去显示真实值。
    Item {
        id: fpsRow
        property int displayFps: mainPage.useWebEngineKernel
                                 ? (CameraCapsStore.isOtg ? Math.round(mainPage.kernelViewerFps / 4)
                                                          : mainPage.kernelViewerFps)
                                 : gstPlayer.receiveFps
    }

    // ⭐ 网页内核作主播放器时 webview 上报的接收帧率（GStreamer receiveFps 此时恒为 0）。
    //   由 kernelBridge.viewerFpsChanged 驱动，供拉流心跳判断画面是否在播。
    property int kernelViewerFps: 0

    // ⭐ §25.7e-附（2026-07-04 内核中途断开 17s 修复）：
    //   ① lastConfigStateMs：最近一条本设备 CONFIG_STATE 心跳到达时间。服务器对旧 WS 会话的
    //     离线判定有 ~2min 超时，CONFIG_ERROR(设备断线) 可能在设备已回线、画面正常播放时才迟到——
    //     若几秒内还在收心跳/画面有帧，这条断线就是陈旧事件，必须忽略，否则会拆掉正常会话。
    //   ② lastKernelStartMs：kernelStartByMode 去抖。CONFIG_ERROR 善后 + 下一条 CONFIG_STATE
    //     曾在 600ms 内触发两次重启，第二次 rebuildPC 拆掉第一次刚回完 Answer 的 RTCPeerConnection，
    //     而 iOS 把第二个 REQUEST 当重复忽略 → 会话对着已消失的对端等 ICE 满 15s 超时。
    property double lastConfigStateMs: 0
    property double lastKernelStartMs: 0

    // ⭐ 接收 webview 帧率上报（仅内核模式有效）
    Connections {
        target: (typeof kernelBridge !== 'undefined' && kernelBridge) ? kernelBridge : null
        ignoreUnknownSignals: true
        function onViewerFpsChanged(fps) {
            mainPage.kernelViewerFps = fps
            mainPage.lastKernelFpsMs = Date.now()   // 记到达时刻，供断线判定识别"陈旧的 fps 读数"
        }
        // ⭐ 网页内核滚轮缩放：webview 把 wheel 转发上来（DOM deltaY<0=上滚=放大，
        //   与 QML angleDelta 相反），这里复用 GStreamer 同款聚焦缩放数学。
        function onWheelZoomRequested(deltaY, mouseX, mouseY) {
            if (!mainPage.useWebEngineKernel) return
            mainPage.applyWheelZoom(deltaY < 0, mouseX, mouseY)
        }
    }

    // ⭐ §53.2：设备是否在线 —— **只看心跳新鲜度，与有没有画面、有没有推流无关**。
    //   以前 PC 这边唯一的"设备状态"是 publishStatus（在不在推流），设备登录着但没推流
    //   也显示「设备未上线」，把"没画面"和"没上线"混成一件事，排障时完全分不清。
    //   设备端 sendDeviceStatus 是 1s 一条、无条件发的，拿它当在线判据最准。
    property bool deviceOnline: false

    // ⭐ §53.4.5：设备端上报的链路/编码决策原因（"与观看端同 WiFi，走单人直连" 等），顶栏 tooltip 显示
    property string deviceConnectReason: ""

    // ⭐ 2026-08-01：本设备处于 P2P 单人直连、已被其他 PC 占用（收到 WEBRTC_REJECT single_mode）。
    //   置位后 §54 自愈对账不再自动重连（否则每 8s 重连又被拒 = 卡死）。仅在设备重推流(streamKey 变)
    //   / 设备离线 / 连接模式变 时清除再试——那些是"先来者可能已走、轮次已变"的合理重试点。
    property bool p2pSingleModeOccupied: false

    // 拉流心跳 + 在线心跳（1s）
    Timer {
        id: viewerHeartbeatTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            // ⭐ 内核模式用 webview 上报的 kernelViewerFps，GStreamer 模式用 gstPlayer.receiveFps。
            var fps = mainPage.useWebEngineKernel ? mainPage.kernelViewerFps : gstPlayer.receiveFps
            var deviceId = HttpClient.currentDeviceId()

            // ① 设备在线灯：最近 4s 内收到过 CONFIG_STATE 即在线（4s = 容忍 3 次丢包）
            var hbAgeMs = mainPage.lastConfigStateMs > 0 ? (Date.now() - mainPage.lastConfigStateMs) : -1
            mainPage.deviceOnline = (hbAgeMs >= 0 && hbAgeMs < 4000)

            // ⭐ §53.10：**心跳超时也必须真的收口**，不能只把顶部灯点红。
            //   设备被杀进程/断网/掉电时**一条消息都不会再来**，而清屏+复位原先只挂在
            //   CONFIG_STATE(publishStatus=0) 与 CONFIG_ERROR 两条"收到消息"的路径上 →
            //   于是出现「顶部已显示设备离线，画面还留着最后一帧，码率/电量/FPS 还是旧值」。
            //   这正是 §50.D 说的"两套状态各走各的"，换了个入口又长了出来。
            if (hbAgeMs >= 0 && !mainPage.deviceOnline) {
                // (a) 心跳派生的读数立刻复位（过期即错值），与画面是否还在无关
                if (mainPage.deviceKbps !== 0 || mainPage.deviceBattery !== -1
                        || mainPage.deviceNetworkQuality !== "" || mainPage.deviceNetworkType !== "") {
                    console.log("🔌 [心跳超时] " + hbAgeMs + "ms 无 CONFIG_STATE → 复位码率/电量/网络质量读数")
                    mainPage.resetDeviceReportedStats()
                    liveInfoFps.text = "FPS: --"
                }
                // (b) 画面确实停了 → 走统一收口（停流+清屏+改状态）。
                //     ⚠️ 必须带 fps 条件：P2P 直连的媒体不经服务器，STOMP 抖一下断了
                //     但画面还在正常播时不能把人家的画面清掉；那种情况只点灯、不清屏。
                if (hbAgeMs > 6000 && currentPlayingFps() === 0
                        && (publishState === 1 || videoSurfaceDirty)) {
                    markDeviceOffline("心跳超时 " + hbAgeMs + "ms 且无画面帧", "设备已离线")
                }
            }

            if (!deviceId) return

            var destination = "/topic/device/" + deviceId + "/config"

            // ② 拉流心跳（旧协议，保持不变）：只在画面实际显示时发，设备端据此显示「在看」
            if (fps > 0) {
                var payload = {
                    "type": "VIEWER_HEARTBEAT",
                    "deviceId": deviceId,
                    "fromDevice": HttpClient.pcDeviceId(),   // ⭐ PC 唯一标识，供 iOS 统计观看者数
                    "networkType": "wifi",                   // ⭐ PC 为桌面控制端，视为非蜂窝宽带
                    "fps": fps,
                    "timestamp": Date.now()
                }
                WebSocketClient.sendMessageJson(destination, JSON.stringify(payload))
            }

            // ③ ⭐ §53.2 在线心跳（新协议）：**不看 fps，一直发**。设备端据此把「PC在线」与
            //   「PC在看」分成两个灯——正是本轮"两端都在线却没画面"的现场判别依据。
            //   顺带把本机内核的 H265 接收能力告诉设备端（§53.5）：
            //   网页内核(低端电脑)所用的 Qt WebEngine=Chromium 134，编译期没启用 WebRTC H265
            //   接收、也没有 H265 软解 → 收 H265 必黑屏，设备端必须据此把 SRS 编码降到 H264。
            // ④ ⭐ §54 拉流自愈对账（最后防线）：3 秒级恢复靠 gstplayer 信令层常驻循环；
            //   这里只兜"循环卡死"的残余情形——设备心跳说在推流、PC 却 8s+ 无画面 →
            //   整会话换 epoch 重建。正常情况本行永远不触发。
            reconcilePlayback(currentPlayingFps())

            var presence = {
                "type": "PC_PRESENCE",
                "deviceId": deviceId,
                "fromDevice": HttpClient.pcDeviceId(),
                "pcUsername": HttpClient.loggedInUsername() || "",
                "kernel": mainPage.useWebEngineKernel ? "web" : "gst",
                "h265Recv": false,  // ⭐ aihj 版拍板：只要 H264，上报"不收 H265"让设备端永远没理由升 H265
                // ⭐ §53.4：本机局域网 IPv4。设备端**在推流前**用它比 /24 网段决定 P2P 还是 SRS，
                //   不必先建 WebRTC 会话再看 ICE 选中的候选对（那要等几秒且必须先推流）。
                "localIps": WebSocketClient.localIpv4List(),
                // ⭐ §53.20.2：本机公网出口 IP（登录响应 clientIp）。设备端与自己的出口比对，
                //   防 /24 网段号撞车（两地都是 192.168.1.x）误判同 WiFi。老后端 → 空=跳过校验。
                "publicIp": HttpClient.publicIp(),
                "viewing": fps > 0,
                "fps": fps,
                "timestamp": Date.now()
            }
            WebSocketClient.sendMessageJson(destination, JSON.stringify(presence))
        }
    }

    // ============ 核心组件 ============
    
    GpuPipeline {
        id: gpuPipeline
        Component.onCompleted: {
            console.log("📦 GpuPipeline: Component.onCompleted 开始初始化...")
            
            // 关联 captureManager 和 slowMotionPlayer
            captureManager.slowMotionPlayer = slowMotionPlayer
            
            if (init()) {
                console.log("✅ GPU Pipeline initialized:", status)
            } else {
                console.log("❌ GPU Pipeline init failed:", status)
            }
        }
        onKeyframeNeeded: { requestKeyframeWithFallback() }  // ⭐ P0-1: PLI + WebSocket 兜底
        onFrameReady: function(frameIndex) {
            if (frameIndex % 30 === 0) {
                liveInfoFps.text = "FPS: 60 | Frame: " + frameIndex
            }
            captureManager.onFrameIndexReady(frameIndex)
        }
        onJpegEncoderError: function(message) {
            errorDialog.text = message
            errorDialog.open()
        }
        onJpegDecoderError: function(message) {
            errorDialog.text = message
            errorDialog.open()
        }
    }
    
    Dialog {
        id: errorDialog
        property alias text: errorText.text
        title: "硬件加速不可用"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok
        
        Label {
            id: errorText
            wrapMode: Text.WordWrap
            width: 400
        }
        
        onAccepted: Qt.quit()
    }

    // ⭐ 2026-08-01：P2P 单人直连占用提示弹框（先到先得，另一台 PC 正在直连该设备）
    Dialog {
        id: singleModeDialog
        title: "单人直连模式"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok
        Label {
            wrapMode: Text.WordWrap
            width: 380
            text: "该设备当前处于「单人直连(P2P)」模式，已被其他电脑连接占用。\n\n请等对方断开后重试，或让设备切换到多人线路。"
        }
    }
    
    // ⭐ WebRTCClient 已废弃，改用 GstPlayer.connectWebRTC()
    // WebRTC 功能现在集成在 GstPlayer 中，使用 GStreamer WebRTCBin
    // WebRTCClient {
    //     id: webrtcClient
    //     ...
    // }
    
    // ⭐ 为了兼容旧代码，创建一个 webrtcClient 别名
    QtObject {
        id: webrtcClient
        function connect(host, app, stream) {
            gstPlayer.connectWebRTC(host, app, stream)
        }
        function disconnect() {
            gstPlayer.disconnectWebRTC()
        }
        function isConnected() {
            return gstPlayer.isWebRTCConnected()
        }
        function requestKeyFrame() {
            requestKeyframeWithFallback()   // ⭐ P0-1: PLI + WebSocket 兜底
        }
    }
    
    // GStreamer 播放器（d3d11h264dec 硬解 + WebRTCBin，所有 Windows PC 兼容）
    GstPlayer {
        id: gstPlayer
        // ⭐ 2026-08-02：OTG 外接摄像头 fps 显示真实值（自带摄像头保持 ×4 口径）
        otgSource: CameraCapsStore.isOtg
        onFirstFrameReceived: {
            console.log("🎬 GstPlayer 首帧已接收")
            if (pairedIosDeviceId && pairedIosDeviceId.length > 0) {
                WebSocketClient.sendWebRTCSignaling("VIEWER_CONNECTED", pairedIosDeviceId)
                console.log("📤 通知 iOS PC 已收到画面: " + pairedIosDeviceId)
            }
        }
        onVideoSizeChanged: {
            console.log("🎬 GstPlayer 分辨率:", videoWidth, "x", videoHeight)
        }
        onError: function(message) {
            console.log("❌ GstPlayer 错误:", message)
            statusText.text = "GStreamer 错误: " + message
            // 🔥 v14: 发生错误时清除连接中标志，允许重试
            isConnecting = false
        }
        // ⭐ 2026-08-01：P2P 被设备端以"单人直连已占用"拒绝（先到先得，另一台 PC 正在直连）。
        //   ① 弹框明确提示；② 置 p2pSingleModeOccupied 停掉 §54 自愈对账重连——否则看门狗每 8s
        //   又 playP2P、又被拒，第二/三台 PC 反复卡死。标记只在"设备重推流/离线/切模式"时清除再试。
        onP2pRejectedSingleMode: {
            console.log("🚧 P2P 被拒：设备处于单人直连模式，已被其他电脑占用")
            mainPage.p2pSingleModeOccupied = true
            isConnecting = false
            statusText.text = "该设备正被其他电脑单人直连占用"
            stopAll()
            clearVideoSurface()
            singleModeDialog.open()
        }
        // ⭐ WebRTC 信号（替代 WebRTCClient）
        onWebrtcConnected: {
            console.log("✅ WebRTC 已连接 (GStreamer WebRTCBin)")
            statusText.text = "WebRTC 已连接 (GStreamer WebRTCBin)"
            isConnecting = false  // 🔥 v14: 连接成功，清除标志
            // ⭐ 不再 reset（会清空抓拍列表），断线重连后保留之前的抓拍
            // captureManager.reset()
        }
        onWebrtcDisconnected: {
            console.log("🔌 WebRTC 已断开")
            statusText.text = "WebRTC 已断开"
            // ⭐⭐ §54.6（2026-07-31 日志实锤）：这里**不再发 VIEWER_DISCONNECTED**。
            //   旧代码对"每一次会话断开"都广播它——包括 PC 自己拆会话重连（streamKeyChanged/
            //   看门狗重建）。垂死 pipeline 的断开信号是队列化回调、会**迟到**：PC 已发出新一轮
            //   REQUEST、iOS 已建好新会话发完 Offer，这条迟到的 VIEWER_DISCONNECTED 才到——
            //   iOS 无条件拆会话（不带 epoch）→ 刚建的会话在 trickle ICE 之前被拆 → PC 收到
            //   Offer 却永远等不到远端候选 → 看门狗再重建 → 再竞态……（21:22:28~21:23:28 四连败实录）。
            //   语义修正：VIEWER_DISCONNECTED = "这台 PC 不再观看了"（退出登录/切设备/切账号），
            //   只在 resetStreamStateForSwitch 的主动清场里发；内部重连根本不是"不看了"。
            //   iOS 端幽灵会话的清理不依赖这条消息（PC_PRESENCE 4s 超时 + ICE 死亡检测 + §54 拆旧重发都在）。
            // 🔥 v14: 只在非连接过程中才重置 publishState（避免 stopAll 期间重置导致死循环）
            if (!isConnecting) {
                publishState = 0
            }
        }
        onWebrtcStatusChanged: function(status) {
            console.log("🌐 WebRTC 状态:", status)
            // 🔥 v14: 连接成功或正在播放时清除 isConnecting 标志
            if (status === "Connected" || status === "Playing" || status === "P2P Connected") {
                isConnecting = false
            }
            // 🔥 v14: 只在非连接过程中才重置 publishState（避免死循环）
            if (status === "Failed" || status === "Closed" || status === "Disconnected" || status === "P2P Hangup") {
                if (!isConnecting) {
                    console.log("🔄 WebRTC 状态异常，重置 publishState 以允许重连")
                    publishState = 0
                }
            }
        }
        
        // P2P 信令信号桥接 → WebSocket
        // ⭐ §53.25：全部带上本轮协商 epoch（gstPlayer.p2pEpoch()），设备端回带、双方按它丢过期轮次
        onSendSdpAnswer: function(sdp, toDevice) {
            console.log("[P2P-QML] 发送 Answer SDP 给 " + toDevice)
            WebSocketClient.sendWebRTCSignaling("WEBRTC_SDP", toDevice, "answer", sdp, "", "", -1, "", gstPlayer.p2pEpoch())
        }
        onSendIceCandidate: function(candidate, sdpMid, sdpMLineIndex, toDevice) {
            console.log("[P2P-QML] 发送 ICE 候选者给 " + toDevice)
            WebSocketClient.sendWebRTCSignaling("WEBRTC_ICE", toDevice, "", "", candidate, sdpMid, sdpMLineIndex, "", gstPlayer.p2pEpoch())
        }
        onSendHangup: function(reason, toDevice) {
            console.log("[P2P-QML] 发送挂断给 " + toDevice)
            WebSocketClient.sendWebRTCSignaling("WEBRTC_HANGUP", toDevice, "", "", "", "", -1, reason, gstPlayer.p2pEpoch())
        }
        onSendViewRequest: function(toDevice) {
            console.log("[P2P-QML] 发送观看请求给 " + toDevice + " epoch=" + gstPlayer.p2pEpoch())
            WebSocketClient.sendWebRTCSignaling("WEBRTC_REQUEST", toDevice, "", "", "", "", -1, "", gstPlayer.p2pEpoch())
        }
        
        // ⭐⭐⭐ 第二道防线：收到降帧请求，通知前端iOS调整推流帧率
        // v9.3 新增：urgency 紧急度 + reason 触发原因
        // v9.3 优化：根据【会员等级】+【当前档位】来决定可用的帧率档位
        // ⭐ 2026-08-14 简化：会员一律不限帧率（上限240），试用/未激活走 levelFps[0]
        //
        // 四档阶梯（服务器格式）：240(60fps) → 180(45fps) → 120(30fps) → 60(15fps)
        onRequestFpsChange: function(targetFps, urgency, reason) {
            // ⭐ 临时屏蔽（§21.11 iOS 自适应 fps 单测）：双缓冲第二道防线不再自动下发 set_fps
            if (mainPage.fpsAutoPushDisabled) {
                console.log("🚫 [fps单测] 双缓冲自动下发fps已屏蔽: targetFps=" + targetFps + " urgency=" + urgency + " reason=" + reason)
                return
            }
            // ⭐ 获取当前档位和会员等级信息
            var qualityType = iosCameraSettingsPopup.qualityType
            var level = mainPage.memberActivationLevel
            var maxFps = getMaxFpsForQuality(qualityType)
            var currentFps = iosCameraSettingsPopup.fpsValue  // 当前滑块值（服务器fps格式）
            
            console.log("📉 收到帧率调整请求:", targetFps, "fps | urgency=" + urgency + 
                       " | 档位=" + qualityType + " 等级=" + level + " 上限=" + maxFps)
            
            // ⭐ 根据等级和档位生成可用的四档阶梯
            // 服务器格式：240=60fps, 180=45fps, 120=30fps, 60=15fps
            var allTiers = [240, 180, 120, 60]
            var availableTiers = allTiers.filter(function(tier) { return tier <= maxFps })
            
            // 确保至少有最低档
            if (availableTiers.length === 0) {
                availableTiers = [60]
            }
            
            console.log("📊 可用档位:", JSON.stringify(availableTiers), 
                       "(最高=" + availableTiers[0] + " 最低=" + availableTiers[availableTiers.length - 1] + ")")
            
            var finalFps = currentFps
            
            if (targetFps === 0) {
                // ⭐ 恢复帧率：升到【当前等级+档位】允许的最高档
                finalFps = availableTiers[0]
                console.log("📈 恢复帧率: 当前=" + currentFps + " → 最高档=" + finalFps + 
                           " (等级" + level + " " + qualityType + "档位上限=" + maxFps + ")")
            } else {
                // ⭐ 降帧请求：targetFps 是实际帧率（如 30fps）
                var requestedServerFps = targetFps * 4  // 转换为服务器格式
                
                // 找到 <= requestedServerFps 的最高档位
                finalFps = availableTiers[availableTiers.length - 1]  // 默认最低档
                for (var i = 0; i < availableTiers.length; i++) {
                    if (availableTiers[i] <= requestedServerFps) {
                        finalFps = availableTiers[i]
                        break
                    }
                }
                
                // 确保不低于当前档位的最低值
                if (finalFps > currentFps) {
                    // 如果计算出的帧率比当前还高，说明要降帧，找下一档
                    var currentIndex = availableTiers.indexOf(currentFps)
                    if (currentIndex >= 0 && currentIndex < availableTiers.length - 1) {
                        finalFps = availableTiers[currentIndex + 1]  // 降一档
                    } else {
                        finalFps = availableTiers[availableTiers.length - 1]  // 最低档
                    }
                }
                
                console.log("📉 降帧: 目标=" + targetFps + "fps(服务器=" + requestedServerFps + 
                           ") 当前=" + currentFps + " → 最终=" + finalFps +
                           " | 等级" + level + " " + qualityType + "档")
            }
            
            // 如果帧率没变且不是恢复请求，不发送
            if (finalFps === currentFps && targetFps !== 0) {
                console.log("⏸️ 帧率未变化(" + finalFps + ")，跳过发送")
                return
            }
            
            // 更新本地状态（滑块显示自适应算出的值，不受 AI 锁影响）
            iosCameraSettingsPopup.fpsValue = finalFps
            fpsSlider.value = finalFps
            
            // ⭐ v9.3: 同步帧率给 gstPlayer（用于网络质量检测，按滑块显示值算，不按下发钉死值）
            gstPlayer.setConfigFps(finalFps / 4)  // 服务器fps转实际fps
            
            // ⭐ AI 工具锁 30：只影响实际下发值，不影响上面滑块显示的 finalFps
            var sendFps = resolveSendFps(finalFps)
            // ⭐⭐⭐ v9.3 发送带 urgency 的 set_fps 命令
            var fpsPayload = {
                "cmd": "set_fps",
                "fps": sendFps,  // 服务器 fps 格式
                "urgency": urgency || "normal",
                "reason": reason || "manual",
                "timestamp": Date.now()
            }
            
            // 通过 HTTP 和 WebSocket 发送
            HttpClient.updateFps(sendFps)
            sendConfigUpdate("fps", fpsPayload)
            console.log("📤 已发送set_fps到iOS:", JSON.stringify(fpsPayload), 
                       "| 等级" + level + " " + qualityType + "档")
        }
    }
    
    CaptureManager {
        id: captureManager
        objectName: "captureManager"
        gpuPipeline: gpuPipeline
        gstPlayer: gstPlayer  // GStreamer 播放器（JPEG 读取）
        videoRotation: mainPage.videoRotation  // 同步视频旋转角度
        videoZoom: mainPage.videoZoom          // 同步视频缩放
        videoOffsetX: mainPage.videoOffsetX    // 同步缩放偏移X
        videoOffsetY: mainPage.videoOffsetY    // 同步缩放偏移Y
        displayWidth: videoContainer.width     // 显示区域宽度
        displayHeight: videoContainer.height   // 显示区域高度
        onGridRowsChanged: rowsInput.currentIndex = gridRows - 1
        onGridColsChanged: colsInput.currentIndex = gridCols - 1
        onPreFrameCountChanged: {
            // model: ["10", "15", "20", "30", "40", "50", "60", "80", "100", "120"]  最大120
            var map = {"10": 0, "15": 1, "20": 2, "30": 3, "40": 4, "50": 5, "60": 6, "80": 7, "100": 8, "120": 9}
            preFramesInput.currentIndex = map[preFrameCount.toString()] ?? 9  // 默认120
        }
        onPostFrameCountChanged: {
            var map = {"10": 0, "15": 1, "20": 2, "30": 3, "40": 4, "50": 5, "60": 6, "80": 7, "100": 8, "120": 9, "150": 10, "180": 11, "200": 12, "240": 13, "1000": 14}
            postFramesInput.currentIndex = map[postFrameCount.toString()] ?? 0
        }
    }
    
    // ============ EventBus 连接（因为通过 Loader 加载，需要在这里连接）============
    Connections {
        target: EventBus
        function onCaptureTriggered() {
            // ⭐ 抓拍时保存当前缩放状态，新 item 将继承这个缩放
            // ⭐ 2026-08-14：PC 端已改单版本，去掉「豪华版不保存缩放」的等级门槛，一律继承
            var nextIndex = captureManager.count  // 下一个 item 的索引
            {
                // ⭐ 抓拍继承实时流缩放：按实时流容器尺寸换算成归一化分量存入（与 item/单个放大同一套）
                var z = mainPage.videoZoom
                var fx = 0, fy = 0
                if (z > 1.0 && videoContainer.width > 0 && videoContainer.height > 0) {
                    var mx = videoContainer.width * (z - 1) / 2
                    var my = videoContainer.height * (z - 1) / 2
                    fx = mx > 0 ? Math.max(-1, Math.min(1, mainPage.videoOffsetX / mx)) : 0
                    fy = my > 0 ? Math.max(-1, Math.min(1, mainPage.videoOffsetY / my)) : 0
                }
                mainPage.saveItemZoomNorm(nextIndex, z, fx, fy)
            }
            captureManager.zoomLog("📸 抓拍保存: index=" + nextIndex + " zoom=" + mainPage.videoZoom + " offsetX=" + mainPage.videoOffsetX + " offsetY=" + mainPage.videoOffsetY + " pcLevel=" + mainPage.pcActivationLevel)
            captureManager.zoomLog("📸 itemZoomMap: " + JSON.stringify(mainPage.itemZoomMap))
            
            captureManager.capture()
        }
        function onClearTriggered() {
            // ⭐ 清空缩放记录
            mainPage.itemZoomMap = {}
            
            // 先退出抓拍全屏状态
            if (mainPage.gridFullscreenMode) {
                mainPage.gridFullscreenMode = false
                console.log("🖥️ 抓拍清空：退出抓拍grid全屏")
            }
            // 如果处于单个抓拍项全屏查看状态，也关闭
            if (fullscreenViewerVisible) {
                closeFullscreenViewer()
                console.log("🖥️ 抓拍清空：关闭全屏查看")
            }
            // ⭐ 如果列查看器打开，也关闭
            if (columnPreviewVisible) {
                columnPreviewVisible = false
                console.log("🖥️ 抓拍清空：关闭列查看器")
            }
            // 弹框确认
            if (captureManager.count > 0) {
                clearCaptureConfirmDialog.open()
            }
        }
    }
    
    // 监听抓拍完成事件，检查是否需要自动全屏
    Connections {
        target: captureManager
        function onCaptureComplete(index) {
            // 抓拍完成后检查是否需要自动全屏
            // ⭐ PC等级2(AI全能版)才能自动触发抓拍全屏，pc=1不允许自动触发
            console.log("[抓拍全屏] onCaptureComplete: autoFullscreenOnCaptureFull=" + mainPage.autoFullscreenOnCaptureFull + ", count=" + captureManager.count + ", pcLevel=" + mainPage.pcActivationLevel)
            
            // PC等级检查：只有pc=2才能自动触发
            if (mainPage.pcActivationLevel < 2) {
                console.log("[抓拍全屏] PC等级1不允许自动触发抓拍全屏")
                return
            }
            
            if (mainPage.autoFullscreenOnCaptureFull) {
                var targetCount = captureManager.gridRows * captureManager.gridCols
                console.log("[抓拍全屏] 目标数量: " + targetCount + ", 当前数量: " + captureManager.count)
                
                if (captureManager.count === targetCount && targetCount > 0) {
                    if (!mainPage.gridFullscreenMode) {
                        console.log("[抓拍全屏] 准备自动全屏，当前 gridFullscreenMode=" + mainPage.gridFullscreenMode + ", pcLevel=" + mainPage.pcActivationLevel)
                        mainPage.gridFullscreenMode = true
                        console.log("[抓拍全屏] 达到", targetCount, "个，自动全屏成功 (pcLevel=" + mainPage.pcActivationLevel + ", gridFullscreenMode=" + mainPage.gridFullscreenMode + ")")
                    } else {
                        console.log("[抓拍全屏] 已经处于全屏模式，跳过")
                    }
                } else {
                    console.log("[抓拍全屏] 数量未达到目标: " + captureManager.count + " != " + targetCount)
                }
            } else {
                console.log("[抓拍全屏] 自动全屏开关未开启")
            }
        }
        function onFrameImageReady(itemIndex, frameOffset) {
            // ⭐ 全屏：目标帧解码完成 → 推进显示帧（未缓存时保持旧画面, 此刻才换, 无白屏）
            if (mainPage.fullscreenViewerVisible
                    && itemIndex === mainPage.fullscreenItemIndex
                    && frameOffset === mainPage.fullscreenFrameIndex) {
                mainPage.fullscreenDisplayFrame = frameOffset
                mainPage.fullscreenRefreshToken = Date.now()
            }
            // ⭐ A键放大：目标帧解码完成 → 推进显示帧
            if (mainPage.columnPreviewZoomItemIdx >= 0
                    && mainPage.columnPreviewZoomItemIdx < mainPage.columnPreviewItems.length
                    && mainPage.columnPreviewItems[mainPage.columnPreviewZoomItemIdx] === itemIndex
                    && frameOffset === mainPage.columnPreviewZoomFrame) {
                mainPage.columnPreviewZoomDisplayFrame = frameOffset
                mainPage.columnPreviewRefreshToken = Date.now()
            }
            // ⭐ 列预览：对应 item 的目标帧解码完成 → 推进该 item 的显示帧
            if (mainPage.columnPreviewVisible && mainPage.columnPreviewItems.length > 0) {
                for (var i = 0; i < mainPage.columnPreviewItems.length; i++) {
                    if (mainPage.columnPreviewItems[i] === itemIndex
                            && mainPage.columnPreviewFrames[i] === frameOffset) {
                        var disp = mainPage.columnPreviewDisplayFrames.slice()
                        disp[i] = frameOffset
                        mainPage.columnPreviewDisplayFrames = disp
                        mainPage.columnPreviewRefreshToken = Date.now()
                        break
                    }
                }
            }
        }
    }
    
    SlowMotionPlayer {
        id: slowMotionPlayer
        objectName: "slowMotionPlayer"
        gpuPipeline: gpuPipeline
        gstPlayer: gstPlayer  // GStreamer 播放器（JPEG 读取）
        // 不再需要 onFrameReady，Image 通过 ImageProvider 自动获取帧
    }
    
    // EventBus 连接 SlowMotionPlayer
    Connections {
        target: EventBus
        function onSlowmoToggleTriggered() {
            // 根据状态切换
            if (slowMotionPlayer.state === SlowMotionPlayer.IDLE) {
                slowMotionPlayer.startRecording()
                captureManager.slowMotionActive = true  // 开启慢放抓拍模式
            } else if (slowMotionPlayer.state === SlowMotionPlayer.RECORDING) {
                slowMotionPlayer.stopRecording()
            } else {
                slowMotionPlayer.togglePlay()
            }
        }
        function onNextFrameTriggered() {
            slowMotionPlayer.nextFrame()
        }
        function onPrevFrameTriggered() {
            slowMotionPlayer.prevFrame()
        }
    }

    // ============ 顶部菜单栏 ============
    // ⭐ 2026-08-14 配色对齐 java gstream：深色标题栏 #1F1F1F，文字 #FAFAFA
    Rectangle {
        id: topMenuBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        color: "#1F1F1F"
        
        // 窗口拖动区域（z=0，在菜单项之下）
        MouseArea {
            id: dragArea
            anchors.fill: parent
            z: 0
            property point clickPos: Qt.point(0, 0)
            
            onPressed: function(mouse) {
                mainPage.forceActiveFocus()  // ⭐ 点击导航栏时恢复焦点
                clickPos = Qt.point(mouse.x, mouse.y)
            }
            
            onPositionChanged: function(mouse) {
                if (pressed) {
                    var delta = Qt.point(mouse.x - clickPos.x, mouse.y - clickPos.y)
                    var newX = mainWindow.x + delta.x
                    var newY = mainWindow.y + delta.y
                    
                    // ⭐ 边界限制：确保窗口不会完全移出屏幕
                    // 至少保留 100 像素在屏幕内
                    var minVisible = 100
                    newX = Math.max(-mainWindow.width + minVisible, Math.min(newX, Screen.width - minVisible))
                    newY = Math.max(0, Math.min(newY, Screen.height - minVisible))  // 顶部不能超出
                    
                    mainWindow.x = newX
                    mainWindow.y = newY
                }
            }
            
            onDoubleClicked: toggleFullscreen()
        }
        
        RowLayout {
            z: 1  // 在拖动区域之上
            anchors.fill: parent
            anchors.leftMargin: 12  // ⭐ 2026-08-14 对齐 java gstream：菜单按钮距左 12
            anchors.rightMargin: 10  // 减小右边距，让头像能靠近右边缘
            spacing: 0
            
            // ===== 左侧菜单项 =====
            RowLayout {
                Layout.fillHeight: true
                spacing: 16  // ⭐ 2026-08-14 对齐 java gstream titleBar spacing=16
                
                // 菜单下拉按钮（⭐ 2026-08-14 对齐 java gstream：frame 图标 +「菜单」+ 下拉箭头）
                Rectangle {
                    id: windowLayoutText
                    width: menuBtnRow.width + 24
                    height: 32
                    radius: 8
                    color: menuBtnArea.containsMouse || windowLayoutMenu.visible ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Row {
                        id: menuBtnRow
                        anchors.centerIn: parent
                        spacing: 4
                        
                        Image {
                            source: "images/frame.png"
                            width: 16; height: 16
                            anchors.verticalCenter: parent.verticalCenter
                            smooth: true
                        }
                        Text {
                            text: "菜单"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#FAFAFA"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Image {
                            source: "images/down.png"
                            width: 8; height: 4
                            anchors.verticalCenter: parent.verticalCenter
                            smooth: true
                        }
                    }
                    
                    MouseArea {
                        id: menuBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: windowLayoutMenu.open()
                    }
                    
                    Menu {
                        id: windowLayoutMenu
                        y: windowLayoutText.height + 4
                        width: 200
                        
                        // ⭐ 2026-08-14 弹框样式对齐 java gstream（.no-arrow-menu .context-menu）
                        background: Rectangle {
                            implicitWidth: 200
                            color: "#292929"
                            radius: 8
                            border.color: "#3A3A3A"
                            border.width: 1
                        }
                        
                        // ⭐ 抓拍全屏菜单项（2026-08-14 需求：老 java gstream 没有 → 不显示，代码保留）
                        Repeater {
                            model: 0
                            delegate: DarkMenuItem {
                                text: "抓拍全屏 (" + ShortcutStore.gridFullscreenKey + ")"
                                onTriggered: toggleGridFullscreen()
                                
                                Component.onCompleted: {
                                    console.log("[抓拍全屏] Repeater 创建菜单项，pcActivationLevel:", mainPage.pcActivationLevel)
                                }
                            }
                        }
                        
                        DarkMenuItem {
                            text: "实时窗口切换 (" + ShortcutStore.realtimeWindowKey + ")"
                            onTriggered: swapRealtimeWindow()
                        }
                        DarkMenuItem {
                            text: "慢放窗口切换 (" + ShortcutStore.slowmoWindowKey + ")"
                            onTriggered: swapSlowmoWindow()
                        }
                        MenuSeparator {
                            contentItem: Rectangle {
                                implicitHeight: 1
                                color: "#3A3A3A"
                            }
                        }
                        DarkMenuItem {
                            text: "快捷键说明"
                            onTriggered: shortcutHelpPopup.open()
                        }
                    }
                }
                
                // 设备绑定（⭐ 2026-08-14 对齐 java gstream：sbbd 图标 +「绑定」）
                Rectangle {
                    id: deviceBindText
                    width: bindBtnRow.width + 24
                    height: 32
                    radius: 8
                    color: bindBtnArea.containsMouse || bindMenu.visible ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Row {
                        id: bindBtnRow
                        anchors.centerIn: parent
                        spacing: 4
                        
                        Image {
                            source: "images/sbbd.png"
                            width: 16; height: 16
                            anchors.verticalCenter: parent.verticalCenter
                            smooth: true
                        }
                        Text {
                            text: "绑定"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#FAFAFA"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    
                    MouseArea {
                        id: bindBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: bindMenu.open()
                    }
                    
                    // 绑定菜单（⭐ 2026-08-14 弹框样式对齐 java gstream）
                    Menu {
                        id: bindMenu
                        y: deviceBindText.height + 4
                        width: 110
                        
                        background: Rectangle {
                            implicitWidth: 110
                            color: "#292929"
                            radius: 8
                            border.color: "#3A3A3A"
                            border.width: 1
                        }
                        
                        DarkMenuItem {
                            text: "扫码绑定"
                            onTriggered: showScanBindPopup()
                        }
                        DarkMenuItem {
                            text: "手动绑定"
                            onTriggered: manualBindDialog.open()
                        }
                    }
                }
                
                // 相机设定（⭐ 2026-08-14 对齐 java gstream：xjsd 图标 +「相机」；OTG 外接时隐藏）
                Rectangle {
                    id: cameraSettingText
                    visible: !CameraCapsStore.isOtg
                    width: cameraBtnRow.width + 24
                    height: 32
                    radius: 8
                    color: cameraBtnArea.containsMouse ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Row {
                        id: cameraBtnRow
                        anchors.centerIn: parent
                        spacing: 4
                        
                        Image {
                            source: "images/xjsd.png"
                            width: 16; height: 16
                            anchors.verticalCenter: parent.verticalCenter
                            smooth: true
                        }
                        Text {
                            text: "相机"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#FAFAFA"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: cameraBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: showIosCameraSettings()
                    }
                }

                // ⭐ 第五十章：外接摄像头设定（只在连着 OTG 设备时出现；面板按设备上报能力动态生成）
                Text {
                    id: otgCameraSettingText
                    visible: CameraCapsStore.isOtg
                    text: "外接摄像头设定(O)"
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#81C784"

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: toggleOtgCameraPanel()
                    }
                }

                // ⭐ iOS 滤镜入口已隐藏 — 快捷键 P 替代菜单项, 见 Shortcut "P"

                // 抓拍全屏开关（2026-08-14 需求：菜单栏不再显示，功能逻辑保留）
                Row {
                    visible: false
                    spacing: 6
                    
                    Text {
                        text: "抓拍全屏"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FAFAFA"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    
                    Rectangle {
                        id: autoFullscreenSwitch
                        width: 40
                        height: 22
                        radius: 11
                        color: mainPage.autoFullscreenOnCaptureFull ? "#4CAF50" : "#90A4AE"
                        anchors.verticalCenter: parent.verticalCenter
                        
                        Rectangle {
                            width: 18
                            height: 18
                            radius: 9
                            color: "#FFFFFF"
                            x: mainPage.autoFullscreenOnCaptureFull ? parent.width - width - 2 : 2
                            anchors.verticalCenter: parent.verticalCenter
                            
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mainPage.autoFullscreenOnCaptureFull = !mainPage.autoFullscreenOnCaptureFull
                        }
                    }
                }
                
                // 横向/纵向切换（⭐ 2026-08-14 对齐 java gstream：hxpl 图标 +「横向排列/纵向排列」）
                Rectangle {
                    width: arrangeBtnRow.width + 24
                    height: 32
                    radius: 8
                    color: arrangeBtnArea.containsMouse ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Row {
                        id: arrangeBtnRow
                        anchors.centerIn: parent
                        spacing: 4
                        
                        Image {
                            source: "images/hxpl.png"
                            width: 16; height: 16
                            anchors.verticalCenter: parent.verticalCenter
                            smooth: true
                        }
                        Text {
                            text: captureManager.isHorizontalLayout ? "横向排列" : "纵向排列"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#FAFAFA"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    
                    MouseArea {
                        id: arrangeBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: captureManager.isHorizontalLayout = !captureManager.isHorizontalLayout
                    }
                }

                // 全屏模式开关（⭐ 2026-08-14 还原：对齐 java gstream 的「全屏（关/开）」按钮，qp 图标。
                //   对应 A 键抓拍放大的显示方式：开=全屏显示，关=只覆盖截图框区域（halfScreenViewMode 取反））
                Rectangle {
                    width: fsModeBtnRow.width + 24
                    height: 32
                    radius: 8
                    color: fsModeBtnArea.containsMouse ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Row {
                        id: fsModeBtnRow
                        anchors.centerIn: parent
                        spacing: 4
                        
                        Image {
                            source: "images/qp.png"
                            width: 16; height: 16
                            anchors.verticalCenter: parent.verticalCenter
                            smooth: true
                        }
                        Text {
                            text: appSettings.halfScreenViewMode ? "全屏（关）" : "全屏（开）"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#FAFAFA"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    
                    MouseArea {
                        id: fsModeBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            appSettings.halfScreenViewMode = !appSettings.halfScreenViewMode
                            console.log("📺 放大查看模式:", appSettings.halfScreenViewMode ? "半屏(截图框)" : "全屏")
                        }
                        
                        ToolTip.visible: containsMouse
                        ToolTip.text: "抓拍放大显示方式：开=全屏显示，关=只覆盖截图框区域"
                        ToolTip.delay: 300
                    }
                }
                
                // 截图质量下拉列表（已改用H.264 IDR编码，JPEG质量参数不再生效，隐藏）
                Row {
                    visible: false
                    spacing: 4
                    height: parent.height
                    
                    Text {
                        id: jpegQualityLabel
                        text: "截图质量"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        anchors.verticalCenter: parent.verticalCenter
                        
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            ToolTip.visible: containsMouse
                            ToolTip.text: "质量越高 电脑配置越高"
                            ToolTip.delay: 300
                        }
                    }
                    
                    ComboBox {
                        id: jpegQualityCombo
                        width: 55
                        height: 22
                        anchors.verticalCenter: parent.verticalCenter
                        
                        // AI全能版(2): 60-100 步进5；豪华版(1)及以下: 只有60
                        model: mainPage.pcActivationLevel >= 2 ? [60, 65, 70, 75, 80, 85, 90, 95, 100] : [60]
                        
                        // ⭐ 从本地设置读取对应 index
                        currentIndex: {
                            if (mainPage.pcActivationLevel >= 2) {
                                // AI全能版：计算 index: (value - 60) / 5，确保在有效范围
                                var savedQ = Math.max(60, Math.min(100, appSettings.screenshotQuality))
                                return Math.max(0, Math.min(8, (savedQ - 60) / 5))
                            } else {
                                return 0  // 豪华版只有60，固定index 0
                            }
                        }
                        
                        // 豪华版禁用下拉（只有一个选项）
                        enabled: mainPage.pcActivationLevel >= 2
                        
                        Component.onCompleted: {
                            // 启动时应用保存的截图质量（强制最低60）
                            var quality = Math.max(60, appSettings.screenshotQuality)
                            gstPlayer.setJpegQuality(quality)
                            appSettings.screenshotQuality = quality
                            console.log("📸 截图质量已恢复:", quality)
                        }
                        
                        onCurrentValueChanged: {
                            gstPlayer.setJpegQuality(currentValue)
                            // ⭐ 保存到本地设置
                            appSettings.screenshotQuality = currentValue
                            console.log("📸 截图质量调整为:", currentValue, "(已保存)")
                        }
                        
                        // 自定义外观
                        background: Rectangle {
                            color: jpegQualityCombo.down ? "#C8E6C9" : "#E8F5E9"
                            border.color: "#A5D6A7"
                            border.width: 1
                            radius: 3
                        }
                        
                        contentItem: Text {
                            leftPadding: 6
                            text: jpegQualityCombo.displayText
                            font.family: "Consolas"
                            font.pixelSize: 12
                            color: "#263238"
                            verticalAlignment: Text.AlignVCenter
                        }
                        
                        indicator: Text {
                            x: jpegQualityCombo.width - width - 6
                            y: (jpegQualityCombo.height - height) / 2
                            text: "▼"
                            font.pixelSize: 8
                            color: "#546E7A"
                        }
                    }
                }
                
                // ⭐ 放大查看模式开关（A键放大）（2026-08-14 需求：菜单栏不再显示，功能逻辑保留）
                Row {
                    visible: false
                    spacing: 4
                    height: parent.height
                    
                    Text {
                        text: "半屏"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FAFAFA"
                        anchors.verticalCenter: parent.verticalCenter
                        
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            ToolTip.visible: containsMouse
                            ToolTip.text: "A键放大查看模式：关闭=全屏，打开=覆盖截图区域"
                            ToolTip.delay: 300
                        }
                    }
                    
                    // 开关控件
                    Rectangle {
                        id: halfScreenSwitch
                        width: 36
                        height: 18
                        radius: 9
                        anchors.verticalCenter: parent.verticalCenter
                        color: appSettings.halfScreenViewMode ? "#4CAF50" : "#B0BEC5"
                        
                        Rectangle {
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                            x: appSettings.halfScreenViewMode ? parent.width - width - 2 : 2
                            anchors.verticalCenter: parent.verticalCenter
                            
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                appSettings.halfScreenViewMode = !appSettings.halfScreenViewMode
                                console.log("📺 放大查看模式:", appSettings.halfScreenViewMode ? "半屏" : "全屏")
                            }
                        }
                    }
                }

                // ⭐ AI 牌位置放大开关
                //   aihj 版：AI 牌识别整套下线，开关隐藏不可达（源码保留，QtQuick.Row 会
                //   自动把 visible:false 的子项排除出布局，不占位）。
                Row {
                    visible: false
                    spacing: 4
                    height: parent.height

                    Text {
                        text: "自动放大"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        anchors.verticalCenter: parent.verticalCenter

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            ToolTip.visible: containsMouse
                            ToolTip.text: "AI牌位置放大：开启后滚动到哪一帧就识别哪一帧，放大居中到牌位（CPU 推理，不影响实时流；识别不到的帧保持上一帧放大）"
                            ToolTip.delay: 300
                        }
                    }

                    // 开关控件
                    Rectangle {
                        id: aiCardZoomSwitch
                        width: 36
                        height: 18
                        radius: 9
                        anchors.verticalCenter: parent.verticalCenter
                        color: captureManager.aiCardZoomEnabled ? "#4CAF50" : "#B0BEC5"

                        Rectangle {
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                            x: captureManager.aiCardZoomEnabled ? parent.width - width - 2 : 2
                            anchors.verticalCenter: parent.verticalCenter

                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                captureManager.aiCardZoomEnabled = !captureManager.aiCardZoomEnabled
                                console.log("🃏 AI牌位置放大:", captureManager.aiCardZoomEnabled ? "开启" : "关闭")
                            }
                        }
                    }

                    // 2026-07-06 改为「每帧独立识别」：滚动到哪帧就识别哪帧，
                    //   去掉了原「前/后 影响帧数」传播张数下拉（不再需要）。
                }
                
                // ⭐ 快捷键说明按钮（2026-08-14 对齐 java gstream：kjjsz 图标 +「快捷键」）
                Rectangle {
                    width: shortcutBtnRow.width + 24
                    height: 32
                    radius: 8
                    color: shortcutBtnArea.containsMouse ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Row {
                        id: shortcutBtnRow
                        anchors.centerIn: parent
                        spacing: 4
                        
                        Image {
                            source: "images/kjjsz.png"
                            width: 16; height: 16
                            anchors.verticalCenter: parent.verticalCenter
                            smooth: true
                        }
                        Text {
                            id: shortcutBtnText
                            text: "快捷键"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#FAFAFA"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    
                    MouseArea {
                        id: shortcutBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: shortcutHelpPopup.open()
                    }
                }

                // ⭐ 2026-08-14：行/列/前(预抓拍张数)/后(后抓拍张数) 从右下控制面板挪到顶部菜单栏，
                //   样式对齐 java gstream 标题栏的「行：5 / 列：5 / 前：10 / 后：10」深色下拉按钮
                Row {
                spacing: 8
                Layout.alignment: Qt.AlignVCenter

                // 行
                Rectangle {
                    width: rowBtnLabel.width + 16
                    height: 24
                    radius: 8
                    color: rowBtnArea.containsMouse || rowsInput.popup.visible ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        id: rowBtnLabel
                        anchors.centerIn: parent
                        text: "行：" + captureManager.gridRows
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FAFAFA"
                    }

                    MouseArea {
                        id: rowBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: rowsInput.popup.open()
                        onWheel: function(wheel) {
                            if (wheel.angleDelta.y > 0 && rowsInput.currentIndex > 0) {
                                rowsInput.currentIndex--
                            } else if (wheel.angleDelta.y < 0 && rowsInput.currentIndex < rowsInput.count - 1) {
                                rowsInput.currentIndex++
                            }
                            pendingRows = parseInt(rowsInput.currentText)
                            gridUpdateTimer.restart()
                        }
                    }

                    ComboBox {
                        id: rowsInput
                        anchors.fill: parent
                        visible: false
                        model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
                        currentIndex: captureManager.gridRows - 1
                        onActivated: captureManager.gridRows = parseInt(currentText)
                    }
                }

                // 列
                Rectangle {
                    width: colBtnLabel.width + 16
                    height: 24
                    radius: 8
                    color: colBtnArea.containsMouse || colsInput.popup.visible ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        id: colBtnLabel
                        anchors.centerIn: parent
                        text: "列：" + captureManager.gridCols
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FAFAFA"
                    }

                    MouseArea {
                        id: colBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: colsInput.popup.open()
                        onWheel: function(wheel) {
                            if (wheel.angleDelta.y > 0 && colsInput.currentIndex > 0) {
                                colsInput.currentIndex--
                            } else if (wheel.angleDelta.y < 0 && colsInput.currentIndex < colsInput.count - 1) {
                                colsInput.currentIndex++
                            }
                            pendingCols = parseInt(colsInput.currentText)
                            gridUpdateTimer.restart()
                        }
                    }

                    ComboBox {
                        id: colsInput
                        anchors.fill: parent
                        visible: false
                        model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
                        currentIndex: captureManager.gridCols - 1
                        onActivated: captureManager.gridCols = parseInt(currentText)
                    }
                }

                // 前（预抓拍张数）
                Rectangle {
                    width: preBtnLabel.width + 16
                    height: 24
                    radius: 8
                    color: preBtnArea.containsMouse || preFramesInput.popup.visible ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        id: preBtnLabel
                        anchors.centerIn: parent
                        text: "前：" + captureManager.preFrameCount
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FAFAFA"
                    }

                    MouseArea {
                        id: preBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: preFramesInput.popup.open()
                        onWheel: function(wheel) {
                            if (wheel.angleDelta.y > 0 && preFramesInput.currentIndex > 0) {
                                preFramesInput.currentIndex--
                            } else if (wheel.angleDelta.y < 0 && preFramesInput.currentIndex < preFramesInput.count - 1) {
                                preFramesInput.currentIndex++
                            }
                            captureManager.preFrameCount = parseInt(preFramesInput.currentText)
                        }
                    }

                    ComboBox {
                        id: preFramesInput
                        anchors.fill: parent
                        visible: false
                        model: ["10", "15", "20", "30", "40", "50", "60", "80", "100", "120"]  // 最大120
                        onActivated: {
                            captureManager.preFrameCount = parseInt(currentText)
                        }

                        function syncIndex() {
                            var val = captureManager.preFrameCount
                            if (val > 120) val = 120  // 限制最大120
                            var valStr = val.toString()
                            for (var i = 0; i < model.length; i++) {
                                if (model[i] === valStr) { currentIndex = i; return; }
                            }
                            // 找最接近的值
                            for (var j = model.length - 1; j >= 0; j--) {
                                if (parseInt(model[j]) <= val) { currentIndex = j; return; }
                            }
                            currentIndex = 0
                        }

                        Component.onCompleted: syncIndex()

                        Connections {
                            target: captureManager
                            function onPreFrameCountChanged() { preFramesInput.syncIndex() }
                        }
                    }
                }

                // 后（后抓拍张数）
                Rectangle {
                    width: postBtnLabel.width + 16
                    height: 24
                    radius: 8
                    color: postBtnArea.containsMouse || postFramesInput.popup.visible ? "#3A3A3A" : "#292929"
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        id: postBtnLabel
                        anchors.centerIn: parent
                        text: "后：" + (captureManager.postFrameCount >= 1000 ? "无限" : captureManager.postFrameCount)
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FAFAFA"
                    }

                    MouseArea {
                        id: postBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: postFramesInput.popup.open()
                        onWheel: function(wheel) {
                            if (wheel.angleDelta.y > 0 && postFramesInput.currentIndex > 0) {
                                postFramesInput.currentIndex--
                            } else if (wheel.angleDelta.y < 0 && postFramesInput.currentIndex < postFramesInput.count - 1) {
                                postFramesInput.currentIndex++
                            }
                            var text = postFramesInput.currentText
                            captureManager.postFrameCount = (text === "无限") ? 1000 : parseInt(text)
                        }
                    }

                    ComboBox {
                        id: postFramesInput
                        anchors.fill: parent
                        visible: false
                        model: ["10", "15", "20", "30", "40", "50", "60", "80", "100", "120", "150", "180", "200", "240", "无限"]
                        onActivated: {
                            var text = currentText
                            captureManager.postFrameCount = (text === "无限") ? 1000 : parseInt(text)
                        }

                        function syncIndex() {
                            var val = captureManager.postFrameCount
                            if (val >= 1000) { currentIndex = model.length - 1; return; }
                            var valStr = val.toString()
                            for (var i = 0; i < model.length; i++) {
                                if (model[i] === valStr) { currentIndex = i; return; }
                            }
                            // 找最接近的值
                            for (var j = model.length - 2; j >= 0; j--) {
                                if (parseInt(model[j]) <= val) { currentIndex = j; return; }
                            }
                            currentIndex = 0
                        }

                        Component.onCompleted: syncIndex()

                        Connections {
                            target: captureManager
                            function onPostFrameCountChanged() { postFramesInput.syncIndex() }
                        }
                    }
                }
                }

                // ⭐ AI自动识别按钮（2026-06-24：按需求隐藏顶部菜单栏入口，功能为「敬请期待」占位，先不展示）
                Rectangle {
                    visible: false
                    width: aiBtnText.width + 16
                    height: 24
                    radius: 4
                    color: aiBtnArea.containsMouse ? "#C8E6C9" : "#E8F5E9"
                    border.color: "#A5D6A7"
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Text {
                        id: aiBtnText
                        anchors.centerIn: parent
                        text: "AI自动识别"
                        font.family: "PingFang HK"
                        font.pixelSize: 12
                        color: "#263238"
                    }
                    
                    MouseArea {
                        id: aiBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            aiComingSoonTip.visible = true
                            aiComingSoonTimer.restart()
                        }
                        
                        ToolTip.visible: containsMouse
                        ToolTip.text: "敬请期待"
                        ToolTip.delay: 300
                    }
                    
                    // "敬请期待"提示
                    Rectangle {
                        id: aiComingSoonTip
                        visible: false
                        width: aiTipText.width + 20
                        height: 28
                        radius: 6
                        color: "#333333"
                        anchors.top: parent.bottom
                        anchors.topMargin: 6
                        anchors.horizontalCenter: parent.horizontalCenter
                        
                        Text {
                            id: aiTipText
                            anchors.centerIn: parent
                            text: "敬请期待"
                            font.family: "PingFang HK"
                            font.pixelSize: 13
                            color: "#FFFFFF"
                        }
                        
                        Timer {
                            id: aiComingSoonTimer
                            interval: 2000
                            onTriggered: aiComingSoonTip.visible = false
                        }
                    }
                }

                // ⭐ 「内核测试」对比浮窗按钮已移除（2026-06-24）：
                //   网页内核已升级为登录页可选的「主播放内核」（见 LoginPage 播放内核开关 +
                //   livePanel 内 kernelPlayerLoader），不再需要顶部对比浮窗入口。
                //   浮窗本体 kernelTestOverlay 暂保留但无入口触发（P2P 退场逻辑仍在），后续可清理。

                // ⭐ 滚轮帧数显示已挪到底部状态栏右侧（对齐 java gstream 的 scrollFrameLabel 位置）

            }
            
            // 中间弹性空间
            Item { Layout.fillWidth: true }

            // 版本号（⭐ 2026-08-14：顶部不再显示，代码保留）
            Text {
                visible: false
                text: "v" + AutoUpdater.currentVersion
                font.family: "Consolas"
                font.pixelSize: 11
                color: "#78909C"
                anchors.verticalCenter: parent.verticalCenter
            }

            // ===== 等级信息 + 到期天数（点击弹出版本说明）=====
            Text {
                visible: mainPage.pcActivationLevel >= 1
                text: {
                    // §57.1：一律本地按等级映射，不用后端下发的 pcLevelName（那边内部仍叫「至尊版」）
                    var name = mainPage.pcActivationLevel >= 2 ? "AI全能版" : "豪华版"
                    if (mainPage.pcActivationLevel >= 2 && mainPage.pcExpireAt && mainPage.pcExpireAt !== "" && mainPage.pcExpireAt !== "null") {
                        var expDate = new Date(mainPage.pcExpireAt)
                        var now = new Date()
                        var daysLeft = Math.ceil((expDate - now) / (1000 * 60 * 60 * 24))
                        if (daysLeft < 0) return name + " 已到期"
                        if (daysLeft === 0) return name + " 今天到期"
                        return name + " " + daysLeft + "天"
                    }
                    return name
                }
                font.family: "PingFang HK"
                font.pixelSize: 11
                font.weight: Font.Medium
                color: {
                    if (mainPage.pcActivationLevel >= 2 && mainPage.pcExpireAt && mainPage.pcExpireAt !== "" && mainPage.pcExpireAt !== "null") {
                        var expDate2 = new Date(mainPage.pcExpireAt)
                        var now2 = new Date()
                        var days = Math.ceil((expDate2 - now2) / (1000 * 60 * 60 * 24))
                        if (days <= 7) return "#EF5350"
                        if (days <= 30) return "#FFB74D"
                    }
                    return "#CCCCCC"
                }
                anchors.verticalCenter: parent.verticalCenter
                
                MouseArea {
                    id: levelInfoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: versionCompareDialog.open()
                }
            }

            Item { width: 8 }

            // ===== 右侧操作区（⭐ 2026-08-14 调整）：头像 | 全屏 | 最小化 | 关闭 =====
            Row {
                spacing: 12
                height: 32
                
                // ⭐ 2026-08-14：iOS 设备状态信息（在线/FPS/码率/电量/网络）已整体搬到底部状态栏
                //   bottomStatusBar（对齐 java gstream 的底部布局），顶部只留 PC 端操作类按钮。

                // 头像（放在全屏左边；最小化/关闭已移出菜单变成独立按钮）
                Rectangle {
                    width: 32
                    height: 32
                    radius: 16
                    color: "transparent"
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Image {
                        anchors.fill: parent
                        source: "images/head.png"
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                    
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: avatarMenu.open()
                    }
                    
                    Menu {
                        id: avatarMenu
                        y: parent.height + 5
                        width: 110
                        
                        // ⭐ 2026-08-14 弹框样式对齐 java gstream
                        background: Rectangle {
                            implicitWidth: 110
                            color: "#292929"
                            radius: 8
                            border.color: "#3A3A3A"
                            border.width: 1
                        }
                        
                        DarkMenuItem {
                            text: "切换账号"
                            onTriggered: showSwitchAccountDialog()
                        }
                        // ⭐ 2026-08-14：隐藏「修改登录密码」（代码保留，height=0 不占位）
                        DarkMenuItem {
                            text: "修改登录密码"
                            visible: false
                            height: 0
                            onTriggered: showChangeLoginPasswordDialog()
                        }
                        DarkMenuItem {
                            text: "退出登录"
                            onTriggered: handleLogout()
                        }
                    }
                }

                // ⭐ 2026-08-15 对齐老 java 标题栏（CameraMainUi.fxml）：最小化 bar.png /
                //   最大化 max.png / 关闭 close.png，20x20 纯图标透明底按钮，文字按钮全部替换。
                //   顺序也对齐老 java：最小化 | 全屏(最大化) | 关闭。

                // 最小化
                Rectangle {
                    width: 24
                    height: 24
                    radius: 4
                    color: minBtnArea.containsMouse ? "#3A3A3A" : "transparent"
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        source: "images/bar.png"
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }

                    MouseArea {
                        id: minBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mainWindow.showMinimized()
                    }
                }

                // 全屏（最大化/还原）
                Rectangle {
                    width: 24
                    height: 24
                    radius: 4
                    color: fullscreenBtnArea.containsMouse ? "#3A3A3A" : "transparent"
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        source: "images/max.png"
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }

                    MouseArea {
                        id: fullscreenBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (mainWindow.visibility === Window.Maximized || mainWindow.visibility === Window.FullScreen) {
                                mainWindow.showNormal()
                            } else {
                                mainWindow.showMaximized()
                            }
                        }
                    }
                }

                // 关闭
                Rectangle {
                    width: 24
                    height: 24
                    radius: 4
                    color: closeBtnArea.containsMouse ? "#C62828" : "transparent"
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        source: "images/close.png"
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }

                    MouseArea {
                        id: closeBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Qt.quit()
                    }
                }
            }
        }
    }
    
    // ============ 底部状态栏 ============
    // ⭐ 2026-08-14 对齐 java gstream：iOS 设备信息放底部左侧
    //   条目照搬 java 端：监控设备 | 在线状态 | 网络质量+fps | 码率 | 电量 | 联网类型
    //   配色同 java：底 #292929，文字 #CCCCCC 12px，网络质量绿色 #34C759
    Rectangle {
        id: bottomStatusBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34
        color: "#292929"

        // 网络质量显示口径（excellent/good/fair/poor → 中文 + 颜色）
        function qualityText(q) {
            switch (q) {
                case "excellent": return "优秀"
                case "good": return "良好"
                case "fair": return "一般"
                case "poor": return "差"
                default: return "未知"
            }
        }
        function qualityColor(q) {
            switch (q) {
                case "excellent": return "#34C759"
                case "good": return "#30B0C7"
                case "fair": return "#FF9500"
                case "poor": return "#FF3B30"
                default: return "#8E8E93"
            }
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12

            // 监控设备
            Text {
                text: "iOS(建议清晰度：50)"
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#CCCCCC"
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle { width: 1; height: 10; color: "#4A4A4A"; anchors.verticalCenter: parent.verticalCenter }

            // 在线状态 + 设备昵称
            Row {
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: 7; height: 7; radius: 3.5
                    anchors.verticalCenter: parent.verticalCenter
                    color: !mainPage.deviceOnline ? "#FF3B30"
                           : (mainPage.publishState === 1 ? "#34C759" : "#FF9500")
                }
                Text {
                    text: !mainPage.deviceOnline ? "未上线"
                          : (mainPage.publishState === 1 ? "在线中" : "在线·未推流")
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: !mainPage.deviceOnline ? "#FF3B30"
                           : (mainPage.publishState === 1 ? "#34C759" : "#FF9500")
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    visible: mainPage.pairedIosDisplay.length > 0
                    text: mainPage.pairedIosDisplay
                    font.family: "PingFang HK"
                    font.pixelSize: 11
                    color: "#8E8E93"
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, 120)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle { width: 1; height: 10; color: "#4A4A4A"; anchors.verticalCenter: parent.verticalCenter }

            // 网络质量 + 线路 + fps
            Row {
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    text: bottomStatusBar.qualityText(mainPage.deviceNetworkQuality)
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: bottomStatusBar.qualityColor(mainPage.deviceNetworkQuality)
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: mainPage.connectMode === 1 ? "P2P" : (mainPage.connectMode === 2 ? "SRT" : "SRS")
                    font.family: "Consolas"
                    font.pixelSize: 11
                    font.bold: true
                    color: mainPage.connectMode === 1 ? "#34C759" : (mainPage.connectMode === 2 ? "#30B0C7" : "#FF9500")
                    anchors.verticalCenter: parent.verticalCenter
                    // ⭐ §53.4.5：鼠标悬停显示设备端为什么选了这条线路/这个编码
                    ToolTip.visible: connectReasonHover.hovered && mainPage.deviceConnectReason.length > 0
                    ToolTip.text: "设备端决策：" + mainPage.deviceConnectReason
                    HoverHandler { id: connectReasonHover }
                }
                // ⭐ P2P 连接阶段（切网重连过程常驻可见）：只在非「已连接」的过渡/异常态显示
                Text {
                    id: p2pPhaseLabel
                    text: mainPage.p2pPhaseText(gstPlayer.webrtcStatus)
                    visible: mainPage.connectMode === 1 && text.length > 0
                    font.family: "PingFang HK"
                    font.pixelSize: 11
                    font.bold: true
                    color: mainPage.p2pPhaseColor(gstPlayer.webrtcStatus)
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: fpsRow.displayFps + "fps"
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: "#CCCCCC"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle { width: 1; height: 10; color: "#4A4A4A"; anchors.verticalCenter: parent.verticalCenter }

            // 码率
            Text {
                text: (mainPage.deviceKbps > 0 ? (mainPage.deviceKbps * 2) : 0) + "kb/s"  // ⭐ x2 显示
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#CCCCCC"
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle { width: 1; height: 10; color: "#4A4A4A"; anchors.verticalCenter: parent.verticalCenter }

            // 电量
            Text {
                text: "电量 " + (mainPage.deviceBattery >= 0 ? mainPage.deviceBattery + "%" : "-")
                font.family: "PingFang HK"
                font.pixelSize: 12
                // 电量颜色：<20红色，20-50橙色，>50正常
                color: {
                    if (mainPage.deviceBattery < 0) return "#CCCCCC"
                    if (mainPage.deviceBattery < 20) return "#FF3B30"
                    if (mainPage.deviceBattery <= 50) return "#FF9500"
                    return "#CCCCCC"
                }
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle { width: 1; height: 10; color: "#4A4A4A"; anchors.verticalCenter: parent.verticalCenter }

            // 联网类型
            Text {
                text: mainPage.deviceNetworkType ? mainPage.deviceNetworkType : "-"
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#CCCCCC"
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        // ⭐ 滚轮帧数（步长）显示：默认1，按 F5–F8 跟随 frameStep 变化
        //   位置对齐 java gstream 的 scrollFrameLabel（底栏右侧）
        Rectangle {
            width: wheelStepText.width + 16
            height: 24
            radius: 8
            color: "#1F1F1F"
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter

            Text {
                id: wheelStepText
                anchors.centerIn: parent
                text: "滚轮帧数: " + mainPage.frameStep
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#FAFAFA"
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                ToolTip.visible: containsMouse
                ToolTip.text: "滚轮切帧步长"
                ToolTip.delay: 300
            }
        }
    }

    // ============ 主布局 ============
    SplitView {
        id: mainSplitView
        anchors.top: topMenuBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bottomStatusBar.top
        anchors.margins: 8
        orientation: Qt.Horizontal
        
        // 左右分割线样式（透明，悬停时显示）
        handle: Rectangle {
            implicitWidth: 8
            implicitHeight: parent.height
            color: "transparent"
            
            // 悬停时显示的指示条
            Rectangle {
                anchors.centerIn: parent
                width: 4
                height: parent.height
                radius: 2
                color: mainSplitHandleArea.containsMouse ? "#4DB6AC" : "transparent"
                opacity: mainSplitHandleArea.containsMouse ? 0.8 : 0
                
                Behavior on opacity { NumberAnimation { duration: 150 } }
            }
            
            MouseArea {
                id: mainSplitHandleArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SplitHCursor
                acceptedButtons: Qt.NoButton
            }
        }

        // ===== 左侧容器（Holder）=====
        Item {
            id: leftHolder
            SplitView.fillHeight: true
            SplitView.fillWidth: true  // 左侧填充剩余空间
            SplitView.minimumWidth: mainSplitView.width * 0.3  // 最小30%
        }

        // ===== 右侧：三部分面板 =====
        ColumnLayout {
            id: rightPanel
            clip: true
            SplitView.fillHeight: true
            SplitView.preferredWidth: gridFullscreenMode ? 0 : mainSplitView.width * savedWidthRatio
            SplitView.minimumWidth: gridFullscreenMode ? 0 : mainSplitView.width * 0.15
            SplitView.maximumWidth: gridFullscreenMode ? 0 : Infinity
            opacity: gridFullscreenMode ? 0 : 1  // 全屏时透明但保持visible
            spacing: 4
            
            // ⭐ 监听宽度变化，在用户拖动后自动保存左右分割比例
            onWidthChanged: {
                if (!gridFullscreenMode && !isRestoringWidthRatio && width > 0 && mainSplitView.width > 0) {
                    // 用户拖动时，延迟保存比例（防抖）
                    saveWidthRatioTimer.stop()
                    saveWidthRatioTimer.start()
                }
            }

            // ----- 可拖动分割的上下两部分（实时流 + 慢放）-----
            SplitView {
                id: rightSplitView
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: Qt.Vertical
                
                // 分割线样式（透明，悬停时显示）
                handle: Rectangle {
                    implicitWidth: parent.width
                    implicitHeight: 8
                    color: "transparent"
                    
                    // 悬停时显示的指示条
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: 4
                        radius: 2
                        color: splitHandleArea.containsMouse ? "#4DB6AC" : "transparent"
                        opacity: splitHandleArea.containsMouse ? 0.8 : 0
                        
                        Behavior on opacity { NumberAnimation { duration: 150 } }
                    }
                    
                    MouseArea {
                        id: splitHandleArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.SplitVCursor
                        acceptedButtons: Qt.NoButton
                    }
                }

                // ----- 右侧第一部分容器（实时流）-----
                Item {
                    id: rightTopHolder
                    SplitView.fillWidth: true
                    // ⭐ 2026-08-14 首次进入实时流/慢放平分高度（原固定 330，多余空间全归慢放）；
                    //   用户拖动后 SplitView 会接管该值，保存/恢复比例逻辑不受影响
                    SplitView.preferredHeight: rightSplitView.height / 2
                    SplitView.minimumHeight: 150
                    
                    // ⭐ 监听高度变化，在用户拖动后自动保存比例
                    onHeightChanged: {
                        if (!gridFullscreenMode && !isRestoringRatio) {
                            // 用户拖动时，延迟保存比例（防抖）
                            saveHeightRatioTimer.stop()
                            saveHeightRatioTimer.start()
                        }
                    }
                }

                // ----- 右侧第二部分容器（慢放）-----
                Item {
                    id: rightMiddleHolder
                    SplitView.fillWidth: true
                    SplitView.preferredHeight: 330
                    SplitView.minimumHeight: 150
                }
            }

            // ----- 右侧第三部分容器（控制面板，固定位置）-----
            // ⭐ 2026-08-14：行/列/预抓拍/后抓拍挪到顶部菜单栏后，面板只剩一排按钮，
            //   高度从 216 压缩到 76（36 按钮 + 上下 20 边距），省出的空间归实时流/慢放
            Item {
                id: rightBottomHolder
                Layout.fillWidth: true
                Layout.preferredHeight: 76
                Layout.minimumHeight: 76
                Layout.maximumHeight: 76
            }
        }
    }
    
    // ============ 可交换的内容组件 ============
    
    // 抓拍网格内容
    Item {
        id: captureGridContent
        // 根据布局模式选择父容器
        parent: windowLayoutMode === 0 ? leftHolder : 
                (windowLayoutMode === 1 ? rightTopHolder : rightMiddleHolder)
        anchors.fill: parent
        
        // 🔥 跟踪鼠标是否在截图区域内（HoverHandler 不与子元素 MouseArea 冲突）
        property bool mouseInCaptureArea: captureAreaHoverHandler.hovered
        
        HoverHandler {
            id: captureAreaHoverHandler
            onHoveredChanged: {
                if (hovered) {
                    // ⭐ 鼠标进入截图区域时恢复焦点（确保S键检测正常）
                    mainPage.forceActiveFocus()
                }
            }
        }
        
        // 🔥 监听新截图添加，只有鼠标不在区域内时才自动选中
        Connections {
            target: captureManager
            function onItemAdded(itemIndex) {
                if (!captureGridContent.mouseInCaptureArea) {
                    // 鼠标不在截图区域内，自动选中新截图
                    captureManager.currentItemIndex = itemIndex
                }
                // 否则保持当前选中状态（由鼠标悬停控制）
            }
        }
        
        GridView {
                    id: captureGrid
                    anchors.fill: parent
                    cellWidth: Math.max(1, Math.floor(width / captureManager.gridCols))
                    cellHeight: Math.max(1, Math.floor(height / captureManager.gridRows))
                    model: captureManager.gridRows * captureManager.gridCols
                    clip: true
                    interactive: false
                    cacheBuffer: 0
                    
                    function getDataIndex(displayIndex) {
                        if (captureManager.isHorizontalLayout) {
                            return displayIndex
                        } else {
                            var displayRow = Math.floor(displayIndex / captureManager.gridCols)
                            var displayCol = displayIndex % captureManager.gridCols
                            return displayCol * captureManager.gridRows + displayRow
                        }
                    }

                    delegate: Rectangle {
                        id: gridCell
                        width: captureGrid.cellWidth - 1
                        height: captureGrid.cellHeight - 1
                        x: 0.5
                        y: 0.5
                        
                        property int dataIndex: captureGrid.getDataIndex(index)
                        property bool hasData: dataIndex < captureManager.count
                        property bool isSelected: hasData && captureManager.currentItemIndex === dataIndex
                        property int currentFrame: hasData ? captureManager.getCurrentOffset(dataIndex) : 0
                        property int totalFrames: hasData ? captureManager.getTotalFrames(dataIndex) : 0
                        property int frameVersion: 0
                        // ⭐ 2026-07-16：底部切帧进度条的悬停显隐标记，由 itemMouseArea 的 onEntered/onExited
                        //   管理。⚠ 之前踩过坑：进度条自己的交互 MouseArea 一旦也设了 hoverEnabled，
                        //   会跟 itemMouseArea 抢 hover（谁盖住谁的问题）导致来回闪烁；后来发现只要进度条
                        //   自己那个 MouseArea 不设 hoverEnabled（它只需要处理按下/拖动/滚轮，不需要关心
                        //   hover），就不会跟 itemMouseArea 抢——两者可以在同一块区域"和平共存"，
                        //   itemMouseArea 的 hover 检测完全不受盖在它上面的进度条影响。
                        //   （曾经加过一层 z:50 的独立感应层来"解决"闪烁，副作用是itemMouseArea 从此再也
                        //   收不到 hover，连带"鼠标悬停即选中该item"「A键放大跟随鼠标」都失效了——已撤回。）
                        property bool frameBarHovered: false
                        
                        function rebindFrameProperties() {
                            gridCell.currentFrame = Qt.binding(function() {
                                return gridCell.hasData ? captureManager.getCurrentOffset(gridCell.dataIndex) : 0
                            })
                            gridCell.totalFrames = Qt.binding(function() {
                                return gridCell.hasData ? captureManager.getTotalFrames(gridCell.dataIndex) : 0
                            })
                        }
                        
                        Connections {
                            target: captureManager
                            function onCaptureComplete(itemIndex) {
                                if (itemIndex === gridCell.dataIndex) {
                                    gridCell.rebindFrameProperties()
                                }
                            }
                            function onItemAdded(itemIndex) {
                                if (itemIndex === gridCell.dataIndex) {
                                    gridCell.rebindFrameProperties()
                                }
                            }
                            function onGridSettingsChanged() {
                                gridCell.rebindFrameProperties()
                            }
                            function onCaptureSettingsChanged() {
                                gridCell.rebindFrameProperties()
                            }
                            function onFrameChanged(itemIndex, frameOffset) {
                                if (itemIndex === gridCell.dataIndex) {
                                    gridCell.currentFrame = frameOffset
                                    // 已缓存 → 立即换图(无白屏)；未缓存 → 保持当前画面, 等 frameImageReady 再换
                                    if (captureManager.isFrameCached(itemIndex, frameOffset))
                                        itemImage.loadCurrentFrame()
                                }
                            }
                            function onFrameImageReady(itemIndex, frameOffset) {
                                if (itemIndex === gridCell.dataIndex && frameOffset === gridCell.currentFrame) {
                                    gridCell.frameVersion++
                                    itemImage.loadCurrentFrame()
                                }
                            }
                            // ⭐ AI 牌位置放大：把识别到的牌中心对齐到格子中心并放大
                            //   cx/cy 为牌中心在原图的归一化坐标(0~1)
                            function onCardZoomReady(itemIndex, frameOffset, zoom, cx, cy) {
                                if (itemIndex !== gridCell.dataIndex) return
                                if (frameOffset !== gridCell.currentFrame) return  // 只对"当前这一张"生效
                                var W = imageContainer.width
                                var H = imageContainer.height
                                if (W <= 0 || H <= 0) return
                                // ⭐ §26-① 镜像错位修复：识别坐标算在未镜像的解码帧上，显示层 Image.mirror
                                //   翻转了画面 → 牌实际出现在对称位置，取景前先翻坐标。
                                if (mainPage.videoMirrorMode === "horizontal") cx = 1 - cx
                                else if (mainPage.videoMirrorMode === "vertical") cy = 1 - cy
                                // 放大后把(cx,cy)归一化点平移到容器中心
                                var offX = (0.5 - cx) * W * zoom
                                var offY = (0.5 - cy) * H * zoom
                                var maxX = W * (zoom - 1) / 2
                                var maxY = H * (zoom - 1) / 2
                                gridCell.itemZoom = zoom
                                gridCell.itemOffsetX = Math.max(-maxX, Math.min(maxX, offX))
                                gridCell.itemOffsetY = Math.max(-maxY, Math.min(maxY, offY))
                            }
                            function onCardZoomCleared(itemIndex) {
                                if (itemIndex !== gridCell.dataIndex) return
                                gridCell.itemZoom = 1.0
                                gridCell.itemOffsetX = 0
                                gridCell.itemOffsetY = 0
                            }
                        }
                        
                        // ⭐ 2026-08-14 对齐老 Java：格子本体 #292929，格子间露出 #1F1F1F 底色缝当分割线；
                        //   悬停边框用老 Java 皮肤的强调蓝 #607AFB——只有「有截图内容且鼠标悬停」才显示，
                        //   空格子悬停不变色
                        color: "#292929"
                        border.color: (gridCell.hasData && itemMouseArea.containsMouse) ? "#607AFB" : "#1F1F1F"
                        border.width: (gridCell.hasData && itemMouseArea.containsMouse) ? 2 : 1
                        radius: 4

                        // item 缩放属性（从抓拍时的 videoZoom 继承，之后用户可手动调整）
                        property real itemZoom: 1.0
                        property real itemOffsetX: 0
                        property real itemOffsetY: 0
                        property bool zoomInitialized: false  // ⭐ 标记是否已初始化
                        
                        // 🔍 追踪 itemZoom 变化
                        onItemZoomChanged: {
                            captureManager.zoomLog("⚡ itemZoom变化: dataIndex=" + dataIndex + " newZoom=" + itemZoom.toFixed(2))
                        }

                        // ⭐ AI 放大（2026-07-06 每帧识别）：切帧时查该帧已缓存的识别结果。
                        //   命中→放大到该帧牌位；未命中(未识别/未检出)→保持上一帧放大(keep_prev)。
                        //   （切帧同时会在 C++ gotoFrame 里对未缓存帧触发一次识别，结果回来经 onCardZoomReady 应用）
                        function applyAiZoomForCurrentFrame() {
                            if (!captureManager.aiCardZoomEnabled) return
                            if (!gridCell.hasData || gridCell.dataIndex < 0) return
                            var r = captureManager.aiZoomForFrame(gridCell.dataIndex, gridCell.currentFrame)
                            if (r && r.valid) {
                                var W = imageContainer.width
                                var H = imageContainer.height
                                if (W <= 0 || H <= 0) return
                                // ⭐ §26-① 镜像错位修复：同 onCardZoomReady——坐标先按当前镜像模式翻转。
                                //   （旋转换算 §26-② 已在 C++ aiZoomForFrame 内完成，返回的即当前旋转空间坐标）
                                var cx = r.cx, cy = r.cy
                                if (mainPage.videoMirrorMode === "horizontal") cx = 1 - cx
                                else if (mainPage.videoMirrorMode === "vertical") cy = 1 - cy
                                var offX = (0.5 - cx) * W * r.zoom
                                var offY = (0.5 - cy) * H * r.zoom
                                var maxX = W * (r.zoom - 1) / 2
                                var maxY = H * (r.zoom - 1) / 2
                                gridCell.itemZoom = r.zoom
                                gridCell.itemOffsetX = Math.max(-maxX, Math.min(maxX, offX))
                                gridCell.itemOffsetY = Math.max(-maxY, Math.min(maxY, offY))
                            }
                            // else：该帧尚未识别 / 未检出牌 → keep_prev：保持上一帧放大，什么都不做
                        }

                        onCurrentFrameChanged: applyAiZoomForCurrentFrame()

                        // ⭐ §26-①②：镜像/旋转切换后，已放大格子的取景坐标立即按新变换重算
                        //   （镜像补偿在本函数内翻坐标；旋转换算在 C++ aiZoomForFrame 内做）
                        Connections {
                            target: mainPage
                            function onVideoMirrorModeChanged() { gridCell.applyAiZoomForCurrentFrame() }
                            function onVideoRotationChanged() { gridCell.applyAiZoomForCurrentFrame() }
                        }

                        // ⭐ 只在组件首次加载且有数据时初始化缩放
                        Component.onCompleted: {
                            initZoomFromMap()
                        }
                        
                        // ⭐ 当有新数据时初始化缩放
                        onHasDataChanged: {
                            captureManager.zoomLog("🔄 hasDataChanged: dataIndex=" + dataIndex + " hasData=" + hasData + " zoomInitialized=" + zoomInitialized)
                            if (hasData) {
                                // 每次有新数据时都从 map 加载缩放
                                initZoomFromMap()
                            } else {
                                // 数据被清除时，重置初始化标记，以便下次重新加载
                                zoomInitialized = false
                                itemZoom = 1.0
                                itemOffsetX = 0
                                itemOffsetY = 0
                            }
                        }
                        
                        function initZoomFromMap() {
                            captureManager.zoomLog("🔧 initZoomFromMap: dataIndex=" + dataIndex + " hasData=" + hasData + " zoomInitialized=" + zoomInitialized)
                            if (dataIndex >= 0 && mainPage.itemZoomMap[dataIndex]) {
                                var saved = mainPage.itemZoomMap[dataIndex]
                                itemZoom = saved.zoom
                                
                                // ⭐ 归一化分量 → 当前 item 容器下的像素偏移（改行列后容器变了，取景仍一致）
                                var fx = (saved.fx !== undefined) ? saved.fx : 0
                                var fy = (saved.fy !== undefined) ? saved.fy : 0
                                itemOffsetX = mainPage.itemZoomOffsetPx(saved.zoom, fx, imageContainer.width)
                                itemOffsetY = mainPage.itemZoomOffsetPx(saved.zoom, fy, imageContainer.height)
                                
                                zoomInitialized = true
                                captureManager.zoomLog("📸 item " + dataIndex + " 初始化: zoom=" + saved.zoom + " fx=" + fx.toFixed(2) + " → offsetX=" + itemOffsetX.toFixed(1))
                            } else if (hasData) {
                                itemZoom = 1.0
                                itemOffsetX = 0
                                itemOffsetY = 0
                                zoomInitialized = true
                                captureManager.zoomLog("📸 item " + dataIndex + " 初始化: zoom=1.0 (默认)")
                            }
                            // ⭐ 2026-07-11 修复「行列改变后 AI 识别放大被破坏」：
                            //   AI 放大结果只写在 delegate 的 itemZoom（onCardZoomReady），未存入 itemZoomMap，
                            //   GridView 行列变化会重建 delegate → 上面只从 map 恢复手动缩放 → AI 放大丢失复位。
                            //   这里用 C++ 侧按帧缓存的识别结果（aiZoomForFrame，跨 delegate 重建持久）重新套用，
                            //   命中即覆盖为识别放大区域；未命中则保持刚恢复的手动/默认缩放。
                            if (hasData && captureManager.aiCardZoomEnabled) {
                                applyAiZoomForCurrentFrame()
                            }
                        }
                        
                        // ⭐ 接收 Ctrl 联动广播 — 整 grid 所有 item 同步切帧 / 缩放 / 拖拽
                        Connections {
                            target: mainPage
                            function onGridSyncFrameStep(direction) {
                                if (!gridCell.hasData || gridCell.totalFrames <= 0) return
                                mainPage.stepCaptureFrame(gridCell.dataIndex, direction)
                                gridCell.currentFrame = captureManager.getCurrentOffset(gridCell.dataIndex)
                            }
                            function onGridSyncZoomDelta(deltaZoom) {
                                if (!gridCell.hasData) return
                                var oldZoom = gridCell.itemZoom
                                var newZoom = Math.max(1.0, Math.min(3.0, oldZoom + deltaZoom))
                                if (newZoom === oldZoom) return
                                // 联动模式: 各 item 以自己容器中心缩放 (鼠标坐标对每个格子不同, 简化为中心)
                                if (newZoom === 1.0) {
                                    gridCell.itemOffsetX = 0
                                    gridCell.itemOffsetY = 0
                                } else {
                                    // 按比例约束已有偏移到新范围
                                    var maxOffsetX = imageContainer.width * (newZoom - 1) / 2
                                    var maxOffsetY = imageContainer.height * (newZoom - 1) / 2
                                    gridCell.itemOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, gridCell.itemOffsetX))
                                    gridCell.itemOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, gridCell.itemOffsetY))
                                }
                                gridCell.itemZoom = newZoom
                                // ⭐ 2026-07-11：集体缩放也要落盘 itemZoomMap，否则改行列后被复位
                                mainPage.saveItemZoom(gridCell.dataIndex, gridCell.itemZoom, gridCell.itemOffsetX, gridCell.itemOffsetY, imageContainer.width, imageContainer.height)
                            }
                            function onGridSyncDrag(dx, dy) {
                                if (!gridCell.hasData || gridCell.itemZoom <= 1.0) return
                                var maxOffsetX = imageContainer.width * (gridCell.itemZoom - 1) / 2
                                var maxOffsetY = imageContainer.height * (gridCell.itemZoom - 1) / 2
                                gridCell.itemOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, gridCell.itemOffsetX + dx))
                                gridCell.itemOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, gridCell.itemOffsetY + dy))
                                // ⭐ 集体拖动也落盘
                                mainPage.saveItemZoom(gridCell.dataIndex, gridCell.itemZoom, gridCell.itemOffsetX, gridCell.itemOffsetY, imageContainer.width, imageContainer.height)
                            }
                            function onGridSyncResetZoom() {
                                if (!gridCell.hasData) return
                                gridCell.itemZoom = 1.0
                                gridCell.itemOffsetX = 0
                                gridCell.itemOffsetY = 0
                                // ⭐ 集体重置也落盘（zoom=1 → 存归一化 0）
                                mainPage.saveItemZoomNorm(gridCell.dataIndex, 1.0, 0, 0)
                            }
                            // ⭐ 2026-07-11：外部（单个放大）改了该格缩放状态 → 重新从 itemZoomMap 套用，保持一致
                            function onItemZoomRestore(idx) {
                                if (idx !== gridCell.dataIndex || !gridCell.hasData) return
                                gridCell.initZoomFromMap()
                            }
                        }

                        MouseArea {
                            id: itemMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton

                            // ⭐ 左键按住拖动放大后的截图（平移，无需 Z 键）
                            //    纯点击（位移＜阈值）= 切帧；拖动（位移≥阈值）= 平移
                            property bool panning: false
                            property bool panMoved: false
                            property real panLastX: 0
                            property real panLastY: 0
                            property real panStartX: 0
                            property real panStartY: 0
                            readonly property real panThreshold: 4

                            onPressed: function(mouse) {
                                ensureFocusAndSelect()
                                // 左键 + 已放大 → 准备平移（移动超过阈值才算拖动，否则当作点击切帧）
                                if (mouse.button === Qt.LeftButton && gridCell.hasData && gridCell.itemZoom > 1.0) {
                                    itemMouseArea.panning = true
                                    itemMouseArea.panMoved = false
                                    itemMouseArea.panLastX = mouse.x
                                    itemMouseArea.panLastY = mouse.y
                                    itemMouseArea.panStartX = mouse.x
                                    itemMouseArea.panStartY = mouse.y
                                    // 不 accept，保留 onClicked 用于纯点击切帧
                                }
                            }

                            onReleased: function(mouse) {
                                if (itemMouseArea.panning) {
                                    itemMouseArea.panning = false
                                    if (itemMouseArea.panMoved) {
                                        mainPage.saveItemZoom(gridCell.dataIndex, gridCell.itemZoom, gridCell.itemOffsetX, gridCell.itemOffsetY, imageContainer.width, imageContainer.height)
                                        captureManager.zoomLog("🖐️ 拖动结束: dataIndex=" + gridCell.dataIndex + " offsetX=" + gridCell.itemOffsetX.toFixed(1) + " offsetY=" + gridCell.itemOffsetY.toFixed(1))
                                        // ⭐ 自动放大开启时拖动放大图 = 该格 AI 识别框不对(牌不在框内) → 标记识别失败
                                        if (captureManager.aiCardZoomEnabled) {
                                            captureManager.markAiRecognitionFailed(gridCell.dataIndex)
                                        }
                                        mouse.accepted = true
                                    }
                                }
                            }

                            // ⭐ 统一处理焦点和选中（避免重复代码）
                            function ensureFocusAndSelect() {
                                mainPage.forceActiveFocus()
                                if (gridCell.hasData && captureManager.currentItemIndex !== gridCell.dataIndex) {
                                    captureManager.currentItemIndex = gridCell.dataIndex
                                }
                            }

                            onEntered: {
                                ensureFocusAndSelect()
                                gridCell.frameBarHovered = true
                            }
                            onExited: {
                                gridCell.frameBarHovered = false
                            }
                            
                            // ⭐ 修复：GridView 重建 delegate 时鼠标已在 item 上，onEntered 不触发
                            // onPositionChanged 在鼠标移动时触发，补偿 onEntered 缺失的情况
                            onPositionChanged: function(mouse) {
                                // ⭐ 左键拖动：平移放大后的图片
                                if (itemMouseArea.panning) {
                                    if (Math.abs(mouse.x - itemMouseArea.panStartX) > itemMouseArea.panThreshold ||
                                        Math.abs(mouse.y - itemMouseArea.panStartY) > itemMouseArea.panThreshold) {
                                        itemMouseArea.panMoved = true
                                    }
                                    var dx = mouse.x - itemMouseArea.panLastX
                                    var dy = mouse.y - itemMouseArea.panLastY
                                    itemMouseArea.panLastX = mouse.x
                                    itemMouseArea.panLastY = mouse.y
                                    var maxOffsetX = imageContainer.width * (gridCell.itemZoom - 1) / 2
                                    var maxOffsetY = imageContainer.height * (gridCell.itemZoom - 1) / 2
                                    gridCell.itemOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, gridCell.itemOffsetX + dx))
                                    gridCell.itemOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, gridCell.itemOffsetY + dy))
                                    mouse.accepted = true
                                    return
                                }
                                if (!gridCell.isSelected) {
                                    ensureFocusAndSelect()
                                }
                            }
                            
                            onClicked: function(mouse) {
                                ensureFocusAndSelect()
                                // ⭐ 刚发生过拖动平移：不触发切帧（左键用于平移放大图）
                                if (itemMouseArea.panMoved) { itemMouseArea.panMoved = false; return }
                                // ⭐ Shift+点击：打开该item所在列的列预览
                                //   2026-08-14 需求：老 java gstream 没有列预览 → 不触发（false && 短路，代码保留）
                                if (false && (mouse.modifiers & Qt.ShiftModifier) && gridCell.hasData) {
                                    var cols = captureManager.gridCols
                                    var displayIndex = index
                                    var displayCol
                                    if (captureManager.isHorizontalLayout) {
                                        displayCol = displayIndex % cols
                                    } else {
                                        displayCol = Math.floor(gridCell.dataIndex / captureManager.gridRows)
                                    }
                                    toggleColumnPreview(displayCol + 1)  // 1-based
                                    return
                                }
                                // ⭐ Ctrl+点击：广播给所有 grid item 同步切帧
                                if (mouse.modifiers & Qt.ControlModifier && gridCell.hasData) {
                                    if (mouse.button === Qt.LeftButton) {
                                        mainPage.gridSyncFrameStep("prev")
                                    } else if (mouse.button === Qt.RightButton) {
                                        mainPage.gridSyncFrameStep("next")
                                    }
                                    return
                                }
                                // ⭐ 左键=上一帧，右键=下一帧（单 item, 受 frameStep 影响）
                                if (gridCell.hasData && gridCell.totalFrames > 0) {
                                    if (mouse.button === Qt.LeftButton) {
                                        mainPage.stepCaptureFrame(gridCell.dataIndex, "prev")
                                        gridCell.currentFrame = captureManager.getCurrentOffset(gridCell.dataIndex)
                                    } else if (mouse.button === Qt.RightButton) {
                                        mainPage.stepCaptureFrame(gridCell.dataIndex, "next")
                                        gridCell.currentFrame = captureManager.getCurrentOffset(gridCell.dataIndex)
                                    }
                                }
                            }
                            
                            onWheel: function(wheel) {
                                wheel.accepted = true  // 阻止事件传播到其他区域
                                // ⭐ 确保焦点和选中（防止首次滚轮时 S 键不生效）
                                ensureFocusAndSelect()
                                if (!gridCell.hasData || gridCell.totalFrames <= 0) return

                                // ⭐ Ctrl 按住: 全 grid 联动 (滚轮切帧 / S+滚轮缩放)
                                if (wheel.modifiers & Qt.ControlModifier) {
                                    if (mainPage.sKeyPressed) {
                                        // Ctrl + S + 滚轮: 全部 item 同步缩放 (各自以容器中心)
                                        mainPage.gridSyncZoomDelta(wheel.angleDelta.y > 0 ? 0.2 : -0.2)
                                    } else {
                                        // Ctrl + 滚轮: 全部 item 同步切帧
                                        mainPage.gridSyncFrameStep(wheel.angleDelta.y > 0 ? "prev" : "next")
                                    }
                                    return
                                }

                                // 🔍 调试日志：显示当前状态
                                captureManager.zoomLog("🎡 wheel: dataIndex=" + gridCell.dataIndex + " itemZoom=" + gridCell.itemZoom.toFixed(2) + " offsetX=" + gridCell.itemOffsetX.toFixed(1) + " offsetY=" + gridCell.itemOffsetY.toFixed(1) + " frame=" + gridCell.currentFrame + " sKey=" + mainPage.sKeyPressed)
                                captureManager.zoomLog("🎡 实时流: videoZoom=" + mainPage.videoZoom.toFixed(2) + " videoOffsetX=" + mainPage.videoOffsetX.toFixed(1) + " videoOffsetY=" + mainPage.videoOffsetY.toFixed(1))

                                if (mainPage.sKeyPressed) {
                                    // S + 滚轮：以鼠标为中心缩放
                                    var oldZoom = gridCell.itemZoom
                                    var delta = wheel.angleDelta.y > 0 ? 0.2 : -0.2
                                    var newZoom = Math.max(1.0, Math.min(3.0, oldZoom + delta))
                                    
                                    if (newZoom !== oldZoom) {
                                        // 计算鼠标相对于容器中心的位置
                                        var containerCenterX = imageContainer.width / 2
                                        var containerCenterY = imageContainer.height / 2
                                        var mouseRelX = wheel.x - containerCenterX
                                        var mouseRelY = wheel.y - containerCenterY
                                        
                                        // 计算缩放比例变化
                                        var zoomRatio = newZoom / oldZoom
                                        
                                        // 调整偏移以保持鼠标位置不变
                                        var newOffsetX = mouseRelX - (mouseRelX - gridCell.itemOffsetX) * zoomRatio
                                        var newOffsetY = mouseRelY - (mouseRelY - gridCell.itemOffsetY) * zoomRatio
                                        
                                        // ⭐ 边界约束：确保偏移量在有效范围内
                                        var maxOffsetX = imageContainer.width * (newZoom - 1) / 2
                                        var maxOffsetY = imageContainer.height * (newZoom - 1) / 2
                                        gridCell.itemOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, newOffsetX))
                                        gridCell.itemOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, newOffsetY))
                                        
                                        gridCell.itemZoom = newZoom
                                        
                                        // 如果缩放到1倍，重置偏移
                                        if (newZoom === 1.0) {
                                            gridCell.itemOffsetX = 0
                                            gridCell.itemOffsetY = 0
                                        }
                                        
                                        // ⭐ 2026-07-11 修复「改行列后 item 缩放丢失」：S+滚轮缩放必须落盘 itemZoomMap
                                        //   （原来只有拖动落盘，滚轮缩放没存 → GridView 重建 delegate 后被复位）
                                        mainPage.saveItemZoom(gridCell.dataIndex, gridCell.itemZoom, gridCell.itemOffsetX, gridCell.itemOffsetY, imageContainer.width, imageContainer.height)
                                        captureManager.zoomLog("🔍 item缩放: dataIndex=" + gridCell.dataIndex + " zoom=" + newZoom.toFixed(2) + " offsetX=" + gridCell.itemOffsetX.toFixed(1) + " maxOffset=" + maxOffsetX.toFixed(1))
                                    }
                                } else {
                                    // 普通滚轮：切换帧
                                    // 🔍 滚帧前的图片尺寸（包括实际绘制尺寸）
                                    captureManager.zoomLog("📏 滚帧前: dataIndex=" + gridCell.dataIndex + " frame=" + gridCell.currentFrame + 
                                        " W=" + itemImage.width.toFixed(0) + " H=" + itemImage.height.toFixed(0) +
                                        " paintedW=" + itemImage.paintedWidth.toFixed(0) + " paintedH=" + itemImage.paintedHeight.toFixed(0) +
                                        " implicitW=" + itemImage.implicitWidth.toFixed(0) + " implicitH=" + itemImage.implicitHeight.toFixed(0) +
                                        " itemZoom=" + gridCell.itemZoom.toFixed(2))
                                    
                                    if (wheel.angleDelta.y > 0) {
                                        mainPage.stepCaptureFrame(gridCell.dataIndex, "prev")
                                    } else {
                                        mainPage.stepCaptureFrame(gridCell.dataIndex, "next")
                                    }
                                    // 直接获取最新帧偏移（frameChanged 信号会更新，这里作为备份）
                                    gridCell.currentFrame = captureManager.getCurrentOffset(gridCell.dataIndex)
                                    
                                    // 🔍 滚帧后的图片尺寸
                                    captureManager.zoomLog("📏 滚帧后: dataIndex=" + gridCell.dataIndex + " frame=" + gridCell.currentFrame + 
                                        " W=" + itemImage.width.toFixed(0) + " H=" + itemImage.height.toFixed(0) +
                                        " paintedW=" + itemImage.paintedWidth.toFixed(0) + " paintedH=" + itemImage.paintedHeight.toFixed(0) +
                                        " implicitW=" + itemImage.implicitWidth.toFixed(0) + " implicitH=" + itemImage.implicitHeight.toFixed(0) +
                                        " itemZoom=" + gridCell.itemZoom.toFixed(2))
                                }
                            }
                        }

                        // 图片容器（用于缩放）
                        Item {
                            id: imageContainer
                            anchors.fill: parent
                            anchors.margins: 2
                            clip: true
                            
                            onWidthChanged: {
                                captureManager.zoomLog("📦 容器尺寸变化: dataIndex=" + gridCell.dataIndex + " containerW=" + width.toFixed(0))
                                // ⭐ 容器大小变化时重新计算偏移量边界
                                if (gridCell.itemZoom > 1.0 && width > 0) {
                                    var maxOffsetX = width * (gridCell.itemZoom - 1) / 2
                                    var maxOffsetY = height * (gridCell.itemZoom - 1) / 2
                                    gridCell.itemOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, gridCell.itemOffsetX))
                                    gridCell.itemOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, gridCell.itemOffsetY))
                                }
                            }
                            
                            Image {
                                id: itemImage
                                // ⭐ 完全铺满容器（拉伸填充）
                                // 使用手动居中 + 偏移量实现缩放拖动
                                x: parent.width / 2 - width / 2 + gridCell.itemOffsetX
                                y: parent.height / 2 - height / 2 + gridCell.itemOffsetY
                                width: parent.width * gridCell.itemZoom
                                height: parent.height * gridCell.itemZoom
                                
                                source: ""
                                fillMode: Image.Stretch  // 拉伸铺满，完全填充容器
                                cache: false
                                visible: gridCell.hasData
                                asynchronous: false
                                mirror: mainPage.videoMirrorMode === "horizontal"
                                mirrorVertically: mainPage.videoMirrorMode === "vertical"

                                function loadCurrentFrame() {
                                    if (gridCell.hasData) {
                                        source = "image://capture/frame/" + gridCell.dataIndex + "/" + gridCell.currentFrame + "?v=" + gridCell.frameVersion
                                    }
                                }

                                Component.onCompleted: loadCurrentFrame()
                                onVisibleChanged: if (visible) loadCurrentFrame()

                                onStatusChanged: {
                                    if (status === Image.Ready) {
                                        captureManager.zoomLog("🖼️ 图片加载: dataIndex=" + gridCell.dataIndex + " frame=" + gridCell.currentFrame + 
                                            " W=" + width.toFixed(0) + " H=" + height.toFixed(0) +
                                            " paintedW=" + paintedWidth.toFixed(0) + " paintedH=" + paintedHeight.toFixed(0) +
                                            " implicitW=" + implicitWidth.toFixed(0) + " implicitH=" + implicitHeight.toFixed(0) +
                                            " sourceW=" + sourceSize.width + " sourceH=" + sourceSize.height +
                                            " itemZoom=" + gridCell.itemZoom.toFixed(2))
                                    } else if (status === Image.Error && gridCell.hasData && source === "") {
                                        source = "image://capture/thumbnail/" + gridCell.dataIndex
                                    }
                                }
                                
                                // 🔍 追踪实际渲染尺寸
                                onWidthChanged: {
                                    captureManager.zoomLog("📐 Image尺寸: dataIndex=" + gridCell.dataIndex + " W=" + width.toFixed(0) + " H=" + height.toFixed(0) + " x=" + x.toFixed(0) + " y=" + y.toFixed(0) + " parentW=" + parent.width.toFixed(0) + " itemZoom=" + gridCell.itemZoom.toFixed(2) + " itemOffsetX=" + gridCell.itemOffsetX.toFixed(1))
                                }
                            }
                        }
                        
                        // 无数据时显示数字
                        Item {
                            anchors.fill: parent
                            visible: !gridCell.hasData
                            
                            Text {
                                anchors.centerIn: parent
                                text: gridCell.dataIndex + 1
                                // ⭐ 2026-08-14 对齐老 Java（GridLayoutManager.NUMBER_LABEL_STYLE）：#666666 36px 粗体
                                font.bold: true
                                font.pixelSize: 36
                                color: "#666666"
                            }
                        }
                        
                        // 左上角帧数数字：对齐老 Java（SnapshotPlayerView.statusLabel）——白色粗体 + 半透明黑底圆角
                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.margins: 6
                            visible: gridCell.hasData && gridCell.totalFrames > 0
                            z: 1
                            width: frameIndexText.width + 16   // 老 Java padding: 4 8
                            height: frameIndexText.height + 8
                            radius: 6
                            color: "#33000000"  // rgba(0,0,0,0.2)
                            Text {
                                id: frameIndexText
                                anchors.centerIn: parent
                                text: (gridCell.currentFrame + 1)  // 只显示当前帧数
                                font.pixelSize: 12
                                font.bold: true
                                color: "#FFFFFF"
                            }
                        }

                        // ⭐ 2026-07-16：截图item——底部切帧进度条（贴底细条，只在鼠标悬停这一格时显示）。
                        //   拖动=只切这一张；Ctrl+拖动=广播给全 grid 同步切帧（跟 Ctrl+滚轮效果一致）。
                        // ⭐ 2026-08-14 需求：截图里不再显示滑动条（代码保留，滚轮/左右键切帧不受影响）
                        Item {
                            id: gridFrameBar
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 20  // ⭐ 2026-07-16：放大一倍（原 10）
                            visible: false  // 原：gridCell.hasData && gridCell.totalFrames > 0 && gridCell.frameBarHovered
                            z: 2

                            property int ctrlLastTarget: gridCell.currentFrame

                            function ratioToFrame(ratio) {
                                var tf = gridCell.totalFrames
                                if (tf <= 0) return 0
                                return Math.round(Math.max(0, Math.min(1, ratio)) * (tf - 1))
                            }
                            function applyCtrlBroadcast(target) {
                                var delta = target - gridFrameBar.ctrlLastTarget
                                gridFrameBar.ctrlLastTarget = target
                                for (var i = 0; i < Math.abs(delta); i++) {
                                    mainPage.gridSyncFrameStep(delta > 0 ? "next" : "prev")
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                color: "#80000000"
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.margins: 5
                                height: 6  // ⭐ 放大一倍（原 3）
                                radius: 999
                                color: "#C8E6C9"
                            }
                            Rectangle {
                                id: gridFrameHandle
                                width: 18; height: 18; radius: 9  // ⭐ 放大一倍（原 9/9/4.5）
                                color: "#A5D6A7"
                                anchors.verticalCenter: parent.verticalCenter
                                x: gridCell.totalFrames > 1 ?
                                   gridCell.currentFrame / (gridCell.totalFrames - 1) * (parent.width - 18) : 0
                            }
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -3
                                drag.target: gridFrameHandle
                                drag.axis: Drag.XAxis
                                drag.minimumX: 0
                                drag.maximumX: gridFrameBar.width - 18

                                property bool ctrlDrag: false

                                onWheel: function(wheel) {
                                    wheel.accepted = true
                                    if (gridCell.totalFrames <= 0) return
                                    var target = wheel.angleDelta.y > 0 ? gridCell.currentFrame - 1 : gridCell.currentFrame + 1
                                    mainPage.jumpCaptureFrame(gridCell.dataIndex, target)
                                    gridCell.currentFrame = captureManager.getCurrentOffset(gridCell.dataIndex)
                                }
                                onPressed: function(mouse) {
                                    if (gridCell.totalFrames <= 1) return
                                    ctrlDrag = !!(mouse.modifiers & Qt.ControlModifier)
                                    if (ctrlDrag) {
                                        gridFrameBar.ctrlLastTarget = gridCell.currentFrame
                                    } else {
                                        var ratio0 = mouse.x / gridFrameBar.width
                                        mainPage.jumpCaptureFrame(gridCell.dataIndex, gridFrameBar.ratioToFrame(ratio0))
                                        gridCell.currentFrame = captureManager.getCurrentOffset(gridCell.dataIndex)
                                    }
                                }
                                onPositionChanged: {
                                    if (!drag.active || gridCell.totalFrames <= 1) return
                                    var ratio = gridFrameHandle.x / (gridFrameBar.width - 18)
                                    var frame = gridFrameBar.ratioToFrame(ratio)
                                    if (ctrlDrag) {
                                        gridFrameBar.applyCtrlBroadcast(frame)
                                    } else {
                                        mainPage.jumpCaptureFrame(gridCell.dataIndex, frame)
                                        gridCell.currentFrame = captureManager.getCurrentOffset(gridCell.dataIndex)
                                    }
                                }
                            }
                        }

                    }
                }
    }
    
    // ============ 实时流内容（可交换）============
    Item {
        id: livePanelContent
        // 根据布局模式选择父容器: 模式1时放左侧，否则放右上
        parent: windowLayoutMode === 1 ? leftHolder : rightTopHolder
        anchors.fill: parent
        
        // 阴影
        Rectangle {
            anchors.fill: livePanel
            anchors.topMargin: 1
            anchors.bottomMargin: -1
            radius: 4
            color: "#1A000000"
        }
        
        Rectangle {
            id: livePanel
            anchors.fill: parent
            color: "#292929"  // ⭐ 对齐 java gstream 实时窗口色（element2_1）
            radius: 4
            
            // 用于追踪整个区域的hover状态
            property bool isHovering: livePanelHover.containsMouse

            // ⭐ 2026-07-15：网页内核模式下，livePanelHover（z:1000，铺满整个面板）会挡住
            //   WebEngineView 的真实 hover 事件，导致页面自己收不到 mousemove——这里改成
            //   QML 拿到的 hover 状态可靠时，主动转发给页面，页面被动显隐即可，不用自己猜。
            onIsHoveringChanged: {
                if (mainPage.useWebEngineKernel && kernelPlayerLoader.item && kernelPlayerLoader.item.setStatsHover) {
                    kernelPlayerLoader.item.setStatsHover(isHovering)
                }
            }

                    // 视频容器（用于旋转）
                    Item {
                        id: videoContainer
                        anchors.fill: parent
                        anchors.margins: 2
                        clip: true
                        onWidthChanged: mainPage.clampVideoOffsets()
                        onHeightChanged: mainPage.clampVideoOffsets()

                        // 视频输出
                        VideoOutput {
                            id: liveVideoPlayer
                            // ⭐ 网页内核模式下隐藏 GStreamer 输出（改由下方 webview 显示画面）
                            visible: !mainPage.useWebEngineKernel
                            // 根据旋转角度调整宽高
                            width: (mainPage.videoRotation === 90 || mainPage.videoRotation === 270) 
                                   ? parent.height : parent.width
                            height: (mainPage.videoRotation === 90 || mainPage.videoRotation === 270) 
                                    ? parent.width : parent.height
                            // ⭐ 2026-08-15 修「旋转画面变形」：原 Stretch 不保宽高比，
                            //   90°/270° 时竖幅画面被强行拉满横向面板必定变形，
                            //   0°/180° 在面板比例≠视频比例时也有轻度拉伸。改保比例留边。
                            fillMode: VideoOutput.PreserveAspectFit
                            
                            // 设置变换原点为中心
                            x: parent.width / 2 - width / 2 + mainPage.videoOffsetX
                            y: parent.height / 2 - height / 2 + mainPage.videoOffsetY
                            
                            transform: [
                                Rotation {
                                    origin.x: liveVideoPlayer.width / 2
                                    origin.y: liveVideoPlayer.height / 2
                                    angle: mainPage.videoRotation
                                },
                                Scale {
                                    origin.x: liveVideoPlayer.width / 2
                                    origin.y: liveVideoPlayer.height / 2
                                    xScale: mainPage.videoMirrorMode === "horizontal" ? -mainPage.videoZoom : mainPage.videoZoom
                                    yScale: mainPage.videoMirrorMode === "vertical" ? -mainPage.videoZoom : mainPage.videoZoom
                                }
                            ]
                            
                            Component.onCompleted: {
                                // 使用 GstPlayer 输出到 VideoOutput
                                gstPlayer.videoSink = liveVideoPlayer.videoSink
                            }
                            
                            layer.enabled: false  // 不再使用 shader，颜色调整由 GStreamer videobalance 和 gamma 处理
                        }

                        // ⭐ 右上角信息开关（默认隐藏统计面板，点击切换显示）
                        // ⭐ 2026-08-14 aihj：老 java gstream 没有时时流统计面板 → 入口和面板一律隐藏（代码保留）
                        Rectangle {
                            id: gstStatsToggle
                            visible: false
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 10
                            z: 6
                            width: 26
                            height: 26
                            radius: 13
                            color: gstStatsToggleArea.containsMouse ? "#C8000000" : (mainPage.gstStatsVisible ? "#C81565C0" : "#A0000000")
                            border.color: "#7FD8FF"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: "ⓘ"
                                font.pixelSize: 15
                                color: "#E8F5E9"
                            }
                            MouseArea {
                                id: gstStatsToggleArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mainPage.gstStatsVisible = !mainPage.gstStatsVisible
                            }
                        }

                        // ⭐ GStreamer 模式左上角统计面板（对标网页内核统计；数据复用 GstPlayer 现有统计，1s 轮询）
                        // ⭐ 2026-07-15 改回点击展开：显隐只看 gstStatsVisible（点右上角 ⓘ 切换），
                        //   跟鼠标是否还在画面内无关——点开后不会因为鼠标移到别处就消失，再点一次收起。
                        Rectangle {
                            id: gstStatsPanel
                            visible: !mainPage.useWebEngineKernel && gstPlayer.playing && mainPage.gstStatsVisible
                            opacity: mainPage.gstStatsVisible ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: 10
                            z: 5
                            radius: 6
                            color: "#A0000000"
                            width: gstStatsText.implicitWidth + 20
                            height: gstStatsText.implicitHeight + 16

                            property string infoHtml: ""

                            function refresh() {
                                if (!gstPlayer.playing) return
                                var loss = gstPlayer.statLossPct()
                                var stall = gstPlayer.statStallSeconds()
                                var lossColor = loss >= 2 ? "#FF6E6E" : "#9CDCAA"
                                var stallColor = stall >= 1 ? "#FF6E6E" : "#9CDCAA"
                                var K = function(t){ return '<span style="color:#7FD8FF">' + t + '</span>' }
                                var route = gstPlayer.statRoute()
                                var routeColor = (route.indexOf("中继") >= 0) ? "#FFC857" : (route.indexOf("直连") >= 0 ? "#9CDCAA" : "#B0B0B0")
                                // ⭐ §56.28b 用户拍板：编码显示**故意**恒为 H265（障眼，不暴露真实会话编码；
                                //   同理下面解码器名称里的 264/avc 字样也伪装成 265/hevc）
                                var codecTxt = '<span style="color:#FFC857">H265</span>'
                                // ⭐ P2P 连接阶段（切网重连过程）：非「已连接」时置顶醒目显示
                                var phase = mainPage.p2pPhaseText(gstPlayer.webrtcStatus)
                                var phaseHtml = phase.length > 0
                                    ? '<span style="color:' + mainPage.p2pPhaseColor(gstPlayer.webrtcStatus) + '">● ' + phase + '</span><br>'
                                    : ''
                                gstStatsPanel.infoHtml =
                                    phaseHtml +
                                    K("引擎") + ": GStreamer · " + gstPlayer.statConnMode() + " · " + codecTxt + "<br>" +
                                    '<span style="color:' + routeColor + '">线路</span>: ' + route + "　(" + gstPlayer.statRouteDetail() + ")<br>" +
                                    K("分辨率") + ": " + gstPlayer.videoWidth + "x" + gstPlayer.videoHeight + "<br>" +
                                    K("解码FPS") + ": " + gstPlayer.receiveFps + "<br>" +
                                    K("解码") + ": " + String(gstPlayer.decoderName).replace(/264/g, "265").replace(/avc/gi, "hevc") + "<br>" +
                                    '<span style="color:' + lossColor + '">丢包率</span>: ' + loss.toFixed(2) + "%　(本秒丢 " + gstPlayer.statLostPerSec() + ")<br>" +
                                    K("NACK") + ": " + gstPlayer.statNackPerSec() + "/s　" + K("重传补回") + ": " + gstPlayer.statRtxOkPerSec() + "/s<br>" +
                                    K("PLI") + ": " + gstPlayer.statPliCount() + "<br>" +
                                    K("抖动") + ": " + gstPlayer.statJitterMs() + " ms<br>" +
                                    K("抖动缓冲") + ": " + gstPlayer.bufferSize + "/" + gstPlayer.bufferTarget + " 帧　队列 " + gstPlayer.statQueueDepth() + "<br>" +
                                    '<span style="color:' + stallColor + '">卡顿</span>: ' + stall + " s"
                            }

                            Text {
                                id: gstStatsText
                                anchors.centerIn: parent
                                textFormat: Text.RichText
                                text: gstStatsPanel.infoHtml
                                font.family: "Consolas"
                                font.pixelSize: 12
                                color: "#E8F5E9"
                                lineHeight: 1.15
                            }

                            Timer {
                                interval: 1000
                                repeat: true
                                running: gstStatsPanel.visible
                                triggeredOnStart: true
                                onTriggered: gstStatsPanel.refresh()
                            }
                        }

                        // ⭐ 网页内核（Chromium WebEngine）主播放器（2026-06-24）：
                        //   useWebEngineKernel 时全屏铺满 videoContainer，替代上面的 VideoOutput。
                        //   缩放/镜像/旋转由 applyTransform(CSS transform) 处理；下发 iOS 的按钮在外层
                        //   liveControlBar，与内核无关、原样复用。生命周期由 play*/stopAll 分流到 startTest/stopTest。
                        Loader {
                            id: kernelPlayerLoader
                            anchors.fill: parent
                            z: 2  // 盖在 VideoOutput 之上（VideoOutput 此时已 visible:false）
                            active: mainPage.useWebEngineKernel
                            source: mainPage.useWebEngineKernel ? "KernelTestView.qml" : ""
                            // ⭐ 2026-07-03（§24 登录卡顿优化）：异步加载。WebEngineView 首个视图要拉起
                            //   Chromium 渲染进程，同步实例化会把刚显示的主页整窗冻住（低配机秒级）。
                            asynchronous: true
                            onLoaded: {
                                item.topInset = 0  // 主播放器全屏，无标题栏留白
                                // 加载完成后立即按当前连接模式拉流
                                mainPage.kernelStartByMode()
                                // 同步当前本地变换
                                mainPage.kernelSyncTransform()
                                // ⭐ 补一次统计面板 hover 状态同步（防止加载完成时鼠标已经在面板内）
                                if (item.setStatsHover) item.setStatsHover(livePanel.isHovering)
                            }
                        }
                        
                        
                        // 滚轮：S+滚轮控制镜头变倍(1.0-3.0)，普通滚轮控制本地缩放(1.0-5.0)
                        MouseArea {
                            id: videoZoomArea
                            anchors.fill: parent
                            // ⭐ 网页内核模式下，画面交互（缩放等）由 webview 内部/CSS 处理，
                            //   但本地缩放滚轮仍要可用（改 videoZoom → applyTransform），故保持启用。
                            //   左键抓拍在内核模式走第三步 JS 侧，这里点击不再触发 GStreamer 抓拍。
                            hoverEnabled: true
                            
                            onEntered: {
                                // ⭐ 恢复键盘焦点（确保S键检测正常工作）
                                mainPage.forceActiveFocus()
                            }
                            
                            onClicked: {
                                // 点击视频区域时关闭档位下拉菜单
                                qualityMenu.visible = false
                                // ⭐ 网页内核模式下截图走第三步 JS 侧，GStreamer 抓拍不可用，跳过
                                if (mainPage.useWebEngineKernel) {
                                    console.log("🌐 [网页内核] 左键抓拍：待第三步 JS 侧实现，暂跳过 GStreamer 抓拍")
                                    return
                                }
                                // 鼠标左键 = 空格键，触发抓拍
                                EventBus.triggerCapture()
                            }
                            
                            onWheel: function(wheel) {
                                if (mainPage.sKeyPressed) {
                                    // S+滚轮：镜头变倍 (lens zoom 1.0-3.0)
                                    var oldLensZoom = iosCameraSettingsPopup.lensZoom
                                    var delta = wheel.angleDelta.y > 0 ? 0.1 : -0.1
                                    var newLensZoom = Math.max(1.0, Math.min(3.0, oldLensZoom + delta))
                                    
                                    if (newLensZoom !== oldLensZoom) {
                                        iosCameraSettingsPopup.lensZoom = newLensZoom
                                        HttpClient.updateZoom(newLensZoom)
                                        sendConfigUpdate("zoom", {"zoom": newLensZoom})
                                        console.log("🔍 S+滚轮 镜头变倍:", oldLensZoom.toFixed(1), "->", newLensZoom.toFixed(1))
                                    }
                                } else {
                                    // 普通滚轮：本地显示缩放 (1.0-5.0)，复用统一的聚焦缩放数学。
                                    // ⭐ 实时流本地放大始终可用，PC等级限制只影响截图item继承和慢放。
                                    //   （网页内核模式下 webview 吃掉滚轮，改由 kernelBridge.wheelZoomRequested
                                    //    走同一个 applyWheelZoom，行为完全一致。）
                                    mainPage.applyWheelZoom(wheel.angleDelta.y > 0, wheel.x, wheel.y)
                                }
                            }
                        }
                    }
                    
                    // 设备状态文字层（当设备睡眠/唤醒时显示）
                    Rectangle {
                        id: deviceStatusOverlay
                        anchors.fill: videoContainer
                        color: "#292929"  // 跟实时窗口同色
                        z: 1  // 层级在noVideoOverlay之上，但在控制栏之下
                        visible: mainPage.deviceStatus !== ""
                        
                        Text {
                            anchors.centerIn: parent
                            text: mainPage.deviceStatus === "sleeping" ? "睡眠中..." : "唤醒中..."
                            font.family: "PingFang HK"
                            font.pixelSize: 18
                            font.bold: true
                            color: mainPage.panelTextColor  // 文字色随面板调整
                        }
                    }
                    
                    // 暂无画面（未推流时显示，覆盖在视频上）
                    Rectangle {
                        id: noVideoOverlay
                        anchors.fill: videoContainer
                        color: "#292929"  // 跟实时窗口同色
                        visible: mainPage.publishState !== 1 && mainPage.deviceStatus === ""
                        
                        // 2026-08-14 去掉图标只留文字；2026-08-15 字体放大 3 倍并加粗
                        Text {
                            anchors.centerIn: parent
                            text: "暂无画面"
                            font.family: "PingFang HK"
                            font.pixelSize: 42
                            font.bold: true
                            color: mainPage.panelTextColor  // 文字色随面板调整
                        }
                    }

                    // ⭐ §56.29b 不支持遮罩：主版(PC-SRS)连到「外接 OTG」设备 → 画面完全遮死，只提示「不支持」
                    Rectangle {
                        id: unsupportedOtgOverlay
                        anchors.fill: videoContainer
                        color: "#000000"
                        z: 10  // 盖住视频/睡眠遮罩/FPS/LIVE 等所有画面层
                        visible: CameraCapsStore.isOtg

                        Text {
                            anchors.centerIn: parent
                            text: "不支持"
                            font.family: "PingFang HK"
                            font.pixelSize: 26
                            font.bold: true
                            color: "#FFFFFF"
                        }

                        // 吞掉点击/滚轮，画面区不可缩放拖动
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onWheel: (wheel) => { wheel.accepted = true }
                        }
                    }


                    Rectangle {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 8
                        width: liveInfoCol.width + 16
                        height: liveInfoCol.height + 12
                        color: "#80000000"
                        radius: 4
                        visible: webrtcClient.isConnected()

                        Column {
                            id: liveInfoCol
                            anchors.centerIn: parent
                            spacing: 2

                            Text {
                                id: liveInfoFps
                                text: "FPS: --"
                                color: "#4caf50"
                                font.pixelSize: 11
                            }
                            Text {
                                text: gstPlayer.videoWidth + "×" + gstPlayer.videoHeight
                                color: "#ffffff"
                                font.pixelSize: 11
                            }
                        }
                    }

            // LIVE 状态指示（只在连接时显示）
            Text {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 8
                z: 10
                text: "● LIVE"
                color: "#4caf50"
                font.pixelSize: 12
                font.bold: true
                visible: webrtcClient.isConnected()
            }
            
            // 底部控制栏（移到 livePanel 层级，不被覆盖层遮挡）
            // ⭐ 第五十章：这一排是「自带摄像头」版（固定5档/倍数变倍/前后置）。
            //   OTG 设备整排换成 OtgLiveControlBar（见下），这里不做逐按钮的 if-else。
            Row {
                id: liveControlBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 10
                spacing: 8
                z: 100  // 确保在覆盖层之上
                visible: livePanel.isHovering && !CameraCapsStore.isOtg
                opacity: livePanel.isHovering ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200 } }
                // onVisibleChanged: console.log("🎮 liveControlBar visible:", visible)
                
                // 档位切换下拉列表
                Rectangle {
                    id: qualityDropdown
                    width: 70
                    height: 32
                    radius: 4
                    color: qualityDropdownArea.containsMouse || qualityMenu.visible ? "#C8E6C9" : "#80000000"
                    
                    Row {
                        anchors.centerIn: parent
                        spacing: 4
                        
                        Text {
                            id: qualityButtonText
                            text: "高清"
                            font.pixelSize: 12
                            font.family: "PingFang HK"
                            font.bold: true
                            color: qualityDropdownArea.containsMouse || qualityMenu.visible ? "#263238" : "#FFFFFF"
                        }
                        
                        Text {
                            text: "▼"
                            font.pixelSize: 8
                            color: qualityDropdownArea.containsMouse || qualityMenu.visible ? "#263238" : "#FFFFFF"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    
                    MouseArea {
                        id: qualityDropdownArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: qualityMenu.visible = !qualityMenu.visible
                    }
                    
                    // 下拉菜单
                    Rectangle {
                        id: qualityMenu
                        visible: false
                        width: parent.width
                        height: qualityColumn.height + 8
                        anchors.bottom: parent.top
                        anchors.bottomMargin: 4
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: "#E8F5E9"
                        radius: 4
                        border.color: "#A5D6A7"
                        border.width: 1
                        
                        Column {
                            id: qualityColumn
                            anchors.centerIn: parent
                            spacing: 2
                            
                            Repeater {
                                // ⭐ 2026-08-14 档位对齐 java gstream，只有四档（按 iOS 实采分辨率升序）：
                                //   标清=low(640x480) / 高清=ultra(1280x720) / 超清=high(1440x1080) / 4K=p4k
                                //   注意：iOS 端的 type 命名与分辨率不成正比（high 反而比 ultra 高），此处按实际分辨率对齐老 java 档位名
                                model: [
                                    { label: "标清", type: "low" },
                                    { label: "高清", type: "ultra" },
                                    { label: "超清", type: "high" },
                                    { label: "4K", type: "p4k" }
                                    // 超快帧：暂不开放，已从档位列表隐藏
                                ]
                                
                                Rectangle {
                                    property bool accessible: isQualityAccessible(modelData.label)
                                    property bool isActive: modelData.type === "ultrafast" ? mainPage.highSpeed240Enabled : (qualityButtonText.text === modelData.label)
                                    width: qualityMenu.width - 8
                                    height: 28
                                    radius: 3
                                    color: !accessible ? "#ECEFF1" : (qualityItemArea.containsMouse ? "#C8E6C9" : (isActive ? "#A5D6A7" : "transparent"))

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        font.pixelSize: 12
                                        font.family: "PingFang HK"
                                        font.bold: true
                                        color: parent.accessible ? "#263238" : "#90A4AE"
                                    }
                                    
                                    MouseArea {
                                        id: qualityItemArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: parent.accessible ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                                        onClicked: {
                                            if (parent.accessible) {
                                                if (modelData.type === "ultrafast") {
                                                    // 超快帧：开发中，暂不开放
                                                    showQualityAccessDeniedTip("超快帧（开发中）")
                                                    qualityMenu.visible = false
                                                } else {
                                                    // 切到其他档位时，如果当前在超快帧模式则自动退出
                                                    if (mainPage.highSpeed240Enabled) {
                                                        mainPage.highSpeed240Enabled = false
                                                        sendConfigUpdate("highspeed", {"fps": 30})
                                                        console.log("⚡ 切换档位，自动退出超快帧模式")
                                                    }
                                                    switchQuality(modelData.type, modelData.label)
                                                    qualityMenu.visible = false
                                                }
                                            } else {
                                                showQualityAccessDeniedTip(modelData.label)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                // ⭐ 2026-08-15 对焦快捷按钮（放在档位/分辨率后面）：
                //   数值直接显示在按钮上（百分比），鼠标滚轮在按钮上滚动即可调节，不再弹滑条。
                //   与「相机设定」弹框里的对焦同源（iosCameraSettingsPopup.focusValue），两边互相同步
                Rectangle {
                    id: focusQuickBtn
                    width: 86
                    height: 32
                    radius: 4
                    color: focusQuickArea.containsMouse ? "#C8E6C9" : "#80000000"

                    Text {
                        anchors.centerIn: parent
                        // 显示真实对焦值（0.00~1.00），不用百分比
                        text: "对焦 " + iosCameraSettingsPopup.focusValue.toFixed(2)
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        font.bold: true
                        color: focusQuickArea.containsMouse ? "#263238" : "#FFFFFF"
                    }

                    MouseArea {
                        id: focusQuickArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // 左键加、右键减（步长0.05），滚轮微调（步长0.01）
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: function(mouse) {
                            var delta = mouse.button === Qt.LeftButton ? 0.05 : -0.05
                            var nv = Math.max(0, Math.min(1, iosCameraSettingsPopup.focusValue + delta))
                            iosCameraSettingsPopup.focusValue = nv
                            HttpClient.updateFocusDistance(nv)
                            sendConfigUpdate("focus", {"focus": nv})
                        }
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? 0.01 : -0.01
                            var nv = Math.max(0, Math.min(1, iosCameraSettingsPopup.focusValue + delta))
                            iosCameraSettingsPopup.focusValue = nv
                            HttpClient.updateFocusDistance(nv)
                            sendConfigUpdate("focus", {"focus": nv})
                        }
                    }
                }

                // 镜头变倍按钮
                Rectangle {
                    id: lensZoomButtonRect
                    width: 50
                    height: 32
                    radius: 4
                    color: lensZoomBtnArea.containsMouse ? "#C8E6C9" : "#80000000"
                    
                    Text {
                        id: lensZoomButtonText
                        anchors.centerIn: parent
                        text: iosCameraSettingsPopup.lensZoom.toFixed(1) + "倍"
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        font.bold: true
                        color: lensZoomBtnArea.containsMouse ? "#263238" : "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: lensZoomBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            iosCameraSettingsPopup.lensZoom = 1.0
                            HttpClient.updateZoom(1.0)
                            sendConfigUpdate("zoom", {"zoom": 1.0})
                        }
                        onWheel: function(wheel) {
                            var oldZoom = iosCameraSettingsPopup.lensZoom
                            var delta = wheel.angleDelta.y > 0 ? 0.1 : -0.1
                            var newZoom = Math.max(1.0, Math.min(3.0, oldZoom + delta))
                            if (newZoom !== oldZoom) {
                                iosCameraSettingsPopup.lensZoom = newZoom
                                HttpClient.updateZoom(newZoom)
                                sendConfigUpdate("zoom", {"zoom": newZoom})
                            }
                        }
                    }
                }
                
                // 前后置切换按钮
                Rectangle {
                    width: 36
                    height: 32
                    radius: 4
                    color: switchCameraBtn.containsMouse ? "#C8E6C9" : "#80000000"
                    
                    Text {
                        id: switchCameraText
                        anchors.centerIn: parent
                        // direction: "1"=后置(显示"前"表示点击切换到前置), "-1"=前置(显示"后"表示点击切换到后置)
                        text: iosCameraSettingsPopup.directionValue === "1" ? "前" : "后"
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        font.bold: true
                        color: switchCameraBtn.containsMouse ? "#263238" : "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: switchCameraBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // 切换前后置：1 变 -1，-1 变 1
                            var currentDir = iosCameraSettingsPopup.directionValue
                            var newDir = (currentDir === "1") ? "-1" : "1"
                            iosCameraSettingsPopup.directionValue = newDir
                            HttpClient.updateDirection(newDir)
                            sendConfigUpdate("direction", {"direction": newDir})
                            console.log("📷 切换摄像头方向:", currentDir, "->", newDir)
                        }
                    }
                }

                // 镜像下拉菜单
                Rectangle {
                    id: mirrorDropdown
                    width: 50
                    height: 32
                    radius: 4
                    color: mirrorDropdownArea.containsMouse || mirrorMenu.visible
                           ? "#C8E6C9"
                           : (mainPage.videoMirrorMode !== "none" ? "#4CAF50" : "#80000000")

                    Row {
                        anchors.centerIn: parent
                        spacing: 3

                        Text {
                            id: mirrorBtnText
                            text: mainPage.videoMirrorMode === "horizontal" ? "水平"
                                : mainPage.videoMirrorMode === "vertical" ? "垂直" : "镜像"
                            font.pixelSize: 12
                            font.family: "PingFang HK"
                            font.bold: true
                            color: mirrorDropdownArea.containsMouse || mirrorMenu.visible ? "#263238" : "#FFFFFF"
                        }

                        Text {
                            text: "▼"
                            font.pixelSize: 8
                            color: mirrorBtnText.color
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: mirrorDropdownArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mirrorMenu.visible = !mirrorMenu.visible
                    }

                    Rectangle {
                        id: mirrorMenu
                        visible: false
                        width: 60
                        height: mirrorCol.height + 8
                        anchors.bottom: parent.top
                        anchors.bottomMargin: 4
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: "#E8F5E9"
                        radius: 4
                        border.color: "#A5D6A7"
                        border.width: 1

                        Column {
                            id: mirrorCol
                            anchors.centerIn: parent
                            spacing: 2

                            Repeater {
                                model: [
                                    { label: "关闭", mode: "none" },
                                    { label: "水平", mode: "horizontal" },
                                    { label: "垂直", mode: "vertical" }
                                ]

                                Rectangle {
                                    width: mirrorMenu.width - 8
                                    height: 28
                                    radius: 3
                                    color: mirrorItemArea.containsMouse ? "#C8E6C9"
                                         : (mainPage.videoMirrorMode === modelData.mode ? "#A5D6A7" : "transparent")

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        font.pixelSize: 12
                                        font.family: "PingFang HK"
                                        font.bold: true
                                        color: "#263238"
                                    }

                                    MouseArea {
                                        id: mirrorItemArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            mainPage.videoMirrorMode = modelData.mode
                                            mirrorMenu.visible = false
                                            console.log("🪞 镜像模式:", modelData.mode)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                // 弹性空间
                Item { Layout.fillWidth: true; width: 10 }
                
                // 本地缩放显示/重置按钮
                Rectangle {
                    width: 50
                    height: 32
                    radius: 4
                    color: zoomResetBtn.containsMouse ? "#C8E6C9" : "#80000000"
                    visible: mainPage.videoZoom > 1.0
                    
                    Text {
                        anchors.centerIn: parent
                        text: mainPage.videoZoom.toFixed(1) + "x"
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        font.bold: true
                        color: zoomResetBtn.containsMouse ? "#263238" : "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: zoomResetBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            mainPage.videoZoom = 1.0
                            mainPage.videoOffsetX = 0
                            mainPage.videoOffsetY = 0
                            // ⭐ 推送本地视觉效果到其他PC
                            sendLocalViewUpdate(1.0, 0, 0)
                        }
                    }
                }
                
                // 旋转按钮
                Rectangle {
                    width: 36
                    height: 32
                    radius: 4
                    color: rotateBtn.containsMouse ? "#C8E6C9" : "#80000000"
                    
                    Text {
                        anchors.centerIn: parent
                        text: mainPage.videoRotation + "°"
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        font.bold: true
                        color: rotateBtn.containsMouse ? "#263238" : "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: rotateBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            mainPage.videoRotation = (mainPage.videoRotation + 90) % 360
                        }
                        onWheel: function(wheel) {
                            if (wheel.angleDelta.y > 0) {
                                mainPage.videoRotation = (mainPage.videoRotation + 90) % 360
                            } else {
                                mainPage.videoRotation = (mainPage.videoRotation - 90 + 360) % 360
                            }
                        }
                    }
                }
                
                // 睡眠按钮
                Rectangle {
                    width: 50
                    height: 32
                    radius: 4
                    color: sleepBtnLive.containsMouse ? "#C8E6C9" : "#80000000"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "睡眠"
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        font.bold: true
                        color: sleepBtnLive.containsMouse ? "#263238" : "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: sleepBtnLive
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            console.log("📤 点击睡眠按钮")
                            mainPage.deviceStatus = "sleeping"
                            // ⭐ 主动停止拉流并重置状态，确保唤醒后能重新连接
                            if (publishState === 1) {
                                console.log("📤 睡眠：主动停止拉流，publishState 1 → 0")
                                stopAll()
                            }
                            publishState = 0
                            sendDeviceCommand("shuimian")
                        }
                    }
                }
                
                // 工作按钮
                Rectangle {
                    width: 50
                    height: 32
                    radius: 4
                    color: workBtnLive.containsMouse ? "#C8E6C9" : "#80000000"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "工作"
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        font.bold: true
                        color: workBtnLive.containsMouse ? "#263238" : "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: workBtnLive
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            console.log("📤 点击工作按钮")
                            mainPage.deviceStatus = "waking"
                            // ⭐ 主动停止旧连接并重置状态，确保收到 CONFIG_STATE(publishStatus=1) 时能触发 playWebRTC()
                            if (publishState === 1) {
                                console.log("📤 工作：主动停止旧拉流，publishState 1 → 0")
                                stopAll()
                            }
                            publishState = 0
                            isConnecting = false
                            sendDeviceCommand("gongzuo")
                        }
                    }
                }
            }
            
            // ⭐ 第五十章：OTG 版底部按钮栏（独立文件 OtgLiveControlBar.qml）。
            //   设备侧的三个按钮（分辨率档位/推送帧率/码率/变焦）全走 otg_ 独立通道；
            //   右半边镜像/缩放/旋转/睡眠/工作与镜头无关，只发信号复用下面既有实现。
            OtgLiveControlBar {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 10
                z: 100
                visible: livePanel.isHovering && CameraCapsStore.isOtg
                opacity: visible ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200 } }

                mirrorMode: mainPage.videoMirrorMode
                localZoom: mainPage.videoZoom
                videoRotation: mainPage.videoRotation

                onSendOtg: function(ptype, payload) {
                    console.log("🔗 [OTG链路|PC下发] " + ptype + " " + JSON.stringify(payload))
                    sendConfigUpdate(ptype, payload)
                    // ⭐ 2026-08-03 修「OTG 切档卡死」：分辨率中途变化，解码器必须等到新关键帧才能
                    //   继续出画面。自带摄像头切档有 300/500/1000/1500ms 四连 PLI（防绿幕/卡帧），
                    //   OTG 通道此前漏了这一套——补上同一个定时器序列。
                    // ⭐ 2026-08-04：otg_fps 也要——改帧率会让部分硬件编码器重置（华为实锤绿屏），
                    //   周期 IDR 已摘除，解码器坏了只能靠 PLI/设备补帧自愈。
                    if (ptype === "otg_resolution" || ptype === "otg_fps") {
                        pliAfterQualitySwitchTimer.restart()
                    }
                }
                onOpenPanelRequested: toggleOtgCameraPanel()
                onMirrorModeRequested: function(mode) { mainPage.videoMirrorMode = mode }
                onLocalZoomResetRequested: {
                    mainPage.videoZoom = 1.0
                    mainPage.videoOffsetX = 0
                    mainPage.videoOffsetY = 0
                    sendLocalViewUpdate(1.0, 0, 0)
                }
                onRotateRequested: function(step) {
                    mainPage.videoRotation = (mainPage.videoRotation + step * 90 + 360) % 360
                }
                onSleepRequested: {
                    mainPage.deviceStatus = "sleeping"
                    if (publishState === 1) stopAll()
                    publishState = 0
                    sendDeviceCommand("shuimian")
                }
                onWorkRequested: {
                    mainPage.deviceStatus = "waking"
                    if (publishState === 1) stopAll()
                    publishState = 0
                    isConnecting = false
                    sendDeviceCommand("gongzuo")
                }
            }

            // 全局 hover 检测层（放在最上层，不拦截点击）
            MouseArea {
                id: livePanelHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton  // 不拦截任何点击
                z: 1000  // 最高层级
                onContainsMouseChanged: {
                    // console.log("🖱️ livePanelHover containsMouse:", containsMouse)
                }
            }
        }
    }

    // ============ 慢放内容（可交换）============
    Item {
        id: slowmoPanelContent
        // 根据布局模式选择父容器: 模式2时放左侧，否则放右中
        parent: windowLayoutMode === 2 ? leftHolder : rightMiddleHolder
        anchors.fill: parent
        
        // 阴影
        Rectangle {
            anchors.fill: slowmoPanel
            anchors.topMargin: 1
            anchors.bottomMargin: -1
            radius: 4
            color: "#1A000000"
        }
        
        Rectangle {
            id: slowmoPanel
            anchors.fill: parent
            color: mainPage.panelBgColor  // 面板背景色（滑块可调）
            radius: 4
            clip: true

                    // 慢放视频容器（用于旋转，与实时流一致）
                    Item {
                        id: slowmoVideoContainer
                        anchors.fill: parent
                        anchors.margins: 2
                        clip: true
                        onWidthChanged: mainPage.clampSlowmoOffsets()
                        onHeightChanged: mainPage.clampSlowmoOffsets()

                        // 慢放视频输出（GPU 直接渲染，避免 QImage 内存开销）
                        VideoOutput {
                            id: slowmoVideoOutput
                            // 根据旋转角度调整宽高（与实时流一致）
                            width: (mainPage.videoRotation === 90 || mainPage.videoRotation === 270) 
                                   ? parent.height : parent.width
                            height: (mainPage.videoRotation === 90 || mainPage.videoRotation === 270) 
                                    ? parent.width : parent.height
                            // ⭐ 2026-08-15 修「旋转画面变形」：同实时流，Stretch→保比例（理由见实时流处注释）
                            fillMode: VideoOutput.PreserveAspectFit
                            visible: slowMotionPlayer.hasContent
                            
                            // ⭐ 满放跟随实时流 videoZoom, 通过 slowmoZoom/slowmoOffsetX/Y 同步
                            x: parent.width / 2 - width / 2 + mainPage.slowmoOffsetX
                            y: parent.height / 2 - height / 2 + mainPage.slowmoOffsetY

                            transform: [
                                Rotation {
                                    origin.x: slowmoVideoOutput.width / 2
                                    origin.y: slowmoVideoOutput.height / 2
                                    angle: mainPage.videoRotation
                                },
                                Scale {
                                    origin.x: slowmoVideoOutput.width / 2
                                    origin.y: slowmoVideoOutput.height / 2
                                    property real baseZoom: mainPage.slowmoZoom
                                    xScale: mainPage.videoMirrorMode === "horizontal" ? -baseZoom : baseZoom
                                    yScale: mainPage.videoMirrorMode === "vertical" ? -baseZoom : baseZoom
                                }
                            ]
                            
                            Component.onCompleted: {
                                slowMotionPlayer.videoSink = slowmoVideoOutput.videoSink
                            }
                            
                            // 色彩调节效果（与实时流一致）
                            layer.enabled: false  // 不再使用 shader，颜色调整由 GStreamer videobalance 和 gamma 处理
                        }
                        
                        // 滚轮切换帧 + 左键上一帧 + 右键下一帧（覆盖在视频上）
                        MouseArea {
                            id: slowmoMouseArea
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            z: 10  // 确保在视频之上

                            // ⭐ 左键按住拖动放大后的慢放画面（平移，无需 Z 键）
                            //    纯点击（位移＜阈值）= 上一帧；拖动（位移≥阈值）= 平移
                            property bool panning: false
                            property bool panMoved: false
                            property real panLastX: 0
                            property real panLastY: 0
                            property real panStartX: 0
                            property real panStartY: 0
                            readonly property real panThreshold: 4

                            onPressed: function(mouse) {
                                if (mouse.button === Qt.LeftButton && slowMotionPlayer.hasContent && mainPage.slowmoZoom > 1.0) {
                                    slowmoMouseArea.panning = true
                                    slowmoMouseArea.panMoved = false
                                    slowmoMouseArea.panLastX = mouse.x
                                    slowmoMouseArea.panLastY = mouse.y
                                    slowmoMouseArea.panStartX = mouse.x
                                    slowmoMouseArea.panStartY = mouse.y
                                }
                            }

                            onPositionChanged: function(mouse) {
                                if (slowmoMouseArea.panning) {
                                    if (Math.abs(mouse.x - slowmoMouseArea.panStartX) > slowmoMouseArea.panThreshold ||
                                        Math.abs(mouse.y - slowmoMouseArea.panStartY) > slowmoMouseArea.panThreshold) {
                                        slowmoMouseArea.panMoved = true
                                    }
                                    var maxX = slowmoVideoContainer.width  * (mainPage.slowmoZoom - 1) / 2
                                    var maxY = slowmoVideoContainer.height * (mainPage.slowmoZoom - 1) / 2
                                    mainPage.slowmoOffsetX = Math.max(-maxX, Math.min(maxX, mainPage.slowmoOffsetX + (mouse.x - slowmoMouseArea.panLastX)))
                                    mainPage.slowmoOffsetY = Math.max(-maxY, Math.min(maxY, mainPage.slowmoOffsetY + (mouse.y - slowmoMouseArea.panLastY)))
                                    slowmoMouseArea.panLastX = mouse.x
                                    slowmoMouseArea.panLastY = mouse.y
                                    mouse.accepted = true
                                }
                            }

                            onReleased: function(mouse) {
                                if (slowmoMouseArea.panning) {
                                    slowmoMouseArea.panning = false
                                    if (slowmoMouseArea.panMoved) mouse.accepted = true
                                }
                            }

                            onClicked: function(mouse) {
                                if (!slowMotionPlayer.hasContent) return
                                // ⭐ 刚发生过拖动平移：不触发切帧
                                if (slowmoMouseArea.panMoved) { slowmoMouseArea.panMoved = false; return }
                                // ⭐ 左键=上一帧，右键=下一帧
                                if (mouse.button === Qt.LeftButton) {
                                    slowMotionPlayer.prevFrame()
                                } else if (mouse.button === Qt.RightButton) {
                                    slowMotionPlayer.nextFrame()
                                }
                            }
                            
                            onWheel: function(wheel) {
                                wheel.accepted = true  // 阻止事件传播
                                if (!slowMotionPlayer.hasContent) return

                                // ⭐ S+滚轮: 慢放独立局部放大 (鼠标位置为中心)
                                //   - 跟实时流 videoZoom 解耦 — 实时流不会跟着缩放
                                //   - ⭐ 2026-08-14：PC 端已改单版本，去掉等级门槛
                                if (mainPage.sKeyPressed) {
                                    var oldZoom = mainPage.slowmoZoom
                                    var delta = wheel.angleDelta.y > 0 ? 0.2 : -0.2
                                    var newZoom = Math.max(1.0, Math.min(5.0, oldZoom + delta))
                                    if (newZoom === oldZoom) return

                                    // 鼠标相对容器中心
                                    var containerCenterX = slowmoVideoContainer.width / 2
                                    var containerCenterY = slowmoVideoContainer.height / 2
                                    var mouseRelX = wheel.x - containerCenterX
                                    var mouseRelY = wheel.y - containerCenterY
                                    var zoomRatio = newZoom / oldZoom

                                    var newOffsetX = mouseRelX - (mouseRelX - mainPage.slowmoOffsetX) * zoomRatio
                                    var newOffsetY = mouseRelY - (mouseRelY - mainPage.slowmoOffsetY) * zoomRatio

                                    // 边界约束: ±(containerSize × (zoom-1) / 2)
                                    var maxOffsetX = slowmoVideoContainer.width  * (newZoom - 1) / 2
                                    var maxOffsetY = slowmoVideoContainer.height * (newZoom - 1) / 2
                                    mainPage.slowmoOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, newOffsetX))
                                    mainPage.slowmoOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, newOffsetY))
                                    mainPage.slowmoZoom = newZoom

                                    if (newZoom === 1.0) {
                                        mainPage.slowmoOffsetX = 0
                                        mainPage.slowmoOffsetY = 0
                                    }
                                    console.log("🔍 慢放局部缩放:", oldZoom.toFixed(1), "->", newZoom.toFixed(1))
                                    return
                                }

                                // 普通滚轮: 切换帧 (会自动暂停跟随实时流)
                                if (wheel.angleDelta.y > 0) {
                                    slowMotionPlayer.prevFrame()
                                } else {
                                    slowMotionPlayer.nextFrame()
                                }
                            }
                        }
                    }

                    // 暂无图片（居中显示，2026-08-14 去掉图标只留文字；2026-08-15 字体放大 3 倍并加粗）
                    Text {
                        anchors.centerIn: parent
                        visible: !slowMotionPlayer.hasContent
                        text: "暂无图片"
                        font.family: "PingFang HK"
                        font.pixelSize: 42
                        font.bold: true
                        color: "#90A4AE"
                    }
                    
            // 状态覆盖层（右上角，录制时显示）
            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 8
                width: stateText.width + 16
                height: stateText.height + 8
                color: "#E53935"
                radius: 4
                visible: false  // 隐藏"录制中"文字

                Text {
                    id: stateText
                    anchors.centerIn: parent
                    text: "● 录制中"
                    color: "#ffffff"
                    font.pixelSize: 12
                    font.bold: true
                }
            }

            // 慢放进度条（贴在慢放view底部，跟随窗口切换）
            Rectangle {
                id: slowmoProgressBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 44
                color: "#80000000"
                visible: slowMotionPlayer.hasContent

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 12

                    // ⭐ 2026-08-15 需求：播放按钮和帧数计数位置对调（播放在左、计数在右）
                    // 播放/暂停按钮
                    Item {
                        width: 72
                        height: 32

                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 2
                            radius: 6
                            color: "#30000000"
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            height: 30
                            radius: 6
                            color: playBtnArea.containsMouse ? "#3A3A3A" : "#292929"

                            Text {
                                anchors.centerIn: parent
                                text: slowMotionPlayer.isPlaying ? "暂停(Q)" : "播放(Q)"
                                font.family: "PingFang HK"
                                font.weight: Font.Medium
                                font.pixelSize: 13
                                color: slowMotionPlayer.hasContent ? "#FAFAFA" : "#8E8E93"
                            }

                            MouseArea {
                                id: playBtnArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: slowMotionPlayer.togglePlay()
                            }
                        }
                    }

                    // 进度条
                    Item {
                        id: frameSliderContainer
                        Layout.fillWidth: true
                        height: 16

                        MouseArea {
                            anchors.fill: parent
                            onWheel: function(wheel) {
                                wheel.accepted = true
                                if (!slowMotionPlayer.hasContent) return
                                if (wheel.angleDelta.y > 0) slowMotionPlayer.prevFrame()
                                else slowMotionPlayer.nextFrame()
                            }
                            onClicked: function(mouse) {
                                if (slowMotionPlayer.recordedFrames > 1) {
                                    var ratio = mouse.x / frameSliderContainer.width
                                    var frame = Math.round(ratio * (slowMotionPlayer.recordedFrames - 1))
                                    slowMotionPlayer.jumpToFrame(frame)
                                }
                            }
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width
                            height: 4
                            radius: 999
                            color: "#C8E6C9"
                        }

                        Rectangle {
                            id: frameHandle
                            width: 16
                            height: 16
                            radius: 8
                            color: "#A5D6A7"
                            x: slowMotionPlayer.recordedFrames > 1 ?
                               slowMotionPlayer.currentFrame / (slowMotionPlayer.recordedFrames - 1) * (parent.width - 16) : 0
                            anchors.verticalCenter: parent.verticalCenter

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -4
                                drag.target: parent
                                drag.axis: Drag.XAxis
                                drag.minimumX: 0
                                drag.maximumX: frameSliderContainer.width - 16

                                onWheel: function(wheel) {
                                    wheel.accepted = true
                                    if (!slowMotionPlayer.hasContent) return
                                    if (wheel.angleDelta.y > 0) slowMotionPlayer.prevFrame()
                                    else slowMotionPlayer.nextFrame()
                                }

                                onPositionChanged: {
                                    if (drag.active && slowMotionPlayer.recordedFrames > 1) {
                                        var ratio = frameHandle.x / (frameSliderContainer.width - 16)
                                        var frame = Math.round(ratio * (slowMotionPlayer.recordedFrames - 1))
                                        slowMotionPlayer.jumpToFrame(frame)
                                    }
                                }
                            }
                        }
                    }

                    // 帧数显示: 当前播放帧/已录制帧数（对调后放到右侧）
                    Text {
                        text: (slowMotionPlayer.currentFrame + 1) + "/" + slowMotionPlayer.recordedFrames
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                        Layout.minimumWidth: 70
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
        }
    }
    
    // ============ 第三部分控制面板（放在右侧底部）============
    Item {
        id: controlPanelContainer
        // 放在右侧底部容器中
        parent: rightBottomHolder
        anchors.fill: parent
        
        // 阴影
        Rectangle {
            anchors.fill: controlPanel
            anchors.topMargin: 1
            anchors.leftMargin: 0
            anchors.rightMargin: 0
            anchors.bottomMargin: -1
            radius: 4
            color: "#1A000000"
        }
        
        Rectangle {
            id: controlPanel
            anchors.fill: parent
            color: mainPage.panelBgColor  // 面板背景色（滑块可调）
            radius: 4
        }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 0

                    // 慢放播放控制（已移到慢放view底部 slowmoProgressBar，这里留空占位）
                    Item { Layout.fillHeight: true }

                    // 四个按钮
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        // 开启慢放按钮
                        Item {
                            Layout.fillWidth: true
                            height: 36
                            
                            Rectangle {
                                anchors.fill: parent
                                anchors.topMargin: 2
                                radius: 6
                                color: "#30000000"
                            }
                            
                            Rectangle {
                                id: slowmoBtn
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: 34
                                radius: 6
                                color: slowmoBtnArea.containsMouse ? "#3A3A3A" : 
                                       (slowMotionPlayer.isRecording ? "#E57373" : "#292929")
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: slowMotionPlayer.isRecording ? "停止(W)" : "慢放(W)"
                                    font.family: "PingFang HK"
                                    font.weight: Font.Medium
                                    font.pixelSize: 14
                                    color: "#FAFAFA"
                                }
                                
                                MouseArea {
                                    id: slowmoBtnArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (slowMotionPlayer.isRecording) {
                                            slowMotionPlayer.stopRecording()
                                        } else {
                                            slowMotionPlayer.startRecording()
                                            captureManager.slowMotionActive = true  // 开启慢放抓拍模式
                                        }
                                    }
                                }
                            }
                        }

                        // 慢放倍数下拉列表
                        Item {
                            Layout.preferredWidth: 60
                            height: 36
                            
                            Rectangle {
                                anchors.fill: parent
                                anchors.topMargin: 2
                                radius: 6
                                color: "#30000000"
                            }
                            
                            Rectangle {
                                id: multiplierDropdown
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: 34
                                radius: 6
                                color: multiplierArea.containsMouse ? "#3A3A3A" : "#292929"
                                border.color: "#3A3A3A"
                                border.width: 1
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: slowMotionPlayer.playbackMultiplier + "x"
                                    font.family: "PingFang HK"
                                    font.weight: Font.Medium
                                    font.pixelSize: 14
                                    color: "#FAFAFA"
                                }
                                
                                MouseArea {
                                    id: multiplierArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: multiplierPopup.open()
                                    onWheel: function(wheel) {
                                        var current = slowMotionPlayer.playbackMultiplier
                                        if (wheel.angleDelta.y > 0) {
                                            // 向上滚，减小倍数（步长0.1）
                                            current = Math.max(1, Math.round((current - 0.1) * 10) / 10)
                                        } else {
                                            // 向下滚，增大倍数（步长0.1）
                                            current = Math.min(10, Math.round((current + 0.1) * 10) / 10)
                                        }
                                        slowMotionPlayer.playbackMultiplier = current
                                    }
                                }
                                
                                // 下拉弹出菜单
                                // ⭐ 2026-08-15 修「倍数下拉往上盖住按钮」：按钮贴窗口底边，
                                //   原 y: parent.height+4 想往下弹但放不下，被 Popup 钳回窗口内
                                //   整个压在按钮上。改为明确锚定在按钮正上方，向上展开且不遮按钮。
                                Popup {
                                    id: multiplierPopup
                                    y: -height - 4
                                    width: parent.width
                                    height: Math.min(200, multiplierListView.contentHeight + 8)
                                    padding: 4
                                    
                                    background: Rectangle {
                                        color: "#F0FFF0"
                                        border.color: "#A5D6A7"
                                        border.width: 1
                                        radius: 6
                                    }
                                    
                                    ListView {
                                        id: multiplierListView
                                        anchors.fill: parent
                                        clip: true
                                        model: [1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 3, 3.5, 4, 4.5, 5, 6, 7, 8, 9, 10]
                                        
                                        delegate: Rectangle {
                                            width: multiplierListView.width
                                            height: 28
                                            color: multiplierItemArea.containsMouse ? "#C8E6C9" : 
                                                   (slowMotionPlayer.playbackMultiplier === modelData ? "#B2DFDB" : "transparent")
                                            radius: 4
                                            
                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData + "x"
                                                font.family: "PingFang HK"
                                                font.pixelSize: 13
                                                color: slowMotionPlayer.playbackMultiplier === modelData ? "#00796B" : "#37474F"
                                                font.weight: slowMotionPlayer.playbackMultiplier === modelData ? Font.Medium : Font.Normal
                                            }
                                            
                                            MouseArea {
                                                id: multiplierItemArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    slowMotionPlayer.playbackMultiplier = modelData
                                                    multiplierPopup.close()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 抓拍按钮（已隐藏，使用空格键触发）
                        Item {
                            visible: false
                            Layout.fillWidth: true
                            height: 36
                            
                            Rectangle {
                                anchors.fill: parent
                                anchors.topMargin: 2
                                radius: 6
                                color: "#30000000"
                            }
                            
                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: 34
                                radius: 6
                                color: captureBtnArea.containsMouse ? "#A5D6A7" : "#B2DFDB"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "抓拍(Space)"
                                    font.family: "PingFang HK"
                                    font.weight: Font.Medium
                                    font.pixelSize: 14
                                    color: "#37474F"
                                }
                                
                                MouseArea {
                                    id: captureBtnArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: EventBus.triggerCapture()
                                }
                            }
                        }

                        // 慢放清空按钮
                        Item {
                            Layout.fillWidth: true
                            height: 36
                            
                            Rectangle {
                                anchors.fill: parent
                                anchors.topMargin: 2
                                radius: 6
                                color: "#30000000"
                            }
                            
                            Rectangle {
                                id: slowmoClearBtn
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: 34
                                radius: 6
                                color: slowmoClearBtnArea.containsMouse ? "#3A3A3A" : "#292929"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "慢放清空(E)"
                                    font.family: "PingFang HK"
                                    font.weight: Font.Medium
                                    font.pixelSize: 14
                                    color: "#FAFAFA"
                                }
                                
                                MouseArea {
                                    id: slowmoClearBtnArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        slowMotionPlayer.clear()
                                        captureManager.slowMotionActive = false  // 关闭慢放抓拍模式
                                    }
                                }
                            }
                        }

                        // 抓拍清空按钮
                        Item {
                            Layout.fillWidth: true
                            height: 36
                            
                            Rectangle {
                                anchors.fill: parent
                                anchors.topMargin: 2
                                radius: 6
                                color: "#30000000"
                            }
                            
                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: 34
                                radius: 6
                                color: captureClearBtnArea.containsMouse ? "#3A3A3A" : "#292929"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "抓拍清空(C)"
                                    font.family: "PingFang HK"
                                    font.weight: Font.Medium
                                    font.pixelSize: 14
                                    color: "#FAFAFA"
                                }
                                
                                MouseArea {
                                    id: captureClearBtnArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: EventBus.triggerClear()
                                }
                            }
                        }
                    }
                    
                    Item { Layout.fillHeight: true }

                    // ⭐ 2026-08-14：行/列/预抓拍张数/后抓拍张数 4 个控件已挪到顶部菜单栏（对齐 java gstream）
                }
        }

    // 底部状态栏已移除，中间内容区域扩展到底部
    // 保留隐藏的状态文本元素以保持代码引用有效
    Text { id: statusText; visible: false }
    Text { id: deviceStatusText; visible: false }

    // ============ 快捷键 ============
    Shortcut { 
        sequence: "Space"
        context: Qt.ApplicationShortcut
        onActivated: {
            // 如果清空确认对话框打开，空格键触发确认
            if (clearCaptureConfirmDialog.visible) {
                console.log("空格键确认清空")
                clearCaptureConfirmDialog.close()
                captureManager.clearAll()
            } else {
                // ⭐ 2026-07-19：按住空格=键盘自动重复(~30次/s)连拍，节流到 ~7次/s——
                //   在源头拦掉，onCaptureTriggered 里的缩放保存/日志也不用每次重复跑；
                //   C++ capture() 内另有 120ms 兜底节流（覆盖左键点击等其它触发路径）。
                var nowMs = Date.now()
                if (nowMs - mainPage._lastSpaceCaptureMs < 150) return
                mainPage._lastSpaceCaptureMs = nowMs
                console.log("空格键抓拍")
                EventBus.triggerCapture()
            }
        }
    }
    
    // W键：开启/停止慢放
    Shortcut { 
        sequence: "W"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (slowMotionPlayer.isRecording) {
                slowMotionPlayer.stopRecording()
            } else {
                slowMotionPlayer.startRecording()
                captureManager.slowMotionActive = true  // 开启慢放抓拍模式
            }
        }
    }
    
    // Q键：慢放播放/暂停
    Shortcut {
        sequence: "Q"
        context: Qt.ApplicationShortcut
        onActivated: slowMotionPlayer.togglePlay()
    }
    
    // E键：慢放清空
    Shortcut { 
        sequence: "E"
        context: Qt.ApplicationShortcut
        onActivated: {
            slowMotionPlayer.clear()
            captureManager.slowMotionActive = false  // 关闭慢放抓拍模式
        }
    }
    
    // C键：抓拍清空
    Shortcut { 
        sequence: "C"
        context: Qt.ApplicationShortcut
        onActivated: EventBus.triggerClear()
    }
    
    // D键：删除最后一个抓拍item
    Shortcut {
        sequence: "D"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (captureManager.count > 0) {
                captureManager.removeItem(captureManager.count - 1)
            }
        }
    }
    
    // F1键：行数增加
    Shortcut {
        sequence: "F1"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (captureManager.gridRows < 10) {
                captureManager.gridRows = captureManager.gridRows + 1
                console.log("F1: 行数增加到", captureManager.gridRows)
            }
        }
    }
    
    // F2键：行数减少
    Shortcut {
        sequence: "F2"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (captureManager.gridRows > 1) {
                captureManager.gridRows = captureManager.gridRows - 1
                console.log("F2: 行数减少到", captureManager.gridRows)
            }
        }
    }
    
    // F3键：列数增加
    Shortcut {
        sequence: "F3"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (captureManager.gridCols < 10) {
                captureManager.gridCols = captureManager.gridCols + 1
                console.log("F3: 列数增加到", captureManager.gridCols)
            }
        }
    }
    
    // F4键：列数减少
    Shortcut {
        sequence: "F4"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (captureManager.gridCols > 1) {
                captureManager.gridCols = captureManager.gridCols - 1
                console.log("F4: 列数减少到", captureManager.gridCols)
            }
        }
    }

    // ⭐ F5/F6/F7/F8: 设置上下帧跳跃步长 (1/2/3/4 帧)
    //   2026-08-14 需求：老 java gstream 没有该功能 → 不显示、不触发（enabled:false，代码保留）
    Shortcut { sequence: "F5"; context: Qt.ApplicationShortcut; enabled: false; onActivated: { mainPage.frameStep = 1; console.log("F5: frameStep=1") } }
    Shortcut { sequence: "F6"; context: Qt.ApplicationShortcut; enabled: false; onActivated: { mainPage.frameStep = 2; console.log("F6: frameStep=2") } }
    Shortcut { sequence: "F7"; context: Qt.ApplicationShortcut; enabled: false; onActivated: { mainPage.frameStep = 3; console.log("F7: frameStep=3") } }
    Shortcut { sequence: "F8"; context: Qt.ApplicationShortcut; enabled: false; onActivated: { mainPage.frameStep = 4; console.log("F8: frameStep=4") } }

    // 数字键1-9, 0：列预览（显示对应列的所有截图，0代表第10列）
    //   2026-08-14 需求：老 java gstream 没有列预览 → 不触发（enabled:false，代码保留）
    Shortcut { sequence: "1"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(1) }
    Shortcut { sequence: "2"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(2) }
    Shortcut { sequence: "3"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(3) }
    Shortcut { sequence: "4"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(4) }
    Shortcut { sequence: "5"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(5) }
    Shortcut { sequence: "6"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(6) }
    Shortcut { sequence: "7"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(7) }
    Shortcut { sequence: "8"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(8) }
    Shortcut { sequence: "9"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(9) }
    Shortcut { sequence: "0"; context: Qt.ApplicationShortcut; enabled: false; onActivated: toggleColumnPreview(10) }  // 0键 = 第10列
    
    // Z/X键：列预览时切换上/下列（列预览已随 0-9 一起下线，不触发）
    Shortcut {
        sequence: "Z"; context: Qt.ApplicationShortcut
        enabled: false
        onActivated: { if (columnPreviewVisible) columnPreviewPrevCol() }
    }
    Shortcut {
        sequence: "X"; context: Qt.ApplicationShortcut
        enabled: false
        onActivated: { if (columnPreviewVisible) columnPreviewNextCol() }
    }
    
    // A键：列预览放大 > 全屏查看（谁在最上面服务于谁）
    // ⭐ 层级：列预览放大(z:1002) > 列预览(z:1001) > 全屏查看(z:1000) > 截图grid
    Shortcut {
        sequence: ShortcutStore.fullscreenViewerKey
        context: Qt.ApplicationShortcut
        onActivated: {
            console.log("🔑 A键按下, columnPreviewVisible:", columnPreviewVisible, "zoomIdx:", columnPreviewZoomItemIdx, "fullscreenVisible:", fullscreenViewerVisible)
            // ⭐ 列预览模式：A键服务于列查看器
            if (columnPreviewVisible) {
                if (columnPreviewZoomItemIdx >= 0) {
                    // 已在列预览放大 → 关闭放大
                    closeColumnPreviewZoom()
                } else if (columnPreviewHoveredIndex >= 0 && columnPreviewHoveredIndex < columnPreviewItems.length) {
                    // 打开列预览放大（悬停的元素）
                    openColumnPreviewZoom(columnPreviewHoveredIndex)
                }
                return
            }
            // ⭐ 原有逻辑：全屏查看
            // ⭐ 2026-08-14：PC 端已改单版本，去掉「AI全能版」等级门槛
            if (fullscreenViewerVisible) {
                closeFullscreenViewer()
                console.log("🔑 关闭放大查看")
            } else if (captureManager.currentItemIndex >= 0 && captureManager.currentItemIndex < captureManager.count) {
                fullscreenViewerMode = appSettings.halfScreenViewMode ? 1 : 0
                console.log("🔑 打开抓拍放大查看, itemIndex:", captureManager.currentItemIndex, "模式:", appSettings.halfScreenViewMode ? "半屏" : "全屏")
                openFullscreenViewer(captureManager.currentItemIndex)
            }
        }
    }
    
    // ESC键：关闭（层级：列预览放大 > 列预览 > 全屏查看）
    Shortcut {
        sequence: "Escape"
        context: Qt.ApplicationShortcut
        onActivated: {
            console.log("🔑 ESC键按下")
            if (columnPreviewVisible && columnPreviewZoomItemIdx >= 0) {
                closeColumnPreviewZoom()  // 先关闭A键放大
            } else if (columnPreviewVisible) {
                closeColumnPreview()
            } else if (fullscreenViewerVisible) {
                closeFullscreenViewer()
            }
        }
    }
    
    // 左右键：帧切换（列预览放大 > 列预览 > 全屏查看 > 慢放 > 抓拍item）
    // 左键：上一帧
    Shortcut {
        sequence: "Left"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (columnPreviewVisible && columnPreviewZoomItemIdx >= 0) {
                // A键放大模式：切换放大图的帧
                columnPreviewZoomPrevFrame()
            } else if (columnPreviewVisible) {
                // 列预览模式：所有图片同时上一帧
                columnPreviewPrevFrame()
            } else if (fullscreenViewerVisible) {
                // 全屏查看模式：切换帧 (frameStep)
                var totalFrames = captureManager.getTotalFrames(fullscreenItemIndex)
                console.log("⬅️ 全屏左键: totalFrames=" + totalFrames + " current=" + fullscreenFrameIndex + " step=" + mainPage.frameStep)
                if (totalFrames > 0 && fullscreenFrameIndex > 0) {
                    fullscreenGoToFrame(fullscreenFrameIndex - mainPage.frameStep)
                }
            } else if (slowMotionPlayer.hasContent) {
                slowMotionPlayer.prevFrame()
            } else if (captureManager.currentItemIndex >= 0) {
                stepCaptureFrame(captureManager.currentItemIndex, "prev")
            }
        }
    }
    // 右键：下一帧
    Shortcut {
        sequence: "Right"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (columnPreviewVisible && columnPreviewZoomItemIdx >= 0) {
                // A键放大模式：切换放大图的帧
                columnPreviewZoomNextFrame()
            } else if (columnPreviewVisible) {
                // 列预览模式：所有图片同时下一帧
                columnPreviewNextFrame()
            } else if (fullscreenViewerVisible) {
                var totalFrames = captureManager.getTotalFrames(fullscreenItemIndex)
                console.log("➡️ 全屏右键: totalFrames=" + totalFrames + " current=" + fullscreenFrameIndex + " step=" + mainPage.frameStep)
                if (totalFrames > 0 && fullscreenFrameIndex < totalFrames - 1) {
                    fullscreenGoToFrame(fullscreenFrameIndex + mainPage.frameStep)
                }
            } else if (slowMotionPlayer.hasContent) {
                slowMotionPlayer.nextFrame()
            } else if (captureManager.currentItemIndex >= 0) {
                stepCaptureFrame(captureManager.currentItemIndex, "next")
            }
        }
    }
    
    // ⭐ P键弹框已禁用：不再弹出 iOS 滤镜弹框（快捷键整体关闭，enabled: false）
    Shortcut {
        sequence: "P"
        context: Qt.ApplicationShortcut
        enabled: false
        onActivated: {
            if (iosFilterPopup.visible) {
                iosFilterPopup.close()
            } else {
                iosFilterPopup.open()
            }
        }
    }
    
    // R键：打开/关闭相机设定弹窗（切换功能；OTG 外接时禁用，改用 O 键外接设定）
    Shortcut {
        sequence: "R"
        context: Qt.ApplicationShortcut
        enabled: !CameraCapsStore.isOtg
        onActivated: {
            if (iosCameraSettingsPopup.visible) {
                iosCameraSettingsPopup.close()
            } else {
                showIosCameraSettings()
            }
        }
    }

    // ⭐ 第五十章 O键：打开/关闭「外接摄像头设定」（OTG 专用面板）
    //   2026-08-14 需求：单版本无 OTG、老 java gstream 没有 → 不触发（代码保留）
    Shortcut {
        sequence: "O"
        context: Qt.ApplicationShortcut
        enabled: false
        onActivated: toggleOtgCameraPanel()
    }

    // OTG 切入时关掉自带「相机设定」，避免菜单隐藏后弹窗仍挂着
    Connections {
        target: CameraCapsStore
        function onIsOtgChanged() {
            if (CameraCapsStore.isOtg) {
                if (iosCameraSettingsPopup.visible)
                    iosCameraSettingsPopup.close()
            }
        }
    }
    // ⭐ §56.29b：主版不看「外接 OTG」设备——在信令阶段（CONFIG_STATE.cameraMode）就拦截，
    //   压根不发起视频连接（见 CONFIG_STATE 推流状态处理的 isOtg 分支），画面区只显示「不支持」
    //   （unsupportedOtgOverlay）。原下载引导弹框已移除（用户拍板：只提示「不支持」三个字）。

    // L键：打开/关闭 iOS 采集颜色调节（冷暖/绿紫/RGB/黑/白 → 硬件白平衡）
    //   2026-08-14 需求：老 java gstream 没有 → 不触发（enabled:false，代码保留）
    Shortcut {
        sequence: "L"
        context: Qt.ApplicationShortcut
        enabled: false
        onActivated: {
            if (iosCaptureAdjustPopup.visible) {
                iosCaptureAdjustPopup.close()
            } else {
                iosCaptureAdjustPopup.open()
            }
        }
    }

    // ============ 函数 ============

    // ⭐ 网页内核辅助（2026-06-24）：内核模式下按连接模式驱动 webview 播放。
    // ⭐ 截图/慢放帧源切换：网页内核模式注入 webFrameSource（JPEG），否则 gstPlayer（H264）。
    //   CaptureManager/SlowMotionPlayer 只认 IFrameSource，UI 完全复用、只换数据源。
    function kernelBindFrameSource() {
        if (typeof webFrameSource === 'undefined' || !webFrameSource) return
        captureManager.setFrameSourceObject(webFrameSource)
        slowMotionPlayer.setFrameSourceObject(webFrameSource)
        console.log("📷 [网页内核] 截图/慢放数据源 → WebFrameSource(JPEG)")
    }
    function gstBindFrameSource() {
        captureManager.setFrameSourceObject(gstPlayer)
        slowMotionPlayer.setFrameSourceObject(gstPlayer)
        console.log("📷 [GStreamer] 截图/慢放数据源 → GstPlayer(H264)")
    }

    function kernelStartByMode() {
        if (!useWebEngineKernel) return
        var view = kernelPlayerLoader.item
        if (!view) return
        // ⭐ 2026-07-24：SRS/SRT 启动前必须有流参数。Loader 的 onLoaded 可能早于 CONFIG_STATE
        //   到达（currentStream 还是空），空参启动只会让页面报「SRS 参数缺失 host/stream」，
        //   还会把下面的去抖时间戳占住——436ms 后真正带参数的 playWebRTC 反被去抖忽略 → 黑屏。
        //   参数没就绪就直接返回（不占去抖），等 CONFIG_STATE 触发的 playWebRTC 再启动。
        if (connectMode !== 1 && (!currentStream || currentStream.length === 0 || !srsServer || srsServer.length === 0)) {
            console.log("🌐 [网页内核] kernelStartByMode: 流参数未就绪(stream=" + currentStream + " srs=" + srsServer + ")，等 CONFIG_STATE 再启动")
            return
        }
        // ⭐ §25.7e-附 去抖：2s 内重复重启直接忽略。双重启（CONFIG_ERROR 善后 + CONFIG_STATE
        //   开始推流）会让第二次 rebuildPC 拆掉第一次刚回完 Answer 的 RTCPeerConnection，
        //   而 iOS 把第二个 REQUEST 当重复忽略 → 会话空等 ICE 15s 超时才自愈。
        var nowMs = Date.now()
        if (nowMs - lastKernelStartMs < 2000) {
            console.log("🌐 [网页内核] kernelStartByMode 去抖：距上次仅" + (nowMs - lastKernelStartMs) + "ms，忽略重复重启")
            return
        }
        lastKernelStartMs = nowMs
        // ⭐ 进内核模式：截图/慢放切到 WebFrameSource，并清掉上次会话残帧。
        if (typeof webFrameSource !== 'undefined' && webFrameSource && kernelBridge) {
            kernelBridge.resetCaptureFrames()
        }
        kernelBindFrameSource()
        if (connectMode === 1) {
            // P2P：参数从 kernelBridge 拿
            view.startTest("p2p", "", "", "", "")
        } else {
            // ⭐ SRS 与 SRT 都走 WHEP：SRT 由 SRS 桥接成 WebRTC（方案A），网页内核天然适配。
            //   （connectMode===2 不再显示「不支持 SRT」提示。）
            //   ⭐ H265：把 codec 传给页面，startSRS 据此在 play API 上加 ?codec=hevc（第四十九章）。
            view.startTest("srs", srsServer, "tenantA", currentStream, "vid-7gg4748", videoCodec)
        }
    }

    function kernelStop() {
        if (!useWebEngineKernel) return
        var view = kernelPlayerLoader.item
        if (view) view.stopTest()
        // ⭐ §25.7e-附：显式停止后清去抖时间戳——合法的「停→立刻重启」（模式切换等）不受 2s 去抖限制，
        //   去抖只拦「未经 stop 的连续二次重启」（那才是拆自己会话的竞态源）。
        lastKernelStartMs = 0
        // ⭐ 立即清零内核帧率，拉流心跳随之停发（不依赖 webview 卸载前是否上报到 0）。
        kernelViewerFps = 0
        // ⭐ 退内核模式：截图/慢放数据源恢复 GStreamer，并清掉 webframes 残帧。
        if (kernelBridge) kernelBridge.resetCaptureFrames()
        gstBindFrameSource()
    }

    // ⭐ 把本地缩放/镜像/旋转/偏移同步到 webview（CSS transform），与 GStreamer 端 QML 变换对齐。
    function kernelSyncTransform() {
        if (!useWebEngineKernel) return
        var view = kernelPlayerLoader.item
        if (view) view.applyTransform(videoZoom, videoMirrorMode, videoRotation, videoOffsetX, videoOffsetY)
    }

    // ============ 滤镜路由（iOS=设备端 STOMP / Android=PC 本地）============
    // 背景：Android 不支持设备端滤镜（或参数无效）。快门(cjfps)、ISO 增益(gain) 属相机采集参数，
    //   必须留在设备端；其余颜色类滤镜（亮度/对比度/饱和度/gamma 等）改由 PC 本地落地——
    //   GStreamer 走 videobalance/gamma（管线线程处理），网页内核走 CSS filter（Chromium 合成器），
    //   两者都不占 Qt 主线程，规避「主线程逐帧处理卡死」的坑。iOS 一律不走本地、行为不变。

    // 颜色类滤镜 ptype（Android 下改走本地；快门 cjfps / 增益 gain 不在此列，仍下发设备）
    function isLocalColorPtype(ptype) {
        return ptype === "brightness" || ptype === "contrast" || ptype === "saturation"
            || ptype === "gamma" || ptype === "exposure" || ptype === "redBoost"
            || ptype === "blackPoint" || ptype === "sharpness" || ptype === "highlightLift"
            || ptype === "chroma"
    }

    // 把 iOS 滤镜弹框当前的 f* 值映射到「PC 本地能实现的子集」并落到当前活动 sink。
    //   本地只做亮度/对比度/饱和度(/gamma)，其余 iOS 专有项(redBoost/黑点/锐化/高光/色度)在 PC 无等价能力→忽略。
    function applyLocalColorFilter() {
        var p = iosFilterPopup
        // 滤镜关 → 本地复位中性
        if (!p.fEnabled) {
            clearLocalColorFilter()
            return
        }
        // GStreamer videobalance 语义：brightness[-1,1](0中性)、contrast[0,2](1)、saturation[0,2](1)、gamma[0.01,10](1)
        var b = Math.max(-1.0, Math.min(1.0, p.fBrightness + (p.fExposure - 1.0) * 0.5))  // 曝光折进亮度
        var c = Math.max(0.0, Math.min(2.0, p.fContrast))
        var s = Math.max(0.0, Math.min(2.0, p.fSaturation))
        var g = Math.max(0.01, Math.min(10.0, p.fGamma))
        if (useWebEngineKernel) {
            // CSS filter 乘数：brightness 由 videobalance 加性[-1,1] 折算成乘数 1+b；对比/饱和直接用乘数
            var view = kernelPlayerLoader.item
            if (view && view.applyColorFilter) view.applyColorFilter(1.0 + b, c, s)
        } else {
            gstPlayer.applyColorFilter(b, c, s, g)
        }
    }

    // 本地滤镜复位中性（滤镜关 / 切到 iOS 设备时，避免上一次 Android 的 videobalance/CSS 残留）
    function clearLocalColorFilter() {
        if (useWebEngineKernel) {
            var view = kernelPlayerLoader.item
            if (view && view.applyColorFilter) view.applyColorFilter(1.0, 1.0, 1.0)
        } else {
            gstPlayer.clearColorFilter()
        }
    }

    // 登录/切设备/切内核后刷新滤镜落点：Android→本地落地当前值；iOS→PC 本地保持中性（滤镜在设备端做）
    function refreshFilterRouting() {
        if (HttpClient.currentIsAndroid()) applyLocalColorFilter()
        else clearLocalColorFilter()
    }

    // ⭐ 滚轮聚焦缩放（GStreamer 与网页内核共用同一套数学）。
    //   up=true 放大、false 缩小；mouseX/Y 为相对 videoContainer 的像素坐标。
    //   videoZoom/offset 变化后会自动触发 onVideoZoomChanged→kernelSyncTransform（内核模式回写 webview）。
    function applyWheelZoom(up, mouseX, mouseY) {
        var oldZoom = mainPage.videoZoom
        var delta = up ? 0.2 : -0.2
        var newZoom = Math.max(1.0, Math.min(5.0, oldZoom + delta))
        if (newZoom === oldZoom) return

        var containerCenterX = videoContainer.width / 2
        var containerCenterY = videoContainer.height / 2
        var mouseRelX = mouseX - containerCenterX
        var mouseRelY = mouseY - containerCenterY
        var zoomRatio = newZoom / oldZoom
        var newOffsetX = mouseRelX - (mouseRelX - mainPage.videoOffsetX) * zoomRatio
        var newOffsetY = mouseRelY - (mouseRelY - mainPage.videoOffsetY) * zoomRatio
        var maxOffsetX = videoContainer.width * (newZoom - 1) / 2
        var maxOffsetY = videoContainer.height * (newZoom - 1) / 2
        mainPage.videoOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, newOffsetX))
        mainPage.videoOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, newOffsetY))
        mainPage.videoZoom = newZoom
        if (newZoom === 1.0) { mainPage.videoOffsetX = 0; mainPage.videoOffsetY = 0 }
        sendLocalViewUpdate(mainPage.videoZoom, mainPage.videoOffsetX, mainPage.videoOffsetY)
    }

    function playWebRTC() {
        lastPlayAttemptMs = Date.now()   // §54 自愈对账：记录本次发起时刻（退避基准）
        videoSurfaceDirty = true   // 起播即标脏，断线时据此保证一定清屏
        // ⭐ 网页内核模式：不走 GStreamer，改驱动 webview
        if (useWebEngineKernel) {
            console.log("🌐 [网页内核] playWebRTC → kernelStartByMode")
            isConnecting = true
            kernelStartByMode()
            return
        }
        // 检查 streamKey 是否有效
        if (!currentStream || currentStream.length === 0) {
            console.log("⚠️ playWebRTC: currentStream 为空，跳过")
            return
        }
        
        // 🔥 v14: 设置连接中标志，防止 stopAll 期间的断开回调重置 publishState 导致死循环
        isConnecting = true
        
        stopAll()
        console.log("🎬 playWebRTC: currentStream=" + currentStream + " srsServer=" + srsServer)
        statusText.text = "正在连接 WebRTC..."
        
        console.log("🎬 playWebRTC: 重置 GstPlayer 状态...")
        gstPlayer.reset()
        
        // ⭐ H265（第四十九章）：SRS/SRT 也按上报 codec 建解码管线（必须在 connectWebRTC 之前设，
        //   否则 connectWebRTC 里 add-transceiver 已按旧 m_useH265 建好）。H264 会话等同旧行为。
        gstPlayer.setVideoCodec(mainPage.videoCodec)
        
        console.log("🎬 playWebRTC: 连接 WebRTC(codec=" + mainPage.videoCodec + ")...")
        webrtcClient.connect(srsServer, "tenantA", currentStream)
    }
    
    // P2P 直连模式拉流（不经过 SRS）
    function playP2P() {
        lastPlayAttemptMs = Date.now()   // §54 自愈对账：记录本次发起时刻（退避基准）
        if (!pairedIosDeviceId || pairedIosDeviceId.length === 0) {
            console.log("❌ playP2P: pairedIosDeviceId 为空，无法建立 P2P 连接")
            statusText.text = "等待 iOS 设备连接..."
            return
        }
        videoSurfaceDirty = true   // 起播即标脏，断线时据此保证一定清屏

        // ⭐ 网页内核模式：P2P 走 webview（QWebChannel kernelBridge 信令）
        if (useWebEngineKernel) {
            console.log("🌐 [网页内核] playP2P → kernelStartByMode")
            isConnecting = true
            kernelStartByMode()
            return
        }
        
        isConnecting = true
        stopAll()
        
        var iceArray = iceServers.length > 0 ? iceServers : HttpClient.iceServers()
        console.log("🌐 playP2P: 配对设备=" + pairedIosDeviceId + " iceServers=" + iceArray.length + "个 编码=" + mainPage.videoCodec)
        statusText.text = "正在建立 P2P 直连..."
        
        // ⭐ H265：按 CONFIG_STATE.videoCodec 预建对应解码管线（必须在 connectP2P 之前设置）
        gstPlayer.setVideoCodec(mainPage.videoCodec)
        
        gstPlayer.reset()
        
        console.log("🌐 playP2P: 启动 P2P 连接...")
        gstPlayer.connectP2P(pairedIosDeviceId, iceArray)
    }

    // MARK: SRT (independent)
    // ⭐ 2026-06-24：SRT 改走方案A（iOS SRT→SRS 桥接成 WebRTC，PC 仍 WHEP 拉）。
    //   原方案B（PC srtsrc 直拉）延迟~3s/碎花/画质差，已弃用。playSRT 现直接转 playWebRTC，
    //   PC 端 SRT 与 SRS 完全等同；iOS 端不用改（照旧推 SRT 到 SRS）；网页内核也天然适配。
    //   保留此函数仅为兼容残留调用点；GStreamer 的 connectSRT/warmupSRT/gstsrtsource 已不再使用。
    function playSRT() {
        console.log("🎬 playSRT → 方案A：改走 SRS/WHEP（SRT 由 SRS 桥接成 WebRTC）")
        playWebRTC()
    }

    function stopAll() {
        console.log("🛑 stopAll: 停止所有流...")

        // ⭐ P2P诊断日志上报：停流即冲刷+停止（若推流仍在，下一条 CONFIG_STATE 会重新激活）
        P2PLogUploader.deactivate()

        // ⭐ 网页内核模式：停 webview 播放即可，不碰 GStreamer（此时 GStreamer 未启动）
        if (useWebEngineKernel) {
            kernelStop()
            console.log("🛑 [网页内核] stopAll: 已停 webview")
            return
        }

        if (gstPlayer.isSRTMode()) {            // MARK: SRT (independent)
            gstPlayer.disconnectSRT()
        } else if (gstPlayer.isP2PMode()) {
            gstPlayer.disconnectP2P()
        } else {
            webrtcClient.disconnect()
        }
        gstPlayer.stop()
        slowMotionPlayer.clear()
        captureManager.slowMotionActive = false
        console.log("🛑 stopAll: 完成")
    }
    
    // ⭐ 第五十章：kernelViewerFps 最近一次上报的时刻。
    //   webview 卡死/崩掉时不会再上报，kernelViewerFps 会**停在最后一个非零值**上；
    //   断线判定若直接信它，就会把真断线当成"画面还在放"而忽略掉 → 顶部断线、画面残留。
    property real lastKernelFpsMs: 0

    // ⭐ 第五十章：画面是否"脏"（起过播放、还没清过屏）。
    //   不用 publishState 判断有没有画面——它是"设备是否在推流"的状态，
    //   跟"PC 这块屏上还留没留着一帧"是两码事，两者一旦不同步就出现
    //   「顶部已显示断线、画面还在」。这个标志只描述屏幕本身。
    property bool videoSurfaceDirty: false

    // 清屏：两个内核都清一遍（切过内核时另一边可能还留着最后一帧）
    function clearVideoSurface() {
        gstPlayer.stop()          // 内部会清 m_lastValidSample 并给 videoSink 送空帧 → 黑屏
        if (useWebEngineKernel) kernelStop()   // §45：webview 侧 srcObject=null + load() 才真清
        videoSurfaceDirty = false
        console.log("🧹 [清屏] 已清除残留画面")
    }

    // ⭐ 第五十章：设备下线的**唯一收口**。
    //   以前"顶部改文字"和"停流清屏"各写各的分支，停流那步还被 publishState===1 挡着；
    //   只要这个标志与实际播放状态不同步，就会出现「顶部说断线了，画面还留在最后一帧」。
    //   现在任何一处判定下线都必须走这里：两件事一起做，杜绝两套状态打架。
    function markDeviceOffline(reason, topText) {
        console.log("🔌 [设备下线] " + reason + " → 停流+清屏+改状态")
        stopAll()
        clearVideoSurface()
        publishState = 0
        isConnecting = false
        statusText.text = topText
        deviceStatusText.text = "📱 " + topText
        deviceStatusText.color = "#f44336"
        liveInfoFps.text = "FPS: --"
        playRecoverStreak = 0   // §54：设备下线 = 一段会话结束，下段会话退避从头算
        p2pSingleModeOccupied = false   // ⭐ 2026-08-01：设备下线，单人占用作废，回来后重新判定
        resetDeviceReportedStats()
    }

    // ⭐ §53.10：把「心跳派生的读数」复位单独抽出来。
    //   码率/电量/网络质量/网络类型/采集fps 全都只来自 CONFIG_STATE 心跳，
    //   心跳一停这些值就是**过期的错值**，必须归零，而不是把最后一次读数一直挂在顶栏上。
    function resetDeviceReportedStats() {
        mainPage.deviceKbps = 0
        mainPage.deviceBattery = -1
        mainPage.deviceNetworkQuality = ""
        mainPage.deviceNetworkType = ""
        mainPage.deviceCaptureFps = 0
        mainPage.deviceLowPowerCapture = false
    }

    // ⭐ §53.10：切设备 / 切账号 / 退登录 / 被改密踢下线时的统一清场。
    //   与 markDeviceOffline 的区别：这不是"判定对方离线"，而是"我主动不看了"，所以不写离线文案。
    //   ⚠️ `lastConfigStateMs` 必须清零——它记的是**上一台设备**的心跳时刻，留着会让
    //     心跳超时判定拿旧设备的时间戳去判新设备，切过去的头几秒就被误判成"设备已离线"。
    function resetStreamStateForSwitch(reason) {
        console.log("🔄 [清场] " + reason)
        // ⭐ §54.6：主动离开（退出登录/切设备/切账号）才通知设备"这台 PC 不看了"。
        //   必须在 stopAll 之前发——stopAll 后 pairedIosDeviceId 语境即将失效。
        //   内部重连路径（onWebrtcDisconnected）不再发这条，防迟到消息拆掉新会话（详见该处注释）。
        if (pairedIosDeviceId && pairedIosDeviceId.length > 0) {
            WebSocketClient.sendWebRTCSignaling("VIEWER_DISCONNECTED", pairedIosDeviceId)
            console.log("📤 [清场] 通知设备 PC 停止观看: " + pairedIosDeviceId)
        }
        stopAll()
        clearVideoSurface()
        publishState = 0
        isConnecting = false
        currentStream = ""
        lastConfigStateMs = 0
        deviceOnline = false
        pairedIosDisplay = ""   // 切设备/退登录清昵称，新登录时重设，避免残留上一台
        playRecoverStreak = 0   // §54：主动清场 = 会话结束，自愈退避从头算
        lastPlayAttemptMs = 0
        p2pSingleModeOccupied = false   // ⭐ 2026-08-01：切设备/退登录，单人占用作废
        resetDeviceReportedStats()
        liveInfoFps.text = "FPS: --"
    }

    // ⭐ §53.10：当前"真的在出画面"的帧率（0 = 没画面）。
    //   网页内核的 fps 是 webview 主动上报的，卡死/崩掉就不再上报、值会停在最后一个非零数上，
    //   所以必须连"这个读数是不是新的"一起判（§50.D 的教训），否则真断线会被当成"还在放"。
    function currentPlayingFps() {
        if (mainPage.useWebEngineKernel) {
            var fresh = mainPage.lastKernelFpsMs > 0 && (Date.now() - mainPage.lastKernelFpsMs) < 5000
            return fresh ? mainPage.kernelViewerFps : 0
        }
        return gstPlayer.receiveFps
    }

    // ⭐ §54（2026-07-31）拉流「期望状态对账」——**最后防线**，正常情况永远轮不到它。
    //   3 秒级恢复靠信令层常驻循环（gstplayer.cpp：P2P REQUEST 1.5s 常驻重发 / SRS WHEP 2s 常驻
    //   重试 / ICE 重连无上限，三条"有限重试后永久放弃"的终态已全部删除）。
    //   本对账只兜"循环本身卡死"的残余情形（如 iOS 幽灵会话把同 epoch 的 REQUEST 全幂等忽略）：
    //   事实源 = 设备端 1s 一条的 CONFIG_STATE（publishState 是它的镜像）；实际 = currentPlayingFps()。
    //   期望在播、实际黑屏超过退避间隔 → 全量重建会话（换新 epoch → iOS 拆旧建新，
    //   playP2P/playWebRTC 入口复位全部内核状态）。
    //   一次性快速路径（publishState 0→1、mode/codec/streamKey 变化）全部保留，对账只兜异常。
    property double lastPlayAttemptMs: 0   // 最近一次发起拉流的时刻（playP2P/playWebRTC 入口更新）
    property int playRecoverStreak: 0      // 连续自愈重建次数（出画面即清零），驱动退避

    function reconcilePlayback(fps) {
        if (fps > 0) {
            if (playRecoverStreak !== 0) {
                console.log("✅ [自愈对账] 画面已恢复（自愈重建 " + playRecoverStreak + " 次后出画）")
                playRecoverStreak = 0
            }
            return
        }
        if (publishState !== 1) return      // 设备没在推流 → 没有对账目标（等 CONFIG_STATE 0→1 起播）
        if (!deviceOnline) return           // 连心跳都没有 → 交给心跳超时收口，别对着空气重连
        if (deviceStatus !== "") return     // 睡眠/唤醒过渡态不介入
        if (p2pSingleModeOccupied) return   // ⭐ 2026-08-01：被单人模式拒绝，不自动重连（否则反复被拒卡死）
        var now = Date.now()
        if (lastPlayAttemptMs <= 0) { lastPlayAttemptMs = now; return }
        // 退避：首次 8s（信令层常驻循环没在 8s 内连上 = 循环卡死，整会话换 epoch 重建），
        // 之后逐次 +4s，封顶 30s——防重建风暴，同时保证异常也能自动收敛。
        var waitMs = Math.min(8000 + playRecoverStreak * 4000, 30000)
        if (now - lastPlayAttemptMs < waitMs) return
        playRecoverStreak++
        console.log("🔁 [自愈对账] 设备在推流但 " + Math.round((now - lastPlayAttemptMs) / 1000)
                    + "s 无画面 → 第 " + playRecoverStreak + " 次整会话重建（mode="
                    + (connectMode === 1 ? "P2P" : "SRS") + " stream=" + currentStream + "）")
        stopAll()
        if (connectMode === 1) {
            playP2P()
        } else {
            playWebRTC()
        }
    }

    function toggleFullscreen() {
        // 保存当前比例
        var topH = rightTopHolder.height
        var middleH = rightMiddleHolder.height
        var total = topH + middleH
        if (total > 0) {
            savedHeightRatio = topH / total
        }
        
        // 使用 showMaximized 保留任务栏，而不是 showFullScreen
        if (mainWindow.visibility === Window.Maximized) {
            mainWindow.showNormal()
        } else {
            mainWindow.showMaximized()
        }
        
        // 延迟恢复比例
        windowFullscreenRestoreTimer.start()
    }
    
    Timer {
        id: windowFullscreenRestoreTimer
        interval: 50  // 减少延迟，快速恢复
        onTriggered: {
            // ⭐ 设置恢复标志，避免触发自动保存
            isRestoringRatio = true
            
            var topH = rightTopHolder.height
            var middleH = rightMiddleHolder.height
            var total = topH + middleH
            if (total > 0 && savedHeightRatio > 0) {
                rightTopHolder.SplitView.preferredHeight = total * savedHeightRatio
                rightMiddleHolder.SplitView.preferredHeight = total * (1 - savedHeightRatio)
                
                // 延迟清除标志
                Qt.callLater(function() {
                    isRestoringRatio = false
                })
            } else {
                isRestoringRatio = false
            }
        }
    }

    // ============ 对话框 ============
    
    Dialog {
        id: cameraSettingsDialog
        title: "相机设定"
        anchors.centerIn: parent
        width: 450
        modal: true
        standardButtons: Dialog.Ok | Dialog.Reset
        
        onReset: captureManager.resetCameraSettings()
        
        ColumnLayout {
            spacing: 16
            width: parent.width - 40
            
            ColumnLayout {
                spacing: 4
                Layout.fillWidth: true
                
                RowLayout {
                    Text { text: "曝光度"; font.pixelSize: 13; font.bold: true; color: "#37474F" }
                    Item { Layout.fillWidth: true }
                    Text { 
                        text: captureManager.exposure.toFixed(0) + "%"
                        font.pixelSize: 12
                        color: "#607D8B"
                    }
                }
                Slider {
                    id: exposureSlider
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    stepSize: 1
                    value: captureManager.exposure
                    onMoved: captureManager.exposure = value
                }
                Text {
                    text: "综合调节亮度、对比度、饱和度、色调、伽马"
                    font.pixelSize: 10
                    color: "#90A4AE"
                }
            }
            
            Rectangle { height: 1; Layout.fillWidth: true; color: "#C8E6C9" }
            
            ColumnLayout {
                spacing: 4
                Layout.fillWidth: true
                
                RowLayout {
                    Text { text: "亮度"; font.pixelSize: 13; color: "#37474F" }
                    Item { Layout.fillWidth: true }
                    Text { text: captureManager.brightness.toFixed(2); font.pixelSize: 12; color: "#607D8B" }
                }
                Slider {
                    Layout.fillWidth: true
                    from: -1.0; to: 1.0
                    value: captureManager.brightness
                    onMoved: captureManager.brightness = value
                }
            }
            
            ColumnLayout {
                spacing: 4
                Layout.fillWidth: true
                
                RowLayout {
                    Text { text: "对比度"; font.pixelSize: 13; color: "#37474F" }
                    Item { Layout.fillWidth: true }
                    Text { text: captureManager.contrast.toFixed(2); font.pixelSize: 12; color: "#607D8B" }
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0.0; to: 2.0
                    value: captureManager.contrast
                    onMoved: captureManager.contrast = value
                }
            }
            
            ColumnLayout {
                spacing: 4
                Layout.fillWidth: true
                
                RowLayout {
                    Text { text: "饱和度"; font.pixelSize: 13; color: "#37474F" }
                    Item { Layout.fillWidth: true }
                    Text { text: captureManager.saturation.toFixed(2); font.pixelSize: 12; color: "#607D8B" }
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0.0; to: 2.0
                    value: captureManager.saturation
                    onMoved: captureManager.saturation = value
                }
            }
            
            ColumnLayout {
                spacing: 4
                Layout.fillWidth: true
                
                RowLayout {
                    Text { text: "色调"; font.pixelSize: 13; color: "#37474F" }
                    Item { Layout.fillWidth: true }
                    Text { text: captureManager.hue.toFixed(2); font.pixelSize: 12; color: "#607D8B" }
                }
                Slider {
                    Layout.fillWidth: true
                    from: -1.0; to: 1.0
                    value: captureManager.hue
                    onMoved: captureManager.hue = value
                }
            }
            
            ColumnLayout {
                spacing: 4
                Layout.fillWidth: true
                
                RowLayout {
                    Text { text: "伽马"; font.pixelSize: 13; color: "#37474F" }
                    Item { Layout.fillWidth: true }
                    Text { text: captureManager.gamma.toFixed(2); font.pixelSize: 12; color: "#607D8B" }
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0.01; to: 10.0
                    value: captureManager.gamma
                    onMoved: captureManager.gamma = value
                }
            }
        }
        
        Connections {
            target: captureManager
            function onCameraSettingsChanged() {
                exposureSlider.value = captureManager.exposure
            }
        }
    }
    
    // ============ iOS 相机设定 Window（独立窗口，可全屏拖动）============
    Window {
        id: iosCameraSettingsPopup
        width: 560
        height: 800  // ⭐ 2026-08-14：新增「颜色参数精调」区（5 行滑块 + 标题），520 → 800
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "transparent"
        visible: false
        
        // 兼容 Popup 的 open/close 方法
        function open() {
            // 综合亮度不从 captureManager 读取 — 使用 exposureValue 属性的当前值（跨 open/close 持久）
            // 只有重新登录时 onLoginSuccess 才会把它重置为 50
            // brightnessValue / saturationValue 是 legacy 字段，仍从 captureManager 读取（无副作用）
            brightnessValue = captureManager.brightness
            saturationValue = captureManager.saturation

            // ⭐ 显式设置滑块值（因为 onMoved 会打破绑定）
            isoSlider.value = hardwareBrightness

            visible = true
        }
        function close() { visible = false }

        function hardwareEVText() {
            var ev = -2 + (hardwareBrightness / 100) * 10
            return ev.toFixed(1) + "EV"
        }
        
        // 拖动相关属性
        property point dragStart: Qt.point(0, 0)
        property bool dragging: false
        
        // 相机设定参数
        property double focusValue: 0.5
        property int exposureValue: 50        // ⭐ 综合亮度: 0..100, 中点 50
        property int overallContrastValue: 50 // ⭐ 综合亮度-对比度: 0..100, 中点 50
        property int overallExposureValue: 50 // ⭐ 综合亮度-曝光度: 0..100, 中点 50
        property int flickerValue: Math.min(240, getMaxFlickerValue())  // 范围 60-400，直接下发60-400
        property int fpsValue: 30
        property int clarityValue: 50
        property double brightnessValue: 0.0  // (legacy, 现在不再使用; 保留兼容防止编译错)
        property double saturationValue: 1.10 // (legacy, 现在不再使用; 保留兼容)
        property double lensZoom: 1.0
        property string directionValue: "1"  // 摄像头方向：1=后置, 0=前置
        property string selectedButton: ""  // 睡眠/工作/刷新
        property string qualityType: "ultra" // 档位type：low(标清)/ultra(高清)/high(超清)/p4k(4K)；standard 为旧残留
        property bool antiFlickerEnabled: false  // 抗频闪开关（默认关闭）
        property int antiFlickerFps: 80          // 抗频闪帧率档位（80/100/200）
        property bool filterModeEnabled: false   // 滤镜模式（Metal 后处理，默认关 — 对标玉麒麟只开 LUT）
        property bool lutModeEnabled: true       // LUT 模式（玉麒麟 GPUImage，默认开）
        property int hardwareBrightness: 20      // 硬件亮度 0~100 → EV -2..+8，20=0EV
        property int hardwareWhiteBalance: 50   // 白平衡 0~100 → 2000K-8000K，50=5000K

        function whiteBalanceText() {
            var kelvin = 2000 + (hardwareWhiteBalance / 100) * 6000
            return Math.round(kelvin) + "K"
        }

        // ⭐ 2026-08-14 颜色参数精调：复用 iOS 滤镜链路下发（iOS 走 STOMP，Android 自动转 PC 本地滤镜）。
        //   滤镜值只有在 filterEnabled 打开时才生效（P 键弹框已禁用，这里首次调整时自动打开）。
        //   ⚠ 首次开启必须全量下发一遍所有滤镜参数——只发单个参数的话，设备端其它参数
        //   （blackPoint/sharpness 等）会以不可控的旧值一起生效，画面会突变。
        function pushColorParam(ptype, val) {
            if (!iosFilterPopup.fEnabled) {
                iosFilterPopup.fEnabled = true
                iosFilterPopup.pushParam("filterEnabled", true)
                iosFilterPopup.pushParam("brightness",    iosFilterPopup.fBrightness)
                iosFilterPopup.pushParam("contrast",      iosFilterPopup.fContrast)
                iosFilterPopup.pushParam("saturation",    iosFilterPopup.fSaturation)
                iosFilterPopup.pushParam("redBoost",      iosFilterPopup.fRedBoost)
                iosFilterPopup.pushParam("gamma",         iosFilterPopup.fGamma)
                iosFilterPopup.pushParam("exposure",      Math.log2(iosFilterPopup.fExposure))
                iosFilterPopup.pushParam("blackPoint",    iosFilterPopup.fBlackPoint)
                iosFilterPopup.pushParam("sharpness",     iosFilterPopup.fSharpness)
                iosFilterPopup.pushParam("highlightLift", iosFilterPopup.fHighlightLift)
                iosFilterPopup.pushParam("chroma",        iosFilterPopup.fChroma)
                console.log("🎨 颜色精调：自动开启滤镜链路（全量下发一遍参数）")
            }
            iosFilterPopup.pushParam(ptype, val)
        }

        // ⭐ 颜色参数精调「还原」：关闭滤镜链路 → 设备回到未加滤镜的原图（这才是真正的还原），
        //   同时把 5 个参数值重置回默认，下次再调时从默认值起步。
        function resetColorTune() {
            iosFilterPopup.fBrightness = iosFilterPopup.brightnessDefault
            iosFilterPopup.fSaturation = iosFilterPopup.saturationDefault
            iosFilterPopup.fContrast   = iosFilterPopup.contrastDefault
            iosFilterPopup.fChroma     = iosFilterPopup.chromaDefault
            iosFilterPopup.fGamma      = iosFilterPopup.gammaDefault
            iosFilterPopup.fEnabled    = false
            iosFilterPopup.pushParam("filterEnabled", false)
            console.log("🎨 颜色参数精调已还原：关闭滤镜链路，画面回到原图")
        }
        
        // 窗口内容背景 ⭐ 深色主题（对齐参考截图风格）
        Rectangle {
            anchors.fill: parent
            color: "#151A24"
            radius: 14
            border.color: "#262C3A"
            border.width: 1
        
            ColumnLayout {
                spacing: 12
                anchors.fill: parent
                anchors.margins: 24
                
                // 拖动区域（标题栏：📷 相机设定 + 复位按钮 + 关闭按钮）
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    color: "transparent"
                    
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.ClosedHandCursor
                        propagateComposedEvents: false
                        
                        property point startPos: Qt.point(0, 0)
                        property point dragStartGlobal: Qt.point(0, 0)
                        
                        onPressed: function(mouse) {
                            startPos = Qt.point(iosCameraSettingsPopup.x, iosCameraSettingsPopup.y)
                            dragStartGlobal = mapToGlobal(mouse.x, mouse.y)
                            iosCameraSettingsPopup.dragging = true
                            mouse.accepted = true
                        }
                        
                        onPositionChanged: function(mouse) {
                            if (iosCameraSettingsPopup.dragging) {
                                var currentGlobal = mapToGlobal(mouse.x, mouse.y)
                                var deltaX = currentGlobal.x - dragStartGlobal.x
                                var deltaY = currentGlobal.y - dragStartGlobal.y
                                iosCameraSettingsPopup.x = startPos.x + deltaX
                                iosCameraSettingsPopup.y = startPos.y + deltaY
                            }
                        }
                        
                        onReleased: {
                            iosCameraSettingsPopup.dragging = false
                        }
                    }

                    // 标题：📷 相机设定 + 复位按钮（紧跟标题后面）
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        spacing: 10
                        Text {
                            text: "📷"
                            font.pixelSize: 18
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "相机设定"
                            font.family: "PingFang HK"
                            font.pixelSize: 17
                            font.bold: true
                            color: "#ECEFF4"
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        // 复位按钮（原"还原"，重置相机设定为默认值；紧跟标题文字后面）
                        Rectangle {
                            id: cameraResetBtn
                            anchors.verticalCenter: parent.verticalCenter
                            width: resetBtnText.width + 20
                            height: 28
                            radius: 6
                            color: resetBtnArea.containsMouse ? "#232B38" : "#1B2330"
                            border.color: "#333B4A"
                            border.width: 1
                            
                            Text {
                                id: resetBtnText
                                anchors.centerIn: parent
                                text: "复位"
                                font.family: "PingFang HK"
                                font.pixelSize: 14
                                color: "#7ED2FF"
                            }
                            
                            MouseArea {
                                id: resetBtnArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    // 对焦：0.6
                                    iosCameraSettingsPopup.focusValue = 0.6
                                    focusSlider.value = 0.6

                                    // 拉后台默认值 → applyServerDefaults 写 f*，反算综亮/综对/综曝，1s 统一下发 pushAllStomp
                                    iosFilterPopup.restorePushPending = true
                                    HttpClient.getIosFilterDefaults()

                                    // 清晰度：50
                                    iosCameraSettingsPopup.clarityValue = 50
                                    claritySlider.value = 50

                                    // 快门：还原到后台配置的默认值（按平台，未配置=120）
                                    var flickerDefault = shutterCfg["default"]
                                    iosCameraSettingsPopup.flickerValue = flickerDefault
                                    flickerSlider.value = flickerDefault

                                    // 帧率：100
                                    iosCameraSettingsPopup.fpsValue = 100
                                    fpsSlider.value = 100

                                    // 抗频闪：打开过就关闭
                                    if (iosCameraSettingsPopup.antiFlickerEnabled) {
                                        iosCameraSettingsPopup.antiFlickerEnabled = false
                                        iosCameraSettingsPopup.antiFlickerFps = 80
                                        sendAntiFlickerConfig()
                                    }

                                    // 下发硬件配置
                                    HttpClient.updateFocusDistance(0.6)
                                    sendConfigUpdate("focus", {"focus": 0.6})
                                    HttpClient.updateFlicker(flickerDefault)
                                    sendConfigUpdate("cjfps", {"cjfps": flickerDefault})
                                    var resetSendFps = resolveSendFps(100)
                                    HttpClient.updateFps(resetSendFps)
                                    sendConfigUpdate("fps", {"fps": resetSendFps})

                                    console.log("🔄 相机设定已复位（滤镜/LUT/硬件 1s 后统一下发）")
                                }
                            }
                        }
                    }

                    // 关闭按钮
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        width: 24
                        height: 24
                        radius: 12
                        color: closeBtn.containsMouse ? "#232B38" : "transparent"
                        
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            font.pixelSize: 14
                            color: "#C7D0DC"
                        }
                        
                        MouseArea {
                            id: closeBtn
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: iosCameraSettingsPopup.close()
                        }
                    }
                }
            
            // 第1行：对焦
            Column {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    text: "向右拖动对焦点变远，向左拖动对焦点变近，请按实际拍摄距离调整"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#6FD1FF"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            RowLayout {
                width: parent.width
                spacing: 10
                
                Text {
                    text: "对焦"
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#ECEFF4"
                    Layout.preferredWidth: 60
                }
                
                Slider {
                    id: focusSlider
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    stepSize: 0.01
                    value: iosCameraSettingsPopup.focusValue
                    onMoved: iosCameraSettingsPopup.focusValue = value
                    onPressedChanged: if (!pressed) {
                        HttpClient.updateFocusDistance(value)
                        sendConfigUpdate("focus", {"focus": value})
                    }
                    
                    background: Rectangle {
                        x: focusSlider.leftPadding
                        y: focusSlider.topPadding + focusSlider.availableHeight / 2 - height / 2
                        implicitWidth: 200
                        implicitHeight: 4
                        width: focusSlider.availableWidth
                        height: 4
                        radius: 999
                        color: "#232A38"
                        
                        Rectangle {
                            width: focusSlider.visualPosition * parent.width
                            height: parent.height
                            radius: 999
                            color: "#3EA6FF"
                        }
                    }
                    
                    handle: Rectangle {
                        x: focusSlider.leftPadding + focusSlider.visualPosition * (focusSlider.availableWidth - width)
                        y: focusSlider.topPadding + focusSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14
                        implicitHeight: 14
                        width: 14
                        height: 14
                        radius: 7
                        color: "#FFFFFF"
                    }
                    
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? focusSlider.stepSize : -focusSlider.stepSize
                            var newValue = focusSlider.value + delta
                            newValue = Math.max(focusSlider.from, Math.min(focusSlider.to, newValue))
                            focusSlider.value = newValue
                            iosCameraSettingsPopup.focusValue = newValue
                            HttpClient.updateFocusDistance(newValue)
                            sendConfigUpdate("focus", {"focus": newValue})
                        }
                    }
                }
                
                Text {
                    text: iosCameraSettingsPopup.focusValue.toFixed(2)
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#ECEFF4"
                    Layout.preferredWidth: 40
                }
            }
            }
            
            // 第2行：ISO（电信号放大增益；对齐 P 键弹框里的「增益(G)」，与清晰度换位挪到这里，简化版不带联动分组 UI）
            Column {
                Layout.fillWidth: true
                spacing: 2

                Text {
                    text: "感光度(ISO) 越高感光越强、暗光下更亮但噪点增多；越低画面更干净但依赖光线充足"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#6FD1FF"
                    anchors.horizontalCenter: parent.horizontalCenter
                }

            RowLayout {
                width: parent.width
                spacing: 10
                
                Text {
                    // ⭐ 2026-08-15 需求：ISO 显示为中文名称
                    text: "感光度"
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#ECEFF4"
                    Layout.preferredWidth: 60
                }
                
                Slider {
                    id: isoSlider
                    Layout.fillWidth: true
                    from: iosFilterPopup.gainFrom
                    to: iosFilterPopup.gainTo
                    stepSize: iosFilterPopup.gainStep
                    value: iosCameraSettingsPopup.hardwareBrightness
                    onMoved: iosCameraSettingsPopup.hardwareBrightness = value
                    onPressedChanged: if (!pressed) {
                        sendTestBrightnessConfig(value)
                    }
                    
                    background: Rectangle {
                        x: isoSlider.leftPadding
                        y: isoSlider.topPadding + isoSlider.availableHeight / 2 - height / 2
                        implicitWidth: 200
                        implicitHeight: 4
                        width: isoSlider.availableWidth
                        height: 4
                        radius: 999
                        color: "#232A38"
                        
                        Rectangle {
                            width: isoSlider.visualPosition * parent.width
                            height: parent.height
                            radius: 999
                            color: "#3EA6FF"
                        }
                    }
                    
                    handle: Rectangle {
                        x: isoSlider.leftPadding + isoSlider.visualPosition * (isoSlider.availableWidth - width)
                        y: isoSlider.topPadding + isoSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14
                        implicitHeight: 14
                        width: 14
                        height: 14
                        radius: 7
                        color: "#FFFFFF"
                    }
                    
                    // ⭐ 鼠标滚轮支持 — ISO
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? isoSlider.stepSize : -isoSlider.stepSize
                            var newValue = isoSlider.value + delta
                            newValue = Math.max(isoSlider.from, Math.min(isoSlider.to, newValue))
                            isoSlider.value = newValue
                            iosCameraSettingsPopup.hardwareBrightness = newValue
                            sendTestBrightnessConfig(newValue)
                        }
                    }
                }
                
                Text {
                    text: Math.round(iosCameraSettingsPopup.hardwareBrightness)
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#ECEFF4"
                    Layout.preferredWidth: 40
                }
            }
            }

            // 第3行：帧率
            Column {
                Layout.fillWidth: true
                spacing: 2
                
                // 说明文字（居中在滑块上方）
                Text {
                    text: "帧率越高画面越流畅连贯，但更消耗网络带宽，网络不佳时建议调低"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#6FD1FF"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                
                // 标签 + 滑块 + 数值
                RowLayout {
                    width: parent.width
                    spacing: 10
                    
                    Text {
                        text: "帧率"
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        color: "#ECEFF4"
                        Layout.preferredWidth: 60
                    }
                    
                    Slider {
                        id: fpsSlider
                        Layout.fillWidth: true
                        from: 0
                        to: 240
                        stepSize: 2  // 步长2，保证下发时为整数
                        value: iosCameraSettingsPopup.fpsValue
                        enabled: !iosCameraSettingsPopup.antiFlickerEnabled  // 抗频闪开启时禁用
                        opacity: iosCameraSettingsPopup.antiFlickerEnabled ? 0.4 : 1.0
                        
                        onMoved: {
                            // 使用全局分段函数获取上限（档位+会员等级）
                            var maxFps = getMaxFpsForQuality(iosCameraSettingsPopup.qualityType)
                            if (value > maxFps) {
                                value = maxFps  // 限制不能超过上限
                            }
                            iosCameraSettingsPopup.fpsValue = value
                        }
                        onPressedChanged: if (!pressed) {
                            // ⭐ fps 直接下发，不再除以2
                            var actualFps = Math.floor(value)
                            if (actualFps < 1) actualFps = 1
                            // ⭐ AI 工具锁 30：滑块本身不受限（想拖多高拖多高），只钉实际下发值
                            var sendFps = resolveSendFps(actualFps)
                            console.log("📤 帧率滑块松开: 滑块值=" + value + ", 实际发送=" + sendFps)
                            HttpClient.updateFps(sendFps)
                            sendConfigUpdate("fps", {"fps": sendFps})
                            // ⭐ v9.3: 同步帧率给 gstPlayer（用于网络质量检测，按滑块显示值算）
                            gstPlayer.setConfigFps(actualFps / 4)  // 服务器fps转实际fps
                        }
                        
                        background: Rectangle {
                            x: fpsSlider.leftPadding
                            y: fpsSlider.topPadding + fpsSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: fpsSlider.availableWidth
                            height: 4
                            radius: 999
                            color: "#232A38"
                            
                            Rectangle {
                                width: fpsSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 999
                                color: "#3EA6FF"
                            }
                        }
                        
                        handle: Rectangle {
                            x: fpsSlider.leftPadding + fpsSlider.visualPosition * (fpsSlider.availableWidth - width)
                            y: fpsSlider.topPadding + fpsSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                        }
                        
                        // ⭐ 鼠标滚轮支持
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            onWheel: function(wheel) {
                                var delta = wheel.angleDelta.y > 0 ? fpsSlider.stepSize : -fpsSlider.stepSize
                                var newValue = fpsSlider.value + delta
                                var maxFps = getMaxFpsForQuality(iosCameraSettingsPopup.qualityType)
                                newValue = Math.max(fpsSlider.from, Math.min(maxFps, newValue))
                                fpsSlider.value = newValue
                                iosCameraSettingsPopup.fpsValue = newValue
                                var actualFps = Math.floor(newValue)
                                if (actualFps < 1) actualFps = 1
                                // ⭐ AI 工具锁 30：滑块本身不受限，只钉实际下发值
                                var sendFps = resolveSendFps(actualFps)
                                HttpClient.updateFps(sendFps)
                                sendConfigUpdate("fps", {"fps": sendFps})
                            }
                        }
                    }
                    
                    Text {
                        text: iosCameraSettingsPopup.fpsValue
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        color: "#ECEFF4"
                        Layout.preferredWidth: 40
                    }
                }
            }
            
            // 第4行：快门（原"超级帧率"改名，取消说明文字）
            Column {
                Layout.fillWidth: true
                spacing: 2

                // 标签 + 滑块 + 数值
                RowLayout {
                    width: parent.width
                    spacing: 10
                    
                    Text {
                        text: "快门"
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        color: "#ECEFF4"
                        Layout.preferredWidth: 60
                    }
                    
                    Slider {
                        id: flickerSlider
                        Layout.fillWidth: true
                        // ⭐ 范围/步进走后台快门配置（按 iOS/Android 分组，见 shutterCfg），onMoved 仍按会员上限钳制
                        from: shutterCfg.min
                        // ⭐ 2026-08-01 修「超级帧率卡 600」：滑块物理上限原来只认 shutterCfg.max（快门配置，
                        //   默认 600），与「曝光FPS 会员上限」是两套配置，导致后台把曝光FPS 设到 1000、
                        //   滑块却滑不过 600。改为取两者较大值——会员实际上限(getMaxFlickerValue，含曝光FPS+PC等级)
                        //   高于快门配置时，直接把滑块顶到会员上限；onMoved/onWheel 仍按会员上限二次钳制，安全。
                        to: Math.max(shutterCfg.max, getMaxFlickerValue())
                        stepSize: shutterCfg.step
                        value: iosCameraSettingsPopup.flickerValue
                        onMoved: {
                            // 使用分段函数获取上限（档位+会员等级）
                            var maxFlicker = getMaxFlickerValue()
                            if (value > maxFlicker) {
                                value = maxFlicker  // 限制不能超过上限
                            }
                            iosCameraSettingsPopup.flickerValue = value
                        }
                        onPressedChanged: if (!pressed) {
                            // 直接下发 60-400
                            HttpClient.updateFlicker(value)
                            sendConfigUpdate("cjfps", {"cjfps": value})
                        }
                        
                        background: Rectangle {
                            x: flickerSlider.leftPadding
                            y: flickerSlider.topPadding + flickerSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: flickerSlider.availableWidth
                            height: 4
                            radius: 999
                            color: "#232A38"
                            
                            Rectangle {
                                width: flickerSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 999
                                color: "#3EA6FF"
                            }
                        }
                        
                        handle: Rectangle {
                            x: flickerSlider.leftPadding + flickerSlider.visualPosition * (flickerSlider.availableWidth - width)
                            y: flickerSlider.topPadding + flickerSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                        }
                        
                        // ⭐ 鼠标滚轮支持
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? flickerSlider.stepSize : -flickerSlider.stepSize
                            var newValue = flickerSlider.value + delta
                            var maxFlicker = getMaxFlickerValue()
                            newValue = Math.max(flickerSlider.from, Math.min(maxFlicker, newValue))
                            flickerSlider.value = newValue
                            iosCameraSettingsPopup.flickerValue = newValue
                            HttpClient.updateFlicker(newValue)
                            sendConfigUpdate("cjfps", {"cjfps": newValue})
                        }
                        }
                    }
                    
                    Text {
                        // 直接显示滑块值 60-400
                        text: iosCameraSettingsPopup.flickerValue
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        color: "#ECEFF4"
                        Layout.preferredWidth: 40
                    }
                }
            }
            
            // 第5行：清晰度（与 ISO 换位挪到这里）
            Column {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    text: "清晰度越高细节越丰富，同样更吃网速，远距离监控建议调高一些"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#6FD1FF"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            RowLayout {
                width: parent.width
                spacing: 10
                
                Text {
                    text: "清晰度"
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#ECEFF4"
                    Layout.preferredWidth: 60
                }
                
                Slider {
                    id: claritySlider
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    stepSize: 1
                    value: iosCameraSettingsPopup.clarityValue
                    onMoved: iosCameraSettingsPopup.clarityValue = value
                    onPressedChanged: if (!pressed) {
                        HttpClient.updateClarity(value)
                        sendConfigUpdate("bitrate", {"bitrate": value})
                    }
                    
                    background: Rectangle {
                        x: claritySlider.leftPadding
                        y: claritySlider.topPadding + claritySlider.availableHeight / 2 - height / 2
                        implicitWidth: 200
                        implicitHeight: 4
                        width: claritySlider.availableWidth
                        height: 4
                        radius: 999
                        color: "#232A38"
                        
                        Rectangle {
                            width: claritySlider.visualPosition * parent.width
                            height: parent.height
                            radius: 999
                            color: "#3EA6FF"
                        }
                    }
                    
                    handle: Rectangle {
                        x: claritySlider.leftPadding + claritySlider.visualPosition * (claritySlider.availableWidth - width)
                        y: claritySlider.topPadding + claritySlider.availableHeight / 2 - height / 2
                        implicitWidth: 14
                        implicitHeight: 14
                        width: 14
                        height: 14
                        radius: 7
                        color: "#FFFFFF"
                    }
                    
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? claritySlider.stepSize : -claritySlider.stepSize
                            var newValue = claritySlider.value + delta
                            newValue = Math.max(claritySlider.from, Math.min(claritySlider.to, newValue))
                            claritySlider.value = newValue
                            iosCameraSettingsPopup.clarityValue = newValue
                            HttpClient.updateClarity(newValue)
                            sendConfigUpdate("bitrate", {"bitrate": newValue})
                        }
                    }
                }
                
                Text {
                    text: iosCameraSettingsPopup.clarityValue
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#ECEFF4"
                    Layout.preferredWidth: 40
                }
            }
            }

            // ===== 颜色参数精调（⭐ 2026-08-14 新增：亮度/饱和度/对比度/色调/伽马，复用 iOS 滤镜参数）=====
            Column {
                Layout.fillWidth: true
                spacing: 10

                // 分隔线
                Rectangle { width: parent.width; height: 1; color: "#262C3A" }

                // 标题 + 还原按钮
                Row {
                    spacing: 10

                    Text {
                        text: "颜色参数精调"
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        font.bold: true
                        color: "#ECEFF4"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: colorTuneResetText.width + 20
                        height: 28
                        radius: 6
                        color: colorTuneResetArea.containsMouse ? "#232B38" : "#1B2330"
                        border.color: "#333B4A"
                        border.width: 1

                        Text {
                            id: colorTuneResetText
                            anchors.centerIn: parent
                            text: "还原"
                            font.family: "PingFang HK"
                            font.pixelSize: 13
                            color: "#ECEFF4"
                        }

                        MouseArea {
                            id: colorTuneResetArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // ⭐ 关滤镜=回原图（真还原），参数重置为默认值供下次起步
                                iosCameraSettingsPopup.resetColorTune()
                                tuneBrightnessSlider.value = iosFilterPopup.fBrightness
                                tuneSaturationSlider.value = iosFilterPopup.fSaturation
                                tuneContrastSlider.value   = iosFilterPopup.fContrast
                                tuneChromaSlider.value     = iosFilterPopup.fChroma
                                tuneGammaSlider.value      = iosFilterPopup.fGamma
                            }
                        }
                    }
                }

                // 亮度
                RowLayout {
                    width: parent.width
                    spacing: 10

                    Text {
                        text: "亮度"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: tuneBrightnessSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.brightnessFrom
                        to: iosFilterPopup.brightnessTo
                        stepSize: iosFilterPopup.brightnessStep
                        value: iosFilterPopup.fBrightness
                        onMoved: iosFilterPopup.fBrightness = value
                        onPressedChanged: if (!pressed) iosCameraSettingsPopup.pushColorParam("brightness", iosFilterPopup.fBrightness)

                        background: Rectangle {
                            x: tuneBrightnessSlider.leftPadding
                            y: tuneBrightnessSlider.topPadding + tuneBrightnessSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: tuneBrightnessSlider.availableWidth
                            height: 4
                            radius: 999
                            color: "#232A38"

                            Rectangle {
                                width: tuneBrightnessSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 999
                                color: "#3EA6FF"
                            }
                        }

                        handle: Rectangle {
                            x: tuneBrightnessSlider.leftPadding + tuneBrightnessSlider.visualPosition * (tuneBrightnessSlider.availableWidth - width)
                            y: tuneBrightnessSlider.topPadding + tuneBrightnessSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            onWheel: function(wheel) {
                                var delta = wheel.angleDelta.y > 0 ? tuneBrightnessSlider.stepSize : -tuneBrightnessSlider.stepSize
                                var newValue = Math.max(tuneBrightnessSlider.from, Math.min(tuneBrightnessSlider.to, tuneBrightnessSlider.value + delta))
                                tuneBrightnessSlider.value = newValue
                                iosFilterPopup.fBrightness = newValue
                                iosCameraSettingsPopup.pushColorParam("brightness", newValue)
                            }
                        }
                    }

                    Text {
                        // ⭐ 2026-08-15 需求：按滑条位置显示百分比（仅显示，底层参数/逻辑不变）
                        text: Math.round(tuneBrightnessSlider.position * 100) + "%"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 48
                    }
                }

                // 对比度（⭐ 2026-08-15 需求：与饱和度换位，顺序统一为 亮度/对比度/饱和度/色调/伽马）
                RowLayout {
                    width: parent.width
                    spacing: 10

                    Text {
                        text: "对比度"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: tuneContrastSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.contrastFrom
                        to: iosFilterPopup.contrastTo
                        stepSize: iosFilterPopup.contrastStep
                        value: iosFilterPopup.fContrast
                        onMoved: iosFilterPopup.fContrast = value
                        onPressedChanged: if (!pressed) iosCameraSettingsPopup.pushColorParam("contrast", iosFilterPopup.fContrast)

                        background: Rectangle {
                            x: tuneContrastSlider.leftPadding
                            y: tuneContrastSlider.topPadding + tuneContrastSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: tuneContrastSlider.availableWidth
                            height: 4
                            radius: 999
                            color: "#232A38"

                            Rectangle {
                                width: tuneContrastSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 999
                                color: "#3EA6FF"
                            }
                        }

                        handle: Rectangle {
                            x: tuneContrastSlider.leftPadding + tuneContrastSlider.visualPosition * (tuneContrastSlider.availableWidth - width)
                            y: tuneContrastSlider.topPadding + tuneContrastSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            onWheel: function(wheel) {
                                var delta = wheel.angleDelta.y > 0 ? tuneContrastSlider.stepSize : -tuneContrastSlider.stepSize
                                var newValue = Math.max(tuneContrastSlider.from, Math.min(tuneContrastSlider.to, tuneContrastSlider.value + delta))
                                tuneContrastSlider.value = newValue
                                iosFilterPopup.fContrast = newValue
                                iosCameraSettingsPopup.pushColorParam("contrast", newValue)
                            }
                        }
                    }

                    Text {
                        text: Math.round(tuneContrastSlider.position * 100) + "%"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 48
                    }
                }

                // 饱和度
                RowLayout {
                    width: parent.width
                    spacing: 10

                    Text {
                        text: "饱和度"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: tuneSaturationSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.saturationFrom
                        to: iosFilterPopup.saturationTo
                        stepSize: iosFilterPopup.saturationStep
                        value: iosFilterPopup.fSaturation
                        onMoved: iosFilterPopup.fSaturation = value
                        onPressedChanged: if (!pressed) iosCameraSettingsPopup.pushColorParam("saturation", iosFilterPopup.fSaturation)

                        background: Rectangle {
                            x: tuneSaturationSlider.leftPadding
                            y: tuneSaturationSlider.topPadding + tuneSaturationSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: tuneSaturationSlider.availableWidth
                            height: 4
                            radius: 999
                            color: "#232A38"

                            Rectangle {
                                width: tuneSaturationSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 999
                                color: "#3EA6FF"
                            }
                        }

                        handle: Rectangle {
                            x: tuneSaturationSlider.leftPadding + tuneSaturationSlider.visualPosition * (tuneSaturationSlider.availableWidth - width)
                            y: tuneSaturationSlider.topPadding + tuneSaturationSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            onWheel: function(wheel) {
                                var delta = wheel.angleDelta.y > 0 ? tuneSaturationSlider.stepSize : -tuneSaturationSlider.stepSize
                                var newValue = Math.max(tuneSaturationSlider.from, Math.min(tuneSaturationSlider.to, tuneSaturationSlider.value + delta))
                                tuneSaturationSlider.value = newValue
                                iosFilterPopup.fSaturation = newValue
                                iosCameraSettingsPopup.pushColorParam("saturation", newValue)
                            }
                        }
                    }

                    Text {
                        text: Math.round(tuneSaturationSlider.position * 100) + "%"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 48
                    }
                }

                // 色调（对应 iOS 滤镜的 chroma 色度参数）
                RowLayout {
                    width: parent.width
                    spacing: 10

                    Text {
                        text: "色调"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: tuneChromaSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.chromaFrom
                        to: iosFilterPopup.chromaTo
                        stepSize: iosFilterPopup.chromaStep
                        value: iosFilterPopup.fChroma
                        onMoved: iosFilterPopup.fChroma = value
                        onPressedChanged: if (!pressed) iosCameraSettingsPopup.pushColorParam("chroma", iosFilterPopup.fChroma)

                        background: Rectangle {
                            x: tuneChromaSlider.leftPadding
                            y: tuneChromaSlider.topPadding + tuneChromaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: tuneChromaSlider.availableWidth
                            height: 4
                            radius: 999
                            color: "#232A38"

                            Rectangle {
                                width: tuneChromaSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 999
                                color: "#3EA6FF"
                            }
                        }

                        handle: Rectangle {
                            x: tuneChromaSlider.leftPadding + tuneChromaSlider.visualPosition * (tuneChromaSlider.availableWidth - width)
                            y: tuneChromaSlider.topPadding + tuneChromaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            onWheel: function(wheel) {
                                var delta = wheel.angleDelta.y > 0 ? tuneChromaSlider.stepSize : -tuneChromaSlider.stepSize
                                var newValue = Math.max(tuneChromaSlider.from, Math.min(tuneChromaSlider.to, tuneChromaSlider.value + delta))
                                tuneChromaSlider.value = newValue
                                iosFilterPopup.fChroma = newValue
                                iosCameraSettingsPopup.pushColorParam("chroma", newValue)
                            }
                        }
                    }

                    Text {
                        text: Math.round(tuneChromaSlider.position * 100) + "%"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 48
                    }
                }

                // 伽马
                RowLayout {
                    width: parent.width
                    spacing: 10

                    Text {
                        text: "伽马"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: tuneGammaSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.gammaFrom
                        to: iosFilterPopup.gammaTo
                        stepSize: iosFilterPopup.gammaStep
                        value: iosFilterPopup.fGamma
                        onMoved: iosFilterPopup.fGamma = value
                        onPressedChanged: if (!pressed) iosCameraSettingsPopup.pushColorParam("gamma", iosFilterPopup.fGamma)

                        background: Rectangle {
                            x: tuneGammaSlider.leftPadding
                            y: tuneGammaSlider.topPadding + tuneGammaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: tuneGammaSlider.availableWidth
                            height: 4
                            radius: 999
                            color: "#232A38"

                            Rectangle {
                                width: tuneGammaSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 999
                                color: "#3EA6FF"
                            }
                        }

                        handle: Rectangle {
                            x: tuneGammaSlider.leftPadding + tuneGammaSlider.visualPosition * (tuneGammaSlider.availableWidth - width)
                            y: tuneGammaSlider.topPadding + tuneGammaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            width: 14
                            height: 14
                            radius: 7
                            color: "#FFFFFF"
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            onWheel: function(wheel) {
                                var delta = wheel.angleDelta.y > 0 ? tuneGammaSlider.stepSize : -tuneGammaSlider.stepSize
                                var newValue = Math.max(tuneGammaSlider.from, Math.min(tuneGammaSlider.to, tuneGammaSlider.value + delta))
                                tuneGammaSlider.value = newValue
                                iosFilterPopup.fGamma = newValue
                                iosCameraSettingsPopup.pushColorParam("gamma", newValue)
                            }
                        }
                    }

                    Text {
                        text: Math.round(tuneGammaSlider.position * 100) + "%"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#ECEFF4"
                        Layout.preferredWidth: 48
                    }
                }
            }

            }  // 关闭 ColumnLayout
        }  // 关闭 Rectangle
    }  // 关闭 Window (相机设定)
    
    // ============ ⭐ 第五十章：OTG 外接摄像头设定面板（独立文件 OtgCameraPanel.qml）============
    //   这里只做接线：面板不认识 STOMP，发 sendOtg 信号，由这里转成 CONFIG_UPDATE。
    //   下发一律 otg_ 前缀，与自带摄像头那套 ptype 分家（Android 侧 OtgConfigRouter 独立消费）。
    OtgCameraPanel {
        id: otgCameraPanel
        onSendOtg: function(ptype, payload) {
            // ⭐ 全链路日志锚点⓪（PC 侧，进 qlgx.txt）：面板每次点击/拖动实际发了什么。
            //   qlgx 里有这行而 OTG 日志里没有「🔗 [OTG链路|收到]」= 信令没到手机；
            //   qlgx 里没这行 = PC 面板没发（点击没触发）。
            console.log("🔗 [OTG链路|PC下发] " + ptype + " " + JSON.stringify(payload))
            sendConfigUpdate(ptype, payload)
            // ⭐ 2026-08-03 修「OTG 切档卡死」：与底部快捷栏同款——切档后四连 PLI 要关键帧
            //  （自带摄像头切档一直有这套，OTG 通道此前漏了）。
            // ⭐ 2026-08-04：otg_fps 也要（改帧率触发编码器重置 → 绿屏，华为实锤）。
            if (ptype === "otg_resolution" || ptype === "otg_fps") {
                pliAfterQualitySwitchTimer.restart()
            }
        }
    }

    function toggleOtgCameraPanel() {
        if (otgCameraPanel.visible) {
            otgCameraPanel.close()
            return
        }
        if (!CameraCapsStore.isOtg) {
            showToast("当前设备不是外接OTG摄像头")
            return
        }
        // 锚定「外接摄像头设定」菜单项（相机设定在 OTG 下已隐藏）
        var anchor = otgCameraSettingText.visible ? otgCameraSettingText : cameraSettingText
        var globalPos = anchor.mapToGlobal(0, anchor.height + 5)
        otgCameraPanel.x = globalPos.x
        otgCameraPanel.y = globalPos.y
        otgCameraPanel.open()
    }

    // 显示 iOS 相机设定
    function showIosCameraSettings() {
        if (CameraCapsStore.isOtg) {
            return
        }
        // ⭐ 不再每次打开都从服务器获取配置，使用本地缓存值
        // 用户修改后的值保持在 iosCameraSettingsPopup 的属性中
        // 登录时已通过 getThinConfig() 获取过初始值

        // 设置位置：使用屏幕绝对坐标（Window 组件）
        var globalPos = cameraSettingText.mapToGlobal(0, cameraSettingText.height + 5)
        iosCameraSettingsPopup.x = globalPos.x
        iosCameraSettingsPopup.y = globalPos.y

        iosCameraSettingsPopup.open()
    }

    // 滤镜模式开关（以 iOS 滤镜弹框为准）
    function sendFilterModeConfig() {
        var enabled = iosFilterPopup.fEnabled
        iosCameraSettingsPopup.filterModeEnabled = enabled
        sendConfigUpdate("filterEnabled", { "filterEnabled": enabled })
        console.log("🎨 滤镜模式:", enabled ? "开启" : "关闭")
    }

    // LUT 模式开关（以 iOS 滤镜弹框为准）
    function sendLutModeConfig() {
        var enabled = iosFilterPopup.lutEnabled
        iosCameraSettingsPopup.lutModeEnabled = enabled
        var payload = { "cmd": "test_mode", "enabled": enabled }
        console.log("🎨 LUT模式:", enabled ? "开启" : "关闭")
        sendConfigUpdate("test_mode", payload)
    }

    // 清晰度百分比 → iOS 码率 min/max
    function sendBitrateConfig() {
        var v = iosCameraSettingsPopup.clarityValue
        sendConfigUpdate("bitrate", { "bitrate": v })
        console.log("📊 清晰度/码率推送:", v + "%")
    }

    // 硬件亮度：ISO/EV -2~+8，不受滤镜/LUT 开关影响
    function sendTestBrightnessConfig(value) {
        var v = Math.round(value)
        iosCameraSettingsPopup.hardwareBrightness = v
        iosFilterPopup.fGain = v
        iosFilterPopup.prevGain = v
        if (typeof ifGainSlider !== 'undefined')
            ifGainSlider.value = v
        if (typeof isoSlider !== 'undefined')
            isoSlider.value = v
        var payload = { "cmd": "test_brightness", "value": v }
        sendConfigUpdate("test_brightness", payload)
    }

    // 白平衡：色温 2000K-8000K，不受滤镜/LUT 开关影响
    function sendWhiteBalanceConfig(value) {
        var v = Math.round(value)
        iosCameraSettingsPopup.hardwareWhiteBalance = v
        if (typeof ifFilterWhiteBalanceSlider !== 'undefined')
            ifFilterWhiteBalanceSlider.value = v
        var payload = { "cmd": "white_balance", "value": v }
        sendConfigUpdate("white_balance", payload)
    }

    // 抗频闪：发送开关和帧率档位到 iOS
    function sendAntiFlickerConfig() {
        var enabled = iosCameraSettingsPopup.antiFlickerEnabled
        var fps = iosCameraSettingsPopup.antiFlickerFps  // 80/100/200（服务器格式）
        var payload = {
            "cmd": "anti_flicker",
            "enabled": enabled,
            "fps": enabled ? fps : 0
        }
        console.log("🔦 抗频闪:", enabled ? "开启 fps=" + fps : "关闭")
        sendConfigUpdate("anti_flicker", payload)

        if (enabled) {
            // 同步 FPS 滑块 UI
            iosCameraSettingsPopup.fpsValue = fps
            fpsSlider.value = fps

            // 同步帧率给 gstPlayer（200 档保持当前画质档位，不自动切 ultra）
            gstPlayer.setConfigFps(fps / 4)
        }
    }
    
    // ============ 曝光值设定 Window（独立窗口，可全屏拖动）============
    Window {
        id: exposureSettingsPopup
        width: 560
        height: 360
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "transparent"
        visible: false
        
        // 兼容 Popup 的 open/close 方法
        function open() { 
            // 打开时同步当前值
            exposureValue = captureManager.exposure
            brightnessValue = captureManager.brightness
            contrastValue = captureManager.contrast
            saturationValue = captureManager.saturation
            hueValue = captureManager.hue
            gammaValue = captureManager.gamma
            
            // 如果首次打开，居中显示
            if (!positionInitialized) {
                x = (Screen.width - width) / 2
                y = (Screen.height - height) / 2
                positionInitialized = true
            }
            visible = true
        }
        function close() { visible = false }
        
        // 拖动相关属性
        property point dragStart: Qt.point(0, 0)
        property bool dragging: false
        property bool positionInitialized: false
        
        // 曝光参数（默认值：饱和度、对比度1.10）
        property int exposureValue: 20
        property double brightnessValue: -0.02
        property double contrastValue: 1.10
        property double saturationValue: 1.10
        property double hueValue: -0.02
        property double gammaValue: 1.08
        
        // 窗口内容背景
        Rectangle {
            anchors.fill: parent
            color: "#FFFFFF"
            radius: 4
            border.color: "#A5D6A7"
            border.width: 1
        
            ColumnLayout {
                spacing: 16
                anchors.fill: parent
                anchors.margins: 24
                
                // 拖动区域（标题栏）
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    color: "transparent"
                    
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.ClosedHandCursor
                        propagateComposedEvents: false
                        
                        property point startPos: Qt.point(0, 0)
                        property point dragStartGlobal: Qt.point(0, 0)
                        
                        onPressed: function(mouse) {
                            startPos = Qt.point(exposureSettingsPopup.x, exposureSettingsPopup.y)
                            dragStartGlobal = mapToGlobal(mouse.x, mouse.y)
                            exposureSettingsPopup.dragging = true
                            mouse.accepted = true
                        }
                        
                        onPositionChanged: function(mouse) {
                            if (exposureSettingsPopup.dragging) {
                                var currentGlobal = mapToGlobal(mouse.x, mouse.y)
                                var deltaX = currentGlobal.x - dragStartGlobal.x
                                var deltaY = currentGlobal.y - dragStartGlobal.y
                                exposureSettingsPopup.x = startPos.x + deltaX
                                exposureSettingsPopup.y = startPos.y + deltaY
                            }
                        }
                        
                        onReleased: {
                            exposureSettingsPopup.dragging = false
                        }
                    }
                    
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "📷 曝光值设定"
                        font.family: "PingFang HK"
                        font.pixelSize: 18
                        font.bold: true
                        color: "#263238"
                    }
                    
                    // 关闭按钮
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 24
                        radius: 12
                        color: closeExpBtn.containsMouse ? "#C8E6C9" : "transparent"
                        
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            font.pixelSize: 14
                            color: "#546E7A"
                        }
                        
                        MouseArea {
                            id: closeExpBtn
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: exposureSettingsPopup.close()
                        }
                    }
                }
            
            // 综合亮度
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: "综合亮度"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 70 }
                Slider {
                    id: expSlider
                    Layout.fillWidth: true
                    from: 0; to: 100; stepSize: 1
                    value: exposureSettingsPopup.exposureValue
                    onMoved: {
                        exposureSettingsPopup.exposureValue = value
                        iosCameraSettingsPopup.exposureValue = value  // 同步到相机设定弹框
                        captureManager.applyExposurePreview(value)
                        syncExposureParamsFromCaptureManager()
                    }
                    onPressedChanged: if (!pressed) {
                        captureManager.exposure = value
                        sendConfigUpdate("exposureBias", {"exposureBias": value})
                    }
                    background: Rectangle {
                        x: expSlider.leftPadding; y: expSlider.topPadding + expSlider.availableHeight / 2 - 2
                        implicitWidth: 200; implicitHeight: 4; width: expSlider.availableWidth; height: 4; radius: 999; color: "#C8E6C9"
                        Rectangle { width: expSlider.visualPosition * parent.width; height: parent.height; radius: 999; color: "#4DB6AC" }
                    }
                    handle: Rectangle {
                        x: expSlider.leftPadding + expSlider.visualPosition * (expSlider.availableWidth - width)
                        y: expSlider.topPadding + expSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14; implicitHeight: 14; width: 14; height: 14; radius: 7; color: "#4DB6AC"
                    }
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? expSlider.stepSize : -expSlider.stepSize
                            var newValue = expSlider.value + delta
                            newValue = Math.max(expSlider.from, Math.min(expSlider.to, newValue))
                            expSlider.value = newValue
                            exposureSettingsPopup.exposureValue = newValue
                            iosCameraSettingsPopup.exposureValue = newValue
                            captureManager.exposure = newValue
                            sendConfigUpdate("exposureBias", {"exposureBias": newValue})
                        }
                    }
                }
                Text { text: exposureSettingsPopup.exposureValue * 100; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 60 }  // ⚠️ ×100 迷惑量级, 跟相机设定弹框一致 — 别改回 ×10
            }
            
            // 亮度
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: "亮度"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 70 }
                Slider {
                    id: brightSlider
                    Layout.fillWidth: true
                    from: -1.0; to: 1.0; stepSize: 0.01
                    value: exposureSettingsPopup.brightnessValue
                    onMoved: {
                        exposureSettingsPopup.brightnessValue = value
                        // 同步到相机设定弹框（限制在其范围内 -0.2 ~ 0.3）
                        iosCameraSettingsPopup.brightnessValue = Math.max(-0.2, Math.min(0.3, value))
                        // ⭐ PC 端色彩调整已禁用 (看 iOS 原画)
                        // captureManager.brightness = value
                    }
                    onPressedChanged: if (!pressed) { /* sendRenderParamUpdate("brightness", value) */ }
                    background: Rectangle {
                        x: brightSlider.leftPadding; y: brightSlider.topPadding + brightSlider.availableHeight / 2 - 2
                        implicitWidth: 200; implicitHeight: 4; width: brightSlider.availableWidth; height: 4; radius: 999; color: "#C8E6C9"
                        Rectangle { width: brightSlider.visualPosition * parent.width; height: parent.height; radius: 999; color: "#4DB6AC" }
                    }
                    handle: Rectangle {
                        x: brightSlider.leftPadding + brightSlider.visualPosition * (brightSlider.availableWidth - width)
                        y: brightSlider.topPadding + brightSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14; implicitHeight: 14; width: 14; height: 14; radius: 7; color: "#4DB6AC"
                    }
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? brightSlider.stepSize : -brightSlider.stepSize
                            var newValue = brightSlider.value + delta
                            newValue = Math.max(brightSlider.from, Math.min(brightSlider.to, newValue))
                            brightSlider.value = newValue
                            exposureSettingsPopup.brightnessValue = newValue
                            iosCameraSettingsPopup.brightnessValue = Math.max(-0.2, Math.min(0.3, newValue))
                            // ⭐ PC 端色彩调整已禁用 (看 iOS 原画)
                            // captureManager.brightness = newValue
                            // sendRenderParamUpdate("brightness", newValue)
                        }
                    }
                }
                Text { text: exposureSettingsPopup.brightnessValue.toFixed(2); font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 40 }
            }
            
            // 对比度
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: "对比度"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 70 }
                Slider {
                    id: contrastSlider
                    Layout.fillWidth: true
                    from: 0.0; to: 2.0; stepSize: 0.01
                    value: exposureSettingsPopup.contrastValue
                    onMoved: { exposureSettingsPopup.contrastValue = value; /* captureManager.contrast = value */ }
                    onPressedChanged: if (!pressed) { /* sendRenderParamUpdate("contrast", value) */ }
                    background: Rectangle {
                        x: contrastSlider.leftPadding; y: contrastSlider.topPadding + contrastSlider.availableHeight / 2 - 2
                        implicitWidth: 200; implicitHeight: 4; width: contrastSlider.availableWidth; height: 4; radius: 999; color: "#C8E6C9"
                        Rectangle { width: contrastSlider.visualPosition * parent.width; height: parent.height; radius: 999; color: "#4DB6AC" }
                    }
                    handle: Rectangle {
                        x: contrastSlider.leftPadding + contrastSlider.visualPosition * (contrastSlider.availableWidth - width)
                        y: contrastSlider.topPadding + contrastSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14; implicitHeight: 14; width: 14; height: 14; radius: 7; color: "#4DB6AC"
                    }
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? contrastSlider.stepSize : -contrastSlider.stepSize
                            var newValue = contrastSlider.value + delta
                            newValue = Math.max(contrastSlider.from, Math.min(contrastSlider.to, newValue))
                            contrastSlider.value = newValue
                            exposureSettingsPopup.contrastValue = newValue
                            // ⭐ PC 端色彩调整已禁用 (看 iOS 原画)
                            // captureManager.contrast = newValue
                            // sendRenderParamUpdate("contrast", newValue)
                        }
                    }
                }
                Text { text: exposureSettingsPopup.contrastValue.toFixed(2); font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 40 }
            }
            
            // 饱和度
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: "饱和度"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 70 }
                Slider {
                    id: satSlider
                    Layout.fillWidth: true
                    from: 0.0; to: 2.0; stepSize: 0.01
                    value: exposureSettingsPopup.saturationValue
                    onMoved: {
                        exposureSettingsPopup.saturationValue = value
                        iosCameraSettingsPopup.saturationValue = value  // 同步到相机设定弹框
                        // ⭐ PC 端色彩调整已禁用 (看 iOS 原画)
                        // captureManager.saturation = value
                    }
                    onPressedChanged: if (!pressed) { /* sendRenderParamUpdate("saturation", value) */ }
                    background: Rectangle {
                        x: satSlider.leftPadding; y: satSlider.topPadding + satSlider.availableHeight / 2 - 2
                        implicitWidth: 200; implicitHeight: 4; width: satSlider.availableWidth; height: 4; radius: 999; color: "#C8E6C9"
                        Rectangle { width: satSlider.visualPosition * parent.width; height: parent.height; radius: 999; color: "#4DB6AC" }
                    }
                    handle: Rectangle {
                        x: satSlider.leftPadding + satSlider.visualPosition * (satSlider.availableWidth - width)
                        y: satSlider.topPadding + satSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14; implicitHeight: 14; width: 14; height: 14; radius: 7; color: "#4DB6AC"
                    }
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? satSlider.stepSize : -satSlider.stepSize
                            var newValue = satSlider.value + delta
                            newValue = Math.max(satSlider.from, Math.min(satSlider.to, newValue))
                            satSlider.value = newValue
                            exposureSettingsPopup.saturationValue = newValue
                            iosCameraSettingsPopup.saturationValue = newValue
                            // ⭐ PC 端色彩调整已禁用 (看 iOS 原画)
                            // captureManager.saturation = newValue
                            // sendRenderParamUpdate("saturation", newValue)
                        }
                    }
                }
                Text { text: exposureSettingsPopup.saturationValue.toFixed(2); font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 40 }
            }
            
            // 色调
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: "色调"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 70 }
                Slider {
                    id: hueSlider
                    Layout.fillWidth: true
                    from: -1.0; to: 1.0; stepSize: 0.01
                    value: exposureSettingsPopup.hueValue
                    onMoved: { exposureSettingsPopup.hueValue = value; /* captureManager.hue = value */ }
                    onPressedChanged: if (!pressed) { /* sendRenderParamUpdate("hue", value) */ }
                    background: Rectangle {
                        x: hueSlider.leftPadding; y: hueSlider.topPadding + hueSlider.availableHeight / 2 - 2
                        implicitWidth: 200; implicitHeight: 4; width: hueSlider.availableWidth; height: 4; radius: 999; color: "#C8E6C9"
                        Rectangle { width: hueSlider.visualPosition * parent.width; height: parent.height; radius: 999; color: "#4DB6AC" }
                    }
                    handle: Rectangle {
                        x: hueSlider.leftPadding + hueSlider.visualPosition * (hueSlider.availableWidth - width)
                        y: hueSlider.topPadding + hueSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14; implicitHeight: 14; width: 14; height: 14; radius: 7; color: "#4DB6AC"
                    }
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? hueSlider.stepSize : -hueSlider.stepSize
                            var newValue = hueSlider.value + delta
                            newValue = Math.max(hueSlider.from, Math.min(hueSlider.to, newValue))
                            hueSlider.value = newValue
                            exposureSettingsPopup.hueValue = newValue
                            // ⭐ PC 端色彩调整已禁用 (看 iOS 原画)
                            // captureManager.hue = newValue
                            // sendRenderParamUpdate("hue", newValue)
                        }
                    }
                }
                Text { text: exposureSettingsPopup.hueValue.toFixed(2); font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 40 }
            }
            
            // 伽马
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: "伽马"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 70 }
                Slider {
                    id: gammaSlider
                    Layout.fillWidth: true
                    from: 0.01; to: 10.0; stepSize: 0.01
                    value: exposureSettingsPopup.gammaValue
                    onMoved: { exposureSettingsPopup.gammaValue = value; /* captureManager.gamma = value */ }
                    onPressedChanged: if (!pressed) { /* sendRenderParamUpdate("gamma", value) */ }
                    background: Rectangle {
                        x: gammaSlider.leftPadding; y: gammaSlider.topPadding + gammaSlider.availableHeight / 2 - 2
                        implicitWidth: 200; implicitHeight: 4; width: gammaSlider.availableWidth; height: 4; radius: 999; color: "#C8E6C9"
                        Rectangle { width: gammaSlider.visualPosition * parent.width; height: parent.height; radius: 999; color: "#4DB6AC" }
                    }
                    handle: Rectangle {
                        x: gammaSlider.leftPadding + gammaSlider.visualPosition * (gammaSlider.availableWidth - width)
                        y: gammaSlider.topPadding + gammaSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14; implicitHeight: 14; width: 14; height: 14; radius: 7; color: "#4DB6AC"
                    }
                    // ⭐ 鼠标滚轮支持
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            var delta = wheel.angleDelta.y > 0 ? gammaSlider.stepSize : -gammaSlider.stepSize
                            var newValue = gammaSlider.value + delta
                            newValue = Math.max(gammaSlider.from, Math.min(gammaSlider.to, newValue))
                            gammaSlider.value = newValue
                            exposureSettingsPopup.gammaValue = newValue
                            // ⭐ PC 端色彩调整已禁用 (看 iOS 原画)
                            // captureManager.gamma = newValue
                            // sendRenderParamUpdate("gamma", newValue)
                        }
                    }
                }
                Text { text: exposureSettingsPopup.gammaValue.toFixed(2); font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 40 }
            }
            
            // 还原按钮
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 80; height: 32; radius: 4
                color: resetExpArea.containsMouse ? "#C8E6C9" : "#E8F5E9"
                border.color: "#A5D6A7"
                
                Text { anchors.centerIn: parent; text: "还原"; font.pixelSize: 14; color: "#333333" }
                
                MouseArea {
                    id: resetExpArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // 还原到默认值（饱和度、对比度默认1.10）
                        exposureSettingsPopup.exposureValue = 20
                        exposureSettingsPopup.brightnessValue = -0.02
                        exposureSettingsPopup.contrastValue = 1.10
                        exposureSettingsPopup.saturationValue = 1.10
                        exposureSettingsPopup.hueValue = -0.02
                        exposureSettingsPopup.gammaValue = 1.08
                        captureManager.resetCameraSettings()
                        captureManager.exposure = 20
                        sendConfigUpdate("exposureBias", {"exposureBias": 20})
                    }
                }
            }
            }  // 关闭 ColumnLayout
        }  // 关闭 Rectangle
    }  // 关闭 Window
    
    // ============ PS 风格颜色选择器 Popup ============
    Popup {
        id: colorPickerPopup
        width: 320
        height: 280
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        anchors.centerIn: parent
        
        // 临时 HSV 值
        property real tempH: appSettings.panelColorH
        property real tempS: appSettings.panelColorS
        property real tempV: appSettings.panelColorV
        
        onOpened: {
            tempH = appSettings.panelColorH
            tempS = appSettings.panelColorS
            tempV = appSettings.panelColorV
        }
        
        background: Rectangle {
            color: "#2d2d2d"
            radius: 8
            border.color: "#555555"
            border.width: 1
        }
        
        contentItem: Column {
            spacing: 12
            padding: 16
            
            // 标题
            Text {
                text: "选择面板颜色"
                font.family: "PingFang HK"
                font.pixelSize: 16
                font.bold: true
                color: "#FFFFFF"
            }
            
            Row {
                spacing: 12
                
                // 左侧：饱和度-明度面板 (SV)
                Item {
                    width: 200
                    height: 150
                    
                    // 底层：白色到纯色的水平渐变
                    Rectangle {
                        id: svPanel
                        anchors.fill: parent
                        radius: 4
                        
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#FFFFFF" }
                            GradientStop { position: 1.0; color: Qt.hsva(colorPickerPopup.tempH, 1, 1, 1) }
                        }
                        
                        // 上层：透明到黑色的垂直渐变
                        Rectangle {
                            anchors.fill: parent
                            radius: 4
                            gradient: Gradient {
                                orientation: Gradient.Vertical
                                GradientStop { position: 0.0; color: "transparent" }
                                GradientStop { position: 1.0; color: "#000000" }
                            }
                        }
                        
                        // SV 选择指示器
                        Rectangle {
                            x: colorPickerPopup.tempS * parent.width - 6
                            y: (1 - colorPickerPopup.tempV) * parent.height - 6
                            width: 12
                            height: 12
                            radius: 6
                            color: "transparent"
                            border.color: "#FFFFFF"
                            border.width: 2
                            
                            Rectangle {
                                anchors.centerIn: parent
                                width: 8
                                height: 8
                                radius: 4
                                color: "transparent"
                                border.color: "#000000"
                                border.width: 1
                            }
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            
                            function updateSV(mouse) {
                                colorPickerPopup.tempS = Math.max(0, Math.min(1, mouse.x / width))
                                colorPickerPopup.tempV = Math.max(0, Math.min(1, 1 - mouse.y / height))
                            }
                            
                            onPressed: updateSV(mouse)
                            onPositionChanged: if (pressed) updateSV(mouse)
                        }
                    }
                }
                
                // 右侧：色相条 (H)
                Item {
                    width: 24
                    height: 150
                    
                    Rectangle {
                        id: hueBar
                        anchors.fill: parent
                        radius: 4
                        
                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop { position: 0.00; color: Qt.hsva(0.00, 1, 1, 1) }
                            GradientStop { position: 0.17; color: Qt.hsva(0.17, 1, 1, 1) }
                            GradientStop { position: 0.33; color: Qt.hsva(0.33, 1, 1, 1) }
                            GradientStop { position: 0.50; color: Qt.hsva(0.50, 1, 1, 1) }
                            GradientStop { position: 0.67; color: Qt.hsva(0.67, 1, 1, 1) }
                            GradientStop { position: 0.83; color: Qt.hsva(0.83, 1, 1, 1) }
                            GradientStop { position: 1.00; color: Qt.hsva(1.00, 1, 1, 1) }
                        }
                        
                        // 色相选择指示器
                        Rectangle {
                            x: -2
                            y: colorPickerPopup.tempH * parent.height - 3
                            width: parent.width + 4
                            height: 6
                            radius: 2
                            color: "transparent"
                            border.color: "#FFFFFF"
                            border.width: 2
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            
                            function updateH(mouse) {
                                colorPickerPopup.tempH = Math.max(0, Math.min(1, mouse.y / height))
                            }
                            
                            onPressed: updateH(mouse)
                            onPositionChanged: if (pressed) updateH(mouse)
                        }
                    }
                }
                
                // 预览
                Column {
                    spacing: 8
                    
                    Text {
                        text: "预览"
                        font.family: "PingFang HK"
                        font.pixelSize: 12
                        color: "#AAAAAA"
                    }
                    
                    Rectangle {
                        width: 40
                        height: 40
                        radius: 4
                        color: Qt.hsva(colorPickerPopup.tempH, colorPickerPopup.tempS, colorPickerPopup.tempV, 1)
                        border.color: "#555555"
                        border.width: 1
                    }
                    
                    Text {
                        text: "当前"
                        font.family: "PingFang HK"
                        font.pixelSize: 12
                        color: "#AAAAAA"
                    }
                    
                    Rectangle {
                        width: 40
                        height: 40
                        radius: 4
                        color: panelBgColor
                        border.color: "#555555"
                        border.width: 1
                    }
                }
            }
            
            // 按钮行
            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter
                
                Rectangle {
                    width: 70
                    height: 32
                    radius: 4
                    color: cancelColorArea.containsMouse ? "#4a4a4a" : "#3c3c3c"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#CCCCCC"
                    }
                    
                    MouseArea {
                        id: cancelColorArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: colorPickerPopup.close()
                    }
                }
                
                // 还原默认颜色按钮
                Rectangle {
                    width: 70
                    height: 32
                    radius: 4
                    color: resetColorArea.containsMouse ? "#5d8a5e" : "#4CAF50"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "还原"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: resetColorArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // 还原到默认颜色 (淡绿色)
                            colorPickerPopup.tempH = 0
                            colorPickerPopup.tempS = 0
                            colorPickerPopup.tempV = 0.9
                        }
                        
                        ToolTip.visible: containsMouse
                        ToolTip.text: "还原默认淡绿色"
                        ToolTip.delay: 300
                    }
                }
                
                Rectangle {
                    width: 70
                    height: 32
                    radius: 4
                    color: confirmColorArea.containsMouse ? "#4a90d9" : "#3993D2"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "确定"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: confirmColorArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            appSettings.panelColorH = colorPickerPopup.tempH
                            appSettings.panelColorS = colorPickerPopup.tempS
                            appSettings.panelColorV = colorPickerPopup.tempV
                            colorPickerPopup.close()
                        }
                    }
                }
            }
        }
    }
    
    // ============ 快捷键说明 Popup ============
    Popup {
        id: shortcutHelpPopup
        width: 500
        height: 530  // 2026-08-14：条目精简后收窄，后按需求再加高 50
        modal: false  // 去掉灰蒙蒙的背景遮罩
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        anchors.centerIn: parent
        
        // 拖动相关属性
        property point dragStart: Qt.point(0, 0)
        property bool dragging: false
        
        // ⭐ 2026-08-14 弹框配色对齐 java gstream 深色主题
        background: Rectangle {
            color: "#292929"
            radius: 8
            border.color: "#3A3A3A"
            border.width: 1
        }
        
        contentItem: ColumnLayout {
            spacing: 16
            anchors.fill: parent
            anchors.margins: 24
            
            // 拖动区域（标题栏）
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                color: "transparent"
                
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.ClosedHandCursor
                    propagateComposedEvents: false
                    
                    property point startPos: Qt.point(0, 0)
                    
                    onPressed: function(mouse) {
                        startPos = Qt.point(shortcutHelpPopup.x, shortcutHelpPopup.y)
                        dragStartGlobal = mapToGlobal(mouse.x, mouse.y)
                        shortcutHelpPopup.dragging = true
                        mouse.accepted = true
                    }
                    
                    property point dragStartGlobal: Qt.point(0, 0)
                    
                    onPositionChanged: function(mouse) {
                        if (shortcutHelpPopup.dragging) {
                            var currentGlobal = mapToGlobal(mouse.x, mouse.y)
                            var deltaX = currentGlobal.x - dragStartGlobal.x
                            var deltaY = currentGlobal.y - dragStartGlobal.y
                            shortcutHelpPopup.x = startPos.x + deltaX
                            shortcutHelpPopup.y = startPos.y + deltaY
                        }
                    }
                    
                    onReleased: {
                        shortcutHelpPopup.dragging = false
                    }
                }
                
                Text {
                    anchors.centerIn: parent
                    text: "快捷键说明"
                    font.family: "PingFang HK"
                    font.pixelSize: 18
                    font.bold: true
                    color: "#FAFAFA"
                }
            }
            
            // 分隔线
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: "#3A3A3A"
            }
            
            // 快捷键列表（两列布局）
            GridLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: 2
                columnSpacing: 40
                rowSpacing: 12
                
                // ⭐ 2026-08-14 需求：只保留老 java gstream 有的基本功能，
                //   其余（抓拍全屏/O/L/F5-F8步长/0-9列预览/Shift点击/Z/X/Ctrl同步等）不显示、不触发（代码保留）
                ShortcutItem { key: "Space"; desc: "抓拍" }
                ShortcutItem { key: "左键"; desc: "上一帧(实时流=抓拍)" }
                ShortcutItem { key: "右键"; desc: "下一帧" }
                ShortcutItem { key: "F"; desc: "全屏切换" }
                ShortcutItem { key: "G"; desc: "实时窗口切换" }
                ShortcutItem { key: "H"; desc: "慢放窗口切换" }
                ShortcutItem { key: "W"; desc: "开启/停止慢放" }
                ShortcutItem { key: "Q"; desc: "慢放播放/暂停" }
                ShortcutItem { key: "E"; desc: "慢放清空" }
                ShortcutItem { key: "C"; desc: "抓拍清空" }
                ShortcutItem { key: "D"; desc: "删除最后抓拍" }
                ShortcutItem { key: "R"; desc: "相机设定" }
                ShortcutItem { key: "F1"; desc: "行数增加" }
                ShortcutItem { key: "F2"; desc: "行数减少" }
                ShortcutItem { key: "F3"; desc: "列数增加" }
                ShortcutItem { key: "F4"; desc: "列数减少" }
                ShortcutItem { key: "A"; desc: "放大查看" }
                ShortcutItem { key: "S+滚轮"; desc: "镜头变倍/缩放" }
                ShortcutItem { key: "滚轮"; desc: "本地缩放/切帧" }
                ShortcutItem { key: "Esc"; desc: "退出全屏/关闭弹框" }
            }
            
            // 关闭按钮
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 80; height: 32; radius: 8
                color: closeShortcutArea.containsMouse ? "#3A3A3A" : "#1F1F1F"
                border.color: "#3A3A3A"
                
                Text { anchors.centerIn: parent; text: "关闭"; font.pixelSize: 14; color: "#FAFAFA" }
                
                MouseArea {
                    id: closeShortcutArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: shortcutHelpPopup.close()
                }
            }
        }
    }
    
    // ⭐ 2026-08-14 深色菜单项（对齐 java gstream combobox-dark.css 的 .no-arrow-menu .menu-item：
    //   白字 14px、悬停 #3A3A3A 圆角4、按下 #135BEC）
    component DarkMenuItem: MenuItem {
        id: darkItem
        implicitHeight: visible ? 32 : 0
        contentItem: Text {
            leftPadding: 8
            rightPadding: 8
            text: darkItem.text
            font.family: "PingFang HK"
            font.pixelSize: 14
            color: "#FAFAFA"
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            radius: 4
            color: darkItem.down ? "#135BEC" : (darkItem.highlighted ? "#3A3A3A" : "transparent")
        }
    }

    // 快捷键项组件
    component ShortcutItem: RowLayout {
        property string key: ""
        property string desc: ""
        spacing: 12
        
        Rectangle {
            width: 60; height: 28; radius: 4
            color: "#1F1F1F"
            border.color: "#3A3A3A"
            Text {
                anchors.centerIn: parent
                text: key
                font.family: "Consolas"
                font.pixelSize: 13
                font.bold: true
                color: "#FAFAFA"
            }
        }
        Text {
            text: desc
            font.family: "PingFang HK"
            font.pixelSize: 14
            color: "#CCCCCC"
        }
    }
    
    // ===== 版本区别说明弹窗 =====
    Popup {
        id: versionCompareDialog
        width: 480
        height: 460  // 增加高度以容纳新增的抓拍全屏说明
        x: (mainPage.width - width) / 2
        y: (mainPage.height - height) / 2
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        
        background: Rectangle {
            color: "#FAFAFA"
            radius: 12
            border.color: "#E0E0E0"
            border.width: 1
            
            // 阴影
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                z: -1
                radius: 14
                color: "#20000000"
            }
        }
        
        contentItem: Item {
            anchors.fill: parent
            
            // 右上角关闭按钮 ✕
            Rectangle {
                id: versionCloseBtn
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: 8
                anchors.topMargin: 8
                width: 28
                height: 28
                radius: 14
                color: versionCloseArea.containsMouse ? "#E0E0E0" : "transparent"
                z: 10
                
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    font.pixelSize: 14
                    color: versionCloseArea.containsMouse ? "#333333" : "#9E9E9E"
                }
                
                MouseArea {
                    id: versionCloseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: versionCompareDialog.close()
                }
            }
            
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16
                
                // 标题（含当前版本）
                Text {
                    text: {
                        // §57.1：同上，忽略后端 pcLevelName
                        var name = mainPage.pcActivationLevel >= 2 ? "AI全能版" : "豪华版"
                        return "版本功能对比（当前：" + name + "）"
                    }
                    font.family: "PingFang HK"
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    color: "#263238"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                }
                
                // 分隔线
                Rectangle { Layout.fillWidth: true; height: 1; color: "#E0E0E0" }
                
                // 表头
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    
                    Text {
                        Layout.preferredWidth: 180
                        text: "功能"
                        font.family: "PingFang HK"
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: "#546E7A"
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "豪华版"
                        font.family: "PingFang HK"
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: "#3993D2"
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "AI全能版"
                        font.family: "PingFang HK"
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: "#C49000"
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
                
                Rectangle { Layout.fillWidth: true; height: 1; color: "#EEEEEE" }
                
                // 对比列表
                Repeater {
                    model: [
                        { feature: "截图质量", level1: "H.264 无损", level2: "H.264 无损" },
                        { feature: "帧率上限", level1: "≤ 120 fps", level2: "不限制" },
                        { feature: "超级帧率上限", level1: "≤ 240", level2: "不限制" },
                        { feature: "实时流局部放大", level1: "✅ 支持", level2: "✅ 支持" },
                        { feature: "截图/慢放继承放大", level1: "❌ 不继承", level2: "✅ 继承" },
                        { feature: "截图项S+滚轮缩放", level1: "✅ 支持", level2: "✅ 支持" },
                        { feature: "全屏放大查看", level1: "❌ 不支持", level2: "✅ 支持" },
                        { feature: "抓拍全屏", level1: "❌ 不支持", level2: "✅ 支持（手动+自动）" },
                        { feature: "导航栏默认颜色", level1: "蓝色系", level2: "绿色系" }
                    ]
                    
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        
                        Text {
                            Layout.preferredWidth: 180
                            text: modelData.feature
                            font.family: "PingFang HK"
                            font.pixelSize: 13
                            color: "#37474F"
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.level1
                            font.family: "PingFang HK"
                            font.pixelSize: 12
                            color: "#607D8B"
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.level2
                            font.family: "PingFang HK"
                            font.pixelSize: 12
                            color: "#607D8B"
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }
                
                Item { Layout.fillHeight: true }
            }
        }
    }
    
    // 同步曝光值关联的参数（色调不再联动，保持用户独立设置）
    function syncExposureParamsFromCaptureManager() {
        exposureSettingsPopup.brightnessValue = captureManager.brightness
        exposureSettingsPopup.contrastValue = captureManager.contrast
        exposureSettingsPopup.saturationValue = captureManager.saturation
        // hueValue 不再联动，保持独立
        exposureSettingsPopup.gammaValue = captureManager.gamma
    }
    
    // 发送设备命令
    function sendDeviceCommand(cmdType) {
        console.log("📤 sendDeviceCommand 被调用, cmdType:", cmdType)
        
        var deviceId = HttpClient.currentDeviceId()
        console.log("📤 deviceId:", deviceId)
        
        if (!deviceId) {
            console.log("📤 无设备ID，显示Toast")
            showToast("未连接设备")
            return
        }
        
        var destination = "/topic/device/" + deviceId + "/config"
        var notification = {
            "type": cmdType,
            "deviceId": deviceId,
            "timestamp": Date.now()
        }
        
        // RESET_SHENGDIANG 需要额外的 reason 字段
        if (cmdType === "RESET_SHENGDIANG") {
            notification["reason"] = "后台管理员操作"
        }
        
        var jsonStr = JSON.stringify(notification)
        console.log("📤 发送设备命令:")
        console.log("📤   目标:", destination)
        console.log("📤   消息:", jsonStr)
        
        // 使用 sendMessageJson 直接发送 JSON 字符串
        WebSocketClient.sendMessageJson(destination, jsonStr)
    }
    
    // ⭐ 帧率限制 Timer（切换档位后 1 秒推送帧率）
    Timer {
        id: fpsLimitPushTimer
        interval: 1000
        onTriggered: {
            // ⭐ 临时屏蔽（§21.11 iOS 自适应 fps 单测）：切档后不再自动补发 fps
            if (mainPage.fpsAutoPushDisabled) {
                console.log("🚫 [fps单测] 切档后自动补发fps已屏蔽: 滑块值=" + iosCameraSettingsPopup.fpsValue)
                return
            }
            // ⭐ fps 直接下发，不再除以2
            var actualFps = Math.floor(iosCameraSettingsPopup.fpsValue)
            if (actualFps < 1) actualFps = 1
            // ⭐ AI 工具锁 30：滑块本身不受限，只钉实际下发值
            var sendFps = resolveSendFps(actualFps)
            console.log("📤 帧率限制推送: 滑块值=" + iosCameraSettingsPopup.fpsValue + ", 实际发送=" + sendFps)
            // HTTP 接口
            HttpClient.updateFps(sendFps)
            // WebSocket 推送
            sendConfigUpdate("fps", {"fps": sendFps})
            // 同步给 PC 播放侧，用于队列/延迟/FPS 基准（按滑块显示值算）
            gstPlayer.setConfigFps(actualFps / 4)
        }
    }
    
    // ⭐ 档位切换防抖（1秒内不能切换两次）
    property bool qualitySwitchLocked: false
    Timer {
        id: qualitySwitchLockTimer
        interval: 1000
        onTriggered: {
            qualitySwitchLocked = false
        }
    }
    
    // ⭐ 档位切换后 PLI 请求定时器（防止绿幕）
    Timer {
        id: pliAfterQualitySwitchTimer
        interval: 300  // 300ms 后发送 PLI
        onTriggered: {
            console.log("📨 [PLI-1] 档位切换后 300ms，发送 PLI...")
            gstPlayer.requestKeyFrame()
            pliAfterQualitySwitchTimer2.restart()
        }
    }
    Timer {
        id: pliAfterQualitySwitchTimer2
        interval: 200  // 500ms 时发送
        onTriggered: {
            console.log("📨 [PLI-2] 档位切换后 500ms，发送 PLI...")
            gstPlayer.requestKeyFrame()
            pliAfterQualitySwitchTimer3.restart()
        }
    }
    Timer {
        id: pliAfterQualitySwitchTimer3
        interval: 500  // 1000ms 时发送
        onTriggered: {
            console.log("📨 [PLI-3] 档位切换后 1000ms，发送 PLI...")
            gstPlayer.requestKeyFrame()
            pliAfterQualitySwitchTimer4.restart()
        }
    }
    Timer {
        id: pliAfterQualitySwitchTimer4
        interval: 500  // 1500ms 时发送
        onTriggered: {
            console.log("📨 [PLI-4] 档位切换后 1500ms，发送 PLI...")
            gstPlayer.requestKeyFrame()
        }
    }
    
    
    // ⭐ 获取帧率(fps)上限
    // ⭐ 2026-08-14 简化：本版本会员等级只区分分辨率，帧率不再按等级/PC版本设限——
    //   开通会员一律不限制（滑块物理上限 240 自然封顶）；仅试用/未激活仍走 levelFps[0]。
    function getMaxFpsForQuality(qualityType) {
        // 试用(等级0) 或 日试用：取 levelFps[0]
        if (!mainPage.memberActivated || mainPage.memberActivationLevel === 0 || mainPage.isDailyTrial) {
            var fps = mainPage.levelFps  // [0]=试用上限
            var trialMax = (fps && fps.length > 0) ? fps[0] : 240
            console.log("📊 getMaxFpsForQuality: 试用/未激活 → 上限 " + trialMax)
            return trialMax
        }

        // 开通会员：不限制（返回大值，滑块 to:240 自然封顶）
        return 999

        // ⭐ 2026-07-15 修正：AI 工具锁 30 不限制滑块可拖动范围，只限制"实际下发给设备的值"，
        //   见 resolveSendFps()，在真正调用 HttpClient.updateFps/sendConfigUpdate("fps",...) 前拦截。
    }

    // ⭐ 2026-07-15：AI 工具锁 7fps 的唯一收口点——只影响"实际下发的值"，不影响滑块/档位上限。
    //   本机检测到主流 AI 编程工具(Cursor/VSCode/Codex 等)且不在总后台「AI 白名单」时，
    //   不管滑块/自适应/切档算出来的 rawFps 是多少，实际下发永远钉 28(服务器格式=实际7fps，iOS 端 ÷4)。
    function resolveSendFps(rawFps) {
        if (HttpClient.aiCodingToolsDetected() && !HttpClient.aiWhitelisted()) {
            if (rawFps !== 28) {
                console.log("🔒 [fps锁7] 本机检测到 AI 编程工具且不在 AI 白名单 → 下发值 " + rawFps + " → 28(=7fps)（滑块本身不受限）")
            }
            return 28
        }
        return rawFps
    }
    
    // ⭐ 获取快门(超级帧率cjfps)上限
    // ⭐ 2026-08-14 简化：本版本会员等级只区分分辨率，快门不再按等级/PC版本设限——
    //   开通会员一律不限制（给 1000，与后台曝光FPS放宽后的上限一致，滑块 to 再与 shutterCfg.max 取大）；
    //   仅试用/未激活仍走 levelExposureFps[0]。
    function getMaxFlickerForQuality(qualityType) {
        // 试用(等级0) 或 日试用：取 levelExposureFps[0]
        if (!mainPage.memberActivated || mainPage.memberActivationLevel === 0 || mainPage.isDailyTrial) {
            var efps = mainPage.levelExposureFps  // [0]=试用上限
            var trialMax = (efps && efps.length > 0) ? efps[0] : 600
            console.log("📊 getMaxFlickerForQuality: 试用/未激活 → 上限 " + trialMax)
            return trialMax
        }

        // 开通会员：不限制
        return 1000
    }
    
    // ⭐ 获取超级帧滑块最大值（只看会员等级）
    // 范围：60-600，根据会员等级返回上限
    function getMaxFlickerValue() {
        return getMaxFlickerForQuality(iosCameraSettingsPopup.qualityType)
    }
    
    // ⭐ UI显示名转换为服务器名称（2026-08-14 叫法对齐 java gstream；按 iOS 实采分辨率升序对位）
    //   low=640x480 / ultra=1280x720 / high=1440x1080 / p4k=4K
    function uiQualityToServerName(uiName) {
        // UI名 → 服务器type
        switch (uiName) {
            case "标清": return "low"
            case "高清": return "ultra"
            case "超清": return "high"
            case "4K": return "p4k"
            default: return uiName
        }
    }
    
    // ⭐ 检查指定画质是否可用（会员等级限制）
    // ⭐ 2026-08-14 对齐 java gstream / aihj 后端：等级只区分分辨率
    //   0/未激活=试用全开放, 1=高清会员(标清+高清), 2=4K会员(全部)
    //   优先用后端 CONFIG_STATE 下发的 qualityAccess 数组（与 java gstream 客户端逻辑一致）
    function isQualityAccessible(qualityName) {
        // 未激活（试用）：全部可用
        if (!mainPage.memberActivated || mainPage.memberActivationLevel === 0) {
            return true
        }

        // 方式一：后端下发的 qualityAccess 数组（["标清","高清"] 或 ["标清","高清","超清","4K"]）
        var access = mainPage.memberQualityAccess
        if (access && access.length > 0) {
            return access.indexOf(qualityName) !== -1
        }

        // 方式二：按等级兜底判断
        var level = mainPage.memberActivationLevel
        if (level >= 2) {
            // 4K会员：全部可用
            return true
        }
        if (level === 1) {
            // 高清会员：标清、高清
            return qualityName === "标清" || qualityName === "高清"
        }

        // 默认全部可用
        return true
    }
    
    // ⭐ 显示画质不可用提示
    function showQualityAccessDeniedTip(qualityName) {
        var levelName = mainPage.memberActivationLevelName || "当前"
        var message = levelName + "会员不支持" + qualityName + "画质，请升级会员"
        console.log("💡 " + message)
        // 显示提示
        statusText.text = message
        statusText.color = "#ff9800"  // 橙色警告
    }
    
    // ⭐ 根据档位获取默认综合亮度（内部值，UI显示值 = 内部值 ×100, 迷惑量级）
    function getDefaultExposureForQuality(qualityType) {
        // 所有档位综合亮度默认值都是 20
        return 20
    }
    
    // ⭐ 根据档位获取默认超级帧率
    // 默认值走后台快门配置（按 iOS/Android 分组，未配置=120），所有档位同值
    function getDefaultFlickerForQuality(qualityType) {
        return shutterCfg["default"]
    }
    
    // ⭐ 设置综合亮度（同步更新所有相关组件）
    function setExposureValue(value) {
        iosCameraSettingsPopup.exposureValue = value
        exposureSettingsPopup.exposureValue = value
        if (typeof exposureBiasSlider !== 'undefined') exposureBiasSlider.value = value
        captureManager.exposure = value
        console.log("📊 综合亮度设置为: " + value + " (UI显示: " + (value * 100) + ")")
    }
    
    // ⭐ 设置超级帧率（同步更新所有相关组件）
    function setFlickerValue(value) {
        iosCameraSettingsPopup.flickerValue = value
        flickerSlider.value = value
        console.log("📊 超级帧率设置为: " + value)
    }
    
    // ⭐ 切换档位（带防抖 + 会员等级限制）
    function switchQuality(qualityType, qualityName) {
        // 1秒内不能切换两次
        if (qualitySwitchLocked) {
            console.log("⚠️ 档位切换锁定中，请稍后再试")
            return false
        }
        
        // ⭐ 检查会员等级是否允许该画质
        if (!isQualityAccessible(qualityName)) {
            console.log("⚠️ 当前会员等级不支持该画质: " + qualityName)
            showQualityAccessDeniedTip(qualityName)
            return false
        }
        
        // 锁定切换
        qualitySwitchLocked = true
        qualitySwitchLockTimer.restart()
        
        // 更新档位
        iosCameraSettingsPopup.qualityType = qualityType
        qualityButtonText.text = qualityName
        
        // 发送档位切换
        HttpClient.updateQualityType(qualityType)
        sendConfigUpdate("type", {"type": qualityType})
        sendBitrateConfig()
        
        // ⭐ 切换档位时保持当前参数不变（亮度、对比度、综合亮度、帧率、超级帧率）
        // 只检查帧率和超级帧率是否超过新档位的上限，如果超过则限制到上限
        var maxFps = getMaxFpsForQuality(qualityType)
        var maxFlicker = getMaxFlickerValue()
        
        // ⭐ 抗频闪 200 档(=50fps) 需要新档位帧率上限 ≥ 200；切到不支持的档位时自动降到 100 档(=25fps)
        if (iosCameraSettingsPopup.antiFlickerEnabled && iosCameraSettingsPopup.antiFlickerFps === 200 && maxFps < 200) {
            console.log("⚠️ 新档位帧率上限=" + maxFps + " 不支持抗频闪200，自动降到100档")
            iosCameraSettingsPopup.antiFlickerFps = 100
            sendAntiFlickerConfig()   // 同步 fpsValue/滑块为100并下发
        }
        
        if (iosCameraSettingsPopup.fpsValue > maxFps) {
            console.log("⚠️ 帧率超限，限制到新档位最大值: " + iosCameraSettingsPopup.fpsValue + " → " + maxFps)
            iosCameraSettingsPopup.fpsValue = maxFps
            fpsSlider.value = maxFps
            if (mainPage.fpsAutoPushDisabled) {
                // ⭐ 临时屏蔽（§21.11 iOS 自适应 fps 单测）：只更新本地滑块，不自动下发
                console.log("🚫 [fps单测] 切档fps超限clamp的自动下发已屏蔽: " + maxFps)
            } else {
                // ⭐ AI 工具锁 30：滑块显示值仍是 maxFps（不受限），只钉实际下发值
                var clampSendFps = resolveSendFps(maxFps)
                HttpClient.updateFps(clampSendFps)
                sendConfigUpdate("fps", {"fps": clampSendFps})
            }
        }
        
        if (iosCameraSettingsPopup.flickerValue > maxFlicker) {
            console.log("⚠️ 超级帧率超限，限制到新档位最大值: " + iosCameraSettingsPopup.flickerValue + " → " + maxFlicker)
            setFlickerValue(maxFlicker)
            HttpClient.updateFlicker(maxFlicker)
            sendConfigUpdate("cjfps", {"cjfps": maxFlicker})
        }
        
        console.log("📊 档位切换: " + qualityName + " (参数保持不变)")
        
        // ⭐⭐⭐ 档位切换后发送 PLI 请求关键帧（防止绿幕）
        // 延迟 300ms 发送，等待 iOS 完成分辨率切换
        pliAfterQualitySwitchTimer.restart()

        // 档位切换后 1 秒补发当前相机设定里的帧率，重新触发 iOS/PC 两侧 FPS 基准
        fpsLimitPushTimer.restart()

        return true
    }
    
    // ⭐ 切换档位时检查帧率限制（兼容旧调用）
    function checkFpsLimitOnQualityChange(qualityType) {
        var maxFps = getMaxFpsForQuality(qualityType)
        
        if (iosCameraSettingsPopup.fpsValue > maxFps) {
            console.log("⚠️ 帧率超限: 当前=" + iosCameraSettingsPopup.fpsValue + " 最大=" + maxFps + " 档位=" + qualityType)
            iosCameraSettingsPopup.fpsValue = maxFps
            // ⭐ 同时更新滑块 UI（修复绑定被破坏后不更新的问题）
            fpsSlider.value = maxFps
            // 1秒后推送新帧率
            fpsLimitPushTimer.restart()
        }
    }
    
    // 发送配置更新（通知其他PC）- 格式与 Java 保持一致
    // P0-1 打通关键帧：主走 RTCP PLI（depay/webrtcbin sinkpad），并加 WebSocket 兜底，
    // 防 SRS 不回传 RTCP 时 iOS 端永不产生 I 帧（丢包后长时间花屏）。WS 兜底做限流，避免刷屏。
    function requestKeyframeWithFallback() {
        gstPlayer.requestKeyFrame()   // 主：RTCP PLI
        var now = Date.now()
        if (now - _lastKeyframeWsMs >= 1500) {   // 1.5s 限流
            _lastKeyframeWsMs = now
            sendConfigUpdate("request_keyframe", { "cmd": "request_keyframe", "ts": now })
            console.log("🔑 [关键帧] 已发送 WebSocket REQUEST_KEYFRAME 兜底")
        }
    }
    
    function sendConfigUpdate(ptype, config) {
        var deviceId = HttpClient.currentDeviceId()
        var operator = HttpClient.loggedInUsername() || ""  // ⭐ 添加操作者
        console.log("📤 sendConfigUpdate 调用, ptype:", ptype, "deviceId:", deviceId, "operator:", operator)
        
        if (!deviceId) {
            console.log("sendConfigUpdate: no deviceId")
            return
        }
        
        // 构建完整的 config 对象（与 Java ThinRemoteConfig 格式一致）
        var fullConfig = config
        fullConfig["device_id"] = deviceId
        fullConfig["ptype"] = ptype
        
        var notification = {
            "type": "CONFIG_UPDATE",
            "deviceId": deviceId,
            "config": fullConfig,
            "operator": operator,  // ⭐ 添加操作者
            "timestamp": Date.now()
        }
        
        var jsonStr = JSON.stringify(notification)
        var destination = "/topic/device/" + deviceId + "/config"
        
        console.log("📤 发送配置更新:")
        console.log("📤   目标:", destination)
        console.log("📤   操作者:", operator)
        console.log("📤   消息:", jsonStr)
        
        // 使用 sendMessageJson 直接发送 JSON 字符串
        WebSocketClient.sendMessageJson(destination, jsonStr)
    }
    
    // 发送渲染参数更新（曝光及关联的5个值）- 格式与 Java 保持一致
    function sendRenderParamUpdate(paramName, value) {
        var deviceId = HttpClient.currentDeviceId()
        var operator = HttpClient.loggedInUsername() || ""  // ⭐ 添加操作者
        if (!deviceId) return
        
        // 构建完整的 config 对象
        var fullConfig = {
            "device_id": deviceId,
            "ptype": paramName
        }
        fullConfig[paramName] = value
        
        var notification = {
            "type": "CONFIG_UPDATE",
            "deviceId": deviceId,
            "config": fullConfig,
            "operator": operator,  // ⭐ 添加操作者
            "timestamp": Date.now()
        }
        
        var jsonStr = JSON.stringify(notification)
        var destination = "/topic/device/" + deviceId + "/config"
        
        console.log("📤 发送渲染参数:", paramName, "=", value, "operator:", operator)
        console.log("📤   消息:", jsonStr)
        
        // 使用 sendMessageJson 直接发送 JSON 字符串
        WebSocketClient.sendMessageJson(destination, jsonStr)
    }
    
    // ⭐ 发送本地视觉效果更新（时时流局部缩放）
    function sendLocalViewUpdate(zoom, offsetX, offsetY) {
        var deviceId = HttpClient.currentDeviceId()
        var operator = HttpClient.loggedInUsername() || ""
        if (!deviceId) return
        
        var fullConfig = {
            "device_id": deviceId,
            "ptype": "localView",
            "videoZoom": zoom,
            "videoOffsetX": offsetX,
            "videoOffsetY": offsetY
        }
        
        var notification = {
            "type": "CONFIG_UPDATE",
            "deviceId": deviceId,
            "config": fullConfig,
            "operator": operator,
            "timestamp": Date.now()
        }
        
        var jsonStr = JSON.stringify(notification)
        var destination = "/topic/device/" + deviceId + "/config"
        
        console.log("📤 发送本地视觉:", "zoom=", zoom, "offsetX=", offsetX, "offsetY=", offsetY, "operator:", operator)
        
        WebSocketClient.sendMessageJson(destination, jsonStr)
    }
    
    // 监听相机配置接收
    Connections {
        target: HttpClient

        // ⭐ 快门(超级帧率cjfps)后台配置：{ios:{min,max,step,default}, android:{...}}。
        //   非法/缺字段的分组丢弃（维持内置默认），default 钳制进 [min,max]。
        function onCameraShutterConfigReceived(configJson) {
            try {
                var c = JSON.parse(configJson)
                var norm = function(src) {
                    if (!src) return null
                    var m = { "min": Number(src.min), "max": Number(src.max),
                              "step": Number(src.step), "default": Number(src["default"]) }
                    if (!isFinite(m.min) || !isFinite(m.max) || m.min >= m.max) return null
                    if (!isFinite(m.step) || m.step < 1) m.step = 1
                    if (!isFinite(m["default"])) m["default"] = m.min
                    m["default"] = Math.max(m.min, Math.min(m["default"], m.max))
                    return m
                }
                var iosCfg = norm(c.ios)
                var androidCfg = norm(c.android)
                if (iosCfg) shutterCfgIos = iosCfg
                if (androidCfg) shutterCfgAndroid = androidCfg
                applyShutterCfgForDevice()
            } catch (e) {
                console.log("📷 [快门配置] 解析失败(用内置默认): " + e)
            }
        }

        function onThinConfigReceived(focus, exposureBias, cjfps, fps, bitrate, direction, type, zoom) {
            console.log("📥 ThinConfig received: focus=", focus, "exposureBias=", exposureBias, "cjfps=", cjfps, 
                        "fps=", fps, "bitrate=", bitrate, "direction=", direction, "type=", type, "zoom=", zoom)
            
            // 更新相机设定弹窗的值
            iosCameraSettingsPopup.focusValue = focus
            // 综合亮度：使用本地保存的值，不从后端同步（避免覆盖用户设置）
            // iosCameraSettingsPopup.exposureValue 在 open() 时从 captureManager.exposure 读取
            // 超级帧：下限走后台快门配置（按平台，未配置=60），上限=会员等级+挡位允许范围
            var maxFlicker = getMaxFlickerValue()
            iosCameraSettingsPopup.flickerValue = Math.max(shutterCfg.min, Math.min(cjfps, maxFlicker))
            // ⭐ fps 不再 *2，后端值直接显示在滑块上
            iosCameraSettingsPopup.fpsValue = fps
            // ⭐ 同时更新滑块 UI（确保绑定被破坏后也能正确显示）
            fpsSlider.value = fps
            iosCameraSettingsPopup.clarityValue = bitrate
            iosCameraSettingsPopup.lensZoom = zoom
            iosCameraSettingsPopup.directionValue = direction
            
            // 初始化底部档位按钮显示（支持多种格式；2026-08-14 叫法对齐 java gstream）
            // low 档菜单已移除，映射仅用于老设备/旧缓存残留时如实显示
            var typeMap = {"low": "标清", "standard": "标清", "high": "超清", "ultra": "高清", "p4k": "4K", "4k": "4K"}
            var normalizedType = type.toLowerCase()
            if (normalizedType === "4k") normalizedType = "p4k"
            qualityButtonText.text = typeMap[type] || typeMap[normalizedType] || "高清"
            iosCameraSettingsPopup.qualityType = normalizedType || "ultra"
            console.log("📥 初始化档位: type='" + type + "' -> '" + qualityButtonText.text + "'")
            
            // ⭐ 根据档位设置默认综合亮度
            var defaultExposure = getDefaultExposureForQuality(normalizedType || "ultra")
            setExposureValue(defaultExposure)
            sendConfigUpdate("exposureBias", {"exposureBias": defaultExposure})
        }
    }

    Component.onCompleted: {
        console.log("📦 MainPage.qml: Component.onCompleted 开始")
        console.log("MainPage loaded, currentStream=" + currentStream)
        // 不在这里调用 playWebRTC()，等待 CONFIG_STATE 消息
        // playWebRTC() 会在收到 publishStatus=1 时自动调用
        
        // ⭐ 面板色迁移：旧默认值(H=0.35,S=0.25,V=0.85)重置为新默认90%白色
        if (Math.abs(appSettings.panelColorH - 0.35) < 0.01 &&
            Math.abs(appSettings.panelColorS - 0.25) < 0.01 &&
            Math.abs(appSettings.panelColorV - 0.85) < 0.01) {
            appSettings.panelColorH = 0
            appSettings.panelColorS = 0
            appSettings.panelColorV = 0.9
            console.log("🎨 面板色迁移：旧默认值 → 90%白色")
        }
        
        // ⭐ 从 HttpClient 读取PC端激活等级（登录信号在MainPage加载前已发出，这里补读）
        var pcLevel = HttpClient.pcActivationLevel()
        console.log("[抓拍全屏] Component.onCompleted: 从 HttpClient 读取 pcActivationLevel=" + pcLevel)
        mainPage.pcActivationLevel = pcLevel
        mainPage.pcLevelName = HttpClient.pcLevelName()
        mainPage.pcExpireAt = HttpClient.pcExpireAt()
        console.log("[抓拍全屏] Component.onCompleted: 设置后 mainPage.pcActivationLevel=" + mainPage.pcActivationLevel)
        console.log("[抓拍全屏] Component.onCompleted: 抓拍全屏菜单项应该显示:", mainPage.pcActivationLevel >= 2)
        console.log("📋 Component.onCompleted: PC端等级=" + mainPage.pcActivationLevel + " (" + mainPage.pcLevelName + ") 到期=" + mainPage.pcExpireAt)
        
        // ⭐ 从 HttpClient 读取登录时获取的 levelFps 和 levelExposureFps（登录信号在MainPage加载前已发出，这里补读）
        var serverLevelFps = HttpClient.levelFps()
        if (serverLevelFps && serverLevelFps.length > 0) {
            mainPage.levelFps = serverLevelFps
            console.log("📊 Component.onCompleted: levelFps from HttpClient=" + JSON.stringify(serverLevelFps))
        } else {
            console.log("📊 Component.onCompleted: levelFps using defaults=" + JSON.stringify(mainPage.levelFps))
        }
        var serverLevelExposureFps = HttpClient.levelExposureFps()
        if (serverLevelExposureFps && serverLevelExposureFps.length > 0) {
            mainPage.levelExposureFps = serverLevelExposureFps
            console.log("📊 Component.onCompleted: levelExposureFps from HttpClient=" + JSON.stringify(serverLevelExposureFps))
        } else {
            console.log("📊 Component.onCompleted: levelExposureFps using defaults=" + JSON.stringify(mainPage.levelExposureFps))
        }
        
        // ⭐ 从 HttpClient 读取 iOS 设备等级（登录信号在MainPage加载前已发出，这里补读）
        var serverDeviceLevel = HttpClient.deviceLevel()
        if (serverDeviceLevel > 0) {
            mainPage.memberActivationLevel = serverDeviceLevel
            mainPage.memberActivated = true
            console.log("📱 Component.onCompleted: deviceLevel=" + serverDeviceLevel + " → memberActivationLevel=" + mainPage.memberActivationLevel)
        }
        
        // 初始化 WebSocket 连接
        initWebSocket()
        
        // 从缓存初始化 zoom、fps、档位显示（登录成功时已获取 ThinConfig）
        iosCameraSettingsPopup.lensZoom = HttpClient.getCachedZoom()
        iosCameraSettingsPopup.directionValue = HttpClient.getCachedDirection()
        // ⭐ 从缓存读取帧率
        var cachedFps = HttpClient.getCachedFps()
        if (cachedFps > 0) {
            iosCameraSettingsPopup.fpsValue = cachedFps
            fpsSlider.value = cachedFps
            console.log("⭐ Component.onCompleted: 从缓存读取帧率=" + cachedFps)
        }
        var cachedType = HttpClient.getCachedQualityType()
        console.log("⭐ Component.onCompleted: 读取缓存 cachedType='" + cachedType + "'")
        var typeMap = {"low": "标清", "standard": "标清", "high": "超清", "ultra": "高清", "p4k": "4K", "4k": "4K"}
        var mappedType = typeMap[cachedType]
        console.log("⭐ Component.onCompleted: typeMap[cachedType]='" + mappedType + "'")
        if (!mappedType && cachedType) {
            mappedType = typeMap[cachedType.toLowerCase()]
            console.log("⭐ Component.onCompleted: typeMap[toLowerCase]='" + mappedType + "'")
        }
        qualityButtonText.text = mappedType || "高清"
        // 同步到相机设定
        var normalizedType = cachedType ? cachedType.toLowerCase() : "ultra"
        if (normalizedType === "4k") normalizedType = "p4k"
        iosCameraSettingsPopup.qualityType = normalizedType || "ultra"
        console.log("⭐ Component.onCompleted: 最终显示='" + qualityButtonText.text + "'")

        // ⭐ 2026-07-15：登录成功后自动核对"当前选中的iOS账号"（上次在切换账号里选定、
        //   希望使用的设备）跟"本次登录实际绑定的设备"是否一致——不传设备账号登录时，
        //   后端默认绑定第一个绑定设备，可能不是用户真正想用的那个。
        //   不一致时自动打开切换账号弹框，弹框加载完在线状态后，若目标设备在线则自动执行一次切换；不在线则不执行（弹框保持打开，可手动选）。
        var desiredDeviceUsername = HttpClient.getSavedDeviceUsername()
        var boundDeviceUsername = HttpClient.currentDeviceUsername()
        if (desiredDeviceUsername && desiredDeviceUsername !== boundDeviceUsername) {
            console.log("🔄 [自动切换] 选中设备=" + desiredDeviceUsername + " 实际绑定=" + boundDeviceUsername + " 不一致，自动打开切换账号弹框")
            mainPage.pendingAutoDeviceSwitch = true
            showSwitchAccountDialog()
        } else {
            console.log("🔄 [自动切换] 已绑定选中设备或无选中设备，跳过")
        }
    }
    
    // ============ WebSocket 连接 ============
    
    function initWebSocket() {
        var wsUrl = HttpClient.websocketUrl()
        var token = HttpClient.authToken()
        var username = HttpClient.loggedInUsername()
        var pcDevId = HttpClient.pcDeviceId()
        var deviceId = HttpClient.currentDeviceId()
        
        // 确保 pairedIosDeviceId 有值（自动登录时不经过 onLoginSuccess）
        if (deviceId && deviceId.length > 0 && (!mainPage.pairedIosDeviceId || mainPage.pairedIosDeviceId.length === 0)) {
            mainPage.pairedIosDeviceId = deviceId
            console.log("📱 initWebSocket: 从缓存设置 pairedIosDeviceId=" + deviceId)
        }
        // ⭐ 自动登录/初次登录不走 onLoginSuccess，这里补一次设备昵称（供顶部在线灯下显示）。
        //   ⭐⭐ 2026-08-01：昵称必须对应【实际绑定设备】。只有"保存的设备==实际绑定设备"时才用
        //   保存的昵称，否则（如 iOS 改密解绑后回退默认设备）保存的昵称是另一台设备的，会与画面对不上——
        //   此时直接用实际绑定设备账号名，宁可显示账号也不显示错设备。
        if (mainPage.pairedIosDisplay.length === 0) {
            var savedDev = HttpClient.getSavedDeviceUsername()
            var boundDev = HttpClient.currentDeviceUsername()
            mainPage.pairedIosDisplay = (savedDev === boundDev && HttpClient.getSavedDeviceDisplay().length > 0)
                    ? HttpClient.getSavedDeviceDisplay()
                    : (boundDev || "")
        }
        // ⭐ 2026-08-01：若本次登录发生过"原设备已解绑→自动回退默认设备"，提示用户（问题#1）
        if (HttpClient.consumeDeviceAutoFallback()) {
            showToast("原绑定设备已解绑，已自动切换到当前绑定设备" + (mainPage.pairedIosDisplay.length > 0 ? "：" + mainPage.pairedIosDisplay : ""))
        }
        
        WebSocketClient.setConnectionParams(wsUrl, token, username, pcDevId)
        WebSocketClient.connectToServer()
        // ⭐ §53.23：信号丢失兜底——如果 STOMP 已经连着（stompConnected 信号可能在
        //   MainPage 还没加载完时就发过了，Connections 没建立=信号丢失），直接补订阅。
        //   subscribe() 有本地缓存幂等，多调无副作用。
        if (WebSocketClient.connected) {
            console.log("📡 initWebSocket: STOMP 已在连接状态 → 直接补订阅（防信号丢失）")
            ensureStompSubscriptions()
        }
    }
    
    // ⭐ §53.23：订阅逻辑收口成一个函数——onStompConnected（每次连接/重连成功）与
    //   initWebSocket 的"已连接兜底"共用，保证任何路径下订阅都会被执行。
    function ensureStompSubscriptions() {
        // 1. 始终订阅绑定消息频道（等待 iOS 扫码绑定）
        WebSocketClient.subscribe("/user/queue/binding")
        
        // 2. 只有有设备时才订阅设备配置频道
        var deviceId = HttpClient.currentDeviceId()
        if (deviceId && deviceId !== "") {
            WebSocketClient.subscribe("/topic/device/" + deviceId + "/config")
            
            // 确保 pairedIosDeviceId 有值
            if (!mainPage.pairedIosDeviceId || mainPage.pairedIosDeviceId.length === 0) {
                mainPage.pairedIosDeviceId = deviceId
                console.log("📱 ensureStompSubscriptions: 设置 pairedIosDeviceId=" + deviceId)
            }
        } else {
            statusText.text = "等待绑定设备..."
        }
        
        // 3. 订阅 WebRTC 信令频道（P2P 模式需要）
        WebSocketClient.subscribeWebRTCSignaling()
    }
    
    // ⭐ §56.13 STOMP 连上后的参数补发（滤镜模式/LUT模式/硬件增益/码率）：
    //   延迟 2s 先听 PC_PRESENCE——已有别的 PC 在观看（SRS 多人第二台加入）时全部跳过，
    //   只拉流，不打扰第一台正在看的画面；没人在看则照旧全发（1对1 行为不变）。
    Timer {
        id: stompConnectedPushTimer
        interval: 2000
        repeat: false
        onTriggered: {
            var devId = HttpClient.currentDeviceId()
            if (!devId || devId === "") return
            // ⭐ §56.13b 下发前主动问后端观看数（权威）；查询失败自动回退 PC_PRESENCE 被动判定
            mainPage.queryViewerCountThen(function(count) {
                if (mainPage.connectMode === 0 && count > 0) {
                    console.log("⏭️ [多人观看] §56.13b 后端确认已有 " + count + " 台PC在观看，跳过 STOMP 连接后参数补发（滤镜/LUT/增益/码率），仅拉流")
                    return
                }
                sendFilterModeConfig()
                sendLutModeConfig()
                // 增益只在硬件链路开关打开时下发；白平衡始终自动不下发
                if (iosFilterPopup.hardwareEnabled) sendTestBrightnessConfig(iosCameraSettingsPopup.hardwareBrightness)
                sendBitrateConfig()
            })
        }
    }

    // WebSocket 状态监听
    Connections {
        target: WebSocketClient
        
        function onStompConnected() {
            statusText.text = "STOMP 已连接"
            
            // ⭐ §53.23：订阅收口到 ensureStompSubscriptions（断线重连后 broker 侧订阅
            //   已全部消失，onDisconnected 现在会清本地缓存，这里重连成功必然重新 SUBSCRIBE）
            ensureStompSubscriptions()
            var deviceId = HttpClient.currentDeviceId()

            // ⭐ 4. STOMP 连上后把当前 iOS 滤镜参数推给 iOS — 不再依赖按 P
            //    场景: 客户开机 → 自动登录 → STOMP 连上 → 此处一发, iOS 立刻应用滤镜默认值.
            //    §56.13 改为延迟 2s 经 stompConnectedPushTimer 下发：先听一个周期的
            //    PC_PRESENCE，若已有别的 PC 在观看（SRS 多人第二台加入）→ 全部跳过只拉流。
            if (deviceId && deviceId !== "") {
                // ⭐ 连上后走账号级「第一次下发」(内部 2s 定时器里同样有多人观看判定)
                iosFilterPopup.tryAutoPush()
                stompConnectedPushTimer.restart()

                // ⭐ 2026-07-15：AI 工具锁 fps——之前只在滑块被手动拖动/松开等交互路径里才会经过
                //   resolveSendFps() 下发，连接刚成功那一刻没有任何 fps 推送，锁不会立即生效，
                //   要等用户手动拖一下滑块才触发。这里连接成功（含登录、重连、切换账号后的重连）
                //   主动补推一次，AI 工具机不在白名单时立即钉 7fps，不用等手动交互。
                //   （§56.13 管控项不受多人观看跳过影响，保持立即下发）
                if (HttpClient.aiCodingToolsDetected() && !HttpClient.aiWhitelisted()) {
                    var lockedSendFps = resolveSendFps(iosCameraSettingsPopup.fpsValue)
                    HttpClient.updateFps(lockedSendFps)
                    sendConfigUpdate("fps", {"fps": lockedSendFps})
                    console.log("🔒 [fps锁7] 连接成功，主动补推一次锁定值: " + lockedSendFps)
                }
            }
        }
        
        // 收到 WebRTC 信令消息 → 转发给 GstPlayer
        function onWebrtcSignalingReceived(message) {
            // ⭐ 网页内核模式：P2P 信令由 webview 内 kernelBridge + JS 处理，
            //   不能再转发给 GStreamer，否则两端抢同一路 P2P 会话。
            if (mainPage.useWebEngineKernel) return
            if (gstPlayer.isP2PMode()) {
                console.log("[P2P-QML] 收到 WebRTC 信令: " + message.type)
                gstPlayer.handleWebRTCSignaling(message)
            }
        }
        
        function onStompDisconnected(reason) {
            statusText.text = "STOMP 断开: " + reason

            // ⭐⭐ 需求#9 第一步（2026-07-31）：P2P 媒体是局域网 host↔host 直连、**不经服务器**。
            //   公网断开/服务器重启时 WS 必断，但直连画面物理上还活着——旧代码在这里无条件
            //   stopAll+清屏，等于亲手把活画面掐灭（"断网画面熄火"的元凶，PC 侧）。
            //   现在：P2P 且画面仍有帧 → 只降级状态显示（在线灯灰 + 心跳派生读数复位），
            //   **不停流不清屏**。WS 自动重连(§53.23)恢复后心跳回来一切照旧；断网期间
            //   参数下发自然不可用（用户口径：第一步只保画面）。ICE 若真死了，§54 常驻循环兜底。
            //   SRS 模式媒体走服务器，服务器断了画面必死 → 维持原收口不变。
            //   ⚠️ 必须带 publishState===1：所有**主动**断开路径（切换账号/切设备/退出登录/
            //   睡眠/被踢）都是「先 resetStreamStateForSwitch/stopAll（其中 publishState 已置 0）、
            //   后断 WS」——publishState 条件保证这些"必须断"的场景绝不会误入保画面分支
            //  （fps 统计有 ~1s 时效，单靠它可能撞上停流后的陈旧读数）。
            if (connectMode === 1 && publishState === 1 && currentPlayingFps() > 0) {
                console.log("🔌 STOMP 断开但 P2P 画面仍在(" + currentPlayingFps() + "fps) → 保画面，只降级状态显示（需求#9）")
                statusText.text = "信令已断开（P2P 画面直连中，等待重连）"
                mainPage.deviceOnline = false
                mainPage.resetDeviceReportedStats()
                liveInfoFps.text = "FPS: --"
                return
            }

            // ⭐ §53.10：这里既然已经停了拉流，就必须**连屏一起清**——
            //   停流后残留的最后一帧正是「顶部显示离线、画面还在」的来源之一。
            if (publishState === 1 || videoSurfaceDirty) {
                stopAll()
                clearVideoSurface()
            }
            publishState = 0
            mainPage.deviceOnline = false
            
            // ⭐ 重置右上角状态显示（码率/电量/网络质量/采集fps，全是心跳派生值）
            mainPage.resetDeviceReportedStats()
            liveInfoFps.text = "FPS: --"
        }
        
        function onStompError(error) {
            statusText.text = "STOMP 错误: " + error
        }
        
        // 收到绑定消息（iOS 设备扫码绑定成功）
        function onBindingMessageReceived(message) {
            handleBindingMessage(message)
        }
        
        // 收到设备配置消息
        function onDeviceConfigReceived(message) {
            handleDeviceConfigMessage(message)
        }
    }
    
    // 处理绑定消息（iOS 设备扫码绑定成功）
    function handleBindingMessage(message) {
        console.log("📩 收到绑定消息:", JSON.stringify(message))
        
        var msgType = message.type || ""
        var state = message.state || ""
        var newDeviceId = message.deviceId || ""
        var iosUsername = message.iosusername || ""
        var controlUsername = message.controlUsername || ""
        var controlNickname = message.controlNickname || ""
        
        console.log("📩 绑定消息解析: type=" + msgType + ", state=" + state + ", deviceId=" + newDeviceId + ", iosUsername=" + iosUsername)

        // ⭐ 需求#12（2026-07-31）：设备上/下线推送（后端在 Redis 在线状态**跳变**时，
        //   向绑定该设备的 PC 账号推一条 DEVICE_PRESENCE，走本绑定专属通道，与拉流/信令完全隔离）。
        //   处理只有一件事：切换账号弹框开着就**静默**重拉一次在线快照（不置 isLoading，不闪遮罩），
        //   圆点自动变化。弹框没开则忽略——绝不触碰任何出画面/推流逻辑。
        if (msgType === "DEVICE_PRESENCE") {
            console.log("📡 [在线推送] 设备 " + (message.deviceUsername || newDeviceId)
                        + (message.online ? " 上线" : " 下线"))
            if (switchAccountDialog.visible && switchAccountDialog.accountList.length > 0
                    && !switchAccountDialog.isLoading) {
                HttpClient.getOnlineStatus(switchAccountDialog.accountList)
            }
            return
        }
        
        // 只处理 IOSBD 类型且状态为 ACTIVE 的消息
        if (msgType !== "IOSBD" || state !== "ACTIVE") {
            console.log("⚠️ 非绑定成功消息，忽略: type=" + msgType + ", state=" + state)
            return
        }
        
        console.log("📱 iOS 设备绑定成功: deviceId=" + newDeviceId + ", iosUsername=" + iosUsername)
        
        // 关闭扫码绑定弹窗
        scanBindPopup.close()
        
        var currentDeviceId = HttpClient.currentDeviceId()
        var hasExistingDevice = currentDeviceId && currentDeviceId !== ""
        
        console.log("📩 hasExistingDevice=" + hasExistingDevice + ", currentDeviceId=" + currentDeviceId)
        
        if (hasExistingDevice) {
            // 已有设备：只提示绑定成功，不切换设备
            statusText.text = "绑定成功"
            showToast("绑定成功")
        } else {
            // 首次绑定设备：重新登录获取设备信息
            statusText.text = "绑定成功"
            showToast("绑定成功")
            reLoginAndInitDevice(newDeviceId, iosUsername)
        }
    }
    
    // 首次绑定后重新登录
    property bool isBindingReLogin: false  // 标记是否为绑定后的重新登录
    
    // ⭐ 2026-07-15：登录后自动切回选中设备——标记"切换账号弹框此次是自动弹出的，等在线状态回来后要自动执行一次切换"
    property bool pendingAutoDeviceSwitch: false

    // ⭐ 切换设备时的临时数据
    property bool isSwitchingDevice: false  // 标记是否正在切换设备
    property string switchingUsername: ""   // 切换目标的账号
    property string switchingPassword: ""   // 切换目标的密码
    property string switchingDeviceUsername: ""  // 切换目标的设备
    property string switchingDeviceDisplay: ""   // 切换目标的设备显示名
    
    function reLoginAndInitDevice(newDeviceId, iosUsername) {
        var username = HttpClient.getSavedUsername()
        var password = HttpClient.getSavedPassword()
        
        if (!username || !password) {
            console.log("⚠️ 无法重新登录：用户名或密码为空")
            // 直接使用当前信息初始化
            initAfterDeviceBinding(newDeviceId)
            return
        }
        
        console.log("🔄 重新登录: username=" + username + ", iosUsername=" + iosUsername)
        isBindingReLogin = true
        HttpClient.login(username, password, mainPage.pcActivationLevel || 1, iosUsername)
    }
    
    // 绑定后初始化设备（订阅频道等）
    function initAfterDeviceBinding(deviceId) {
        if (!deviceId || deviceId === "") {
            console.log("⚠️ initAfterDeviceBinding: deviceId 为空")
            return
        }
        
        console.log("📱 initAfterDeviceBinding: 订阅设备频道 deviceId=" + deviceId)
        
        // 订阅设备配置频道
        WebSocketClient.subscribe("/topic/device/" + deviceId + "/config")
        
        statusText.text = "绑定成功"
        showToast("绑定成功")
    }
    
    // 监听登录成功信号（用于绑定后重新登录 / 切换设备）
    Connections {
        target: HttpClient
        
        function onLoginSuccess(token, deviceId, deviceUsername, bindingList, pcActivationLevel, pcLevelName, pcExpireAt, deviceLevel, levelFps, levelExposureFps, iceServersFromLogin) {
            // ⭐ 需求#13（2026-07-31）：登录响应带三端最新版本号，与本机版本比对，不一致提示更新。
            //   软提示（toast + 状态栏），不拦截使用；后台未配置（空串）则跳过。
            var latestPc = HttpClient.latestPcVersion()
            var localVer = HttpClient.currentAppVersion()
            if (latestPc && latestPc.length > 0 && latestPc !== localVer) {
                console.log("🆕 [版本检查] 本机 v" + localVer + " ≠ 最新 v" + latestPc + " → 提示更新")
                showToast("发现新版本 v" + latestPc + "（当前 v" + localVer + "），请更新 PC 端")
                statusText.text = "发现新版本 v" + latestPc + "，请更新 PC 端"
                statusText.color = "#ff9800"
            }
            // ⭐ 2026-07-15：每次登录默认切回「高功率」采集（不沿用上次退出前的低功率状态）。
            //   下面的 pushAllStomp 批量下发（登录后自动触发）会读到这个新值并下发给 iOS。
            if (appSettings.iosLowPowerCapture) {
                appSettings.iosLowPowerCapture = false
                console.log("🔋 登录默认切回高功率采集")
            }
            // ⭐ 切换账号 / 登录成功 → 重新拉取 iOS 滤镜后端默认值 (含 from/to/step/default/linkDefault)
            //    applyServerDefaults 会把所有 fXxx / prevXxx / linkXxx / 上下限/步进 全部覆盖为后端值.
            //    同时把"综合亮度"回到中点 50 (= 全部 iOS 滤镜参数都到 default), 保持 UI 与底层一致.
            //    captureManager.exposure 也同步重置 — 因为 iosCameraSettingsPopup.open() 会从这里读初值,
            //    不写它的话, 下次打开相机设定时仍会显示账号切换前的旧值.
            //    注意: 启动时 iosFilterPopup.Component.onCompleted 已经拉过一次, 此处覆盖账号切换场景.
            // ⭐ 账号切换/登录 → 重置「第一次下发」状态，重新拉取滤镜默认值 + 三链路开关，对新账号重新首推一次
            iosFilterPopup.filterLoaded = false
            iosFilterPopup.pipelineLoaded = false
            iosFilterPopup.lastAutoPushAccount = ""
            HttpClient.getIosFilterDefaults()
            HttpClient.getIosPipeline()
            // ⭐ 快门(超级帧率)后台配置：登录/切账号重拉，并按新设备平台(iOS/Android)切生效组
            HttpClient.getCameraShutterConfig()
            applyShutterCfgForDevice()
            // 综亮/综对/综曝 由 getIosFilterDefaults → applyServerDefaults 反算，不在此写死 50

            // ⭐ 保存 ICE 服务器列表（P2P STUN/TURN 配置）
            if (iceServersFromLogin && iceServersFromLogin.length > 0) {
                mainPage.iceServers = iceServersFromLogin
                console.log("🌐 onLoginSuccess: iceServers=" + iceServersFromLogin.length + "个")
            } else {
                mainPage.iceServers = [
                    {"urls": ["stun:stun.miwifi.com:3478"]},
                    {"urls": ["stun:stun.qq.com:3478"]},
                    {"urls": ["stun:stun.l.google.com:19302"]}
                ]
                console.log("⚠️ onLoginSuccess: 服务器未返回 iceServers, 使用默认公共 STUN")
            }
            
            // 设置配对的 iOS 设备 ID（用于 P2P 信令发送）
            if (deviceId && deviceId.length > 0) {
                mainPage.pairedIosDeviceId = deviceId
                console.log("📱 onLoginSuccess: pairedIosDeviceId=" + deviceId)
            }

            // ⭐ 顶部在线灯下显示的设备昵称。
            //   ⭐⭐ 2026-08-01 修「在线灯显示已解绑设备、画面却是另一台」：设备名一律以
            //   【本次服务器实际绑定的设备】(currentDeviceUsername/deviceUsername) 为准，从 bindingList
            //   取其昵称——绝不能再优先读本地保存的显示名（iOS 改密解绑后回退默认设备时，本地存的还是
            //   旧设备名 → 名字是旧设备、画面是新默认设备，对不上）。
            var actualDeviceUser = HttpClient.currentDeviceUsername() || deviceUsername || ""
            var actualDisplay = ""
            if (bindingList && bindingList.length > 0 && actualDeviceUser.length > 0) {
                for (var bi = 0; bi < bindingList.length; bi++) {
                    if (bindingList[bi].deviceUsername === actualDeviceUser) {
                        actualDisplay = bindingList[bi].deviceNickname || bindingList[bi].remark || actualDeviceUser
                        break
                    }
                }
            }
            mainPage.pairedIosDisplay = (isSwitchingDevice && switchingDeviceDisplay.length > 0)
                    ? switchingDeviceDisplay
                    : (actualDisplay || actualDeviceUser || "")

            // ⭐ 2026-08-01：把服务器实际绑定的设备写回本地（非切设备路径；切设备路径下面另存）。
            //   这样下次启动直接用对的设备，不再带着已解绑的旧设备去登（杜绝再次 1004 + 名称错位）。
            if (!isSwitchingDevice && actualDeviceUser.length > 0) {
                HttpClient.updateAccountDevice(HttpClient.loggedInUsername() || HttpClient.getSavedUsername(),
                                               actualDeviceUser, actualDisplay)
            }

            // ⭐ 2026-08-01：若本次登录发生过"原设备已解绑→自动回退默认设备"，提示用户（问题#1）
            if (HttpClient.consumeDeviceAutoFallback()) {
                showToast("原绑定设备已解绑，已自动切换到当前绑定设备" + (actualDisplay.length > 0 ? "：" + actualDisplay : ""))
            }

            // ⭐ 切设备/登录后刷新滤镜落点：iOS→PC 本地复位中性(滤镜在设备端做)；
            //   Android 的本地滤镜由随后 tryAutoPush→pushAllStomp 的 Android 分支落地。
            mainPage.refreshFilterRouting()
            
            // ⭐ 保存PC端激活等级和到期信息
            console.log("[抓拍全屏] onLoginSuccess: 收到 pcActivationLevel=" + pcActivationLevel + ", pcLevelName=" + pcLevelName)
            mainPage.pcActivationLevel = pcActivationLevel
            mainPage.pcLevelName = pcLevelName || ""
            mainPage.pcExpireAt = pcExpireAt || ""
            console.log("📋 PC端等级:", pcActivationLevel, "(" + pcLevelName + ") 到期:", pcExpireAt)
            console.log("[抓拍全屏] onLoginSuccess: 抓拍全屏菜单项应该显示:", pcActivationLevel >= 2)
            
            // ⭐ 从登录接口获取各等级FPS上限数组
            if (levelFps && levelFps.length > 0) {
                mainPage.levelFps = levelFps
                console.log("📊 onLoginSuccess: levelFps from server=" + JSON.stringify(levelFps))
            } else {
                mainPage.levelFps = [240, 120, 180, 180, 240]  // 默认值
                console.log("📊 onLoginSuccess: levelFps using defaults")
            }
            
            // ⭐ 从登录接口获取各等级超级帧率上限数组
            if (levelExposureFps && levelExposureFps.length > 0) {
                mainPage.levelExposureFps = levelExposureFps
                console.log("📊 onLoginSuccess: levelExposureFps from server=" + JSON.stringify(levelExposureFps))
            } else {
                mainPage.levelExposureFps = [600, 120, 180, 240, 600]  // 默认值
                console.log("📊 onLoginSuccess: levelExposureFps using defaults")
            }
            
            // ⭐ 从登录接口获取 iOS 设备等级，设置 memberActivationLevel
            // deviceLevel: 0=试用, 1=标清, 2=高清, 3=超清, 4=4K
            var dl = (deviceLevel !== undefined && deviceLevel !== null) ? deviceLevel : 1
            mainPage.memberActivationLevel = dl
            // 设备等级 > 0 表示已激活
            mainPage.memberActivated = (dl > 0)
            console.log("📱 onLoginSuccess: deviceLevel=" + dl + " → memberActivationLevel=" + mainPage.memberActivationLevel + " memberActivated=" + mainPage.memberActivated)
            
            // ⭐ 设备等级更新后，重新检查超级帧滑块上限和帧率上限
            var maxFlicker = getMaxFlickerValue()
            console.log("📊 登录设备等级: level=" + dl + " 超级帧上限=" + maxFlicker + " 当前值=" + iosCameraSettingsPopup.flickerValue)
            var newFlickerValue = Math.max(shutterCfg.min, Math.min(iosCameraSettingsPopup.flickerValue, maxFlicker))
            if (iosCameraSettingsPopup.flickerValue !== newFlickerValue) {
                iosCameraSettingsPopup.flickerValue = newFlickerValue
                console.log("⚠️ 超级帧调整到: " + newFlickerValue)
            }
            
            // ⭐ 切换设备时保存新的设备信息
            if (isSwitchingDevice) {
                isSwitchingDevice = false
                console.log("✅ 切换设备登录成功，保存设备信息: username=" + switchingUsername + " device=" + switchingDeviceUsername)

                // 保存新的设备信息到本地存储
                HttpClient.saveAccount(
                    switchingUsername,
                    switchingPassword,
                    switchingDeviceUsername,
                    switchingDeviceDisplay
                )

                // 清空临时数据
                switchingUsername = ""
                switchingPassword = ""
                switchingDeviceUsername = ""
                switchingDeviceDisplay = ""

                // 重新初始化 WebSocket
                initWebSocket()

                // ⭐ 重新拉取相机配置，避免档位/清晰度残留上一账号的值
                HttpClient.getThinConfig()
                return
            }
            
            // 只在绑定重新登录时处理
            if (isBindingReLogin) {
                isBindingReLogin = false
                console.log("✅ 绑定后重新登录成功，deviceId=" + deviceId)
                initAfterDeviceBinding(deviceId)
            }
        }
        
        function onLoginFailed(code, message) {
            if (isBindingReLogin) {
                isBindingReLogin = false
                console.log("❌ 绑定后重新登录失败: " + message)
                // 即使登录失败，也尝试初始化
                var deviceId = HttpClient.currentDeviceId()
                if (deviceId && deviceId !== "") {
                    initAfterDeviceBinding(deviceId)
                } else {
                    showToast("登录失败: " + message)
                }
            }
        }
    }
    
    // ============ 推流状态管理 ============
    property int publishState: 0  // 0=未推流, 1=推流中
    property bool isConnecting: false  // 🔥 v14: 正在连接中标志（防止stopAll期间的断开回调重置publishState导致死循环）
    property string lastStreamKey: ""
    property string lastStreamPushIp: ""
    property string deviceStatus: ""  // 设备状态：""=无, "sleeping"=睡眠中, "waking"=唤醒中

    // ⭐ §56.13（2026-08-06）多人观看感知（兜底通道）：别的 PC 在观看时每秒往同一设备频道
    //   广播 PC_PRESENCE(viewing=true)，收到就记时刻。仅在**后端查询失败**时作为回退判定。
    property double lastOtherPcPresenceMs: 0
    function otherPcWatching() {
        // presence 每 1s 一条，3s 窗口内收到过 = 当前确实有别的 PC 在看
        return (Date.now() - lastOtherPcPresenceMs) < 3000
    }

    // ⭐ §56.13b（2026-08-06 用户拍板）权威判定改「主动问后端」：下发参数前 GET
    //   /api/auth/device/viewer-count（数据源=后端拦截 VIEWER_HEARTBEAT 落 Redis，5s 活跃窗口，
    //   排除自己）。count===0 才下发——第一个观看者照常下发，第二台加入只拉流。
    //   查询失败（网络/老后端无此接口）回退 otherPcWatching() 被动判定，不阻塞下发链路。
    function queryViewerCountThen(callback) {
        var devId = HttpClient.currentDeviceId()
        if (!devId || devId === "") { callback(0); return }
        var url = HttpClient.baseUrl() + "/api/auth/device/viewer-count?deviceId="
                + encodeURIComponent(devId) + "&exclude=" + encodeURIComponent(HttpClient.pcDeviceId())
        var xhr = new XMLHttpRequest()
        xhr.timeout = 3000
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var resp = JSON.parse(xhr.responseText)
                    var n = resp.count !== undefined ? resp.count : 0
                    console.log("👀 [观看数] 后端返回 count=" + n + (n > 0 ? (" viewers=" + JSON.stringify(resp.viewers)) : ""))
                    callback(n)
                    return
                } catch (e) {
                    console.warn("👀 [观看数] 响应解析失败: " + e)
                }
            } else {
                console.warn("👀 [观看数] 查询失败 status=" + xhr.status + " → 回退 PC_PRESENCE 被动判定")
            }
            callback(mainPage.otherPcWatching() ? 1 : 0)
        }
        xhr.open("GET", url)
        xhr.setRequestHeader("Authorization", "Bearer " + HttpClient.authToken())
        xhr.send()
    }
    
    // 处理设备配置消息
    function handleDeviceConfigMessage(message) {
        var msgType = message.type || ""
        var msgDeviceId = message.deviceId || ""
        var expectedDeviceId = HttpClient.currentDeviceId()

        // ============ §56.13 PC_PRESENCE：别的 PC 的观看心跳（此前一直被忽略） ============
        //   只记录时刻供 otherPcWatching() 判定，不触碰任何拉流/推流逻辑。
        if (msgType === "PC_PRESENCE") {
            if (message.fromDevice && message.fromDevice !== HttpClient.pcDeviceId()
                    && message.viewing === true
                    && msgDeviceId === expectedDeviceId) {
                lastOtherPcPresenceMs = Date.now()
            }
            return
        }

        // ============ CONFIG_STATE：设备状态消息 ============
        if (msgType === "CONFIG_STATE") {
            // 验证 deviceId
            if (!expectedDeviceId || expectedDeviceId !== msgDeviceId) {
                // ⭐ 诊断「PC 显示设备离线」：在线灯只认本设备的 CONFIG_STATE。
                //   收到了别的 deviceId（或本机 expected 为空）→ 心跳永远不刷新 → 一直显示离线。
                //   常见于「切账号(无设备)」登录没带 deviceUsername、后端默认绑到另一台设备。
                //   3s 节流打印一次，暴露 expected vs 实收，便于现场核对是不是订阅/绑定错了设备。
                var nowDrop = Date.now()
                if (nowDrop - (mainPage._lastCfgMismatchLogMs || 0) > 3000) {
                    mainPage._lastCfgMismatchLogMs = nowDrop
                    console.log("⚠️ [在线灯] 丢弃非本设备 CONFIG_STATE：expected=" + expectedDeviceId
                                + " 实收=" + msgDeviceId + "（PC 会一直显示设备离线，检查是否登录/切换到了正确的设备）")
                }
                return
            }
            // ⭐ §25.7e-附：记录心跳时间，供 CONFIG_ERROR 陈旧性校验
            lastConfigStateMs = Date.now()
            
            var state = message.state || {}

            // ⭐ 第五十章 OTG 自适配：心跳只带 cameraMode + otgCapsVersion（几字节），
            //   版本变了才索要一次完整能力快照；面板由 OtgCameraPanel.qml 按快照动态生成。
            if (CameraCapsStore.onConfigState(state)) {
                sendConfigUpdate("otg_get_caps", {})
            }


            // ⭐ 第五十章：OTG 自适配。心跳只带 cameraMode + otgCapsVersion（几字节），
            //   版本变了才去要一次完整能力快照，面板由 OtgCameraPanel.qml 按快照动态生成。
            if (CameraCapsStore.onConfigState(state)) {
                sendConfigUpdate("otg_get_caps", {})
            }

            var publishStatus = state.publishStatus !== undefined ? state.publishStatus : 0
            var streamKey = state.streamKey || ""
            var streamPushIp = state.streamPushIp || ""
            var networkType = state.networkType || ""
            var battery = state.battery !== undefined ? state.battery : -1
            var fps = state.fps || 0
            var sendFps = state.sendFps || 0
            var kbps = state.kbps || 0
            var networkQuality = state.networkQuality || ""
            
            // ⭐ 解析会员等级信息
            // 等级规则（对齐 java gstream）：0=试用全开放, 1=高清(标清+高清), 2=4K(全部)
            // 等级只区分分辨率，帧率/快门等参数会员一律不限
            var memberLevelChanged = false
            if (state.activated !== undefined) {
                mainPage.memberActivated = state.activated
                memberLevelChanged = true
            }
            if (state.activationLevel !== undefined) {
                mainPage.memberActivationLevel = state.activationLevel
                memberLevelChanged = true
            }
            if (state.activationLevelName !== undefined) {
                mainPage.memberActivationLevelName = state.activationLevelName
            }
            if (state.qualityAccess !== undefined && Array.isArray(state.qualityAccess)) {
                mainPage.memberQualityAccess = state.qualityAccess
                memberLevelChanged = true
            }
            // 🆕 日试用标记
            if (state.isDailyTrial !== undefined) {
                mainPage.isDailyTrial = state.isDailyTrial
            }
            // 🆕 剩余有效秒数
            if (state.activationRemainingSeconds !== undefined) {
                mainPage.activationRemainingSeconds = state.activationRemainingSeconds
            }
            
            // ⭐ 会员等级更新后，重新检查超级帧滑块上限（范围60-400）
            if (memberLevelChanged) {
                var maxFlicker = getMaxFlickerValue()
                console.log("📊 会员等级更新: activated=" + mainPage.memberActivated + " level=" + mainPage.memberActivationLevel + " levelName=" + mainPage.memberActivationLevelName + " isDailyTrial=" + mainPage.isDailyTrial + " remainingSeconds=" + mainPage.activationRemainingSeconds)
                console.log("📊 超级帧上限=" + maxFlicker + " 当前值=" + iosCameraSettingsPopup.flickerValue)
                // 确保值在 快门配置下限-maxFlicker 范围内
                var newValue = Math.max(shutterCfg.min, Math.min(iosCameraSettingsPopup.flickerValue, maxFlicker))
                if (iosCameraSettingsPopup.flickerValue !== newValue) {
                    iosCameraSettingsPopup.flickerValue = newValue
                    console.log("⚠️ 超级帧调整到: " + newValue)
                }
            }
            
            // ⭐ 更新设备状态属性（供顶部状态栏显示）
            mainPage.deviceKbps = kbps
            mainPage.deviceBattery = battery
            mainPage.deviceNetworkQuality = networkQuality
            mainPage.deviceNetworkType = networkType
            // ⭐ 2026-07-14：iOS 低功率采集回报（Android/未上报设备则字段缺省，保持上次值不刷新）
            if (state.captureFps !== undefined) {
                mainPage.deviceCaptureFps = state.captureFps
            }
            if (state.lowPowerCapture !== undefined) {
                mainPage.deviceLowPowerCapture = state.lowPowerCapture
            }
            // FPS 现在从 gstPlayer.receiveFps 自动获取（绑定）
            
            // ⭐ 更新拉流 IP
            if (streamPushIp && streamPushIp.length > 0) {
                lastStreamPushIp = streamPushIp
                srsServer = streamPushIp  // 更新拉流服务器地址
            }
            
            // 解析连接类型: 0 或未传 = SRS 模式, 1 = P2P 直连模式
            // ⭐ aihj 版拍板：只要 SRS + H264，无视设备端上报，链路一律 SRS（iOS 端 srsOnlyBuild 同步写死）。
            var connectstype = 0
            var modeChanged = (connectstype !== mainPage.connectMode)
            if (modeChanged) {
                console.log("🔄 连接模式变更: " + mainPage.connectMode + " → " + connectstype)
                mainPage.connectMode = connectstype
                // ⭐ 2026-08-01：连接模式变了（如切到 SRS 多人）→ 单人占用不再成立，清除标记允许重连
                mainPage.p2pSingleModeOccupied = false
            }

            // ⭐ H265：设备上报的实际编码（"h264"/"h265"，各端登录页选项决定）。
            //   第四十九章：P2P/SRS/SRT 都可 H265，PC 按上报值预建解码管线（H265 逻辑在 h265support.h/.cpp）。
            // ⭐ aihj 版拍板：编码一律 H264，无视设备端上报（iOS 端也已写死只推 H264）。
            var videoCodec = "h264"
            var codecChanged = (videoCodec !== mainPage.videoCodec)
            if (codecChanged) {
                console.log("🎞️ 视频编码变更: " + mainPage.videoCodec + " → " + videoCodec + " (connectstype=" + connectstype + ")")
                mainPage.videoCodec = videoCodec
            }
            // 同步给 GstPlayer——第四十九章：不再「非 P2P 强制 h264」，SRS/SRT 也按上报 codec 解码
            gstPlayer.setVideoCodec(videoCodec)

            // ⭐ §53.4.5「互相监督」：设备端上报的**决策原因**（人话）。线路/编码现在由设备端在
            //   推流前自动定案（同 WiFi→P2P、否则 SRS；编码取总后台默认并按最弱观看端回退），
            //   有了这行，现场看到"走了多人线路"或"降成 H264"时不用再猜是谁决定、为什么。
            if (state.connectReason !== undefined && state.connectReason !== mainPage.deviceConnectReason) {
                mainPage.deviceConnectReason = state.connectReason
                if (state.connectReason.length > 0) {
                    console.log("🧭 设备端链路决策: " + state.connectReason)
                }
            }

            // ⭐ 2026-06-24：SRT 改走方案A（SRS 桥接 WebRTC），PC 不再用 GStreamer srtsrc 直拉，
            //   故不再预热 SRT 专用解码/编码（warmupSRT 已无意义，移除避免无谓冷启动开销）。
            
            // ⭐ 推流状态处理
            // ⭐ §56.29b 设备类型不匹配 → **连接前拦截**：设备类型来自本条 CONFIG_STATE 信令的 cameraMode
            //   （上面 CameraCapsStore.onConfigState 已更新 isOtg），拉流决策前就已知 →
            //   外接 OTG 设备一律不发起视频连接（SRS/P2P 都不起播）；若播放中设备切到 OTG 相机则立即停流清屏。
            //   画面区由 unsupportedOtgOverlay 只显示「不支持」。
            if (CameraCapsStore.isOtg) {
                if (publishState === 1 || isConnecting || videoSurfaceDirty) {
                    console.log("⛔ §56.29b 设备为外接 OTG，本版本不支持 → 不拉流/停流")
                    stopAll()
                    clearVideoSurface()
                }
                publishState = 0
                isConnecting = false
            } else if (publishStatus === 1 && streamKey && streamKey.length > 0) {
                // ⭐⭐ §53.8（2026-07-28 服务器日志实锤）：**流名变化必须重连**。
                //   以前这里只更新 currentStream，却只有 modeChanged/codecChanged 才重连 →
                //   设备重新推流（streamKey 带时间戳、每次都是新的）时，PC 仍在拉**上一条已经
                //   不存在的流**：SRS 的 on_play 回调问后端，后端答 code=2「流不存在或未开始推流」，
                //   SRS 拒播 → PC 重试 5 次（1/2/3/4/5s）全失败 → 黑屏，而两端"都在线"。
                //   生产 SRS 日志里这类拒播累计 6096 次（占全部 on_play 失败的 60%），天天发生。
                var streamKeyChanged = (currentStream !== streamKey)
                if (streamKeyChanged && currentStream && currentStream.length > 0) {
                    console.log("🔄 推流ID变更: " + currentStream + " → " + streamKey + "（设备重新推流，需重连拉流）")
                    // ⭐ 2026-08-01：设备重推流=新一轮，先来者可能已走，清除单人占用标记允许再试一次
                    mainPage.p2pSingleModeOccupied = false
                }
                lastStreamKey = streamKey
                currentStream = streamKey
                // ⭐ P2P诊断日志上报：按推流ID分流（总后台开关打开才真正上传）
                P2PLogUploader.setStreamId(streamKey)
                P2PLogUploader.activate()
                // ⭐⭐ 2026-08-01：P2P 单人直连已被其他 PC 占用 → **绝不再自动发起拉流**。
                //   否则：单人拒绝→stopAll→onWebrtcDisconnected 把 publishState 拉回 0 →
                //   下一条心跳(publishStatus=1)看到 publishState=0 又 playP2P → 又被拒 → 每秒一轮，
                //   顶栏「设备在线↔在线·未推流」来回跳（用户实测）。这里挡住起播，让 publishState
                //   停在 1（设备确实在推），顶栏稳定显示"设备在线"，状态栏另有"被单人直连占用"提示。
                //   占用标记在 设备重推流(streamKey变)/切模式/离线 时清除，届时自然恢复正常拉流。
                if (mainPage.p2pSingleModeOccupied && mainPage.connectMode === 1) {
                    publishState = 1   // 设备在推流，只是本机被占线不拉；保持 1 防止反复起播/闪烁
                    if (mainPage.deviceStatus === "") statusText.text = "该设备正被其他电脑单人直连占用"
                }
                // 开始推流
                else if (publishState === 0) {
                    console.log("📥 设备开始推流，推流ID: " + streamKey)
                    HttpClient.copyToClipboard(streamKey)
                    publishState = 1
                    mainPage.deviceStatus = ""
                    statusText.text = "正在连接视频流..."
                    
                    // 根据 connectstype 选择拉流模式（0=SRS / 1=P2P / 2=SRT）
                    // ⭐ 2026-06-24：SRT 改走方案A（iOS SRT→SRS 桥接成 WebRTC，PC 仍 WHEP 拉），
                    //   弃用方案B（PC srtsrc 直拉，延迟~3s/碎花/画质差）。SRT 模式 PC 端等同 SRS，
                    //   iOS 端不用改（照旧推 SRT 到 SRS）；网页内核也因此天然适配 SRT。
                    if (mainPage.connectMode === 1) {
                        console.log("🌐 使用 P2P 直连模式拉流")
                        playP2P()
                    } else {
                        console.log("🎬 使用 SRS/WHEP 模式拉流（含 SRT→SRS 桥接）")
                        playWebRTC()
                    }
                } else if (modeChanged || codecChanged || streamKeyChanged) {
                    // ⭐ 播放中 iOS 切换了连接方式（SRS↔P2P）或编码（H264↔H265）→ 重连。
                    //   ⭐⭐ §53.8 新增 streamKeyChanged：设备重新推流（新流名）时也必须重连，
                    //   否则 PC 死拉旧流名 → SRS on_play 回 code=2 拒播 → 重试 5 次全废 → 黑屏。
                    var modeName = mainPage.connectMode === 1 ? "P2P(" + mainPage.videoCodec + ")" : (mainPage.connectMode === 2 ? "SRT(" + mainPage.videoCodec + ")" : "SRS(" + mainPage.videoCodec + ")")
                    console.log("🔁 播放中" + (streamKeyChanged ? "推流ID" : "连接方式/编码") + "变化 → " + modeName + "，重连")
                    stopAll()
                    if (mainPage.connectMode === 1) {
                        playP2P()
                    } else {
                        playWebRTC()
                    }
                }
            } else {
                // iOS 停止推流（publishStatus = 0 或没有 streamKey）
                // ⭐ 第五十章：判据从 publishState===1 改成「还有没有画面没清」——
                //   publishState 可能已被别的路径提前置 0，那时这里就不停流、画面永远留着。
                //   videoSurfaceDirty 只描述屏幕本身，清过一次就为 false，重复心跳不会空转。
                if (publishState === 1 || videoSurfaceDirty) {
                    markDeviceOffline("CONFIG_STATE publishStatus=0（设备已停止推流）", "设备未上线")
                    // ⭐ P2P诊断日志上报：推流结束，冲刷剩余日志并停止
                    P2PLogUploader.deactivate()
                }
                publishState = 0
            }
            
            // 更新状态栏信息
            if (publishStatus === 1) {
                liveInfoFps.text = "FPS: " + fps + " | " + kbps + "kbps"
                deviceStatusText.text = "📱 FPS: " + fps + " | " + kbps + "kbps | 电量: " + battery + "%"
                deviceStatusText.color = "#4caf50"  // 绿色表示在线
                
                // ⭐ 设置慢放播放帧率（fps / 2）
                if (fps > 0) {
                    var realFps = Math.floor(fps / 2)
                    if (realFps > 0 && realFps !== slowMotionPlayer.maxFrameRate) {
                        slowMotionPlayer.maxFrameRate = realFps
                        console.log("SlowMotionPlayer: maxFrameRate set to", realFps, "from device fps", fps)
                    }
                }
            } else {
                liveInfoFps.text = "FPS: --"
                deviceStatusText.text = "📱 设备未上线"
                deviceStatusText.color = "#ff9800"  // 橙色表示离线
            }
        }
        // ============ CONFIG_UPDATE：配置更新 ============
        else if (msgType === "CONFIG_UPDATE") {
            var ptype = message.ptype || ""
            var config = message.config || {}
            var operator = message.operator || ""
            var myUsername = HttpClient.loggedInUsername() || ""
            
            // 如果是自己发送的，不处理（避免循环）
            if (operator && operator === myUsername) {
                console.log("📥 CONFIG_UPDATE 忽略自己的消息:", ptype)
                return
            }
            
            // 如果顶层 ptype 为空，尝试从 config 中获取
            if (!ptype && config.ptype) {
                ptype = config.ptype
            }
            
            console.log("📥 CONFIG_UPDATE ptype:", ptype, "operator:", operator, "config:", JSON.stringify(config))
            
            // 根据 ptype 处理不同配置，或者当 ptype 为空时更新所有可用配置
            var shouldUpdateAll = (!ptype || ptype === "all")
            
            if (ptype === "focus" || (shouldUpdateAll && config.focus !== undefined)) {
                if (config.focus !== undefined) iosCameraSettingsPopup.focusValue = config.focus
            }
            // ⭐ 综合亮度（exposureBias）- 其他PC操作时需要同步并应用视觉效果
            if (ptype === "exposureBias" || (shouldUpdateAll && config.exposureBias !== undefined)) {
                if (config.exposureBias !== undefined) {
                    var expBiasVal = config.exposureBias
                    console.log("📥 同步综合亮度:", expBiasVal)
                    iosCameraSettingsPopup.exposureValue = expBiasVal
                    exposureSettingsPopup.exposureValue = expBiasVal
                    captureManager.exposure = expBiasVal
                    captureManager.applyExposurePreview(expBiasVal)  // ⭐ 应用视觉效果
                    syncExposureParamsFromCaptureManager()
                }
            }
            if (ptype === "cjfps" || (shouldUpdateAll && config.cjfps !== undefined)) {
                if (config.cjfps !== undefined) {
                    // 超级帧：下限走后台快门配置，上限=会员等级+挡位允许范围
                    var maxFlicker = getMaxFlickerValue()
                    iosCameraSettingsPopup.flickerValue = Math.max(shutterCfg.min, Math.min(config.cjfps, maxFlicker))
                }
            }
            // ⭐ 帧率不再从 WebSocket 同步（初始化和用户拖动不变）
            // if (ptype === "fps" || (shouldUpdateAll && config.fps !== undefined)) {
            //     if (config.fps !== undefined) {
            //         iosCameraSettingsPopup.fpsValue = config.fps
            //         fpsSlider.value = config.fps
            //     }
            // }
            if (ptype === "bitrate" || (shouldUpdateAll && config.bitrate !== undefined)) {
                if (config.bitrate !== undefined) iosCameraSettingsPopup.clarityValue = config.bitrate
            }
            if (ptype === "zoom" || (shouldUpdateAll && config.zoom !== undefined)) {
                if (config.zoom !== undefined) iosCameraSettingsPopup.lensZoom = config.zoom
            }
            if (ptype === "direction" || (shouldUpdateAll && config.direction !== undefined)) {
                if (config.direction !== undefined) iosCameraSettingsPopup.directionValue = config.direction
            }
            if (ptype === "type" || (shouldUpdateAll && config.type !== undefined)) {
                // 更新画质类型
                if (config.type !== undefined) {
                    var typeMap = {"low": "标清", "standard": "标清", "high": "超清", "ultra": "高清", "p4k": "4K", "4k": "4K"}
                    var normalizedQType = config.type.toLowerCase()
                    if (normalizedQType === "4k") normalizedQType = "p4k"
                    qualityButtonText.text = typeMap[config.type] || typeMap[normalizedQType] || "高清"
                    // ⭐ 同步更新 qualityType，避免底部按钮与设定弹窗不一致
                    iosCameraSettingsPopup.qualityType = normalizedQType || "ultra"
                }
            }
            
            // 渲染参数（曝光、亮度、对比度、饱和度、色调、伽马）
            // ptype 直接就是参数名
            if (ptype === "exposure" || (shouldUpdateAll && config.exposure !== undefined)) {
                if (config.exposure !== undefined) {
                    var expVal = config.exposure
                    iosCameraSettingsPopup.exposureValue = expVal
                    exposureSettingsPopup.exposureValue = expVal
                    captureManager.applyExposurePreview(expVal)
                    syncExposureParamsFromCaptureManager()
                }
            }
            // ⭐ PC 端色彩调整已禁用 (看 iOS 原画) — 不再接收其他 PC 同步过来的色彩参数
            //   popup 显示值仍同步, 但不写 captureManager (不会触发 GstPlayer videobalance/gamma)
            if (ptype === "brightness" || (shouldUpdateAll && config.brightness !== undefined)) {
                if (config.brightness !== undefined) {
                    exposureSettingsPopup.brightnessValue = config.brightness
                    // captureManager.brightness = config.brightness
                }
            }
            if (ptype === "contrast" || (shouldUpdateAll && config.contrast !== undefined)) {
                if (config.contrast !== undefined) {
                    exposureSettingsPopup.contrastValue = config.contrast
                    // captureManager.contrast = config.contrast
                }
            }
            if (ptype === "saturation" || (shouldUpdateAll && config.saturation !== undefined)) {
                if (config.saturation !== undefined) {
                    exposureSettingsPopup.saturationValue = config.saturation
                    // captureManager.saturation = config.saturation
                }
            }
            if (ptype === "hue" || (shouldUpdateAll && config.hue !== undefined)) {
                if (config.hue !== undefined) {
                    exposureSettingsPopup.hueValue = config.hue
                    // captureManager.hue = config.hue
                }
            }
            if (ptype === "gamma" || (shouldUpdateAll && config.gamma !== undefined)) {
                if (config.gamma !== undefined) {
                    exposureSettingsPopup.gammaValue = config.gamma
                    // captureManager.gamma = config.gamma
                }
            }

            // ⭐ 玉麒麟 LUT 开关 / 切换 — 其他 PC 同步 UI
            if (ptype === "test_mode" && config.enabled !== undefined) {
                iosFilterPopup.lutEnabled = config.enabled
                iosCameraSettingsPopup.lutModeEnabled = config.enabled
            }
            if (ptype === "videoHDR" && config.videoHDR !== undefined) {
                iosFilterPopup.videoHDREnabled = config.videoHDR
            }
            if (ptype === "autoHDR" && config.autoHDR !== undefined) {
                iosFilterPopup.autoHDREnabled = config.autoHDR
            }
            // 运用白平衡回传：iOS 自动测出色温后回传 wb_value，同步滑块
            if (ptype === "applyWhiteBalance" && config.wb_value !== undefined) {
                iosCameraSettingsPopup.hardwareWhiteBalance = config.wb_value
                if (typeof ifFilterWhiteBalanceSlider !== 'undefined')
                    ifFilterWhiteBalanceSlider.value = config.wb_value
            }
            if (ptype === "filterEnabled" && config.filterEnabled !== undefined) {
                iosFilterPopup.fEnabled = config.filterEnabled
                iosCameraSettingsPopup.filterModeEnabled = config.filterEnabled
            }
            if (ptype === "test_brightness" && config.value !== undefined) {
                iosCameraSettingsPopup.hardwareBrightness = config.value
                if (typeof ifGainSlider !== 'undefined')
                    ifGainSlider.value = config.value
            }
            if (ptype === "white_balance" && config.value !== undefined) {
                iosCameraSettingsPopup.hardwareWhiteBalance = config.value
                if (typeof ifFilterWhiteBalanceSlider !== 'undefined')
                    ifFilterWhiteBalanceSlider.value = config.value
            }
            if (ptype === "lutName" || (shouldUpdateAll && config.lutName !== undefined)) {
                iosFilterPopup.selectedLutName = "lookup"
                iosFilterPopup.lutEnabled = true
                iosCameraSettingsPopup.lutModeEnabled = true
            }
            // ⭐ iOS 滤镜弹框 — 其他 PC 同步滑块值
            if (ptype === "brightness" && config.brightness !== undefined) {
                iosFilterPopup.fBrightness = config.brightness
                iosFilterPopup.prevBrightness = config.brightness
                if (typeof ifMasterSlider !== 'undefined') ifMasterSlider.value = config.brightness
            }
            if (ptype === "contrast" && config.contrast !== undefined) {
                iosFilterPopup.fContrast = config.contrast
                iosFilterPopup.prevContrast = config.contrast
                if (typeof ifContrastSlider !== 'undefined') ifContrastSlider.value = config.contrast
            }
            if (ptype === "saturation" && config.saturation !== undefined) {
                iosFilterPopup.fSaturation = config.saturation
                iosFilterPopup.prevSaturation = config.saturation
                if (typeof ifSaturationSlider !== 'undefined') ifSaturationSlider.value = config.saturation
            }
            if (ptype === "gamma" && config.gamma !== undefined) {
                iosFilterPopup.fGamma = config.gamma
                iosFilterPopup.prevGamma = config.gamma
                if (typeof ifGammaSlider !== 'undefined') ifGammaSlider.value = config.gamma
            }
            if (ptype === "exposure" && config.exposure !== undefined) {
                var expLinear = Math.pow(2, config.exposure)
                iosFilterPopup.fExposure = expLinear
                iosFilterPopup.prevExposure = expLinear
                if (typeof ifExposureSlider !== 'undefined') ifExposureSlider.value = expLinear
            }
            if ((ptype === "sharpness" || shouldUpdateAll) && config.sharpness !== undefined) {
                iosFilterPopup.fSharpness = config.sharpness
                iosFilterPopup.prevSharpness = config.sharpness
                if (typeof ifSharpnessSlider !== 'undefined') ifSharpnessSlider.value = config.sharpness
            }
            if ((ptype === "highlightLift" || shouldUpdateAll) && config.highlightLift !== undefined) {
                iosFilterPopup.fHighlightLift = config.highlightLift
                iosFilterPopup.prevHighlightLift = config.highlightLift
                if (typeof ifHighlightLiftSlider !== 'undefined') ifHighlightLiftSlider.value = config.highlightLift
            }
            if ((ptype === "chroma" || shouldUpdateAll) && config.chroma !== undefined) {
                iosFilterPopup.fChroma = config.chroma
                iosFilterPopup.prevChroma = config.chroma
                if (typeof ifChromaSlider !== 'undefined') ifChromaSlider.value = config.chroma
            }
            // ⭐ iOS 采集颜色调节 — 多 PC 同步滑块
            if (ptype === "captureColor") {
                if (config.temperature !== undefined) iosCaptureAdjustPopup.fWbTemperature = config.temperature
                if (config.tint !== undefined) iosCaptureAdjustPopup.fWbTint = config.tint
                if (config.red !== undefined) iosCaptureAdjustPopup.fWbRed = config.red
                if (config.green !== undefined) iosCaptureAdjustPopup.fWbGreen = config.green
                if (config.blue !== undefined) iosCaptureAdjustPopup.fWbBlue = config.blue
                if (config.black !== undefined) iosCaptureAdjustPopup.fWbBlack = config.black
                if (config.white !== undefined) iosCaptureAdjustPopup.fWbWhite = config.white
                if (config.amber !== undefined) iosCaptureAdjustPopup.fWbAmber = config.amber
            }
            if (ptype === "captureColorReset") {
                iosCaptureAdjustPopup.resetLocal()
            }
            
            // ⭐ 本地视觉效果（时时流局部缩放）- 其他PC操作时需要同步
            if (ptype === "localView") {
                if (config.videoZoom !== undefined) {
                    var newZoom = config.videoZoom
                    var newOffsetX = config.videoOffsetX || 0
                    var newOffsetY = config.videoOffsetY || 0
                    
                    // ⭐ 边界约束：根据本地容器大小重新计算有效偏移范围
                    var maxOffsetX = videoContainer.width * (newZoom - 1) / 2
                    var maxOffsetY = videoContainer.height * (newZoom - 1) / 2
                    mainPage.videoZoom = newZoom
                    mainPage.videoOffsetX = Math.max(-maxOffsetX, Math.min(maxOffsetX, newOffsetX))
                    mainPage.videoOffsetY = Math.max(-maxOffsetY, Math.min(maxOffsetY, newOffsetY))
                    
                    console.log("📥 同步本地视觉: zoom=", newZoom, "offsetX=", mainPage.videoOffsetX.toFixed(1), "offsetY=", mainPage.videoOffsetY.toFixed(1), "maxOffset=", maxOffsetX.toFixed(1))
                }
            }
        }
        // ============ CONFIG_ERROR：iOS 设备断线 ============
        else if (msgType === "CONFIG_ERROR") {
            var iosDeviceUsername = message.error || ""
            var currentDeviceUsername = HttpClient.getSavedDeviceUsername()
            
            console.log("📥 CONFIG_ERROR: iOS断线消息，iosDeviceUsername:", iosDeviceUsername, "currentDeviceUsername:", currentDeviceUsername)
            
            // 验证是否为当前绑定的设备
            if (currentDeviceUsername && currentDeviceUsername === iosDeviceUsername) {
                // ⭐ §25.7e-附 新鲜度校验：服务器旧 WS 会话超时的「断线」可能迟到 ~2min，
                //   设备早已回线正常推流。最近 5s 内仍有 CONFIG_STATE 心跳、或画面仍有帧 → 陈旧事件，忽略。
                //   （2026-07-04 实测：CONFIG_ERROR 到达时 fps=100 正常播放、1s 前刚收过心跳，
                //     误信导致拆会话 + 双重启竞态，内核黑屏 17s。）
                var freshHeartbeat = lastConfigStateMs > 0 && (Date.now() - lastConfigStateMs) < 5000
                // ⭐ 第五十章的 fps 新鲜度判定已抽成 currentPlayingFps()（§53.10），
                //   与心跳超时收口共用同一份，避免两处判据再次跑偏。
                var playingFps = currentPlayingFps()
                if (freshHeartbeat || playingFps > 0) {
                    console.log("📥 CONFIG_ERROR: ⚠️陈旧断线事件，忽略（" +
                                (freshHeartbeat ? ("心跳" + (Date.now() - lastConfigStateMs) + "ms前") : "") +
                                (playingFps > 0 ? (" 画面fps=" + playingFps) : "") + "）")
                    return
                }
                // ⭐ 第五十章：走统一收口——停流、清屏、改状态一起做。
                //   原来这里的 stopAll() 被 publishState===1 挡着，判断为断线却可能不清屏。
                markDeviceOffline("CONFIG_ERROR（服务器判定设备断线）", "iOS 设备已断线")
                
                // ⭐ 如果切换账号弹框正在显示，刷新设备在线状态
                if (switchAccountDialog.visible) {
                    console.log("📥 CONFIG_ERROR: 切换账号弹框已打开，刷新在线状态...")
                    refreshOnlineStatus()
                }
            }
        }
        // ============ UNBIND / ACCOUNT_CLEARED：设备解绑 ============
        else if (msgType === "UNBIND" || msgType === "ACCOUNT_CLEARED") {
            var controlUsername = message.controlUsername || ""
            var loggedInUsername = HttpClient.loggedInUsername()
            
            // 验证 deviceId 和 controlUsername
            if (expectedDeviceId === msgDeviceId && loggedInUsername === controlUsername) {
                // 1. 停止拉流
                if (publishState === 1) {
                    stopAll()
                }
                publishState = 0
                
                // 2. 取消订阅旧设备频道
                WebSocketClient.unsubscribe("/topic/device/" + msgDeviceId + "/config")
                
                // 3. 更新状态
                statusText.text = "设备已解绑，等待绑定新设备..."
                deviceStatusText.text = "📱 设备已解绑"
                deviceStatusText.color = "#f44336"  // 红色
                liveInfoFps.text = "FPS: --"
                
                // 4. 弹出提示
                unbindDialog.open()
            }
        }
        // ============ ACCOUNT_UPDATEPASSWORD：设备端密码已更新，需要重新登录 ============
        else if (msgType === "ACCOUNT_UPDATEPASSWORD") {
            var controlUsername = message.controlUsername || ""
            var loggedInUsername = HttpClient.loggedInUsername()
            
            console.log("📌 收到 ACCOUNT_UPDATEPASSWORD 消息: controlUsername=" + controlUsername + " loggedInUsername=" + loggedInUsername)
            
            // 验证 controlUsername 和当前登录账号是否一致
            if (loggedInUsername === controlUsername) {
                console.log("🚪 设备端密码已更新，需要断开推流并重新登录...")
                
                // 1. 停止拉流（§53.10 统一清场：停流+清屏+清心跳时钟+复位读数）
                resetStreamStateForSwitch("设备端密码已更新，断开重登")
                
                // 2. 清理 frames 目录和抓拍列表
                gstPlayer.clearJpegFiles()
                captureManager.clearAll()
                
                // 3. 断开 WebSocket
                WebSocketClient.disconnectFromServer()
                
                // 4. 退出登录（只清除token，保留账号列表）
                HttpClient.logout()
                
                // 5. 弹出提示并返回登录页
                showToast("设备端账号密码已更新，请重新登录")
                logoutRequested()
            }
        }
        // ============ OTG_CAPS：外接摄像头能力快照（第五十章）============
        else if (msgType === "OTG_CAPS") {
            if (expectedDeviceId && expectedDeviceId === msgDeviceId) {
                CameraCapsStore.applyCaps(message.caps)
            }
        }
        // ============ RESET_PUBLISH / TryDisconnect：忽略 ============
        else if (msgType === "RESET_PUBLISH" || msgType === "TryDisconnect") {
            // 忽略
        }
    }
    
    // ============ 解绑提示对话框 ============
    Dialog {
        id: unbindDialog
        title: "设备已解绑"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok
        
        Label {
            text: "iOS 设备已解除绑定\n\n如需继续使用请重新绑定设备"
            wrapMode: Text.WordWrap
            width: 300
        }
    }
    
    // ============ 扫码绑定 Popup ============
    // ⭐ 2026-08-14 样式对齐 java gstream DeviceBindingDialog：
    //   #2b2b2b 标题栏（「设备绑定」+ ×）、#1f1f1f 内容区、#e8e8e8 浅灰二维码底、上下灰色提示文字
    Popup {
        id: scanBindPopup
        parent: Overlay.overlay
        width: 320
        height: 344
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 0
        
        property string qrCodeContent: ""
        
        // 动态计算位置
        onAboutToShow: {
            var pos = deviceBindText.mapToGlobal(0, deviceBindText.height + 8)
            var windowPos = mainWindow.contentItem.mapFromGlobal(pos.x, pos.y)
            scanBindPopup.x = windowPos.x - scanBindPopup.width / 2 + deviceBindText.width / 2
            scanBindPopup.y = windowPos.y
        }
        
        background: Rectangle {
            color: "#2b2b2b"
            radius: 12
        }
        
        contentItem: Column {
            spacing: 0
            
            // 标题栏（同 java：#2b2b2b，「设备绑定」白 16 bold + × 关闭）
            Item {
                width: parent.width
                height: 44
                
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: "设备绑定"
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    font.bold: true
                    color: "#FFFFFF"
                }
                
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 24
                    radius: 4
                    color: scanCloseArea.containsMouse ? "#ef4444" : "transparent"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        font.pixelSize: 20
                        font.bold: true
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: scanCloseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: scanBindPopup.close()
                    }
                }
            }
            
            // 内容区（同 java：#1f1f1f，提示 + 二维码 + 底部提示）
            Rectangle {
                width: parent.width
                height: scanBindPopup.height - 44
                color: "#1f1f1f"
                radius: 12
                
                // 顶部两角保持直角（只让底部圆角生效）
                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 12
                    color: "#1f1f1f"
                }
                
                Column {
                    anchors.top: parent.top
                    anchors.topMargin: 16
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 15
                    
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "请使用iOS设备扫描二维码"
                        font.family: "PingFang HK"
                        font.pixelSize: 12
                        color: "#9ca3af"
                    }
                    
                    // 二维码容器（同 java：柔和浅灰 #e8e8e8，不刺眼）
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 180
                        height: 180
                        radius: 8
                        color: "#e8e8e8"
                        
                        QRCodeGenerator {
                            id: qrCode
                            anchors.centerIn: parent
                            width: 160
                            height: 160
                            text: scanBindPopup.qrCodeContent
                            foreground: "#000000"
                            background: "#e8e8e8"
                            margin: 2
                        }
                        
                        // 加载中
                        Text {
                            anchors.centerIn: parent
                            text: "加载中..."
                            font.pixelSize: 14
                            color: "#666666"
                            visible: scanBindPopup.qrCodeContent === ""
                        }
                    }
                    
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "扫码后在iOS设备上确认绑定"
                        font.family: "PingFang HK"
                        font.pixelSize: 11
                        color: "#6b7280"
                    }
                }
            }
        }
    }
    
    // ============ 手动绑定对话框 ============
    Dialog {
        id: manualBindDialog
        title: "手动绑定设备"
        modal: true
        anchors.centerIn: parent
        width: 360
        height: 420
        padding: 20
        
        property string errorText: ""
        property bool isBinding: false
        
        // ⭐ 2026-08-14 样式对齐 java gstream 手动绑定弹窗：#1F1F1F 底、白字、#292929 输入框
        background: Rectangle {
            color: "#1F1F1F"
            radius: 12
        }
        
        header: Item {
            height: 44
            
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                text: "手动绑定设备"
                font.family: "PingFang HK"
                font.pixelSize: 18
                font.bold: true
                color: "#FAFAFA"
            }
        }
        
        contentItem: Column {
            spacing: 16
            topPadding: 8
            
            // 提示
            Text {
                text: "请输入设备端的账号前8位和密码进行绑定"
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#64748b"
            }
            
            // 设备账号前8位
            Column {
                spacing: 6
                width: parent.width
                
                Text {
                    text: "设备端账号前8位"
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#FAFAFA"
                }
                
                TextField {
                    id: deviceNicknameField
                    width: parent.width
                    height: 40
                    placeholderText: "请输入账号前8位"
                    color: "#FAFAFA"
                    placeholderTextColor: "#64748b"
                    background: Rectangle {
                        color: "#292929"
                        radius: 8
                        border.color: deviceNicknameField.activeFocus ? "#607AFB" : "#3a3a3a"
                        border.width: 1
                    }
                    leftPadding: 12
                    rightPadding: 12
                    verticalAlignment: TextInput.AlignVCenter
                }
            }
            
            // 绑定密码
            Column {
                spacing: 6
                width: parent.width

                Text {
                    text: "绑定密码"
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#FAFAFA"
                }

                TextField {
                    id: secondaryPasswordField
                    width: parent.width
                    height: 40
                    placeholderText: "请输入绑定密码"
                    echoMode: TextInput.Password
                    color: "#FAFAFA"
                    placeholderTextColor: "#64748b"
                    background: Rectangle {
                        color: "#292929"
                        radius: 8
                        border.color: secondaryPasswordField.activeFocus ? "#607AFB" : "#3a3a3a"
                        border.width: 1
                    }
                    leftPadding: 12
                    rightPadding: 12
                    verticalAlignment: TextInput.AlignVCenter
                }
            }
            
            // 错误提示
            Text {
                text: manualBindDialog.errorText
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#ef4444"
                visible: manualBindDialog.errorText !== ""
            }
        }
        
        footer: Item {
            height: 56
            
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                
                // 取消按钮（同 java：#292929 白字，hover #374151）
                Rectangle {
                    width: 72
                    height: 32
                    color: cancelBtnMouse.containsMouse ? "#374151" : "#292929"
                    radius: 8
                    
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FAFAFA"
                    }
                    
                    MouseArea {
                        id: cancelBtnMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: manualBindDialog.close()
                    }
                }
                
                // 绑定按钮（同 java：#607AFB，hover #4f6af0）
                Rectangle {
                    width: 72
                    height: 32
                    color: manualBindDialog.isBinding ? "#A0B0FF" : (bindBtnMouse.containsMouse ? "#4f6af0" : "#607AFB")
                    radius: 8
                    
                    Text {
                        anchors.centerIn: parent
                        text: manualBindDialog.isBinding ? "绑定中..." : "绑定"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: bindBtnMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !manualBindDialog.isBinding
                        onClicked: executeManualBind()
                    }
                }
            }
        }
        
        onClosed: {
            // 清空表单
            deviceNicknameField.text = ""
            devicePasswordField.text = ""
            secondaryPasswordField.text = ""
            errorText = ""
            isBinding = false
        }
    }
    
    // ============ 绑定成功对话框 ============
    Dialog {
        id: bindSuccessDialog
        title: "绑定成功"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok
        
        Label {
            text: "设备绑定成功！"
            wrapMode: Text.WordWrap
            width: 200
        }
    }
    
    // ============ 设备绑定函数 ============
    function showScanBindPopup() {
        scanBindPopup.qrCodeContent = ""
        scanBindPopup.open()
        HttpClient.getQRCodeData()
    }
    
    function executeManualBind() {
        var nickname = deviceNicknameField.text.trim()
        var secondaryPassword = secondaryPasswordField.text

        // 验证
        if (nickname === "") {
            manualBindDialog.errorText = "请输入设备端账号前8位"
            return
        }
        if (secondaryPassword === "") {
            manualBindDialog.errorText = "请输入绑定密码"
            return
        }

        manualBindDialog.isBinding = true
        manualBindDialog.errorText = ""
        HttpClient.manualBind(nickname, "", secondaryPassword)
    }
    
    // HttpClient 绑定信号处理
    Connections {
        target: HttpClient
        
        function onQrCodeDataReceived(controlUsername) {
            scanBindPopup.qrCodeContent = controlUsername
        }
        
        function onQrCodeDataFailed(code, message) {
            console.log("获取二维码失败:", message)
            scanBindPopup.close()
            statusText.text = "获取二维码失败: " + message
        }
        
        function onManualBindSuccess(deviceId, deviceUsername) {
            manualBindDialog.isBinding = false
            manualBindDialog.close()
            
            // 检查是否已有设备
            var currentDeviceId = HttpClient.currentDeviceId()
            var hasExistingDevice = currentDeviceId && currentDeviceId !== ""
            
            console.log("📱 手动绑定成功: deviceId=" + deviceId + ", deviceUsername=" + deviceUsername + ", hasExistingDevice=" + hasExistingDevice)
            
            if (hasExistingDevice) {
                // 已有设备：只提示绑定成功，不切换设备
                statusText.text = "绑定成功"
                showToast("绑定成功")
            } else {
                // 首次绑定设备：重新登录获取设备信息并订阅频道
                statusText.text = "绑定成功"
                showToast("绑定成功")
                reLoginAndInitDevice(deviceId, deviceUsername)
            }
        }
        
        function onManualBindFailed(code, message) {
            manualBindDialog.isBinding = false
            manualBindDialog.errorText = message
        }
    }
    
    // ============ 列预览函数（数字键0-9，0代表第10列） ============
    function toggleColumnPreview(colNumber) {
        // colNumber: 1-10 (用户按键1-9对应1-9列, 0对应第10列), 列索引 0-based
        var colIndex = colNumber - 1
        var cols = captureManager.gridCols
        var rows = captureManager.gridRows
        
        if (colIndex >= cols) {
            console.log("⚠️ 列预览: 按键" + colNumber + "超出列数" + cols)
            return
        }
        
        // 再次按同一数字键 → 关闭预览
        if (columnPreviewVisible && columnPreviewCol === colIndex) {
            closeColumnPreview()
            return
        }
        
        // 收集该列所有有数据的 dataIndex
        var items = []
        var frames = []
        var zooms = []
        var offX = []
        var offY = []
        for (var row = 0; row < rows; row++) {
            var dataIdx
            if (captureManager.isHorizontalLayout) {
                dataIdx = row * cols + colIndex
            } else {
                dataIdx = colIndex * rows + row
            }
            if (dataIdx < captureManager.count) {
                items.push(dataIdx)
                frames.push(captureManager.getCurrentOffset(dataIdx))  // 当前帧
                zooms.push(1.0)
                offX.push(0)
                offY.push(0)
            }
        }
        
        if (items.length === 0) {
            console.log("⚠️ 列预览: 第" + colNumber + "列没有截图数据")
            return
        }
        
        // ⭐ 仅支持 2-5 个元素
        if (items.length < 2 || items.length > 5) {
            console.log("⚠️ 列预览: 第" + colNumber + "列有" + items.length + "个元素，仅支持2-5个")
            return
        }
        
        console.log("📸 列预览: 列" + colNumber + " 共" + items.length + "张 dataIndices=" + JSON.stringify(items))
        columnPreviewItems = items
        columnPreviewFrames = frames
        columnPreviewDisplayFrames = frames.slice()
        columnPreviewZooms = zooms
        columnPreviewOffsetX = offX
        columnPreviewOffsetY = offY
        columnPreviewCol = colIndex
        columnPreviewRefreshToken = Date.now()
        columnPreviewVisible = true
    }
    
    function closeColumnPreview() {
        // 先关闭A键放大
        closeColumnPreviewZoom()
        // 关闭前同步帧到captureManager
        if (columnPreviewItems && columnPreviewFrames) {
            for (var i = 0; i < columnPreviewItems.length; i++) {
                captureManager.gotoFrame(columnPreviewItems[i], columnPreviewFrames[i])
            }
        }
        columnPreviewVisible = false
        columnPreviewCol = -1
        columnPreviewItems = []
        columnPreviewFrames = []
        columnPreviewDisplayFrames = []
        columnPreviewZooms = []
        columnPreviewOffsetX = []
        columnPreviewOffsetY = []
        columnPreviewHoveredIndex = -1
    }
    
    // ⭐ 列预览A键放大相关函数
    function openColumnPreviewZoom(previewIdx) {
        if (previewIdx < 0 || previewIdx >= columnPreviewItems.length) return
        columnPreviewZoomItemIdx = previewIdx
        columnPreviewZoomFrame = columnPreviewFrames[previewIdx] || 0
        columnPreviewZoomDisplayFrame = columnPreviewZoomFrame
        // ⭐ 2026-07-12：A键放大继承该格 itemZoomMap 的缩放/取景（与 item/列预览同步），不再复位 1.0
        var di = columnPreviewItems[previewIdx]
        var saved = mainPage.itemZoomMap[di]
        if (saved && saved.zoom > 1.0) {
            columnPreviewZoomScale = saved.zoom
            var fx = (saved.fx !== undefined) ? saved.fx : 0
            var fy = (saved.fy !== undefined) ? saved.fy : 0
            columnPreviewZoomOffX = mainPage.itemZoomOffsetPx(saved.zoom, fx, zoomImageContainer.width)
            columnPreviewZoomOffY = mainPage.itemZoomOffsetPx(saved.zoom, fy, zoomImageContainer.height)
        } else {
            columnPreviewZoomScale = 1.0
            columnPreviewZoomOffX = 0
            columnPreviewZoomOffY = 0
        }
        columnPreviewRefreshToken = Date.now()
        console.log("🔍 列预览放大: 索引=" + previewIdx + " dataIdx=" + di)
    }

    // ⭐ 2026-07-12：把 A键放大当前缩放/取景写回 itemZoomMap 并通知 item/列预览同步
    function syncColumnPreviewZoomToItem() {
        if (columnPreviewZoomItemIdx < 0 || columnPreviewZoomItemIdx >= columnPreviewItems.length) return
        var di = columnPreviewItems[columnPreviewZoomItemIdx]
        mainPage.saveItemZoom(di, columnPreviewZoomScale, columnPreviewZoomOffX, columnPreviewZoomOffY,
                              zoomImageContainer.width, zoomImageContainer.height)
        mainPage.itemZoomRestore(di)
    }
    
    function closeColumnPreviewZoom() {
        if (columnPreviewZoomItemIdx >= 0 && columnPreviewZoomItemIdx < columnPreviewFrames.length) {
            // 同步帧回列预览（逻辑帧 + 显示帧）
            var frames = columnPreviewFrames.slice()
            frames[columnPreviewZoomItemIdx] = columnPreviewZoomFrame
            columnPreviewFrames = frames
            var disp = columnPreviewDisplayFrames.slice()
            disp[columnPreviewZoomItemIdx] = columnPreviewZoomFrame
            columnPreviewDisplayFrames = disp
            columnPreviewRefreshToken = Date.now()
            // ⭐ 关闭前把缩放/取景写回 itemZoomMap（与 item/列预览一致）
            syncColumnPreviewZoomToItem()
        }
        columnPreviewZoomItemIdx = -1
        columnPreviewZoomScale = 1.0
        columnPreviewZoomOffX = 0
        columnPreviewZoomOffY = 0
    }
    
    function columnPreviewZoomPrevFrame() {
        if (columnPreviewZoomItemIdx < 0) return
        columnPreviewZoomGoToFrame(columnPreviewZoomFrame - mainPage.frameStep)
    }

    function columnPreviewZoomNextFrame() {
        if (columnPreviewZoomItemIdx < 0) return
        columnPreviewZoomGoToFrame(columnPreviewZoomFrame + mainPage.frameStep)
    }

    // ⭐ 单 item 步进上/下一帧 frameStep 次 (C++ side stepwise)
    function stepCaptureFrame(dataIndex, direction) {
        var n = mainPage.frameStep
        for (var i = 0; i < n; i++) {
            if (direction === "prev") captureManager.prevFrame(dataIndex)
            else captureManager.nextFrame(dataIndex)
        }
    }

    // ⭐ 2026-07-16：截图item（主 grid 格子）——跳到目标帧（进度条拖动/点击用，绝对跳转）
    function jumpCaptureFrame(dataIndex, target) {
        var total = captureManager.getTotalFrames(dataIndex)
        if (total <= 0) return
        target = Math.max(0, Math.min(total - 1, target))
        // ⭐ 2026-07-16：跳过没有变化的调用（跟 fullscreenGoToFrame/columnPreviewZoomGoToFrame 等已有
        //   跳转函数的写法保持一致）——拖动进度条时 onPositionChanged 每移动几像素就触发一次，如果每次
        //   都无条件转发给 C++ 侧解码，快速拖动时会堆积大量重复/过时的解码请求，容易造成拖动卡顿。
        if (captureManager.getCurrentOffset(dataIndex) === target) return
        captureManager.gotoFrame(dataIndex, target)
    }

    // 列预览：所有图片同时切换上一帧
    function columnPreviewPrevFrame() {
        if (!columnPreviewVisible || columnPreviewItems.length === 0) return
        var step = mainPage.frameStep
        var frames = columnPreviewFrames.slice()  // 拷贝数组
        var changed = false
        for (var i = 0; i < columnPreviewItems.length; i++) {
            var newF = Math.max(0, (frames[i] || 0) - step)
            if (newF !== frames[i]) {
                frames[i] = newF
                changed = true
            }
        }
        if (changed) {
            columnPreviewCommitFrames(frames)
        }
    }

    // 列预览：所有图片同时切换下一帧
    function columnPreviewNextFrame() {
        if (!columnPreviewVisible || columnPreviewItems.length === 0) return
        var step = mainPage.frameStep
        var frames = columnPreviewFrames.slice()
        var changed = false
        for (var i = 0; i < columnPreviewItems.length; i++) {
            var total = captureManager.getTotalFrames(columnPreviewItems[i])
            var newF = Math.min(total - 1, (frames[i] || 0) + step)
            if (newF !== frames[i] && newF >= 0) {
                frames[i] = newF
                changed = true
            }
        }
        if (changed) {
            columnPreviewCommitFrames(frames)
        }
    }

    // 列预览：所有图片同时按各自中心缩放 (Ctrl+S+滚轮)
    function columnPreviewSyncZoomDelta(delta) {
        if (!columnPreviewVisible || columnPreviewItems.length === 0) return
        // ⭐ 2026-07-12：列预览联动缩放直接落 itemZoomMap（唯一数据源，与 item 同步）。
        //   以容器中心为原点缩放（归一化分量 fx/fy 不变、只改 zoom）；zoom=1 归零。
        for (var i = 0; i < columnPreviewItems.length; i++) {
            var di = columnPreviewItems[i]
            var saved = mainPage.itemZoomMap[di]
            var oldZoom = (saved && saved.zoom > 1.0) ? saved.zoom : 1.0
            var newZoom = Math.max(1.0, Math.min(5.0, oldZoom + delta))
            if (newZoom === oldZoom) continue
            if (newZoom <= 1.0) {
                mainPage.saveItemZoomNorm(di, 1.0, 0, 0)
            } else {
                // 归一化分量与容器无关、中心缩放下保持不变
                var fx = (saved && saved.fx !== undefined) ? saved.fx : 0
                var fy = (saved && saved.fy !== undefined) ? saved.fy : 0
                mainPage.saveItemZoomNorm(di, newZoom, fx, fy)
            }
            mainPage.itemZoomRestore(di)
        }
    }

    // 列预览：切换到上一列
    function columnPreviewPrevCol() {
        if (!columnPreviewVisible) return
        var newCol = columnPreviewCol  // 0-based
        if (newCol <= 0) return  // 已在第一列
        closeColumnPreview()
        toggleColumnPreview(newCol)  // newCol is 0-based current-1, which equals colNumber for prev
    }
    
    // 列预览：切换到下一列
    function columnPreviewNextCol() {
        if (!columnPreviewVisible) return
        var cols = captureManager.gridCols
        var newColIndex = columnPreviewCol + 1  // 0-based
        if (newColIndex >= cols) return  // 已在最后一列
        closeColumnPreview()
        toggleColumnPreview(newColIndex + 1)  // +1 because toggleColumnPreview expects 1-based colNumber
    }
    
    // ⭐ 全屏：切到目标帧 — 已缓存立即换图(无白屏), 未缓存保持当前画面等解码完成再换
    function fullscreenGoToFrame(target) {
        var totalFrames = captureManager.getTotalFrames(fullscreenItemIndex)
        if (totalFrames <= 0) return
        target = Math.max(0, Math.min(totalFrames - 1, target))
        if (target === fullscreenFrameIndex) return
        fullscreenFrameIndex = target
        captureManager.gotoFrame(fullscreenItemIndex, target)  // 触发解码+预取
        if (captureManager.isFrameCached(fullscreenItemIndex, target)) {
            fullscreenDisplayFrame = target
            fullscreenRefreshToken = Date.now()
        }
    }

    // ⭐ A键放大：切到目标帧 — 同上防闪烁
    function columnPreviewZoomGoToFrame(target) {
        if (columnPreviewZoomItemIdx < 0 || columnPreviewZoomItemIdx >= columnPreviewItems.length) return
        var dataIdx = columnPreviewItems[columnPreviewZoomItemIdx]
        var total = captureManager.getTotalFrames(dataIdx)
        if (total <= 0) return
        target = Math.max(0, Math.min(total - 1, target))
        if (target === columnPreviewZoomFrame) return
        columnPreviewZoomFrame = target
        captureManager.gotoFrame(dataIdx, target)
        if (captureManager.isFrameCached(dataIdx, target)) {
            columnPreviewZoomDisplayFrame = target
            columnPreviewRefreshToken = Date.now()
        }
    }

    // ⭐ 2026-07-16：列预览单张——跳到目标帧（进度条拖动/点击用，只改这一张，不影响其它 item）
    function columnPreviewJumpSingleFrame(idx, target) {
        if (idx < 0 || idx >= columnPreviewItems.length) return
        var total = captureManager.getTotalFrames(columnPreviewItems[idx])
        if (total <= 0) return
        target = Math.max(0, Math.min(total - 1, target))
        var frames = columnPreviewFrames.slice()
        if ((frames[idx] || 0) === target) return
        frames[idx] = target
        columnPreviewCommitFrames(frames)
    }

    // ⭐ 列预览：提交新的逐帧数组 — 每个 item 已缓存的立即推进显示帧, 未缓存的等解码
    function columnPreviewCommitFrames(newFrames) {
        columnPreviewFrames = newFrames
        var disp = columnPreviewDisplayFrames.slice()
        var advanced = false
        for (var i = 0; i < columnPreviewItems.length; i++) {
            var dataIdx = columnPreviewItems[i]
            var f = newFrames[i] || 0
            captureManager.gotoFrame(dataIdx, f)  // 触发解码+预取
            if (captureManager.isFrameCached(dataIdx, f)) {
                disp[i] = f
                advanced = true
            }
        }
        if (advanced) {
            columnPreviewDisplayFrames = disp
            columnPreviewRefreshToken = Date.now()
        }
    }

    // ============ 全屏查看函数 ============
    function openFullscreenViewer(itemIndex) {
        if (itemIndex < 0 || itemIndex >= captureManager.count) return
        
        fullscreenItemIndex = itemIndex
        fullscreenFrameIndex = captureManager.getCurrentOffset(itemIndex)
        fullscreenDisplayFrame = fullscreenFrameIndex
        // ⭐ 2026-07-11：单个放大继承 item 当前缩放/取景（与 item 效果一样），而不是复位 1.0。
        //   用归一化分量按全屏容器尺寸换算，保证与格子里看到的是同一取景区域。
        var saved = mainPage.itemZoomMap[itemIndex]
        if (saved && saved.zoom > 1.0) {
            fullscreenZoom = saved.zoom
            var fx = (saved.fx !== undefined) ? saved.fx : 0
            var fy = (saved.fy !== undefined) ? saved.fy : 0
            fullscreenOffsetX = mainPage.itemZoomOffsetPx(saved.zoom, fx, fullscreenImageContainer.width)
            fullscreenOffsetY = mainPage.itemZoomOffsetPx(saved.zoom, fy, fullscreenImageContainer.height)
        } else {
            fullscreenZoom = 1.0
            fullscreenOffsetX = 0
            fullscreenOffsetY = 0
        }
        fullscreenRefreshToken = Date.now()  // ⭐ 强制刷新图片
        fullscreenViewerVisible = true
    }

    // ⭐ 2026-07-11：把单个放大当前的缩放/取景写回 itemZoomMap（归一化）并通知对应 item 同步。
    //   单个放大里缩放/拖动后，关闭或实时都保持与 item 一致。
    function syncFullscreenZoomToItem() {
        if (fullscreenItemIndex < 0) return
        mainPage.saveItemZoom(fullscreenItemIndex, fullscreenZoom,
                              fullscreenOffsetX, fullscreenOffsetY,
                              fullscreenImageContainer.width, fullscreenImageContainer.height)
        mainPage.itemZoomRestore(fullscreenItemIndex)
    }
    
    function closeFullscreenViewer() {
        if (fullscreenItemIndex >= 0 && fullscreenItemIndex < captureManager.count) {
            // 同步帧 index 到 item
            captureManager.gotoFrame(fullscreenItemIndex, fullscreenFrameIndex)
            // ⭐ 关闭时把单个放大的缩放/取景同步回 item（效果一致）
            syncFullscreenZoomToItem()
        }
        fullscreenViewerVisible = false
        fullscreenItemIndex = -1
    }
    
    // ============ 全屏查看弹窗 ============
    // fullscreenViewerMode: 0=全屏, 1=半屏（只覆盖截图区域）
    Rectangle {
        id: fullscreenViewer
        // ⭐ 根据模式选择覆盖区域
        x: fullscreenViewerMode === 0 ? 0 : captureGridContent.mapToItem(mainPage, 0, 0).x
        y: fullscreenViewerMode === 0 ? 0 : captureGridContent.mapToItem(mainPage, 0, 0).y
        width: fullscreenViewerMode === 0 ? parent.width : captureGridContent.width
        height: fullscreenViewerMode === 0 ? parent.height : captureGridContent.height
        color: "#000000"
        visible: fullscreenViewerVisible
        z: 1000

        // ⭐ 2026-07-16：底部切帧进度条悬停显隐标记——由下面 z:50 的独立感应层单独负责置 true/false，
        //   感应层必须盖在进度条之上，否则进度条一显示就盖住感应层，会来回"测不到→隐藏→测到了→显示"闪烁。
        property bool progressBarHovered: false

        // ⭐ 2026-07-14：与 item / 列预览单张 / 列预览A放大 保持三方同步兜底——
        //   万一该 item 在别处被改动（如联动缩放），这里也重新从 itemZoomMap 读取套用
        Connections {
            target: mainPage
            function onItemZoomRestore(idx) {
                if (idx !== mainPage.fullscreenItemIndex) return
                var saved = mainPage.itemZoomMap[idx]
                if (saved && saved.zoom > 1.0) {
                    mainPage.fullscreenZoom = saved.zoom
                    var fx = (saved.fx !== undefined) ? saved.fx : 0
                    var fy = (saved.fy !== undefined) ? saved.fy : 0
                    mainPage.fullscreenOffsetX = mainPage.itemZoomOffsetPx(saved.zoom, fx, fullscreenImageContainer.width)
                    mainPage.fullscreenOffsetY = mainPage.itemZoomOffsetPx(saved.zoom, fy, fullscreenImageContainer.height)
                } else {
                    mainPage.fullscreenZoom = 1.0
                    mainPage.fullscreenOffsetX = 0
                    mainPage.fullscreenOffsetY = 0
                }
            }
        }
        
        // 点击背景关闭
        MouseArea {
            anchors.fill: parent
            onClicked: closeFullscreenViewer()
            
            onWheel: function(wheel) {
                if (mainPage.sKeyPressed) {
                    // ⭐ 2026-08-14：PC 端已改单版本，去掉等级门槛
                    // ⭐ S + 滚轮：以鼠标位置为中心缩放
                    var oldZoom = fullscreenZoom
                    var delta = wheel.angleDelta.y > 0 ? 0.2 : -0.2
                    var newZoom = Math.max(1.0, Math.min(5.0, fullscreenZoom + delta))
                    
                    if (newZoom !== oldZoom) {
                        // 计算鼠标相对于容器中心的位置
                        var containerCenterX = fullscreenImageContainer.width / 2
                        var containerCenterY = fullscreenImageContainer.height / 2
                        var mouseRelX = wheel.x - containerCenterX
                        var mouseRelY = wheel.y - containerCenterY
                        
                        // 计算缩放比例变化
                        var zoomRatio = newZoom / oldZoom
                        
                        // 调整偏移量，使鼠标位置保持不变
                        fullscreenOffsetX = mouseRelX - (mouseRelX - fullscreenOffsetX) * zoomRatio
                        fullscreenOffsetY = mouseRelY - (mouseRelY - fullscreenOffsetY) * zoomRatio
                        
                        fullscreenZoom = newZoom
                        
                        // 缩放回1.0时重置偏移
                        if (newZoom === 1.0) {
                            fullscreenOffsetX = 0
                            fullscreenOffsetY = 0
                        }
                        mainPage.syncFullscreenZoomToItem()  // ⭐ 同步回 item
                    }
                } else {
                    // 普通滚轮：切换帧 (受 frameStep 影响)
                    var totalFrames = captureManager.getTotalFrames(fullscreenItemIndex)
                    if (totalFrames > 0) {
                        var step = mainPage.frameStep
                        if (wheel.angleDelta.y > 0) {
                            fullscreenGoToFrame(fullscreenFrameIndex - step)
                        } else {
                            fullscreenGoToFrame(fullscreenFrameIndex + step)
                        }
                    }
                }
            }
        }

        // 图片容器
        Item {
            id: fullscreenImageContainer
            anchors.centerIn: parent
            width: parent.width
            height: parent.height
            clip: true
            
            Image {
                id: fullscreenImage
                // ⭐ 完全铺满容器（拉伸填充）
                // 使用手动居中 + 偏移量实现缩放拖动
                x: parent.width / 2 - width / 2 + fullscreenOffsetX
                y: parent.height / 2 - height / 2 + fullscreenOffsetY
                width: parent.width * fullscreenZoom
                height: parent.height * fullscreenZoom
                // ⭐ 使用刷新令牌强制重新加载图片，解决图片不同步问题
                source: fullscreenViewerVisible && fullscreenItemIndex >= 0 
                        ? "image://capture/frame/" + fullscreenItemIndex + "/" + fullscreenDisplayFrame + "?t=" + fullscreenRefreshToken
                        : ""
                fillMode: Image.Stretch  // 拉伸铺满，完全填充容器
                cache: false
                asynchronous: false
                mirror: mainPage.videoMirrorMode === "horizontal"
                mirrorVertically: mainPage.videoMirrorMode === "vertical"
                
                layer.enabled: false  // 不再使用 shader，颜色调整由 GStreamer videobalance 和 gamma 处理
                
                // ⭐ 左键=上一帧，右键=下一帧，滚轮=切帧/缩放
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    
                    // ⭐ 左键按住拖动放大后的全屏截图（平移，无需 Z 键）
                    property bool panning: false
                    property bool panMoved: false
                    property real panLastX: 0
                    property real panLastY: 0
                    property real panStartX: 0
                    property real panStartY: 0
                    readonly property real panThreshold: 4

                    onPressed: function(mouse) {
                        mainPage.forceActiveFocus()
                        if (mouse.button === Qt.LeftButton && fullscreenZoom > 1.0) {
                            panning = true
                            panMoved = false
                            panLastX = mouse.x
                            panLastY = mouse.y
                            panStartX = mouse.x
                            panStartY = mouse.y
                        }
                    }

                    onReleased: function(mouse) {
                        if (panning) {
                            panning = false
                            if (panMoved) {
                                mouse.accepted = true
                                mainPage.syncFullscreenZoomToItem()  // ⭐ 拖动结束同步回 item
                            }
                        }
                    }

                    onPositionChanged: function(mouse) {
                        if (panning) {
                            if (Math.abs(mouse.x - panStartX) > panThreshold || Math.abs(mouse.y - panStartY) > panThreshold)
                                panMoved = true
                            var maxX = fullscreenImageContainer.width * (fullscreenZoom - 1) / 2
                            var maxY = fullscreenImageContainer.height * (fullscreenZoom - 1) / 2
                            fullscreenOffsetX = Math.max(-maxX, Math.min(maxX, fullscreenOffsetX + (mouse.x - panLastX)))
                            fullscreenOffsetY = Math.max(-maxY, Math.min(maxY, fullscreenOffsetY + (mouse.y - panLastY)))
                            panLastX = mouse.x
                            panLastY = mouse.y
                            mouse.accepted = true
                        }
                    }

                    onClicked: function(mouse) {
                        if (panMoved) { panMoved = false; return }
                        var totalFrames = captureManager.getTotalFrames(fullscreenItemIndex)
                        if (totalFrames > 0) {
                            var step = mainPage.frameStep
                            if (mouse.button === Qt.LeftButton) {
                                fullscreenGoToFrame(fullscreenFrameIndex - step)
                            } else if (mouse.button === Qt.RightButton) {
                                fullscreenGoToFrame(fullscreenFrameIndex + step)
                            }
                        }
                    }
                    
                    onWheel: function(wheel) {
                        if (mainPage.sKeyPressed) {
                            // ⭐ S + 滚轮：以鼠标位置为中心缩放
                            var oldZoom = fullscreenZoom
                            var delta = wheel.angleDelta.y > 0 ? 0.2 : -0.2
                            var newZoom = Math.max(1.0, Math.min(5.0, fullscreenZoom + delta))
                            
                            if (newZoom !== oldZoom) {
                                // 鼠标在图片上的位置
                                var mouseInImageX = wheel.x
                                var mouseInImageY = wheel.y
                                
                                // 鼠标相对于容器中心的位置
                                var containerCenterX = fullscreenImageContainer.width / 2
                                var containerCenterY = fullscreenImageContainer.height / 2
                                var mouseRelX = fullscreenImage.x + mouseInImageX - containerCenterX
                                var mouseRelY = fullscreenImage.y + mouseInImageY - containerCenterY
                                
                                // 计算缩放比例变化
                                var zoomRatio = newZoom / oldZoom
                                
                                // 调整偏移量
                                fullscreenOffsetX = mouseRelX - (mouseRelX - fullscreenOffsetX) * zoomRatio
                                fullscreenOffsetY = mouseRelY - (mouseRelY - fullscreenOffsetY) * zoomRatio
                                
                                fullscreenZoom = newZoom
                                
                                // 缩放回1.0时重置偏移
                                if (newZoom === 1.0) {
                                    fullscreenOffsetX = 0
                                    fullscreenOffsetY = 0
                                }
                                mainPage.syncFullscreenZoomToItem()  // ⭐ 同步回 item
                            }
                        } else {
                            var totalFrames = captureManager.getTotalFrames(fullscreenItemIndex)
                            if (totalFrames > 0) {
                                var step = mainPage.frameStep
                                if (wheel.angleDelta.y > 0) {
                                    fullscreenGoToFrame(fullscreenFrameIndex - step)
                                } else {
                                    fullscreenGoToFrame(fullscreenFrameIndex + step)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // 帧信息显示（左上角，无背景，白色文字70%透明度）
        Text {
            id: fullscreenFrameText
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 20
            text: (fullscreenFrameIndex + 1)  // 只显示当前帧数
            font.pixelSize: 12  // 字体增加4px（8 -> 12）
            font.family: "PingFang HK"
            color: "#B3FFFFFF"  // 白色，透明度70%
        }
        
        // 关闭按钮（右上角，透明度与抓拍item一致）
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 20
            width: 40
            height: 40
            color: fullscreenCloseBtn.containsMouse ? "#E53935" : "#40000000"  // 25% 透明度
            radius: 20
            
            Text {
                anchors.centerIn: parent
                text: "✕"
                font.pixelSize: 20
                color: "#33FFFFFF"  // 白色 20% 透明度
            }
            
            MouseArea {
                id: fullscreenCloseBtn
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: closeFullscreenViewer()
            }
        }
        
        // 操作提示（底部，透明度与抓拍item一致；⭐ 2026-07-16 上移，给下面新增的进度条让位）
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: fullscreenProgressBar.top
            anchors.bottomMargin: 10
            width: hintText.width + 32
            height: 36
            color: "#40000000"  // 25% 透明度
            radius: 18
            
            Text {
                id: hintText
                anchors.centerIn: parent
                text: "左键/滚轮↑: 上一帧 | 右键/滚轮↓: 下一帧 | S+滚轮: 缩放 | " + ShortcutStore.fullscreenViewerKey + ": 全屏/半屏 | Esc: 关闭"
                font.pixelSize: 13
                font.family: "PingFang HK"
                color: "#33FFFFFF"  // 白色 20% 透明度
            }
        }

        // ⭐ 2026-07-16：底部悬停感应区（比进度条本身高一点，鼠标靠近底部就先感应到）——
        //   只用于显隐判断，不拦截点击/拖动（NoButton），真正的交互都在下面进度条自己的 MouseArea 里。
        MouseArea {
            id: fullscreenProgressHoverArea
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 120  // ⭐ 2026-07-16：进度条放大到88后同步加高（原70）
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            z: 50  // ⭐ 2026-07-16 修复闪烁：必须盖在进度条自己之上，否则进度条一显示就把这层的悬停检测挡住，来回抖动
            onEntered: fullscreenViewer.progressBarHovered = true
            onExited: fullscreenViewer.progressBarHovered = false
        }

        // ⭐ 2026-07-16：截图单张放大——底部切帧进度条（样式与慢放底部进度条一致），鼠标靠近底部才显示。
        //   拖动=只切当前这一张；Ctrl+拖动=广播给全 grid 同步切帧（跟 Ctrl+滚轮效果一致）。
        // ⭐ 2026-08-14 需求：A 键放大后不再显示滑动条（代码保留，滚轮/左右键切帧不受影响）
        Rectangle {
            id: fullscreenProgressBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 88  // ⭐ 2026-07-16：放大一倍（原 44）
            color: "#80000000"
            visible: false  // 原：captureManager.getTotalFrames(fullscreenItemIndex) > 0 && fullscreenViewer.progressBarHovered

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 12

                Text {
                    text: (fullscreenFrameIndex + 1) + "/" + captureManager.getTotalFrames(fullscreenItemIndex)
                    font.family: "PingFang HK"
                    font.pixelSize: 18
                    color: "#FFFFFF"
                    Layout.minimumWidth: 90
                }

                Item {
                    id: fullscreenFrameSliderContainer
                    Layout.fillWidth: true
                    height: 32

                    property int totalFrames: captureManager.getTotalFrames(fullscreenItemIndex)
                    // ⭐ Ctrl 广播：记录上一次换算出的目标帧，drag/wheel 时用差值步进 gridSyncFrameStep，
                    //   复用现成的、已验证过的单步广播函数，不额外发明新的"绝对跳转广播"，风险更低。
                    property int ctrlLastTarget: fullscreenFrameIndex

                    function ratioToFrame(ratio) {
                        var tf = fullscreenFrameSliderContainer.totalFrames
                        if (tf <= 0) return 0
                        return Math.round(Math.max(0, Math.min(1, ratio)) * (tf - 1))
                    }
                    function applyCtrlBroadcast(target) {
                        var delta = target - fullscreenFrameSliderContainer.ctrlLastTarget
                        fullscreenFrameSliderContainer.ctrlLastTarget = target
                        for (var i = 0; i < Math.abs(delta); i++) {
                            mainPage.gridSyncFrameStep(delta > 0 ? "next" : "prev")
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onWheel: function(wheel) {
                            wheel.accepted = true
                            if (fullscreenFrameSliderContainer.totalFrames <= 0) return
                            if (wheel.angleDelta.y > 0) fullscreenGoToFrame(fullscreenFrameIndex - 1)
                            else fullscreenGoToFrame(fullscreenFrameIndex + 1)
                        }
                        onPressed: function(mouse) {
                            if (fullscreenFrameSliderContainer.totalFrames <= 1) return
                            var ratio = mouse.x / fullscreenFrameSliderContainer.width
                            var frame = fullscreenFrameSliderContainer.ratioToFrame(ratio)
                            if (mouse.modifiers & Qt.ControlModifier) {
                                fullscreenFrameSliderContainer.ctrlLastTarget = fullscreenFrameIndex
                                fullscreenFrameSliderContainer.applyCtrlBroadcast(frame)
                            } else {
                                fullscreenGoToFrame(frame)
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: 8  // ⭐ 放大一倍（原 4）
                        radius: 999
                        color: "#C8E6C9"
                    }

                    Rectangle {
                        id: fullscreenFrameHandle
                        width: 32
                        height: 32
                        radius: 16
                        color: "#A5D6A7"
                        x: fullscreenFrameSliderContainer.totalFrames > 1 ?
                           fullscreenFrameIndex / (fullscreenFrameSliderContainer.totalFrames - 1) * (parent.width - 32) : 0
                        anchors.verticalCenter: parent.verticalCenter

                        MouseArea {
                            id: fullscreenFrameHandleArea
                            anchors.fill: parent
                            anchors.margins: -4
                            drag.target: parent
                            drag.axis: Drag.XAxis
                            drag.minimumX: 0
                            drag.maximumX: fullscreenFrameSliderContainer.width - 32

                            property bool ctrlDrag: false

                            onWheel: function(wheel) {
                                wheel.accepted = true
                                if (fullscreenFrameSliderContainer.totalFrames <= 0) return
                                if (wheel.angleDelta.y > 0) fullscreenGoToFrame(fullscreenFrameIndex - 1)
                                else fullscreenGoToFrame(fullscreenFrameIndex + 1)
                            }
                            onPressed: function(mouse) {
                                ctrlDrag = !!(mouse.modifiers & Qt.ControlModifier)
                                if (ctrlDrag) fullscreenFrameSliderContainer.ctrlLastTarget = fullscreenFrameIndex
                            }
                            onPositionChanged: {
                                if (!drag.active || fullscreenFrameSliderContainer.totalFrames <= 1) return
                                var ratio = fullscreenFrameHandle.x / (fullscreenFrameSliderContainer.width - 32)
                                var frame = fullscreenFrameSliderContainer.ratioToFrame(ratio)
                                if (ctrlDrag) {
                                    fullscreenFrameSliderContainer.applyCtrlBroadcast(frame)
                                } else {
                                    fullscreenGoToFrame(frame)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // ============ 列预览覆盖层（数字键0-9触发，仅2-5张）============
    Rectangle {
        id: columnPreviewOverlay
        anchors.fill: parent
        color: "#CC000000"  // 半透明黑色背景
        visible: columnPreviewVisible
        z: 1001  // 在全屏查看之上
        
        // 点击背景关闭
        MouseArea {
            anchors.fill: parent
            onClicked: closeColumnPreview()
        }
        
        // ===== 顶部栏：Z按钮 + 列号 + X按钮 + 拉伸开关 =====
        Row {
            id: colPreviewTopBar
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: 12
            spacing: 16
            z: 2
            
            // Z按钮（上一列）
            Rectangle {
                width: 36; height: 28; radius: 4
                color: colPrevBtnArea.containsMouse ? "#4DB6AC" : "#40FFFFFF"
                Text { anchors.centerIn: parent; text: "Z ◀"; font.pixelSize: 13; font.family: "PingFang HK"; color: "#FFFFFF" }
                MouseArea {
                    id: colPrevBtnArea
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: columnPreviewPrevCol()
                }
            }
            
            // 列号提示
            Text {
                text: "第 " + (columnPreviewCol + 1) + " 列  （共 " + columnPreviewItems.length + " 张）"
                font.family: "PingFang HK"; font.pixelSize: 18; font.bold: true; color: "#FFFFFF"
                anchors.verticalCenter: parent.verticalCenter
            }
            
            // X按钮（下一列）
            Rectangle {
                width: 36; height: 28; radius: 4
                color: colNextBtnArea.containsMouse ? "#4DB6AC" : "#40FFFFFF"
                Text { anchors.centerIn: parent; text: "▶ X"; font.pixelSize: 13; font.family: "PingFang HK"; color: "#FFFFFF" }
                MouseArea {
                    id: colNextBtnArea
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: columnPreviewNextCol()
                }
            }
            
            // 分隔线
            Rectangle { width: 1; height: 24; color: "#40FFFFFF"; anchors.verticalCenter: parent.verticalCenter }
            
            // 拉伸开关
            Rectangle {
                width: stretchLabel.width + 16; height: 28; radius: 4
                color: stretchBtnArea.containsMouse ? "#4DB6AC" : (columnPreviewStretch ? "#66FFFFFF" : "#40FFFFFF")
                Text {
                    id: stretchLabel
                    anchors.centerIn: parent
                    text: columnPreviewStretch ? "拉伸:开" : "拉伸:关"
                    font.pixelSize: 13; font.family: "PingFang HK"; color: "#FFFFFF"
                }
                MouseArea {
                    id: stretchBtnArea
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: columnPreviewStretch = !columnPreviewStretch
                }
            }
        }
        
        // ===== 图片网格容器（2-3:1行, 4:2x2, 5:2x3）=====
        Item {
            id: columnPreviewGrid
            anchors.centerIn: parent
            
            property int imgCount: columnPreviewVisible ? columnPreviewItems.length : 0
            property int layoutCols: imgCount <= 3 ? imgCount : (imgCount === 4 ? 2 : 3)
            property int layoutRows: imgCount <= 3 ? 1 : 2
            property real gridSpacing: 8
            property real availH: columnPreviewOverlay.height - 110  // 上方顶部栏+下方提示栏
            property real availW: columnPreviewOverlay.width - 60    // 左右各留30边距
            property real cellW: layoutCols > 0 ? (availW - (layoutCols - 1) * gridSpacing) / layoutCols : 0
            property real cellH: layoutRows > 0 ? (availH - (layoutRows - 1) * gridSpacing) / layoutRows : 0
            
            width: layoutCols > 0 ? layoutCols * cellW + (layoutCols - 1) * gridSpacing : 0
            height: layoutRows > 0 ? layoutRows * cellH + (layoutRows - 1) * gridSpacing : 0
            
            Repeater {
                model: columnPreviewGrid.imgCount
                
                // 每张图片的容器
                Item {
                    id: colPreviewItem
                    property int myIndex: index
                    property int dataIdx: columnPreviewItems[index]
                    property int frameIdx: columnPreviewFrames.length > index ? columnPreviewFrames[index] : 0
                    property int displayFrameIdx: columnPreviewDisplayFrames.length > index ? columnPreviewDisplayFrames[index] : 0
                    property int totalFrames: captureManager.getTotalFrames(dataIdx)
                    // ⭐ 2026-07-14 修复「列预览单张放大/拖动失效」回归：itemZoomMap 是 property var 包着的 JS 对象，
                    //   saveItemZoomNorm 走的是「同引用 mutate 后再赋值给自己」（var m=itemZoomMap; m[idx]=...; itemZoomMap=m），
                    //   QML 对「赋值成同一个引用」不发变更信号 → 声明式绑定 mainPage.itemZoomMap[dataIdx] 永远不会重新求值，
                    //   拖动/滚轮改的值虽然真的写进了 map，但这里的 UI 绑定初次求值后就冻住了（看起来像"功能没了"）。
                    //   改回跟 gridCell.initZoomFromMap() 一样的「本地可写属性 + 显式函数重新读取」模式，
                    //   不依赖 itemZoomMap 的属性变更信号，配合 mainPage.itemZoomRestore(idx) 信号做跨视图同步。
                    property real itemZoom: 1.0
                    property real itemOffX: 0
                    property real itemOffY: 0
                    property bool isHovered: false

                    // 从 itemZoomMap 重新读取并套用到本地属性（列切换/组件创建/收到同步信号时调用）
                    function loadZoomFromMap() {
                        var saved = mainPage.itemZoomMap[dataIdx]
                        if (saved && saved.zoom > 1.0) {
                            itemZoom = saved.zoom
                            var fx = (saved.fx !== undefined) ? saved.fx : 0
                            var fy = (saved.fy !== undefined) ? saved.fy : 0
                            itemOffX = mainPage.itemZoomOffsetPx(saved.zoom, fx, width)
                            itemOffY = mainPage.itemZoomOffsetPx(saved.zoom, fy, height)
                        } else {
                            itemZoom = 1.0
                            itemOffX = 0
                            itemOffY = 0
                        }
                    }
                    Component.onCompleted: loadZoomFromMap()
                    onDataIdxChanged: loadZoomFromMap()  // 切列(Z/X键)复用 delegate 时 dataIdx 会变
                    Connections {
                        target: mainPage
                        function onItemZoomRestore(idx) {
                            if (idx === colPreviewItem.dataIdx) colPreviewItem.loadZoomFromMap()
                        }
                    }
                    
                    x: (index % columnPreviewGrid.layoutCols) * (columnPreviewGrid.cellW + columnPreviewGrid.gridSpacing)
                    y: Math.floor(index / columnPreviewGrid.layoutCols) * (columnPreviewGrid.cellH + columnPreviewGrid.gridSpacing)
                    width: columnPreviewGrid.cellW
                    height: columnPreviewGrid.cellH
                    clip: true
                    
                    Image {
                        id: colPreviewImage
                        // 缩放 + 偏移定位
                        x: parent.width / 2 - width / 2 + colPreviewItem.itemOffX
                        y: parent.height / 2 - height / 2 + colPreviewItem.itemOffY
                        width: parent.width * colPreviewItem.itemZoom
                        height: parent.height * colPreviewItem.itemZoom
                        source: colPreviewItem.dataIdx >= 0
                            ? "image://capture/frame/" + colPreviewItem.dataIdx + "/" + colPreviewItem.displayFrameIdx + "?t=" + columnPreviewRefreshToken
                            : ""
                        fillMode: columnPreviewStretch ? Image.Stretch : Image.PreserveAspectFit
                        cache: false
                        asynchronous: false
                        mirror: mainPage.videoMirrorMode === "horizontal"
                        mirrorVertically: mainPage.videoMirrorMode === "vertical"
                        
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton

                            // ⭐ 2026-07-11：列预览单张也支持左键拖动平移放大后的图（与 item 一致）
                            property bool panning: false
                            property bool panMoved: false
                            property real panLastX: 0
                            property real panLastY: 0
                            property real panStartX: 0
                            property real panStartY: 0
                            readonly property real panThreshold: 4

                            onEntered: {
                                colPreviewItem.isHovered = true
                                columnPreviewHoveredIndex = colPreviewItem.myIndex
                            }
                            onExited: {
                                colPreviewItem.isHovered = false
                                if (columnPreviewHoveredIndex === colPreviewItem.myIndex)
                                    columnPreviewHoveredIndex = -1
                            }
                            
                            onPressed: function(mouse) {
                                if (mouse.button === Qt.LeftButton && (colPreviewItem.itemZoom > 1.0)) {
                                    panning = true; panMoved = false
                                    panLastX = mouse.x; panLastY = mouse.y
                                    panStartX = mouse.x; panStartY = mouse.y
                                }
                            }
                            onPositionChanged: function(mouse) {
                                if (!panning) return
                                if (Math.abs(mouse.x - panStartX) > panThreshold || Math.abs(mouse.y - panStartY) > panThreshold)
                                    panMoved = true
                                var z = colPreviewItem.itemZoom
                                if (z <= 1.0) return
                                var maxX = colPreviewItem.width * (z - 1) / 2
                                var maxY = colPreviewItem.height * (z - 1) / 2
                                var nx = Math.max(-maxX, Math.min(maxX, colPreviewItem.itemOffX + (mouse.x - panLastX)))
                                var ny = Math.max(-maxY, Math.min(maxY, colPreviewItem.itemOffY + (mouse.y - panLastY)))
                                // ⭐ 写回唯一数据源 itemZoomMap + 通知 item 同步（与 item/单个放大一致）
                                mainPage.saveItemZoom(colPreviewItem.dataIdx, z, nx, ny, colPreviewItem.width, colPreviewItem.height)
                                mainPage.itemZoomRestore(colPreviewItem.dataIdx)
                                panLastX = mouse.x; panLastY = mouse.y
                                mouse.accepted = true
                            }
                            onReleased: function(mouse) {
                                if (panning) { panning = false; if (panMoved) mouse.accepted = true }
                            }
                            
                            onClicked: function(mouse) {
                                // ⭐ 刚拖动过 → 不触发切帧
                                if (panMoved) { panMoved = false; return }
                                // ⭐ Ctrl+点击：本列所有 item 同步上/下一帧
                                if (mouse.modifiers & Qt.ControlModifier) {
                                    if (mouse.button === Qt.LeftButton) columnPreviewPrevFrame()
                                    else if (mouse.button === Qt.RightButton) columnPreviewNextFrame()
                                    return
                                }
                                // ⭐ 左键=上一帧，右键=下一帧（单张, 受 frameStep 影响）
                                var idx = colPreviewItem.myIndex
                                var step = mainPage.frameStep
                                var frames = columnPreviewFrames.slice()
                                var total = captureManager.getTotalFrames(colPreviewItem.dataIdx)
                                if (total > 0) {
                                    if (mouse.button === Qt.LeftButton) {
                                        frames[idx] = Math.max(0, (frames[idx] || 0) - step)
                                    } else if (mouse.button === Qt.RightButton) {
                                        frames[idx] = Math.min(total - 1, (frames[idx] || 0) + step)
                                    }
                                    columnPreviewCommitFrames(frames)
                                }
                            }

                            onWheel: function(wheel) {
                                wheel.accepted = true
                                var idx = colPreviewItem.myIndex

                                // ⭐ Ctrl+滚轮：本列所有 item 同步切帧 / 同步缩放
                                if (wheel.modifiers & Qt.ControlModifier) {
                                    if (mainPage.sKeyPressed) {
                                        columnPreviewSyncZoomDelta(wheel.angleDelta.y > 0 ? 0.2 : -0.2)
                                    } else {
                                        if (wheel.angleDelta.y > 0) columnPreviewPrevFrame()
                                        else columnPreviewNextFrame()
                                    }
                                    return
                                }

                                if (mainPage.sKeyPressed) {
                                    // S + 滚轮：以鼠标为中心缩放（单张）→ 直接落 itemZoomMap（唯一数据源）
                                    var oldZoom = colPreviewItem.itemZoom
                                    var delta = wheel.angleDelta.y > 0 ? 0.2 : -0.2
                                    var newZoom = Math.max(1.0, Math.min(5.0, oldZoom + delta))
                                    
                                    if (newZoom !== oldZoom) {
                                        var containerCenterX = colPreviewItem.width / 2
                                        var containerCenterY = colPreviewItem.height / 2
                                        var mouseRelX = colPreviewImage.x + wheel.x - containerCenterX
                                        var mouseRelY = colPreviewImage.y + wheel.y - containerCenterY
                                        var zoomRatio = newZoom / oldZoom
                                        var nOffX = mouseRelX - (mouseRelX - colPreviewItem.itemOffX) * zoomRatio
                                        var nOffY = mouseRelY - (mouseRelY - colPreviewItem.itemOffY) * zoomRatio
                                        if (newZoom === 1.0) { nOffX = 0; nOffY = 0 }
                                        else {
                                            var mX = colPreviewItem.width * (newZoom - 1) / 2
                                            var mY = colPreviewItem.height * (newZoom - 1) / 2
                                            nOffX = Math.max(-mX, Math.min(mX, nOffX))
                                            nOffY = Math.max(-mY, Math.min(mY, nOffY))
                                        }
                                        mainPage.saveItemZoom(colPreviewItem.dataIdx, newZoom, nOffX, nOffY, colPreviewItem.width, colPreviewItem.height)
                                        mainPage.itemZoomRestore(colPreviewItem.dataIdx)
                                    }
                                } else {
                                    // 普通滚轮：切换该张图的帧 (受 frameStep 影响)
                                    var step2 = mainPage.frameStep
                                    var frames = columnPreviewFrames.slice()
                                    var total = captureManager.getTotalFrames(colPreviewItem.dataIdx)
                                    if (total > 0) {
                                        if (wheel.angleDelta.y > 0) {
                                            frames[idx] = Math.max(0, (frames[idx] || 0) - step2)
                                        } else {
                                            frames[idx] = Math.min(total - 1, (frames[idx] || 0) + step2)
                                        }
                                        columnPreviewCommitFrames(frames)
                                    }
                                }
                            }
                        }
                    }
                    
                    // 帧信息（左上角）
                    Text {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: 6
                        text: (colPreviewItem.frameIdx + 1) + "/" + colPreviewItem.totalFrames
                        font.pixelSize: 12
                        font.family: "PingFang HK"
                        color: "#B3FFFFFF"
                        style: Text.Outline
                        styleColor: "#000000"
                    }
                    
                    // 编号（右上角，大号）
                    Rectangle {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6
                        width: 28; height: 28; radius: 14
                        color: "#60000000"
                        Text {
                            anchors.centerIn: parent
                            text: (colPreviewItem.myIndex + 1)
                            font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true
                            color: "#FFFFFF"
                        }
                    }
                    
                    // ⭐ 悬停/选中边框
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.color: colPreviewItem.isHovered ? "#4DB6AC" : "#40FFFFFF"
                        border.width: colPreviewItem.isHovered ? 3 : 1
                    }
                    
                    // 悬停提示：按A放大（⭐ 2026-07-16 上移，给下面新增的进度条让位）
                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottomMargin: 8 + colPreviewFrameBar.height
                        width: zoomHintText.width + 16; height: 24; radius: 12
                        color: "#80000000"
                        visible: colPreviewItem.isHovered
                        Text {
                            id: zoomHintText
                            anchors.centerIn: parent
                            text: "按 A 放大"
                            font.pixelSize: 11; font.family: "PingFang HK"; color: "#CCFFFFFF"
                        }
                    }

                    // ⭐ 2026-07-16：列预览单张——底部切帧进度条（格子小，做成贴底的细条）。
                    //   拖动=只切这一张；Ctrl+拖动=本列所有 item 同步切帧（跟 Ctrl+滚轮效果一致）。
                    Item {
                        id: colPreviewFrameBar
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 20  // ⭐ 2026-07-16：放大一倍（原 10）
                        visible: colPreviewItem.totalFrames > 0 && colPreviewItem.isHovered
                        z: 2

                        property int ctrlLastTarget: colPreviewItem.frameIdx

                        function ratioToFrame(ratio) {
                            var tf = colPreviewItem.totalFrames
                            if (tf <= 0) return 0
                            return Math.round(Math.max(0, Math.min(1, ratio)) * (tf - 1))
                        }
                        function applyCtrlBroadcast(target) {
                            var delta = target - colPreviewFrameBar.ctrlLastTarget
                            colPreviewFrameBar.ctrlLastTarget = target
                            for (var i = 0; i < Math.abs(delta); i++) {
                                if (delta > 0) columnPreviewNextFrame(); else columnPreviewPrevFrame()
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: "#80000000"
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 5
                            height: 6  // ⭐ 放大一倍（原 3）
                            radius: 999
                            color: "#C8E6C9"
                        }
                        Rectangle {
                            id: colPreviewFrameHandle
                            width: 18; height: 18; radius: 9  // ⭐ 放大一倍（原 9/9/4.5）
                            color: "#A5D6A7"
                            anchors.verticalCenter: parent.verticalCenter
                            x: colPreviewItem.totalFrames > 1 ?
                               colPreviewItem.frameIdx / (colPreviewItem.totalFrames - 1) * (parent.width - 18) : 0
                        }
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -3
                            drag.target: colPreviewFrameHandle
                            drag.axis: Drag.XAxis
                            drag.minimumX: 0
                            drag.maximumX: colPreviewFrameBar.width - 18

                            property bool ctrlDrag: false

                            onWheel: function(wheel) {
                                wheel.accepted = true
                                if (colPreviewItem.totalFrames <= 0) return
                                if (wheel.angleDelta.y > 0) columnPreviewJumpSingleFrame(colPreviewItem.myIndex, colPreviewItem.frameIdx - 1)
                                else columnPreviewJumpSingleFrame(colPreviewItem.myIndex, colPreviewItem.frameIdx + 1)
                            }
                            onPressed: function(mouse) {
                                if (colPreviewItem.totalFrames <= 1) return
                                ctrlDrag = !!(mouse.modifiers & Qt.ControlModifier)
                                if (ctrlDrag) {
                                    colPreviewFrameBar.ctrlLastTarget = colPreviewItem.frameIdx
                                } else {
                                    var ratio0 = mouse.x / colPreviewFrameBar.width
                                    columnPreviewJumpSingleFrame(colPreviewItem.myIndex, colPreviewFrameBar.ratioToFrame(ratio0))
                                }
                            }
                            onPositionChanged: {
                                if (!drag.active || colPreviewItem.totalFrames <= 1) return
                                var ratio = colPreviewFrameHandle.x / (colPreviewFrameBar.width - 18)
                                var frame = colPreviewFrameBar.ratioToFrame(ratio)
                                if (ctrlDrag) {
                                    colPreviewFrameBar.applyCtrlBroadcast(frame)
                                } else {
                                    columnPreviewJumpSingleFrame(colPreviewItem.myIndex, frame)
                                }
                            }
                        }
                    }

                }
            }
        }
        
        // ===== 底部操作提示 =====
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            width: colPreviewHintText.width + 32
            height: 36
            color: "#40000000"
            radius: 18
            
            Text {
                id: colPreviewHintText
                anchors.centerIn: parent
                text: "左键/滚轮↑: 上一帧 | 右键/滚轮↓: 下一帧 | ←→: 切帧(全部) | S+滚轮: 缩放 | A: 放大 | Z/X: 上/下列 | Esc: 关闭"
                font.pixelSize: 13
                font.family: "PingFang HK"
                color: "#33FFFFFF"
            }
        }
    }
    
    // ============ 列预览A键放大覆盖层（z:1002，在列预览之上）============
    Rectangle {
        id: columnPreviewZoomOverlay
        anchors.fill: parent
        color: "#EE000000"
        visible: columnPreviewVisible && columnPreviewZoomItemIdx >= 0
        z: 1002
        
        property int zoomDataIdx: columnPreviewZoomItemIdx >= 0 && columnPreviewZoomItemIdx < columnPreviewItems.length
            ? columnPreviewItems[columnPreviewZoomItemIdx] : -1
        property int zoomTotalFrames: zoomDataIdx >= 0 ? captureManager.getTotalFrames(zoomDataIdx) : 0
        // ⭐ 2026-07-16：底部切帧进度条悬停显隐标记，同 fullscreenViewer.progressBarHovered 的思路
        property bool progressBarHovered: false

        // ⭐ 2026-07-14：与 item / 列预览单张 保持三方同步——若该图缩放在别处被改动（如联动缩放），
        //   这里也重新从 itemZoomMap 读取套用（imperative 重载，同 colPreviewItem.loadZoomFromMap）
        Connections {
            target: mainPage
            function onItemZoomRestore(idx) {
                if (idx !== columnPreviewZoomOverlay.zoomDataIdx) return
                var saved = mainPage.itemZoomMap[idx]
                if (saved && saved.zoom > 1.0) {
                    columnPreviewZoomScale = saved.zoom
                    var fx = (saved.fx !== undefined) ? saved.fx : 0
                    var fy = (saved.fy !== undefined) ? saved.fy : 0
                    columnPreviewZoomOffX = mainPage.itemZoomOffsetPx(saved.zoom, fx, zoomImageContainer.width)
                    columnPreviewZoomOffY = mainPage.itemZoomOffsetPx(saved.zoom, fy, zoomImageContainer.height)
                } else {
                    columnPreviewZoomScale = 1.0
                    columnPreviewZoomOffX = 0
                    columnPreviewZoomOffY = 0
                }
            }
        }
        
        // 点击背景关闭放大
        MouseArea {
            anchors.fill: parent
            onClicked: closeColumnPreviewZoom()
            
            onWheel: function(wheel) {
                if (mainPage.sKeyPressed) {
                    // S + 滚轮：缩放
                    var oldZoom = columnPreviewZoomScale
                    var delta = wheel.angleDelta.y > 0 ? 0.2 : -0.2
                    var newZoom = Math.max(1.0, Math.min(5.0, oldZoom + delta))
                    if (newZoom !== oldZoom) {
                        var cx = zoomImageContainer.width / 2
                        var cy = zoomImageContainer.height / 2
                        var mx = wheel.x - cx
                        var my = wheel.y - cy
                        var r = newZoom / oldZoom
                        columnPreviewZoomOffX = mx - (mx - columnPreviewZoomOffX) * r
                        columnPreviewZoomOffY = my - (my - columnPreviewZoomOffY) * r
                        columnPreviewZoomScale = newZoom
                        if (newZoom === 1.0) { columnPreviewZoomOffX = 0; columnPreviewZoomOffY = 0 }
                    }
                } else {
                    // 普通滚轮：切帧
                    if (columnPreviewZoomOverlay.zoomTotalFrames > 0) {
                        if (wheel.angleDelta.y > 0) {
                            columnPreviewZoomGoToFrame(columnPreviewZoomFrame - 1)
                        } else {
                            columnPreviewZoomGoToFrame(columnPreviewZoomFrame + 1)
                        }
                    }
                }
            }
        }
        
        // 图片容器
        Item {
            id: zoomImageContainer
            anchors.centerIn: parent
            width: parent.width
            height: parent.height
            clip: true
            
            Image {
                id: zoomImage
                x: parent.width / 2 - width / 2 + columnPreviewZoomOffX
                y: parent.height / 2 - height / 2 + columnPreviewZoomOffY
                width: parent.width * columnPreviewZoomScale
                height: parent.height * columnPreviewZoomScale
                source: columnPreviewZoomOverlay.zoomDataIdx >= 0
                    ? "image://capture/frame/" + columnPreviewZoomOverlay.zoomDataIdx + "/" + columnPreviewZoomDisplayFrame + "?t=" + columnPreviewRefreshToken
                    : ""
                fillMode: columnPreviewStretch ? Image.Stretch : Image.PreserveAspectFit
                cache: false
                asynchronous: false
                mirror: mainPage.videoMirrorMode === "horizontal"
                mirrorVertically: mainPage.videoMirrorMode === "vertical"
                
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton

                    // ⭐ 2026-07-11：A键单张放大也支持左键拖动平移（与 item 一致）
                    property bool panning: false
                    property bool panMoved: false
                    property real panLastX: 0
                    property real panLastY: 0
                    property real panStartX: 0
                    property real panStartY: 0
                    readonly property real panThreshold: 4

                    onPressed: function(mouse) {
                        if (mouse.button === Qt.LeftButton && columnPreviewZoomScale > 1.0) {
                            panning = true; panMoved = false
                            panLastX = mouse.x; panLastY = mouse.y
                            panStartX = mouse.x; panStartY = mouse.y
                        }
                    }
                    onPositionChanged: function(mouse) {
                        if (!panning) return
                        if (Math.abs(mouse.x - panStartX) > panThreshold || Math.abs(mouse.y - panStartY) > panThreshold)
                            panMoved = true
                        var maxX = zoomImageContainer.width * (columnPreviewZoomScale - 1) / 2
                        var maxY = zoomImageContainer.height * (columnPreviewZoomScale - 1) / 2
                        columnPreviewZoomOffX = Math.max(-maxX, Math.min(maxX, columnPreviewZoomOffX + (mouse.x - panLastX)))
                        columnPreviewZoomOffY = Math.max(-maxY, Math.min(maxY, columnPreviewZoomOffY + (mouse.y - panLastY)))
                        panLastX = mouse.x; panLastY = mouse.y
                        mouse.accepted = true
                    }
                    onReleased: function(mouse) {
                        if (panning) {
                            panning = false
                            if (panMoved) { mouse.accepted = true; syncColumnPreviewZoomToItem() }  // ⭐ 拖动结束同步
                        }
                    }
                    onClicked: function(mouse) {
                        // ⭐ 刚拖动过 → 不触发切帧
                        if (panMoved) { panMoved = false; return }
                        // ⭐ 左键=上一帧，右键=下一帧
                        if (columnPreviewZoomOverlay.zoomTotalFrames > 0) {
                            if (mouse.button === Qt.LeftButton) {
                                columnPreviewZoomGoToFrame(columnPreviewZoomFrame - 1)
                            } else if (mouse.button === Qt.RightButton) {
                                columnPreviewZoomGoToFrame(columnPreviewZoomFrame + 1)
                            }
                        }
                    }
                    onWheel: function(wheel) {
                        if (mainPage.sKeyPressed) {
                            var oldZoom = columnPreviewZoomScale
                            var delta = wheel.angleDelta.y > 0 ? 0.2 : -0.2
                            var newZoom = Math.max(1.0, Math.min(5.0, oldZoom + delta))
                            if (newZoom !== oldZoom) {
                                var cx = zoomImageContainer.width / 2
                                var cy = zoomImageContainer.height / 2
                                var mx = zoomImage.x + wheel.x - cx
                                var my = zoomImage.y + wheel.y - cy
                                var r = newZoom / oldZoom
                                columnPreviewZoomOffX = mx - (mx - columnPreviewZoomOffX) * r
                                columnPreviewZoomOffY = my - (my - columnPreviewZoomOffY) * r
                                columnPreviewZoomScale = newZoom
                                if (newZoom === 1.0) { columnPreviewZoomOffX = 0; columnPreviewZoomOffY = 0 }
                                syncColumnPreviewZoomToItem()  // ⭐ 缩放同步回 itemZoomMap
                            }
                        } else {
                            if (columnPreviewZoomOverlay.zoomTotalFrames > 0) {
                                if (wheel.angleDelta.y > 0) {
                                    columnPreviewZoomGoToFrame(columnPreviewZoomFrame - 1)
                                } else {
                                    columnPreviewZoomGoToFrame(columnPreviewZoomFrame + 1)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // 左上角帧信息
        Text {
            anchors.left: parent.left; anchors.top: parent.top; anchors.margins: 20
            text: (columnPreviewZoomFrame + 1) + "/" + columnPreviewZoomOverlay.zoomTotalFrames + "  [#" + (columnPreviewZoomItemIdx + 1) + "]"
            font.pixelSize: 14; font.family: "PingFang HK"; color: "#B3FFFFFF"
        }
        
        // 右上角关闭按钮
        Rectangle {
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20
            width: 40; height: 40; radius: 20
            color: zoomCloseArea.containsMouse ? "#E53935" : "#40000000"
            Text { anchors.centerIn: parent; text: "✕"; font.pixelSize: 20; color: "#33FFFFFF" }
            MouseArea {
                id: zoomCloseArea
                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: closeColumnPreviewZoom()
            }
        }
        
        // 底部操作提示（⭐ 2026-07-16 上移，给下面新增的进度条让位）
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: columnPreviewZoomProgressBar.top; anchors.bottomMargin: 10
            width: zoomHintBar.width + 32; height: 36; radius: 18
            color: "#40000000"
            Text {
                id: zoomHintBar
                anchors.centerIn: parent
                text: "左键/滚轮↑: 上一帧 | 右键/滚轮↓: 下一帧 | ←→: 切帧 | S+滚轮: 缩放 | 放大后左键拖动: 平移 | A/Esc: 关闭"
                font.pixelSize: 13; font.family: "PingFang HK"; color: "#33FFFFFF"
            }
        }

        // ⭐ 2026-07-16：底部悬停感应区（比进度条本身高一点），只用于显隐判断，不拦截点击/拖动。
        MouseArea {
            id: columnPreviewZoomProgressHoverArea
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 120  // ⭐ 2026-07-16：进度条放大到88后同步加高（原70）
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            z: 50  // ⭐ 2026-07-16 修复闪烁：必须盖在进度条自己之上，理由同 fullscreenProgressHoverArea
            onEntered: columnPreviewZoomOverlay.progressBarHovered = true
            onExited: columnPreviewZoomOverlay.progressBarHovered = false
        }

        // ⭐ 2026-07-16：A键放大——底部切帧进度条，鼠标靠近底部才显示。拖动=只切当前这一张；
        //   Ctrl+拖动=本列所有 item 同步切帧（跟 Ctrl+滚轮效果一致，复用现成的 columnPreviewPrevFrame/NextFrame）。
        // ⭐ 2026-08-14 需求：A 键放大后不再显示滑动条（代码保留）
        Rectangle {
            id: columnPreviewZoomProgressBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 88  // ⭐ 2026-07-16：放大一倍（原 44）
            color: "#80000000"
            visible: false  // 原：columnPreviewZoomOverlay.zoomTotalFrames > 0 && columnPreviewZoomOverlay.progressBarHovered

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 12

                Text {
                    text: (columnPreviewZoomFrame + 1) + "/" + columnPreviewZoomOverlay.zoomTotalFrames
                    font.family: "PingFang HK"
                    font.pixelSize: 18
                    color: "#FFFFFF"
                    Layout.minimumWidth: 90
                }

                Item {
                    id: zoomFrameSliderContainer
                    Layout.fillWidth: true
                    height: 32

                    property int totalFrames: columnPreviewZoomOverlay.zoomTotalFrames
                    property int ctrlLastTarget: columnPreviewZoomFrame

                    function ratioToFrame(ratio) {
                        var tf = zoomFrameSliderContainer.totalFrames
                        if (tf <= 0) return 0
                        return Math.round(Math.max(0, Math.min(1, ratio)) * (tf - 1))
                    }
                    function applyCtrlBroadcast(target) {
                        var delta = target - zoomFrameSliderContainer.ctrlLastTarget
                        zoomFrameSliderContainer.ctrlLastTarget = target
                        for (var i = 0; i < Math.abs(delta); i++) {
                            if (delta > 0) columnPreviewNextFrame(); else columnPreviewPrevFrame()
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onWheel: function(wheel) {
                            wheel.accepted = true
                            if (zoomFrameSliderContainer.totalFrames <= 0) return
                            if (wheel.angleDelta.y > 0) columnPreviewZoomGoToFrame(columnPreviewZoomFrame - 1)
                            else columnPreviewZoomGoToFrame(columnPreviewZoomFrame + 1)
                        }
                        onPressed: function(mouse) {
                            if (zoomFrameSliderContainer.totalFrames <= 1) return
                            var ratio = mouse.x / zoomFrameSliderContainer.width
                            var frame = zoomFrameSliderContainer.ratioToFrame(ratio)
                            if (mouse.modifiers & Qt.ControlModifier) {
                                zoomFrameSliderContainer.ctrlLastTarget = columnPreviewZoomFrame
                                zoomFrameSliderContainer.applyCtrlBroadcast(frame)
                            } else {
                                columnPreviewZoomGoToFrame(frame)
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: 8  // ⭐ 放大一倍（原 4）
                        radius: 999
                        color: "#C8E6C9"
                    }

                    Rectangle {
                        id: zoomFrameHandle
                        width: 32
                        height: 32
                        radius: 16
                        color: "#A5D6A7"
                        x: zoomFrameSliderContainer.totalFrames > 1 ?
                           columnPreviewZoomFrame / (zoomFrameSliderContainer.totalFrames - 1) * (parent.width - 32) : 0
                        anchors.verticalCenter: parent.verticalCenter

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            drag.target: parent
                            drag.axis: Drag.XAxis
                            drag.minimumX: 0
                            drag.maximumX: zoomFrameSliderContainer.width - 32

                            property bool ctrlDrag: false

                            onWheel: function(wheel) {
                                wheel.accepted = true
                                if (zoomFrameSliderContainer.totalFrames <= 0) return
                                if (wheel.angleDelta.y > 0) columnPreviewZoomGoToFrame(columnPreviewZoomFrame - 1)
                                else columnPreviewZoomGoToFrame(columnPreviewZoomFrame + 1)
                            }
                            onPressed: function(mouse) {
                                ctrlDrag = !!(mouse.modifiers & Qt.ControlModifier)
                                if (ctrlDrag) zoomFrameSliderContainer.ctrlLastTarget = columnPreviewZoomFrame
                            }
                            onPositionChanged: {
                                if (!drag.active || zoomFrameSliderContainer.totalFrames <= 1) return
                                var ratio = zoomFrameHandle.x / (zoomFrameSliderContainer.width - 32)
                                var frame = zoomFrameSliderContainer.ratioToFrame(ratio)
                                if (ctrlDrag) {
                                    zoomFrameSliderContainer.applyCtrlBroadcast(frame)
                                } else {
                                    columnPreviewZoomGoToFrame(frame)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // ============ 快捷键处理（使用 Shortcut 组件更可靠）============
    
    // Grid全屏快捷键（2026-08-14 需求：老 java gstream 没有抓拍全屏 → 不触发，代码保留）
    Shortcut {
        sequence: ShortcutStore.gridFullscreenKey
        enabled: false
        onActivated: toggleGridFullscreen()
    }
    
    // 实时窗口切换快捷键
    Shortcut {
        sequence: ShortcutStore.realtimeWindowKey
        onActivated: swapRealtimeWindow()
    }
    
    // 慢放窗口切换快捷键
    Shortcut {
        sequence: ShortcutStore.slowmoWindowKey
        onActivated: swapSlowmoWindow()
    }
    
    // 全屏查看关闭快捷键（A键和ESC已在上方统一定义）
    
    // ============ 窗口切换函数 ============
    
    // Grid全屏切换：左侧占满宽度，右侧隐藏
    function toggleGridFullscreen() {
        // ⭐ PC等级1(豪华版)：不允许手动打开抓拍全屏
        if (mainPage.pcActivationLevel < 2) {
            console.log("[抓拍全屏] PC等级1不允许手动打开抓拍全屏")
            return
        }
        
        // ⭐ 变化前的状态（在进入全屏前立即获取，确保是最新的）
        var beforeTop = rightTopHolder.height
        var beforeMiddle = rightMiddleHolder.height
        var beforeTotal = beforeTop + beforeMiddle
        var beforeHeightRatio = beforeTotal > 0 ? beforeTop / beforeTotal : 0
        
        // ⭐ 保存左右分割的宽度比例
        var beforeRightWidth = rightPanel.width
        var beforeTotalWidth = mainSplitView.width
        var beforeWidthRatio = beforeTotalWidth > 0 ? beforeRightWidth / beforeTotalWidth : 0.25
        
        console.log("[抓拍全屏] ====== 切换前 ======")
        console.log("[抓拍全屏] top高度:", beforeTop, "middle高度:", beforeMiddle, "总高度:", beforeTotal, "高度比例:", beforeHeightRatio)
        console.log("[抓拍全屏] rightPanel宽度:", beforeRightWidth, "总宽度:", beforeTotalWidth, "宽度比例:", beforeWidthRatio)
        console.log("[抓拍全屏] 当前 gridFullscreenMode:", gridFullscreenMode)
        
        if (!gridFullscreenMode) {
            // ⭐ 进入全屏前：先停止防抖 Timer，立即保存当前实际比例
            saveHeightRatioTimer.stop()
            saveWidthRatioTimer.stop()
            
            // ⭐ 立即保存当前高度比例（包括用户拖动后的最新比例）
            savedHeightRatio = beforeHeightRatio
            
            // ⭐ 立即保存当前宽度比例（包括用户拖动后的最新比例）
            savedWidthRatio = beforeWidthRatio
            
            console.log("[抓拍全屏] 进入全屏，立即保存高度比例:", savedHeightRatio, "top=", beforeTop, "middle=", beforeMiddle, "total=", beforeTotal)
            console.log("[抓拍全屏] 进入全屏，立即保存宽度比例:", savedWidthRatio, "rightPanel=", beforeRightWidth, "total=", beforeTotalWidth)
        }
        
        gridFullscreenMode = !gridFullscreenMode
        console.log("[抓拍全屏] Grid全屏模式:", gridFullscreenMode)
        
        // 延迟打印变化后的状态
        afterChangeTimer.start()
        
        if (!gridFullscreenMode) {
            // ⭐ 退出全屏后：延迟恢复比例（确保布局已经完成）
            console.log("[抓拍全屏] 退出全屏，准备恢复比例:", savedHeightRatio)
            ratioRestoreTimer.start()
        }
    }
    
    Timer {
        id: afterChangeTimer
        interval: 100
        onTriggered: {
            var afterTop = rightTopHolder.height
            var afterMiddle = rightMiddleHolder.height
            var afterTotal = afterTop + afterMiddle
            var afterRatio = afterTotal > 0 ? afterTop / afterTotal : 0
            console.log("====== 切换后(100ms) ======")
            console.log("top高度:", afterTop, "middle高度:", afterMiddle, "总高度:", afterTotal, "比例:", afterRatio)
        }
    }
    
    Timer {
        id: ratioRestoreTimer
        interval: 100  // 减少延迟，更快恢复
        onTriggered: {
            // ⭐ 设置恢复标志，避免触发自动保存
            isRestoringRatio = true
            isRestoringWidthRatio = true
            
            // ⭐ 先恢复宽度比例（左右分割）
            var totalWidth = mainSplitView.width
            if (totalWidth > 0 && savedWidthRatio > 0 && savedWidthRatio <= 1) {
                var newRightWidth = totalWidth * savedWidthRatio
                console.log("[抓拍全屏] 恢复宽度: rightPanel=", newRightWidth, "total=", totalWidth, "比例=", savedWidthRatio)
                rightPanel.SplitView.preferredWidth = newRightWidth
            }
            
            // ⭐ 再恢复高度比例（上下分割）
            var topHeight = rightTopHolder.height
            var middleHeight = rightMiddleHolder.height
            var totalHeight = topHeight + middleHeight
            var currentRatio = totalHeight > 0 ? topHeight / totalHeight : 0
            console.log("[抓拍全屏] ====== 恢复前(100ms) ======")
            console.log("[抓拍全屏] top高度:", topHeight, "middle高度:", middleHeight, "总高度:", totalHeight)
            console.log("[抓拍全屏] 当前高度比例:", currentRatio, "目标高度比例:", savedHeightRatio)
            
            if (totalHeight > 0 && savedHeightRatio > 0 && savedHeightRatio <= 1) {
                var newTopHeight = totalHeight * savedHeightRatio
                var newMiddleHeight = totalHeight * (1 - savedHeightRatio)
                console.log("[抓拍全屏] 设置高度: top=", newTopHeight, "middle=", newMiddleHeight, "total=", totalHeight)
                
                // ⭐ 直接设置 preferredHeight，SplitView 会自动调整
                rightTopHolder.SplitView.preferredHeight = newTopHeight
                rightMiddleHolder.SplitView.preferredHeight = newMiddleHeight
                
                // 再延迟打印恢复后的状态
                afterRestoreTimer.start()
            } else {
                console.log("[抓拍全屏] 无法恢复高度: totalHeight=", totalHeight, "savedHeightRatio=", savedHeightRatio)
                // 如果无法恢复，也要清除标志
                isRestoringRatio = false
                isRestoringWidthRatio = false
            }
        }
    }
    
    Timer {
        id: afterRestoreTimer
        interval: 150  // 增加延迟，确保 SplitView 完成调整
        onTriggered: {
            var afterTop = rightTopHolder.height
            var afterMiddle = rightMiddleHolder.height
            var afterTotal = afterTop + afterMiddle
            var afterHeightRatio = afterTotal > 0 ? afterTop / afterTotal : 0
            
            var afterRightWidth = rightPanel.width
            var afterTotalWidth = mainSplitView.width
            var afterWidthRatio = afterTotalWidth > 0 ? afterRightWidth / afterTotalWidth : 0
            
            console.log("[抓拍全屏] ====== 恢复后(250ms) ======")
            console.log("[抓拍全屏] top高度:", afterTop, "middle高度:", afterMiddle, "总高度:", afterTotal, "高度比例:", afterHeightRatio)
            console.log("[抓拍全屏] rightPanel宽度:", afterRightWidth, "总宽度:", afterTotalWidth, "宽度比例:", afterWidthRatio)
            console.log("[抓拍全屏] 目标高度比例:", savedHeightRatio, "误差:", Math.abs(afterHeightRatio - savedHeightRatio))
            console.log("[抓拍全屏] 目标宽度比例:", savedWidthRatio, "误差:", Math.abs(afterWidthRatio - savedWidthRatio))
            
            // ⭐ 如果高度恢复不准确，再次尝试恢复
            if (afterTotal > 0 && savedHeightRatio > 0 && Math.abs(afterHeightRatio - savedHeightRatio) > 0.01) {
                console.log("[抓拍全屏] 高度恢复不准确，再次尝试恢复")
                var newTopHeight2 = afterTotal * savedHeightRatio
                var newMiddleHeight2 = afterTotal * (1 - savedHeightRatio)
                rightTopHolder.SplitView.preferredHeight = newTopHeight2
                rightMiddleHolder.SplitView.preferredHeight = newMiddleHeight2
            }
            
            // ⭐ 如果宽度恢复不准确，再次尝试恢复
            if (afterTotalWidth > 0 && savedWidthRatio > 0 && Math.abs(afterWidthRatio - savedWidthRatio) > 0.01) {
                console.log("[抓拍全屏] 宽度恢复不准确，再次尝试恢复")
                var newRightWidth2 = afterTotalWidth * savedWidthRatio
                rightPanel.SplitView.preferredWidth = newRightWidth2
            }
            
            // ⭐ 恢复完成，清除恢复标志
            Qt.callLater(function() {
                isRestoringRatio = false
                isRestoringWidthRatio = false
                console.log("[抓拍全屏] 恢复完成")
            })
        }
    }
    
    // 实时窗口切换：抓拍grid <-> 实时流
    function swapRealtimeWindow() {
        if (windowLayoutMode === 1) {
            // 当前是实时窗口模式，切换回默认
            windowLayoutMode = 0
        } else {
            // 切换到实时窗口模式
            windowLayoutMode = 1
        }
        console.log("实时窗口切换，当前模式:", windowLayoutMode)
    }
    
    // 慢放窗口切换：抓拍grid <-> 慢放
    function swapSlowmoWindow() {
        if (windowLayoutMode === 2) {
            // 当前是慢放窗口模式，切换回默认
            windowLayoutMode = 0
        } else {
            // 切换到慢放窗口模式
            windowLayoutMode = 2
        }
        console.log("慢放窗口切换，当前模式:", windowLayoutMode)
    }
    
    // ============ Toast 提示框 ============
    Rectangle {
        id: toastContainer
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 100
        width: toastText.width + 40
        height: 44
        radius: 22
        color: "#E0000000"
        visible: false
        z: 10000
        
        Text {
            id: toastText
            anchors.centerIn: parent
            text: ""
            font.family: "PingFang HK"
            font.pixelSize: 14
            color: "#FFFFFF"
        }
        
        opacity: 0
        
        Behavior on opacity {
            NumberAnimation { duration: 200 }
        }
    }
    
    Timer {
        id: toastTimer
        interval: 2000
        onTriggered: {
            toastContainer.opacity = 0
            toastHideTimer.start()
        }
    }
    
    Timer {
        id: toastHideTimer
        interval: 200
        onTriggered: {
            toastContainer.visible = false
        }
    }
    
    function showToast(message) {
        toastText.text = message
        toastContainer.visible = true
        toastContainer.opacity = 1
        toastTimer.restart()
    }
    
    // ============ 切换账号对话框 ============
    Dialog {
        id: switchAccountDialog
        anchors.centerIn: parent
        width: 500
        height: 500
        modal: true
        
        property var accountList: []
        property var deviceMap: ({})  // {username: [device1, device2, ...]}
        property string currentUsername: ""
        property string currentDeviceUsername: ""
        property bool isLoading: false
        property var currentDevices: deviceMap[currentUsername] || []

        // ⭐ 2026-08-15 需求：去掉标题栏「设备号」显示，圆角 25（50 太大改小）
        background: Rectangle {
            color: "#1F1F1F"
            radius: 25
            border.color: "#3A3A3A"
            border.width: 1
        }
        
        header: Item {
            height: 50

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                Text {
                    text: "账号管理"
                    font.family: "PingFang HK"
                    font.pixelSize: 18
                    font.bold: true
                    color: "#FAFAFA"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            
            // 刷新按钮
            Rectangle {
                anchors.right: switchCloseBtn.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 60
                height: 28
                radius: 4
                color: switchRefreshBtnArea.containsMouse ? "#374151" : "#292929"
                
                Text {
                    anchors.centerIn: parent
                    text: switchAccountDialog.isLoading ? "加载中" : "🔄 刷新"
                    font.pixelSize: 12
                    color: "#FAFAFA"
                }
                
                MouseArea {
                    id: switchRefreshBtnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!switchAccountDialog.isLoading) {
                            refreshOnlineStatus()
                        }
                    }
                }
            }
            
            // 关闭按钮（圆角后稍往里挪，避免压到弧线）
            Rectangle {
                id: switchCloseBtn
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: 14
                color: switchCloseArea.containsMouse ? "#374151" : "transparent"
                
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    font.pixelSize: 14
                    color: "#FAFAFA"
                }
                
                MouseArea {
                    id: switchCloseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: switchAccountDialog.close()
                }
            }
            
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#3A3A3A"
            }
        }
        
        contentItem: Item {
            Column {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 16
                
                // 当前账号信息（独立显示）
                Rectangle {
                    width: parent.width
                    height: 60
                    radius: 8
                    color: "#2a3a5a"
                    border.color: "#607AFB"
                    border.width: 2
                    
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 12
                        
                        // 头像
                        Rectangle {
                            width: 36
                            height: 36
                            radius: 18
                            color: "#F8F8F8"
                            clip: true
                            
                            Image {
                                anchors.fill: parent
                                source: "images/head.png"
                                fillMode: Image.PreserveAspectCrop
                            }
                        }
                        
                        // 账号信息
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            
                            Text {
                                text: switchAccountDialog.currentUsername || "未登录"
                                font.family: "PingFang HK"
                                font.pixelSize: 15
                                font.bold: true
                                color: "#FFFFFF"
                            }
                            
                            Text {
                                property int deviceCount: switchAccountDialog.currentDevices.length
                                property int onlineCount: {
                                    var count = 0
                                    for (var i = 0; i < switchAccountDialog.currentDevices.length; i++) {
                                        if (switchAccountDialog.currentDevices[i].online) count++
                                    }
                                    return count
                                }
                                text: deviceCount > 0 
                                    ? deviceCount + " 个设备，" + onlineCount + " 个在线" 
                                    : "未绑定设备"
                                font.family: "PingFang HK"
                                font.pixelSize: 12
                                color: "#64748b"
                            }
                        }
                        
                        // 当前标记
                        Rectangle {
                            width: 50
                            height: 22
                            radius: 11
                            color: "#607AFB"
                            
                            Text {
                                anchors.centerIn: parent
                                text: "当前"
                                font.pixelSize: 11
                                color: "#FFFFFF"
                            }
                        }
                    }
                }
                
                // 绑定设备列表标题
                Text {
                    text: "绑定的设备"
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    font.bold: true
                    color: "#FAFAFA"
                    visible: switchAccountDialog.currentDevices.length > 0
                }
                
                // 设备列表（直接显示，不需要展开）
                ListView {
                    id: deviceListView
                    width: parent.width
                    height: parent.height - 120
                    clip: true
                    model: switchAccountDialog.currentDevices
                    spacing: 8
                    
                    delegate: Rectangle {
                        id: deviceItem
                        width: deviceListView.width
                        height: 48
                        radius: 6
                        color: deviceItemMouseArea.containsMouse ? "#3a3a3a" : "#1F1F1F"
                        // ⭐ 当前使用的判断：必须是当前登录账号 + 当前设备
                        // 注意：switchAccountDialog.currentUsername 是选中的标签页账号
                        // HttpClient.getSavedUsername() 是真正登录的账号
                        // switchAccountDialog.currentDeviceUsername 是打开对话框时获取的当前设备
                        property bool isCurrentDevice: {
                            var loggedInUsername = HttpClient.getSavedUsername() || ""
                            var loggedInDeviceUsername = HttpClient.getSavedDeviceUsername() || ""
                            return switchAccountDialog.currentUsername === loggedInUsername && 
                                   modelData.deviceUsername === loggedInDeviceUsername
                        }
                        border.color: isCurrentDevice ? "#607AFB" : "#3A3A3A"
                        border.width: isCurrentDevice ? 2 : 1
                        property string deviceDisplayName: {
                            var baseName = modelData.deviceNickname || modelData.deviceUsername || "未知设备"
                            // ⭐ 备注放在昵称后面
                            if (modelData.remark) {
                                baseName = baseName + " (" + modelData.remark + ")"
                            }
                            // ⭐ 设备后面标注平台（iOS / Android）——按 deviceId 的 android 前缀判断
                            return baseName + " · " + HttpClient.deviceTypeLabel(modelData.deviceId || "")
                        }
                        
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 8
                            spacing: 8
                            
                            // 在线状态点
                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                color: modelData.online ? "#34C759" : "#666666"
                            }

                            // 设备名称
                            Text {
                                Layout.fillWidth: true
                                text: deviceItem.deviceDisplayName
                                font.family: "PingFang HK"
                                font.pixelSize: 13
                                color: "#FFFFFF"
                                elide: Text.ElideRight
                            }

                            // ⭐ 设备激活等级徽章 — 2026-08-14 叫法对齐 java gstream / aihj 后端
                            //   等级只区分分辨率：0=试用, 1=高清, 2=4K（与后端 User.getActivationLevelName 一致）
                            //   颜色: 试用=灰, 高清=绿, 4K=橙
                            Rectangle {
                                visible: modelData.activationLevel !== undefined && modelData.activationLevel !== null
                                width: levelBadgeText.implicitWidth + 12
                                height: 20
                                radius: 10
                                property int lvl: modelData.activationLevel || 0
                                property string lvlText: {
                                    switch (lvl) {
                                        case 1: return "高清"
                                        case 2: return "4K"
                                        default: return "试用"
                                    }
                                }
                                color: {
                                    if (lvl >= 2) return "#FFF3E0"   // 4K — 浅橙
                                    if (lvl === 1) return "#E8F5E9"  // 高清 — 浅绿
                                    return "#F0F0F0"                  // 试用 — 灰
                                }
                                border.width: 1
                                border.color: {
                                    if (lvl >= 2) return "#FFB74D"
                                    if (lvl === 1) return "#81C784"
                                    return "#BDBDBD"
                                }

                                Text {
                                    id: levelBadgeText
                                    anchors.centerIn: parent
                                    text: parent.lvlText
                                    font.family: "PingFang HK"
                                    font.pixelSize: 10
                                    font.bold: true
                                    color: {
                                        // parent = 外层 Rectangle, 直接读它定义的 lvl
                                        if (parent.lvl >= 4) return "#C62828"
                                        if (parent.lvl === 3) return "#E65100"
                                        if (parent.lvl === 2) return "#1565C0"
                                        if (parent.lvl === 1) return "#2E7D32"
                                        return "#757575"
                                    }
                                }
                            }
                            
                            // 当前使用标记
                            Rectangle {
                                visible: deviceItem.isCurrentDevice
                                width: 60
                                height: 20
                                radius: 10
                                color: "#2a3a5a"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "当前使用"
                                    font.pixelSize: 10
                                    color: "#607AFB"
                                }
                            }
                            
                            // ⭐ 移除在线状态文字（已有绿灯指示）
                            
                            // 备注按钮
                            Rectangle {
                                width: 36
                                height: 24
                                radius: 4
                                color: remarkBtnMouseArea.containsMouse ? "#4a4a4a" : "#3a3a3a"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "备注"
                                    font.pixelSize: 11
                                    color: remarkBtnMouseArea.containsMouse ? "#FFFFFF" : "#94a3b8"
                                }
                                
                                MouseArea {
                                    id: remarkBtnMouseArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        showRemarkDialog(
                                            switchAccountDialog.currentUsername,
                                            modelData.deviceUsername || "",
                                            modelData.remark || "",
                                            modelData.deviceNickname || modelData.deviceUsername || "未知设备"
                                        )
                                    }
                                }
                            }
                            
                            // ⭐ 2026-08-14 aihj：隐藏「修改密码」（aihj 后端无 /binding/change-device-password），换成「解绑」文字按钮对齐老 java gstream
                            //   解绑接口仍在：POST /api/binding/windows-unbind/{bindingId}（ai-device-control-demo DeviceBindingController）
                            Rectangle {
                                width: 44
                                height: 24
                                radius: 4
                                color: unbindBtnMouseArea.containsMouse ? "#4a4a4a" : "#3a3a3a"
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "解绑"
                                    font.pixelSize: 11
                                    color: unbindBtnMouseArea.containsMouse ? "#FFFFFF" : "#94a3b8"
                                }
                                
                                MouseArea {
                                    id: unbindBtnMouseArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        console.log("📍 解绑点击 - modelData:", JSON.stringify(modelData))
                                        var bindingId = modelData.bindingId
                                        console.log("📍 解绑点击 - bindingId:", bindingId, "类型:", typeof bindingId)
                                        if (!bindingId && bindingId !== 0) {
                                            showToast("无法获取绑定信息，请刷新后重试")
                                            return
                                        }
                                        showUnbindConfirmDialog(
                                            bindingId,
                                            modelData,
                                            modelData.deviceNickname || modelData.deviceUsername || "未知设备"
                                        )
                                    }
                                }
                            }
                        }
                        
                        MouseArea {
                            id: deviceItemMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            z: -1
                            onClicked: {
                                if (!deviceItem.isCurrentDevice) {
                                    switchToAccountWithDevice(modelData, switchAccountDialog.currentUsername)
                                }
                            }
                        }
                    }
                }
                
                // 无设备提示
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: switchAccountDialog.currentDevices.length === 0 && !switchAccountDialog.isLoading
                    text: "暂无绑定设备"
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#64748b"
                }
            }
            
            // 加载中提示
            Rectangle {
                anchors.fill: parent
                color: "#CC1F1F1F"
                visible: switchAccountDialog.isLoading
                
                Text {
                    anchors.centerIn: parent
                    text: "正在加载设备信息..."
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#FAFAFA"
                }
            }
        }
        
        footer: Item { height: 12 }
    }
    
    // 监听在线状态接口响应
    Connections {
        target: HttpClient
        
        function onOnlineStatusReceived(list) {
            console.log("📥 OnlineStatus received:", list.length, "devices")
            switchAccountDialog.isLoading = false
            
            // 按 controlUsername 分组
            var deviceMap = {}
            for (var i = 0; i < list.length; i++) {
                var item = list[i]
                console.log("📥 Device", i, "- bindingId:", item.bindingId, 
                            "deviceUsername:", item.deviceUsername, 
                            "online:", item.online)
                var controlUsername = item.controlUsername || ""
                if (!deviceMap[controlUsername]) {
                    deviceMap[controlUsername] = []
                }
                deviceMap[controlUsername].push(item)
            }
            
            // ⭐ 每个账号下的设备按在线状态排序：在线的排前面
            var keys = Object.keys(deviceMap)
            for (var k = 0; k < keys.length; k++) {
                deviceMap[keys[k]].sort(function(a, b) {
                    return (b.online ? 1 : 0) - (a.online ? 1 : 0)
                })
            }
            
            switchAccountDialog.deviceMap = deviceMap

            // ⭐ 2026-07-15：登录后自动打开弹框的这次，在线状态一到就自动执行一次切换（仅当目标设备在线）
            if (mainPage.pendingAutoDeviceSwitch) {
                mainPage.pendingAutoDeviceSwitch = false
                mainPage.tryAutoSwitchToSelectedDevice(list)
            }
        }
        
        function onOnlineStatusFailed(code, message) {
            console.log("❌ OnlineStatus failed:", code, message)
            switchAccountDialog.isLoading = false
            showToast("获取设备状态失败")
            mainPage.pendingAutoDeviceSwitch = false
        }
        
        function onSetRemarkSuccess(controlUsername, deviceUsername, remark) {
            console.log("✅ SetRemark success:", controlUsername, deviceUsername, remark)
            showToast("备注设置成功")
            refreshOnlineStatus()
        }
        
        function onSetRemarkFailed(code, message) {
            console.log("❌ SetRemark failed:", code, message)
            showToast("设置备注失败: " + message)
        }
        
        function onUnbindSuccess(bindingId, message) {
            console.log("✅ Unbind success - bindingId:", bindingId, "message:", message)
            showToast("解绑成功: " + message)
            
            // ⭐ 检查被解绑的设备是否是当前正在拉流的设备
            var unbindedDeviceUsername = unbindConfirmDialog.deviceData ? unbindConfirmDialog.deviceData.deviceUsername : ""
            var currentDeviceUsername = HttpClient.getSavedDeviceUsername()
            
            console.log("📍 解绑检查 - 被解绑设备:", unbindedDeviceUsername, "当前拉流设备:", currentDeviceUsername)
            
            if (unbindedDeviceUsername && currentDeviceUsername && unbindedDeviceUsername === currentDeviceUsername) {
                console.log("⚠️ 解绑的是当前正在拉流的设备，停止拉流...")
                // ⭐ §53.10：走统一收口（停流+清屏+复位读数），别再各写一份
                markDeviceOffline("当前拉流设备被解绑", "设备已解绑")
            }
            
            refreshOnlineStatus()
        }
        
        function onUnbindFailed(code, message) {
            console.log("❌ Unbind failed - code:", code, "message:", message)
            showToast("解绑失败: (" + code + ") " + message)
        }
        
        function onChangePasswordSuccess(deviceUsername, message, notifyCount, unbindCount) {
            console.log("✅ ChangePassword success:", deviceUsername, message, "notifyCount:", notifyCount, "unbindCount:", unbindCount)
            var toastMsg = message
            if (unbindCount > 0) {
                toastMsg += " (已解绑 " + unbindCount + " 个其他PC端)"
            }
            showToast(toastMsg)
        }
        
        function onChangePasswordFailed(code, message) {
            console.log("❌ ChangePassword failed:", code, message)
            showToast("修改密码失败: " + message)
        }

        function onChangeLoginPasswordSuccess(message) {
            console.log("✅ ChangeLoginPassword success:", message)
            changeLoginPasswordDialog.close()
            showToast(message && message.length > 0 ? message : "登录密码修改成功")
        }

        function onChangeLoginPasswordFailed(code, message) {
            console.log("❌ ChangeLoginPassword failed:", code, message)
            showToast("修改登录密码失败: " + message)
        }
    }
    
    // ============ 设置备注对话框 ============
    Dialog {
        id: remarkDialog
        anchors.centerIn: parent
        width: 360
        height: 200
        modal: true
        
        property string controlUsername: ""
        property string deviceUsername: ""
        property string currentRemark: ""
        property string deviceName: ""
        
        background: Rectangle {
            color: "#1F1F1F"
            radius: 12
            border.color: "#3A3A3A"
            border.width: 1
        }
        
        header: Item {
            height: 50
            
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                text: "设置备注 - " + remarkDialog.deviceName
                font.family: "PingFang HK"
                font.pixelSize: 16
                font.bold: true
                color: "#FAFAFA"
                elide: Text.ElideRight
                width: parent.width - 60
            }
            
            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: 14
                color: remarkCloseArea.containsMouse ? "#3A3A3A" : "transparent"
                
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    font.pixelSize: 14
                    color: "#AAAAAA"
                }
                
                MouseArea {
                    id: remarkCloseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: remarkDialog.close()
                }
            }
            
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#3A3A3A"
            }
        }
        
        contentItem: Column {
            spacing: 16
            padding: 20
            
            TextField {
                id: remarkInput
                width: parent.width - 40
                height: 40
                placeholderText: "请输入备注（可为空）"
                placeholderTextColor: "#777777"
                text: remarkDialog.currentRemark
                font.pixelSize: 14
                color: "#FAFAFA"
                background: Rectangle {
                    color: "#2A2A2A"
                    radius: 4
                    border.color: remarkInput.activeFocus ? "#3993D2" : "#3A3A3A"
                    border.width: 1
                }
            }
            
            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter
                
                Rectangle {
                    width: 100
                    height: 36
                    radius: 4
                    color: remarkCancelArea.containsMouse ? "#3A3A3A" : "#2A2A2A"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.pixelSize: 14
                        color: "#CCCCCC"
                    }
                    
                    MouseArea {
                        id: remarkCancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: remarkDialog.close()
                    }
                }
                
                Rectangle {
                    width: 100
                    height: 36
                    radius: 4
                    color: remarkConfirmArea.containsMouse ? "#2E7AB8" : "#3993D2"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "确定"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: remarkConfirmArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var newRemark = remarkInput.text.trim()
                            HttpClient.setRemark(
                                remarkDialog.controlUsername,
                                remarkDialog.deviceUsername,
                                newRemark
                            )
                            remarkDialog.close()
                        }
                    }
                }
            }
        }
        
        footer: Item { height: 1 }
    }
    
    // 显示备注对话框
    function showRemarkDialog(controlUsername, deviceUsername, currentRemark, deviceName) {
        remarkDialog.controlUsername = typeof controlUsername === 'string' ? controlUsername : HttpClient.getSavedUsername()
        remarkDialog.deviceUsername = deviceUsername
        remarkDialog.currentRemark = currentRemark || ""
        remarkDialog.deviceName = deviceName
        remarkInput.text = currentRemark || ""
        remarkDialog.open()
    }
    
    // ============ 修改密码对话框 ============
    Dialog {
        id: changePasswordDialog
        anchors.centerIn: parent
        width: 360
        height: 420
        modal: true
        title: ""
        
        property string controlUsername: ""
        property string deviceUsername: ""
        property string deviceName: ""
        
        background: Rectangle {
            color: "#FFFFFF"
            radius: 12
            border.color: "#A5D6A7"
            border.width: 1
        }
        
        header: Item {
            width: parent.width
            height: 50
            
            Text {
                anchors.centerIn: parent
                text: "修改密码"
                font.family: "PingFang HK"
                font.pixelSize: 16
                font.bold: true
                color: "#263238"
            }
            
            Rectangle {
                width: parent.width
                height: 1
                anchors.bottom: parent.bottom
                color: "#E8F5E9"
            }
        }
        
        contentItem: Column {
            spacing: 12
            padding: 20
            
            // 设备名称
            Text {
                text: "设备: " + changePasswordDialog.deviceName
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#666666"
            }
            
            // 当前绑定码
            Column {
                spacing: 6
                width: parent.width - 40
                
                Text {
                    text: "当前绑定码"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#333333"
                }
                
                Rectangle {
                    width: parent.width
                    height: 40
                    radius: 6
                    border.color: currentPasswordInput.activeFocus ? "#3993D2" : "#E0E0E0"
                    border.width: currentPasswordInput.activeFocus ? 2 : 1
                    
                    TextInput {
                        id: currentPasswordInput
                        anchors.fill: parent
                        anchors.margins: 10
                        anchors.rightMargin: 36   // §56.8 给眼睛按钮留位
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        // §56.8 需求：默认明文显示，点眼睛可切换隐藏
                        property bool showPlain: true
                        echoMode: showPlain ? TextInput.Normal : TextInput.Password
                        clip: true
                        verticalAlignment: TextInput.AlignVCenter
                        
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "请输入当前绑定码"
                            color: "#AAAAAA"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            visible: parent.text.length === 0 && !parent.activeFocus
                        }
                    }
                    // §56.8 明/密文切换眼睛
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: currentPasswordInput.showPlain ? "👁" : "🙈"
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: currentPasswordInput.showPlain = !currentPasswordInput.showPlain
                        }
                    }
                }
            }
            
            // 新登录密码
            Column {
                spacing: 6
                width: parent.width - 40
                
                Text {
                    text: "新登录密码（留空=不修改）"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#333333"
                }
                
                Rectangle {
                    width: parent.width
                    height: 40
                    radius: 6
                    border.color: newLoginPasswordInput.activeFocus ? "#3993D2" : "#E0E0E0"
                    border.width: newLoginPasswordInput.activeFocus ? 2 : 1
                    
                    TextInput {
                        id: newLoginPasswordInput
                        anchors.fill: parent
                        anchors.margins: 10
                        anchors.rightMargin: 36
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        // §56.8 默认明文，点眼睛切换
                        property bool showPlain: true
                        echoMode: showPlain ? TextInput.Normal : TextInput.Password
                        clip: true
                        verticalAlignment: TextInput.AlignVCenter
                        
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "不填 = 登录密码保持不变"
                            color: "#AAAAAA"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            visible: parent.text.length === 0 && !parent.activeFocus
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: newLoginPasswordInput.showPlain ? "👁" : "🙈"
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: newLoginPasswordInput.showPlain = !newLoginPasswordInput.showPlain
                        }
                    }
                }
            }
            
            // 新绑定码
            Column {
                spacing: 6
                width: parent.width - 40
                
                Text {
                    text: "新绑定码（留空=保持当前）"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#333333"
                }
                
                Rectangle {
                    width: parent.width
                    height: 40
                    radius: 6
                    border.color: newPasswordInput.activeFocus ? "#3993D2" : "#E0E0E0"
                    border.width: newPasswordInput.activeFocus ? 2 : 1
                    
                    TextInput {
                        id: newPasswordInput
                        anchors.fill: parent
                        anchors.margins: 10
                        anchors.rightMargin: 36
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        // §56.8 默认明文，点眼睛切换
                        property bool showPlain: true
                        echoMode: showPlain ? TextInput.Normal : TextInput.Password
                        clip: true
                        verticalAlignment: TextInput.AlignVCenter
                        
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "不填 = 绑定码保持当前"
                            color: "#AAAAAA"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            visible: parent.text.length === 0 && !parent.activeFocus
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: newPasswordInput.showPlain ? "👁" : "🙈"
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: newPasswordInput.showPlain = !newPasswordInput.showPlain
                        }
                    }
                }
            }
            
            // 按钮行
            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter
                
                // 取消按钮
                Rectangle {
                    width: 100
                    height: 36
                    radius: 6
                    color: cancelPwdBtnArea.containsMouse ? "#F0F0F0" : "#FAFAFA"
                    border.color: "#A5D6A7"
                    border.width: 1
                    
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#546E7A"
                    }
                    
                    MouseArea {
                        id: cancelPwdBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: changePasswordDialog.close()
                    }
                }
                
                // 确认按钮
                Rectangle {
                    width: 100
                    height: 36
                    radius: 6
                    color: confirmPwdBtnArea.containsMouse ? "#2E7BB8" : "#3993D2"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "确认修改"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: confirmPwdBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var currentSecondaryPwd = currentPasswordInput.text.trim()
                            var newLoginPwd = newLoginPasswordInput.text.trim()
                            var newSecondaryPwd = newPasswordInput.text.trim()
                            
                            if (currentSecondaryPwd.length === 0) {
                                showToast("请输入当前绑定码")
                                return
                            }
                            
                            // 两个"新"字段都可留空 = 该项不修改（后端 changeDevicePasswordByControl 对空值直接跳过）
                            if (newLoginPwd.length > 20) {
                                showToast("新登录密码最长20位")
                                return
                            }
                            if (newSecondaryPwd.length > 20) {
                                showToast("新绑定码最长20位")
                                return
                            }
                            // 两项都留空 = 什么都不改。此时不能调接口空跑：后端一旦成功就会
                            // 解绑其他所有 PC 端（changeDevicePasswordByControl 第 8 步），
                            // 没改密码却把别人踢下线属于误伤。
                            if (newLoginPwd.length === 0 && newSecondaryPwd.length === 0) {
                                changePasswordDialog.close()
                                showToast("未填写新密码，登录密码与绑定码保持不变")
                                return
                            }
                            
                            HttpClient.changeDevicePassword(
                                changePasswordDialog.controlUsername,
                                changePasswordDialog.deviceUsername,
                                currentSecondaryPwd,
                                newLoginPwd,
                                newSecondaryPwd
                            )
                            changePasswordDialog.close()
                            showToast("正在修改密码...")
                        }
                    }
                }
            }
        }
        
        footer: Item { height: 1 }
    }
    
    // 显示修改密码对话框
    function showChangePasswordDialog(controlUsername, deviceUsername, deviceName) {
        changePasswordDialog.controlUsername = controlUsername
        changePasswordDialog.deviceUsername = deviceUsername
        changePasswordDialog.deviceName = deviceName
        currentPasswordInput.text = ""
        newLoginPasswordInput.text = ""
        newPasswordInput.text = ""
        changePasswordDialog.open()
    }

    // ============ 修改当前登录账号密码对话框 ============
    Dialog {
        id: changeLoginPasswordDialog
        anchors.centerIn: parent
        width: 360
        height: 360
        modal: true
        title: ""

        background: Rectangle {
            color: "#FFFFFF"
            radius: 12
            border.color: "#A5D6A7"
            border.width: 1
        }

        header: Item {
            width: parent.width
            height: 50
            Text {
                anchors.centerIn: parent
                text: "修改登录密码"
                font.family: "PingFang HK"
                font.pixelSize: 16
                font.bold: true
                color: "#263238"
            }
            Rectangle {
                width: parent.width
                height: 1
                anchors.bottom: parent.bottom
                color: "#E8F5E9"
            }
        }

        contentItem: Column {
            spacing: 12
            padding: 20

            Text {
                text: "账号: " + (HttpClient.loggedInUsername() || "")
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#666666"
            }

            // 当前登录密码
            Column {
                spacing: 6
                width: parent.width - 40
                Text {
                    text: "当前登录密码"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#333333"
                }
                Rectangle {
                    width: parent.width
                    height: 40
                    radius: 6
                    border.color: oldLoginPwdInput.activeFocus ? "#3993D2" : "#E0E0E0"
                    border.width: oldLoginPwdInput.activeFocus ? 2 : 1
                    TextInput {
                        id: oldLoginPwdInput
                        anchors.fill: parent
                        anchors.margins: 10
                        anchors.rightMargin: 36
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        // §56.8 默认明文，点眼睛切换
                        property bool showPlain: true
                        echoMode: showPlain ? TextInput.Normal : TextInput.Password
                        clip: true
                        verticalAlignment: TextInput.AlignVCenter
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "请输入当前登录密码"
                            color: "#AAAAAA"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            visible: parent.text.length === 0 && !parent.activeFocus
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: oldLoginPwdInput.showPlain ? "👁" : "🙈"
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: oldLoginPwdInput.showPlain = !oldLoginPwdInput.showPlain
                        }
                    }
                }
            }

            // 新登录密码
            Column {
                spacing: 6
                width: parent.width - 40
                Text {
                    text: "新登录密码 (1-20位)"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#333333"
                }
                Rectangle {
                    width: parent.width
                    height: 40
                    radius: 6
                    border.color: newLoginPwdInput2.activeFocus ? "#3993D2" : "#E0E0E0"
                    border.width: newLoginPwdInput2.activeFocus ? 2 : 1
                    TextInput {
                        id: newLoginPwdInput2
                        anchors.fill: parent
                        anchors.margins: 10
                        anchors.rightMargin: 36
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        // §56.8 默认明文，点眼睛切换
                        property bool showPlain: true
                        echoMode: showPlain ? TextInput.Normal : TextInput.Password
                        clip: true
                        verticalAlignment: TextInput.AlignVCenter
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "请输入新登录密码"
                            color: "#AAAAAA"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            visible: parent.text.length === 0 && !parent.activeFocus
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: newLoginPwdInput2.showPlain ? "👁" : "🙈"
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: newLoginPwdInput2.showPlain = !newLoginPwdInput2.showPlain
                        }
                    }
                }
            }

            // 确认新登录密码
            Column {
                spacing: 6
                width: parent.width - 40
                Text {
                    text: "确认新登录密码"
                    font.family: "PingFang HK"
                    font.pixelSize: 13
                    color: "#333333"
                }
                Rectangle {
                    width: parent.width
                    height: 40
                    radius: 6
                    border.color: confirmLoginPwdInput.activeFocus ? "#3993D2" : "#E0E0E0"
                    border.width: confirmLoginPwdInput.activeFocus ? 2 : 1
                    TextInput {
                        id: confirmLoginPwdInput
                        anchors.fill: parent
                        anchors.margins: 10
                        anchors.rightMargin: 36
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        // §56.8 默认明文，点眼睛切换
                        property bool showPlain: true
                        echoMode: showPlain ? TextInput.Normal : TextInput.Password
                        clip: true
                        verticalAlignment: TextInput.AlignVCenter
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "请再次输入新登录密码"
                            color: "#AAAAAA"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            visible: parent.text.length === 0 && !parent.activeFocus
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: confirmLoginPwdInput.showPlain ? "👁" : "🙈"
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: confirmLoginPwdInput.showPlain = !confirmLoginPwdInput.showPlain
                        }
                    }
                }
            }

            // 按钮行
            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    width: 100
                    height: 36
                    radius: 6
                    color: cancelLoginPwdBtnArea.containsMouse ? "#F0F0F0" : "#FAFAFA"
                    border.color: "#A5D6A7"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#546E7A"
                    }
                    MouseArea {
                        id: cancelLoginPwdBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: changeLoginPasswordDialog.close()
                    }
                }

                Rectangle {
                    width: 100
                    height: 36
                    radius: 6
                    color: confirmLoginPwdBtnArea.containsMouse ? "#2E7BB8" : "#3993D2"
                    Text {
                        anchors.centerIn: parent
                        text: "确认修改"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    MouseArea {
                        id: confirmLoginPwdBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var oldPwd = oldLoginPwdInput.text.trim()
                            var newPwd = newLoginPwdInput2.text.trim()
                            var confirmPwd = confirmLoginPwdInput.text.trim()

                            if (oldPwd.length === 0) {
                                showToast("请输入当前登录密码")
                                return
                            }
                            if (newPwd.length < 1 || newPwd.length > 20) {
                                showToast("新登录密码长度需为1-20位")
                                return
                            }
                            if (newPwd !== confirmPwd) {
                                showToast("两次输入的新密码不一致")
                                return
                            }
                            HttpClient.changeLoginPassword(oldPwd, newPwd)
                            showToast("正在修改登录密码...")
                        }
                    }
                }
            }
        }

        footer: Item { height: 1 }
    }

    // 显示修改登录密码对话框
    function showChangeLoginPasswordDialog() {
        oldLoginPwdInput.text = ""
        newLoginPwdInput2.text = ""
        confirmLoginPwdInput.text = ""
        changeLoginPasswordDialog.open()
    }
    
    // ============ 抓拍清空确认对话框 ============
    // ⭐ 2026-08-14 对齐老 Java 深色风格（同「确认解绑」弹框：#1F1F1F 底/#3A3A3A 边框/#FAFAFA 文字）
    // ⭐ 2026-08-15 需求：弹框加大、说明字体加大、层次感分明（主句大字加粗 / 提示小字弱化分行）
    Dialog {
        id: clearCaptureConfirmDialog
        anchors.centerIn: parent
        width: 440
        height: 250
        modal: true
        
        background: Rectangle {
            color: "#1F1F1F"
            radius: 12
            border.color: "#3A3A3A"
            border.width: 1
        }
        
        header: Item {
            height: 56
            
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "确认清空"
                font.family: "PingFang HK"
                font.pixelSize: 19
                font.bold: true
                color: "#FAFAFA"
            }
            
            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: 14
                color: clearCaptureCloseArea.containsMouse ? "#3A3A3A" : "transparent"
                
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    font.pixelSize: 14
                    color: "#999999"
                }
                
                MouseArea {
                    id: clearCaptureCloseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: clearCaptureConfirmDialog.close()
                }
            }
            
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#3A3A3A"
            }
        }
        
        contentItem: Column {
            spacing: 10
            padding: 24
            
            // 主句：大字加粗，最醒目
            Text {
                width: parent.width - 48
                text: "确定要清空所有抓拍内容吗？"
                font.family: "PingFang HK"
                font.pixelSize: 18
                font.bold: true
                color: "#FAFAFA"
                wrapMode: Text.Wrap
            }
            
            // 提示：小一号、弱化色，与主句拉开层次（⭐ 需求#8 红字空格键提示保留）
            Text {
                width: parent.width - 48
                text: "提示：按 <font color='#E53935'><b>空格键</b></font> 可直接确认清空"
                textFormat: Text.RichText
                font.family: "PingFang HK"
                font.pixelSize: 14
                color: "#999999"
                wrapMode: Text.Wrap
            }
            
            Item { width: 1; height: 8 }
            
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 20
                
                Rectangle {
                    width: 120
                    height: 42
                    radius: 6
                    color: clearCaptureCancelArea.containsMouse ? "#3A3A3A" : "#292929"
                    border.color: "#3A3A3A"
                    border.width: 1
                    
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        color: "#CCCCCC"
                    }
                    
                    MouseArea {
                        id: clearCaptureCancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: clearCaptureConfirmDialog.close()
                    }
                }
                
                Rectangle {
                    width: 120
                    height: 42
                    radius: 6
                    color: clearCaptureConfirmArea.containsMouse ? "#D32F2F" : "#E53935"
                    
                    Text {
                        anchors.centerIn: parent
                        // ⭐ 2026-08-14：去掉「(空格键)」字样（Space 快捷键仍有效，弹框内红字有提示）
                        text: "确认清空"
                        font.family: "PingFang HK"
                        font.pixelSize: 15
                        font.bold: true
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: clearCaptureConfirmArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // 清空抓拍
                            captureManager.clearAll()
                            clearCaptureConfirmDialog.close()
                            console.log("🗑️ 抓拍已清空")
                        }
                    }
                }
            }
        }
    }
    
    // ============ 解绑确认对话框 ============
    Dialog {
        id: unbindConfirmDialog
        anchors.centerIn: parent
        width: 360
        height: 200
        modal: true
        
        property var bindingId: 0  // 使用 var 以支持大整数（Java Long类型）
        property var deviceData: null
        property string deviceName: ""
        
        background: Rectangle {
            color: "#1F1F1F"
            radius: 12
            border.color: "#3A3A3A"
            border.width: 1
        }
        
        header: Item {
            height: 50
            
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                text: "确认解绑"
                font.family: "PingFang HK"
                font.pixelSize: 16
                font.bold: true
                color: "#FAFAFA"
            }
            
            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: 14
                color: unbindCloseArea.containsMouse ? "#3A3A3A" : "transparent"
                
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    font.pixelSize: 14
                    color: "#AAAAAA"
                }
                
                MouseArea {
                    id: unbindCloseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: unbindConfirmDialog.close()
                }
            }
            
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#3A3A3A"
            }
        }
        
        contentItem: Column {
            spacing: 16
            padding: 20
            
            Text {
                width: parent.width - 40
                text: "确定要解绑设备「" + unbindConfirmDialog.deviceName + "」吗？\n解绑后需要重新在iOS端扫码或手动绑定。"
                font.family: "PingFang HK"
                font.pixelSize: 14
                color: "#DDDDDD"
                wrapMode: Text.WordWrap
            }
            
            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter
                
                Rectangle {
                    width: 100
                    height: 36
                    radius: 4
                    color: unbindCancelArea.containsMouse ? "#3A3A3A" : "#2A2A2A"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.pixelSize: 14
                        color: "#CCCCCC"
                    }
                    
                    MouseArea {
                        id: unbindCancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: unbindConfirmDialog.close()
                    }
                }
                
                Rectangle {
                    width: 100
                    height: 36
                    radius: 4
                    color: unbindConfirmArea.containsMouse ? "#CC0000" : "#E53935"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "确认解绑"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: unbindConfirmArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var username = HttpClient.getSavedUsername()
                            var password = HttpClient.getAccountPassword(username)
                            console.log("📍 确认解绑 - username:", username)
                            console.log("📍 确认解绑 - password长度:", password ? password.length : 0)
                            console.log("📍 确认解绑 - bindingId:", unbindConfirmDialog.bindingId)
                            if (!password) {
                                showToast("无法获取账号密码，请重新登录")
                                unbindConfirmDialog.close()
                                return
                            }
                            if (!unbindConfirmDialog.bindingId && unbindConfirmDialog.bindingId !== 0) {
                                showToast("绑定ID无效")
                                unbindConfirmDialog.close()
                                return
                            }
                            console.log("📍 发送解绑请求 - bindingId:", unbindConfirmDialog.bindingId, "passwordLen:", password.length)
                            HttpClient.windowsUnbind(unbindConfirmDialog.bindingId, password)
                            unbindConfirmDialog.close()
                            showToast("正在解绑...")
                        }
                    }
                }
            }
        }
        
        footer: Item { height: 1 }
    }
    
    // 显示解绑确认对话框
    function showUnbindConfirmDialog(bindingId, deviceData, deviceName) {
        unbindConfirmDialog.bindingId = bindingId
        unbindConfirmDialog.deviceData = deviceData
        unbindConfirmDialog.deviceName = deviceName
        unbindConfirmDialog.open()
    }
    
    // 刷新在线状态
    function refreshOnlineStatus() {
        var accounts = switchAccountDialog.accountList
        if (accounts.length === 0) return
        
        switchAccountDialog.isLoading = true
        HttpClient.getOnlineStatus(accounts)
    }
    
    // 显示切换账号对话框
    function showSwitchAccountDialog() {
        var accounts = HttpClient.getSavedAccounts()
        switchAccountDialog.accountList = accounts
        switchAccountDialog.currentUsername = HttpClient.getSavedUsername()
        switchAccountDialog.currentDeviceUsername = HttpClient.getSavedDeviceUsername()
        switchAccountDialog.deviceMap = {}
        switchAccountDialog.open()
        
        // 自动加载设备状态
        refreshOnlineStatus()
    }

    // ⭐ 2026-07-15：登录后自动切回选中设备——在拿到在线状态列表后，找到"当前选中的iOS账号"，
    //   仅当它在线才自动执行一次切换；找不到 / 不在线则什么都不做（弹框留给用户手动处理）。
    function tryAutoSwitchToSelectedDevice(list) {
        var username = HttpClient.getSavedUsername()
        var deviceUsername = HttpClient.getSavedDeviceUsername()
        if (!username || !deviceUsername) {
            console.log("🔄 [自动切换] 无已选中的iOS账号，跳过")
            return
        }
        for (var i = 0; i < list.length; i++) {
            var item = list[i]
            if ((item.controlUsername || "") === username && (item.deviceUsername || "") === deviceUsername) {
                if (item.online) {
                    console.log("🔄 [自动切换] 选中设备在线，自动执行一次切换: " + deviceUsername)
                    switchToAccountWithDevice(item, username)
                } else {
                    console.log("🔄 [自动切换] 选中设备不在线，不执行切换: " + deviceUsername)
                }
                return
            }
        }
        console.log("🔄 [自动切换] 未在绑定列表中找到选中设备，跳过: " + deviceUsername)
    }
    
    // 切换到指定账号（无设备时）
    function switchToAccount(username) {
        var password = HttpClient.getAccountPassword(username)
        if (!password) {
            showToast("账号密码已失效，请重新登录")
            return
        }
        
        switchAccountDialog.close()
        showToast("正在切换账号...")
        
        // 停止当前流（§53.10 统一清场）
        resetStreamStateForSwitch("切换账号")
        
        // ⭐ 清理 frames 目录和抓拍列表
        gstPlayer.clearJpegFiles()
        captureManager.clearAll()
        
        // ⭐ 重置档位显示（避免残留上一账号的档位）
        iosCameraSettingsPopup.qualityType = "ultra"
        qualityButtonText.text = "高清"

        // ⭐ 第五十章：相机能力跟着设备走，切账号一律清空重拉
        CameraCapsStore.clear()
        otgCameraPanel.close()
        
        // 断开 WebSocket
        WebSocketClient.disconnectFromServer()
        
        // ⭐ 设置切换设备标志，以便登录成功后重连 WebSocket 并刷新配置
        isSwitchingDevice = true
        switchingUsername = username
        switchingPassword = password
        switchingDeviceUsername = ""
        switchingDeviceDisplay = ""
        
        // 重新登录（保持当前等级）
        HttpClient.login(username, password, mainPage.pcActivationLevel || 1)
    }
    
    // 切换到指定账号的指定设备
    function switchToAccountWithDevice(device, username) {
        var deviceUsername = device.deviceUsername || ""
        
        // 检查是否是同一账号同一设备，如果是则忽略
        // ⭐ 2026-07-15 修正：这里必须比对"本次登录实际绑定的设备"(currentDeviceUsername)，
        //   不能比对"上次选中保存的设备"(getSavedDeviceUsername)——登录时不传设备账号，
        //   后端会默认绑到第一个绑定设备，可能跟保存的选中设备不是同一个，
        //   若仍拿 getSavedDeviceUsername 比较，会永远判定为"同一设备"而误跳过真正需要的切换。
        var currentUsername = HttpClient.loggedInUsername()
        var currentDeviceUsername = HttpClient.currentDeviceUsername()
        if (username === currentUsername && deviceUsername === currentDeviceUsername) {
            console.log("📌 同一账号同一设备（已实际绑定），忽略切换")
            switchAccountDialog.close()
            return
        }
        
        var password = HttpClient.getAccountPassword(username)
        if (!password) {
            showToast("账号密码已失效，请重新登录")
            return
        }
        
        switchAccountDialog.close()
        showToast("正在切换到 " + (device.deviceNickname || deviceUsername) + "...")
        
        console.log("🔄 切换账号: 停止当前流...")
        // 停止当前流、清空慢放、清空抓拍（§53.10 统一清场）
        resetStreamStateForSwitch("切换到指定设备")
        
        // ⭐ 清理 frames 目录和抓拍列表
        console.log("🔄 切换账号: 清理 frames 目录和抓拍列表...")
        gstPlayer.clearJpegFiles()
        captureManager.clearAll()
        
        // ⭐ 重置档位显示（避免残留上一账号的档位）
        iosCameraSettingsPopup.qualityType = "ultra"
        qualityButtonText.text = "高清"

        // ⭐ 第五十章：相机能力跟着设备走——切设备必须清空并关掉 OTG 面板，
        //   新设备的 CONFIG_STATE 一到（cameraMode/capsVersion）会自动重新索要
        CameraCapsStore.clear()
        otgCameraPanel.close()
        
        console.log("🔄 切换账号: 断开 WebSocket...")
        // 断开 WebSocket (STOMP)
        WebSocketClient.disconnectFromServer()
        
        // ⭐ 设置切换设备标志，以便登录成功后保存设备信息
        isSwitchingDevice = true
        switchingUsername = username
        switchingPassword = password
        switchingDeviceUsername = deviceUsername
        switchingDeviceDisplay = device.deviceNickname || deviceUsername
        
        console.log("🔄 切换账号: 重新登录 username=" + username + " device=" + deviceUsername)
        // 重新登录（传入设备账号，保持当前等级）
        HttpClient.login(username, password, mainPage.pcActivationLevel || 1, deviceUsername)
    }
    
    // 退出登录
    function handleLogout() {
        console.log("🚪 退出登录: 开始...")
        
        // 停止当前流（§53.10 统一清场）
        resetStreamStateForSwitch("退出登录")
        
        // ⭐ 清理 frames 目录和抓拍列表
        console.log("🚪 退出登录: 清理 frames 目录和抓拍列表...")
        gstPlayer.clearJpegFiles()
        captureManager.clearAll()
        
        // ⭐ 第五十章：清空相机能力 + 关掉 OTG 面板
        CameraCapsStore.clear()
        otgCameraPanel.close()

        console.log("🚪 退出登录: 断开 WebSocket...")
        // 断开 WebSocket
        WebSocketClient.disconnectFromServer()
        
        // 退出登录（只清除token，保留账号列表）
        HttpClient.logout()
        
        console.log("🚪 退出登录: 完成，返回登录页")
        showToast("已退出登录")

        // 触发信号，返回登录页
        logoutRequested()
    }

    // ============ ⭐ iOS 滤镜设定 Window（独立窗口，可拖动）============
    //   STOMP 直推 iOS, 不绕后端 HTTP. 正式后端没有 IosFilterController,
    //   所以这里去掉了"保存为系统默认"按钮和登录默认值拉取.
    Window {
        id: iosFilterPopup
        width: iosFilterPopup.pcFreeConfig ? 920 : 560
        height: 820
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "transparent"
        visible: false

        // 兼容 Popup 的 open/close
        //   open 时把 PC 当前默认值同步到 iOS (确保 redBoost=0.02 等锁死值生效)
        function open()  {
            visible = true
            if (typeof ifGainSlider !== 'undefined')
                ifGainSlider.value = iosFilterPopup.fGain
            if (typeof ifFilterWhiteBalanceSlider !== 'undefined')
                ifFilterWhiteBalanceSlider.value = iosCameraSettingsPopup.hardwareWhiteBalance
            // ⭐ 打开弹框只在「该账号第一次」自动下发；之后重开不再覆盖设备当前状态
            tryAutoPush()
        }
        function close() { visible = false }

        // ⭐ 联动编号输入弹框
        Dialog {
            id: groupIdDialog
            title: "设置联动编号"
            modal: true
            anchors.centerIn: parent
            width: 260; height: 160
            standardButtons: Dialog.Ok | Dialog.Cancel
            onAccepted: {
                var v = parseInt(groupIdSpinBox.value)
                if (isNaN(v) || v < 0) v = 0
                if (v > 100) v = 100
                var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig))
                lc[iosFilterPopup.editingGroupParam].groupId = v
                iosFilterPopup.linkageConfig = lc
            }
            Column {
                anchors.fill: parent; spacing: 12
                Text { text: "输入编号 0-100（0=不联动）"; font.family: "PingFang HK"; font.pixelSize: 14; color: "#546E7A" }
                SpinBox {
                    id: groupIdSpinBox
                    from: 0; to: 100; value: iosFilterPopup.groupIdInput
                    editable: true
                    width: 200
                }
            }
        }

        // 拖动状态
        property point dragStart: Qt.point(0, 0)
        property bool dragging: false

        // ⭐ 滤镜参数（默认值规格 — 启动时从总后台动态拉取覆盖）
        //   滑块值直接 = 发给 iOS 的值 (无派生公式)
        //   曝光: PC 端展示线性倍数, 发给 iOS 时 Math.log2() 转 EV stops
        //   红色增强: 锁死, 无滑块
        property double fBrightness: 1.10
        property double fGamma:      1.10
        property double fContrast:   1.10
        property double fSaturation: 1.10
        property double fExposure:   1.10
        property double fRedBoost:   0.02
        property double fBlackPoint: 0.10   // ⭐ 默认 0.10 压死 limited-range 伪黑 (黑色不再灰)
        property bool   fEnabled:    false

        // ⭐ 玉麒麟 LUT（5 张 png，STOMP ptype=lutName + test_mode 开关）
        property bool   lutEnabled: true
        property string selectedLutName: "lookup"
        property bool   videoHDREnabled: false
        property bool   autoHDREnabled: false
        // ⭐ 硬件链路开关（增益 + 白平衡；白平衡始终自动，只手动纠正才下发）
        property bool   hardwareEnabled: true
        // ⭐ 三链路开关由后端 GET /api/config/ios-pipeline 的 switches 初始化（两者都要：后端初始化 + 操作员可改，下发以弹框开关为准）
        // ⭐ 账号级「第一次下发」：滤镜默认值 + 三链路开关都加载完、且该账号尚未推过时，才自动推一次
        property string lastAutoPushAccount: ""
        property bool   filterLoaded: false
        property bool   pipelineLoaded: false
        // autoWhiteBalanceEnabled 已移除 — 改为"运用白平衡"单次触发
        readonly property var lutOptions: [
            { name: "lookup",                 label: "标准" },
            { name: "lookup_soft_elegance_1", label: "柔雅1" },
            { name: "lookup_soft_elegance_2", label: "柔雅2" },
            { name: "lookup_amatorka",        label: "Amatorka" },
            { name: "lookup_miss_etikate",    label: "Etikate" }
        ]

        // ⭐ 上下限 / 步进 / 出厂默认 — 跟默认值一样从后台动态拉取 (硬编码仅作 server fetch 失败时的 fallback)
        property double brightnessFrom: 0.8;   property double brightnessTo: 2.0;   property double brightnessStep: 0.02; property double brightnessDefault: 1.10
        property double gammaFrom:      0.8;   property double gammaTo:      2.0;   property double gammaStep:      0.01; property double gammaDefault:      1.10
        property double contrastFrom:   0.8;   property double contrastTo:   1.30;  property double contrastStep:   0.02; property double contrastDefault:   1.10
        property double saturationFrom: 0.0;   property double saturationTo: 2.0;   property double saturationStep: 0.02; property double saturationDefault: 1.10
        property double exposureFrom:   0.6;   property double exposureTo:   1.6;   property double exposureStep:   0.02; property double exposureDefault:   1.10
        property double redBoostDefault: 0.02
        property double blackPointDefault: 0.10   // ⭐ 后台可调; 压 H.264 limited-range 伪黑
        // ⭐ 玉麒麟扩展参数
        property double sharpnessFrom: 0;   property double sharpnessTo: 1.0;  property double sharpnessStep: 0.05; property double sharpnessDefault: 0.20
        property double highlightLiftFrom: 0; property double highlightLiftTo: 1.0; property double highlightLiftStep: 0.02; property double highlightLiftDefault: 0.0
        // ⭐ 色度（黄色拉白，保留红色）— 独立滑块, 不参与综合联动
        property double chromaFrom: 0.0; property double chromaTo: 1.0; property double chromaStep: 0.05; property double chromaDefault: 0.0
        property double fSharpness: 0.20
        property double fHighlightLift: 0.0
        property double fChroma: 0.0
        property double prevSharpness: 0.20
        property double prevHighlightLift: 0.0
        property double prevChroma: 0.0

        // ⭐ 增益（从硬件参数区移入滤镜统一联动）
        property double gainFrom: 0; property double gainTo: 100; property double gainStep: 1; property double gainDefault: 20
        property double fGain: 20
        property double prevGain: 20

        // ⭐ 联动分组模式（替代旧的 boolean 联动）
        //   groupId(1-100): 同编号参数组成联动组, 0=不参与
        //   groupDirection(-1/1): -1=向左, 1=向右
        //   brightSwitch: 综合亮度联动开关（后台配置）
        //   brightDirection(-1/1): 综合亮度方向
        //   pcFreeConfig: 后台开关, 打开后 PC 端显示方向配置
        property bool pcFreeConfig: false
        property var linkageConfig: ({
            brightness:    { groupEnabled: true, groupId: 1, groupDirection: -1, brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            gamma:         { groupEnabled: true, groupId: 1, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            contrast:      { groupEnabled: true, groupId: 0, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            saturation:    { groupEnabled: true, groupId: 0, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            exposure:      { groupEnabled: true, groupId: 0, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            sharpness:     { groupEnabled: true, groupId: 0, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            highlightLift: { groupEnabled: true, groupId: 0, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            chroma:        { groupEnabled: true, groupId: 0, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 },
            gain:          { groupEnabled: true, groupId: 0, groupDirection: 1,  brightSwitch: false, brightDirection: 1, brightContrastSwitch: false, brightContrastDirection: 1, brightExposureSwitch: false, brightExposureDirection: 1 }
        })
        property var linkageConfigDefault: null
        property string editingGroupParam: ""
        property int groupIdInput: 0
        property bool restorePushPending: false
        property string pendingIosPushReason: ""

        // ⭐ 滤镜 / LUT / 硬件 统一下发入口：固定延迟 2s（首推、还原、STOMP 连上兜底共用）
        //   §56.13 延迟 1s→2s：给"别的 PC 的 PC_PRESENCE（每秒一条）"留一个完整到达周期，
        //   加入观看时才能准确判定是不是多人场景。
        Timer {
            id: unifiedIosPushTimer
            interval: 2000
            repeat: false
            onTriggered: {
                var reason = iosFilterPopup.pendingIosPushReason
                iosFilterPopup.pendingIosPushReason = ""
                // ⭐ §56.13b 第二台 PC 加入观看（SRS 多人）：下发前主动问后端观看数，
                //   count>0（已有别的 PC 在看）→ 跳过账号首推，只拉流不下发任何参数
                //  （否则会把第一台正在看的画面参数全量重置）。
                //   仅拦「account-first」自动首推；还原/手动路径 reason 不同，照常下发。
                if (mainPage.connectMode === 0 && reason === "account-first") {
                    mainPage.queryViewerCountThen(function(count) {
                        if (count > 0) {
                            console.log("⏭️ [iOS] §56.13b 后端确认已有 " + count + " 台PC在观看，跳过自动参数下发(account-first)，仅拉流")
                            return
                        }
                        console.log("⬆️ [iOS] 统一下发(" + reason + "): 滤镜/LUT/硬件（后端确认观看数=0）")
                        iosFilterPopup.pushAllStomp()
                    })
                    return
                }
                console.log("⬆️ [iOS] 统一下发(" + reason + "): 滤镜/LUT/硬件")
                iosFilterPopup.pushAllStomp()
            }
        }

        function scheduleUnifiedIosPush(reason) {
            pendingIosPushReason = reason || ""
            unifiedIosPushTimer.restart()
        }

        // 还原等强制全量：不检查 lastAutoPushAccount，仍走 1s 统一下发
        function requestDelayedIosPush(reason) {
            if (!filterLoaded || !pipelineLoaded) {
                console.warn("⏳ [iOS] 配置未齐，跳过延迟下发:", reason)
                return
            }
            scheduleUnifiedIosPush(reason || "manual")
        }

        // ⭐ 应用从后台拉到的默认配置 JSON
        //   后端 GET /api/config/ios-filter-defaults 返回 { config: "<JSON>" }
        //   解析后覆盖 popup 上述属性, 滑块自动 rebind
        function applyServerDefaults(configJson) {
            var c
            try { c = JSON.parse(configJson) }
            catch (e) { console.warn("🎨 [iOS-Filter] 后台默认值 JSON 解析失败:", e); return }

            // ⭐ PC端自由配置开关
            if (c.pcFreeConfig && c.pcFreeConfig.enabled !== undefined)
                iosFilterPopup.pcFreeConfig = c.pcFreeConfig.enabled

            function applyOne(key, fromProp, toProp, stepProp, defaultProp, currProp, prevProp) {
                if (!c[key]) return
                var entry = c[key]
                if (entry.from      !== undefined) iosFilterPopup[fromProp]    = entry.from
                if (entry.to        !== undefined) iosFilterPopup[toProp]      = entry.to
                if (entry.stepSize  !== undefined) iosFilterPopup[stepProp]    = entry.stepSize
                if (entry.default   !== undefined) {
                    iosFilterPopup[defaultProp] = entry.default
                    iosFilterPopup[currProp]    = entry.default
                    iosFilterPopup[prevProp]    = entry.default
                }
            }
            applyOne("brightness",    "brightnessFrom",    "brightnessTo",    "brightnessStep",    "brightnessDefault",    "fBrightness",    "prevBrightness")
            applyOne("gamma",         "gammaFrom",         "gammaTo",         "gammaStep",         "gammaDefault",         "fGamma",         "prevGamma")
            applyOne("contrast",      "contrastFrom",      "contrastTo",      "contrastStep",      "contrastDefault",      "fContrast",      "prevContrast")
            applyOne("saturation",    "saturationFrom",    "saturationTo",    "saturationStep",    "saturationDefault",    "fSaturation",    "prevSaturation")
            applyOne("exposure",      "exposureFrom",      "exposureTo",      "exposureStep",      "exposureDefault",      "fExposure",      "prevExposure")
            applyOne("sharpness",     "sharpnessFrom",     "sharpnessTo",     "sharpnessStep",     "sharpnessDefault",     "fSharpness",     "prevSharpness")
            applyOne("highlightLift", "highlightLiftFrom", "highlightLiftTo", "highlightLiftStep", "highlightLiftDefault", "fHighlightLift", "prevHighlightLift")
            applyOne("chroma",        "chromaFrom",        "chromaTo",        "chromaStep",        "chromaDefault",        "fChroma",        "prevChroma")
            applyOne("gain",          "gainFrom",          "gainTo",          "gainStep",          "gainDefault",          "fGain",          "prevGain")

            // ⭐ 联动分组配置
            var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig))
            var params = ["brightness", "gamma", "contrast", "saturation", "exposure", "sharpness", "highlightLift", "chroma", "gain"]
            for (var i = 0; i < params.length; i++) {
                var key = params[i]
                if (c[key]) {
                    if (c[key].groupEnabled !== undefined) lc[key].groupEnabled = c[key].groupEnabled
                    if (c[key].groupId !== undefined) lc[key].groupId = c[key].groupId
                    if (c[key].groupDirection !== undefined) lc[key].groupDirection = c[key].groupDirection
                    if (c[key].brightSwitch !== undefined) lc[key].brightSwitch = c[key].brightSwitch
                    if (c[key].brightDirection !== undefined) lc[key].brightDirection = c[key].brightDirection
                    if (c[key].brightContrastSwitch !== undefined) lc[key].brightContrastSwitch = c[key].brightContrastSwitch
                    if (c[key].brightContrastDirection !== undefined) lc[key].brightContrastDirection = c[key].brightContrastDirection
                    if (c[key].brightExposureSwitch !== undefined) lc[key].brightExposureSwitch = c[key].brightExposureSwitch
                    if (c[key].brightExposureDirection !== undefined) lc[key].brightExposureDirection = c[key].brightExposureDirection
                }
            }
            iosFilterPopup.linkageConfig = lc
            iosFilterPopup.linkageConfigDefault = JSON.parse(JSON.stringify(lc))

            if (c.redBoost && c.redBoost.locked !== undefined) {
                iosFilterPopup.redBoostDefault = c.redBoost.locked
                iosFilterPopup.fRedBoost       = c.redBoost.locked
            }
            if (c.blackPoint && c.blackPoint.locked !== undefined) {
                iosFilterPopup.blackPointDefault = c.blackPoint.locked
                iosFilterPopup.fBlackPoint       = c.blackPoint.locked
            }
            iosCameraSettingsPopup.hardwareBrightness = Math.round(iosFilterPopup.fGain)
            if (typeof isoSlider !== 'undefined')
                isoSlider.value = iosCameraSettingsPopup.hardwareBrightness
            console.log("✅ [iOS-Filter] 已应用后台默认值")

            syncIndividualParamUiFromFilter()
            syncOverallSlidersFromCurrentFilter()
            filterLoaded = true
            if (restorePushPending) {
                restorePushPending = false
                requestDelayedIosPush("camera-restore")
            } else {
                tryAutoPush()
            }
        }

        Component.onCompleted: {
            // 启动时连接 HttpClient 的 iOS 滤镜默认值信号 + 主动拉取一次
            HttpClient.iosFilterDefaultsReceived.connect(applyServerDefaults)
            HttpClient.iosFilterDefaultsFailed.connect(function(code, msg) {
                console.warn("🎨 [iOS-Filter] 拉默认值失败 (用前端 fallback): code=" + code + ", msg=" + msg)
                iosFilterPopup.filterLoaded = true   // 失败也标记加载完, 用前端 fallback 值
                iosFilterPopup.tryAutoPush()
            })
            // ⭐ 三链路开关/硬件/LUT 配置
            HttpClient.iosPipelineReceived.connect(applyServerPipeline)
            HttpClient.iosPipelineFailed.connect(function(code, msg) {
                console.warn("🔀 [iOS-Pipeline] 拉配置失败 (用前端 fallback): code=" + code + ", msg=" + msg)
                iosFilterPopup.pipelineLoaded = true
                iosFilterPopup.tryAutoPush()
            })
            HttpClient.getIosFilterDefaults()
            HttpClient.getIosPipeline()
        }

        // ⭐ 应用后端三链路配置 (switches / hardware / lut) — 初始化弹框开关与硬件默认值
        function applyServerPipeline(configJson) {
            var c
            try { c = JSON.parse(configJson) }
            catch (e) {
                console.warn("🔀 [iOS-Pipeline] JSON 解析失败:", e)
                pipelineLoaded = true; tryAutoPush(); return
            }
            if (c.switches) {
                if (c.switches.filter !== undefined) {
                    fEnabled = !!c.switches.filter
                    iosCameraSettingsPopup.filterModeEnabled = fEnabled
                }
                if (c.switches.lut !== undefined) {
                    lutEnabled = !!c.switches.lut
                    iosCameraSettingsPopup.lutModeEnabled = lutEnabled
                }
                if (c.switches.hardware !== undefined) hardwareEnabled = !!c.switches.hardware
            }
            selectedLutName = "lookup"
            if (c.hardware && c.hardware.gain && c.hardware.gain.default !== undefined)
                iosCameraSettingsPopup.hardwareBrightness = c.hardware.gain.default
            console.log("✅ [iOS-Pipeline] 开关 filter=" + fEnabled + " lut=" + lutEnabled + " hardware=" + hardwareEnabled)
            pipelineLoaded = true
            tryAutoPush()
        }

        // ⭐ 账号级「第一次自动下发」：滤镜默认值 + 三链路开关都加载完、且该账号尚未推过时，推一次全量
        //   账号切换会在 onLoginSuccess 重置 lastAutoPushAccount/filterLoaded/pipelineLoaded，从而对新账号重新首推
        function tryAutoPush() {
            var acct = HttpClient.loggedInUsername() || ""
            if (acct === "") return                          // 未登录不推
            if (!filterLoaded || !pipelineLoaded) return     // 两份配置都到齐才推
            if (acct === lastAutoPushAccount) return          // 该账号已首推过, 不重复
            lastAutoPushAccount = acct
            console.log("⏳ [iOS-Filter] 账号[" + acct + "] 首次自动下发 — 1秒后推送")
            scheduleUnifiedIosPush("account-first")
        }

        // 内部 prev 值 — 用于计算每次 onMoved 的 delta (slider 的 value 已经是新值)
        property double prevBrightness: 1.10
        property double prevGamma:      1.10
        property double prevContrast:   1.10
        property double prevSaturation: 1.10
        property double prevExposure:   1.10

        // ⭐ 联动 helper
        function clampVal(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

        function getParamRange(pid) {
            if (pid === "brightness") return brightnessTo - brightnessFrom
            if (pid === "gamma") return gammaTo - gammaFrom
            if (pid === "contrast") return contrastTo - contrastFrom
            if (pid === "saturation") return saturationTo - saturationFrom
            if (pid === "exposure") return exposureTo - exposureFrom
            if (pid === "sharpness") return sharpnessTo - sharpnessFrom
            if (pid === "highlightLift") return highlightLiftTo - highlightLiftFrom
            if (pid === "chroma") return chromaTo - chromaFrom
            if (pid === "gain") return gainTo - gainFrom
            return 1
        }

        function getParamPrev(pid) {
            if (pid === "brightness") return prevBrightness
            if (pid === "gamma") return prevGamma
            if (pid === "contrast") return prevContrast
            if (pid === "saturation") return prevSaturation
            if (pid === "exposure") return prevExposure
            if (pid === "sharpness") return prevSharpness
            if (pid === "highlightLift") return prevHighlightLift
            if (pid === "chroma") return prevChroma
            if (pid === "gain") return prevGain
            return 0
        }

        function setParamValue(pid, val) {
            if (pid === "brightness") {
                var nv = clampVal(val, brightnessFrom, brightnessTo)
                prevBrightness = nv; fBrightness = nv
                if (typeof ifMasterSlider !== 'undefined') ifMasterSlider.value = nv
                pushParam("brightness", nv)
            } else if (pid === "gamma") {
                var nv = clampVal(val, gammaFrom, gammaTo)
                prevGamma = nv; fGamma = nv
                if (typeof ifGammaSlider !== 'undefined') ifGammaSlider.value = nv
                pushParam("gamma", nv)
            } else if (pid === "contrast") {
                var nv = clampVal(val, contrastFrom, contrastTo)
                prevContrast = nv; fContrast = nv
                if (typeof ifContrastSlider !== 'undefined') ifContrastSlider.value = nv
                pushParam("contrast", nv)
            } else if (pid === "saturation") {
                var nv = clampVal(val, saturationFrom, saturationTo)
                prevSaturation = nv; fSaturation = nv
                if (typeof ifSaturationSlider !== 'undefined') ifSaturationSlider.value = nv
                if (typeof cameraSaturationSlider !== 'undefined') cameraSaturationSlider.value = nv
                pushParam("saturation", nv)
            } else if (pid === "exposure") {
                var nv = clampVal(val, exposureFrom, exposureTo)
                prevExposure = nv; fExposure = nv
                if (typeof ifExposureSlider !== 'undefined') ifExposureSlider.value = nv
                pushParam("exposure", Math.log2(nv))
            } else if (pid === "sharpness") {
                var nv = clampVal(val, sharpnessFrom, sharpnessTo)
                prevSharpness = nv; fSharpness = nv
                if (typeof ifSharpnessSlider !== 'undefined') ifSharpnessSlider.value = nv
                pushParam("sharpness", nv)
            } else if (pid === "highlightLift") {
                var nv = clampVal(val, highlightLiftFrom, highlightLiftTo)
                prevHighlightLift = nv; fHighlightLift = nv
                if (typeof ifHighlightLiftSlider !== 'undefined') ifHighlightLiftSlider.value = nv
                pushParam("highlightLift", nv)
            } else if (pid === "chroma") {
                var nv = clampVal(val, chromaFrom, chromaTo)
                prevChroma = nv; fChroma = nv
                if (typeof ifChromaSlider !== 'undefined') ifChromaSlider.value = nv
                pushParam("chroma", nv)
            } else if (pid === "gain") {
                var nv = clampVal(val, gainFrom, gainTo)
                nv = Math.round(nv)
                prevGain = nv; fGain = nv
                if (typeof ifGainSlider !== 'undefined') ifGainSlider.value = nv
                sendTestBrightnessConfig(nv)
            }
        }

        // ⭐ 分组联动：同 groupId 的参数按百分比同步, 方向由 groupDirection 决定
        //   rawDelta: 源参数的原始值变化量（非步进数）
        function applyLinkedDelta(sourceId, rawDelta) {
            var cfg = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig))
            var sc = cfg[sourceId]
            if (!sc || sc.groupId === 0 || !sc.groupEnabled) return
            var sourceRange = getParamRange(sourceId)
            if (sourceRange === 0) return
            var deltaPercent = rawDelta / sourceRange

            var params = ["brightness", "gamma", "contrast", "saturation", "exposure", "sharpness", "highlightLift", "chroma", "gain"]
            for (var i = 0; i < params.length; i++) {
                var tid = params[i]
                if (tid === sourceId) continue
                var tc = cfg[tid]
                if (!tc || tc.groupId !== sc.groupId || !tc.groupEnabled) continue
                var dirMul = tc.groupDirection / sc.groupDirection
                var targetRange = getParamRange(tid)
                var targetDelta = deltaPercent * targetRange * dirMul
                setParamValue(tid, getParamPrev(tid) + targetDelta)
            }
        }

        // ⭐ v3 STOMP 直推: 单参数 → /topic/device/{id}/config
        function pushParam(ptype, val) {
            // ⭐ Android：颜色类滤镜不下发设备，改 PC 本地处理（快门 cjfps / 增益 gain 不走此函数，仍下发设备）
            if (HttpClient.currentIsAndroid()) {
                if (mainPage.isLocalColorPtype(ptype) || ptype === "filterEnabled") {
                    mainPage.applyLocalColorFilter()
                }
                // lutName / 其它设备端专有项：Android 无对应能力，忽略
                return
            }
            var c = {}
            c[ptype] = val
            sendConfigUpdate(ptype, c)
        }

        // ⭐ STOMP 全量推送 — 只下发「开关打开」的链路；白平衡任何时候都不在这里推（只手动纠正）
        function pushAllStomp() {
            // ⭐ Android：颜色类滤镜走 PC 本地；仅 ISO 增益仍下发设备（快门 cjfps 由超级帧率滑块单独下发，不在此）
            if (HttpClient.currentIsAndroid()) {
                mainPage.applyLocalColorFilter()
                if (iosFilterPopup.hardwareEnabled) sendTestBrightnessConfig(Math.round(iosFilterPopup.fGain))
                console.log("🎨 Android 滤镜走 PC 本地处理（仅 ISO 增益下发设备）")
                return
            }
            // ⭐ 2026-07-14：低功率/高功率采集状态也在这批统一下发里补发一次
            //   （登录/重连/还原都会走到这里，避免"PC 重启前设过低功率，iOS 重连后又变回默认高功率"）
            sendConfigUpdate("lowPowerCapture", {"lowPowerCapture": appSettings.iosLowPowerCapture})

            // 滤镜链路：始终告知 iOS 开关状态；仅在打开时下发各滤镜值
            pushParam("filterEnabled", iosFilterPopup.fEnabled)
            if (iosFilterPopup.fEnabled) {
                pushParam("brightness",    iosFilterPopup.fBrightness)
                pushParam("contrast",      iosFilterPopup.fContrast)
                pushParam("saturation",    iosFilterPopup.fSaturation)
                pushParam("redBoost",      iosFilterPopup.fRedBoost)
                pushParam("gamma",         iosFilterPopup.fGamma)
                pushParam("exposure",      Math.log2(iosFilterPopup.fExposure))
                pushParam("blackPoint",    iosFilterPopup.fBlackPoint)
                pushParam("sharpness",     iosFilterPopup.fSharpness)
                pushParam("highlightLift", iosFilterPopup.fHighlightLift)
                pushParam("chroma",        iosFilterPopup.fChroma)
            }
            sendConfigUpdate("videoHDR", { "videoHDR": iosFilterPopup.videoHDREnabled })
            sendConfigUpdate("autoHDR", { "autoHDR": iosFilterPopup.autoHDREnabled })
            // 硬件链路：增益(0-100→iOS 映射到 ISO)；白平衡始终自动，不在此下发
            if (iosFilterPopup.hardwareEnabled) {
                sendTestBrightnessConfig(Math.round(iosFilterPopup.fGain))
            }
            // LUT 链路：开=启用并下发 LUT 名；关=明确关闭
            if (iosFilterPopup.lutEnabled) {
                sendConfigUpdate("test_mode", { "cmd": "test_mode", "enabled": true })
                pushParam("lutName", iosFilterPopup.selectedLutName)
            } else {
                sendConfigUpdate("test_mode", { "cmd": "test_mode", "enabled": false })
            }
        }

        // ⭐ LUT 开关 → STOMP test_mode（与相机设定同步）
        function pushLutEnabled(enabled) {
            lutEnabled = enabled
            iosCameraSettingsPopup.lutModeEnabled = enabled
            sendConfigUpdate("test_mode", { "cmd": "test_mode", "enabled": enabled })
        }

        function pushVideoHDREnabled(enabled) {
            videoHDREnabled = enabled
            sendConfigUpdate("videoHDR", { "videoHDR": enabled })
        }

        function pushAutoHDREnabled(enabled) {
            autoHDREnabled = enabled
            sendConfigUpdate("autoHDR", { "autoHDR": enabled })
        }

        function pushApplyWhiteBalance() {
            sendConfigUpdate("applyWhiteBalance", { "cmd": "applyWhiteBalance" })
        }

        // ⭐ 滤镜栈开关
        function pushFilterEnabled(enabled) {
            fEnabled = enabled
            iosCameraSettingsPopup.filterModeEnabled = enabled
            pushParam("filterEnabled", enabled)
        }

        // ⭐ 硬件链路开关（增益）。开=下发当前增益默认值；白平衡始终自动，不在此下发
        function pushHardwareEnabled(enabled) {
            hardwareEnabled = enabled
            if (enabled) sendTestBrightnessConfig(iosCameraSettingsPopup.hardwareBrightness)
            console.log("🎛️ 硬件链路:", enabled ? "开启" : "关闭")
        }

        // ⭐ 切换 LUT 图
        function selectLut(name) {
            selectedLutName = name
            pushParam("lutName", name)
        }

        // 单项 f* → 综合滑块(0-100)：syncFromOverall* 的逆映射；只更新 UI，不下发
        function filterValueToOverallX(v, def, lo, hi, direction) {
            var actualT = 0
            if (Math.abs(v - def) < 1e-6)
                actualT = 0
            else if (v < def) {
                if (Math.abs(def - lo) < 1e-9) actualT = 0
                else actualT = (v - def) / (def - lo)
            } else {
                if (Math.abs(hi - def) < 1e-9) actualT = 0
                else actualT = (v - def) / (hi - def)
            }
            actualT = clampVal(actualT, -1, 1)
            var t = (direction === -1) ? -actualT : actualT
            return Math.round(clampVal(50 + t * 50, 0, 100))
        }

        function computeOverallForChannel(switchKey, directionKey) {
            var lc = linkageConfig
            var rows = [
                ["brightness",    "fBrightness",    "brightnessDefault",    "brightnessFrom",    "brightnessTo"],
                ["gamma",         "fGamma",         "gammaDefault",         "gammaFrom",         "gammaTo"],
                ["contrast",      "fContrast",      "contrastDefault",      "contrastFrom",      "contrastTo"],
                ["saturation",    "fSaturation",    "saturationDefault",    "saturationFrom",    "saturationTo"],
                ["exposure",      "fExposure",      "exposureDefault",      "exposureFrom",      "exposureTo"],
                ["sharpness",     "fSharpness",     "sharpnessDefault",     "sharpnessFrom",     "sharpnessTo"],
                ["highlightLift", "fHighlightLift", "highlightLiftDefault", "highlightLiftFrom", "highlightLiftTo"],
                ["chroma",        "fChroma",        "chromaDefault",        "chromaFrom",        "chromaTo"],
                ["gain",          "fGain",          "gainDefault",          "gainFrom",          "gainTo"]
            ]
            var sum = 0, n = 0
            for (var i = 0; i < rows.length; i++) {
                var pid = rows[i][0]
                var cfg = lc[pid]
                if (!cfg || !cfg[switchKey]) continue
                sum += filterValueToOverallX(
                    iosFilterPopup[rows[i][1]],
                    iosFilterPopup[rows[i][2]],
                    iosFilterPopup[rows[i][3]],
                    iosFilterPopup[rows[i][4]],
                    cfg[directionKey])
                n++
            }
            return n > 0 ? Math.round(sum / n) : 50
        }

        function syncOverallSlidersFromCurrentFilter() {
            var bright = computeOverallForChannel("brightSwitch", "brightDirection")
            var contrast = computeOverallForChannel("brightContrastSwitch", "brightContrastDirection")
            var exposure = computeOverallForChannel("brightExposureSwitch", "brightExposureDirection")
            iosCameraSettingsPopup.exposureValue = bright
            iosCameraSettingsPopup.overallContrastValue = contrast
            iosCameraSettingsPopup.overallExposureValue = exposure
            if (typeof exposureBiasSlider !== 'undefined') exposureBiasSlider.value = bright
            if (typeof cameraBrightnessSlider !== 'undefined') cameraBrightnessSlider.value = contrast
            if (typeof cameraFakeExposureSlider !== 'undefined') cameraFakeExposureSlider.value = exposure
        }

        // 综合 → 单项：刷新滤镜弹框 + 相机设定里绑 f* 的滑块（红外等）；不碰综亮/综对/综曝 三个 0-100
        function syncIndividualParamUiFromFilter() {
            if (typeof ifMasterSlider     !== 'undefined') ifMasterSlider.value     = fBrightness
            if (typeof ifGammaSlider      !== 'undefined') ifGammaSlider.value      = fGamma
            if (typeof ifContrastSlider   !== 'undefined') ifContrastSlider.value   = fContrast
            if (typeof ifSaturationSlider !== 'undefined') ifSaturationSlider.value = fSaturation
            if (typeof ifExposureSlider   !== 'undefined') ifExposureSlider.value   = fExposure
            if (typeof ifSharpnessSlider  !== 'undefined') ifSharpnessSlider.value  = fSharpness
            if (typeof ifHighlightLiftSlider !== 'undefined') ifHighlightLiftSlider.value = fHighlightLift
            if (typeof ifChromaSlider     !== 'undefined') ifChromaSlider.value     = fChroma
            if (typeof ifGainSlider       !== 'undefined') ifGainSlider.value       = fGain
            if (typeof cameraSaturationSlider !== 'undefined') cameraSaturationSlider.value = fSaturation
        }

        // ⭐ 综合亮度(0-100) → 驱动所有 brightSwitch=true 的参数
        //   X=0 → from (最暗), X=50 → default (出厂), X=100 → to (最亮)
        //   方向由 brightDirection 决定: -1 时 X 增大→值减小, 1 时 X 增大→值增大
        function syncFromOverallBrightness(X) {
            var t = (X - 50) / 50   // -1 .. +1
            var lc = linkageConfig
            function setOne(pid, currProp, prevProp, defProp, fromProp, toProp) {
                var cfg = lc[pid]
                if (!cfg || !cfg.brightSwitch) return
                var def = iosFilterPopup[defProp]
                var lo  = iosFilterPopup[fromProp]
                var hi  = iosFilterPopup[toProp]
                var actualT = cfg.brightDirection === -1 ? -t : t
                var v   = actualT < 0 ? def + actualT * (def - lo) : def + actualT * (hi - def)
                v = clampVal(v, lo, hi)
                iosFilterPopup[currProp] = v
                iosFilterPopup[prevProp] = v
                if (pid === "gain") { sendTestBrightnessConfig(Math.round(v)) }
                else if (pid === "exposure") { pushParam("exposure", Math.log2(v)) }
                else { pushParam(pid, v) }
            }
            setOne("brightness",    "fBrightness",    "prevBrightness",    "brightnessDefault",    "brightnessFrom",    "brightnessTo")
            setOne("gamma",         "fGamma",         "prevGamma",         "gammaDefault",         "gammaFrom",         "gammaTo")
            setOne("contrast",      "fContrast",      "prevContrast",      "contrastDefault",      "contrastFrom",      "contrastTo")
            setOne("saturation",    "fSaturation",    "prevSaturation",    "saturationDefault",    "saturationFrom",    "saturationTo")
            setOne("exposure",      "fExposure",      "prevExposure",      "exposureDefault",      "exposureFrom",      "exposureTo")
            setOne("sharpness",     "fSharpness",     "prevSharpness",     "sharpnessDefault",     "sharpnessFrom",     "sharpnessTo")
            setOne("highlightLift", "fHighlightLift", "prevHighlightLift", "highlightLiftDefault", "highlightLiftFrom", "highlightLiftTo")
            setOne("chroma",        "fChroma",        "prevChroma",        "chromaDefault",        "chromaFrom",        "chromaTo")
            setOne("gain",          "fGain",          "prevGain",          "gainDefault",          "gainFrom",          "gainTo")
            syncIndividualParamUiFromFilter()
        }

        // ⭐ 综合亮度-对比度(0-100) → 驱动所有 brightContrastSwitch=true 的参数
        function syncFromOverallContrast(X) {
            var t = (X - 50) / 50
            var lc = linkageConfig
            function setOne(pid, currProp, prevProp, defProp, fromProp, toProp) {
                var cfg = lc[pid]
                if (!cfg || !cfg.brightContrastSwitch) return
                var def = iosFilterPopup[defProp]
                var lo  = iosFilterPopup[fromProp]
                var hi  = iosFilterPopup[toProp]
                var actualT = cfg.brightContrastDirection === -1 ? -t : t
                var v   = actualT < 0 ? def + actualT * (def - lo) : def + actualT * (hi - def)
                v = clampVal(v, lo, hi)
                iosFilterPopup[currProp] = v
                iosFilterPopup[prevProp] = v
                if (pid === "gain") { sendTestBrightnessConfig(Math.round(v)) }
                else if (pid === "exposure") { pushParam("exposure", Math.log2(v)) }
                else { pushParam(pid, v) }
            }
            setOne("brightness",    "fBrightness",    "prevBrightness",    "brightnessDefault",    "brightnessFrom",    "brightnessTo")
            setOne("gamma",         "fGamma",         "prevGamma",         "gammaDefault",         "gammaFrom",         "gammaTo")
            setOne("contrast",      "fContrast",      "prevContrast",      "contrastDefault",      "contrastFrom",      "contrastTo")
            setOne("saturation",    "fSaturation",    "prevSaturation",    "saturationDefault",    "saturationFrom",    "saturationTo")
            setOne("exposure",      "fExposure",      "prevExposure",      "exposureDefault",      "exposureFrom",      "exposureTo")
            setOne("sharpness",     "fSharpness",     "prevSharpness",     "sharpnessDefault",     "sharpnessFrom",     "sharpnessTo")
            setOne("highlightLift", "fHighlightLift", "prevHighlightLift", "highlightLiftDefault", "highlightLiftFrom", "highlightLiftTo")
            setOne("chroma",        "fChroma",        "prevChroma",        "chromaDefault",        "chromaFrom",        "chromaTo")
            setOne("gain",          "fGain",          "prevGain",          "gainDefault",          "gainFrom",          "gainTo")
            syncIndividualParamUiFromFilter()
        }

        // ⭐ 综合亮度-曝光度(0-100) → 驱动所有 brightExposureSwitch=true 的参数
        function syncFromOverallExposure(X) {
            var t = (X - 50) / 50
            var lc = linkageConfig
            function setOne(pid, currProp, prevProp, defProp, fromProp, toProp) {
                var cfg = lc[pid]
                if (!cfg || !cfg.brightExposureSwitch) return
                var def = iosFilterPopup[defProp]
                var lo  = iosFilterPopup[fromProp]
                var hi  = iosFilterPopup[toProp]
                var actualT = cfg.brightExposureDirection === -1 ? -t : t
                var v   = actualT < 0 ? def + actualT * (def - lo) : def + actualT * (hi - def)
                v = clampVal(v, lo, hi)
                iosFilterPopup[currProp] = v
                iosFilterPopup[prevProp] = v
                if (pid === "gain") { sendTestBrightnessConfig(Math.round(v)) }
                else if (pid === "exposure") { pushParam("exposure", Math.log2(v)) }
                else { pushParam(pid, v) }
            }
            setOne("brightness",    "fBrightness",    "prevBrightness",    "brightnessDefault",    "brightnessFrom",    "brightnessTo")
            setOne("gamma",         "fGamma",         "prevGamma",         "gammaDefault",         "gammaFrom",         "gammaTo")
            setOne("contrast",      "fContrast",      "prevContrast",      "contrastDefault",      "contrastFrom",      "contrastTo")
            setOne("saturation",    "fSaturation",    "prevSaturation",    "saturationDefault",    "saturationFrom",    "saturationTo")
            setOne("exposure",      "fExposure",      "prevExposure",      "exposureDefault",      "exposureFrom",      "exposureTo")
            setOne("sharpness",     "fSharpness",     "prevSharpness",     "sharpnessDefault",     "sharpnessFrom",     "sharpnessTo")
            setOne("highlightLift", "fHighlightLift", "prevHighlightLift", "highlightLiftDefault", "highlightLiftFrom", "highlightLiftTo")
            setOne("chroma",        "fChroma",        "prevChroma",        "chromaDefault",        "chromaFrom",        "chromaTo")
            setOne("gain",          "fGain",          "prevGain",          "gainDefault",          "gainFrom",          "gainTo")
            syncIndividualParamUiFromFilter()
        }

        // ⭐ 相机设定弹框里 红外模式(saturation) 等单项滑块：只改 f* + 推 iOS，不反写综亮/综对/综曝
        function syncSingle(ptype, v) {
            if (ptype === "brightness") {
                v = clampVal(v, brightnessFrom, brightnessTo)
                fBrightness = v;  prevBrightness = v
                if (typeof ifMasterSlider !== 'undefined') ifMasterSlider.value = v
                pushParam("brightness", v)
            } else if (ptype === "contrast") {
                v = clampVal(v, contrastFrom, contrastTo)
                fContrast = v;   prevContrast = v
                if (typeof ifContrastSlider !== 'undefined') ifContrastSlider.value = v
                pushParam("contrast", v)
            } else if (ptype === "saturation") {
                v = clampVal(v, saturationFrom, saturationTo)
                fSaturation = v;  prevSaturation = v
                if (typeof ifSaturationSlider !== 'undefined') ifSaturationSlider.value = v
                if (typeof cameraSaturationSlider !== 'undefined') cameraSaturationSlider.value = v
                pushParam("saturation", v)
            }
        }

        // ⭐ 滚轮调节滑块: 一格 = 2 × stepSize (0.02), 直接 STOMP, 无防抖
        function adjustSliderByWheel(slider, propName, ptype, angleDeltaY) {
            if (angleDeltaY === 0) return
            var dir = angleDeltaY > 0 ? 1 : -1
            var step = slider.stepSize > 0 ? slider.stepSize * 2 : (slider.to - slider.from) / 100
            var newVal = slider.value + dir * step
            newVal = Math.max(slider.from, Math.min(slider.to, newVal))
            slider.value = newVal
            iosFilterPopup[propName] = newVal
            pushParam(ptype, newVal)
        }

        // 窗口背景（白底+绿描边，跟相机设定一致）
        Rectangle {
            anchors.fill: parent
            color: "#FFFFFF"
            radius: 4
            border.color: "#A5D6A7"
            border.width: 1

            ColumnLayout {
                spacing: 12
                anchors.fill: parent
                anchors.margins: 24

                // ===== 标题栏（拖动区 + 还原 + ✕）=====
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    color: "transparent"

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.ClosedHandCursor
                        propagateComposedEvents: false
                        property point startPos: Qt.point(0, 0)
                        property point dragStartGlobal: Qt.point(0, 0)
                        onPressed: function(mouse) {
                            startPos = Qt.point(iosFilterPopup.x, iosFilterPopup.y)
                            dragStartGlobal = mapToGlobal(mouse.x, mouse.y)
                            iosFilterPopup.dragging = true
                            mouse.accepted = true
                        }
                        onPositionChanged: function(mouse) {
                            if (iosFilterPopup.dragging) {
                                var g = mapToGlobal(mouse.x, mouse.y)
                                iosFilterPopup.x = startPos.x + (g.x - dragStartGlobal.x)
                                iosFilterPopup.y = startPos.y + (g.y - dragStartGlobal.y)
                            }
                        }
                        onReleased: iosFilterPopup.dragging = false
                    }

                    // 还原按钮
                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: filterResetText.width + 20
                        height: 28
                        radius: 6
                        color: filterResetArea.containsMouse ? "#C8E6C9" : "#E8F5E9"
                        border.color: "#A5D6A7"
                        border.width: 1
                        Text {
                            id: filterResetText
                            anchors.centerIn: parent
                            text: "还原"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#263238"
                        }
                        MouseArea {
                            id: filterResetArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // ⭐ 还原 — 用从后台拉到的出厂默认值 + 联动配置
                                iosFilterPopup.fBrightness = iosFilterPopup.brightnessDefault
                                iosFilterPopup.fGamma      = iosFilterPopup.gammaDefault
                                iosFilterPopup.fContrast   = iosFilterPopup.contrastDefault
                                iosFilterPopup.fSaturation = iosFilterPopup.saturationDefault
                                iosFilterPopup.fExposure   = iosFilterPopup.exposureDefault
                                iosFilterPopup.fSharpness  = iosFilterPopup.sharpnessDefault
                                iosFilterPopup.fHighlightLift = iosFilterPopup.highlightLiftDefault
                                iosFilterPopup.fChroma     = iosFilterPopup.chromaDefault
                                iosFilterPopup.fGain       = iosFilterPopup.gainDefault
                                iosFilterPopup.fRedBoost   = iosFilterPopup.redBoostDefault
                                iosFilterPopup.fBlackPoint = iosFilterPopup.blackPointDefault   // ⭐ 修复：原逻辑漏还原 blackPoint
                                // ⭐ 修复：还原必须保持滤镜开启。pushAllStomp 仅在 fEnabled=true 时才下发各滤镜值，
                                //   原来这里置 false → 还原反而关掉滤镜、且默认值一个都推不到 iOS（与“还原”语义相反，
                                //   也违反“启用滤镜永远 true”）。改为 true，并同步相机设定弹框的滤镜开关。
                                iosFilterPopup.fEnabled    = true
                                iosCameraSettingsPopup.filterModeEnabled = true
                                iosFilterPopup.prevBrightness = iosFilterPopup.brightnessDefault
                                iosFilterPopup.prevGamma      = iosFilterPopup.gammaDefault
                                iosFilterPopup.prevContrast   = iosFilterPopup.contrastDefault
                                iosFilterPopup.prevSaturation = iosFilterPopup.saturationDefault
                                iosFilterPopup.prevExposure   = iosFilterPopup.exposureDefault
                                iosFilterPopup.prevSharpness  = iosFilterPopup.sharpnessDefault
                                iosFilterPopup.prevHighlightLift = iosFilterPopup.highlightLiftDefault
                                iosFilterPopup.prevChroma      = iosFilterPopup.chromaDefault
                                iosFilterPopup.prevGain        = iosFilterPopup.gainDefault
                                // ⭐ 还原联动配置到后台默认
                                if (iosFilterPopup.linkageConfigDefault)
                                    iosFilterPopup.linkageConfig = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfigDefault))
                                if (typeof ifMasterSlider     !== 'undefined') ifMasterSlider.value     = iosFilterPopup.brightnessDefault
                                if (typeof ifGammaSlider      !== 'undefined') ifGammaSlider.value      = iosFilterPopup.gammaDefault
                                if (typeof ifContrastSlider   !== 'undefined') ifContrastSlider.value   = iosFilterPopup.contrastDefault
                                if (typeof ifSaturationSlider !== 'undefined') ifSaturationSlider.value = iosFilterPopup.saturationDefault
                                if (typeof ifExposureSlider   !== 'undefined') ifExposureSlider.value   = iosFilterPopup.exposureDefault
                                if (typeof ifSharpnessSlider  !== 'undefined') ifSharpnessSlider.value  = iosFilterPopup.sharpnessDefault
                                if (typeof ifHighlightLiftSlider !== 'undefined') ifHighlightLiftSlider.value = iosFilterPopup.highlightLiftDefault
                                if (typeof ifChromaSlider     !== 'undefined') ifChromaSlider.value     = iosFilterPopup.chromaDefault
                                if (typeof ifGainSlider       !== 'undefined') ifGainSlider.value       = iosFilterPopup.gainDefault
                                iosCameraSettingsPopup.hardwareBrightness = Math.round(iosFilterPopup.gainDefault)
                                iosFilterPopup.syncOverallSlidersFromCurrentFilter()
                                iosFilterPopup.requestDelayedIosPush("filter-restore")
                            }
                        }
                    }

                    // 标题
                    Text {
                        anchors.centerIn: parent
                        text: "iOS 视频滤镜"
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        font.bold: true
                        color: "#263238"
                    }

                    // ✕ 关闭按钮
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 24
                        radius: 12
                        color: filterCloseBtn.containsMouse ? "#C8E6C9" : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            font.pixelSize: 14
                            color: "#546E7A"
                        }
                        MouseArea {
                            id: filterCloseBtn
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: iosFilterPopup.close()
                        }
                    }
                }

                // ===== 启用滤镜 永远 true, UI 不再显示 (用户需求) =====
                // ===== "GPU 后处理" 提示文字已移除 =====

                // ===== 联动分组提示文字 =====
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: iosFilterPopup.pcFreeConfig ? "分组联动: 箭头=联动方向(点击切换)" : "分组联动(后台配置)"
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: "#90A4AE"
                    wrapMode: Text.WordWrap
                }

                // ===== 亮度滑块 (range 0.8/1.10/2.0, stepSize 0.02) =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.brightness.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.brightness.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.groupEnabled = !lc.brightness.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.brightness.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.brightness.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "brightness"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.brightness.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.brightness.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.brightness.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "亮度"; font.family: "PingFang HK"; font.pixelSize: 20; font.bold: true; color: "#E53935"; Layout.preferredWidth: 70 }
                    Slider {
                        id: ifMasterSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.brightnessFrom; to: iosFilterPopup.brightnessTo; stepSize: iosFilterPopup.brightnessStep
                        value: iosFilterPopup.fBrightness
                        onMoved: {
                            var delta = value - iosFilterPopup.prevBrightness
                            iosFilterPopup.prevBrightness = value
                            iosFilterPopup.fBrightness = value
                            iosFilterPopup.pushParam("brightness", value)
                            iosFilterPopup.applyLinkedDelta("brightness", delta)
                        }
                        onPressedChanged: if (!pressed) iosFilterPopup.pushParam("brightness", value)
                        background: Rectangle {
                            x: ifMasterSlider.leftPadding
                            y: ifMasterSlider.topPadding + ifMasterSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifMasterSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifMasterSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifMasterSlider.leftPadding + ifMasterSlider.visualPosition * (ifMasterSlider.availableWidth - width)
                            y: ifMasterSlider.topPadding + ifMasterSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifMasterSlider.value + dir * ifMasterSlider.stepSize, ifMasterSlider.from, ifMasterSlider.to)
                                var delta = nv - iosFilterPopup.prevBrightness
                                ifMasterSlider.value = nv
                                iosFilterPopup.prevBrightness = nv
                                iosFilterPopup.fBrightness = nv
                                iosFilterPopup.pushParam("brightness", nv)
                                iosFilterPopup.applyLinkedDelta("brightness", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fBrightness.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.brightness.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.brightSwitch = !lc.brightness.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.brightness.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.brightness.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.brightness.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.brightContrastSwitch = !lc.brightness.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.brightness.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.brightness.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.brightness.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.brightExposureSwitch = !lc.brightness.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.brightness.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.brightness.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.brightness.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.brightness.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                // ===== 伽马滑块 (range 0.8/1.10/2.0, stepSize 0.01 ⭐ 比亮度细一倍) =====
                //   联动时双向 — 拖伽马也会驱动亮度等其他勾选项
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.gamma.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.gamma.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.groupEnabled = !lc.gamma.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.gamma.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.gamma.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "gamma"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.gamma.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gamma.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gamma.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "伽马"; font.family: "PingFang HK"; font.pixelSize: 20; font.bold: true; color: "#E53935"; Layout.preferredWidth: 70 }
                    Slider {
                        id: ifGammaSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.gammaFrom; to: iosFilterPopup.gammaTo; stepSize: iosFilterPopup.gammaStep
                        value: iosFilterPopup.fGamma
                        onMoved: {
                            var delta = value - iosFilterPopup.prevGamma
                            iosFilterPopup.prevGamma = value
                            iosFilterPopup.fGamma = value
                            iosFilterPopup.pushParam("gamma", value)
                            iosFilterPopup.applyLinkedDelta("gamma", delta)
                        }
                        onPressedChanged: if (!pressed) iosFilterPopup.pushParam("gamma", value)
                        background: Rectangle {
                            x: ifGammaSlider.leftPadding
                            y: ifGammaSlider.topPadding + ifGammaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifGammaSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifGammaSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifGammaSlider.leftPadding + ifGammaSlider.visualPosition * (ifGammaSlider.availableWidth - width)
                            y: ifGammaSlider.topPadding + ifGammaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifGammaSlider.value + dir * ifGammaSlider.stepSize, ifGammaSlider.from, ifGammaSlider.to)
                                var delta = nv - iosFilterPopup.prevGamma
                                ifGammaSlider.value = nv
                                iosFilterPopup.prevGamma = nv
                                iosFilterPopup.fGamma = nv
                                iosFilterPopup.pushParam("gamma", nv)
                                iosFilterPopup.applyLinkedDelta("gamma", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fGamma.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.gamma.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.brightSwitch = !lc.gamma.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gamma.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gamma.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.gamma.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.brightContrastSwitch = !lc.gamma.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gamma.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gamma.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.gamma.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.brightExposureSwitch = !lc.gamma.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gamma.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gamma.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gamma.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gamma.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                // ===== 对比度滑块 (0.8/1.10/1.30, stepSize 0.02) =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.contrast.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.contrast.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.groupEnabled = !lc.contrast.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.contrast.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.contrast.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "contrast"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.contrast.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.contrast.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.contrast.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "对比度"; font.family: "PingFang HK"; font.pixelSize: 20; font.bold: true; color: "#E53935"; Layout.preferredWidth: 70 }
                    Slider {
                        id: ifContrastSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.contrastFrom; to: iosFilterPopup.contrastTo; stepSize: iosFilterPopup.contrastStep
                        value: iosFilterPopup.fContrast
                        onMoved: {
                            var delta = value - iosFilterPopup.prevContrast
                            iosFilterPopup.prevContrast = value
                            iosFilterPopup.fContrast = value
                            iosFilterPopup.pushParam("contrast", value)
                            iosFilterPopup.applyLinkedDelta("contrast", delta)
                        }
                        onPressedChanged: if (!pressed) iosFilterPopup.pushParam("contrast", value)
                        background: Rectangle {
                            x: ifContrastSlider.leftPadding
                            y: ifContrastSlider.topPadding + ifContrastSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifContrastSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifContrastSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifContrastSlider.leftPadding + ifContrastSlider.visualPosition * (ifContrastSlider.availableWidth - width)
                            y: ifContrastSlider.topPadding + ifContrastSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifContrastSlider.value + dir * ifContrastSlider.stepSize, ifContrastSlider.from, ifContrastSlider.to)
                                var delta = nv - iosFilterPopup.prevContrast
                                ifContrastSlider.value = nv
                                iosFilterPopup.prevContrast = nv
                                iosFilterPopup.fContrast = nv
                                iosFilterPopup.pushParam("contrast", nv)
                                iosFilterPopup.applyLinkedDelta("contrast", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fContrast.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.contrast.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.brightSwitch = !lc.contrast.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.contrast.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.contrast.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.contrast.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.brightContrastSwitch = !lc.contrast.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.contrast.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.contrast.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.contrast.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.brightExposureSwitch = !lc.contrast.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.contrast.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.contrast.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.contrast.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.contrast.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                // ===== 红外模式 (饱和度) (0.0/1.10/2.0, stepSize 0.02, 0=黑白) =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.saturation.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.saturation.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.groupEnabled = !lc.saturation.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.saturation.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.saturation.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "saturation"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.saturation.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.saturation.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.saturation.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "红外模式"; font.family: "PingFang HK"; font.pixelSize: 20; font.bold: true; color: "#E53935"; Layout.preferredWidth: 90 }
                    Slider {
                        id: ifSaturationSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.saturationFrom; to: iosFilterPopup.saturationTo; stepSize: iosFilterPopup.saturationStep
                        value: iosFilterPopup.fSaturation
                        onMoved: {
                            var delta = value - iosFilterPopup.prevSaturation
                            iosFilterPopup.prevSaturation = value
                            iosFilterPopup.fSaturation = value
                            if (typeof cameraSaturationSlider !== 'undefined') cameraSaturationSlider.value = value
                            iosFilterPopup.pushParam("saturation", value)
                            iosFilterPopup.applyLinkedDelta("saturation", delta)
                        }
                        onPressedChanged: if (!pressed) {
                            if (typeof cameraSaturationSlider !== 'undefined') cameraSaturationSlider.value = value
                            iosFilterPopup.pushParam("saturation", value)
                        }
                        background: Rectangle {
                            x: ifSaturationSlider.leftPadding
                            y: ifSaturationSlider.topPadding + ifSaturationSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifSaturationSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifSaturationSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifSaturationSlider.leftPadding + ifSaturationSlider.visualPosition * (ifSaturationSlider.availableWidth - width)
                            y: ifSaturationSlider.topPadding + ifSaturationSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifSaturationSlider.value + dir * ifSaturationSlider.stepSize, ifSaturationSlider.from, ifSaturationSlider.to)
                                var delta = nv - iosFilterPopup.prevSaturation
                                ifSaturationSlider.value = nv
                                iosFilterPopup.prevSaturation = nv
                                iosFilterPopup.fSaturation = nv
                                iosFilterPopup.pushParam("saturation", nv)
                                iosFilterPopup.applyLinkedDelta("saturation", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fSaturation.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.saturation.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.brightSwitch = !lc.saturation.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.saturation.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.saturation.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.saturation.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.brightContrastSwitch = !lc.saturation.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.saturation.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.saturation.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.saturation.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.brightExposureSwitch = !lc.saturation.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.saturation.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.saturation.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.saturation.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.saturation.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                // ===== 曝光度滑块 (0.6/1.10/1.6, stepSize 0.02, PC 端线性倍数, 发送 log2) =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.exposure.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.exposure.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.groupEnabled = !lc.exposure.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.exposure.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.exposure.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "exposure"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.exposure.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.exposure.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.exposure.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "曝光度"; font.family: "PingFang HK"; font.pixelSize: 20; font.bold: true; color: "#E53935"; Layout.preferredWidth: 70 }
                    Slider {
                        id: ifExposureSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.exposureFrom; to: iosFilterPopup.exposureTo; stepSize: iosFilterPopup.exposureStep
                        value: iosFilterPopup.fExposure
                        onMoved: {
                            var delta = value - iosFilterPopup.prevExposure
                            iosFilterPopup.prevExposure = value
                            iosFilterPopup.fExposure = value
                            iosFilterPopup.pushParam("exposure", Math.log2(value))
                            iosFilterPopup.applyLinkedDelta("exposure", delta)
                        }
                        onPressedChanged: if (!pressed) iosFilterPopup.pushParam("exposure", Math.log2(value))
                        background: Rectangle {
                            x: ifExposureSlider.leftPadding
                            y: ifExposureSlider.topPadding + ifExposureSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifExposureSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifExposureSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifExposureSlider.leftPadding + ifExposureSlider.visualPosition * (ifExposureSlider.availableWidth - width)
                            y: ifExposureSlider.topPadding + ifExposureSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifExposureSlider.value + dir * ifExposureSlider.stepSize, ifExposureSlider.from, ifExposureSlider.to)
                                var delta = nv - iosFilterPopup.prevExposure
                                ifExposureSlider.value = nv
                                iosFilterPopup.prevExposure = nv
                                iosFilterPopup.fExposure = nv
                                iosFilterPopup.pushParam("exposure", Math.log2(nv))
                                iosFilterPopup.applyLinkedDelta("exposure", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fExposure.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.exposure.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.brightSwitch = !lc.exposure.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.exposure.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.exposure.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.exposure.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.brightContrastSwitch = !lc.exposure.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.exposure.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.exposure.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.exposure.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.brightExposureSwitch = !lc.exposure.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.exposure.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.exposure.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.exposure.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.exposure.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: "#E0E0E0"
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "玉麒麟补充"
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: "#90A4AE"
                }

                // ===== 色调(H) — iOS 无 STOMP =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                    Text { text: "色调(H)"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#90A4AE"; Layout.preferredWidth: 70 }
                    Text { text: "无法调"; font.family: "PingFang HK"; font.pixelSize: 14; color: "#90A4AE"; Layout.fillWidth: true }
                    Text { text: "—"; font.family: "PingFang HK"; font.pixelSize: 16; color: "#90A4AE"; Layout.preferredWidth: 50 }
                }

                // ===== 清晰度(P)（滤镜） =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.sharpness.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.sharpness.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.groupEnabled = !lc.sharpness.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.sharpness.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.sharpness.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "sharpness"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.sharpness.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.sharpness.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.sharpness.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "清晰度(P)"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#E53935"; Layout.preferredWidth: 130 }
                    Slider {
                        id: ifSharpnessSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.sharpnessFrom; to: iosFilterPopup.sharpnessTo; stepSize: iosFilterPopup.sharpnessStep
                        value: iosFilterPopup.fSharpness
                        onMoved: {
                            var delta = value - iosFilterPopup.prevSharpness
                            iosFilterPopup.prevSharpness = value
                            iosFilterPopup.fSharpness = value
                            iosFilterPopup.pushParam("sharpness", value)
                            iosFilterPopup.applyLinkedDelta("sharpness", delta)
                        }
                        onPressedChanged: if (!pressed) iosFilterPopup.pushParam("sharpness", value)
                        background: Rectangle {
                            x: ifSharpnessSlider.leftPadding
                            y: ifSharpnessSlider.topPadding + ifSharpnessSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifSharpnessSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifSharpnessSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifSharpnessSlider.leftPadding + ifSharpnessSlider.visualPosition * (ifSharpnessSlider.availableWidth - width)
                            y: ifSharpnessSlider.topPadding + ifSharpnessSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifSharpnessSlider.value + dir * ifSharpnessSlider.stepSize, ifSharpnessSlider.from, ifSharpnessSlider.to)
                                var delta = nv - iosFilterPopup.prevSharpness
                                ifSharpnessSlider.value = nv
                                iosFilterPopup.prevSharpness = nv
                                iosFilterPopup.fSharpness = nv
                                iosFilterPopup.pushParam("sharpness", nv)
                                iosFilterPopup.applyLinkedDelta("sharpness", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fSharpness.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.sharpness.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.brightSwitch = !lc.sharpness.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.sharpness.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.sharpness.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.sharpness.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.brightContrastSwitch = !lc.sharpness.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.sharpness.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.sharpness.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.sharpness.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.brightExposureSwitch = !lc.sharpness.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.sharpness.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.sharpness.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.sharpness.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.sharpness.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                // ===== 色度(C)（滤镜）— 黄色拉白, 保留红色, 与亮度一致参与联动 =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.chroma.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.chroma.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.groupEnabled = !lc.chroma.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.chroma.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.chroma.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "chroma"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.chroma.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.chroma.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.chroma.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "色度(C)"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#E53935"; Layout.preferredWidth: 130 }
                    Slider {
                        id: ifChromaSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.chromaFrom; to: iosFilterPopup.chromaTo; stepSize: iosFilterPopup.chromaStep
                        value: iosFilterPopup.fChroma
                        onMoved: {
                            var delta = value - iosFilterPopup.prevChroma
                            iosFilterPopup.prevChroma = value
                            iosFilterPopup.fChroma = value
                            iosFilterPopup.pushParam("chroma", value)
                            iosFilterPopup.applyLinkedDelta("chroma", delta)
                        }
                        onPressedChanged: if (!pressed) iosFilterPopup.pushParam("chroma", value)
                        background: Rectangle {
                            x: ifChromaSlider.leftPadding
                            y: ifChromaSlider.topPadding + ifChromaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifChromaSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifChromaSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifChromaSlider.leftPadding + ifChromaSlider.visualPosition * (ifChromaSlider.availableWidth - width)
                            y: ifChromaSlider.topPadding + ifChromaSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifChromaSlider.value + dir * ifChromaSlider.stepSize, ifChromaSlider.from, ifChromaSlider.to)
                                var delta = nv - iosFilterPopup.prevChroma
                                ifChromaSlider.value = nv
                                iosFilterPopup.prevChroma = nv
                                iosFilterPopup.fChroma = nv
                                iosFilterPopup.pushParam("chroma", nv)
                                iosFilterPopup.applyLinkedDelta("chroma", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fChroma.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.chroma.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.brightSwitch = !lc.chroma.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.chroma.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.chroma.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.chroma.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.brightContrastSwitch = !lc.chroma.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.chroma.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.chroma.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.chroma.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.brightExposureSwitch = !lc.chroma.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.chroma.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.chroma.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.chroma.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.chroma.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                // ===== 白平衡(WD) — iOS 无 STOMP =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                    Text { text: "白平衡(WD)"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#90A4AE"; Layout.preferredWidth: 90 }
                    Text { text: "无法调"; font.family: "PingFang HK"; font.pixelSize: 14; color: "#90A4AE"; Layout.fillWidth: true }
                    Text { text: "—"; font.family: "PingFang HK"; font.pixelSize: 16; color: "#90A4AE"; Layout.preferredWidth: 50 }
                }

                // ===== 逆光对比(B)（滤镜） =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.highlightLift.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.highlightLift.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.groupEnabled = !lc.highlightLift.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.highlightLift.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.highlightLift.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "highlightLift"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.highlightLift.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.highlightLift.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.highlightLift.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "逆光对比(B)"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#E53935"; Layout.preferredWidth: 130 }
                    Slider {
                        id: ifHighlightLiftSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.highlightLiftFrom; to: iosFilterPopup.highlightLiftTo; stepSize: iosFilterPopup.highlightLiftStep
                        value: iosFilterPopup.fHighlightLift
                        onMoved: {
                            var delta = value - iosFilterPopup.prevHighlightLift
                            iosFilterPopup.prevHighlightLift = value
                            iosFilterPopup.fHighlightLift = value
                            iosFilterPopup.pushParam("highlightLift", value)
                            iosFilterPopup.applyLinkedDelta("highlightLift", delta)
                        }
                        onPressedChanged: if (!pressed) iosFilterPopup.pushParam("highlightLift", value)
                        background: Rectangle {
                            x: ifHighlightLiftSlider.leftPadding
                            y: ifHighlightLiftSlider.topPadding + ifHighlightLiftSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifHighlightLiftSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifHighlightLiftSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifHighlightLiftSlider.leftPadding + ifHighlightLiftSlider.visualPosition * (ifHighlightLiftSlider.availableWidth - width)
                            y: ifHighlightLiftSlider.topPadding + ifHighlightLiftSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifHighlightLiftSlider.value + dir * ifHighlightLiftSlider.stepSize, ifHighlightLiftSlider.from, ifHighlightLiftSlider.to)
                                var delta = nv - iosFilterPopup.prevHighlightLift
                                ifHighlightLiftSlider.value = nv
                                iosFilterPopup.prevHighlightLift = nv
                                iosFilterPopup.fHighlightLift = nv
                                iosFilterPopup.pushParam("highlightLift", nv)
                                iosFilterPopup.applyLinkedDelta("highlightLift", delta)
                            }
                        }
                    }
                    Text { text: iosFilterPopup.fHighlightLift.toFixed(2); font.family: "PingFang HK"; font.pixelSize: 16; color: "#263238"; Layout.preferredWidth: 50 }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.highlightLift.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.brightSwitch = !lc.highlightLift.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.highlightLift.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.highlightLift.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.highlightLift.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.brightContrastSwitch = !lc.highlightLift.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.highlightLift.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.highlightLift.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.highlightLift.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.brightExposureSwitch = !lc.highlightLift.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.highlightLift.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.highlightLift.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.highlightLift.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.highlightLift.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                // ===== 增益(G) — 移入滤镜联动区 =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { Layout.preferredWidth: 28; text: iosFilterPopup.linkageConfig.gain.groupEnabled ? "●" : "○"; font.pixelSize: 22; color: iosFilterPopup.linkageConfig.gain.groupEnabled ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.groupEnabled = !lc.gain.groupEnabled; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 30; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.groupId > 0 ? "组" + iosFilterPopup.linkageConfig.gain.groupId : "—"; font.family: "PingFang HK"; font.pixelSize: 11; color: iosFilterPopup.linkageConfig.gain.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { iosFilterPopup.editingGroupParam = "gain"; iosFilterPopup.groupIdInput = iosFilterPopup.linkageConfig.gain.groupId; groupIdDialog.open() } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.groupDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gain.groupId > 0 ? "#4DB6AC" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gain.groupId > 0; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.groupDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { text: "增益(G)"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#E53935"; Layout.preferredWidth: 130 }
                    Slider {
                        id: ifGainSlider
                        Layout.fillWidth: true
                        from: iosFilterPopup.gainFrom; to: iosFilterPopup.gainTo; stepSize: iosFilterPopup.gainStep
                        value: iosFilterPopup.fGain
                        onMoved: {
                            var delta = value - iosFilterPopup.prevGain
                            iosFilterPopup.prevGain = value
                            iosFilterPopup.fGain = value
                            sendTestBrightnessConfig(Math.round(value))
                            iosFilterPopup.applyLinkedDelta("gain", delta)
                        }
                        onPressedChanged: if (!pressed) sendTestBrightnessConfig(Math.round(value))
                        background: Rectangle {
                            x: ifGainSlider.leftPadding
                            y: ifGainSlider.topPadding + ifGainSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifGainSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifGainSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#4DB6AC"
                            }
                        }
                        handle: Rectangle {
                            x: ifGainSlider.leftPadding + ifGainSlider.visualPosition * (ifGainSlider.availableWidth - width)
                            y: ifGainSlider.topPadding + ifGainSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#4DB6AC"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = iosFilterPopup.clampVal(ifGainSlider.value + dir * ifGainSlider.stepSize, ifGainSlider.from, ifGainSlider.to)
                                var delta = nv - iosFilterPopup.prevGain
                                ifGainSlider.value = nv
                                iosFilterPopup.prevGain = nv
                                iosFilterPopup.fGain = nv
                                sendTestBrightnessConfig(Math.round(nv))
                                iosFilterPopup.applyLinkedDelta("gain", delta)
                            }
                        }
                    }
                    Text {
                        text: iosCameraSettingsPopup.hardwareEVText()
                        font.family: "PingFang HK"; font.pixelSize: 14; color: "#263238"; Layout.preferredWidth: 50
                    }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.brightSwitch ? "☀" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.gain.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.brightSwitch = !lc.gain.brightSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.brightDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gain.brightSwitch ? "#FF9800" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gain.brightSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.brightDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.brightContrastSwitch ? "◆" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.gain.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.brightContrastSwitch = !lc.gain.brightContrastSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.brightContrastDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gain.brightContrastSwitch ? "#2196F3" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gain.brightContrastSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.brightContrastDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.brightExposureSwitch ? "◇" : "·"; font.pixelSize: 14; color: iosFilterPopup.linkageConfig.gain.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.brightExposureSwitch = !lc.gain.brightExposureSwitch; iosFilterPopup.linkageConfig = lc } } }
                    Text { Layout.preferredWidth: 20; visible: iosFilterPopup.pcFreeConfig; text: iosFilterPopup.linkageConfig.gain.brightExposureDirection === -1 ? "←" : "→"; font.pixelSize: 16; font.bold: true; color: iosFilterPopup.linkageConfig.gain.brightExposureSwitch ? "#9C27B0" : "#BDBDBD"; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: iosFilterPopup.linkageConfig.gain.brightExposureSwitch; onClicked: { var lc = JSON.parse(JSON.stringify(iosFilterPopup.linkageConfig)); lc.gain.brightExposureDirection *= -1; iosFilterPopup.linkageConfig = lc } } }
                }

                Rectangle {
                    visible: false
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: "#E0E0E0"
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "硬件参数（不受滤镜/LUT 开关影响）"
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    font.bold: true
                    color: "#546E7A"
                    visible: false
                }

                // ===== 白平衡(WB)：色温 2000K-8000K =====
                RowLayout {
                    visible: false
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                    Text { text: "白平衡"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#263238"; Layout.preferredWidth: 72 }
                    Slider {
                        id: ifFilterWhiteBalanceSlider
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        stepSize: 1
                        value: iosCameraSettingsPopup.hardwareWhiteBalance
                        onMoved: sendWhiteBalanceConfig(value)
                        onPressedChanged: if (!pressed) sendWhiteBalanceConfig(value)
                        background: Rectangle {
                            x: ifFilterWhiteBalanceSlider.leftPadding
                            y: ifFilterWhiteBalanceSlider.topPadding + ifFilterWhiteBalanceSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200; implicitHeight: 4
                            width: ifFilterWhiteBalanceSlider.availableWidth; height: 4
                            radius: 999; color: "#C8E6C9"
                            Rectangle {
                                width: ifFilterWhiteBalanceSlider.visualPosition * parent.width
                                height: parent.height; radius: 999; color: "#FF8A65"
                            }
                        }
                        handle: Rectangle {
                            x: ifFilterWhiteBalanceSlider.leftPadding + ifFilterWhiteBalanceSlider.visualPosition * (ifFilterWhiteBalanceSlider.availableWidth - width)
                            y: ifFilterWhiteBalanceSlider.topPadding + ifFilterWhiteBalanceSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14; implicitHeight: 14
                            width: 14; height: 14; radius: 7; color: "#FF8A65"
                        }
                        WheelHandler {
                            onWheel: function(event) {
                                if (event.angleDelta.y === 0) return
                                var dir = event.angleDelta.y > 0 ? 1 : -1
                                var nv = Math.max(0, Math.min(100, ifFilterWhiteBalanceSlider.value + dir))
                                ifFilterWhiteBalanceSlider.value = nv
                                sendWhiteBalanceConfig(nv)
                            }
                        }
                    }
                    Text {
                        text: iosCameraSettingsPopup.whiteBalanceText()
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#263238"
                        Layout.preferredWidth: 50
                    }
                    Rectangle {
                        width: 40; height: 22; radius: 4
                        color: applyWBMouseArea.containsMouse ? "#1565C0" : "#1976D2"
                        Text {
                            anchors.centerIn: parent
                            text: "运用"
                            font.family: "PingFang HK"
                            font.pixelSize: 12
                            font.bold: true
                            color: "#FFFFFF"
                        }
                        MouseArea {
                            id: applyWBMouseArea
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: iosFilterPopup.pushApplyWhiteBalance()
                        }
                    }
                }

                // ===== 自动 — 相机 AE，PC 暂无 STOMP =====
                RowLayout {
                    visible: false
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                    Text { text: "自动"; font.family: "PingFang HK"; font.pixelSize: 16; font.bold: true; color: "#90A4AE"; Layout.preferredWidth: 72 }
                    Text { text: "无法调"; font.family: "PingFang HK"; font.pixelSize: 14; color: "#90A4AE"; Layout.fillWidth: true }
                    Text { text: "—"; font.family: "PingFang HK"; font.pixelSize: 16; color: "#90A4AE"; Layout.preferredWidth: 50 }
                }

                // ===== 红色增强已锁死 0.02 (无滑块, 启动时由 pushAllStomp 推) =====

                // ===== 滤镜 / LUT 开关 + LUT 切换 =====
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: "#E0E0E0"
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    Repeater {
                        model: [
                            { label: "滤镜模式", checked: iosFilterPopup.fEnabled, action: "filter" },
                            { label: "LUT模式", checked: iosFilterPopup.lutEnabled, action: "lut" }
                        ]

                        delegate: RowLayout {
                            spacing: 6
                            Layout.preferredWidth: 96

                            Text {
                                text: modelData.label
                                font.family: "PingFang HK"
                                font.pixelSize: 13
                                font.bold: true
                                color: "#1976D2"
                                Layout.preferredWidth: 52
                                elide: Text.ElideRight
                            }
                            Rectangle {
                                width: 38; height: 22; radius: 11
                                color: modelData.checked ? "#1976D2" : "#E0E0E0"
                                Rectangle {
                                    width: 18; height: 18; radius: 9
                                    color: "#FFFFFF"
                                    x: modelData.checked ? 18 : 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    Behavior on x { NumberAnimation { duration: 150 } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (modelData.action === "filter") iosFilterPopup.pushFilterEnabled(!iosFilterPopup.fEnabled)
                                        else if (modelData.action === "lut") iosFilterPopup.pushLutEnabled(!iosFilterPopup.lutEnabled)
                                        else if (modelData.action === "hardware") iosFilterPopup.pushHardwareEnabled(!iosFilterPopup.hardwareEnabled)
                                        else if (modelData.action === "videoHDR") iosFilterPopup.pushVideoHDREnabled(!iosFilterPopup.videoHDREnabled)
                                        else if (modelData.action === "autoHDR") iosFilterPopup.pushAutoHDREnabled(!iosFilterPopup.autoHDREnabled)
                                        // applyWhiteBalance 已移到独立按钮
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: false
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "LUT 切换"
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: "#1976D2"
                    font.bold: true
                }

                Flow {
                    visible: false
                    Layout.fillWidth: true
                    spacing: 6

                    Repeater {
                        model: iosFilterPopup.lutOptions
                        delegate: Rectangle {
                            width: 84
                            height: 28
                            radius: 6
                            property bool isSelected: iosFilterPopup.selectedLutName === modelData.name
                            color: isSelected ? "#1976D2" : (lutBtnArea.containsMouse ? "#E3F2FD" : "#F5F5F5")
                            border.color: isSelected ? "#1565C0" : "#B0BEC5"
                            border.width: 1
                            opacity: iosFilterPopup.lutEnabled ? 1.0 : 0.55

                            Text {
                                anchors.centerIn: parent
                                text: modelData.label
                                font.family: "PingFang HK"
                                font.pixelSize: 12
                                font.bold: parent.isSelected
                                color: parent.isSelected ? "#FFFFFF" : "#37474F"
                            }

                            MouseArea {
                                id: lutBtnArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: iosFilterPopup.selectLut(modelData.name)
                            }
                        }
                    }
                }

                // 底部留空 (正式后端没有 IosFilterController, "保存为系统默认"按钮已去掉)
                Item { Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }

    // ============ ⭐ iOS 采集颜色调节 Window（L 键，硬件白平衡 WB gain）============
    Window {
        id: iosCaptureAdjustPopup
        width: 560
        height: 680
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "transparent"
        visible: false

        function open() { visible = true }
        function close() { visible = false }

        property point dragStart: Qt.point(0, 0)
        property bool dragging: false

        property double fWbTemperature: 0
        property double fWbTint: 0
        property double fWbRed: 0
        property double fWbGreen: 0
        property double fWbBlue: 0
        property double fWbBlack: 0
        property double fWbWhite: 0
        property double fWbAmber: 0

        readonly property var captureColorRows: [
            { label: "冷暖", prop: "fWbTemperature" },
            { label: "黄/琥珀", prop: "fWbAmber" },
            { label: "绿紫", prop: "fWbTint" },
            { label: "红",   prop: "fWbRed" },
            { label: "绿",   prop: "fWbGreen" },
            { label: "蓝",   prop: "fWbBlue" },
            { label: "黑",   prop: "fWbBlack" },
            { label: "白",   prop: "fWbWhite" }
        ]

        function clampWb(v) { return Math.max(-1, Math.min(1, v)) }

        function pushCaptureColor() {
            sendConfigUpdate("captureColor", {
                temperature: fWbTemperature,
                tint: fWbTint,
                red: fWbRed,
                green: fWbGreen,
                blue: fWbBlue,
                black: fWbBlack,
                white: fWbWhite,
                amber: fWbAmber
            })
        }

        function resetLocal() {
            fWbTemperature = 0
            fWbTint = 0
            fWbRed = 0
            fWbGreen = 0
            fWbBlue = 0
            fWbBlack = 0
            fWbWhite = 0
            fWbAmber = 0
        }

        function resetCaptureColor() {
            resetLocal()
            sendConfigUpdate("captureColorReset", { cmd: "reset" })
        }

        Rectangle {
            anchors.fill: parent
            color: "#FFFFFF"
            radius: 4
            border.color: "#A5D6A7"
            border.width: 1

            ColumnLayout {
                spacing: 12
                anchors.fill: parent
                anchors.margins: 24

                // ===== 标题栏 =====
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    color: "transparent"

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.ClosedHandCursor
                        property point startPos: Qt.point(0, 0)
                        property point dragStartGlobal: Qt.point(0, 0)
                        onPressed: function(mouse) {
                            startPos = Qt.point(iosCaptureAdjustPopup.x, iosCaptureAdjustPopup.y)
                            dragStartGlobal = mapToGlobal(mouse.x, mouse.y)
                            iosCaptureAdjustPopup.dragging = true
                            mouse.accepted = true
                        }
                        onPositionChanged: function(mouse) {
                            if (iosCaptureAdjustPopup.dragging) {
                                var g = mapToGlobal(mouse.x, mouse.y)
                                iosCaptureAdjustPopup.x = startPos.x + (g.x - dragStartGlobal.x)
                                iosCaptureAdjustPopup.y = startPos.y + (g.y - dragStartGlobal.y)
                            }
                        }
                        onReleased: iosCaptureAdjustPopup.dragging = false
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: icaResetText.width + 20
                        height: 28
                        radius: 6
                        color: icaResetArea.containsMouse ? "#C8E6C9" : "#E8F5E9"
                        border.color: "#A5D6A7"
                        border.width: 1
                        Text {
                            id: icaResetText
                            anchors.centerIn: parent
                            text: "还原"
                            font.family: "PingFang HK"
                            font.pixelSize: 14
                            color: "#263238"
                        }
                        MouseArea {
                            id: icaResetArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: iosCaptureAdjustPopup.resetCaptureColor()
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "iOS 采集颜色调节"
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        font.bold: true
                        color: "#263238"
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 24
                        radius: 12
                        color: icaCloseBtn.containsMouse ? "#C8E6C9" : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            font.pixelSize: 14
                            color: "#546E7A"
                        }
                        MouseArea {
                            id: icaCloseBtn
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: iosCaptureAdjustPopup.close()
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "拖动滑块松手即推送 iOS（滚轮亦可），无需额外点击"
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: "#90A4AE"
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: iosCaptureAdjustPopup.captureColorRows
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        property string propName: modelData.prop

                        Text {
                            text: modelData.label
                            font.family: "PingFang HK"
                            font.pixelSize: 20
                            font.bold: true
                            color: "#E53935"
                            Layout.preferredWidth: 56
                        }
                        Slider {
                            id: wbSlider
                            Layout.fillWidth: true
                            from: -1
                            to: 1
                            stepSize: 0.05
                            value: iosCaptureAdjustPopup[propName]
                            onMoved: {
                                iosCaptureAdjustPopup[propName] = iosCaptureAdjustPopup.clampWb(value)
                                iosCaptureAdjustPopup.pushCaptureColor()
                            }
                            onPressedChanged: if (!pressed) iosCaptureAdjustPopup.pushCaptureColor()
                            background: Rectangle {
                                x: wbSlider.leftPadding
                                y: wbSlider.topPadding + wbSlider.availableHeight / 2 - height / 2
                                implicitWidth: 200
                                implicitHeight: 4
                                width: wbSlider.availableWidth
                                height: 4
                                radius: 999
                                color: "#C8E6C9"
                                Rectangle {
                                    width: wbSlider.visualPosition * parent.width
                                    height: parent.height
                                    radius: 999
                                    color: "#4DB6AC"
                                }
                            }
                            handle: Rectangle {
                                x: wbSlider.leftPadding + wbSlider.visualPosition * (wbSlider.availableWidth - width)
                                y: wbSlider.topPadding + wbSlider.availableHeight / 2 - height / 2
                                implicitWidth: 14
                                implicitHeight: 14
                                width: 14
                                height: 14
                                radius: 7
                                color: "#4DB6AC"
                            }
                            WheelHandler {
                                onWheel: function(event) {
                                    if (event.angleDelta.y === 0) return
                                    var dir = event.angleDelta.y > 0 ? 1 : -1
                                    var nv = iosCaptureAdjustPopup.clampWb(wbSlider.value + dir * wbSlider.stepSize)
                                    wbSlider.value = nv
                                    iosCaptureAdjustPopup[propName] = nv
                                    iosCaptureAdjustPopup.pushCaptureColor()
                                }
                            }
                        }
                        Text {
                            text: iosCaptureAdjustPopup[propName].toFixed(2)
                            font.family: "PingFang HK"
                            font.pixelSize: 16
                            color: "#263238"
                            Layout.preferredWidth: 50
                        }
                    }
                }

                Item { Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }

    // ⭐⭐⭐ 内核测试浮动窗口（Chromium WebEngine 拉 SRS 流，对比 GStreamer 画质）
    //   可拖动 + 可缩放，默认靠右半屏，下面露出 GStreamer 画面方便左右对比。
    //   用 Loader 动态加载 KernelTestView.qml，把 WebEngine 依赖隔离；加载失败只提示不崩。
    Rectangle {
        id: kernelTestOverlay
        z: 99000
        visible: false
        color: "#000000"
        border.color: "#1565C0"
        border.width: 2

        // 默认：靠右、占约一半宽、上下留边
        width: Math.min(820, mainPage.width * 0.5)
        height: Math.min(560, mainPage.height * 0.8)
        x: mainPage.width - width - 20
        y: 60

        function openTest() {
            // 每次打开复位到默认位置/大小
            width = Math.min(820, mainPage.width * 0.5)
            height = Math.min(560, mainPage.height * 0.8)
            x = mainPage.width - width - 20
            y = 60
            visible = true
            kernelLoader.active = true
        }
        function closeTest() {
            if (kernelLoader.item && kernelLoader.item.stopTest)
                kernelLoader.item.stopTest()
            kernelLoader.active = false
            visible = false
        }

        // ⭐ 接 kernelBridge 信号：P2P 测试开始时断开 GStreamer P2P 让出会话；结束时恢复
        Connections {
            target: (typeof kernelBridge !== 'undefined' && kernelBridge) ? kernelBridge : null
            ignoreUnknownSignals: true
            function onRequestStopGstP2P() {
                console.log("[内核测试] 收到请求 → 进入内核测试模式，GStreamer 彻底让出 P2P")
                // ⭐ 用硬开关让 GStreamer 完全退场：不拉流/不渲染/不处理信令，且拦截任何自动重连重启。
                //   （旧做法只 disconnectP2P，会被 watchdog/状态变化重新 playP2P，导致双端抢会话→内核黑屏）
                if (gstPlayer.setKernelTestMode) gstPlayer.setKernelTestMode(true)
            }
            function onRequestResumeGstP2P() {
                console.log("[内核测试] 结束 → 退出内核测试模式，恢复 GStreamer P2P")
                if (gstPlayer.setKernelTestMode) gstPlayer.setKernelTestMode(false)
                if (mainPage.connectMode === 1) {
                    playP2P()
                }
            }
        }

        // 标题栏（可拖动整个窗口）
        Rectangle {
            id: kernelTitleBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 34
            color: "#1565C0"
            z: 10

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.right: kernelBtnRow.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: "内核测试 · Chromium · 拖标题移动 / 拖右下角缩放 / 对比下方 GStreamer"
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#FFFFFF"
            }

            // 拖动：移动整个窗口
            MouseArea {
                anchors.fill: parent
                anchors.rightMargin: 140
                cursorShape: Qt.SizeAllCursor
                property real startX: 0
                property real startY: 0
                onPressed: function(mouse) { startX = mouse.x; startY = mouse.y }
                onPositionChanged: function(mouse) {
                    if (pressed) {
                        kernelTestOverlay.x += (mouse.x - startX)
                        kernelTestOverlay.y += (mouse.y - startY)
                    }
                }
            }

            Row {
                id: kernelBtnRow
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                // 全屏 / 还原
                Rectangle {
                    width: 56; height: 24; radius: 4
                    color: fsArea.containsMouse ? "#42A5F5" : "#1E88E5"
                    Text { anchors.centerIn: parent; text: "全屏"; font.pixelSize: 12; color: "#FFFFFF" }
                    MouseArea {
                        id: fsArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            kernelTestOverlay.x = 0
                            kernelTestOverlay.y = 0
                            kernelTestOverlay.width = mainPage.width
                            kernelTestOverlay.height = mainPage.height
                        }
                    }
                }

                Rectangle {
                    width: 56; height: 24; radius: 4
                    color: closeKernelArea.containsMouse ? "#E53935" : "#C62828"
                    Text { anchors.centerIn: parent; text: "关闭"; font.pixelSize: 12; color: "#FFFFFF" }
                    MouseArea {
                        id: closeKernelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: kernelTestOverlay.closeTest()
                    }
                }
            }
        }

        Loader {
            id: kernelLoader
            anchors.top: kernelTitleBar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 2
            active: false
            asynchronous: true
            source: "KernelTestView.qml"
            onLoaded: {
                if (item && item.startTest) {
                    var mode = (mainPage.connectMode === 1) ? "p2p" : "srs"
                    item.startTest(mode, mainPage.srsServer, "tenantA", mainPage.currentStream, "vid-7gg4748", mainPage.videoCodec)
                }
            }
            onStatusChanged: {
                if (status === Loader.Error) {
                    kernelLoadErrText.visible = true
                }
            }
        }

        Text {
            id: kernelLoadErrText
            visible: false
            anchors.centerIn: parent
            text: "未启用内核测试：Qt WebEngine 模块缺失或未编译。\n请确认 CMake 检测到 WebEngineQuick 并重新构建。"
            horizontalAlignment: Text.AlignHCenter
            font.family: "PingFang HK"
            font.pixelSize: 16
            color: "#FF5252"
        }

        // 右下角缩放手柄
        Rectangle {
            width: 18
            height: 18
            color: "#1565C0"
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            z: 20

            Text {
                anchors.centerIn: parent
                text: "⤡"
                font.pixelSize: 12
                color: "#FFFFFF"
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeFDiagCursor
                property real startX: 0
                property real startY: 0
                onPressed: function(mouse) { startX = mouse.x; startY = mouse.y }
                onPositionChanged: function(mouse) {
                    if (pressed) {
                        var nw = kernelTestOverlay.width + (mouse.x - startX)
                        var nh = kernelTestOverlay.height + (mouse.y - startY)
                        kernelTestOverlay.width = Math.max(320, nw)
                        kernelTestOverlay.height = Math.max(240, nh)
                    }
                }
            }
        }
    }
}

