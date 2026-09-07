# Generated integrations are refreshed during setup, never on shell startup.
$env.config.show_banner = false
$env.config.edit_mode = 'emacs'
$env.config.buffer_editor = if $env.EDITOR == 'code --wait' { ['code' '--wait'] } else { $env.EDITOR }
$env.config.history = {file_format: sqlite max_size: 100000 sync_on_enter: true isolation: false}
$env.config.completions.algorithm = 'fuzzy'
$env.config.completions.external.enable = true
$env.config.keybindings = ($env.config.keybindings | append [
    {name: word_left modifier: alt keycode: left mode: [emacs vi_insert] event: {edit: MoveWordLeft}}
    {name: word_right modifier: alt keycode: right mode: [emacs vi_insert] event: {edit: MoveWordRight}}
    {name: meta_b modifier: alt keycode: char_b mode: [emacs vi_insert] event: {edit: MoveWordLeft}}
    {name: meta_f modifier: alt keycode: char_f mode: [emacs vi_insert] event: {edit: MoveWordRight}}
])
source aliases.nu
source carapace.nu
# Expand the full alias (including fixed arguments) before asking Carapace.
# Nushell marks external aliases with ^; Carapace expects the executable name.
let carapace_backend = $env.config.completions.external.completer
$env.config.completions.external.completer = {|spans|
    let expansion = (scope aliases | where name == $spans.0 | get -o 0.expansion)
    let words = if $expansion == null { $spans } else {
        $expansion | split row ' ' | append ($spans | skip 1)
    }
    let words = ($words | update 0 {|word| $word | str trim --left --char '^' })
    try { do $carapace_backend $words } catch { null }
}
source zoxide.nu
source worktrunk.nu
use starship.nu
# Machine-specific Nushell settings; this file is never replaced by setup.
source config.local.nu
