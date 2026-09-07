#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('nu-terminal-test-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temp
try {
    $exe = Join-Path $temp 'nu.exe'; Set-Content $exe 'fake executable; never run'
    $path = Join-Path $temp 'settings.json'
    Set-Content $path '{ // keep existing data, JSONC supported
        "defaultProfile":"old", "theme":"dark", "profiles":{"defaults":{"font":{"size":14}},"list":[{"guid":"old","name":"Existing"}]}}
'
    $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'set-windows-terminal.ps1'
    & $script -SettingsPaths $path -NuPath $exe
    & $script -SettingsPaths $path -NuPath $exe
    $s = Get-Content -Raw $path | ConvertFrom-Json -AsHashtable
    if ($s.profiles.list.Count -ne 2 -or $s.theme -ne 'dark' -or $s.profiles.defaults.font.size -ne 14) { throw 'Settings lost or duplicate profile added' }
    if ($s.defaultProfile -eq 'old') { throw 'Default not changed' }
    if (@(Get-ChildItem "$path.backup.*").Count -ne 2) { throw 'Backups missing' }
    Set-Content $path '{broken json'
    try { & $script -SettingsPaths $path -NuPath $exe; throw 'Expected parse failure' } catch {
        if ((Get-Content -Raw $path).Trim() -ne '{broken json') { throw 'Invalid original was overwritten' }
    }
    'Windows Terminal preservation and repeat-run checks passed'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
