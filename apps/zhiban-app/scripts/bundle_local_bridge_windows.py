#!/usr/bin/env python3
"""Build and probe the F31 companion. Go/Python are build-time dependencies only."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile


BRIDGE = Path(__file__).resolve().parents[2] / 'zhiban-local-bridge'


def verify(executable):
    with executable.open('rb') as binary:
        if binary.read(2) != b'MZ':
            raise ValueError('Bridge is not a Windows executable')
        binary.seek(0x3c)
        offset = struct.unpack('<I', binary.read(4))[0]
        binary.seek(offset)
        if binary.read(6) != b'PE\0\0\x64\x86':
            raise ValueError('Bridge must be Windows x64')
    request = {'jsonrpc': '2.0', 'id': 'package-probe', 'method': 'initialize',
               'params': {'protocol_version': '1.0', 'app_version': '1.0.0',
                          'platform': 'windows', 'arch': 'x64'}}
    # No tool discovery, credential writes, or real user configuration access.
    with tempfile.TemporaryDirectory(prefix='zhiban bridge probe ') as temporary:
        root = Path(temporary)
        system = Path(os.environ['SystemRoot'])
        env = {'SystemRoot': str(system), 'WINDIR': str(system),
               'PATH': str(system / 'System32'), 'COMSPEC': str(system / 'System32/cmd.exe'),
               'USERPROFILE': str(root), 'HOME': str(root),
               'APPDATA': str(root / 'AppData/Roaming'),
               'LOCALAPPDATA': str(root / 'AppData/Local'),
               'TEMP': str(root), 'TMP': str(root)}
        result = subprocess.run([str(executable)], input=json.dumps(request) + '\n',
                                capture_output=True, text=True, encoding='utf-8',
                                env=env, cwd=root, timeout=30, check=True)
        response = json.loads(result.stdout)
        payload = response.get('result', {})
        if (response.get('jsonrpc') != '2.0' or response.get('id') != request['id']
                or 'error' in response or payload.get('protocol_version') != '1.0'
                or not payload.get('bridge_version')
                or 'tool.detect' not in payload.get('supported_methods', [])):
            raise ValueError('Bridge Windows x64 initialize probe failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--go', default='go')
    parser.add_argument('--version', default='0.3.0-dev')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    if args.verify_only:
        verify(output)
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        # Validate before replacing a previously working binary. Always invoke
        # Go so source/vendor changes are not missed by CMake's C++ relink rules.
        with tempfile.TemporaryDirectory(prefix='bridge-build-', dir=output.parent) as temporary:
            executable = Path(temporary) / 'zhiban-local-bridge.exe'
            env = dict(os.environ, GOOS='windows', GOARCH='amd64', CGO_ENABLED='0')
            subprocess.run([args.go, 'build', '-trimpath', '-buildvcs=false', '-mod=vendor',
                            '-ldflags', f'-X main.bridgeVersion={args.version}',
                            '-o', str(executable), './cmd/zhiban-local-bridge'],
                           cwd=BRIDGE, env=env, check=True)
            verify(executable)
            # Avoid disturbing a running helper when the build is identical.
            if not output.exists() or output.read_bytes() != executable.read_bytes():
                executable.replace(output)
    print('Local coding Bridge: Windows x64 build/protocol verified')


if __name__ == '__main__':
    main()
