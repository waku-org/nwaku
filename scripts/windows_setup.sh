#!/bin/bash

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
build_component "vendor/nimbus-build-system/vendor/Nim" "./build_all.bat" "Nim"

echo "4. Building miniupnpc"
build_component "vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc" "./mingw32make.bat" "miniupnpc"

echo "5. Building libnatpmp"
build_component "vendor/nim-nat-traversal/vendor/libnatpmp-upstream" "./build.bat" "libnatpmp"

echo "6. Building libunwind"
build_component "vendor/nim-libbacktrace" "make install/usr/lib/libunwind.a" "libunwind"

echo "7. Building wakunode2"
execute_command "make wakunode2 V=1 NIMFLAGS="-d:disableMarchNative -d:postgres -d:chronicles_colors:none" "

echo "Windows setup completed successfully!"
