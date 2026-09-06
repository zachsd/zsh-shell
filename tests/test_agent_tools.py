"""Installer helper behavior; fake tools ensure no packages are installed."""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AgentInstallTests(unittest.TestCase):
    def test_npm_helpers(self):
        for script in ('setup-zsh-devops.sh', 'setup-zsh-devops-linux.sh'):
            source = (ROOT / script).read_text()
            helper = source[source.index('install_npm_cli() {'):source.index('\nif [[ ${ZSH_SETUP_CONFIG_ONLY', source.index('install_npm_cli() {'))]
            with self.subTest(script=script), tempfile.TemporaryDirectory(prefix='agent tools ') as temp:
                home = Path(temp)
                bindir = home / 'bin'; bindir.mkdir()
                for name, body in {
                    'node': 'exit "${NODE_RESULT:-0}"',
                    'npm': 'printf "%s\\n" "$@" > "$HOME/npm-args"; exit "${NPM_RESULT:-0}"',
                }.items():
                    path = bindir / name
                    path.write_text('#!/bin/sh\n' + body + '\n'); path.chmod(0o755)
                env = dict(os.environ, HOME=temp, PATH=f'{bindir}:/usr/bin:/bin')
                def run(extra='', code='install_npm_cli "@earendil-works/pi-coding-agent" pi 22 19', **overrides):
                    return subprocess.run(['/bin/bash','-c', 'log(){ :; }; warn(){ :; }; FAILED_PKGS=()\n'+helper+'\n'+extra+'\n'+code+'\nprintf "failures:%s\\n" "${FAILED_PKGS[*]}"'], env=dict(env,**overrides), capture_output=True,text=True,check=True)
                result = run()
                self.assertEqual(result.stdout.strip(), 'failures:')
                args = (home/'npm-args').read_text().splitlines()
                self.assertEqual(args, ['install','--global','--prefix',str(home/'.local'),'--ignore-scripts','--engine-strict','@earendil-works/pi-coding-agent'])
                (home/'npm-args').unlink()
                result = run(NODE_RESULT='1')
                self.assertIn('failures:@earendil-works/pi-coding-agent', result.stdout)
                self.assertFalse((home/'npm-args').exists())
                result = run(NPM_RESULT='1')
                self.assertIn('failures:@earendil-works/pi-coding-agent', result.stdout)
                (home/'npm-args').unlink()
                executable = home/'.local/bin/pi'; executable.parent.mkdir(parents=True)
                executable.write_text('#!/bin/sh\nexit 0\n'); executable.chmod(0o755)
                result = run(NODE_RESULT='1')
                self.assertEqual(result.stdout.strip(), 'failures:')
                self.assertFalse((home/'npm-args').exists())

    def test_linux_release_selection_and_unpack(self):
        source = (ROOT/'setup-zsh-devops-linux.sh').read_text()
        helper = source[source.index('install_github_release() {'):source.index('# Bounded parallel job pool')]
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp); bindir=base/'bin'; bindir.mkdir()
            # Exercise the real .tar.xz format used by Worktrunk releases.
            xz = shutil.which("xz")
            if not xz: self.skipTest("xz is required for release archive tests")
            (bindir/"xz").symlink_to(xz)
            payload=base/'payload'; payload.mkdir(); (payload/'wt').write_text('#!/bin/sh\nexit 0\n')
            subprocess.run(['tar','-cJf',str(base/'fixture.tar.xz'),'-C',str(payload),'wt'],check=True)
            stubs = {
              'curl': '''case "$*" in
                *api.github.com*) printf '%s\\n' '{"browser_download_url": "https://example.invalid/worktrunk-x86_64-unknown-linux-musl.tar.xz"}' ;;
                *) while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; cp "$FIXTURE" "$1"; break; fi; shift; done ;;
              esac''',
              'sudo': '[ "${INSTALL_FAIL:-0}" = 0 ] || exit 1; exec "$@"',
            }
            for name,body in stubs.items():
                p=bindir/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o755)
            env=dict(os.environ, PATH=f'{bindir}:/usr/bin:/bin',FIXTURE=str(base/'fixture.tar.xz'))
            command='log(){ :; }; warn(){ :; }; record_failure(){ echo "failure:$1"; };\n'+helper+'\ninstall_github_release max-sixty/worktrunk "worktrunk-x86_64-unknown-linux-musl\\.tar\\.xz$" "$DEST" Worktrunk'
            result=subprocess.run(['/bin/bash','-c',command],env=dict(env,DEST=str(base/'wt')),capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(os.access(base/'wt',os.X_OK))
            result=subprocess.run(['/bin/bash','-c',command],env=dict(env,DEST=str(base/'failed'),INSTALL_FAIL='1'),capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('failure:Worktrunk',result.stdout)

if __name__ == '__main__': unittest.main()
