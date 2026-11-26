import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch


ADAPTER = Path(__file__).resolve().parents[2] / "assets/tools/douyin_creator.py"
SPEC = importlib.util.spec_from_file_location("douyin_creator", ADAPTER)
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)


class Response:
    def __init__(self, data):
        self.data = data

    def _to_raw(self):
        return self.data


class DouyinAdapterTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.profile_requests = []
        self.page_requests = []
        self.posts = [{"aweme_id": "1234567890123456789", "author": {"sec_uid": "author"}}]
        self.has_more = False
        fixture = self

        class Handler:
            def __init__(self, _):
                pass

            async def fetch_user_profile(self, author_id):
                fixture.profile_requests.append(author_id)
                return Response({"user": {"sec_uid": author_id, "nickname": "演示博主",
                                          "avatar_thumb": {"url_list": None},
                                          "avatar_medium": {"url_list": ["https://p3.douyinpic.com/avatar.jpeg"]}}})

            async def fetch_user_post_videos(self, author_id, *, max_cursor, page_counts, max_counts):
                fixture.page_requests.append((max_cursor, page_counts, max_counts))
                yield Response({
                    "aweme_list": fixture.posts,
                    "has_more": fixture.has_more,
                    "max_cursor": max_cursor + 1,
                })

        handler = types.ModuleType("f2.apps.douyin.handler")
        handler.DouyinHandler = Handler
        utils = types.ModuleType("f2.apps.douyin.utils")
        utils.AwemeIdFetcher = object
        modules = patch.dict(sys.modules, {handler.__name__: handler, utils.__name__: utils})
        modules.start()
        self.addCleanup(modules.stop)

    async def page(self, cursor):
        return await APP.run({"cookie": "synthetic", "author_id": "author", "cursor": cursor})

    async def test_author_page_requests_the_selected_count_and_marks_pinned_posts(self):
        self.posts[0]["is_top"] = 1
        result = await APP.run({
            "cookie": "synthetic", "author_id": "author", "cursor": 0, "count": 4,
        })
        self.assertEqual(self.page_requests, [(0, 4, 4)])
        self.assertTrue(result["posts"][0]["pinned"])

    async def test_reads_profile_on_first_page_and_reuses_identity_later(self):
        profile = (await self.page(0))["author"]
        self.assertEqual(profile["name"], "演示博主")
        self.assertEqual(profile["avatar"], "https://p3.douyinpic.com/avatar.jpeg")
        later = await self.page(1)
        self.assertEqual(later["author"], {"id": "author", "profile_complete": False})
        self.assertEqual(later["posts"][0]["id"], "1234567890123456789")
        self.assertEqual(self.profile_requests, ["author"])

    async def test_empty_page_validates_author_and_missing_auth_is_distinct(self):
        self.posts = []
        self.assertEqual((await self.page(1))["author"]["name"], "演示博主")
        self.assertEqual(self.profile_requests, ["author"])
        self.has_more = None
        with self.assertRaisesRegex(APP.RequestError, "auth_expired"):
            await self.page(2)
        self.assertEqual(self.profile_requests, ["author"])

    async def test_each_post_still_requires_author_or_coauthor(self):
        self.posts[0]["author"]["sec_uid"] = "different-author"
        with self.assertRaisesRegex(APP.RequestError, "author_mismatch"):
            await self.page(1)
        self.posts[0]["cooperation_info"] = {"co_creators": [{"sec_uid": "author"}]}
        self.assertTrue((await self.page(1))["posts"][0]["coauthored"])
        self.assertEqual(self.profile_requests, [])


class DouyinErrorTest(unittest.TestCase):
    def test_reports_upstream_unavailability_without_exposing_response(self):
        class APIResponseError(RuntimeError):
            def __init__(self, status):
                super().__init__("诊断地址 https://example.invalid/?cookie=sensitive")
                self.status_code = status

        for status, expected in ((502, "upstream_unavailable"),
                                 (503, "upstream_unavailable"),
                                 (504, "upstream_unavailable"),
                                 (200, "empty_response"),
                                 (429, "rate_limited")):
            with self.subTest(status=status):
                self.assertEqual(APP.error_response(APIResponseError(status),
                                                    {"stage": "博主其他作品"}),
                                 {"ok": False, "code": expected, "kind": "APIResponseError",
                                  "status": status, "stage": "博主其他作品"})


if __name__ == "__main__":
    unittest.main()
