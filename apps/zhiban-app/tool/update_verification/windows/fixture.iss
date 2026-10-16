[Setup]
AppId=EasyOUpdateVerification-{#ProbeId}
AppName=EasyO Update Verification
AppVersion=0.0.0.101
VersionInfoVersion=0.0.0.101
DefaultDirName={#ProbeRoot}\installed
PrivilegesRequired=lowest
OutputDir={#ProbeRoot}
OutputBaseFilename=fixture-101
Uninstallable=no
CreateUninstallRegKey=no
DisableProgramGroupPage=yes
DisableDirPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
Compression=lzma2/fast

[Files]
Source: "{#ProbeRoot}\build\101\*"; DestDir: "{app}"; Flags: ignoreversion

[Code]
var Installed: Boolean;
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then Installed := True;
end;
procedure DeinitializeSetup();
begin
  if Installed then
    SaveStringToFile(ExpandConstant('{#ProbeRoot}\installer-result'), 'installed', False)
  else
    SaveStringToFile(ExpandConstant('{#ProbeRoot}\installer-result'), 'cancelled', False);
end;
