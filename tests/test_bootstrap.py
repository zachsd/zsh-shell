import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BootstrapTests(unittest.TestCase):
    def test_downloads_starship_theme_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / 'bin'
            bindir.mkdir()
            stubs = {
                'uname': 'case "$1" in -s) echo Darwin;; *) echo arm64;; esac',
                'curl': '''url="$2"; dest="$4"
                    case "$url" in
                      */shell/*) file="shell/${url##*/}" ;;
                      */bin/*) file="bin/${url##*/}" ;;
                      *) file="${url##*/}" ;;
                    esac
                    cp "$SOURCE/$file" "$dest"''',
                'bash': '''folder=$(dirname "$1")
                    test -s "$folder/setup-zsh-devops.sh" || exit 41
                    test -s "$folder/shell/starship.toml" || exit 42
                    test -s "$folder/bin/zsh-shell-update" || exit 43
                    test "$ZSH_SETUP_COMMIT" = 2222222222222222222222222222222222222222 || exit 44
                    echo bundle-ready''',
            }
            for name, body in stubs.items():
                path = bindir / name
                path.write_text('#!/bin/sh\n' + body + '\n')
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(bindir) + ':/usr/bin:/bin', SOURCE=str(ROOT),
                       ZSH_SETUP_COMMIT='2' * 40)
            result = subprocess.run(
                ['/bin/sh', str(ROOT / 'install.sh'), '--yes'],
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('bundle-ready', result.stdout)


if __name__ == '__main__':
    unittest.main()
