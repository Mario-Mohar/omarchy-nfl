"""Tests for bin/nfl-data against recorded-shape ESPN responses.

Nothing here reaches ESPN: `get` is replaced by a lookup into tests/fixtures/espn,
and the cache goes to a temporary directory.
"""

import importlib.machinery
import importlib.util
import json
import os
import sys
import time
import urllib.error
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
ESPN = Path(__file__).resolve().parent / "fixtures" / "espn"


def load_nfl_data():
    path = str(REPO_ROOT / "bin" / "nfl-data")
    loader = importlib.machinery.SourceFileLoader("nfl_data", path)
    spec = importlib.util.spec_from_loader("nfl_data", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


nfl_data = load_nfl_data()


def fixture_for(url):
    if "/standings" in url:
        return "standings.json"
    if "seasontype=" in url:
        return "schedule-seasontype-%s.json" % url.rsplit("seasontype=", 1)[1]
    if url.endswith("/schedule"):
        return "schedule.json"
    raise AssertionError("unexpected URL %s" % url)


class FakeESPN:
    """Serves fixtures; any URL containing a string in `failing` raises."""

    def __init__(self):
        self.failing = set()
        self.calls = []

    def __call__(self, url):
        self.calls.append(url)
        if any(part in url for part in self.failing):
            raise urllib.error.URLError("simulated outage")
        return json.loads((ESPN / fixture_for(url)).read_text())


@pytest.fixture
def espn(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    fake = FakeESPN()
    monkeypatch.setattr(nfl_data, "get", fake)
    return fake


def run(monkeypatch, capsys, *args):
    monkeypatch.setattr(sys, "argv", ["nfl-data", *args])
    code = nfl_data.main()
    out = capsys.readouterr().out
    return code, (json.loads(out) if out.strip() else None)


def test_full_fetch_is_cached(espn, monkeypatch, capsys, tmp_path):
    cache = tmp_path / "nfl-sf.json"
    code, data = run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache))
    assert code == 0
    assert len(data["games"]) == 19
    assert len(data["standings"]["division"]) == 4
    assert json.loads(cache.read_text())["games"] == data["games"]


# --------------------------------------------------------------------------
# Issue #10: a short ESPN error must not replace a good cache
# --------------------------------------------------------------------------

def test_failed_parts_keep_the_good_cache(espn, monkeypatch, capsys, tmp_path):
    cache = tmp_path / "nfl-sf.json"
    run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache))
    good = cache.read_text()
    old = 1_000_000_000
    os.utime(cache, (old, old))

    espn.failing = {"seasontype=2", "/standings"}
    code, data = run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache), "--max-age", "0")

    assert code == 0
    # The missing parts are filled from the cache, not shown as empty ...
    assert len(data["games"]) == 19
    assert len(data["standings"]["division"]) == 4
    assert data["record"] == {"wins": 7, "losses": 1, "ties": 0}
    # ... and the cache is left alone, age included, so the next run retries.
    assert cache.read_text() == good
    assert int(cache.stat().st_mtime) == old


def test_failed_parts_without_a_cache_still_show_what_arrived(espn, monkeypatch, capsys, tmp_path):
    cache = tmp_path / "nfl-sf.json"
    espn.failing = {"seasontype=2", "/standings"}
    code, data = run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache))

    assert code == 0
    assert len(data["games"]) == 3
    assert data["standings"]["division"] == []
    assert not cache.exists()


def test_cache_from_another_season_is_not_mixed_in(espn, monkeypatch, capsys, tmp_path):
    cache = tmp_path / "nfl-sf.json"
    run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache))
    stale = json.loads(cache.read_text())
    stale["season"] = 2025
    cache.write_text(json.dumps(stale))

    espn.failing = {"seasontype=2"}
    code, data = run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache), "--max-age", "0")
    assert code == 0
    assert len(data["games"]) == 3
    assert json.loads(cache.read_text())["season"] == 2025


def test_failed_first_request_serves_the_stale_cache(espn, monkeypatch, capsys, tmp_path):
    cache = tmp_path / "nfl-sf.json"
    run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache))
    good = cache.read_text()

    espn.failing = {"/teams/sf/schedule"}
    code, data = run(monkeypatch, capsys, "--team", "sf", "--cache", str(cache), "--max-age", "0")
    assert code == 0
    assert len(data["games"]) == 19
    assert cache.read_text() == good


def test_get_gives_up_on_a_response_that_trickles(monkeypatch):
    """Each byte arrives well inside the socket timeout; the whole never ends."""
    import socket
    import threading

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    stop = threading.Event()

    def trickle():
        conn, _ = listener.accept()
        try:
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n")
            while not stop.is_set():
                conn.sendall(b" ")
                time.sleep(0.1)
        except OSError:
            pass
        finally:
            conn.close()

    threading.Thread(target=trickle, daemon=True).start()
    monkeypatch.setattr(nfl_data, "REQUEST_DEADLINE", 1)
    started = time.monotonic()
    try:
        with pytest.raises(nfl_data.FETCH_ERRORS):
            nfl_data.get("http://127.0.0.1:%d/" % listener.getsockname()[1])
    finally:
        stop.set()
        listener.close()
    assert time.monotonic() - started < 5


def test_get_refuses_redirects_without_reading_the_body(monkeypatch):
    """A 302 with an endless body must fail fast instead of being drained."""
    import socket
    import threading

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    stop = threading.Event()
    sent = []

    def redirect():
        conn, _ = listener.accept()
        try:
            conn.sendall(
                b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\n"
                b"Content-Length: 1000000000\r\n\r\n"
            )
            chunk = b"x" * 65536
            while not stop.is_set():
                conn.sendall(chunk)
                sent.append(len(chunk))
        except OSError:
            pass
        finally:
            conn.close()

    threading.Thread(target=redirect, daemon=True).start()
    started = time.monotonic()
    try:
        with pytest.raises(urllib.error.HTTPError) as err:
            nfl_data.get("http://127.0.0.1:%d/" % listener.getsockname()[1])
        assert err.value.code == 302
        err.value.close()
    finally:
        stop.set()
        listener.close()
    assert time.monotonic() - started < 5
    # Only what the socket buffers took before the client gave up, not the body.
    assert sum(sent) < 50 * 1024 * 1024


@pytest.mark.parametrize("value, expected", [
    (1, 1), (18, 18), (nfl_data.MAX_WEEK, nfl_data.MAX_WEEK),
    (0, 0), (-3, 0), (nfl_data.MAX_WEEK + 1, 0), (1000000000, 0),
    ("5", 0), (5.0, 0), (True, 0), (None, 0), ([1], 0),
])
def test_week_number_keeps_only_plausible_weeks(value, expected):
    assert nfl_data.week_number(value) == expected
