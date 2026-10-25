import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "omarchy-agent-usage-copilot"
SPEC = importlib.util.spec_from_loader("copilot_collector", SourceFileLoader("copilot_collector", str(SCRIPT)))
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)


class CollectorTests(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.home = Path(self.tmp.name) / "copilot"
    self.sessions = self.home / "session-state"
    self.sessions.mkdir(parents=True)
    self.now = datetime.now().astimezone().replace(microsecond=0)

  def tearDown(self):
    self.tmp.cleanup()

  def write_events(self, name, events, malformed=False):
    directory = self.sessions / name
    directory.mkdir()
    lines = [json.dumps(event) for event in events]
    if malformed:
      lines.insert(1, "{not json")
    (directory / "events.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return directory

  def usage(self, stamp, model="provider/model-a", input_tokens=100, output_tokens=20,
            cache_read=30, cache_write=10, reasoning=5, cost=1):
    return {
      "type": "session.usage_record",
      "timestamp": stamp,
      "data": {"usage": {
        "model": model,
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
        "cacheReadTokens": cache_read,
        "cacheWriteTokens": cache_write,
        "reasoningTokens": reasoning,
        "cost": cost,
      }},
    }

  def test_token_mapping_does_not_double_count_cache_reasoning_or_subagent(self):
    stamp = self.now.isoformat()
    events = [
      self.usage(stamp),
      self.usage(stamp, input_tokens=0, output_tokens=0, cache_read=0, cache_write=0),
      {"type": "subagent.completed", "timestamp": stamp, "data": {"totalTokens": 120}},
      # Every record carries cost 1, yet the session made one premium request.
      {"type": "session.shutdown", "timestamp": stamp,
       "data": {"accountingSnapshot": {"totalPremiumRequestCost": 1.0}}},
    ]
    self.write_events("one", events)
    stats = COLLECTOR.collect_local(self.sessions, self.now)
    self.assertEqual(stats["modelUsage"]["model-a"], {
      "inputTokens": 60,
      "outputTokens": 20,
      "cacheReadInputTokens": 30,
      "cacheCreationInputTokens": 10,
    })
    self.assertEqual(stats["todayTotalTokens"], 120)
    self.assertEqual(stats["totalSessions"], 1)
    self.assertEqual(stats["premiumRequests30d"], 1.0)

  def test_local_day_bucketing_prompts_and_seven_recent_days(self):
    yesterday = self.now - timedelta(days=1)
    old = self.now - timedelta(days=8)
    self.write_events("dates", [
      self.usage(yesterday.astimezone(timezone.utc).isoformat(), input_tokens=10,
                 output_tokens=2, cache_read=3, cache_write=1),
      self.usage(old.isoformat(), input_tokens=5, output_tokens=1, cache_read=0, cache_write=0),
      {"type": "user.message", "timestamp": self.now.isoformat(), "data": {"content": "synthetic"}},
    ])
    stats = COLLECTOR.collect_local(self.sessions, self.now)
    self.assertEqual(len(stats["recentDays"]), 7)
    self.assertEqual(stats["recentDays"][-1]["date"], self.now.strftime("%Y-%m-%d"))
    self.assertEqual(stats["recentDays"][-2]["messageCount"], 12)
    self.assertEqual(stats["todayPrompts"], 1)
    self.assertEqual(stats["activeDays"], 2)

  def test_quota_parsing_limited_unlimited_zero_and_missing(self):
    payload = {
      "copilot_plan": "Free",
      "quota_reset_date": "2030-02-03",
      "quota_snapshots": {
        "premium_interactions": {"unlimited": False, "entitlement": 50, "percent_remaining": 75},
        "chat": {"unlimited": True, "entitlement": 100, "percent_remaining": 10},
        "completions": {"unlimited": False, "entitlement": 0, "percent_remaining": 90},
      },
    }
    parsed = COLLECTOR.parse_quota_response(payload)
    self.assertEqual(parsed["tierLabel"], "Free")
    self.assertEqual(parsed["limits"], [{
      "label": "Premium requests (monthly)",
      "title": "Premium requests",
      "percent": 0.25,
      "resetsAt": "2030-02-03T00:00:00+00:00",
    }])
    missing = COLLECTOR.parse_quota_response({"access_type_sku": "Pro"})
    self.assertEqual(missing["tierLabel"], "Pro")
    self.assertEqual(missing["limits"], [])

  def test_free_sku_wins_over_the_plan_name(self):
    parsed = COLLECTOR.parse_quota_response({
      "copilot_plan": "individual", "access_type_sku": "free_limited_copilot",
      "quota_reset_date_utc": "2030-02-01T00:00:00.000Z",
      "quota_snapshots": {"chat": {"unlimited": False, "entitlement": 200, "percent_remaining": 97.5}},
    })
    self.assertEqual(parsed["tierLabel"], "Free")
    self.assertEqual(parsed["limits"], [{"label": "Chat (monthly)", "title": "Chat", "percent": 0.025, "resetsAt": "2030-02-01T00:00:00+00:00"}])

  def test_session_without_usage_records_falls_back_to_the_shutdown_snapshot(self):
    stamp = self.now.isoformat()
    self.write_events("old", [
      {"type": "user.message", "timestamp": stamp, "data": {}},
      {"type": "session.shutdown", "timestamp": stamp, "data": {"totalPremiumRequests": 2, "modelMetrics": {"gpt-old": {
        "requests": {"count": 2, "cost": 2},
        "usage": {"inputTokens": 150, "outputTokens": 7, "cacheReadTokens": 40, "cacheWriteTokens": 100, "reasoningTokens": 3},
      }}}},
    ])
    # A session that has per-call records ignores its snapshot.
    self.write_events("new", [
      self.usage(stamp, model="gpt-new"),
      {"type": "session.shutdown", "timestamp": stamp, "data": {"accountingSnapshot": {"totalPremiumRequestCost": 1}, "modelMetrics": {"gpt-new": {
        "usage": {"inputTokens": 100, "outputTokens": 20, "cacheReadTokens": 30, "cacheWriteTokens": 10}}}}},
    ])
    stats = COLLECTOR.collect_local(self.sessions, now=self.now)
    self.assertEqual(stats["modelUsage"]["gpt-old"], {
      "inputTokens": 10, "outputTokens": 7, "cacheReadInputTokens": 40, "cacheCreationInputTokens": 100})
    self.assertEqual(stats["modelUsage"]["gpt-new"]["inputTokens"], 60)
    self.assertEqual(stats["totalSessions"], 2)
    self.assertEqual(stats["premiumRequests30d"], 3)

  def test_a_subagent_opening_turn_is_not_a_prompt(self):
    stamp = self.now.isoformat()
    self.write_events("s", [
      {"type": "user.message", "timestamp": stamp, "data": {}},
      {"type": "user.message", "timestamp": stamp, "agentId": "a1", "data": {"parentToolCallId": "c1"}},
      self.usage(stamp),
    ])
    stats = COLLECTOR.collect_local(self.sessions, now=self.now)
    self.assertEqual(stats["totalPrompts"], 1)

  def test_fetch_quota_uses_token_header_and_mocked_http(self):
    response = mock.MagicMock()
    response.__enter__.return_value = response
    response.__exit__.return_value = False
    response.read.return_value = json.dumps({"copilot_plan": "Free"}).encode()
    with mock.patch.object(COLLECTOR, "find_command", return_value="/bin/gh"), \
         mock.patch.object(COLLECTOR.subprocess, "run", return_value=mock.Mock(stdout="secret\n")), \
         mock.patch.object(COLLECTOR.urllib.request, "urlopen", return_value=response) as opened:
      result = COLLECTOR.fetch_quota()
    request = opened.call_args.args[0]
    self.assertEqual(request.get_header("Authorization"), "token secret")
    self.assertEqual(result["tierLabel"], "Free")

  def test_malformed_lines_are_skipped(self):
    self.write_events("broken", [self.usage(self.now.isoformat())], malformed=True)
    stats = COLLECTOR.collect_local(self.sessions, self.now)
    self.assertEqual(stats["todayTotalTokens"], 120)

  def test_unreadable_directory_exits_nonzero_and_preserves_record(self):
    state = Path(self.tmp.name) / "state"
    target = state / "omarchy" / "agents" / "usage" / "copilot.json"
    target.parent.mkdir(parents=True)
    target.write_text("old-record\n", encoding="utf-8")
    self.sessions.chmod(0)
    env = os.environ.copy()
    env.update({"COPILOT_HOME": str(self.home), "XDG_STATE_HOME": str(state)})
    try:
      proc = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True)
    finally:
      self.sessions.chmod(0o700)
    self.assertNotEqual(proc.returncode, 0)
    self.assertEqual(target.read_text(encoding="utf-8"), "old-record\n")

  def test_stdout_is_valid_json_and_does_not_write_record(self):
    self.write_events("stdout", [self.usage(self.now.isoformat())])
    state = Path(self.tmp.name) / "state"
    env = os.environ.copy()
    env.update({"COPILOT_HOME": str(self.home), "XDG_STATE_HOME": str(state), "PATH": ""})
    proc = subprocess.run(
      [sys.executable, str(SCRIPT), "--stdout"], env=env, capture_output=True, text=True, check=True,
    )
    record = json.loads(proc.stdout)
    self.assertEqual(record["id"], "copilot")
    self.assertEqual(record["todayTotalTokens"], 120)
    self.assertFalse((state / "omarchy" / "agents" / "usage" / "copilot.json").exists())


if __name__ == "__main__":
  unittest.main()
