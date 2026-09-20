; AcpAgent Client 的 Windows 安装器（R8）。Inno Setup 6，**per-user 安装、不签名**
; （所有者裁定 2026-09-20：装进 %LOCALAPPDATA%\Programs，免 UAC 提权；per-machine 没签名时
; SmartScreen 拦得更凶，而这个项目开源不商用，暂不买签名证书）。
;
; 由 scripts/package.ps1 调用，版本与要打包的目录从命令行传进来：
;   ISCC /DAppVersion=1.3.0 /DPayloadDir=<dist\stage\AcpAgentClient-1.3.0-windows-x64> /O<dist> 本文件
; 直接双击编译也行（用下面的默认值，需要先跑过 scripts/package.ps1 -NoInstaller）。
;
; 卸载**不动** %APPDATA%\AcpAgentClient（设置、会话索引、日志、受管 Node、sidecar 的 zed-agent 数据目录）：
; 那是用户数据，CLAUDE.md 规则 7。重装或升级直接覆盖安装即可。
;
; 界面语言只有英文：Inno Setup 6 自带的 Languages\ 里没有简体中文（ChineseSimplified.isl 要另外下载，
; 入库它等于再分发第三方文件）。装完之后应用自己的界面照常是中文。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "AcpAgent Client"
#define AppExeName "acp_agent_client.exe"
#define AppPublisher "ClickPM"
#define AppUrl "https://github.com/ClickPM/AcpAgentClient"

#ifndef PayloadDir
  #define PayloadDir "..\..\dist\stage\AcpAgentClient-" + AppVersion + "-windows-x64"
#endif

[Setup]
; AppId 固定（R8 生成一次）：升级安装靠它认出上一版，改了会变成并存的两份安装。
AppId={{7398E811-37B7-4DD4-AC1B-72B398313DD5}
AppName={#AppName}
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={autopf}\AcpAgentClient
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\..\LICENSE
OutputBaseFilename=AcpAgentClient-{#AppVersion}-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName} {#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
