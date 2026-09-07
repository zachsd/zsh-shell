#!/usr/bin/env bash
# DevOps tools + Nushell, Starship, Carapace and zoxide.
# Historical filename retained for compatibility; this now configures Nushell.

set -uo pipefail
ZSH_SETUP_CONFIG_ONLY="${SHELL_SETUP_CONFIG_ONLY:-${ZSH_SETUP_CONFIG_ONLY:-0}}"

# ------------------------------------------------------------------------------
# Colours & helpers
# ------------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
           echo -e "${BOLD}${CYAN}  $*${RESET}"; \
           echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

FAILED_PKGS=()

safe_brew_install() {
  local pkg="$1" desc="${2:-$1}"
  if brew list --formula "$pkg" &>/dev/null || brew list --cask "$pkg" &>/dev/null; then
    log "$desc — already installed."
  else
    log "Installing $desc …"
    brew install "$pkg" 2>/dev/null || { warn "FAILED: $pkg"; FAILED_PKGS+=("$pkg"); }
  fi
}

safe_cask_install() {
  local pkg="$1" desc="${2:-$1}"
  if brew list --cask "$pkg" &>/dev/null; then
    log "$desc — already installed."
  else
    log "Installing $desc …"
    brew install --cask "$pkg" 2>/dev/null || { warn "FAILED (cask): $pkg"; FAILED_PKGS+=("$pkg"); }
  fi
}


# ==============================================================================
# 1. Preflight
# ==============================================================================
# Install npm CLIs per-user without sudo or shell-startup installation.
install_npm_cli() {
  local package="$1" executable="$2" min_major="$3" min_minor="${4:-0}"
  if command -v "$executable" &>/dev/null || [[ -x "$HOME/.local/bin/$executable" ]]; then
    log "$executable — already installed."
    return 0
  fi
  if ! command -v npm &>/dev/null || ! command -v node &>/dev/null ||
     ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); const [x,y]=process.argv.slice(1).map(Number); process.exit(a>x || (a===x && b>=y) ? 0 : 1)' "$min_major" "$min_minor"; then
    warn "$executable requires Node.js ${min_major}.${min_minor}+ and npm; install a supported Node.js LTS release and rerun."
    FAILED_PKGS+=("$package")
    return 1
  fi
  log "Installing $package …"
  npm install --global --prefix "$HOME/.local" --ignore-scripts --engine-strict "$package" \
    || { warn "FAILED: $package"; FAILED_PKGS+=("$package"); return 1; }
}

if [[ ${ZSH_SETUP_CONFIG_ONLY:-0} != 1 ]]; then
header "1 / 8  Preflight checks"

[[ "$(uname -s)" == "Darwin" ]] || error "This script targets macOS only."
log "macOS $(sw_vers -productVersion) — $(uname -m)"

# ==============================================================================
# 2. Homebrew
# ==============================================================================
header "2 / 8  Homebrew"

if ! command -v brew &>/dev/null; then
  log "Installing Homebrew …"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Ensure brew is in PATH for this session (Apple Silicon & Intel)
if [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

log "Homebrew $(brew --version | head -1)"
brew update --quiet

# ==============================================================================
# 3. Nerd Font (Starship icons)
# ==============================================================================
header "3 / 8  Nerd Font — JetBrainsMono"

brew tap homebrew/cask-fonts 2>/dev/null || true
safe_cask_install "font-jetbrains-mono-nerd-font" "JetBrainsMono Nerd Font"
warn "Remember to set your terminal font to 'JetBrainsMono Nerd Font Mono'."
warn "  • iTerm2:       Preferences → Profiles → Text → Font"
warn "  • Terminal.app: Settings → Profiles → Font"
warn "  • VSCode:       terminal.integrated.fontFamily"

header "4 / 8  Nushell, Starship, Carapace & zoxide"
safe_brew_install nushell "Nushell (default shell)"
safe_brew_install neovim "Neovim (default editor)"
safe_brew_install tree-sitter "Tree-sitter CLI (Neovim parser runtime)"
safe_brew_install starship "Starship prompt"
safe_brew_install carapace "Carapace command completion"
safe_brew_install zoxide "zoxide (smart directory navigation)"

# ==============================================================================
# 7. Tool installation
# ==============================================================================
header "7 / 8  Installing tools"

# ── DevOps / Cloud ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}  DevOps / IaC${RESET}"
safe_brew_install terraform             "HashiCorp Terraform"
safe_brew_install terragrunt            "Terragrunt"
safe_brew_install tflint                "TFLint"
safe_brew_install terraform-docs        "terraform-docs"
safe_brew_install infracost             "Infracost"
safe_brew_install packer                "HashiCorp Packer"
safe_brew_install vault                 "HashiCorp Vault"
safe_brew_install sops                  "SOPS (secrets)"
safe_brew_install ansible               "Ansible"

echo -e "\n${BOLD}  AWS${RESET}"
safe_brew_install awscli                "AWS CLI v2"
safe_brew_install aws-iam-authenticator "AWS IAM Authenticator"
safe_brew_install eksctl                "eksctl (EKS)"

echo -e "\n${BOLD}  Azure${RESET}"
safe_brew_install azure-cli             "Azure CLI"

echo -e "\n${BOLD}  Kubernetes / OpenShift / Helm${RESET}"
safe_brew_install kubectl               "kubectl"
safe_brew_install kubectx               "kubectx + kubens"
safe_brew_install k9s                   "K9s (TUI)"
safe_brew_install helm                  "Helm"
safe_brew_install kustomize             "Kustomize"
safe_brew_install stern                 "Stern (multi-pod log tailing)"
safe_brew_install kubeseal              "Sealed Secrets CLI"
safe_brew_install openshift-cli         "OpenShift CLI (oc)"
safe_brew_install kubecolor             "kubecolor (colourised kubectl)"

echo -e "\n${BOLD}  Containers${RESET}"
safe_brew_install podman                "Podman"
safe_brew_install docker-compose        "Docker Compose"

echo -e "\n${BOLD}  General Dev${RESET}"
safe_brew_install git                   "Git"
safe_brew_install gh                    "GitHub CLI"
safe_brew_install jq                    "jq"
safe_brew_install yq                    "yq"
safe_brew_install fzf                   "fzf"
safe_brew_install bat                   "bat (better cat)"
safe_brew_install eza                   "eza (modern ls)"
safe_brew_install zoxide                "zoxide (smart cd)"
safe_brew_install ripgrep               "ripgrep (rg)"
safe_brew_install fd                    "fd (better find)"
safe_brew_install tldr                  "tldr"
safe_brew_install direnv                "direnv"

# ── Agent tools & worktrees ────────────────────────────────────────────────────
echo -e "\n${BOLD}  Agent tools & worktrees${RESET}"
safe_brew_install herdr     "Herdr (agent multiplexer)"
safe_brew_install worktrunk "Worktrunk (wt)"
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
  safe_brew_install node "Node.js + npm (agent CLI runtime)"
fi
install_npm_cli "@earendil-works/pi-coding-agent" pi 22 19
install_npm_cli "@a5c-ai/babysitter" babysitter 20

# ── Network / SysAdmin diagnostics ─────────────────────────────────────────
echo -e "\n${BOLD}  Network & SysAdmin diagnostics${RESET}"
safe_brew_install netcat                "netcat (nc)"
safe_brew_install bind                  "BIND tools: dig, nslookup, host"
safe_brew_install nmap                  "Nmap"
safe_brew_install mtr                   "mtr (traceroute + ping)"
safe_brew_install tcpdump               "tcpdump"
safe_brew_install wireshark             "Wireshark (tshark)"
safe_brew_install httpie                "HTTPie (http/https)"
safe_brew_install curl                  "curl (Homebrew — latest)"
safe_brew_install wget                  "wget"
safe_brew_install socat                 "socat"
safe_brew_install iperf3                "iperf3 (bandwidth testing)"
safe_brew_install nload                 "nload (bandwidth monitor)"
safe_brew_install lsof                  "lsof"
safe_brew_install watch                 "watch"
safe_brew_install rsync                 "rsync"
safe_brew_install openssh               "OpenSSH"
safe_brew_install tmux                  "tmux"
safe_brew_install htop                  "htop"
safe_brew_install bottom                "bottom (btm — system monitor)"
safe_brew_install speedtest-cli         "Speedtest CLI"
safe_brew_install httping                 "hping (TCP/IP packet tester)"
safe_brew_install whois                 "whois"
safe_brew_install ipcalc                "ipcalc (IP subnet calculator)"

# ── VSCode ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}  VSCode${RESET}"
if command -v code &>/dev/null; then
  log "VSCode 'code' CLI already available ($(code --version 2>/dev/null | head -1))."
elif [[ -d "/Applications/Visual Studio Code.app" ]]; then
  warn "VSCode is installed but 'code' CLI is missing."
  warn "Open VSCode → Cmd+Shift+P → 'Shell Command: Install code in PATH'"
else
  safe_cask_install "visual-studio-code" "Visual Studio Code"
fi

fi # dependency installation

# Configure and validate before changing the account's login shell.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
command -v nu &>/dev/null || error "Nushell is required. Install nu and rerun."
nu --no-config-file "$SCRIPT_DIR/configure-nushell.nu" || error "Nushell configuration failed; login shell unchanged."
nu --no-config-file "$SCRIPT_DIR/configure-neovim.nu" \
  || { warn "tree-sitter-nu configuration failed."; FAILED_PKGS+=("tree-sitter-nu"); }

if [[ "$ZSH_SETUP_CONFIG_ONLY" != 1 && ${SHELL_SETUP_SET_DEFAULT:-1} == 1 ]]; then
  NU_BIN="$(command -v nu)"
  if ! grep -qxF "$NU_BIN" /etc/shells; then
    printf '%s\n' "$NU_BIN" | sudo tee -a /etc/shells >/dev/null \
      || error "Could not register Nushell in /etc/shells."
  fi
  if [[ ${SHELL:-} != "$NU_BIN" ]]; then
    chsh -s "$NU_BIN" || { warn "Default shell change failed. Run: chsh -s $NU_BIN"; FAILED_PKGS+=("default shell"); }
  fi
fi
header "Setup complete — Nushell + Starship"
log "Open a new terminal. Use z / zi for smart directory navigation and Tab for Carapace completions."
log "Refresh integrations after upgrades: nu --no-config-file $SCRIPT_DIR/configure-nushell.nu"
if (( ${#FAILED_PKGS[@]} )); then
  warn "The following items need attention: ${FAILED_PKGS[*]}"
fi
