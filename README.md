# cloud-startup-script

Automates the initial setup of a fresh Ubuntu LTS cloud instance:

- Create a sudo user and migrate SSH keys from `/root/.ssh/authorized_keys`
- Disable root SSH login and password authentication (public-key only)
- Pin DNS to `1.1.1.1` and `1.0.0.1` (DHCP-provided resolvers are ignored)
- Add a 2G swap file (`vm.swappiness=10`) before package installs
- Install Docker Engine and the Docker Compose plugin
- Enable `unattended-upgrades` for automatic security patches

## Usage

Paste the contents of `bootstrap.sh` into your CSP's user-data field when
creating the instance. That field is limited to 1024 bytes, so keep
`bootstrap.sh` within that size. `.githooks/pre-commit` rejects a commit
that exceeds it. Adjust `USERNAME`, `SSH_PORT`, `DNS_SERVERS`, or
`SWAP_SIZE` at the top of the script if needed.

`bootstrap.sh` pins those resolvers before it installs `curl` or downloads
`setup.sh`. `setup.sh` applies the same resolvers again and ignores DHCP DNS.

After boot, connect as the new user:

```bash
ssh ubuntu@<host>
```

## Environment variables

| Name          | Default           | Description                                             |
|---------------|-------------------|---------------------------------------------------------|
| `USERNAME`    | `ubuntu`          | Name of the sudo user to create                         |
| `SSH_PORT`    | `22`              | sshd listen port (sync with your network firewall too)  |
| `DNS_SERVERS` | `1.1.1.1 1.0.0.1` | Space-separated IPv4 resolvers. DHCP DNS is not used.  |
| `SWAP_SIZE`   | `2G`              | Swap file size (`512M`, `2G`, `2GB`, or `0` to skip). Created at `/swapfile` before package installs. |

## Supported Ubuntu versions

22.04 LTS / 24.04 LTS / 26.04 LTS

## Prerequisites

- `/root/.ssh/authorized_keys` must exist and be non-empty. Those keys are
  migrated to the new user. (The script aborts early if missing, to avoid
  locking you out.)
- Must run as root. CSP user-data runs as root by default.

## Version pinning

For production, prefer a tag-based URL over `main`:

```
https://raw.githubusercontent.com/sjy5386/cloud-startup-script/refs/tags/v1.0.0/setup.sh
```

## Troubleshooting

- DNS in use: `resolvectl dns` (expect only `1.1.1.1` and `1.0.0.1`)
- Swap: `swapon --show` (expect `/swapfile`). `SWAP_SIZE=0` skips it.
  Creation fails before packages are installed when `/` does not have the
  swap size plus 1 GiB free.
- If setup stops at `name resolution failed`, the instance cannot reach the
  pinned resolvers on port 53.
- Execution log: `/var/log/cloud-init-output.log`
- SSH hardening is the last step, so a failure earlier in the script leaves
  existing root SSH access intact.
- Setting `SSH_PORT` to anything other than `22` disables Ubuntu 22.10+'s
  socket-activated `ssh.socket` and switches to the regular `ssh.service`
  so the `Port` directive takes effect.
