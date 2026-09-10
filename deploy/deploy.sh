#!/usr/bin/env bash
# Ship this repo to the VPS and restart the collectors.
#
#   ./deploy/deploy.sh              # rsync working tree (fast iteration)
#   ./deploy/deploy.sh --git        # server pulls from origin instead
#
# Reads VPS_ALIAS from the environment or defaults to the ssh Host name below.
set -Eeuo pipefail

HOST="${VPS_ALIAS:-scali}"
DEST=/opt/market-ingest
ETC=/etc/market-ingest
REPO_URL="${REPO_URL:-git@github.com:greyfenrir/market-ingest.git}"
BRANCH="${BRANCH:-main}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-rsync}"

say() { printf '\033[36m[ .. ]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }

say "preparing $DEST on $HOST"
ssh "$HOST" "sudo install -d -o ingest -g ingest -m 0755 $DEST && sudo install -d -m 0750 -g ingest /etc/market-ingest"

if [[ "$MODE" == "--git" ]]; then
  # The deploy target was first populated by rsync, so there is no .git in it
  # and `git pull` would fail with "not a git repository". Initialise in place
  # on the first run instead of demanding a pristine clone.
  #
  # git also has no $HOME here - the service account deliberately has none - so
  # the key and the pinned host fingerprint are passed explicitly. Without this
  # the first pull dies on an unverified host key, in a way that reads like a
  # transport error rather than a trust problem.
  say "pulling $REPO_URL on the server"
  ssh "$HOST" "sudo -u ingest env \
      GIT_SSH_COMMAND='ssh -i $ETC/deploy_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$ETC/known_hosts -o StrictHostKeyChecking=yes' \
      bash -c '
    set -e
    cd $DEST
    if [ ! -d .git ]; then
      git init -q
      git remote add origin "$REPO_URL"
    fi
    git remote set-url origin "$REPO_URL"
    git fetch -q --depth=1 origin "$BRANCH"
    git reset -q --hard "origin/$BRANCH"
    # -fd without -x: untracked files are removed, gitignored ones (.venv) stay.
    git clean -qfd
    git log --oneline -1
  '"
else
  say "rsyncing working tree"
  rsync -az --delete \
    --exclude '.git' --exclude '__pycache__' --exclude '.venv' \
    --exclude '*.pyc' --exclude 'logs' \
    --rsync-path="sudo -u ingest rsync" \
    "$HERE"/{src,schema,deploy,requirements.txt} "$HOST:$DEST/"
fi

# --no-cache-dir below: the service account has no home by design, so pip has
# nowhere to put a cache and says so noisily on every single deploy. The
# dependency set is two small wheels; the cache was never buying anything.
say "virtualenv and dependencies"
ssh "$HOST" "sudo -u ingest bash -c '
  set -e
  [ -d $DEST/.venv ] || python3 -m venv $DEST/.venv
  $DEST/.venv/bin/pip -q --no-cache-dir install --upgrade pip
  $DEST/.venv/bin/pip -q --no-cache-dir install -r $DEST/requirements.txt
'"

# Apply the schema that is ON THE SERVER, not the one on this laptop. In --git
# mode the code comes from origin while the working tree may sit anywhere
# relative to it, and a deploy that ships one version of the code with another
# version of the schema fails in the worst way: quietly, at query time.
say "schema (idempotent, from $DEST/schema)"
ssh "$HOST" "set -e; for f in $DEST/schema/*.sql; do clickhouse-client --multiquery < \"\$f\"; done"

say "clickhouse ingest user"
ssh "$HOST" "sudo bash $DEST/deploy/setup_ch_user.sh"

say "systemd unit"
ssh "$HOST" "sudo install -m 0644 $DEST/deploy/market-ingest@.service /etc/systemd/system/ && sudo systemctl daemon-reload"

if ssh "$HOST" "systemctl is-enabled --quiet market-ingest@binance_um" 2>/dev/null; then
  say "restarting collector"
  ssh "$HOST" "sudo systemctl restart market-ingest@binance_um"
else
  say "collector not enabled yet; enable it with:"
  echo "    ssh $HOST sudo systemctl enable --now market-ingest@binance_um"
fi

ok "deployed"
