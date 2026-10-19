#!/usr/bin/env python3
"""Sample CPU time and RSS for an app and descendants; optionally include known XPC PIDs.

Example: perf-resources.py --pid 123 --include-pid 456 --out build/perf/resources.jsonl
WebKit XPC services may be parented by launchd. Include their PIDs explicitly after identifying
this app's services in Activity Monitor; other apps' WebKit processes are never guessed.
"""
import argparse
import json
import math
import signal
import subprocess
import time
from pathlib import Path


def cpu_seconds(value):
    days, separator, clock = value.rpartition('-')
    parts = [float(part) for part in (clock if separator else value).split(':')]
    total = 0.0
    for part in parts:
        total = total * 60 + part
    return total + (float(days) * 86400 if separator else 0)


def processes(output):
    result = {}
    for line in output.splitlines():
        fields = line.split(None, 9)
        if len(fields) != 10:
            continue
        pid, ppid, rss, cpu, *rest = fields
        result[int(pid)] = dict(ppid=int(ppid), rss_bytes=int(rss) * 1024,
                                cpu_seconds=cpu_seconds(cpu), identity=' '.join(rest[:5]))
    return result


def select(table, roots):
    selected = set(roots) & table.keys()
    while True:
        children = {pid for pid, row in table.items() if row['ppid'] in selected}
        expanded = selected | children
        if expanded == selected:
            return {pid: table[pid] for pid in sorted(selected)}
        selected = expanded


def sample(table, previous, elapsed):
    cpu = sum(max(0, row['cpu_seconds'] - previous[pid]['cpu_seconds'])
              for pid, row in table.items() if pid in previous and row['identity'] == previous[pid]['identity'])
    return dict(rss_bytes=sum(row['rss_bytes'] for row in table.values()),
                cpu_percent=100 * cpu / elapsed if elapsed > 0 else None,
                pids=list(table), processes=len(table),
                cpu_unobserved_processes=sum(1 for pid, row in table.items()
                    if pid not in previous or row['identity'] != previous[pid]['identity']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--include-pid', type=int, action='append', default=[])
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--seconds', type=float, default=0, help='0: until app exits or SIGTERM')
    args = parser.parse_args()
    if not math.isfinite(args.interval) or not math.isfinite(args.seconds) or args.interval < 0.2 or args.seconds < 0:
        parser.error('interval must be >=0.2 seconds; duration must be nonnegative')
    stopping = False
    def stop(*_):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    started = last = time.monotonic()
    previous, samples = {}, []
    with args.out.open('w') as output:
        output.write(json.dumps(dict(kind='config', pid=args.pid, include_pids=args.include_pid,
                                    interval=args.interval, cpu_unit='100% = one core; deltas only for identities present in consecutive samples',
                                    memory='sum of RSS; shared pages can be counted more than once',
                                    scope='app descendants plus explicit PIDs; excludes unlisted launchd XPC services')) + '\n')
        root_identity = None
        explicit_identities = None
        while not stopping:
            table = processes(subprocess.check_output(
                ['ps', '-axo', 'pid=,ppid=,rss=,time=,lstart=,comm='], text=True))
            root = table.get(args.pid)
            if root is None or (root_identity is not None and root['identity'] != root_identity):
                break
            root_identity = root['identity']
            if explicit_identities is None:
                explicit_identities = {pid: table[pid]['identity'] for pid in args.include_pid if pid in table}
                missing = set(args.include_pid) - explicit_identities.keys()
                if missing:
                    parser.error(f'explicit PIDs are not running: {sorted(missing)}')
            explicit_identities = {pid: identity for pid, identity in explicit_identities.items()
                                   if pid in table and table[pid]['identity'] == identity}
            selected = select(table, [args.pid, *explicit_identities])
            now = time.monotonic()
            row = sample(selected, previous, now - last if previous else 0)
            row.update(kind='sample', seconds=now - started, wall_ms=int(time.time() * 1000))
            samples.append(row)
            output.write(json.dumps(row) + '\n')
            output.flush()
            previous, last = selected, now
            if args.seconds and now - started >= args.seconds:
                break
            time.sleep(args.interval)
        if not samples:
            parser.error('no samples: app PID was not running')
        summary = dict(kind='summary', samples=len(samples), seconds=samples[-1]['seconds'],
                       rss_first_bytes=samples[0]['rss_bytes'], rss_last_bytes=samples[-1]['rss_bytes'],
                       rss_peak_bytes=max(row['rss_bytes'] for row in samples),
                       rss_growth_bytes=samples[-1]['rss_bytes'] - samples[0]['rss_bytes'],
                       cpu_peak_percent=max((row['cpu_percent'] for row in samples if row['cpu_percent'] is not None), default=None))
        output.write(json.dumps(summary) + '\n')
        print(json.dumps(summary))


if __name__ == '__main__':
    main()
