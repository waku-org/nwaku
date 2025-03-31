#!/usr/bin/env bash

# This script is used for building Nix derivation which doesn't allow Git commands.
# It implements similar logic as $(NIMBLE_DIR) target in nimbus-build-system Makefile.

create_nimble_link_script_path="$(pwd)/${BUILD_SYSTEM_DIR}/scripts/create_nimble_link.sh"

process_gitmodules() {
  local gitmodules_file="$1"
  local gitmodules_dir=$(dirname "$gitmodules_file")
  
  # Extract all submodule paths from the .gitmodules file
  grep "path" $gitmodules_file | awk '{print $3}' | while read submodule_path; do
    # Change pwd to the submodule dir and execute script
    pushd "$gitmodules_dir/$submodule_path" > /dev/null
    NIMBLE_DIR=$NIMBLE_DIR PWD_CMD=$PWD_CMD EXCLUDED_NIM_PACKAGES=$EXCLUDED_NIM_PACKAGES \
    "$create_nimble_link_script_path" "$submodule_path"
    popd  > /dev/null
  done
}

# Create the base directory if it doesn't exist
mkdir -p "${NIMBLE_DIR}/pkgs"

# Find all .gitmodules files and process them
for gitmodules_file in $(find . -name '.gitmodules'); do
  echo "Processing .gitmodules file: $gitmodules_file"
  process_gitmodules "$gitmodules_file"
done