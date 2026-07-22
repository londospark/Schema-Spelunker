@echo off
setlocal

set OUT=bin\schema_spelunker.exe

if "%~1"=="clean" ( rmdir /s /q bin 2>nul & rmdir /s /q build 2>nul & exit /b 0 )

if not exist bin mkdir bin

call _compile_libs.bat
if errorlevel 1 exit /b 1

set FLAGS=-vet
if "%~1"=="release" set FLAGS=-o:speed
if "%~1"=="debug" set FLAGS=-o:none -debug

call odin build . -out:"%OUT%" %FLAGS% || exit /b 1

if "%~1"=="run" "%OUT%"