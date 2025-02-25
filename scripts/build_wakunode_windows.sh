#!/bin/bash


# 1. Install Git Bash terminal  
#    Download and install it from: https://git-scm.com/download/win  
#  
# 2. Install MSYS2  
#    a. Download the installer from: https://www.msys2.org  
#    b. Run the installer and make sure it's installed at "C:\" because we explicitly set the PATH accordingly (NOTE: the default location is C:\).  
#    c. The msys64 directory contains multiple terminals; you need to use the ucrt64 terminal to install all packages and libraries.  
#  
# 3. Open the MSYS2 MINGW64 terminal and run the following commands to install the required dependencies:  
#  
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
# 4. Run the Script  
#    Open Git Bash with administrative privileges and run the required script.  
#  
# 5. If multiple commands fail at the end, there may be an issue. ( 1 failed is expected )
#  
# 6. Troubleshooting: Build Issues  
#    If "wakunode2.exe" is not generated, there could be different issues.  
#  
#    1. Missing required dependencies  
#       - Check if they are installed by running:  
#         ``which make cmake gcc g++ rustc cargo python3 upx``
#       
#       - If any dependency is missing, you may have skipped a package in Step 3 or installed MSYS2 in a location other than the C: drive.
#
#  
#    2. Conflicts with a previous installation  
#       - Remove any existing MinGW installations.  
#       - If you already have MSYS2 and Git Bash installed, remove them and perform a fresh installation.  
#
#----------------------------------------------------------------------------------------------------------------------------------------------------------------------


echo "Windows Setup Script"
echo "===================="

success_count=0
failure_count=0

# Function to execute a command and check its status
execute_command() {
    echo "Executing: $1"
    if eval "$1"; then
        echo -e "✓ Command succeeded \n"
        ((success_count++))
    else
        echo -e "✗ Command failed \n"
        ((failure_count++))
    fi
}

echo "0. Set PATH"
execute_command "export PATH="/c/msys64/usr/bin:/c/msys64/usr/lib:/c/msys64/ucrt64/bin:/c/msys64/ucrt64/lib:/c/msys64/mingw64/bin:/c/msys64/mingw64/lib:$PATH""

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
cp ./vendor/libunwind/build/lib/libunwind.a install/usr/lib
cd ../../

echo "5. Building miniupnpc"
cd vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc
execute_command "git checkout little_chore_windows_support"
execute_command "make -f Makefile.mingw CC=gcc CXX=g++ libminiupnpc.a V=1"
cd ../../../../..

echo "6. Building libnatpmp"
cd ./vendor/nim-nat-traversal/vendor/libnatpmp-upstream
execute_command "make CC="gcc -fPIC -D_WIN32_WINNT=0x0600 -DNATPMP_STATICLIB" libnatpmp.a V=1"
cd ../../../../

echo "7. Building wakunode2"
execute_command "make wakunode2 LOG_LEVEL=DEBUG V=1 -j8"

echo "Windows setup completed successfully!"
echo "✓ Successful commands: $success_count"
echo "✗ Failed commands: $failure_count"
