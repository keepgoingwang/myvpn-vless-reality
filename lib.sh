#!/usr/bin/env bash
# Shared helpers for MyVPN scripts. Values written by these helpers are simple
# scalar fields (UUID, keys, port, hostname, IPv4), not arbitrary shell code.

myvpn_is_ipv4() {
  local value="${1:-}" a b c d octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$value"
  for octet in "$a" "$b" "$c" "$d"; do
    # Force base 10, avoiding octal interpretation of leading zeros.
    (( 10#$octet <= 255 )) || return 1
  done
}

myvpn_detect_public_ipv4() {
  local url candidate
  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://checkip.amazonaws.com"; do
    candidate="$(curl -4 -fsSL --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if myvpn_is_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

myvpn_set_env_value() {
  local env_file="$1" key="$2" value="$3" tmp mode escaped
  [[ -f "$env_file" ]] || { echo "ERROR: env file not found: $env_file" >&2; return 1; }
  printf -v escaped '%q' "$value"
  tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
  mode="$(stat -c '%a' "$env_file" 2>/dev/null || printf '600')"
  # Replace only the first matching assignment, drop duplicate assignments for this key,
  # and append the key if it does not exist. The values supplied here have no newlines.
  awk -v key="$key" -v value="$escaped" '
    BEGIN { found = 0; prefix = key "=" }
    index($0, prefix) == 1 {
      if (!found) { print prefix value; found = 1 }
      next
    }
    { print }
    END { if (!found) print prefix value }
  ' "$env_file" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$env_file"
}
