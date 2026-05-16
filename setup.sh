#!/bin/bash
# Cloud instance bootstrap: sudo user + SSH key migration + root lockdown + Docker.
# Designed to be fetched via `curl ... | bash` from CSP user-data.

set -euo pipefail

USERNAME="${USERNAME:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0)

log() { printf '[setup] %s\n' "$*" >&2; }
err() { printf '[setup][error] %s\n' "$*" >&2; exit 1; }

# 1. Environment validation -------------------------------------------------
[ "$(id -u)" -eq 0 ] || err "must run as root"

[ -r /etc/os-release ] || err "/etc/os-release missing"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || err "unsupported distro: ${ID:-unknown}"
case "${VERSION_ID:-}" in
  22.04|24.04|26.04) ;;
  *) err "unsupported Ubuntu version: ${VERSION_ID:-unknown} (supported: 22.04, 24.04, 26.04)" ;;
esac

[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
  || err "invalid USERNAME: $USERNAME"
[ "$USERNAME" != "root" ] || err "USERNAME cannot be 'root'"
{ [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; } \
  || err "invalid SSH_PORT: $SSH_PORT"

if [ ! -s /root/.ssh/authorized_keys ]; then
  err "/root/.ssh/authorized_keys is empty or missing — refusing to proceed (would lock you out)"
fi

log "config: USERNAME=$USERNAME SSH_PORT=$SSH_PORT ubuntu=$VERSION_ID"

# 2. System update ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

log "updating apt indexes"
apt-get "${APT_OPTS[@]}" update

log "upgrading packages"
apt-get "${APT_OPTS[@]}" -y upgrade

log "installing prerequisites"
apt-get "${APT_OPTS[@]}" -y install ca-certificates curl gnupg

# 3. Create sudo user, migrate SSH keys -------------------------------------
if id -u "$USERNAME" >/dev/null 2>&1; then
  log "user '$USERNAME' already exists; skipping creation"
else
  log "creating user '$USERNAME'"
  useradd -m -s /bin/bash "$USERNAME"
fi

usermod -aG sudo "$USERNAME"

log "configuring passwordless sudo for '$USERNAME'"
sudoers_file="/etc/sudoers.d/90-$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >"$sudoers_file"
chmod 0440 "$sudoers_file"
visudo -cf "$sudoers_file" >/dev/null || { rm -f "$sudoers_file"; err "invalid sudoers file"; }

home_dir=$(getent passwd "$USERNAME" | cut -d: -f6)
[ -n "$home_dir" ] && [ -d "$home_dir" ] || err "could not resolve home directory for $USERNAME"
home_ssh="$home_dir/.ssh"

log "migrating SSH keys from /root to $home_ssh"
install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "$home_ssh"
install -m 0600 -o "$USERNAME" -g "$USERNAME" /root/.ssh/authorized_keys "$home_ssh/authorized_keys"

grep -qE '^[^#[:space:]]' "$home_ssh/authorized_keys" \
  || err "no SSH keys present in $home_ssh/authorized_keys after copy"

# 4. Docker + Compose plugin ------------------------------------------------
log "installing Docker (official apt repo)"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

arch=$(dpkg --print-architecture)
echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME:-} stable" \
  >/etc/apt/sources.list.d/docker.list

apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" -y install \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker "$USERNAME"
systemctl enable --now docker

# 5. Unattended security upgrades -------------------------------------------
log "enabling unattended-upgrades"
apt-get "${APT_OPTS[@]}" -y install unattended-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# 6. SSH hardening (LAST — leave root access intact if earlier steps fail) --
log "hardening sshd"
sshd_conf="/etc/ssh/sshd_config.d/99-hardening.conf"
{
  echo "# managed by cloud-startup-script"
  echo "PermitRootLogin no"
  echo "PasswordAuthentication no"
  echo "PubkeyAuthentication yes"
  echo "KbdInteractiveAuthentication no"
  [ "$SSH_PORT" != "22" ] && echo "Port $SSH_PORT"
} >"$sshd_conf"
chmod 0644 "$sshd_conf"

if ! sshd -t; then
  rm -f "$sshd_conf"
  err "sshd config validation failed; reverted hardening conf"
fi

if [ "$SSH_PORT" != "22" ]; then
  # Ubuntu 22.10+ ships socket-activated ssh.socket bound to 22 — disable it
  # so the Port directive in sshd_config takes effect on ssh.service.
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    log "disabling socket-activated ssh.socket to honor custom port"
    systemctl disable --now ssh.socket
  fi
  systemctl enable --now ssh.service
  systemctl restart ssh.service
else
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi

# 7. Done -------------------------------------------------------------------
log "complete"
log "  user:      $USERNAME (groups: sudo, docker)"
log "  ssh port:  $SSH_PORT"
log "  connect:   ssh -p $SSH_PORT $USERNAME@<host>"
log "  root ssh:  disabled"
