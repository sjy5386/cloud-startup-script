# cloud-startup-script

Automates the initial setup of a fresh Ubuntu LTS cloud instance:

- Create a sudo user and migrate SSH keys from `/root/.ssh/authorized_keys`
- Disable root SSH login and password authentication (public-key only)
- Install Docker Engine and the Docker Compose plugin
- Enable `unattended-upgrades` for automatic security patches

## Usage

Paste the contents of `bootstrap.sh` into your CSP's user-data field when
creating the instance. Adjust `USERNAME` or `SSH_PORT` at the top of the
script if needed.

After boot, connect as the new user:

```bash
ssh ubuntu@<host>
```

## Environment variables

| Name        | Default  | Description                                              |
|-------------|----------|----------------------------------------------------------|
| `USERNAME`  | `ubuntu` | Name of the sudo user to create                          |
| `SSH_PORT`  | `22`     | sshd listen port (sync with your network firewall too)   |

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

- Execution log: `/var/log/cloud-init-output.log`
- SSH hardening is the last step, so a failure earlier in the script leaves
  existing root SSH access intact.
- Setting `SSH_PORT` to anything other than `22` disables Ubuntu 22.10+'s
  socket-activated `ssh.socket` and switches to the regular `ssh.service`
  so the `Port` directive takes effect.
