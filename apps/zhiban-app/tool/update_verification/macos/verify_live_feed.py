"""Verify an uploaded fixture through a real Bus feed and native Sparkle."""

import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
from urllib.parse import urlparse


def main():
    root = Path(os.environ["EASYO_UPDATE_PROBE"]).resolve()
    feed = os.environ["EASYO_LIVE_APPCAST"]
    if urlparse(feed).scheme not in ("http", "https"):
        raise ValueError("EASYO_LIVE_APPCAST must be an HTTP(S) Bus appcast")
    baseline = root / "100/EasyOUpdateFixture.app"
    info = plistlib.loads((baseline / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "cn.qkfintech.zhiban.updatefixture"
    assert info["CFBundleVersion"] == "100"
    app = root / "live-bus/EasyOUpdateFixture.app"
    executable = app / "Contents/MacOS/EasyOUpdateFixture"
    exact_process = "^" + re.escape(str(executable)) + "$"

    def stop_relaunched_fixture():
        subprocess.run(["pkill", "-f", exact_process], capture_output=True)

    stop_relaunched_fixture()
    if app.exists():
        shutil.rmtree(app)
    subprocess.run(["ditto", str(baseline), str(app)], check=True)
    for name in ("native-state.json", "native-events.jsonl", "native-command"):
        (root / name).unlink(missing_ok=True)
    (root / "feed-url").write_text(feed)

    def wait_for(event, build=None):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            time.sleep(0.2)
            state_file = root / "native-state.json"
            if not state_file.exists():
                continue
            state = json.loads(state_file.read_text())
            if state["event"].startswith(("failed", "notFound")):
                # Detailed native output is retained locally, never print signed URLs.
                raise RuntimeError("Native update failed; inspect live-bus-native.log")
            if state["event"] == event and (build is None or state["build"] == build):
                return
        raise TimeoutError(f"Native update did not reach {event}")

    with (root / "live-bus-native.log").open("w") as log:
        process = subprocess.Popen([str(executable)], stdout=log, stderr=log)
        try:
            wait_for("ready")
            events = [json.loads(line) for line in (root / "native-events.jsonl").read_text().splitlines()]
            packages = [event["packageType"] for event in events if event["event"] == "sparkleDownloadStarted"]
            assert packages == ["delta"], packages
            (root / "native-command").write_text("install")
            wait_for("started", "101")
            installed = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            assert installed["CFBundleVersion"] == "101"
            evidence = {
                "source": "Bus appcast and configured object storage",
                "packages": packages,
                "installedBuild": installed["CFBundleVersion"],
            }
            (root / "live-bus-evidence.json").write_text(json.dumps(evidence, indent=2))
            print("PASS: Bus -> object storage -> Sparkle Delta -> installed and relaunched 101")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            stop_relaunched_fixture()


if __name__ == "__main__":
    main()
