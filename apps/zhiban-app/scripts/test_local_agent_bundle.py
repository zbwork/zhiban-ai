import importlib.util
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location('bundle', Path(__file__).with_name('bundle_local_agent_macos.py'))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class Architectures(unittest.TestCase):
    def test_single_and_universal(self):
        self.assertEqual(bundle.target_architectures({}, 'arm64'), ['arm64'])
        self.assertEqual(bundle.target_architectures({}, 'x86_64'), ['x64'])
        self.assertEqual(bundle.target_architectures({'ARCHS': 'x86_64 arm64'}, 'arm64'), ['arm64', 'x64'])
        self.assertEqual(bundle.target_architectures({'ARCHS': 'arm64 x86_64 arm64'}, 'x86_64'), ['arm64', 'x64'])

    def test_active_debug_architecture(self):
        self.assertEqual(bundle.target_architectures({'ARCHS': 'arm64 x86_64', 'ONLY_ACTIVE_ARCH': 'YES'}, 'arm64'), ['arm64'])
        self.assertEqual(bundle.target_architectures({'ARCHS': 'arm64 x86_64', 'ONLY_ACTIVE_ARCH': 'YES'}, 'x86_64'), ['x64'])

    def test_explicit_intel_debug_target_is_not_replaced_with_arm(self):
        self.assertEqual(bundle.target_architectures({'ARCHS': 'x86_64', 'ONLY_ACTIVE_ARCH': 'YES'}, 'arm64'), ['x64'])

    def test_invalid_target_fails_before_writing(self):
        for target in ['', 'i386', 'arm64 i386', '$(ARCHS_STANDARD)']:
            with self.assertRaises(RuntimeError):
                bundle.target_architectures({'ARCHS': target}, 'arm64')


class PtyPrebuilds(unittest.TestCase):
    def test_keeps_only_target_without_mutating_other_runtime(self):
        for target in ['arm64', 'x64']:
            with tempfile.TemporaryDirectory() as tmp:
                helper = Path(tmp)
                prebuilds = helper / 'node_modules/node-pty/prebuilds'
                for arch in ['darwin-arm64', 'darwin-x64', 'linux-x64']:
                    folder = prebuilds / arch
                    folder.mkdir(parents=True)
                    for name in ['pty.node', 'spawn-helper']:
                        (folder / name).write_bytes(b'fixture')
                bundle.prune_pty_prebuilds(helper, target)
                self.assertEqual([p.name for p in prebuilds.iterdir()], [f'darwin-{target}'])
                self.assertEqual((prebuilds / f'darwin-{target}' / 'pty.node').read_bytes(), b'fixture')

    def test_missing_target_fails_without_removing_other_architecture(self):
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp)
            foreign = helper / 'node_modules/node-pty/prebuilds/darwin-x64'
            foreign.mkdir(parents=True)
            with self.assertRaisesRegex(RuntimeError, 'Missing target'):
                bundle.prune_pty_prebuilds(helper, 'arm64')
            self.assertTrue(foreign.exists())


if __name__ == '__main__':
    unittest.main()
