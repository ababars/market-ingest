#!/usr/bin/env bash
# Docker Engine + compose plugin from Docker's own repo (Ubuntu's docker.io is
# consistently behind and ships no compose v2).
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

if [[ "${INSTALL_DOCKER:-1}" != "1" ]]; then
  skip "docker disabled by INSTALL_DOCKER=$INSTALL_DOCKER"
  exit 0
fi

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"

section "Docker repository"
add_apt_repo docker \
  "https://download.docker.com/linux/ubuntu/gpg" \
  "deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable"

section "Docker packages"
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

section "Daemon configuration"
# Container logs default to an unbounded json file. On a 200 GB disk that is a
# slow-motion outage, so cap them up front.
write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
svc_enable_start docker
if (( FILE_CHANGED )); then
  svc_restart docker
fi

section "Group membership"
if [[ -n "${VPS_USER:-}" ]] && id -u "$VPS_USER" >/dev/null 2>&1; then
  if user_in_group "$VPS_USER" docker; then
    skip "$VPS_USER already in docker group"
  else
    # Membership in `docker` is effectively root: the socket can mount the host
    # filesystem into a container. Fine for a single-admin box, worth knowing.
    usermod -aG docker "$VPS_USER"
    ok "$VPS_USER added to docker group (takes effect on next login)"
  fi
fi

ok "$(docker --version), $(docker compose version)"
