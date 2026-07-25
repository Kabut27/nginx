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

# ---- fully-automatic wildcard cert (acme.sh + Cloudflare DNS-01) ----
CF_TOKEN_FILE="/root/.cf_api_token"

ensure_acme() {
  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    info "acme.sh haijasakinishwa — inasakinisha sasa (moja kwa moja)..."
    curl -s https://get.acme.sh | sh -s email="admin@${1}" >/dev/null 2>&1
    ok "acme.sh imesakinishwa."
  fi
}

issue_wildcard_cert() {
  # issues/installs a single *.<apex> + <apex> cert, fully automatic + auto-renewing
  local apex="$1"
  local cert_dir="${CERT_BASE}/${apex}"
  mkdir -p "$cert_dir"

  if [[ -f "${cert_dir}/fullchain.pem" && -f "${cert_dir}/privkey.pem" ]]; then
    chmod 700 "$cert_dir"; chmod 600 "${cert_dir}/privkey.pem"; chmod 644 "${cert_dir}/fullchain.pem"
    info "Wildcard cert tayari ipo kwa ${apex} (${cert_dir}) — acme.sh cron itaifanyia renew moja kwa moja."
    return
  fi

  local cf_token=""
  if [[ -f "$CF_TOKEN_FILE" ]]; then
    cf_token="$(cat "$CF_TOKEN_FILE")"
  else
    cf_token="$(ask "Cloudflare API Token (Zone:DNS:Edit, scope ${apex})" "")"
    if [[ -z "$cf_token" ]]; then
      err "Hakuna CF API token — siwezi kutoa wildcard cert moja kwa moja."
      info "Weka cert mwenyewe kwenye ${cert_dir}/fullchain.pem na ${cert_dir}/privkey.pem, kisha rerun script."
      return
    fi
    echo -n "$cf_token" > "$CF_TOKEN_FILE"
    chmod 600 "$CF_TOKEN_FILE"
    ok "CF API token imehifadhiwa kwa matumizi ya baadaye (${CF_TOKEN_FILE})."
  fi
  export CF_Token="$cf_token"

  ensure_acme "$apex"

  info "Inatoa wildcard cert ya *.${apex} + ${apex} kupitia Cloudflare DNS-01 (moja kwa moja)..."
  if "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "${apex}" -d "*.${apex}" --server letsencrypt; then
    "$HOME/.acme.sh/acme.sh" --install-cert -d "${apex}" \
      --key-file       "${cert_dir}/privkey.pem" \
      --fullchain-file "${cert_dir}/fullchain.pem" \
      --reloadcmd "systemctl reload nginx"
    chmod 700 "$cert_dir"; chmod 600 "${cert_dir}/privkey.pem"; chmod 644 "${cert_dir}/fullchain.pem"
    ok "Wildcard cert imewekwa: ${cert_dir}/fullchain.pem (auto-renew imewashwa)."
  else
    err "Utoaji wa cert umeshindwa. Angalia CF_Token (Zone:DNS:Edit) na kwamba ${apex} iko Cloudflare."
    rm -f "$CF_TOKEN_FILE"
  fi
}

STATE_FILE="/etc/nginx-deploy-state.sh"
ADD_ONLY_MODE=false

bold "=== nginx reverse-proxy deploy script (3x-ui / Xray) ==="

# ---- ensure nginx is installed ----
if command -v nginx >/dev/null 2>&1; then
  info "nginx is installed: $(nginx -v 2>&1 | sed 's/nginx version: //')"
else
  err "nginx is not installed on this server."
  if ask_yes_no "Install nginx now?" "y"; then
    apt-get update -y
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
    ok "nginx installed: $(nginx -v 2>&1 | sed 's/nginx version: //')"
  else
    err "nginx is required to continue. Exiting."
    exit 1
  fi
fi

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  info "Found a saved setup for domain: ${DOMAIN:-unknown}"
  if ask_yes_no "Just add new location(s) to this existing setup? (fast, no re-typing)" "y"; then
    ADD_ONLY_MODE=true
    ok "Reusing saved domain, certs, and $(( ${#LOC_PATHS[@]} )) existing location(s)."
  else
    info "Starting a full rebuild — you'll be asked everything again."
  fi
fi

if [[ "$ADD_ONLY_MODE" != "true" ]]; then
info "This will build /etc/nginx/sites-available/default from scratch based on your answers."
echo

DOMAIN="$(ask "Domain kuu / apex (bila subdomain — mfano yourdomain.com)" "example.com")"
SERVER_NAME_LINE="*.${DOMAIN} ${DOMAIN}"
info "server_name itakuwa: ${SERVER_NAME_LINE}  (inafunika subdomain zote — a., 2., n.k.)"

echo
CERT_BASE="/root/cert"
issue_wildcard_cert "$DOMAIN"
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
bold "--- Camouflage fallback website ---"
info "Ordinary browsers hitting / (no Upgrade header) can be shown a real-looking"
info "website instead of an empty/error response, while your VLESS/HTTPUpgrade"
info "client keeps working on any path exactly as before."
ENABLE_FALLBACK=false
FALLBACK_DIR="/var/www/fallback"
if ask_yes_no "Enable the camouflage fallback website?" "y"; then
  ENABLE_FALLBACK=true
  FALLBACK_DIR="$(ask "Directory to serve the fallback site from" "/var/www/fallback")"
  mkdir -p "$FALLBACK_DIR"
  if [[ -f "${FALLBACK_DIR}/index.html" ]]; then
    info "index.html already exists at ${FALLBACK_DIR}, leaving it as-is."
  else
    cat > "${FALLBACK_DIR}/index.html" <<'FALLBACKHTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Kabuti Grid — Network Infrastructure Monitoring</title>
<meta name="description" content="Kabuti Grid provides real-time infrastructure monitoring, uptime tracking, and network health analytics for distributed systems.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root{
    --bg:#060e16;
    --surface:#0c1c28;
    --surface-2:#102534;
    --line:#16303f;
    --teal:#29e0c9;
    --teal-dim:#1a4a45;
    --orange:#f5a524;
    --text:#e7f3f1;
    --text-muted:#6f8894;
    --radius:14px;
  }

  *{box-sizing:border-box; margin:0; padding:0;}

  html{scroll-behavior:smooth;}

  body{
    background:
      radial-gradient(ellipse 900px 500px at 15% -10%, rgba(41,224,201,0.08), transparent 60%),
      radial-gradient(ellipse 700px 500px at 100% 10%, rgba(245,165,36,0.05), transparent 60%),
      var(--bg);
    color:var(--text);
    font-family:'Inter', -apple-system, sans-serif;
    line-height:1.5;
    min-height:100vh;
  }

  @media (prefers-reduced-motion: reduce){
    *{animation-duration:0.01ms !important; animation-iteration-count:1 !important; transition-duration:0.01ms !important;}
  }

  a{color:inherit; text-decoration:none;}

  .wrap{max-width:1080px; margin:0 auto; padding:0 24px;}

  /* Nav */
  nav{
    display:flex; align-items:center; justify-content:space-between;
    padding:28px 0;
  }
  .brand{
    display:flex; align-items:center; gap:10px;
    font-family:'Space Grotesk', sans-serif;
    font-weight:600; font-size:1.05rem;
    letter-spacing:0.01em;
  }
  .brand-mark{
    width:28px; height:28px; border-radius:8px;
    background:linear-gradient(135deg, var(--teal), #158f80);
    display:flex; align-items:center; justify-content:center;
    box-shadow:0 0 18px rgba(41,224,201,0.45);
  }
  .brand-mark svg{width:15px; height:15px;}
  nav .links{display:flex; gap:32px; font-size:0.9rem; color:var(--text-muted);}
  nav .links a:hover{color:var(--text);}
  .status-pill{
    display:flex; align-items:center; gap:8px;
    font-family:'JetBrains Mono', monospace;
    font-size:0.78rem; color:var(--teal);
    background:rgba(41,224,201,0.07);
    border:1px solid rgba(41,224,201,0.25);
    padding:6px 12px; border-radius:100px;
  }
  .dot{width:6px; height:6px; border-radius:50%; background:var(--teal); box-shadow:0 0 8px var(--teal); animation:pulse 2.4s ease-in-out infinite;}
  @keyframes pulse{0%,100%{opacity:1;} 50%{opacity:0.35;}}

  /* Hero */
  .hero{
    display:grid;
    grid-template-columns:1.15fr 0.85fr;
    gap:56px;
    align-items:center;
    padding:56px 0 88px;
  }
  .eyebrow{
    font-family:'JetBrains Mono', monospace;
    font-size:0.78rem; color:var(--orange);
    letter-spacing:0.12em; text-transform:uppercase;
    margin-bottom:18px; display:block;
  }
  h1{
    font-family:'Space Grotesk', sans-serif;
    font-size:clamp(2.1rem, 4.4vw, 3.4rem);
    font-weight:700; letter-spacing:-0.02em;
    line-height:1.08;
    margin-bottom:20px;
  }
  h1 .accent{color:var(--teal);}
  .lede{color:var(--text-muted); font-size:1.05rem; max-width:46ch; margin-bottom:32px;}
  .cta-row{display:flex; gap:14px; flex-wrap:wrap;}
  .btn{
    font-family:'Inter', sans-serif; font-weight:600; font-size:0.92rem;
    padding:13px 24px; border-radius:10px;
    display:inline-flex; align-items:center; gap:8px;
  }
  .btn-primary{
    background:var(--teal); color:#04211d;
    box-shadow:0 0 0 rgba(41,224,201,0); transition:box-shadow 0.25s ease, transform 0.15s ease;
  }
  .btn-primary:hover{box-shadow:0 0 28px rgba(41,224,201,0.35); transform:translateY(-1px);}
  .btn-ghost{
    border:1px solid var(--line); color:var(--text);
    transition:border-color 0.2s ease;
  }
  .btn-ghost:hover{border-color:var(--teal);}

  /* Signature ring */
  .ring-card{
    background:var(--surface);
    border:1px solid var(--line);
    border-radius:20px;
    padding:32px;
    display:flex; flex-direction:column; align-items:center; gap:20px;
  }
  .ring-label{
    font-family:'JetBrains Mono', monospace;
    font-size:0.72rem; color:var(--text-muted);
    letter-spacing:0.12em; text-transform:uppercase;
  }
  .ring{
    position:relative; width:190px; height:190px;
  }
  .ring svg{transform:rotate(-90deg); width:100%; height:100%;}
  .ring-track{fill:none; stroke:var(--line); stroke-width:10;}
  .ring-fill{
    fill:none; stroke:var(--teal); stroke-width:10; stroke-linecap:round;
    stroke-dasharray:534; stroke-dashoffset:11;
    filter:drop-shadow(0 0 8px rgba(41,224,201,0.55));
    animation:draw 1.6s cubic-bezier(0.4,0,0.2,1) both;
  }
  @keyframes draw{from{stroke-dashoffset:534;} to{stroke-dashoffset:11;}}
  .ring-center{
    position:absolute; inset:0; display:flex; flex-direction:column;
    align-items:center; justify-content:center;
  }
  .ring-pct{font-family:'Space Grotesk', sans-serif; font-size:2.4rem; font-weight:700;}
  .ring-sub{font-family:'JetBrains Mono', monospace; font-size:0.7rem; color:var(--text-muted); margin-top:4px;}
  .ring-meta{
    display:flex; gap:24px; font-family:'JetBrains Mono', monospace; font-size:0.78rem;
  }
  .ring-meta div{text-align:center;}
  .ring-meta .n{color:var(--orange); font-size:0.95rem; font-weight:600;}
  .ring-meta .l{color:var(--text-muted); font-size:0.68rem; margin-top:2px;}

  /* Stat cards */
  .stats{
    display:grid; grid-template-columns:repeat(4, 1fr); gap:16px;
    padding:8px 0 72px;
  }
  .stat{
    background:var(--surface);
    border:1px solid var(--line);
    border-radius:var(--radius);
    padding:22px 20px;
  }
  .stat .k{
    font-family:'Space Grotesk', sans-serif; font-size:1.7rem; font-weight:600;
  }
  .stat .k .u{font-size:1rem; color:var(--teal); margin-left:2px;}
  .stat .l{color:var(--text-muted); font-size:0.82rem; margin-top:6px;}

  /* Section */
  .section{padding:64px 0; border-top:1px solid var(--line);}
  .section-head{max-width:52ch; margin-bottom:44px;}
  .section-head .eyebrow{margin-bottom:12px;}
  .section-head h2{
    font-family:'Space Grotesk', sans-serif; font-size:1.9rem; font-weight:700;
    letter-spacing:-0.01em; margin-bottom:12px;
  }
  .section-head p{color:var(--text-muted);}

  .grid3{display:grid; grid-template-columns:repeat(3, 1fr); gap:20px;}
  .card{
    background:var(--surface);
    border:1px solid var(--line);
    border-radius:var(--radius);
    padding:26px;
    transition:border-color 0.2s ease, transform 0.2s ease;
  }
  .card:hover{border-color:var(--teal-dim); transform:translateY(-2px);}
  .card .icon{
    width:38px; height:38px; border-radius:9px;
    background:var(--surface-2); border:1px solid var(--line);
    display:flex; align-items:center; justify-content:center;
    margin-bottom:16px; color:var(--teal);
  }
  .card h3{font-family:'Space Grotesk', sans-serif; font-size:1.05rem; margin-bottom:8px;}
  .card p{color:var(--text-muted); font-size:0.9rem;}

  footer{
    border-top:1px solid var(--line);
    padding:32px 0 48px;
    display:flex; justify-content:space-between; align-items:center;
    flex-wrap:wrap; gap:12px;
    color:var(--text-muted); font-size:0.82rem;
  }
  footer .links{display:flex; gap:22px;}
  footer a:hover{color:var(--text);}

  @media (max-width:860px){
    .hero{grid-template-columns:1fr; gap:40px;}
    .stats{grid-template-columns:repeat(2,1fr);}
    .grid3{grid-template-columns:1fr;}
    nav .links{display:none;}
  }

  :focus-visible{outline:2px solid var(--teal); outline-offset:3px; border-radius:4px;}
</style>
</head>
<body>

<div class="wrap">
  <nav>
    <div class="brand">
      <span class="brand-mark">
        <svg viewBox="0 0 24 24" fill="none"><path d="M4 12c0-4.4 3.6-8 8-8s8 3.6 8 8" stroke="#04211d" stroke-width="2.4" stroke-linecap="round"/><circle cx="12" cy="18" r="2" fill="#04211d"/></svg>
      </span>
      Kabuti Grid
    </div>
    <div class="links">
      <a href="#platform">Platform</a>
      <a href="#regions">Regions</a>
      <a href="#status">Status</a>
    </div>
    <div class="status-pill"><span class="dot"></span> All systems operational</div>
  </nav>

  <section class="hero">
    <div>
      <span class="eyebrow">Infrastructure monitoring</span>
      <h1>Know the moment<br>your network <span class="accent">breathes wrong.</span></h1>
      <p class="lede">Kabuti Grid watches latency, throughput, and uptime across every node you run — so incidents get caught in seconds, not support tickets.</p>
      <div class="cta-row">
        <a href="#platform" class="btn btn-primary">View live status</a>
        <a href="#regions" class="btn btn-ghost">See coverage map</a>
      </div>
    </div>

    <div class="ring-card">
      <span class="ring-label">Network Health — 30d</span>
      <div class="ring">
        <svg viewBox="0 0 200 200">
          <circle class="ring-track" cx="100" cy="100" r="85"/>
          <circle class="ring-fill" cx="100" cy="100" r="85"/>
        </svg>
        <div class="ring-center">
          <div class="ring-pct">99.98%</div>
          <div class="ring-sub">UPTIME</div>
        </div>
      </div>
      <div class="ring-meta">
        <div><div class="n">14 ms</div><div class="l">AVG LATENCY</div></div>
        <div><div class="n">6</div><div class="l">REGIONS</div></div>
        <div><div class="n">2</div><div class="l">INCIDENTS/YR</div></div>
      </div>
    </div>
  </section>

  <section class="stats" id="status">
    <div class="stat"><div class="k">312<span class="u">TB</span></div><div class="l">Traffic analyzed this month</div></div>
    <div class="stat"><div class="k">99.98<span class="u">%</span></div><div class="l">Rolling 30-day uptime</div></div>
    <div class="stat"><div class="k">6</div><div class="l">Monitored regions</div></div>
    <div class="stat"><div class="k">&lt;30<span class="u">s</span></div><div class="l">Median alert time</div></div>
  </section>

  <section class="section" id="platform">
    <div class="section-head">
      <span class="eyebrow">Platform</span>
      <h2>Built for people who get paged at 3am</h2>
      <p>Three things Kabuti Grid does well, and does quietly, so you don't have to think about it until you need to.</p>
    </div>
    <div class="grid3">
      <div class="card">
        <div class="icon"><svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M13 2 4 14h7l-1 8 9-12h-7l1-8Z" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/></svg></div>
        <h3>Realtime probes</h3>
        <p>TCP and latency checks every few seconds from independent vantage points, so a blip in one region never hides behind an average.</p>
      </div>
      <div class="card">
        <div class="icon"><svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 3v18M3 12h18" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.8"/></svg></div>
        <h3>Regional coverage</h3>
        <p>Nodes across six regions give you a real picture of how your infrastructure behaves for the people actually using it.</p>
      </div>
      <div class="card">
        <div class="icon"><svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 2 3 7v6c0 5 4 8 9 9 5-1 9-4 9-9V7l-9-5Z" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/></svg></div>
        <h3>Quiet alerting</h3>
        <p>One notification when something's actually wrong. No duplicate pages, no noise dashboards nobody reads.</p>
      </div>
    </div>
  </section>

  <section class="section" id="regions">
    <div class="section-head">
      <span class="eyebrow">Coverage</span>
      <h2>Six regions, one view</h2>
      <p>Every probe reports back to the same pane, whichever region it's watching.</p>
    </div>
    <div class="grid3">
      <div class="card"><h3>EU-West</h3><p style="margin-top:4px">12 ms median · operational</p></div>
      <div class="card"><h3>EU-North</h3><p style="margin-top:4px">18 ms median · operational</p></div>
      <div class="card"><h3>EU-Central</h3><p style="margin-top:4px">9 ms median · operational</p></div>
    </div>
  </section>

  <footer>
    <div>© 2026 Kabuti Grid. All systems nominal.</div>
    <div class="links">
      <a href="#status">Status</a>
      <a href="#platform">Platform</a>
      <a href="#regions">Regions</a>
    </div>
  </footer>
</div>

</body>
</html>

FALLBACKHTML
    ok "Wrote default camouflage site to ${FALLBACK_DIR}/index.html"
  fi
fi
fi

echo
bold "--- Extra locations ---"
if [[ "$ADD_ONLY_MODE" == "true" ]]; then
  info "Existing locations:"
  for i in "${!LOC_PATHS[@]}"; do
    info "  ${LOC_PATHS[$i]} -> 127.0.0.1:${LOC_PORTS[$i]}"
  done
  info "Add the new one(s) below."
fi
info "Add as many reverse-proxy locations as you need (e.g. /yourpath for a websocket inbound,"
info "/panel/ for the 3x-ui panel, /user/ for a subscription endpoint, etc.)"
info "Enter blank path when done."

if [[ "$ADD_ONLY_MODE" != "true" ]]; then
  declare -a LOC_PATHS=()
  declare -a LOC_PORTS=()
  declare -a LOC_WS=()
  declare -a LOC_BUFOFF=()
fi

# ---- add or replace a location, never duplicate an existing path ----
add_or_replace_location() {
  local path="$1" port="$2" ws="$3" bufoff="$4"
  local i
  for i in "${!LOC_PATHS[@]}"; do
    if [[ "${LOC_PATHS[$i]}" == "$path" ]]; then
      LOC_PORTS[$i]="$port"
      LOC_WS[$i]="$ws"
      LOC_BUFOFF[$i]="$bufoff"
      info "  $path already existed — updated to -> 127.0.0.1:${port} (no duplicate created)."
      return
    fi
  done
  LOC_PATHS+=("$path")
  LOC_PORTS+=("$port")
  LOC_WS+=("$ws")
  LOC_BUFOFF+=("$bufoff")
  ok "  Added: $path -> 127.0.0.1:${port}"
}

if ask_yes_no "Quick-add your standard VLESS httpupgrade paths (/1-10001, /2-10002, /3-10003, /4-10004)?" "y"; then
  for n in 1 2 3 4; do
    p=$((10000 + n))
    add_or_replace_location "/${n}" "$p" "1" "1"
  done
  echo
  info "You can still add more locations below, or leave blank to finish."
fi

while true; do
  echo
  LOC_PATH="$(ask "Location path (e.g. /yourpath or /panel/) [blank to finish]" "")"
  [[ -z "$LOC_PATH" ]] && break
  LOC_PORT="$(ask "  Backend port for $LOC_PATH" "")"
  if [[ -z "$LOC_PORT" ]]; then
    err "  No port given, skipping this location."
    continue
  fi
  if ask_yes_no "  Is this a websocket/upgrade-capable backend (panel, xhttp, ws)?" "y"; then
    ws_val="1"
  else
    ws_val="0"
  fi
  if ask_yes_no "  Disable buffering for this location (good for streaming/xray inbounds)?" "n"; then
    bufoff_val="1"
  else
    bufoff_val="0"
  fi
  add_or_replace_location "$LOC_PATH" "$LOC_PORT" "$ws_val" "$bufoff_val"
done

# ---- render one location block ----
render_location() {
  local path="$1" port="$2" ws="$3" bufoff="$4"
  local target="$path"
  # if the path ends without a trailing slash and proxy_pass should include it as-is (no rewrite),
  # keep proxy_pass target matching the path so upstream sees the same prefix.
  echo "    location $path {"
  if [[ "$path" == "/" ]]; then
    if [[ "$ENABLE_FALLBACK" == "true" ]]; then
      echo "        if (\$http_upgrade = \"\") {"
      echo "            rewrite ^ /_fallback last;"
      echo "        }"
    fi
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
  echo "        proxy_read_timeout 3600s;"
  echo "        proxy_send_timeout 3600s;"
  echo "    }"
}

render_server_body() {
  local i
  for i in "${!LOC_PATHS[@]}"; do
    render_location "${LOC_PATHS[$i]}" "${LOC_PORTS[$i]}" "${LOC_WS[$i]}" "${LOC_BUFOFF[$i]}"
    echo
  done
  render_location "/" "$DEFAULT_PORT" "1" "0"
  if [[ "$ENABLE_FALLBACK" == "true" ]]; then
    echo
    echo "    location /_fallback {"
    echo "        internal;"
    echo "        root ${FALLBACK_DIR};"
    echo "        try_files /index.html =404;"
    echo "    }"
  fi
}

# ---- hide nginx version/OS from response headers ----
ensure_server_tokens_off() {
  if grep -q "server_tokens off;" /etc/nginx/nginx.conf 2>/dev/null; then
    info "server_tokens already off in nginx.conf."
  else
    if grep -q "^http {" /etc/nginx/nginx.conf 2>/dev/null; then
      sed -i '/^http {/a\    server_tokens off;' /etc/nginx/nginx.conf
      ok "Added 'server_tokens off;' to nginx.conf (hides version/OS in headers)."
    else
      err "Could not find 'http {' block in nginx.conf, skipping server_tokens off."
    fi
  fi
}

# ---- pick correct http2 syntax for the installed nginx version ----
detect_http2_syntax() {
  local ver major minor patch
  ver="$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "0.0.0")"
  major="$(echo "$ver" | cut -d. -f1)"
  minor="$(echo "$ver" | cut -d. -f2)"
  patch="$(echo "$ver" | cut -d. -f3)"
  # http2 became a separate directive in 1.25.1; before that it's "listen ... ssl http2;"
  if (( major > 1 || (major == 1 && minor > 25) || (major == 1 && minor == 25 && patch >= 1) )); then
    echo "new"
  else
    echo "old"
  fi
}

ensure_server_tokens_off

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
  echo "    server_name ${SERVER_NAME_LINE};"
  echo
  render_server_body
  echo "}"
  echo

  if [[ "$ENABLE_SSL" == "true" ]]; then
    HTTP2_MODE="$(detect_http2_syntax)"
    echo "server {"
    if [[ "$HTTP2_MODE" == "new" ]]; then
      echo "    listen 443 ssl;"
      echo "    listen [::]:443 ssl;"
      echo "    http2 on;"
    else
      echo "    listen 443 ssl http2;"
      echo "    listen [::]:443 ssl http2;"
    fi
    echo "    server_name ${SERVER_NAME_LINE};"
    echo
    echo "    ssl_certificate     ${CERT_PATH};"
    echo "    ssl_certificate_key ${KEY_PATH};"
    echo "    ssl_protocols TLSv1.2 TLSv1.3;"
    echo "    ssl_ciphers HIGH:!aNULL:!MD5;"
    echo "    ssl_prefer_server_ciphers off;"
    echo "    ssl_session_cache shared:SSL:10m;"
    echo "    ssl_session_timeout 1d;"
    echo "    ssl_session_tickets off;"
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

  # ---- save state so next run can add-only without re-asking everything ----
  {
    echo "DOMAIN=\"${DOMAIN}\""
    echo "SERVER_NAME_LINE=\"${SERVER_NAME_LINE}\""
    echo "CERT_PATH=\"${CERT_PATH}\""
    echo "KEY_PATH=\"${KEY_PATH}\""
    echo "ENABLE_SSL=${ENABLE_SSL}"
    echo "DEFAULT_PORT=\"${DEFAULT_PORT}\""
    echo "ENABLE_FALLBACK=${ENABLE_FALLBACK}"
    echo "FALLBACK_DIR=\"${FALLBACK_DIR}\""
    declare -p LOC_PATHS
    declare -p LOC_PORTS
    declare -p LOC_WS
    declare -p LOC_BUFOFF
  } > "$STATE_FILE"
  ok "Saved setup to $STATE_FILE for next time (use 'add-only' to skip re-typing)."
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
[[ "$ENABLE_FALLBACK" == "true" ]] && info "Camouflage fallback site served from: $FALLBACK_DIR"
info "server_tokens off is set — nginx version/OS hidden from response headers."
info "Reminder: any backend you proxy to a public path (panel, sub endpoint) should"
info "have its own Listen IP set to 127.0.0.1 so it can't be reached bypassing nginx."
