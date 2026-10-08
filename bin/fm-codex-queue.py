#!/usr/bin/env python3
"""Bind a daemon-backed Codex coordinator and reconcile native queue delivery.

Usage: FM_HOME=<home> CODEX_HOME=<account-home> fm-codex-queue.py bind|check|flush
Bind runs in the locked coordinator's tool ancestry with CODEX_THREAD_ID set.
FM_CODEX_QUEUE_BIN selects the native Codex executable, otherwise the live CLI executable is used.
FM_CODEX_QUEUE_SOCKET may select an exact Unix socket; otherwise the owner must
hold exactly one named Unix socket. FM_CODEX_QUEUE_CLI_PID is required for an
explicit-remote CLI whose daemon is not its child. Only CLI 0.160.1 and daemon
0.161.0 have empirical evidence. The binding refuses other versions.
Check is read-only. Flush requires .afk and the existing supervisor singleton;
it journals once before codex queue, then waits for exact-input native turn
completion before removing the corresponding escalation-buffer prefix.
Acceptance and ambiguous exits never mean handling, and are never blindly
resent. Receipts and pending submissions survive supervisor restart and return.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import uuid

CODE = Path(__file__).resolve().parent


def run(argv):
    return subprocess.check_output(argv, text=True, timeout=5).strip()


def identity(pid):
    return run(['bash', '-c', '. "$1/fm-wake-lib.sh"; fm_pid_identity "$2"', '_', str(CODE), str(pid)])


def parent(pid):
    return int(run(['ps', '-p', str(pid), '-o', 'ppid=']))


def ancestor(pid):
    current = os.getpid()
    for _ in range(32):
        if current == pid:
            return True
        if current <= 1:
            break
        current = parent(current)
    return False


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def save(path, value):
    fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def lock_owner(state):
    lines = (state / '.lock').read_text().splitlines()
    if len(lines) != 2 or not lines[0].isdigit() or not lines[1].startswith('identity='):
        raise ValueError('an identity-backed coordinator lock is required')
    pid = int(lines[0])
    recorded = lines[1][9:]
    if not recorded or identity(pid) != recorded:
        raise ValueError('coordinator lock identity changed; no locks were cleared')
    return pid, recorded


def sockets(pid):
    names = run(['lsof', '-a', '-p', str(pid), '-U', '-Fn']).splitlines()
    return sorted({str(Path(line[1:]).resolve()) for line in names if line.startswith('n/') and ' ->' not in line})


def socket_identity(path):
    info = path.stat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('the Unix socket must be private and owned by this user')
    return [info.st_dev, info.st_ino, info.st_uid]


def events(path):
    with path.open() as stream:
        for line in stream:
            if not line.endswith('\n'):
                break
            yield json.loads(line)


def rollout(home, thread, cwd):
    paths = list((home / 'sessions').glob('**/*' + thread + '.jsonl'))
    if len(paths) != 1:
        raise ValueError('exactly one native rollout for this thread is required')
    path = paths[0].resolve()
    first = next(events(path))
    meta = first.get('payload', {})
    if first.get('type') != 'session_meta' or meta.get('id') != thread or Path(meta.get('cwd', '')).resolve() != cwd:
        raise ValueError('thread identity or operational home differs')
    contexts = [item['payload'] for item in events(path) if item.get('type') == 'turn_context']
    if not contexts or contexts[-1].get('approval_policy') != 'never' or contexts[-1].get('sandbox_policy', {}).get('type') != 'danger-full-access':
        raise ValueError('native thread must retain danger-full-access/never')
    return path


def bind(home, account, state, thread):
    if str(uuid.UUID(thread)) != thread or os.environ.get('CODEX_THREAD_ID') != thread:
        raise ValueError('CODEX_THREAD_ID must be the exact coordinator UUID')
    owner, owner_identity = lock_owner(state)
    if not ancestor(owner):
        raise ValueError('only the owning coordinator tool ancestry may bind')
    daemon = Path(run(['ps', '-p', str(owner), '-o', 'comm='])).resolve()
    args = run(['ps', '-p', str(owner), '-o', 'command='])
    if ' app-server ' not in args or '--managed-daemon' not in args:
        raise ValueError('lock owner is not the managed Codex daemon')
    cli_pid = int(os.environ.get('FM_CODEX_QUEUE_CLI_PID', str(parent(owner))))
    cli = Path(run(['ps', '-p', str(cli_pid), '-o', 'comm='])).resolve()
    binary = Path(os.environ.get('FM_CODEX_QUEUE_BIN') or str(cli)).resolve()
    if binary != cli:
        raise ValueError('select the exact native executable of the live Codex CLI')
    available = sockets(owner)
    socket_path = Path(os.environ['FM_CODEX_QUEUE_SOCKET']).resolve() if os.environ.get('FM_CODEX_QUEUE_SOCKET') else Path(available[0]) if len(available) == 1 else None
    if socket_path is None or str(socket_path) not in available:
        raise ValueError('owner socket is absent or ambiguous; select its exact Unix path')
    if cli_pid != parent(owner):
        cli_args = run(['ps', '-p', str(cli_pid), '-o', 'command='])
        if '--remote unix://' not in cli_args or not any('unix://' + candidate in cli_args for candidate in [str(socket_path), os.environ.get('FM_CODEX_QUEUE_SOCKET', '')]):
            raise ValueError('explicit-remote CLI is not attached to the exact daemon socket')
    cli_version = run([str(binary), '--no-daemon', '--version'])
    daemon_version = run([str(daemon), '--no-daemon', '--version'])
    if cli_version != 'codex-cli 0.160.1' or daemon_version != 'codex-cli 0.161.0':
        raise ValueError('unverified native queue CLI/daemon version pair')
    data = dict(home=str(home), account=str(account), thread=thread, owner=owner, owner_identity=owner_identity,
                cli_pid=cli_pid, cli_identity=identity(cli_pid), binary=str(binary), binary_hash=digest(binary),
                daemon=str(daemon), daemon_hash=digest(daemon), socket=str(socket_path), socket_identity=socket_identity(socket_path),
                rollout=str(rollout(account, thread, home)), cli_version=cli_version, daemon_version=daemon_version)
    path = state / '.codex-queue-target.json'
    if path.exists() and json.loads(path.read_text()) != data:
        raise ValueError('an existing binding owns a different target; archive it explicitly before rebind')
    save(path, data)
    return data


def check(home, state, thread):
    data = json.loads((state / '.codex-queue-target.json').read_text())
    if data['home'] != str(home) or data['thread'] != thread:
        raise ValueError('target belongs to a different home or thread')
    owner, owner_identity = lock_owner(state)
    if (owner, owner_identity) != (data['owner'], data['owner_identity']) or identity(data['cli_pid']) != data['cli_identity']:
        raise ValueError('coordinator or CLI was replaced; explicit rebind is required')
    for name in ['binary', 'daemon']:
        if digest(Path(data[name])) != data[name + '_hash']:
            raise ValueError('bound executable changed')
    socket_path = Path(data['socket'])
    if socket_identity(socket_path) != data['socket_identity'] or str(socket_path) not in sockets(owner):
        raise ValueError('bound daemon socket changed')
    if rollout(Path(data['account']), thread, home) != Path(data['rollout']):
        raise ValueError('bound rollout changed')
    return data


def completion(data, pending):
    matched = None
    started = set()
    for item in events(Path(data['rollout'])):
        payload = item.get('payload', {})
        if item.get('type') == 'event_msg':
            if payload.get('type') == 'task_started':
                started.add(payload.get('turn_id'))
            if payload.get('type') == 'task_complete' and matched in started and payload.get('turn_id') == matched:
                return dict(turn=matched, completed=item['timestamp'])
        if item.get('type') == 'response_item' and payload.get('type') == 'message' and payload.get('role') == 'user':
            if any(part.get('text') == pending['message'] for part in payload.get('content', [])):
                matched = payload.get('internal_chat_message_metadata_passthrough', {}).get('turn_id')
    return None


def reconcile(state, data, pending, path):
    handled = completion(data, pending)
    if not handled:
        return False
    buf = state / '.subsuper-escalations'
    current = buf.read_text() if buf.exists() else ''
    prefix = pending['buffer']
    if current.startswith(prefix):
        buf.write_text(current[len(prefix):])
        if not buf.stat().st_size:
            (state / '.subsuper-escalations.since').unlink(missing_ok=True)
            (state / '.subsuper-inject-wedged').unlink(missing_ok=True)
    pending.update(handled=handled, target=data)
    receipts = state / '.codex-queue-receipts'
    receipts.mkdir(mode=0o700, exist_ok=True)
    save(receipts / (pending['id'] + '.json'), pending)
    path.unlink()
    return True


def flush(state, data):
    path = state / '.codex-queue-pending.json'
    if not ancestor(data['owner']):
        supervisor = state / '.supervise-daemon.lock'
        supervisor_pid = int((supervisor / 'pid').read_text())
        if not ancestor(supervisor_pid) or identity(supervisor_pid) != (supervisor / 'pid-identity').read_text().strip():
            raise ValueError('only the coordinator or its supervisor may reconcile')
    if path.exists():
        pending = json.loads(path.read_text())
        if pending['binding'] != data:
            raise ValueError('pending submission belongs to an earlier owner; manual reconciliation required')
        return reconcile(state, data, pending, path)
    if not (state / '.afk').exists() or (state / '.afk-return-catchup').exists():
        return False
    owner = state / '.supervise-daemon.lock'
    pid = int((owner / 'pid').read_text())
    if not ancestor(pid) or identity(pid) != (owner / 'pid-identity').read_text().strip():
        raise ValueError('only the identity-backed supervisor singleton may submit')
    buf = state / '.subsuper-escalations'
    text = buf.read_text() if buf.exists() else ''
    if not text:
        return True
    token = str(uuid.uuid4())
    message = '\u2063Supervisor escalate (' + str(len(text.splitlines())) + ' event(s)): ' + ' | '.join(text.splitlines())
    message += ' (native queue delivery ' + token + '; pre-read; watcher daemon-managed)'
    pending = dict(id=token, buffer=text, message=message, binding=data, submitted=time.time(), acceptance='unknown')
    save(path, pending)
    argv = [data['binary'], 'queue', '--remote', 'unix://' + data['socket'], '--thread', data['thread'], '--message', message]
    env = os.environ.copy()
    env['CODEX_HOME'] = data['account']
    try:
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=10)
        pending.update(exit=result.returncode, acceptance='accepted' if result.returncode == 0 else 'unknown', stdout=result.stdout, stderr=result.stderr)
    except subprocess.TimeoutExpired:
        pending['acceptance'] = 'unknown-timeout'
    save(path, pending)
    return reconcile(state, data, pending, path)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ['bind', 'check', 'flush']:
        raise ValueError('usage: fm-codex-queue.py bind|check|flush')
    if not os.environ.get('FM_HOME') or os.environ.get('FM_STATE_OVERRIDE') or os.environ.get('FM_ROOT_OVERRIDE'):
        raise ValueError('explicit FM_HOME without root/state overrides is required')
    home = Path(os.environ['FM_HOME']).resolve(strict=True)
    state = home / 'state'
    thread = os.environ.get('FM_SUPERVISOR_TARGET') or os.environ.get('CODEX_THREAD_ID', '')
    if str(uuid.UUID(thread)) != thread:
        raise ValueError('target must be an exact thread UUID')
    if sys.argv[1] == 'bind':
        account = Path(os.environ['CODEX_HOME']).resolve(strict=True)
        bind(home, account, state, thread)
        print('native queue: exact coordinator bound; handling proof still required')
    else:
        data = check(home, state, thread)
        if sys.argv[1] == 'flush' and not flush(state, data):
            print('native queue: pending handling receipt; submission will not be repeated', file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        print('native queue: ' + str(error), file=sys.stderr)
        sys.exit(1)
