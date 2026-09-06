#Requires -Version 5.1
<#
==============================================================================
 Modern PowerShell Environment Setup — DevOps / Cloud / SysAdmin  (Windows)
==============================================================================
 Prompt : oh-my-posh (atomic theme) + a JetBrainsMono Nerd Font
 Shell UX: PSReadLine (syntax highlighting, inline autosuggestions from history,
           ListView predictions, MenuComplete tab menu), Terminal-Icons, PSFzf,
           zoxide (smart cd)

 Workloads: Terraform, Terragrunt, AWS, Azure, Kubernetes, OpenShift, Helm,
            VSCode, plus network/sysadmin diagnostic utilities.

 Package managers: winget (built-in on Win10/11) for large/GUI apps & fonts,
                   scoop (per-user, no admin) for CLI dev tooling.

 This is the PowerShell counterpart to setup-zsh-devops.sh / -linux.sh.

 Compatibility: runs on both PowerShell 7+ (pwsh, the priority target) AND
 Windows PowerShell 5.1. The generated profile is written to BOTH profile
 locations and is itself version-neutral (feature detection at runtime), so a
 modern pwsh 7 session and an older Windows PowerShell 5.1 session on the same
 machine both get a working, degrade-gracefully environment.

 Usage (from a PowerShell 7 prompt — preferred — or Windows PowerShell 5.1):
     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
     .\setup-pwsh-devops.ps1
==============================================================================
#>

[CmdletBinding()]
param(
    # Skip the (potentially slow) tool-installation phase and only (re)write the
    # PowerShell profile + install the shell-UX modules/prompt.
    [switch]$SkipTools
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

function Install-PSModuleSafe {
    param([Parameter(Mandatory)][string]$Name, [string]$MinimumVersion)
    if (Get-Module -ListAvailable -Name $Name | Where-Object { -not $MinimumVersion -or $_.Version -ge [version]$MinimumVersion }) {
        Write-Log "Module $Name - already installed."
        return
    }
    Write-Log "Installing module $Name ..."
    try {
        $params = @{ Name = $Name; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true; Repository = 'PSGallery' }
        if ($MinimumVersion) { $params['MinimumVersion'] = $MinimumVersion }
        Install-Module @params -ErrorAction Stop
    } catch {
        Write-Warn "FAILED (module): $Name - $($_.Exception.Message)"
        Add-Failure "module:$Name"
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

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warn "You're running this under Windows PowerShell $($PSVersionTable.PSVersion.Major).x."
    Write-Warn "PowerShell 7+ (pwsh) is the priority target — this script installs it."
    Write-Warn "A compatible profile is still written for Windows PowerShell 5.1 too."
} else {
    Write-Log "PowerShell 7+ detected — priority target. A 5.1 profile is also written for compatibility."
}

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
# 3. Nerd Font  (required for oh-my-posh glyphs/icons)
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
    # Fallback: oh-my-posh can also fetch fonts. winget has some NF packages.
    Install-WingetPackage -Id 'DEVCOM.JetBrainsMonoNerdFont' -Desc 'JetBrainsMono Nerd Font'
}
Write-Warn "Set your terminal font to 'JetBrainsMono Nerd Font Mono' afterwards:"
Write-Warn "  - Windows Terminal: Settings -> Profiles -> Appearance -> Font face"
Write-Warn "  - VSCode:           `"terminal.integrated.fontFamily`": `"JetBrainsMono Nerd Font Mono`""

# ==============================================================================
# 4. PowerShell 7 (pwsh)
# ==============================================================================
Write-Header "4 / 9  PowerShell 7"

if (Test-CommandExists pwsh) {
    Write-Log "PowerShell 7 - already installed ($(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null))."
} else {
    Install-WingetPackage -Id 'Microsoft.PowerShell' -Desc 'PowerShell 7 (pwsh)' -Command 'pwsh'
}

# ==============================================================================
# 5. Shell-UX modules (the zsh-plugin equivalents)
# ==============================================================================
Write-Header "5 / 9  Shell UX modules"

# PSGallery must be trusted for unattended installs.
try {
    if (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) {
        if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
    }
    # NuGet provider is required by Install-Module on a clean box.
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
    }
} catch { }

# PSReadLine 2.2.6+  -> inline autosuggestions + ListView predictions
#   (zsh-autosuggestions + zsh-syntax-highlighting + zsh-autocomplete)
Install-PSModuleSafe -Name 'PSReadLine'      -MinimumVersion '2.2.6'
# Terminal-Icons -> file-type glyphs in listings (like eza --icons)
Install-PSModuleSafe -Name 'Terminal-Icons'
# PSFzf -> fzf key bindings & pickers
Install-PSModuleSafe -Name 'PSFzf'

# ==============================================================================
# 6. oh-my-posh + atomic theme
# ==============================================================================
Write-Header "6 / 9  oh-my-posh"

if (Test-CommandExists oh-my-posh) {
    Write-Log "oh-my-posh - already installed. Upgrading ..."
    if (Test-CommandExists winget) {
        winget upgrade --id JanDeDobbeleer.OhMyPosh --exact --silent `
            --accept-package-agreements --accept-source-agreements 2>$null | Out-Null
    } elseif (Test-CommandExists scoop) { scoop update oh-my-posh *> $null }
} else {
    Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -Desc 'oh-my-posh' -Command 'oh-my-posh'
    if (-not (Test-CommandExists oh-my-posh) -and (Test-CommandExists scoop)) {
        Install-ScoopPackage -Package 'oh-my-posh' -Desc 'oh-my-posh (scoop)'
    }
}

# Refresh PATH so oh-my-posh is callable this session (winget adds it to PATH).
$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
$userPath    = [Environment]::GetEnvironmentVariable('Path','User')
$env:PATH    = (@($env:PATH, $machinePath, $userPath) -join ';')

# Locate the atomic theme.
$ompThemesDir = $env:POSH_THEMES_PATH
if (-not $ompThemesDir) {
    foreach ($cand in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\themes'),
        (Join-Path $env:USERPROFILE  'scoop\apps\oh-my-posh\current\themes')
    )) { if (Test-Path $cand) { $ompThemesDir = $cand; break } }
}
if ($ompThemesDir -and (Test-Path (Join-Path $ompThemesDir 'atomic.omp.json'))) {
    Write-Log "atomic theme found in $ompThemesDir"
} else {
    Write-Warn "atomic theme not located yet; the profile falls back to the default prompt if missing."
}

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
    Write-Log "In a new PowerShell session, run: git-wt config shell install powershell"

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

# ==============================================================================
# 8. Generate the PowerShell profile
# ==============================================================================
Write-Header "8 / 9  Writing the PowerShell profile"

# The SAME version-neutral profile is written to BOTH profile locations so a
# pwsh 7 session (priority) and a Windows PowerShell 5.1 session both pick it up.
# Both editions honour the same Documents redirection (e.g. OneDrive), so
# building from MyDocuments is reliable for the 5.1 path; pwsh is queried for its
# own path so we respect wherever it reports $PROFILE.
$targetProfiles = [System.Collections.Generic.List[string]]::new()

# --- PowerShell 7 (priority) -------------------------------------------------
if (Test-CommandExists pwsh) {
    try {
        $p7 = (pwsh -NoProfile -Command '$PROFILE.CurrentUserCurrentHost' 2>$null)
        if ($p7) { $targetProfiles.Add($p7.Trim()) }
    } catch { }
} elseif ($PSVersionTable.PSVersion.Major -ge 7) {
    $targetProfiles.Add($PROFILE.CurrentUserCurrentHost)
}

# --- Windows PowerShell 5.1 (compatibility) ----------------------------------
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # Running under 5.1 right now: $PROFILE already points at the 5.1 path.
    $targetProfiles.Add($PROFILE.CurrentUserCurrentHost)
} else {
    $docs = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
    if ($docs) {
        $targetProfiles.Add((Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'))
    }
}

# Fallback + de-dup.
if ($targetProfiles.Count -eq 0) { $targetProfiles.Add($PROFILE.CurrentUserCurrentHost) }
$targetProfiles = @($targetProfiles | Select-Object -Unique)
$primaryProfile = $targetProfiles[0]

# The profile is written as a single-quoted here-string (no interpolation), so
# every `$` below is literal PowerShell for the *generated* profile, not this
# installer. Runtime discovery keeps it host-agnostic (no hardcoded paths).
$profileContent = @'
# npm CLI executables installed per-user by this setup.
$npmBin = Join-Path $env:APPDATA 'npm'
if (($env:PATH -split ';') -notcontains $npmBin) { $env:PATH = "$npmBin;$env:PATH" }

# ==============================================================================
# PowerShell profile — Modern DevOps / Cloud Admin Environment
# Generated by setup-pwsh-devops.ps1
#
# Version-neutral: loads under BOTH PowerShell 7+ (priority) and Windows
# PowerShell 5.1. Every edition-specific feature is probed at runtime and
# degrades gracefully, so the same file works in either host.
# ==============================================================================

# ------------------------------------------------------------------------------
# PSReadLine — syntax highlighting + inline autosuggestions + prediction menu
#   (the zsh-syntax-highlighting / zsh-autosuggestions / zsh-autocomplete combo)
# ------------------------------------------------------------------------------
# Prefer the newer PSReadLine the installer put in the user module path. On 5.1
# an older PSReadLine may already be auto-loaded; -MinimumVersion picks the newer
# one when present, and everything below is guarded so it's fine either way.
Import-Module PSReadLine -MinimumVersion 2.2.0 -ErrorAction SilentlyContinue
if (-not (Get-Module PSReadLine)) { Import-Module PSReadLine -ErrorAction SilentlyContinue }

# Predictive IntelliSense (PSReadLine 2.1+). ListView needs 2.2+. Older builds
# (e.g. the 2.0 shipped with a fresh Windows PowerShell 5.1) lack -PredictionSource
# entirely, so the whole block is best-effort.
try {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction Stop
} catch {
    try { Set-PSReadLineOption -PredictionSource History -ErrorAction Stop } catch { }
}
Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue
Set-PSReadLineOption -EditMode Windows -ErrorAction SilentlyContinue
Set-PSReadLineOption -BellStyle None -ErrorAction SilentlyContinue          # NO_BEEP
Set-PSReadLineOption -HistoryNoDuplicates -ErrorAction SilentlyContinue     # HIST_IGNORE_ALL_DUPS
Set-PSReadLineOption -HistorySearchCursorMovesToEnd -ErrorAction SilentlyContinue
Set-PSReadLineOption -MaximumHistoryCount 100000 -ErrorAction SilentlyContinue   # HISTSIZE
Set-PSReadLineOption -HistorySaveStyle SaveIncrementally -ErrorAction SilentlyContinue

# Syntax-highlighting colours (Tokyo-Night-ish, to match the fzf theme below).
# Hex colour strings need PSReadLine 2.0+; guarded so an ancient build can't error.
try {
    Set-PSReadLineOption -Colors @{
        Command            = '#7AA2F7'
        Parameter          = '#BB9AF7'
        Operator           = '#89DDFF'
        Variable           = '#C0CAF5'
        String             = '#9ECE6A'
        Number             = '#FF9E64'
        Comment            = '#565F89'
        Keyword            = '#BB9AF7'
        Error              = '#F7768E'
        InlinePrediction   = '#565F89'
        Selection          = '#283457'
    } -ErrorAction Stop
} catch { }

# Tab -> interactive completion MENU (zsh 'menu select'); Shift-Tab goes back.
Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
Set-PSReadLineKeyHandler -Key Shift+Tab -Function TabCompleteNext

# Up/Down -> history search anchored on what you've typed so far, and simple
# one-by-one cycling on an empty line (mirrors the zsh arrow-key behaviour).
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

# Accept the inline suggestion with -> (RightArrow) or Ctrl+f (like zsh).
Set-PSReadLineKeyHandler -Key RightArrow -Function ForwardChar
Set-PSReadLineKeyHandler -Key Ctrl+f     -Function AcceptSuggestion

# ------------------------------------------------------------------------------
# Terminal-Icons — file-type glyphs in Get-ChildItem / ls output
# ------------------------------------------------------------------------------
Import-Module Terminal-Icons -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------
# oh-my-posh — atomic theme
# ------------------------------------------------------------------------------
# Never fetch over the network at prompt-init: locate the theme on disk and fall
# back to the built-in default silently if it's missing.
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $_themesDir = $env:POSH_THEMES_PATH
    if (-not $_themesDir) {
        foreach ($c in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\themes'),
            (Join-Path $env:USERPROFILE  'scoop\apps\oh-my-posh\current\themes')
        )) { if (Test-Path $c) { $_themesDir = $c; break } }
    }
    $_ompConfig = if ($_themesDir) { Join-Path $_themesDir 'atomic.omp.json' } else { $null }
    if ($_ompConfig -and (Test-Path $_ompConfig)) {
        oh-my-posh init pwsh --config $_ompConfig | Invoke-Expression
    } else {
        oh-my-posh init pwsh | Invoke-Expression   # theme missing -> default prompt
    }
}

# ------------------------------------------------------------------------------
# Encoding / Locale
# ------------------------------------------------------------------------------
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------------------------
# Tool completions (cached — regenerated only when the binary is newer)
# ------------------------------------------------------------------------------
# Each `tool completion powershell` forks the binary and evaluates its output —
# 100-400ms per tool on EVERY startup. Cache the generated script to disk and
# re-fork only when the cache is missing/empty or older than the binary.
# (No null-coalescing here — must parse under Windows PowerShell 5.1 too.)
$__compBase  = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }
$__compCache = Join-Path $__compBase 'PowerShell\completions'
if (-not (Test-Path $__compCache)) { New-Item -ItemType Directory -Path $__compCache -Force | Out-Null }

function global:__Load-Comp {
    param([string]$Name, [string]$Command, [string[]]$CompletionArgs)
    $bin = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $bin) { return }
    $out = Join-Path $__compCache "$Name.ps1"
    $stale = -not (Test-Path $out) -or (Get-Item $out).Length -eq 0 -or
             ($bin.Source -and (Test-Path $bin.Source) -and (Get-Item $bin.Source).LastWriteTime -gt (Get-Item $out).LastWriteTime)
    if ($stale) {
        $tmp = "$out.tmp.$PID"
        try {
            & $Command @CompletionArgs > $tmp 2>$null
            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) { Move-Item -Force $tmp $out }
            else { Remove-Item $tmp -ErrorAction SilentlyContinue; if (-not (Test-Path $out)) { return } }
        } catch { Remove-Item $tmp -ErrorAction SilentlyContinue; if (-not (Test-Path $out)) { return } }
    }
    . $out
}

__Load-Comp kubectl kubectl @('completion','powershell')
__Load-Comp helm    helm    @('completion','powershell')
__Load-Comp oc      oc      @('completion','powershell')
__Load-Comp eksctl  eksctl  @('completion','powershell')
__Load-Comp gh      gh      @('completion','-s','powershell')
__Load-Comp k9s     k9s     @('completion','powershell')

# kubecolor equivalent: reuse kubectl's completer for the 'k' function (below).
# terraform ships its own PowerShell completion via a registered argument
# completer when you run `terraform -install-autocomplete`; skipped here to keep
# startup fast. AWS CLI provides completion through 'aws_completer'.
if (Get-Command aws_completer -ErrorAction SilentlyContinue) {
    Register-ArgumentCompleter -Native -CommandName aws -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        $env:COMP_LINE  = $commandAst.ToString()
        $env:COMP_POINT = $cursorPosition
        (& aws_completer) | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
        Remove-Item Env:\COMP_LINE, Env:\COMP_POINT -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------
# zoxide — smart cd replacement (replaces 'cd')
# ------------------------------------------------------------------------------
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) })
}

# ------------------------------------------------------------------------------
# PSFzf — fzf key bindings & pickers
# ------------------------------------------------------------------------------
if ((Get-Module -ListAvailable PSFzf) -and (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Import-Module PSFzf -ErrorAction SilentlyContinue
    # Ctrl+t -> file picker, Ctrl+r -> history picker (fzf-style).
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r' -ErrorAction SilentlyContinue
}

$env:FZF_DEFAULT_OPTS = @(
    '--height 50% --layout=reverse --border rounded'
    "--info=inline --prompt='> ' --pointer='>' --marker='+'"
    '--color=fg:#c0caf5,bg:#1a1b26,hl:#ff9e64'
    '--color=fg+:#c0caf5,bg+:#292e42,hl+:#ff9e64'
    '--color=border:#29a4bd,header:#ff9e64,gutter:#1a1b26'
    '--color=spinner:#73daca,info:#73daca,separator:#29a4bd'
    '--color=pointer:#bd93f9,marker:#e06c75,prompt:#7aa2f7'
) -join ' '
if (Get-Command fd -ErrorAction SilentlyContinue) {
    $env:FZF_DEFAULT_COMMAND = 'fd --type f --hidden --follow --exclude .git'
    $env:FZF_CTRL_T_COMMAND  = $env:FZF_DEFAULT_COMMAND
    $env:FZF_ALT_C_COMMAND   = 'fd --type d --hidden --follow --exclude .git'
}

# ------------------------------------------------------------------------------
# Editor / Pager
# ------------------------------------------------------------------------------
if (Get-Command code -ErrorAction SilentlyContinue) {
    $env:EDITOR = 'code --wait'
    $env:VISUAL = $env:EDITOR
}
if (Get-Command bat -ErrorAction SilentlyContinue) { $env:PAGER = 'bat' }

# ------------------------------------------------------------------------------
# Helper used by many aliases: prefer a modern tool, gracefully fall back.
# ------------------------------------------------------------------------------
function Test-Cmd { param([string]$n) [bool](Get-Command $n -ErrorAction SilentlyContinue) }

# ==============================================================================
# Aliases — navigation & general
# ==============================================================================
# PowerShell aliases can't carry arguments, so argument-bearing shortcuts are
# functions that splat @args through.
if (Test-Cmd eza) {
    function ls  { eza --icons --group-directories-first @args }
    function ll  { eza -lah --icons --group-directories-first --git @args }
    function la  { eza -a --icons @args }
    function lt  { eza --tree --icons -L 3 @args }
} else {
    function ll  { Get-ChildItem -Force @args | Format-Table -AutoSize }
    function la  { Get-ChildItem -Force @args }
    function lt  { Get-ChildItem -Recurse -Depth 2 @args }
}
if (Test-Cmd bat) {
    function cat  { bat --style=plain --paging=never @args }
    function less { bat --style=plain @args }
}
function mkcd  { param([string]$p) New-Item -ItemType Directory -Force -Path $p | Out-Null; Set-Location $p }
function ..    { Set-Location .. }
function ...   { Set-Location ..\.. }
function ....  { Set-Location ..\..\.. }
function ~     { Set-Location $HOME }
function reload { . $PROFILE }
function which { param([string]$n) (Get-Command $n -ErrorAction SilentlyContinue).Source }
function path  { $env:PATH -split ';' | Where-Object { $_ } | ForEach-Object { $_ } }
function now   { Get-Date -Format 'yyyy-MM-dd HH:mm:ss K' }
function timestamp { Get-Date -Format 'yyyyMMdd_HHmmss' }
function touch { param([string]$f) if (Test-Path $f) { (Get-Item $f).LastWriteTime = Get-Date } else { New-Item -ItemType File -Path $f | Out-Null } }

# ==============================================================================
# Aliases — network & diagnostics  (Windows-native cmdlets)
# ==============================================================================
function myip     { (Invoke-RestMethod -Uri 'https://ifconfig.me/ip').Trim() }
function localip  { (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' -and $_.IPAddress -notlike '169.254*' } | Select-Object -First 1 -Expand IPAddress) }
function flushdns { Clear-DnsClientCache; ipconfig /flushdns | Out-Null; Write-Host 'DNS cache flushed.' }
function ports    { Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Format-Table -AutoSize LocalAddress,LocalPort,State,OwningProcess }
function listening { Get-NetTCPConnection -State Listen | ForEach-Object { [pscustomobject]@{ Port=$_.LocalPort; PID=$_.OwningProcess; Process=(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } } | Sort-Object Port | Format-Table -AutoSize }
function ipinfo   { Invoke-RestMethod -Uri 'https://ipinfo.io/json' }

# Quick TCP port check: tcpcheck <host> <port>
function tcpcheck {
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][int]$Port)
    $r = Test-NetConnection -ComputerName $Target -Port $Port -WarningAction SilentlyContinue
    if ($r.TcpTestSucceeded) { Write-Host "PORT OPEN"   -ForegroundColor Green }
    else                     { Write-Host "PORT CLOSED / FILTERED" -ForegroundColor Red }
}

# DNS lookup: lookup <hostname> [type]
function lookup { param([string]$Name, [string]$Type='A') Resolve-DnsName -Name $Name -Type $Type -ErrorAction SilentlyContinue }
# Reverse DNS: rdns <ip>
function rdns   { param([string]$Ip) Resolve-DnsName -Name $Ip -Type PTR -ErrorAction SilentlyContinue }
# HTTP headers: headers <url>
function headers { param([string]$Url) (Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing).Headers }
# SSL certificate info: sslcheck <host> [port]
function sslcheck {
    param([string]$Target, [int]$Port=443)
    if (Test-Cmd openssl) {
        "" | openssl s_client -connect "${Target}:${Port}" -servername $Target 2>$null | openssl x509 -noout -subject -issuer -dates -fingerprint
    } else {
        $tcp = [System.Net.Sockets.TcpClient]::new($Target, $Port)
        $validate = [System.Net.Security.RemoteCertificateValidationCallback]{ param($s,$c,$ch,$e) $true }
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $validate)
        $ssl.AuthenticateAsClient($Target)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
        [pscustomobject]@{ Subject=$cert.Subject; Issuer=$cert.Issuer; NotBefore=$cert.NotBefore; NotAfter=$cert.NotAfter; Thumbprint=$cert.Thumbprint }
        $ssl.Dispose(); $tcp.Close()
    }
}
# Nmap wrappers (require nmap)
function portscan      { nmap -sV --open @args }
function portscan-full { nmap -sV -p- --open @args }
# whois (requires whois)
function ipwhois  { param([string]$q) whois $q }
function ipreport { param([string]$Ip) Invoke-RestMethod -Uri "https://ipinfo.io/$Ip/json" }
# Watch a command every 2s: ww { <scriptblock> }
function ww { param([scriptblock]$Block, [int]$Seconds=2) while ($true) { Clear-Host; & $Block; Start-Sleep -Seconds $Seconds } }
# Traceroute
function tracepath { param([string]$Target) tracert $Target }

# ==============================================================================
# Aliases — Terraform / Terragrunt
# ==============================================================================
function tf   { terraform @args }
function tfi  { terraform init @args }
function tfiu { terraform init -upgrade @args }
function tfp  { terraform plan @args }
function tfa  { terraform apply @args }
function tfaa { terraform apply -auto-approve @args }
function tfd  { terraform destroy @args }
function tfdaa{ terraform destroy -auto-approve @args }
function tfo  { terraform output -json | ConvertFrom-Json }
function tfw  { terraform workspace @args }
function tfwl { terraform workspace list @args }
function tfws { terraform workspace select @args }
function tff  { terraform fmt -recursive @args }
function tfv  { terraform validate @args }
function tfs  { terraform state @args }
function tfsl { terraform state list @args }
function tfss { terraform state show @args }

function tg    { terragrunt @args }
function tgp   { terragrunt plan @args }
function tga   { terragrunt apply @args }
function tgaa  { terragrunt apply --auto-approve @args }
function tgd   { terragrunt destroy @args }
function tgra  { terragrunt run-all apply @args }
function tgraa { terragrunt run-all apply --auto-approve @args }
function tgrp  { terragrunt run-all plan @args }
function tgrd  { terragrunt run-all destroy @args }
function tgv   { terragrunt validate @args }
function tgf   { terragrunt hclfmt @args }

# ==============================================================================
# Aliases — AWS
# ==============================================================================
function awswho      { aws sts get-caller-identity | ConvertFrom-Json }
function awsprofiles { aws configure list-profiles }
function awsregions  { (aws ec2 describe-regions --query "Regions[].RegionName" --output text) -split '\s+' | Sort-Object }
function awss3ls     { aws s3 ls @args }
function awsecr      { aws ecr describe-repositories --output table }
# Interactive profile switch (requires fzf)
function awsprofile {
    $p = aws configure list-profiles | fzf --prompt="Select AWS profile: " --height=40% --border
    if ($p) { $env:AWS_PROFILE = $p.Trim(); Write-Host "AWS_PROFILE=$env:AWS_PROFILE" }
}
function awsregion {
    $r = ((aws ec2 describe-regions --query "Regions[].RegionName" --output text) -split '\s+' | Sort-Object) | fzf --prompt="Select AWS region: " --height=40% --border
    if ($r) { $env:AWS_DEFAULT_REGION = $r.Trim(); Write-Host "AWS_DEFAULT_REGION=$env:AWS_DEFAULT_REGION" }
}
# EKS kubeconfig update: eksconfig <cluster> [region]
function eksconfig { param([string]$Cluster, [string]$Region) if (-not $Region) { $Region = if ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { 'us-east-1' } } aws eks update-kubeconfig --name $Cluster --region $Region }

# ==============================================================================
# Aliases — Azure
# ==============================================================================
function azwho   { az account show | ConvertFrom-Json | Select-Object name, id, @{n='user';e={$_.user.name}} }
function azlist  { az account list --output table }
function azswitch{ az account set --subscription @args }
function azlogin { az login @args }
function azrg    { az group list --output table }
function azaks   { az aks list --output table }
# Interactive subscription switch (requires fzf)
function azprofile {
    $sub = (az account list --query "[].{name:name,id:id}" -o tsv | fzf --prompt="Select Azure subscription: " --height=40% --border)
    if ($sub) { $id = ($sub -split '\t')[0]; az account set --subscription $id; azwho }
}
# AKS kubeconfig: aksconfig <resource-group> <cluster>
function aksconfig { param([string]$Rg, [string]$Cluster) az aks get-credentials --resource-group $Rg --name $Cluster --overwrite-existing }

# ==============================================================================
# Aliases — Kubernetes
# ==============================================================================
function k    { kubectl @args }
function kga  { kubectl get all -A @args }
function kgp  { kubectl get pods @args }
function kgpa { kubectl get pods -A -o wide @args }
function kgn  { kubectl get nodes -o wide @args }
function kgs  { kubectl get svc -A @args }
function kgi  { kubectl get ingress -A @args }
function kgd  { kubectl get deployments -A @args }
function kgcm { kubectl get configmap -A @args }
function kgsec{ kubectl get secrets -A @args }
function kd   { kubectl describe @args }
function kdp  { kubectl describe pod @args }
function kdn  { kubectl describe node @args }
function kl   { kubectl logs @args }
function klf  { kubectl logs -f @args }
function klt  { kubectl logs --tail=100 @args }
function ke   { kubectl exec -it @args }
function kaf  { kubectl apply -f @args }
function kdf  { kubectl delete -f @args }
function kdel { kubectl delete @args }
function kctxl{ kubectl config get-contexts @args }
function kns  { kubens @args }
function kctx { kubectx @args }
function k9   { k9s @args }
# Note: kubectl's own completion (loaded above) covers the 'kubectl' command;
# the 'k' shortcut falls back to default file/arg completion.

# Switch context with fzf
function kswitch {
    $ctx = kubectl config get-contexts -o name | fzf --prompt="Select kube context: " --height=40% --border
    if ($ctx) { kubectl config use-context $ctx.Trim() }
}
# Port-forward: kpf <resource> [local:remote]
function kpf { param([string]$Resource, [string]$Ports='8080:8080') kubectl port-forward $Resource $Ports }
# Watch pods: kwatch [namespace]
function kwatch {
    param([string]$Namespace)
    while ($true) {
        Clear-Host
        if ($Namespace) { kubectl get pods -n $Namespace } else { kubectl get pods }
        Start-Sleep -Seconds 2
    }
}
# Decode all keys of a k8s Secret: ksecret <name> [namespace]
function ksecret {
    param([string]$Name, [string]$Namespace)
    $nsArg = if ($Namespace) { @('-n', $Namespace) } else { @() }
    (kubectl get secret $Name @nsArg -o json | ConvertFrom-Json).data.PSObject.Properties |
        ForEach-Object { "{0}: {1}" -f $_.Name, [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Value)) }
}
# Tail all pods matching a label: ktail app=myapp [namespace]
function ktail { param([string]$Selector, [string]$Namespace) $nsArg = if ($Namespace) { @('-n',$Namespace) } else { @() }; stern $Selector @nsArg --tail 50 }
# Force-delete a stuck pod
function kforce { param([string]$Pod, [string]$Namespace) $nsArg = if ($Namespace) { @('-n',$Namespace) } else { @() }; kubectl delete pod $Pod @nsArg --grace-period=0 --force }
# Node readiness overview
function knodes { kubectl get nodes -o "custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status,VERSION:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage" }
# Watch kubectl top nodes
function ktop { ww { kubectl top nodes } 3 }

# ==============================================================================
# Aliases — OpenShift
# ==============================================================================
function ocwho     { oc whoami @args }
function ocproject { oc project @args }
function ocprojects{ oc projects @args }
function ocget     { oc get all @args }
function oclogs    { oc logs -f @args }
function oclogin   { oc login @args }

# ==============================================================================
# Aliases — Helm
# ==============================================================================
function h    { helm @args }
function hl   { helm list -A @args }
function hr   { helm repo @args }
function hrl  { helm repo list @args }
function hru  { helm repo update @args }
function hrs  { helm repo search @args }
function hi   { helm install @args }
function hup  { helm upgrade --install @args }
function hun  { helm uninstall @args }
function hst  { helm status @args }
function hh   { helm history @args }
function hd   { helm diff @args }          # requires helm-diff plugin
function hvals{ helm show values @args }
function htemplate { helm template @args }

# ==============================================================================
# Aliases — Docker / Compose
# ==============================================================================
function d      { docker @args }
function dps    { docker ps -a @args }
function dim    { docker images @args }
function dex    { docker exec -it @args }
function dlogs  { docker logs -f @args }
function dstop  { docker stop @args }
function drm    { docker rm @args }
function drmi   { docker rmi @args }
function dprune { docker system prune -af --volumes @args }
function dc     { docker-compose @args }
function dcu    { docker-compose up -d @args }
function dcd    { docker-compose down @args }
function dcl    { docker-compose logs -f @args }

# ==============================================================================
# Aliases — Git
# ==============================================================================
function gs   { git status @args }
function ga   { git add @args }
function gaa  { git add -A @args }
function gc   { git commit @args }
function gcm  { git commit -m @args }
function gca  { git commit --amend --no-edit @args }
function gp   { git push @args }
function gpf  { git push --force-with-lease @args }
function gpl  { git pull @args }
function gplr { git pull --rebase @args }
function gco  { git checkout @args }
function gcob { git checkout -b @args }
function gb   { git branch @args }
function gba  { git branch -a @args }
function gbd  { git branch -d @args }
function glog { git log --oneline --graph --decorate --all @args }
function gd   { git diff @args }
function gds  { git diff --staged @args }
function gst  { git stash @args }
function gstp { git stash pop @args }
function gstl { git stash list @args }
function gtag { git tag --sort=-version:refname @args }
# Interactive git log with fzf
function gshow {
    $sha = git log --oneline --all | fzf --ansi --preview 'git show --color=always {1}'
    if ($sha) { git show ($sha -split '\s+')[0] }
}

# ==============================================================================
# Useful functions
# ==============================================================================
# extract — unpack any archive (uses 7z/tar when available)
function extract {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { Write-Host "File '$Path' not found."; return }
    switch -Regex ($Path) {
        '\.(tar\.bz2|tbz2|tar\.gz|tgz|tar\.xz|tar)$' { tar -xvf $Path; break }
        '\.zip$'          { Expand-Archive -Path $Path -DestinationPath (Get-Location) -Force; break }
        '\.(7z|rar|gz|bz2)$' { if (Test-Cmd 7z) { 7z x $Path } else { Write-Host "Install 7zip: scoop install 7zip" }; break }
        default           { Write-Host "Don't know how to extract '$Path'" }
    }
}
# b64enc / b64dec
function b64enc { param([string]$s) [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s)) }
function b64dec { param([string]$s) [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) }
# json / yaml pretty-print
function json { param([string]$f) $d = if ($f) { Get-Content $f -Raw } else { $input }; $d | jq '.' }
function yaml { param([string]$f) $d = if ($f) { Get-Content $f -Raw } else { $input }; $d | yq '.' }
# genpass — random password
function genpass {
    param([int]$Length=32)
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+~'
    -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}
# serve — quick HTTP server in the current directory
function serve { param([int]$Port=8000) if (Test-Cmd python) { python -m http.server $Port } else { Write-Host "python not found" } }
# has — check if a command exists
function has { param([string]$n) $c = Get-Command $n -ErrorAction SilentlyContinue; if ($c) { Write-Host "OK $n found: $($c.Source)" -ForegroundColor Green } else { Write-Host "X $n not found" -ForegroundColor Red } }
# whatsmyip — public + private
function whatsmyip { Write-Host "Public:  $(myip)"; Write-Host "Private: $(localip)" }
# loop — run a scriptblock N times: loop 5 { ping -n 1 8.8.8.8 }
function loop { param([int]$N, [scriptblock]$Block) 1..$N | ForEach-Object { & $Block } }
# Base64-encode a file for k8s secrets
function k8senc { param([string]$f) [Convert]::ToBase64String([IO.File]::ReadAllBytes($f)) }

# ------------------------------------------------------------------------------
# Greeting
# ------------------------------------------------------------------------------
# (Kept minimal — oh-my-posh renders the prompt.)
'@

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($tp in $targetProfiles) {
    $profileDir = Split-Path -Parent $tp
    if ($profileDir -and -not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (Test-Path $tp) {
        $backup = "$tp.backup.$timestamp"
        Copy-Item $tp $backup -Force
        Write-Log "Backed up existing profile -> $backup"
    }
    # UTF-8. On 5.1 this includes a BOM (harmless & helps 5.1 read the glyphs);
    # on 7+ Set-Content's UTF8 is BOM-less. Both editions read either fine.
    Set-Content -Path $tp -Value $profileContent -Encoding UTF8
    Write-Log "Profile written -> $tp"
}

# ==============================================================================
# 9. Final summary
# ==============================================================================
Write-Header "Setup complete!"

Write-Host ""
Write-Host "Profiles written:" -ForegroundColor Cyan
for ($i = 0; $i -lt $targetProfiles.Count; $i++) {
    $tag = if ($i -eq 0) { "(primary)" } else { "(compat)" }
    Write-Host "  - " -NoNewline; Write-Host $targetProfiles[$i] -ForegroundColor Cyan -NoNewline; Write-Host "  $tag"
}
Write-Host "Theme used:    " -NoNewline; Write-Host "atomic (oh-my-posh)" -ForegroundColor Cyan
Write-Host "Font required: " -NoNewline; Write-Host "JetBrainsMono Nerd Font Mono" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. " -NoNewline; Write-Host "Set your terminal font" -ForegroundColor Yellow -NoNewline; Write-Host " to " -NoNewline; Write-Host "JetBrainsMono Nerd Font Mono" -ForegroundColor Cyan
Write-Host "     - Windows Terminal: Settings -> Profiles -> Appearance -> Font face"
Write-Host "     - VSCode:           `"terminal.integrated.fontFamily`": `"JetBrainsMono Nerd Font Mono`""
Write-Host ""
Write-Host "  2. " -NoNewline; Write-Host "Open a new PowerShell 7 (pwsh) session" -ForegroundColor Yellow -NoNewline; Write-Host " — recommended —"
Write-Host "     or a new Windows PowerShell 5.1 session, or reload with:"
Write-Host "     . `$PROFILE" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. " -NoNewline; Write-Host "Configure credentials:" -ForegroundColor Yellow
Write-Host "     - AWS:       " -NoNewline; Write-Host "aws configure" -ForegroundColor Cyan -NoNewline; Write-Host "   (or set `$env:AWS_PROFILE)"
Write-Host "     - Azure:     " -NoNewline; Write-Host "az login" -ForegroundColor Cyan
Write-Host "     - K8s/EKS:   copy kubeconfig to " -NoNewline; Write-Host "`$HOME\.kube\config" -ForegroundColor Cyan
Write-Host "     - OpenShift: " -NoNewline; Write-Host "oc login https://<api-url>" -ForegroundColor Cyan
Write-Host ""
Write-Host "  4. " -NoNewline; Write-Host "Helm diff plugin" -ForegroundColor Yellow -NoNewline; Write-Host " (optional, enables the 'hd' function):"
Write-Host "     helm plugin install https://github.com/databus23/helm-diff" -ForegroundColor Cyan
Write-Host ""

if ($script:FailedPkgs.Count -gt 0) {
    Write-Warn "The following packages failed to install — review manually:"
    foreach ($pkg in $script:FailedPkgs) { Write-Host "    - $pkg" -ForegroundColor Red }
    Write-Host ""
}

Write-Host "Done." -ForegroundColor Green
