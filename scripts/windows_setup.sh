#!/bin/bash

# 1. Install Git Bash terminal
#    Download and install from: https://git-scm.com/download/win
#
# 2. Install MSYS2
#    a. Download the installer from: https://www.msys2.org
#    b. Run the installer and follow the installation steps
#
# 3. Open MSYS2 UCRT64 terminal and run the following commands to install requirements:
#    pacman -Syu                                           # Update package database and core packages
#    pacman -S --needed mingw-w64-ucrt-x86_64-toolchain    # Install toolchain
#    pacman -S --needed base-devel                         # Install development tools
#    pacman -S --needed make                               # Install make
#    pacman -S --needed cmake                              # Install cmake
#    pacman -S --needed upx                                # Install upx
#    pacman -S --needed mingw-w64-ucrt-x86_64-rust         # Install rustc
#    pacman -S --needed mingw-w64-ucrt-x86_64-postgresql
#    pacman -S --needed mingw-w64-ucrt-x86_64-gcc 
#    pacman -S --needed mingw-w64-ucrt-x86_64-gcc-libs 
#    pacman -S --needed mingw-w64-ucrt-x86_64-libwinpthread-git 
#    pacman -S --needed mingw-w64-ucrt-x86_64-zlib 
#    pacman -s --needed mingw-w64-ucrt-x86_64-openssl
# 
# 4. Setup PATH 
#    export PATH="/c/msys64/mingw64/bin"    # this is a default, need to change accordingly
#    export PATH="/mingw64/bin"             # this one is mandotory
#
# 5. on git bash terminal run this scripts 

set -e  # Exit immediately if a command exits with a non-zero status

echo "Windows Setup Script"
echo "===================="

# Function to execute a command and check its status
execute_command() {
    echo "Executing: $1"
    if eval "$1"; then
        echo "✓ Command succeeded"
    else
        echo "✗ Command failed"
        exit 1
    fi
}

# Function to change directory safely
change_directory() {
    echo "Changing to directory: $1"
    if cd "$1"; then
        echo "✓ Changed directory successfully"
    else
        echo "✗ Failed to change directory"
        exit 1
    fi
}

# Function to build a component
build_component() {
    local dir="$1"
    local command="$2"
    local name="$3"

    echo "Building $name"
    if [ -d "$dir" ]; then
        change_directory "$dir"
        execute_command "$command"
        change_directory - > /dev/null
    else
        echo "✗ $name directory not found: $dir"
        exit 1
    fi
}

echo "1. Updating submodules"
execute_command "git submodule update --init --recursive"

echo "2. Creating tmp directory"
execute_command "mkdir -p tmp"

echo "3. Building Nim"
cd vendor/nimbus-build-system/vendor/Nim
execute_command "./build_all.bat"
cd ../../../..

echo "4. Building libunwind"
cd vendor/nim-libbacktrace
execute_command "make all V=1"
execute_command "make install/usr/lib/libunwind.a V=1"
cd ../../

echo "5. Building miniupnpc"
cd vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc
git checkout little_chore_windows_support
execute_command "make -f Makefile.mingw CC=gcc CXX=g++ V=1"
cd ../../../../..

echo "6. Building libnatpmp"
cd ./vendor/nim-nat-traversal/vendor/libnatpmp-upstream
execute_command "./build.bat"
execute_command "mv natpmp.a libnatpmp.a"
cd ../../../../

echo "7. Building wakunode2"
execute_command "make wakunode2 LOG_LEVEL=DEBUG"

echo "Windows setup completed successfully!"
