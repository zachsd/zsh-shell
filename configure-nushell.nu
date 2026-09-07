# Run with nu --no-config-file configure-nushell.nu. Does not change login shell.
def main [] {
    let root = $env.FILE_PWD
    let target = $nu.default-config-dir
    let stamp = (date now | format date '%Y%m%d-%H%M%S-%f')
    let stage = ($target | path join $'.setup-($stamp)')
    for tool in [starship carapace zoxide] {
        if (which $tool | is-empty) { error make {msg: $'Required tool not found: ($tool). Install it and rerun setup.'} }
    }
    mkdir $stage
    try {
        for name in [env.nu config.nu aliases.nu] {
            open --raw ($root | path join shell $name) | save --force ($stage | path join $name)
        }
        for task in [
            {cmd: starship args: [init nu] file: starship.nu}
            {cmd: carapace args: [_carapace nushell] file: carapace.nu}
            {cmd: zoxide args: [init nushell] file: zoxide.nu}
        ] {
            let result = (run-external $task.cmd ...$task.args | complete)
            if $result.exit_code != 0 or ($result.stdout | str trim | is-empty) {
                error make {msg: $'Could not generate ($task.file): ($result.stderr)'}
            }
            $result.stdout | save --force ($stage | path join $task.file)
        }
        # Worktrunk is optional. Its Nu module must be loaded into the caller.
        let wt = if $nu.os-info.name == 'windows' or not (which git-wt | is-empty) { 'git-wt' } else { 'wt' }
        if not (which $wt | is-empty) {
            let result = (run-external $wt config shell init nu | complete)
            if $result.exit_code != 0 { error make {msg: $'Worktrunk integration failed: ($result.stderr)'} }
            $result.stdout | save --force ($stage | path join worktrunk.nu)
        } else { '# Worktrunk not installed.' | save --force ($stage | path join worktrunk.nu) }
        let local = ($target | path join config.local.nu)
        if ($local | path exists) { cp $local ($stage | path join config.local.nu) } else {
            '# Add machine-specific Nushell settings here.' | save ($stage | path join config.local.nu)
        }
        # Parse all includes before replacing any existing configuration.
        let cfg = ($stage | path join config.nu | to nuon)
        let validation = (^$nu.current-exe --no-config-file -c $'nu-check --debug ($cfg)' | complete)
        if $validation.exit_code != 0 or ($validation.stdout | str trim) != 'true' {
            error make {msg: $'Generated Nushell config failed validation: ($validation.stderr) ($validation.stdout)'}
        }
        let smoke = (with-env {TERM: 'xterm-256color'} { ^$nu.current-exe --no-history --config ($stage | path join config.nu) --env-config ($stage | path join env.nu) -c 'null' | complete })
        if $smoke.exit_code != 0 or not ($smoke.stderr | str trim | is-empty) {
            error make {msg: $'Nushell startup validation failed: ($smoke.stderr)'}
        }
        for name in [env.nu config.nu aliases.nu starship.nu carapace.nu zoxide.nu worktrunk.nu] {
            let dest = ($target | path join $name)
            if ($dest | path exists) { cp $dest $'($dest).backup.($stamp)' }
            mv --force ($stage | path join $name) $dest
        }
        if not ($local | path exists) { mv ($stage | path join config.local.nu) $local }
        let theme = ($target | path join starship.toml)
        if not ($theme | path exists) { cp ($root | path join shell starship.toml) $theme }
        # Keep a user's explicit Starship override. Otherwise use our local theme.
        '\n$env.STARSHIP_CONFIG = ($env.STARSHIP_CONFIG? | default ($nu.default-config-dir | path join "starship.toml"))\n'
            | str replace --all '\n' (char newline) | save --append ($target | path join env.nu)
        rm --recursive $stage
        print $'Nushell configuration written to ($target). Existing files have timestamped backups.'
    } catch {|err|
        rm --recursive --force $stage
        error make {msg: $err.msg}
    }
}
