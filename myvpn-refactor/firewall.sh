#!/usr/bin/env bash
set -Eeuo pipefail

COMMENT="myvpn-managed"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root." >&2
  exit 1
fi

status_text() { ufw status numbered 2>/dev/null || true; }

has_managed_rule() {
  local port="$1" proto="$2"
  status_text | grep -F "# ${COMMENT}" | grep -Eq "(^|[[:space:]])${port}/${proto}([[:space:]]|$)"
}

has_broad_allow() {
  local port="$1" proto="$2"
  # Do not duplicate a pre-existing globally allowed rule owned by another tool/person.
  status_text | awk -v target="${port}/${proto}" '
    {
      line=$0
      sub(/^[[:space:]]*\[[[:space:]]*[0-9]+[[:space:]]*\][[:space:]]*/, "", line)
      if (line ~ ("^" target "([[:space:]]|$)") && /ALLOW IN/ && /Anywhere/ && $0 !~ /\(v6\)/ && $0 !~ /# myvpn-managed/) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

ensure_rule() {
  local port="$1" proto="$2"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port: $port" >&2; return 1; }
  (( port >= 1 && port <= 65535 )) || { echo "Port out of range: $port" >&2; return 1; }
  if has_managed_rule "$port" "$proto"; then
    echo "UFW: managed rule already exists: ${port}/${proto}"
  elif has_broad_allow "$port" "$proto"; then
    echo "UFW: ${port}/${proto} is already broadly allowed by an existing rule; leaving it untouched."
  else
    ufw allow "${port}/${proto}" comment "$COMMENT"
    if [[ -n "${MYVPN_FIREWALL_JOURNAL:-}" ]]; then
      printf '%s/%s\n' "$port" "$proto" >> "$MYVPN_FIREWALL_JOURNAL"
    fi
    echo "UFW: added managed rule: ${port}/${proto}"
  fi
}

remove_managed_port() {
  local port="$1" proto="$2" number
  while :; do
    number="$(status_text | sed -nE "/# ${COMMENT}/ { /^[[:space:]]*\[[[:space:]]*[0-9]+[[:space:]]*\][[:space:]]*${port}\/${proto}([[:space:]]|$)/ { s/^[[:space:]]*\[[[:space:]]*([0-9]+)[[:space:]]*\].*/\1/p; q; } }")"
    [[ -n "$number" ]] || break
    local before after
    before="$(status_text)"
    ufw --force delete "$number" >/dev/null || return 1
    after="$(status_text)"
    [[ "$after" != "$before" ]] || { echo "ERROR: UFW rule deletion did not change the ruleset; stopping to avoid a loop." >&2; return 1; }
    echo "UFW: removed project-owned rule ${port}/${proto} (#${number})"
  done
}

remove_managed_rules() {
  if ! command -v ufw >/dev/null 2>&1; then return 0; fi
  while :; do
    local number
    number="$(status_text | sed -n "/# ${COMMENT}/ { s/^[[:space:]]*\\[[[:space:]]*\\([0-9][0-9]*\\)[[:space:]]*\\].*/\\1/p; q; }")"
    [[ -n "$number" ]] || break
    local before after
    before="$(status_text)"
    ufw --force delete "$number" >/dev/null || return 1
    after="$(status_text)"
    [[ "$after" != "$before" ]] || { echo "ERROR: UFW rule deletion did not change the ruleset; stopping to avoid a loop." >&2; return 1; }
    echo "UFW: removed project-owned rule #${number}"
  done
}

case "${1:-}" in
  ensure)
    # Arguments: ssh-port, proxy-port, nginx-http-port
    [[ $# -eq 4 ]] || { echo "Usage: $0 ensure SSH_PORT PROXY_PORT NGINX_HTTP_PORT" >&2; exit 2; }
    if ! command -v ufw >/dev/null 2>&1; then echo "ERROR: UFW not installed." >&2; exit 1; fi
    if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
      echo "UFW is inactive; not enabling it or changing its rules. Open the needed ports in the cloud security group, or explicitly enable UFW after reviewing the host's other services."
      exit 0
    fi
    ensure_rule "$2" tcp
    ensure_rule "$3" tcp
    ensure_rule "$4" tcp
    echo
    echo "Current UFW status:"
    ufw status numbered || true
    echo "Note: the cloud security group is separate and must allow TCP ${3} and TCP ${4}."
    ;;
  remove)
    remove_managed_rules
    ;;
  rollback)
    [[ $# -eq 2 && -f "$2" ]] || { echo "Usage: $0 rollback JOURNAL_FILE" >&2; exit 2; }
    while IFS= read -r rule; do
      [[ "$rule" =~ ^([0-9]{1,5})/(tcp|udp)$ ]] || continue
      remove_managed_port "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    done < "$2"
    ;;
  *) echo "Usage: $0 {ensure SSH_PORT PROXY_PORT NGINX_HTTP_PORT|remove|rollback JOURNAL_FILE}" >&2; exit 2 ;;
esac
