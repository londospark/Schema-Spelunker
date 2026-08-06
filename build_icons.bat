@echo off

cl /nologo /O2 /I vendor/imgui /I vendor/stb tools/gen_icons.c /Fe:bin/gen_icons.exe

start bin/gen_icons.exe