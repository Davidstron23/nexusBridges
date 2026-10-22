; Inno Setup script for NexusBridges. Build it with tool/build-installer.ps1,
; which passes the app version with /DAppVersion=x.y.z.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef CrtDir
  #error CrtDir is not defined. Build the installer with tool/build-installer.ps1.
#endif

#define AppName "NexusBridges"
#define AppExeName "nexus_bridges.exe"
#define ReleaseDir "..\apps\nexus_bridges\build\windows\x64\runner\Release"

[Setup]
; Fixed GUID: it identifies the app across versions so upgrades replace the old install.
; The doubled opening brace is Inno Setup's escape for a literal brace.
AppId={{7BF0D2F1-3A07-442B-AF98-6CDB86B44480}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=David Ariza
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=NexusBridges-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#AppExeName}
PrivilegesRequired=admin
WizardStyle=modern

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Visual C++ runtime, installed next to the exe (app-local deployment) so the app starts on a clean Windows.
Source: "{#CrtDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""NexusBridges"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""NexusBridges"" dir=in action=allow program=""{app}\nexus_bridges.exe"" enable=yes profile=any remoteip=localsubnet protocol=TCP localport=53530"; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""NexusBridges"" dir=in action=allow program=""{app}\nexus_bridges.exe"" enable=yes profile=any remoteip=localsubnet protocol=UDP localport=53530"; Flags: runhidden waituntilterminated
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""NexusBridges"""; Flags: runhidden; RunOnceId: "DelFirewall"
