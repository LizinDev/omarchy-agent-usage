# Devlog

What was found, decided and measured while building Agent Usage, newest
first. The README says what the plugin does; this says why it is the way it is.

## 2026-10-25 — 0.2.0: the rail

Five directions were mocked up at full size with real numbers (an overview
list, a vertical rail, a card grid, icon-only tabs, a combined day view). The
rail won: it fixes the truncated switcher, shows every agent's state at once,
and leaves the detail page as wide as it can be.

The pieces, and where they come from:

- **Rail.** One 40 px disc per agent with its mark, ringed (Qt Quick Shapes,
  `PathAngleArc`) by its fullest limit: the foreground normally, the accent on
  the agent shown, red from 90%, like the built-in meters. An accent marker
  slides to the agent on show. Agents without a quota keep a bare ring.
- **Hero.** The agent's mark sits in a square tinted with the theme accent at
  12%, and refresh is a matching tinted square whose glyph spins while any
  collector runs. Both follow the tinted squares of Omarchy's own redesigned
  panel on `quattro`.
- **Today.** The day's tokens in the theme's `displayLarge` size, prompts and
  sessions beside it: the first thing worth reading.
- **Limits.** The built-in meter gained the pace marker that `quattro` draws
  for scoped allowances, here at the window's elapsed time, and a forecast
  borrowed from ai-usagebar's macOS dashboard: the current rate projected to
  the reset (`~39% left`), or the time until it runs out, in the urgent color.
  It stays quiet for the first 5% of a window.
- **Week.** Columns instead of rows, today in the accent, empty days on a
  hairline floor (solid backgrounds on empty days read as heavy blocks).
- **Motion.** One orchestrated moment: opening the panel sweeps the rings and
  fills the meters from zero; switching agents fades the page in (220 ms).

Marks: the 4.0.5 package only ships Claude, Codex and Fireworks, so the other
three would all fall back to the same robot glyph on the rail. The OpenCode,
Copilot and Hermes marks come from `quattro`'s assets.

Copilot quotas reset monthly, but their labels ("Chat") named no window, so
the panel could draw neither pace nor forecast. The collector now sends
`label: "Chat (monthly)"` and `title: "Chat"`; the panel reads the window from
the label and shows the title.

The fonts, sizes and colors are the shell's: the bar's font family, the
`Style.font` scale (caption 10 to displayLarge 28), the theme's foreground,
accent and urgent colors, and the theme's corner radius (square on sharp
themes, rounded on others).

## 2026-10-25 — 0.1.0: the fork

### Why a fork

The built-in Agents panel (`omarchy.agents`) lives in `/usr/share/omarchy`
and belongs to the `omarchy` package: any edit there is gone on the next
update. The panel needs a redesign now that it shows six agents (the switcher
already cuts "Claude Code" to "laude Code"), and that needs a home of its own.

`omarchy plugin clone` showed the sanctioned way to do it. A manifest that
declares `omarchy.clonedFrom: "omarchy.agents"` is treated as the built-in's
replacement: `omarchy plugin enable` puts it in the built-in's spot in the
bar, and the plugin registry routes every call aimed at `omarchy.agents` to
it (`PluginRegistry.resolveEnabledId`). Nothing in the panel needed
first-party privileges: it uses the bar, its own settings and ordinary
processes, which third-party widgets get too.

The first commit imports the 4.0.5 panel byte for byte, so every later
change is a reviewable diff against the original.

### Bundling the collectors

OpenCode, Copilot and Hermes started as standalone collectors in
`~/.local/bin`, run by a systemd user timer. That had a gap: the panel's
refresh (`r`) only runs `omarchy-agent-usage-update`, which only knows the
collectors in `$OMARCHY_PATH/bin`, and `/usr/share/omarchy/bin` comes first
in the shell's `PATH`, so a wrapper could not intercept it either.

Inside the plugin the gap closes: `Main.qml` starts `bin/collect` beside the
packaged runner on every refresh, with the same `--force`, `--limits-only`
and `--except` flags. The timer is no longer needed.

### What each source turned out to be

**OpenCode.** The old collector read only the 1.x `message` table, and
OpenCode 2.x stopped writing there: from 22 to 25 October about 3.3 million
tokens never reached the panel. 2.x keeps one `session_message` row per turn
and per-session totals in `session_v2`. Two traps:

- sessions migrated from 1.x exist in both tables with identical sums, so
  each session is read from exactly one of them;
- `session_v2` totals exceed the sum of their turns by one short call (in one
  session +927 input, +9 output, +589 reasoning tokens): the title request,
  which leaves no message row. It is counted on the session's own model,
  dated at the session's last update.

Oracle: per-model sums of `session_v2` totals. Result: equal for all five
models.

**Copilot.** Every API call is a `session.usage_record` event. Codex,
reading the real event files, settled three questions with evidence before
any code depended on them: `inputTokens` already includes cache reads and
writes, `outputTokens` already includes reasoning, and a subagent's calls
are already usage records (their sum matched `subagent.completed.totalTokens`
exactly). Adding any of them again would double count.

Two more surfaced in review: 7 of 10 sessions came from CLI versions (1.0.83
to 1.0.86) that wrote no per-call records at all, only a `session.shutdown`
snapshot, so they now fall back to it; and summing the per-call `cost` gave
27 premium requests where the session's own accounting said 2, because the
cost is a per-request multiplier repeated on every call of that request.

Limits come from the endpoint the Copilot CLI uses. The first draft reported
them on a 0–100 scale; the panel reads a 0–1 fraction (Claude's record says
`0.22`), so 2.5% used would have drawn as 250% and lit the alarm.

Oracle: the shutdown snapshots. Result: equal per model.

**Hermes.** `session_model_usage` has one row per session, model, billing
provider and task, auxiliary tasks included; the `sessions` totals leave
those out (four sessions differed, always lower). So the per-model table is
the source and `sessions` only stands in for a session without rows. A
subagent's "user" turns are written by its parent and are not prompts (11 of
42). Only actual costs reach the tier label: estimates for calls billed to a
subscription are not money spent.

Oracle: SQL over the same tables, and a second implementation written
independently (by GLM-5.3 in a sandbox with synthetic data only) run on the
same real database. Result: identical on every figure.

### Verification habits

- Every claim of "equal" above compares against something that shares no
  code with the collector.
- The tests were checked by breaking the code on purpose (reasoning dropped
  from output, the OpenCode remainder removed, the 1.x/2.x dedupe disabled):
  each break fails a test.
- Real data stays on the machine. Tests use synthetic databases and event
  files; the agents that wrote code saw schemas, not contents.

### Found in Omarchy's own collectors

Checking the bundled numbers meant checking the built-in ones too:

- **Codex "account/read".** The limits card failed 5 times in 6. Probing
  `codex app-server` 0.163 by hand showed the cause: an `account/read` sent
  while the server is still loading the account (the `account/updated`
  notification in the first ~0.3 s) gets no answer until the next request
  arrives, and the collector waits 4 s, then gives up. Sending both requests
  before waiting fixes it (6 in 6); the patch is in `patches/`.
- **Claude output tokens.** Of 6,063 messages, 4,737 span several transcript
  lines and 69 carry partial usage on the first line, which the collector
  keeps: output reads 4.9% low (225k tokens), total 0.01%.
- **OpenCode 2.x on Anthropic/OpenAI providers** is invisible to the Claude
  and Codex collectors, which read only the 1.x table. The OpenCode tab counts
  those sessions, under `<model> · <provider>`, until a packaged collector
  reads `session_message` (the bundled one checks for that string).

### Upstream moved the same week

On 24 October Omarchy's `quattro` branch merged "Add every coding agent and
provider to the agents panel" (#14040): a shared `collectors.py` and native
collectors for some twenty agents, OpenCode, Copilot and Hermes among them,
plus a redesigned panel. None of it is in a release yet. Two consequences:

- `bin/collect` now skips any bundled collector whose agent Omarchy ships, so
  the next release takes over those records instead of fighting over the
  same files;
- the fork stays on the 4.0.5 panel for now (the new one needs `Commons.I18n`
  and a `ShellIpc` type that the 4.0.5 shell does not have) and gets rebased
  on the released one.

### Next

The visual pass. The switcher truncates with six agents; directions to mock
up: an overview-first list with two mini meters per agent, a vertical agent
sidebar, a card grid, icon-only chips, and a combined "today" view across
agents. The upstream redesign is the first reference to study.
