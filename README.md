# zsh-shell

Opinionated, one-command setup for a modern **zsh** environment tuned for
DevOps / cloud / sysadmin work — on both **Linux** and **macOS**.

It installs and configures zsh with [oh-my-zsh] for plugins and completions,
[oh-my-posh] rendering the git-aware **bubblesextra** prompt, native Tab
completion menus, history autosuggestions, fast syntax highlighting, a curated set of CLI
tools (Terraform, AWS/Azure/Kubernetes tooling, and more), and a ready-to-use
`~/.zshrc` full of aliases and helper functions.

---

## Quick start

For this private repository, use an authenticated checkout:

```sh
gh repo clone zachsd/zsh-shell
cd zsh-shell
# Choose the platform script below.
```

The raw-URL bootstrap below requires the repository to be publicly accessible;
it does not authenticate private repository downloads. `GITHUB_TOKEN` is used
for Linux release lookups, not by this bootstrap.

When raw URLs are accessible, detect your OS and run the matching script:

```sh
curl -fsSL https://raw.githubusercontent.com/zachsd/zsh-shell/main/install.sh | sh
```

`install.sh` figures out whether you're on macOS or Linux (and which Linux
distro), prints what it found, asks for confirmation, then downloads and runs
the right script. Prefer to see what it would do first? Add `--dry-run`:

```sh
curl -fsSL https://raw.githubusercontent.com/zachsd/zsh-shell/main/install.sh | sh -s -- --dry-run
```

> The script asks for confirmation and uses `sudo` for system packages. Read it
> first if you like — `curl -fsSL https://raw.githubusercontent.com/zachsd/zsh-shell/main/install.sh | less`
> — before piping to a shell.

### Or run a platform script directly

```sh
# Linux (Debian/Ubuntu · RHEL/CentOS/Fedora/Alma/Rocky)
bash setup-zsh-devops-linux.sh

# macOS (Homebrew)
bash setup-zsh-devops.sh
```

---

## What you get

**Shell & prompt**
- zsh set as your default shell, with oh-my-zsh (plugins + completions)
- the git-aware `bubblesextra` prompt rendered by [oh-my-posh] (branch + working-tree status in the prompt)
- Native Tab / Shift-Tab menus, `zsh-autosuggestions`, `fast-syntax-highlighting`
- Option/Alt–Left and Right move by word; Up/Down browse command history
- JetBrainsMono Nerd Font

**Tooling** (best-effort; anything unavailable is reported at the end)
- **IaC:** Terraform, Terragrunt, Packer, Vault, TFLint, terraform-docs, Infracost, SOPS, Ansible
- **AWS:** AWS CLI v2, `aws-iam-authenticator`, `eksctl`
- **Azure:** Azure CLI
- **Kubernetes / OpenShift:** kubectl, Helm, kubectx/kubens, k9s, kustomize, stern, kubeseal, `oc`, kubecolor
- **Containers:** Podman, Docker Compose
- **Dev:** git, GitHub CLI, jq, yq, fzf, bat, eza, zoxide, ripgrep, fd, tldr, direnv
- **Network / sysadmin:** nmap, mtr, tcpdump, tshark, httpie, socat, iperf3, whois, and more
- **VS Code** (where available)

**A configured `~/.zshrc`** with aliases and functions for Terraform/Terragrunt,
AWS, Azure, Kubernetes, Helm, Docker, and git, plus network helpers
(`sslcheck`, `lookup`, `tcpcheck`, …) and utilities (`mkcd`, `extract`,
`genpass`, `serve`, …). Your existing `~/.zshrc` is backed up first.

---

## Performance notes

The generated shell config keeps maintenance out of interactive startup:

- Tool completions are driven by `zsh_completion_tools` in `~/.zshrc`.
  Run `zsh-refresh-completions` once after setup and after tool upgrades, then
  open a new shell. Startup only reads the cached scripts; it never launches
  kubectl, Helm, oc, eksctl, or gh to generate them. Failed refreshes preserve
  the previous cache. Before the first refresh, only system/OMZ completions
  are available.
- Native completion menus replace `zsh-autocomplete`. Press Tab to complete
  and enter the menu; Tab / Shift-Tab cycle matches. History suggestions and
  syntax highlighting remain, with the same bubblesextra prompt and fzf colors.
- Oh My Zsh automatic updates are disabled. Run `omz update` when you want to
  update the framework; rerunning the full installer updates external plugins.
- The default plugin list omits `dirhistory` (which takes over Option-arrow),
  redundant AWS/Terraform/Helm setup, and brew/macos/vscode/command-not-found
  helpers. The repository's aliases and installed tools remain available;
  aliases provided only by removed plugins are no longer loaded.
- `PATH` stays in `~/.zshenv` (Linux) / `~/.zprofile` (macOS), de-duplicated via
  `typeset -U`.
- Linux release downloads still run in parallel during installation.

### Update configuration without reinstalling tools

From a local checkout containing these changes:

```sh
# macOS
ZSH_SETUP_CONFIG_ONLY=1 bash setup-zsh-devops.sh

# Linux
ZSH_SETUP_CONFIG_ONLY=1 bash setup-zsh-devops-linux.sh
```

This backs up and replaces `~/.zshrc`, skips package installation, downloads,
font setup and shell changes, and preserves `~/.zprofile` / `~/.zshenv`.
It requires the existing shell dependencies (including Homebrew on macOS).
Put machine-specific settings in `~/.zshrc.local`, which is loaded last and
preserved by either installation mode. Open a new shell and run
`zsh-refresh-completions`; open another shell to use the refreshed caches.
Restore the printed `.zshrc.backup.<timestamp>` file to roll back.

### Option-arrow navigation

The shell binds common terminal sequences in both Emacs and vi insert keymaps,
including Esc-b/f, Alt-arrow, double-Esc arrows, and Ctrl-arrow. Emacs editing
is the default; add `bindkey -v` to `~/.zshrc.local` if you prefer vi mode.

If a terminal intercepts the shortcut, configure Option-Left to send `Esc b`
and Option-Right to send `Esc f`. In iTerm2, review the profile's
[Keys settings](https://iterm2.com/documentation-preferences-profiles-keys.html)
and Option key behavior. The former `dirhistory` plugin assigned these
shortcuts to directory navigation instead of word movement.

### Validation

Run `python3 tests/test_shell.py` (requires zsh) to exercise both generated
platform configurations in temporary homes without package installation.
The checks cover keymaps, completion menus, cold-cache startup, refresh failure
recovery, invalid cache names, backups, and local overrides.

---

## `install.sh` options

Pass flags through the pipe with `sh -s --`:

| Flag | Effect |
| ---- | ------ |
| `-n`, `--dry-run` | Detect and print the environment; download/run nothing. |
| `-y`, `--yes`     | Skip the confirmation prompt. |
| `-h`, `--help`    | Show usage. |

Environment overrides:

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `ZSH_SETUP_REPO` | `zachsd/zsh-shell` | Source `owner/repo`. |
| `ZSH_SETUP_REF`  | `main` | Branch / tag / commit to pull the scripts from. |
| `GITHUB_TOKEN`   | — | Used by the Linux installer to avoid GitHub API rate limits. |

The Linux installer also honors `MAX_PARALLEL_DOWNLOADS` (default `6`).

---

## Requirements

- **Linux:** a Debian- or RHEL-family distro with `sudo`. For the `curl | sh`
  path you need a downloader (`curl` **or** `wget`) plus `bash` to run the setup
  script; other essentials like `git`/`unzip`/`tar` are bootstrapped by the
  setup script if missing.
- **macOS:** [Homebrew]. `bash` is required to run the setup script.
- `install.sh` itself is POSIX `sh`, so it runs the same under `sh`, `bash`,
  `dash`, or `zsh`.

---

## After install

1. **Set your terminal font** to `JetBrainsMono Nerd Font Mono` (the script
   prints per-terminal instructions).
2. **Restart your terminal** (or open a new tab).
3. **Prepare tool completions:** run `zsh-refresh-completions`, then open a new tab.
4. **Configure credentials** as needed: `aws configure`, `az login`, copy your
   kubeconfig, `oc login`, etc.

---

## Repository layout

| File | Purpose |
| ---- | ------- |
| `install.sh` | OS/shell discovery bootstrap; run via `curl … \| sh`. |
| `setup-zsh-devops-linux.sh` | Full setup for Linux (apt / dnf / yum). |
| `setup-zsh-devops.sh` | Full setup for macOS (Homebrew). |

[oh-my-zsh]: https://ohmyz.sh/
[oh-my-posh]: https://ohmyposh.dev/
[Homebrew]: https://brew.sh/
