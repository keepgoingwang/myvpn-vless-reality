#!/usr/bin/env bash
set -Eeuo pipefail
sudo /opt/my-vpn/apply-config.sh
sudo systemctl restart nginx
sudo /opt/my-vpn/healthcheck.sh
