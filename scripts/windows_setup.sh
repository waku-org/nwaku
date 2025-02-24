#!/bin/bash

# 1. Install Git Bash terminal
#    Download and install from: https://git-scm.com/download/win
#
# 2. Install MSYS2
#    a. Download the installer from: https://www.msys2.org
#    b. Run the installer 
#    c. msys64 directory have mutiple terminal you need to use ucrt64 terminal to install all package and library.
#
# 3. Open MSYS2 MINGW64 terminal and run the following commands to install requirements:
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
# 4. Set Up PATH
#    Note: This guide assumes that you have installed MSYS2 at "C:\".
#    
#    export PATH="/c/msys64/usr/bin:/c/msys64/usr/lib:/c/msys64/ucrt64/bin:/c/msys64/ucrt64/lib:/c/msys64/mingw64/bin:/c/msys64/mingw64/lib:$PATH"
#  
# 5. Verify Prerequisites
#    Before proceeding, ensure that all required dependencies are installed.
#    You can check this by running:
#
#    which make cmake gcc g++ rustc cargo python3 upx
#
#    This step helps avoid script failures due to missing dependencies.
#
# 6. Run the Script
#    Open Git Bash with administrative privileges and run the required script.
#
# 7. Troubleshooting: Build Issues
#    If "wakunode2.exe" is not generated, there might be conflicting installations on your system.
#    This often happens if you already have MinGW installed separately.
#
#    To resolve this:
#    - Remove any existing MinGW installations.
#    - Alternatively, you can completely uninstall Git Bash and MSYS2, then do a fresh installation.

set +e  # Exit immediately if a command exits with a non-zero status

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
if make install/usr/lib/libunwind.a V=1; then
    echo "✓ libunwind.a installed successfully"
else
    echo "⚠️  libunwind installation failed, attempting to copy directly"
    execute_command "make install/usr/lib/libunwind.a V=1"
fi

cd vendor/nim-libbacktrace
cp ./vendor/libunwind/build/lib/libunwind.a install/usr/lib
cd ../../

echo "5. Building miniupnpc"
cd vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc
git checkout little_chore_windows_support
execute_command "make -f Makefile.mingw CC=gcc CXX=g++ libminiupnpc.a V=1"
cd ../../../../..

echo "6. Building libnatpmp"
cd ./vendor/nim-nat-traversal/vendor/libnatpmp-upstream
make CC="gcc -fPIC -D_WIN32_WINNT=0x0600 -DNATPMP_STATICLIB" libnatpmp.a V=1
cd ../../../../

echo "7. Building wakunode2"
execute_command "make wakunode2 LOG_LEVEL=DEBUG V=1 -j8"

echo "Windows setup completed successfully!"
