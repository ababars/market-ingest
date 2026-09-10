#!/usr/bin/env bash
# Ship this repo to the VPS and restart the collectors.
#
#   ./deploy/deploy.sh              # rsync working tree (fast iteration)
#   ./deploy/deploy.sh --git        # server pulls from origin instead
#
# Reads VPS_ALIAS from the environment or defaults to the ssh Host name below.
set -Eeuo pipefail

HOST="${VPS_ALIAS:-scali}"
DEST=/opt/hash7-ingest
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-rsync}"

say() { printf '\033[36m[ .. ]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }

say "preparing $DEST on $HOST"
ssh "$HOST" "sudo install -d -o hash7 -g hash7 -m 0755 $DEST && sudo install -d -m 0750 -g hash7 /etc/hash7-ingest"

if [[ "$MODE" == "--git" ]]; then
  say "pulling from origin on the server"
  ssh "$HOST" "sudo -u hash7 git -C $DEST pull --ff-only"
else
  say "rsyncing working tree"
  rsync -az --delete \
    --exclude '.git' --exclude '__pycache__' --exclude '.venv' \
    --exclude '*.pyc' --exclude 'logs' \
    --rsync-path="sudo -u hash7 rsync" \
    "$HERE"/{src,schema,deploy,requirements.txt} "$HOST:$DEST/"
fi

say "virtualenv and dependencies"
ssh "$HOST" "sudo -u hash7 bash -c '
  set -e
  [ -d $DEST/.venv ] || python3 -m venv $DEST/.venv
  $DEST/.venv/bin/pip -q install --upgrade pip
  $DEST/.venv/bin/pip -q install -r $DEST/requirements.txt
'"

say "schema (idempotent)"
for f in "$HERE"/schema/*.sql; do
  ssh "$HOST" "clickhouse-client --multiquery" < "$f"
done

say "clickhouse ingest user"
ssh "$HOST" "sudo bash $DEST/deploy/setup_ch_user.sh"

say "systemd unit"
ssh "$HOST" "sudo install -m 0644 $DEST/deploy/hash7-ingest@.service /etc/systemd/system/ && sudo systemctl daemon-reload"

if ssh "$HOST" "systemctl is-enabled --quiet hash7-ingest@binance_um" 2>/dev/null; then
  say "restarting collector"
  ssh "$HOST" "sudo systemctl restart hash7-ingest@binance_um"
else
  say "collector not enabled yet; enable it with:"
  echo "    ssh $HOST sudo systemctl enable --now hash7-ingest@binance_um"
fi

ok "deployed"
