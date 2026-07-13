@echo off
REM Shared helper: ensures native C libs are compiled.
REM Called by build.bat and seed.bat — keeps MSVC detection + compilation in one place.

call :ensure_sqlite
if errorlevel 1 exit /b 1

call :ensure_imgui
exit /b %ERRORLEVEL%

:ensure_sqlite
if exist vendor\sqlite3\sqlite3.lib exit /b 0

call :find_msvc
if errorlevel 1 exit /b 1

echo Compiling SQLite from source...
cl /nologo /c /O2 /DSQLITE_THREADSAFE=0 /DSQLITE_OMIT_LOAD_EXTENSION /DSQLITE_DEFAULT_MEMSTATUS=0 vendor\sqlite3\sqlite3.c /Fovendor\sqlite3\sqlite3.obj
if errorlevel 1 exit /b 1
lib /nologo vendor\sqlite3\sqlite3.obj /OUT:vendor\sqlite3\sqlite3.lib
if errorlevel 1 exit /b 1
del vendor\sqlite3\sqlite3.obj
exit /b 0

:ensure_imgui
if exist vendor\imgui\imgui.lib exit /b 0

call :find_msvc
if errorlevel 1 exit /b 1

echo Compiling ImGui + ImNodes + rlImGui from source...

if not exist build\imgui mkdir build\imgui

REM Find raylib header location from Odin's vendor dir
for /f "tokens=*" %%i in ('where odin') do set CACHE_ODIN_DIR=%%~dpi..
set RAYLIB_INC=%CACHE_ODIN_DIR%Odin\vendor\raylib\windows

set IMGUI=vendor\imgui
set RLIMGUI=vendor\rlimgui

set CFLAGS=/std:c++17 /O2 /MP /DIMGUI_ENABLE_DOCKING /DIMGUI_IMPL_API= /DNO_FONT_AWESOME
set INC=/I%IMGUI% /I%RLIMGUI% /I%RLIMGUI%\include /I%RAYLIB_INC%

cl /nologo %CFLAGS% /c %INC% ^
	%IMGUI%\dcimgui.cpp ^
	%IMGUI%\imgui.cpp ^
	%IMGUI%\imgui_demo.cpp ^
	%IMGUI%\imgui_draw.cpp ^
	%IMGUI%\imgui_tables.cpp ^
	%IMGUI%\imgui_widgets.cpp ^
	%IMGUI%\dcimnodes.cpp ^
	%IMGUI%\imnodes.cpp ^
	%RLIMGUI%\rlImGui.cpp ^
	/Fobuild\imgui\

if errorlevel 1 exit /b 1

lib /nologo build\imgui\*.obj /OUT:%IMGUI%\imgui.lib
if errorlevel 1 exit /b 1

rmdir /s /q build\imgui 2>nul
exit /b 0

:find_msvc
where cl >nul 2>nul && exit /b 0
for /f "delims=" %%i in ('"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find VC\Auxiliary\Build\vcvars64.bat 2^>nul') do call "%%i" >nul
where cl >nul 2>nul && exit /b 0
echo Error: MSVC compiler not found.
echo Install Visual Studio Build Tools from:
echo https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022
exit /b 1
