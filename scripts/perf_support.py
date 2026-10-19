#!/usr/bin/env python3
"""Metadata and compatibility checks shared by local performance suites."""
import argparse
import hashlib
import json
import os
import platform
import subprocess
from pathlib import Path


def capture(root, fixtures):
    def command(*args):
        return subprocess.check_output(args, text=True).strip()
    digest = hashlib.sha256()
    for name in fixtures:
        digest.update(name.encode() + b'\0')
        digest.update((root / name).read_bytes())
    return {
        'protocol': 1,
        'machine': command('sysctl', '-n', 'hw.model'),
        'os': platform.mac_ver()[0],
        'arch': platform.machine(),
        'cpus': os.cpu_count(),
        'toolchain': command('xcodebuild', '-version'),
        'package_revisions': {pin['identity']: pin['state']['revision'] for pin in json.loads(
            (root / 'wooloo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']},
        'commit': command('git', '-C', str(root), 'rev-parse', 'HEAD'),
        'dirty': bool(command('git', '-C', str(root), 'status', '--porcelain', '--untracked-files=no')),
        'fixture_sha256': digest.hexdigest(),
        'load_before': os.getloadavg()[0],
    }


def compatible(current, baseline, fields, cases, old_cases):
    """Refuse ratios when the experiment changed; app source/commit may differ."""
    problems = []
    for field in ('protocol', 'machine', 'os', 'arch', 'cpus', 'toolchain', 'package_revisions', 'fixture_sha256', *fields):
        if field not in current or field not in baseline:
            problems.append(f'missing {field} metadata (refresh the reference and rerun)')
        elif current[field] != baseline[field]:
            problems.append(f'incompatible {field}: {current[field]!r} vs {baseline[field]!r}')
    missing, added = set(old_cases) - set(cases), set(cases) - set(old_cases)
    if missing:
        problems.append('missing cases: ' + ', '.join(map(str, sorted(missing))))
    if added:
        problems.append('new cases require a reference: ' + ', '.join(map(str, sorted(added))))
    if not cases or not old_cases:
        problems.append('empty benchmark results')
    if problems:
        raise ValueError('; '.join(problems))
    for label, config in [('run', current), ('baseline', baseline)]:
        values = [config.get('load_before'), config.get('load_after')]
        loads = []
        for value in values:
            try:
                loads.append(float(str(value).strip('{} ').split()[0]))
            except (ValueError, IndexError):
                pass
        if loads and max(loads) > config.get('cpus', 1) * 0.75:
            print(f'WARNING: {label} host load exceeds 75% of logical CPUs; repeat idle before attributing changes.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('fixtures', nargs='+')
    args = parser.parse_args()
    print(json.dumps(capture(args.root, args.fixtures)))


if __name__ == '__main__':
    main()
