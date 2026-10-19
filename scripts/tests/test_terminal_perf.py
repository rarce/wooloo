import importlib.util
import io
from unittest.mock import patch
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location('terminal', Path(__file__).resolve().parents[1] / 'terminal-perf.py')
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)


class TerminalMetricsTests(unittest.TestCase):
    def test_redraw_of_previous_phase_is_not_new_phase_arrival_latency(self):
        with tempfile.TemporaryDirectory() as directory:
            metrics, phases = Path(directory) / 'metrics.jsonl', Path(directory) / 'phases.jsonl'
            metrics.write_text('\n'.join(map(json.dumps, [
                dict(e='start', wall_ms=0),
                dict(e='recv', boot='b', proj=1, rev=1, t=0, decode=1, bytes=1, patch=False, cols=10, rows=5),
                dict(e='draw', boot='b', proj=1, rev=1, t=2_000_000, dur=10),
            ])))
            phases.write_text(json.dumps(dict(name='mouse-click', start_ms=1, end_ms=3)))
            result = t.e2e_summary(metrics, phases)[0]
            self.assertEqual(result['frames'], 0)
            self.assertEqual(result['fps_drawn'], 0)
            self.assertIsNone(result['e2e_p50_ms'])
            self.assertEqual(result['draws'], 1)  # local redraw still costs CPU

    def test_sustained_player_repeats_fixture_until_the_requested_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'short.txt'
            path.write_text('a\n')
            clock = [0.0]
            def sleep(seconds):
                clock[0] += seconds
            output = io.StringIO()
            with patch('time.monotonic', side_effect=lambda: clock[0]), patch('time.sleep', side_effect=sleep), patch('sys.stdout', output):
                t.play(path, 10, None, 0.25)
            self.assertEqual(output.getvalue(), 'a\na\na\n\x1b[0m\n')

    def test_empty_stage_and_workspace_runs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'empty.jsonl'
            path.write_text('{}\n')
            for report in [t.bench_report, t.files_report]:
                with self.subTest(report=report.__name__), self.assertRaisesRegex(ValueError, 'empty'):
                    report(path, None)


if __name__ == '__main__':
    unittest.main()
