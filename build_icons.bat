@echo off
setlocal

if not exist bin mkdir bin

call odin run tools\gen_icons.odin -file -out:"bin\gen_icons.exe" -vet || exit /b 1
