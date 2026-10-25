import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "bin" / "omarchy-agent-usage-hermes"
SPEC = importlib.util.spec_from_loader("hermes_collector", SourceFileLoader("hermes_collector", str(SCRIPT)))
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)

NOW = time.time()
TOKENS = "input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens"


class HermesTests(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.home = Path(self.tmp.name) / "hermes"
    self.home.mkdir()
    self.db = self.home / "state.db"
    self.conn = sqlite3.connect(self.db)
    # The columns the collector reads, as in Hermes v0.22.2's state.db.
    self.conn.executescript(f"""
      CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, model TEXT, billing_provider TEXT,
        started_at REAL, ended_at REAL, actual_cost_usd REAL, estimated_cost_usd REAL,
        input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
        cache_write_tokens INTEGER, reasoning_tokens INTEGER);
      CREATE TABLE session_model_usage (session_id TEXT, model TEXT, billing_provider TEXT, task TEXT,
        first_seen REAL, last_seen REAL, actual_cost_usd REAL, estimated_cost_usd REAL,
        input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
        cache_write_tokens INTEGER, reasoning_tokens INTEGER);
      CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL);
    """)
    self.env = mock.patch.dict(os.environ, {"HERMES_HOME": str(self.home), "XDG_STATE_HOME": str(Path(self.tmp.name) / "state")})
    self.env.start()

  def tearDown(self):
    self.env.stop()
    self.conn.close()
    self.tmp.cleanup()

  def session(self, sid, model, provider, totals=(0, 0, 0, 0, 0), source="cli", at=NOW, actual=0.0, estimated=0.0):
    self.conn.execute(f"INSERT INTO sessions (id, source, model, billing_provider, started_at, ended_at,"
                      f" actual_cost_usd, estimated_cost_usd, {TOKENS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                      (sid, source, model, provider, at, at, actual, estimated, *totals))

  def usage(self, sid, model, provider, totals, task="", at=NOW, actual=0.0, estimated=0.0):
    self.conn.execute(f"INSERT INTO session_model_usage (session_id, model, billing_provider, task, first_seen,"
                      f" last_seen, actual_cost_usd, estimated_cost_usd, {TOKENS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                      (sid, model, provider, task, at, at, actual, estimated, *totals))

  def prompt(self, sid, at=NOW):
    self.conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', 'secret', ?)", (sid, at))

  def record(self):
    self.conn.commit()
    return COLLECTOR.build_record()

  def test_auxiliary_tasks_and_reasoning_count(self):
    self.session("s", "claude-opus-5", "anthropic", (10, 5, 100, 20, 0))
    self.usage("s", "claude-opus-5", "anthropic", (10, 5, 100, 20, 0))
    self.usage("s", "claude-opus-5", "anthropic", (3, 2, 0, 0, 4), task="title_generation")
    rec = self.record()
    self.assertEqual(rec["modelUsage"]["claude-opus-5"],
                     {"inputTokens": 13, "outputTokens": 11, "cacheReadInputTokens": 100, "cacheCreationInputTokens": 20})
    self.assertEqual(rec["todayTotalTokens"], 144)

  def test_sessions_totals_only_stand_in_for_sessions_without_usage_rows(self):
    self.session("old", "claude-opus-5", "anthropic", (1, 1, 1, 1, 1))
    self.session("new", "claude-opus-5", "anthropic", (50, 0, 0, 0, 0))
    self.usage("new", "claude-opus-5", "anthropic", (60, 0, 0, 0, 0))
    rec = self.record()
    self.assertEqual(rec["modelUsage"]["claude-opus-5"]["inputTokens"], 61)
    self.assertEqual(rec["totalSessions"], 2)

  def test_subagent_turns_are_not_prompts_but_their_tokens_count(self):
    self.session("p", "claude-opus-5", "anthropic")
    self.session("c", "claude-opus-5", "anthropic", source="subagent")
    self.usage("c", "claude-opus-5", "anthropic", (5, 5, 0, 0, 0))
    self.prompt("p")
    self.prompt("c")
    rec = self.record()
    self.assertEqual((rec["totalPrompts"], rec["todayPrompts"]), (1, 1))
    self.assertEqual(rec["todayTotalTokens"], 10)

  def test_names_drop_the_vendor_prefix_and_split_a_model_billed_twice(self):
    self.usage("a", "poolside/laguna-s-2.1:free", "nous", (1, 0, 0, 0, 0))
    self.usage("b", "gpt-6", "copilot", (2, 0, 0, 0, 0))
    self.usage("c", "gpt-6", "openrouter", (3, 0, 0, 0, 0))
    usage = self.record()["modelUsage"]
    self.assertEqual(sorted(usage), ["gpt-6 · copilot", "gpt-6 · openrouter", "laguna-s-2.1:free"])

  def test_tier_lists_providers_by_tokens_and_only_real_spend(self):
    self.usage("a", "laguna", "nous", (5, 0, 0, 0, 0), actual=0.5)
    self.usage("b", "claude-opus-5", "anthropic", (50, 0, 0, 0, 0), estimated=9.0)
    self.assertEqual(self.record()["tierLabel"], "Anthropic · Nous · $0.50 / 30d")

  def test_empty_maps_are_objects_and_seven_days_end_today(self):
    rec = self.record()
    self.assertEqual(rec["modelUsage"], {})
    self.assertEqual(rec["todayTokensByModel"], {})
    self.assertEqual(len(rec["recentDays"]), 7)
    self.assertEqual(rec["recentDays"][-1]["date"], time.strftime("%Y-%m-%d"))

  def test_message_text_never_reaches_the_record(self):
    self.prompt("p")
    self.assertNotIn("secret", json.dumps(self.record()))

  def test_an_unreadable_database_keeps_the_last_record(self):
    self.conn.commit()
    target = Path(os.environ["XDG_STATE_HOME"]) / "omarchy" / "agents" / "usage" / "hermes.json"
    target.parent.mkdir(parents=True)
    target.write_text("previous\n")
    self.db.write_bytes(b"not a database")
    proc = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, env=os.environ.copy())
    self.assertNotEqual(proc.returncode, 0)
    self.assertEqual(target.read_text(), "previous\n")


if __name__ == "__main__":
  unittest.main()
