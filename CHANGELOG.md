# Changelog

Notable changes to Agent Usage. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions
follow [Semantic Versioning](https://semver.org/). The reasoning behind each
change is in [DEVLOG.md](DEVLOG.md).

## [Unreleased]

### Added
- The rail follows the widget's side of the bar: a widget in the right section
  gets its rail on the right, under the bar icon.
- `make check`, `make dev` and the rest of a `Makefile` for development.
- `tools/lint-qml`, which lints the panel against the installed Omarchy shell.
- CI on GitHub Actions: the tests on Python 3.11 and 3.14, ruff, shellcheck.
- CONTRIBUTING.md, issue and pull request templates.

### Fixed
- A leftover variable in the Copilot collector's shutdown-snapshot fallback.

## [0.2.0] - 2026-10-25

### Added
- An agent rail down the left edge: one disc per agent, ringed by its fullest
  limit, with an accent marker that slides to the agent on show.
- A forecast under each limit: what the current pace leaves at the reset, or
  how long until it runs out.
- A pace marker on every limit meter, at the window's elapsed time.
- Today's tokens in large type, with prompts and sessions.
- The week as columns, today in the accent.
- Marks for OpenCode, Copilot and Hermes (from Omarchy's `quattro` branch).
- An opening animation: rings sweep and meters fill as the panel opens.

### Changed
- Copilot limits name their monthly window, so they get a pace marker and a
  forecast too.
- The refresh button spins while any collector runs.

### Removed
- The row of text tabs, which truncated agent names past four agents.

## [0.1.0] - 2026-10-25

### Added
- Fork of Omarchy 4.0.5's Agents panel as a third-party plugin that replaces
  the built-in one in place (`omarchy.clonedFrom`).
- Bundled collectors for OpenCode (1.x and 2.x databases), the GitHub Copilot
  CLI (with its quota as limits) and the Hermes Agent, run on the panel's own
  refresh.
- `bin/collect`, which steps aside for any agent an Omarchy release collects
  natively.
- A patch for the packaged Codex collector's `account/read` race.

[Unreleased]: https://github.com/LizinDev/omarchy-agent-usage/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/LizinDev/omarchy-agent-usage/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/LizinDev/omarchy-agent-usage/releases/tag/v0.1.0
