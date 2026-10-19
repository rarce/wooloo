import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('resources', Path(__file__).resolve().parents[1] / 'perf-resources.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ResourceTests(unittest.TestCase):
    def test_parse_and_select_excludes_other_apps_and_includes_explicit_xpc(self):
        table = r.processes('10 1 100 00:01.50 Mon Oct 19 10:00:00 2026 /app\n'
                            '11 10 200 00:02.00 Mon Oct 19 10:00:00 2026 /child\n'
                            '12 11 300 00:00.50 Mon Oct 19 10:00:00 2026 /grandchild\n'
                            '20 1 400 00:03.00 Mon Oct 19 10:00:00 2026 /WebKit\n'
                            '30 1 500 00:04.00 Mon Oct 19 10:00:00 2026 /other\n')
        self.assertEqual(set(r.select(table, [10])), {10, 11, 12})
        self.assertEqual(set(r.select(table, [10, 20])), {10, 11, 12, 20})
        self.assertEqual(table[10]['rss_bytes'], 102400)
        self.assertEqual(table[10]['cpu_seconds'], 1.5)
        self.assertEqual(r.cpu_seconds('1-01:02:03'), 90123)

    def test_cpu_uses_interval_deltas_and_ignores_reused_pid(self):
        old = {1: dict(cpu_seconds=2, identity='old', rss_bytes=100)}
        new = {1: dict(cpu_seconds=3, identity='old', rss_bytes=200)}
        self.assertEqual(r.sample(new, old, 2)['cpu_percent'], 50)
        new[1]['identity'] = 'new'
        self.assertEqual(r.sample(new, old, 2)['cpu_percent'], 0)
        self.assertIsNone(r.sample(new, {}, 0)['cpu_percent'])


if __name__ == '__main__':
    unittest.main()
