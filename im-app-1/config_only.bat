@echo off
rem ============================================================
rem  Config-only helper - NO Flutter needed on this machine.
rem  Edit config\app_build.json (name / package / api / version),
rem  apply the changes to the project files, then push to git.
rem  Codemagic picks it up and builds in the cloud (it also
rem  regenerates icons/splash there via tool/apply_config.dart).
rem
rem  Usage: config_only.bat
rem  NOTE: keep this file pure ASCII - cmd parses .bat by GBK.
rem ============================================================

setlocal
cd /d %~dp0

if not exist "config\app_build.json" (
  echo [FAIL] config\app_build.json not found next to this .bat.
  goto :end
)
if not exist "tool\apply_config_noflutter.ps1" (
  echo [FAIL] tool\apply_config_noflutter.ps1 is MISSING.
  echo   Copy the "tool" folder together with the project.
  goto :end
)

echo ===== config only (no Flutter required) =====
echo.
echo [1/2] opening config\app_build.json ...
echo   Edit the values, then SAVE and CLOSE notepad to continue.
echo   (appName / packageName / iosPackageName / versionName /
echo    versionCode / apiBase / wsBase / jpushAppKey / icon)
start "" /wait notepad "config\app_build.json"

echo [2/2] applying config ...
powershell -NoProfile -ExecutionPolicy Bypass -File "tool\apply_config_noflutter.ps1"
if errorlevel 1 goto :fail

echo.
echo [DONE] Config applied. No APK/IPA was built.
echo   Next steps for Codemagic build:
echo     1. (optional) replace assets\icon\app_icon.png / splash_logo.png
echo        - icons are regenerated in the cloud automatically
echo     2. git commit + push these changed files
echo     3. start the build on codemagic.com (workflow: iOS IPA)
echo   If you changed the icon locally too, config_only.bat CANNOT
echo   regenerate it - the cloud build step handles it.
echo.
goto :end

:fail
echo.
echo [FAILED] config apply returned an error. See messages above.
pause
goto :eof

:end
pause
