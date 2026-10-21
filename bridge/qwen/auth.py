"""Capture Qwen Chat's short-lived access token in a dedicated browser profile."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import math
import os
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar, Optional
from urllib.parse import urlparse

from playwright.sync_api import Error as PlaywrightError, sync_playwright

from deepseek.auth import LoginRequired as DeepSeekLoginRequired, Session as BrowserSession
from settings import ROOT

CHAT_URL = "https://chat.qwen.ai/"
AUTH_URL = "https://auth.qwen.ai/"
AUTH_REFRESH_URL = AUTH_URL + "api/v2/auths/refresh"
DEFAULT_PROFILE_DIR = Path(os.getenv("QWEN_PROFILE_DIR", ROOT / "session" / "qwen" / "profile"))
DEFAULT_SESSION_FILE = ROOT / "session" / "qwen" / "session.json"
_PROFILE_LOCK = threading.RLock()


def _sync_session_directory(path: Path) -> None:
    if os.name != "nt":
        directory = os.open(Path(path).parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


@contextmanager
def _session_write_lock(path: Path):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    with path.with_suffix(".lock").open("a+b") as lock:
        os.chmod(lock.name, 0o600)
        if os.name == "nt":
            import msvcrt
            if lock.seek(0, 2) == 0:
                lock.write(b"\0")
                lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            if os.name == "nt":
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


class LoginRequired(DeepSeekLoginRequired):
    def __init__(self, message: str = "No valid Qwen Chat session (missing or expired). Run python -m qwen.auth to sign in. QWEN_RENEW_SESSION enables optional pre-request renewal."):
        super().__init__(message)


@dataclass
class Session(BrowserSession):
    COOKIE_DOMAINS: ClassVar[tuple[str, ...]] = ("qwen.ai", "chat.qwen.ai", "auth.qwen.ai")
    expires_at: float = 0

    @property
    def usable(self) -> bool:
        return (isinstance(self.token, str) and bool(self.token.strip())
                and isinstance(self.expires_at, (int, float)) and math.isfinite(self.expires_at)
                and self.expires_at > time.time() + 60)

    def save(self, path: Path = DEFAULT_SESSION_FILE) -> None:
        with _session_write_lock(path):
            super().save(path)
            _sync_session_directory(path)

    def save_if_current(self, expected: "Session", path: Path = DEFAULT_SESSION_FILE,
                        check=None) -> bool:
        with _session_write_lock(path):
            if check is not None:
                check()
            if self.load(path) != expected:
                return False
            super().save(path)
            _sync_session_directory(path)
            return True

    @classmethod
    def load(cls, path: Path = DEFAULT_SESSION_FILE) -> Optional["Session"]:
        return super().load(path)


_READ_SESSION_JS = """() => {
    if (location.origin !== 'https://chat.qwen.ai') return null;
    try {
        const state = JSON.parse(localStorage.getItem('qwen_access_token_state') || 'null');
        if (state && state.version === 1 && typeof state.token === 'string' && state.token.trim())
            return {token: state.token, expires_at: state.expiresAt / 1000};
        const token = localStorage.getItem('token');
        const expires = Number(localStorage.getItem('at_expire_time'));
        return token && token.trim() && expires > 0 ? {token, expires_at: expires / 1000} : null;
    } catch (_) { return null; }
}"""


def _capture(context, page) -> Optional[Session]:
    if urlparse(page.url).hostname != "chat.qwen.ai":
        return None
    try:
        data = page.evaluate(_READ_SESSION_JS)
        if not isinstance(data, dict) or not isinstance(data.get("token"), str) or not data["token"].strip():
            return None
        expires = data.get("expires_at")
        if not isinstance(expires, (int, float)) or not math.isfinite(expires) or expires <= time.time() + 60:
            return None
        cookies = [c for c in context.cookies([CHAT_URL, AUTH_URL, AUTH_REFRESH_URL])
                   if c.get("domain", "").lower().lstrip(".") in Session.COOKIE_DOMAINS]
        return Session(data["token"], cookies, page.evaluate("() => navigator.userAgent"),
                       time.time(), expires_at=expires)
    except PlaywrightError as exc:
        if "Execution context was destroyed" in str(exc) or "navigation" in str(exc).lower():
            return None
        raise


def _launch(p, profile_dir: Path, headless: bool, channel: Optional[str],
            cdp_url: Optional[str] = None):
    """Запускает собственный браузер или подключается к существующему через CDP."""
    if cdp_url:
        browser = p.chromium.connect_over_cdp(cdp_url)
        context = browser.contexts[0] if browser.contexts else browser.new_context()
        return context, browser
    else:
        profile_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        profile_dir.chmod(0o700)
        options = {"headless": headless}
        if channel:
            options["channel"] = channel
        try:
            context = p.chromium.launch_persistent_context(str(profile_dir), **options)
            return context, None
        except PlaywrightError:
            if not channel:
                raise
            options.pop("channel")
            context = p.chromium.launch_persistent_context(str(profile_dir), **options)
            return context, None


def _capture_profile(profile_dir: Path, headless: bool, channel: Optional[str], timeout: float,
                     cdp_url: Optional[str] = None):
    with sync_playwright() as p:
        context, browser = _launch(p, profile_dir, headless, channel, cdp_url=cdp_url)
        try:
            page = context.pages[0] if context.pages else context.new_page()
            try:
                page.goto(CHAT_URL if headless else CHAT_URL + "auth", wait_until="commit", timeout=60000)
            except PlaywrightError:
                if page.is_closed():
                    raise
            if not headless:
                print("[qwen-auth] Sign in to Qwen Chat in this window. Waiting for the session...", flush=True)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                session = _capture(context, page)
                if session:
                    return session
                page.wait_for_timeout(1000)
            return None
        finally:
            if browser:
                browser.close()
            else:
                context.close()


def login(profile_dir: Path = DEFAULT_PROFILE_DIR, session_file: Path = DEFAULT_SESSION_FILE,
          channel: Optional[str] = "chrome", cdp_url: Optional[str] = None) -> Session:
    with _PROFILE_LOCK:
        session = _capture_profile(profile_dir, False, channel, 1800, cdp_url=cdp_url)
        if session is None or not session.usable:
            raise LoginRequired("Qwen Chat sign-in timed out without a valid session.")
        session.save(session_file)
        return session


def keep_open(profile_dir: Path = DEFAULT_PROFILE_DIR, session_file: Path = DEFAULT_SESSION_FILE,
              channel: Optional[str] = "chrome", cdp_url: Optional[str] = None) -> None:
    """Observe one foreground website window; only the website may renew auth."""
    with _PROFILE_LOCK, sync_playwright() as p:
        context, browser = _launch(p, profile_dir, False, channel, cdp_url=cdp_url)
        closed = False

        def on_close(*_):
            nonlocal closed
            closed = True

        page = None
        try:
            context.on("close", on_close)
            page = context.pages[0] if context.pages else context.new_page()
            page.goto(CHAT_URL + "auth", wait_until="commit", timeout=60000)
            print("[qwen-auth] Sign in on the website. Keep this window open; Ctrl+C stops capture.", flush=True)
            last_saved = None
            ready = False
            while not closed and not page.is_closed():
                session = _capture(context, page)
                if session is not None and session.usable:
                    state = (session.token, session.expires_at, session.user_agent,
                             tuple(sorted(json.dumps(cookie, sort_keys=True) for cookie in session.cookies)))
                    if state != last_saved:
                        session.save(session_file)
                        last_saved = state
                        print("[qwen-auth] Valid session saved. Keep the website window open; sessions expire.", flush=True)
                    elif not ready:
                        print("[qwen-auth] Valid session available in this window; sessions expire.", flush=True)
                    ready = True
                else:
                    if ready:
                        print("[qwen-auth] Website session is missing or expired. Waiting for a valid session.", flush=True)
                    ready = False
                page.wait_for_timeout(1000)
            print("[qwen-auth] Website window closed; capture stopped.", flush=True)
        except KeyboardInterrupt:
            print("[qwen-auth] Capture stopped by Ctrl+C.", flush=True)
        except PlaywrightError:
            if closed or (page is not None and page.is_closed()):
                print("[qwen-auth] Website window closed; capture stopped.", flush=True)
            else:
                raise RuntimeError("Browser capture failed; stopped without retry.") from None
        finally:
            if browser:
                browser.close()
            else:
                try:
                    context.close()
                except PlaywrightError:
                    pass


def get_session(profile_dir: Path = DEFAULT_PROFILE_DIR, session_file: Path = DEFAULT_SESSION_FILE,
                allow_interactive: bool = False, force: bool = False,
                channel: Optional[str] = "chromium-headless-shell",
                fallback_channel: Optional[str] = "chrome", allow_refresh: bool = False,
                cdp_url: Optional[str] = None) -> Session:
    with _PROFILE_LOCK:
        cached = Session.load(session_file)
        if not force and cached and cached.usable:
            return cached
        if not allow_refresh:
            raise LoginRequired()
        channels = list(dict.fromkeys([channel] + ([fallback_channel] if fallback_channel else [])))
        for browser_channel in channels:
            try:
                session = _capture_profile(profile_dir, True, browser_channel, 30, cdp_url=cdp_url)
            except (PlaywrightError, OSError, RuntimeError):
                continue
            if session and session.usable:
                session.save(session_file)
                return session
        if allow_interactive:
            return login(profile_dir, session_file, cdp_url=cdp_url)
        raise LoginRequired()


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description="Sign in to Qwen Chat in a visible website window.")
    parser.add_argument("--keep-open", action="store_true",
                        help="Keep the website open and save changed valid sessions until Ctrl+C or window close.")
    parser.add_argument("--cdp-url", type=str, default=None,
                        help="Подключиться к существующему Chromium через CDP (например, http://127.0.0.1:9222).")
    args = parser.parse_args(argv)
    try:
        if args.keep_open:
            keep_open(cdp_url=args.cdp_url)
        else:
            captured = login(cdp_url=args.cdp_url)
            print(f"[qwen-auth] Session saved ({len(captured.cookies)} cookies); sessions expire.", flush=True)
    except KeyboardInterrupt:
        print("[qwen-auth] Capture stopped by Ctrl+C.", flush=True)
    except (PlaywrightError, OSError, RuntimeError):
        print("[qwen-auth] Sign-in capture failed; stopped without retry.", flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()