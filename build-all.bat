@echo off

fd -g *.slides -x cmd /c zig run compile.zig < {} > {.}.html && echo generated {.}.html

