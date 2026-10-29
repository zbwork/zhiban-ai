; F18 桌面更新 · 知办AI Windows 安装器（Inno Setup）。
;
; 用法（在 Windows 上，已装 Inno Setup 6）：
;   iscc /DMyAppVersion=1.0.0 installer.iss
;   产出：Output\zhiban-setup-1.0.0.exe
;
; 该安装器由 WinSparkle 在检测到更新后下载并运行，完成自动更新。
; 默认从 ..\..\build\windows\x64\runner\Release 取 flutter build windows --release 的产物。
; 可用 /DMySourceDir=<目录> 覆盖产物路径。
;
; 版本号默认自动从已构建的 ZhiBanAI.exe 读取（含构建号，如 1.0.0.10008），GUI 点 Compile
; 也能拿到真实版本；如需自定义版本字符串：iscc /DMyAppVersion=1.0.1 installer.iss

#ifndef MySourceDir
  #define MySourceDir AddBackslash(ExtractFileDir(ExtractFileDir(RemoveBackslash(SourcePath)))) + "build\windows\x64\runner\Release"
#endif

#if !FileExists(MySourceDir + "\zhiban-local-bridge.exe")
  #error 缺少 zhiban-local-bridge.exe，请先运行 flutter build windows --release（Go 需加入 PATH）
#endif

#if !FileExists(MySourceDir + "\WinSparkle.dll")
  #error 缺少 WinSparkle.dll，请配置 Windows 更新 SDK 后重新运行 flutter build windows --release
#endif

#if !FileExists(MySourceDir + "\msvcp140.dll") || !FileExists(MySourceDir + "\vcruntime140.dll") || !FileExists(MySourceDir + "\vcruntime140_1.dll")
  #error 缺少 Release VC++ 运行库，请重新运行 flutter build windows --release；运行库必须随应用分发
#endif

#if !FileExists(MySourceDir + "\local-agent\manifest.json") || !FileExists(MySourceDir + "\local-agent\node\node.exe") || !FileExists(MySourceDir + "\local-agent\dsh-runtime\native\zhiban-local-sandbox.exe") || !FileExists(MySourceDir + "\local-agent\dsh-runtime\native\zhiban-windows-path.node")
  #error 缺少 Local Agent 运行组件，请重新运行 flutter build windows --release
#endif
#if !FileExists(MySourceDir + "\data\flutter_assets\packages\zhiban_client\assets\file_preview\viewer.html") || !FileExists(MySourceDir + "\WebView2Loader.dll")
  #error 缺少文件预览组件，请重新运行 flutter build windows --release
#endif

#ifndef MyWebView2Installer
  #define MyWebView2Installer "..\..\build\windows-dependencies\MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
#endif
#if !FileExists(MyWebView2Installer)
  #error 缺少 WebView2 离线安装器，请先运行 scripts/prepare_webview2_windows.ps1
#endif

#ifndef MyAppVersion
  #define MyAppExeFull MySourceDir + "\ZhiBanAI.exe"
  #if !FileExists(MyAppExeFull)
    #error 找不到 ZhiBanAI.exe，请先运行 flutter build windows --release（或用 /DMyAppVersion=x.y.z 指定版本）
  #endif
  #define MyAppVersion GetFileVersion(MyAppExeFull)
#endif

#define MyAppName "知办AI"
#define MyAppPublisher "cn.qkfintech.zhiban"
#define MyAppExeName "ZhiBanAI.exe"

[Setup]
; AppId 固定，勿改：Inno 用它识别同一应用以做升级覆盖安装。
AppId={{A1E8C2F0-7B3D-4C56-9A21-0F4D8E6B12C3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
PrivilegesRequired=admin
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=zhiban-setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; 升级时关闭/重启正在运行的应用，避免文件占用导致更新失败。
CloseApplications=yes
RestartApplications=yes
SetupLogging=yes
; 把版本号写进生成的 setup.exe 文件属性（资源管理器 → 属性 → 详细信息 → 文件版本）。
; VersionInfoVersion 需为数字版本（如 1.0.1）；MyAppVersion 含非数字后缀时此处会报错。
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoProductName={#MyAppName}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
; 未做 Authenticode 代码签名：安装/更新首启会触发 SmartScreen「未知发布者」提示（见 F18 §6.2）。

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Excludes: "\.local-agent-*"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#MyWebView2Installer}"; DestDir: "{tmp}"; DestName: "MicrosoftEdgeWebView2RuntimeInstallerX64.exe"; Flags: dontcopy

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; 安装/升级完成后启动应用（WinSparkle 静默更新场景由 RestartApplications 负责重启）。
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  RuntimeDir: String;
  ExitCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  RuntimeDir := ExpandConstant('{app}\local-agent');
  { Only public, bundled program files. Users' workspaces/credentials are outside
    this tree. AppContainers need their own read/execute ACE; Users RX does not
    suffice, and ordinary users cannot set DACLs on administrator-owned installs.
    Numeric SID avoids localized group names. Preserve all other permissions. }
  if not DirExists(RuntimeDir) then
    RaiseException('本地运行组件目录缺失，安装无法完成。');
  if not Exec(ExpandConstant('{sys}\icacls.exe'),
      '"' + RuntimeDir + '" /grant "*S-1-15-2-1:(OI)(CI)(RX)" /Q',
      '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    RaiseException('无法设置本地运行组件读取权限，安装无法完成。');
  if ExitCode <> 0 then
    RaiseException('设置本地运行组件读取权限失败（' + IntToStr(ExitCode) + '），安装无法完成。');
end;

function HasWebView2: Boolean;
var
  Version: String;
  ClientKey: String;
begin
  ClientKey := 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  { This is a machine-wide installer. HKCU could belong to the administrator
    who approved elevation, rather than the user who will run the app. }
  Result := RegQueryStringValue(HKLM32, ClientKey, 'pv', Version) and
    (Version <> '') and (Version <> '0.0.0.0');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  if HasWebView2 then Exit;
  ExtractTemporaryFile('MicrosoftEdgeWebView2RuntimeInstallerX64.exe');
  if not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebView2RuntimeInstallerX64.exe'),
      '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    Result := '无法启动 Microsoft Edge WebView2 安装程序，请重试。'
  else if (ExitCode <> 0) and (ExitCode <> 3010) then
    Result := 'Microsoft Edge WebView2 安装失败（' + IntToStr(ExitCode) + '），请重试。'
  else begin
    NeedsRestart := ExitCode = 3010;
    if not HasWebView2 then
      Result := '未检测到 Microsoft Edge WebView2 Runtime，安装已中止，请重试。';
  end;
end;
