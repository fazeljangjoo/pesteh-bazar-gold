; نصب‌کنندهٔ ویندوز «پسته بازار» (Inno Setup 6) — این فایل با UTF-8 BOM ذخیره شده است
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{204092CC-1B33-42AD-936A-E78F297D7C23}
AppName=پسته بازار
AppVersion={#AppVersion}
AppPublisher=پسته بازار
DefaultDirName={autopf}\PestehBazar
DefaultGroupName=پسته بازار
UninstallDisplayName=پسته بازار
UninstallDisplayIcon={app}\pesteh_bazar.exe
OutputDir=..\dist
OutputBaseFilename=PestehBazar-Setup
SetupIconFile=..\windows_assets\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; نصب برای کاربر جاری، بدون نیاز به دسترسی ادمین
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs

[Icons]
Name: "{group}\پسته بازار"; Filename: "{app}\pesteh_bazar.exe"
Name: "{autodesktop}\پسته بازار"; Filename: "{app}\pesteh_bazar.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "ساخت میانبر روی دسکتاپ"; GroupDescription: "میانبرها:"

[Run]
Filename: "{app}\pesteh_bazar.exe"; Description: "اجرای پسته بازار"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // در حالت بی‌صدا (silent) پیش‌فرض «خیر» است و چیزی پاک نمی‌شود
    if MsgBox('آیا اطلاعات برنامه (پایگاه‌داده و تنظیمات روی این کامپیوتر) هم پاک شود؟' + #13#10 +
              'اگر مطمئن نیستید «خیر» را بزنید. اطلاعات شما روی سرور هم ذخیره است ' +
              'و پوشهٔ پشتیبان‌ها در Documents هرگز پاک نمی‌شود.',
              mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(ExpandConstant('{userappdata}\Pesteh Bazar'), True, True, True);
  end;
end;
