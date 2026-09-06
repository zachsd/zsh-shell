# Parse the installer, then load ONLY the npm helper. Never run the installer.
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup-pwsh-devops.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
$helper = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-NpmCli' }, $true)
. ([scriptblock]::Create($helper.Extent.Text))

function Write-Log { param($Msg) }
function Write-Warn { param($Msg) }
function Add-Failure { param($Name) $script:Failures += $Name }
function Test-CommandExists { param($Name) return $Name -in $script:Present }
function node { $global:LASTEXITCODE = $script:NodeResult }
function npm.cmd { $script:NpmArgs = @($args); $global:LASTEXITCODE = $script:NpmResult }
function Reset-Case {
    $script:Present = @('node','npm.cmd')
    $script:NodeResult = 0; $script:NpmResult = 0
    $script:NpmArgs = @(); $script:Failures = @()
}
function Assert-True { param($Value, $Message) if (-not $Value) { throw $Message } }
$originalAppData = $env:APPDATA
try {
    # A path containing spaces catches accidental argument splitting.
    $env:APPDATA = Join-Path ([IO.Path]::GetTempPath()) 'agent tools fake appdata'
    Reset-Case
    Install-NpmCli '@earendil-works/pi-coding-agent' pi 22 19
    Assert-True ($Failures.Count -eq 0) 'Successful npm install recorded a failure'
    Assert-True ($NpmArgs[3] -eq (Join-Path $env:APPDATA 'npm')) 'npm prefix split or lost'
    Assert-True ($NpmArgs -contains '--ignore-scripts') 'Lifecycle scripts must be disabled'
    Assert-True ($NpmArgs -contains '--engine-strict') 'Engine requirements must be enforced'
    Reset-Case; $script:NodeResult = 1
    Install-NpmCli '@earendil-works/pi-coding-agent' pi 22 19
    Assert-True ($Failures.Count -eq 1 -and $NpmArgs.Count -eq 0) 'Old Node must skip npm and report failure'
    Reset-Case; $script:NpmResult = 1
    Install-NpmCli '@a5c-ai/babysitter' babysitter 20
    Assert-True ($Failures -contains '@a5c-ai/babysitter') 'npm failure must be recorded'
    Reset-Case; $script:Present += 'pi'; $script:NodeResult = 1
    Install-NpmCli '@earendil-works/pi-coding-agent' pi 22 19
    Assert-True ($Failures.Count -eq 0 -and $NpmArgs.Count -eq 0) 'Existing CLI must be skipped'
    'PowerShell npm helper checks passed'
} finally { $env:APPDATA = $originalAppData }
