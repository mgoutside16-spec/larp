; Установщик LARP Studio для Windows (для текущего пользователя, без прав администратора).
; Игры хранятся отдельно, в %APPDATA%\LARP Studio, и не затрагиваются установкой, обновлением и удалением.
Unicode true
SetCompressor /SOLID lzma

!define APPNAME "Мир Снов для Граней"
!ifndef VERSION
  !define VERSION "1.1.0"
!endif
!define EXE "Мир Снов для Граней.exe"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\LARPStudio"

Name "${APPNAME}"
OutFile "release\Мир-Снов-для-Граней-установка-${VERSION}.exe"
InstallDir "$LOCALAPPDATA\Programs\LARP Studio"
RequestExecutionLevel user
ShowInstDetails nevershow
ShowUninstDetails nevershow
BrandingText "Мастерская «Без правил»"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1049 "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=1049 "FileDescription" "Установщик «Мир Снов для Граней»"
VIAddVersionKey /LANG=1049 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1049 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1049 "CompanyName" "Без правил"
VIAddVersionKey /LANG=1049 "LegalCopyright" "Без правил"

!include "MUI2.nsh"
!define MUI_ICON "build\icon.ico"
!define MUI_UNICON "build\icon.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Установка «Мир Снов для Граней» ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "Мастерская «Без правил» для подготовки ролевых игр.$\r$\n$\r$\nЕсли программа уже установлена, она обновится. Ваши игры при этом сохранятся.$\r$\n$\r$\nПеред продолжением закройте программу, если она открыта."
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Запустить «Мир Снов для Граней»"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"

Function .onInit
  check:
  FindWindow $0 "" "Мир Снов для Граней"
  StrCmp $0 0 done
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Программа «Мир Снов для Граней» сейчас открыта. Закройте её и нажмите «Повтор»." IDRETRY check
  Abort
  done:
FunctionEnd

Section "Install"
  ; Удаляем только файлы прежней версии программы. Игры лежат в другой папке.
  RMDir /r "$INSTDIR\resources"
  RMDir /r "$INSTDIR\locales"
  ; Файлы и ярлыки прежнего названия LARP Studio.
  Delete "$INSTDIR\LARP Studio.exe"
  Delete "$INSTDIR\Удалить программу.exe"
  Delete "$DESKTOP\LARP Studio.lnk"
  RMDir /r "$SMPROGRAMS\LARP Studio"
  SetOutPath "$INSTDIR"
  File /r "release\win-unpacked\*"
  WriteUninstaller "$INSTDIR\Удалить программу.exe"
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\${EXE}" 0
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\${EXE}" 0
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "Без правил"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${EXE}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Удалить программу.exe"'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APPNAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APPNAME}"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "${UNINST_KEY}"
  MessageBox MB_OK|MB_ICONINFORMATION "Программа удалена. Ваши игры сохранены в папке %APPDATA%\LARP Studio — при повторной установке они снова появятся."
SectionEnd
