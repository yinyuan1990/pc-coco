import QtQuick
import QtQuick.Layouts

// ⭐ 第五十章：OTG(外接UVC) 版实时流底部按钮栏 —— 独立重写，与自带摄像头那排分开。
//
// 为什么不复用老那排：老那排的「档位」是固定 5 档（标清~4K）、「变倍」是 1.0~3.0 倍数、
// 还有「前后置」——这三样在 UVC 上全部不成立（档位=设备枚举的分辨率、变焦是百分比、单摄）。
// 硬塞进去就是满屏 if-else 和灰按钮，所以整排重写。
//
// 提取出来公用的：LiveBarButton（按钮外观）+ LiveBarMenu（下拉），两排共用同一套外观语言。
// 右半边那些「镜像 / 本地缩放 / 旋转 / 睡眠 / 工作」是 PC 本地或与镜头无关的通用操作，
// 两种模式行为完全一样，这里只发信号、由 MainPage 接到既有实现上（不重复实现一遍）。
RowLayout {
    id: bar

    spacing: 8

    // ===== 由 MainPage 绑进来的通用状态 =====
    //   注意：别起名 rotation —— 那是 Item 的内建属性，绑上去会把整排按钮转起来
    property string mirrorMode: "none"
    property real   localZoom: 1.0
    property int    videoRotation: 0
    property string deviceStatus: ""

    // ===== 设备侧下发（一律 otg_ 前缀，与自带摄像头通道分家）=====
    signal sendOtg(string ptype, var payload)
    // ===== 通用操作（沿用 MainPage 既有实现）=====
    signal mirrorModeRequested(string mode)
    signal localZoomResetRequested()
    signal rotateRequested(int step)
    signal sleepRequested()
    signal workRequested()
    signal openPanelRequested()

    // 推送帧率 / 码率：设备不回报，PC 是唯一下发方，状态存这里
    property int pushFps: 30
    property int bitratePct: 50

    // 推流上限 = min(编码器该尺寸真实能力, 采集实际帧率)，都来自设备上报，不写死
    function fpsCap() {
        return Math.max(1, Math.min(CameraCapsStore.pushFpsCapOfCurrentSize(),
                                    CameraCapsStore.maxFpsOfCurrentSize()))
    }

    function fpsOptions() {
        var cap = bar.fpsCap()
        var out = []
        var candidates = [5, 10, 15, 20, 25, 30, 45, 60, 90, 120]
        for (var i = 0; i < candidates.length; i++)
            if (candidates[i] <= cap) out.push({ label: candidates[i] + "fps", value: candidates[i] })
        if (out.length === 0) out.push({ label: cap + "fps", value: cap })
        return out
    }

    function bitrateOptions() {
        var ceil = CameraCapsStore.maxKbpsOfCurrentSize()
        var out = []
        var pcts = [20, 40, 60, 80, 100]
        for (var i = 0; i < pcts.length; i++) {
            var p = pcts[i]
            out.push({
                label: ceil > 0 ? (p + "%  " + Math.round(ceil * p / 100) + "k") : (p + "%"),
                value: p
            })
        }
        return out
    }

    function sizeOptions() {
        // 只列编码器吃得下的档位（低于编码器最小尺寸的选了必黑）
        var usable = CameraCapsStore.usableSizes()
        var out = []
        for (var i = 0; i < usable.length; i++)
            out.push({ label: CameraCapsStore.sizeLabel(usable[i]), value: usable[i] })
        return out
    }

    Connections {
        target: CameraCapsStore
        function onCapsUpdated() {
            if (CameraCapsStore.devicePushFps > 0)    bar.pushFps = CameraCapsStore.devicePushFps
            if (CameraCapsStore.deviceBitratePct > 0) bar.bitratePct = CameraCapsStore.deviceBitratePct
        }
    }

    // ===== 档位 = 设备枚举出的分辨率（几档就是几档）=====
    LiveBarButton {
        id: sizeBtn
        minWidth: 96
        hasArrow: true
        highlighted: sizeMenu.visible
        label: CameraCapsStore.curWidth > 0
               ? CameraCapsStore.curWidth + "x" + CameraCapsStore.curHeight
               : "外接"
        onClicked: sizeMenu.toggle()

        LiveBarMenu {
            id: sizeMenu
            itemWidth: 132
            anchors.bottom: parent.top
            anchors.bottomMargin: 4
            anchors.horizontalCenter: parent.horizontalCenter
            options: bar.sizeOptions()
            isCurrent: function(v) {
                return v.width === CameraCapsStore.curWidth && v.height === CameraCapsStore.curHeight
            }
            onPicked: function(v) {
                // ⭐ 2026-08-02：未知 fps 的档位按最大（120）请求，UVC 就近协商（原来兜底 30 会白压采集）
                var fps = v.maxFps > 0 ? v.maxFps : 120
                bar.sendOtg("otg_resolution", { "width": v.width, "height": v.height, "fps": fps })
                CameraCapsStore.setLocalSize(v.width, v.height)
                if (bar.pushFps > fps) {
                    bar.pushFps = fps
                    bar.sendOtg("otg_fps", { "fps": fps })
                }
            }
        }
    }

    // ⭐ §56.23（2026-08-08 用户拍板）：底部栏去掉「推送帧率 / 码率百分比 / 变焦 / 设定」
    //   四个按钮——这些调节全部收进 OTG 弹框面板（入口：顶部菜单 / O 快捷键）。
    //   pushFps/bitratePct 属性与 fpsOptions()/bitrateOptions() 保留：档位切换联动降 fps
    //   仍要用（sizeMenu.onPicked），面板/设备上报同步也照旧。

    Item { Layout.fillWidth: true }

    // ===== 以下与镜头无关，两种模式行为一致：只发信号，复用 MainPage 既有实现 =====

    LiveBarButton {
        id: mirrorBtn
        hasArrow: true
        highlighted: mirrorMenu.visible || bar.mirrorMode !== "none"
        label: bar.mirrorMode === "horizontal" ? "水平"
             : bar.mirrorMode === "vertical" ? "垂直" : "镜像"
        onClicked: mirrorMenu.toggle()

        LiveBarMenu {
            id: mirrorMenu
            itemWidth: 68
            anchors.bottom: parent.top
            anchors.bottomMargin: 4
            anchors.horizontalCenter: parent.horizontalCenter
            options: [
                { label: "关闭", value: "none" },
                { label: "水平", value: "horizontal" },
                { label: "垂直", value: "vertical" }
            ]
            currentValue: bar.mirrorMode
            onPicked: function(v) { bar.mirrorModeRequested(v) }
        }
    }

    LiveBarButton {
        visible: bar.localZoom > 1.0
        label: bar.localZoom.toFixed(1) + "x"
        onClicked: bar.localZoomResetRequested()
    }

    LiveBarButton {
        label: bar.videoRotation + "°"
        minWidth: 40
        onClicked: bar.rotateRequested(1)
        onWheeled: function(d) { bar.rotateRequested(d) }
    }

    LiveBarButton {
        id: sleepWorkBtn
        label: (bar.deviceStatus === "sleeping" ? "睡眠" : "工作") + " ▼"
        onClicked: sleepWorkMenu.toggle()

        LiveBarMenu {
            id: sleepWorkMenu
            anchors.bottom: parent.top
            anchors.bottomMargin: 4
            anchors.horizontalCenter: parent.horizontalCenter
            itemWidth: 64
            options: [
                { label: "工作", value: "work" },
                { label: "睡眠", value: "sleep" }
            ]
            currentValue: bar.deviceStatus === "sleeping" ? "sleep" : "work"
            onPicked: function(v) {
                if (v === "sleep") bar.sleepRequested()
                else bar.workRequested()
            }
        }
    }
}
