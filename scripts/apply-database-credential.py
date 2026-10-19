#!/usr/bin/env python3
"""Agent-run adapter (mnscloud.module.database.credential.v1): switch Asterisk to its own DB principal.

Input (stdin JSON, never argv): username, password, databaseHost, databasePort, databaseName.
The credential lives in three files; only its user/password lines change, every other byte stays:
  /etc/mnscloud/pabx/db.conf     AST_DB_USER / AST_DB_PASS (also read by the CDR diagnostic helper)
  /etc/odbc.ini                  User / Password of the mnscloud_asterisk DSN
  /etc/asterisk/res_odbc.conf    username / password of the mnscloud class (written 0640)
res_odbc is reloaded (no call is dropped). The switch is proven before the old account may be
revoked: Asterisk holds connections as the new account, the account reads the realtime views and
PABX routing tables and runs the routing functions, and the PJSIP realtime endpoint count is
unchanged. Otherwise the three previous files are restored and res_odbc reloaded again.
"""
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import time

DB_CONF = '/etc/mnscloud/pabx/db.conf'
ODBC_INI = '/etc/odbc.ini'
RES_ODBC = '/etc/asterisk/res_odbc.conf'
STATE = '/var/lib/mnscloud/database-credential/mnscloud-asterisk'
USERNAME = re.compile(r'[A-Za-z0-9]{16}')
PASSWORD = re.compile(r'[A-Za-z0-9]{64}')
PROBES = (
    'SELECT COUNT(*) FROM AsteriskRealtimeEndpoint',
    'SELECT COUNT(*) FROM AsteriskRealtimeContact',
    'SELECT COUNT(*) FROM AsteriskCdr WHERE 1=0',
    'SELECT COUNT(*) FROM VoipPabxExtension WHERE 1=0',
    'SELECT COUNT(*) FROM VoipPabxInboundRoute WHERE 1=0',
    "SELECT FuncOnlyNumber('1'), FuncUUIDFromBin(FuncUUIDToBin(UUID())) IS NOT NULL",
)


class CredentialError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def validate(data):
    if not isinstance(data, dict) or not USERNAME.fullmatch(str(data.get('username', ''))) \
            or not PASSWORD.fullmatch(str(data.get('password', ''))) \
            or not re.fullmatch(r'[A-Za-z0-9.:-]{1,253}', str(data.get('databaseHost', ''))) \
            or not re.fullmatch(r'[a-zA-Z0-9_]{1,64}', str(data.get('databaseName', ''))) \
            or not str(data.get('databasePort', '')).isdigit():
        raise CredentialError('MODULE_DATABASE_CREDENTIAL_INVALID')
    return data


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1].replace('\\"', '"').replace('\\\\', '\\')
    return value


# Each file: (path, line pattern for user, line pattern for password, renderers, endpoint keys).
def db_conf_lines(source):
    found = {}
    for line in source.decode().splitlines():
        match = re.match(r'\s*([A-Z][A-Z0-9_]*)=(.*)$', line)
        if match:
            found.setdefault(match[1], []).append(unquote(match[2]))
    return found


def replace_lines(source, rules):
    """rules: {regex with groups (prefix)(value): new value}; each must match exactly one line."""
    lines = source.decode().splitlines(keepends=True)
    counts = {pattern: 0 for pattern in rules}
    for index, line in enumerate(lines):
        for pattern, value in rules.items():
            match = re.match(pattern, line.rstrip('\n'))
            if match:
                counts[pattern] += 1
                lines[index] = match[1] + value + ('\n' if line.endswith('\n') else '')
    if any(count != 1 for count in counts.values()):
        raise CredentialError('MODULE_DATABASE_ENV_UNSUPPORTED')
    return ''.join(lines).encode()


def rewrite(files, data):
    """New contents of the three files; refuses a configuration that points elsewhere."""
    conf = db_conf_lines(files[DB_CONF])
    expected = {'AST_DB_HOST': str(data['databaseHost']), 'AST_DB_PORT': str(data['databasePort']),
                'AST_DB_NAME': data['databaseName']}
    for key, value in expected.items():
        if conf.get(key, ['3306' if key == 'AST_DB_PORT' else '']) != [value]:
            raise CredentialError('MODULE_DATABASE_ENDPOINT_MISMATCH')
    user, password = data['username'], data['password']
    return {
        DB_CONF: replace_lines(files[DB_CONF], {r'(\s*AST_DB_USER=).*$': f'"{user}"', r'(\s*AST_DB_PASS=).*$': f'"{password}"'}),
        ODBC_INI: replace_lines(files[ODBC_INI], {r'(\s*User\s*=\s*).*$': user, r'(\s*Password\s*=\s*).*$': password}),
        RES_ODBC: replace_lines(files[RES_ODBC], {r'(\s*username\s*=>\s*).*$': user, r'(\s*password\s*=>\s*).*$': password}),
    }


def read_private(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 262144:
            raise CredentialError('MODULE_DATABASE_ENV_UNSAFE')
        return stream.read(), info


def write_atomic(path, data, mode, uid, gid):
    directory = os.path.dirname(path)
    temporary = os.path.join(directory, '.credential-' + os.urandom(8).hex())
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb', closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fchown(fd, uid, gid)
            os.fchmod(fd, mode)
            os.fsync(fd)
        os.replace(temporary, path)
        parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        os.close(fd)
        if os.path.exists(temporary):
            os.unlink(temporary)


def file_mode(path, info):
    # Secret-bearing files are never world-readable (res_odbc.conf used to be 0644).
    return stat.S_IMODE(info.st_mode) & 0o750


def run(args, timeout=60, env=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False, env=env)
    return result.returncode, result.stdout


def reload_odbc():
    code, _ = run(['asterisk', '-rx', 'module reload res_odbc.so'])
    if code:
        raise CredentialError('MODULE_DATABASE_RESTART_FAILED')


def endpoint_count():
    code, output = run(['asterisk', '-rx', 'pjsip show endpoints'])
    if code:
        return None
    match = re.search(r'Objects found:\s*(\d+)', output)
    return int(match[1]) if match else 0


def query(data, sql):
    environment = {**os.environ, 'MYSQL_PWD': data['password']}
    return run(['mariadb', '--batch', '--skip-column-names', '--connect-timeout=5', '-h', str(data['databaseHost']),
                '-P', str(data['databasePort']), '-u', data['username'], data['databaseName'], '-e', sql], env=environment)


def proven(data, endpoints_before, attempts=24, delay=5):
    """Asterisk connected as the new account, which holds every privilege the dialplan needs."""
    for _ in range(attempts):
        code, sessions = query(data, "SELECT COUNT(*) FROM information_schema.PROCESSLIST "
                                     "WHERE USER=SUBSTRING_INDEX(CURRENT_USER(), '@', 1)")
        # Our own probe plus at least one pooled res_odbc connection of Asterisk.
        if code == 0 and sessions.strip().isdigit() and int(sessions.strip()) >= 2 \
                and all(query(data, sql)[0] == 0 for sql in PROBES) \
                and (endpoints_before is None or endpoint_count() == endpoints_before):
            return True
        time.sleep(delay)
    return False


def apply(data, state=STATE, paths=(DB_CONF, ODBC_INI, RES_ODBC), reload=reload_odbc, proof=proven, count=endpoint_count):
    validate(data)
    current = {path: read_private(path) for path in paths}
    sources = {path: item[0] for path, item in current.items()}
    os.makedirs(state, mode=0o700, exist_ok=True)
    backup = os.path.join(state, 'previous.json')
    if os.path.exists(backup):
        # An earlier run stopped between switching and proving the account: restore first.
        with open(backup, encoding='utf-8') as stream:
            previous = {path: bytes.fromhex(value) for path, value in json.load(stream).items()}
        for path in paths:
            info = current[path][1]
            write_atomic(path, previous[path], file_mode(path, info), info.st_uid, info.st_gid)
        reload()
        os.unlink(backup)
        current = {path: read_private(path) for path in paths}
        sources = {path: item[0] for path, item in current.items()}
    updated = rewrite(sources, data)
    endpoints = count()
    write_atomic(backup, json.dumps({path: value.hex() for path, value in sources.items()}).encode(), 0o600,
                 os.geteuid(), os.getegid())
    for path in paths:
        info = current[path][1]
        write_atomic(path, updated[path], file_mode(path, info), info.st_uid, info.st_gid)
    try:
        reload()
        if proof(data, endpoints):
            os.unlink(backup)
            return {'ok': True}
        failure = 'MODULE_DATABASE_CREDENTIAL_UNHEALTHY'
    except CredentialError as error:
        failure = error.code
    for path in paths:
        info = current[path][1]
        write_atomic(path, sources[path], file_mode(path, info), info.st_uid, info.st_gid)
    try:
        reload()
    finally:
        os.unlink(backup)
    raise CredentialError(failure)


def main():
    if os.geteuid() != 0:
        raise CredentialError('MODULE_DATABASE_CREDENTIAL_ROOT_REQUIRED')
    os.umask(0o077)
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    lock = os.open(os.path.join(STATE, '.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        raw = sys.stdin.read(65537)
        if len(raw) > 65536:
            raise CredentialError('MODULE_DATABASE_CREDENTIAL_INVALID')
        print(json.dumps(apply(json.loads(raw))))
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except CredentialError as error:
        print(json.dumps({'ok': False, 'errorCode': error.code}))
        sys.exit(1)
    except Exception:
        # Never serialize exceptions: they may carry file contents.
        print(json.dumps({'ok': False, 'errorCode': 'MODULE_DATABASE_CREDENTIAL_FAILED'}))
        sys.exit(1)
