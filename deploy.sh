#!/usr/bin/env bash
# =============================================================================
# OpenClaw Local / VPN Deployment Script
# =============================================================================
# Supports: Ubuntu 20.04+, Debian 11+, CentOS/RHEL 8+, Fedora, Arch Linux
# Usage   : bash deploy.sh
# =============================================================================

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔═══════════════════════════════════════════════╗"
  echo "  ║         OpenClaw  —  Local / VPN Deploy       ║"
  echo "  ╚═══════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

ask() {
  # ask <varname> <prompt> [default]
  local varname="$1" prompt="$2" default="${3:-}"
  local display_default=""
  [[ -n "$default" ]] && display_default=" [${default}]"
  while true; do
    read -rp "$(echo -e "${BOLD}${prompt}${display_default}: ${RESET}")" value
    value="${value:-$default}"
    if [[ -n "$value" ]]; then
      printf -v "$varname" '%s' "$value"
      return
    fi
    warn "This field is required."
  done
}

ask_optional() {
  # ask_optional <varname> <prompt>
  local varname="$1" prompt="$2"
  read -rp "$(echo -e "${BOLD}${prompt} (leave blank to skip): ${RESET}")" value
  printf -v "$varname" '%s' "${value:-}"
}

ask_secret() {
  # ask_secret <varname> <prompt> [default]
  local varname="$1" prompt="$2" default="${3:-}"
  local display_default=""
  [[ -n "$default" ]] && display_default=" [press Enter to use auto-generated]"
  read -rsp "$(echo -e "${BOLD}${prompt}${display_default}: ${RESET}")" value
  echo
  value="${value:-$default}"
  printf -v "$varname" '%s' "$value"
}

ask_yn() {
  # ask_yn <prompt> <default: y|n>  → returns 0 for yes, 1 for no
  local prompt="$1" default="${2:-y}"
  local yn_hint="[Y/n]"
  [[ "$default" == "n" ]] && yn_hint="[y/N]"
  while true; do
    read -rp "$(echo -e "${BOLD}${prompt} ${yn_hint}: ${RESET}")" yn
    yn="${yn:-$default}"
    case "${yn,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     warn "Please answer y or n." ;;
    esac
  done
}

command_exists() { command -v "$1" &>/dev/null; }

# ─── Latest Stable Version Resolution ────────────────────────────────────────
resolve_latest_version() {
  info "Resolving latest stable OpenClaw release..."

  local api_url="https://api.github.com/repos/openclaw/openclaw/releases/latest"
  local version=""

  if command_exists curl; then
    version=$(curl -fsSL "$api_url" 2>/dev/null \
      | grep '"tag_name"' \
      | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  fi

  if [[ -z "$version" ]]; then
    warn "Could not resolve latest release from GitHub API. Falling back to 'latest' tag."
    OPENCLAW_VERSION="latest"
    OPENCLAW_IMAGE_TAG="latest"
  else
    OPENCLAW_VERSION="$version"           # e.g. v2026.3.22 — used for git checkout
    OPENCLAW_IMAGE_TAG="${version#v}"     # e.g. 2026.3.22  — used for Docker image tag
    success "Latest stable release: ${OPENCLAW_VERSION} (image tag: ${OPENCLAW_IMAGE_TAG})"
  fi
}

# ─── OS Detection ─────────────────────────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-}"
  else
    die "Cannot detect OS. /etc/os-release not found."
  fi

  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop)
      PKG_MANAGER="apt"
      ;;
    centos|rhel|rocky|almalinux|ol)
      PKG_MANAGER="dnf"
      command_exists dnf || PKG_MANAGER="yum"
      ;;
    fedora)
      PKG_MANAGER="dnf"
      ;;
    arch|manjaro|endeavouros)
      PKG_MANAGER="pacman"
      ;;
    *)
      if echo "$OS_ID_LIKE" | grep -qiE "debian|ubuntu"; then
        PKG_MANAGER="apt"
      elif echo "$OS_ID_LIKE" | grep -qiE "rhel|centos|fedora"; then
        PKG_MANAGER="dnf"
        command_exists dnf || PKG_MANAGER="yum"
      else
        die "Unsupported OS: $OS_ID. Supported: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Fedora, Arch."
      fi
      ;;
  esac

  info "Detected OS: ${OS_ID} ${OS_VERSION} (package manager: ${PKG_MANAGER})"
}

# ─── Package Install Wrapper ──────────────────────────────────────────────────
pkg_install() {
  case "$PKG_MANAGER" in
    apt)     sudo apt-get install -y "$@" ;;
    dnf)     sudo dnf install -y "$@" ;;
    yum)     sudo yum install -y "$@" ;;
    pacman)  sudo pacman -S --noconfirm "$@" ;;
  esac
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)     sudo apt-get update -qq ;;
    dnf|yum) sudo "$PKG_MANAGER" makecache -q ;;
    pacman)  sudo pacman -Sy ;;
  esac
}

# ─── Prerequisite Checks ──────────────────────────────────────────────────────
check_root() {
  if [[ "$EUID" -eq 0 ]]; then
    warn "Running as root. It is recommended to run as a regular user with sudo."
    if ! ask_yn "Continue as root?" "n"; then
      die "Please re-run as a non-root user with sudo privileges."
    fi
  fi
}

check_sudo() {
  if ! sudo -n true 2>/dev/null; then
    info "sudo access is required. You may be prompted for your password."
    sudo -v || die "sudo privileges are required to run this script."
  fi
}

install_prerequisites() {
  info "Checking system prerequisites..."
  pkg_update

  # ── curl ──────────────────────────────────────────────────────────────────
  if ! command_exists curl; then
    info "Installing curl..."
    pkg_install curl
  else
    success "curl is already installed."
  fi

  # ── git ───────────────────────────────────────────────────────────────────
  if ! command_exists git; then
    info "Installing git..."
    pkg_install git
  else
    success "git is already installed."
  fi

  # ── openssl (for token generation) ───────────────────────────────────────
  if ! command_exists openssl; then
    info "Installing openssl..."
    pkg_install openssl
  else
    success "openssl is already installed."
  fi

  # ── jq (optional but useful) ─────────────────────────────────────────────
  if ! command_exists jq; then
    info "Installing jq..."
    pkg_install jq 2>/dev/null || warn "jq installation skipped (not critical)."
  fi
}

install_docker() {
  if command_exists docker; then
    local docker_version
    docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    success "Docker already installed: $(docker --version)"
  else
    info "Docker not found. Installing Docker Engine..."

    case "$PKG_MANAGER" in
      apt)
        # Official Docker convenience script (supports Ubuntu/Debian)
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        ;;
      dnf|yum)
        sudo "$PKG_MANAGER" install -y yum-utils 2>/dev/null || true
        sudo yum-config-manager --add-repo \
          https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
          sudo dnf config-manager --add-repo \
          https://download.docker.com/linux/centos/docker-ce.repo
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
      pacman)
        pkg_install docker docker-compose
        ;;
    esac

    sudo systemctl enable --now docker
    success "Docker installed successfully."
  fi

  # ── Add current user to docker group ─────────────────────────────────────
  if [[ "$EUID" -ne 0 ]]; then
    if ! groups "$USER" | grep -qw docker; then
      info "Adding ${USER} to the docker group..."
      sudo usermod -aG docker "$USER"
      NEEDS_DOCKER_GROUP_REFRESH=true
      warn "Docker group membership will apply after this script re-invokes itself via 'sg docker'."
    else
      success "User ${USER} is already in the docker group."
    fi
  fi

  sudo systemctl start docker 2>/dev/null || true
}

install_docker_compose() {
  # Docker Compose v2 (plugin) is preferred.
  if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose v2 plugin: $(docker compose version --short 2>/dev/null || echo 'installed')"
    return
  fi

  # Fallback: standalone docker-compose v2
  if command_exists docker-compose; then
    local ver
    ver=$(docker-compose --version 2>/dev/null | grep -oP '\d+' | head -1)
    if [[ "${ver:-1}" -ge 2 ]]; then
      success "docker-compose v2 (standalone) found."
      return
    fi
    warn "docker-compose v1 found. Upgrading to v2..."
  fi

  info "Installing Docker Compose v2 plugin..."
  case "$PKG_MANAGER" in
    apt)
      pkg_install docker-compose-plugin
      ;;
    dnf|yum)
      pkg_install docker-compose-plugin 2>/dev/null || {
        # Manual install fallback
        local compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
        sudo curl -fsSL "$compose_url" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
      }
      ;;
    pacman)
      pkg_install docker-compose
      ;;
  esac

  docker compose version &>/dev/null || docker-compose version &>/dev/null || \
    die "Docker Compose installation failed. Please install it manually."
  success "Docker Compose installed."
}

# ─── Configuration Gathering ──────────────────────────────────────────────────
gather_config() {
  echo
  echo -e "${BOLD}${CYAN}━━━  Configuration  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  info "All values are auto-configured. AI keys and channels are set up via the web UI after install."
  echo

  # Installation directory — always use default, no prompt needed
  INSTALL_DIR="$HOME/openclaw"

  # Ports
  GATEWAY_PORT="18789"   # internal — openclaw gateway, not exposed directly
  HTTPS_PORT="443"       # Caddy HTTPS — what the user actually opens in browser

  # Always use pre-built image
  OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:${OPENCLAW_IMAGE_TAG}"
  info "Image: ${OPENCLAW_IMAGE}"

  # Token is set by onboarding and read back in patch_config().
  # We use a placeholder here; the real value is displayed in print_summary()
  # after patch_config() has updated GATEWAY_TOKEN from openclaw.json.
  GATEWAY_TOKEN="(will be shown after setup)"

  # Auto-detect timezone
  TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
  info "Timezone: ${TIMEZONE}"

  # Sandbox on by default
  OPENCLAW_SANDBOX=1

  # Auto-open firewall if available
  CONFIGURE_FIREWALL=false
  if command_exists ufw || command_exists firewall-cmd; then
    CONFIGURE_FIREWALL=true
  fi

  info "HTTPS port: ${HTTPS_PORT}"

  success "Configuration ready."
}

# ─── Clone / Update Repo ──────────────────────────────────────────────────────
setup_repo() {
  info "Setting up OpenClaw repository at: ${INSTALL_DIR}"

  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Repository already exists. Fetching tags and checking out ${OPENCLAW_VERSION}..."
    git -C "$INSTALL_DIR" fetch --tags --quiet || warn "Could not fetch tags. Continuing with current version."
    if [[ "$OPENCLAW_VERSION" != "latest" ]]; then
      git -C "$INSTALL_DIR" checkout "$OPENCLAW_VERSION" --quiet 2>/dev/null || \
        warn "Could not checkout ${OPENCLAW_VERSION}. Staying on current commit."
    else
      git -C "$INSTALL_DIR" pull --ff-only --quiet || warn "Could not pull latest changes. Continuing with existing version."
    fi
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    if [[ "$OPENCLAW_VERSION" != "latest" ]]; then
      git clone --branch "$OPENCLAW_VERSION" --depth 1 \
        https://github.com/openclaw/openclaw.git "$INSTALL_DIR"
    else
      git clone --depth 1 https://github.com/openclaw/openclaw.git "$INSTALL_DIR"
    fi
    success "Repository cloned at version ${OPENCLAW_VERSION}."
  fi
}

# ─── Create .env file ─────────────────────────────────────────────────────────
write_env() {
  local env_file="${INSTALL_DIR}/.env"

  info "Writing configuration to ${env_file} ..."

  cat > "$env_file" <<EOF
# ─── OpenClaw Configuration ───────────────────────────────────────────────────
# Generated by deploy.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# DO NOT commit this file to version control.

# ── Image ─────────────────────────────────────────────────────────────────────
OPENCLAW_IMAGE=${OPENCLAW_IMAGE}

# ── Directories (required for Docker volume mounts) ───────────────────────────
OPENCLAW_CONFIG_DIR=${HOME}/.openclaw
OPENCLAW_WORKSPACE_DIR=${HOME}/openclaw/workspace

# ── Gateway ───────────────────────────────────────────────────────────────────
# Note: gateway token is managed by openclaw.json — do not set OPENCLAW_GATEWAY_TOKEN here.
OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}
OPENCLAW_GATEWAY_BIND=lan

# ── Sandbox ───────────────────────────────────────────────────────────────────
OPENCLAW_SANDBOX=${OPENCLAW_SANDBOX}

# ── Timezone ──────────────────────────────────────────────────────────────────
TZ=${TIMEZONE}

EOF

  # AI keys and channel tokens are configured via the web UI after install.
  # Add them manually to this file if needed, e.g.:
  #   ANTHROPIC_API_KEY=sk-...
  #   OPENAI_API_KEY=sk-...

  # Secure the file — only owner can read
  chmod 600 "$env_file"
  success ".env file written and secured (chmod 600)."
}

# ─── Build / Pull Image ───────────────────────────────────────────────────────
prepare_image() {
  cd "$INSTALL_DIR"

  if [[ "$OPENCLAW_IMAGE" == "openclaw:local" ]]; then
    info "Building OpenClaw image from source (this may take 5-15 minutes)..."
    docker build -t openclaw:local -f Dockerfile . || die "Docker build failed."
    success "Image built: openclaw:local"
  else
    info "Pulling pre-built image: ${OPENCLAW_IMAGE} ..."
    docker pull "$OPENCLAW_IMAGE" || die "Failed to pull image. Check your internet connection."
    success "Image pulled."
  fi
}

# ─── Run Onboarding ───────────────────────────────────────────────────────────
run_onboarding() {
  cd "$INSTALL_DIR"

  # Create host directories and give the container's node user (UID 1000) write access
  # before any Docker step tries to use them.
  mkdir -p "${HOME}/.openclaw" "${HOME}/openclaw/workspace"
  chown -R 1000:1000 "${HOME}/.openclaw" "${HOME}/openclaw/workspace" 2>/dev/null || \
    chmod -R 777 "${HOME}/.openclaw" "${HOME}/openclaw/workspace"

  info "Running OpenClaw onboarding (initialises config and data directories)..."

  docker compose run --rm openclaw-cli onboard 2>/dev/null || {
    warn "Onboarding step exited with non-zero code. This can be normal if already initialised."
  }
}

# ─── Start Services ───────────────────────────────────────────────────────────
start_services() {
  cd "$INSTALL_DIR"

  info "Starting OpenClaw gateway and Caddy HTTPS proxy..."
  # Explicitly name the long-running services only — openclaw-cli is a one-shot
  # CLI tool and must NOT be started as a daemon (it has no persistent entrypoint
  # and will restart-loop, blocking network namespace joins for other containers).
  docker compose up -d openclaw-gateway caddy
  success "Containers started."
}

# ─── Patch Config for LAN Access ─────────────────────────────────────────────
patch_config() {
  local config_file="${HOME}/.openclaw/openclaw.json"

  # Wait up to 10s for onboarding to write the config file
  local attempts=0
  while [[ ! -f "$config_file" && $attempts -lt 5 ]]; do
    sleep 2
    attempts=$((attempts + 1))
  done

  if [[ ! -f "$config_file" ]]; then
    warn "Config file not found at ${config_file}. Skipping LAN patch."
    return
  fi

  info "Patching OpenClaw config for LAN/remote access..."

  # Read the auth token set by onboarding
  local actual_token
  actual_token=$(jq -r '.gateway.auth.token // empty' "$config_file" 2>/dev/null)
  if [[ -n "$actual_token" ]]; then
    GATEWAY_TOKEN="$actual_token"
    info "Gateway auth token read from config: ${GATEWAY_TOKEN:0:16}..."
  fi

  # Deep-merge all required settings:
  # - bind: lan                              → listen on all interfaces, not just loopback
  # - remote.token = auth.token             → CLI and device pairing can connect
  # - dangerouslyAllowHostHeaderOriginFallback → Control UI works over IP/LAN
  local tmp="${config_file}.patch.tmp"
  jq --arg token "$GATEWAY_TOKEN" \
    '. * {"gateway": {"bind": "lan", "remote": {"token": $token}, "controlUi": {"dangerouslyAllowHostHeaderOriginFallback": true}}}' \
    "$config_file" > "$tmp" && mv "$tmp" "$config_file"

  # Re-apply ownership so the container's node user can still write the file
  chown 1000:1000 "$config_file" 2>/dev/null || chmod 666 "$config_file"

  success "Config patched — Control UI accessible from LAN."
}

# ─── Caddy HTTPS Reverse Proxy ────────────────────────────────────────────────
setup_caddy() {
  info "Setting up Caddy HTTPS reverse proxy..."

  local cert_dir="${INSTALL_DIR}/certs"
  mkdir -p "$cert_dir"

  # Detect all IPs this server is reachable on for the cert SAN
  local server_ips
  server_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | \
    sed 's/^/IP:/' | paste -sd ',' -)
  [[ -z "$server_ips" ]] && server_ips="IP:127.0.0.1"
  local san="IP:127.0.0.1,${server_ips}"

  # Generate a self-signed cert valid for 10 years covering all server IPs
  info "Generating self-signed TLS certificate (SAN: ${san})..."
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${cert_dir}/key.pem" \
    -out    "${cert_dir}/cert.pem" \
    -sha256 -days 3650 -nodes \
    -subj   "/CN=openclaw-gateway" \
    -addext "subjectAltName=${san}" \
    2>/dev/null
  chmod 644 "${cert_dir}/cert.pem" "${cert_dir}/key.pem"
  success "TLS certificate generated."

  # Caddyfile — use the pre-generated cert so TLS is ready immediately on start
  cat > "${INSTALL_DIR}/Caddyfile" <<EOF
:${HTTPS_PORT} {
    tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem
    reverse_proxy openclaw-gateway:${GATEWAY_PORT}
}
EOF

  # docker-compose.override.yml — adds Caddy as a sidecar
  cat > "${INSTALL_DIR}/docker-compose.override.yml" <<EOF
services:
  caddy:
    image: caddy:latest
    restart: unless-stopped
    ports:
      - "${HTTPS_PORT}:${HTTPS_PORT}"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./certs:/etc/caddy/certs:ro
    depends_on:
      - openclaw-gateway
EOF

  success "Caddy configured (HTTPS on port ${HTTPS_PORT})."
}

# ─── Firewall ─────────────────────────────────────────────────────────────────
configure_firewall() {
  if [[ "$CONFIGURE_FIREWALL" != "true" ]]; then
    return
  fi

  if command_exists ufw; then
    info "Opening port ${HTTPS_PORT}/tcp in ufw..."
    sudo ufw allow "${HTTPS_PORT}/tcp" && success "ufw: port ${HTTPS_PORT} opened."
  elif command_exists firewall-cmd; then
    info "Opening port ${HTTPS_PORT}/tcp in firewalld..."
    sudo firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp"
    sudo firewall-cmd --reload
    success "firewalld: port ${HTTPS_PORT} opened."
  fi
}

# ─── Health Check ─────────────────────────────────────────────────────────────
health_check() {
  info "Waiting for gateway to become healthy (up to 60s)..."
  local attempts=0 max=30
  while [[ $attempts -lt $max ]]; do
    if curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/healthz" &>/dev/null; then
      echo
      success "Gateway is healthy!"
      return 0
    fi
    # Show a dot every 2 seconds with a running counter
    echo -n "  [${attempts}/${max}] waiting..."$'\r'
    sleep 2
    attempts=$((attempts + 1))
  done
  echo
  warn "Gateway health check timed out after $((max * 2))s."
  warn "Last 20 lines of container logs:"
  (cd "${INSTALL_DIR}" && docker compose logs --tail=20 2>/dev/null) || true
  warn "To follow live logs: cd ${INSTALL_DIR} && docker compose logs -f"
}

# ─── Auto-Approve Device Pairing ─────────────────────────────────────────────
auto_approve_pairing() {
  local pending_file="${HOME}/.openclaw/devices/pending.json"
  local server_ip
  server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")

  echo
  echo -e "${BOLD}${CYAN}━━━  Browser Pairing  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  echo -e "  Open this URL in your browser:"
  echo -e "  ${BOLD}${CYAN}  ➜  https://${server_ip}/#token=${GATEWAY_TOKEN}${RESET}"
  echo
  echo -e "  Accept the certificate warning, then click ${BOLD}Connect${RESET}."
  echo -e "  The script will auto-approve the pairing request."
  echo

  local attempts=0 max=60  # 2 minutes
  while [[ $attempts -lt $max ]]; do
    # Check for any pending entry in pending.json
    local request_id
    request_id=$(jq -r 'keys[0] // empty' "$pending_file" 2>/dev/null)

    if [[ -n "$request_id" ]]; then
      echo
      info "Pairing request detected: ${request_id:0:16}... — approving..."
      if (cd "$INSTALL_DIR" && \
          docker compose run --rm openclaw-cli devices approve "$request_id" \
          2>/dev/null); then
        success "Device paired! The web UI is ready to use."
        return 0
      else
        warn "Approval failed. You can approve manually:"
        warn "  cd ${INSTALL_DIR} && docker compose run --rm openclaw-cli devices approve ${request_id}"
        return 1
      fi
    fi

    echo -n "  [${attempts}/${max}] waiting for browser connection..."$'\r'
    sleep 2
    attempts=$((attempts + 1))
  done

  echo
  warn "No pairing request detected within 2 minutes."
  warn "After opening the browser, run:"
  warn "  cd ${INSTALL_DIR} && docker compose run --rm openclaw-cli devices approve \$(jq -r 'keys[0]' ~/.openclaw/devices/pending.json)"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  local server_ip
  server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")

  echo
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${GREEN}  OpenClaw is ready!${RESET}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  echo -e "  ${BOLD}Dashboard URL (token pre-filled):${RESET}"
  echo -e "  ${BOLD}${CYAN}  ➜  https://${server_ip}/#token=${GATEWAY_TOKEN}${RESET}"
  echo
  echo -e "  ${YELLOW}Note: Accept the certificate warning (self-signed cert) on first visit.${RESET}"
  echo
  echo -e "  Configure AI keys, channels (WhatsApp, Telegram, Discord)"
  echo -e "  and all other settings directly inside the dashboard."
  echo
  echo -e "${BOLD}${CYAN}━━━  Useful Commands  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  echo -e "  ${BOLD}Logs:${RESET}      cd ${INSTALL_DIR} && docker compose logs -f"
  echo -e "  ${BOLD}Stop:${RESET}      cd ${INSTALL_DIR} && docker compose down"
  echo -e "  ${BOLD}Restart:${RESET}   cd ${INSTALL_DIR} && docker compose restart"
  echo -e "  ${BOLD}Update:${RESET}    cd ${INSTALL_DIR} && git pull && docker compose pull && docker compose up -d"
  echo -e "  ${BOLD}Uninstall:${RESET} bash <(curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh) --uninstall"
  echo
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
uninstall() {
  banner
  echo -e "${BOLD}${RED}━━━  Uninstall OpenClaw  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  echo -e "  This will remove:"
  echo -e "    • All OpenClaw containers and volumes"
  echo -e "    • Install directory:  ${HOME}/openclaw"
  echo -e "    • Config directory:   ${HOME}/.openclaw"
  echo -e "    • Workspace:          ${HOME}/openclaw/workspace"
  echo
  if ! ask_yn "Are you sure you want to completely uninstall OpenClaw?" "n"; then
    info "Uninstall cancelled."
    exit 0
  fi

  local install_dir="${HOME}/openclaw"

  # ── Stop and remove containers + volumes ─────────────────────────────────
  if [[ -f "${install_dir}/docker-compose.yml" ]]; then
    info "Stopping and removing containers..."
    (cd "$install_dir" && docker compose down --volumes --remove-orphans 2>/dev/null) || \
      warn "Could not stop containers (may already be stopped)."
    success "Containers removed."
  fi

  # ── Remove Docker images ──────────────────────────────────────────────────
  if ask_yn "Also remove the OpenClaw Docker image (frees disk space)?" "y"; then
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'openclaw|caddy' | \
      xargs -r docker rmi -f 2>/dev/null || true
    success "Docker images removed."
  fi

  # ── Close firewall port ───────────────────────────────────────────────────
  detect_os 2>/dev/null || true
  if command_exists ufw; then
    sudo ufw delete allow 443/tcp 2>/dev/null || true
    success "ufw: port 443 closed."
  elif command_exists firewall-cmd; then
    sudo firewall-cmd --permanent --remove-port=443/tcp 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
    success "firewalld: port 443 closed."
  fi

  # ── Remove install and config directories ────────────────────────────────
  info "Removing install directory: ${install_dir}"
  rm -rf "$install_dir"

  info "Removing config directory: ${HOME}/.openclaw"
  rm -rf "${HOME}/.openclaw"

  echo
  echo -e "${BOLD}${GREEN}━━━  Uninstall Complete  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  OpenClaw has been fully removed from this system."
  echo
}

# ─── Auto-reload for docker group ─────────────────────────────────────────────
relaunch_with_docker_group() {
  if [[ "${NEEDS_DOCKER_GROUP_REFRESH:-false}" == "true" ]]; then
    info "Re-launching script with docker group active via 'sg docker'..."
    NEEDS_DOCKER_GROUP_REFRESH=false exec sg docker "$0" "$@"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Handle --uninstall flag before anything else
  for arg in "$@"; do
    if [[ "$arg" == "--uninstall" || "$arg" == "uninstall" ]]; then
      uninstall
      exit 0
    fi
  done

  banner

  # Guard against running inside Docker itself
  if [[ -f /.dockerenv ]]; then
    die "This script should not be run inside a Docker container."
  fi

  check_root
  check_sudo
  detect_os
  install_prerequisites
  install_docker

  # Re-exec with docker group if we just added the user
  NEEDS_DOCKER_GROUP_REFRESH="${NEEDS_DOCKER_GROUP_REFRESH:-false}"
  if [[ "$NEEDS_DOCKER_GROUP_REFRESH" == "true" ]]; then
    relaunch_with_docker_group "$@"
  fi

  install_docker_compose
  resolve_latest_version
  gather_config
  setup_repo
  write_env
  prepare_image
  run_onboarding
  patch_config
  setup_caddy
  start_services
  configure_firewall
  health_check
  auto_approve_pairing
  print_summary
}

main "$@"
