#!/usr/bin/env python3
"""Probe native keyboard input through an isolated Herdr PTY (pane and popup).

Build Debug tests first. Set WOOLOO_HERDR to a Herdr 0.9.5 executable and,
optionally, WOOLOO_DERIVED_DATA. Results are saved in build/perf/keyboard-input.
Only the temporary XDG directories and the wooloo-ui-test session are used.
"""
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time
ROOT = pathlib.Path(__file__).resolve().parent.parent
HERDR = os.environ.get('WOOLOO_HERDR', 'herdr')
DERIVED = os.environ.get('WOOLOO_DERIVED_DATA', str(ROOT / 'build/DerivedData'))
COLLECTOR = str(ROOT / 'scripts/terminal-key-collector.py')
version = subprocess.check_output([HERDR, '--version'], text=True).strip()
if version != 'herdr 0.9.5':
    raise SystemExit('This probe expects Herdr 0.9.5; set WOOLOO_HERDR to that executable')
WORK = pathlib.Path(tempfile.mkdtemp(prefix='wooloo-key-probe-', dir='/private/tmp'))
OUT = ROOT / 'build/perf/keyboard-input'
OUT.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, XDG_CONFIG_HOME=str(WORK / 'c'), XDG_STATE_HOME=str(WORK / 's'), XDG_DATA_HOME=str(WORK / 'd'))
for name in ['HERDR_SOCKET_PATH', 'HERDR_SESSION', 'HERDR_PANE_ID', 'HERDR_WORKSPACE_ID', 'HERDR_TAB_ID', 'HERDR_CONFIG_PATH']:
    env.pop(name, None)
base = WORK / 'c/herdr/sessions/wooloo-ui-test'

def cli(*args):
    r = subprocess.run([HERDR, '--session', 'wooloo-ui-test', *args], env=env, text=True, capture_output=True)
    if r.returncode:
        print(r.stdout, r.stderr, flush=True)
        r.check_returncode()
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return r.stdout

def wait(predicate, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise RuntimeError('Timed out waiting for isolated Herdr')

def key(name, code, chars, mask, legacy, kitty=None, ignoring=None, count=1):
    return {'name': name, 'kind': 'key', 'code': code, 'characters': chars, 'ignoring': ignoring or chars, 'modifiers': mask, 'plain': legacy, 'kitty': kitty, 'count': count}
keys=[
 key('Option+Left',123,'\uf702',4,b'\x1b[1;3D',b'\x1b[1;3D'),
 key('Option+Right',124,'\uf703',4,b'\x1b[1;3C',b'\x1b[1;3C'),
 key('Option+Backspace',51,'\x7f',4,b'\x1b\x7f',b'\x1b[127;3u'),
 key('Ctrl+Left',123,'\uf702',2,b'\x1b[1;5D',b'\x1b[1;5D'),
 key('Ctrl+Right',124,'\uf703',2,b'\x1b[1;5C',b'\x1b[1;5C'),
 key('Shift+Enter',36,'\r',1,b'\r',b'\x1b[13;2u'),
 key('Ctrl+Shift+A',0,'\x01',3,b'\x01',b'\x1b[97;6u',ignoring='A'),
 key('Ctrl+Option+A',0,'\x01',6,b'\x1b\x01',b'\x1b[97;7u',ignoring='a'),
 key('Ctrl+Option+Shift+A',0,'\x01',7,b'\x1b\x01',b'\x1b[97;8u',ignoring='A'),
 key('Ctrl+Option+Left',123,'\uf702',6,b'\x1b[1;7D',b'\x1b[1;7D'),
 key('Repeated Ctrl+Left',123,'\uf702',2,b'\x1b[1;5D'*2,b'\x1b[1;5D'*2,count=2),
 key('Plain A',0,'a',0,b'a',b'a'),
 key('Shift A text',0,'A',1,b'A',b'A'),
 key('Option+Shift+A layout',0,'Å',5,b'\x1bA',ignoring='A'),
 key('Option+Shift+Ö layout',41,'Ö',5,'\x1bÖ'.encode(),ignoring='Ö'),
 key('Option+Shift+? layout',44,'?',5,b'\x1b?',ignoring='?'),
]
cases = []
for mode in ['plain', 'kitty']:
    for item in keys:
        if item[mode] is None:
            continue
        case = {k: v for k, v in item.items() if k not in ['plain', 'kitty']}
        case.update(mode=mode, expected=item[mode].hex(), name=mode + ': ' + item['name'])
        cases.append(case)
    for kind, text, expected in [('text', '日本語 é 😀', '日本語 é 😀'.encode()), ('paste', 'first\nsecond', b'\x1b[200~first\nsecond\x1b[201~')]:
        cases.append(dict(mode=mode, name=mode + ': ' + kind, kind=kind, text=text, expected=expected.hex()))
server = subprocess.Popen([HERDR, '--session', 'wooloo-ui-test', 'server'], env=env, stdout=open(OUT / 'server.log', 'w'), stderr=subprocess.STDOUT)
summary = []
try:
    wait(lambda: (base / 'herdr.sock').exists())
    created = cli('workspace', 'create', '--cwd', str(WORK), '--label', 'wooloo-key-probe', '--focus')['result']
    pane = created['root_pane']['pane_id']
    for popup in [False, True]:
        directory = WORK / ('popup' if popup else 'pane')
        directory.mkdir()
        fixture = {'socket': str(base / 'herdr-client.sock'), 'pane': pane, 'directory': str(directory), 'popup': popup, 'cases': cases}
        fixturePath = directory / 'fixture.json'
        fixturePath.write_text(json.dumps(fixture))
        if popup:
            plugin = WORK / 'plugin'
            plugin.mkdir()
            (plugin / 'herdr-plugin.toml').write_text('id = "wooloo-key-probe"\nname = "Wooloo key probe"\nversion = "0.1.0"\nmin_herdr_version = "0.9.5"\nplatforms = ["macos"]\n[[panes]]\nid = "keys"\ntitle = "Key probe"\nplacement = "popup"\ncommand = ' + json.dumps([sys.executable, COLLECTOR, str(directory)]) + '\n')
            cli('plugin', 'link', str(plugin))
            cli('plugin', 'pane', 'open', '--plugin', 'wooloo-key-probe', '--entrypoint', 'keys', '--focus')
        else:
            cli('pane', 'run', pane, shlex.join([sys.executable, COLLECTOR, str(directory)]))
        wait(lambda: (directory / 'ready-0').exists())
        testEnv = dict(env, TEST_RUNNER_WOOLOO_LIVE_KEY_PROBE=str(fixturePath))
        logfile = OUT / ('popup.log' if popup else 'pane.log')
        cmd = ['xcodebuild', 'test-without-building', '-project', 'wooloo.xcodeproj', '-scheme', 'wooloo', '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', DERIVED, '-only-testing:woolooTests/TerminalKeyInputTests/testLiveHerdrKeyboardProbe']
        result = subprocess.run(cmd, cwd=ROOT, env=testEnv, stdout=open(logfile, 'w'), stderr=subprocess.STDOUT)
        actual = [json.loads((directory / f'result-{i}.json').read_text()) if (directory / f'result-{i}.json').exists() else {'name': c['name'], 'hex': 'MISSING'} for i, c in enumerate(cases)]
        differences = [dict(name=c['name'], expected=c['expected'], actual=a['hex']) for c, a in zip(cases, actual) if c['expected'] != a['hex']]
        summary.append({'route': 'popup' if popup else 'pane', 'cases': len(cases), 'exit': result.returncode, 'differences': differences})
        (OUT / ('popup-results.json' if popup else 'pane-results.json')).write_text(json.dumps(actual, indent=2) + '\n')
        print(json.dumps(summary[-1]), flush=True)
    (OUT / 'summary.json').write_text(json.dumps({'version': version, 'work': str(WORK), 'routes': summary}, indent=2) + '\n')
    if not all(x['exit'] == 0 and not x['differences'] for x in summary):
        raise SystemExit('Keyboard probe failed; see ' + str(OUT / 'summary.json'))
finally:
    try:
        cli('server', 'stop')
    except Exception:
        pass
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.terminate()
