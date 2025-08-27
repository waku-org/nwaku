#!/bin/sh

echo "- - - - - - - - - - Windows Setup Script - - - - - - - - - -"

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

echo "1. -.-.-.-- Set PATH -.-.-.-"
export PATH="/c/msys64/usr/bin:/c/msys64/mingw64/bin:/c/msys64/usr/lib:/c/msys64/mingw64/lib:$PATH"

echo "2. -.-.-.- Verify dependencies -.-.-.-"
execute_command "which gcc g++ make cmake cargo upx rustc python"

echo "3. -.-.-.- Updating submodules -.-.-.-"
execute_command "git submodule update --init --recursive"

echo "4. -.-.-.- Creating tmp directory -.-.-.-"
execute_command "mkdir -p tmp"

echo "5. -.-.-.- Building Nim -.-.-.-"
cd vendor/nimbus-build-system/vendor/Nim
execute_command "./build_all.bat"
cd ../../../..

echo "6. -.-.-.- Building libunwind -.-.-.-"
cd vendor/nim-libbacktrace
execute_command "make all V=1 -j8"
execute_command "make install/usr/lib/libunwind.a V=1 -j8"
cp ./vendor/libunwind/build/lib/libunwind.a install/usr/lib
cd ../../

echo "7. -.-.-.- Building miniupnpc -.-.-.- "
cd vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc
execute_command "make -f Makefile.mingw CC=gcc CXX=g++ libminiupnpc.a V=1 -j8"
cd ../../../../..

echo "8. -.-.-.- Building libnatpmp -.-.-.- "
cd ./vendor/nim-nat-traversal/vendor/libnatpmp-upstream
make CC="gcc -fPIC -D_WIN32_WINNT=0x0600 -DNATPMP_STATICLIB" libnatpmp.a V=1 -j8
cd ../../../../

echo "9. -.-.-.- Building wakunode2 -.-.-.- "
execute_command "make wakunode2 LOG_LEVEL=DEBUG V=1 -j8"

echo "10. -.-.-.- Building libwaku -.-.-.- "
execute_command "make libwaku STATIC=0 LOG_LEVEL=DEBUG V=1 -j8"

echo "Windows setup completed successfully!"
echo "✓ Successful commands: $success_count"
echo "✗ Failed commands: $failure_count"
