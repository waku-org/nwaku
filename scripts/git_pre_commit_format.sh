#!/bin/sh

echo "Running pre-commit hook"

# Regexp for grep to only choose some file extensions for formatting
exts="\.\(nim\|nims\)$"

# Build nph lazily
make build-nph || (1>&2 echo "failed to build nph. Pre-commit formatting will not be done."; exit 0)

# Format staged files
git diff --cached --name-only --diff-filter=ACMR | grep "$exts" | while read file; do
  echo "Formatting $file"
  make nph/"$file"
  git add "$file"
done
