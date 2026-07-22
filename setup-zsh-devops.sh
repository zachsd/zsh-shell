#!/usr/bin/env bash
# ==============================================================================
# Modern ZSH Environment Setup — DevOps / Cloud / SysAdmin
# ==============================================================================
# Tools: oh-my-zsh, oh-my-posh (atomic theme), zsh-autocomplete,
#        zsh-autosuggestions, zsh-syntax-highlighting, zsh-completions
#
# Workloads: Terraform, Terragrunt, AWS, Azure, Kubernetes, OpenShift, Helm,
#            VSCode, plus network/sysadmin diagnostic utilities.
#
# Usage: bash setup-zsh-devops.sh
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

# ==============================================================================
# 1. Preflight
# ==============================================================================
header "1 / 9  Preflight checks"

[[ "$(uname -s)" == "Darwin" ]] || error "This script targets macOS only."
log "macOS $(sw_vers -productVersion) — $(uname -m)"

# ==============================================================================
# 2. Homebrew
# ==============================================================================
header "2 / 9  Homebrew"

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
# 3. Nerd Font  (required for oh-my-posh glyphs/icons)
# ==============================================================================
header "3 / 9  Nerd Font — JetBrainsMono"

brew tap homebrew/cask-fonts 2>/dev/null || true
safe_cask_install "font-jetbrains-mono-nerd-font" "JetBrainsMono Nerd Font"
warn "Remember to set your terminal font to 'JetBrainsMono Nerd Font Mono'."
warn "  • iTerm2:       Preferences → Profiles → Text → Font"
warn "  • Terminal.app: Settings → Profiles → Font"
warn "  • VSCode:       terminal.integrated.fontFamily"

# ==============================================================================
# 4. ZSH (Homebrew — newer than macOS built-in)
# ==============================================================================
header "4 / 9  ZSH"

safe_brew_install zsh "ZSH (Homebrew)"
ZSH_BIN="$(brew --prefix)/bin/zsh"

if ! grep -qF "$ZSH_BIN" /etc/shells; then
  log "Adding $ZSH_BIN to /etc/shells (requires sudo) …"
  echo "$ZSH_BIN" | sudo tee -a /etc/shells
fi

if [[ "$SHELL" != "$ZSH_BIN" ]]; then
  log "Changing default shell to $ZSH_BIN …"
  chsh -s "$ZSH_BIN" || warn "chsh failed — change shell manually: chsh -s $ZSH_BIN"
fi

# ==============================================================================
# 5. oh-my-zsh
# ==============================================================================
header "5 / 9  oh-my-zsh"

if [[ -d "${HOME}/.oh-my-zsh" ]]; then
  log "oh-my-zsh already installed."
else
  log "Installing oh-my-zsh (unattended, no shell switch) …"
  RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# ==============================================================================
# 6. ZSH plugins (external — cloned into OMZ custom/plugins)
# ==============================================================================
header "6 / 9  ZSH plugins"

ZSH_CUSTOM="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"

# Load order matters:
#   zsh-autocomplete  → must source BEFORE compinit (before oh-my-zsh.sh)
#   zsh-completions   → FPATH addition before compinit
#   zsh-autosuggestions / zsh-syntax-highlighting → after oh-my-zsh.sh
clone_or_update_plugin "marlonrichert/zsh-autocomplete"       "${ZSH_CUSTOM}/plugins/zsh-autocomplete"
clone_or_update_plugin "zsh-users/zsh-completions"            "${ZSH_CUSTOM}/plugins/zsh-completions"
clone_or_update_plugin "zsh-users/zsh-autosuggestions"        "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
clone_or_update_plugin "zsh-users/zsh-syntax-highlighting"    "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"

# ==============================================================================
# 7. oh-my-posh
# ==============================================================================
header "7 / 9  oh-my-posh"

if brew list oh-my-posh &>/dev/null; then
  log "oh-my-posh already installed — upgrading …"
  brew upgrade oh-my-posh 2>/dev/null || true
else
  brew install oh-my-posh
fi

OMP_THEMES_DIR="$(brew --prefix oh-my-posh)/themes"
log "Themes directory: $OMP_THEMES_DIR"
if [[ -f "${OMP_THEMES_DIR}/atomic.omp.json" ]]; then
  log "atomic theme found."
else
  warn "atomic theme not found at $OMP_THEMES_DIR — will fall back to default."
fi

# ==============================================================================
# 8. Tool installation
# ==============================================================================
header "8 / 9  Installing tools"

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

# ==============================================================================
# 9. Generate ~/.zprofile and ~/.zshrc
# ==============================================================================
header "9 / 9  Writing ~/.zprofile and ~/.zshrc"

# Resolve paths now so they're hardcoded in the config (avoids a brew call at
# every shell start)
BREW_PREFIX="$(brew --prefix)"
OMP_THEME_PATH="${OMP_THEMES_DIR}/atomic.omp.json"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# --- ~/.zprofile : PATH lives here. On macOS, ~/.zprofile is sourced after
#     /etc/zprofile's path_helper, so our dirs reliably take precedence.
#     `typeset -U` keeps the array unique across re-sourcing.
ZPROFILE="${HOME}/.zprofile"
if [[ -f "$ZPROFILE" ]]; then
  cp "$ZPROFILE" "${ZPROFILE}.backup.${TIMESTAMP}"
  log "Backed up existing .zprofile → ${ZPROFILE}.backup.${TIMESTAMP}"
fi
cat > "$ZPROFILE" << ZPROFILE_EOF
# ==============================================================================
# ~/.zprofile — login-shell PATH  (generated by setup-zsh-devops.sh)
# ==============================================================================
typeset -U path PATH
path=("${BREW_PREFIX}/bin" "${BREW_PREFIX}/sbin" "\$HOME/.local/bin" "\$HOME/bin" \$path)
export PATH
ZPROFILE_EOF
log ".zprofile written."

ZSHRC="${HOME}/.zshrc"
BACKUP="${HOME}/.zshrc.backup.${TIMESTAMP}"

if [[ -f "$ZSHRC" ]]; then
  cp "$ZSHRC" "$BACKUP"
  log "Backed up existing .zshrc → $BACKUP"
fi

cat > "$ZSHRC" << ZSHRC_EOF
# ==============================================================================
# ~/.zshrc — Modern DevOps / Cloud Admin Shell Environment
# Generated by setup-zsh-devops.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# zsh-autocomplete  ← MUST be sourced BEFORE compinit / oh-my-zsh.sh
# ------------------------------------------------------------------------------
ZSH_AUTOCOMPLETE_PLUGIN="\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/zsh-autocomplete/zsh-autocomplete.plugin.zsh"
[[ -f "\$ZSH_AUTOCOMPLETE_PLUGIN" ]] && source "\$ZSH_AUTOCOMPLETE_PLUGIN"

# Tune autocomplete behaviour
zstyle ':autocomplete:*' min-input 1          # start completing after 1 char
zstyle ':autocomplete:*' delay 0.05           # fast response (seconds)
zstyle ':autocomplete:history-incremental-search-backward:*' list-lines 8
zstyle ':autocomplete:history-search:*' list-lines 8

# Show more completions before they get cut off.
# zsh-autocomplete caps real-time listings at 16 lines by default, which
# truncates commands that have many options. Scale the cap to the terminal
# height (2/3 of the screen) so long option lists stay visible, while still
# leaving room for the prompt. zsh additionally caps this to what fits on
# screen, so it never overflows.
zstyle -e ':autocomplete:*' list-lines 'reply=( \$(( LINES * 2 / 3 )) )'

# ------------------------------------------------------------------------------
# oh-my-zsh
# ------------------------------------------------------------------------------
export ZSH="\$HOME/.oh-my-zsh"

# ZSH_THEME="" — oh-my-posh handles the prompt; OMZ theme is disabled
ZSH_THEME=""

# Extra completions on FPATH before compinit (called inside oh-my-zsh.sh)
fpath=("${BREW_PREFIX}/share/zsh/site-functions" "\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/zsh-completions/src" \$fpath)

# OMZ plugins
# Note: zsh-autocomplete is sourced above (before compinit).
#       zsh-autosuggestions and zsh-syntax-highlighting are safe after compinit.
plugins=(
  # --- Version control ---
  git

  # --- Cloud / DevOps ---
  # NOTE: kubectl plugin omitted — its aliases conflict with our kpf()/etc. functions
  # and its completion sourcing is handled explicitly below.
  aws
  helm
  terraform
  ansible
  docker
  docker-compose

  # --- macOS / system ---
  brew
  macos

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

  # --- External (cloned) ---
  zsh-completions
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source "\$ZSH/oh-my-zsh.sh"

# ------------------------------------------------------------------------------
# Completion menu — Tab cycles through options, Enter selects
# ------------------------------------------------------------------------------
# Enable interactive menu-select so completions are shown as a navigable list.
# Must be configured after oh-my-zsh.sh (which calls compinit and creates the
# menuselect keymap).
zstyle ':completion:*' menu select
# When a list is still longer than the screen, page/scroll it (with a position
# indicator) instead of silently truncating the options.
zstyle ':completion:*' list-prompt   '%SAt %p: Tab for more, / to search%s'
zstyle ':completion:*' select-prompt '%SScrolling: line %l — %p%s'
# Tab enters menu-select mode; Shift-Tab enters it going backwards.
bindkey '\t' menu-select "\$terminfo[kcbt]" menu-select
# While inside the menu: Tab advances to the next option,
# Shift-Tab goes to the previous option. Enter (built-in) confirms selection.
bindkey -M menuselect '\t' menu-complete "\$terminfo[kcbt]" reverse-menu-complete

# ------------------------------------------------------------------------------
# Arrow keys — restore up/down to standard history cycling
# ------------------------------------------------------------------------------
# zsh-autocomplete overrides the up/down arrows with a history-search widget.
# Rebind them here (after oh-my-zsh.sh/compinit) to restore simple one-by-one
# cycling through previous commands.
bindkey "\$terminfo[kcuu1]" up-line-or-history    # Up arrow → previous command
bindkey "\$terminfo[kcud1]" down-line-or-history  # Down arrow → next command

# ------------------------------------------------------------------------------
# oh-my-posh — atomic theme
# ------------------------------------------------------------------------------
if command -v oh-my-posh &>/dev/null; then
  _OMP_CONFIG="${OMP_THEME_PATH}"
  # Never fetch over the network here — interactive shell startup must not block
  # on I/O (a flaky/offline network would hang every new prompt). The installer
  # downloads the theme; if it's somehow absent, fall back to the built-in
  # default prompt silently.
  if [[ -f "\$_OMP_CONFIG" ]]; then
    eval "\$(oh-my-posh init zsh --config "\$_OMP_CONFIG")"
  else
    eval "\$(oh-my-posh init zsh)"   # theme missing — use built-in default
  fi
fi

# ------------------------------------------------------------------------------
# PATH — defined in ~/.zprofile (generated by the installer). On macOS,
# /etc/zprofile runs path_helper, which reorders PATH; ~/.zprofile is sourced
# AFTER it, so setting PATH there guarantees Homebrew/local dirs win. Keeping it
# out of ~/.zshrc also avoids re-prepending on every re-source.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Tool completions
# ------------------------------------------------------------------------------
# Each \`tool completion zsh\` forks the binary and evaluates its output — often
# 100–400ms *per tool* on EVERY shell startup. Instead, cache the generated
# script to disk and re-fork only when the cache is missing/empty or older than
# the binary (i.e. after a tool upgrade); otherwise just source the cached file,
# which costs a few ms. These are sourced after oh-my-zsh.sh (post-compinit),
# exactly as before, so \`compdef\` calls inside them still work.
_zsh_comp_cache="\${XDG_CACHE_HOME:-\$HOME/.cache}/zsh/completions"
mkdir -p "\$_zsh_comp_cache"

# Namespaced so \`unset -f\` below can't clobber a user-defined function.
__zdo_load_comp() {
  # __zdo_load_comp <cache-name> <command> [args...]
  local out="\$_zsh_comp_cache/\$1.zsh"; shift
  local bin; bin=\$(command -v "\$1" 2>/dev/null) || return 0
  if [[ ! -s "\$out" || "\$bin" -nt "\$out" ]]; then
    # Generate to a per-process temp file and atomically mv into place ONLY on
    # success. A failed generation or a concurrent shell startup can then never
    # corrupt or clobber a previously-good cache — we simply keep the old one.
    local tmp="\$out.tmp.\$\$"
    if "\$@" > "\$tmp" 2>/dev/null && [[ -s "\$tmp" ]]; then
      mv -f "\$tmp" "\$out"
    else
      rm -f "\$tmp"
      [[ -s "\$out" ]] || return 0   # generation failed and no cache to reuse
    fi
  fi
  source "\$out"
}

__zdo_load_comp kubectl kubectl completion zsh
__zdo_load_comp helm    helm    completion zsh
__zdo_load_comp oc      oc      completion zsh
__zdo_load_comp eksctl  eksctl  completion zsh
__zdo_load_comp gh      gh      completion -s zsh
unset -f __zdo_load_comp
unset _zsh_comp_cache

# kubecolor: inherit kubectl completions via compdef (do NOT alias kubectl itself —
# completion scripts define a kubectl() function which conflicts with aliases)
command -v kubecolor &>/dev/null && compdef kubecolor=kubectl
# AWS
command -v aws_completer &>/dev/null && complete -C "\$(command -v aws_completer)" aws
# Terraform (built-in)
command -v terraform  &>/dev/null && complete -o nospace -C "\$(command -v terraform)" terraform
# direnv hook
command -v direnv     &>/dev/null && eval "\$(direnv hook zsh)"

# ------------------------------------------------------------------------------
# zoxide — smart cd replacement  (replaces 'cd')
# ------------------------------------------------------------------------------
command -v zoxide &>/dev/null && eval "\$(zoxide init zsh --cmd cd)"

# ------------------------------------------------------------------------------
# fzf
# ------------------------------------------------------------------------------
[[ -f "${BREW_PREFIX}/opt/fzf/shell/key-bindings.zsh" ]] && \
  source "${BREW_PREFIX}/opt/fzf/shell/key-bindings.zsh"
[[ -f "${BREW_PREFIX}/opt/fzf/shell/completion.zsh" ]] && \
  source "${BREW_PREFIX}/opt/fzf/shell/completion.zsh"

export FZF_DEFAULT_OPTS="--height 50% --layout=reverse --border rounded \
  --info=inline --prompt='❯ ' --pointer='▶' --marker='✓' \
  --color=fg:#c0caf5,bg:#1a1b26,hl:#ff9e64 \
  --color=fg+:#c0caf5,bg+:#292e42,hl+:#ff9e64 \
  --color=border:#29a4bd,header:#ff9e64,gutter:#1a1b26 \
  --color=spinner:#73daca,info:#73daca,separator:#29a4bd \
  --color=pointer:#bd93f9,marker:#e06c75,prompt:#7aa2f7"
export FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git"
export FZF_CTRL_T_COMMAND="\$FZF_DEFAULT_COMMAND"
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
# zsh-syntax-highlighting
# ------------------------------------------------------------------------------
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern)
ZSH_HIGHLIGHT_PATTERNS+=('rm -rf *' 'fg=white,bold,bg=red')   # highlight dangerous rm

# ------------------------------------------------------------------------------
# Editor / Pager
# ------------------------------------------------------------------------------
export EDITOR="code --wait"
export VISUAL="\$EDITOR"
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
HISTFILE="\$HOME/.zsh_history"
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
setopt CORRECT                # spell-correct commands
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
alias cat='bat --style=plain --paging=never'
alias less='bat --style=plain'
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
alias zshrc='\${EDITOR:-code} ~/.zshrc'
alias path='echo \$PATH | tr ":" "\n" | nl'
alias now='date +"%Y-%m-%d %H:%M:%S %Z"'
alias timestamp='date +%Y%m%d_%H%M%S'

# ------------------------------------------------------------------------------
# Aliases — network & diagnostics
# ------------------------------------------------------------------------------
alias ping='ping -c 5'
alias myip='curl -fsSL https://ifconfig.me && echo'
alias localip="ipconfig getifaddr en0 2>/dev/null || ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}'"
alias flushdns='sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; echo "DNS cache flushed."'
alias tracert='mtr --report-wide'
alias ports='sudo lsof -iTCP -sTCP:LISTEN -n -P'
alias openports='sudo nmap -sT -O localhost'
alias listening='sudo lsof -i -P -n | grep LISTEN'
alias bandwidth='iftop -i en0 2>/dev/null || nload en0'
alias ipinfo='curl -fsSL ipinfo.io | jq'

# Quick TCP port check: tcpcheck <host> <port>
tcpcheck() {
  local host="\$1" port="\$2"
  nc -zv -w 3 "\$host" "\$port" 2>&1 && echo -e "\n\033[0;32mPORT OPEN\033[0m" || echo -e "\n\033[0;31mPORT CLOSED / FILTERED\033[0m"
}

# DNS lookup: lookup <hostname> [record-type]
lookup() { dig +noall +answer "\$1" "\${2:-A}"; }

# Reverse DNS lookup
rdns() { dig +noall +answer -x "\$1"; }

# SSL certificate info: sslcheck <host> [port]
sslcheck() {
  echo | openssl s_client -connect "\${1}:\${2:-443}" -servername "\$1" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -fingerprint
}

# HTTP headers
headers() { curl -fsIL "\$1"; }

# HTTP request with verbose output
hreq() { http --pretty=all "\$@"; }       # requires httpie

# Quick Nmap scans
portscan()      { nmap -sV --open "\$@"; }
portscan-full() { nmap -sV -p- --open "\$@"; }
portscan-udp()  { sudo nmap -sU --open "\$@"; }

# Whois + geolocation
ipwhois() { whois "\$1"; }
ipreport() { curl -fsSL "https://ipinfo.io/\${1}" | jq; }

# Watch a command every 2 s
ww() { watch -n 2 "\$@"; }

# Traceroute with hostnames
tracepath() { mtr --report-wide --show-ips --aslookup "\$@"; }

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
  --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==\`Name\`].Value|[0],InstanceType,PrivateIpAddress,PublicIpAddress]" \
  --output table'
alias awslogs='aws logs describe-log-groups --query "logGroups[].logGroupName" --output text | tr "\t" "\n" | sort'
alias awss3ls='aws s3 ls'
alias awsecr='aws ecr describe-repositories --output table'

# Switch AWS profile interactively (requires fzf)
awsprofile() {
  local profile
  profile=\$(aws configure list-profiles | fzf --prompt="Select AWS profile: " --height=40% --border)
  [[ -n "\$profile" ]] && export AWS_PROFILE="\$profile" && echo "AWS_PROFILE=\$profile"
}

# Switch AWS region interactively (requires fzf)
awsregion() {
  local region
  region=\$(aws ec2 describe-regions --query "Regions[].RegionName" --output text \
    | tr "\t" "\n" | sort | fzf --prompt="Select AWS region: " --height=40% --border)
  [[ -n "\$region" ]] && export AWS_DEFAULT_REGION="\$region" && echo "AWS_DEFAULT_REGION=\$region"
}

# EKS kubeconfig update: eksconfig <cluster-name> [region]
eksconfig() { aws eks update-kubeconfig --name "\$1" --region "\${2:-\${AWS_DEFAULT_REGION:-us-east-1}}"; }

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
  sub=\$(az account list --query "[].{name:name,id:id}" -o tsv \
    | fzf --prompt="Select Azure subscription: " --height=40% --border | awk '{print \$1}')
  [[ -n "\$sub" ]] && az account set --subscription "\$sub" && azwho
}

# AKS kubeconfig: aksconfig <resource-group> <cluster-name>
aksconfig() { az aks get-credentials --resource-group "\$1" --name "\$2" --overwrite-existing; }

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
  ctx=\$(kubectl config get-contexts -o name | fzf --prompt="Select kube context: " --height=40% --border)
  [[ -n "\$ctx" ]] && kubectl config use-context "\$ctx"
}

# Port-forward: kpf <resource> [local:remote]
kpf() { kubectl port-forward "\$1" "\${2:-8080:8080}"; }

# Watch pods: kwatch [namespace]
kwatch() { watch -n 2 kubectl get pods "\${1:+-n \$1}"; }

# Decode all keys of a k8s Secret
ksecret() {
  kubectl get secret "\$1" \${2:+-n \$2} -o json \
    | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
}

# Tail all pods matching a label: ktail app=myapp [namespace]
ktail() { stern "\${1}" \${2:+-n \$2} --tail 50; }

# Run a temporary debug pod
kdebug() {
  kubectl run debug-\$(date +%s) --image=nicolaka/netshoot -it --rm --restart=Never -- bash
}

# Force-delete a stuck pod
kforce() { kubectl delete pod "\$1" \${2:+-n \$2} --grace-period=0 --force; }

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
hudiff() { helm diff upgrade "\$1" "\$2" "\${@:3}"; }

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
    | awk '{print \$1}' \
    | xargs -r git show
}

# ------------------------------------------------------------------------------
# Useful functions
# ------------------------------------------------------------------------------

# mkcd — mkdir + cd
mkcd() { mkdir -p "\$1" && cd "\$1"; }

# extract — unpack any archive
extract() {
  if [[ ! -f "\$1" ]]; then echo "File '\$1' not found."; return 1; fi
  case "\$1" in
    *.tar.bz2|*.tbz2) tar xvjf "\$1" ;;
    *.tar.gz|*.tgz)   tar xvzf "\$1" ;;
    *.tar.xz)         tar xvJf "\$1" ;;
    *.tar.zst)        tar --use-compress-program=unzstd -xvf "\$1" ;;
    *.tar)            tar xvf  "\$1" ;;
    *.bz2)            bunzip2  "\$1" ;;
    *.gz)             gunzip   "\$1" ;;
    *.zip)            unzip    "\$1" ;;
    *.7z)             7z x     "\$1" ;;
    *.rar)            unrar x  "\$1" ;;
    *) echo "Don't know how to extract '\$1'" ;;
  esac
}

# b64enc / b64dec
b64enc() { echo -n "\$1" | base64; }
b64dec() { echo -n "\$1" | base64 --decode && echo; }

# json / yaml pretty-print
json() { cat "\${1:--}" | jq '.'; }
yaml() { cat "\${1:--}" | yq '.'; }

# genpass — random password
genpass() { LC_ALL=C tr -dc 'A-Za-z0-9!@#\$%^&*()_+~' </dev/urandom | head -c "\${1:-32}"; echo; }

# serve — quick HTTP server in current directory
serve() { python3 -m http.server "\${1:-8000}"; }

# has — check if command exists
has() { command -v "\$1" &>/dev/null && echo "✓ \$1 found: \$(command -v \$1)" || echo "✗ \$1 not found"; }

# whatsmyip — public + private IP
whatsmyip() {
  echo "Public:  \$(curl -fsSL https://ifconfig.me)"
  echo "Private: \$(ipconfig getifaddr en0 2>/dev/null || ip -4 a show | grep -oP '(?<=inet )[0-9.]+')"
}

# loop — run a command N times: loop 5 ping -c1 8.8.8.8
# (cannot use 'repeat' — it is a zsh reserved keyword)
loop() {
  local n="\$1"; shift
  for (( i=1; i<=n; i++ )); do "\$@"; done
}

# CIDR subnet info (requires ipcalc)
cidr() { ipcalc "\$1"; }

# Check all nodes and their readiness
knodes() { kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status,VERSION:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage'; }

# Tail pod logs across namespaces by keyword
tlogs() { stern "\$1" -A --tail 50; }

# Base64-encode a file for use in k8s secrets
k8senc() { base64 < "\$1" | tr -d '\n'; echo; }

# Watch kubectl top
ktop() { watch -n 3 kubectl top nodes; }
ZSHRC_EOF

log ".zshrc written."

# ==============================================================================
# Final summary
# ==============================================================================
header "Setup complete!"

echo ""
echo -e "${BOLD}Installed themes path:${RESET}  $OMP_THEMES_DIR"
echo -e "${BOLD}Theme used:${RESET}             atomic"
echo -e "${BOLD}Font required:${RESET}          JetBrainsMono Nerd Font Mono"
echo ""
echo -e "${BOLD}${CYAN}Next steps:${RESET}"
echo -e "  1. ${YELLOW}Set your terminal font${RESET} to ${CYAN}JetBrainsMono Nerd Font Mono${RESET}."
echo -e "     • iTerm2:    Preferences → Profiles → Text → Font"
echo -e "     • Ghostty:   font_family = JetBrainsMono Nerd Font Mono"
echo -e "     • VSCode:    \"terminal.integrated.fontFamily\": \"JetBrainsMono Nerd Font Mono\""
echo ""
echo -e "  2. ${YELLOW}Restart your terminal${RESET} (or open a new tab), then run:"
echo -e "     ${CYAN}source ~/.zshrc${RESET}"
echo ""
echo -e "  3. ${YELLOW}Configure credentials:${RESET}"
echo -e "     • AWS:       ${CYAN}aws configure${RESET}  (or set \$AWS_PROFILE)"
echo -e "     • Azure:     ${CYAN}az login${RESET}"
echo -e "     • K8s/EKS:   copy kubeconfig to ${CYAN}~/.kube/config${RESET}"
echo -e "     • OpenShift: ${CYAN}oc login https://<api-url>${RESET}"
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
