#!/usr/bin/env python3
"""Windows x64 build-time bundler. The installed app needs neither Python nor global Node."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from bundle_local_agent_macos import APP, PACKAGE, NODE_VERSION, digest, run

NODE_SHA256 = '57f71ab3652e797d84acddc79c81cc9ff1c6ddb2a1974cdb83f00fee9bff4c73'


def filesystem_path(path):
    """Use Win32 extended paths for deep npm trees without registry opt-in.

    Keep ordinary paths at subprocess boundaries (Node/tsc/CMake); only Python
    filesystem operations need the prefix. UNC shares use the documented UNC form.
    """
    path = os.path.abspath(path)
    if sys.platform != 'win32' or path.startswith('\\\\?\\'):
        return path
    if path.startswith('\\\\'):
        return '\\\\?\\UNC\\' + path[2:]
    return '\\\\?\\' + path


def copy_tree(source, destination):
    shutil.copytree(filesystem_path(source), filesystem_path(destination), symlinks=False)


def promote_stage(stage, destination):
    """Wait briefly for observed Windows rename contention; never replace a new target."""
    deadline = time.monotonic() + 10
    waited = False
    while True:
        try:
            stage.replace(destination)
            if waited:
                print('Windows runtime directory rename completed after waiting.', flush=True)
            return
        except OSError as error:
            remaining = deadline - time.monotonic()
            if (sys.platform != 'win32' or getattr(error, 'winerror', None) not in (5, 32)
                    or destination.exists() or remaining <= 0):
                raise
            if not waited:
                print(f'Windows runtime directory rename temporarily denied (WinError {error.winerror}); waiting up to 10 seconds.', flush=True)
                waited = True
            time.sleep(min(0.5, remaining))


def validate_checks(checks, allow_unavailable_codex=False):
    required = ['node', 'engine', 'office', 'isolation']
    if not allow_unavailable_codex:
        required.append('codex')
    failed = [key for key in required if checks.get(key) is not True]
    if failed:
        raise RuntimeError('packaged Windows runtime failed probes: ' + ', '.join(failed))
    if checks.get('codex') is not True:
        print('WARNING: Codex is unavailable (explicit packaging option). Runtime capability checks remain enabled.', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    parser.add_argument('--sandbox', type=Path, required=True)
    parser.add_argument('--path-addon', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'win32':
        raise RuntimeError('Windows packaging requires a Windows x64 builder')
    destination = args.destination.resolve()
    if destination.name != 'local-agent' or not args.sandbox.is_file() or not args.path_addon.is_file():
        raise RuntimeError('dedicated destination and compiled sandbox required')
    cache = APP / 'build/local-agent-bundle/windows-x64'
    cache.mkdir(parents=True, exist_ok=True)
    name = f'node-v{NODE_VERSION}-win-x64'
    archive = cache / (name + '.zip')
    if not archive.exists() or digest(archive) != NODE_SHA256:
        partial = archive.with_suffix('.download')
        try:
            with urllib.request.urlopen(f'https://nodejs.org/dist/v{NODE_VERSION}/{name}.zip', timeout=180) as source, partial.open('wb') as target:
                shutil.copyfileobj(source, target)
            if digest(partial) != NODE_SHA256:
                raise RuntimeError('Node archive checksum mismatch')
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    node_root = cache / name
    if not (node_root / 'node.exe').exists():
        with zipfile.ZipFile(archive) as source:
            source.extractall(filesystem_path(cache))
    node = node_root / 'node.exe'
    npm = node_root / 'node_modules/npm/bin/npm-cli.js'
    env = {**os.environ, 'PATH': str(node_root) + os.pathsep + os.environ.get('PATH', '')}
    arch = subprocess.check_output([node, '-p', 'process.arch'], env=env, text=True).strip()
    if arch != 'x64':
        raise RuntimeError('wrong Node architecture')
    lock = digest(PACKAGE / 'package-lock.json')
    dependencies = cache / ('dependencies-' + lock[:20])
    production = cache / ('production-' + lock[:20])
    # Windows needs the version-pinned AppContainer compatibility build. This is
    # a build-machine dependency only; users still receive a self-contained app.
    codex = cache / 'codex-appcontainer'
    run([sys.executable, PACKAGE / 'scripts/build-codex-windows.py',
         '--destination', codex, '--cache', os.environ.get('ZHIBAN_CODEX_BUILD_CACHE', str(cache / 'codex-source'))], env=env)
    for target, omit in [(dependencies, []), (production, ['--omit=dev'])]:
        if not (target / '.complete').exists():
            target.mkdir(exist_ok=True)
            for filename in ['package.json', 'package-lock.json']:
                shutil.copy2(PACKAGE / filename, target / filename)
            run([node, npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund', *omit], cwd=target, env=env)
            (target / '.complete').write_text(lock)
    # Compile source outside the checkout. TypeScript can use its installed compiler
    # via an absolute path; resolution needs the locked dependencies beside source.
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='assembly-', dir=cache) as assembly:
        assembly = Path(assembly)
        for filename in ['package.json', 'tsconfig.json', 'tsconfig.build.json']:
            shutil.copy2(PACKAGE / filename, assembly / filename)
        copy_tree(PACKAGE / 'src', assembly / 'src')
        # Junctions do not require Windows Developer Mode/admin symlink privileges.
        import _winapi
        _winapi.CreateJunction(str(dependencies / 'node_modules'), str(assembly / 'node_modules'))
        stage = Path(tempfile.mkdtemp(prefix='.local-agent-', dir=destination.parent))
        try:
            run([node, dependencies / 'node_modules/typescript/bin/tsc', '-p', assembly / 'tsconfig.build.json'], cwd=assembly, env=env)
            (stage / 'node').mkdir()
            shutil.copy2(node, stage / 'node/node.exe')
            shutil.copy2(node_root / 'LICENSE', stage / 'node/LICENSE')
            helper = stage / 'dsh-runtime'
            helper.mkdir()
            for filename in ['package.json', 'package-lock.json']:
                shutil.copy2(PACKAGE / filename, helper / filename)
            copy_tree(assembly / 'dist', helper / 'dist')
            copy_tree(PACKAGE / 'assets', helper / 'assets')
            copy_tree(production / 'node_modules', helper / 'node_modules')
            (helper / 'native').mkdir()
            shutil.copy2(args.sandbox, helper / 'native/zhiban-local-sandbox.exe')
            shutil.copy2(args.path_addon, helper / 'native/zhiban-windows-path.node')
            copy_tree(codex, helper / 'native/codex')
            report = json.loads(subprocess.check_output([stage / 'node/node.exe', helper / 'dist/desktop/main.js', '--self-check'], cwd=helper, env=env, text=True, timeout=120))
            validate_checks(report['checks'], os.environ.get('ZHIBAN_WINDOWS_ALLOW_UNAVAILABLE_CODEX') == '1')
            (stage / 'manifest.json').write_text(json.dumps({'version': 1, 'platform': 'win32', 'arch': 'x64', 'node': NODE_VERSION, 'dsh': '0.1.0-rc.8', 'codex_app_server': '0.132.0', 'codex_build': json.loads((codex / 'build.json').read_text()), 'checks': report['checks'], 'lock_sha256': lock}, indent=2) + '\n')
            if destination.exists():
                shutil.rmtree(filesystem_path(destination))
            promote_stage(stage, destination)
        finally:
            if stage.exists():
                shutil.rmtree(filesystem_path(stage))
            # Remove only the junction, never its target (cached dependencies).
            junction = assembly / 'node_modules'
            if junction.exists():
                junction.rmdir()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'local-agent-bundle : error ZB1002: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
