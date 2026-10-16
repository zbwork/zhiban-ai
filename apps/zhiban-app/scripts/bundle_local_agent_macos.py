#!/usr/bin/env python3
"""Bundle the pinned local helper before Xcode signs Runner; no global Node dependency."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

SELF_CHECK_TIMEOUT_SECONDS = int(os.environ.get("LOCAL_AGENT_SELF_CHECK_TIMEOUT_SECONDS", "120"))

NODE_VERSION = "24.19.0"
NODE_HASHES = {
    "arm64": "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d",
    "x64": "d1b5e999db158c62fe8f7267a4476b035d8bd93b1a605bac24a3f0dd166e3316",
}
APP = Path(__file__).resolve().parents[1]
PACKAGE = APP.parents[1] / "services/dsh-runtime"


def run(argv, **kwargs):
    subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def target_architectures(environment, machine):
    native = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x64"}.get(machine)
    if native not in NODE_HASHES:
        raise RuntimeError("unsupported build architecture")
    requested = environment.get("ARCHS", "arm64" if native == "arm64" else "x86_64").split()
    if environment.get("ONLY_ACTIVE_ARCH") == "YES" and len(set(requested)) > 1:
        requested = ["arm64" if native == "arm64" else "x86_64"]
    mapping = {"arm64": "arm64", "x86_64": "x64"}
    if not requested or any(value not in mapping for value in requested):
        raise RuntimeError("unsupported target architecture")
    return sorted({mapping[value] for value in requested})


def prune_pty_prebuilds(helper, arch):
    if arch not in NODE_HASHES:
        raise RuntimeError("unsupported node-pty architecture")
    prebuilds = helper / "node_modules/node-pty/prebuilds"
    target = prebuilds / f"darwin-{arch}"
    for name in ["pty.node", "spawn-helper"]:
        if not (target / name).is_file():
            raise RuntimeError(f"Missing target node-pty prebuild: {target / name}")
    for candidate in prebuilds.iterdir():
        if candidate.name != target.name:
            if candidate.is_symlink() or candidate.is_file():
                candidate.unlink()
            else:
                shutil.rmtree(candidate)


def bundle_arch(arch, destination, package=PACKAGE):
    cache = APP / "build/local-agent-bundle" / arch
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"node-v{NODE_VERSION}-darwin-{arch}.tar.gz"
    if not archive.exists() or digest(archive) != NODE_HASHES[arch]:
        print(f"Downloading pinned Node {NODE_VERSION} ({arch})", flush=True)
        temporary = archive.with_suffix(".download")
        try:
            run(["/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--retry", "3", "--max-time", "180", "--output", temporary, f"https://nodejs.org/dist/v{NODE_VERSION}/{archive.name}"])
            if digest(temporary) != NODE_HASHES[arch]:
                raise RuntimeError("Node archive checksum mismatch")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    node_root = cache / archive.name.removesuffix(".tar.gz")
    if not (node_root / "bin/node").exists():
        run(["/usr/bin/tar", "-xzf", archive, "-C", cache])
    node = node_root / "bin/node"
    npm = node_root / "lib/node_modules/npm/bin/npm-cli.js"
    env = {**os.environ, "PATH": str(node.parent) + ":/usr/bin:/bin:/usr/sbin:/sbin"}
    lock = digest(package / "package-lock.json")
    dependencies = cache / ("dependencies-" + lock[:20])
    if not (dependencies / ".complete").exists():
        dependencies.mkdir(exist_ok=True)
        for name in ["package.json", "package-lock.json"]:
            shutil.copy2(package / name, dependencies / name)
        run([node, npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=dependencies, env=env)
        (dependencies / ".complete").write_text(lock)
    # Compile in an isolated directory: incremental Xcode builds do not mutate a developer's node_modules/dist.
    with tempfile.TemporaryDirectory(prefix="assembly-", dir=cache) as work:
        work = Path(work)
        for name in ["package.json", "tsconfig.json", "tsconfig.build.json"]:
            shutil.copy2(package / name, work / name)
        shutil.copytree(package / "src", work / "src")
        (work / "node_modules").symlink_to(dependencies / "node_modules", target_is_directory=True)
        run([node, dependencies / "node_modules/typescript/bin/tsc", "-p", work / "tsconfig.build.json"], cwd=work, env=env)
        production = cache / ("production-" + lock[:20])
        if not (production / ".complete").exists():
            production.mkdir(exist_ok=True)
            for name in ["package.json", "package-lock.json"]:
                shutil.copy2(package / name, production / name)
            run([node, npm, "ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=production, env=env)
            (production / ".complete").write_text(lock)
        destination.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=".local-agent-", dir=destination.parent))
        try:
            (stage / "node/bin").mkdir(parents=True)
            shutil.copy2(node, stage / "node/bin/node")
            shutil.copy2(node_root / "LICENSE", stage / "node/LICENSE")
            helper = stage / "dsh-runtime"
            helper.mkdir()
            shutil.copy2(package / "package.json", helper / "package.json")
            shutil.copy2(package / "package-lock.json", helper / "package-lock.json")
            shutil.copytree(work / "dist", helper / "dist")
            shutil.copytree(package / "assets", helper / "assets")
            shutil.copytree(production / "node_modules", helper / "node_modules", symlinks=True)
            prune_pty_prebuilds(helper, arch)
            run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-O", "-target", f"{'arm64' if arch == 'arm64' else 'x86_64'}-apple-macosx13.0", helper / "assets/bridge/local-media.swift", "-o", helper / "assets/bridge/local-media"])
            # Source maps are development diagnostics, not runtime dependencies. Preserve all package licenses.
            for source_map in helper.rglob("*.map"):
                source_map.unlink()
            # Xcode signs the complete application after this phase; sign nested executables first.
            identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
            native = []
            for candidate in stage.rglob("*"):
                if candidate.is_file() and not candidate.is_symlink():
                    with candidate.open("rb") as stream:
                        if stream.read(4) in [b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"]:
                            native.append(candidate)
            for binary in sorted(native, key=lambda path: len(path.parts), reverse=True):
                run(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "0" if identity == "-" else "runtime", "--entitlements", APP / "macos/Runner/LocalAgent.entitlements", binary])
            # Rosetta must translate this exact signed executable before a confined child
            # can start it. This build-only --version check uses no account or user config.
            # Runtime execution still has to pass the unchanged OS-confined probe below.
            if arch == "x64" and platform.machine() in ["arm64", "aarch64"]:
                binary = helper / "node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex"
                with tempfile.TemporaryDirectory(prefix="codex-rosetta-version-") as probe_home:
                    version = subprocess.check_output([binary, "--version"], cwd=probe_home,
                        env={"PATH": env["PATH"], "HOME": probe_home, "TMPDIR": probe_home},
                        stdin=subprocess.DEVNULL, timeout=90, text=True).strip()
                    if version != "codex-cli 0.132.0":
                        raise RuntimeError("Pinned Intel Codex version mismatch")
            # The worker must resolve its imports with only bundled production dependencies.
            report = json.loads(subprocess.check_output([stage / "node/bin/node", helper / "dist/desktop/main.js", "--self-check"], cwd=helper, env=env, stdin=subprocess.DEVNULL, timeout=SELF_CHECK_TIMEOUT_SECONDS))
            if not all(report["checks"].get(key) for key in ["node", "engine", "office", "isolation", "codex"]):
                raise RuntimeError(f"Packaged {arch} runtime failed component/isolation probes: {report['checks']}")
            # Load and exercise the retained native addon, not just its JS entrypoint.
            run([stage / "node/bin/node", "-e", """
const p = require('node-pty').spawn('/bin/sh', ['-c', 'printf pty-architecture-ok'], {env: {PATH:'/usr/bin:/bin'}});
let output = '';
p.onData(data => output += data);
const timer = setTimeout(() => process.exit(2), 10000);
p.onExit(({exitCode}) => { clearTimeout(timer); process.exit(exitCode === 0 && output.includes('pty-architecture-ok') ? 0 : 1); });
"""], cwd=helper, env=env, stdin=subprocess.DEVNULL, timeout=20)
            manifest = {"version": 1, "node": NODE_VERSION, "platform": "darwin", "arch": arch, "lock_sha256": lock, "dsh": "0.1.0-rc.8", "codex_app_server": "0.132.0" if report["checks"].get("codex") else None}
            (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            # Only this script's dedicated generated subtree is replaced.
            if destination.exists():
                shutil.rmtree(destination)
            stage.replace(destination)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    print(f"Local Agent bundled: Node {NODE_VERSION}, {arch}", flush=True)


def main():
    if sys.platform != "darwin":
        raise RuntimeError("macOS packaging requires a macOS builder")
    architectures = target_architectures(os.environ, platform.machine())
    if len(sys.argv) == 2:
        destination = Path(sys.argv[1]).resolve()
    else:
        destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "local-agent"
    if destination.name != "local-agent":
        raise RuntimeError("destination must be a dedicated local-agent directory")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".local-agent-platforms-", dir=destination.parent))
    try:
        # Each Node runs its own npm/compile/self-check, including under Rosetta.
        # If a target cannot execute on this builder, fail instead of shipping an unchecked slice.
        # Freeze source once so concurrent edits cannot produce different code per ABI.
        with tempfile.TemporaryDirectory(prefix="local-agent-source-") as snapshot:
            snapshot = Path(snapshot)
            for name in ["package.json", "package-lock.json", "tsconfig.json", "tsconfig.build.json"]:
                shutil.copy2(PACKAGE / name, snapshot / name)
            for name in ["src", "assets"]:
                shutil.copytree(PACKAGE / name, snapshot / name)
            for arch in architectures:
                bundle_arch(arch, stage / arch, snapshot)
        (stage / "manifest.json").write_text(json.dumps({"version": 2, "platform": "darwin", "architectures": architectures}, indent=2) + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        stage.replace(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    main()
