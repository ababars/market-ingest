#!/usr/bin/env bash
# Runs every test in this directory. No root, no server, no network required.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$HERE"/test-*.sh; do
  echo "### $(basename "$t")"
  bash "$t" || fail=1
  echo
done
[[ $fail -eq 0 ]] && echo "ALL SUITES PASSED" || { echo "SUITE FAILURES"; exit 1; }
