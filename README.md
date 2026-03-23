# OpenClaw Self-Hosted Deployment Script

> One-shot interactive Bash script that installs and configures [OpenClaw](https://github.com/openclaw/openclaw) on any Linux server — your own VPS, home lab, or private VPN — without Hostinger's hPanel.

If this saved you time, consider giving it a ⭐ on [GitHub](https://github.com/tahasaifeee/openclaw_AutoInstall_Dockerized)!

---

## What It Does

`deploy.sh` automates the full setup in a single interactive run:

| Step | What happens |
|------|-------------|
| 1 | Detects your OS and package manager |
| 2 | Installs prerequisites (Docker Engine, Docker Compose v2, git, curl, openssl, jq) |
| 3 | Adds your user to the `docker` group and refreshes permissions |
| 4 | Prompts for all configuration (port, API keys, channels, sandbox, etc.) |
| 5 | Clones the OpenClaw repository |
| 6 | Writes a secure `.env` file (`chmod 600`) |
| 7 | Pulls the pre-built image **or** builds from source |
| 8 | Runs onboarding and starts the gateway container |
| 9 | Optionally connects Telegram / Discord / WhatsApp |
| 10 | Opens the firewall port (ufw or firewalld) |
| 11 | Health-checks the gateway and prints a full summary |

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

- A Linux server (local, VPN, or any VPS)
- A non-root user with `sudo` privileges
- Internet access (to pull the Docker image and clone the repo)
- Minimum **2 GB RAM**

---

## Quick Start

### One-line install *(recommended)*

SSH into your server and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh)
```

That's it. The script handles everything from Docker installation to the running gateway.

### Manual install

```bash
curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh -o deploy.sh
chmod +x deploy.sh && bash deploy.sh
```

> **Note:** Run these commands on your server over SSH, not on your local machine.

---

## Interactive Prompts

The script will ask for the following during setup. All items have sensible defaults.

### General

| Prompt | Default | Required |
|--------|---------|----------|
| Installation directory | `~/openclaw` | Yes |
| Gateway web UI port | `18789` | Yes |
| Image source (pre-built / build from source) | Pre-built (ghcr.io) | Yes |
| Gateway token | Auto-generated (32-byte hex) | Yes |
| Timezone | System timezone | Yes |
| Enable agent sandbox | Yes | Yes |
| Open firewall port | Yes (if ufw/firewalld detected) | No |

### AI Provider API Keys *(at least one recommended)*

| Key | Provider |
|-----|---------|
| `ANTHROPIC_API_KEY` | Claude (Anthropic) |
| `OPENAI_API_KEY` | OpenAI / ChatGPT |
| `GEMINI_API_KEY` | Google Gemini |
| `XAI_API_KEY` | xAI / Grok |

### Messaging Channels *(all optional — can be added later)*

| Prompt | Notes |
|--------|-------|
| Telegram bot token | Create a bot via [@BotFather](https://t.me/BotFather) |
| Discord bot token | Create at [discord.com/developers](https://discord.com/developers) |
| WhatsApp number | Triggers QR-code scan flow |

---

## After Deployment

Once the script completes, you'll see a summary like:

```
  Web UI:         http://192.168.1.10:18789
  Local URL:      http://127.0.0.1:18789
  Gateway Token:  a3f9c2...
  Install Dir:    /home/you/openclaw
  Config Dir:     ~/.openclaw
  Workspace:      ~/openclaw/workspace
```

Open the web UI in your browser and paste the **Gateway Token** to log in.

---

## Common Post-Install Commands

```bash
# View status
docker compose -f ~/openclaw/docker-compose.yml ps

# Follow logs
docker compose -f ~/openclaw/docker-compose.yml logs -f openclaw-gateway

# Stop
docker compose -f ~/openclaw/docker-compose.yml down

# Restart
docker compose -f ~/openclaw/docker-compose.yml restart openclaw-gateway

# Update to latest
cd ~/openclaw && git pull && docker compose pull && docker compose up -d
```

### Add messaging channels later

```bash
# WhatsApp (QR code scan)
docker compose -f ~/openclaw/docker-compose.yml run --rm openclaw-cli channels login

# Telegram
docker compose -f ~/openclaw/docker-compose.yml run --rm openclaw-cli channels add \
  --channel telegram --token <YOUR_BOT_TOKEN>

# Discord
docker compose -f ~/openclaw/docker-compose.yml run --rm openclaw-cli channels add \
  --channel discord --token <YOUR_BOT_TOKEN>
```

### Health check endpoints

```bash
curl http://127.0.0.1:18789/healthz   # Liveness
curl http://127.0.0.1:18789/readyz    # Readiness
```

---

## Directory Structure

```
~/openclaw/            ← cloned OpenClaw repo + docker-compose.yml
~/openclaw/.env        ← your secrets (chmod 600, never commit this)
~/.openclaw/           ← runtime config, memory, channel state
~/openclaw/workspace/  ← files the AI agent can read/write
```

---

## Security Notes

- The **Gateway Token** is the only authentication layer for the web UI. Keep it secret.
- The `.env` file is written with `chmod 600` — only your user can read it.
- By default the gateway binds to all LAN interfaces (`OPENCLAW_GATEWAY_BIND=lan`). If your server has a public IP, restrict access with a firewall rule or put a reverse proxy (Nginx / Caddy) with HTTPS in front.
- Never commit `.env` to version control.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `permission denied` running Docker | Log out and back in, or run `newgrp docker` |
| Gateway health check times out | `docker compose logs openclaw-gateway` to see errors |
| WhatsApp QR code not appearing | Run the channels login command in an interactive terminal |
| Port already in use | Change `OPENCLAW_GATEWAY_PORT` in `.env` and restart |
| `docker compose` not found | Re-run the script — it installs Compose v2 automatically |

---

## Re-running the Script

The script is idempotent for most steps:

- Already-installed packages are skipped.
- If the repo directory already exists, it runs `git pull` instead of cloning.
- The `.env` file is **overwritten** on each run — back it up first if you've made manual changes.

---

## License

This deployment script is provided as-is under the [MIT License](LICENSE).
OpenClaw itself is developed by the [OpenClaw project](https://github.com/openclaw/openclaw) — refer to their repository for its license.
