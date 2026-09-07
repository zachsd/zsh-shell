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


# ------------------------------------------------------------------------------
# GitHub release binary installer
# Downloads the latest release asset matching asset_re and installs to install_path.
# Supports tar.gz, tar.xz, zip, and bare binaries.
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
    | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' \
    | grep -E "$asset_re" \
    | head -1)

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
    *.tar.gz|*.tgz|*.tar.xz)
      tar -xf "${tmpdir}/${filename}" -C "$tmpdir" || {
        warn "Could not unpack $filename."
        record_failure "$desc"; rm -rf "$tmpdir"; return 1
      }
      local found
      found=$(find "$tmpdir" -type f -name "$binary_name" | head -1)
      [[ -z "$found" ]] && found=$(find "$tmpdir" -maxdepth 3 -type f -executable ! -name "*.tar.gz" ! -name "*.tar.xz" | head -1)
      if [[ -n "$found" ]]; then
        sudo install -m 0755 "$found" "$install_path" || {
          record_failure "$desc"; rm -rf "$tmpdir"; return 1
        }
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
        sudo install -m 0755 "$found" "$install_path" || {
          record_failure "$desc"; rm -rf "$tmpdir"; return 1
        }
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

header "4 / 8  Nushell, Starship & Carapace"
safe_pkg_install neovim "Neovim (default editor)"
case "$ARCH" in
  amd64|arm64) NU_TARGET="${ARCH_ALT}-unknown-linux-musl" ;;
  *) error "Nushell setup supports Linux x86_64 and aarch64 release binaries." ;;
esac
command -v nu &>/dev/null || install_github_release "nushell/nushell" \
  "nu-[0-9].*-${NU_TARGET}\.tar\.gz$" "/usr/local/bin/nu" "Nushell"
command -v starship &>/dev/null || install_github_release "starship/starship" \
  "starship-${NU_TARGET}\.tar\.gz$" "/usr/local/bin/starship" "Starship"
command -v carapace &>/dev/null || install_github_release "carapace-sh/carapace-bin" \
  "carapace-bin_[0-9].*_linux_${ARCH}\.tar\.gz$" "/usr/local/bin/carapace" "Carapace"

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

# ── Agent tools & worktrees ────────────────────────────────────────────────────
echo -e "\n${BOLD}  Agent tools & worktrees${RESET}"
if command -v herdr &>/dev/null || [[ -x "$HOME/.local/bin/herdr" ]]; then
  log "Herdr — already installed."
else
  # Download completely before execution; upstream verifies the binary checksum.
  herdr_installer=$(mktemp)
  if [[ -n "$herdr_installer" ]] && curl -fsSL https://herdr.dev/install.sh -o "$herdr_installer" \
     && sh "$herdr_installer"; then
    log "Herdr installed."
  else
    warn "FAILED: Herdr"; FAILED_PKGS+=("herdr")
  fi
  [[ -n "$herdr_installer" ]] && rm -f "$herdr_installer"
fi
if command -v wt &>/dev/null; then
  log "Worktrunk — already installed."
elif [[ "$ARCH" == amd64 || "$ARCH" == arm64 ]]; then
  if ! command -v xz &>/dev/null; then
    case "$DISTRO_FAMILY" in
      debian) safe_pkg_install xz-utils "xz (Worktrunk archives)" ;;
      rhel) safe_pkg_install xz "xz (Worktrunk archives)" ;;
    esac
  fi
  pbg install_github_release "max-sixty/worktrunk" \
    "worktrunk-${ARCH_ALT}-unknown-linux-musl\.tar\.xz$" \
    "/usr/local/bin/wt" "Worktrunk"
else
  warn "Worktrunk release binaries support x86_64/aarch64; skipping $ARCH."
  FAILED_PKGS+=("worktrunk")
fi
if ! command -v node &>/dev/null; then
  safe_pkg_install nodejs "Node.js (agent CLI runtime)"
fi
if ! command -v npm &>/dev/null; then
  safe_pkg_install npm "npm (agent CLI packages)"
fi
install_npm_cli "@earendil-works/pi-coding-agent" pi 22 19
install_npm_cli "@a5c-ai/babysitter" babysitter 20

# Barrier: wait for all parallel GitHub-release downloads to finish and fold
# their failures back into FAILED_PKGS before we report/summarise.
log "Waiting for parallel release-binary installs to finish …"
wait_downloads

fi # dependency installation

# Configure and validate before changing the account's login shell.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
command -v nu &>/dev/null || error "Nushell is required. Install nu and rerun."
nu --no-config-file "$SCRIPT_DIR/configure-nushell.nu" || error "Nushell configuration failed; login shell unchanged."

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
