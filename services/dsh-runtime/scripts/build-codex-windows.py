#!/usr/bin/env python3
"""Build the pinned Windows-only Codex compatibility patch; never use global Codex."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

VERSION = '0.132.0'
TOOLCHAIN = '1.93.0'
SOURCE_SHA256 = '770f09cd9a98f4145ddca1f26343c0c0602c622ec1ebb0e5c0457206ff1efa73'
RUNTIME = Path(__file__).resolve().parents[1]
PATCH = RUNTIME / 'native/windows/codex-appcontainer.patch'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def patch_bytes():
    # Windows checkout may use CRLF; the pinned source archive always uses LF.
    return PATCH.read_bytes().replace(b'\r\n', b'\n')


def find_cargo():
    cargo = shutil.which('cargo')
    if cargo:
        return cargo
    cargo_home = Path(os.environ.get('CARGO_HOME') or Path.home() / '.cargo')
    candidate = cargo_home / 'bin/cargo.exe'
    if candidate.is_file():
        return str(candidate)
    raise RuntimeError('Windows builder requires Rustup/Cargo for the build-runner account; '
                       'install Rustup, then run: rustup toolchain install 1.93.0 '
                       '--profile minimal --target x86_64-pc-windows-msvc. End users do not need Rust')


def cargo_environment(cargo):
    return {**os.environ, 'PATH': str(Path(cargo).parent) + os.pathsep + os.environ.get('PATH', '')}


def check_toolchain(cargo, env):
    try:
        subprocess.run([cargo, f'+{TOOLCHAIN}', '--version'], env=env, check=True,
                       capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError(f'Rust {TOOLCHAIN} is not ready for the build-runner account; run: '
                           f'rustup toolchain install {TOOLCHAIN} --profile minimal '
                           '--target x86_64-pc-windows-msvc') from error


def build(destination, cache):
    if sys.platform != 'win32':
        raise RuntimeError('Build this compatibility binary on Windows x64')
    patch = patch_bytes()
    identity = {'version': VERSION, 'variant': 'zhiban-appcontainer-1',
                'source_sha256': SOURCE_SHA256, 'patch_sha256': hashlib.sha256(patch).hexdigest(),
                'rust_toolchain': TOOLCHAIN, 'profile': 'release'}
    manifest = destination / 'build.json'
    binary = destination / 'codex.exe'
    if manifest.is_file() and binary.is_file() and all((destination / name).is_file() for name in ('LICENSE', 'NOTICE', 'compatibility.patch')):
        previous = json.loads(manifest.read_text())
        if (all(previous.get(k) == v for k, v in identity.items())
                and previous.get('binary_sha256') == digest(binary)
                and digest(destination / 'compatibility.patch') == identity['patch_sha256']):
            return previous
    cargo = find_cargo()
    env = cargo_environment(cargo)
    check_toolchain(cargo, env)
    cache.mkdir(parents=True, exist_ok=True)
    applied_patch = cache / f"compatibility-{identity['patch_sha256']}.patch"
    applied_patch.write_bytes(patch)
    archive = cache / f'codex-{VERSION}.tar.gz'
    if not archive.is_file() or digest(archive) != SOURCE_SHA256:
        temporary = archive.with_suffix('.download')
        with urllib.request.urlopen(f'https://codeload.github.com/openai/codex/tar.gz/refs/tags/rust-v{VERSION}', timeout=180) as source, temporary.open('wb') as target:
            shutil.copyfileobj(source, target)
        if digest(temporary) != SOURCE_SHA256:
            raise RuntimeError('Codex source checksum mismatch')
        temporary.replace(archive)
    assembly = cache / identity['patch_sha256'][:20]
    source = assembly / f'codex-rust-v{VERSION}'
    if not (assembly / '.patched').is_file():
        if source.exists():
            raise RuntimeError(f'Incomplete build source exists: {source}; inspect it before retrying')
        assembly.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(assembly, filter='data')
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', '--check', str(applied_patch)], cwd=source, check=True)
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', str(applied_patch)], cwd=source, check=True)
        # The release tag changes workspace.version but its lock still says 0.0.0.
        # Synchronize local package versions only; keep every external dependency locked.
        lock = source / 'codex-rs/Cargo.lock'
        chunks = lock.read_text().split('[[package]]')
        for index, chunk in enumerate(chunks):
            if '\nsource = ' not in chunk:
                chunks[index] = chunk.replace('version = "0.0.0"', f'version = "{VERSION}"')
        lock.write_text('[[package]]'.join(chunks), encoding='utf-8', newline='\n')
        (assembly / '.patched').write_text(identity['patch_sha256'])
    target = cache / 'target'
    env = {**env, 'CARGO_PROFILE_RELEASE_LTO': 'false',
           'CARGO_PROFILE_RELEASE_CODEGEN_UNITS': '16', 'CARGO_PROFILE_RELEASE_DEBUG': '0',
           'CARGO_TARGET_DIR': str(target)}
    env.setdefault('CARGO_BUILD_JOBS', '4')
    subprocess.run([cargo, f'+{TOOLCHAIN}', 'build', '--locked', '--release',
                    '--target', 'x86_64-pc-windows-msvc', '-p', 'codex-cli', '--bin', 'codex'],
                   cwd=source / 'codex-rs', env=env, check=True)
    built = target / 'x86_64-pc-windows-msvc/release/codex.exe'
    if patch_bytes() != patch:
        raise RuntimeError('Codex compatibility patch changed during compilation; rebuild before packaging')
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built, binary)
    shutil.copy2(source / 'LICENSE', destination / 'LICENSE')
    shutil.copy2(source / 'NOTICE', destination / 'NOTICE')
    (destination / 'compatibility.patch').write_bytes(patch)
    identity['binary_sha256'] = digest(binary)
    manifest.write_text(json.dumps(identity, indent=2) + '\n', encoding='utf-8')
    return identity


def main():
    if sys.version_info < (3, 12):
        raise RuntimeError('The Windows Codex source builder requires Python 3.12 or newer')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=RUNTIME / 'native/codex')
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.destination.resolve(), args.cache.resolve())))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'codex-builder : error ZB1001: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
