#!/usr/bin/env bash
# Stage 0, runs on the LAPTOP. Turns a freshly created VPS (root + password)
# into a host you reach by key with a short name.
#
#   1. uploads the public key to root@VPS_HOST using the root password
#   2. pins the server's host key in ~/.ssh/known_hosts (and shows you the
#      fingerprint so you can compare it with the hoster's console)
#   3. writes a managed block into ~/.ssh/config
#   4. writes tunnel aliases into ~/.bash_aliases
#
# Safe to re-run: every step converges instead of appending.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# On the laptop /var/lib is not ours to write to.
export STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vps-toolkit}"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

# ------------------------------------------------------------------ load .env
[[ -f "$HERE/.env" ]] || die "no $HERE/.env - copy .env.example to .env and fill it in"
set -a; source "$HERE/.env"; set +a

: "${VPS_HOST:?set VPS_HOST in .env}"
: "${VPS_ALIAS:?set VPS_ALIAS in .env}"
: "${VPS_USER:?set VPS_USER in .env}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
PUB_KEY="${SSH_KEY}.pub"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# ------------------------------------------------------------------- key pair
section "SSH key pair"
if [[ -f "$SSH_KEY" ]]; then
  skip "private key present: $SSH_KEY"
else
  log "generating $SSH_KEY"
  ssh-keygen -t ed25519 -a 100 -C "${USER}@$(hostname)-${VPS_ALIAS}" -f "$SSH_KEY"
  ok "key generated"
fi
[[ -f "$PUB_KEY" ]] || die "public key $PUB_KEY is missing"
log "fingerprint: $(ssh-keygen -lf "$PUB_KEY")"

# ------------------------------------------------------------- host key (TOFU)
section "Host key"
install -d -m 0700 "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"; chmod 600 "$HOME/.ssh/known_hosts"
if ssh-keygen -F "[$VPS_HOST]:$SSH_PORT" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 \
   || { [[ "$SSH_PORT" == "22" ]] && ssh-keygen -F "$VPS_HOST" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; }; then
  skip "host key already pinned for $VPS_HOST"
else
  log "scanning host key of $VPS_HOST:$SSH_PORT"
  scanned="$(ssh-keyscan -T 10 -p "$SSH_PORT" -t ed25519 "$VPS_HOST" 2>/dev/null)" \
    || die "cannot reach $VPS_HOST:$SSH_PORT"
  [[ -n "$scanned" ]] || die "host returned no ed25519 key"
  printf '%s\n' "$scanned" >> "$HOME/.ssh/known_hosts"
  warn "pinned a NEW host key. Compare this fingerprint with your hoster's console:"
  printf '%s\n' "$scanned" | ssh-keygen -lf -
fi

# --------------------------------------------------------------- upload pubkey
section "Public key upload"
key_works() {
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o PasswordAuthentication=no \
      -i "$SSH_KEY" -p "$SSH_PORT" "root@$VPS_HOST" true 2>/dev/null
}

if key_works; then
  skip "key already authorized for root@$VPS_HOST"
else
  [[ -n "${VPS_ROOT_PASS:-}" ]] || die \
    "key auth does not work yet and VPS_ROOT_PASS is empty - put the root password in .env"
  have sshpass || die "sshpass is required for the first upload:  sudo apt install sshpass"
  log "uploading $PUB_KEY to root@$VPS_HOST (password auth, one time only)"
  SSHPASS="$VPS_ROOT_PASS" sshpass -e \
    ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$PUB_KEY" -p "$SSH_PORT" "root@$VPS_HOST" \
    || die "ssh-copy-id failed - check VPS_HOST / VPS_ROOT_PASS"
  key_works || die "key uploaded but key auth still fails - inspect sshd on the server"
  ok "key auth to root@$VPS_HOST works"
fi

# -------------------------------------------------------------- ~/.ssh/config
# A Host block beats a shell alias: scp, rsync, git, and ssh -L all honour it,
# an alias only helps interactive ssh.
section "~/.ssh/config"
SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"

# Renaming VPS_ALIAS must not leave the previous name behind pointing at the
# same machine. Any block we own whose HostName is this server but whose tag is
# no longer the current alias is stale by definition - drop it from both the ssh
# config and the aliases file.
ALIASES="$HOME/.bash_aliases"
touch "$ALIASES"
stale_tags="$(awk -v want="$VPS_HOST" -v cur="$VPS_ALIAS" '
  /^# >>> vps-provision:.+ >>>$/ {
      tag = $0; sub(/^# >>> vps-provision:/, "", tag); sub(/ >>>$/, "", tag)
      inblock = 1; host = ""; next
  }
  /^# <<< vps-provision:.+ <<<$/ {
      if (inblock && host == want && tag != cur) print tag
      inblock = 0; next
  }
  inblock && $1 == "HostName" { host = $2 }
' "$SSH_CONFIG" | sort -u)"

for tag in $stale_tags; do
  warn "alias renamed: '$tag' -> '$VPS_ALIAS' for $VPS_HOST, pruning the old entries"
  remove_block "$SSH_CONFIG" "$tag"
  remove_block "$ALIASES"    "$tag"
done

read -r -d '' SSH_BLOCK <<EOF || true
Host $VPS_ALIAS
    HostName $VPS_HOST
    User $VPS_USER
    Port $SSH_PORT
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 4

Host ${VPS_ALIAS}-root
    HostName $VPS_HOST
    User root
    Port $SSH_PORT
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF

replace_block "$SSH_CONFIG" "$VPS_ALIAS" "$SSH_BLOCK"

# ------------------------------------------------------------------- aliases
section "Shell aliases"

read -r -d '' ALIAS_BLOCK <<EOF || true
# Default way in: a shell on the server with every forward already up.
# The trailing ${VPS_ALIAS} is the Host block in ~/.ssh/config - aliases expand
# only in the first word of a command, so this does not recurse.
alias ${VPS_ALIAS}='ssh -L 8123:127.0.0.1:8123 -L 9000:127.0.0.1:9000 -L 19999:127.0.0.1:19999 ${VPS_ALIAS}'
# Forward only, no shell (-N): for when the ports are all you want.
# ClickHouse -> localhost:8123 (HTTP) and localhost:9000 (native)
alias ${VPS_ALIAS}-ch='ssh -N -L 8123:127.0.0.1:8123 -L 9000:127.0.0.1:9000 ${VPS_ALIAS}'
# Netdata -> http://localhost:19999
alias ${VPS_ALIAS}-mon='ssh -N -L 19999:127.0.0.1:19999 ${VPS_ALIAS}'
EOF

replace_block "$ALIASES" "$VPS_ALIAS" "$ALIAS_BLOCK"

if ! grep -qE '(^|[^#])\s*\.\s+.*bash_aliases|source.*bash_aliases' "$HOME/.bashrc" 2>/dev/null; then
  warn "~/.bashrc does not source ~/.bash_aliases - add:  . ~/.bash_aliases"
fi

# -------------------------------------------------------------------- summary
section "Done"
cat <<EOF
  ${VPS_ALIAS}               shell as ${VPS_USER} + all forwards (works after ./provision.sh)
  ssh ${VPS_ALIAS}           plain shell, no forwards
  ssh ${VPS_ALIAS}-root      root shell (works now)
  ${VPS_ALIAS}-ch            forward ClickHouse only, no shell
  ${VPS_ALIAS}-mon           forward Netdata only, no shell

Next:  ./provision.sh
Then:  clear VPS_ROOT_PASS in .env - the key has made it redundant.
  (new aliases need:  source ~/.bash_aliases)
EOF
