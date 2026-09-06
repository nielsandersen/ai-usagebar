import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.root = self.home / 'installation'
        self.old = self.root / 'versions' / 'old'
        self.new = self.root / 'versions' / 'new'
        self.old.mkdir(parents=True)
        self.new.mkdir()
        (self.root / 'current').symlink_to(self.old)
        self.plist = self.home / 'Library' / 'LaunchAgents' / f'{installer.LABEL}.plist'
        self.plist.parent.mkdir(parents=True)
        self.old_plist = plistlib.dumps({'Label': installer.LABEL, 'RunAtLoad': True,
                                        'ProgramArguments': [str(self.old / 'ai-usagebar-menubar')]})
        self.plist.write_bytes(self.old_plist)
        self.calls = []

    def command(self, args, **kwargs):
        self.calls.append(args)
        if args[:2] == ['defaults', 'read']:
            return subprocess.CompletedProcess(args, 0, str(self.old / 'ai-usagebar') + '\n')
        if args[:2] == ['launchctl', 'print-disabled']:
            return subprocess.CompletedProcess(args, 0, '{}')
        return subprocess.CompletedProcess(args, 0, '')

    def test_failed_activation_restores_old_link_plist_and_preferences(self):
        def fail_new_defaults(args, **kwargs):
            if args[:2] == ['defaults', 'write'] and args[-1] == str(self.root / 'current' / 'ai-usagebar'):
                raise subprocess.CalledProcessError(1, args)
            return self.command(args, **kwargs)
        with patch.object(Path, 'home', return_value=self.home), patch.object(installer.subprocess, 'run', side_effect=fail_new_defaults):
            with self.assertRaises(subprocess.CalledProcessError):
                installer.activate(self.root, self.new, True)
        self.assertEqual((self.root / 'current').resolve(), self.old)
        self.assertEqual(self.plist.read_bytes(), self.old_plist)
        self.assertTrue(any(c[:2] == ['defaults','write'] and c[-1] == str(self.old / 'ai-usagebar') for c in self.calls))
        self.assertTrue(any(c[:2] == ['launchctl','bootstrap'] for c in self.calls))

    def test_no_start_does_not_change_active_installation_or_login(self):
        with patch.object(Path, 'home', return_value=self.home), patch.object(installer.subprocess, 'run', side_effect=self.command):
            installer.activate(self.root, self.new, False)
        self.assertEqual((self.root / 'current').resolve(), self.old)
        self.assertEqual(self.plist.read_bytes(), self.old_plist)
        self.assertEqual(self.calls, [])

    def test_update_preserves_removed_login_agent(self):
        self.plist.unlink()
        with patch.object(Path, 'home', return_value=self.home), patch.object(installer.subprocess, 'run', side_effect=self.command), patch.object(installer.subprocess, 'Popen') as app:
            installer.activate(self.root, self.new, True)
        self.assertFalse(self.plist.exists())
        self.assertFalse(any(c[:2] == ['launchctl','enable'] for c in self.calls))
        app.assert_not_called()

    def test_update_preserves_launchctl_disabled_login(self):
        def disabled(args, **kwargs):
            if args[:2] == ['launchctl', 'print-disabled']:
                return subprocess.CompletedProcess(args, 0, '"' + installer.LABEL + '" => disabled')
            return self.command(args, **kwargs)
        with patch.object(Path, 'home', return_value=self.home), patch.object(installer.subprocess, 'run', side_effect=disabled), patch.object(installer.subprocess, 'Popen') as app:
            installer.activate(self.root, self.new, True)
        self.assertTrue(self.plist.exists())
        self.assertFalse(any(c[:2] == ['launchctl','enable'] for c in self.calls))
        app.assert_not_called()

if __name__ == '__main__':
    unittest.main()
