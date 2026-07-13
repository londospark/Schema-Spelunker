@echo off
setlocal

set OUT=bin\schema_spelunker.exe

if "%~1"=="clean" ( rmdir /s /q bin & exit /b 0 )

if not exist bin mkdir bin
if not exist bin\sqlite3.dll copy sqlite3\sqlite3.dll bin\ > nul

set FLAGS=-vet
if "%~1"=="release" set FLAGS=-o:speed

odin build . -out:"%OUT%" %FLAGS% || exit /b 1

if "%~1"=="run" "%OUT%"