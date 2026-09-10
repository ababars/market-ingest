#!/usr/bin/env bash
# Exercises the idempotency primitives without needing root or a server.
set -Eeuo pipefail
SANDBOX="$(mktemp -d)"
export STATE_DIR="$SANDBOX/state" LOG_DIR="$SANDBOX/log" NO_COLOR=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

fail=0
assert() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1: got '$2', want '$3'"; fail=1; fi; }

echo "== write_file"
write_file "$SANDBOX/a.conf" 0644 <<<"hello" >/dev/null
assert "first write sets FILE_CHANGED" "$FILE_CHANGED" "1"
assert "content"                       "$(cat "$SANDBOX/a.conf")" "hello"
assert "mode"                          "$(stat -c %a "$SANDBOX/a.conf")" "644"

write_file "$SANDBOX/a.conf" 0644 <<<"hello" >/dev/null
assert "rewrite of identical content is a no-op" "$FILE_CHANGED" "0"
assert "no backup created on no-op" "$(find "$STATE_DIR/backups" -name 'a.conf.*' 2>/dev/null | wc -l)" "0"

write_file "$SANDBOX/a.conf" 0644 <<<"world" >/dev/null
assert "changed content sets FILE_CHANGED" "$FILE_CHANGED" "1"
assert "backup kept (in STATE_DIR, not beside the file)" "$(find "$STATE_DIR/backups" -name 'a.conf.*' 2>/dev/null | wc -l)" "1"
assert "original dir not polluted" "$(ls "$SANDBOX"/a.conf.bak.* 2>/dev/null | wc -l)" "0"

write_file "$SANDBOX/deep/nested/b.conf" 0600 <<<"x" >/dev/null
assert "creates parent dirs" "$(cat "$SANDBOX/deep/nested/b.conf")" "x"
assert "restrictive mode"    "$(stat -c %a "$SANDBOX/deep/nested/b.conf")" "600"

echo "== set -e survival (the false && true idiom used all over the steps)"
probe() { (( FILE_CHANGED )) && changed=1; echo "survived"; }
FILE_CHANGED=0 changed=0
assert "no-op branch does not abort under set -e" "$(probe)" "survived"

echo "== state markers"
assert "not done initially" "$(is_done swapfile && echo y || echo n)" "n"
mark_done swapfile
assert "done after mark"    "$(is_done swapfile && echo y || echo n)" "y"

echo "== replace_block"
printf 'keep-me\n' > "$SANDBOX/.bashrc"
replace_block "$SANDBOX/.bashrc" prompt 'export A=1' >/dev/null
assert "block appended once" "$(grep -c 'export A=1' "$SANDBOX/.bashrc")" "1"
assert "existing content kept" "$(grep -c 'keep-me' "$SANDBOX/.bashrc")" "1"

replace_block "$SANDBOX/.bashrc" prompt 'export A=1' >/dev/null
assert "idempotent re-run" "$FILE_CHANGED" "0"
assert "still exactly one block" "$(grep -c '>>> vps-provision:prompt >>>' "$SANDBOX/.bashrc")" "1"

replace_block "$SANDBOX/.bashrc" prompt 'export A=2' >/dev/null
assert "content replaced, not duplicated" "$(grep -c 'export A=' "$SANDBOX/.bashrc")" "1"
assert "new value"                        "$(grep -c 'export A=2' "$SANDBOX/.bashrc")" "1"
assert "unrelated line survived"          "$(grep -c 'keep-me' "$SANDBOX/.bashrc")" "1"

replace_block "$SANDBOX/.bashrc" other 'export B=1' >/dev/null
assert "second tag coexists" "$(grep -c '>>> vps-provision:' "$SANDBOX/.bashrc")" "2"

echo "== pkg_installed (against the real local dpkg)"
assert "bash is installed"        "$(pkg_installed bash && echo y || echo n)" "y"
assert "nonsense pkg is not"      "$(pkg_installed no-such-pkg-xyz && echo y || echo n)" "n"

rm -rf "$SANDBOX"
echo
[[ $fail -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
