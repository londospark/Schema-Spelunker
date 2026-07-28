@echo off
setlocal

if not exist bin mkdir bin

call _compile_libs.bat
if errorlevel 1 exit /b 1

if /i "%~1"=="huge" (
	call odin build test\huge_seed.odin -out:"bin\huge_seed.exe" || exit /b 1
	bin\huge_seed.exe huge.db
) else (
	call odin build test -out:"bin\seed.exe" || exit /b 1
	bin\seed.exe seed.db
)