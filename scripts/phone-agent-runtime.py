#!/usr/bin/env python3
"""Local AMI event bridge and control-plane-managed contact-center members.

Only managed agent-* members are changed. Credentials are read on the host and never logged.
The API owns identity, tenant/queue authorization, pause policy and after-call work.
"""
import configparser
import json
from pathlib import Path
import re
import socket
import signal
import time
import threading
import urllib.error
import urllib.request

UUID = re.compile(r'^[0-9a-fA-F-]{32,36}$')
STATE_LOCK = threading.RLock()
SOCKET_LOCK = threading.RLock()
BLOCKED = set()
SHUTDOWN = threading.Event()
LAST_SYNC_AT = 0.0
STATE = Path('/var/lib/mnscloud-asterisk-phone-agent/state.json')


def save_state(known, pending):
    with STATE_LOCK:
        STATE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = STATE.with_suffix('.tmp')
        temporary.write_text(json.dumps({'known': known, 'pending': pending, 'syncedAt': LAST_SYNC_AT}))
        temporary.chmod(0o600)
        temporary.replace(STATE)

def load_state():
    try:
        data = json.loads(STATE.read_text())
        return data['known'], data['pending']
    except FileNotFoundError:
        return {}, []


SAFE = re.compile(r'^[a-zA-Z0-9_./@:-]+$')


def api(body=None):
    root = Path('/etc/mnscloud/pabx')
    base = (root / 'api.base').read_text().strip().rstrip('/')
    if not base.startswith('https://'):
        raise ValueError('HTTPS control plane required')
    url = base + ('' if base.endswith('/api/v1') else '/api/v1') + '/pabx/runtime/agents'
    headers = {'Authorization': 'Bearer ' + (root / 'api.token').read_text().strip(),
               'X-PABX-Node-UUID': (root / 'node.uuid').read_text().strip()}
    data = None if body is None else json.dumps(body).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    # Never follow a redirect with the node credential.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(url, data=data, headers=headers), timeout=10) as response:
        return json.load(response)['data']['items']


def fields(raw):
    return dict(line.split(': ', 1) for line in raw.replace('\r', '').split('\n') if ': ' in line)


def event_payload(event):
    kind = {'AgentConnect': 'connected', 'AgentComplete': 'ended'}.get(event.get('Event'))
    agent = event.get('MemberName', '').removeprefix('agent-')
    queue = event.get('Queue', '').removeprefix('mnscloud-')
    call = event.get('DestUniqueid') or event.get('Uniqueid')
    if kind and UUID.fullmatch(agent) and UUID.fullmatch(queue) and call:
        return {'agentUUID': agent, 'queueUUID': queue, 'callKey': call, 'kind': kind}
    return None


def action(sock, **values):
    if any('\r' in str(v) or '\n' in str(v) for v in values.values()):
        raise ValueError('Invalid AMI field')
    with SOCKET_LOCK:
        sock.sendall(('\r\n'.join(f'{k}: {v}' for k, v in values.items()) + '\r\n\r\n').encode())


def desired(sock, rows, known):
    current = {}
    for row in rows:
        if row.get('agentUUID') in BLOCKED:
            row = {**row, 'state': 'PAUSED'}
        queue, interface, name = row['queueName'], row['interface'], row['agentName']
        if not interface or not all(SAFE.fullmatch(v) for v in (queue, interface, name)) or not name.startswith('agent-'):
            continue
        key = queue + '|' + interface
        if row['state'] == 'LOGGED_OUT':
            continue
        current[key] = row
        # Reassert even after a PBX restart or a rejected/late queue load.
        action(sock, Action='QueueAdd', Queue=queue, Interface=interface, MemberName=name,
               StateInterface=interface, Penalty=int(row['penalty']), Paused='true')
        action(sock, Action='QueuePenalty', Queue=queue, Interface=interface, Penalty=int(row['penalty']))
        action(sock, Action='QueuePause', Queue=queue, Interface=interface,
               Paused='false' if row['state'] == 'AVAILABLE' else 'true', Reason='MNSCloud agent state')
    for key, row in list(known.items()):
        if key not in current:
            action(sock, Action='QueueRemove', Queue=row['queueName'], Interface=row['interface'])
    return current


def run():
    config = configparser.ConfigParser(strict=False, interpolation=None, inline_comment_prefixes=(';',))
    config.read('/etc/asterisk/manager.conf')
    host = config.get('general', 'bindaddr')
    if host in ('0.0.0.0', '::'):
        host = '127.0.0.1'
    with socket.create_connection((host, config.getint('general', 'port', fallback=5038)), timeout=10) as sock:
        sock.settimeout(1)
        action(sock, Action='Login', Username='mnscloud', Secret=config.get('mnscloud', 'secret'), Events='on')
        action(sock, Action='QueueStatus')
        buffer = ''
        ready = False
        ready_by = time.monotonic() + 15
        known, pending = load_state()
        BLOCKED.clear()
        BLOCKED.update(event['agentUUID'] for event in pending)
        metrics = {}
        snapshot = {}
        stopped = threading.Event()
        wakeup = threading.Event()
        def synchronize():
            global LAST_SYNC_AT
            nonlocal known, snapshot
            try:
                while not stopped.is_set() and not SHUTDOWN.is_set():
                    if not ready:
                        wakeup.wait(0.2)
                        continue
                    try:
                        while pending and not stopped.is_set():
                            try:
                                api(pending[0])
                            except urllib.error.HTTPError as error:
                                # A deleted membership or superseded station cannot be replayed.
                                if error.code != 409:
                                    raise
                            pending.pop(0)
                            save_state(known, pending)
                        for queue, counters in metrics.items():
                            if stopped.is_set(): return
                            api({'kind': 'queue', 'queueUUID': queue.removeprefix('mnscloud-'), **counters})
                        if stopped.is_set(): return
                        rows = api()
                        with SOCKET_LOCK:
                            BLOCKED.intersection_update(event['agentUUID'] for event in pending)
                            known = desired(sock, rows, known)
                        snapshot = {}
                        action(sock, Action='QueueStatus')
                        LAST_SYNC_AT = time.time()
                        save_state(known, pending)
                    except (OSError, ValueError, KeyError):
                        # Losing control-plane access must not route new calls to managed agents.
                        for row in list(known.values()):
                            action(sock, Action='QueuePause', Queue=row['queueName'], Interface=row['interface'], Paused='true', Reason='Control plane unavailable')
                    wakeup.wait(5)
                    wakeup.clear()
            finally:
                stopped.set()
        worker = threading.Thread(target=synchronize, daemon=True)
        worker.start()
        try:
            while not stopped.is_set() and not SHUTDOWN.is_set():
                if not ready and time.monotonic() > ready_by:
                    raise ConnectionError('AMI subscription unavailable')
                try:
                    data = sock.recv(65536)
                    if not data:
                        raise ConnectionError('AMI closed')
                    buffer += data.decode(errors='replace')
                    if len(buffer) > 1048576:
                        raise ValueError('AMI frame too large')
                    while '\r\n\r\n' in buffer:
                        frame, buffer = buffer.split('\r\n\r\n', 1)
                        values = fields(frame)
                        queue = values.get('Queue', '')
                        if values.get('Event') == 'QueueParams' and UUID.fullmatch(queue.removeprefix('mnscloud-')):
                            snapshot[queue] = {'waiting': max(0, int(values.get('Calls', 0))), 'longestWait': 0}
                        if values.get('Event') == 'QueueEntry' and queue in snapshot:
                            snapshot[queue]['longestWait'] = max(snapshot[queue]['longestWait'], int(values.get('Wait', 0)))
                        if values.get('Event') == 'QueueStatusComplete':
                            ready = True
                            metrics = snapshot.copy()
                        if values.get('Event') == 'QueueMember' and values.get('Name', '').startswith('agent-'):
                            queue, interface = values.get('Queue', ''), values.get('Location', '')
                            if SAFE.fullmatch(queue) and SAFE.fullmatch(interface):
                                known[queue+'|'+interface] = {**known.get(queue+'|'+interface, {}), 'queueName': queue, 'interface': interface, 'agentName': values['Name']}
                        event = event_payload(values)
                        if event:
                            with SOCKET_LOCK:
                                BLOCKED.add(event['agentUUID'])
                                # Pause immediately on the local event path, independent of HTTP latency.
                                for member in list(known.values()):
                                    if member.get('agentName') == 'agent-' + event['agentUUID']:
                                        action(sock, Action='QueuePause', Queue=member['queueName'], Interface=member['interface'], Paused='true', Reason='Contact event')
                                pending.append(event)
                                save_state(known, pending)
                                wakeup.set()
                                if len(pending) > 1000:
                                    raise ValueError('Event backlog requires recovery')
                except socket.timeout:
                    pass
        finally:
            stopped.set()
            wakeup.set()
            worker.join()
            if SHUTDOWN.is_set():
                known = desired(sock, [], known)
                save_state(known, pending)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: SHUTDOWN.set())
    signal.signal(signal.SIGINT, lambda *_: SHUTDOWN.set())
    while not SHUTDOWN.is_set():
        try:
            run()
        except Exception:
            print('Phone agent bridge disconnected; retrying.', flush=True)
            time.sleep(5)
