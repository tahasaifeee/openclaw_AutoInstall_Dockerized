# OpenClaw Self-Hosted Deployment Script

> One-shot Bash script that installs and configures [OpenClaw](https://openclaw.ai) on any Linux server — your own VPS, home lab, or private VPN.

If this saved you time, consider giving it a ⭐ on [GitHub](https://github.com/tahasaifeee/openclaw_AutoInstall_Dockerized)!

---

## What It Does

`deploy.sh` automates the complete setup in a single run:

| Step | What happens |
|------|-------------|
| 1 | Detects OS and installs prerequisites (curl, openssl, jq) |
| 2 | Installs OpenClaw via the official installer (`openclaw.ai/install.sh`) |
| 3 | Patches `openclaw.json` for LAN/remote access and syncs auth tokens |
| 4 | Installs Caddy and generates a self-signed TLS certificate |
| 5 | Starts Caddy as an HTTPS reverse proxy (systemd service) |
| 6 | Opens the firewall port (ufw or firewalld) |
| 7 | Health-checks the gateway |
| 8 | Displays the dashboard URL with token pre-filled, then auto-approves the browser pairing |

Everything after that — AI keys, channels, agents — is configured through the web UI.

---

## Supported Operating Systems

| Distro | Package Manager |
|--------|----------------|
| Ubuntu 20.04 + | apt |
| Debian 11 + | apt |
| Linux Mint / Pop!_OS | apt |
| CentOS / RHEL 8 + | dnf / yum |
| Rocky Linux / AlmaLinux | dnf |
| Fedora | dnf |
| Arch / Manjaro / EndeavourOS | pacman |

---

## Requirements

- A Linux server (local network, VPN, or any VPS)
- Non-root user with `sudo` privileges (or root)
- Internet access
- Minimum **2 GB RAM**

---

## Install

### One-line *(recommended)*

SSH into your server and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh)
```

### Manual

```bash
curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh -o deploy.sh
chmod +x deploy.sh && bash deploy.sh
```

> Run these commands on your server — not your local machine.

---

## Setup Flow

The script is fully automatic — no questions asked.

Once the gateway is running, the script displays:

```
━━━  Browser Pairing  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Open this URL in your browser:
  ➜  https://10.11.100.150/#token=65f3c944...

  Accept the certificate warning, then click Connect.
  The script will auto-approve the pairing request.
```

1. Open the URL in your browser
2. Click **Advanced → Proceed** on the certificate warning (self-signed cert, expected)
3. Click **Connect** — the script detects the pairing request and approves it automatically
4. You're in — configure AI keys and channels from the dashboard

---

## Architecture

```
Browser (HTTPS :443)
      ↓
 Caddy (systemd service)  ←  self-signed TLS cert (openssl)
      ↓
 openclaw-gateway (:18789, localhost only)
```

- **Caddy** handles TLS so the browser's WebCrypto API works (required for device identity)
- **OpenClaw** is installed natively via the official installer (`openclaw.ai/install.sh`)
- **Config** lives in `~/.openclaw/openclaw.json`

---

## Update Configuration

Update AI keys or Telegram bot token without re-running the full setup:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh) --configure
```

Prompts for each setting with the current value masked. Press Enter to skip any field. Restarts the gateway automatically if anything changed.

Supported fields:
- OpenAI, Anthropic, Gemini, Groq, OpenRouter API keys
- Telegram bot token

---

## Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh) --uninstall
```

Removes OpenClaw, Caddy, TLS certificates, firewall rule, and `~/.openclaw/`.

---

## Post-Install Commands

```bash
# OpenClaw logs
journalctl -u openclaw -f

# Restart OpenClaw
sudo systemctl restart openclaw

# Update OpenClaw to latest
curl -fsSL https://openclaw.ai/install.sh | bash

# Restart Caddy
sudo systemctl restart caddy
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ERR_SSL_PROTOCOL_ERROR` | `sudo systemctl restart caddy` |
| Gateway not responding | `sudo systemctl restart openclaw` |
| `gateway token mismatch` | Token is in `~/.openclaw/openclaw.json` → `.gateway.auth.token` |
| Pairing stuck | `openclaw devices approve $(jq -r 'keys[0]' ~/.openclaw/devices/pending.json)` |
| Gateway not healthy | `journalctl -u openclaw --no-pager -n 50` |
| Port 443 in use | Edit `/etc/caddy/Caddyfile`, change the port, then `sudo systemctl restart caddy` |

---

## Security Notes

- The gateway token is managed by `openclaw.json` — set once during install, never rotated by this script on re-runs.
- The TLS certificate is self-signed (valid 10 years). For production, replace it with a real cert or configure Caddy with a domain and Let's Encrypt.
- Port 443 is the only port exposed publicly. The gateway port (18789) only listens on localhost.

---

## License

This deployment script is provided as-is under the [MIT License](LICENSE).
OpenClaw itself is developed by the [OpenClaw project](https://openclaw.ai) — refer to their repository for its license.
