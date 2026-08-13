@echo off
setlocal EnableExtensions EnableDelayedExpansion
title 强制卸载 zjc_worker
cd /d "%~dp0"

echo.
echo ========================================
echo   强制卸载 zjc_worker（金凤凰）
echo ========================================
echo.

REM ---- 检查管理员；没有则弹 UAC 重开自己 ----
net session >nul 2>&1
if %errorlevel%==0 goto :IS_ADMIN

echo [提示] 当前不是管理员，即将弹出 UAC，请点「是」
echo.
mshta "javascript:var s=new ActiveXObject('Shell.Application');s.ShellExecute('%~f0','','','runas',1);close();"
echo.
echo 若没有弹出 UAC：请关闭本窗口，右键本 bat -^>「以管理员身份运行」
pause
exit /b 1

:IS_ADMIN
echo [OK] 已是管理员
echo.

set "ZJC_DIR=%ProgramData%\zjc_worker"
set "SVC=zjc_worker"

echo 安装目录: %ZJC_DIR%
echo 服务名:   %SVC%
echo.
echo 按任意键开始强制卸载，或直接关闭窗口取消...
pause >nul
echo.

echo [1/5] 停止服务...
sc stop %SVC%
echo.

echo [2/5] 强杀进程...
taskkill /F /IM zjc_worker.exe 2>nul
taskkill /F /IM winshaper.exe 2>nul
ping -n 2 127.0.0.1 >nul
echo.

echo [3/5] 删除服务...
for /L %%i in (1,1,5) do (
    sc query %SVC% >nul 2>&1
    if errorlevel 1060 (
        echo     服务已不存在
        goto :SVC_DONE
    )
    echo     第 %%i 次: sc delete
    sc stop %SVC% >nul 2>&1
    taskkill /F /IM zjc_worker.exe 2>nul
    sc delete %SVC%
    ping -n 2 127.0.0.1 >nul
)
echo     [!] 仍删不掉，重启后再跑一次
:SVC_DONE
echo.

echo [4/5] 清理注册表自启...
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\Run" /v zjc_worker /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v zjc_worker /f 2>nul
echo     完成
echo.

echo [5/5] 删除目录 %ZJC_DIR% ...
if exist "%ZJC_DIR%" (
    attrib -R -S -H "%ZJC_DIR%\*" /S /D >nul 2>&1
    rd /s /q "%ZJC_DIR%"
    ping -n 2 127.0.0.1 >nul
    if exist "%ZJC_DIR%" (
        taskkill /F /IM zjc_worker.exe 2>nul
        rd /s /q "%ZJC_DIR%"
    )
)

echo.
echo ========== 结果 ==========
sc query %SVC% >nul 2>&1
if errorlevel 1060 (
    echo [OK] 服务已删除
) else (
    echo [!!] 服务还在 — 请重启电脑后再跑本脚本
    sc query %SVC%
)

tasklist /FI "IMAGENAME eq zjc_worker.exe" 2>nul | find /I "zjc_worker.exe" >nul
if errorlevel 1 (
    echo [OK] 无残留进程
) else (
    echo [!!] 仍有 zjc_worker.exe
)

if exist "%ZJC_DIR%" (
    echo [!!] 目录未删干净: %ZJC_DIR%
) else (
    echo [OK] 安装目录已删除
)

echo.
echo 完成，按任意键退出
pause >nul
endlocal
