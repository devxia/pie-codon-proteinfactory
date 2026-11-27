[Setup]
AppId={{7CB45779-74FC-4DA8-B2DC-EA6EC3A383C1}
AppName=Codon ProteinFactory
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
UninstallDisplayIcon={app}\CodonProteinFactory.exe
DefaultDirName={autopf}\Codon Protein Factory
DisableDirPage=no
DefaultGroupName=Codon ProteinFactory
OutputDir={#OutputDirectory}
OutputBaseFilename=Pie-Codon-ProteinFactory-{#AppVersion}-win-x64
SetupIconFile=Assets\CodonProteinFactory.ico
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.26200
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
#ifdef InstallerSignTool
SignTool={#InstallerSignTool}
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{commonprograms}\Codon ProteinFactory"; Filename: "{app}\CodonProteinFactory.exe"

#include "SetupPrerequisites.iss"
