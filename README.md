# rayoo-nginx-deploy

Interactive nginx reverse-proxy setup script for 3x-ui / Xray VPN servers.

Instead of hand-editing `/etc/nginx/sites-available/default` on every new server,
run this script and answer a few prompts — it generates the config for you.

## Usage

On a fresh server:

```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/<your-repo>/main/deploy-nginx.sh -o deploy-nginx.sh
sudo bash deploy-nginx.sh
```

## What it asks

1. **Domain name** — e.g. `rayoo.uk`
2. **SSL cert paths** — fullchain + privkey. If missing, you can choose to configure
   port 80 only until certs are ready.
3. **Default backend port** — where root `/` traffic goes (e.g. your main Xray inbound, `10001`)
4. **Extra locations** — add as many as you need, one at a time:
   - Path (e.g. `/kabut`, `/rayoo/`, `/user/`)
   - Backend port
   - Whether it needs websocket/Upgrade headers (panel, xhttp, ws — usually yes)
   - Whether to disable buffering (useful for some Xray inbounds)
   - Leave the path blank to stop adding locations

The script then:
- Backs up any existing `/etc/nginx/sites-available/default` to
  `/etc/nginx/sites-available/backups/default.<timestamp>.bak`
- Writes the new config
- Runs `nginx -t`
- If the test fails, automatically restores the backup
- Asks before reloading nginx

## Notes

- Every generated location includes `X-Forwarded-Proto`, `X-Real-IP`, and
  `X-Forwarded-For` headers so backends (like 3x-ui) correctly detect HTTPS
  and the real client IP — this avoids redirect loops.
- For any backend exposed only through a path (panel, subscription/user
  endpoint, etc.), set that service's own "Listen IP" to `127.0.0.1` so it's
  unreachable except through nginx.
- Re-running the script overwrites the config after asking, and always keeps
  a timestamped backup first.
