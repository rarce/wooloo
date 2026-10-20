import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from concurrency_audit import audit


class ConcurrencyAuditTests(unittest.TestCase):
    root = Path("/private/tmp/audit workspace")

    def log(self, *diagnostics, source="wooloo/BlockingWork.swift"):
        return "\n".join(["    SWIFT_STRICT_CONCURRENCY = complete", f"SwiftCompile normal arm64 {source} (in target 'wooloo' from project 'wooloo')",
                          *diagnostics, "** TEST SUCCEEDED **"])

    def test_relative_and_absolute_paths_identify_migrated_source(self):
        for source in ["wooloo/BlockingWork.swift", str(self.root / "wooloo/BlockingWork.swift")]:
            with self.subTest(source=source):
                diagnostics, guarded, failures = audit(self.log(f"{source}:42:9: warning: unsafe state", source=source), self.root)
                self.assertEqual(len(diagnostics), 1)
                self.assertEqual(len(guarded), 1)
                self.assertTrue(failures)

    def test_same_basename_in_vendor_or_other_checkout_is_not_migrated(self):
        diagnostics, guarded, failures = audit(self.log(
            "Vendor/BlockingWork.swift:4:3: warning: third party",
            "/another/checkout/wooloo/BlockingWork.swift:4:3: error: different checkout"), self.root)
        self.assertEqual(len(diagnostics), 1)
        self.assertFalse(guarded)
        self.assertFalse(failures)

    def test_duplicate_diagnostics_are_counted_once(self):
        warning = "wooloo/BlockingWork.swift:42:9: warning: duplicate"
        diagnostics, guarded, _ = audit(self.log(warning, warning), self.root)
        self.assertEqual(len(diagnostics), 1)
        self.assertEqual(len(guarded), 1)

    def test_all_warning_and_error_wording_is_gated(self):
        for severity, message in [("warning", "sending 'value' risks causing data races"),
                                  ("error", "actor-isolated property cannot be accessed"),
                                  ("warning", "unrelated compiler warning")]:
            with self.subTest(severity=severity, message=message):
                _, guarded, failures = audit(self.log(f"wooloo/BlockingWork.swift:10: {severity}: {message}"), self.root)
                self.assertEqual(len(guarded), 1)
                self.assertTrue(failures)

    def test_empty_truncated_and_incremental_logs_cannot_pass(self):
        for text in ["", "** TEST SUCCEEDED **", self.log().replace("** TEST SUCCEEDED **", ""),
                     self.log(source="Vendor/BlockingWork.swift"),
                     self.log().replace("SWIFT_STRICT_CONCURRENCY = complete", "SWIFT_STRICT_CONCURRENCY = targeted"),
                     self.log(source="/another/checkout/wooloo/BlockingWork.swift")]:
            with self.subTest(text=text):
                self.assertTrue(audit(text, self.root)[2])

    def test_escaped_absolute_compile_path_and_other_file_warning(self):
        source = str(self.root / "wooloo/BlockingWork.swift").replace(" ", "\\ ")
        diagnostics, guarded, failures = audit(self.log("wooloo/Other.swift:2:1: warning: not migrated", source=source), self.root)
        self.assertEqual(len(diagnostics), 1)
        self.assertFalse(guarded)
        self.assertFalse(failures)

    def test_command_exit_status_rejects_missing_log_and_migrated_warning(self):
        script = Path(__file__).resolve().parents[1] / "concurrency_audit.py"
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "build.log"
            command = [sys.executable, str(script), str(log), "--root", str(self.root)]
            missing = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("cannot read", missing.stderr)
            log.write_text(self.log("wooloo/BlockingWork.swift:1:1: warning: sending risks races"))
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)
            log.write_text(self.log())
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
