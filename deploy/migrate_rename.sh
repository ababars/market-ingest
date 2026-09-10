#!/usr/bin/env bash
# One-shot migration: hash7-ingest -> market-ingest. Run on the SERVER as root.
#
# Renaming the project is not a directory rename on the server. The unit name,
# both path trees, the enable symlink and the service account all carry the old
# name, and leaving any of them behind means a dead unit and a pair of twin
# directories nobody dares delete six months later.
#
# Idempotent: if the new layout is already in place it exits without touching
# anything.
set -Eeuo pipefail

OLD_UNIT=hash7-ingest@binance_um
NEW_UNIT=market-ingest@binance_um
OLD_USER=hash7
NEW_USER=ingest

say() { printf '\033[36m[ .. ]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
skip(){ printf '\033[2m[skip] %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- stop the old
if systemctl list-unit-files 'hash7-ingest@*' --no-legend 2>/dev/null | grep -q hash7; then
  say "stopping $OLD_UNIT (collection pauses from here)"
  systemctl disable --now "$OLD_UNIT" 2>/dev/null || true
  ok "old unit stopped and disabled"
else
  skip "no old unit present"
fi
rm -f /etc/systemd/system/hash7-ingest@.service
systemctl daemon-reload

# ------------------------------------------------------------------- the user
if id -u "$NEW_USER" >/dev/null 2>&1; then
  skip "user $NEW_USER already exists"
elif id -u "$OLD_USER" >/dev/null 2>&1; then
  say "renaming service account $OLD_USER -> $NEW_USER"
  # Safe only because the service is stopped: usermod refuses while the account
  # owns running processes.
  usermod -l "$NEW_USER" "$OLD_USER"
  groupmod -n "$NEW_USER" "$OLD_USER" 2>/dev/null || true
  ok "service account renamed"
else
  say "creating service account $NEW_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$NEW_USER"
fi

# ------------------------------------------------------------------ the trees
for pair in "/opt/hash7-ingest:/opt/market-ingest" "/etc/hash7-ingest:/etc/market-ingest"; do
  old="${pair%%:*}"; new="${pair##*:}"
  if [[ -d "$new" && ! -d "$old" ]]; then skip "$new already in place"; continue; fi
  if [[ -d "$old" && -d "$new" ]]; then
    echo "both $old and $new exist - refusing to guess; resolve by hand" >&2; exit 1
  fi
  if [[ -d "$old" ]]; then
    say "moving $old -> $new"
    mv "$old" "$new"
    ok "moved"
  fi
done

chown -R "$NEW_USER:$NEW_USER" /opt/market-ingest 2>/dev/null || true
chown root:"$NEW_USER" /etc/market-ingest/* 2>/dev/null || true
chgrp "$NEW_USER" /etc/market-ingest 2>/dev/null || true
chmod 0750 /etc/market-ingest

# -------------------------------------------------------------------- the venv
# Console scripts inside a venv hard-code the interpreter path in their shebang,
# so a moved venv has a working python but a broken pip. Cheaper to rebuild than
# to explain later.
if [[ -d /opt/market-ingest/.venv ]]; then
  say "rebuilding the virtualenv (its shebangs point at the old path)"
  rm -rf /opt/market-ingest/.venv
fi
sudo -u "$NEW_USER" python3 -m venv /opt/market-ingest/.venv
sudo -u "$NEW_USER" /opt/market-ingest/.venv/bin/pip -q install --upgrade pip
sudo -u "$NEW_USER" /opt/market-ingest/.venv/bin/pip -q install -r /opt/market-ingest/requirements.txt
ok "virtualenv rebuilt"

# -------------------------------------------------------------------- the unit
install -m 0644 /opt/market-ingest/deploy/market-ingest@.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now "$NEW_UNIT"
sleep 3
systemctl is-active --quiet "$NEW_UNIT" || {
  echo "new unit failed to start:" >&2
  journalctl -u "$NEW_UNIT" -n 30 --no-pager >&2
  exit 1
}
ok "$NEW_UNIT active"

echo
echo "old paths remaining (should be none):"
ls -d /opt/hash7-ingest /etc/hash7-ingest /etc/systemd/system/hash7-ingest@.service 2>/dev/null || echo "  none"
