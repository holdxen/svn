@echo off
REM build.bat - One-step build script for subversion (Windows)
REM Usage: build.bat [clean]

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

REM Clean if requested
if "%1"=="clean" (
    echo === Cleaning ===
    if exist build rmdir /s /q build
    if exist .xmake rmdir /s /q .xmake
)

REM Step 1: Build serf and install dependencies
echo === Step 1: Building dependencies and serf ===
xmake build -y svn-build
if %errorlevel% neq 0 (
    echo ERROR: Step 1 failed ^(xmake build^)
    exit /b %errorlevel%
)

REM Step 2: Install subversion
echo.
echo === Step 2: Installing subversion ===
xmake require -y subversion
if %errorlevel% neq 0 (
    echo ERROR: Step 2 failed ^(xmake require^)
    exit /b %errorlevel%
)

REM Step 3: Install all to build/install
echo.
echo === Step 3: Installing to build/install ===
xmake install -y subversion-install
if %errorlevel% neq 0 (
    echo ERROR: Step 3 failed ^(xmake install^)
    exit /b %errorlevel%
)

echo.
echo ============================================================
echo Build complete!
echo Output: %SCRIPT_DIR%build\install
echo.
echo Usage:
echo   %SCRIPT_DIR%build\install\bin\svn.exe --version
echo ============================================================
