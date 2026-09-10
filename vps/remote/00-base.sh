#!/usr/bin/env bash
# Base system: updates, essential CLI, clock, swap, kernel tunables.
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

VPS_TZ="${VPS_TZ:-UTC}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

section "System update"
apt_refresh
log "apt-get upgrade"
apt-get upgrade -y -qq >/dev/null
ok "packages up to date"

section "Base packages"
apt_install ca-certificates curl wget gnupg lsb-release apt-transport-https \
            rsync tar xz-utils zstd unzip jq ncdu tree net-tools dnsutils \
            ca-certificates chrony

section "Clock"
# Exchange data is only as good as the timestamp attached to it, so we want a
# real NTP client rather than the coarse systemd-timesyncd default.
if systemctl is-active --quiet systemd-timesyncd; then
  systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  ok "systemd-timesyncd disabled in favour of chrony"
fi
svc_enable_start chrony
if [[ "$(timedatectl show -p Timezone --value)" == "$VPS_TZ" ]]; then
  skip "timezone already $VPS_TZ"
else
  timedatectl set-timezone "$VPS_TZ"
  ok "timezone set to $VPS_TZ"
fi

section "Swap"
# 12 GB of RAM does not need much swap, but a small file keeps a memory spike
# from turning into an OOM kill of clickhouse-server. Low swappiness means the
# kernel reaches for it only under real pressure, not to page out a hot cache.
if [[ "$SWAP_SIZE" == "0" ]]; then
  skip "swap disabled by SWAP_SIZE=0"
elif [[ -n "$(swapon --show=NAME,SIZE --noheadings 2>/dev/null || true)" ]]; then
  skip "swap already active: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
elif is_done swapfile; then
  skip "swap file was created earlier but is not active - check /etc/fstab"
else
  log "creating ${SWAP_SIZE} swap file at /swapfile"
  swap_mb=$(( $(numfmt --from=iec "$SWAP_SIZE") / 1048576 ))
  # fallocate is instant but fails on filesystems without extent support (some
  # VPS images still hand out ext3 or a loop-mounted image), hence the dd fallback.
  if fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || \
     dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none; then
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    mark_done swapfile
    ok "swap active: $SWAP_SIZE"
  else
    warn "could not create a swap file (container without swap support?) - continuing"
  fi
fi

section "Kernel tunables"
write_file /etc/sysctl.d/60-vps-base.conf 0644 <<'EOF'
# Managed by vps-provision.

# Swap only under genuine pressure; never to free up page cache.
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# ClickHouse maps a lot of files; the default 65530 is easy to hit.
vm.max_map_count = 262144

# Room for bursty inbound connections from exchange feeds.
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_slow_start_after_idle = 0

# Long-lived websocket feeds die quietly behind NAT without keepalives.
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

fs.file-max = 1048576
EOF
if (( FILE_CHANGED )); then
  sysctl --system >/dev/null
  ok "sysctl applied"
fi

write_file /etc/security/limits.d/90-vps.conf 0644 <<'EOF'
# Managed by vps-provision. Applies to interactive/PAM sessions; systemd
# services get their limits from their own unit files instead.
*  soft  nofile  262144
*  hard  nofile  262144
EOF

ok "base system ready"
