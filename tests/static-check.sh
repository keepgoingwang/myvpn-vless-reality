#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for f in "$ROOT"/*.sh; do bash -n "$f"; done
grep -q 'myvpn-vless-reality-in' "$ROOT/apply-config.sh"
grep -q 'reality-keypair' "$ROOT/install.sh"
grep -q 'myvpn-managed' "$ROOT/firewall.sh"
if grep -q 'sites-enabled/default' "$ROOT/nginx-setup.sh"; then
  echo "ERROR: installer must not delete the global Nginx default site." >&2
  exit 1
fi
if grep -q '^REALITY_PRIVATE_KEY=.' "$ROOT/server.env.example"; then
  echo "ERROR: example env must not contain a private key." >&2
  exit 1
fi
echo "Static checks passed (bash syntax and ownership guardrails)."
