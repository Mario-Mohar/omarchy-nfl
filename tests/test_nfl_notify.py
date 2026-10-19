"""bin/nfl-notify hands text from ESPN to notify-send.

It has no .py suffix, so it is loaded by path here.
"""

import importlib.machinery
import importlib.util
import subprocess

from conftest import REPO_ROOT


def load_notify():
    path = str(REPO_ROOT / "bin" / "nfl-notify")
    loader = importlib.machinery.SourceFileLoader("nfl_notify", path)
    spec = importlib.util.spec_from_loader("nfl_notify", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


nfl_notify = load_notify()


def test_clean_text_drops_leading_dashes():
    assert nfl_notify.clean_text("--hint=string:x:1") == "hint=string:x:1"
    assert nfl_notify.clean_text("  - Week 1") == "Week 1"
    assert nfl_notify.clean_text("Wild Card - Round") == "Wild Card - Round"


def test_notify_ends_options_before_the_text(monkeypatch):
    calls = []
    monkeypatch.setattr(subprocess, "run", lambda argv, **kw: calls.append(argv))
    nfl_notify.notify("--hint=string:x:1", "-u critical")
    argv = calls[0]
    assert argv[argv.index("--") + 1:] == ["--hint=string:x:1", "-u critical"]
