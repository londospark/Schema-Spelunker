@echo off
REM Regenerate dcimgui C wrapper from vendored imgui.h using dear_bindings.
REM Run this after updating the ImGui version.
REM Requires: Python 3, git clone access to github.com/dearimgui/dear_bindings

setlocal

set VENDOR=%~dp0
set DEPS=%VENDOR%..\..\build\deps
set DEAR_BINDINGS_TAG=DearBindings_v0.21_ImGui_v1.92.8-docking

REM Check Python
python --version >nul 2>nul || python3 --version >nul 2>nul || (
	echo Error: Python 3 not found. Install from https://www.python.org/
	exit /b 1
)

REM Clone dear_bindings if not already present
if not exist "%DEPS%\dear_bindings" (
	echo Cloning dear_bindings...
	mkdir "%DEPS%" 2>nul
	git clone --depth 1 --branch %DEAR_BINDINGS_TAG% https://github.com/dearimgui/dear_bindings.git "%DEPS%\dear_bindings"
)

REM Find Python executable
where python >nul 2>nul && set PY=python || set PY=python3

REM Generate dcimgui from imgui.h
echo Generating dcimgui from imgui.h...
%PY% "%DEPS%\dear_bindings\dear_bindings.py" --nogeneratedefaultargfunctions -o "%VENDOR%dcimgui" "%VENDOR%imgui.h"
if errorlevel 1 exit /b 1

echo Fixing Odin binding link-prefixes for underscore-namespaced functions...
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%VENDOR%fix_foreign_prefixes.ps1" "%VENDOR%imgui.odin"
if errorlevel 1 exit /b 1

echo Done. Generated files:
dir "%VENDOR%dcimgui*" /b
