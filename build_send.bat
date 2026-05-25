@echo off
setlocal EnableDelayedExpansion

echo ============================================
echo   QNote APK Build
echo ============================================
echo.

set "PROJECT_ROOT=%~dp0"
set "BUILD_PATH=%PROJECT_ROOT%build\app\outputs\flutter-apk\app-release.apk"

for /f %%i in ('powershell -Command "Get-Date -Format 'yyyyMMdd-HHmm'"') do set "TIMESTAMP=%%i"
set "APK_NAME=qnote-%TIMESTAMP%.apk"

echo [1/2] Building APK...
call flutter build apk --release
if errorlevel 1 (
    echo.
    echo [ERROR] APK build failed!
    pause
    exit /b 1
)

echo.
echo [2/2] Copying APK...
if exist "%BUILD_PATH%" (
    copy "%BUILD_PATH%" "%PROJECT_ROOT%%APK_NAME%" >nul
    echo Project root: %PROJECT_ROOT%%APK_NAME%
    
    copy "%BUILD_PATH%" "%PROJECT_ROOT%..\%APK_NAME%" >nul
    echo Parent folder: %PROJECT_ROOT%..\%APK_NAME%
) else (
    echo [ERROR] Build output not found: %BUILD_PATH%
    pause
    exit /b 1
)

echo.
echo ============================================
echo   Done!
echo ============================================
pause
