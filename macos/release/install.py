#!/usr/bin/env python3
"""Install a verified personal macOS build; keep versions for rollback."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

LABEL = 'com.akitaonrails.ai-usagebar-menubar'
DOMAIN = 'ai-usagebar-menubar'
BINARIES = ('ai-usagebar', 'ai-usagebar-tui', 'ai-usagebar-menubar')

def activate(root, target, start):
    if not start:
        print(f'Staged {target.name}: {target}. Active version and login settings unchanged.')
        return
    current = root / 'current'
    if current.exists() and not current.is_symlink():
        raise RuntimeError(f'Refusing to replace non-symlink {current}')
    previous_link = os.readlink(current) if current.is_symlink() else None
    previous = current.resolve() if current.exists() else None
    plist = Path.home() / 'Library' / 'LaunchAgents' / f'{LABEL}.plist'
    old_plist = plist.read_bytes() if plist.exists() else None
    service = f'gui/{os.getuid()}/{LABEL}'
    pref = subprocess.run(['defaults', 'read', DOMAIN, 'binaryPath'], capture_output=True, text=True)
    old_pref = pref.stdout.rstrip('\n') if pref.returncode == 0 else None
    was_loaded = subprocess.run(['launchctl', 'print', service],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    disabled = subprocess.run(['launchctl', 'print-disabled', f'gui/{os.getuid()}'],
        capture_output=True, text=True)
    was_disabled = bool(re.search(r'"' + re.escape(LABEL) + r'"\s*=>\s*(?:true|disabled)', disabled.stdout))
    # First personal install enables login launch. Later updates preserve both
    # ways the user can disable it: removing its plist or launchctl disable.
    login_enabled = previous is None or (old_plist is not None and not was_disabled)
    backup = root / 'backups'
    backup.mkdir(parents=True, exist_ok=True)
    if old_plist is not None:
        fd, saved = tempfile.mkstemp(prefix='launch-agent-', suffix='.plist', dir=backup)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(old_plist)

    def replace_link(destination):
        staging_link = root / 'current.next'
        if staging_link.is_symlink():
            staging_link.unlink()
        staging_link.symlink_to(destination, target_is_directory=True)
        staging_link.replace(current)

    try:
        subprocess.run(['launchctl', 'bootout', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        replace_link(target)
        subprocess.run(['defaults', 'write', DOMAIN, 'binaryPath', '-string', str(current / 'ai-usagebar')], check=True)
        if old_plist is not None or login_enabled:
            plist.parent.mkdir(parents=True, exist_ok=True)
            data = {'Label': LABEL, 'ProgramArguments': [str(current / 'ai-usagebar-menubar')],
                    'RunAtLoad': True, 'ProcessType': 'Interactive'}
            fd, tmp = tempfile.mkstemp(prefix='.ai-usagebar-', dir=plist.parent)
            with os.fdopen(fd, 'wb') as stream:
                plistlib.dump(data, stream)
            os.replace(tmp, plist)
        if login_enabled:
            subprocess.run(['launchctl', 'enable', service], check=True)
            subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(plist)], check=True)
        else:
            print('Login launch remains disabled. Quit any running copy, then reopen:')
            print(current / 'ai-usagebar-menubar')
    except Exception:
        subprocess.run(['launchctl', 'bootout', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if previous_link is not None:
            replace_link(previous_link)
        elif current.is_symlink():
            current.unlink()
        if old_plist is not None:
            plist.write_bytes(old_plist)
        elif plist.exists():
            plist.unlink()
        if old_pref is not None:
            subprocess.run(['defaults', 'write', DOMAIN, 'binaryPath', '-string', old_pref], check=True)
        else:
            subprocess.run(['defaults', 'delete', DOMAIN, 'binaryPath'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['launchctl', 'disable' if was_disabled else 'enable', service], check=True)
        if was_loaded and old_plist is not None:
            subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(plist)], check=True)
        raise
    if previous and previous != target:
        (root / 'previous-version').write_text(previous.name + '\n')
    print(f'Installed {target.name}: {current}')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-start', action='store_true')
    parser.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    root = Path.home() / '.local' / 'share' / 'ai-usagebar'
    root.mkdir(parents=True, exist_ok=True)
    if args.rollback:
        version = (root / 'previous-version').read_text().strip()
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', version):
            raise RuntimeError('Invalid rollback version')
        target = root / 'versions' / version
        if not all((target / name).is_file() for name in BINARIES):
            raise RuntimeError('Previous version is incomplete')
    else:
        source = Path(__file__).resolve().parent
        version = (source / 'VERSION').read_text().strip()
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', version):
            raise RuntimeError('Invalid package version')
        checksums = {}
        for line in (source / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split(None, 1)
            checksums[name.lstrip('*')] = digest
        for name in BINARIES:
            if hashlib.sha256((source / name).read_bytes()).hexdigest() != checksums.get(name):
                raise RuntimeError(f'Checksum mismatch: {name}')
        reported = subprocess.check_output([str(source / 'ai-usagebar'), '--version'], text=True).strip()
        if reported != f'ai-usagebar {version}':
            raise RuntimeError('Version mismatch')
        versions = root / 'versions'
        versions.mkdir(exist_ok=True)
        target = versions / version
        if target.exists():
            for name in BINARIES:
                if hashlib.sha256((target / name).read_bytes()).hexdigest() != checksums[name]:
                    raise RuntimeError('Installed version differs; publish a new version instead')
        else:
            stage = Path(tempfile.mkdtemp(prefix='.install-', dir=versions))
            try:
                for name in (*BINARIES, 'install.py', 'VERSION', 'SHA256SUMS'):
                    shutil.copy2(source / name, stage / name)
                for name in BINARIES:
                    (stage / name).chmod(0o755)
                stage.rename(target)
            finally:
                if stage.exists():
                    shutil.rmtree(stage)
    activate(root, target, not args.no_start)

if __name__ == '__main__':
    main()
