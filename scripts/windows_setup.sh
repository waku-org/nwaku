#!/bin/sh
echo "1. Downloading submodule"
git submodule update --init --recursive 
mkdir -p tmp

echo "2. Executing build_all.bat for Windows"
BUILD_DIR="vendor/nimbus-build-system/vendor/Nim"

if [ ! -d "$BUILD_DIR" ]; then
    echo "Directory not found: $BUILD_DIR"
else
    cd "$BUILD_DIR" || exit
    ./build_all.bat
    cd ../../../..
fi

LIBUNWIND_DIR="vendor/nim-libbacktrace"

if [ ! -d "$LIBUNWIND_DIR" ]; then
    echo "Directory not found: $LIBUNWIND_DIR"
else
    cd "$LIBUNWIND_DIR" || exit
    make install/usr/lib/libunwind.a
    cd ../..
fi

echo "3. Building wakunode2"

make wakunode2 V=1

