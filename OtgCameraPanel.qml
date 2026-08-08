import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ⭐ 第五十章：OTG(外接UVC) 相机调节面板 —— 完全按设备上报的能力**动态生成**。
//
// 与自带摄像头面板（MainPage.qml 里的 iosCameraSettingsPopup）彻底分开的理由：
//   · 档位不是固定 5 档，是设备枚举出来的分辨率列表（这台 7 档、那台 3 档，尺寸各不相同）
//   · 硬件可调项逐台不同（有的有变焦没对焦，有的连白平衡都没有）
//   · 快门(cjfps) / 前后摄 在 UVC 上根本不存在
// 所以这里不渲染"不支持的灰按钮"——设备没有的项直接不画。
//
// 下发一律走 `otg_` 前缀（见 Android 侧 OtgConfigRouter），与老通道互不干扰；
// 本面板不认识 STOMP，只发 sendOtg 信号，由 MainPage 接到 sendConfigUpdate 上。
Window {
    id: panel

    width: 520
    // ⭐ 需求#6（2026-07-31）：高度=内容高，封顶 880；超出部分由 Flickable 滚动。
    //   以前内容直接被窗口裁掉——分辨率档位多的设备"显示不完全"，且底部的
    //   还原/刷新按钮跟着被裁没（用户报"没有还原按钮"，其实是被裁掉了）。
    height: Math.min(880, contentColumn.implicitHeight + 150)
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "transparent"
    visible: false

    // ptype 以 otg_ 开头，payload 是对象
    signal sendOtg(string ptype, var payload)

    // 推送帧率 / 码率：以**设备回报的真值**为准（初始值来自后端下发的配置，
    // 面板自己猜一个缺省会和设备实际状态对不上——之前面板显示 50%、设备其实是 60%）
    property int pushFps: 30
    property int bitratePct: 50

    Connections {
        target: CameraCapsStore
        function onCapsUpdated() {
            if (CameraCapsStore.devicePushFps > 0)    panel.pushFps = CameraCapsStore.devicePushFps
            if (CameraCapsStore.deviceBitratePct > 0) panel.bitratePct = CameraCapsStore.deviceBitratePct
        }
    }

    // 推流侧帧率天花板 = 手机编码器在当前尺寸的真实能力（设备随能力快照上报），不再写死 60
    readonly property int pushFpsCeiling: CameraCapsStore.pushFpsCapOfCurrentSize()

    // 采集侧格式：⭐ 需求#6（2026-07-31）固定 MJPEG（1），面板不再提供格式选择。
    //   USB2.0 带宽下 1080p30 必须 MJPEG；设备端 preferredFormat=1 时仍保留 YUYV 兜底
    //   （UvcVideoCapturer.strategies()：mjpeg 谈不拢自动降 YUYV，不会黑屏）。
    property int captureFormat: 1
    // ⭐ 2026-08-02：「采集帧率」手动选择已移除——切档一律按最大请求（120，设备端硬上限
    //   OTG_MAX_CAPTURE_FPS），UVC 谈不拢自动就近回退，实际协商值在"设备实际协商"行如实显示。
    //   采集上限直接体现在「推送帧率」滑条的 max 上（= min(编码器上限, 采集协商值)），无需再选。
    readonly property int captureFpsRequest: 120
    // 「还原」用的出厂缺省
    readonly property int defaultBitratePct: 50

    function defaultPushFps() {
        var cap = Math.min(pushFpsCeiling, CameraCapsStore.maxFpsOfCurrentSize())
        return Math.min(30, cap)      // 默认 30，设备撑不到就取它能给的
    }

    function open() {
        // 每次打开都问设备要一次最新能力（换了摄像头/重新协商过都能刷新）
        panel.sendOtg("otg_get_caps", {})
        visible = true
        raise()
        requestActivate()
    }
    function close() { visible = false }

    // ⭐ 还原：硬件项回设备**出厂缺省**（Android 在首次枚举时记下的原始值，一条 otg_reset 全量回落，
    //   不是 PC 逐项猜一个"中间值"发下去），推送帧率/码率回本面板缺省。
    function resetAll() {
        panel.sendOtg("otg_reset", {})
        panel.pushFps = panel.defaultPushFps()
        panel.bitratePct = panel.defaultBitratePct
        panel.sendOtg("otg_fps", { "fps": panel.pushFps })
        panel.sendOtg("otg_bitrate", { "bitrate": panel.bitratePct })
        // 设备回落完会重推一次能力快照，滑条随 controls[].cur 自动归位
    }

    property point dragStartGlobal: Qt.point(0, 0)
    property point dragStartPos: Qt.point(0, 0)
    property bool dragging: false

    Rectangle {
        anchors.fill: parent
        color: "#FFFFFF"
        radius: 4
        border.color: "#A5D6A7"
        border.width: 1

        // ⭐ 需求#6：外层三段式——标题（固定）+ 内容（Flickable 滚动）+ 底部按钮（固定）。
        //   还原/刷新永远可见，分辨率再多也只是中间滚动。
        ColumnLayout {
            id: outerColumn
            anchors.fill: parent
            anchors.margins: 20
            spacing: 10

            // ===== 标题栏（可拖动）=====
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                color: "transparent"

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.ClosedHandCursor
                    onPressed: function(mouse) {
                        panel.dragStartPos = Qt.point(panel.x, panel.y)
                        panel.dragStartGlobal = mapToGlobal(mouse.x, mouse.y)
                        panel.dragging = true
                    }
                    onPositionChanged: function(mouse) {
                        if (!panel.dragging) return
                        var g = mapToGlobal(mouse.x, mouse.y)
                        panel.x = panel.dragStartPos.x + (g.x - panel.dragStartGlobal.x)
                        panel.y = panel.dragStartPos.y + (g.y - panel.dragStartGlobal.y)
                    }
                    onReleased: panel.dragging = false
                }

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "外接摄像头设定"
                    font.family: "PingFang HK"
                    font.pixelSize: 15
                    font.bold: true
                    color: "#263238"
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 26; height: 26; radius: 13
                    color: closeArea.containsMouse ? "#FFCDD2" : "transparent"
                    Text {
                        anchors.centerIn: parent
                        text: "✕"; font.pixelSize: 13; color: "#546E7A"
                    }
                    MouseArea {
                        id: closeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.close()
                    }
                }
            }

            // ⭐ 需求#6：中间内容区可滚动（内容高 > 窗口高时鼠标滚轮/拖动查看）
            Flickable {
                id: scroller
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: contentColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                // ⭐ §56.23：多分辨率镜头内容超高时显示可拖动的滚动条（此前只能滚轮盲滑，
                //   用户不知道下面还有内容）。内容不超高时自动隐藏。
                ScrollBar.vertical: ScrollBar {
                    policy: scroller.contentHeight > scroller.height
                            ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    width: 8
                }

                ColumnLayout {
                    id: contentColumn
                    width: scroller.width
                    spacing: 10

            // ===== 设备信息 =====
            Text {
                Layout.fillWidth: true
                text: CameraCapsStore.capsReady
                      ? (CameraCapsStore.deviceName || "UVC 摄像头")
                        + "  ·  当前 " + CameraCapsStore.curWidth + "x" + CameraCapsStore.curHeight
                      : "正在读取外接摄像头能力…（设备开流后自动上报）"
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#546E7A"
                elide: Text.ElideRight
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#E8F5E9" }

            // ===== 档位 = 设备分辨率列表（几档就是几档）=====
            Text {
                text: "档位（分辨率）" + (CameraCapsStore.usableSizes().length > 0
                                        ? "  共" + CameraCapsStore.usableSizes().length + "档" : "")
                      + (CameraCapsStore.blockedSizeCount() > 0
                         ? "（另有 " + CameraCapsStore.blockedSizeCount() + " 档低于编码器最小尺寸，已屏蔽）" : "")
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#263238"
                visible: CameraCapsStore.sizes.length > 0
            }

            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: CameraCapsStore.sizes.length > 0

                Repeater {
                    // 全部档位都列出来（含编码器吃不下的，灰显不可点，见下面 usable）——
                    // 直接过滤掉的话用户会疑惑"设备明明有4档，面板怎么只剩3档"
                    model: CameraCapsStore.sizes

                    Rectangle {
                        // 编码器吃不下的尺寸（低于硬件 H264/HEVC 最小分辨率）：采集正常但编码器
                        // 一帧不出，点了必黑。这里保留显示并说明原因，但不让点——直接隐藏的话
                        // 用户会疑惑"设备明明有 4 档，面板怎么只有 3 档"。
                        property bool usable: modelData.encodable !== false
                        property bool active: usable
                                              && modelData.width === CameraCapsStore.curWidth
                                              && modelData.height === CameraCapsStore.curHeight
                        width: Math.max(100, sizeText.implicitWidth + 18)
                        height: 38
                        radius: 4
                        color: !usable ? "#ECEFF1"
                             : (active ? "#A5D6A7" : (sizeArea.containsMouse ? "#E8F5E9" : "#FFFFFF"))
                        border.color: active ? "#4CAF50" : "#E0E0E0"
                        border.width: 1

                        Text {
                            id: sizeText
                            anchors.centerIn: parent
                            text: CameraCapsStore.sizeLabel(modelData)
                                  + (parent.usable
                                     ? (modelData.maxKbps > 0 ? "\n" + modelData.maxKbps + "k" : "")
                                     : "\n编码器不支持")
                            horizontalAlignment: Text.AlignHCenter
                            lineHeight: 0.85
                            font.family: "PingFang HK"
                            font.pixelSize: 11
                            font.bold: parent.active
                            color: parent.usable ? "#263238" : "#90A4AE"
                        }

                        MouseArea {
                            id: sizeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: parent.usable ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                            onClicked: {
                                if (!parent.usable) return
                                // ⭐ 2026-08-02：采集帧率不手选——该档设备**声明了** fps 就按声明值
                                //   请求（读出来的真值）；没声明（不少 UVC 库不吐每档 fps）才按最大
                                //   （120）喊价，UVC 就近协商，谈成多少看"设备实际协商"行。
                                panel.sendOtg("otg_resolution", {
                                    "width": modelData.width,
                                    "height": modelData.height,
                                    "fps": (modelData.maxFps > 0 ? modelData.maxFps : panel.captureFpsRequest),
                                    "format": panel.captureFormat
                                })
                                CameraCapsStore.setLocalSize(modelData.width, modelData.height)
                            }
                        }
                    }
                }
            }

            // ===== 采集协商结果（只显示，不再手动选）=====
            //   ⭐ 需求#6：「采集格式」固定 MJPEG；⭐ 2026-08-02：「采集帧率」选择也移除——
            //   切档按最大（120）请求、UVC 就近协商，结果在这行如实显示。
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "设备实际协商：" + (CameraCapsStore.capsReady
                          ? (CameraCapsStore.curWidth + "x" + CameraCapsStore.curHeight
                             + " " + (CameraCapsStore.activeFormat || "?")
                             + " " + CameraCapsStore.maxFpsOfCurrentSize() + "fps"
                             + (CameraCapsStore.fpsIsKnown() ? "" : "（估算）"))
                          : "—")
                      + "。采集按该档最大帧率自动协商，以这里显示的为准。"
                font.family: "PingFang HK"
                font.pixelSize: 11
                color: "#90A4AE"
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#E8F5E9" }

            // ===== 推送帧率 / 码率（软件侧，与镜头无关，逻辑同自带摄像头）=====
            CameraControlRow {
                label: "推送帧率"
                ctrlType: "pct"
                minValue: 1
                // 上限 = min(编码器该尺寸能编多快, 采集协商/实测值)——采集 fps 上限直接体现在
                // 这根滑条的 max 上（采集已按该档最大自动协商，不需要用户再选）。
                maxValue: Math.max(1, Math.min(panel.pushFpsCeiling, CameraCapsStore.maxFpsOfCurrentSize()))
                value: panel.pushFps
                unit: "fps"
                onMoved: function(v) { panel.pushFps = v }
                onCommitted: function(v) {
                    panel.pushFps = v
                    panel.sendOtg("otg_fps", { "fps": v })
                }
            }

            // 把"采集"和"推送"两个上限说清楚——它们不是一回事，容易看岔
            Text {
                Layout.fillWidth: true
                visible: CameraCapsStore.maxFpsOfCurrentSize() > 0
                text: "　　　　采集 " + CameraCapsStore.maxFpsOfCurrentSize() + "fps"
                      + (CameraCapsStore.fpsIsKnown() ? "（协商/实测）" : "（未知，按30估）")
                      + " → 编码器上限 " + panel.pushFpsCeiling + "fps"
                      + (CameraCapsStore.deviceThermalCap > 0
                         ? " → ⚠️ 手机发热，热控当前压到 " + CameraCapsStore.deviceThermalCap + "fps（降温自动放开）"
                         : "")
                      + "。推流按三者最小值生效"
                font.family: "PingFang HK"
                font.pixelSize: 11
                color: "#90A4AE"
            }

            CameraControlRow {
                label: "码率"
                ctrlType: "pct"
                minValue: 10
                maxValue: 100
                value: panel.bitratePct
                unit: "%"
                onMoved: function(v) { panel.bitratePct = v }
                onCommitted: function(v) {
                    panel.bitratePct = v
                    panel.sendOtg("otg_bitrate", { "bitrate": v })
                }
            }

            // 码率上限随分辨率走：设备按"最大分辨率=现有最高档码率"为锚、按像素率等比算好后上报，
            // 这里只显示，公式不在 PC 侧重复实现
            Text {
                Layout.fillWidth: true
                visible: CameraCapsStore.maxKbpsOfCurrentSize() > 0
                text: "　　　　本档上限 " + CameraCapsStore.maxKbpsOfCurrentSize() + " kbps"
                      + "  →  当前约 "
                      + Math.round(CameraCapsStore.maxKbpsOfCurrentSize() * panel.bitratePct / 100) + " kbps"
                font.family: "PingFang HK"
                font.pixelSize: 11
                color: "#90A4AE"
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: "#E8F5E9"
                visible: CameraCapsStore.supportedControls().length > 0
            }

            Text {
                text: "硬件可调项（该摄像头支持 " + CameraCapsStore.supportedControls().length + " 项）"
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#263238"
                visible: CameraCapsStore.supportedControls().length > 0
            }

            // ===== 硬件可调项：设备支持哪些就长哪些 =====
            Repeater {
                model: CameraCapsStore.supportedControls()

                CameraControlRow {
                    Layout.fillWidth: true
                    label: modelData.label
                    ctrlType: modelData.type
                    minValue: modelData.min
                    maxValue: modelData.max
                    options: modelData.options || []
                    value: modelData.cur < 0 ? 0 : modelData.cur
                    unit: modelData.type === "pct" ? "%" : ""
                    onCommitted: function(v) {
                        panel.sendOtg("otg_ctrl", { "key": modelData.key, "value": v })
                        CameraCapsStore.setLocalValue(modelData.key, v)
                    }
                }
            }

            // ===== 能力还没到 =====
            Text {
                Layout.fillWidth: true
                visible: !CameraCapsStore.capsReady
                text: "外接摄像头插上并开流后，设备会自动上报可调能力。\n若长时间没有，检查手机端是否已选「外接OTG」并成功出画面。"
                wrapMode: Text.WordWrap
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#90A4AE"
            }

                }   // contentColumn
            }   // scroller（Flickable）

            // ===== 底部（固定不滚动，还原/刷新永远可见）=====
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    Layout.preferredWidth: 76
                    Layout.preferredHeight: 30
                    radius: 4
                    color: resetArea.containsMouse ? "#FFE0B2" : "#FFF8E1"
                    border.color: "#FFB74D"; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "还原"
                        font.family: "PingFang HK"; font.pixelSize: 12; color: "#E65100"
                    }
                    MouseArea {
                        id: resetArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.resetAll()
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 90
                    Layout.preferredHeight: 30
                    radius: 4
                    color: refreshArea.containsMouse ? "#C8E6C9" : "#F1F8E9"
                    border.color: "#A5D6A7"; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "刷新能力"
                        font.family: "PingFang HK"; font.pixelSize: 12; color: "#33691E"
                    }
                    MouseArea {
                        id: refreshArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.sendOtg("otg_get_caps", {})
                    }
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: "ver " + CameraCapsStore.version
                    font.pixelSize: 10
                    color: "#B0BEC5"
                    visible: CameraCapsStore.capsReady
                }
            }
        }
    }
}
