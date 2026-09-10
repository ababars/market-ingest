#!/usr/bin/env bash
# Creates the least-privilege ClickHouse account the collectors run as.
# Run on the server as root. Idempotent: re-running reuses the stored password.
set -Eeuo pipefail

CREDS=/etc/market-ingest/env
install -d -m 0750 -g ingest /etc/market-ingest

if [[ -f "$CREDS" ]] && grep -q '^CH_PASSWORD=' "$CREDS"; then
  pw="$(grep '^CH_PASSWORD=' "$CREDS" | cut -d= -f2-)"
  echo "reusing existing ingest password from $CREDS"
else
  # No pipeline: `tr ... | head -c` dies of SIGPIPE under `set -o pipefail`.
  raw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 4096 /dev/urandom))"
  pw="${raw:0:32}"
  echo "generated a new ingest password"
fi

clickhouse-client --multiquery -q "
CREATE USER IF NOT EXISTS ingest IDENTIFIED WITH sha256_password BY '${pw}'
    HOST LOCAL;
ALTER USER ingest IDENTIFIED WITH sha256_password BY '${pw}';
GRANT INSERT, SELECT ON market.* TO ingest;
GRANT INSERT, SELECT ON ops.*    TO ingest;
-- The storage probe reports how big the archive has grown, which lives in
-- system.parts. Read-only, and narrower than granting the whole system
-- database: parts is metadata about our own tables and nothing else.
GRANT SELECT ON system.parts TO ingest;
"

umask 077
cat > "$CREDS" <<EOF
# Managed by deploy/setup_ch_user.sh. Read by the systemd units.
CH_PASSWORD=${pw}
EOF
chmod 0640 "$CREDS"
chgrp ingest "$CREDS" 2>/dev/null || true

echo "ingest user ready; credentials in $CREDS"
