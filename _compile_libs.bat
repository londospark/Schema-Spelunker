@echo off
REM Shared helper: ensures native C libs are compiled.
REM Called by build.bat and seed.bat — keeps MSVC detection + compilation in one place.

call :ensure_sqlite
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

:find_msvc
where cl >nul 2>nul && exit /b 0
for /f "delims=" %%i in ('"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find VC\Auxiliary\Build\vcvars64.bat 2^>nul') do call "%%i" >nul
where cl >nul 2>nul && exit /b 0
echo Error: MSVC compiler not found.
echo Install Visual Studio Build Tools from:
echo https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022
exit /b 1
