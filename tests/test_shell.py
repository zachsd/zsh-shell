"""Exercise generated shells without installing packages or changing real dotfiles."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ZSH = shutil.which('zsh')

@unittest.skipUnless(ZSH, 'zsh is required')
class ShellConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zsh-shell-test-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), ZDOTDIR=str(self.home),
                        XDG_CACHE_HOME=str(self.home / '.cache'),
                        PATH=f'{self.bin}:/usr/bin:/bin', TERM='xterm-256color',
                        ZSH_SETUP_CONFIG_ONLY='1')
        self.stub('brew', 'echo /nonexistent-homebrew')
        for cmd in ('sudo', 'curl', 'wget', 'git', 'chsh'):
            self.stub(cmd, f'echo {cmd} >> "$HOME/forbidden"; exit 99')
        omz = self.home / '.oh-my-zsh'
        omz.mkdir()
        (omz / 'oh-my-zsh.sh').write_text('autoload -Uz compinit\ncompinit -d "$HOME/.zcompdump"\n')
        (self.home / '.zshrc').write_text('# existing shell\n')
        for name in ('.zprofile', '.zshenv'):
            (self.home / name).write_text('# keep environment\n')

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)

    def generate(self, script):
        subprocess.run(['bash', str(ROOT / script)], env=self.env, check=True,
                       capture_output=True, text=True)
        self.assertFalse((self.home / 'forbidden').exists())
        self.assertTrue(list(self.home.glob('.zshrc.backup.*')))
        for name in ('.zprofile', '.zshenv'):
            self.assertEqual((self.home / name).read_text(), '# keep environment\n')
        subprocess.run([ZSH, '-n', str(self.home / '.zshrc')], check=True)

    def shell(self, code, success=True):
        result = subprocess.run([ZSH, '-fic', 'source "$HOME/.zshrc"\n' + code],
                                env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
        return result

    def test_platforms(self):
        for script in ('setup-zsh-devops.sh', 'setup-zsh-devops-linux.sh'):
            with self.subTest(platform=script):
                self.generate(script)
                self.shell('')
                self.shell('[[ $EDITOR == nvim && $VISUAL == nvim ]]')
                generated = (self.home / '.zshrc').read_text()
                self.assertIn('starship init zsh', generated)
                self.assertNotIn('oh-my-posh', generated)
                self.assertNotIn('nushell', generated.lower())
                # Startup must not execute a generator, even with a cold cache.
                self.stub('wt', "echo called >> \"$HOME/wt-generator\"; echo 'wt() { print -r -- wrapper-loaded; }'")
                self.stub('kubectl', 'echo called >> "$HOME/generator"; echo "compdef _files kubectl"')
                result = self.shell('''
for map in emacs viins; do
  for key in '^[b' '^[[1;3D' '^[[3D' '^[^[[D' '^[O3D' '^[[1;5D'; do
    [[ $(bindkey -M "$map" "$key") == *backward-word ]] || exit 10
  done
  for key in '^[f' '^[[1;3C' '^[[3C' '^[^[[C' '^[O3C' '^[[1;5C'; do
    [[ $(bindkey -M "$map" "$key") == *forward-word ]] || exit 11
  done
done
[[ $(bindkey -M menuselect '^I') == *menu-complete ]] || exit 12
[[ $(bindkey -M menuselect '^[[Z') == *reverse-menu-complete ]] || exit 13
[[ $plugins != *dirhistory* && $plugins != *zsh-autocomplete* ]] || exit 14
''')
                self.assertFalse((self.home / 'generator').exists())
                self.assertFalse((self.home / 'wt-generator').exists())
                self.shell('zsh-refresh-completions')
                cache = self.home / '.cache/zsh/completions/kubectl.zsh'
                self.assertEqual(cache.read_text(), 'compdef _files kubectl\n')
                (self.home / 'generator').unlink()
                (self.home / 'wt-generator').unlink()
                self.shell('[[ $_comps[kubectl] == _files ]] && [[ $(wt) == wrapper-loaded ]]')
                self.assertFalse((self.home / 'wt-generator').exists())
                self.assertFalse((self.home / 'generator').exists())
                # A failed or malformed generator must preserve the working cache.
                for body in ('echo broken; exit 1', 'echo "if then"', 'exit 0'):
                    self.stub('kubectl', body)
                    result = self.shell('zsh-refresh-completions', success=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(cache.read_text(), 'compdef _files kubectl\n')
                self.assertFalse(list(cache.parent.glob('*.zsh.*')))
                self.shell("zsh_completion_tools=('../escape|kubectl completion zsh'); zsh-refresh-completions", success=False)
                self.assertFalse((cache.parent.parent / 'escape.zsh').exists())
                local_dir = self.home / '.zshrc.d'
                self.assertTrue(local_dir.is_dir())
                self.assertEqual(local_dir.stat().st_mode & 0o777, 0o700)
                first = local_dir / '10-machine.zsh'
                second = local_dir / '20-secrets.zsh'
                ignored = local_dir / 'README.txt'
                first.write_text('export LOCAL_LOAD_ORDER=machine\n')
                second.write_text('export LOCAL_LOAD_ORDER="${LOCAL_LOAD_ORDER}:secrets"\nexport PRIVATE_MARKER=kept\n')
                ignored.write_text('export SHOULD_NOT_LOAD=yes\n')
                local = self.home / '.zshrc.local'
                local.write_text('export LOCAL_LOAD_ORDER="${LOCAL_LOAD_ORDER}:legacy"\n')
                self.shell('[[ $LOCAL_LOAD_ORDER == machine:secrets:legacy && $PRIVATE_MARKER == kept && -z $SHOULD_NOT_LOAD ]]')

                # A setup rerun replaces .zshrc but leaves every local drop-in intact.
                before = {path.name: path.read_text() for path in (first, second, ignored)}
                self.generate(script)
                self.assertEqual(before, {path.name: path.read_text() for path in (first, second, ignored)})
                self.shell('[[ $LOCAL_LOAD_ORDER == machine:secrets:legacy && $PRIVATE_MARKER == kept ]]')
                (self.home / '.zshrc.local').unlink()
                (self.home / 'wt-generator').unlink(missing_ok=True)

    def test_installers_select_zsh(self):
        for script in ('setup-zsh-devops.sh', 'setup-zsh-devops-linux.sh'):
            text = (ROOT / script).read_text()
            self.assertIn('chsh -s "$ZSH_BIN"', text)
            self.assertNotIn('nushell', text.lower())

if __name__ == '__main__':
    unittest.main()
