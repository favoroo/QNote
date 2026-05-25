@echo off
setlocal EnableDelayedExpansion

echo ============================================
echo   QNote APK Build and Install via ADB
echo ============================================
echo.

set "PROJECT_ROOT=%~dp0"
set "BUILD_DIR=%PROJECT_ROOT%build\app\outputs\flutter-apk"

echo [1/3] Building APK (arm64-v8a)...
call flutter build apk --release --target-platform android-arm64
if errorlevel 1 (
    echo.
    echo [ERROR] APK build failed!
    exit /b 1
)

echo.
echo [2/3] Copying APK to parent folder...
set "SRC_APK=%BUILD_DIR%\app-arm64-v8a-release.apk"
set "APK_NAME=qnote.apk"

if exist "%SRC_APK%" (
    copy "%SRC_APK%" "%PROJECT_ROOT%..\%APK_NAME%" >nul
    echo Output: %PROJECT_ROOT%..\%APK_NAME%
) else (
    echo [ERROR] Build output not found: %SRC_APK%
    exit /b 1
)

echo.
echo [3/3] Installing via ADB...
adb devices
echo.
adb install -r "%PROJECT_ROOT%..\%APK_NAME%"
if errorlevel 1 (
    echo.
    echo [ERROR] ADB install failed! Make sure your phone is connected and USB debugging is enabled.
    exit /b 1
)

echo.
echo ============================================
echo   Done! APK installed to device.
echo ============================================