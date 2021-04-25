#!/usr/bin/env sh

nim c --skipParentCfg libwaku.nim
gcc libwaku.c ./libwaku.a -lm -g -o libwaku
