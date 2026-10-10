#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sudo "$SCRIPT_DIR/apply-config.sh"
sudo systemctl restart nginx
sudo "$SCRIPT_DIR/healthcheck.sh"
