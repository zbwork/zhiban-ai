#!/usr/bin/env python3
"""Read-only community document checks, not a product/security release audit."""

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


DOCUMENTS = (
    "README.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md",
    "SUPPORT.md", "GOVERNANCE.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md",
    "docs/INSTALL.md", ".github/pull_request_template.md",
)
CONFIGS = (
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/ISSUE_TEMPLATE/config.yml", ".github/dependabot.yml",
    ".github/workflows/community.yml",
)
MARKER = "RELEASE_INPUT_" + "REQUIRED"


def check(root: Path, draft: bool = False) -> tuple[list[str], list[str]]:
    root = root.resolve()
    errors, pending = [], []
    for name in (*DOCUMENTS, *CONFIGS, "LICENSE"):
        path = root / name
        if not path.resolve().is_relative_to(root):
            errors.append(f"{name}: path escapes candidate root")
            continue
        if not path.is_file():
            (pending if name == "LICENSE" else errors).append(f"{name}: missing")
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            errors.append(f"{name}: cannot read UTF-8 text")
            continue
        if not content.strip():
            errors.append(f"{name}: empty")
        if MARKER in content:
            pending.append(f"{name}: unresolved release input")
        if name not in DOCUMENTS:
            continue
        # The candidate documents use inline Markdown links. Skip code fences.
        prose = re.sub(r"```.*?```", "", content, flags=re.S)
        for raw in re.findall(r"\]\(([^\s)]+)\)", prose):
            url = urlsplit(raw.strip("<>"))
            if url.scheme or url.netloc or not url.path:
                continue
            target = (path.parent / unquote(url.path)).resolve()
            if not target.is_relative_to(root):
                errors.append(f"{name}: local link escapes candidate root")
            elif not target.exists():
                # A pending LICENSE link is only acceptable in draft mode.
                bucket = pending if target == root / "LICENSE" else errors
                bucket.append(f"{name}: local link target missing")
    if not draft:
        errors.extend(pending)
    return errors, pending


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Candidate or public repository root")
    parser.add_argument("--draft", action="store_true", help="Allow known pending release inputs")
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error("root must be an existing directory")
    errors, pending = check(args.root, args.draft)
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 1
    if args.draft:
        for item in pending:
            print(f"PENDING: {item}")
        print("Draft structure passed; this is not release approval.")
    else:
        print("Community materials passed; product/security/license review still required.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
