"""Shared filesystem plumbing for the NFL plugin's helper scripts.

Everything the helpers read or write lives in one state directory, and every
operation below happens through a descriptor for that directory rather than
through its path. Checking a path and then opening it is two different files as
far as the kernel is concerned: between the two, a symlink can appear where a
regular file used to be. Opening the directory once and working relative to
that descriptor closes the gap, and O_NOFOLLOW refuses a symlink outright.

The size caps exist because the consumer is a QML StdioCollector, which buffers
everything a helper prints before anything looks at it. An upstream response
that never ends would otherwise grow that buffer without limit -- in the helper
and in the shell process both.
"""

import errno
import json
import os
import stat

# ESPN's three schedule responses are a few hundred KB each; the standings are
# smaller. The cap is a backstop against a response that does not end, not a
# tuned budget.
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
# The reduced document is ~17 KB, and the team file a few dozen bytes.
MAX_CACHE_BYTES = 2 * 1024 * 1024
MAX_EMIT_BYTES = 2 * 1024 * 1024


def state_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "omarchy")


def open_dir(path, create=False):
    """A descriptor for a directory we are willing to read and write in.

    Refuses a symlink, something that is not a directory, one owned by somebody
    else, or one other users can write to -- anyone who can write here can also
    put a symlink where our next file is about to go. The sticky bit is the one
    exception, because that is exactly what makes /tmp safe to share.
    """
    if create:
        os.makedirs(path, mode=0o700, exist_ok=True)

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode):
            raise OSError(errno.ENOTDIR, "%s is not a directory" % path)
        if info.st_uid != os.geteuid():
            raise OSError(errno.EPERM,
                          "%s is owned by uid %d, not by you" % (path, info.st_uid))
        if info.st_mode & stat.S_IWGRP or (
                info.st_mode & stat.S_IWOTH and not info.st_mode & stat.S_ISVTX):
            raise OSError(errno.EPERM,
                          "%s is writable by others -- run: chmod 700 %s" % (path, path))
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_bounded(dir_fd, name, max_bytes=MAX_CACHE_BYTES):
    """Contents of one file in the directory, or None if it is not there.

    Every property is asked of the descriptor we actually read from, so nothing
    can be swapped underneath us between the check and the read.
    """
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            raise OSError(errno.ELOOP,
                          "%s is a symlink, refusing to read it" % name) from exc
        raise

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EINVAL, "%s is not a regular file" % name)
        if info.st_uid != os.geteuid():
            raise OSError(errno.EPERM,
                          "%s is owned by uid %d, not by you" % (name, info.st_uid))
        if info.st_size > max_bytes:
            raise OSError(errno.EFBIG,
                          "%s is larger than %d bytes" % (name, max_bytes))

        chunks = []
        remaining = max_bytes + 1
        while remaining > 0:
            block = os.read(fd, min(65536, remaining))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        raw = b"".join(chunks)
        if len(raw) > max_bytes:
            raise OSError(errno.EFBIG,
                          "%s grew past %d bytes while reading" % (name, max_bytes))
        return raw
    finally:
        os.close(fd)


def age_seconds(dir_fd, name):
    """Seconds since the file was written, or None if it is not there."""
    try:
        info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return None
    if not stat.S_ISREG(info.st_mode):
        return None
    import time
    return max(0.0, time.time() - info.st_mtime)


def write_atomic(dir_fd, name, data):
    """Replace one file in the directory, atomically and without a race.

    The temporary name is random and created with O_EXCL and mode 600 from the
    start: a fixed `<name>.tmp` is a name somebody else can occupy first, and
    creating the file before tightening its mode leaves a window in which it
    exists readable. Publication is descriptor-relative, so the rename lands in
    the directory we checked, whatever happened to its path meanwhile.
    """
    if isinstance(data, str):
        data = data.encode("utf-8")

    flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
    tmp = ".%s.%s.tmp" % (name, os.urandom(8).hex())
    fd = os.open(tmp, flags, 0o600, dir_fd=dir_fd)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dir_fd)
        except OSError:
            pass
        raise


def emit(text, stream=None):
    """Print a document, refusing one that outgrew its cap."""
    if stream is None:
        stream = __import__("sys").stdout
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    if len(text.encode("utf-8")) > MAX_EMIT_BYTES:
        text = json.dumps({"error": "response too large, refusing to emit"})
    stream.write(text)


def load_json_bounded(response, max_bytes=MAX_RESPONSE_BYTES):
    """Parse an HTTP response only after it has proven to be a sane size."""
    raw = response.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise ValueError("upstream response larger than %d bytes" % max_bytes)
    return json.loads(raw.decode("utf-8", "replace"))
