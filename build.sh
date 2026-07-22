#!/bin/sh
set -e

OUT=bin/schema_spelunker

if [ "$1" = "clean" ]; then
    rm -rf bin build
    exit 0
fi

mkdir -p bin

./_compile_libs.sh

FLAGS="-vet"
if [ "$1" = "release" ] || [ "$2" = "release" ]; then
    FLAGS="-o:speed"
fi
if [ "$1" = "debug" ] || [ "$2" = "debug" ]; then
    FLAGS="-o:none -debug"
fi

LINKER="mold"
if [ "$(uname)" = "Darwin" ]; then
    LINKER="lld"
fi

odin build . -out:"$OUT" -linker="$LINKER" $FLAGS

if [ "$1" = "run" ] || [ "$2" = "run" ]; then
    "$OUT"
fi
