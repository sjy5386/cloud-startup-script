#!/bin/bash
# CSP user-data, 1024-byte limit. Downloads setup.sh from main.
set -euo pipefail
export USERNAME=ubuntu SSH_PORT=22 DNS_SERVERS='1.1.1.1 1.0.0.1' DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=%s\nFallbackDNS=\nDomains=~.\n' "$DNS_SERVERS" >/etc/systemd/resolved.conf.d/dns.conf
systemctl restart systemd-resolved
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
curl -fsSL https://raw.githubusercontent.com/sjy5386/cloud-startup-script/main/setup.sh | bash
