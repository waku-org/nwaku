#!/usr/bin/env bash

# Output file to store the submodule paths
output_file="submodule_paths.txt"

# Ensure the output file is empty before we start
> "$output_file"

# Convert EXCLUDED_NIM_PACKAGES to an array (splitting by ':')
IFS=':' read -ra EXCLUDED_PATTERNS <<< "$EXCLUDED_NIM_PACKAGES"

# Function to check if a path should be excluded
should_exclude() {
    local path="$1"
    for pattern in "${EXCLUDED_PATTERNS[@]}"; do
        if [[ "$path" == *"$pattern"* ]]; then
            return 0 # Exclude this path
        fi
    done
    return 1 # Keep this path
}

# Find all .gitmodules files and process them
find . -name .gitmodules | while read -r gitmodules_file; do
    # Get the absolute directory path containing the .gitmodules file
    module_dir=$(dirname "$(realpath "$gitmodules_file")")

    # Extract paths from the .gitmodules file
    while IFS= read -r line; do
        if [[ $line =~ path[[:space:]]*=[[:space:]]*(.*) ]]; then
            submodule_path="${BASH_REMATCH[1]}"
            abs_path="$module_dir/$submodule_path"

            # Skip paths that match exclusion patterns
            if should_exclude "$abs_path"; then
                continue
            fi
            # Append /src if it exists in the submodule directory
            if [[ -d "$abs_path/src" ]]; then
                abs_path="$abs_path/src"
            fi

            # Write the absolute path of the submodule to the output file
            echo "$abs_path" >> "$output_file"
        fi
    done < "$gitmodules_file"
done

echo "Submodule paths collected in $output_file"

# Base directory for nimble packages
nimble_pkgs_dir="./vendor/.nimble/pkgs2"

# Ensure the base directory exists
mkdir -p "$nimble_pkgs_dir"

# Read each submodule path and process it
while IFS= read -r submodule_path; do
    if [[ "$submodule_path" == */src ]]; then
        submodule_name=$(basename "$(dirname "$submodule_path")")
    else
        submodule_name=$(basename "$submodule_path")
    fi

    # Check if the submodule directory (without /src) contains at least one .nimble file
    base_dir="${submodule_path%/src}"
    # Check if there is at least one .nimble file in the directory (excluding empty matches)
    nimble_files_count=$(find "$base_dir" -maxdepth 1 -type f -name "*.nimble" | wc -l)

    # Proceed only if there is at least one .nimble file
    if [ "$nimble_files_count" -gt 0 ]; then
        # Create the directory for the submodule
        submodule_dir="$nimble_pkgs_dir/${submodule_name}-#head"
        mkdir -p "$submodule_dir"

        # Create the .nimble-link file with the absolute path
        nimble_link_file="$submodule_dir/${submodule_name}.nimble-link"
        echo "$submodule_path" > "$nimble_link_file"
        echo "$submodule_path" >> "$nimble_link_file"
    fi
done < "$output_file"

echo "Nimble packages prepared in $nimble_pkgs_dir"
