import QtQuick

// ⭐ 第五十章：实时流底部按钮栏的**公用按钮控件**。
//
// 原来底部那一坨按钮每个都是「Rectangle + Text + MouseArea」手抄一遍（同样的黑底半透明、
// hover 变浅绿、文字白转深灰），抄了九份。这里抽成一个控件：
// 自带摄像头那排保持原样不动（生产链路不冒回归风险），OTG 那排用这个控件搭。
//
// 用法：
//   LiveBarButton { label: "睡眠"; onClicked: ... }
//   LiveBarButton { label: "1280x720"; hasArrow: true; highlighted: menuOpen; onClicked: ... }
Rectangle {
    id: btn

    property string label: ""
    property bool hasArrow: false        // 右侧是否带 ▼（下拉用）
    property bool highlighted: false     // 常亮态（如下拉已展开、功能已启用）
    property bool hovered: btnArea.containsMouse
    property int  minWidth: 50

    signal clicked()
    signal wheeled(int delta)            // delta: +1 上滚 / -1 下滚

    // 用 implicit* 而不是 width/height：这个控件要放进 RowLayout，
    // 布局是按 implicit 尺寸排的，直接写 width 会被布局覆盖掉
    implicitWidth: Math.max(minWidth, contentRow.implicitWidth + 16)
    implicitHeight: 32
    // ⭐ 2026-08-16 对齐老 java gstream GpuView 深色按钮：#292929 底/#FAFAFA 字/圆角 8，悬停 #3A3A3A
    radius: 8
    color: (hovered || highlighted) ? "#3A3A3A" : "#292929"

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: 3

        Text {
            id: labelText
            text: btn.label
            font.pixelSize: 12
            font.family: "PingFang HK"
            font.bold: true
            color: "#FAFAFA"
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            visible: btn.hasArrow
            text: "▼"
            font.pixelSize: 8
            color: labelText.color
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: btnArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
        onWheel: function(wheel) { btn.wheeled(wheel.angleDelta.y > 0 ? 1 : -1) }
    }
}
