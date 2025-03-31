#!/usr/bin/env bash

# This script generates `.nimble-link` files and the folder structure typically created by `make update`
# within this repository. It is an alternative to `vendor/nimbus-build-system/scripts/create_nimble_link.sh`,
# designed for execution inside a Nix derivation, where Git commands are not available.

output_file="submodule_paths.txt"

# The EXCLUDED_NIM_PACKAGES variable (defined in the Makefile) contains a colon-separated list of
# submodule paths that should be ignored. We split it into an array for easier matching.
IFS=':' read -ra EXCLUDED_PATTERNS <<< "$EXCLUDED_NIM_PACKAGES"

# Function to check if a given submodule path should be excluded
should_exclude() {
    local path="$1"
    for pattern in "${EXCLUDED_PATTERNS[@]}"; do
        if [[ "$path" == *"$pattern"* ]]; then
            return 0 # Match found, exclude this submodule
        fi
    done
    return 1  # No match, include this submodule
}

# Locate all `.gitmodules` files and extract submodule paths
find . -name .gitmodules | while read -r gitmodules_file; do
    module_dir=$(dirname "$(realpath "$gitmodules_file")")

    while IFS= read -r line; do
        # Extract the submodule path from lines matching `path = /some/path`
        if [[ $line =~ path[[:space:]]*=[[:space:]]*(.*) ]]; then
            submodule_path="${BASH_REMATCH[1]}"
            abs_path="$module_dir/$submodule_path"
            
            # Skip if the submodule is in the excluded list
            if should_exclude "$abs_path"; then
                continue
            fi
            
             # If the submodule contains a `src/` folder, use it as the path
            if [[ -d "$abs_path/src" ]]; then
                abs_path="$abs_path/src"
            fi

            echo "$abs_path" >> "$output_file"
        fi
    done < "$gitmodules_file"
done

echo "Submodule paths collected in $output_file"

# Directory where Nimble packages will be linked
nimble_pkgs_dir="./vendor/.nimble/pkgs"

mkdir -p "$nimble_pkgs_dir"

# Process each submodule path collected earlier
while IFS= read -r submodule_path; do
    # Determine the submodule name from its path
    if [[ "$submodule_path" == */src ]]; then
        submodule_name=$(basename "$(dirname "$submodule_path")")
    else
        submodule_name=$(basename "$submodule_path")
    fi

    # Check if the submodule contains at least one `.nimble` file
    base_dir="${submodule_path%/src}"
    nimble_files_count=$(find "$base_dir" -maxdepth 1 -type f -name "*.nimble" | wc -l)

    if [ "$nimble_files_count" -gt 0 ]; then
        submodule_dir="$nimble_pkgs_dir/${submodule_name}-#head"
        mkdir -p "$submodule_dir"

        nimble_link_file="$submodule_dir/${submodule_name}.nimble-link"
        # `.nimble-link` files require two identical lines for Nimble to recognize them properly
        echo "$submodule_path" > "$nimble_link_file"
        echo "$submodule_path" >> "$nimble_link_file"
    fi
done < "$output_file"

echo "Nimble packages prepared in $nimble_pkgs_dir"

rm "$output_file"
