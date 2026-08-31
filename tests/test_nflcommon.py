"""Tests for the filesystem plumbing shared by the NFL helper scripts.

The module's job is to be unsurprising when the directory it works in is not
what it expects: a symlink where a file should be, a file somebody else owns, a
response that never ends. Those refusals are the behaviour worth pinning down,
so most of what follows builds a hostile directory and checks that the helper
declines rather than proceeds.
"""

import errno
import json
import os
import stat

import nflcommon
import pytest

# --------------------------------------------------------------------------
# state_path
# --------------------------------------------------------------------------

def test_state_path_follows_xdg_state_home(monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", "/somewhere/state")
    assert nflcommon.state_path() == "/somewhere/state/omarchy"


def test_state_path_falls_back_to_home(monkeypatch):
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    monkeypatch.setenv("HOME", "/home/someone")
    assert nflcommon.state_path() == "/home/someone/.local/state/omarchy"


def test_state_path_treats_empty_xdg_as_unset(monkeypatch):
    # An exported but empty XDG_STATE_HOME is common in minimal sessions and
    # must not produce a path rooted at "/omarchy".
    monkeypatch.setenv("XDG_STATE_HOME", "")
    monkeypatch.setenv("HOME", "/home/someone")
    assert nflcommon.state_path() == "/home/someone/.local/state/omarchy"


# --------------------------------------------------------------------------
# open_dir
# --------------------------------------------------------------------------

def test_open_dir_creates_the_directory_private(tmp_path):
    target = tmp_path / "state"
    fd = nflcommon.open_dir(str(target), create=True)
    try:
        assert target.is_dir()
        assert stat.S_IMODE(os.stat(target).st_mode) == 0o700
    finally:
        os.close(fd)


def test_open_dir_refuses_a_symlink(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real)

    # O_NOFOLLOW together with O_DIRECTORY reports ENOTDIR for a symlink on
    # Linux rather than ELOOP. What matters is that it refuses.
    with pytest.raises(OSError) as excinfo:
        nflcommon.open_dir(str(link))
    assert excinfo.value.errno in (errno.ENOTDIR, errno.ELOOP, errno.EMLINK)


def test_open_dir_refuses_a_regular_file(tmp_path):
    plain = tmp_path / "notadir"
    plain.write_text("")

    with pytest.raises(OSError) as excinfo:
        nflcommon.open_dir(str(plain))
    assert excinfo.value.errno == errno.ENOTDIR


def test_open_dir_refuses_a_group_writable_directory(tmp_path):
    target = tmp_path / "shared"
    target.mkdir()
    os.chmod(target, 0o770)  # mkdir(mode=...) would be filtered by the umask

    with pytest.raises(OSError) as excinfo:
        nflcommon.open_dir(str(target))
    assert excinfo.value.errno == errno.EPERM
    assert "writable by others" in str(excinfo.value)


def test_open_dir_refuses_a_world_writable_directory(tmp_path):
    target = tmp_path / "open"
    target.mkdir()
    os.chmod(target, 0o707)

    with pytest.raises(OSError) as excinfo:
        nflcommon.open_dir(str(target))
    assert excinfo.value.errno == errno.EPERM


def test_open_dir_accepts_world_writable_with_sticky_bit(tmp_path):
    # The documented exception: the sticky bit forgives the world-writable bit.
    target = tmp_path / "sticky"
    target.mkdir()
    os.chmod(target, 0o707 | stat.S_ISVTX)

    fd = nflcommon.open_dir(str(target))
    os.close(fd)


def test_open_dir_refuses_group_writable_even_when_sticky(tmp_path):
    """The sticky exception covers the other-writable bit only.

    Worth pinning down because the module docstring names /tmp as the reason
    for the exception, and a real /tmp is 1777 -- group-writable as well as
    sticky -- so this helper would refuse it. Nothing depends on that today:
    state_path() only ever yields a directory under XDG_STATE_HOME or ~, never
    /tmp. This test records the behaviour as it is, so a deliberate change to
    either the check or the docstring shows up here.
    """
    target = tmp_path / "tmplike"
    target.mkdir()
    os.chmod(target, 0o777 | stat.S_ISVTX)

    with pytest.raises(OSError) as excinfo:
        nflcommon.open_dir(str(target))
    assert excinfo.value.errno == errno.EPERM


def test_open_dir_leaves_no_descriptor_behind_when_it_refuses(tmp_path):
    target = tmp_path / "shared"
    target.mkdir()
    os.chmod(target, 0o770)

    before = len(os.listdir("/proc/self/fd"))
    for _ in range(20):
        with pytest.raises(OSError):
            nflcommon.open_dir(str(target))
    after = len(os.listdir("/proc/self/fd"))
    assert after <= before + 1


# --------------------------------------------------------------------------
# read_bounded
# --------------------------------------------------------------------------

@pytest.fixture
def state_dir(tmp_path):
    """An acceptable state directory, plus its descriptor."""
    target = tmp_path / "state"
    fd = nflcommon.open_dir(str(target), create=True)
    yield target, fd
    os.close(fd)


def test_read_bounded_returns_none_when_absent(state_dir):
    _, fd = state_dir
    assert nflcommon.read_bounded(fd, "missing.json") is None


def test_read_bounded_returns_the_bytes(state_dir):
    path, fd = state_dir
    (path / "cache.json").write_bytes(b'{"a": 1}')
    assert nflcommon.read_bounded(fd, "cache.json") == b'{"a": 1}'


def test_read_bounded_refuses_a_symlink(state_dir, tmp_path):
    path, fd = state_dir
    secret = tmp_path / "secret"
    secret.write_text("not yours")
    os.symlink(secret, path / "cache.json")

    with pytest.raises(OSError) as excinfo:
        nflcommon.read_bounded(fd, "cache.json")
    assert excinfo.value.errno == errno.ELOOP


def test_read_bounded_refuses_a_directory(state_dir):
    path, fd = state_dir
    (path / "cache.json").mkdir()

    with pytest.raises(OSError) as excinfo:
        nflcommon.read_bounded(fd, "cache.json")
    assert excinfo.value.errno == errno.EINVAL


def test_read_bounded_refuses_a_file_over_the_cap(state_dir):
    path, fd = state_dir
    (path / "big.json").write_bytes(b"x" * 200)

    with pytest.raises(OSError) as excinfo:
        nflcommon.read_bounded(fd, "big.json", max_bytes=100)
    assert excinfo.value.errno == errno.EFBIG


def test_read_bounded_accepts_a_file_exactly_at_the_cap(state_dir):
    path, fd = state_dir
    (path / "edge.json").write_bytes(b"x" * 100)
    assert nflcommon.read_bounded(fd, "edge.json", max_bytes=100) == b"x" * 100


def test_read_bounded_reads_a_file_larger_than_one_block(state_dir):
    path, fd = state_dir
    payload = os.urandom(200_000)
    (path / "wide.bin").write_bytes(payload)
    assert nflcommon.read_bounded(fd, "wide.bin") == payload


# --------------------------------------------------------------------------
# age_seconds
# --------------------------------------------------------------------------

def test_age_seconds_is_none_when_absent(state_dir):
    _, fd = state_dir
    assert nflcommon.age_seconds(fd, "missing") is None


def test_age_seconds_is_small_for_a_fresh_file(state_dir):
    path, fd = state_dir
    (path / "fresh").write_text("x")
    age = nflcommon.age_seconds(fd, "fresh")
    assert age is not None and 0 <= age < 10


def test_age_seconds_reports_an_old_file(state_dir):
    path, fd = state_dir
    old = path / "old"
    old.write_text("x")
    long_ago = os.stat(old).st_mtime - 3600
    os.utime(old, (long_ago, long_ago))
    assert nflcommon.age_seconds(fd, "old") >= 3500


def test_age_seconds_is_none_for_a_symlink(state_dir, tmp_path):
    path, fd = state_dir
    target = tmp_path / "elsewhere"
    target.write_text("x")
    os.symlink(target, path / "link")
    assert nflcommon.age_seconds(fd, "link") is None


# --------------------------------------------------------------------------
# write_atomic
# --------------------------------------------------------------------------

def test_write_atomic_writes_text_and_bytes(state_dir):
    path, fd = state_dir
    nflcommon.write_atomic(fd, "a.json", "hello")
    nflcommon.write_atomic(fd, "b.json", b"world")
    assert (path / "a.json").read_bytes() == b"hello"
    assert (path / "b.json").read_bytes() == b"world"


def test_write_atomic_replaces_an_existing_file(state_dir):
    path, fd = state_dir
    (path / "cache.json").write_text("old")
    nflcommon.write_atomic(fd, "cache.json", "new")
    assert (path / "cache.json").read_text() == "new"


def test_write_atomic_creates_the_file_private(state_dir):
    path, fd = state_dir
    nflcommon.write_atomic(fd, "cache.json", "x")
    assert stat.S_IMODE(os.stat(path / "cache.json").st_mode) == 0o600


def test_write_atomic_leaves_no_temporary_behind(state_dir):
    path, fd = state_dir
    nflcommon.write_atomic(fd, "cache.json", "x")
    assert sorted(p.name for p in path.iterdir()) == ["cache.json"]


def test_write_atomic_cleans_up_its_temporary_on_failure(state_dir, monkeypatch):
    path, fd = state_dir

    def explode(*args, **kwargs):
        raise RuntimeError("disk went away")

    monkeypatch.setattr(nflcommon.os, "replace", explode)
    with pytest.raises(RuntimeError):
        nflcommon.write_atomic(fd, "cache.json", "x")
    assert list(path.iterdir()) == []


def test_write_atomic_does_not_use_a_predictable_temporary_name(state_dir, monkeypatch):
    # A fixed "<name>.tmp" is a name an attacker can occupy first. Two writes
    # must not reach for the same one.
    path, fd = state_dir
    seen = []
    real_open = nflcommon.os.open

    def record(name, *args, **kwargs):
        if isinstance(name, str) and name.endswith(".tmp"):
            seen.append(name)
        return real_open(name, *args, **kwargs)

    monkeypatch.setattr(nflcommon.os, "open", record)
    nflcommon.write_atomic(fd, "cache.json", "one")
    nflcommon.write_atomic(fd, "cache.json", "two")
    assert len(seen) == 2 and seen[0] != seen[1]


# --------------------------------------------------------------------------
# emit
# --------------------------------------------------------------------------

class _Sink:
    def __init__(self):
        self.written = ""

    def write(self, text):
        self.written += text


def test_emit_passes_a_normal_document_through():
    sink = _Sink()
    nflcommon.emit('{"ok": true}', stream=sink)
    assert sink.written == '{"ok": true}'


def test_emit_decodes_bytes():
    sink = _Sink()
    nflcommon.emit(b'{"ok": true}', stream=sink)
    assert sink.written == '{"ok": true}'


def test_emit_refuses_a_document_over_the_cap(monkeypatch):
    monkeypatch.setattr(nflcommon, "MAX_EMIT_BYTES", 16)
    sink = _Sink()
    nflcommon.emit("x" * 100, stream=sink)
    assert json.loads(sink.written) == {"error": "response too large, refusing to emit"}


def test_emit_measures_bytes_not_characters(monkeypatch):
    # Ten astral characters are 40 bytes, and the cap is in bytes.
    monkeypatch.setattr(nflcommon, "MAX_EMIT_BYTES", 20)
    sink = _Sink()
    nflcommon.emit("\U0001F3C8" * 10, stream=sink)
    assert "error" in json.loads(sink.written)


# --------------------------------------------------------------------------
# load_json_bounded
# --------------------------------------------------------------------------

class _Response:
    def __init__(self, payload):
        self._payload = payload

    def read(self, size):
        chunk, self._payload = self._payload[:size], self._payload[size:]
        return chunk


def test_load_json_bounded_parses_a_document():
    assert nflcommon.load_json_bounded(_Response(b'{"a": 1}')) == {"a": 1}


def test_load_json_bounded_refuses_an_oversized_response():
    with pytest.raises(ValueError, match="larger than"):
        nflcommon.load_json_bounded(_Response(b"x" * 200), max_bytes=100)


def test_load_json_bounded_accepts_a_response_exactly_at_the_cap():
    payload = b'{"a": "%s"}' % (b"x" * 90)
    assert nflcommon.load_json_bounded(payload and _Response(payload),
                                       max_bytes=len(payload))["a"] == "x" * 90


def test_load_json_bounded_replaces_undecodable_bytes():
    # A truncated multi-byte sequence must not raise UnicodeDecodeError; the
    # helper is meant to fail on JSON grounds if at all.
    with pytest.raises(json.JSONDecodeError):
        nflcommon.load_json_bounded(_Response(b'{"a": "\xff\xfe"'))
