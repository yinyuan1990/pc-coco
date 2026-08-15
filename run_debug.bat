@echo off
chcp 65001 > nul

REM ====== GStreamer 环境变量 ======
set "GST_HOME=C:\Program Files\gstreamer\1.0\msvc_x86_64"

REM 检查 GStreamer 是否安装
if not exist "%GST_HOME%\bin\gstreamer-1.0-0.dll" (
    echo [ERROR] GStreamer not found at %GST_HOME%
    pause
    exit /b 1
)

REM 设置 PATH（bin 和 lib 都要加）
set "PATH=%GST_HOME%\bin;%GST_HOME%\lib;%PATH%"

REM 设置插件路径
set "GST_PLUGIN_PATH=%GST_HOME%\lib\gstreamer-1.0"
set "GST_PLUGIN_SYSTEM_PATH=%GST_PLUGIN_PATH%"
set "GST_PLUGIN_SCANNER=%GST_HOME%\libexec\gstreamer-1.0\gst-plugin-scanner.exe"

REM 禁用插件扫描器的弹框（静默模式）
set "GST_DEBUG=0"

echo ========================================
echo   GStreamer: %GST_HOME%
echo   Plugin Path: %GST_PLUGIN_PATH%
echo ========================================
echo.

REM 运行程序
cd /d "%~dp0build\Desktop_Qt_6_10_3_MSVC2022_64bit-Debug"
echo Starting HuanJing.exe from %CD%
echo.
HuanJing.exe

pause
