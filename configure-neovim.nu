# Install Neovim's Tree-sitter support and the Nushell grammar without replacing
# the user's init.lua. Run with: nu --no-config-file configure-neovim.nu
const plugin_url = 'https://github.com/nvim-treesitter/nvim-treesitter'

def nvim-path [name: string] {
    let lua = (['lua io.write(vim.fn.stdpath("' $name '"))'] | str join)
    let result = (^nvim --headless -u NONE -i NONE
        --cmd $lua -c qa | complete)
    if $result.exit_code != 0 or ($result.stdout | str trim | is-empty) {
        error make {msg: $'Could not determine Neovim ($name) directory: ($result.stderr)'}
    }
    $result.stdout | str trim
}

def main [] {
    for tool in [nvim git tree-sitter] {
        if (which $tool | is-empty) {
            error make {msg: $'Required tool not found: ($tool). Install it and rerun setup.'}
        }
    }

    let root = $env.FILE_PWD
    let config_dir = (nvim-path config)
    let data_dir = (nvim-path data)
    let plugin_dir = ($data_dir | path join site pack zsh-shell start nvim-treesitter)
    let plugin_parent = ($plugin_dir | path dirname)
    mkdir $plugin_parent

    if not ($plugin_dir | path exists) {
        let clone = (^git clone --filter=blob:none --depth=1 --branch main $plugin_url $plugin_dir | complete)
        if $clone.exit_code != 0 {
            error make {msg: $'Could not install nvim-treesitter: ($clone.stderr)'}
        }
    }

    let managed_dir = ($config_dir | path join after plugin)
    let managed_file = ($managed_dir | path join tree-sitter-nu.lua)
    let source_file = ($root | path join nvim after plugin tree-sitter-nu.lua)
    mkdir $managed_dir
    if ($managed_file | path exists) and ((open --raw $managed_file) != (open --raw $source_file)) {
        let stamp = (date now | format date '%Y%m%d-%H%M%S-%f')
        cp $managed_file $'($managed_file).backup.($stamp)'
    }
    cp --force $source_file $managed_file

    let install_lua = "local ts=require('nvim-treesitter'); ts.install({'nu'}):wait(300000); if not vim.list_contains(ts.get_installed(),'nu') then error('nu parser is not installed') end"
    let install = (^nvim --headless -u NONE -i NONE -c packloadall
        -c $'lua ($install_lua)' -c qa | complete)
    if $install.exit_code != 0 {
        error make {msg: $'Could not install tree-sitter-nu: ($install.stderr) ($install.stdout)'}
    }

    let check_lua = "local ok,loaded=pcall(vim.treesitter.language.add,'nu'); if not ok or not loaded then error(loaded) end"
    let check = (^nvim --headless -u NONE -i NONE -c packloadall
        -c $'lua ($check_lua)' -c qa | complete)
    if $check.exit_code != 0 {
        error make {msg: $'tree-sitter-nu did not load: ($check.stderr) ($check.stdout)'}
    }
    print $'tree-sitter-nu installed for Neovim; managed settings written to ($managed_file).'
}
