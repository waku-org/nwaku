#!/bin/sh

# Regexp for grep to only choose some file extensions for formatting
exts="\.\(nim\|nims\)$"

# The formatter to use
formatter=`which nph`

# Check availability of the formatter
if [ -z "$formatter" ]
then
  1>&2 echo "$formatter not found. Pre-commit formatting will not be done."
  exit 0
fi

# Format staged files
git diff --cached --name-only --diff-filter=ACMR | grep "$exts" | while read file; do
  echo "Formatting $file"
  "$formatter" "$file"
  git add "$file"
done

