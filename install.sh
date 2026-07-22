#!/bin/sh
# ==============================================================================
# install.sh — OS/shell discovery bootstrap for the zsh DevOps setup scripts
# ==============================================================================
# Detects your operating system (and, on Linux, your distribution), reports the
# environment, then downloads and runs the matching setup script:
#
#     macOS  → setup-zsh-devops.sh        (Homebrew)
#     Linux  → setup-zsh-devops-linux.sh  (apt / dnf / yum)
#
# Usage — pipe straight into a shell:
#
#     curl -fsSL https://raw.githubusercontent.com/zachsd/zsh-shell/main/install.sh | sh
#
# Pass flags through the pipe with `sh -s --`:
#
#     curl -fsSL .../install.sh | sh -s -- --dry-run   # detect only, run nothing
#     curl -fsSL .../install.sh | sh -s -- --yes       # skip the confirmation
#
# Environment overrides:
#     ZSH_SETUP_REPO   owner/repo to pull from   (default: zachsd/zsh-shell)
#     ZSH_SETUP_REF    branch/tag/commit to use  (default: main)
#
# This script is intentionally POSIX sh so it runs the same whether piped to
# `sh`, `bash`, `dash`, or `zsh`. The setup scripts it launches require bash.
# ==============================================================================

set -eu

REPO="${ZSH_SETUP_REPO:-zachsd/zsh-shell}"
REF="${ZSH_SETUP_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

DRY_RUN=0
ASSUME_YES=0

# ------------------------------------------------------------------------------
# Output helpers — colourised only when writing to a terminal.
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
  C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'
  C_C='\033[0;36m'; C_B='\033[1m';    C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_C=''; C_B=''; C_0=''
fi

say()  { printf '%b[detect]%b %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '%b[warn]%b  %s\n'  "$C_Y" "$C_0" "$1" >&2; }
die()  { printf '%b[error]%b %s\n'  "$C_R" "$C_0" "$1" >&2; exit 1; }

usage() {
  cat <<EOF
install.sh — detect OS/shell and run the matching zsh DevOps setup script.

Options:
  -n, --dry-run   Detect and print the environment, but do not download or run.
  -y, --yes       Proceed without the interactive confirmation prompt.
  -h, --help      Show this help.

Environment:
  ZSH_SETUP_REPO  owner/repo   (default: zachsd/zsh-shell)
  ZSH_SETUP_REF   branch/ref   (default: main)
EOF
}

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            warn "Ignoring unknown argument: $arg" ;;
  esac
done

# ------------------------------------------------------------------------------
# Detect OS / architecture / distribution / shell
# ------------------------------------------------------------------------------
OS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"

case "$OS" in
  Darwin)
    PLATFORM="macOS"
    SCRIPT="setup-zsh-devops.sh"
    ;;
  Linux)
    PLATFORM="Linux"
    SCRIPT="setup-zsh-devops-linux.sh"
    ;;
  *)
    die "Unsupported operating system: '$OS'. This installer supports macOS and Linux only."
    ;;
esac

DISTRO=""
if [ "$OS" = "Linux" ] && [ -r /etc/os-release ]; then
  # Subshell so sourcing os-release can't leak variables into this script.
  DISTRO="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}" )"
fi

# The user's configured login shell, plus whether zsh is already present.
LOGIN_SHELL="${SHELL:-unknown}"
if command -v zsh >/dev/null 2>&1; then
  ZSH_STATE="present ($(zsh --version 2>/dev/null | cut -d' ' -f1-2))"
else
  ZSH_STATE="not installed — the setup script will install it"
fi

# ------------------------------------------------------------------------------
# Report
# ------------------------------------------------------------------------------
printf '%b' "\n${C_B}${C_C}==== zsh DevOps environment installer ====${C_0}\n\n"
say "Operating system : ${PLATFORM} (${OS})"
say "Architecture     : ${ARCH}"
[ -n "$DISTRO" ] && say "Distribution     : ${DISTRO}"
say "Login shell      : ${LOGIN_SHELL}"
say "zsh              : ${ZSH_STATE}"
say "Selected script  : ${SCRIPT}"
say "Source           : ${REPO}@${REF}"
printf '\n'

if [ "$DRY_RUN" -eq 1 ]; then
  say "Dry run — would download and execute:"
  say "  ${RAW_BASE}/${SCRIPT}"
  exit 0
fi

# ------------------------------------------------------------------------------
# Confirm (reads from the terminal, so it works even when this script itself is
# being piped from curl — in which case stdin is the pipe, not the keyboard).
# ------------------------------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
  if [ -e /dev/tty ]; then
    printf '%bProceed with the %s setup now?%b [Y/n] ' "$C_B" "$PLATFORM" "$C_0" > /dev/tty
    read reply < /dev/tty || reply=""
    case "$reply" in
      ''|y|Y|yes|YES|Yes) : ;;
      *) die "Aborted by user." ;;
    esac
  else
    warn "No terminal available for confirmation — proceeding (pass --yes to silence)."
  fi
fi

# ------------------------------------------------------------------------------
# Download the setup script to a temp file, then execute it with bash.
# Running from a file (rather than another pipe) keeps the setup script's stdin
# free for its own prompts (sudo, chsh, oh-my-zsh).
# ------------------------------------------------------------------------------
command -v bash >/dev/null 2>&1 || die "bash is required to run the setup script, but was not found."

TMP="$(mktemp "${TMPDIR:-/tmp}/zsh-setup.XXXXXX")" || die "Could not create a temp file."
trap 'rm -f "$TMP"' EXIT INT TERM

URL="${RAW_BASE}/${SCRIPT}"
say "Downloading ${URL} …"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$TMP" || die "Download failed (curl). Check the URL / network."
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP" "$URL" || die "Download failed (wget). Check the URL / network."
else
  die "Neither curl nor wget is available to download the setup script."
fi
[ -s "$TMP" ] || die "Downloaded setup script is empty."

say "Launching ${SCRIPT} …"
printf '\n'
# Reconnect stdin to the terminal when available so interactive prompts work.
if [ -e /dev/tty ]; then
  bash "$TMP" < /dev/tty
else
  bash "$TMP"
fi
