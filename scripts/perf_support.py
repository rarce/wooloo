#!/usr/bin/env python3
"""Metadata and compatibility checks shared by local performance suites."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
import os
import platform
import subprocess
from pathlib import Path


def capture(root, fixtures, ssh_target=""):
    def command(*args):
        return subprocess.check_output(args, text=True).strip()
    digest = hashlib.sha256()
    for name in fixtures:
        digest.update(name.encode() + b'\0')
        digest.update((root / name).read_bytes())
    source_digest = hashlib.sha256()
    for source in sorted([*root.glob('wooloo/**/*.swift'), *root.glob('Vendor/**/*.swift'), root / 'wooloo.xcodeproj/project.pbxproj']):
        source_digest.update(source.relative_to(root).as_posix().encode() + b'\0')
        source_digest.update(source.read_bytes())
    remote = command('ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', ssh_target,
                     "uname -sr; uname -m; getconf _NPROCESSORS_ONLN; git --version") if ssh_target else "local"
    return {
        'recorded_at': datetime.now(timezone.utc).isoformat(),
        'ssh_environment': remote,
        'checkout_sha256': source_digest.hexdigest(),
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
        if current.get(field) is None or baseline.get(field) is None:
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


def verify_sources(current, recorded):
    compatible(current, recorded, ("checkout_sha256", "ssh_environment"), {"sources"}, {"sources"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('fixtures', nargs='+')
    parser.add_argument('--ssh-target', default='')
    parser.add_argument('--verify', type=Path, help='verify captured sources/environment after measuring')
    args = parser.parse_args()
    current = capture(args.root, args.fixtures, args.ssh_target)
    if args.verify:
        recorded = json.loads(args.verify.read_text().splitlines()[0])
        try:
            verify_sources(current, recorded)
        except ValueError as error:
            parser.error("sources or environment changed during measurement: " + str(error))
        verified = dict(sources_verified=True, sources_verified_at=datetime.now(timezone.utc).isoformat())
        if args.verify.suffix == '.jsonl':
            with args.verify.open('a') as output:
                output.write(json.dumps(verified) + "\n")
        else:
            recorded.update(verified)
            args.verify.write_text(json.dumps(recorded) + "\n")
        print('Verified unchanged sources and environment:', args.verify)
    else:
        print(json.dumps(current))


if __name__ == '__main__':
    main()
