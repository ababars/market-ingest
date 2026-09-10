#!/usr/bin/env bash
# Everyday CLI tools plus dotfiles for both root and the working user.
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

DOTFILES="$TOOLKIT_ROOT/dotfiles"

section "CLI packages"
apt_install git htop mc tmux vim less bash-completion man-db

section "Dotfiles"
install_dotfiles() {
  local user="$1" home
  home="$(getent passwd "$user" | cut -d: -f6)" || return 0
  [[ -n "$home" && -d "$home" ]] || { warn "no home dir for $user"; return 0; }

  write_user_file "$user" "$home/.tmux.conf" 0644 < "$DOTFILES/tmux.conf"
  write_user_file "$user" "$home/.vimrc"     0644 < "$DOTFILES/vimrc"
  install -d -m 0700 -o "$user" -g "$(id -gn "$user")" \
    "$home/.vim/undo" "$home/.vim/swap" "$home/.vim/backup"

  # A visibly different prompt on the server is cheap insurance against typing
  # a server command into a laptop terminal, or the reverse.
  replace_block "$home/.bashrc" prompt "$(cat <<'BRC'
export EDITOR=vim
export VISUAL=vim
export LESS='-R -F -X -i'
export HISTSIZE=20000
export HISTFILESIZE=50000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend checkwinsize
if [ -n "$PS1" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
  else
    PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
  fi
fi
BRC
)"
  chown "$user:$(id -gn "$user")" "$home/.bashrc"
}

install_dotfiles root
[[ -n "${VPS_USER:-}" ]] && id -u "$VPS_USER" >/dev/null 2>&1 && install_dotfiles "$VPS_USER"

section "System-wide aliases"
write_file /etc/profile.d/vps-toolkit.sh 0644 <<'EOF'
# Managed by vps-provision.
alias ll='ls -alFh --group-directories-first'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -hT -x tmpfs -x devtmpfs'
alias du1='du -h --max-depth=1'
alias ports='ss -tulpn'
alias jctl='journalctl -n 200 -f'
alias chc='clickhouse-client'
EOF

section "git"
if [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]]; then
  for u in root "${VPS_USER:-}"; do
    [[ -n "$u" ]] && id -u "$u" >/dev/null 2>&1 || continue
    sudo -u "$u" -H git config --global user.name  "$GIT_USER_NAME"
    sudo -u "$u" -H git config --global user.email "$GIT_USER_EMAIL"
    sudo -u "$u" -H git config --global init.defaultBranch main
    sudo -u "$u" -H git config --global pull.rebase true
  done
  ok "git identity set to $GIT_USER_NAME <$GIT_USER_EMAIL>"
else
  skip "GIT_USER_NAME / GIT_USER_EMAIL not set in .env - git identity left alone"
fi

ok "tools ready: $(git --version | head -1), tmux $(tmux -V | awk '{print $2}'), $(vim --version | head -1 | cut -d' ' -f1-5)"
