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

ask_yn() {
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

# ─── Env Key Helper ───────────────────────────────────────────────────────────
env_set_or_append() {
  # env_set_or_append <file> <KEY> <value>
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
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
        die "Unsupported OS: $OS_ID."
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

  for pkg in curl openssl jq; do
    if ! command_exists "$pkg"; then
      info "Installing ${pkg}..."
      pkg_install "$pkg"
    else
      success "${pkg} is already installed."
    fi
  done
}

# ─── Install OpenClaw ─────────────────────────────────────────────────────────
install_openclaw() {
  if command_exists openclaw; then
    local ver
    ver=$(openclaw --version 2>/dev/null || echo "unknown")
    success "OpenClaw already installed (${ver}). Skipping."
    return
  fi

  info "Installing OpenClaw via official installer..."
  curl -fsSL https://openclaw.ai/install.sh | bash

  # Reload PATH in case openclaw was installed to a non-standard location
  export PATH="$PATH:/usr/local/bin:$HOME/.local/bin"

  if ! command_exists openclaw; then
    # Search common install locations
    for loc in /usr/local/bin/openclaw "$HOME/.local/bin/openclaw" /usr/bin/openclaw; do
      if [[ -x "$loc" ]]; then
        export PATH="$PATH:$(dirname "$loc")"
        break
      fi
    done
  fi

  command_exists openclaw || die "OpenClaw installation failed. Check the output above for errors."
  success "OpenClaw installed."
}

# ─── Install Caddy ────────────────────────────────────────────────────────────
install_caddy() {
  if command_exists caddy; then
    success "Caddy already installed: $(caddy version 2>/dev/null | head -1)"
    return
  fi

  info "Installing Caddy web server..."

  case "$PKG_MANAGER" in
    apt)
      sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https 2>/dev/null || true
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
      sudo apt-get update -qq
      sudo apt-get install -y caddy
      ;;
    dnf|yum)
      sudo "$PKG_MANAGER" install -y caddy 2>/dev/null || {
        # Fallback: download binary from GitHub releases
        local arch; arch=$(uname -m)
        [[ "$arch" == "x86_64" ]]  && arch="amd64"
        [[ "$arch" == "aarch64" ]] && arch="arm64"
        local url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${arch}.tar.gz"
        info "Downloading Caddy binary..."
        curl -fsSL "$url" | sudo tar -xz -C /usr/local/bin caddy
        sudo chmod +x /usr/local/bin/caddy
      }
      ;;
    pacman)
      sudo pacman -S --noconfirm caddy
      ;;
  esac

  command_exists caddy || die "Caddy installation failed."
  success "Caddy installed."
}

# ─── Configuration ────────────────────────────────────────────────────────────
gather_config() {
  GATEWAY_PORT="18789"
  HTTPS_PORT="443"

  CONFIGURE_FIREWALL=false
  if command_exists ufw || command_exists firewall-cmd; then
    CONFIGURE_FIREWALL=true
  fi

  info "Gateway port: ${GATEWAY_PORT}"
  info "HTTPS port:   ${HTTPS_PORT}"
}

# ─── Patch Config for LAN Access ─────────────────────────────────────────────
patch_config() {
  local config_file="${HOME}/.openclaw/openclaw.json"

  # Wait up to 10s for the config file to appear
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

  # Read the auth token set by the OpenClaw installer
  local actual_token
  actual_token=$(jq -r '.gateway.auth.token // empty' "$config_file" 2>/dev/null || true)
  if [[ -n "$actual_token" ]]; then
    GATEWAY_TOKEN="$actual_token"
    info "Gateway auth token read from config: ${GATEWAY_TOKEN:0:16}..."
  fi

  local tmp="${config_file}.patch.tmp"
  jq --arg token "${GATEWAY_TOKEN:-}" \
    '. * {"gateway": {"bind": "lan", "remote": {"token": $token}, "controlUi": {"dangerouslyAllowHostHeaderOriginFallback": true}}}' \
    "$config_file" > "$tmp" && mv "$tmp" "$config_file"

  success "Config patched — Control UI accessible from LAN."
}

# ─── Caddy HTTPS Setup ────────────────────────────────────────────────────────
setup_caddy() {
  info "Setting up Caddy HTTPS reverse proxy..."

  local cert_dir="/etc/caddy/certs"
  sudo mkdir -p "$cert_dir"

  # Collect all server IPs for the certificate SAN
  local server_ips
  server_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | \
    sed 's/^/IP:/' | paste -sd ',' -)
  [[ -z "$server_ips" ]] && server_ips="IP:127.0.0.1"
  local san="IP:127.0.0.1,${server_ips}"

  info "Generating self-signed TLS certificate (SAN: ${san})..."
  sudo openssl req -x509 -newkey rsa:2048 \
    -keyout "${cert_dir}/key.pem" \
    -out    "${cert_dir}/cert.pem" \
    -sha256 -days 3650 -nodes \
    -subj   "/CN=openclaw-gateway" \
    -addext "subjectAltName=${san}" \
    2>/dev/null
  sudo chmod 644 "${cert_dir}/cert.pem" "${cert_dir}/key.pem"
  success "TLS certificate generated."

  # Write Caddyfile
  sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
:${HTTPS_PORT} {
    tls ${cert_dir}/cert.pem ${cert_dir}/key.pem
    reverse_proxy 127.0.0.1:${GATEWAY_PORT}
}
EOF

  # Enable and start Caddy via systemd
  sudo systemctl enable caddy  2>/dev/null || true
  sudo systemctl restart caddy
  success "Caddy started (HTTPS on port ${HTTPS_PORT})."
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
    echo -n "  [${attempts}/${max}] waiting..."$'\r'
    sleep 2
    attempts=$((attempts + 1))
  done
  echo
  warn "Gateway health check timed out after $((max * 2))s."
  warn "Check logs: journalctl -u openclaw -f"
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
  echo -e "  ${BOLD}${CYAN}  ➜  https://${server_ip}/#token=${GATEWAY_TOKEN:-}${RESET}"
  echo
  echo -e "  Accept the certificate warning, then click ${BOLD}Connect${RESET}."
  echo -e "  The script will auto-approve the pairing request."
  echo

  local attempts=0 max=60
  while [[ $attempts -lt $max ]]; do
    local request_id
    request_id=$(jq -r 'keys[0] // empty' "$pending_file" 2>/dev/null || true)

    if [[ -n "$request_id" ]]; then
      echo
      info "Pairing request detected — approving..."
      if openclaw devices approve "$request_id" 2>/dev/null; then
        success "Device paired! The web UI is ready to use."
        return 0
      else
        warn "Approval failed. Run manually:"
        warn "  openclaw devices approve ${request_id}"
        return 1
      fi
    fi

    echo -n "  [${attempts}/${max}] waiting for browser connection..."$'\r'
    sleep 2
    attempts=$((attempts + 1))
  done

  echo
  warn "No pairing request detected within 2 minutes."
  warn "Run manually after opening the browser:"
  warn "  openclaw devices approve \$(jq -r 'keys[0]' ~/.openclaw/devices/pending.json)"
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
  echo -e "  ${BOLD}${CYAN}  ➜  https://${server_ip}/#token=${GATEWAY_TOKEN:-}${RESET}"
  echo
  echo -e "  ${YELLOW}Note: Accept the certificate warning (self-signed cert) on first visit.${RESET}"
  echo
  echo -e "${BOLD}${CYAN}━━━  Useful Commands  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  echo -e "  ${BOLD}Logs:${RESET}      journalctl -u openclaw -f"
  echo -e "  ${BOLD}Restart:${RESET}   sudo systemctl restart openclaw"
  echo -e "  ${BOLD}Update:${RESET}    curl -fsSL https://openclaw.ai/install.sh | bash"
  echo -e "  ${BOLD}Caddy:${RESET}     sudo systemctl restart caddy"
  echo -e "  ${BOLD}Uninstall:${RESET} bash <(curl -fsSL https://raw.githubusercontent.com/tahasaifeee/openclaw_AutoInstall_Dockerized/main/deploy.sh) --uninstall"
  echo
}

# ─── Configure Mode (update settings without full reinstall) ─────────────────
configure_mode() {
  banner
  local config_file="${HOME}/.openclaw/openclaw.json"

  if [[ ! -f "$config_file" ]]; then
    die "OpenClaw is not installed. Run the script without flags to install first."
  fi

  echo -e "${BOLD}${CYAN}━━━  Update Configuration  ━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  info "Editing: ${config_file}"
  info "Press Enter on any field to keep the current value / skip it."
  echo

  # ── AI Provider Keys ──────────────────────────────────────────────────────
  echo -e "${BOLD}AI Provider Keys${RESET}"
  echo

  local -a key_entries=(
    "openai:OpenAI (GPT)"
    "anthropic:Anthropic (Claude)"
    "gemini:Google (Gemini)"
    "groq:Groq"
    "openrouter:OpenRouter"
  )

  local changed=false

  for entry in "${key_entries[@]}"; do
    local provider="${entry%%:*}"
    local label="${entry##*:}"
    local current new_val hint

    current=$(jq -r --arg p "$provider" '.secrets.providers[$p] // empty' "$config_file" 2>/dev/null || true)

    if [[ -n "$current" ]]; then
      hint=" [current: ${current:0:8}... — Enter to keep]"
    else
      hint=" [Enter to skip]"
    fi

    read -rsp "$(echo -e "${BOLD}${label} API key${hint}: ${RESET}")" new_val
    echo

    if [[ -n "$new_val" ]]; then
      echo -e "  ${CYAN}Entered:${RESET} ${new_val:0:8}...${new_val: -4} (${#new_val} chars)"
      local tmp="${config_file}.tmp"
      jq --arg p "$provider" --arg k "$new_val" \
        '.secrets.providers[$p] = $k' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
      success "${provider} API key updated."
      changed=true
    fi
  done

  # ── Telegram bot token ────────────────────────────────────────────────────
  echo
  echo -e "${BOLD}Telegram Bot Token${RESET} (from @BotFather)"
  echo
  local current_tg new_tg tg_hint
  current_tg=$(jq -r '.channels.telegram.botToken // empty' "$config_file" 2>/dev/null || true)
  [[ -n "$current_tg" ]] && tg_hint=" [current: ${current_tg:0:8}... — Enter to keep]" || tg_hint=" [Enter to skip]"

  read -rsp "$(echo -e "${BOLD}Telegram bot token${tg_hint}: ${RESET}")" new_tg
  echo

  if [[ -n "$new_tg" ]]; then
    echo -e "  ${CYAN}Entered:${RESET} ${new_tg:0:8}...${new_tg: -4} (${#new_tg} chars)"
    local tmp="${config_file}.tmp"
    jq --arg t "$new_tg" '.channels.telegram.botToken = $t' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    success "Telegram bot token updated."
    changed=true
  fi

  # ── Apply ─────────────────────────────────────────────────────────────────
  echo
  if [[ "$changed" == "true" ]]; then
    info "Restarting OpenClaw to apply changes..."
    sudo systemctl restart openclaw 2>/dev/null || \
      openclaw restart 2>/dev/null || \
      warn "Could not restart automatically. Run: sudo systemctl restart openclaw"
    success "Changes applied."
  else
    info "No changes made."
  fi
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
uninstall() {
  banner
  echo -e "${BOLD}${RED}━━━  Uninstall OpenClaw  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  echo -e "  This will remove:"
  echo -e "    • OpenClaw service and binary"
  echo -e "    • Caddy reverse proxy"
  echo -e "    • Config directory: ${HOME}/.openclaw"
  echo -e "    • TLS certificates: /etc/caddy/certs"
  echo
  if ! ask_yn "Are you sure you want to completely uninstall OpenClaw?" "n"; then
    info "Uninstall cancelled."
    exit 0
  fi

  # ── Stop and remove Caddy ────────────────────────────────────────────────
  info "Stopping Caddy..."
  sudo systemctl stop caddy  2>/dev/null || true
  sudo systemctl disable caddy 2>/dev/null || true
  sudo rm -f /etc/caddy/Caddyfile
  sudo rm -rf /etc/caddy/certs
  success "Caddy removed."

  # ── Stop and remove OpenClaw ─────────────────────────────────────────────
  info "Stopping OpenClaw..."
  sudo systemctl stop openclaw 2>/dev/null || true
  sudo systemctl disable openclaw 2>/dev/null || true

  # Try official uninstall first
  if command_exists openclaw; then
    openclaw uninstall 2>/dev/null || true
  fi

  # Remove binary if still present
  sudo rm -f /usr/local/bin/openclaw /usr/bin/openclaw "$HOME/.local/bin/openclaw"
  success "OpenClaw removed."

  # ── Remove config directory ───────────────────────────────────────────────
  info "Removing config directory: ${HOME}/.openclaw"
  rm -rf "${HOME}/.openclaw"

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

  echo
  echo -e "${BOLD}${GREEN}━━━  Uninstall Complete  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  OpenClaw has been fully removed from this system."
  echo
}

# ─── Installation State Menu ──────────────────────────────────────────────────
installed_menu() {
  echo -e "${BOLD}${CYAN}━━━  OpenClaw is already installed  ━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
  echo -e "  ${BOLD}[1]${RESET} Update configuration  (AI keys, Telegram token, etc.)"
  echo -e "  ${BOLD}[2]${RESET} Uninstall"
  echo -e "  ${BOLD}[3]${RESET} Reinstall  (full fresh setup)"
  echo

  local choice
  while true; do
    read -rp "$(echo -e "${BOLD}Enter choice [1-3]: ${RESET}")" choice
    case "$choice" in
      1) configure_mode; exit 0 ;;
      2) uninstall;      exit 0 ;;
      3) info "Proceeding with reinstall..."; echo; return ;;
      *) warn "Please enter 1, 2, or 3." ;;
    esac
  done
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Handle explicit flags before anything else
  for arg in "$@"; do
    case "$arg" in
      --uninstall|uninstall)
        uninstall
        exit 0
        ;;
      --configure|configure)
        configure_mode
        exit 0
        ;;
    esac
  done

  banner

  # Guard against running inside Docker itself
  if [[ -f /.dockerenv ]]; then
    die "This script should not be run inside a Docker container."
  fi

  # Auto-detect existing installation
  if [[ -f "${HOME}/.openclaw/openclaw.json" ]]; then
    installed_menu
  fi

  check_root
  check_sudo
  detect_os
  install_prerequisites
  install_openclaw
  gather_config
  patch_config
  install_caddy
  setup_caddy
  configure_firewall
  health_check
  auto_approve_pairing
  print_summary
}

main "$@"
