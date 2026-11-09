"""Cache trust checks; no network, compiler or user configuration is required."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('codex_builder', Path(__file__).with_name('build-codex-windows.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class CodexBuildCache(unittest.TestCase):
    def test_reuses_only_matching_identity_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            bundle.mkdir()
            binary = bundle / 'codex.exe'
            binary.write_bytes(b'fixture')
            (bundle / 'LICENSE').write_text('fixture license')
            (bundle / 'NOTICE').write_text('fixture attribution')
            (bundle / 'compatibility.patch').write_bytes(builder.PATCH.read_bytes())
            identity = {'version': builder.VERSION, 'variant': 'zhiban-appcontainer-1',
                        'source_sha256': builder.SOURCE_SHA256,
                        'patch_sha256': builder.digest(builder.PATCH),
                        'rust_toolchain': builder.TOOLCHAIN, 'profile': 'release',
                        'binary_sha256': builder.digest(binary)}
            manifest = bundle / 'build.json'
            manifest.write_text(json.dumps(identity))
            with patch.object(builder.sys, 'platform', 'win32'), patch.object(builder.shutil, 'which', return_value=None), patch.object(builder.Path, 'home', return_value=root), patch.dict(builder.os.environ, {}, clear=True):
                self.assertEqual(builder.build(bundle, root / 'cache'), identity)
                self.assertFalse((root / 'cache').exists())
                for key in ['version', 'variant', 'source_sha256', 'patch_sha256', 'rust_toolchain', 'profile', 'binary_sha256']:
                    with self.subTest(key=key):
                        manifest.write_text(json.dumps({**identity, key: 'changed'}))
                        with self.assertRaisesRegex(RuntimeError, 'requires Rustup'):
                            builder.build(bundle, root / 'cache')
                manifest.write_text(json.dumps(identity))
                binary.write_bytes(b'changed')
                with self.assertRaisesRegex(RuntimeError, 'requires Rustup'):
                    builder.build(bundle, root / 'cache')


class CodexBuildTools(unittest.TestCase):
    def test_crlf_checkout_patch_applies_to_lf_source(self):
        original = b'--- a/source.txt\n+++ b/source.txt\n@@ -1 +1 @@\n-old\n+new\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patch_file = root / 'checkout.patch'
            source = root / 'source.txt'
            patch_file.write_bytes(original.replace(b'\n', b'\r\n'))
            source.write_bytes(b'old\n')
            with patch.object(builder, 'PATCH', patch_file):
                canonical = builder.patch_bytes()
            self.assertEqual(canonical, original)
            applied = root / 'applied.patch'
            applied.write_bytes(canonical)
            subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', str(applied)], cwd=root, check=True)
            self.assertEqual(source.read_bytes(), b'new\n')

    def test_default_rustup_install_is_found_with_restricted_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cargo = root / '.cargo/bin/cargo.exe'
            cargo.parent.mkdir(parents=True)
            cargo.touch()
            with patch.object(builder.Path, 'home', return_value=root), patch.object(builder.shutil, 'which', return_value=None), patch.dict(builder.os.environ, {'PATH': 'system-only'}, clear=True):
                self.assertEqual(builder.find_cargo(), str(cargo))
                self.assertEqual(builder.cargo_environment(str(cargo))['PATH'], str(cargo.parent) + os.pathsep + 'system-only')
                # An explicit installation root must not silently select another one.
                with patch.dict(builder.os.environ, {'CARGO_HOME': str(root / 'missing')}):
                    with self.assertRaisesRegex(RuntimeError, 'requires Rustup'):
                        builder.find_cargo()

    def test_custom_cargo_home_and_missing_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            cargo = Path(directory) / 'bin/cargo.exe'
            cargo.parent.mkdir()
            cargo.touch()
            with patch.object(builder.shutil, 'which', return_value=None), patch.dict(builder.os.environ, {'CARGO_HOME': directory}, clear=True):
                self.assertEqual(builder.find_cargo(), str(cargo))
            with patch.object(builder.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'cargo')):
                with self.assertRaisesRegex(RuntimeError, 'rustup toolchain install 1.93.0'):
                    builder.check_toolchain(str(cargo), {})

    @unittest.skipUnless(sys.platform == 'win32', 'Windows builder diagnostic')
    def test_missing_cargo_error_survives_flutter_error_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, 'PATH': '', 'CARGO_HOME': directory}
            result = subprocess.run([sys.executable, str(Path(builder.__file__)),
                                     '--cache', str(Path(directory) / 'cache'),
                                     '--destination', str(Path(directory) / 'bundle')],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 1)
            self.assertRegex(result.stderr, r':\s*error ZB1001: .*requires Rustup')
            self.assertTrue(re.search(r'(:\s*(?:warning|(?:fatal )?error).*?:)', result.stderr))
            self.assertFalse((Path(directory) / 'cache').exists())


if __name__ == '__main__':
    unittest.main()
