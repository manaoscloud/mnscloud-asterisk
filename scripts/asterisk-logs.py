#!/usr/bin/env python3
"""Apply the PABX server Logs tab on Asterisk and keep /var/log/asterisk bounded.

Run every minute by mnscloud-asterisk-logs.timer. logger.conf is rendered from the normalized level
(rotatestrategy=none: this script rotates), then applied live with `logger reload`, `core set
verbose/debug` and the PJSIP packet logger (debug only); a restart re-applies it. The security
channel is never disabled.
"""
import grp
import importlib.util
import os
from pathlib import Path
import pwd
import subprocess

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('mnscloud_engine_logs', HERE / 'mnscloud_engine_logs.py')
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

IDENTITY = Path('/etc/mnscloud/pabx')
LOG_DIR = Path('/var/log/asterisk')
CONFIG = Path('/etc/asterisk/logger.conf')
LOG_FILES = ('full', 'messages', 'security', 'mnscloud-cdr-diagnostic-capture.log')
MANAGED_MARKER = '; Managed by MNSCloud (PABX server Logs tab)'

FULL = {
    'error': 'error',
    'warning': 'warning,error',
    'notice': 'notice,warning,error,verbose(1)',
    'info': 'notice,warning,error,verbose(3)',
    'debug': 'notice,warning,error,verbose(5),debug',
}
MESSAGES = {
    'error': 'error',
    'warning': 'warning,error',
    'notice': 'notice,warning,error',
    'info': 'notice,warning,error',
    'debug': 'notice,warning,error',
}
VERBOSE = {'error': 0, 'warning': 0, 'notice': 1, 'info': 3, 'debug': 5}


def render(level):
    return f'''{MANAGED_MARKER}; rewritten by asterisk-logs.py.
[general]
dateformat=%F %T.%3q
use_callids=yes
rotatestrategy=none

[logfiles]
console => notice,warning,error
security => security
messages => {MESSAGES[level]}
full => {FULL[level]}
'''


def owner():
    try:
        return pwd.getpwnam('asterisk').pw_uid, grp.getgrnam('asterisk').gr_gid
    except KeyError:
        return None


def ast(command):
    result = subprocess.run(['asterisk', '-rx', command], capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    if result.returncode or 'No such command' in output or 'Unable to connect' in output:
        raise RuntimeError('Asterisk command failed: ' + ' '.join(command.split()[:2]))
    return output


def main_pid():
    result = subprocess.run(['systemctl', 'show', '-p', 'MainPID', '--value', 'asterisk'],
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() or '0'


def apply(settings, previous):
    level = core.effective_level(settings, core.low_disk(LOG_DIR))
    changed = core.write_if_changed(CONFIG, render(level), 0o640, owner())
    marker = {'pid': main_pid(), 'level': level}
    if marker['pid'] == '0':
        return {'pid': '0', 'level': None}  # Not running: apply on the next refresh.
    if changed or marker != previous:
        ast('logger reload')
        ast(f'core set verbose {VERBOSE[level]}')
        ast('core set debug 5' if level == 'debug' else 'core set debug off')
        ast('pjsip set logger ' + ('on' if level == 'debug' else 'off'))
    return marker


def maintain(settings):
    days, rotated, deleted = settings['logRetentionDays'], [], 0
    for name in LOG_FILES:
        result = core.rotate(LOG_DIR / name, core.STATE_ROOT / f'asterisk-{name}-rotated', owner())
        if result:
            rotated.append(str(result))
        deleted += core.purge(LOG_DIR, [f'{name}-*.gz', f'{name}.[0-9]*'], days)
    core.maintain_install_log(days)
    return {'rotated': rotated, 'deleted': deleted}


def fetch():
    base, node, token = core.read_identity(IDENTITY, 'api.token')
    return core.fetch_settings(base, 'pabx/runtime/log-config', node, token,
                               headers={'X-PABX-Node-UUID': node})


if __name__ == '__main__':
    os.environ.setdefault('LC_ALL', 'C')
    core.main('asterisk', fetch, apply, maintain)
