import QtQuick

// ⭐ 第五十章：实时流底部按钮栏的**公用下拉菜单**（弹在按钮正上方）。
//
// 与 LiveBarButton 配套：底部原来的档位/镜像两个下拉是各抄一份的，这里抽成一个。
// options 元素形如 { label: "1280x720@30", value: {...} }，选中即发 picked(value)。
Rectangle {
    id: menu

    property var options: []
    property var currentValue: undefined
    // 判等函数：默认按值比；对象型 value（如分辨率）由调用方传入自定义比较
    property var isCurrent: function(v) { return v === menu.currentValue }
    property int itemWidth: 96

    signal picked(var value)

    visible: false
    width: itemWidth
    height: col.height + 8
    z: 200          // 弹在按钮上方，别被同排后面的按钮盖住
    // ⭐ 2026-08-16 对齐老 java gstream 深色下拉：#292929 底/#3A3A3A 边框
    color: "#292929"
    radius: 8
    border.color: "#3A3A3A"
    border.width: 1

    function toggle() { visible = !visible }

    Column {
        id: col
        anchors.centerIn: parent
        spacing: 2

        Repeater {
            model: menu.options

            Rectangle {
                property bool active: menu.isCurrent(modelData.value)
                width: menu.width - 8
                height: 28
                radius: 3
                color: itemArea.containsMouse ? "#3A3A3A" : (active ? "#4A4A4A" : "transparent")

                Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    font.pixelSize: 12
                    font.family: "PingFang HK"
                    font.bold: parent.active
                    color: "#FAFAFA"
                }

                MouseArea {
                    id: itemArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        menu.picked(modelData.value)
                        menu.visible = false
                    }
                }
            }
        }
    }
}
