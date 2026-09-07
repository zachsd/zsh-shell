# Nushell does not read .zprofile/.zshenv. Keep paths local and deduplicated.
let extra_paths = if $nu.os-info.name == 'windows' {
    [($env.APPDATA | path join 'npm') ($nu.home-dir | path join 'scoop' 'shims')]
} else {
    [($nu.home-dir | path join '.local' 'bin') ($nu.home-dir | path join 'bin') '/opt/homebrew/bin' '/opt/homebrew/sbin' '/usr/local/bin' '/usr/local/sbin']
}
$env.PATH = ($extra_paths | where {|p| $p | path exists } | append $env.PATH | uniq)
# Consistent editor even when a parent shell exported a different preference.
$env.EDITOR = 'nvim'
$env.VISUAL = 'nvim'
$env.FZF_DEFAULT_OPTS = '--height 50% --layout=reverse --border rounded --color=fg:#c0caf5,bg:#1a1b26,hl:#ff9e64,border:#29a4bd,prompt:#7aa2f7'
