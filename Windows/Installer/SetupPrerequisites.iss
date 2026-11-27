[Files]
Source: "{#PrerequisiteDir}\vc_redist.x64.exe"; Flags: dontcopy
Source: "{#PrerequisiteDir}\windowsappruntimeinstall-x64.exe"; Flags: dontcopy

[Code]
var
  PrerequisiteReboot: Boolean;

function HasVisualCppRuntime: Boolean;
var
  Installed, Major, Minor, Build: Cardinal;
begin
  Result :=
    RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) and
    (Installed = 1) and
    RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Major', Major) and
    RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Minor', Minor) and
    RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Bld', Build) and
    ((Major > 14) or ((Major = 14) and ((Minor > 50) or ((Minor = 50) and (Build >= 35719)))));
end;

function InstallPrerequisite(const Name, FileName, Arguments: String): String;
var
  ExitCode: Integer;
begin
  Log('Installing ' + Name);
  ExtractTemporaryFile(FileName);
  Result := '';
  if not Exec(ExpandConstant('{tmp}\') + FileName, Arguments, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    Result := Format('%s could not start (error %d).', [Name, ExitCode])
  else if (ExitCode = 3010) or (ExitCode = 1641) then
    PrerequisiteReboot := True
  else if ExitCode <> 0 then
    Result := Format('%s setup failed (exit code %d).', [Name, ExitCode]);
  Log(Format('%s exit code: %d', [Name, ExitCode]));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not HasVisualCppRuntime then
    Result := InstallPrerequisite('Visual C++ Redistributable', 'vc_redist.x64.exe', '/install /quiet /norestart')
  else
    Log('A supported Visual C++ x64 Redistributable is already installed.');

  if Result = '' then
    Result := InstallPrerequisite('Windows App Runtime', 'windowsappruntimeinstall-x64.exe', '--quiet');
end;

function NeedRestart: Boolean;
begin
  Result := PrerequisiteReboot;
end;
