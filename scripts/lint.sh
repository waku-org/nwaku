#!/usr/bin/env bash
# Runs every linter and reports all failures, not just the first.
#
#   scripts/lint.sh            # nph formatting check + metric labels
#
# Needs `nph` on PATH (make build-nph).
set -u
shopt -s extglob
cd "$(dirname "$0")/.."

status=0
run() {
  local name=$1
  shift
  echo "::group::${name}"
  if "$@"; then
    echo "${name}: ok"
  else
    echo "::error::${name} failed"
    status=1
  fi
  echo "::endgroup::"
}

NPH=$(command -v nph) || { echo "nph not found: run make build-nph" >&2; exit 2; }

run "nph formatting" "${NPH}" --check examples logos_delivery rest tests tools apps *.@(nim|nims|nimble)
run "metric labels" scripts/check_metric_labels.py

exit "${status}"
