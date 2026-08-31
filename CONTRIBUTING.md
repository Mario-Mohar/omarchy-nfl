# Contributing

## Contributions are welcome

This is a small project maintained by one person in his spare time, and that is
exactly why an outside pair of eyes is worth a lot. **Finding a bug and writing
it down is a real contribution** — arguably the most useful one, because I only
ever use this on my own machine, with my own setup, and most of what is broken
is broken somewhere I never look.

Three ways to help, in the order of what they cost you:

### 1. Report something that is wrong

Open an issue with the **Bug report** template. It asks for what it does because
each field is something I would otherwise have to come back and ask for, which
costs us both a day.

What actually decides whether a report is useful:

- **What you expected, and what happened instead.** Both halves. "It does not
  work" is the one report I cannot act on.
- **The steps that get there.** If you can reproduce it, say how. If it only
  happened once, say that too — an intermittent bug is still worth knowing about,
  and "I could not reproduce it" is useful information rather than a
  disqualification.
- **Your setup**, as the template asks for it.

Do not polish it. A rough report today beats a perfect one that never gets
written. If in doubt whether something counts as a bug: open it. Deciding that
is my job, not yours.

### 2. Suggest something it should do

Open an issue with the **Feature request** template.

It asks what you are trying to *achieve* before what you want built, and that is
deliberate — not a hoop. Roughly half the time there turns out to be a simpler
answer than the one either of us had in mind, and it only surfaces if I know the
underlying situation.

A wish that gets declined is not a wasted issue. "Not now" and "not in this
project" are answers you will get quickly and with a reason.

### 3. Send a fix or a feature

Very welcome, and you do not need to ask permission for something small.

**For anything bigger than a few lines, open an issue first** — or comment on
the existing one — and say you are working on it. It costs you a sentence and
saves you the case where I fixed the same thing that evening, or where I would
have wanted it solved differently.

Because you cannot push to this repository, the route is through a fork:

```bash
# 1. Fork it on GitHub, then clone your fork
git clone https://github.com/<your-username>/omarchy-nfl.git
cd omarchy-nfl

# 2. A branch. Any name.
git switch -c fix/the-thing

# 3. Change what you came for, then run the checks below

# 4. Push to your fork and open the pull request
git push -u origin fix/the-thing
```

GitHub then offers you the pull request button. Fill in the template, and if it
closes an issue write `Fixes #12` so it closes itself on merge.

## What happens after you send it

1. **The pipeline runs** and posts a comment on your pull request with a table
   of what passed. It updates that same comment on every push, so there is one
   place to look rather than a growing pile.
2. **It labels the pull request** by size and type, and adds `ready-to-merge`
   once everything is green.
3. **On your very first contribution here, the checks wait for me to release
   them.** GitHub does that by default so that a stranger's code cannot use the
   runners unasked. If your pull request sits at "waiting for approval",
   **nothing is broken and you do not need to do anything** — I have to click
   once.
4. **I do the merging.** The default branch takes nothing that has not been
   through a pull request with green checks, and that holds for my own commits
   too.

If a check is red, the run log says which one and why. Ask in the pull request
if it is not obvious — a red pipeline is not a rejection, and quite often it is
the pipeline that is wrong rather than you.

I do this beside a job, so a reply can take a few days. It is not disinterest.

## Getting set up

The plugin is a directory that Omarchy loads. To work on it, clone the
repository and point your installation at the clone:

```bash
git clone https://github.com/Mario-Mohar/omarchy-nfl.git
cd omarchy-nfl
./install
```

`install` copies the plugin into `~/.config/omarchy/plugins/themo.nfl/` and adds
its entry to `shell.json`, backing that file up first. `./uninstall` reverses
both. Neither uses `sudo`, neither downloads anything, and neither writes
outside your own directories.

Only `python3` is required at runtime — the standard library, nothing to
install.

## Running the checks

The pipeline runs exactly what you can run here, so nothing should surprise you
on a pull request:

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install pytest ruff

python3 .github/scripts/check_plugin.py   # manifest.json and textFormat
ruff check .                              # Python lint
pytest tests/ -v                          # tests
shellcheck install uninstall              # shell scripts
```

QML syntax is checked with `qmllint` (`qt6-declarative-dev-tools`). It also
reports unresolved Quickshell imports, which cannot be resolved outside a
running shell — the pipeline only fails on diagnostics tagged `[syntax]`, and
so should you.

## Two rules worth knowing before you write code

**Every `Text` item declares a `textFormat`.** A `Text` without one keeps Qt's
default `AutoText`, which renders HTML-shaped content as rich text inside the
shell process and can make it load a remote image. Anything that displays a
value from ESPN is a hole. The rule is deliberately blunt — *every* `Text`,
including static labels — so that adding one always forces the decision.
`python3 .github/scripts/check_plugin.py` fails on a missing one.

**`manifest.json` and the code have to agree.** Declared entry points must
exist, every schema entry needs a `defaultValue`, an enum's default must be one
of its own options, and `defaults` may not contain a key the schema does not
describe. The marketplace rejects a submission that gets this wrong; the same
check runs here so you find out in seconds instead of in a submission thread.

## Filesystem helpers

`bin/nflcommon.py` is where the helpers read and write state, and it is stricter
than it looks: it refuses a symlink, a directory somebody else owns or others
can write to, a file larger than its cap, and it publishes writes atomically
through a directory descriptor rather than a path. If you add a helper, go
through it rather than calling `open()`. `tests/test_nflcommon.py` documents
what each of those refusals looks like.

## Pull requests

- Branch off `main` **in your fork** (see above). Any branch name is fine.
- Commit messages follow `fix(scope):`, `feat(scope):`, `docs:`, `chore:`.
  The pipeline reads the pull request title's prefix to label it.
- Say what changed and why. If it is user-visible, a screenshot helps.
- The pipeline comments the result on the pull request and updates that comment
  on every push. Green plus not-a-draft gets a `ready-to-merge` label.
- Maintainers can ask for a deeper look by commenting `/claude review` on the
  pull request.

Tests are welcome but not demanded for every change. A bug fix that comes with
the test that would have caught it is the ideal, not the entry fee.

## Reporting something

Use the issue templates. For a bug, the two things that always help are which
compositor and Omarchy version you are on, and what `bin/nfl-data` prints when
you run it by hand.

## Licence

MIT, same as the project. By contributing you agree your work ships under it.
