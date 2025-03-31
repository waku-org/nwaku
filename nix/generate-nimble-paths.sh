#!/usr/bin/env bash

# Output file to store the submodule paths
output_file="submodule_paths.txt"

# Ensure the output file is empty before we start
> "$output_file"

# Find all .gitmodules files and process them
find . -name .gitmodules | while read -r gitmodules_file; do
    # Get the absolute directory path containing the .gitmodules file
    module_dir=$(dirname "$(realpath "$gitmodules_file")")
    
    # Extract paths from the .gitmodules file
    while IFS= read -r line; do
        if [[ $line =~ path[[:space:]]*=[[:space:]]*(.*) ]]; then
            submodule_path="${BASH_REMATCH[1]}"
            # Write the absolute path of the submodule to the output file
            echo "$module_dir/$submodule_path" >> "$output_file"
        fi
    done < "$gitmodules_file"
done

echo "Submodule paths collected in $output_file"

# Base directory for nimble packages
nimble_pkgs_dir="./vendor/.nimble/pkgs"

# Ensure the base directory exists
mkdir -p "$nimble_pkgs_dir"

# Read each submodule path and process it
while IFS= read -r submodule_path; do
    # Extract the submodule name (last part of the path)
    submodule_name=$(basename "$submodule_path")
    
    # Create the directory for the submodule
    submodule_dir="$nimble_pkgs_dir/${submodule_name}-#head"
    mkdir -p "$submodule_dir"
    
    # Create the .nimble-link file with the absolute path
    nimble_link_file="$submodule_dir/${submodule_name}.nimble-link"
    echo "$submodule_path" > "$nimble_link_file"
    echo "$submodule_path" >> "$nimble_link_file"
done < "$output_file"

echo "Nimble packages prepared in $nimble_pkgs_dir"