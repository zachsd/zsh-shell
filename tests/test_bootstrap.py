import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
class BootstrapTests(unittest.TestCase):
    def test_downloads_shared_config_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); bindir=root/'bin';bindir.mkdir()
            stubs={
              'uname': 'case "$1" in -s) echo Darwin;; *) echo arm64;; esac',
              'curl': '''url="$2"; dest="$4"
                case "$url" in
                  */shell/*) file="shell/${url##*/}" ;;
                  *) file="${url##*/}" ;;
                esac
                cp "$SOURCE/$file" "$dest"''',
              'bash': '''folder=$(dirname "$1")
                for file in configure-nushell.nu shell/env.nu shell/config.nu shell/aliases.nu shell/starship.toml; do
                  test -s "$folder/$file" || exit 42
                done
                echo bundle-ready''',
            }
            for name,body in stubs.items():
                p=bindir/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o755)
            env=dict(os.environ,PATH=str(bindir)+':/usr/bin:/bin',SOURCE=str(ROOT))
            r=subprocess.run(['/bin/sh',str(ROOT/'install.sh'),'--yes'],env=env,stdin=subprocess.DEVNULL,capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('bundle-ready',r.stdout)
if __name__=='__main__': unittest.main()
