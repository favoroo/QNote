@echo off
setlocal EnableDelayedExpansion

echo ============================================
echo   QNote APK Build and Send Email
echo ============================================
echo.

set "PROJECT_ROOT=%~dp0"
set "BUILD_DIR=%PROJECT_ROOT%build\app\outputs\flutter-apk"

for /f %%i in ('powershell -Command "Get-Date -Format 'yyyyMMdd-HHmm'"') do set "TIMESTAMP=%%i"

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
set "OUTPUT_PATH=%PROJECT_ROOT%..\%APK_NAME%"

if exist "%SRC_APK%" (
    copy "%SRC_APK%" "%OUTPUT_PATH%" >nul
    echo Output: %OUTPUT_PATH%
) else (
    echo [ERROR] Build output not found: %SRC_APK%
    exit /b 1
)

echo.
echo [3/3] Sending email...
powershell -ExecutionPolicy Bypass -File "%PROJECT_ROOT%send_email.ps1" "%OUTPUT_PATH%" "%TIMESTAMP%"

echo.
echo ============================================
echo   Done!
echo ============================================