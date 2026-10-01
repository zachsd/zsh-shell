"""Exercise the installed revision checker without network access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
UPDATER = ROOT / 'bin/zsh-shell-update'
OLD_COMMIT = '1' * 40
NEW_COMMIT = '2' * 40


class UpdateCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zsh-shell-update-test-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.state = self.home / 'state/zsh-shell'
        self.state.mkdir(parents=True)
        (self.state / 'installed-commit').write_text(OLD_COMMIT + '\n')
        (self.state / 'repository').write_text('zachsd/zsh-shell\n')
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_STATE_HOME=str(self.home / 'state'),
                        PATH=f'{self.bin}:/usr/bin:/bin')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def test_available_update_runs_platform_installer(self):
        self.stub('gh', f'''
case "$1 $2" in
  "api repos/zachsd/zsh-shell/commits/main") echo {NEW_COMMIT} ;;
  "repo clone")
    destination="$4"
    mkdir -p "$destination"
    for script in setup-zsh-devops.sh setup-zsh-devops-linux.sh; do
      printf '%s\n' '#!/bin/sh' 'printf "%s:%s\\n" "$ZSH_SETUP_COMMIT" "$ZSH_SETUP_REPO" > "$HOME/applied-update"' > "$destination/$script"
      chmod 755 "$destination/$script"
    done
    ;;
  *) exit 1 ;;
esac''')
        self.stub('git', f'''case "$*" in *"rev-parse HEAD"*) echo {NEW_COMMIT};; *) exit 1;; esac''')
        result = subprocess.run([str(UPDATER), '--yes'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.state / 'installed-commit').read_text(), NEW_COMMIT + '\n')
        self.assertEqual((self.home / 'applied-update').read_text(),
                         f'{NEW_COMMIT}:zachsd/zsh-shell\n')
        self.assertIn('Update complete', result.stdout)

    def test_recent_check_avoids_network(self):
        (self.state / 'last-check').write_text(str(int(__import__('time').time())) + '\n')
        self.stub('gh', 'echo called > "$HOME/network-called"; exit 1')
        result = subprocess.run([str(UPDATER), '--check'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / 'network-called').exists())


if __name__ == '__main__':
    unittest.main()
