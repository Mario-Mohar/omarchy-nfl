"""Tests for Model.js, the panel's pure helpers.

Model.js is a QML `.pragma library` script, which is plain JavaScript once that
one line is taken out. Node runs it here; the shell's own engine is not needed
for functions that never touch QML. Skipped where node is not installed.
"""

import copy
import json
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURES = Path(__file__).resolve().parent / "fixtures"
NODE = shutil.which("node")

pytestmark = pytest.mark.skipif(NODE is None, reason="node is not installed")

# Reads the call from stdin rather than argv so a payload of any size fits.
RUNNER = r"""
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8").replace(/^\.pragma library\s*$/m, "");
const call = JSON.parse(fs.readFileSync(0, "utf8"));
const Model = new Function(src + "\nreturn {" + call.exports.join(",") + "};")();
const result = Model[call.fn].apply(null, call.args);
process.stdout.write(JSON.stringify(result === undefined ? null : result));
"""

EXPORTS = ["upcoming", "results", "played", "nextGame", "lastGame", "regularRecordLabel",
           "resultScoreLine", "tooltipText", "barLabel", "cacheMaxAge"]


def model(fn, *args):
    proc = subprocess.run(
        [NODE, "-e", RUNNER, str(REPO_ROOT / "Model.js")],
        input=json.dumps({"fn": fn, "args": list(args), "exports": EXPORTS}),
        capture_output=True, text=True, check=True, timeout=30,
    )
    return json.loads(proc.stdout)


@pytest.fixture
def bills_2022():
    # Trimmed from the Buffalo Bills' 2022 season as bin/nfl-data hands it to
    # the panel. Week 17 at Cincinnati was called off; ESPN reports it as
    # state "post", completed false, STATUS_CANCELED.
    return json.loads((FIXTURES / "bills-2022-payload.json").read_text())


# --------------------------------------------------------------------------
# Issue #11: a cancelled game is not the next game
# --------------------------------------------------------------------------

def test_cancelled_game_is_not_next_once_the_season_is_over(bills_2022):
    assert model("upcoming", bills_2022) == []
    assert model("nextGame", bills_2022) is None
    assert "Next:" not in model("tooltipText", bills_2022)


def test_cancelled_game_is_skipped_for_the_real_next_game(bills_2022):
    data = copy.deepcopy(bills_2022)
    later = data["games"][-1]
    later.update(state="pre", completed=False, teamScore=None, oppScore=None, result="")
    assert model("nextGame", data)["id"] == later["id"]
    assert [g["id"] for g in model("upcoming", data)] == [later["id"]]


def test_cancelled_game_is_listed_with_results_but_kept_out_of_the_record(bills_2022):
    listed = [g["id"] for g in model("results", bills_2022)]
    assert "401437954" in listed
    assert "401437954" not in [g["id"] for g in model("played", bills_2022)]
    assert model("regularRecordLabel", bills_2022) == "2-0"
    assert model("lastGame", bills_2022)["id"] == "401438009"

    cancelled = next(g for g in bills_2022["games"] if g["id"] == "401437954")
    assert model("resultScoreLine", cancelled) == "Canceled"
    played = next(g for g in bills_2022["games"] if g["id"] == "401437964")
    assert model("resultScoreLine", played) == "35:23"


def test_live_game_still_counts_as_upcoming(bills_2022):
    data = copy.deepcopy(bills_2022)
    data["games"][-1].update(state="in", completed=False, result="")
    assert model("nextGame", data)["id"] == data["games"][-1]["id"]


# --------------------------------------------------------------------------
# Issue #9: a timer tick must not be answered from the previous tick's cache
# --------------------------------------------------------------------------

@pytest.mark.parametrize("minutes", [1, 2, 15, 120])
def test_timer_max_age_is_below_the_interval(minutes):
    # The cache is written a little after a tick, so at the next tick it is
    # just under one interval old. Anything accepted at that age would be the
    # previous fetch served again. Half the interval leaves room for a slow
    # fetch on either side.
    interval = minutes * 60
    max_age = model("cacheMaxAge", minutes, "timer")
    assert 0 < max_age <= interval // 2


def test_force_skips_the_cache_and_a_plain_refresh_takes_a_full_interval():
    assert model("cacheMaxAge", 15, "force") == 0
    assert model("cacheMaxAge", 15, "") == 900
