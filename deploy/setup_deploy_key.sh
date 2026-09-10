#!/usr/bin/env bash
# Prepares the server to pull from GitHub. Run on the SERVER as root.
#
# The private key is generated here and never leaves the machine - a deploy key
# you carried through a laptop is a deploy key you have to trust your laptop
# with. You paste only the PUBLIC half into GitHub.
#
# The service account has no home directory on purpose, so git cannot fall back
# to ~/.ssh for either the key or the host fingerprint. Both are given to it
# explicitly through GIT_SSH_COMMAND, which is also why nothing here depends on
# $HOME being set.
set -Eeuo pipefail

ETC=/etc/market-ingest
KEY="$ETC/deploy_key"
KNOWN="$ETC/known_hosts"
USER_NAME=ingest

install -d -m 0750 -g "$USER_NAME" "$ETC"

if [[ -s "$KEY" ]]; then
  echo "deploy key already exists at $KEY"
else
  ssh-keygen -t ed25519 -N '' -C "market-ingest-deploy@$(hostname)" -f "$KEY" >/dev/null
  echo "generated a new deploy key"
fi
chown root:"$USER_NAME" "$KEY" "$KEY.pub"
chmod 0640 "$KEY"
chmod 0644 "$KEY.pub"

# Pin GitHub's host key now, so the first pull cannot be a silent MITM window
# or - more likely - a confusing failure in a non-interactive session.
if [[ -s "$KNOWN" ]] && grep -q github.com "$KNOWN"; then
  echo "github.com host key already pinned"
else
  ssh-keyscan -t ed25519 github.com 2>/dev/null > "$KNOWN"
  [[ -s "$KNOWN" ]] || { echo "could not fetch github.com host key" >&2; exit 1; }
  echo "pinned github.com host key:"
  ssh-keygen -lf "$KNOWN" | sed 's/^/    /'
fi
chown root:"$USER_NAME" "$KNOWN"
chmod 0644 "$KNOWN"

cat <<EOF

--------------------------------------------------------------------------
Add this as a READ-ONLY deploy key on the GitHub repository
(Settings -> Deploy keys -> Add deploy key; leave "Allow write access" OFF):

$(cat "$KEY.pub")
--------------------------------------------------------------------------
EOF
