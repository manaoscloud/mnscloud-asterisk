#!/usr/bin/env python3
"""apply-database-credential.py: only the user/password lines of the three files change, endpoint
mismatch is refused, res_odbc.conf loses world read, failure restores all files, an interrupted
switch is restored before the next one."""
import importlib.util
import os
from pathlib import Path
import secrets
import stat
import string
import tempfile

spec = importlib.util.spec_from_file_location('credential', Path(__file__).resolve().parents[1] / 'scripts/apply-database-credential.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
ALPHA = string.ascii_letters + string.digits
token = lambda n: ''.join(secrets.choice(ALPHA) for _ in range(n))

DB_CONF = b'AST_DB_HOST="10.20.0.2"\nAST_DB_PORT="3306"\nAST_DB_NAME="clouddb"\nAST_DB_USER="OldShared0000001"\nAST_DB_PASS="old-secret"\n'
ODBC = b'[mnscloud_asterisk]\nDriver=MariaDB Unicode\nServer=10.20.0.2\nUser=OldShared0000001\nPassword=old-secret\nOption=3\n'
RES = b'[mnscloud]\nenabled => yes\ndsn => mnscloud_asterisk\nusername => OldShared0000001\npassword => old-secret\npre-connect => yes\n'


def scenario(proofs, data=None, prepare=None):
    folder = tempfile.mkdtemp()
    paths = tuple(os.path.join(folder, name) for name in ('db.conf', 'odbc.ini', 'res_odbc.conf'))
    for path, content, mode in zip(paths, (DB_CONF, ODBC, RES), (0o640, 0o640, 0o644)):
        with open(path, 'wb') as stream:
            stream.write(content)
        os.chmod(path, mode)
    state = os.path.join(folder, 'state')
    if prepare:
        prepare(paths, state)
    reloads, results = [], list(proofs)
    data = data or {'username': token(16), 'password': token(64), 'databaseHost': '10.20.0.2', 'databasePort': 3306, 'databaseName': 'clouddb'}
    try:
        c.DB_CONF, c.ODBC_INI, c.RES_ODBC = paths
        outcome = c.apply(data, state, paths, reload=lambda: reloads.append(1), proof=lambda d, e: results.pop(0), count=lambda: 4)
    except c.CredentialError as error:
        outcome = error.code
    contents = [open(path, 'rb').read() for path in paths]
    modes = [stat.S_IMODE(os.stat(path).st_mode) for path in paths]
    return outcome, contents, modes, reloads, data, state


outcome, contents, modes, reloads, data, state = scenario([True])
user, password = data['username'].encode(), data['password'].encode()
assert outcome == {'ok': True} and len(reloads) == 1
assert contents[0] == DB_CONF.replace(b'"OldShared0000001"', b'"' + user + b'"').replace(b'"old-secret"', b'"' + password + b'"')
assert contents[1] == ODBC.replace(b'OldShared0000001', user).replace(b'old-secret', password)
assert contents[2] == RES.replace(b'OldShared0000001', user).replace(b'old-secret', password)
assert modes == [0o640, 0o640, 0o640], 'res_odbc.conf no longer world-readable'
assert not os.path.exists(os.path.join(state, 'previous.json'))

outcome, contents, modes, reloads, *_ = scenario([False])
assert outcome == 'MODULE_DATABASE_CREDENTIAL_UNHEALTHY' and contents == [DB_CONF, ODBC, RES] and len(reloads) == 2

outcome, contents, _, reloads, *_ = scenario([], data={'username': token(16), 'password': token(64), 'databaseHost': '10.20.0.9', 'databasePort': 3306, 'databaseName': 'clouddb'})
assert outcome == 'MODULE_DATABASE_ENDPOINT_MISMATCH' and contents == [DB_CONF, ODBC, RES] and not reloads

outcome, contents, *_ = scenario([], data={'username': token(15), 'password': token(64), 'databaseHost': '10.20.0.2', 'databasePort': 3306, 'databaseName': 'clouddb'})
assert outcome == 'MODULE_DATABASE_CREDENTIAL_INVALID' and contents == [DB_CONF, ODBC, RES]

pending = {'username': token(16), 'password': token(64), 'databaseHost': '10.20.0.2', 'databasePort': 3306, 'databaseName': 'clouddb'}


def interrupted(paths, state):
    import json
    os.makedirs(state, mode=0o700)
    with open(os.path.join(state, 'previous.json'), 'w') as stream:
        json.dump({path: content.hex() for path, content in zip(paths, (DB_CONF, ODBC, RES))}, stream)
    c.DB_CONF, c.ODBC_INI, c.RES_ODBC = paths
    switched = c.rewrite(dict(zip(paths, (DB_CONF, ODBC, RES))), pending)
    for path in paths:
        with open(path, 'wb') as stream:
            stream.write(switched[path])


fresh = {**pending, 'username': token(16), 'password': token(64)}
outcome, contents, _, reloads, *_ = scenario([True], data=fresh, prepare=interrupted)
assert outcome == {'ok': True} and fresh['username'].encode() in contents[2] and pending['username'].encode() not in contents[2]
assert len(reloads) == 2, 'restore reload, then switch reload'
print('PASS: Asterisk database credential switch, endpoint guard, file modes, rollback and interrupted-switch recovery')
