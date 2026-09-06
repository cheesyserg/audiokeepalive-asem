@echo off
if not exist bin mkdir bin

rem Build the application
nasm -f win64 main.asm -o main.obj
windres resource.rc -O coff -o manifest.res
gcc -mwindows main.obj manifest.res -o bin\AudioKeepAlive.exe -Os -s -Wl,--strip-all -Wl,--gc-sections -Wl,--no-insert-timestamp -Wl,--subsystem,windows -lwinmm -lshell32 -ladvapi32 -luser32 -lkernel32

rem Clean up intermediate files
del main.obj
del manifest.res

rem Optional: Remove debug files if any
if exist main.asm.dbg del main.asm.dbg
if exist main.asm.map del main.asm.map

echo Build complete. Binary placed in bin\AudioKeepAlive.exe
