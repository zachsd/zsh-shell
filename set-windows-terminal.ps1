#Requires -Version 7.0
# Windows has no chsh; select Nushell as Windows Terminal's default profile.
[CmdletBinding()]
param([string[]]$SettingsPaths, [string]$NuPath)
$ErrorActionPreference = 'Stop'
if (-not $NuPath) { $NuPath = (Get-Command nu -CommandType Application -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $NuPath)) { throw 'Nushell executable not found.' }
if (-not $SettingsPaths) {
    $SettingsPaths = @(
        Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages/Microsoft.WindowsTerminal*') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState/settings.json' }
        $unpacked = Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/settings.json'
        if (Test-Path $unpacked) { $unpacked }
    )
}
if (-not $SettingsPaths) {
    throw 'Open Windows Terminal once, then rerun setup to select Nushell as the default profile.'
}
foreach ($path in $SettingsPaths) {
    # PowerShell 7 parses JSONC comments. Do not discard unknown settings.
    $settings = if (Test-Path $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable } else { @{} }
    if (-not $settings.Contains('profiles')) { $settings.profiles = @{list = @()} }
    # Older Windows Terminal versions used a plain profile array.
    if ($settings.profiles -isnot [System.Collections.IDictionary]) { $settings.profiles = @{list = @($settings.profiles)} }
    if (-not $settings.profiles.Contains('list')) { $settings.profiles.list = @() }
    $guid = '{d56bb462-10cc-48f0-9efb-3ac09372f0c6}'
    $profile = @($settings.profiles.list | Where-Object { $_.guid -eq $guid }) | Select-Object -First 1
    if (-not $profile) {
        $profile = @{guid = $guid; name = 'Nushell (DevOps)'}
        $settings.profiles.list = @($settings.profiles.list) + @($profile)
    }
    $profile.commandline = '"' + $NuPath + '" --login'
    $profile.hidden = $false
    $settings.defaultProfile = $guid
    $text = $settings | ConvertTo-Json -Depth 100
    # Verify serialization before touching the original.
    $null = $text | ConvertFrom-Json -AsHashtable
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'
    if (Test-Path $path) { Copy-Item -LiteralPath $path -Destination "$path.backup.$stamp" }
    $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
    $temp = "$path.$stamp.tmp"
    [IO.File]::WriteAllText($temp, $text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $path -Force
    Write-Host "Nushell selected as default in $path"
}
