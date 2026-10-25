# Contributing

Bug reports, numbers that look wrong, and pull requests are welcome. This page
covers how the repository is laid out and what a change needs before it lands.

## Layout

```
manifest.json            plugin manifest (id, bar widget, settings schema)
Panel.qml                bar button and panel; components are inline at the bottom
Main.qml                 discovers and watches the usage records, runs collectors, sync
Agent.qml                one record's file watcher
assets/                  agent marks: <id>.svg, plus <id>-light.svg for light surfaces
bin/collect              runs the bundled collectors, like omarchy-agent-usage-update
bin/omarchy-agent-usage-<agent>   one stdlib-only collector per bundled agent
tests/                   unittest suites, synthetic data only
tools/lint-qml           qmllint against the installed shell
patches/                 fixes for Omarchy's packaged collectors
```

`Panel.qml`, `Main.qml` and `Agent.qml` started as Omarchy 4.0.5's built-in
panel. The first commit imports them unchanged, so
`git diff $(git rev-list --max-parents=0 HEAD) -- Panel.qml` shows every change
this fork made.

## Setup

You need Omarchy 4, Python 3.11 or newer, and
[uv](https://docs.astral.sh/uv/) for the linters.

```bash
make dev      # copy into ~/.config/omarchy/plugins/ and restart the shell
make check    # lint (Python, shell, QML), tests, manifest validation
```

QML changes need `make dev` (the shell does not hot-reload third-party
widgets reliably). A collector change applies on the panel's next refresh,
`r` in the panel.

`tools/lint-qml` catches syntax and import errors. It cannot follow
properties through the inline components (`root.something` that does not
exist passes), so open the panel after a QML change.

## Collectors

A collector is a standalone executable Python script, standard library only,
in the style of Omarchy's own collectors (2-space indent). It writes one record
to `~/.local/state/omarchy/agents/usage/<agent>.json`; the record contract is in
Omarchy's agents panel README and in the README's
[Accuracy](README.md#accuracy) section. Rules every collector keeps:

- **Read-only.** Open SQLite with `?mode=ro` and `PRAGMA query_only=ON`; never
  write into an agent's data directory.
- **Counts, not content.** Never read, store or print prompt or response
  text. Select counts and token fields only.
- **Keep the last good record.** If the source cannot be read, exit non-zero
  and leave the existing record alone.
- **Prove the numbers.** Compare a new collector against something that shares
  no code with it (the agent's own session totals, its shutdown snapshot, a
  plain SQL query) before claiming it is accurate, and say how in DEVLOG.md.

`--print` prints the record instead of writing it, which is the quickest way to
check a change against real data on your own machine.

## Tests

`make test` runs every suite. Tests build their own synthetic databases and
event files; never point a test at a real home directory. When you fix a bug,
add a test that fails without the fix, and check that it does.

## Style

- QML follows the shell: `Style` sizes, `Commons.Color` roles, the bar's font,
  the theme's corner radius. No hard-coded colors or pixel sizes.
- Comments explain why, in full sentences.
- Commit messages are one line in the conventional form (`feat:`, `fix:`,
  `docs:`, `chore:`).
- Record user-visible changes in CHANGELOG.md under Unreleased, and the
  reasoning behind non-obvious ones in DEVLOG.md.

## Releasing

Bump `version` in `manifest.json` and `pyproject.toml`, move the Unreleased
entries in CHANGELOG.md under the new version, tag `vX.Y.Z` and publish a
GitHub release with that section as its notes.
