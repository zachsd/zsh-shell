# zsh-shell

Opinionated, one-command setup for a modern **zsh** environment tuned for
DevOps / cloud / sysadmin work — on both **Linux** and **macOS**.

It installs and configures zsh with [oh-my-zsh], the git-aware **agnoster**
theme, real-time autocompletion, autosuggestions, fast syntax highlighting, a
curated set of CLI tools (Terraform, AWS/Azure/Kubernetes tooling, and more),
and a ready-to-use `~/.zshrc` full of aliases and helper functions.

---

## Quick start

Detect your OS and run the matching setup script in one line:

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
- zsh set as your default shell, with oh-my-zsh
- the built-in git-aware `agnoster` theme (branch + working-tree status in the prompt)
- `zsh-autocomplete`, `zsh-autosuggestions`, `fast-syntax-highlighting`
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

The generated shell config is built for fast startup:

- Tool completions are driven by an editable `zsh_completion_tools` list in
  `~/.zshrc` (kubectl/helm/oc/eksctl/gh out of the box — add your own in one
  line). They're **cached to disk** and only regenerated after a tool upgrade,
  instead of forking each binary on every shell launch.
- No network I/O during interactive startup.
- `PATH` lives in `~/.zshenv` (Linux) / `~/.zprofile` (macOS), de-duplicated via
  `typeset -U`, rather than being re-prepended in `~/.zshrc`.
- On Linux, the installer downloads release binaries **in parallel**.

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
3. **Configure credentials** as needed: `aws configure`, `az login`, copy your
   kubeconfig, `oc login`, etc.

---

## Repository layout

| File | Purpose |
| ---- | ------- |
| `install.sh` | OS/shell discovery bootstrap; run via `curl … \| sh`. |
| `setup-zsh-devops-linux.sh` | Full setup for Linux (apt / dnf / yum). |
| `setup-zsh-devops.sh` | Full setup for macOS (Homebrew). |

[oh-my-zsh]: https://ohmyz.sh/
[Homebrew]: https://brew.sh/
