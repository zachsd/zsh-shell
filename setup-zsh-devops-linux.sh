#!/usr/bin/env bash
# ==============================================================================
# Modern ZSH Environment Setup — DevOps / Cloud / SysAdmin  (Linux)
# ==============================================================================
# Tools: oh-my-zsh + oh-my-posh (bubblesextra theme), zsh-autocomplete,
#        zsh-autosuggestions, fast-syntax-highlighting
#
# Workloads: Terraform, Terragrunt, AWS, Azure, Kubernetes, OpenShift, Helm,
#            VSCode, plus network/sysadmin diagnostic utilities.
#
# Supports: Debian/Ubuntu (apt)  |  RHEL/CentOS/Fedora/AlmaLinux (dnf/yum)
#
# Usage: bash setup-zsh-devops-linux.sh
# ==============================================================================

set -uo pipefail

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

# When FAIL_LOG is a non-empty path, failures are appended there instead of the
# FAILED_PKGS array. Background jobs run in subshells and can't mutate the
# parent's array, so during the parallel-download phase we point FAIL_LOG at a
# temp file and merge it back afterwards. record_failure() bridges both modes.
FAIL_LOG=""
record_failure() {
  if [[ -n "$FAIL_LOG" ]]; then
    printf '%s\n' "$1" >> "$FAIL_LOG"   # single-line append is atomic (< PIPE_BUF)
  else
    FAILED_PKGS+=("$1")
  fi
}

# Populated by detect_distro():
PKG_MANAGER=""    # "apt" | "dnf" | "yum"
DISTRO_FAMILY=""  # "debian" | "rhel"
DISTRO_ID=""      # e.g. "ubuntu", "debian", "fedora", "centos", "rhel", "almalinux"
DISTRO_VERSION="" # e.g. "22.04", "9"

# Populated by detect_arch():
ARCH=""      # Go-style: "amd64" | "arm64"
ARCH_ALT=""  # target-triple style: "x86_64" | "aarch64" (some projects use this)

# Background sudo keepalive PID
SUDO_KEEPALIVE_PID=""

# ------------------------------------------------------------------------------
# Distro & architecture detection
# ------------------------------------------------------------------------------
detect_distro() {
  if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release not found. Cannot detect distro. Aborting."
  fi

  DISTRO_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
  DISTRO_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"
  local id_like
  id_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"

  case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|elementary|kali)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt"
      ;;
    fedora)
      DISTRO_FAMILY="rhel"
      PKG_MANAGER="dnf"
      ;;
    rhel|centos|almalinux|rocky|ol)
      DISTRO_FAMILY="rhel"
      if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
      else
        PKG_MANAGER="yum"
      fi
      ;;
    *)
      if [[ "$id_like" == *debian* || "$id_like" == *ubuntu* ]]; then
        DISTRO_FAMILY="debian"
        PKG_MANAGER="apt"
      elif [[ "$id_like" == *rhel* || "$id_like" == *fedora* ]]; then
        DISTRO_FAMILY="rhel"
        PKG_MANAGER="dnf"
      else
        warn "Unsupported distro: $DISTRO_ID (ID_LIKE='$id_like')."
        warn "Continuing with best-effort support. Some steps may fail."
        DISTRO_FAMILY="unknown"
        PKG_MANAGER=""
      fi
      ;;
  esac

  log "Distro: $DISTRO_ID $DISTRO_VERSION | Family: $DISTRO_FAMILY | Package manager: $PKG_MANAGER"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64"; ARCH_ALT="x86_64"  ;;
    aarch64) ARCH="arm64"; ARCH_ALT="aarch64" ;;
    armv7l)  ARCH="arm";   ARCH_ALT="armv7"   ;;
    *)       ARCH="$(uname -m)"; ARCH_ALT="$ARCH"; warn "Unrecognised architecture: $ARCH" ;;
  esac
  log "Architecture: $ARCH (alt: $ARCH_ALT)"
}

require_sudo() {
  if [[ "$EUID" -eq 0 ]]; then
    warn "Running as root. Some steps may behave differently than when run as a regular user."
    return 0
  fi
  if ! sudo -v 2>/dev/null; then
    error "sudo access required. Add yourself to the sudoers file and re-run."
  fi
  # Keep sudo timestamp alive so it doesn't expire mid-install
  (while true; do sudo -v; sleep 50; done) &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
}

# ------------------------------------------------------------------------------
# Package manager helpers
# ------------------------------------------------------------------------------
pkg_update() {
  log "Updating package index …"
  case "$PKG_MANAGER" in
    apt) sudo apt-get update -qq ;;
    dnf) sudo dnf makecache --quiet ;;
    yum) sudo yum makecache --quiet ;;
    *)   warn "Unknown package manager; skipping update." ;;
  esac
}

# NOTE: For binaries installed outside the package manager (via GitHub releases
# or vendor scripts), always guard with 'command -v <binary> &>/dev/null' rather
# than relying on safe_pkg_install's dpkg/rpm check.
safe_pkg_install() {
  local pkg="$1" desc="${2:-$1}"

  # Fast-path: check if the package is already installed
  if dpkg -s "$pkg" &>/dev/null || rpm -q "$pkg" &>/dev/null; then
    log "$desc — already installed."
    return 0
  fi

  log "Installing $desc …"
  case "$PKG_MANAGER" in
    apt) sudo apt-get install -y -qq "$pkg" 2>/dev/null \
           || { warn "FAILED: $pkg"; FAILED_PKGS+=("$pkg"); } ;;
    dnf) sudo dnf install -y -q  "$pkg" 2>/dev/null \
           || { warn "FAILED: $pkg"; FAILED_PKGS+=("$pkg"); } ;;
    yum) sudo yum install -y -q  "$pkg" 2>/dev/null \
           || { warn "FAILED: $pkg"; FAILED_PKGS+=("$pkg"); } ;;
    *)   warn "No package manager available — cannot install $pkg."; FAILED_PKGS+=("$pkg") ;;
  esac
}

clone_or_update_plugin() {
  local repo="$1" dest="$2" name
  name="$(basename "$dest")"
  if [[ -d "$dest/.git" ]]; then
    log "Plugin $name — pulling latest …"
    git -C "$dest" pull --quiet --ff-only 2>/dev/null || true
  else
    log "Cloning plugin $name …"
    git clone --depth=1 "https://github.com/$repo" "$dest" 2>/dev/null \
      || { warn "Failed to clone $repo"; FAILED_PKGS+=("$name"); }
  fi
}

# ------------------------------------------------------------------------------
# GitHub release binary installer
# Downloads the latest release asset matching asset_re and installs to install_path.
# Supports tar.gz, zip, and bare binaries.
# Respects GITHUB_TOKEN if set (avoids API rate limits).
# ------------------------------------------------------------------------------
install_github_release() {
  local repo="$1"        # e.g. "derailed/k9s"
  local asset_re="$2"    # extended regex matching the asset filename
  local install_path="$3"
  local desc="${4:-$(basename "$install_path")}"
  local api_url="https://api.github.com/repos/${repo}/releases/latest"

  if [[ -x "$install_path" ]]; then
    log "$desc — already installed at $install_path."
    return 0
  fi

  log "Fetching latest release info for $repo …"
  local curl_auth_opts=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && curl_auth_opts=(-H "Authorization: token $GITHUB_TOKEN")

  local download_url
  download_url=$(curl "${curl_auth_opts[@]}" -fsSL "$api_url" \
    | grep '"browser_download_url"' \
    | grep -E "$asset_re" \
    | head -1 \
    | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

  if [[ -z "$download_url" ]]; then
    warn "Could not find asset matching '$asset_re' in $repo releases."
    record_failure "$desc"
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  local filename
  filename=$(basename "$download_url")
  local binary_name
  binary_name=$(basename "$install_path")

  log "Downloading $filename …"
  curl -fsSL "$download_url" -o "${tmpdir}/${filename}" || {
    warn "Download failed for $desc."
    record_failure "$desc"
    rm -rf "$tmpdir"
    return 1
  }

  case "$filename" in
    *.tar.gz|*.tgz)
      tar -xzf "${tmpdir}/${filename}" -C "$tmpdir"
      local found
      found=$(find "$tmpdir" -type f -name "$binary_name" | head -1)
      [[ -z "$found" ]] && found=$(find "$tmpdir" -maxdepth 3 -type f -executable ! -name "*.tar.gz" | head -1)
      if [[ -n "$found" ]]; then
        sudo install -m 0755 "$found" "$install_path"
      else
        warn "Could not locate '$binary_name' after unpacking $filename."
        record_failure "$desc"; rm -rf "$tmpdir"; return 1
      fi
      ;;
    *.zip)
      unzip -q "${tmpdir}/${filename}" -d "$tmpdir"
      local found
      found=$(find "$tmpdir" -type f -name "$binary_name" | head -1)
      if [[ -n "$found" ]]; then
        sudo install -m 0755 "$found" "$install_path"
      else
        warn "Could not locate '$binary_name' after unzipping."
        record_failure "$desc"; rm -rf "$tmpdir"; return 1
      fi
      ;;
    *)
      # Assume the asset itself is the binary
      sudo install -m 0755 "${tmpdir}/${filename}" "$install_path"
      ;;
  esac

  rm -rf "$tmpdir"
  log "$desc installed → $install_path"
}

# ------------------------------------------------------------------------------
# Bounded parallel job pool
# The GitHub-release installs are independent and network-bound, so running them
# concurrently cuts the wall-clock time of Step 8 substantially. pbg launches its
# argument command in the background, throttled to MAX_PARALLEL_DOWNLOADS live
# jobs; wait_downloads() blocks until they all finish. Only self-contained
# install_github_release calls go through this — never apt/dnf (which serialize
# on the dpkg/rpm lock anyway). Failures are collected via FAIL_LOG.
# ------------------------------------------------------------------------------
MAX_PARALLEL_DOWNLOADS="${MAX_PARALLEL_DOWNLOADS:-6}"
DOWNLOAD_PIDS=()

pbg() {
  # While at capacity, prune finished PIDs and wait. The array is only expanded
  # inside the loop body (guaranteed non-empty there) to stay safe under set -u.
  while (( ${#DOWNLOAD_PIDS[@]} >= MAX_PARALLEL_DOWNLOADS )); do
    local live=() p
    for p in "${DOWNLOAD_PIDS[@]}"; do
      kill -0 "$p" 2>/dev/null && live+=("$p")
    done
    if (( ${#live[@]} )); then DOWNLOAD_PIDS=("${live[@]}"); else DOWNLOAD_PIDS=(); fi
    (( ${#DOWNLOAD_PIDS[@]} >= MAX_PARALLEL_DOWNLOADS )) && sleep 0.3
  done
  "$@" &
  DOWNLOAD_PIDS+=($!)
}

wait_downloads() {
  # Wait only for our download jobs (not the sudo keepalive), then merge any
  # failures recorded to FAIL_LOG back into FAILED_PKGS.
  [[ ${#DOWNLOAD_PIDS[@]} -gt 0 ]] && wait "${DOWNLOAD_PIDS[@]}" 2>/dev/null
  DOWNLOAD_PIDS=()
  if [[ -n "$FAIL_LOG" && -s "$FAIL_LOG" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && FAILED_PKGS+=("$line")
    done < "$FAIL_LOG"
  fi
  [[ -n "$FAIL_LOG" ]] && rm -f "$FAIL_LOG"
  FAIL_LOG=""
}

# ------------------------------------------------------------------------------
# GitHub API rate-limit check
# This script makes ~16 unauthenticated GitHub API calls (release lookups + the
# Nerd Font). Unauthenticated requests are capped at 60/hour/IP, so shared or
# NAT'd networks — or a re-run — can exhaust the budget and cause downloads to
# fail with HTTP 403. Warn early and point at GITHUB_TOKEN. (The /rate_limit
# endpoint itself does not count against the limit.)
# ------------------------------------------------------------------------------
check_github_rate_limit() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "GITHUB_TOKEN detected — using authenticated GitHub API (higher rate limit)."
    return 0
  fi
  local remaining
  remaining=$(curl -fsSL --max-time 10 "https://api.github.com/rate_limit" 2>/dev/null \
    | grep -A3 '"core"' | grep '"remaining"' | grep -oE '[0-9]+' | head -1)
  if [[ -z "$remaining" ]]; then
    warn "Could not query GitHub API rate limit. Set GITHUB_TOKEN if downloads 403."
  elif (( remaining < 20 )); then
    warn "GitHub API: only ${remaining} unauthenticated requests left this hour."
    warn "  This script needs ~16; some downloads may fail with HTTP 403."
    warn "  Raise the limit:  export GITHUB_TOKEN=<a personal access token>"
  else
    log "GitHub API: ${remaining} unauthenticated requests remaining this hour."
    log "  Tip: export GITHUB_TOKEN to avoid rate limits (recommended for re-runs)."
  fi
}

# ==============================================================================
# 1. Preflight
# ==============================================================================
header "1 / 8  Preflight checks"

[[ "$(uname -s)" == "Linux" ]] || error "This script targets Linux only."

detect_distro
detect_arch
require_sudo

log "Linux $(uname -r) — $(uname -m)"

# Ensure ~/.local/bin exists and is on PATH for this session
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"

# Bootstrap bare essentials before anything else
for _cmd in curl git unzip tar; do
  if ! command -v "$_cmd" &>/dev/null; then
    warn "Required tool missing: $_cmd — attempting install"
    case "$PKG_MANAGER" in
      apt) sudo apt-get install -y -qq "$_cmd" ;;
      dnf|yum) sudo "$PKG_MANAGER" install -y -q "$_cmd" ;;
    esac
  fi
done
unset _cmd

check_github_rate_limit

# ==============================================================================
# 2. Package manager setup and external repos
# ==============================================================================
header "2 / 8  Package manager setup and external repos"

pkg_update

add_apt_repo() {
  local name="$1" key_url="$2" repo_line="$3"
  local keyring_path="/usr/share/keyrings/${name}-archive-keyring.gpg"
  if [[ -f "/etc/apt/sources.list.d/${name}.list" ]]; then
    log "Repo $name already configured."
    return 0
  fi
  log "Adding apt repo: $name …"
  curl -fsSL "$key_url" | sudo gpg --dearmor -o "$keyring_path"
  echo "$repo_line" | sudo tee "/etc/apt/sources.list.d/${name}.list" > /dev/null
  sudo apt-get update -qq
}

add_dnf_repo() {
  local name="$1" repo_url="$2"
  if sudo "$PKG_MANAGER" repolist 2>/dev/null | grep -qi "$name"; then
    log "Repo $name already configured."
    return 0
  fi
  log "Adding dnf/yum repo: $name …"
  sudo "$PKG_MANAGER" config-manager --add-repo "$repo_url" 2>/dev/null \
    || sudo "$PKG_MANAGER" install -y -q "$repo_url" 2>/dev/null \
    || warn "Could not add repo $name — some packages may not install."
}

# Derive codename from /etc/os-release (lsb_release may not be present)
VERSION_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
if [[ -z "$VERSION_CODENAME" ]] && command -v lsb_release &>/dev/null; then
  VERSION_CODENAME="$(lsb_release -cs)"
fi

if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  sudo apt-get install -y -qq apt-transport-https ca-certificates gnupg lsb-release \
    software-properties-common curl 2>/dev/null || true

  if [[ -n "$VERSION_CODENAME" ]]; then
    # HashiCorp
    add_apt_repo "hashicorp" \
      "https://apt.releases.hashicorp.com/gpg" \
      "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main"

    # GitHub CLI
    add_apt_repo "github-cli" \
      "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/github-cli-archive-keyring.gpg] https://cli.github.com/packages stable main"

    # Azure CLI
    add_apt_repo "azure-cli" \
      "https://packages.microsoft.com/keys/microsoft.asc" \
      "deb [arch=amd64 signed-by=/usr/share/keyrings/azure-cli-archive-keyring.gpg] https://packages.microsoft.com/repos/azure-cli/ ${VERSION_CODENAME} main"
  else
    warn "Could not determine VERSION_CODENAME — HashiCorp/GitHub CLI/Azure CLI repos not configured."
    warn "Install lsb-release or upgrade to a newer distro to enable these repos."
  fi

  # kubectl
  add_apt_repo "kubernetes" \
    "https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key" \
    "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /"

  # Helm
  add_apt_repo "helm" \
    "https://baltocdn.com/helm/signing.asc" \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm-archive-keyring.gpg] https://baltocdn.com/helm/stable/debian/ all main"

elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  # EPEL (not needed on Fedora)
  if [[ "$DISTRO_ID" != "fedora" ]]; then
    sudo "$PKG_MANAGER" install -y -q epel-release 2>/dev/null || true
  fi

  # HashiCorp
  add_dnf_repo "hashicorp" "https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo"

  # kubectl
  if [[ ! -f /etc/yum.repos.d/kubernetes.repo ]]; then
    log "Adding dnf/yum repo: kubernetes …"
    cat <<'EOF' | sudo tee /etc/yum.repos.d/kubernetes.repo > /dev/null
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
EOF
  else
    log "Repo kubernetes already configured."
  fi

  # GitHub CLI
  add_dnf_repo "github-cli" "https://cli.github.com/packages/rpm/gh-cli.repo"

  # Azure CLI
  if [[ ! -f /etc/yum.repos.d/azure-cli.repo ]]; then
    log "Adding dnf/yum repo: azure-cli …"
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    cat <<'EOF' | sudo tee /etc/yum.repos.d/azure-cli.repo > /dev/null
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  else
    log "Repo azure-cli already configured."
  fi
fi

# ==============================================================================
# 3. Nerd Font — JetBrainsMono
# ==============================================================================
header "3 / 8  Nerd Font — JetBrainsMono"

safe_pkg_install fontconfig "fontconfig (fc-cache)"

FONT_DIR="$HOME/.local/share/fonts"
mkdir -p "$FONT_DIR"

install_nerd_font() {
  local font_check_file="$FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf"
  if [[ -f "$font_check_file" ]]; then
    log "JetBrainsMono Nerd Font — already installed."
    return 0
  fi

  log "Fetching latest JetBrainsMono Nerd Font release …"
  local curl_auth_opts=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && curl_auth_opts=(-H "Authorization: token $GITHUB_TOKEN")

  local download_url
  download_url=$(curl "${curl_auth_opts[@]}" -fsSL \
    "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" \
    | grep '"browser_download_url"' \
    | grep "JetBrainsMono\.zip" \
    | head -1 \
    | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

  if [[ -z "$download_url" ]]; then
    warn "Could not determine JetBrainsMono download URL. Font not installed."
    FAILED_PKGS+=("JetBrainsMono Nerd Font")
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  log "Downloading JetBrainsMono.zip …"
  curl -fsSL "$download_url" -o "${tmpdir}/JetBrainsMono.zip" || {
    warn "Download failed for JetBrainsMono Nerd Font."
    FAILED_PKGS+=("JetBrainsMono Nerd Font")
    rm -rf "$tmpdir"
    return 1
  }

  unzip -q "${tmpdir}/JetBrainsMono.zip" -d "${tmpdir}/JetBrainsMono"
  find "${tmpdir}/JetBrainsMono" -name "*.ttf" ! -name "*Windows*" \
    -exec cp {} "$FONT_DIR/" \;
  rm -rf "$tmpdir"

  if command -v fc-cache &>/dev/null; then
    fc-cache -fv "$FONT_DIR" &>/dev/null
    log "Font cache refreshed."
  fi
  log "JetBrainsMono Nerd Font installed → $FONT_DIR"
}

install_nerd_font

warn "Remember to set your terminal font to 'JetBrainsMono Nerd Font Mono'."
warn "  • GNOME Terminal:  Preferences → Profile → Custom font"
warn "  • Alacritty:       font.family = JetBrainsMono Nerd Font Mono"
warn "  • Kitty:           font_family JetBrainsMono Nerd Font Mono"
warn "  • Konsole:         Settings → Edit Current Profile → Appearance → Font"
warn "  • VSCode:          \"terminal.integrated.fontFamily\": \"JetBrainsMono Nerd Font Mono\""

# ==============================================================================
# 4. ZSH
# ==============================================================================
header "4 / 8  ZSH"

safe_pkg_install zsh "ZSH"

ZSH_BIN="$(which zsh 2>/dev/null)"
[[ -z "$ZSH_BIN" ]] && error "zsh binary not found after install. Aborting."

if ! grep -qF "$ZSH_BIN" /etc/shells; then
  log "Adding $ZSH_BIN to /etc/shells …"
  echo "$ZSH_BIN" | sudo tee -a /etc/shells
fi

if [[ "$SHELL" != "$ZSH_BIN" ]]; then
  log "Changing default shell to $ZSH_BIN …"
  chsh -s "$ZSH_BIN" "$USER" \
    || warn "chsh failed — change shell manually: chsh -s $ZSH_BIN"
fi

log "ZSH $(zsh --version)"

# ==============================================================================
# 5. oh-my-zsh + oh-my-posh
# ==============================================================================
header "5 / 8  oh-my-zsh & oh-my-posh"

if [[ -d "${HOME}/.oh-my-zsh" ]]; then
  log "oh-my-zsh already installed."
else
  log "Installing oh-my-zsh (unattended, no shell switch) …"
  RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# oh-my-posh renders the prompt (the bubblesextra theme); oh-my-zsh is kept for
# its plugins and completions, with its own theme disabled in ~/.zshrc. The
# installer drops the binary in ~/.local/bin (on PATH via ~/.zshenv) and the
# themes under ~/.cache/oh-my-posh/themes.
OMP_THEMES_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-posh/themes"
if command -v oh-my-posh &>/dev/null; then
  log "oh-my-posh already installed ($(oh-my-posh version 2>/dev/null))."
else
  log "Installing oh-my-posh …"
  curl -fsSL https://ohmyposh.dev/install.sh \
    | bash -s -- -d "$HOME/.local/bin" -t "$OMP_THEMES_DIR" \
    || { warn "oh-my-posh install failed; the prompt falls back to the OMZ default until it's installed."; FAILED_PKGS+=("oh-my-posh"); }
fi

# Guarantee the bubblesextra theme file exists where ~/.zshrc looks for it,
# regardless of what the installer bundled.
if [[ ! -f "$OMP_THEMES_DIR/bubblesextra.omp.json" ]]; then
  mkdir -p "$OMP_THEMES_DIR"
  curl -fsSL "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/bubblesextra.omp.json" \
    -o "$OMP_THEMES_DIR/bubblesextra.omp.json" \
    || warn "Could not fetch the bubblesextra theme; oh-my-posh will use its default prompt."
fi

# ==============================================================================
# 6. ZSH plugins (external — cloned into OMZ custom/plugins)
# ==============================================================================
header "6 / 8  ZSH plugins"

ZSH_CUSTOM="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"

# These are loaded via the plugins=() array in ~/.zshrc. Load order there
# matters: fast-syntax-highlighting and zsh-autosuggestions must come before
# zsh-autocomplete (which requires being loaded last).
clone_or_update_plugin "zsh-users/zsh-autosuggestions"              "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
clone_or_update_plugin "zdharma-continuum/fast-syntax-highlighting" "${ZSH_CUSTOM}/plugins/fast-syntax-highlighting"
clone_or_update_plugin "marlonrichert/zsh-autocomplete"             "${ZSH_CUSTOM}/plugins/zsh-autocomplete"

# ==============================================================================
# 7. Tool installation
# ==============================================================================
header "7 / 8  Installing tools"

# GitHub-release binaries (the `pbg …` calls below) download and install in
# parallel; their per-tool logs interleave and their failures are collected via
# FAIL_LOG until wait_downloads() at the end of this step merges them back.
FAIL_LOG="$(mktemp)"
log "Release-binary downloads run in parallel (up to ${MAX_PARALLEL_DOWNLOADS} at once); logs may interleave."

# ── DevOps / IaC ──────────────────────────────────────────────────────────────
echo -e "\n${BOLD}  DevOps / IaC${RESET}"

# HashiCorp tools — via vendor apt/dnf repo registered in Step 2
safe_pkg_install terraform "HashiCorp Terraform"
safe_pkg_install packer    "HashiCorp Packer"
safe_pkg_install vault     "HashiCorp Vault"

# Terragrunt — GitHub release binary
pbg install_github_release "gruntwork-io/terragrunt" \
  "terragrunt_linux_${ARCH}$" \
  "/usr/local/bin/terragrunt" \
  "Terragrunt"

# TFLint — GitHub release binary (zip)
pbg install_github_release "terraform-linters/tflint" \
  "tflint_linux_${ARCH}\.zip" \
  "/usr/local/bin/tflint" \
  "TFLint"

# terraform-docs — GitHub release binary (tar.gz)
pbg install_github_release "terraform-docs/terraform-docs" \
  "terraform-docs-v[0-9].*-linux-${ARCH}\.tar\.gz" \
  "/usr/local/bin/terraform-docs" \
  "terraform-docs"

# Infracost — GitHub release binary (tar.gz)
pbg install_github_release "infracost/infracost" \
  "infracost-linux-${ARCH}\.tar\.gz" \
  "/usr/local/bin/infracost" \
  "Infracost"

# SOPS — GitHub release binary (bare binary)
pbg install_github_release "getsops/sops" \
  "sops-v[0-9].*\.linux\.${ARCH}$" \
  "/usr/local/bin/sops" \
  "SOPS (secrets)"

# Ansible — package name and PPA requirements differ between distros
if command -v ansible &>/dev/null; then
  log "Ansible — already installed."
elif [[ "$DISTRO_FAMILY" == "debian" ]]; then
  # Ubuntu < 22.04 needs the PPA for a current version
  if [[ "$DISTRO_ID" == "ubuntu" ]] && command -v bc &>/dev/null && \
     [[ "$(echo "${DISTRO_VERSION:-0} < 22" | bc -l 2>/dev/null)" == "1" ]]; then
    log "Ubuntu < 22.04 detected — adding ansible PPA …"
    sudo add-apt-repository --yes --update ppa:ansible/ansible 2>/dev/null || true
  fi
  sudo apt-get install -y -qq ansible 2>/dev/null \
    || { warn "FAILED: ansible"; FAILED_PKGS+=("ansible"); }
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  safe_pkg_install ansible-core "Ansible"
fi

# ── AWS ────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}  AWS${RESET}"

install_awscli() {
  if command -v aws &>/dev/null; then
    log "AWS CLI — already installed ($(aws --version 2>&1 | head -1))."
    return 0
  fi
  log "Installing AWS CLI v2 via official installer …"
  local tmpdir
  tmpdir=$(mktemp -d)
  local url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  [[ "$ARCH" == "arm64" ]] && url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
  curl -fsSL "$url" -o "${tmpdir}/awscliv2.zip" \
    && unzip -q "${tmpdir}/awscliv2.zip" -d "$tmpdir" \
    && sudo "${tmpdir}/aws/install" \
    || { warn "AWS CLI install failed."; FAILED_PKGS+=("awscli"); }
  rm -rf "$tmpdir"
}
install_awscli

# aws-iam-authenticator — GitHub release binary
pbg install_github_release "kubernetes-sigs/aws-iam-authenticator" \
  "aws-iam-authenticator_[0-9].*_linux_${ARCH}$" \
  "/usr/local/bin/aws-iam-authenticator" \
  "AWS IAM Authenticator"

# eksctl — GitHub release binary (tar.gz)
pbg install_github_release "eksctl-io/eksctl" \
  "eksctl_Linux_${ARCH}\.tar\.gz" \
  "/usr/local/bin/eksctl" \
  "eksctl (EKS)"

# ── Azure ──────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}  Azure${RESET}"
safe_pkg_install azure-cli "Azure CLI"

# ── Kubernetes / OpenShift / Helm ──────────────────────────────────────────────
echo -e "\n${BOLD}  Kubernetes / OpenShift / Helm${RESET}"

safe_pkg_install kubectl "kubectl"

# Helm — try package manager first; fall back to official script
if ! safe_pkg_install helm "Helm" 2>/dev/null && ! command -v helm &>/dev/null; then
  log "Helm not in repos — using official install script …"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
    || { warn "Helm install failed."; FAILED_PKGS+=("helm"); }
fi

# kubectx + kubens — GitHub release (separate tar.gz assets)
# kubectx/kubens assets use x86_64 (not amd64) on Intel — match both spellings
pbg install_github_release "ahmetb/kubectx" \
  "kubectx_v[0-9].*_linux_(${ARCH}|${ARCH_ALT})\.tar\.gz" \
  "/usr/local/bin/kubectx" \
  "kubectx"
pbg install_github_release "ahmetb/kubectx" \
  "kubens_v[0-9].*_linux_(${ARCH}|${ARCH_ALT})\.tar\.gz" \
  "/usr/local/bin/kubens" \
  "kubens"

# k9s — GitHub release binary (tar.gz)
pbg install_github_release "derailed/k9s" \
  "k9s_Linux_${ARCH}\.tar\.gz" \
  "/usr/local/bin/k9s" \
  "K9s (TUI)"

# kustomize — GitHub release binary (tar.gz)
pbg install_github_release "kubernetes-sigs/kustomize" \
  "kustomize_v[0-9].*_linux_${ARCH}\.tar\.gz" \
  "/usr/local/bin/kustomize" \
  "Kustomize"

# stern — GitHub release binary (tar.gz)
pbg install_github_release "stern/stern" \
  "stern_[0-9].*_linux_${ARCH}\.tar\.gz" \
  "/usr/local/bin/stern" \
  "Stern (multi-pod log tailing)"

# kubeseal — GitHub release binary (tar.gz)
pbg install_github_release "bitnami-labs/sealed-secrets" \
  "kubeseal-[0-9].*-linux-${ARCH}\.tar\.gz" \
  "/usr/local/bin/kubeseal" \
  "Sealed Secrets CLI"

# OpenShift CLI (oc) — binary from mirror.openshift.com
install_oc() {
  if command -v oc &>/dev/null; then
    log "OpenShift CLI (oc) — already installed."
    return 0
  fi
  log "Installing OpenShift CLI (oc) …"
  local oc_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz"
  local tmpdir
  tmpdir=$(mktemp -d)
  curl -fsSL "$oc_url" -o "${tmpdir}/oc.tar.gz" \
    && tar -xzf "${tmpdir}/oc.tar.gz" -C "$tmpdir" \
    && sudo install -m 0755 "${tmpdir}/oc" /usr/local/bin/oc \
    || { warn "OpenShift CLI install failed."; FAILED_PKGS+=("oc"); }
  rm -rf "$tmpdir"
}
install_oc

# kubecolor — GitHub release binary (tar.gz)
pbg install_github_release "kubecolor/kubecolor" \
  "kubecolor_[0-9].*_linux_${ARCH}\.tar\.gz" \
  "/usr/local/bin/kubecolor" \
  "kubecolor (colourised kubectl)"

# ── Containers ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}  Containers${RESET}"
safe_pkg_install podman         "Podman"
safe_pkg_install docker-compose "Docker Compose"

# ── General Dev ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}  General Dev${RESET}"

safe_pkg_install git "Git"
safe_pkg_install gh  "GitHub CLI"
safe_pkg_install jq  "jq"
safe_pkg_install yq  "yq"
safe_pkg_install fzf "fzf"

# bat — binary is named 'batcat' on some Debian/Ubuntu versions; create symlink
safe_pkg_install bat "bat (better cat)"
if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
  ln -sf "$(which batcat)" "$HOME/.local/bin/bat"
  log "Created bat → batcat symlink in ~/.local/bin"
fi

# eza — available in apt on Ubuntu 23.04+; otherwise GitHub release
install_eza() {
  if command -v eza &>/dev/null; then
    log "eza — already installed."
    return 0
  fi
  if [[ "$DISTRO_FAMILY" == "debian" ]]; then
    sudo apt-get install -y -qq eza 2>/dev/null && return 0
  elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
    sudo "$PKG_MANAGER" install -y -q eza 2>/dev/null && return 0
  fi
  # eza release assets use the Rust target triple, e.g. eza_x86_64-unknown-linux-gnu.tar.gz
  install_github_release "eza-community/eza" \
    "eza_(${ARCH}|${ARCH_ALT})-unknown-linux-gnu\.tar\.gz" \
    "/usr/local/bin/eza" \
    "eza (modern ls)"
}
install_eza

# zoxide — try package manager first; fall back to GitHub release
install_zoxide() {
  if command -v zoxide &>/dev/null; then
    log "zoxide — already installed."
    return 0
  fi
  safe_pkg_install zoxide "zoxide (smart cd)"
  command -v zoxide &>/dev/null && return 0
  # Match the arch dynamically (was hardcoded x86_64, which failed on arm64)
  install_github_release "ajeetdsouza/zoxide" \
    "zoxide-[0-9].*-(${ARCH}|${ARCH_ALT})-unknown-linux-musl\.tar\.gz" \
    "/usr/local/bin/zoxide" \
    "zoxide (smart cd)"
}
install_zoxide

safe_pkg_install ripgrep "ripgrep (rg)"

# fd — binary is named 'fdfind' on Debian/Ubuntu; create symlink
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  safe_pkg_install fd-find "fd (better find)"
  if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
    ln -sf "$(which fdfind)" "$HOME/.local/bin/fd"
    log "Created fd → fdfind symlink in ~/.local/bin"
  fi
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  safe_pkg_install fd-find "fd (better find)"
fi

safe_pkg_install tldr   "tldr"
safe_pkg_install direnv "direnv"

# ── Network & SysAdmin diagnostics ────────────────────────────────────────────
echo -e "\n${BOLD}  Network & SysAdmin diagnostics${RESET}"

# netcat — package name differs
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  safe_pkg_install netcat-openbsd "netcat (nc)"
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  safe_pkg_install nmap-ncat "netcat (nc)"
fi

# dig/nslookup/host — package name differs
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  safe_pkg_install dnsutils "BIND tools (dig/nslookup/host)"
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  safe_pkg_install bind-utils "BIND tools (dig/nslookup/host)"
fi

safe_pkg_install nmap    "Nmap"
safe_pkg_install mtr     "mtr (traceroute + ping)"
safe_pkg_install tcpdump "tcpdump"

# tshark (Wireshark CLI) — package name differs
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  DEBIAN_FRONTEND=noninteractive safe_pkg_install tshark "Wireshark (tshark)"
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  safe_pkg_install wireshark-cli "Wireshark (tshark)"
fi

safe_pkg_install httpie  "HTTPie"
safe_pkg_install curl    "curl"
safe_pkg_install wget    "wget"
safe_pkg_install socat   "socat"
safe_pkg_install iperf3  "iperf3 (bandwidth testing)"
safe_pkg_install nload   "nload (bandwidth monitor)"
safe_pkg_install lsof    "lsof"
safe_pkg_install watch   "watch"
safe_pkg_install rsync   "rsync"

if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  safe_pkg_install openssh-client "OpenSSH"
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  safe_pkg_install openssh-clients "OpenSSH"
fi

safe_pkg_install tmux    "tmux"
safe_pkg_install htop    "htop"

# bottom (btm) — GitHub release (not widely packaged).
# Assets use the Rust target triple, e.g. bottom_x86_64-unknown-linux-gnu.tar.gz
pbg install_github_release "ClementTsang/bottom" \
  "bottom_(${ARCH}|${ARCH_ALT})-unknown-linux-gnu\.tar\.gz" \
  "/usr/local/bin/btm" \
  "bottom (btm — system monitor)"

# speedtest-cli
if ! safe_pkg_install speedtest-cli "Speedtest CLI" 2>/dev/null && ! command -v speedtest-cli &>/dev/null; then
  # pip is the fallback when the distro doesn't package it. Modern distros mark
  # the system Python as externally managed (PEP 668), so a bare
  # `pip install --user` fails — prefer pipx, then retry pip with
  # --break-system-packages.
  if command -v pipx &>/dev/null; then
    pipx install speedtest-cli 2>/dev/null \
      || { warn "speedtest-cli not available."; FAILED_PKGS+=("speedtest-cli"); }
  elif command -v python3 &>/dev/null; then
    python3 -m pip install --user speedtest-cli 2>/dev/null \
      || python3 -m pip install --user --break-system-packages speedtest-cli 2>/dev/null \
      || { warn "speedtest-cli not available (try: pipx install speedtest-cli)."; FAILED_PKGS+=("speedtest-cli"); }
  else
    warn "speedtest-cli not available (no pipx/python3)."; FAILED_PKGS+=("speedtest-cli")
  fi
fi

safe_pkg_install httping "httping (TCP/IP packet tester)"
safe_pkg_install whois   "whois"
safe_pkg_install ipcalc  "ipcalc (IP subnet calculator)"
safe_pkg_install iftop   "iftop (bandwidth monitor)"

# ── VSCode ─────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}  VSCode${RESET}"

install_vscode() {
  if command -v code &>/dev/null; then
    log "VSCode 'code' CLI already available ($(code --version 2>/dev/null | head -1))."
    return 0
  fi

  if [[ "$DISTRO_FAMILY" == "debian" ]]; then
    add_apt_repo "vscode" \
      "https://packages.microsoft.com/keys/microsoft.asc" \
      "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/vscode-archive-keyring.gpg] https://packages.microsoft.com/repos/code stable main"
    sudo apt-get install -y -qq code 2>/dev/null \
      || { warn "apt install of code failed; trying snap …"
           snap install code --classic 2>/dev/null \
             || { warn "snap install of code failed."; FAILED_PKGS+=("vscode"); }; }
  elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
    if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
      sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
      cat <<'EOF' | sudo tee /etc/yum.repos.d/vscode.repo > /dev/null
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    fi
    sudo "$PKG_MANAGER" install -y -q code \
      || { warn "dnf/yum install of code failed."; FAILED_PKGS+=("vscode"); }
  else
    warn "Cannot install VSCode on unsupported distro — try: snap install code --classic"
    FAILED_PKGS+=("vscode")
  fi
}
install_vscode

# Barrier: wait for all parallel GitHub-release downloads to finish and fold
# their failures back into FAILED_PKGS before we report/summarise.
log "Waiting for parallel release-binary installs to finish …"
wait_downloads

# ==============================================================================
# 9. Generate ~/.zshenv and ~/.zshrc
# ==============================================================================
header "8 / 8  Writing ~/.zshenv and ~/.zshrc"

# --- ~/.zshenv : PATH lives here so it applies to ALL shells (login,
#     interactive, and scripts) and is de-duplicated via `typeset -U`.
ZSHENV="${HOME}/.zshenv"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [[ -f "$ZSHENV" ]]; then
  cp "$ZSHENV" "${ZSHENV}.backup.${TIMESTAMP}"
  log "Backed up existing .zshenv → ${ZSHENV}.backup.${TIMESTAMP}"
fi
cat > "$ZSHENV" << 'ZSHENV_EOF'
# ==============================================================================
# ~/.zshenv — environment for all zsh shells  (generated by setup-zsh-devops-linux.sh)
# ==============================================================================
# `typeset -U path` keeps the array unique, so re-sourcing never duplicates
# entries; the leading assignment guarantees our dirs take precedence.
typeset -U path PATH
path=("$HOME/.local/bin" "$HOME/bin" "/usr/local/bin" $path)
export PATH
ZSHENV_EOF
log ".zshenv written."

ZSHRC="${HOME}/.zshrc"
BACKUP="${HOME}/.zshrc.backup.${TIMESTAMP}"

if [[ -f "$ZSHRC" ]]; then
  cp "$ZSHRC" "$BACKUP"
  log "Backed up existing .zshrc → $BACKUP"
fi

cat > "$ZSHRC" << 'ZSHRC_EOF'
# ==============================================================================
# ~/.zshrc — Modern DevOps / Cloud Admin Shell Environment  (Linux)
# Generated by setup-zsh-devops-linux.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# oh-my-zsh
# ------------------------------------------------------------------------------
export ZSH="$HOME/.oh-my-zsh"

# Theme — left empty on purpose: oh-my-posh renders the prompt (the bubblesextra
# theme, configured further down). oh-my-zsh is kept for its plugins and
# completions. Set this to an OMZ theme name (e.g. "agnoster") only if you want
# oh-my-zsh's own prompt instead of oh-my-posh.
ZSH_THEME=""

# Plugins. The last three MUST stay in this order: fast-syntax-highlighting and
# zsh-autosuggestions load first, then zsh-autocomplete (which requires being
# loaded after them).
plugins=(
  # --- Version control ---
  git

  # --- Cloud / DevOps ---
  # NOTE: kubectl plugin omitted — its aliases conflict with our kpf()/etc.
  # functions; its completion is handled by the cached list further down.
  aws
  helm
  terraform
  ansible
  docker
  docker-compose

  # --- IDE ---
  vscode

  # --- Shell UX ---
  sudo
  colored-man-pages
  command-not-found
  copypath
  dirhistory
  history
  jsontools
  urltools

  # --- Completion / suggestions / highlighting (keep this order) ---
  fast-syntax-highlighting
  zsh-autosuggestions
  zsh-autocomplete
)

# zsh-autocomplete's async worker leaks a file descriptor on every keystroke
# (upstream bug marlonrichert/zsh-autocomplete#294 / #156). After ~256 of them a
# shell hits its open-file limit and starts erroring with
#   .autocomplete:async:wait:sysopen: can't open file /dev/fd/255
# after which input is corrupted until you restart. Running completion
# synchronously sidesteps the leaking machinery entirely. Must be set BEFORE the
# plugin loads (below), since async wiring happens at load time.
zstyle ':autocomplete:*' async off

source "$ZSH/oh-my-zsh.sh"

# ------------------------------------------------------------------------------
# Arrow keys — restore up/down to plain history cycling
# ------------------------------------------------------------------------------
# zsh-autocomplete rebinds Up/Down to an incremental history search. Restore the
# familiar one-command-at-a-time cycling through previous commands.
bindkey "$terminfo[kcuu1]" up-line-or-history    # Up arrow → previous command
bindkey "$terminfo[kcud1]" down-line-or-history  # Down arrow → next command

# ------------------------------------------------------------------------------
# Tab — cycle through completion matches
# ------------------------------------------------------------------------------
# By default zsh-autocomplete binds Tab to insert the longest common match and
# stop there. Rebind it (after the plugin has loaded, like the arrow keys above)
# so Tab opens the completion menu and repeated Tab / Shift-Tab cycle forward /
# backward through the matches. `menuselect` is the keymap active in the menu.
bindkey              '^I' menu-select          # Tab       → open menu / next match
bindkey "$terminfo[kcbt]" menu-select          # Shift-Tab → open menu / prev match
bindkey -M menuselect '^I'               menu-complete          # Tab in menu → next
bindkey -M menuselect "$terminfo[kcbt]"  reverse-menu-complete  # Shift-Tab   → prev

# ------------------------------------------------------------------------------
# oh-my-posh — prompt (bubblesextra theme)
# ------------------------------------------------------------------------------
# oh-my-posh owns the prompt (oh-my-zsh's own theme is disabled via ZSH_THEME=""
# above). No network at prompt-init: the theme is located on disk, falling back
# to oh-my-posh's default prompt if the bubblesextra config isn't found.
if command -v oh-my-posh &>/dev/null; then
  _omp_theme=""
  for _d in "$POSH_THEMES_PATH" "${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-posh/themes"; do
    if [[ -n "$_d" && -f "$_d/bubblesextra.omp.json" ]]; then
      _omp_theme="$_d/bubblesextra.omp.json"
      break
    fi
  done
  if [[ -n "$_omp_theme" ]]; then
    eval "$(oh-my-posh init zsh --config "$_omp_theme")"
  else
    eval "$(oh-my-posh init zsh)"
  fi
  unset _omp_theme _d
fi

# ------------------------------------------------------------------------------
# PATH — defined in ~/.zshenv (generated by the installer) so it applies to
# non-interactive shells too and is de-duplicated instead of being re-prepended
# every time this file is re-sourced.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Tool completions — cached  (★ add your own tools to the list below ★)
# ------------------------------------------------------------------------------
# Add one entry per tool as  "name|command that prints its zsh completion".
# Running `tool completion zsh` forks the binary on every shell startup
# (100–400ms each), so instead the generated script is cached under
# ~/.cache/zsh/completions and only regenerated when the tool's binary is newer
# than the cache (e.g. after an upgrade). To add a tool, append a line here —
# nothing else to change.
zsh_completion_tools=(
  "kubectl|kubectl completion zsh"
  "helm|helm completion zsh"
  "oc|oc completion zsh"
  "eksctl|eksctl completion zsh"
  "gh|gh completion -s zsh"
)

_zsh_comp_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions"
mkdir -p "$_zsh_comp_cache"
for _entry in "${zsh_completion_tools[@]}"; do
  _name="${_entry%%|*}"                 # cache name (text before the first '|')
  _cmd="${_entry#*|}"                   # generator command (text after it)
  # Only accept a plain filename as the cache name, so a stray '/' or '..' in an
  # edited entry can never write the cache file outside its directory.
  if [[ -z "$_name" || "$_name" == */* || "$_name" == ".." ]]; then
    print -u2 "zshrc: skipping completion entry with invalid name: '$_name'"
    continue
  fi
  # Split the generator into an argv array (respecting quotes) and run it
  # directly — no eval, so nothing in the entry is re-interpreted as shell.
  _argv=( ${(z)_cmd} )
  (( $#_argv )) || continue
  _binpath=$(command -v "${_argv[1]}" 2>/dev/null) || continue   # tool present?
  _out="$_zsh_comp_cache/$_name.zsh"
  if [[ ! -s "$_out" || "$_binpath" -nt "$_out" ]]; then
    # Generate to a temp file and only replace the cache on success, so a failed
    # run (or a race between two starting shells) never clobbers a good cache.
    if "${_argv[@]}" > "$_out.tmp.$$" 2>/dev/null && [[ -s "$_out.tmp.$$" ]]; then
      mv -f "$_out.tmp.$$" "$_out"
    else
      rm -f "$_out.tmp.$$"
    fi
  fi
  [[ -s "$_out" ]] && source "$_out"
done
unset _entry _name _cmd _argv _binpath _out _zsh_comp_cache

# kubecolor: inherit kubectl completions via compdef
command -v kubecolor &>/dev/null && compdef kubecolor=kubectl
# AWS
command -v aws_completer &>/dev/null && complete -C "$(command -v aws_completer)" aws
# Terraform (built-in)
command -v terraform  &>/dev/null && complete -o nospace -C "$(command -v terraform)" terraform
# direnv hook
command -v direnv     &>/dev/null && eval "$(direnv hook zsh)"

# ------------------------------------------------------------------------------
# zoxide — smart cd replacement  (replaces 'cd')
# ------------------------------------------------------------------------------
command -v zoxide &>/dev/null && eval "$(zoxide init zsh --cmd cd)"

# ------------------------------------------------------------------------------
# fzf
# ------------------------------------------------------------------------------
_fzf_shell_dir=""
if [[ -d "/usr/share/fzf" ]]; then
  _fzf_shell_dir="/usr/share/fzf"                         # apt install fzf
elif [[ -d "$HOME/.fzf/shell" ]]; then
  _fzf_shell_dir="$HOME/.fzf/shell"                       # git clone install
elif [[ -d "/usr/share/doc/fzf/examples" ]]; then
  _fzf_shell_dir="/usr/share/doc/fzf/examples"            # some RHEL variants
fi
if [[ -n "$_fzf_shell_dir" ]]; then
  [[ -f "$_fzf_shell_dir/key-bindings.zsh" ]] && source "$_fzf_shell_dir/key-bindings.zsh"
  [[ -f "$_fzf_shell_dir/completion.zsh"   ]] && source "$_fzf_shell_dir/completion.zsh"
fi
unset _fzf_shell_dir

export FZF_DEFAULT_OPTS="--height 50% --layout=reverse --border rounded \
  --info=inline --prompt='❯ ' --pointer='▶' --marker='✓' \
  --color=fg:#c0caf5,bg:#1a1b26,hl:#ff9e64 \
  --color=fg+:#c0caf5,bg+:#292e42,hl+:#ff9e64 \
  --color=border:#29a4bd,header:#ff9e64,gutter:#1a1b26 \
  --color=spinner:#73daca,info:#73daca,separator:#29a4bd \
  --color=pointer:#bd93f9,marker:#e06c75,prompt:#7aa2f7"
export FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type d --hidden --follow --exclude .git"

# ------------------------------------------------------------------------------
# zsh-autosuggestions
# ------------------------------------------------------------------------------
# 'history' only: the 'completion' strategy invokes the completion engine on
# every keystroke to build a suggestion, which is noticeably heavy layered on
# zsh-autocomplete + syntax-highlighting. History-based suggestions are far
# cheaper and cover the vast majority of cases. Add 'completion' back if you
# specifically want suggestions for never-run commands.
ZSH_AUTOSUGGEST_STRATEGY=(history)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=244"
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=50
ZSH_AUTOSUGGEST_USE_ASYNC=1

# ------------------------------------------------------------------------------
# fast-syntax-highlighting
# ------------------------------------------------------------------------------
# Works out of the box — no configuration required. To change its colour theme
# interactively, run:  fast-theme <theme>   (list options with: fast-theme -l)

# ------------------------------------------------------------------------------
# Editor / Pager
# ------------------------------------------------------------------------------
if command -v code &>/dev/null; then
  export EDITOR="code --wait"
else
  export EDITOR="vim"
fi
export VISUAL="$EDITOR"
export PAGER="less"
# bat as man pager (requires bat)
command -v bat &>/dev/null && export MANPAGER="sh -c 'col -bx | bat -l man -p'"

# ------------------------------------------------------------------------------
# Locale
# ------------------------------------------------------------------------------
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# ------------------------------------------------------------------------------
# History
# ------------------------------------------------------------------------------
HISTSIZE=100000
SAVEHIST=100000
HISTFILE="$HOME/.zsh_history"
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt SHARE_HISTORY
setopt EXTENDED_HISTORY       # store timestamps

# ------------------------------------------------------------------------------
# ZSH options
# ------------------------------------------------------------------------------
setopt AUTO_CD                # type dir name to cd
setopt AUTO_PUSHD             # push dirs onto stack automatically
setopt PUSHD_IGNORE_DUPS
# CORRECT is intentionally left OFF: with this many aliases/functions it fires
# constant "correct 'foo' to 'bar'? [nyae]" prompts that interrupt the flow.
# Uncomment if you want interactive spell-correction of command names.
# setopt CORRECT
setopt NO_BEEP
setopt GLOB_DOTS              # include dotfiles in globs
setopt EXTENDED_GLOB
setopt INTERACTIVE_COMMENTS   # allow # comments in interactive shell

# ------------------------------------------------------------------------------
# Aliases — navigation & general
# ------------------------------------------------------------------------------
alias ls='eza --icons --group-directories-first'
alias ll='eza -lah --icons --group-directories-first --git'
alias la='eza -a --icons'
alias lt='eza --tree --icons -L 3'
# 'cat'/'less' are intentionally NOT shadowed by bat: overriding core commands
# surprises muscle memory, and because zsh expands aliases when a function is
# *parsed*, an alias here would silently leak into helpers like json()/yaml()
# defined later in this file. Use bat directly, or these explicit aliases:
alias batp='bat --style=plain --paging=never'   # plain, no pager (cat-like)
alias batf='bat --style=full'                    # full view, paged (less-like)
alias grep='grep --color=auto'
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -iv'
alias mkdir='mkdir -pv'
alias df='df -hT'
alias du='du -h'          # human-readable; use 'du -sch ./*' explicitly for a per-entry summary
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias reload='exec zsh'   # replace the shell with a fresh zsh (re-reads config)
alias zshrc='${EDITOR:-vim} ~/.zshrc'
alias path='echo $PATH | tr ":" "\n" | nl'
alias now='date +"%Y-%m-%d %H:%M:%S %Z"'
alias timestamp='date +%Y%m%d_%H%M%S'

# ------------------------------------------------------------------------------
# Aliases — network & diagnostics
# ------------------------------------------------------------------------------
alias ping='ping -c 5'
alias myip='curl -fsSL https://ifconfig.me && echo'
alias localip="ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127"
alias flushdns='sudo resolvectl flush-caches 2>/dev/null \
  || sudo systemd-resolve --flush-caches 2>/dev/null \
  || sudo service nscd restart 2>/dev/null \
  && echo "DNS cache flushed."'
alias tracert='mtr --report-wide'
alias ports='sudo lsof -iTCP -sTCP:LISTEN -n -P'
alias openports='sudo nmap -sT -O localhost'
alias listening='sudo lsof -i -P -n | grep LISTEN'
alias bandwidth='sudo iftop 2>/dev/null || sudo nload'
alias ipinfo='curl -fsSL ipinfo.io | jq'

# Quick TCP port check: tcpcheck <host> <port>
tcpcheck() {
  local host="$1" port="$2"
  nc -zv -w 3 "$host" "$port" 2>&1 && echo -e "\n\033[0;32mPORT OPEN\033[0m" || echo -e "\n\033[0;31mPORT CLOSED / FILTERED\033[0m"
}

# DNS lookup: lookup <hostname> [record-type]
lookup() { dig +noall +answer "$1" "${2:-A}"; }

# Reverse DNS lookup
rdns() { dig +noall +answer -x "$1"; }

# SSL certificate info: sslcheck <host> [port]
sslcheck() {
  echo | openssl s_client -connect "${1}:${2:-443}" -servername "$1" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -fingerprint
}

# HTTP headers
headers() { curl -fsIL "$1"; }

# HTTP request with verbose output
hreq() { http --pretty=all "$@"; }       # requires httpie

# Quick Nmap scans
portscan()      { nmap -sV --open "$@"; }
portscan-full() { nmap -sV -p- --open "$@"; }
portscan-udp()  { sudo nmap -sU --open "$@"; }

# Whois + geolocation
ipwhois()  { whois "$1"; }
ipreport() { curl -fsSL "https://ipinfo.io/${1}" | jq; }

# Watch a command every 2 s
ww() { watch -n 2 "$@"; }

# Traceroute with hostnames
tracepath() { mtr --report-wide --show-ips --aslookup "$@"; }

# ------------------------------------------------------------------------------
# Aliases — Terraform / Terragrunt
# ------------------------------------------------------------------------------
alias tf='terraform'
alias tfi='terraform init'
alias tfiu='terraform init -upgrade'
alias tfp='terraform plan'
alias tfa='terraform apply'
alias tfaa='terraform apply -auto-approve'
alias tfd='terraform destroy'
alias tfdaa='terraform destroy -auto-approve'
alias tfo='terraform output -json | jq'
alias tfw='terraform workspace'
alias tfwl='terraform workspace list'
alias tfws='terraform workspace select'
alias tff='terraform fmt -recursive'
alias tfv='terraform validate'
alias tfs='terraform state'
alias tfsl='terraform state list'
alias tfss='terraform state show'
alias tfi-lock='terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64'

alias tg='terragrunt'
alias tgp='terragrunt plan'
alias tga='terragrunt apply'
alias tgaa='terragrunt apply --auto-approve'
alias tgd='terragrunt destroy'
alias tgra='terragrunt run-all apply'
alias tgraa='terragrunt run-all apply --auto-approve'
alias tgrp='terragrunt run-all plan'
alias tgrd='terragrunt run-all destroy'
alias tgv='terragrunt validate'
alias tgf='terragrunt hclfmt'

# ------------------------------------------------------------------------------
# Aliases — AWS
# ------------------------------------------------------------------------------
alias awswho='aws sts get-caller-identity | jq'
alias awsprofiles='aws configure list-profiles'
alias awsregions='aws ec2 describe-regions --query "Regions[].RegionName" --output text | tr "\t" "\n" | sort'
alias awsinstances='aws ec2 describe-instances \
  --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0],InstanceType,PrivateIpAddress,PublicIpAddress]" \
  --output table'
alias awslogs='aws logs describe-log-groups --query "logGroups[].logGroupName" --output text | tr "\t" "\n" | sort'
alias awss3ls='aws s3 ls'
alias awsecr='aws ecr describe-repositories --output table'

# Switch AWS profile interactively (requires fzf)
awsprofile() {
  local profile
  profile=$(aws configure list-profiles | fzf --prompt="Select AWS profile: " --height=40% --border)
  [[ -n "$profile" ]] && export AWS_PROFILE="$profile" && echo "AWS_PROFILE=$profile"
}

# Switch AWS region interactively (requires fzf)
awsregion() {
  local region
  region=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text \
    | tr "\t" "\n" | sort | fzf --prompt="Select AWS region: " --height=40% --border)
  [[ -n "$region" ]] && export AWS_DEFAULT_REGION="$region" && echo "AWS_DEFAULT_REGION=$region"
}

# EKS kubeconfig update: eksconfig <cluster-name> [region]
eksconfig() { aws eks update-kubeconfig --name "$1" --region "${2:-${AWS_DEFAULT_REGION:-us-east-1}}"; }

# ------------------------------------------------------------------------------
# Aliases — Azure
# ------------------------------------------------------------------------------
alias azwho='az account show | jq "{name:.name, id:.id, user:.user.name}"'
alias azlist='az account list --output table'
alias azswitch='az account set --subscription'
alias azlogin='az login'
alias azrg='az group list --output table'
alias azvm='az vm list --output table'
alias azaks='az aks list --output table'

# Switch Azure subscription interactively (requires fzf)
azprofile() {
  local sub
  sub=$(az account list --query "[].{name:name,id:id}" -o tsv \
    | fzf --prompt="Select Azure subscription: " --height=40% --border | awk '{print $1}')
  [[ -n "$sub" ]] && az account set --subscription "$sub" && azwho
}

# AKS kubeconfig: aksconfig <resource-group> <cluster-name>
aksconfig() { az aks get-credentials --resource-group "$1" --name "$2" --overwrite-existing; }

# ------------------------------------------------------------------------------
# Aliases — Kubernetes
# ------------------------------------------------------------------------------
# k → kubecolor (colourised) if installed, else plain kubectl.
# Do NOT alias 'kubectl' itself: kubectl completion zsh defines a kubectl()
# function, and zsh cannot have a function and an alias with the same name.
command -v kubecolor &>/dev/null && alias k='kubecolor' || alias k='kubectl'
alias kga='kubectl get all -A'
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A -o wide'
alias kgn='kubectl get nodes -o wide'
alias kgs='kubectl get svc -A'
alias kgi='kubectl get ingress -A'
alias kgd='kubectl get deployments -A'
alias kgcm='kubectl get configmap -A'
alias kgsec='kubectl get secrets -A'
alias kgpv='kubectl get pv,pvc -A'
alias kd='kubectl describe'
alias kdp='kubectl describe pod'
alias kdn='kubectl describe node'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias klt='kubectl logs --tail=100'
alias ke='kubectl exec -it'
alias kaf='kubectl apply -f'
alias kdf='kubectl delete -f'
alias kdel='kubectl delete'
alias kctxl='kubectl config get-contexts'
alias kns='kubens'
alias kctx='kubectx'
alias k9='k9s'

# Switch context with fzf
kswitch() {
  local ctx
  ctx=$(kubectl config get-contexts -o name | fzf --prompt="Select kube context: " --height=40% --border)
  [[ -n "$ctx" ]] && kubectl config use-context "$ctx"
}

# Port-forward: kpf <resource> [local:remote]
kpf() { kubectl port-forward "$1" "${2:-8080:8080}"; }

# Watch pods: kwatch [namespace]
kwatch() { watch -n 2 kubectl get pods "${1:+-n $1}"; }

# Decode all keys of a k8s Secret
ksecret() {
  kubectl get secret "$1" ${2:+-n $2} -o json \
    | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
}

# Tail all pods matching a label: ktail app=myapp [namespace]
ktail() { stern "${1}" ${2:+-n $2} --tail 50; }

# Run a temporary debug pod
kdebug() {
  kubectl run debug-$(date +%s) --image=nicolaka/netshoot -it --rm --restart=Never -- bash
}

# Force-delete a stuck pod
kforce() { kubectl delete pod "$1" ${2:+-n $2} --grace-period=0 --force; }

# ------------------------------------------------------------------------------
# Aliases — OpenShift
# ------------------------------------------------------------------------------
alias ocp='oc'
alias ocwho='oc whoami'
alias ocproject='oc project'
alias ocprojects='oc projects'
alias ocget='oc get all'
alias oclogs='oc logs -f'
alias oclogin='oc login'

# ------------------------------------------------------------------------------
# Aliases — Helm
# ------------------------------------------------------------------------------
alias h='helm'
alias hl='helm list -A'
alias hr='helm repo'
alias hrl='helm repo list'
alias hru='helm repo update'
alias hrs='helm repo search'
alias hi='helm install'
alias hup='helm upgrade --install'
alias hun='helm uninstall'
alias hst='helm status'
alias hh='helm history'
alias hd='helm diff'         # requires helm-diff plugin
alias hvals='helm show values'
alias htemplate='helm template'

# Helm upgrade with diff preview: hudiff <release> <chart> [args]
hudiff() { helm diff upgrade "$1" "$2" "${@:3}"; }

# ------------------------------------------------------------------------------
# Aliases — Docker / Podman / Compose
# ------------------------------------------------------------------------------
alias d='docker'
alias dps='docker ps -a'
alias dim='docker images'
alias dex='docker exec -it'
alias dlogs='docker logs -f'
alias dstop='docker stop'
alias drm='docker rm'
alias drmi='docker rmi'
alias dprune='docker system prune -af --volumes'
alias dc='docker-compose'
alias dcu='docker-compose up -d'
alias dcd='docker-compose down'
alias dcl='docker-compose logs -f'

# ------------------------------------------------------------------------------
# Aliases — Git
# ------------------------------------------------------------------------------
alias gs='git status'
alias ga='git add'
alias gaa='git add -A'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit --amend --no-edit'
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gpl='git pull'
alias gplr='git pull --rebase'
alias gco='git checkout'
alias gcob='git checkout -b'
alias gb='git branch'
alias gba='git branch -a'
alias gbd='git branch -d'
alias glog='git log --oneline --graph --decorate --all'
alias gd='git diff'
alias gds='git diff --staged'
alias gst='git stash'
alias gstp='git stash pop'
alias gstl='git stash list'
alias gclean='git clean -fdx'
alias gtag='git tag --sort=-version:refname'

# Interactive git log with fzf
gshow() {
  git log --oneline --all \
    | fzf --ansi --preview 'git show --color=always {1}' \
    | awk '{print $1}' \
    | xargs -r git show
}

# ------------------------------------------------------------------------------
# Useful functions
# ------------------------------------------------------------------------------

# mkcd — mkdir + cd
mkcd() { mkdir -p "$1" && cd "$1"; }

# extract — unpack any archive
extract() {
  if [[ ! -f "$1" ]]; then echo "File '$1' not found."; return 1; fi
  case "$1" in
    *.tar.bz2|*.tbz2) tar xvjf "$1" ;;
    *.tar.gz|*.tgz)   tar xvzf "$1" ;;
    *.tar.xz)         tar xvJf "$1" ;;
    *.tar.zst)        tar --use-compress-program=unzstd -xvf "$1" ;;
    *.tar)            tar xvf  "$1" ;;
    *.bz2)            bunzip2  "$1" ;;
    *.gz)             gunzip   "$1" ;;
    *.zip)            unzip    "$1" ;;
    *.7z)             7z x     "$1" ;;
    *.rar)            unrar x  "$1" ;;
    *) echo "Don't know how to extract '$1'" ;;
  esac
}

# b64enc / b64dec
b64enc() { echo -n "$1" | base64; }
b64dec() { echo -n "$1" | base64 --decode && echo; }

# json / yaml pretty-print
json() { cat "${1:--}" | jq '.'; }
yaml() { cat "${1:--}" | yq '.'; }

# genpass — random password
genpass() { LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+~' </dev/urandom | head -c "${1:-32}"; echo; }

# serve — quick HTTP server in current directory
serve() { python3 -m http.server "${1:-8000}"; }

# has — check if command exists
has() { command -v "$1" &>/dev/null && echo "✓ $1 found: $(command -v $1)" || echo "✗ $1 not found"; }

# whatsmyip — public + private IP
whatsmyip() {
  echo "Public:  $(curl -fsSL https://ifconfig.me)"
  echo "Private: $(ip -4 a show | grep -oP '(?<=inet )[0-9.]+' | grep -v 127 | head -1)"
}

# loop — run a command N times: loop 5 ping -c1 8.8.8.8
# (cannot use 'repeat' — it is a zsh reserved keyword)
loop() {
  local n="$1"; shift
  for (( i=1; i<=n; i++ )); do "$@"; done
}

# CIDR subnet info (requires ipcalc)
cidr() { ipcalc "$1"; }

# Check all nodes and their readiness
knodes() { kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status,VERSION:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage'; }

# Tail pod logs across namespaces by keyword
tlogs() { stern "$1" -A --tail 50; }

# Base64-encode a file for use in k8s secrets
k8senc() { base64 < "$1" | tr -d '\n'; echo; }

# Watch kubectl top
ktop() { watch -n 3 kubectl top nodes; }
ZSHRC_EOF

log ".zshrc written."

# ==============================================================================
# Final summary
# ==============================================================================
header "Setup complete!"

echo ""
echo -e "${BOLD}Theme used:${RESET}             bubblesextra (oh-my-posh)"
echo -e "${BOLD}Font required:${RESET}          JetBrainsMono Nerd Font Mono"
echo ""
echo -e "${BOLD}${CYAN}Next steps:${RESET}"
echo -e "  1. ${YELLOW}Set your terminal font${RESET} to ${CYAN}JetBrainsMono Nerd Font Mono${RESET}."
echo -e "     • GNOME Terminal:  Preferences → Profile → Custom font"
echo -e "     • Alacritty:       font.family = JetBrainsMono Nerd Font Mono"
echo -e "     • Kitty:           font_family JetBrainsMono Nerd Font Mono"
echo -e "     • Konsole:         Settings → Edit Current Profile → Appearance → Font"
echo -e "     • VSCode:          \"terminal.integrated.fontFamily\": \"JetBrainsMono Nerd Font Mono\""
echo ""
echo -e "  2. ${YELLOW}Restart your terminal${RESET} (or open a new tab), then run:"
echo -e "     ${CYAN}source ~/.zshrc${RESET}"
echo ""
echo -e "  3. ${YELLOW}Configure credentials:${RESET}"
echo -e "     • AWS:       ${CYAN}aws configure${RESET}  (or set \$AWS_PROFILE)"
echo -e "     • Azure:     ${CYAN}az login${RESET}"
echo -e "     • K8s/EKS:   copy kubeconfig to ${CYAN}~/.kube/config${RESET}"
echo -e "     • OpenShift: ${CYAN}oc login https://<api-url>${RESET}"
echo -e "     • Linux DNS: ${CYAN}sudo resolvectl flush-caches${RESET}   (systemd-resolved)"
echo ""
echo -e "  4. ${YELLOW}Helm diff plugin${RESET} (optional, enables 'hd' alias):"
echo -e "     ${CYAN}helm plugin install https://github.com/databus23/helm-diff${RESET}"
echo ""

if [[ ${#FAILED_PKGS[@]} -gt 0 ]]; then
  warn "The following packages failed to install — review manually:"
  for pkg in "${FAILED_PKGS[@]}"; do
    echo -e "    ${RED}•${RESET} $pkg"
  done
fi

echo -e "${GREEN}Done.${RESET}"
