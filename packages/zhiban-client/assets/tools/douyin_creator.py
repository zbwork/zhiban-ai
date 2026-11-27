"""Fetch Douyin works and their verified author. Cookies arrive only on stdin."""

import asyncio
import json
import logging
import re
import sys
from urllib.parse import urlparse

class RequestError(Exception):
    pass


def image_url(image):
    if not isinstance(image, dict):
        return ""
    urls = image.get("url_list")
    for url in urls if isinstance(urls, list) else []:
        if isinstance(url, str) and url.startswith("https://"):
            return url
    return ""


def subtitle_url(video):
    cla = video.get("cla_info") or {}
    tracks = video.get("subtitle_infos") or cla.get("caption_infos") or []
    if isinstance(tracks, dict):
        tracks = [tracks]
    if not isinstance(tracks, list):
        return ""
    candidates = []
    for track in tracks:
        if not isinstance(track, dict):
            continue
        url = track.get("url") or track.get("subtitle_url") or image_url(track)
        if not isinstance(url, str) or not url.startswith("https://"):
            continue
        kind = str(track.get("format") or "").lower()
        if kind and kind not in {"webvtt", "vtt", "srt"}:
            continue
        language = str(track.get("language_code") or track.get("language") or "")
        candidates.append((not language.lower().startswith("zh"), url))
    return min(candidates, key=lambda item: item[0])[1] if candidates else ""


def work_data(work, author_id, allow_coauthored=False):
    author = work.get("author") or {}
    is_publisher = author.get("sec_uid") == author_id
    creators = (work.get("cooperation_info") or {}).get("co_creators") or []
    is_coauthor = allow_coauthored and any(
        isinstance(creator, dict) and creator.get("sec_uid") == author_id
        for creator in creators
    )
    if not is_publisher and not is_coauthor:
        raise RequestError("author_mismatch")
    stats = work.get("statistics") or {}
    video = work.get("video") or {}
    images = work.get("images") or []
    cover = video.get("cover") or video.get("origin_cover")
    if not cover and images:
        cover = images[0]
    return {
        "id": str(work.get("aweme_id") or ""),
        "title": str(work.get("desc") or ""),
        "article_body": str(work.get("desc") or "") if images else "",
        "cover": image_url(cover),
        "images": [url for item in images if (url := image_url(item))],
        "media_url": (image_url(video.get("play_addr_h264")) or
                      image_url(video.get("play_addr"))) if not images else "",
        "subtitle_url": subtitle_url(video) if not images else "",
        "duration_ms": video.get("duration") or work.get("duration") or 0,
        "published_at": work.get("create_time") or 0,
        "pinned": work.get("is_top") in (1, "1"),
        "likes": stats.get("digg_count") or 0,
        "comments": stats.get("comment_count") or 0,
        "collects": stats.get("collect_count") or 0,
        "shares": stats.get("share_count") or 0,
        "publisher": str(author.get("nickname") or ""),
        "publisher_account_id": str(author.get("sec_uid") or ""),
        "coauthored": not is_publisher and is_coauthor,
    }


async def run(request):
    from f2.apps.douyin.handler import DouyinHandler
    from f2.apps.douyin.utils import AwemeIdFetcher

    cookies = request.get("cookie")
    if not isinstance(cookies, str) or not cookies or "\n" in cookies or "\r" in cookies:
        raise RequestError("auth_required")
    handler = DouyinHandler({
        "cookie": cookies,
        "headers": {
            "User-Agent": request.get("user_agent") or "Mozilla/5.0",
            "Referer": "https://www.douyin.com/",
        },
        "proxies": {"http://": None, "https://": None},
        "timeout": 8,
        "max_retries": 1,
        "enable_bark": False,
    })
    author_id = request.get("author_id")
    result = {}
    work_author = {}
    if author_id is not None:
        if not isinstance(author_id, str) or not re.fullmatch(r"[A-Za-z0-9_.=-]{1,256}", author_id):
            raise RequestError("invalid_link")
        if "work_id" in request:
            work_id = request["work_id"]
            if not isinstance(work_id, str) or not re.fullmatch(r"\d{10,24}", work_id):
                raise RequestError("invalid_link")
            request["stage"] = "作品详情"
            detail = (await handler.fetch_one_video(work_id))._to_raw() or {}
            work = detail.get("aweme_detail") or {}
            if str(work.get("aweme_id")) != work_id:
                raise RequestError("empty_response")
            return work_data(work, author_id, allow_coauthored=True)
    else:
        url = urlparse(request.get("url") or "")
        if (url.scheme != "https" or url.hostname not in {
            "v.douyin.com", "www.douyin.com", "www.iesdouyin.com"
        } or url.username or url.password or url.port not in (None, 443)):
            raise RequestError("invalid_link")
        request["stage"] = "短链解析"
        work_id = await AwemeIdFetcher.get_aweme_id(url.geturl())
        if not work_id or not re.fullmatch(r"\d{10,24}", str(work_id)):
            raise RequestError("invalid_link")
        request["stage"] = "作品详情"
        detail = (await handler.fetch_one_video(work_id))._to_raw() or {}
        work = detail.get("aweme_detail") or {}
        work_author = work.get("author") or {}
        author_id = work_author.get("sec_uid")
        if str(work.get("aweme_id")) != str(work_id) or not author_id:
            raise RequestError("empty_response")
        result["work"] = work_data(work, author_id)
    cursor = request.get("cursor", 0)
    count = request.get("count", 12)
    if type(cursor) is not int or cursor < 0 or type(count) is not int or not 1 <= count <= 20:
        raise RequestError("invalid_link")
    request["stage"] = "博主其他作品"
    pages = handler.fetch_user_post_videos(author_id, max_cursor=cursor,
                                           page_counts=count, max_counts=count)
    try:
        page = await anext(pages, None)
    finally:
        await pages.aclose()
    data = page._to_raw() if page is not None else {}
    data = data or {}
    posts = data.get("aweme_list") or []
    if "work" not in result and data.get("has_more") is None:
        raise RequestError("auth_expired")
    next_cursor = data.get("max_cursor")
    if data.get("has_more") and (type(next_cursor) is not int or next_cursor < 0 or next_cursor == cursor):
        raise RequestError("parse_failed")
    result["next_cursor"] = next_cursor if data.get("has_more") else None
    result["posts"] = [work_data(item, author_id, allow_coauthored=True)
                       for item in (posts if "work" not in result else posts[:count])]
    if cursor == 0 or "work" in result or not result["posts"]:
        request["stage"] = "博主资料"
        profile = (await handler.fetch_user_profile(author_id))._to_raw() or {}
        user = profile.get("user") or {}
        if user.get("sec_uid") != author_id:
            raise RequestError("author_mismatch")
        result["author"] = {
            "id": author_id,
            "name": str(user.get("nickname") or ""),
            "bio": str(user.get("signature") or ""),
            "avatar": next((url for source in (user, work_author)
                            for key in ("avatar_thumb", "avatar_medium", "avatar_larger")
                            if (url := image_url(source.get(key)))), ""),
            "followers": user.get("follower_count") or 0,
            "works": user.get("aweme_count") or 0,
        }
    else:
        result["author"] = {"id": author_id, "profile_complete": False}
    return result


def error_response(error, request):
    kind = type(error).__name__
    status = getattr(error, "status_code", None)
    if status is None:
        status = getattr(getattr(error.__context__, "response", None),
                         "status_code", None)
    categories = {
        "APIConnectionError": "connection_failed",
        "APINotFoundError": "not_found",
        "APIRateLimitError": "rate_limited",
        "APITimeoutError": "timeout",
        "APIUnauthorizedError": "auth_expired",
        "APIFilterError": "parse_failed",
        "APIResponseError": "empty_response",
    }
    if isinstance(error, RequestError):
        code = str(error)
    elif isinstance(error, (TimeoutError, asyncio.TimeoutError)):
        code = "timeout"
    elif status == 403:
        code = "forbidden"
    elif status == 429:
        code = "rate_limited"
    elif status in (502, 503, 504):
        code = "upstream_unavailable"
    else:
        code = categories.get(kind, "upstream_error")
    return {
        "ok": False,
        "code": code,
        "kind": kind,
        "status": status if isinstance(status, int) else None,
        "stage": request.get("stage", "请求校验"),
    }


def main():
    output = sys.stdout
    sys.stdout = sys.stderr
    logging.disable(logging.CRITICAL)
    request = {}
    try:
        payload = sys.stdin.buffer.read(131073)
        if len(payload) > 131072:
            raise RequestError("invalid_request")
        decoded = json.loads(payload)
        if not isinstance(decoded, dict):
            raise RequestError("invalid_request")
        request = decoded
        result = asyncio.run(asyncio.wait_for(run(request), 45))
        response = {"ok": True, "data": result}
    except Exception as error:
        response = error_response(error, request)
    print(json.dumps(response, ensure_ascii=False), file=output, flush=True)


if __name__ == "__main__":
    main()
