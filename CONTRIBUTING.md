# Contributing

Thanks for taking the time. This is a small project, so the process is short.

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

- Branch off `main`. Any branch name is fine.
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
