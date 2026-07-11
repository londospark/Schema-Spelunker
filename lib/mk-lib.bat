@echo off
REM mk-lib.bat — Generate sqlite3.lib from sqlite3.def using MSVC lib.exe
REM
REM Locates the newest Visual Studio with C++ tools (Insider 2025 first,
REM then 2022) and calls vcvarsall.bat to set up the environment before
REM running lib.exe.
REM
REM Prerequisites: Visual Studio 2022 / 2025+ or Build Tools with
REM "Desktop development with C++" workload installed.

setlocal enabledelayedexpansion

set "DEF_FILE=%~dp0sqlite3.def"
set "LIB_FILE=%~dp0sqlite3.lib"

if not exist "%DEF_FILE%" (
    echo Error: %DEF_FILE% not found.
    exit /b 1
)

REM --- Detect native architecture for vcvarsall ---
set "VCVARS_ARCH=x86"
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "VCVARS_ARCH=amd64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "VCVARS_ARCH=arm64"

REM --- Try to locate and call vcvarsall.bat ---
set "VCVARS_FOUND="

REM Method 1: vswhere — try newest prerelease (Insider) first, then stable
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    REM 1a: Newest installation including prerelease (e.g. VS 2025 Insider)
    if not defined VCVARS_FOUND (
        for /f "usebackq delims=" %%p in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -prerelease -property installationPath 2^>nul`) do (
            set "VCVARS_BAT=%%p\VC\Auxiliary\Build\vcvarsall.bat"
            if exist "!VCVARS_BAT!" (
                echo Found: !VCVARS_BAT!
                call "!VCVARS_BAT!" %VCVARS_ARCH% >nul 2>nul
                if not errorlevel 1 set "VCVARS_FOUND=1"
            )
        )
    )
    REM 1b: Newest stable installation (e.g. VS 2022)
    if not defined VCVARS_FOUND (
        for /f "usebackq delims=" %%p in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do (
            set "VCVARS_BAT=%%p\VC\Auxiliary\Build\vcvarsall.bat"
            if exist "!VCVARS_BAT!" (
                echo Found: !VCVARS_BAT!
                call "!VCVARS_BAT!" %VCVARS_ARCH% >nul 2>nul
                if not errorlevel 1 set "VCVARS_FOUND=1"
            )
        )
    )
)

REM Method 2: Common VS 2022 fallback paths (if vswhere missing or failed)
if not defined VCVARS_FOUND (
    for %%e in ("Community" "Professional" "Enterprise" "BuildTools") do (
        if not defined VCVARS_FOUND (
            set "VCVARS_BAT=%ProgramFiles%\Microsoft Visual Studio\2022\%%~e\VC\Auxiliary\Build\vcvarsall.bat"
            if exist "!VCVARS_BAT!" (
                echo Found: !VCVARS_BAT!
                call "!VCVARS_BAT!" %VCVARS_ARCH% >nul 2>nul
                if not errorlevel 1 set "VCVARS_FOUND=1"
            )
        )
    )
)

REM Method 3: ProgramFiles(x86) fallback
if not defined VCVARS_FOUND (
    for %%e in ("Community" "Professional" "Enterprise" "BuildTools") do (
        if not defined VCVARS_FOUND (
            set "VCVARS_BAT=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\%%~e\VC\Auxiliary\Build\vcvarsall.bat"
            if exist "!VCVARS_BAT!" (
                echo Found: !VCVARS_BAT!
                call "!VCVARS_BAT!" %VCVARS_ARCH% >nul 2>nul
                if not errorlevel 1 set "VCVARS_FOUND=1"
            )
        )
    )
)

if not defined VCVARS_FOUND (
    echo Error: Could not locate vcvarsall.bat. Make sure Visual Studio 2022
    echo        or later with "Desktop development with C++" is installed.
    exit /b 1
)

REM --- Verify lib.exe is now on PATH ---
where lib.exe >nul 2>nul
if errorlevel 1 (
    echo Error: lib.exe not found even after vcvarsall.bat.
    exit /b 1
)

REM --- Run lib.exe to create the import library ---
echo Creating %LIB_FILE% from %DEF_FILE% ^(%VCVARS_ARCH%^) ...
lib /def:"%DEF_FILE%" /out:"%LIB_FILE%" /machine:%VCVARS_ARCH% /nologo
if errorlevel 1 (
    echo Error: lib.exe failed.
    exit /b 1
)

echo Done.
exit /b 0
