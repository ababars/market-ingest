#!/usr/bin/env bash
# Netdata: per-second CPU / RAM / disk / network, plus a ClickHouse collector.
# Binds to loopback; reachable through the SSH tunnel, or from a phone via
# Netdata Cloud (outbound connection, no inbound port).
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"

section "Netdata repository"
# Flat repository, not the usual dists/<codename>/<component> layout - but the
# split between base URI and directory matters. Packages carry
#   Filename: noble/netdata_2.10.0+ubuntu24.04_amd64.deb
# and apt resolves that against the BASE URI, not against the directory. So the
# base has to stop at .../ubuntu/ with "noble/" as the directory; writing
# ".../ubuntu/noble/ ./" instead still finds Release and Packages, then asks for
# .../ubuntu/noble/noble/netdata_... and gets a 404 on every single package.
add_apt_repo netdata \
  "https://repo.netdata.cloud/netdatabot.gpg.key" \
  "deb [signed-by=/usr/share/keyrings/netdata.gpg arch=${ARCH}] https://repo.netdata.cloud/repos/stable/ubuntu/ ${CODENAME}/"

section "Packages"
# Deliberately without netdata-plugin-ebpf: it is the one plugin that costs
# real CPU and memory, and it buys us nothing for host-level metrics.
apt_install netdata netdata-plugin-go netdata-plugin-apps

section "Telemetry"
if [[ -f /etc/netdata/.opt-out-from-anonymous-statistics ]]; then
  skip "anonymous statistics already opted out"
else
  touch /etc/netdata/.opt-out-from-anonymous-statistics
  ok "opted out of anonymous statistics"
fi

section "Agent configuration"
write_file /etc/netdata/netdata.conf 0644 <<'EOF'
# Managed by vps-provision.
# Kept intentionally small: everything not listed here stays at the Netdata
# default, which is auto-sized from the host's CPU count and RAM.

[global]
    run as user = netdata

[web]
    # Loopback only. ufw blocks 19999 as well, but a service that never listens
    # on a public interface cannot be reached even if the firewall is flushed.
    bind to = 127.0.0.1
    mode = static-threaded

[registry]
    enabled = no
EOF
conf_changed=$FILE_CHANGED

section "ClickHouse collector"
if [[ -f /root/.clickhouse-credentials ]]; then
  # shellcheck disable=SC1091
  ch_pw="$(grep -E '^CH_PASSWORD=' /root/.clickhouse-credentials | cut -d= -f2-)"
  write_file /etc/netdata/go.d/clickhouse.conf 0640 <<EOF
# Managed by vps-provision.
jobs:
  - name: local
    url: http://127.0.0.1:8123
    username: default
    password: ${ch_pw}
EOF
  chown root:netdata /etc/netdata/go.d/clickhouse.conf
  (( FILE_CHANGED )) && conf_changed=1
  ok "ClickHouse collector configured"
else
  skip "no /root/.clickhouse-credentials - run step 50-clickhouse first"
fi

section "Alert notifications"
if [[ -n "${NETDATA_TG_BOT_TOKEN:-}" && -n "${NETDATA_TG_CHAT_ID:-}" ]]; then
  write_file /etc/netdata/health_alarm_notify.conf 0640 <<EOF
# Managed by vps-provision.
SEND_TELEGRAM="YES"
TELEGRAM_BOT_TOKEN="${NETDATA_TG_BOT_TOKEN}"
DEFAULT_RECIPIENT_TELEGRAM="${NETDATA_TG_CHAT_ID}"
SEND_EMAIL="NO"
EOF
  chown root:netdata /etc/netdata/health_alarm_notify.conf
  (( FILE_CHANGED )) && conf_changed=1
  ok "Telegram alerts enabled"
else
  skip "NETDATA_TG_* not set - built-in alerts will fire but go nowhere"
fi

section "Service"
svc_enable_start netdata
if (( conf_changed )); then
  svc_restart netdata
fi
wait_port 19999 60 || die "Netdata is not answering on 19999 (journalctl -u netdata -n 80)"
ok "dashboard up on 127.0.0.1:19999"

section "Netdata Cloud"
# Claiming is what makes the dashboard reachable from a phone: the agent opens
# an outbound connection to app.netdata.cloud, so nothing has to listen on a
# public port and ufw stays closed.
if [[ -z "${NETDATA_CLAIM_TOKEN:-}" ]]; then
  skip "NETDATA_CLAIM_TOKEN not set - agent stays local-only"
elif [[ -f /var/lib/netdata/cloud.d/claimed_id ]]; then
  skip "agent already claimed to Netdata Cloud"
else
  claim_sh=""
  for c in /usr/sbin/netdata-claim.sh /opt/netdata/bin/netdata-claim.sh; do
    [[ -x "$c" ]] && { claim_sh="$c"; break; }
  done
  if [[ -n "$claim_sh" ]]; then
    log "claiming agent to Netdata Cloud"
    "$claim_sh" -token="$NETDATA_CLAIM_TOKEN" \
                -rooms="${NETDATA_CLAIM_ROOMS:-}" \
                -url=https://app.netdata.cloud -daemon-not-running \
      && ok "claimed - the node will appear at https://app.netdata.cloud" \
      || warn "claim failed; check the token and re-run: $0"
    systemctl restart netdata
  else
    warn "netdata-claim.sh not found - claim manually from the Netdata Cloud UI"
  fi
fi

ok "netdata $(netdata -v 2>/dev/null | head -1 || echo installed)"
