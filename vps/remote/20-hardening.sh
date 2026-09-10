#!/usr/bin/env bash
# SSH hardening, firewall, fail2ban, automatic security updates.
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

SSH_PORT="${SSH_PORT:-22}"
HARDEN_ROOT_LOGIN="${HARDEN_ROOT_LOGIN:-prohibit-password}"

section "SSH daemon"
# Safety interlock: turning off password auth while no key is installed would
# lock us out of our own server, so verify the key first and refuse otherwise.
HOME_DIR="$(getent passwd "$VPS_USER" | cut -d: -f6)"
[[ -s "$HOME_DIR/.ssh/authorized_keys" ]] \
  || die "$VPS_USER has no authorized_keys - refusing to disable password auth"

# A drop-in rather than an edit of sshd_config: the distro file keeps updating
# cleanly, and undoing our changes is one `rm`.
#
# The "00-" prefix is load-bearing. sshd takes the FIRST value it sees for a
# keyword, not the last, and Ubuntu cloud images ship
# /etc/ssh/sshd_config.d/50-cloud-init.conf containing "PasswordAuthentication
# yes". A drop-in named 60-* is included after that one and is therefore
# silently ignored - the box keeps accepting passwords while the config on disk
# claims otherwise. Sorting first is what makes these settings actually win.
sshd_changed=0
if [[ -f /etc/ssh/sshd_config.d/60-hardening.conf ]]; then
  rm -f /etc/ssh/sshd_config.d/60-hardening.conf
  sshd_changed=1
  ok "removed superseded 60-hardening.conf (it lost to 50-cloud-init.conf)"
fi

write_file /etc/ssh/sshd_config.d/00-hardening.conf 0644 <<EOF
# Managed by vps-provision.
Port $SSH_PORT
PermitRootLogin $HARDEN_ROOT_LOGIN
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $VPS_USER root
EOF

(( FILE_CHANGED )) && sshd_changed=1
if (( sshd_changed )); then
  sshd -t || die "sshd config is invalid - NOT restarting (your session is still safe)"
  # Restarting sshd never drops the connection you are currently sitting in;
  # only new connections use the new config. That is what makes this safe.
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  ok "sshd restarted (existing sessions unaffected)"
else
  skip "sshd config unchanged"
fi

# Writing a config file is not the same as the daemon honouring it. `sshd -T`
# prints the settings actually in effect after all includes are resolved, so
# assert against that rather than trusting our own file.
effective="$(sshd -T 2>/dev/null || true)"
eff_get() { awk -v k="$1" 'tolower($1)==k {print tolower($2); exit}' <<<"$effective"; }

pw_eff="$(eff_get passwordauthentication)"
[[ "$pw_eff" == "no" ]] || die \
  "password authentication is still '$pw_eff' - something in /etc/ssh/sshd_config.d/ sorts before 00-hardening.conf and overrides it"
ok "verified: passwordauthentication = no"

root_eff="$(eff_get permitrootlogin)"
# sshd reports the historical spelling for prohibit-password
case "$HARDEN_ROOT_LOGIN:$root_eff" in
  prohibit-password:without-password|prohibit-password:prohibit-password|no:no)
    ok "verified: permitrootlogin = $root_eff" ;;
  *)
    die "permitrootlogin is '$root_eff' but '$HARDEN_ROOT_LOGIN' was requested" ;;
esac

section "Firewall (ufw)"
apt_install ufw
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ufw allow "$SSH_PORT/tcp" comment 'ssh' >/dev/null
# Nothing else is opened on purpose: ClickHouse (8123/9000) and Netdata (19999)
# bind to 127.0.0.1 and are reached through an SSH tunnel.
ufw_state="$(ufw status 2>/dev/null || true)"
if [[ "$ufw_state" == *"Status: active"* ]]; then
  skip "ufw already active"
else
  ufw --force enable >/dev/null
  ok "ufw enabled"
fi
log "$(ufw status | tr '\n' '|' | sed 's/|/ | /g')"

section "fail2ban"
apt_install fail2ban
write_file /etc/fail2ban/jail.d/sshd.local 0644 <<EOF
# Managed by vps-provision.
[sshd]
enabled  = true
port     = $SSH_PORT
backend  = systemd
maxretry = 4
findtime = 10m
bantime  = 1h
EOF
svc_enable_start fail2ban
(( FILE_CHANGED )) && svc_restart fail2ban

section "Unattended security upgrades"
apt_install unattended-upgrades
write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
# Managed by vps-provision.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
write_file /etc/apt/apt.conf.d/52unattended-upgrades-local 0644 <<'EOF'
// Managed by vps-provision.
// Security updates only, and never an unattended reboot: a ClickHouse box
// should go down when we say so, not at 06:00 on its own.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF
svc_enable_start unattended-upgrades

ok "hardening applied"
