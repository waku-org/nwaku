#!/usr/bin/env bash
# Runs every linter, reports ALL failures (not just the first) and finishes
# with a summary of which check failed, why, and how to fix it.
#
#   scripts/lint.sh        or        make lint
#
# Needs `nph` on PATH (make build-nph).
set -u
shopt -s extglob
cd "$(dirname "$0")/.."

NPH=$(command -v nph) || {
  echo "lint: nph not found on PATH: run 'make build-nph' first" >&2
  exit 2
}

failed=()   # names of failed checks
hints=()    # one fix hint per failed check

# run <name> <what it checks> <how to fix> <command...>
run() {
  local name=$1 what=$2 fix=$3
  shift 3
  echo
  echo "=================================================="
  echo "CHECK: ${name}"
  echo "  what: ${what}"
  echo "=================================================="
  if "$@"; then
    echo "-> PASSED: ${name}"
  else
    echo "-> FAILED: ${name}  (details above)"
    failed+=("${name}")
    hints+=("${name}: ${fix}")
  fi
}

run "nph formatting" \
  "every .nim/.nims/.nimble file must be formatted exactly as nph would (files that would change are listed above as 'would reformat')" \
  "run 'make nph/<file>' (or 'nph <file>') on each listed file and commit the result; 'make install-nph' installs a pre-commit hook that does this" \
  "${NPH}" --check examples logos_delivery rest tests tools apps *.@(nim|nims|nimble)

run "metric labels" \
  "Prometheus label values must come from a bounded set (literals/consts); free-form text creates one time series per value" \
  "follow the 'fix:' line under each finding above; reproduce with scripts/check_metric_labels.py" \
  scripts/check_metric_labels.py

echo
echo "=================================================="
if [ ${#failed[@]} -eq 0 ]; then
  echo "LINT PASSED: all checks ok"
  exit 0
fi
echo "LINT FAILED: ${#failed[@]} check(s) failed: ${failed[*]}"
for h in "${hints[@]}"; do
  echo "  * ${h}"
done
echo "=================================================="
exit 1
