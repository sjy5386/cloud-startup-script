#!/bin/bash
# Paste the contents of this file into your CSP instance's user-data field.
# It downloads and runs setup.sh from this repo's main branch.
set -euo pipefail
export USERNAME="ubuntu"
export SSH_PORT="22"
curl -fsSL https://raw.githubusercontent.com/sjy5386/cloud-startup-script/main/setup.sh | bash
