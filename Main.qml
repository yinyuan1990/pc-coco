import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Aifs.Components

// 应用入口：根据登录状态加载不同页面
ApplicationWindow {
    id: mainWindow
    visible: true
    title: "幻境"
    
    // 登录状态
    property bool isLoggedIn: false
    property string srsServer: "47.122.115.33"  // ⭐ aihj SRS 流媒体服务器
    property string currentStream: "VID_59C9232BFF5576718C575E19EDE7"
    
    // ⭐ 启动画面状态
    property bool showSplash: true
    
    // 窗口尺寸变化信号（供子组件使用）
    signal windowSizeChanged(int newWidth, int newHeight)
    
    // 初始尺寸（登录/注册卡片大小）
    //   ⭐ 2026-08-13：登录/注册窗口高度 650 → 700。
    width: 600
    height: 700
    // ⭐ 2026-08-15 修「登录后登录页先被撑大」：最小尺寸不能绑 isLoggedIn——
    //   登录成功瞬间 isLoggedIn=true，但 MainPage 是异步加载（§24），窗口切换推迟到
    //   mainPageLoader.onLoaded；绑定抢跑会让 600x700 的登录窗口立刻被最小尺寸
    //   1280x720 强制撑大，登录卡片跟着拉大。最小尺寸改为进主页时 switchTimer
    //   显式设 1280x720、退出登录时显式设回 600x700。
    minimumWidth: 600
    minimumHeight: 700
    flags: Qt.Window | Qt.FramelessWindowHint
    color: "transparent"
    
    // 居中显示
    Component.onCompleted: {
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
        console.log("Main.qml: 启动时窗口尺寸 width=" + width + " height=" + height)
        
        // ⭐ 启动画面计时器（2秒后隐藏）
        splashTimer.start()
        
        // 启动时检查更新（aihj 更新域名，DCDN 回源 nginx /updatesoft/ → /opt/yql/www/soft）
        // ⭐ 2026-08-14 改用 hjversion.json：老文件名 yqlversion.json 曾传过主线的 8.3.7，
        //   部分 CDN 节点缓存了旧内容且 CDN 忽略 ?v= 参数（实测 X-Cache HIT）穿不透，
        //   换全新文件名让所有节点强制回源。发版时记得同步更新服务器上的 hjversion.json！
        AutoUpdater.setUpdateUrl("https://update.cocoaihj.com/updatesoft/hjversion.json?v=" + Date.now())
        AutoUpdater.checkForUpdates()
    }
    
    // ⭐ 启动画面计时器
    Timer {
        id: splashTimer
        interval: 2000  // 2秒
        onTriggered: {
            console.log("Main.qml: 启动画面结束，进入登录页面")
            showSplash = false
        }
    }
    
    // 监听更新可用信号
    Connections {
        target: AutoUpdater
        function onUpdateAvailable(version, changelog) {
            console.log("发现新版本:", version)
            updateDialog.open()
        }
        function onUpdateError(error) {
            console.log("更新检查错误:", error)
        }
    }
    
    // 窗口尺寸变化回调
    onWidthChanged: {
        if (isLoggedIn) {
            windowSizeChanged(width, height)
        }
    }
    onHeightChanged: {
        if (isLoggedIn) {
            windowSizeChanged(width, height)
        }
    }
    
    // ⭐ 2026-07-03 登录卡顿优化（§24）：主页加载中标志。
    //   isLoggedIn=true 后 MainPage 改为异步加载，加载期间登录页保持可见并盖「正在进入主页…」遮罩，
    //   等 mainPageLoader.onLoaded 才做 隐藏→改窗口尺寸→显示 的切换，避免同步实例化冻死登录窗口。
    property bool mainLoading: isLoggedIn && mainPageLoader.status !== Loader.Ready

    onIsLoggedInChanged: {
        if (isLoggedIn) {
            // 什么都不做：窗口切换推迟到 mainPageLoader.onLoaded（见下）。
            // 登录页由 mainLoading 绑定保持加载，遮罩提示加载中。
        }
    }
    
    Timer {
        id: switchTimer
        interval: 10
        onTriggered: {
            // 计算新窗口位置和大小（根据屏幕尺寸自适应）
            var screenW = Screen.width
            var screenH = Screen.height
            
            // 目标尺寸：屏幕的 90%，但不超过 1920x1000
            var newWidth = Math.min(screenW * 0.9, 1920)
            var newHeight = Math.min(screenH * 0.9, 1000)
            
            // 确保不小于最小尺寸
            newWidth = Math.max(newWidth, 1280)
            newHeight = Math.max(newHeight, 720)
            
            var newX = (screenW - newWidth) / 2
            var newY = (screenH - newHeight) / 2 - 20
            
            // 确保窗口在屏幕内
            newY = Math.max(0, newY)
            
            console.log("Main.qml: 屏幕尺寸", screenW, "x", screenH, "-> 窗口尺寸", newWidth, "x", newHeight)
            
            // 设置位置和大小（窗口透明不可见时）
            mainWindow.x = newX
            mainWindow.y = newY
            mainWindow.width = newWidth
            mainWindow.height = newHeight
            mainWindow.minimumWidth = 1280
            mainWindow.minimumHeight = 720
            // 窗口背景色根据PC等级区分：等级2绿色，等级1蓝色
            var pcLevel = HttpClient.pcActivationLevel()
            mainWindow.color = (pcLevel >= 2) ? "#C8DFC0" : "#CAD9F2"
            
            // 再延迟一帧后恢复可见
            showTimer.start()
        }
    }
    
    Timer {
        id: showTimer
        interval: 50
        onTriggered: {
            mainWindow.opacity = 1
        }
    }
    
    // ============ 边缘拖动调整窗口大小（无边框窗口需要手动实现）============
    // 边缘拖动区域宽度
    property int resizeBorderWidth: 6
    
    // 左边缘
    MouseArea {
        id: leftResize
        width: resizeBorderWidth
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: resizeBorderWidth
        anchors.bottomMargin: resizeBorderWidth
        cursorShape: Qt.SizeHorCursor
        visible: isLoggedIn
        
        property real startX
        property real startWidth
        
        onPressed: (mouse) => {
            startX = mainWindow.x
            startWidth = mainWindow.width
        }
        onPositionChanged: (mouse) => {
            if (pressed) {
                var dx = mouse.x
                var newWidth = startWidth - dx
                if (newWidth >= mainWindow.minimumWidth) {
                    mainWindow.width = newWidth
                    mainWindow.x = startX + dx
                }
            }
        }
    }
    
    // 右边缘
    MouseArea {
        id: rightResize
        width: resizeBorderWidth
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: resizeBorderWidth
        anchors.bottomMargin: resizeBorderWidth
        cursorShape: Qt.SizeHorCursor
        visible: isLoggedIn
        
        onPositionChanged: (mouse) => {
            if (pressed) {
                var newWidth = mainWindow.width + mouse.x
                if (newWidth >= mainWindow.minimumWidth) {
                    mainWindow.width = newWidth
                }
            }
        }
    }
    
    // 上边缘
    MouseArea {
        id: topResize
        height: resizeBorderWidth
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: resizeBorderWidth
        anchors.rightMargin: resizeBorderWidth
        cursorShape: Qt.SizeVerCursor
        visible: isLoggedIn
        
        property real startY
        property real startHeight
        
        onPressed: (mouse) => {
            startY = mainWindow.y
            startHeight = mainWindow.height
        }
        onPositionChanged: (mouse) => {
            if (pressed) {
                var dy = mouse.y
                var newHeight = startHeight - dy
                if (newHeight >= mainWindow.minimumHeight) {
                    mainWindow.height = newHeight
                    mainWindow.y = startY + dy
                }
            }
        }
    }
    
    // 下边缘
    MouseArea {
        id: bottomResize
        height: resizeBorderWidth
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: resizeBorderWidth
        anchors.rightMargin: resizeBorderWidth
        cursorShape: Qt.SizeVerCursor
        visible: isLoggedIn
        
        onPositionChanged: (mouse) => {
            if (pressed) {
                var newHeight = mainWindow.height + mouse.y
                if (newHeight >= mainWindow.minimumHeight) {
                    mainWindow.height = newHeight
                }
            }
        }
    }
    
    // 左上角
    MouseArea {
        id: topLeftResize
        width: resizeBorderWidth
        height: resizeBorderWidth
        anchors.left: parent.left
        anchors.top: parent.top
        cursorShape: Qt.SizeFDiagCursor
        visible: isLoggedIn
        
        property real startX
        property real startY
        property real startWidth
        property real startHeight
        
        onPressed: (mouse) => {
            startX = mainWindow.x
            startY = mainWindow.y
            startWidth = mainWindow.width
            startHeight = mainWindow.height
        }
        onPositionChanged: (mouse) => {
            if (pressed) {
                var dx = mouse.x
                var dy = mouse.y
                var newWidth = startWidth - dx
                var newHeight = startHeight - dy
                if (newWidth >= mainWindow.minimumWidth) {
                    mainWindow.width = newWidth
                    mainWindow.x = startX + dx
                }
                if (newHeight >= mainWindow.minimumHeight) {
                    mainWindow.height = newHeight
                    mainWindow.y = startY + dy
                }
            }
        }
    }
    
    // 右上角
    MouseArea {
        id: topRightResize
        width: resizeBorderWidth
        height: resizeBorderWidth
        anchors.right: parent.right
        anchors.top: parent.top
        cursorShape: Qt.SizeBDiagCursor
        visible: isLoggedIn
        
        property real startY
        property real startHeight
        
        onPressed: (mouse) => {
            startY = mainWindow.y
            startHeight = mainWindow.height
        }
        onPositionChanged: (mouse) => {
            if (pressed) {
                var newWidth = mainWindow.width + mouse.x
                if (newWidth >= mainWindow.minimumWidth) {
                    mainWindow.width = newWidth
                }
                var dy = mouse.y
                var newHeight = startHeight - dy
                if (newHeight >= mainWindow.minimumHeight) {
                    mainWindow.height = newHeight
                    mainWindow.y = startY + dy
                }
            }
        }
    }
    
    // 左下角
    MouseArea {
        id: bottomLeftResize
        width: resizeBorderWidth
        height: resizeBorderWidth
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        cursorShape: Qt.SizeBDiagCursor
        visible: isLoggedIn
        
        property real startX
        property real startWidth
        
        onPressed: (mouse) => {
            startX = mainWindow.x
            startWidth = mainWindow.width
        }
        onPositionChanged: (mouse) => {
            if (pressed) {
                var dx = mouse.x
                var newWidth = startWidth - dx
                if (newWidth >= mainWindow.minimumWidth) {
                    mainWindow.width = newWidth
                    mainWindow.x = startX + dx
                }
                var newHeight = mainWindow.height + mouse.y
                if (newHeight >= mainWindow.minimumHeight) {
                    mainWindow.height = newHeight
                }
            }
        }
    }
    
    // 右下角
    MouseArea {
        id: bottomRightResize
        width: resizeBorderWidth
        height: resizeBorderWidth
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        cursorShape: Qt.SizeFDiagCursor
        visible: isLoggedIn
        
        onPositionChanged: (mouse) => {
            if (pressed) {
                var newWidth = mainWindow.width + mouse.x
                var newHeight = mainWindow.height + mouse.y
                if (newWidth >= mainWindow.minimumWidth) {
                    mainWindow.width = newWidth
                }
                if (newHeight >= mainWindow.minimumHeight) {
                    mainWindow.height = newHeight
                }
            }
        }
    }
    
    // 主页面（登录后才加载）
    Loader {
        id: mainPageLoader
        anchors.fill: parent
        active: isLoggedIn
        source: isLoggedIn ? "MainPage.qml" : ""
        // ⭐ 2026-07-03（§24）：改异步加载。MainPage.qml 有 744KB，同步实例化会把主线程
        //   冻住数百毫秒~数秒（低配机更久），登录窗口死冻就是「登录卡5秒」主因之一。
        //   异步模式下错误同样经 status===Loader.Error 上报，不影响下面的错误捕获。
        asynchronous: true

        // ⭐ 2026-08-15 需求：主界面四角 25px 圆弧。窗口本身无边框+透明底，
        //   顶栏/底栏是方角矩形会把角画满，单给 MainPage 根加 radius 不够，
        //   这里用 OpacityMask 对整个主页面内容裁圆角。最大化/全屏时贴屏显示，关掉圆角省一层离屏渲染。
        layer.enabled: isLoggedIn
                       && mainWindow.visibility !== Window.Maximized
                       && mainWindow.visibility !== Window.FullScreen
        layer.effect: OpacityMask {
            maskSource: Item {
                width: mainPageLoader.width
                height: mainPageLoader.height
                Rectangle { anchors.fill: parent; radius: 25 }
            }
        }
        
        onActiveChanged: {
            console.log("Main.qml: mainPageLoader.active 变化:", active)
        }
        
        onSourceChanged: {
            console.log("Main.qml: mainPageLoader.source 变化:", source)
        }
        
        onStatusChanged: {
            console.log("Main.qml: mainPageLoader 状态变化:", status, 
                        "(0=Null, 1=Ready, 2=Loading, 3=Error)")
            if (status === Loader.Error) {
                console.log("Main.qml: ❌ MainPage.qml 加载失败! sourceComponent:", sourceComponent)
            }
        }
        
        onLoaded: {
            console.log("Main.qml: ✅ MainPage.qml 加载成功")
            item.srsServer = srsServer
            item.currentStream = currentStream
            // 连接退出登录信号
            item.logoutRequested.connect(handleLogout)

            // ⭐ 2026-07-03（§24）：主页异步加载完成后才切换窗口（原来在 onIsLoggedInChanged）。
            //   先 opacity 隐藏 → switchTimer 改窗口尺寸/位置 → showTimer 恢复可见。
            mainWindow.opacity = 0
            switchTimer.start()
        }
    }
    
    // 处理退出登录
    function handleLogout() {
        console.log("Main.qml: 收到退出登录信号")
        // 先隐藏窗口
        mainWindow.visible = false
        logoutTimer.start()
    }
    
    Timer {
        id: logoutTimer
        interval: 50
        onTriggered: {
            // 先切换状态（最小尺寸已不再绑 isLoggedIn，下面显式恢复 600x700）
            isLoggedIn = false
            
            // ⭐ 恢复登录页窗口尺寸（必须与首次启动初始值完全一致：600 x 700）。
            mainWindow.minimumWidth = 600
            mainWindow.minimumHeight = 700
            mainWindow.maximumWidth = 600
            mainWindow.maximumHeight = 700
            mainWindow.width = 600
            mainWindow.height = 700
            mainWindow.x = (Screen.width - 600) / 2
            mainWindow.y = (Screen.height - 700) / 2
            mainWindow.color = "transparent"
            
            // 延迟一帧后解除最大尺寸限制
            Qt.callLater(function() {
                mainWindow.maximumWidth = 16777215
                mainWindow.maximumHeight = 16777215
            })
            
            mainWindow.visible = true
            console.log("Main.qml: 退出登录后窗口尺寸 width=" + mainWindow.width + " height=" + mainWindow.height)
        }
    }
    
    // ⭐ 启动画面：仿老 Java 版 SplashScreen（假进度，2 秒后由 splashTimer 关闭）
    Rectangle {
        id: splashScreen
        width: 400
        height: 280
        anchors.centerIn: parent
        visible: showSplash
        z: 100  // 确保在最上层
        radius: 20
        border.color: "#50505A"
        border.width: 1
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#1E1E23" }
            GradientStop { position: 1.0; color: "#2D2D37" }
        }

        // 假进度：0→100 匀速走完，配合阶段状态文案
        property real fakeProgress: 0
        property string statusText: "正在启动..."

        NumberAnimation on fakeProgress {
            from: 0; to: 100
            duration: 1900
            running: showSplash
        }
        onFakeProgressChanged: {
            if (fakeProgress < 30) statusText = "正在启动..."
            else if (fakeProgress < 65) statusText = "初始化 GStreamer..."
            else if (fakeProgress < 90) statusText = "加载组件..."
            else statusText = "启动完成"
        }

        Column {
            anchors.centerIn: parent
            spacing: 0

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "AI 幻镜"
                font.family: "Segoe UI"
                font.pixelSize: 42
                font.weight: Font.Bold
                color: "#42A5F5"
            }

            Item { width: 1; height: 8 }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Secure Vision System"
                font.family: "Segoe UI"
                font.pixelSize: 14
                color: "#B4B4BE"
            }

            Item { width: 1; height: 4 }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "v" + AutoUpdater.currentVersion
                font.family: "Segoe UI"
                font.pixelSize: 12
                color: "#787882"
            }

            Item { width: 1; height: 40 }

            // 进度条
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 300
                height: 8
                radius: 4
                color: "#3C3C46"

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * splashScreen.fakeProgress / 100
                    radius: 4
                    color: "#42A5F5"
                }
            }

            Item { width: 1; height: 12 }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: splashScreen.statusText
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#9696A0"
            }
        }
    }
    
    // 登录页面（登录前显示，启动画面结束后）
    // ⭐ 2026-07-03（§24）：MainPage 异步加载期间（mainLoading）登录页保持加载，
    //   配合下方遮罩避免窗口空白；加载完成 status→Ready 后此绑定自动卸载登录页。
    Loader {
        id: loginLoader
        anchors.fill: parent
        active: (!isLoggedIn || mainLoading) && !showSplash
        source: ((!isLoggedIn || mainLoading) && !showSplash) ? "LoginPage.qml" : ""
        
        onLoaded: {
            console.log("Main.qml: LoginPage 已加载")
            if (item) {
                item.loginSuccess.connect(handleLoginSuccess)
            }
        }
    }

    // ⭐ 2026-07-03（§24）：主页异步加载中的遮罩提示（盖在登录页上，低于启动画面 z:100）
    Rectangle {
        anchors.fill: parent
        visible: mainLoading && !showSplash
        z: 90
        color: "#B3000000"
        radius: 20

        // 吞掉加载期间的点击，防止误操作登录页
        MouseArea { anchors.fill: parent; hoverEnabled: true }

        Column {
            anchors.centerIn: parent
            spacing: 16

            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                running: mainLoading
                width: 48
                height: 48
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "正在进入主页…"
                font.family: "PingFang HK"
                font.pixelSize: 16
                color: "#FFFFFF"
            }
        }
    }
    
    // 处理登录成功
    function handleLoginSuccess(server) {
        console.log("Main.qml: handleLoginSuccess 收到信号, server:", server)
        srsServer = server
        console.log("Main.qml: 准备设置 isLoggedIn = true...")
        isLoggedIn = true
        console.log("Main.qml: isLoggedIn 已设置为 true")
    }
    
    // ============ 更新对话框 ============
    Dialog {
        id: updateDialog
        anchors.centerIn: parent
        width: 400
        height: 320
        modal: true
        closePolicy: Popup.NoAutoClose
        
        // ⭐ 2026-08-14：换成 aihj 深色规范（#1F1F1F 底 / #3A3A3A 边框 / #FAFAFA 文字 / #607AFB 主按钮）
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
                text: "发现新版本"
                font.family: "PingFang HK"
                font.pixelSize: 18
                font.bold: true
                color: "#FAFAFA"
            }
        }
        
        contentItem: ColumnLayout {
            spacing: 16
            
            // 版本信息
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                spacing: 10
                
                Text {
                    text: "当前版本："
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#64748b"
                }
                Text {
                    text: AutoUpdater.currentVersion
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    font.bold: true
                    color: "#FAFAFA"
                }
                Text {
                    text: "→"
                    font.pixelSize: 14
                    color: "#64748b"
                }
                Text {
                    text: "新版本："
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    color: "#64748b"
                }
                Text {
                    text: AutoUpdater.latestVersion
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    font.bold: true
                    color: "#607AFB"
                }
            }
            
            // 更新日志
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                color: "#292929"
                radius: 8
                border.color: "#3A3A3A"
                border.width: 1
                
                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 10
                    
                    Text {
                        width: parent.width
                        text: AutoUpdater.changelog || "暂无更新说明"
                        font.family: "PingFang HK"
                        font.pixelSize: 13
                        color: "#9ca3af"
                        wrapMode: Text.Wrap
                        lineHeight: 1.5
                    }
                }
            }
            
            // 下载进度
            ProgressBar {
                id: updateProgressBar
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                visible: AutoUpdater.isDownloading
                value: AutoUpdater.downloadProgress / 100.0
                
                Text {
                    anchors.centerIn: parent
                    text: AutoUpdater.downloadProgress + "%"
                    font.pixelSize: 12
                    color: "#FAFAFA"
                }
            }

            // §43 清单差量更新状态（比对中 / 正在下第几个文件）
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                visible: AutoUpdater.isDownloading && AutoUpdater.statusText.length > 0
                text: AutoUpdater.statusText
                font.family: "PingFang HK"
                font.pixelSize: 12
                color: "#9ca3af"
                elide: Text.ElideMiddle
            }

            // 安装中提示
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                spacing: 8
                visible: AutoUpdater.isInstalling

                Text {
                    Layout.fillWidth: true
                    text: "正在安装更新，请勿手动打开程序..."
                    font.family: "PingFang HK"
                    font.pixelSize: 14
                    font.bold: true
                    color: "#607AFB"
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    Layout.fillWidth: true
                    text: "安装完成后程序将自动重启"
                    font.family: "PingFang HK"
                    font.pixelSize: 12
                    color: "#9ca3af"
                    horizontalAlignment: Text.AlignHCenter
                }

                ProgressBar {
                    Layout.fillWidth: true
                    indeterminate: true
                }
            }
            
            // 按钮行
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.bottomMargin: 10
                spacing: 12
                visible: !AutoUpdater.isInstalling
                
                Item { Layout.fillWidth: true }
                
                // 稍后提醒
                Rectangle {
                    Layout.preferredWidth: 100
                    height: 36
                    radius: 8
                    color: laterArea.containsMouse ? "#374151" : "#292929"
                    visible: !AutoUpdater.isDownloading
                    
                    Text {
                        anchors.centerIn: parent
                        text: "稍后提醒"
                        font.family: "PingFang HK"
                        font.pixelSize: 13
                        color: "#FAFAFA"
                    }
                    
                    MouseArea {
                        id: laterArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: updateDialog.close()
                    }
                }
                
                // 立即更新
                Rectangle {
                    Layout.preferredWidth: 100
                    height: 36
                    radius: 8
                    color: AutoUpdater.isDownloading ? "#3A3A3A" : (updateNowArea.containsMouse ? "#4E66DA" : "#607AFB")
                    
                    Text {
                        anchors.centerIn: parent
                        text: AutoUpdater.isDownloading ? "下载中..." : "立即更新"
                        font.family: "PingFang HK"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#FFFFFF"
                    }
                    
                    MouseArea {
                        id: updateNowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: AutoUpdater.isDownloading ? Qt.ArrowCursor : Qt.PointingHandCursor
                        enabled: !AutoUpdater.isDownloading
                        onClicked: AutoUpdater.downloadAndInstall()
                    }
                }
            }
        }
    }
}
