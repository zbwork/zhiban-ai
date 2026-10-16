"""Exercise the real Windows CMake directory scopes without a Windows SDK.

Flutter/native sources are placeholders: this validates configure/generate only,
not MSVC compilation, bundling, or sandbox execution.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


APP = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cmake'), 'CMake is required')
class WindowsCMake(unittest.TestCase):
    def test_local_agent_post_build_configures_with_runner_target(self):
        with tempfile.TemporaryDirectory(prefix='zhiban cmake ') as temporary:
            root = Path(temporary)
            windows = root / 'apps/zhiban-app/windows'
            runner = windows / 'runner'
            flutter = windows / 'flutter'
            native = root / 'services/dsh-runtime/native/windows'
            for directory in (runner, flutter, native):
                directory.mkdir(parents=True)

            # Keep both production CMakeLists unchanged so a cross-directory
            # POST_BUILD registration reproduces the actual configure failure.
            for relative in ('CMakeLists.txt', 'runner/CMakeLists.txt'):
                shutil.copy2(APP / 'windows' / relative, windows / relative)

            (flutter / 'CMakeLists.txt').write_text('''
add_library(flutter INTERFACE)
add_library(flutter_wrapper_app INTERFACE)
add_custom_target(flutter_assemble)
set(FLUTTER_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/flutter.dll" PARENT_SCOPE)
set(FLUTTER_ICU_DATA_FILE "${CMAKE_CURRENT_SOURCE_DIR}/icudtl.dat" PARENT_SCOPE)
set(AOT_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/app.so" PARENT_SCOPE)
set(PROJECT_BUILD_DIR "${CMAKE_BINARY_DIR}/" PARENT_SCOPE)
''')
            (flutter / 'generated_plugins.cmake').write_text('')
            (flutter / 'generated_plugin_registrant.cc').write_text('')
            for filename in (
                'flutter_window.cpp', 'main.cpp', 'utils.cpp',
                'win32_window.cpp', 'Runner.rc', 'runner.exe.manifest',
            ):
                (runner / filename).write_text('')
            (native / 'CMakeLists.txt').write_text('''
add_executable(zhiban-local-sandbox sandbox.cpp)
add_library(zhiban-windows-path SHARED sandbox.cpp)
''')
            (native / 'sandbox.cpp').write_text('int main() { return 0; }\n')

            result = subprocess.run(
                ['cmake', '-S', str(windows), '-B', str(root / 'build'),
                 f'-DDINGRTC_WINDOWS_SDK_DIR={root / "unused-sdk"}',
                 f'-DWINSPARKLE_DIR={root / "unused-sdk"}'],
                capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
