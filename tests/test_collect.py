import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / "bin" / "collect"


class CollectRunnerTests(unittest.TestCase):
  """bin/collect, against an empty home: no agent data, no network."""

  def run_collect(self, *args, native=()):
    with tempfile.TemporaryDirectory() as tmp:
      tmp = Path(tmp)
      (tmp / "omarchy" / "bin").mkdir(parents=True)
      for agent in native:
        (tmp / "omarchy" / "bin" / f"omarchy-agent-usage-{agent}").touch()
      env = dict(os.environ, HOME=str(tmp / "home"), XDG_STATE_HOME=str(tmp / "state"),
                 XDG_DATA_HOME=str(tmp / "data"), OMARCHY_PATH=str(tmp / "omarchy"),
                 HERMES_HOME=str(tmp / "hermes"), COPILOT_HOME=str(tmp / "copilot"))
      subprocess.run(["bash", str(RUNNER), *args], env=env, capture_output=True, timeout=60)
      usage = tmp / "state" / "omarchy" / "agents" / "usage"
      return sorted(p.stem for p in usage.glob("*.json")) if usage.is_dir() else []

  def test_every_bundled_collector_runs(self):
    # Copilot has no session directory here, so it fails and writes nothing,
    # exactly as it keeps a last good record when its source is unreadable.
    self.assertEqual(self.run_collect(), ["hermes", "opencode"])

  def test_a_collector_omarchy_ships_takes_over_its_record(self):
    self.assertEqual(self.run_collect(native=("opencode",)), ["hermes"])

  def test_except_and_named_agents_follow_the_packaged_runner(self):
    self.assertEqual(self.run_collect("--except", "hermes"), ["opencode"])
    self.assertEqual(self.run_collect("hermes"), ["hermes"])


if __name__ == "__main__":
  unittest.main()
