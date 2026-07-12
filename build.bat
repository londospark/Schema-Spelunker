@echo off
setlocal enabledelayedexpansion

set BUILD_DIR=bin
set EXE_NAME=schema_spelunker.exe
set OUT=%BUILD_DIR%\%EXE_NAME%
set DLL_SRC=sqlite3\sqlite3.dll
set DLL_DST=%BUILD_DIR%\sqlite3.dll
set BUILD_FLAGS=-vet
set DO_RUN=

:: --- Parse arguments ---
:parse
if "%~1"=="" goto :done_parse
if /i "%~1"=="run"    set DO_RUN=1
if /i "%~1"=="release" set BUILD_FLAGS=-o:speed
if /i "%~1"=="clean"   goto :clean
shift
goto :parse
:done_parse

:: --- Clean ---
if not exist "%BUILD_DIR%" goto :after_clean
:clean
if exist "%BUILD_DIR%" (
    echo Cleaning "%BUILD_DIR%"...
    rmdir /s /q "%BUILD_DIR%"
)
if "%~1"=="" (
    if "%DO_RUN%"=="" exit /b 0
)
:after_clean

:: --- Ensure output directory ---
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

:: --- Copy DLL only if missing ---
if not exist "%DLL_DST%" (
    if exist "%DLL_SRC%" (
        copy /Y "%DLL_SRC%" "%DLL_DST%" > nul
        echo Copied %DLL_SRC% -^> %DLL_DST%
    ) else (
        echo Error: %DLL_SRC% not found. Make sure you cloned with Git LFS
        echo        or downloaded the file manually.
        exit /b 1
    )
)

:: --- Build ---
echo Building...
call odin build . -out:"%OUT%" %BUILD_FLAGS%
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)
echo Build succeeded: %OUT%

:: --- Run (optional) ---
if defined DO_RUN (
    echo.
    "%OUT%"
)
