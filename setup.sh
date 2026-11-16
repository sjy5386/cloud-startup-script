#!/bin/bash
# Cloud instance bootstrap: DNS pin + swap + sudo user + SSH key migration + root lockdown + Docker.
# Designed to be fetched via `curl ... | bash` from CSP user-data.

set -euo pipefail

USERNAME="${USERNAME:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
# Space-separated IPv4 resolvers. DHCP DNS is ignored once this is applied.
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 1.0.0.1}"
# 0 skips. K/M/G are 1024-based (2G, 512M, 2GB). Rounded up to 1 MiB.
SWAP_SIZE="${SWAP_SIZE:-2G}"
APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0)

log() { printf '[setup] %s\n' "$*" >&2; }
err() { printf '[setup][error] %s\n' "$*" >&2; exit 1; }

is_ipv4() {
  local ip=$1 o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [ "$o" -le 255 ] || return 1
    # Reject leading zeros (08) so the address cannot be read as octal.
    [ "$o" = "$((10#$o))" ] || return 1
  done
}

# Prints byte count, or 0 when swap is disabled. K/M/G are 1024-based.
# Rounds up to 1 MiB. Rejects values outside 1 MiB..64 GiB.
parse_swap_bytes() {
  local spec=$1 num unit factor bytes
  case "$spec" in
    0|off|OFF|none|NONE|false|FALSE|no|NO) echo 0; return 0 ;;
  esac
  [[ "$spec" =~ ^([0-9]+)([KkMmGg])?[Bb]?$ ]] || return 1
  num=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]:-}
  case "$unit" in
    K|k) factor=1024 ;;
    M|m) factor=$((1024 * 1024)) ;;
    G|g) factor=$((1024 * 1024 * 1024)) ;;
    "") factor=1 ;;
    *) return 1 ;;
  esac
  bytes=$((10#$num * factor)) || return 1
  if [ "$bytes" -eq 0 ]; then
    echo 0
    return 0
  fi
  [ "$bytes" -ge 1048576 ] || return 1
  [ "$bytes" -le $((64 * 1024 * 1024 * 1024)) ] || return 1
  echo $(( (bytes + 1048575) / 1048576 * 1048576 ))
}

bytes_human() {
  local b=$1
  if [ $((b % 1073741824)) -eq 0 ]; then
    printf '%sG' $((b / 1073741824))
  elif [ $((b % 1048576)) -eq 0 ]; then
    printf '%sM' $((b / 1048576))
  else
    printf '%sB' "$b"
  fi
}

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
swap_bytes=$(parse_swap_bytes "$SWAP_SIZE") \
  || err "invalid SWAP_SIZE: $SWAP_SIZE (examples: 2G, 512M, 0)"

if [ ! -s /root/.ssh/authorized_keys ]; then
  err "/root/.ssh/authorized_keys is empty or missing — refusing to proceed (would lock you out)"
fi

log "config: USERNAME=$USERNAME SSH_PORT=$SSH_PORT SWAP_SIZE=$SWAP_SIZE ubuntu=$VERSION_ID"

# 2. Pin DNS ----------------------------------------------------------------
# Cloud images take resolvers from DHCP (netplan → systemd-resolved). A
# resolved drop-in pins the global servers for every lookup (Domains=~.),
# and a later netplan file stops DHCP from installing its own resolvers.
# bootstrap.sh already did this before the download. Repeat it here so a
# direct run of setup.sh still pins DNS before apt.
read -r -a dns_raw <<< "$DNS_SERVERS"
declare -A dns_seen=()
dns_list=()
for s in "${dns_raw[@]}"; do
  is_ipv4 "$s" || err "invalid DNS server: $s"
  [ -n "${dns_seen[$s]:-}" ] && continue
  dns_seen[$s]=1
  dns_list+=("$s")
done
unset dns_seen
[ "${#dns_list[@]}" -ge 1 ] || err "DNS_SERVERS is empty"

log "pinning DNS: ${dns_list[*]}"

install -d -m 0755 /etc/systemd/resolved.conf.d
{
  echo "# managed by cloud-startup-script"
  echo "[Resolve]"
  echo "DNS=${dns_list[*]}"
  echo "FallbackDNS="
  echo "Domains=~."
} >/etc/systemd/resolved.conf.d/dns.conf
chmod 0644 /etc/systemd/resolved.conf.d/dns.conf

systemctl enable --now systemd-resolved
systemctl restart systemd-resolved

# A regular file here would bypass systemd-resolved. Ubuntu cloud images
# already use the stub symlink; only replace a non-symlink.
if [ ! -L /etc/resolv.conf ]; then
  log "pointing /etc/resolv.conf at the systemd-resolved stub"
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

# 1 = /etc/netplan/99-dns.yaml was written and `netplan generate` accepted it.
# `netplan apply` is deferred until package installs finish.
netplan_dns_ready=0

pin_dns_via_netplan() {
  command -v python3 >/dev/null || { log "python3 missing; skipping netplan DNS override"; return 0; }
  command -v netplan >/dev/null || { log "netplan missing; skipping netplan DNS override"; return 0; }

  local dns_csv netplan_rc netplan_ifaces
  netplan_rc=0
  netplan_ifaces=""
  dns_csv=$(IFS=,; printf '%s' "${dns_list[*]}")
  # python exits 2 when PyYAML is missing, 3 when no netplan devices exist.
  # The heredoc terminator must be at column 0.
  netplan_ifaces=$(python3 - "$dns_csv" <<'PY'
import glob, os, sys

try:
    import yaml
except ImportError:
    sys.exit(2)

servers = [s for s in sys.argv[1].split(",") if s]
if not servers:
    sys.exit(1)

# (kind, name) -> [dhcp4, dhcp6]. OR the flags across every file so a later
# fragment that enables DHCP is not missed.
found = {}
order = []
paths = sorted(glob.glob("/etc/netplan/*.yaml")) + sorted(glob.glob("/etc/netplan/*.yml"))
for path in paths:
    if os.path.basename(path) == "99-dns.yaml":
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except yaml.YAMLError:
        sys.exit(1)
    if not isinstance(data, dict):
        continue
    network = data.get("network") or {}
    if not isinstance(network, dict):
        continue
    for kind in ("ethernets", "bonds", "bridges", "vlans"):
        block = network.get(kind) or {}
        if not isinstance(block, dict):
            continue
        for name, cfg in block.items():
            key = (kind, name)
            cfg = cfg if isinstance(cfg, dict) else {}
            prev = found.get(key, [False, False])
            found[key] = [
                prev[0] or cfg.get("dhcp4") is True,
                prev[1] or cfg.get("dhcp6") is True,
            ]
            if key not in order:
                order.append(key)

if not order:
    sys.exit(3)

class _NoAliasDumper(yaml.SafeDumper):
    def ignore_aliases(self, data):
        return True

network_out = {"version": 2}
for kind, name in order:
    dhcp4, dhcp6 = found[(kind, name)]
    # A fresh list per interface. Reusing one list object makes PyYAML
    # emit anchors (&id / *id) instead of repeating the addresses.
    entry = {"nameservers": {"addresses": list(servers)}}
    # Overrides without the matching dhcp flag make netplan reject the file.
    if dhcp4:
        entry["dhcp4-overrides"] = {"use-dns": False}
    if dhcp6:
        entry["dhcp6-overrides"] = {"use-dns": False}
    network_out.setdefault(kind, {})[name] = entry

path = "/etc/netplan/99-dns.yaml"
with open(path, "w", encoding="utf-8") as fh:
    fh.write("# managed by cloud-startup-script\n")
    yaml.dump(
        {"network": network_out},
        fh,
        Dumper=_NoAliasDumper,
        sort_keys=False,
        default_flow_style=False,
    )
os.chmod(path, 0o600)
print(" ".join(f"{kind}.{name}" for kind, name in order))
PY
) && netplan_rc=0 || netplan_rc=$?

  case "$netplan_rc" in
    0) ;;
    2)
      log "python3-yaml missing; DHCP DNS is not disabled (systemd-resolved still pins global DNS)"
      return 0
      ;;
    3)
      log "no netplan interfaces found; DHCP DNS is not disabled (systemd-resolved still pins global DNS)"
      return 0
      ;;
    *)
      err "failed to write /etc/netplan/99-dns.yaml (python exit $netplan_rc)"
      ;;
  esac

  log "netplan DNS override for: $netplan_ifaces"
  # generate only renders backend files under /run. It does not restart the
  # network, so the curl|bash pipe stays up. apply happens later.
  if ! netplan generate; then
    rm -f /etc/netplan/99-dns.yaml
    if netplan generate >/dev/null 2>&1; then
      err "netplan generate rejected the DNS override; removed /etc/netplan/99-dns.yaml"
    fi
    err "netplan generate failed even without the DNS override"
  fi
  netplan_dns_ready=1
}

global_dns_is_exact() {
  local line addr
  local -A want=() seen=()
  local -a got=()
  for addr in "${dns_list[@]}"; do
    want[$addr]=1
  done
  line=$(resolvectl dns 2>/dev/null | awk '/^[Gg]lobal:/ {sub(/^[^:]+:[[:space:]]*/, ""); print; exit}')
  read -r -a got <<< "$line"
  for addr in "${got[@]}"; do
    [ -n "$addr" ] || continue
    seen[$addr]=1
    [ -n "${want[$addr]:-}" ] || return 1
  done
  [ "${#seen[@]}" -eq "${#dns_list[@]}" ] || return 1
  for addr in "${dns_list[@]}"; do
    [ -n "${seen[$addr]:-}" ] || return 1
  done
}

retry() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    "$@" && return 0
    sleep 1
  done
  return 1
}

pin_dns_via_netplan

retry global_dns_is_exact \
  || err "global DNS is not pinned to: ${dns_list[*]} (resolvectl dns: $(resolvectl dns 2>/dev/null | tr '\n' ' '))"
if command -v timeout >/dev/null; then
  query_out=$(timeout 15 resolvectl query one.one.one.one 2>&1) \
    || err "name resolution failed using pinned DNS: $query_out"
else
  query_out=$(resolvectl query one.one.one.one 2>&1) \
    || err "name resolution failed using pinned DNS: $query_out"
fi
log "global DNS pinned: $(resolvectl dns 2>/dev/null | awk '/^[Gg]lobal:/ {print; exit}')"

# 3. Swap file --------------------------------------------------------------
# Small instances OOM during apt upgrade and the Docker install. Create the
# file first. A failure here still leaves root SSH open.
swapfile_active() {
  awk 'NR>1 && $1=="/swapfile" {found=1} END {exit found?0:1}' /proc/swaps
}

swapfile_is_swap() {
  local t
  t=$(blkid -p -o value -s TYPE /swapfile 2>/dev/null || true)
  [ "$t" = "swap" ]
}

# stat %b is 512-byte units. Fewer allocated blocks than the size means holes,
# which the kernel rejects for a swap file.
file_has_holes() {
  local size alloc
  size=$(stat -c%s "$1") || return 0
  alloc=$(stat -c%b "$1") || return 0
  [ $((alloc * 512)) -lt "$size" ]
}

# Allocate $swap_bytes bytes at $1. fallocate is instant; pass "dd" as $3 to
# skip it. ext4 and XFS can hand swapon a fallocate file it rejects as having
# holes, and btrfs swap files must be NODATACOW before any data is written.
allocate_swapfile() {
  local path=$1 fstype=$2 mode=${3:-auto}
  rm -f "$path"
  if [ "$fstype" = "btrfs" ]; then
    : > "$path"
    # +C only sticks on an empty file.
    chattr +C "$path" || return 1
  fi
  if [ "$mode" != "dd" ] && fallocate -l "$swap_bytes" "$path" 2>/dev/null && ! file_has_holes "$path"; then
    return 0
  fi
  log "writing $(bytes_human "$swap_bytes") swap file with dd"
  rm -f "$path"
  if [ "$fstype" = "btrfs" ]; then
    : > "$path"
    chattr +C "$path" || return 1
  fi
  dd if=/dev/zero of="$path" bs=1M count=$((swap_bytes / 1048576)) status=none conv=fsync
}

enable_swapfile() {
  local fstype=$1 mode=$2
  allocate_swapfile /swapfile "$fstype" "$mode" || return 1
  chmod 0600 /swapfile || return 1
  mkswap /swapfile >/dev/null || return 1
  swapon /swapfile
}

install_swap_fstab() {
  [ -f /etc/fstab ] || err "/etc/fstab is missing"
  if grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
    return 0
  fi
  printf '/swapfile none swap sw 0 0\n' >>/etc/fstab || err "failed to update /etc/fstab"
}

set_swappiness() {
  local conf=/etc/sysctl.d/99-swap.conf
  install -d -m 0755 /etc/sysctl.d
  cat >"$conf" <<'EOF'
# managed by cloud-startup-script
vm.swappiness=10
EOF
  chmod 0644 "$conf"
  sysctl -q -p "$conf" >/dev/null || err "failed to apply vm.swappiness"
}

configure_swap() {
  local fstype avail_kb need_kb existing_kb human
  if [ "$swap_bytes" -eq 0 ]; then
    log "swap skipped (SWAP_SIZE=$SWAP_SIZE)"
    return 0
  fi

  human=$(bytes_human "$swap_bytes")

  if [ -e /swapfile ] && [ ! -f /swapfile ]; then
    err "/swapfile exists and is not a regular file"
  fi

  # Same size and already a swap signature: enable it, do not rewrite.
  if [ -f /swapfile ] && [ "$(stat -c%s /swapfile)" -eq "$swap_bytes" ] && swapfile_is_swap; then
    if swapfile_active || swapon /swapfile; then
      install_swap_fstab
      set_swappiness
      log "swap already present: /swapfile ($human, swappiness 10)"
      return 0
    fi
    log "existing /swapfile did not enable; recreating"
  fi

  avail_kb=$(df -Pk / | awk 'NR==2 {print $4}') || err "df / failed"
  existing_kb=0
  if [ -f /swapfile ]; then
    existing_kb=$(( $(stat -c%s /swapfile) / 1024 ))
  fi
  # Leave 1 GiB for the package installs that follow this step.
  need_kb=$((swap_bytes / 1024 + 1024 * 1024))
  if [ $((avail_kb + existing_kb)) -lt "$need_kb" ]; then
    err "not enough free space for ${human} swap on / (free $((avail_kb / 1024)) MiB, need $((need_kb / 1024)) MiB including 1 GiB reserve); set a smaller SWAP_SIZE or 0 to skip"
  fi

  if swapfile_active; then
    log "replacing /swapfile ($human)"
    swapoff /swapfile || err "swapoff /swapfile failed"
  else
    log "creating swap file /swapfile ($human)"
  fi

  fstype=$(findmnt -n -o FSTYPE -T /) || err "could not detect filesystem type of /"
  if ! enable_swapfile "$fstype" auto; then
    log "swap file was rejected; rewriting it with dd"
    swapoff /swapfile 2>/dev/null || true
    enable_swapfile "$fstype" dd || err "swapon /swapfile failed"
  fi
  install_swap_fstab
  set_swappiness
  log "swap on: /swapfile ($human, swappiness 10)"
}

configure_swap

# 4. System update ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

log "updating apt indexes"
apt-get "${APT_OPTS[@]}" update

log "upgrading packages"
apt-get "${APT_OPTS[@]}" -y upgrade

log "installing prerequisites"
apt-get "${APT_OPTS[@]}" -y install ca-certificates curl gnupg

# 5. Create sudo user, migrate SSH keys -------------------------------------
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

# 6. Docker + Compose plugin ------------------------------------------------
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

# 7. Unattended security upgrades -------------------------------------------
log "enabling unattended-upgrades"
apt-get "${APT_OPTS[@]}" -y install unattended-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# 8. Apply link DNS (before SSH lockdown) ------------------------------------
# systemd-resolved already sends lookups to the pinned servers. Applying
# netplan here clears DHCP resolvers on the interface. Deferred until the
# package installs finish so a network restart cannot cut off `curl | bash`,
# and kept before SSH hardening so a failed apply leaves root login intact.
apply_pinned_dns() {
  [ "$netplan_dns_ready" -eq 1 ] || return 0
  log "applying netplan DNS override"
  if ! netplan apply; then
    rm -f /etc/netplan/99-dns.yaml
    netplan generate >/dev/null 2>&1 || true
    netplan apply || err "netplan apply failed and rollback failed"
    err "netplan apply failed; rolled back the DNS override"
  fi
  systemctl restart systemd-resolved
}

# Every resolver `resolvectl dns` reports must be one we pinned, and each
# pinned server must appear. Catches DHCP resolvers that survived netplan.
dns_is_exact() {
  local line tok
  local -a toks=()
  local -A want=() seen=()
  for tok in "${dns_list[@]}"; do
    want[$tok]=1
  done
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    read -r -a toks <<< "$line" || true
    for tok in "${toks[@]}"; do
      tok=${tok%,}
      tok=${tok%%%*}
      if [[ "$tok" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        :
      elif [[ "$tok" =~ ^[0-9A-Fa-f:]+$ && "$tok" == *:*:* ]]; then
        :
      else
        continue
      fi
      seen[$tok]=1
      [ -n "${want[$tok]:-}" ] || return 1
    done
  done < <(resolvectl dns 2>/dev/null || true)
  for tok in "${dns_list[@]}"; do
    [ -n "${seen[$tok]:-}" ] || return 1
  done
}

apply_pinned_dns
if [ "$netplan_dns_ready" -eq 1 ]; then
  retry dns_is_exact \
    || err "DHCP DNS is still installed (want only: ${dns_list[*]}; resolvectl dns: $(resolvectl dns 2>/dev/null | tr '\n' ' '))"
  log "link DNS pinned: $(resolvectl dns 2>/dev/null | tr '\n' ' ')"
fi

# 9. SSH hardening (LAST — leave root access intact if earlier steps fail) --
log "hardening sshd"
# sshd keeps the first value of each keyword. Ubuntu's sshd_config starts with
# `Include /etc/ssh/sshd_config.d/*.conf`, expanded in lexical order, so
# 50-cloud-init.conf (`PasswordAuthentication yes`) beats a later 99- drop-in.
# 00- is read first and is the value that actually applies.
sshd_conf="/etc/ssh/sshd_config.d/00-hardening.conf"
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

# sshd -t only checks syntax. Confirm the first-match result is the one we set.
effective=$(sshd -T) || { rm -f "$sshd_conf"; err "sshd -T failed; reverted hardening conf"; }
fail=
for pair in \
  "passwordauthentication no" \
  "permitrootlogin no" \
  "kbdinteractiveauthentication no" \
  "pubkeyauthentication yes" \
  "port $SSH_PORT"
do
  key=${pair%% *}
  want=${pair#* }
  got=$(printf '%s\n' "$effective" | awk -v k="$key" '$1==k {print $2; exit}')
  if [ "$got" != "$want" ]; then
    fail+="${key}=${got:-<unset>} (want ${want}); "
  fi
done
if [ -n "$fail" ]; then
  rm -f "$sshd_conf"
  err "sshd effective config does not match hardening (${fail% }); reverted"
fi
rm -f /etc/ssh/sshd_config.d/99-hardening.conf

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

# 10. Done ------------------------------------------------------------------
log "complete"
log "  user:      $USERNAME (groups: sudo, docker)"
log "  ssh port:  $SSH_PORT"
log "  dns:       ${dns_list[*]}"
if [ "$swap_bytes" -eq 0 ]; then
  log "  swap:      disabled"
else
  log "  swap:      /swapfile ($(bytes_human "$swap_bytes"), swappiness 10)"
fi
log "  connect:   ssh -p $SSH_PORT $USERNAME@<host>"
log "  root ssh:  disabled"
