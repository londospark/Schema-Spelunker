@echo off
setlocal enabledelayedexpansion

set BUILD_DIR=bin
set EXE_NAME=seed.exe
set OUT=%BUILD_DIR%\%EXE_NAME%

:: --- Ensure output directory ---
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

:: --- Build seed tool ---
echo Building seed tool...
call odin build test -out:"%OUT%"
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

:: --- Run seed tool ---
echo Seeding database...
"%OUT%" seed.db

echo Done: seed.db
