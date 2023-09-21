#!/bin/sh

# Check for lcov tool
which lcov 1>/dev/null 2>&1
if [ $? != 0 ]
then
    echo "[ERROR] You need to have lcov installed in order to generate the test coverage report."
    exit 1
fi

SCRIPT_PATH=$(dirname "$(realpath -s "$0")")
REPO_ROOT=$(dirname $SCRIPT_PATH)
generated_not_to_break_here="$REPO_ROOT/generated_not_to_break_here"

if [ -f $generated_not_to_break_here ]
then
    echo "The file '$generated_not_to_break_here' already exists. Do you want to continue? (y/n)"
    read -r response
    if [ "$response" != "y" ]
    then
        exit 1
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
