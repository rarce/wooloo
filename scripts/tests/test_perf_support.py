import contextlib
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from perf_support import compatible


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.config = dict(protocol=1, machine='Mac16,5', os='26.6.2', arch='arm64', cpus=16,
                           fixture_sha256='fixture', toolchain='Xcode', package_revisions={'test': 'pinned'}, cols=200, load_before=2)

    def test_app_revision_and_repetitions_may_change(self):
        compatible(dict(self.config, commit='new', repeat=7), dict(self.config, commit='old', repeat=3),
                   ('cols',), {'decode'}, {'decode'})

    def test_missing_legacy_metadata_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'missing os'):
            compatible(self.config, {'machine': 'Mac16,5'}, (), {'decode'}, {'decode'})

    def test_changed_environment_and_experiment_are_rejected(self):
        for field in ('machine', 'os', 'arch', 'cpus', 'fixture_sha256', 'cols'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, field):
                compatible(dict(self.config, **{field: 'different'}), self.config, ('cols',), {'decode'}, {'decode'})

    def test_missing_and_added_cases_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'missing cases.*new cases'):
            compatible(self.config, self.config, (), {'new'}, {'old'})

    def test_empty_run_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'empty'):
            compatible(self.config, self.config, (), set(), set())

    def test_loaded_host_is_marked(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            compatible(dict(self.config, load_before=14), self.config, (), {'decode'}, {'decode'})
        self.assertIn('WARNING: run host load', output.getvalue())


if __name__ == '__main__':
    unittest.main()
