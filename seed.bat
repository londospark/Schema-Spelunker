@echo off
setlocal

if not exist bin mkdir bin
odin build test -out:"bin\seed.exe" || exit /b 1
bin\seed.exe seed.db