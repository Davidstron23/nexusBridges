; Inno Setup script for NexusBridges. Build it with tool/build-installer.ps1,
; which passes the app version with /DAppVersion=x.y.z.

#ifndef AppVersion
  #define AppVersion "0.0.0"
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
; No administrator rights needed: it installs for the current user unless they choose otherwise.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
