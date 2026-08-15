; 幻境(HuanJing) 安装程序脚本 (Inno Setup) —— aihj PC 端
; 需要安装 Inno Setup: https://jrsoftware.org/isinfo.php

; 显示名（开始菜单/桌面快捷方式/卸载列表）用中文，安装目录用 ASCII（避免非 ASCII 路径坑）
#define MyAppName "幻境"
#define MyAppDirName "HuanJing"
; §43 版本号由 pack.bat 经 ISCC /DMyAppVersion=x.y.z 传入（源头=CMakeLists.txt 的 PHOENIX_APP_VERSION）
; 未传时才用下面的兜底值
#ifndef MyAppVersion
#define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "Acard"
#define MyAppExeName "HuanJing.exe"

[Setup]
; 应用程序信息（⭐ AppId 是 aihj 幻境专属 GUID，勿与主线产品混用）
AppId={{0BC8F763-882E-47AA-A9D6-C2B38F8A8A7E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={code:GetDefaultInstallDir}
DefaultGroupName={#MyAppName}
; 输出设置（相对 .iss 所在目录 = pc-coco 自己）
OutputDir=installer_output
OutputBaseFilename=HuanJing_Setup_{#MyAppVersion}
; 压缩设置
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
; 界面设置
WizardStyle=modern
SetupIconFile=images\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
; 权限设置
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; 其他设置
DisableProgramGroupPage=yes
DisableDirPage=no
DisableWelcomePage=no
ShowLanguageDialog=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加选项:"

[Files]
Source: "release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; 先静默安装 VC++ 运行库（如果需要）
Filename: "{app}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装 Visual C++ 运行库..."; Flags: waituntilterminated skipifdoesntexist
; 安装完成后运行程序
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 卸载时删除主程序生成的文件
Type: filesandordirs; Name: "{app}\captures"
Type: filesandordirs; Name: "{app}\logs"
Type: files; Name: "{app}\*.log"

[Code]
// 自动选择安装盘：优先选非 C 盘根目录，无其他盘则用 C:\ 根目录
function GetDefaultInstallDir(Param: String): String;
var
  I: Integer;
  DriveRoot: String;
begin
  // 从 D(68) 到 Z(90) 找第一个存在的非 C 盘
  for I := 68 to 90 do
  begin
    DriveRoot := Chr(I) + ':\';
    if DirExists(DriveRoot) then
    begin
      Result := DriveRoot + '{#MyAppDirName}';
      Exit;
    end;
  end;
  // 没有其他盘，装到 C:\ 根目录
  Result := 'C:\{#MyAppDirName}';
end;

// 安装完成后清理 VC++ 安装程序
procedure CurStepChanged(CurStep: TSetupStep);
var
  VCRedistPath: String;
begin
  if CurStep = ssPostInstall then
  begin
    // 删除 VC++ 运行库安装程序（节省空间）
    VCRedistPath := ExpandConstant('{app}\vc_redist.x64.exe');
    if FileExists(VCRedistPath) then
      DeleteFile(VCRedistPath);
  end;
end;

// 卸载前关闭主进程
function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  Exec('taskkill.exe', '/F /IM HuanJing.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
