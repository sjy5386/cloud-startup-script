#!/bin/bash
# Paste the contents of this file into your CSP instance's user-data field.
# It downloads and runs setup.sh from this repo's main branch.
set -euo pipefail
export USERNAME="ubuntu"
export SSH_PORT="22"
export DNS_SERVERS="1.1.1.1 1.0.0.1"
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=%s\nFallbackDNS=\nDomains=~.\n' "$DNS_SERVERS" >/etc/systemd/resolved.conf.d/dns.conf
systemctl restart systemd-resolved
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
curl -fsSL https://raw.githubusercontent.com/sjy5386/cloud-startup-script/main/setup.sh | bash
