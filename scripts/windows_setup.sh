#!/bin/sh
echo "1. Downloading submodule -------------------------------- "
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

echo "3. Executing build_all.bat for Windows ----------------------------"
BUILD_DIR="vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc"

if [ ! -d "$BUILD_DIR" ]; then
    echo "Directory not found: $BUILD_DIR"
else
    cd "$BUILD_DIR" || exit
    ./mingw32make.bat
    cd ../../../../..
fi

echo "4. Executing build_all.bat for Windows ----------------------------"
BUILD_DIR="vendor/nim-nat-traversal/vendor/libnatpmp-upstream"

if [ ! -d "$BUILD_DIR" ]; then
    echo "Directory not found: $BUILD_DIR"
else
    cd "$BUILD_DIR" || exit
    ./build.bat
    cd ../../../..
fi

echo "5. Building libunwind -----------------------------------"
LIBUNWIND_DIR="vendor/nim-libbacktrace"

if [ ! -d "$LIBUNWIND_DIR" ]; then
    echo "Directory not found: $LIBUNWIND_DIR"
else
    cd "$LIBUNWIND_DIR" || exit
    make install/usr/lib/libunwind.a
    cd ../..
fi

echo "6. Building wakunode2 -----------------------------------"

make wakunode2 V=1

# #!/bin/bash
# 
# set -e  # Exit immediately if a command exits with a non-zero status
# 
# echo "Windows Setup Script"
# echo "===================="
# 
# # Function to execute a command and check its status
# execute_command() {
#     echo "Executing: $1"
#     if $1; then
#         echo "✓ Command succeeded"
#     else
#         echo "✗ Command failed"
#         exit 1
#     fi
# }
# 
# # Function to change directory safely
# change_directory() {
#     echo "Changing to directory: $1"
#     if cd "$1"; then
#         echo "✓ Changed directory successfully"
#     else
#         echo "✗ Failed to change directory"
#         exit 1
#     fi
# }
# 
# echo "1. Updating submodules"
# execute_command "git submodule update --init --recursive"
# 
# echo "2. Creating tmp directory"
# execute_command "mkdir -p tmp"
# 
# echo "3. Building Nim"
# NIM_BUILD_DIR="vendor/nimbus-build-system/vendor/Nim"
# if [ -d "$NIM_BUILD_DIR" ]; then
#     change_directory "$NIM_BUILD_DIR"
#     execute_command "./build_all.bat"
#     change_directory "../../../.."
# else
#     echo "✗ Nim build directory not found: $NIM_BUILD_DIR"
#     exit 1
# fi
# 
# echo "4. Building miniupnpc"
# MINIUPNPC_BUILD_DIR="vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc"
# if [ -d "$MINIUPNPC_BUILD_DIR" ]; then
#     change_directory "$MINIUPNPC_BUILD_DIR"
#     execute_command "./mingw32make.bat"
#     change_directory "../../../../.."
# else
#     echo "✗ miniupnpc build directory not found: $MINIUPNPC_BUILD_DIR"
#     exit 1
# fi
# 
# echo "5. Building libunwind"
# LIBUNWIND_DIR="vendor/nim-libbacktrace"
# if [ -d "$LIBUNWIND_DIR" ]; then
#     change_directory "$LIBUNWIND_DIR"
#     execute_command "make install/usr/lib/libunwind.a"
#     change_directory "../.."
# else
#     echo "✗ libunwind directory not found: $LIBUNWIND_DIR"
#     exit 1
# fi
# 
# echo "6. Building wakunode2"
# execute_command "make wakunode2 V=1"
# 
# echo "Windows setup completed successfully!"