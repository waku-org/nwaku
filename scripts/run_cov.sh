#!/bin/sh

# Check if env.sh has been loaded, or if this file is being ran from it.
# Using NIMC as a proxy for this, as it's defined in the nimbus-build-system's env.sh.
if [ -z "$NIMC" ]
then
    echo "[ERROR] This tool can only be ran from the Nimbus environment. Either:" 
    echo "- Source env.sh 'source /path/to/env.sh', and then run the script directly '/path/to/scripts/run_cov.sh'." 
    echo "- Run this script as a parameter to env.sh '/path/to/env.sh /path/to/scripts/run_cov.sh'."
    exit 1
fi

# Check for lcov tool
which lcov 1>/dev/null 2>&1
if [ $? != 0 ]
then
    echo "[ERROR] You need to have lcov installed in order to generate the test coverage report."
    exit 2
fi

SCRIPT_PATH=$(dirname "$(realpath -s "$0")")
REPO_ROOT=$(dirname $SCRIPT_PATH)
generated_not_to_break_here="$REPO_ROOT/generated_not_to_break_here"

if [ "$1" != "-y" ] && [ -f "$generated_not_to_break_here" ]
then
    echo "The file '$generated_not_to_break_here' already exists. Do you want to continue? (y/n)"
    read -r response
    if [ "$response" != "y" ]
    then
        exit 3
    fi
fi

output_directory="$REPO_ROOT/coverage_html_report"
base_filepath="$REPO_ROOT/tests/test_all"
nim_filepath=$base_filepath.nim
info_filepath=$base_filepath.info

# Workaround a nim bug. See https://github.com/nim-lang/Nim/issues/12376
touch $generated_not_to_break_here

# Generate the coverage report
nim --debugger:native --passC:--coverage --passL:--coverage --passL:librln_v0.3.4.a --passL:-lm c $nim_filepath
lcov --base-directory . --directory . --zerocounters -q
$base_filepath
lcov --base-directory . --directory . --include "*/waku/**" --include "*/apps/**" --exclude "*/vendor/**" -c -o $info_filepath
genhtml -o $output_directory $info_filepath

# Cleanup
rm -rf $info_filepath $base_filepath nimcache
rm $generated_not_to_break_here
