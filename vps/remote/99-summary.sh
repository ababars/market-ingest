#!/usr/bin/env bash
# Read-only report: what ended up installed, and what is actually listening.
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

v() {
  local cmd="$1"; shift
  command -v "$cmd" >/dev/null 2>&1 || { echo "not installed"; return 0; }
  local out; out="$("$@" 2>/dev/null | head -1 || true)"
  echo "${out:-installed}"
}

section "Host"
printf '  %-22s %s\n' "hostname"  "$(hostname)"
printf '  %-22s %s\n' "os"        "$(. /etc/os-release && echo "$PRETTY_NAME")"
printf '  %-22s %s\n' "kernel"    "$(uname -r)"
printf '  %-22s %s\n' "uptime"    "$(uptime -p)"
printf '  %-22s %s\n' "timezone"  "$(timedatectl show -p Timezone --value)"
printf '  %-22s %s\n' "clock sync" "$(timedatectl show -p NTPSynchronized --value)"

section "Resources"
printf '  %-22s %s\n' "cpu"  "$(nproc) cores - $(lscpu | awk -F': +' '/Model name/{print $2; exit}')"
free -h | sed 's/^/  /'
df -hT -x tmpfs -x devtmpfs | sed 's/^/  /'

section "Versions"
printf '  %-22s %s\n' "git"        "$(v git git --version)"
printf '  %-22s %s\n' "tmux"       "$(v tmux tmux -V)"
printf '  %-22s %s\n' "vim"        "$(v vim sh -c 'vim --version | head -1')"
printf '  %-22s %s\n' "mc"         "$(v mc sh -c 'mc --version | head -1')"
printf '  %-22s %s\n' "docker"     "$(v docker docker --version)"
printf '  %-22s %s\n' "compose"    "$(v docker docker compose version)"
printf '  %-22s %s\n' "clickhouse" "$(v clickhouse-client sh -c 'clickhouse-client --version')"
printf '  %-22s %s\n' "netdata"    "$(v netdata sh -c 'netdata -v')"

section "Services"
for s in ssh chrony ufw fail2ban docker clickhouse-server netdata; do
  state="$(systemctl is-active "$s" 2>/dev/null || true)"
  case "$state" in
    active)   printf '  %s%-22s %s%s\n' "$C_GRN" "$s" "$state" "$C_RESET" ;;
    inactive|failed) printf '  %s%-22s %s%s\n' "$C_RED" "$s" "$state" "$C_RESET" ;;
    *)        printf '  %s%-22s %s%s\n' "$C_DIM" "$s" "${state:-absent}" "$C_RESET" ;;
  esac
done

section "Listening sockets"
# Anything bound to 0.0.0.0 or :: here is exposed to the internet unless ufw
# happens to block it - worth a second look every time.
ss -tulpnH 2>/dev/null | awk '{printf "  %-6s %-24s %s\n", $1, $5, $7}' | sort -u

section "Firewall"
ufw status verbose 2>/dev/null | sed 's/^/  /' || echo "  ufw not installed"

section "Access from the laptop"
cat <<EOF
  ssh ${VPS_ALIAS:-<alias>}                       shell as ${VPS_USER:-<user>}
  ${VPS_ALIAS:-<alias>}-tunnel                    forward 8123 / 9000 / 19999 to localhost
  http://localhost:19999                          Netdata, while the tunnel is up
  clickhouse-client                               on the server, password picked up from
                                                  ~/.clickhouse-client/config.xml
  /root/.clickhouse-credentials                   ClickHouse user / password / database
  /var/log/vps-provision/latest.log               this run's full log
EOF
