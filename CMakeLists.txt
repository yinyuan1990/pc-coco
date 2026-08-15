cmake_minimum_required(VERSION 3.16)

project(Phoenix VERSION 0.1 LANGUAGES C CXX)

# ⭐ §43 版本号单一来源：发版只改这一行！
#   - autoupdater.cpp 经宏 PHOENIX_VERSION_STR 得到当前版本（不再硬编码）
#   - pack.bat 解析本行生成 manifest.json / yqlversion_new.json
set(PHOENIX_APP_VERSION "1.0.0")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# ⭐ 大对象格式 — MainPage.qml 经 qmlcache 编译后单 .obj sections 数突破 PE-COFF 上限
#   MinGW (GAS) 用 -Wa,-mbig-obj, MSVC 用 /bigobj
#   报错形式: "too many sections (49470)" / "file too big"
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    add_compile_options(-Wa,-mbig-obj)
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    add_compile_options(/bigobj)
    add_compile_options(/utf-8)   # 统一源文件和执行字符集为 UTF-8，避免中文字符串乱码
endif()

# FFmpeg 路径
set(FFMPEG_ROOT "C:/ffmpeg")
set(FFMPEG_INCLUDE_DIR "${FFMPEG_ROOT}/include")
set(FFMPEG_LIB_DIR "${FFMPEG_ROOT}/lib")
set(FFMPEG_BIN_DIR "${FFMPEG_ROOT}/bin")

# ⭐ aihj 版：AI 牌位置识别（ONNX Runtime + cardYolov8）整套下线，不再依赖 C:/onnxruntime。
#   carddetector.cpp/h 保留但已改为无 ONNX 的空实现（见文件顶部说明）。

# vcpkg 安装路径（仅用于 turbojpeg，不使用 vcpkg 的 GStreamer）
set(VCPKG_ROOT "D:/javafx/Acard/aic/vcpkg/installed/x64-windows")
set(VCPKG_INCLUDE_DIR "${VCPKG_ROOT}/include")
set(VCPKG_LIB_DIR "${VCPKG_ROOT}/lib")
set(VCPKG_BIN_DIR "${VCPKG_ROOT}/bin")

# GStreamer 路径
set(GSTREAMER_ROOT "C:/PROGRA~1/gstreamer/1.0/msvc_x86_64")
set(GSTREAMER_LIB_DIR "${GSTREAMER_ROOT}/lib")
set(GSTREAMER_BIN_DIR "${GSTREAMER_ROOT}/bin")

# 查找 Qt 模块
find_package(Qt6 REQUIRED COMPONENTS Quick Widgets Network QuickControls2 Concurrent Multimedia ShaderTools WebSockets)
find_package(Qt6 COMPONENTS Qt5Compat QUIET)  # 可选：用于 GraphicalEffects

# ⭐ Qt WebEngine（Chromium 内核）—— 浏览器内核兜底/画质对比测试用。
#   可选依赖：装了 QtWebEngine 才编译「内核测试」功能（定义 HAVE_WEBENGINE 宏）；
#   没装则自动跳过，不影响主程序构建（环境差异零回归）。
find_package(Qt6 COMPONENTS WebEngineQuick WebChannel QUIET)
if(Qt6WebEngineQuick_FOUND AND Qt6WebChannel_FOUND)
    message(STATUS "✅ Qt WebEngine + WebChannel 已找到 → 启用「内核测试」(Chromium 内核拉流对比)")
    set(HAVE_KERNEL_TEST ON)
else()
    message(STATUS "⚠️ Qt WebEngine/WebChannel 未找到 → 跳过「内核测试」功能（主程序不受影响）")
    set(HAVE_KERNEL_TEST OFF)
endif()

qt_standard_project_setup(REQUIRES 6.8)

# 源文件
qt_add_executable(Phoenix
    main.cpp
    videoplayer.cpp
    videoplayer.h
    # webrtcclient.cpp  # ⭐ 废弃，改用 GstPlayer WebRTCBin
    # webrtcclient.h
    capturemanager.cpp
    capturemanager.h
    carddetector.cpp     # ⭐ aihj：AI 牌识别已下线，保留空实现接口（无 ONNX 依赖）
    carddetector.h
    slowmotionplayer.cpp
    slowmotionplayer.h
    imageprovider.cpp
    imageprovider.h
    eventbus.cpp
    eventbus.h
    gpupipeline.cpp      # 颜色调整（亮度/对比度/饱和度/伽马）
    gpupipeline.h
    naluframestore.cpp   # H.264 NALU 环形缓冲（替代 JPEG 文件）
    naluframestore.h
    naludecoder.cpp      # H.264 NALU → QImage 解码器（FFmpeg，备用）
    naludecoder.h
    gstcapturedecoder.cpp  # H.264 NALU → QImage（GStreamer 管线，同直播 d3d11h264dec）
    gstcapturedecoder.h
    capturedebuglog.cpp
    capturedebuglog.h
    gstplayer.cpp        # GStreamer 实时流 + NALU 存储
    gstplayer.h
    h265support.cpp      # ⭐ H265(HEVC) P2P 支持（元素工厂/IRAP判断/独立日志，与 H264 主链路解耦）
    h265support.h
    iframesource.h       # ⭐ 帧源抽象接口（截图/慢放数据源解耦：GStreamer / 网页内核）
    webframesource.cpp   # ⭐ 网页内核帧源（JS 回传 JPEG → 落盘，供截图/慢放复用）
    webframesource.h
    gstsrtsource.cpp     # MARK: SRT (independent) 方案B PC端独立 SRT 拉流前段
    gstsrtsource.h
    httpclient.cpp
    httpclient.h
    p2ploguploader.cpp   # ⭐ P2P诊断日志上报器（总后台开关控制，按推流ID分流上传）
    p2ploguploader.h
    websocketclient.cpp
    websocketclient.h
    shortcutstore.cpp
    shortcutstore.h
    qrcodegenerator.cpp
    qrcodegenerator.h
    qrcodegen.cpp
    qrcodegen.hpp
    autoupdater.cpp
    autoupdater.h
    app.rc  # Windows 应用图标
)

# Include 路径（注意顺序：GStreamer 在前，vcpkg 在后，避免 glib 冲突）
target_include_directories(Phoenix PRIVATE 
    ${FFMPEG_INCLUDE_DIR}
    # GStreamer（系统安装，优先级高于 vcpkg）
    "${GSTREAMER_ROOT}/include/gstreamer-1.0"
    "${GSTREAMER_ROOT}/include/glib-2.0"
    "${GSTREAMER_ROOT}/lib/glib-2.0/include"
    # vcpkg（仅用于 turbojpeg.h）
    ${VCPKG_INCLUDE_DIR}
)

# ⭐ GStreamer WebRTC API 需要此宏定义
target_compile_definitions(Phoenix PRIVATE GST_USE_UNSTABLE_API)

# ⭐ §43 当前版本号注入（单一来源见顶部 PHOENIX_APP_VERSION）
target_compile_definitions(Phoenix PRIVATE PHOENIX_VERSION_STR="${PHOENIX_APP_VERSION}")

# ⭐ Qt WebEngine + WebChannel 可用时定义 HAVE_WEBENGINE，main.cpp / 测试逻辑据此条件编译
#   并加入桥对象 kernelbridge（QWebChannel 把 C++ P2P 信令暴露给 WebEngine 里的 JS）。
if(HAVE_KERNEL_TEST)
    target_compile_definitions(Phoenix PRIVATE HAVE_WEBENGINE)
    target_link_libraries(Phoenix PRIVATE Qt6::WebEngineQuick Qt6::WebChannel)
    target_sources(Phoenix PRIVATE kernelbridge.cpp kernelbridge.h)
endif()

# 注意：MSVC 不支持 #warning 指令，需要手动修补 GStreamer 头文件
# 已通过 PowerShell 管理员命令修补：
# (Get-Content 'C:\Program Files\gstreamer\1.0\msvc_x86_64\include\gstreamer-1.0\gst\webrtc\webrtc_fwd.h') -replace '#warning', '// #warning' | Set-Content '...'

# Library 路径（GStreamer 在前，避免链接 vcpkg 版本）
target_link_directories(Phoenix PRIVATE 
    ${GSTREAMER_LIB_DIR}
    ${FFMPEG_LIB_DIR}
    ${VCPKG_LIB_DIR}  # 仅用于 turbojpeg
)

# 链接库
target_link_libraries(Phoenix PRIVATE
    Qt6::Quick
    Qt6::Widgets
    Qt6::Network
    Qt6::QuickControls2
    Qt6::Concurrent
    Qt6::Multimedia
    Qt6::WebSockets
    # FFmpeg
    avformat
    avcodec
    avutil
    swscale
    # libdatachannel（已废弃，改用 GStreamer WebRTCBin）
    # datachannel
    # libjpeg-turbo (软件 JPEG 编码/解码，备用)
    turbojpeg
    # GStreamer（核心 + WebRTC）
    gstreamer-1.0
    gstapp-1.0
    gstvideo-1.0
    gstsdp-1.0         # ⭐ SDP 解析（WebRTC 需要）
    gstwebrtc-1.0      # ⭐ WebRTCBin
    gstrtp-1.0         # ⭐ RTP 载荷解析（H265 收流 NAL 类型诊断，h265support.cpp）
    gobject-2.0
    glib-2.0
    # Windows 网络库
    ws2_32
    iphlpapi
    # D3D11 硬件加速
    d3d11
    dxgi
    # Shell API（ShellExecuteW 用于更新脚本启动）
    Shell32
)

# ⭐ QML 文件列表：KernelTestView.qml 含 `import QtWebEngine`，仅在装了 WebEngine 时编入，
#   否则 qmlcachegen 会因找不到 QtWebEngine 模块而构建失败。
set(PHOENIX_QML_FILES
    Main.qml
    LoginPage.qml
    MainPage.qml
    # ⭐ 第五十章 OTG 自适配：新东西一律独立成文件，不再往 MainPage.qml 里堆
    CameraCapsStore.qml      # 能力仓库（单例）
    CameraControlRow.qml     # 公用：滑条/开关/分段 三合一的一行控件
    OtgCameraPanel.qml       # OTG 完整设定面板（按能力动态生成）
    LiveBarButton.qml        # 公用：实时流底部按钮
    LiveBarMenu.qml          # 公用：实时流底部下拉
    OtgLiveControlBar.qml    # OTG 版实时流底部按钮栏
)
if(HAVE_KERNEL_TEST)
    list(APPEND PHOENIX_QML_FILES KernelTestView.qml)
endif()

# CameraCapsStore 是 QML 单例（pragma Singleton），需显式标记，否则 qmlcachegen 不认
set_source_files_properties(CameraCapsStore.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(Phoenix
    URI Aifs
    QML_FILES
        ${PHOENIX_QML_FILES}
    RESOURCES
        images/yql.png
        images/zwtp.png
        images/avatar.png
        images/head.png
        images/icon.png
        images/fh.png
        images/frame.png
        images/down.png
        images/sbbd.png
        images/xjsd.png
        images/kjjsz.png
        images/hxpl.png
        images/qp.png
        images/bar.png
        images/max.png
        images/close.png
        webplayer_test.html
)

# MinGW: QML AOT 原生代码会调用 copysign，链接时需 libm；--only-bytecode 避免生成该原生代码
if(MINGW)
    target_link_libraries(Phoenix PRIVATE m)
    set_target_properties(Phoenix PROPERTIES
        QT_QMLCACHEGEN_ARGUMENTS "--only-bytecode"
    )
endif()

# 编译 Shader（GPU 颜色调整）
qt6_add_shaders(Phoenix "shaders"
    PREFIX "/shaders"
    FILES
        shaders/coloradjust.frag
)

set_target_properties(Phoenix PROPERTIES
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
    # ⭐ 2026-08-14 aihj 品牌：产物名 HuanJing.exe（幻境；target 名保留 Phoenix，避免大范围改动）
    OUTPUT_NAME "HuanJing"
)

# §23.14 冻结取证：Release 也产出 HuanJing.pdb（放 exe 同级），
# 让 freeze_diag.txt 的主线程栈能把 HuanJing.exe 帧解析成 函数名+源文件:行号。
# /Zi 不改代码生成（仍 /O2 优化），仅多写调试信息；/DEBUG 默认会关掉
# /OPT:REF|ICF，显式加回避免 exe 变大/布局变化。
if(MSVC)
    target_compile_options(Phoenix PRIVATE $<$<CONFIG:Release>:/Zi>)
    target_link_options(Phoenix PRIVATE
        $<$<CONFIG:Release>:/DEBUG /OPT:REF /OPT:ICF>
    )
endif()

# ⭐ FFmpeg DLL：通配所有 av*/sw*，不写死版本号（升级 61→62→… 不会漏拷/缺 DLL，与 pack.bat 一致）
file(GLOB FFMPEG_RUNTIME_DLLS "${FFMPEG_BIN_DIR}/av*.dll" "${FFMPEG_BIN_DIR}/sw*.dll")

# 复制 DLL 到输出目录
add_custom_command(TARGET Phoenix POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${FFMPEG_RUNTIME_DLLS}
        # libdatachannel（已废弃，改用 GStreamer WebRTCBin）
        # "${VCPKG_BIN_DIR}/datachannel.dll"
        # "${VCPKG_BIN_DIR}/juice.dll"
        # "${VCPKG_BIN_DIR}/libcrypto-3-x64.dll"
        # "${VCPKG_BIN_DIR}/libssl-3-x64.dll"
        # "${VCPKG_BIN_DIR}/srtp2.dll"
        "${VCPKG_BIN_DIR}/turbojpeg.dll"
        # GStreamer 核心 DLL
        "${GSTREAMER_ROOT}/bin/gstreamer-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstapp-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstvideo-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstbase-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstsdp-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstrtp-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gobject-2.0-0.dll"
        "${GSTREAMER_ROOT}/bin/glib-2.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gmodule-2.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gio-2.0-0.dll"
        "${GSTREAMER_ROOT}/bin/intl-8.dll"
        "${GSTREAMER_ROOT}/bin/ffi-7.dll"
        "${GSTREAMER_ROOT}/bin/pcre2-8-0.dll"
        # ⭐ WebRTC 相关 DLL
        "${GSTREAMER_ROOT}/bin/gstwebrtc-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstwebrtcnice-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/nice-10.dll"
        "${GSTREAMER_ROOT}/bin/libcrypto-3-x64.dll"
        "${GSTREAMER_ROOT}/bin/libssl-3-x64.dll"
        # 额外依赖 DLL
        "${GSTREAMER_ROOT}/bin/orc-0.4-0.dll"
        "${GSTREAMER_ROOT}/bin/gstpbutils-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstaudio-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gsttag-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstnet-1.0-0.dll"
        "${GSTREAMER_ROOT}/bin/gstsctp-1.0-0.dll"
        $<TARGET_FILE_DIR:Phoenix>
)

# ⭐ Qt WebEngine 运行时（仅当启用时）：QtWebEngineProcess.exe + resources + locales
#   注意：windeployqt 也会处理，但开发期直接 copy 更省事；版本须严格对齐当前 Qt 6.10.3。
if(HAVE_KERNEL_TEST)
    get_target_property(_qmake_exe Qt6::qmake IMPORTED_LOCATION)
    get_filename_component(_qt_bin_dir "${_qmake_exe}" DIRECTORY)            # .../msvc2022_64/bin
    get_filename_component(_qt_root_dir "${_qt_bin_dir}" DIRECTORY)           # .../msvc2022_64
    add_custom_command(TARGET Phoenix POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${_qt_bin_dir}/QtWebEngineProcess.exe"
            $<TARGET_FILE_DIR:Phoenix>
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:Phoenix>/resources"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${_qt_root_dir}/resources"
            "$<TARGET_FILE_DIR:Phoenix>/resources"
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:Phoenix>/translations/qtwebengine_locales"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${_qt_root_dir}/translations/qtwebengine_locales"
            "$<TARGET_FILE_DIR:Phoenix>/translations/qtwebengine_locales"
        COMMENT "复制 Qt WebEngine 运行时（QtWebEngineProcess + resources + locales）"
    )
endif()

include(GNUInstallDirs)
install(TARGETS Phoenix
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
