#!/usr/bin/env bash
# Shared helpers for provisioning scripts. Meant to be sourced, not executed.
#
# Core idea: every operation must be safe to run twice. We get that from two
# mechanisms:
#   1. write_file  - renders the desired content, compares with what is on disk,
#                    touches the file only on a real difference (and reports it
#                    via FILE_CHANGED so callers can restart services selectively);
#   2. mark_done   - a state marker under STATE_DIR for genuinely one-shot actions
#                    (creating a swap file, generating a password) that have no
#                    natural "compare and converge" form.

set -Eeuo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m';  C_RED=$'\033[1;31m'
  C_GRN=$'\033[32m';  C_YLW=$'\033[33m'; C_BLU=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BOLD=''
fi

STATE_DIR="${STATE_DIR:-/var/lib/vps-provision}"
LOG_DIR="${LOG_DIR:-/var/log/vps-provision}"

_ts() { date -u '+%H:%M:%S'; }

log()  { printf '%s %s[ .. ]%s %s\n' "$(_ts)" "$C_BLU" "$C_RESET" "$*"; }
ok()   { printf '%s %s[ ok ]%s %s\n' "$(_ts)" "$C_GRN" "$C_RESET" "$*"; }
skip() { printf '%s %s[skip]%s %s%s%s\n' "$(_ts)" "$C_DIM" "$C_RESET" "$C_DIM" "$*" "$C_RESET"; }
warn() { printf '%s %s[warn]%s %s\n' "$(_ts)" "$C_YLW" "$C_RESET" "$*" >&2; }
die()  { printf '%s %s[FAIL]%s %s\n' "$(_ts)" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

section() {
  printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_BLU" "$*" "$C_RESET"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Backups live under STATE_DIR, never next to the original: a stray
# `sshd_config.d/60-hardening.conf.bak.2026...` in a *.conf.d directory is at
# best noise in apt's output and at worst a second config the daemon reads.
backup_file() {
  local path="$1" dest
  dest="$STATE_DIR/backups/${path#/}.$(date -u +%Y%m%d%H%M%S)"
  install -d -m 0700 "$(dirname "$dest")"
  cp -a "$path" "$dest"
}

# ---------------------------------------------------------------- state markers

mark_done() { install -d -m 0755 "$STATE_DIR/done"; date -u +%FT%TZ > "$STATE_DIR/done/$1"; }
is_done()   { [[ -f "$STATE_DIR/done/$1" ]]; }

# ------------------------------------------------------------------------- apt

export DEBIAN_FRONTEND=noninteractive

pkg_installed() {
  local st
  st="$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" || return 1
  [[ "$st" == installed ]]
}

# Same reasoning: `id -nG | tr | grep -q` is three chances for a broken pipe to
# be mistaken for "not a member". Plain string matching has none.
user_in_group() {
  [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]
}

# apt-get update, but at most once per APT_REFRESH_TTL seconds per run of the
# whole toolkit - repeated updates across eight scripts are pure waiting.
apt_refresh() {
  local stamp="$STATE_DIR/apt-refreshed" ttl="${APT_REFRESH_TTL:-1800}" now age
  install -d -m 0755 "$STATE_DIR"
  now=$(date +%s)
  if [[ -f "$stamp" ]]; then
    age=$(( now - $(cat "$stamp") ))
    if (( age < ttl )); then skip "apt index is fresh (${age}s old)"; return 0; fi
  fi
  log "apt-get update"
  apt-get update -qq
  echo "$now" > "$stamp"
}

# Installs only what is actually missing, so a re-run prints one skip line
# instead of scrolling a screen of "already the newest version".
apt_install() {
  local missing=() p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  if (( ${#missing[@]} == 0 )); then
    skip "packages present: $*"
    return 0
  fi
  apt_refresh
  log "installing: ${missing[*]}"
  apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
  ok "installed: ${missing[*]}"
}

# Adds a third-party apt repository with a keyring in the modern signed-by form
# (never apt-key, which is deprecated and trusts the key for every repo).
#   add_apt_repo <name> <key-url> <sources-line>
add_apt_repo() {
  local name="$1" key_url="$2" line="$3"
  local keyring="/usr/share/keyrings/${name}.gpg"
  local list="/etc/apt/sources.list.d/${name}.list"
  local changed=0

  if [[ ! -s "$keyring" ]]; then
    log "fetching signing key for $name"
    curl -fsSL --retry 3 "$key_url" | gpg --dearmor --yes -o "$keyring"
    chmod 0644 "$keyring"
    changed=1
  else
    skip "keyring present: $keyring"
  fi

  write_file "$list" 0644 <<<"$line"
  (( FILE_CHANGED )) && changed=1

  if (( changed )); then
    rm -f "$STATE_DIR/apt-refreshed"
    apt_refresh
  fi
}

# ----------------------------------------------------------------------- files

# write_file <path> [mode]   -- content on stdin
# Sets FILE_CHANGED=1 when the file was actually created or modified.
# Always returns 0 so it is safe under `set -e` without an `|| true` dance.
FILE_CHANGED=0
write_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  install -d -m 0755 "$(dirname "$path")"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; FILE_CHANGED=0; skip "unchanged: $path"; return 0
  fi
  [[ -f "$path" ]] && backup_file "$path"
  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"; FILE_CHANGED=1; ok "written: $path"
}

# Same, but the file belongs to a user (dotfiles).
write_user_file() {
  local user="$1" path="$2" mode="${3:-0644}"
  write_file "$path" "$mode"
  chown "$user:$(id -gn "$user")" "$path"
}

# --------------------------------------------------------------------- systemd

svc_enable_start() {
  local svc="$1"
  systemctl enable --quiet --now "$svc" 2>/dev/null || systemctl enable "$svc" >/dev/null 2>&1
  systemctl is-active --quiet "$svc" || systemctl start "$svc"
  ok "service running: $svc"
}

svc_restart() {
  local svc="$1"
  log "restarting $svc"
  systemctl restart "$svc"
  systemctl is-active --quiet "$svc" || die "$svc failed to start (journalctl -u $svc -n 50)"
  ok "service running: $svc"
}

# Waits for a TCP port on localhost to accept connections.
wait_port() {
  local port="$1" tries="${2:-30}" i
  for ((i = 0; i < tries; i++)); do
    if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

require_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

# NB: no pipeline here on purpose. `tr ... | head -c 32` looks natural but
# head closes the pipe after 32 bytes, tr dies of SIGPIPE (141), and `pipefail`
# turns that into a failed command. Feeding tr a finite input instead means
# nothing ever gets a broken pipe.
gen_password() {
  local raw
  raw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 4096 /dev/urandom))"
  printf '%s' "${raw:0:32}"
}

# ------------------------------------------------------------ managed blocks

# remove_block <file> <tag>  -- drops a managed region entirely, markers and all.
# Needed when a block is renamed: replace_block only ever touches its own tag,
# so without this a rename leaves the old region behind as a live orphan.
remove_block() {
  local file="$1" tag="$2"
  local b="# >>> vps-provision:${tag} >>>"
  local e="# <<< vps-provision:${tag} <<<"
  FILE_CHANGED=0
  [[ -f "$file" ]] || return 0
  grep -qxF "$b" "$file" || return 0
  local tmp; tmp="$(mktemp)"
  awk -v b="$b" -v e="$e" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    !inblock { print }
  ' "$file" > "$tmp"
  backup_file "$file"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  FILE_CHANGED=1
  ok "removed stale block: $file [$tag]"
}

# replace_block <file> <tag> <content>
# Keeps a fenced, re-writable region inside a file we do not own (~/.bashrc and
# friends). Re-running replaces the region instead of appending a second copy.
# Sets FILE_CHANGED like write_file.
replace_block() {
  local file="$1" tag="$2" content="$3"
  local b="# >>> vps-provision:${tag} >>>"
  local e="# <<< vps-provision:${tag} <<<"
  local tmp out
  [[ -f "$file" ]] || { install -d -m 0755 "$(dirname "$file")"; : > "$file"; }
  tmp="$(mktemp)"; out="$(mktemp)"
  awk -v b="$b" -v e="$e" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    !inblock { print }
  ' "$file" > "$tmp"
  { printf '%s\n' "$(cat "$tmp")"; printf '\n%s\n%s\n%s\n' "$b" "$content" "$e"; } > "$out"
  if cmp -s "$out" "$file"; then
    rm -f "$tmp" "$out"; FILE_CHANGED=0; skip "unchanged: $file"; return 0
  fi
  backup_file "$file"
  cat "$out" > "$file"
  rm -f "$tmp" "$out"; FILE_CHANGED=1; ok "updated: $file [$tag]"
}
