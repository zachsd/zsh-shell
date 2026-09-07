"""Exercise real Nushell integrations in isolated homes; no system installation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NU = shutil.which('nu')
TOOLS = all(shutil.which(x) for x in ('nu','starship','carapace','zoxide'))

@unittest.skipUnless(TOOLS, 'Install nu, starship, carapace and zoxide to run integration checks')
class ShellConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nushell test ')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = dict(os.environ, HOME=str(self.home), USERPROFILE=str(self.home), TERM="xterm-256color",
                        XDG_CONFIG_HOME=str(self.home/'config'), XDG_DATA_HOME=str(self.home/'data'),
                        XDG_CACHE_HOME=str(self.home/'cache'), STARSHIP_CACHE=str(self.home/'cache/starship'))
        self.env.pop('STARSHIP_CONFIG', None)
        self.config = self.home/'config/nushell'

    def generate(self, success=True):
        result=subprocess.run([NU,'--no-config-file',str(ROOT/'configure-nushell.nu')],env=self.env,cwd=self.home,capture_output=True,text=True)
        if success: self.assertEqual(result.returncode,0,result.stderr)
        return result

    def shell(self, command):
        r=subprocess.run([NU,'--no-history','--config',str(self.config/'config.nu'),'--env-config',str(self.config/'env.nu'),'-c',command],env=self.env,cwd=self.home,capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stderr,'')
        return r.stdout

    def test_integrations_and_preservation(self):
        for name in ('.zshrc','.zshenv','.zprofile'):
            (self.home/name).write_text('# original\n')
        self.generate()
        self.assertEqual(self.shell('$env.STARSHIP_SHELL').strip(),'nu')
        # Normal interactive startup must discover the native config directory.
        ready = subprocess.run([NU, '--no-history', '-e', 'print $env.STARSHIP_SHELL; exit'], env=self.env, cwd=self.home, capture_output=True, text=True)
        self.assertEqual(ready.returncode, 0, ready.stderr)
        self.assertIn('nu', ready.stdout)
        self.assertEqual(ready.stderr, '')
        if shutil.which('wt'):
            self.assertEqual(self.shell('scope commands | where name == wt | length').strip(), '1')
        self.assertEqual(self.shell('$env.config.completions.external.completer | describe').strip(),'closure')
        self.assertEqual(json.loads(self.shell('scope aliases | where name in [z zi] | get name | sort | to json')),['z','zi'])
        self.assertIn('git status',self.shell('scope aliases | where name == gs | get expansion | to json'))
        self.assertEqual(self.shell('$env.config.keybindings | where name == word_left | get event.edit.0').strip(),'MoveWordLeft')
        # Actually ask Carapace for git subcommands, not just inspect its hook.
        self.assertGreater(int(self.shell('do $env.config.completions.external.completer [git ""] | length')),0)
        self.assertGreater(int(self.shell('do $env.config.completions.external.completer [gs --] | length')),0)
        self.shell('mkdir sandbox; cd sandbox; zoxide add $env.PWD; cd ..; z sandbox; if ($env.PWD | path basename) != sandbox { error make {msg: "zoxide did not change directory"} }')
        self.shell('starship prompt | ignore')
        (self.config/'config.local.nu').write_text('$env.MY_LOCAL_SETTING = "kept"\n')
        (self.config/'starship.toml').write_text('add_newline = false\n')
        old = (self.config/'config.nu').read_text()
        self.generate()
        self.assertEqual(self.shell('$env.MY_LOCAL_SETTING').strip(),'kept')
        self.assertEqual((self.config/'starship.toml').read_text(),'add_newline = false\n')
        backups=list(self.config.glob('config.nu.backup.*'))
        self.assertTrue(backups)
        self.assertEqual(backups[-1].read_text(),old)
        for name in ('.zshrc','.zshenv','.zprofile'):
            self.assertEqual((self.home/name).read_text(),'# original\n')
        # Invalid local config aborts BEFORE replacing a working config.
        (self.config/'config.local.nu').write_text('def broken [\n')
        self.assertNotEqual(self.generate(False).returncode,0)
        self.assertEqual((self.config/'config.nu').read_text(),old)
        self.assertFalse(list(self.config.glob('.setup-*')))

    def test_platform_config_only_does_not_install_or_change_shell(self):
        bindir=self.home/'bin';bindir.mkdir()
        for name in ('brew','sudo','chsh','curl','wget','npm'):
            p=bindir/name;p.write_text('#!/bin/sh\necho forbidden >> "$HOME/forbidden"\nexit 99\n');p.chmod(0o755)
        self.env['PATH']=str(bindir)+os.pathsep+self.env['PATH']
        self.env['SHELL_SETUP_CONFIG_ONLY']='1'
        for script in ('setup-zsh-devops.sh','setup-zsh-devops-linux.sh'):
            r=subprocess.run(['/bin/bash',str(ROOT/script)],env=self.env,cwd=self.home,capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertFalse((self.home/'forbidden').exists())

if __name__ == '__main__': unittest.main()
