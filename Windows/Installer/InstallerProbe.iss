[Setup]
AppId={{252B8A14-9C62-40FC-8DA1-E1A2C7EAF718}
AppName=Codon Protein Factory Installer Probe
AppVersion={#ProbeVersion}
DefaultDirName={autopf}\Codon Protein Factory Installer Probe
OutputDir={#OutputDirectory}
OutputBaseFilename=InstallerProbe-{#ProbeVersion}-win-x64
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.26200
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{commonprograms}\Codon Protein Factory Installer Probe"; Filename: "{app}\InstallerProbe.exe"

#include "SetupPrerequisites.iss"
