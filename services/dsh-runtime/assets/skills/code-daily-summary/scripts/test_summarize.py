import importlib.util
import json
import sys
import unittest
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from zoneinfo import ZoneInfo


SCRIPT = Path(__file__).with_name("summarize.py")
spec = importlib.util.spec_from_file_location("summarize", SCRIPT)
summarize = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = summarize
spec.loader.exec_module(summarize)


class SummarizeTests(unittest.TestCase):
    def test_default_window_before_cutoff(self):
        now = datetime(2026, 6, 25, 21, 0, tzinfo=ZoneInfo("Asia/Shanghai"))
        since, until = summarize.default_window("Asia/Shanghai", 22, now=now)
        self.assertEqual(since.isoformat(), "2026-06-23T22:00:00+08:00")
        self.assertEqual(until.isoformat(), "2026-06-24T22:00:00+08:00")

    def test_summary_tracks_no_commit_and_untracked(self):
        with TemporaryDirectory() as tmp:
            data = [
                {
                    "sha": "abc123456789",
                    "title": "feat: add report skill",
                    "message": "feat: add report skill",
                    "author_name": "Alice",
                    "author_email": "alice@example.com",
                    "committed_at": "2026-06-25T10:00:00+08:00",
                    "additions": 20,
                    "deletions": 5,
                },
                {
                    "sha": "def123456789",
                    "title": "fix: repair cron trigger",
                    "message": "fix: repair cron trigger",
                    "author_name": "Other",
                    "author_email": "other@example.com",
                    "committed_at": "2026-06-25T11:00:00+08:00",
                    "additions": 3,
                    "deletions": 1,
                },
            ]
            path = Path(tmp) / "commits.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            args = summarize.build_parser().parse_args(
                [
                    "--provider",
                    "gitlab",
                    "--repo",
                    "group/project",
                    "--since",
                    "2026-06-24T22:00:00+08:00",
                    "--until",
                    "2026-06-25T22:00:00+08:00",
                    "--tracked-authors",
                    "Alice=alice@example.com;Other=other@example.com;Bob=bob@example.com",
                    "--input-json",
                    str(path),
                ]
            )
            commits = summarize.load_input_commits(str(path))
            profiles = summarize.parse_author_profiles(args.tracked_authors)
            summary = summarize.build_summary(args, commits, profiles, summarize.parse_dt(args.since), summarize.parse_dt(args.until))
            markdown = summarize.render_markdown(summary)
            self.assertEqual(summary["totals"]["commit_count"], 2)
            self.assertEqual(
                summary["tracked_authors"],
                [
                    {"name": "Alice", "aliases": ["alice@example.com"]},
                    {"name": "Other", "aliases": ["other@example.com"]},
                    {"name": "Bob", "aliases": ["bob@example.com"]},
                ],
            )
            self.assertEqual(summary["authors"][0]["status"], "submitted")
            self.assertEqual(summary["authors"][1]["status"], "submitted")
            self.assertEqual(summary["authors"][2]["status"], "no_commit")
            self.assertEqual(len(summary["untracked_commits"]), 0)
            self.assertIn("Bob", markdown)
            self.assertIn("# 代码地址：group/project (main)", markdown)
            self.assertIn("一、功能开发（新增能力）", markdown)
            self.assertIn("二、问题修复（体验/稳定性）", markdown)
            self.assertIn("提交数和行数包含 Merge / 同步类提交", markdown)
            self.assertNotIn("代码变更 +", markdown)
            latest_rows = summarize.latest_result_rows(summary)
            self.assertEqual([row["author_name"] for row in latest_rows], ["Alice", "Other", "Bob"])
            self.assertIn("人员：alice@example.com (Alice)", latest_rows[0]["report_markdown"])
            self.assertIn("新增 report skill", latest_rows[0]["report_markdown"])
            self.assertNotIn("repair cron trigger", latest_rows[0]["report_markdown"])
            self.assertIn("当日未提交代码", latest_rows[2]["report_markdown"])
            latest_markdown = summarize.latest_result_markdown(latest_rows)
            self.assertIsNotNone(latest_markdown)
            self.assertEqual(latest_markdown.count("# 代码地址：group/project (main)"), 3)
            self.assertNotIn("author_name:", latest_markdown)
            self.assertNotIn("report_markdown:", latest_markdown)

    def test_report_items_merge_related_details_without_raw_titles(self):
        commits = [
            {
                "title": "feat: platform tabs with URL sync on ClientVersions page",
                "category": "feature",
                "files": ["apps/agent-bus-admin/src/pages/ClientVersions.tsx"],
            },
            {
                "title": "feat: Windows auto-update via WinSparkle + rename exe to ZhiBanAI",
                "category": "feature",
                "files": ["apps/zhiban-app/windows/runner/main.cpp"],
            },
            {
                "title": "feat: query macOS update via Sparkle appcast for sidebar indicator",
                "category": "feature",
                "files": ["apps/zhiban-app/macos/Runner/AppDelegate.swift"],
            },
        ]

        grouped = summarize.grouped_report_items(commits)
        feature_text = "\n".join(grouped["feature"])

        self.assertNotIn("platform tabs with URL sync on ClientVersions page：", feature_text)
        self.assertNotIn("Windows auto-update via WinSparkle", feature_text)
        self.assertIn("统一版本号和发布配置管理", feature_text)
        self.assertIn("完善桌面端自动更新链路", feature_text)
        self.assertIn("Windows 接入 WinSparkle 自动更新，macOS 接入 Sparkle appcast 更新检查", feature_text)

    def test_report_topic_prefers_explicit_title_over_incidental_file_paths(self):
        commits = [
            {
                "title": "feat: add agent run observability and usage attribution",
                "category": "feature",
                "files": [
                    "apps/agent-bus-admin/src/pages/BillingPage.tsx",
                    "apps/agent-bus-admin/src/pages/ObservabilityAgentRuns.tsx",
                    "apps/agent-bus-admin/src/pages/ObservabilityConversations.tsx",
                    "docs/handbook/platform/observability-agent-runs.md",
                ],
            }
        ]

        feature_text = "\n".join(summarize.grouped_report_items(commits)["feature"])

        self.assertIn("Agent 全链路追踪与用量归因", feature_text)
        self.assertIn("新增 Agent Runs 运行追踪", feature_text)
        self.assertIn("新增会话维度追踪", feature_text)
        self.assertIn("打通模型用量归因", feature_text)
        self.assertNotIn("用量计费链路", feature_text)

    def test_report_keeps_a2a_as_an_independent_product_topic(self):
        commits = [
            {
                "title": "feat(agent-bus): unify a2a runtime tool context",
                "category": "feature",
                "files": [
                    "apps/agent-bus-admin/src/pages/BillingPage.tsx",
                    "services/agent-bus/internal/service/a2a/service.go",
                    "deploy/hermes-deploy/plugins/zhiban-a2a/__init__.py",
                ],
            },
            {
                "title": "fix(a2a): keep runtime calls agent scoped",
                "category": "fix",
                "files": [
                    "services/agent-bus/internal/transport/http/runtimetools/tools.go",
                ],
            },
        ]

        grouped = summarize.grouped_report_items(commits)
        feature_text = "\n".join(grouped["feature"])
        fix_text = "\n".join(grouped["fix"])

        self.assertIn("A2A 跨 Agent 协作全链路", feature_text)
        self.assertIn("统一 runtime tool 调用上下文", feature_text)
        self.assertIn("打通 OpenClaw 和 Hermes runtime 插件", feature_text)
        self.assertIn("A2A 跨 Agent 协作全链路", fix_text)
        self.assertIn("强化 Agent scope 隔离", fix_text)
        self.assertNotIn("用量计费链路", feature_text)

    def test_generic_title_does_not_inherit_an_incidental_file_topic(self):
        commit = {
            "title": "chore: checkpoint local worktree updates",
            "category": "maintenance",
            "files": [
                "services/agent-bus/internal/service/runtimeprewarm/worker.go",
                "services/agent-bus/internal/domain/billing/billing.go",
                "services/agent-bus/internal/service/chat/knowledge_context.go",
            ],
        }

        topic = summarize.product_summary_topic(commit)

        self.assertTrue(topic["key"].startswith("scope:"))
        self.assertNotIn("预热", topic["summary"])
        self.assertNotIn("计费", topic["summary"])
        self.assertNotIn("知识库", topic["summary"])

if __name__ == "__main__":
    unittest.main()
