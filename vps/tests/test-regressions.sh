#!/usr/bin/env bash
# Regression tests for the SIGPIPE class of bugs. Runs under the same
# `set -Eeuo pipefail` the real scripts use - that is the whole point.
set -Eeuo pipefail
SANDBOX="$(mktemp -d)"
export STATE_DIR="$SANDBOX/state" LOG_DIR="$SANDBOX/log" NO_COLOR=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fail=0
assert() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1: got '$2', want '$3'"; fail=1; fi; }

echo "== gen_password (the one that broke provisioning)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  pw="$(gen_password)"
  [[ ${#pw} -eq 32 ]] || { echo "  FAIL  run $i: length ${#pw}"; fail=1; }
  [[ "$pw" =~ ^[A-Za-z0-9]{32}$ ]] || { echo "  FAIL  run $i: bad charset '$pw'"; fail=1; }
done
assert "10 consecutive runs, 32 alnum chars, no SIGPIPE" "$fail" "0"
assert "successive passwords differ" "$([[ "$(gen_password)" != "$(gen_password)" ]] && echo y || echo n)" "y"

echo "== pkg_installed"
assert "bash installed"       "$(pkg_installed bash && echo y || echo n)" "y"
assert "nonsense not"         "$(pkg_installed no-such-pkg-xyz && echo y || echo n)" "n"
for i in 1 2 3 4 5 6 7 8 9 10; do pkg_installed bash || { echo "  FAIL  flake on run $i"; fail=1; }; done
assert "10 runs, no race" "$fail" "0"

echo "== user_in_group"
me="$(id -un)"; mygrp="$(id -gn)"
assert "own primary group"    "$(user_in_group "$me" "$mygrp" && echo y || echo n)" "y"
assert "bogus group"          "$(user_in_group "$me" no-such-group && echo y || echo n)" "n"
assert "no substring match"   "$(user_in_group "$me" "${mygrp:0:2}" && echo y || echo n)" "n"

echo "== backups land in STATE_DIR, not beside the original"
mkdir -p "$SANDBOX/etc/apt.conf.d"
write_file "$SANDBOX/etc/apt.conf.d/20auto.conf" 0644 <<<"v1" >/dev/null
write_file "$SANDBOX/etc/apt.conf.d/20auto.conf" 0644 <<<"v2" >/dev/null
assert "conf.d dir stays clean" "$(ls "$SANDBOX/etc/apt.conf.d" | tr '\n' ' ')" "20auto.conf "
assert "backup exists in STATE_DIR" "$(find "$STATE_DIR/backups" -name '20auto.conf.*' | wc -l)" "1"
assert "backup holds the OLD content" "$(cat "$(find "$STATE_DIR/backups" -name '20auto.conf.*')")" "v1"

rm -rf "$SANDBOX"
echo
[[ $fail -eq 0 ]] && echo "ALL REGRESSION TESTS PASSED" || { echo "FAILURES"; exit 1; }
