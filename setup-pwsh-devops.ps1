#Requires -Version 5.1
# Windows DevOps tools + Nushell/Starship/Carapace/zoxide.
# The historical filename is retained; existing PowerShell profiles are preserved.
[CmdletBinding()]
param(
    # Skip optional DevOps tools; still install/configure Nushell and integrations.
    [switch]$SkipTools,
    [switch]$NoDefaultShell
)

# Stop on unhandled errors, but individual installs are wrapped so one bad
# package never aborts the whole run (mirrors the bash scripts' set -uo pipefail
# + per-package guards).
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # hugely speeds up Invoke-WebRequest

# ------------------------------------------------------------------------------
# Colours & helpers
# ------------------------------------------------------------------------------
function Write-Log    { param([string]$Msg) Write-Host "[INFO]  " -ForegroundColor Green  -NoNewline; Write-Host $Msg }
function Write-Warn   { param([string]$Msg) Write-Host "[WARN]  " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err    { param([string]$Msg) Write-Host "[ERROR] " -ForegroundColor Red    -NoNewline; Write-Host $Msg }
function Write-Header {
    param([string]$Msg)
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  $Msg"                                      -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
}
function Write-Section { param([string]$Msg) Write-Host ""; Write-Host "  $Msg" -ForegroundColor White }

# Tools that failed to install — reported at the end (mirrors FAILED_PKGS).
$script:FailedPkgs = [System.Collections.Generic.List[string]]::new()
function Add-Failure { param([string]$Name) if (-not $script:FailedPkgs.Contains($Name)) { $script:FailedPkgs.Add($Name) } }

function Test-CommandExists {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ------------------------------------------------------------------------------
# Package-manager wrappers
# ------------------------------------------------------------------------------

# Cache of installed scoop apps so we don't shell out per package.
$script:ScoopInstalled = $null
function Get-ScoopInstalled {
    if ($null -eq $script:ScoopInstalled) {
        $script:ScoopInstalled = @{}
        if (Test-CommandExists scoop) {
            try {
                # `scoop export` emits JSON in modern scoop; fall back to `scoop list`.
                $raw = scoop export 2>$null | Out-String
                if ($raw) {
                    $json = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($json -and $json.apps) {
                        foreach ($a in $json.apps) { $script:ScoopInstalled[$a.Name] = $true }
                    }
                }
            } catch { }
        }
    }
    $script:ScoopInstalled
}

function Install-ScoopPackage {
    param(
        [Parameter(Mandatory)][string]$Package,
        [string]$Desc,
        [string]$Command   # command name to probe when scoop metadata is unavailable
    )
    if (-not $Desc) { $Desc = $Package }
    if (-not (Test-CommandExists scoop)) { Write-Warn "scoop unavailable — skipping $Desc"; Add-Failure $Package; return }

    $installed = Get-ScoopInstalled
    $probe = if ($Command) { $Command } else { $Package.Split('/')[-1] }
    if ($installed.ContainsKey($Package.Split('/')[-1]) -or (Test-CommandExists $probe)) {
        Write-Log "$Desc - already installed."
        return
    }

    Write-Log "Installing $Desc ..."
    # scoop writes progress to stdout; suppress but keep exit status.
    scoop install $Package *> $null
    if ($LASTEXITCODE -ne 0 -and -not (Test-CommandExists $probe)) {
        Write-Warn "FAILED (scoop): $Package"
        Add-Failure $Package
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Desc,
        [string]$Command
    )
    if (-not $Desc) { $Desc = $Id }
    if (-not (Test-CommandExists winget)) { Write-Warn "winget unavailable — skipping $Desc"; Add-Failure $Id; return }

    # Already present?
    if ($Command -and (Test-CommandExists $Command)) { Write-Log "$Desc - already installed."; return }
    $listed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($listed -match [regex]::Escape($Id)) { Write-Log "$Desc - already installed."; return }

    Write-Log "Installing $Desc ..."
    winget install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity 2>$null | Out-Null
    # 0 = installed, -1978335189 (0x8A15002B) = already installed / no upgrade.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189 -and -not ($Command -and (Test-CommandExists $Command))) {
        Write-Warn "FAILED (winget): $Id (exit $LASTEXITCODE)"
        Add-Failure $Id
    }
}

function Install-NpmCli {
    param([string]$Package, [string]$Command, [int]$Major, [int]$Minor = 0)
    if (Test-CommandExists $Command) { Write-Log "$Command - already installed."; return }
    try {
        if (-not (Test-CommandExists node) -or -not (Test-CommandExists npm.cmd)) {
            throw "Node.js ${Major}.${Minor}+ and npm are required; install a supported Node.js LTS release and rerun."
        }
        & node -e 'const [a,b]=process.versions.node.split(".").map(Number); const [x,y]=process.argv.slice(1).map(Number); process.exit(a>x || (a===x && b>=y) ? 0 : 1)' $Major $Minor
        if ($LASTEXITCODE -ne 0) { throw "Node.js ${Major}.${Minor}+ is required; upgrade Node.js and rerun." }
        # Per-user prefix keeps global installs independent of admin permissions.
        & npm.cmd install --global --prefix (Join-Path $env:APPDATA 'npm') --ignore-scripts --engine-strict $Package
        if ($LASTEXITCODE -ne 0) { throw "npm exited with $LASTEXITCODE" }
    } catch {
        Write-Warn "FAILED: $Package - $($_.Exception.Message)"
        Add-Failure $Package
    }
}

# ==============================================================================
# 1. Preflight
# ==============================================================================
Write-Header "1 / 9  Preflight checks"

# Windows PowerShell 5.1 negotiates TLS 1.0/1.1 by default, which the PowerShell
# Gallery and the scoop installer now reject. Force TLS 1.2 for the whole run so
# Install-Module and the scoop bootstrap succeed on 5.1 (no-op on 7+).
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# $IsWindows only exists on PowerShell 6+; on 5.1 it's $null (and 5.1 only runs
# on Windows anyway), so this correctly allows 5.1 through and blocks non-Windows
# on 7+.
if ($env:OS -ne 'Windows_NT' -and -not $IsWindows) {
    Write-Err "This script targets Windows. For macOS/Linux use the setup-zsh-devops*.sh scripts."
    exit 1
}

$osCaption = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { "Windows" }
$osArch    = try { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { $env:PROCESSOR_ARCHITECTURE }
Write-Log "$osCaption ($osArch)"
Write-Log "Running under PowerShell $($PSVersionTable.PSVersion) [$($PSVersionTable.PSEdition)]"

# ==============================================================================
# 2. Package managers — winget & scoop
# ==============================================================================
Write-Header "2 / 9  Package managers"

if (Test-CommandExists winget) {
    Write-Log "winget present ($(winget --version 2>$null))."
} else {
    Write-Warn "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
    Write-Warn "Continuing — scoop will handle most tools."
}

if (Test-CommandExists scoop) {
    Write-Log "scoop present."
} else {
    Write-Log "Installing scoop (per-user, no admin required) ..."
    try {
        if ((Get-ExecutionPolicy -Scope CurrentUser) -in @('Restricted','AllSigned','Undefined')) {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        }
        Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
    } catch {
        Write-Warn "scoop install failed: $($_.Exception.Message)"
    }
}

# Ensure scoop shim dir is on PATH for THIS session.
$scoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
if ((Test-Path $scoopShims) -and ($env:PATH -notlike "*$scoopShims*")) {
    $env:PATH = "$scoopShims;$env:PATH"
}

if (Test-CommandExists scoop) {
    Write-Log "Enabling git (required by scoop buckets) and adding buckets ..."
    # git is needed to add/update buckets.
    if (-not (Test-CommandExists git)) { scoop install git *> $null }
    foreach ($bucket in @('main','extras','nerd-fonts','versions')) {
        $have = (scoop bucket list 2>$null | Out-String)
        if ($have -notmatch "(?m)^\s*$bucket\b") {
            Write-Log "Adding scoop bucket: $bucket"
            scoop bucket add $bucket *> $null
        }
    }
}

# ==============================================================================
# 3. Nerd Font (Starship icons)
# ==============================================================================
Write-Header "3 / 9  Nerd Font — JetBrainsMono"

$fontInstalled = $false
try {
    $fontInstalled = @(Get-ChildItem "$env:WINDIR\Fonts","$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match 'JetBrainsMono.*Nerd' }).Count -gt 0
} catch { }

if ($fontInstalled) {
    Write-Log "JetBrainsMono Nerd Font - already installed."
} elseif (Test-CommandExists scoop) {
    Install-ScoopPackage -Package 'nerd-fonts/JetBrainsMono-NF' -Desc 'JetBrainsMono Nerd Font'
} elseif (Test-CommandExists winget) {
    # Fallback to the Winget font package.
    Install-WingetPackage -Id 'DEVCOM.JetBrainsMonoNerdFont' -Desc 'JetBrainsMono Nerd Font'
}
Write-Warn "Set your terminal font to 'JetBrainsMono Nerd Font Mono' afterwards:"
Write-Warn "  - Windows Terminal: Settings -> Profiles -> Appearance -> Font face"
Write-Warn "  - VSCode:           `"terminal.integrated.fontFamily`": `"JetBrainsMono Nerd Font Mono`""

Write-Header "Shell tools — Nushell, Starship, Carapace & zoxide"
Install-ScoopPackage nushell "Nushell" nu
Install-ScoopPackage neovim "Neovim (default editor)" nvim
Install-ScoopPackage tree-sitter "Tree-sitter CLI" tree-sitter
Install-ScoopPackage zig "Zig compiler (Tree-sitter parsers)" zig
Install-ScoopPackage starship "Starship" starship
Install-ScoopPackage extras/carapace-bin "Carapace" carapace
Install-ScoopPackage zoxide "zoxide" zoxide
# PowerShell 7 is used only to safely parse Windows Terminal's JSONC settings.
Install-WingetPackage 'Microsoft.PowerShell' "PowerShell 7" pwsh
$env:PATH = (@($env:PATH, [Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User')) -join ';')

# ==============================================================================
# 7. Tool installation
# ==============================================================================
Write-Header "7 / 9  Installing tools"

if ($SkipTools) {
    Write-Warn "-SkipTools set — skipping the DevOps/CLI tool installation phase."
} else {

    # -- DevOps / IaC (scoop main/extras) --------------------------------------
    Write-Section "DevOps / IaC"
    Install-ScoopPackage terraform      "HashiCorp Terraform"      terraform
    Install-ScoopPackage terragrunt     "Terragrunt"               terragrunt
    Install-ScoopPackage tflint         "TFLint"                   tflint
    Install-ScoopPackage terraform-docs "terraform-docs"           terraform-docs
    Install-ScoopPackage 'main/infracost' "Infracost"              infracost
    Install-ScoopPackage packer         "HashiCorp Packer"         packer
    Install-ScoopPackage vault          "HashiCorp Vault"          vault
    Install-ScoopPackage sops           "SOPS (secrets)"           sops

    # Ansible is Python-based; on Windows it runs from WSL. Note rather than force.
    Write-Warn "Ansible: control node is not supported natively on Windows — use WSL2 (Ubuntu) for 'ansible'."

    # -- AWS -------------------------------------------------------------------
    Write-Section "AWS"
    Install-WingetPackage 'Amazon.AWSCLI' "AWS CLI v2" aws
    Install-ScoopPackage  aws-iam-authenticator "AWS IAM Authenticator" aws-iam-authenticator
    Install-ScoopPackage  eksctl "eksctl (EKS)" eksctl

    # -- Azure -----------------------------------------------------------------
    Write-Section "Azure"
    Install-WingetPackage 'Microsoft.AzureCLI' "Azure CLI" az

    # -- Kubernetes / OpenShift / Helm -----------------------------------------
    Write-Section "Kubernetes / OpenShift / Helm"
    Install-ScoopPackage kubectl   "kubectl"                       kubectl
    Install-ScoopPackage kubectx   "kubectx + kubens"              kubectx
    Install-ScoopPackage k9s       "K9s (TUI)"                     k9s
    Install-ScoopPackage helm      "Helm"                          helm
    Install-ScoopPackage kustomize "Kustomize"                     kustomize
    Install-ScoopPackage stern     "Stern (multi-pod log tailing)" stern
    Install-ScoopPackage kubeseal  "Sealed Secrets CLI"            kubeseal
    Install-ScoopPackage 'extras/openshift-cli' "OpenShift CLI (oc)" oc

    # -- Containers ------------------------------------------------------------
    Write-Section "Containers"
    Install-ScoopPackage docker-compose "Docker Compose"           docker-compose
    Write-Warn "Podman/Docker engine on Windows needs a backend — install Podman Desktop or Docker Desktop (WSL2)."

    # -- General Dev -----------------------------------------------------------
    Write-Section "General Dev"
    Install-ScoopPackage git      "Git"                            git
    Install-ScoopPackage gh       "GitHub CLI"                     gh
    Install-ScoopPackage jq       "jq"                             jq
    Install-ScoopPackage yq       "yq"                             yq
    Install-ScoopPackage fzf      "fzf"                            fzf
    Install-ScoopPackage bat      "bat (better cat)"               bat
    Install-ScoopPackage eza      "eza (modern ls)"                eza
    Install-ScoopPackage zoxide   "zoxide (smart cd)"              zoxide
    Install-ScoopPackage ripgrep  "ripgrep (rg)"                   rg
    Install-ScoopPackage fd       "fd (better find)"               fd
    Install-ScoopPackage 'extras/tldr' "tldr"                      tldr
    Install-ScoopPackage delta    "delta (git diff pager)"         delta

    # -- Agent tools & worktrees ----------------------------------------------
    Write-Section "Agent tools & worktrees"
    # git-wt avoids the Windows Terminal wt.exe alias collision.
    Install-WingetPackage 'max-sixty.worktrunk' "Worktrunk (git-wt)" git-wt
    if (-not (Test-CommandExists herdr)) {
        $herdrInstaller = Join-Path ([IO.Path]::GetTempPath()) ("herdr-" + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://herdr.dev/install.ps1' -OutFile $herdrInstaller
            # Child process isolates upstream exit and preference changes.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $herdrInstaller
            if ($LASTEXITCODE -ne 0) { throw "Installer exited with $LASTEXITCODE" }
        } catch {
            Write-Warn "FAILED: Herdr - $($_.Exception.Message)"; Add-Failure 'herdr'
        } finally {
            Remove-Item -LiteralPath $herdrInstaller -Force -ErrorAction SilentlyContinue
        }
    } else { Write-Log "Herdr - already installed." }
    if (-not (Test-CommandExists node) -or -not (Test-CommandExists npm.cmd)) {
        Install-ScoopPackage nodejs-lts "Node.js LTS + npm" node
    }
    $npmBin = Join-Path $env:APPDATA 'npm'
    $env:PATH = (@($npmBin, $env:PATH, [Environment]::GetEnvironmentVariable('Path','User')) -join ';')
    Install-NpmCli '@earendil-works/pi-coding-agent' pi 22 19
    Install-NpmCli '@a5c-ai/babysitter' babysitter 20
    # Worktrunk integration is generated by configure-nushell.nu.

    # -- Network / SysAdmin diagnostics ----------------------------------------
    Write-Section "Network & SysAdmin diagnostics"
    Install-ScoopPackage nmap     "Nmap"                           nmap
    Install-ScoopPackage curl     "curl"                           curl
    Install-ScoopPackage wget     "wget"                           wget
    Install-ScoopPackage 'main/iperf3' "iperf3 (bandwidth testing)" iperf3
    Install-ScoopPackage 'main/whois'  "whois"                     whois
    Install-ScoopPackage openssl  "OpenSSL"                        openssl
    Install-ScoopPackage 'extras/wireshark' "Wireshark (tshark)"   tshark
    Install-ScoopPackage 'main/tcping' "tcping (TCP reachability)" tcping
    Write-Warn "dig/nslookup/traceroute -> use built-in Resolve-DnsName / Test-NetConnection / tracert (profile wraps these)."

    # -- VSCode ----------------------------------------------------------------
    Write-Section "VSCode"
    if (Test-CommandExists code) {
        Write-Log "VSCode 'code' CLI already available."
    } else {
        Install-WingetPackage 'Microsoft.VisualStudioCode' "Visual Studio Code" code
    }
}

# Write and validate shared Nushell configuration. Existing PowerShell profiles stay intact.
if (-not (Test-CommandExists nu)) { throw "Nushell installation failed; default terminal unchanged." }
& nu --no-config-file (Join-Path $PSScriptRoot 'configure-nushell.nu')
if ($LASTEXITCODE -ne 0) { throw "Nushell configuration failed; default terminal unchanged." }
& nu --no-config-file (Join-Path $PSScriptRoot 'configure-neovim.nu')
if ($LASTEXITCODE -ne 0) {
    Write-Warn "tree-sitter-nu configuration failed."
    Add-Failure 'tree-sitter-nu'
}
if (-not $NoDefaultShell) {
    if (Test-CommandExists pwsh) {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'set-windows-terminal.ps1')
        if ($LASTEXITCODE -ne 0) { Add-Failure 'Windows Terminal default profile' }
    } else {
        Write-Warn "Select Nushell as the default profile in Windows Terminal settings."
        Add-Failure 'Windows Terminal default profile'
    }
}
Write-Header "Setup complete — Nushell + Starship"
Write-Log "Open a new terminal. Use z / zi for directory navigation and Tab for Carapace completions."
if ($script:FailedPkgs.Count -gt 0) { Write-Warn ("Needs attention: " + ($script:FailedPkgs -join ', ')) }
