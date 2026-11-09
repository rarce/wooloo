import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class NotebookEditableAssetsTests(unittest.TestCase):
    def run_benchmark_stub(self, changed_asset=None):
        with tempfile.TemporaryDirectory(prefix='notebook-bench-contract-') as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'
            scripts.mkdir()
            script = scripts / 'notebook-editable-bench.sh'
            shutil.copyfile(Path(__file__).resolve().parents[1] / script.name, script)
            script.chmod(0o755)
            # Isolate the asset-verification contract from Xcode, machine metadata and timings.
            (scripts / 'perf_support.py').write_text('print("{}")\n')
            (scripts / 'markdown-perf.py').write_text(
                'from pathlib import Path\nPath(__file__).with_name("compared").touch()\n')
            for name in ['wooloo/NotebookAssets/notebook.js', 'Vendor/NotebookPreview/highlight.min.js',
                         'Vendor/NotebookPreview/katex.min.css', 'Vendor/NotebookPreview/fonts/font.woff2']:
                asset = root / name
                asset.parent.mkdir(parents=True, exist_ok=True)
                asset.write_bytes(b'original asset')
            binaries = root / 'bin'
            binaries.mkdir()
            xcode = binaries / 'xcodebuild'
            xcode.write_text('#!/usr/bin/env python3\n'
                             'import os\nfrom pathlib import Path\n'
                             'name=os.environ.get("NOTEBOOK_TEST_CHANGED_ASSET")\n'
                             'if name:\n'
                             '    path=Path(name)\n'
                             '    path.write_bytes(path.read_bytes()+b" changed")\n')
            xcode.chmod(0o755)
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'])
            environment.pop('NOTEBOOK_TEST_CHANGED_ASSET', None)
            if changed_asset:
                environment['NOTEBOOK_TEST_CHANGED_ASSET'] = str(root / changed_asset)
            result = subprocess.run([str(script), '--no-baseline'], env=environment,
                                    capture_output=True, text=True, timeout=20)
            return result, (scripts / 'compared').exists()

    def test_unchanged_renderer_assets_reach_comparison(self):
        result, compared = self.run_benchmark_stub()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(compared)

    def test_changed_application_or_vendor_assets_abort_before_comparison(self):
        for asset in ['wooloo/NotebookAssets/notebook.js', 'Vendor/NotebookPreview/highlight.min.js',
                      'Vendor/NotebookPreview/katex.min.css', 'Vendor/NotebookPreview/fonts/font.woff2']:
            with self.subTest(asset=asset):
                result, compared = self.run_benchmark_stub(asset)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('Notebook assets changed during measurement', result.stdout + result.stderr)
                self.assertFalse(compared)


if __name__ == '__main__':
    unittest.main()
