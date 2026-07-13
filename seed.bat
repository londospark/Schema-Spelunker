@echo off
setlocal

if not exist bin mkdir bin

call _compile_libs.bat
if errorlevel 1 exit /b 1

call odin build test -out:"bin\seed.exe" || exit /b 1
bin\seed.exe seed.db