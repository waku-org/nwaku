#!/bin/bash

# 1. Install Git Bash terminal
#    Download and install from: https://git-scm.com/download/win
#
# 2. Install MSYS2
#    a. Download the installer from: https://www.msys2.org
#    b. Run the installer 
#    c. inside msys2 directory mutiple terminal you need to use mingw64 terminal all package and library
#
# 3. Open MSYS2 MINGW^$ terminal and run the following commands to install requirements:
#    pacman -Syu --noconfirm
#    pacman -S --noconfirm --needed mingw-w64-x86_64-toolchain
#    pacman -S --noconfirm --needed base-devel
#    pacman -S --noconfirm --needed make                         
#    pacman -S --noconfirm --needed cmake                          
#    pacman -S --noconfirm --needed upx        
#    pacman -S --noconfirm --needed mingw-w64-x86_64-rust
#    pacman -S --noconfirm --needed mingw-w64-x86_64-postgresql
#    pacman -S --noconfirm --needed mingw-w64-x86_64-gcc
#    pacman -S --noconfirm --needed mingw-w64-x86_64-gcc-libs
#    pacman -S --noconfirm --needed mingw-w64-x86_64-libwinpthread-git
#    pacman -S --noconfirm --needed mingw-w64-x86_64-zlib
#    pacman -S --noconfirm --needed mingw-w64-x86_64-openssl
# 
# 4. Setup PATH
#    MSYS_DIR = xyz
#    export PATH="{MSYS_DIR}/msys64/mingw64/bin:$PATH"
#    export PATH="{MSYS_DIR}/msys64/mingw64/lib:$PATH"   
#    export PATH="{MSYS_DIR}/msys64/ucrt64/bin:$PATH"    
#    export PATH="{MSYS_DIR}/msys64/ucrt64/lib:$PATH" 
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
execute_command "make wakunode2 LOG_LEVEL=DEBUG V=1"

echo "Windows setup completed successfully!"
