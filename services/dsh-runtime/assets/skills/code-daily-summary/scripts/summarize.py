#!/usr/bin/env python3
"""Generate a daily code contribution report from GitLab or GitHub commits."""

from __future__ import annotations

import argparse
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import threading
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, time, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo


PER_PAGE = 100


@dataclass
class AuthorProfile:
    name: str
    aliases: list[str] = field(default_factory=list)

    def keys(self) -> set[str]:
        values = {self.name, *self.aliases}
        return {normalize_identity(v) for v in values if v}

    def payload(self) -> dict[str, Any]:
        return {"name": self.name, "aliases": self.aliases}


@dataclass
class CommitInfo:
    sha: str
    short_sha: str
    title: str
    message: str
    author_name: str
    author_email: str
    author_username: str
    committed_at: str
    web_url: str
    additions: int
    deletions: int
    total: int
    files: list[str] = field(default_factory=list)
    category: str = "other"

    def __post_init__(self) -> None:
        if self.total == 0 and (self.additions or self.deletions):
            self.total = self.additions + self.deletions

    def author_keys(self) -> set[str]:
        return {
            normalize_identity(v)
            for v in (self.author_name, self.author_email, self.author_username)
            if v
        }


def normalize_identity(value: str) -> str:
    return value.strip().lower()


def parse_dt(value: str) -> datetime:
    raw = value.strip()
    if raw.endswith("Z"):
        raw = f"{raw[:-1]}+00:00"
    dt = datetime.fromisoformat(raw)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_window(tz_name: str, cutoff_hour: int, now: datetime | None = None) -> tuple[datetime, datetime]:
    tz = ZoneInfo(tz_name)
    current = (now or datetime.now(tz)).astimezone(tz)
    today_cutoff = datetime.combine(current.date(), time(cutoff_hour, 0), tzinfo=tz)
    until = today_cutoff if current >= today_cutoff else today_cutoff - timedelta(days=1)
    since = until - timedelta(days=1)
    return since, until


def parse_author_profiles(raw: str | None) -> list[AuthorProfile]:
    if not raw:
        return []
    value = raw.strip()
    if not value:
        return []

    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        parsed = None

    profiles: list[AuthorProfile] = []
    if isinstance(parsed, list):
        for item in parsed:
            if isinstance(item, dict):
                name = str(item.get("name") or "").strip()
                aliases = item.get("aliases") or []
                if isinstance(aliases, str):
                    aliases = [aliases]
                if name:
                    profiles.append(AuthorProfile(name=name, aliases=[str(a) for a in aliases if str(a).strip()]))
        return profiles
    if isinstance(parsed, dict):
        for name, aliases in parsed.items():
            if isinstance(aliases, str):
                aliases = [aliases]
            profiles.append(AuthorProfile(name=str(name), aliases=[str(a) for a in aliases]))
        return profiles

    for chunk in value.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "=" in chunk:
            name, aliases_raw = chunk.split("=", 1)
            aliases = [x.strip() for x in re.split(r"[|,]", aliases_raw) if x.strip()]
            profiles.append(AuthorProfile(name=name.strip(), aliases=aliases))
        else:
            profiles.append(AuthorProfile(name=chunk, aliases=[]))
    return profiles


def request_json(url: str, headers: dict[str, str]) -> tuple[Any, dict[str, str]]:
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body), {k.lower(): v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"HTTP {exc.code} for {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"request failed for {url}: {exc}") from exc


def build_url(base: str, path: str, query: dict[str, Any]) -> str:
    encoded = urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
    return f"{base.rstrip('/')}{path}?{encoded}"


def fetch_gitlab_commits(args: argparse.Namespace, since: datetime, until: datetime) -> list[CommitInfo]:
    token = os.environ.get(args.token_env or "GITLAB_TOKEN", "")
    headers = {"Accept": "application/json"}
    if token:
        headers["PRIVATE-TOKEN"] = token
    project = urllib.parse.quote(args.repo, safe="")
    commits: list[CommitInfo] = []
    page = 1
    while True:
        url = build_url(
            args.gitlab_base_url,
            f"/api/v4/projects/{project}/repository/commits",
            {
                "ref_name": args.branch,
                "since": iso_z(since),
                "until": iso_z(until),
                "with_stats": "true",
                "per_page": PER_PAGE,
                "page": page,
            },
        )
        rows, _headers = request_json(url, headers)
        if not isinstance(rows, list):
            raise RuntimeError("GitLab commits response is not a list")
        for row in rows:
            stats = row.get("stats") or {}
            message = row.get("message") or row.get("title") or ""
            commits.append(
                CommitInfo(
                    sha=row.get("id", ""),
                    short_sha=row.get("short_id") or row.get("id", "")[:8],
                    title=row.get("title") or message.splitlines()[0] if message else "",
                    message=message,
                    author_name=row.get("author_name") or "",
                    author_email=row.get("author_email") or "",
                    author_username="",
                    committed_at=row.get("committed_date") or row.get("created_at") or "",
                    web_url=row.get("web_url") or "",
                    additions=int(stats.get("additions") or 0),
                    deletions=int(stats.get("deletions") or 0),
                    total=int(stats.get("total") or 0),
                )
            )
        if len(rows) < PER_PAGE:
            break
        page += 1
    return commits


def fetch_github_commits(args: argparse.Namespace, since: datetime, until: datetime) -> list[CommitInfo]:
    if "/" not in args.repo:
        raise ValueError("GitHub repo must be in owner/repo format")
    owner, repo = args.repo.split("/", 1)
    token = os.environ.get(args.token_env or "GITHUB_TOKEN", "")
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10",
        "User-Agent": "zhiban-code-daily-summary",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    base = args.github_api_base_url.rstrip("/")
    commits: list[CommitInfo] = []
    page = 1
    while True:
        url = build_url(
            base,
            f"/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(repo)}/commits",
            {
                "sha": args.branch,
                "since": iso_z(since),
                "until": iso_z(until),
                "per_page": PER_PAGE,
                "page": page,
            },
        )
        rows, _headers = request_json(url, headers)
        if not isinstance(rows, list):
            raise RuntimeError("GitHub commits response is not a list")
        for row in rows:
            sha = row.get("sha", "")
            detail_url = f"{base}/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(repo)}/commits/{sha}"
            detail, _ = request_json(detail_url, headers)
            commit = detail.get("commit") or {}
            author = commit.get("author") or {}
            gh_author = detail.get("author") or {}
            stats = detail.get("stats") or {}
            files = [f.get("filename", "") for f in detail.get("files") or [] if f.get("filename")]
            message = commit.get("message") or ""
            commits.append(
                CommitInfo(
                    sha=sha,
                    short_sha=sha[:8],
                    title=message.splitlines()[0] if message else "",
                    message=message,
                    author_name=author.get("name") or "",
                    author_email=author.get("email") or "",
                    author_username=gh_author.get("login") or "",
                    committed_at=author.get("date") or "",
                    web_url=detail.get("html_url") or row.get("html_url") or "",
                    additions=int(stats.get("additions") or 0),
                    deletions=int(stats.get("deletions") or 0),
                    total=int(stats.get("total") or 0),
                    files=files,
                )
            )
        if len(rows) < PER_PAGE:
            break
        page += 1
    return commits


def run_git(args: list[str], cwd: str | None = None, env: dict[str, str] | None = None) -> str:
    proc = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise RuntimeError(f"{' '.join(args)} failed: {detail[:1000]}")
    return proc.stdout


def git_env(args: argparse.Namespace, temp_dir: str) -> dict[str, str]:
    env = os.environ.copy()
    command = args.git_ssh_command or env.get("GIT_SSH_COMMAND", "")
    key_content = os.environ.get(args.git_ssh_key_env or "", "") if args.git_ssh_key_env else ""
    http_username = args.git_http_username or os.environ.get("CODE_SUMMARY_GIT_HTTP_USERNAME", "")
    http_password_env = args.git_http_password_env or os.environ.get("CODE_SUMMARY_GIT_HTTP_PASSWORD_ENV", "")
    http_password = os.environ.get(http_password_env, "") if http_password_env else ""
    if key_content:
        key_path = os.path.join(temp_dir, "git_ssh_key")
        with open(key_path, "w", encoding="utf-8") as f:
            f.write(key_content if key_content.endswith("\n") else f"{key_content}\n")
        os.chmod(key_path, 0o600)
        command = (
            f"ssh -i {shlex_quote(key_path)} -o IdentitiesOnly=yes "
            "-o StrictHostKeyChecking=accept-new -o BatchMode=yes"
        )
    elif args.repo.startswith("git@") and not command:
        command = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    if command:
        env["GIT_SSH_COMMAND"] = command
    if args.repo.startswith(("http://", "https://")) and http_username and http_password:
        askpass_path = os.path.join(temp_dir, "git_askpass.sh")
        with open(askpass_path, "w", encoding="utf-8") as f:
            f.write(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  *Username*|*username*) printf '%s\\n' \"$CODE_SUMMARY_GIT_HTTP_USERNAME_VALUE\" ;;\n"
                "  *Password*|*password*) printf '%s\\n' \"$CODE_SUMMARY_GIT_HTTP_PASSWORD_VALUE\" ;;\n"
                "  *) printf '%s\\n' \"$CODE_SUMMARY_GIT_HTTP_PASSWORD_VALUE\" ;;\n"
                "esac\n"
            )
        os.chmod(askpass_path, 0o700)
        env["GIT_ASKPASS"] = askpass_path
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["CODE_SUMMARY_GIT_HTTP_USERNAME_VALUE"] = http_username
        env["CODE_SUMMARY_GIT_HTTP_PASSWORD_VALUE"] = http_password
    return env


def shlex_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def repo_web_url(repo: str, sha: str) -> str:
    match = re.match(r"^git@([^:]+):(.+?)(?:\.git)?$", repo)
    if match:
        return f"https://{match.group(1)}/{match.group(2)}/-/commit/{sha}"
    parsed = urllib.parse.urlsplit(repo)
    if parsed.scheme in {"http", "https"} and parsed.netloc:
        path = parsed.path[:-4] if parsed.path.endswith(".git") else parsed.path
        return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, f"{path}/-/commit/{sha}", "", ""))
    return ""


def parse_numstat(raw: str) -> tuple[int, int, list[str]]:
    additions = 0
    deletions = 0
    files: list[str] = []
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        add_raw, del_raw, file_name = parts[0], parts[1], parts[2]
        additions += int(add_raw) if add_raw.isdigit() else 0
        deletions += int(del_raw) if del_raw.isdigit() else 0
        if file_name:
            files.append(file_name)
    return additions, deletions, files


def fetch_git_commits(args: argparse.Namespace, since: datetime, until: datetime) -> list[CommitInfo]:
    temp_dir = tempfile.mkdtemp(prefix="code-summary-git-")
    repo_dir = os.path.join(temp_dir, "repo")
    try:
        env = git_env(args, temp_dir)
        clone_args = [
            "git",
            "clone",
            "--quiet",
            "--no-checkout",
            "--no-tags",
            "--single-branch",
            "--branch",
            args.branch,
        ]
        if args.git_filter:
            clone_args.extend(["--filter", args.git_filter])
        if args.git_depth > 0:
            clone_args.extend(["--depth", str(args.git_depth)])
        clone_args.extend([args.repo, repo_dir])
        run_git(clone_args, env=env)
        log_format = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e"
        raw = run_git(
            [
                "git",
                "log",
                args.branch,
                f"--since={since.isoformat()}",
                f"--until={until.isoformat()}",
                f"--format={log_format}",
            ],
            cwd=repo_dir,
            env=env,
        )
        commits: list[CommitInfo] = []
        for record in raw.strip("\x1e\n").split("\x1e"):
            record = record.strip("\n")
            if not record:
                continue
            fields = record.split("\x1f")
            if len(fields) < 6:
                continue
            sha, short_sha, author_name, author_email, committed_at, title = fields[:6]
            message = run_git(["git", "log", "-1", "--format=%B", sha], cwd=repo_dir, env=env).strip()
            numstat = run_git(["git", "show", "--numstat", "--format=", "--no-renames", sha], cwd=repo_dir, env=env)
            additions, deletions, files = parse_numstat(numstat)
            commits.append(
                CommitInfo(
                    sha=sha,
                    short_sha=short_sha,
                    title=title,
                    message=message or title,
                    author_name=author_name,
                    author_email=author_email,
                    author_username="",
                    committed_at=committed_at,
                    web_url=repo_web_url(args.repo, sha),
                    additions=additions,
                    deletions=deletions,
                    total=additions + deletions,
                    files=files,
                )
            )
        return commits
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def load_input_commits(path: str) -> list[CommitInfo]:
    with open(path, "r", encoding="utf-8") as f:
        rows = json.load(f)
    commits: list[CommitInfo] = []
    for row in rows:
        stats = row.get("stats") or {}
        sha = row.get("sha") or row.get("id") or ""
        message = row.get("message") or row.get("title") or ""
        commits.append(
            CommitInfo(
                sha=sha,
                short_sha=row.get("short_sha") or row.get("short_id") or sha[:8],
                title=row.get("title") or (message.splitlines()[0] if message else ""),
                message=message,
                author_name=row.get("author_name") or "",
                author_email=row.get("author_email") or "",
                author_username=row.get("author_username") or "",
                committed_at=row.get("committed_at") or row.get("committed_date") or row.get("created_at") or "",
                web_url=row.get("web_url") or row.get("html_url") or "",
                additions=int(row.get("additions", stats.get("additions", 0)) or 0),
                deletions=int(row.get("deletions", stats.get("deletions", 0)) or 0),
                total=int(row.get("total", stats.get("total", 0)) or 0),
                files=[str(x) for x in row.get("files", [])],
            )
        )
    return commits


def categorize(message: str, files: list[str]) -> str:
    first_line = (message.splitlines()[0] if message else "").strip().lower()
    if re.match(r"^feat(\([^)]+\))?\s*[:：]", first_line):
        return "feature"
    if re.match(r"^(fix|bugfix|hotfix|revert)(\([^)]+\))?\s*[:：]", first_line):
        return "fix"
    if re.match(r"^(docs?|readme)(\([^)]+\))?\s*[:：]", first_line):
        return "docs"
    if re.match(r"^(test|tests)(\([^)]+\))?\s*[:：]", first_line):
        return "tests"
    if re.match(r"^(refactor|chore|style|cleanup|format)(\([^)]+\))?\s*[:：]", first_line):
        return "maintenance"

    text = f"{message}\n{' '.join(files)}".lower()
    patterns = [
        ("fix", r"\b(fix|bugfix|hotfix|repair)\b|修复|问题|故障|缺陷"),
        ("feature", r"\b(feat|feature|add|implement|support)\b|新增|实现|支持|上线"),
        ("docs", r"\b(doc|docs|readme)\b|文档|说明"),
        ("tests", r"\b(test|tests|spec)\b|测试|用例"),
        ("ops", r"\b(ci|deploy|docker|k8s|config|infra|ops)\b|部署|配置|镜像|流水线"),
        ("maintenance", r"\b(refactor|chore|style|cleanup|format)\b|重构|清理|格式"),
    ]
    for category, pattern in patterns:
        if re.search(pattern, text):
            return category
    return "other"


def match_author_profile(commit: CommitInfo, profiles: list[AuthorProfile]) -> AuthorProfile | None:
    keys = commit.author_keys()
    for profile in profiles:
        if keys & profile.keys():
            return profile
    return None


def matched_profile_aliases(commit: CommitInfo, profile: AuthorProfile) -> list[str]:
    keys = commit.author_keys()
    matched = []
    for alias in profile.aliases:
        if normalize_identity(alias) in keys:
            matched.append(alias)
    return matched


def derive_profiles(commits: list[CommitInfo]) -> list[AuthorProfile]:
    seen: dict[str, AuthorProfile] = {}
    for c in commits:
        name = c.author_name or c.author_username or c.author_email or "unknown"
        key = normalize_identity(name)
        if key not in seen:
            aliases = [v for v in (c.author_email, c.author_username) if v]
            seen[key] = AuthorProfile(name=name, aliases=aliases)
    return list(seen.values())


def build_summary(
    args: argparse.Namespace,
    commits: list[CommitInfo],
    profiles: list[AuthorProfile],
    since: datetime,
    until: datetime,
) -> dict[str, Any]:
    for commit in commits:
        commit.category = categorize(commit.message, commit.files)

    tracked_profiles = profiles[:]
    if not profiles:
        profiles = derive_profiles(commits)

    by_author: dict[str, dict[str, Any]] = {}
    for profile in profiles:
        by_author[profile.name] = {
            "name": profile.name,
            "aliases": profile.aliases,
            "matched_aliases": [],
            "commit_count": 0,
            "additions": 0,
            "deletions": 0,
            "total": 0,
            "categories": {},
            "commits": [],
            "status": "no_commit",
        }

    untracked: list[dict[str, Any]] = []
    for commit in commits:
        profile = match_author_profile(commit, profiles)
        commit_payload = asdict(commit)
        if profile:
            stat = by_author[profile.name]
            stat["commit_count"] += 1
            stat["additions"] += commit.additions
            stat["deletions"] += commit.deletions
            stat["total"] += commit.total
            stat["status"] = "submitted"
            stat["categories"][commit.category] = stat["categories"].get(commit.category, 0) + 1
            stat["commits"].append(commit_payload)
            for alias in matched_profile_aliases(commit, profile):
                if alias not in stat["matched_aliases"]:
                    stat["matched_aliases"].append(alias)
        else:
            untracked.append(commit_payload)

    totals = {
        "commit_count": len(commits),
        "additions": sum(c.additions for c in commits),
        "deletions": sum(c.deletions for c in commits),
        "total": sum(c.total for c in commits),
    }
    categories: dict[str, int] = {}
    for commit in commits:
        categories[commit.category] = categories.get(commit.category, 0) + 1

    return {
        "provider": args.provider,
        "repo": args.repo,
        "branch": args.branch,
        "timezone": args.timezone,
        "window_start": since.isoformat(),
        "window_end": until.isoformat(),
        "window_start_utc": iso_z(since),
        "window_end_utc": iso_z(until),
        "tracked_authors": [profile.payload() for profile in tracked_profiles],
        "totals": totals,
        "categories": categories,
        "authors": list(by_author.values()),
        "untracked_commits": untracked,
    }


def category_label(category: str) -> str:
    return {
        "feature": "功能开发",
        "fix": "问题修复",
        "docs": "文档",
        "tests": "测试",
        "ops": "配置/部署",
        "maintenance": "重构/维护",
        "other": "其他",
    }.get(category, category)


def display_window(value: str) -> str:
    dt = parse_dt(value)
    return dt.strftime("%Y-%m-%dT%H:%M:%S")


def period_text(summary: dict[str, Any]) -> str:
    start = parse_dt(summary["window_start"]).strftime("%Y-%m-%d %H:%M")
    end = parse_dt(summary["window_end"]).strftime("%Y-%m-%d %H:%M")
    return f"{start} - {end}"


def author_heading(author: dict[str, Any]) -> str:
    aliases = author.get("matched_aliases") or author.get("aliases") or []
    if aliases:
        return f"{','.join(aliases)} ({author['name']})"
    return author["name"]


def report_bucket(category: str) -> str:
    if category == "feature":
        return "feature"
    if category == "fix":
        return "fix"
    return "optimization"


def report_bucket_label(bucket: str) -> str:
    return {
        "feature": "一、功能开发（新增能力）",
        "fix": "二、问题修复（体验/稳定性）",
        "optimization": "三、代码优化（用户无感，为后续提速）",
    }[bucket]


def strip_commit_prefix(title: str) -> str:
    text = re.sub(r"^\s*(feat|fix|docs|doc|chore|refactor|style|test|tests|ci|build|perf|update)(\([^)]+\))?\s*[:：]\s*", "", title, flags=re.I)
    text = re.sub(r"\s+", " ", text).strip()
    return text or title.strip()


def chinese_title(title: str) -> str:
    text = strip_commit_prefix(title)
    replacements = [
        (r"^add\s+", "新增 "),
        (r"^support\s+", "支持 "),
        (r"^implement\s+", "实现 "),
        (r"^update\s+", "更新 "),
        (r"^fix\s+", "修复 "),
        (r"^repair\s+", "修复 "),
        (r"^disable\s+", "禁用 "),
        (r"^remove\s+", "移除 "),
        (r"^rename\s+", "重命名 "),
        (r"^revert\s+", "回滚 "),
        (r"^refactor\s+", "重构 "),
        (r"^polish\s+", "打磨 "),
        (r"^improve\s+", "优化 "),
        (r"^extend\s+", "扩展 "),
        (r"^use\s+", "使用 "),
        (r"^map\s+", "映射 "),
    ]
    for pattern, replacement in replacements:
        text = re.sub(pattern, replacement, text, flags=re.I)
    text = text.replace("docs", "文档")
    text = text.replace("doc", "文档")
    text = text.replace("billing", "计费")
    text = text.replace("runtime", "运行时")
    text = text.replace("workflow", "工作流")
    text = text.replace("models", "模型")
    text = text.replace("model", "模型")
    text = text.replace("provider", "提供方")
    text = re.sub(r"映射 (.+?) through (.+)", r"通过 \2 映射 \1", text, flags=re.I)
    text = text.replace("presigned URLs", "预签名 URL")
    text = text.replace("download endpoint", "下载接口")
    text = text.replace("notification", "通知")
    text = text.replace("notifications", "通知")
    text = text.replace("contacts list", "通讯录列表")
    text = text.replace("incoming panel", "来电面板")
    text = text.replace("packaging guide", "打包指南")
    text = text.replace("README", "README")
    return text


def is_merge_commit(title: str) -> bool:
    return bool(re.match(r"^\s*merge\b", title, flags=re.I))


def file_scope(files: list[str]) -> str:
    joined = "\n".join(files)
    scopes: list[str] = []
    checks = [
        ("客户端", r"apps/zhiban-app/"),
        ("管理后台", r"apps/agent-bus-admin/"),
        ("Agent Bus 服务", r"services/agent-bus/"),
        ("OpenClaw 运行时", r"deploy/openclaw-deploy/"),
        ("示例 Agent", r"apps/example/"),
        ("文档/契约", r"(^|/)docs/|README|\.md$"),
        ("数据库迁移", r"sql/postgres|migrations?"),
        ("测试用例", r"(_test\.go|test_|/tests?/|\.spec\.)"),
    ]
    for label, pattern in checks:
        if re.search(pattern, joined):
            scopes.append(label)
    return "、".join(scopes[:3])


def product_summary_item(commit: dict[str, Any]) -> str:
    topic = product_summary_topic(commit)
    return render_topic_item(topic["summary"], topic["details"])


def render_topic_item(summary: str, details: list[str]) -> str:
    summary_text = summary.rstrip("。；; ")
    clean_details = []
    seen = set()
    for detail in details:
        item = detail.rstrip("。；; ")
        if not item:
            continue
        key = normalize_identity(item)
        if key in seen:
            continue
        seen.add(key)
        clean_details.append(item)
    if not clean_details:
        return f"{summary_text}。"
    return f"{summary_text}：{'，'.join(clean_details)}。"


def product_summary_topic(commit: dict[str, Any]) -> dict[str, Any]:
    title_raw = commit.get("title") or commit.get("short_sha") or ""
    title = chinese_title(title_raw)
    title_text = f"{title_raw}\n{title}".lower()
    text = f"{title_raw}\n{title}\n{' '.join(str(f) for f in commit.get('files') or [])}".lower()
    rules = [
        ("a2a", r"\ba2a\b|cross[- ]agent|跨\s*agent|跨智能体", "打通 A2A 跨 Agent 协作全链路，让发现、调用、续聊、治理和结果呈现保持一致"),
        ("observability", r"agent runs?|agent run|observability|trace|tracing|调用日志|全链路追踪|usage attribution", "补齐 Agent 全链路追踪与用量归因，方便运营和研发定位每次运行"),
        ("prewarm", r"prewarm|预热", "完善 Agent 运行时预热和任务恢复，避免依赖阻塞或实例替换导致任务卡住"),
        ("memory", r"memory|记忆", "完善 Hermes 统一记忆能力，避免默认记忆与平台记忆并行冲突"),
        ("meeting_guard", r"meeting|unready", "隐藏尚未就绪的会议入口，避免用户误触未完成能力"),
        ("desktop_av", r"screen share|hwnd|video.*overlay|dingrtc|camera|preview|/utf-8|c4819|msvc|视频|屏幕共享", "补齐桌面端音视频能力，提升会议和通话可用性"),
        ("download_https", r"latest download endpoint|下载接口|ats|https|presigned url|s3", "补齐客户端下载和外链访问链路，减少安装包下载失败"),
        ("installer_filename", r"installer filename|安装包.*命名|ZhiBanAI_", "统一安装包文件名，便于用户识别和运营分发"),
        ("macos_archive", r"xcode archive|archive workflow", "把 macOS 打包流程切到 Xcode Archive，减少手工打包差异"),
        ("macos_dmg", r"dmg", "补充 macOS DMG 打包说明，方便桌面端安装包标准化产出"),
        ("auto_update", r"winsparkle|sparkle|自动更新|appcast|sidebar update card|silent update|diagnostics|inno", "完善桌面端自动更新链路，客户端可检测新版本并引导用户升级"),
        ("packaging_docs", r"packaging guide|packaging|installer|安装包|打包配置", "补充桌面端打包和发布说明，让多端发版流程更清晰"),
        ("notification_route", r"navigate to chat|notification.*tab", "优化通知点击后的跳转路径，用户点击提醒后能直接回到聊天"),
        ("desktop_notification", r"notification|dock|taskbar|通知|角标|闪烁", "补齐桌面通知体验，让消息提醒更及时"),
        ("billing_usage", r"usage|billing|计费|用量|pay|wechat", "打通用量计费链路，让 Agent 调用消耗可记录、展示并用于后续计费"),
        ("support_feedback", r"feedback|customer|客服|zhiban support|support avatar|support tenant", "新增用户反馈和客服相关入口，把问题反馈统一收口到平台处理"),
        ("rag", r"rag|knowledge|kb|citation|retrieval|rrf|知识库|引用", "优化知识库问答检索和引用展示，提升回答速度、召回质量和可信度"),
        ("agent_model", r"llm|model|provider|aigc|openclaw|agent key|agent platform|zap", "打通或修正 Agent 模型和运行时对接链路，避免模型标识或凭证不一致导致调用失败"),
        ("input_style", r"uiselect|input widget|input field|fieldstyle|borderRadius|hintStyle", "统一客户端输入控件和选择器样式，减少页面间视觉差异"),
        ("client_layout", r"contacts list|avatar card|incoming panel|layout|clipping|通讯录|来电面板|头像|布局|tooltip|padding", "修复客户端关键界面布局问题，减少内容裁切、面板错位和入口展示不稳定"),
        ("desktop_stability", r"nil coalescing|impeller|metal|crash|崩溃", "修复桌面端更新或渲染稳定性问题，降低启动崩溃和运行异常风险"),
        ("account_session", r"wukong|logout|reconnect|账号|会话|登录|account switch", "修复账号切换、退出登录和会话重置问题，避免重连循环或残留旧会话"),
        ("friendly_error", r"captcha|error|中文|friendly|错误|网络异常|business errors", "优化错误提示文案，把网络失败、验证码等异常改成用户更容易理解的中文表达"),
        ("tenant_bootstrap", r"tenant|template|客服 agent|默认模板|member names|picker", "完善租户初始化和人员展示，新租户开通后可以更快进入可用状态"),
        ("service_refactor", r"rename|refactor|service|DesktopNotificationService|MacosUpdateService", "整理服务命名和模块边界，让后续维护更清晰"),
        ("version_release", r"version|版本|platform tabs|clientversions|app icons|export compliance", "统一版本号和发布配置管理，减少多端发版时的手工配置差异"),
        ("external_docs", r"api|webhook|文档|docs|readme|organization|org delta", "完善对外 API、Webhook 或发版文档，降低外部对接和内部交接成本"),
    ]
    for key, pattern, summary in rules:
        if re.search(pattern, title_text, flags=re.I):
            return {"key": key, "summary": summary, "details": topic_details(key, text, title)}
    scope = file_scope([str(f) for f in commit.get("files") or []])
    if scope:
        return {
            "key": f"scope:{scope}",
            "summary": f"主要影响{scope}，用于补齐能力、修复体验或改善后续维护效率",
            "details": [title],
        }
    return {
        "key": f"misc:{normalize_identity(title)}",
        "summary": "补齐能力、修复体验或改善后续维护效率",
        "details": [title],
    }


def topic_details(key: str, text: str, title: str) -> list[str]:
    detail_rules: dict[str, list[tuple[str, str]]] = {
        "a2a": [
            (r"runtime tool|tool context|runtimetools", "统一 runtime tool 调用上下文"),
            (r"approval|审批|governance", "完善 A2A 审批和协作治理"),
            (r"origin conversation|session|续聊", "保留跨 Agent 会话来源和续聊上下文"),
            (r"billing|usage|计费|用量", "接通 A2A 计费和用量呈现"),
            (r"client|zhiban-app|chat|客户端", "完善客户端协作消息展示和交互"),
            (r"e2e|smoke|preflight|端到端", "补齐端到端联调脚本和验证"),
            (r"agent scoped|agent scope|隔离", "强化 Agent scope 隔离"),
            (r"plugin|openclaw|hermes", "打通 OpenClaw 和 Hermes runtime 插件"),
        ],
        "observability": [
            (r"agent runs?|agent run|observability|全链路追踪", "新增 Agent Runs 运行追踪"),
            (r"conversation", "新增会话维度追踪"),
            (r"usage attribution|usage|用量归因", "打通模型用量归因"),
            (r"handbook|运营手册", "补齐平台和租户使用手册"),
            (r"call logs|调用日志", "扩展 Agent 调用日志"),
            (r"trace|tracing", "加固 tracing 启动流程"),
        ],
        "prewarm": [
            (r"instance replacement|实例替换", "实例替换后恢复 Agent 任务"),
            (r"blocked dependency|dependency chain|依赖", "终止被依赖链阻塞的预热任务"),
        ],
        "memory": [
            (r"hermes", "Hermes 接入统一记忆模块"),
            (r"disable|default|默认", "禁用默认 memory 避免数据冲突"),
            (r"local|本地", "禁止运行时写本地记忆文件"),
            (r"log|日志", "补充记忆运行日志"),
        ],
        "desktop_av": [
            (r"screen share|屏幕共享", "Windows 支持屏幕共享"),
            (r"hwnd|overlay|视频.*渲染", "Windows 支持视频画面叠加渲染"),
            (r"flicker|闪烁", "修复远端摄像头和窗口画面闪烁"),
            (r"local camera|preview|本地.*预览", "补齐本地摄像头预览"),
            (r"msvc|constexpr|device list|atomic|race|private access|flutter_wrapper|/utf-8|c4819", "修复 DingRTC Windows 桥接编译、链接和叠加层竞态问题"),
            (r"auto-detect|sdk path", "自动识别项目内 DingRTC Windows SDK 路径"),
            (r"exclude arm64|simulator arch", "排除不兼容的 arm64 模拟器架构"),
        ],
        "download_https": [
            (r"latest download endpoint|下载接口", "新增 latest 下载接口"),
            (r"ats|https|presigned url|s3", "处理 ATS、HTTPS 和 S3 预签名 URL 兼容问题"),
        ],
        "installer_filename": [
            (r".*", "安装包文件名带环境、版本、构建号和平台信息"),
        ],
        "macos_archive": [
            (r".*", "macOS 打包切到 Xcode Archive 工作流"),
        ],
        "macos_dmg": [
            (r".*", "补充 macOS DMG 打包步骤"),
        ],
        "auto_update": [
            (r"winsparkle|windows", "Windows 接入 WinSparkle 自动更新"),
            (r"sparkle|macos|appcast", "macOS 接入 Sparkle appcast 更新检查"),
            (r"sidebar update card|indicator", "恢复侧边栏更新提示"),
            (r"silent update|native dialog", "静默检查后弹出系统更新对话框"),
            (r"diagnostics", "补充 WinSparkle 诊断输出"),
            (r"inno|auto-version", "自动生成 Windows 安装包版本信息"),
            (r"rename exe|zhibanai", "Windows 可执行文件统一命名为 ZhiBanAI"),
        ],
        "packaging_docs": [
            (r"macos.*windows|windows.*macos", "补充 macOS 和 Windows 打包指南"),
            (r"windows|inno", "更新 Windows 打包配置"),
            (r"macos|xcode|archive", "更新 macOS 打包流程说明"),
            (r"readme|文档", "沉淀 README 发版说明"),
        ],
        "notification_route": [
            (r".*", "点击通知时直接切回聊天页"),
        ],
        "desktop_notification": [
            (r"dock|taskbar|badge|flash|角标|闪烁", "新增 Dock 角标和任务栏闪烁提醒"),
            (r"window is closed|窗口", "关闭窗口后保持 macOS Dock 常驻"),
            (r"DesktopNotificationService|AppNotificationService", "通知服务命名收敛"),
        ],
        "support_feedback": [
            (r"feedback", "新增平台反馈入口"),
            (r"support avatar|avatar", "补齐知办客服头像资产"),
            (r"zhiban support|customer|客服", "客服 Agent 统一纳入平台管理"),
        ],
        "billing_usage": [
            (r"usage|用量", "记录 Agent 实际调用用量"),
            (r"billing|计费", "打通计费展示和扣费链路"),
            (r"pay|wechat|pem", "补齐微信支付证书加载"),
            (r"sidebar", "优化客户端侧边栏计费提示"),
        ],
        "rag": [
            (r"parallel|rrf|cache", "知识库检索支持并行召回、RRF 融合和按库缓存"),
            (r"citation|引用", "优化引用来源展示"),
            (r"runtime|运行时|chat rag", "OpenClaw 接入 chat-rag 运行时"),
            (r"docs|scripts|文档", "补充 chat-rag 文档和脚本"),
        ],
        "agent_model": [
            (r"credential|凭证", "LLM 凭证可下发到 ZAP 实例"),
            (r"normalize|model id|provider|aigc|模型", "统一模型 ID、provider 前缀和 AIGC 映射"),
            (r"agent key", "后端管理 ZAP Agent key"),
            (r"validation", "加强自定义 Agent 运行时校验"),
            (r"platform integration|agent platform", "同步 Agent 平台集成链路"),
            (r"emp rendering", "优化 ZAP EMP 渲染兼容性"),
        ],
        "input_style": [
            (r"uiselect", "UiSelect 并入共享输入主题"),
            (r"border|radius|hintstyle|fieldstyle", "统一边框、圆角和提示文案样式"),
            (r"all pages|across", "全页面复用统一输入框主题"),
            (r"claude.md|rules", "沉淀统一输入组件规则"),
        ],
        "client_layout": [
            (r"contacts list|clipping", "修复移动端通讯录列表裁切"),
            (r"avatar card", "压缩 Agent 头像卡片布局"),
            (r"incoming panel|来电面板", "修复来电面板布局"),
            (r"tooltip|overlay", "修复 Tooltip 所需 Overlay 上下文"),
            (r"padding|search field", "调整会话列表搜索框间距"),
        ],
        "meeting_guard": [
            (r".*", "未就绪会议入口先禁用"),
        ],
        "desktop_stability": [
            (r"nil coalescing|sparkle", "修复 Sparkle 属性访问问题"),
            (r"impeller|metal|product_name|crash", "规避 macOS PRODUCT_NAME 导致的 Metal shader 崩溃"),
        ],
        "account_session": [
            (r"logout|reconnect", "退出登录前注销 WuKong 防重连循环"),
            (r"account switch|账号切换|session", "账号切换时重置 WuKong 会话"),
            (r"devtools", "补充 WuKong SDK 调试配置"),
        ],
        "friendly_error": [
            (r"business errors|网络异常", "业务错误不再统一显示为网络异常"),
            (r"network|网络", "网络失败显示中文友好提示"),
            (r"captcha|验证码", "验证码错误显示中文提示"),
            (r"comments|c4819", "清理 Windows runner 中文注释避免编码构建错误"),
        ],
        "tenant_bootstrap": [
            (r"template|默认模板", "自注册租户自动初始化默认模板"),
            (r"support tenant|backfill", "回填知办客服租户 Agent"),
            (r"member names|picker", "选人弹窗显示真实姓名"),
        ],
        "service_refactor": [
            (r"DesktopNotificationService|AppNotificationService", "DesktopNotificationService 更名为 AppNotificationService"),
            (r"MacosUpdateService|DesktopUpdateService", "MacosUpdateService 更名为 DesktopUpdateService"),
            (r"service|module", "整理服务命名和模块边界"),
        ],
        "version_release": [
            (r"platform tabs|clientversions", "客户端版本页支持平台维度切换和 URL 同步"),
            (r"unify client version|version management", "统一多端版本号管理"),
            (r"(^|\n)version($|\n)|bump version|更新版本|bump build|build number", "同步版本号和构建号"),
            (r"app icons", "更新 iOS app icons"),
            (r"export compliance|encryption", "补齐 iOS 出口合规配置"),
            (r"target iphone", "发布目标收敛到 iPhone"),
        ],
        "external_docs": [
            (r"webhook", "补充组织 webhook 增量同步说明"),
            (r"organization|org delta", "完善组织外部 API 和 delta 响应示例"),
            (r"readme|docs|文档", "沉淀 README/文档说明"),
        ],
    }
    details = [label for pattern, label in detail_rules.get(key, []) if re.search(pattern, text, flags=re.I)]
    if details:
        return details
    return [title] if title else []


def summarize_commit_item(commit: dict[str, Any]) -> str:
    return product_summary_item(commit)


def grouped_report_items(commits: list[dict[str, Any]]) -> dict[str, list[str]]:
    buckets = {"feature": [], "fix": [], "optimization": []}
    source = [c for c in commits if not is_merge_commit(c.get("title") or "")]
    if not source:
        source = commits
    grouped: dict[str, dict[str, dict[str, Any]]] = {key: {} for key in buckets}
    for commit in source:
        topic = product_summary_topic(commit)
        bucket = report_bucket(commit.get("category") or "other")
        topic_key = topic["key"]
        if topic_key not in grouped[bucket]:
            grouped[bucket][topic_key] = {
                "summary": topic["summary"],
                "details": [],
                "seen_details": set(),
            }
        entry = grouped[bucket][topic_key]
        for detail in topic["details"]:
            detail_key = normalize_identity(detail)
            if detail_key in entry["seen_details"]:
                continue
            entry["seen_details"].add(detail_key)
            entry["details"].append(detail)
    for bucket, entries in grouped.items():
        for entry in entries.values():
            buckets[bucket].append(render_topic_item(entry["summary"], entry["details"]))
    return buckets


def render_markdown(summary: dict[str, Any]) -> str:
    totals = summary["totals"]
    lines = [
        f"# 代码地址：{summary['repo']} ({summary['branch']})",
        "",
        f"- 统计窗口：{display_window(summary['window_start'])} ~ {display_window(summary['window_end'])}",
        f"- 总提交：{totals['commit_count']} 个；新增 {totals['additions']} 行，删除 {totals['deletions']} 行，变更 {totals['total']} 行",
    ]
    if summary["categories"]:
        cats = "，".join(f"{category_label(k)} {v}" for k, v in sorted(summary["categories"].items()))
        lines.append(f"- 类型分布：{cats}")
    lines.extend(["", "## 按人员统计"])

    no_commit = []
    for author in summary["authors"]:
        if author["commit_count"] == 0:
            no_commit.append(author["name"])
            continue
        lines.extend([
            "",
            f"### {author_heading(author)}：{author['commit_count']} 个提交，+{author['additions']} / -{author['deletions']}"
        ])
        lines.append("")
        lines.append("> 提交数和行数包含 Merge / 同步类提交；下方按产品事项归纳展示。")
        grouped = grouped_report_items(author["commits"])
        for bucket in ("feature", "fix", "optimization"):
            if not grouped[bucket]:
                continue
            lines.extend(["", f"#### {report_bucket_label(bucket)}"])
            for index, item in enumerate(grouped[bucket], start=1):
                lines.append(f"{index}. {item}")
    lines.extend(["", "## 当日未提交代码"])
    if no_commit:
        for name in no_commit:
            lines.append(f"- {name}")
    else:
        lines.append("- 无")

    if summary["untracked_commits"]:
        lines.extend(["", "## 未匹配到指定人员的提交"])
        for commit in summary["untracked_commits"]:
            who = commit["author_name"] or commit["author_username"] or commit["author_email"] or "unknown"
            lines.append(f"- `{commit['short_sha']}` {commit['title']}（{who}，+{commit['additions']} / -{commit['deletions']}）")
    return "\n".join(lines).strip() + "\n"


def render_author_markdown(summary: dict[str, Any], author: dict[str, Any]) -> str:
    lines = [
        f"# 代码地址：{summary['repo']} ({summary['branch']})",
        "",
        f"- 统计窗口：{display_window(summary['window_start'])} ~ {display_window(summary['window_end'])}",
        f"- 人员：{author_heading(author)}",
        f"- 提交：{author['commit_count']} 个；新增 {author['additions']} 行，删除 {author['deletions']} 行，变更 {author['total']} 行",
    ]
    if author.get("categories"):
        cats = "，".join(f"{category_label(k)} {v}" for k, v in sorted(author["categories"].items()))
        lines.append(f"- 类型分布：{cats}")
    if author["commit_count"] == 0:
        lines.extend(["", "## 当日未提交代码", f"- {author['name']}"])
        return "\n".join(lines).strip() + "\n"

    lines.extend(["", "## 按人员统计", ""])
    lines.append(f"### {author_heading(author)}：{author['commit_count']} 个提交，+{author['additions']} / -{author['deletions']}")
    lines.append("")
    lines.append("> 提交数和行数包含 Merge / 同步类提交；下方按产品事项归纳展示。")
    grouped = grouped_report_items(author["commits"])
    for bucket in ("feature", "fix", "optimization"):
        if not grouped[bucket]:
            continue
        lines.extend(["", f"#### {report_bucket_label(bucket)}"])
        for index, item in enumerate(grouped[bucket], start=1):
            lines.append(f"{index}. {item}")
    return "\n".join(lines).strip() + "\n"


def latest_result_rows(summary: dict[str, Any]) -> list[dict[str, str]]:
    period = period_text(summary)
    return [
        {
            "author_name": author["name"],
            "period_text": period,
            "report_markdown": render_author_markdown(summary, author),
        }
        for author in summary["authors"]
    ]


def latest_result_markdown(rows: list[dict[str, str]] | None) -> str | None:
    if not rows:
        return None
    parts = [str(row.get("report_markdown", "")).strip() for row in rows]
    parts = [part for part in parts if part]
    if not parts:
        return None
    return "\n\n".join(parts).strip() + "\n"


def validate_identifier(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value):
        raise ValueError(f"invalid SQL identifier: {value}")
    return value


def build_db_dsn(args: argparse.Namespace) -> str:
    if args.db_dsn:
        return with_connect_timeout(args.db_dsn, args.db_connect_timeout)
    if os.environ.get("CODE_SUMMARY_DB_DSN"):
        return with_connect_timeout(os.environ["CODE_SUMMARY_DB_DSN"], args.db_connect_timeout)
    host = args.db_host or os.environ.get("CODE_SUMMARY_DB_HOST", "")
    name = args.db_name or os.environ.get("CODE_SUMMARY_DB_NAME", "")
    user = args.db_user or os.environ.get("CODE_SUMMARY_DB_USER", "")
    if not (host and name and user):
        return ""
    port = str(args.db_port or os.environ.get("CODE_SUMMARY_DB_PORT", "5432"))
    password = ""
    if args.db_password_env:
        password = os.environ.get(args.db_password_env, "")
    else:
        password = os.environ.get("CODE_SUMMARY_DB_PASSWORD", "")
    auth_user = urllib.parse.quote(user)
    auth_pass = f":{urllib.parse.quote(password)}" if password else ""
    return with_connect_timeout(f"postgresql://{auth_user}{auth_pass}@{host}:{port}/{name}", args.db_connect_timeout)


def with_connect_timeout(dsn: str, timeout: int) -> str:
    if timeout <= 0:
        return dsn
    parsed = urllib.parse.urlsplit(dsn)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    query.setdefault("connect_timeout", [str(timeout)])
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode(query, doseq=True), parsed.fragment)
    )


def db_target_from_dsn(dsn: str) -> tuple[str, int] | None:
    parsed = urllib.parse.urlsplit(dsn)
    if not parsed.hostname:
        return None
    return parsed.hostname, parsed.port or 5432


class HTTPConnectTunnel:
    def __init__(self, proxy_url: str, target_host: str, target_port: int):
        parsed = urllib.parse.urlsplit(proxy_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError(f"unsupported db proxy URL: {proxy_url}")
        if parsed.scheme == "https":
            raise ValueError("HTTPS proxy endpoints are not supported for DB tunnels; use an http:// proxy URL")
        self.proxy_host = parsed.hostname
        self.proxy_port = parsed.port or 80
        self.target_host = target_host
        self.target_port = target_port
        self._server: socket.socket | None = None
        self._stop = threading.Event()
        self.local_port = 0

    def start(self) -> "HTTPConnectTunnel":
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(8)
        self._server = srv
        self.local_port = srv.getsockname()[1]
        threading.Thread(target=self._accept_loop, daemon=True).start()
        return self

    def close(self) -> None:
        self._stop.set()
        if self._server:
            try:
                self._server.close()
            except OSError:
                pass

    def _accept_loop(self) -> None:
        assert self._server is not None
        while not self._stop.is_set():
            try:
                client, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._handle_client, args=(client,), daemon=True).start()

    def _handle_client(self, client: socket.socket) -> None:
        upstream: socket.socket | None = None
        try:
            upstream = socket.create_connection((self.proxy_host, self.proxy_port), timeout=15)
            request = (
                f"CONNECT {self.target_host}:{self.target_port} HTTP/1.1\r\n"
                f"Host: {self.target_host}:{self.target_port}\r\n"
                "Proxy-Connection: Keep-Alive\r\n\r\n"
            ).encode("ascii")
            upstream.sendall(request)
            response = b""
            while b"\r\n\r\n" not in response and len(response) < 8192:
                chunk = upstream.recv(1024)
                if not chunk:
                    break
                response += chunk
            if b" 200 " not in response.split(b"\r\n", 1)[0]:
                return
            self._relay(client, upstream)
        except OSError:
            return
        finally:
            for sock in (client, upstream):
                if sock:
                    try:
                        sock.close()
                    except OSError:
                        pass

    def _relay(self, left: socket.socket, right: socket.socket) -> None:
        sockets = [left, right]
        while not self._stop.is_set():
            readable, _, errored = select.select(sockets, [], sockets, 30)
            if errored:
                return
            if not readable:
                continue
            for src in readable:
                try:
                    data = src.recv(65536)
                except OSError:
                    return
                if not data:
                    return
                dst = right if src is left else left
                try:
                    dst.sendall(data)
                except OSError:
                    return


def proxied_db_dsn(args: argparse.Namespace, dsn: str) -> tuple[str, HTTPConnectTunnel] | None:
    proxy_url = args.db_http_proxy or os.environ.get("CODE_SUMMARY_DB_HTTP_PROXY") or os.environ.get("HTTPS_PROXY") or os.environ.get("HTTP_PROXY") or ""
    if not proxy_url:
        return None
    target = db_target_from_dsn(dsn)
    if not target:
        return None
    tunnel = HTTPConnectTunnel(proxy_url, target[0], target[1]).start()
    parsed = urllib.parse.urlsplit(dsn)
    netloc = parsed.netloc
    if "@" in netloc:
        auth = netloc.rsplit("@", 1)[0]
        netloc = f"{auth}@127.0.0.1:{tunnel.local_port}"
    else:
        netloc = f"127.0.0.1:{tunnel.local_port}"
    return urllib.parse.urlunsplit((parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment)), tunnel


def ensure_psycopg():
    try:
        import psycopg  # type: ignore
        from psycopg.types.json import Json  # type: ignore

        return psycopg, Json
    except ModuleNotFoundError:
        cmd = [sys.executable, "-m", "pip", "install", "psycopg[binary]", "-q"]
        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError:
            subprocess.run([*cmd, "--break-system-packages"], check=True)
        import psycopg  # type: ignore
        from psycopg.types.json import Json  # type: ignore

        return psycopg, Json


def write_db(args: argparse.Namespace, summary: dict[str, Any], markdown: str) -> dict[str, Any]:
    dsn = build_db_dsn(args)
    if not dsn:
        return {"enabled": False, "ok": False, "message": "database config not provided"}
    try:
        return write_db_with_dsn(args, dsn, summary, markdown)
    except Exception as direct_exc:
        proxied = proxied_db_dsn(args, dsn)
        if not proxied:
            raise
        proxy_dsn, tunnel = proxied
        try:
            out = write_db_with_dsn(args, proxy_dsn, summary, markdown)
            out["db_proxy"] = "http_connect"
            return out
        except Exception as proxy_exc:
            raise RuntimeError(f"direct DB failed: {direct_exc}; proxy DB failed: {proxy_exc}") from proxy_exc
        finally:
            tunnel.close()


def write_db_with_dsn(args: argparse.Namespace, dsn: str, summary: dict[str, Any], markdown: str) -> dict[str, Any]:
    schema = validate_identifier(args.db_schema)
    psycopg, Json = ensure_psycopg()
    report_id = None
    latest_result = latest_result_rows(summary)
    with psycopg.connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{schema}"')
            cur.execute(
                f"""
                CREATE TABLE IF NOT EXISTS "{schema}".daily_code_reports (
                    id BIGSERIAL PRIMARY KEY,
                    provider TEXT NOT NULL,
                    repo TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    window_start TIMESTAMPTZ NOT NULL,
                    window_end TIMESTAMPTZ NOT NULL,
                    timezone TEXT NOT NULL,
                    markdown TEXT NOT NULL,
                    summary JSONB NOT NULL,
                    tracked_authors JSONB NOT NULL DEFAULT '[]'::jsonb,
                    commit_count INTEGER NOT NULL DEFAULT 0,
                    additions INTEGER NOT NULL DEFAULT 0,
                    deletions INTEGER NOT NULL DEFAULT 0,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    UNIQUE (provider, repo, branch, window_start, window_end)
                )
                """
            )
            cur.execute(
                f"""
                ALTER TABLE "{schema}".daily_code_reports
                ADD COLUMN IF NOT EXISTS tracked_authors JSONB NOT NULL DEFAULT '[]'::jsonb
                """
            )
            cur.execute(
                f"""
                CREATE TABLE IF NOT EXISTS "{schema}".daily_code_author_stats (
                    id BIGSERIAL PRIMARY KEY,
                    report_id BIGINT NOT NULL REFERENCES "{schema}".daily_code_reports(id) ON DELETE CASCADE,
                    author_name TEXT NOT NULL,
                    status TEXT NOT NULL,
                    commit_count INTEGER NOT NULL DEFAULT 0,
                    additions INTEGER NOT NULL DEFAULT 0,
                    deletions INTEGER NOT NULL DEFAULT 0,
                    categories JSONB NOT NULL DEFAULT '{{}}'::jsonb,
                    commits JSONB NOT NULL DEFAULT '[]'::jsonb,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    UNIQUE (report_id, author_name)
                )
                """
            )
            cur.execute(
                f"""
                CREATE TABLE IF NOT EXISTS "{schema}".daily_code_commits (
                    id BIGSERIAL PRIMARY KEY,
                    report_id BIGINT NOT NULL REFERENCES "{schema}".daily_code_reports(id) ON DELETE CASCADE,
                    sha TEXT NOT NULL,
                    short_sha TEXT NOT NULL,
                    title TEXT NOT NULL,
                    author_name TEXT,
                    author_email TEXT,
                    author_username TEXT,
                    committed_at TIMESTAMPTZ,
                    web_url TEXT,
                    additions INTEGER NOT NULL DEFAULT 0,
                    deletions INTEGER NOT NULL DEFAULT 0,
                    category TEXT NOT NULL,
                    payload JSONB NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    UNIQUE (report_id, sha)
                )
                """
            )
            cur.execute(
                f"""
                CREATE TABLE IF NOT EXISTS "{schema}".daily_code_latest_result (
                    id BIGSERIAL PRIMARY KEY,
                    author_name TEXT NOT NULL DEFAULT '',
                    period_text TEXT NOT NULL,
                    report_markdown TEXT NOT NULL
                )
                """
            )
            latest_seq = f'"{schema}".daily_code_latest_result_id_seq'
            latest_table = f'"{schema}".daily_code_latest_result'
            cur.execute(f'CREATE SEQUENCE IF NOT EXISTS {latest_seq}')
            cur.execute(f'ALTER TABLE {latest_table} ADD COLUMN IF NOT EXISTS id BIGINT')
            cur.execute(f'ALTER SEQUENCE {latest_seq} OWNED BY {latest_table}.id')
            cur.execute(f"UPDATE {latest_table} SET id = nextval('{latest_seq}'::regclass) WHERE id IS NULL")
            cur.execute(
                f"""
                SELECT setval(
                    '{latest_seq}'::regclass,
                    GREATEST((SELECT COALESCE(MAX(id), 0) FROM {latest_table}), 1),
                    (SELECT COALESCE(MAX(id), 0) > 0 FROM {latest_table})
                )
                """
            )
            cur.execute(f"ALTER TABLE {latest_table} ALTER COLUMN id SET DEFAULT nextval('{latest_seq}'::regclass)")
            cur.execute(f"ALTER TABLE {latest_table} ALTER COLUMN id SET NOT NULL")
            cur.execute(
                f"""
                DO $$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1
                        FROM pg_constraint
                        WHERE conrelid = '{latest_table}'::regclass
                          AND contype = 'p'
                    ) THEN
                        ALTER TABLE {latest_table}
                        ADD CONSTRAINT daily_code_latest_result_pkey PRIMARY KEY (id);
                    END IF;
                END $$;
                """
            )
            cur.execute(
                f"""
                ALTER TABLE "{schema}".daily_code_latest_result
                ADD COLUMN IF NOT EXISTS author_name TEXT NOT NULL DEFAULT ''
                """
            )
            totals = summary["totals"]
            cur.execute(
                f"""
                INSERT INTO "{schema}".daily_code_reports
                    (provider, repo, branch, window_start, window_end, timezone, markdown, summary, tracked_authors, commit_count, additions, deletions)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (provider, repo, branch, window_start, window_end)
                DO UPDATE SET
                    timezone = EXCLUDED.timezone,
                    markdown = EXCLUDED.markdown,
                    summary = EXCLUDED.summary,
                    tracked_authors = EXCLUDED.tracked_authors,
                    commit_count = EXCLUDED.commit_count,
                    additions = EXCLUDED.additions,
                    deletions = EXCLUDED.deletions,
                    updated_at = now()
                RETURNING id
                """,
                (
                    summary["provider"],
                    summary["repo"],
                    summary["branch"],
                    parse_dt(summary["window_start"]),
                    parse_dt(summary["window_end"]),
                    summary["timezone"],
                    markdown,
                    Json(summary),
                    Json(summary.get("tracked_authors", [])),
                    totals["commit_count"],
                    totals["additions"],
                    totals["deletions"],
                ),
            )
            report_id = cur.fetchone()[0]
            cur.execute(f'DELETE FROM "{schema}".daily_code_author_stats WHERE report_id = %s', (report_id,))
            cur.execute(f'DELETE FROM "{schema}".daily_code_commits WHERE report_id = %s', (report_id,))
            cur.execute(f'DELETE FROM "{schema}".daily_code_latest_result')
            for row in latest_result:
                cur.execute(
                    f'INSERT INTO "{schema}".daily_code_latest_result (author_name, period_text, report_markdown) VALUES (%s, %s, %s)',
                    (row["author_name"], row["period_text"], row["report_markdown"]),
                )
            for author in summary["authors"]:
                cur.execute(
                    f"""
                    INSERT INTO "{schema}".daily_code_author_stats
                        (report_id, author_name, status, commit_count, additions, deletions, categories, commits)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (report_id, author_name)
                    DO UPDATE SET
                        status = EXCLUDED.status,
                        commit_count = EXCLUDED.commit_count,
                        additions = EXCLUDED.additions,
                        deletions = EXCLUDED.deletions,
                        categories = EXCLUDED.categories,
                        commits = EXCLUDED.commits,
                        updated_at = now()
                    """,
                    (
                        report_id,
                        author["name"],
                        author["status"],
                        author["commit_count"],
                        author["additions"],
                        author["deletions"],
                        Json(author["categories"]),
                        Json(author["commits"]),
                    ),
                )
            all_commits = []
            for author in summary["authors"]:
                all_commits.extend(author["commits"])
            all_commits.extend(summary["untracked_commits"])
            for commit in all_commits:
                cur.execute(
                    f"""
                    INSERT INTO "{schema}".daily_code_commits
                        (report_id, sha, short_sha, title, author_name, author_email, author_username,
                         committed_at, web_url, additions, deletions, category, payload)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (report_id, sha)
                    DO UPDATE SET
                        short_sha = EXCLUDED.short_sha,
                        title = EXCLUDED.title,
                        author_name = EXCLUDED.author_name,
                        author_email = EXCLUDED.author_email,
                        author_username = EXCLUDED.author_username,
                        committed_at = EXCLUDED.committed_at,
                        web_url = EXCLUDED.web_url,
                        additions = EXCLUDED.additions,
                        deletions = EXCLUDED.deletions,
                        category = EXCLUDED.category,
                        payload = EXCLUDED.payload,
                        updated_at = now()
                    """,
                    (
                        report_id,
                        commit["sha"],
                        commit["short_sha"],
                        commit["title"],
                        commit["author_name"],
                        commit["author_email"],
                        commit["author_username"],
                        parse_dt(commit["committed_at"]) if commit["committed_at"] else None,
                        commit["web_url"],
                        commit["additions"],
                        commit["deletions"],
                        commit["category"],
                        Json(commit),
                    ),
                )
        conn.commit()
    return {"enabled": True, "ok": True, "report_id": report_id, "schema": schema, "latest_result": latest_result}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate a daily code summary from GitLab, GitHub, or a git remote.")
    parser.add_argument("--provider", choices=["gitlab", "github", "git"], required=True)
    parser.add_argument("--repo", required=True, help="GitLab project id/path, GitHub owner/repo, or git remote URL")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--since", help="ISO-8601 window start. Defaults to previous cutoff window.")
    parser.add_argument("--until", help="ISO-8601 window end. Defaults to previous cutoff window.")
    parser.add_argument("--timezone", default=os.environ.get("CODE_SUMMARY_TIMEZONE", "Asia/Shanghai"))
    parser.add_argument("--cutoff-hour", type=int, default=int(os.environ.get("CODE_SUMMARY_CUTOFF_HOUR", "22")))
    parser.add_argument("--tracked-authors", default=os.environ.get("CODE_SUMMARY_TRACKED_AUTHORS", ""))
    parser.add_argument("--token-env", help="Environment variable that contains provider token")
    parser.add_argument("--gitlab-base-url", default=os.environ.get("GITLAB_BASE_URL", "https://gitlab.com"))
    parser.add_argument("--github-api-base-url", default=os.environ.get("GITHUB_API_BASE_URL", "https://api.github.com"))
    parser.add_argument("--git-depth", type=int, default=int(os.environ.get("CODE_SUMMARY_GIT_DEPTH", "500")))
    parser.add_argument("--git-filter", default=os.environ.get("CODE_SUMMARY_GIT_FILTER", ""))
    parser.add_argument("--git-ssh-key-env", default=os.environ.get("CODE_SUMMARY_GIT_SSH_KEY_ENV", ""))
    parser.add_argument("--git-ssh-command", default=os.environ.get("CODE_SUMMARY_GIT_SSH_COMMAND", ""))
    parser.add_argument("--git-http-username", default=os.environ.get("CODE_SUMMARY_GIT_HTTP_USERNAME", ""))
    parser.add_argument("--git-http-password-env", default=os.environ.get("CODE_SUMMARY_GIT_HTTP_PASSWORD_ENV", ""))
    parser.add_argument("--input-json", help="Local commit JSON for tests or offline runs")
    parser.add_argument("--db-dsn", default="")
    parser.add_argument("--db-host", default="")
    parser.add_argument("--db-port", default="")
    parser.add_argument("--db-name", default="")
    parser.add_argument("--db-user", default="")
    parser.add_argument("--db-password-env", default="")
    parser.add_argument("--db-schema", default=os.environ.get("CODE_SUMMARY_DB_SCHEMA", "public"))
    parser.add_argument(
        "--db-http-proxy",
        default=os.environ.get("CODE_SUMMARY_DB_HTTP_PROXY", "http://proxy.paas.test:7890"),
    )
    parser.add_argument("--db-connect-timeout", type=int, default=int(os.environ.get("CODE_SUMMARY_DB_CONNECT_TIMEOUT", "10")))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.since and args.until:
        since, until = parse_dt(args.since), parse_dt(args.until)
    elif args.since or args.until:
        raise ValueError("--since and --until must be provided together")
    else:
        since, until = default_window(args.timezone, args.cutoff_hour)

    profiles = parse_author_profiles(args.tracked_authors)
    if args.input_json:
        commits = load_input_commits(args.input_json)
    elif args.provider == "gitlab":
        commits = fetch_gitlab_commits(args, since, until)
    elif args.provider == "github":
        commits = fetch_github_commits(args, since, until)
    else:
        commits = fetch_git_commits(args, since, until)

    summary = build_summary(args, commits, profiles, since, until)
    markdown = render_markdown(summary)
    try:
        db_write = write_db(args, summary, markdown)
    except Exception as exc:
        db_write = {"enabled": True, "ok": False, "error": str(exc)}

    latest_result = db_write.get("latest_result") if db_write.get("ok") else None
    latest_markdown = latest_result_markdown(latest_result)
    print(
        json.dumps(
            {
                "ok": True,
                "summary": summary,
                "markdown": markdown,
                "db_write": db_write,
                "latest_result": latest_result,
                "latest_result_markdown": latest_markdown,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
