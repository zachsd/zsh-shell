# DevOps shell setup

A cross-platform **Nushell** environment with a **Starship** prompt,
**Carapace** command completion, **zoxide** directory navigation, and the
DevOps/agent tools used across your machines. The repository and installer
filenames retain their original `zsh-shell` names for compatibility.

## Install

For this private repository, start with an authenticated checkout:

```sh
gh repo clone zachsd/zsh-shell
cd zsh-shell

# macOS — Homebrew
bash setup-zsh-devops.sh

# Linux — Debian/Ubuntu or RHEL/Fedora family; x86_64/aarch64
bash setup-zsh-devops-linux.sh
```

Windows, from PowerShell:

```powershell
.\setup-pwsh-devops.ps1
```

The Unix installers register Nushell in `/etc/shells` and run `chsh` **after**
the configuration validates. Windows selects a dedicated Nushell profile as
Windows Terminal's default; open Windows Terminal once before running setup.
Existing terminal settings are backed up and preserved, although JSON comments
and formatting are normalized. Windows has no system-wide `chsh` equivalent.
Other terminal applications with an explicit startup command must be set to `nu`.

To configure without changing the default, set `SHELL_SETUP_SET_DEFAULT=0` on
Unix or use `-NoDefaultShell` on Windows. A failed default-shell change is
reported at the end. Existing zsh/PowerShell profiles and installed Oh My Posh /
Oh My Zsh packages are left intact for rollback; the new Nushell setup does not
install or load them.

Set your terminal font to **JetBrainsMono Nerd Font Mono**, then open a new
terminal. Nushell is a different language: use `bash script.sh` for Bash scripts
and `$env.NAME = 'value'` for environment variables. Old `.zshrc.local` code is
not automatically executed or translated.

The public/raw-URL bootstrap is still available where the raw files are
accessible. It downloads the platform installer and all shared configuration
files from the same ref. It does not authenticate private raw downloads:

```sh
curl -fsSL https://raw.githubusercontent.com/zachsd/zsh-shell/main/install.sh | sh
# Detect only, without downloading or installing:
sh install.sh --dry-run
```

Bootstrap flags: `--yes`, `--dry-run`, `--help`. `ZSH_SETUP_REPO` and
`ZSH_SETUP_REF` override the repository and ref. `GITHUB_TOKEN` is used for Linux
release API lookups. Linux downloads remain bounded by `MAX_PARALLEL_DOWNLOADS`
(default 6).

## Shell experience

- Starship: a compact two-line blue/purple prompt with Nerd Font OS icons,
  directory, Git branch/status, duration of slow commands, and a green/red cursor.
- Carapace: external command/argument completion alongside Nushell's native
  structured completion and fuzzy matching.
- zoxide: `z <name>` jumps to a frequent directory; `zi` uses the fzf picker.
  Native `cd` remains available.
- Neovim (`nvim`) is installed and selected for `EDITOR`, `VISUAL`, and
  Nushell’s command-buffer editor. Personal overrides can go in `config.local.nu`.
- Built-in syntax highlighting, Emacs editing, shared SQLite history,
  and explicit Option/Alt-arrow (and Meta-b/f) word navigation.
- Common Terraform, AWS, Azure, Kubernetes, Helm, Docker and Git aliases,
  plus Nushell helpers including `mkcd`, `awsprofile`, `awsregion`, `kswitch`,
  `kpf`, `eksconfig`, `aksconfig`, `b64enc`, `b64dec`, and `serve`.
  Native `ls`, `ps`, and other structured commands are not replaced by text tools.
- Worktrunk's Nushell integration is generated when installed (`git-wt` on
  Windows avoids the Windows Terminal `wt` alias).

Integration scripts are generated **during configuration**, not on every shell
launch. Starship still renders each prompt, Carapace computes matches on demand,
and zoxide tracks visited directories. There are no automatic framework/plugin
updates or cloud status queries added by this configuration.

## Update configuration and refresh integrations

After installing/upgrading the required binaries, run from the checkout:

```sh
nu --no-config-file configure-nushell.nu
```

The configurator requires `nu`, `starship`, `carapace`, and `zoxide` on PATH.
It stages the generated files and validates parsing and startup before replacing
configuration. Existing managed files receive timestamped backups.

Unix configuration-only compatibility commands (no installs or `chsh`):

```sh
SHELL_SETUP_CONFIG_ONLY=1 bash setup-zsh-devops.sh
SHELL_SETUP_CONFIG_ONLY=1 bash setup-zsh-devops-linux.sh
```

The old `ZSH_SETUP_CONFIG_ONLY=1` spelling is also accepted. On Windows,
`-SkipTools` skips optional DevOps packages but still installs/configures the
shell stack; use the `nu` configurator above for a strictly configuration-only
refresh.

Files live in Nushell's native configuration directory, discoverable with
`$nu.default-config-dir` (respects `XDG_CONFIG_HOME`):

- macOS: `~/Library/Application Support/nushell`
- Linux: `~/.config/nushell`
- Windows: `%APPDATA%\nushell`

`env.nu` manages PATH without reading zsh files. `config.nu` loads cached
integrations and aliases, then **`config.local.nu`** for personal settings.
The local file and an existing `starship.toml` are never overwritten. Set
`STARSHIP_CONFIG` to use a different theme.

For rollback, restore the relevant timestamped files and open a new shell.
On Unix, `chsh -s /bin/zsh` selects the previous shell where that is its path;
on Windows restore the settings backup or choose the previous default profile.

## Installed tools

- Shell/editor: Nushell, Neovim, Starship, Carapace, zoxide, fzf, JetBrainsMono Nerd Font.
- Agents/worktrees: Herdr, Pi, Worktrunk, Babysitter (`@a5c-ai/babysitter`).
- IaC: Terraform, Terragrunt, Packer, Vault, TFLint, terraform-docs, Infracost,
  SOPS; Ansible on Unix.
- Cloud/Kubernetes: AWS CLI, Azure CLI, eksctl, aws-iam-authenticator, kubectl,
  Helm, kubectx/kubens, k9s, kustomize, stern, kubeseal, OpenShift CLI.
- Dev: Git, GitHub CLI, jq, yq, bat, eza, ripgrep, fd, tldr, VS Code; direnv
  remains installed on Unix but requires an explicit Nushell integration if used.
- Containers and network/sysadmin utilities remain in the platform package lists.

Package installation is best-effort; failures are reported. Pi requires Node.js
22.19+ and Babysitter requires Node.js 20+. Missing Node/npm are attempted via the
platform package manager; older Linux packages may require a manual LTS upgrade.
Existing Node installations are preserved. npm CLIs use per-user prefixes,
`--ignore-scripts` and `--engine-strict`. Configure agent/provider credentials
separately; setup does not start agents or install harness plugins.

## Validation

With `nu`, `starship`, `carapace`, `zoxide`, Python 3, and xz installed:

```sh
python3 -m unittest discover -s tests
pwsh -NoProfile -File tests/test_agent_tools.ps1
pwsh -NoProfile -File tests/test_windows_terminal.ps1
```

Tests use temporary homes and fake package managers. They check actual Nushell
startup, Carapace Git matches, zoxide jumps, local overrides, backups, failed
configuration rollback, package failure handling, and Windows Terminal settings
preservation. The migration was tested with Nushell 0.115.1, Starship 1.26.0,
and Carapace 1.7.3 on macOS; full Windows/Linux installation requires validation
on those hosts.

Official integration references: [Nushell](https://www.nushell.sh/book/configuration.html),
[Starship](https://starship.rs/guide/),
[Carapace](https://carapace-sh.github.io/carapace-bin/setup.html),
[zoxide](https://github.com/ajeetdsouza/zoxide).
