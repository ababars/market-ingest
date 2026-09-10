#!/usr/bin/env bash
# Runs ON THE SERVER. Executes the numbered steps in order, teeing everything
# into /var/log/vps-provision/.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
export TOOLKIT_ROOT="$ROOT"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
require_root

[[ -f "$ROOT/env" ]] || die "missing $ROOT/env (provision.sh should have shipped it)"
set -a; source "$ROOT/env"; set +a

install -d -m 0755 "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/$(date -u +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
ln -sfn "$LOG_FILE" "$LOG_DIR/latest.log"

ALL_STEPS=(00-base 10-user 20-hardening 30-tools 40-docker 50-clickhouse 60-netdata 99-summary)

if (( $# > 0 )); then
  STEPS_TO_RUN=("$@")
else
  STEPS_TO_RUN=("${ALL_STEPS[@]}")
fi

CURRENT_STEP=""
trap 'rc=$?; [[ $rc -ne 0 ]] && printf "\n%s[FAIL]%s step %s exited with %d - see %s\n" "$C_RED" "$C_RESET" "${CURRENT_STEP:-?}" "$rc" "$LOG_FILE" >&2; exit $rc' EXIT

printf '%s%s\n' "$C_BOLD" "=========================================================="
printf 'vps-provision  %s  host=%s  steps=%s\n' "$(date -u +%FT%TZ)" "$(hostname)" "${STEPS_TO_RUN[*]}"
printf '%s%s\n' "==========================================================" "$C_RESET"

for step in "${STEPS_TO_RUN[@]}"; do
  script="$HERE/${step}.sh"
  [[ -f "$script" ]] || die "unknown step: $step (available: ${ALL_STEPS[*]})"
  CURRENT_STEP="$step"
  printf '\n%s%s--- %s %s%s\n' "$C_BOLD" "$C_YLW" "$step" "$(printf '%.0s-' {1..40})" "$C_RESET"
  # Each step is a separate bash process: a step that leaves odd shell state
  # cannot poison the next one.
  bash "$script"
done

CURRENT_STEP=""
printf '\n%s[ ok ]%s all steps completed. Log: %s\n' "$C_GRN" "$C_RESET" "$LOG_FILE"
