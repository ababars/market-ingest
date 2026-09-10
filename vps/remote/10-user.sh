#!/usr/bin/env bash
# Non-root working account with the same SSH key root already trusts.
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

: "${VPS_USER:?VPS_USER not set}"
[[ "$VPS_USER" != "root" ]] || die "VPS_USER must not be root"

section "User $VPS_USER"
if id -u "$VPS_USER" >/dev/null 2>&1; then
  skip "user exists: $VPS_USER"
else
  adduser --disabled-password --gecos "" "$VPS_USER" >/dev/null
  ok "user created: $VPS_USER"
fi

usermod -s /bin/bash "$VPS_USER"
if user_in_group "$VPS_USER" sudo; then
  skip "already in sudo group"
else
  usermod -aG sudo "$VPS_USER"
  ok "added to sudo group"
fi

section "Authorized keys"
# The account has no password at all (--disabled-password), so the SSH key is
# the only way in - which is exactly what we want.
HOME_DIR="$(getent passwd "$VPS_USER" | cut -d: -f6)"
install -d -m 0700 -o "$VPS_USER" -g "$VPS_USER" "$HOME_DIR/.ssh"
[[ -s /root/.ssh/authorized_keys ]] || die "/root/.ssh/authorized_keys is empty - run bootstrap.sh first"

if [[ -f "$HOME_DIR/.ssh/authorized_keys" ]] && \
   cmp -s /root/.ssh/authorized_keys "$HOME_DIR/.ssh/authorized_keys"; then
  skip "authorized_keys already in sync with root's"
else
  install -m 0600 -o "$VPS_USER" -g "$VPS_USER" \
    /root/.ssh/authorized_keys "$HOME_DIR/.ssh/authorized_keys"
  ok "authorized_keys installed for $VPS_USER"
fi

section "sudo"
# Passwordless sudo, matching the cloud-init convention: the account has no
# password to type, and the SSH key is already the authentication boundary.
write_file "/etc/sudoers.d/90-$VPS_USER" 0440 <<EOF
# Managed by vps-provision.
$VPS_USER ALL=(ALL) NOPASSWD:ALL
EOF
visudo -cf "/etc/sudoers.d/90-$VPS_USER" >/dev/null || die "generated sudoers file is invalid"
ok "passwordless sudo configured for $VPS_USER"
