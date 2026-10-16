"""Real filesystem regression for deep, non-ASCII npm dependency paths."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from bundle_local_agent_windows import copy_tree, filesystem_path, promote_stage, validate_checks


class WindowsBundlePromotion(unittest.TestCase):
    def failure(self, code):
        error = OSError('rename failed')
        error.winerror = code
        return error

    def test_transient_windows_refusal_recovers(self):
        for code in (5, 32):
            with self.subTest(code=code):
                stage, destination = Mock(), Mock()
                destination.exists.return_value = False
                stage.replace.side_effect = [self.failure(code), None]
                with patch('bundle_local_agent_windows.sys.platform', 'win32'), patch('bundle_local_agent_windows.time.sleep') as sleep:
                    promote_stage(stage, destination)
                self.assertEqual(stage.replace.call_count, 2)
                sleep.assert_called_once()

    def test_persistent_refusal_raises_original_error_at_deadline(self):
        stage, destination = Mock(), Mock()
        destination.exists.return_value = False
        error = self.failure(5)
        stage.replace.side_effect = error
        with patch('bundle_local_agent_windows.sys.platform', 'win32'), patch('bundle_local_agent_windows.time.monotonic', side_effect=[0, 0, 10]), patch('bundle_local_agent_windows.time.sleep'):
            with self.assertRaises(OSError) as caught:
                promote_stage(stage, destination)
        self.assertIs(caught.exception, error)
        self.assertEqual(stage.replace.call_count, 2)

    def test_other_errors_platforms_and_new_targets_fail_without_waiting(self):
        for platform, code, exists in [('win32', 2, False), ('linux', 5, False), ('win32', 5, True)]:
            with self.subTest(platform=platform, code=code, exists=exists):
                stage, destination = Mock(), Mock()
                destination.exists.return_value = exists
                error = self.failure(code)
                stage.replace.side_effect = error
                with patch('bundle_local_agent_windows.sys.platform', platform), patch('bundle_local_agent_windows.time.sleep') as sleep:
                    with self.assertRaises(OSError) as caught:
                        promote_stage(stage, destination)
                self.assertIs(caught.exception, error)
                stage.replace.assert_called_once_with(destination)
                sleep.assert_not_called()


class WindowsBundleChecks(unittest.TestCase):
    def test_failure_is_visible_in_non_verbose_flutter_build(self):
        script = Path(__file__).with_name('bundle_local_agent_windows.py')
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(script), str(Path(directory) / 'invalid'),
                                     '--sandbox', str(Path(directory) / 'missing.exe'),
                                     '--path-addon', str(Path(directory) / 'missing.node')],
                                    capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertRegex(result.stderr, r':\s*error ZB1002: ')

    def test_default_requires_codex(self):
        checks = dict.fromkeys(['node', 'engine', 'office', 'isolation', 'codex'], True)
        validate_checks(checks)
        checks['codex'] = False
        with self.assertRaisesRegex(RuntimeError, 'codex'):
            validate_checks(checks)

    def test_explicit_test_package_retains_basic_and_isolation_checks(self):
        checks = dict.fromkeys(['node', 'engine', 'office', 'isolation'], True)
        checks['codex'] = False
        validate_checks(checks, allow_unavailable_codex=True)
        self.assertFalse(checks['codex'])
        for key in ['node', 'engine', 'office', 'isolation']:
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, key):
                validate_checks({**checks, key: False}, allow_unavailable_codex=True)


@unittest.skipUnless(sys.platform == 'win32', 'Windows filesystem required')
class WindowsBundlePaths(unittest.TestCase):
    def test_copies_and_removes_deep_dependency_tree(self):
        with tempfile.TemporaryDirectory(prefix='zhiban bundle ') as temporary:
            root = Path(temporary)
            source = root / '源 dependencies'
            destination = root / '安装目录 with spaces'
            relative = Path(*(['nested-package-name-0123456789'] * 10)) / '模块.js'
            original = Path(filesystem_path(source / relative))
            original.parent.mkdir(parents=True)
            original.write_bytes(b'export const intact = true;\n')
            self.assertGreater(len(str(destination / relative)), 260)
            try:
                copy_tree(source, destination)
                self.assertEqual(Path(filesystem_path(destination / relative)).read_bytes(), original.read_bytes())
            finally:
                shutil.rmtree(filesystem_path(source))
                if destination.exists():
                    shutil.rmtree(filesystem_path(destination))

    def test_preserves_extended_paths_and_formats_unc(self):
        self.assertEqual(filesystem_path(r'\\?\C:\bundle'), r'\\?\C:\bundle')
        self.assertEqual(filesystem_path(r'\\server\share\bundle'), r'\\?\UNC\server\share\bundle')


if __name__ == '__main__':
    unittest.main()
