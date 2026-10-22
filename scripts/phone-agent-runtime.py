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
        # The path is fixed; engine/API data is serialized only as file contents.
        with temporary.open('w', encoding='utf-8') as stream:
            temporary.chmod(0o600)
            json.dump({'known': known, 'pending': pending, 'syncedAt': LAST_SYNC_AT}, stream)
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
    pairs = (line.split(': ', 1) for line in raw.replace('\r', '').split('\n') if ': ' in line)
    return {key: value for key, value in pairs}


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
    for key, row in known.items():
        if key not in current:
            action(sock, Action='QueueRemove', Queue=row['queueName'], Interface=row['interface'])
    return current


class Bridge:
    def __init__(self, sock, params=None):
        self.sock = sock
        self.params = params
        self.known, self.pending = load_state()
        BLOCKED.clear()
        BLOCKED.update(event['agentUUID'] for event in self.pending)
        self.ready = False
        self.ready_by = time.monotonic() + 15
        self.stopped = threading.Event()
        self.wakeup = threading.Event()
        self.buffer = b''
        self.metrics = {}
        self.snapshot = {}

    def active(self):
        return not self.stopped.is_set() and not SHUTDOWN.is_set()

    def replay(self):
        while self.pending and self.active():
            try:
                api(self.pending[0])
            except urllib.error.HTTPError as error:
                # Deleted memberships and superseded stations cannot be replayed.
                if error.code != 409:
                    raise
            with SOCKET_LOCK:
                self.pending.pop(0)
                save_state(self.known, self.pending)

    def report_counters(self, counters):
        for queue, values in counters.items():
            if not self.active():
                return
            api({'kind': 'queue', 'queueUUID': queue.removeprefix('mnscloud-'), **values})

    def sync_once(self):
        global LAST_SYNC_AT
        self.replay()
        if not self.active():
            return
        rows = api()
        with SOCKET_LOCK:
            BLOCKED.intersection_update(event['agentUUID'] for event in self.pending)
            self.known = desired(self.sock, rows, self.known)
        self.observe(rows)
        LAST_SYNC_AT = time.time()
        with SOCKET_LOCK:
            save_state(self.known, self.pending)

    def synchronize(self):
        try:
            while self.active():
                if not self.ready:
                    self.wakeup.wait(0.2)
                    continue
                try:
                    self.sync_once()
                except (OSError, ValueError, KeyError):
                    self.pause_all()
                self.wakeup.wait(5)
                self.wakeup.clear()
        finally:
            self.stopped.set()

    def record_event(self, event):
        if not event:
            return
        with SOCKET_LOCK:
            BLOCKED.add(event['agentUUID'])
            self.pause_agent(event['agentUUID'])
            self.pending.append(event)
            save_state(self.known, self.pending)
            self.wakeup.set()
            if len(self.pending) > 1000:
                raise ValueError('Event backlog requires recovery')

    def receive(self):
        if not self.ready and time.monotonic() > self.ready_by:
            raise ConnectionError('Event subscription unavailable')
        data = self.sock.recv(65536)
        if not data:
            raise ConnectionError('Event socket closed')
        self.buffer += data
        if len(self.buffer) > 1048576:
            raise ValueError('Event frame too large')
        self.parse_frames()

    def run(self):
        worker = threading.Thread(target=self.synchronize, daemon=True)
        worker.start()
        try:
            while self.active():
                try:
                    self.receive()
                except socket.timeout:
                    pass
        finally:
            self.stopped.set()
            self.wakeup.set()
            worker.join()
            if SHUTDOWN.is_set():
                self.known = desired(self.sock, [], self.known)
                save_state(self.known, self.pending)

    def pause_all(self):
        with SOCKET_LOCK:
            for row in self.known.values():
                action(self.sock, Action='QueuePause', Queue=row['queueName'], Interface=row['interface'], Paused='true', Reason='Control plane unavailable')

    def pause_agent(self, agent):
        for member in self.known.values():
            if member.get('agentName') == 'agent-' + agent:
                action(self.sock, Action='QueuePause', Queue=member['queueName'], Interface=member['interface'], Paused='true', Reason='Contact event')

    def observe(self, rows):
        self.report_counters(self.metrics.copy())
        self.snapshot = {}
        action(self.sock, Action='QueueStatus')

    def handle_frame(self, values):
        queue = values.get('Queue', '')
        kind = values.get('Event')
        if kind == 'QueueParams' and UUID.fullmatch(queue.removeprefix('mnscloud-')):
            self.snapshot[queue] = {'waiting': max(0, int(values.get('Calls', 0))), 'longestWait': 0}
        if kind == 'QueueEntry' and queue in self.snapshot:
            self.snapshot[queue]['longestWait'] = max(self.snapshot[queue]['longestWait'], int(values.get('Wait', 0)))
        if kind == 'QueueStatusComplete':
            self.ready = True
            self.metrics = self.snapshot.copy()
        if kind == 'QueueMember' and values.get('Name', '').startswith('agent-'):
            self.restore_member(values)
        self.record_event(event_payload(values))

    def restore_member(self, values):
        queue, interface = values.get('Queue', ''), values.get('Location', '')
        if SAFE.fullmatch(queue) and SAFE.fullmatch(interface):
            key = queue + '|' + interface
            with SOCKET_LOCK:
                self.known[key] = {**self.known.get(key, {}), 'queueName': queue, 'interface': interface, 'agentName': values['Name']}

    def parse_frames(self):
        while b'\r\n\r\n' in self.buffer:
            frame, self.buffer = self.buffer.split(b'\r\n\r\n', 1)
            self.handle_frame(fields(frame.decode(errors='replace')))


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
        Bridge(sock).run()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: SHUTDOWN.set())
    signal.signal(signal.SIGINT, lambda *_: SHUTDOWN.set())
    while not SHUTDOWN.is_set():
        try:
            run()
        except Exception:
            print('Phone agent bridge disconnected; retrying.', flush=True)
            time.sleep(5)
