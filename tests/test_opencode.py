import datetime as dt
import importlib.util
import json
import os
import sqlite3
import tempfile
import time
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "bin" / "omarchy-agent-usage-opencode"
SPEC = importlib.util.spec_from_loader("opencode_collector", SourceFileLoader("opencode_collector", str(SCRIPT)))
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)

NOW_MS = int(time.time() * 1000)


def tokens(i, o, r=0, read=0, write=0):
  return {"input": i, "output": o, "reasoning": r, "cache": {"read": read, "write": write}}


class OpenCodeTests(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.db = Path(self.tmp.name) / "opencode.db"
    self.conn = sqlite3.connect(self.db)
    self.conn.executescript("""
      CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
      CREATE TABLE session_v2 (id TEXT, model TEXT, tokens_input INTEGER, tokens_output INTEGER,
        tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, cost REAL,
        time_created INTEGER, time_updated INTEGER);
      CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, seq INTEGER,
        time_created INTEGER, time_updated INTEGER, data TEXT);
    """)
    # Packaged collectors that only know the 1.x table.
    self.omarchy = Path(self.tmp.name) / "omarchy"
    (self.omarchy / "bin").mkdir(parents=True)
    for name in ("claude", "codex"):
      (self.omarchy / "bin" / f"omarchy-agent-usage-{name}").write_text("SELECT data FROM message\n")
    self.env = mock.patch.dict(os.environ, {"OMARCHY_PATH": str(self.omarchy)})
    self.env.start()

  def tearDown(self):
    self.env.stop()
    self.conn.close()
    self.tmp.cleanup()

  def v1(self, sid, role, provider, model="", toks=None, at=NOW_MS):
    data = {"role": role, "time": {"created": at}}
    if role == "user":
      data["model"] = {"providerID": provider, "modelID": model}
    else:
      data.update(providerID=provider, modelID=model, tokens=toks or tokens(0, 0))
    self.conn.execute("INSERT INTO message VALUES (?, ?, ?, ?, ?)", (f"m{time.time_ns()}", sid, at, at, json.dumps(data)))

  def v2_session(self, sid, provider, model, totals, at=NOW_MS, cost=0.0):
    i, o, r, read, write = totals
    self.conn.execute("INSERT INTO session_v2 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                      (sid, json.dumps({"id": model, "providerID": provider}), i, o, r, read, write, cost, at, at))

  def v2_msg(self, sid, kind, provider="", model="", toks=None, at=NOW_MS):
    data = {"time": {"created": at}}
    if kind == "assistant":
      data.update(model={"providerID": provider, "id": model}, tokens=toks, cost=0)
    self.conn.execute("INSERT INTO session_message VALUES (?, ?, ?, ?, ?, ?, ?)",
                      (f"s{time.time_ns()}", sid, kind, 0, at, at, json.dumps(data)))

  def scan(self):
    self.conn.commit()
    return COLLECTOR.scan_messages(self.db)

  def test_a_migrated_session_counts_once(self):
    self.v1("old", "user", "opencode", "big-pickle")
    self.v1("old", "assistant", "opencode", "big-pickle", tokens(100, 10, 0, 50))
    self.v2_session("old", "opencode", "big-pickle", (100, 10, 0, 50, 0))
    self.v2_msg("old", "user")
    self.v2_msg("old", "assistant", "opencode", "big-pickle", tokens(100, 10, 0, 50))
    stats = self.scan()
    self.assertEqual(stats["modelUsage"]["big-pickle"],
                     {"inputTokens": 100, "outputTokens": 10, "cacheReadInputTokens": 50, "cacheCreationInputTokens": 0})
    self.assertEqual(stats["totalPrompts"], 1)
    self.assertEqual(stats["totalSessions"], 1)

  def test_session_totals_beyond_the_turns_count_on_the_session_model(self):
    # The title request leaves no message row but is in the session totals.
    self.v2_session("s", "opencode", "glm-5.3-flash-free", (1100, 15, 600, 384, 0))
    self.v2_msg("s", "assistant", "opencode", "glm-5.3-flash-free", tokens(1000, 10, 500))
    stats = self.scan()
    self.assertEqual(stats["modelUsage"]["glm-5.3-flash-free"],
                     {"inputTokens": 1100, "outputTokens": 615, "cacheReadInputTokens": 384, "cacheCreationInputTokens": 0})
    self.assertEqual(stats["todayTotalTokens"], 1100 + 615 + 384)

  def test_a_v1_only_session_still_counts(self):
    self.v1("legacy", "assistant", "opencode", "nemotron-3-ultra-free", tokens(8, 2))
    stats = self.scan()
    self.assertEqual(stats["modelUsage"]["nemotron-3-ultra-free"]["inputTokens"], 8)

  def test_native_providers_are_left_to_their_tabs_unless_they_cannot_see_the_session(self):
    self.v1("v1-claude", "assistant", "anthropic", "claude-sonnet-5-5", tokens(5, 5))
    self.v2_session("v2-claude", "anthropic", "claude-sonnet-5-5", (7, 3, 0, 0, 0))
    self.v2_msg("v2-claude", "assistant", "anthropic", "claude-sonnet-5-5", tokens(7, 3))
    self.v2_session("v2-fw", "fireworks-ai", "kimi", (9, 1, 0, 0, 0))
    self.v2_msg("v2-fw", "assistant", "fireworks-ai", "kimi", tokens(9, 1))
    stats = self.scan()
    # 1.x row: the native claude collector counts it. 2.x: nobody else does.
    self.assertEqual(stats["modelUsage"], {"claude-sonnet-5-5 · anthropic": {
      "inputTokens": 7, "outputTokens": 3, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}})

  def test_once_the_natives_read_v2_this_tab_stops_counting_their_providers(self):
    (self.omarchy / "bin" / "omarchy-agent-usage-claude").write_text("FROM session_message\n")
    self.v2_session("v2-claude", "anthropic", "claude-sonnet-5-5", (7, 3, 0, 0, 0))
    self.v2_msg("v2-claude", "assistant", "anthropic", "claude-sonnet-5-5", tokens(7, 3))
    self.assertEqual(self.scan()["modelUsage"], {})

  def test_recent_days_are_token_totals_by_local_day(self):
    yesterday = int((dt.datetime.now() - dt.timedelta(days=1)).timestamp() * 1000)
    self.v2_session("a", "opencode", "m", (10, 0, 0, 0, 0), at=yesterday)
    self.v2_msg("a", "assistant", "opencode", "m", tokens(10, 0), at=yesterday)
    self.v2_session("b", "opencode", "m", (20, 0, 0, 0, 0))
    self.v2_msg("b", "assistant", "opencode", "m", tokens(20, 0))
    days = self.scan()["recentDays"]
    self.assertEqual(len(days), 7)
    self.assertEqual([d["messageCount"] for d in days[-2:]], [10, 20])
    self.assertEqual(days[-1]["date"], dt.date.today().isoformat())


if __name__ == "__main__":
  unittest.main()
