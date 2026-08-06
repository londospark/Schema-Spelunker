@echo off

cl /nologo /O2 /W4 /WX /I vendor/imgui /I vendor/stb tools/gen_icons.c /Fe:bin/gen_icons.exe

bin/gen_icons.exe