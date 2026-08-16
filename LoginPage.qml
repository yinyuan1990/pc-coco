// 登录/注册页（此行为 UTF-8 编码锚点，勿删）
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Aifs.Components 1.0

// 登录/注册卡片
// ⭐ 2026-08-13 重构：
//   1. 两步登录——第一步只带账号密码（不带 iOS 设备）走 /api/auth/login/pc，
//      有绑定设备时先显示「选择设备」列表，选中后带设备再登录一次才进主页；
//      没有绑定设备则直接进主页。注册流程不变。
//   2. 移除「切换账号」体系（历史账号下拉/账号管理弹窗/监控账号下拉）。
//   3. 单版本：去掉 豪华版/AI全能版 双登录按钮，只留一个「登录」。
Rectangle {
    id: loginPage
    color: "#1F1F1F"
    radius: 16    // ⭐ 窗口四角圆弧（窗体透明+无边框，靠这里出圆角）
    border.color: "#3c3c3c"
    border.width: 1
    clip: true

    signal loginSuccess(string server)

    // ⭐ 播放内核：选择入口已从登录页隐藏，固定用 GStreamer（Component.onCompleted 强制回写，
    //   清掉历史上可能存过的 webengine 选择）。MainPage 仍读取此值。
    Settings {
        id: kernelSettings
        property string playbackKernel: "webengine"  // "gstreamer" | "webengine"（2026-08-16 默认改网页内核）
    }

    // 当前视图：login / selectDevice / register
    property string currentView: "login"
    property bool isLoggingIn: false
    property string loginError: ""
    property string pendingLoginUsername: ""   // 注册成功后待填充的用户名
    property bool toastSwitchToLogin: false    // Toast 消失后是否切换到登录页
    property bool rememberPassword: true       // 记住密码（2026-08-15 恢复勾选框，默认勾选；取消则不保存密码）

    // ⭐ §53.19：isLoggingIn 卡死兜底。回调丢失时 12s 后强制复位按钮。
    onIsLoggingInChanged: {
        if (isLoggingIn) loggingInWatchdog.restart()
        else loggingInWatchdog.stop()
    }
    Timer {
        id: loggingInWatchdog
        interval: 12000
        repeat: false
        onTriggered: {
            if (loginPage.isLoggingIn) {
                console.log("[登录兜底] isLoggingIn 卡住 12s 无回调，强制复位")
                loginPage.isLoggingIn = false
                loginPage.loginError = "连接超时，请重试"
            }
        }
    }

    // 生成6位数字昵称（不显示，只用于注册）
    function generateNickname() {
        var nanoTime = Date.now() * 1000 + Math.floor(Math.random() * 1000)
        var nanoStr = nanoTime.toString()
        if (nanoStr.length >= 6) {
            return nanoStr.slice(-6)
        } else {
            return nanoStr.padStart(6, '0')
        }
    }

    // 监听 HttpClient 登录结果
    Connections {
        target: HttpClient

        function onLoginSuccess(token, deviceId, deviceUsername, bindingList, pcActivationLevel, pcLevelName, pcExpireAt, deviceLevel, levelFps, levelExposureFps, iceServersFromLogin) {
            console.log("登录成功! DeviceId:", deviceId, "DeviceUsername:", deviceUsername,
                        "绑定设备数:", bindingList ? bindingList.length : 0)
            isLoggingIn = false
            loginError = ""

            // ⭐ 两步登录：第一步不带设备账号。服务器本次未绑定设备（deviceUsername 空）
            //   且账号有绑定 iOS 设备时，先显示绑定列表让用户选，不进主页；
            //   用户点选后带 deviceUsername 再登录一次（本回调再次进入，走下面进主页分支）。
            //   没有绑定设备则直接进主页。
            if ((!deviceUsername || deviceUsername.length === 0) && bindingList && bindingList.length > 0) {
                deviceSelectForm.populate(bindingList)
                currentView = "selectDevice"
                return
            }

            // §44.4 账号归一化：一律存服务器返回的【真实账号】，而不是输入框里的短账号
            var canonicalUsername = HttpClient.loggedInUsername()
            if (!canonicalUsername || canonicalUsername.length === 0) {
                canonicalUsername = loginUsername.text.trim()
            }
            var typedUsername = loginUsername.text.trim()

            // 一律保存【服务器本次实际绑定的设备】（= currentDeviceUsername）
            var actualDeviceUser = deviceUsername || ""
            var actualDeviceDisplay = actualDeviceUser
            if (bindingList && bindingList.length > 0 && actualDeviceUser.length > 0) {
                for (var bi = 0; bi < bindingList.length; bi++) {
                    if ((bindingList[bi].deviceUsername || "") === actualDeviceUser) {
                        actualDeviceDisplay = bindingList[bi].deviceNickname || bindingList[bi].remark || actualDeviceUser
                        break
                    }
                }
            }
            // 保存账号和设备信息；密码默认一律保存（记住密码开关已移除）
            HttpClient.saveAccount(
                canonicalUsername,
                loginPage.rememberPassword ? loginPassword.text.trim() : "",
                actualDeviceUser,
                actualDeviceDisplay
            )
            // 无绑定设备时显式清掉本地设备记忆，避免旧设备残留
            if (actualDeviceUser.length === 0) {
                HttpClient.clearAccountDevice(canonicalUsername)
            }
            // 清掉历史上可能存过的「短账号」本地条目
            if (typedUsername.length > 0 && typedUsername !== canonicalUsername) {
                HttpClient.removeAccount(typedUsername)
            }

            // 触发登录成功信号（跳转主页）
            loginPage.loginSuccess(HttpClient.baseUrl())
        }

        function onLoginFailed(code, message) {
            console.log("登录失败:", code, message)
            isLoggingIn = false
            // §57.1：code=1005 文案固定用本地的（后端 message 是内部命名，不透出）
            if (code === 1005) {
                loginError = "AI全能版已到期或未开通，请联系管理员"
            } else {
                loginError = message
            }
        }

        // §44.2 强制版本号拦截：弹框提示更新 + 点击用浏览器下载新版 exe
        function onLoginNeedUpdate(message, downloadUrl) {
            console.log("需要更新版本:", message, "下载地址:", downloadUrl)
            isLoggingIn = false
            loginError = ""
            updateDialog.message = message || "您的版本过低，请更新到最新版本后再登录"
            updateDialog.downloadUrl = downloadUrl || ""
            updateDialog.visible = true
        }

        function onRegisterSuccess(username, message) {
            console.log("注册成功:", username, message)
            isLoggingIn = false
            loginError = ""
            pendingLoginUsername = username
            showToast("注册成功！", true)
        }

        function onRegisterFailed(code, message) {
            console.log("注册失败:", code, message)
            isLoggingIn = false
            showToast(message || "注册失败", false)
        }
    }
    // 支持拖动窗口（排除右上角关闭按钮区域）
    MouseArea {
        id: dragArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40
        z: 100

        property point clickPos: "0,0"

        function isInCloseButton(mouseX, mouseY) {
            var closeRight = dragArea.width - 12
            var closeLeft = closeRight - 28
            return mouseX >= closeLeft && mouseX <= closeRight && mouseY >= 12 && mouseY <= 40
        }

        onPressed: function(mouse) {
            if (isInCloseButton(mouse.x, mouse.y)) {
                mouse.accepted = false
                return
            }
            clickPos = Qt.point(mouse.x, mouse.y)
        }

        onPositionChanged: function(mouse) {
            var delta = Qt.point(mouse.x - clickPos.x, mouse.y - clickPos.y)
            mainWindow.x = mainWindow.x + delta.x
            mainWindow.y = mainWindow.y + delta.y
        }
    }

    // 顶部固定区域（⭐ 2026-08-15：Logo+标题整体水平居中，关闭按钮仍固定右上角）
    Item {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 12
        anchors.rightMargin: 12
        height: 40
        z: 1000

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Image {
                anchors.verticalCenter: parent.verticalCenter
                source: "images/icon.png"
                sourceSize.width: 36
                sourceSize.height: 36
                fillMode: Image.PreserveAspectFit
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "AI 幻镜"
                font.family: "PingFang HK"
                font.pixelSize: 28
                font.weight: Font.Bold
                color: "#E0E0E0"
            }
        }

        Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            id: closeButtonRect
            width: 28
            height: 28
            color: closeButtonArea.containsMouse ? "#e0e0e0" : "transparent"
            radius: 4
            z: 2000

            Text {
                anchors.centerIn: parent
                text: "\u2715"
                font.pixelSize: 14
                color: closeButtonArea.containsMouse ? "#000000" : "#9E9E9E"
            }

            MouseArea {
                id: closeButtonArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                propagateComposedEvents: false
                onPressed: function(mouse) { mouse.accepted = true }
                onClicked: function(mouse) {
                    console.log("关闭按钮点击，退出程序")
                    mouse.accepted = true
                    Qt.callLater(Qt.quit)
                }
            }
        }
    }
    // ============ 登录表单 ============
    Rectangle {
        id: loginForm
        anchors.fill: parent
        color: "transparent"
        visible: currentView === "login"

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 40
            anchors.rightMargin: 40
            anchors.topMargin: 44
            anchors.bottomMargin: 32
            spacing: 0

            Item { Layout.preferredHeight: 40 }

            // 顶部页签：登录（当前） / 注册（右侧）。无「切换账号」。
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 34

                Column {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    spacing: 7

                    Text {
                        id: tabLoginText
                        text: "登录"
                        font.family: "PingFang HK"
                        font.pixelSize: 17
                        font.weight: Font.Bold
                        color: "#FFFFFF"
                    }

                    Rectangle {
                        width: tabLoginText.width
                        height: 3
                        radius: 1.5
                        color: "#607AFB"
                    }
                }

                Text {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    text: "注册"
                    font.family: "PingFang HK"
                    font.pixelSize: 17
                    color: tabRegisterArea.containsMouse ? "#FFFFFF" : "#9E9E9E"

                    MouseArea {
                        id: tabRegisterArea
                        anchors.fill: parent
                        anchors.margins: -8
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: showRegister()
                    }
                }
            }

            Item { Layout.preferredHeight: 24 }

            // 账号
            Column {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "账号"
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#B0B0B0"
                }

                Item {
                    width: parent.width
                    height: 52

                    Rectangle {
                        anchors.fill: parent
                        radius: 26
                        color: "#292929"
                        border.color: loginUsername.activeFocus ? "#607AFB" : "#3a3a3a"
                        border.width: 1
                    }

                    TextField {
                        id: loginUsername
                        anchors.left: parent.left
                        anchors.right: loginUsernameClearBtn.left
                        height: parent.height
                        placeholderText: "请输入用户名"
                        font.family: "PingFang HK"
                        font.pixelSize: 18
                        color: "#E0E0E0"
                        placeholderTextColor: "#808080"
                        background: null
                        leftPadding: 20
                        rightPadding: 0
                        verticalAlignment: TextInput.AlignVCenter

                        cursorDelegate: Rectangle {
                            width: 2; height: 20; color: "#607AFB"
                            visible: loginUsername.activeFocus
                            SequentialAnimation on opacity {
                                loops: Animation.Infinite
                                running: loginUsername.activeFocus
                                NumberAnimation { to: 0; duration: 500 }
                                NumberAnimation { to: 1; duration: 500 }
                            }
                        }
                    }

                    // 清除按钮
                    Item {
                        id: loginUsernameClearBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: loginUsername.text.length > 0 ? 24 : 0
                        height: parent.height
                        visible: loginUsername.text.length > 0

                        Text {
                            anchors.centerIn: parent
                            text: "\u2715"
                            font.pixelSize: 10
                            color: loginUsernameClearArea.containsMouse ? "#ff4444" : "#808080"
                        }

                        MouseArea {
                            id: loginUsernameClearArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                loginUsername.text = ""
                                loginPassword.text = ""
                                loginUsername.forceActiveFocus()
                            }
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 18 }

            // 密码
            Column {
                id: passwordColumn
                Layout.fillWidth: true
                spacing: 8

                property bool passwordVisible: false

                Text {
                    text: "密码"
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#B0B0B0"
                }

                Item {
                    width: parent.width
                    height: 52

                    Rectangle {
                        anchors.fill: parent
                        radius: 26
                        color: "#292929"
                        border.color: loginPassword.activeFocus ? "#607AFB" : "#3a3a3a"
                        border.width: 1
                    }

                    TextField {
                        id: loginPassword
                        anchors.left: parent.left
                        anchors.right: passwordEyeBtn.left
                        anchors.rightMargin: 8
                        height: parent.height
                        placeholderText: "请输入您的密码"
                        font.family: "PingFang HK"
                        font.pixelSize: 18
                        color: "#E0E0E0"
                        placeholderTextColor: "#808080"
                        echoMode: passwordColumn.passwordVisible ? TextInput.Normal : TextInput.Password
                        background: null
                        leftPadding: 20
                        rightPadding: 0
                        verticalAlignment: TextInput.AlignVCenter

                        cursorDelegate: Rectangle {
                            width: 2; height: 20; color: "#607AFB"
                            visible: loginPassword.activeFocus
                            SequentialAnimation on opacity {
                                loops: Animation.Infinite
                                running: loginPassword.activeFocus
                                NumberAnimation { to: 0; duration: 500 }
                                NumberAnimation { to: 1; duration: 500 }
                            }
                        }
                    }

                    // 显示/隐藏密码（文字按钮）
                    Text {
                        id: passwordEyeBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: passwordColumn.passwordVisible ? "隐藏" : "显示"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: passwordEyeArea.containsMouse ? "#607AFB" : "#808080"

                        MouseArea {
                            id: passwordEyeArea
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: passwordColumn.passwordVisible = !passwordColumn.passwordVisible
                        }
                    }
                }
            }
            // ⭐ 2026-08-15 按需求恢复「记住密码」勾选：默认勾选；取消勾选则登录成功后不保存密码
            // ⭐ 播放内核选择入口已隐藏：固定 GStreamer（见 Component.onCompleted）
            Item { Layout.preferredHeight: 14 }

            // ⭐ 2026-08-15 需求：勾选按钮放到右边（整行右对齐），颜色改绿色系、文字提亮
            Row {
                spacing: 8
                Layout.alignment: Qt.AlignRight

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "记住密码"
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#E0E0E0"

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: loginPage.rememberPassword = !loginPage.rememberPassword
                    }
                }

                Rectangle {
                    width: 18
                    height: 18
                    radius: 4
                    anchors.verticalCenter: parent.verticalCenter
                    color: loginPage.rememberPassword ? "#22C55E" : "transparent"
                    border.color: loginPage.rememberPassword ? "#22C55E" : "#808080"
                    border.width: 1

                    Text {
                        anchors.centerIn: parent
                        text: "\u2713"
                        font.pixelSize: 12
                        font.bold: true
                        color: "#FFFFFF"
                        visible: loginPage.rememberPassword
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: loginPage.rememberPassword = !loginPage.rememberPassword
                    }
                }
            }

            Item { Layout.preferredHeight: 10 }

            // 错误提示
            Text {
                Layout.fillWidth: true
                Layout.preferredHeight: 16
                text: loginError
                font.family: "PingFang HK"
                font.pixelSize: 14
                color: "#ff4444"
                visible: loginError !== ""
                horizontalAlignment: Text.AlignHCenter
            }

            // ⭐ 2026-08-15：登录按钮不再压底，紧跟在输入区下方，与账号/密码同宽居中，整体更协调
            Item { Layout.preferredHeight: 26 }

            // ⭐ 登录按钮（单版本，唯一入口；第一步一律不带 iOS 设备）
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 52

                Rectangle {
                    anchors.fill: loginBtn
                    anchors.topMargin: 2
                    radius: 24
                    color: "#30000000"
                }

                Rectangle {
                    id: loginBtn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 48
                    radius: 24
                    color: loginPage.isLoggingIn ? "#3a4470"
                         : (loginBtnMouse.containsMouse ? "#4D63D1" : "#607AFB")

                    Text {
                        anchors.centerIn: parent
                        text: loginPage.isLoggingIn ? "登录中..." : "登 录"
                        font.family: "PingFang HK"
                        font.pixelSize: 20
                        font.weight: Font.Medium
                        color: "#FFFFFF"
                    }

                    MouseArea {
                        id: loginBtnMouse
                        enabled: !loginPage.isLoggingIn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (loginPage.isLoggingIn) return
                            if (loginUsername.text.trim() === "" || loginPassword.text.trim() === "") {
                                // §53.19：没记住密码时把焦点放进空的那个框，提示说清楚
                                loginError = loginPassword.text.trim() === ""
                                        ? "未记住密码，请输入密码后登录" : "请输入用户名和密码"
                                if (loginPassword.text.trim() === "") loginPassword.forceActiveFocus()
                                else loginUsername.forceActiveFocus()
                                return
                            }
                            isLoggingIn = true
                            loginError = ""
                            // ⭐ 两步登录第一步：一律不带 iOS 设备账号，
                            //   服务器只校验账号密码并返回 bindingList（见 onLoginSuccess）。
                            HttpClient.login(loginUsername.text.trim(), loginPassword.text.trim(), 1, "", false)
                        }
                    }
                }
            }

            // 底部弹性占位（按钮上移后剩余空间全部留在下方）
            Item { Layout.fillHeight: true }

        }
    }
    // ============ 选择绑定 iOS 设备（两步登录·第二步）============
    Rectangle {
        id: deviceSelectForm
        anchors.fill: parent
        color: "#1F1F1F"
        radius: loginPage.radius
        visible: currentView === "selectDevice"
        z: 50

        // 由 onLoginSuccess 用登录响应的 bindingList 填充
        property var deviceList: []

        // ⭐ 2026-08-16 对齐切换账号弹框：item 支持 备注/解绑，需带上 bindingId 和原始字段
        function populate(bindingList) {
            var arr = []
            for (var i = 0; i < bindingList.length; i++) {
                var b = bindingList[i]
                arr.push({
                    devUser: b.deviceUsername || "",
                    name: b.deviceNickname || b.deviceUsername || "",
                    remark: b.remark || "",
                    bindingId: (b.bindingId !== undefined && b.bindingId !== null) ? b.bindingId : null,
                    online: b.online === true
                })
            }
            deviceList = arr
        }

        // 备注修改后就地更新列表项
        function updateRemark(devUser, remark) {
            var arr = deviceList.slice()
            for (var i = 0; i < arr.length; i++) {
                if (arr[i].devUser === devUser) {
                    arr[i].remark = remark || ""
                    break
                }
            }
            deviceList = arr
        }

        // 解绑成功后移除列表项；列表空了则不带设备再登录一次直接进主页
        function removeByBindingId(bindingId) {
            var arr = deviceList.filter(function(d) { return d.bindingId !== bindingId })
            deviceList = arr
            if (arr.length === 0 && !loginPage.isLoggingIn) {
                loginPage.isLoggingIn = true
                loginError = ""
                HttpClient.login(loginUsername.text.trim(), loginPassword.text.trim(), 1, "", false)
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 40
            anchors.rightMargin: 40
            anchors.topMargin: 44
            anchors.bottomMargin: 32
            spacing: 0

            Item { Layout.preferredHeight: 40 }

            Text {
                text: "选择设备"
                font.family: "PingFang HK"
                font.pixelSize: 24
                font.weight: Font.Medium
                color: "#FFFFFF"
            }

            Item { Layout.preferredHeight: 8 }

            Text {
                Layout.fillWidth: true
                text: "该账号绑定了以下 iOS 设备，点击选择要控制的设备"
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#9E9E9E"
                wrapMode: Text.WordWrap
            }

            Item { Layout.preferredHeight: 18 }

            // 设备列表
            ListView {
                id: deviceSelectList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 10
                model: deviceSelectForm.deviceList
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    width: deviceSelectList.width
                    height: 52
                    radius: 12
                    color: deviceItemArea.containsMouse ? "#31344a" : "#292929"
                    border.color: deviceItemArea.containsMouse ? "#607AFB" : "#3a3a3a"
                    border.width: 1

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        // 在线状态点
                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: modelData.online ? "#4CD964" : "#666666"
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.remark && modelData.remark.length > 0
                                  ? modelData.name + " (" + modelData.remark + ")"
                                  : modelData.name
                            font.family: "PingFang HK"
                            font.pixelSize: 15
                            color: "#E0E0E0"
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.online ? "在线" : "离线"
                            font.family: "PingFang HK"
                            font.pixelSize: 12
                            color: modelData.online ? "#4CD964" : "#808080"
                        }
                    }

                    MouseArea {
                        id: deviceItemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !loginPage.isLoggingIn
                        onClicked: loginWithDevice(modelData.devUser)
                    }

                    // ⭐ 2026-08-16 对齐切换账号弹框的三个操作：整行点击=选中登录，
                    //   右侧加 备注 / 解绑（声明在整行 MouseArea 之后，保证点得到）
                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Rectangle {
                            width: 40
                            height: 24
                            radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: selRemarkArea.containsMouse ? "#4a4a4a" : "#3a3a3a"

                            Text {
                                anchors.centerIn: parent
                                text: "备注"
                                font.pixelSize: 11
                                color: selRemarkArea.containsMouse ? "#FFFFFF" : "#94a3b8"
                            }

                            MouseArea {
                                id: selRemarkArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    selectRemarkDialog.devUser = modelData.devUser
                                    selectRemarkDialog.deviceName = modelData.name
                                    selectRemarkInput.text = modelData.remark || ""
                                    selectRemarkDialog.open()
                                }
                            }
                        }

                        Rectangle {
                            width: 40
                            height: 24
                            radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: selUnbindArea.containsMouse ? "#4a4a4a" : "#3a3a3a"

                            Text {
                                anchors.centerIn: parent
                                text: "解绑"
                                font.pixelSize: 11
                                color: selUnbindArea.containsMouse ? "#FFFFFF" : "#94a3b8"
                            }

                            MouseArea {
                                id: selUnbindArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.bindingId === null || modelData.bindingId === undefined) {
                                        showToast("无法获取绑定信息，请返回重新登录", false)
                                        return
                                    }
                                    selectUnbindDialog.bindingId = modelData.bindingId
                                    selectUnbindDialog.deviceName = modelData.name
                                    selectUnbindDialog.open()
                                }
                            }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u203A"
                            font.pixelSize: 20
                            color: deviceItemArea.containsMouse ? "#607AFB" : "#808080"
                        }
                    }
                }

                ScrollBar.vertical: ScrollBar {
                    policy: deviceSelectList.contentHeight > deviceSelectList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                }
            }

            Item { Layout.preferredHeight: 10 }

            // 错误提示（第二次登录失败时显示在此视图）
            Text {
                Layout.fillWidth: true
                Layout.preferredHeight: loginError !== "" ? 16 : 0
                text: loginError
                font.family: "PingFang HK"
                font.pixelSize: 14
                color: "#ff4444"
                visible: loginError !== ""
                horizontalAlignment: Text.AlignHCenter
            }

            Item { Layout.preferredHeight: 8 }

            // 返回登录
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                radius: 22
                color: backFromSelectMouse.containsMouse ? "#4a4a4a" : "#3c3c3c"

                Text {
                    anchors.centerIn: parent
                    text: loginPage.isLoggingIn ? "登录中..." : "返回登录"
                    font.family: "PingFang HK"
                    font.pixelSize: 16
                    color: "#CCCCCC"
                }

                MouseArea {
                    id: backFromSelectMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !loginPage.isLoggingIn
                    onClicked: {
                        loginError = ""
                        currentView = "login"
                    }
                }
            }
        }
    }
    // ============ 选择设备页：备注弹框（对齐切换账号弹框功能）============
    Dialog {
        id: selectRemarkDialog
        anchors.centerIn: parent
        width: 320
        height: 210
        modal: true

        property string devUser: ""
        property string deviceName: ""

        background: Rectangle {
            color: "#1F1F1F"
            radius: 12
            border.color: "#3A3A3A"
            border.width: 1
        }

        contentItem: Column {
            spacing: 14
            padding: 20

            Text {
                text: "设备备注 · " + selectRemarkDialog.deviceName
                font.family: "PingFang HK"
                font.pixelSize: 15
                font.bold: true
                color: "#FAFAFA"
            }

            Rectangle {
                width: parent.width - 40
                height: 40
                radius: 8
                color: "#292929"
                border.color: selectRemarkInput.activeFocus ? "#607AFB" : "#3a3a3a"
                border.width: 1

                TextField {
                    id: selectRemarkInput
                    anchors.fill: parent
                    placeholderText: "请输入备注（留空则清除）"
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#E0E0E0"
                    placeholderTextColor: "#808080"
                    background: null
                    leftPadding: 12
                }
            }

            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    width: 100
                    height: 36
                    radius: 4
                    color: selRemarkCancelArea.containsMouse ? "#3A3A3A" : "#2A2A2A"

                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.pixelSize: 14
                        color: "#CCCCCC"
                    }

                    MouseArea {
                        id: selRemarkCancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: selectRemarkDialog.close()
                    }
                }

                Rectangle {
                    width: 100
                    height: 36
                    radius: 4
                    color: selRemarkSaveArea.containsMouse ? "#4f6af0" : "#607AFB"

                    Text {
                        anchors.centerIn: parent
                        text: "保存"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }

                    MouseArea {
                        id: selRemarkSaveArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var ctrl = HttpClient.loggedInUsername()
                            if (!ctrl || ctrl.length === 0) ctrl = loginUsername.text.trim()
                            HttpClient.setRemark(ctrl, selectRemarkDialog.devUser, selectRemarkInput.text.trim())
                            selectRemarkDialog.close()
                        }
                    }
                }
            }
        }
    }

    // ============ 选择设备页：解绑确认弹框（对齐切换账号弹框功能）============
    Dialog {
        id: selectUnbindDialog
        anchors.centerIn: parent
        width: 340
        height: 190
        modal: true

        property var bindingId: null
        property string deviceName: ""

        background: Rectangle {
            color: "#1F1F1F"
            radius: 12
            border.color: "#3A3A3A"
            border.width: 1
        }

        contentItem: Column {
            spacing: 16
            padding: 20

            Text {
                width: parent.width - 40
                text: "确定要解绑设备「" + selectUnbindDialog.deviceName + "」吗？\n解绑后需要重新在iOS端扫码绑定。"
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
                    color: selUnbindCancelArea.containsMouse ? "#3A3A3A" : "#2A2A2A"

                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.pixelSize: 14
                        color: "#CCCCCC"
                    }

                    MouseArea {
                        id: selUnbindCancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: selectUnbindDialog.close()
                    }
                }

                Rectangle {
                    width: 100
                    height: 36
                    radius: 4
                    color: selUnbindConfirmArea.containsMouse ? "#CC0000" : "#E53935"

                    Text {
                        anchors.centerIn: parent
                        text: "确认解绑"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }

                    MouseArea {
                        id: selUnbindConfirmArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var pwd = loginPassword.text.trim()
                            if (!pwd) {
                                showToast("无法获取账号密码，请返回重新登录", false)
                                selectUnbindDialog.close()
                                return
                            }
                            HttpClient.windowsUnbind(selectUnbindDialog.bindingId, pwd)
                            selectUnbindDialog.close()
                            showToast("正在解绑...")
                        }
                    }
                }
            }
        }
    }

    // 选择设备页的备注/解绑结果处理（仅本页可见时响应，避免与主页面重复处理）
    Connections {
        target: HttpClient
        enabled: currentView === "selectDevice"

        function onSetRemarkSuccess(controlUsername, deviceUsername, remark) {
            deviceSelectForm.updateRemark(deviceUsername, remark)
            showToast("备注已保存")
        }

        function onSetRemarkFailed(code, message) {
            showToast("备注保存失败: " + message)
        }

        function onUnbindSuccess(bindingId, message) {
            showToast("解绑成功")
            deviceSelectForm.removeByBindingId(bindingId)
        }

        function onUnbindFailed(code, message) {
            showToast("解绑失败: " + message)
        }
    }

    // ============ 注册表单（流程不变，仅换肤）============
    Rectangle {
        id: registerForm
        anchors.fill: parent
        color: "#1F1F1F"
        radius: loginPage.radius
        y: parent.height  // 初始在下方隐藏
        visible: currentView === "register"

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 40
            anchors.rightMargin: 40
            anchors.topMargin: 44
            anchors.bottomMargin: 32
            spacing: 0

            Item { Layout.preferredHeight: 32 }

            Text {
                text: "注册账号"
                font.family: "PingFang HK"
                font.pixelSize: 32
                font.weight: Font.Medium
                color: "#E0E0E0"
                Layout.fillWidth: true
            }

            Item { Layout.preferredHeight: 40 }

            // 输入框
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 32

                // 用户名
                Column {
                    Layout.fillWidth: true
                    spacing: 0

                    Item {
                        width: parent.width
                        height: 44

                        Rectangle {
                            anchors.fill: parent
                            radius: 22
                            color: "#292929"
                            border.color: regUsername.activeFocus ? "#607AFB" : "#3a3a3a"
                            border.width: 1
                        }

                        TextField {
                            id: regUsername
                            anchors.left: parent.left
                            anchors.right: regUsernameClearBtn.left
                            height: 44
                            placeholderText: "请输入账号 (8-15位字母数字)"
                            font.family: "PingFang HK"
                            font.pixelSize: 16
                            color: "#E0E0E0"
                            placeholderTextColor: "#808080"
                            background: null
                            leftPadding: 16
                            rightPadding: 0
                            verticalAlignment: TextInput.AlignVCenter
                            maximumLength: 15

                            cursorDelegate: Rectangle {
                                width: 2; height: 18; color: "#607AFB"
                                visible: regUsername.activeFocus
                                SequentialAnimation on opacity {
                                    loops: Animation.Infinite
                                    running: regUsername.activeFocus
                                    NumberAnimation { to: 0; duration: 500 }
                                    NumberAnimation { to: 1; duration: 500 }
                                }
                            }
                        }

                        // 清除按钮
                        Item {
                            id: regUsernameClearBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: regUsername.text.length > 0 ? 20 : 0
                            height: parent.height
                            visible: regUsername.text.length > 0

                            Text {
                                anchors.centerIn: parent
                                text: "\u2715"
                                font.pixelSize: 10
                                color: regUsernameClearArea.containsMouse ? "#ff4444" : "#808080"
                            }

                            MouseArea {
                                id: regUsernameClearArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    regUsername.text = ""
                                    regUsername.forceActiveFocus()
                                }
                            }
                        }
                    }
                }

                // 密码
                Column {
                    Layout.fillWidth: true
                    spacing: 0

                    TextField {
                        id: regPassword
                        width: parent.width
                        height: 44
                        placeholderText: "请输入密码 (6-20位)"
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        color: "#E0E0E0"
                        placeholderTextColor: "#808080"
                        echoMode: TextInput.Password
                        maximumLength: 20
                        background: Rectangle { radius: 22; color: "#292929"; border.color: parent.activeFocus ? "#607AFB" : "#3a3a3a"; border.width: 1 }
                        leftPadding: 16
                        rightPadding: 0
                        verticalAlignment: TextInput.AlignVCenter

                        cursorDelegate: Rectangle {
                            width: 2; height: 18; color: "#607AFB"
                            visible: regPassword.activeFocus
                            SequentialAnimation on opacity {
                                loops: Animation.Infinite
                                running: regPassword.activeFocus
                                NumberAnimation { to: 0; duration: 500 }
                                NumberAnimation { to: 1; duration: 500 }
                            }
                        }
                    }
                }

                // 确认密码
                Column {
                    Layout.fillWidth: true
                    spacing: 0

                    TextField {
                        id: regConfirmPwd
                        width: parent.width
                        height: 44
                        placeholderText: "请确认密码 (6-20位)"
                        font.family: "PingFang HK"
                        font.pixelSize: 16
                        color: "#E0E0E0"
                        placeholderTextColor: "#808080"
                        echoMode: TextInput.Password
                        background: Rectangle { radius: 22; color: "#292929"; border.color: parent.activeFocus ? "#607AFB" : "#3a3a3a"; border.width: 1 }
                        leftPadding: 16
                        rightPadding: 0
                        verticalAlignment: TextInput.AlignVCenter

                        cursorDelegate: Rectangle {
                            width: 2; height: 18; color: "#607AFB"
                            visible: regConfirmPwd.activeFocus
                            SequentialAnimation on opacity {
                                loops: Animation.Infinite
                                running: regConfirmPwd.activeFocus
                                NumberAnimation { to: 0; duration: 500 }
                                NumberAnimation { to: 1; duration: 500 }
                            }
                        }
                    }
                }

                // 昵称：随机生成 + 「换一个」（对齐老 Java 版注册页）
                Column {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        text: "昵称"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#B0B0B0"
                    }

                    Row {
                        width: parent.width
                        spacing: 10

                        TextField {
                            id: regNickname
                            width: parent.width - regNickBtn.width - 10
                            height: 44
                            font.family: "PingFang HK"
                            font.pixelSize: 16
                            color: "#607AFB"
                            maximumLength: 6   // 对齐老 Java 版：昵称固定 6 位数字
                            validator: RegularExpressionValidator { regularExpression: /^\d{0,6}$/ }
                            background: Rectangle { radius: 22; color: "#292929"; border.color: parent.activeFocus ? "#607AFB" : "#3a3a3a"; border.width: 1 }
                            leftPadding: 16
                            rightPadding: 0
                            verticalAlignment: TextInput.AlignVCenter

                            cursorDelegate: Rectangle {
                                width: 2; height: 18; color: "#607AFB"
                                visible: regNickname.activeFocus
                                SequentialAnimation on opacity {
                                    loops: Animation.Infinite
                                    running: regNickname.activeFocus
                                    NumberAnimation { to: 0; duration: 500 }
                                    NumberAnimation { to: 1; duration: 500 }
                                }
                            }
                        }

                        Rectangle {
                            id: regNickBtn
                            width: 76
                            height: 44
                            radius: 22
                            anchors.verticalCenter: regNickname.verticalCenter
                            color: regNickBtnArea.containsMouse ? "#4D63D1" : "#607AFB"

                            Text {
                                anchors.centerIn: parent
                                text: "换一个"
                                font.family: "PingFang HK"
                                font.pixelSize: 14
                                color: "#FFFFFF"
                            }

                            MouseArea {
                                id: regNickBtnArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: regNickname.text = generateNickname()
                            }
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 16 }

            // 注册按钮
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 58

                Rectangle {
                    anchors.fill: regSubmitBtn
                    anchors.topMargin: 2
                    radius: 27
                    color: "#30000000"
                }

                Rectangle {
                    id: regSubmitBtn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 54
                    radius: 27
                    color: regSubmitBtnMouse.containsMouse ? "#4a90d9" : "#607AFB"

                    Text {
                        anchors.centerIn: parent
                        text: "注 册"
                        font.family: "PingFang HK"
                        font.pixelSize: 24
                        font.weight: Font.Medium
                        color: "#FFFFFF"
                    }

                    MouseArea {
                        id: regSubmitBtnMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (isLoggingIn) return

                            var username = regUsername.text.trim()
                            var password = regPassword.text.trim()

                            // 校验账号
                            if (username === "") {
                                showToast("请输入账号", false)
                                return
                            }
                            if (!/^[a-zA-Z0-9]{8,15}$/.test(username)) {
                                showToast("账号必须是8-15位字母或数字", false)
                                return
                            }

                            // 校验密码
                            if (password === "") {
                                showToast("请输入密码", false)
                                return
                            }
                            if (password.length < 6 || password.length > 20) {
                                showToast("密码长度需在6到20位之间", false)
                                return
                            }
                            if (regPassword.text !== regConfirmPwd.text) {
                                showToast("两次输入的密码不一致", false)
                                return
                            }

                            // 昵称：默认随机生成，可「换一个」/手改；对齐老 Java 版校验——
                            //   必须是 6 位数字，格式不对（含手改成非法值）则自动重新生成并回填
                            var nickname = regNickname.text.trim()
                            if (!/^\d{6}$/.test(nickname)) {
                                nickname = generateNickname()
                                regNickname.text = nickname
                            }
                            console.log("注册账号:", username, "昵称:", nickname)

                            isLoggingIn = true
                            loginError = ""
                            HttpClient.registerUser(username, password, nickname)
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 16 }

            // 返回登录按钮
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 58

                Rectangle {
                    anchors.fill: backLoginBtn
                    anchors.topMargin: 2
                    radius: 27
                    color: "#30000000"
                }

                Rectangle {
                    id: backLoginBtn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 54
                    radius: 27
                    color: backLoginMouse.containsMouse ? "#4a4a4a" : "#3c3c3c"

                    Text {
                        anchors.centerIn: parent
                        text: "返回登录"
                        font.family: "PingFang HK"
                        font.pixelSize: 24
                        font.weight: Font.Medium
                        color: "#CCCCCC"
                    }

                    MouseArea {
                        id: backLoginMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: showLogin()
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }
    }
    // ============ 版本过低·需更新对话框遮罩 ============
    Rectangle {
        anchors.fill: parent
        color: "#40000000"
        radius: loginPage.radius
        visible: updateDialog.visible
        z: 320

        MouseArea {
            anchors.fill: parent
            onClicked: {}  // 遮罩不允许点击关闭，强制用户处理
        }
    }

    // ============ 版本过低·需更新对话框 ============
    Rectangle {
        id: updateDialog
        width: 420
        height: 220
        anchors.centerIn: parent
        color: "#2d2d2d"
        radius: 6
        visible: false
        z: 321

        property string message: ""
        property string downloadUrl: ""

        Column {
            anchors.fill: parent
            anchors.margins: 22
            spacing: 16

            Text {
                text: "需要更新版本"
                font.family: "PingFang HK"
                font.pixelSize: 18
                font.weight: Font.Medium
                color: "#E0E0E0"
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: updateDialog.message
                font.family: "PingFang HK"
                font.pixelSize: 13
                color: "#B0B0B0"
                lineHeight: 1.3
            }

            Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                text: "下载地址：" + updateDialog.downloadUrl
                font.family: "PingFang HK"
                font.pixelSize: 11
                color: "#808080"
                visible: updateDialog.downloadUrl.length > 0
            }

            Row {
                anchors.right: parent.right
                spacing: 10

                Rectangle {
                    width: 90
                    height: 36
                    radius: 4
                    color: cancelUpdArea.containsMouse ? "#3c3c3c" : "#333333"
                    Text {
                        anchors.centerIn: parent
                        text: "取消"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#CCCCCC"
                    }
                    MouseArea {
                        id: cancelUpdArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: updateDialog.visible = false
                    }
                }

                Rectangle {
                    width: 130
                    height: 36
                    radius: 4
                    color: dlUpdArea.containsMouse ? "#4D63D1" : "#607AFB"
                    Text {
                        anchors.centerIn: parent
                        text: "立即下载"
                        font.family: "PingFang HK"
                        font.pixelSize: 14
                        color: "#FFFFFF"
                    }
                    MouseArea {
                        id: dlUpdArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (updateDialog.downloadUrl.length > 0) {
                                Qt.openUrlExternally(updateDialog.downloadUrl)
                            } else {
                                showToast("未获取到下载地址，请联系管理员", false)
                            }
                        }
                    }
                }
            }
        }
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
        z: 1000

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
            // 注册成功后切换到登录页面并填充新账号
            if (toastSwitchToLogin && pendingLoginUsername !== "") {
                showLogin()
                loginUsername.text = pendingLoginUsername
                loginPassword.text = ""
                pendingLoginUsername = ""
                toastSwitchToLogin = false
            }
        }
    }

    // ============ 函数 ============

    function showToast(message, switchToLogin) {
        toastText.text = message
        toastContainer.visible = true
        toastContainer.opacity = 1
        toastSwitchToLogin = switchToLogin || false
        toastTimer.restart()
    }

    function showRegister() {
        currentView = "register"
        registerForm.y = 0
        // 清空输入框，让用户手动输入；昵称默认随机生成一个
        regUsername.text = ""
        regPassword.text = ""
        regConfirmPwd.text = ""
        regNickname.text = generateNickname()
        loginError = ""
    }

    function showLogin() {
        currentView = "login"
        registerForm.y = loginPage.height
    }

    // ⭐ 两步登录第二步：带上用户点选的 iOS 设备账号再登录一次，成功即进主页
    function loginWithDevice(devUser) {
        if (isLoggingIn) return
        if (!devUser || devUser.length === 0) {
            showToast("设备信息异常，请返回重新登录", false)
            return
        }
        isLoggingIn = true
        loginError = ""
        console.log("[两步登录] 选中设备:", devUser, "带设备再次登录")
        HttpClient.login(loginUsername.text.trim(), loginPassword.text.trim(), 1, devUser, false)
    }

    // 加载保存的账号信息（仅上次账号 + 记住的密码；无历史账号下拉）
    function loadSavedAccount() {
        var savedUsername = HttpClient.getSavedUsername()
        var savedPassword = HttpClient.getSavedPassword()

        if (savedUsername) {
            loginUsername.text = savedUsername
        }
        if (savedPassword) {
            loginPassword.text = savedPassword
        }

        console.log("加载保存的账号:", savedUsername)
    }

    Component.onCompleted: {
        // ⭐ 2026-08-16 需求：播放模式改为网页内核（覆盖历史保存的 gstreamer 选择）
        kernelSettings.playbackKernel = "webengine"
        loadSavedAccount()
    }
}
