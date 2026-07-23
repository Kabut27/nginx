#!/usr/bin/env bash
#
# deploy-nginx.sh
# Interactive nginx reverse-proxy setup for 3x-ui + extra services (Xray inbound,
# panel, sub/user endpoint, etc.) fronted by a single domain over 80/443.
#
# Usage:
#   sudo bash deploy-nginx.sh
#
# Repo: keep this in your own github repo and just:
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/deploy-nginx.sh -o deploy-nginx.sh
#   sudo bash deploy-nginx.sh
#
set -euo pipefail

NGINX_CONF="/etc/nginx/sites-available/default"
BACKUP_DIR="/etc/nginx/sites-available/backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '\033[36m[i]\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$1"; }
err()  { printf '\033[31m[!]\033[0m %s\n' "$1" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Run this as root (sudo bash deploy-nginx.sh)."
    exit 1
  fi
}

ask() {
  # ask "prompt" "default"  -> echoes the answer
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    echo "$answer"
  fi
}

ask_yes_no() {
  # ask_yes_no "prompt" "default(y/n)"
  local prompt="$1" default="${2:-y}" answer
  read -r -p "$prompt [y/n, default $default]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

require_root

bold "=== Rayoo / 3x-ui nginx deploy script ==="
info "This will build /etc/nginx/sites-available/default from scratch based on your answers."
echo

DOMAIN="$(ask "Domain name (server_name)" "rayoo.uk")"

echo
CERT_BASE="/root/cert"
info "SSL certificates are always expected under ${CERT_BASE}/<domain>/"
CERT_PATH="${CERT_BASE}/${DOMAIN}/fullchain.pem"
KEY_PATH="${CERT_BASE}/${DOMAIN}/privkey.pem"
info "Full chain cert path: $CERT_PATH"
info "Private key path:     $KEY_PATH"

ENABLE_SSL=true
if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
  err "Certificate or key not found at given paths."
  if ask_yes_no "Continue anyway and configure HTTPS server block regardless?" "n"; then
    ENABLE_SSL=true
  else
    ENABLE_SSL=false
    info "Will only configure the port 80 server block."
  fi
fi

echo
bold "--- Default catch-all backend (location /) ---"
info "This location is always required: it catches any path and proxies to your main"
info "VLESS/HTTPUpgrade inbound, with Upgrade/Connection headers already included."
DEFAULT_PORT="$(ask "Default backend port (httpupgrade inbound)" "10000")"

echo
bold "--- Extra locations ---"
info "Add as many reverse-proxy locations as you need (e.g. /kabut for a websocket inbound,"
info "/rayoo/ for the 3x-ui panel, /user/ for a subscription endpoint, etc.)"
info "Enter blank path when done."

declare -a LOC_PATHS=()
declare -a LOC_PORTS=()
declare -a LOC_WS=()
declare -a LOC_BUFOFF=()

while true; do
  echo
  LOC_PATH="$(ask "Location path (e.g. /kabut or /rayoo/) [blank to finish]" "")"
  [[ -z "$LOC_PATH" ]] && break
  LOC_PORT="$(ask "  Backend port for $LOC_PATH" "")"
  if [[ -z "$LOC_PORT" ]]; then
    err "  No port given, skipping this location."
    continue
  fi
  if ask_yes_no "  Is this a websocket/upgrade-capable backend (panel, xhttp, ws)?" "y"; then
    LOC_WS+=("1")
  else
    LOC_WS+=("0")
  fi
  if ask_yes_no "  Disable buffering for this location (good for streaming/xray inbounds)?" "n"; then
    LOC_BUFOFF+=("1")
  else
    LOC_BUFOFF+=("0")
  fi
  LOC_PATHS+=("$LOC_PATH")
  LOC_PORTS+=("$LOC_PORT")
  ok "  Added: $LOC_PATH -> 127.0.0.1:$LOC_PORT"
done

# ---- render one location block ----
render_location() {
  local path="$1" port="$2" ws="$3" bufoff="$4"
  local target="$path"
  # if the path ends without a trailing slash and proxy_pass should include it as-is (no rewrite),
  # keep proxy_pass target matching the path so upstream sees the same prefix.
  echo "    location $path {"
  if [[ "$path" == "/" ]]; then
    echo "        rewrite ^ / break;"
    echo "        proxy_pass http://127.0.0.1:${port};"
  else
    echo "        proxy_pass http://127.0.0.1:${port}${target};"
  fi
  echo "        proxy_http_version 1.1;"
  if [[ "$ws" == "1" ]]; then
    echo "        proxy_set_header Upgrade \$http_upgrade;"
    echo "        proxy_set_header Connection \"upgrade\";"
  fi
  echo "        proxy_set_header Host \$host;"
  echo "        proxy_set_header X-Real-IP \$remote_addr;"
  echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
  echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
  if [[ "$bufoff" == "1" ]]; then
    echo "        proxy_buffering off;"
    echo "        proxy_request_buffering off;"
  fi
  echo "        proxy_read_timeout 300s;"
  echo "        proxy_send_timeout 300s;"
  echo "    }"
}

render_server_body() {
  local i
  for i in "${!LOC_PATHS[@]}"; do
    render_location "${LOC_PATHS[$i]}" "${LOC_PORTS[$i]}" "${LOC_WS[$i]}" "${LOC_BUFOFF[$i]}"
    echo
  done
  render_location "/" "$DEFAULT_PORT" "1" "0"
}

# ---- backup existing config ----
mkdir -p "$BACKUP_DIR"
if [[ -f "$NGINX_CONF" ]]; then
  cp "$NGINX_CONF" "${BACKUP_DIR}/default.${TIMESTAMP}.bak"
  ok "Backed up existing config to ${BACKUP_DIR}/default.${TIMESTAMP}.bak"
fi

# ---- write config ----
{
  echo "server {"
  echo "    listen 80;"
  echo "    listen [::]:80;"
  echo "    server_name ${DOMAIN};"
  echo
  render_server_body
  echo "}"
  echo

  if [[ "$ENABLE_SSL" == "true" ]]; then
    echo "server {"
    echo "    listen 443 ssl;"
    echo "    listen [::]:443 ssl;"
    echo "    server_name ${DOMAIN};"
    echo
    echo "    ssl_certificate     ${CERT_PATH};"
    echo "    ssl_certificate_key ${KEY_PATH};"
    echo
    render_server_body
    echo "}"
  fi
} > "$NGINX_CONF"

ok "Wrote new config to $NGINX_CONF"
echo
bold "--- Preview ---"
cat "$NGINX_CONF"
echo

if nginx -t; then
  ok "nginx config test passed."
  if ask_yes_no "Reload nginx now?" "y"; then
    systemctl reload nginx
    ok "nginx reloaded."
  fi
else
  err "nginx config test FAILED. Restoring previous config."
  if [[ -f "${BACKUP_DIR}/default.${TIMESTAMP}.bak" ]]; then
    cp "${BACKUP_DIR}/default.${TIMESTAMP}.bak" "$NGINX_CONF"
    err "Restored backup. Please fix the issue above and re-run."
  fi
  exit 1
fi

echo
bold "=== Done ==="
info "Domain: $DOMAIN"
for i in "${!LOC_PATHS[@]}"; do
  info "  ${LOC_PATHS[$i]} -> 127.0.0.1:${LOC_PORTS[$i]}"
done
info "  / -> 127.0.0.1:${DEFAULT_PORT}"
[[ "$ENABLE_SSL" == "true" ]] && info "HTTPS enabled with cert: $CERT_PATH"
info "Reminder: any backend you proxy to a public path (panel, sub endpoint) should"
info "have its own Listen IP set to 127.0.0.1 so it can't be reached bypassing nginx."
