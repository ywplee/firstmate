#!/usr/bin/env python3
"""One bounded disposable native queue lifecycle rehearsal; invoked by its .sh."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from fm_codex_queue_live_assertions import assert_busy_order, assert_restart_recovery

root = Path(sys.argv[1]).resolve()
evidence = Path(os.environ['FM_CODEX_QUEUE_LIVE_EVIDENCE']).resolve()
evidence.mkdir(parents=True, exist_ok=False)
diagnostic = os.environ.get('FM_CODEX_QUEUE_STARTUP_DIAGNOSTIC') == '1'
deadline = float(os.environ['FM_CODEX_LIVE_DEADLINE']) - (60 if diagnostic else 120)
if time.time() >= deadline:
    raise RuntimeError('outer deadline leaves no execution time')
scratch = Path(os.environ['FM_CODEX_QUEUE_LIVE_SCRATCH']) if diagnostic else Path(tempfile.mkdtemp(prefix='.fm-native-queue-', dir=root))
socket_dir = tempfile.TemporaryDirectory(prefix='fmq-', dir='/tmp')
home = scratch / 'home'
account = scratch / 'account'
home.mkdir()
(home / 'state').mkdir()
account.mkdir(mode=0o700)
python_bin = Path(sys.executable).resolve()
cli = Path(os.environ['FM_CODEX_QUEUE_LIVE_CLI']).resolve()
daemon_bin = Path(os.environ['FM_CODEX_QUEUE_LIVE_DAEMON']).resolve()
source_account = Path(os.environ['CODEX_HOME']).resolve()
def protected_identity():
    paths = [source_account / 'auth.json', source_account / 'config.toml', source_account / 'skills']
    if (source_account / 'skills').is_dir():
        paths.extend(sorted((source_account / 'skills').rglob('*')))
    values = {}
    for path in paths:
        if not path.exists() and not path.is_symlink():
            values[str(path)] = None
            continue
        info = path.lstat()
        values[str(path)] = dict(device=info.st_dev, inode=info.st_ino, mode=info.st_mode,
                                 link=os.readlink(path) if path.is_symlink() else None,
                                 hash=hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
    return values


protected = protected_identity()
endpoint = Path(socket_dir.name) / 'control.sock'
env = os.environ.copy()
for key in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','FM_HOME','CODEX_THREAD_ID','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','NO_MISTAKES_GATE']:
    env.pop(key, None)
env.update(CODEX_HOME=str(account),TERM_PROGRAM='WarpTerminal',FM_HOME=str(home),FM_WEDGE_ALARM_EXEC='discard',FM_GATE_REFUSE_BYPASS='1')
if os.environ.get('ASDF_PYTHON_VERSION'):
    env['ASDF_PYTHON_VERSION']=os.environ['ASDF_PYTHON_VERSION']
pane = None
daemon = None
thread = None
log = []
bindings = {}


class DiagnosticComplete(Exception):
    pass


def interrupted(signum, frame):
    raise RuntimeError('outer deadline or termination signal: ' + str(signum))


signal.signal(signal.SIGTERM, interrupted)


def process_identity(pid):
    return subprocess.check_output(['bash', '-c', '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"', '_', str(root), str(pid)], text=True, timeout=5).strip()


def command(argv, timeout=15, expected=0, **kwargs):
    remaining = deadline - time.time()
    timeout = min(timeout, remaining) if remaining > 0 else timeout
    result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=timeout, **kwargs)
    log.append(dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), argv=argv, exit=result.returncode, stdout=result.stdout, stderr=result.stderr))
    (evidence / 'commands.json').write_text(json.dumps(log, indent=2))
    if result.returncode != expected:
        raise RuntimeError('command failed: ' + result.stderr[:400])
    return result.stdout.strip()


def snapshot():
    if pane:
        value = command(['tmux','capture-pane','-p','-t',pane,'-S','-100'])
        if re.search(r'trust this (directory|folder|workspace|project)|trust.*(hook|configuration)|sign in|log in', value, re.I):
            raise RuntimeError('new trust/login prompt; fixture stops')
        return value
    return ''


def wait(predicate, label, seconds=90):
    stop = min(deadline, time.time() + seconds)
    while time.time() < stop:
        if daemon and daemon.poll() is not None:
            raise RuntimeError('daemon exited before ' + label)
        snapshot()
        if (scratch/'cli.exit').exists():
            raise RuntimeError('native CLI exited before ' + label + ': ' + (scratch/'cli.exit').read_text())
        result = predicate()
        if result:
            return result
        time.sleep(0.5)
    raise RuntimeError('bounded wait expired: ' + label)


def native_events():
    target = home / 'state/.codex-queue-target.json'
    if not target.exists():
        return []
    data = json.loads(target.read_text())
    return [json.loads(line) for line in Path(data['rollout']).read_text().splitlines() if line.endswith('}')]


def final(text):
    return any(item.get('type') == 'event_msg' and item.get('payload',{}).get('type') == 'task_complete' and item['payload'].get('last_agent_message') == text for item in native_events())


def owner_command(argv, label):
    script = home / (label + '.sh')
    result = home / (label + '.exit')
    keys = ['PATH', 'FM_HOME', 'FM_SUPERVISOR_BACKEND', 'FM_SUPERVISOR_TARGET', 'FM_AFK_LAUNCH_ENTRY', 'FM_GATE_REFUSE_BYPASS', 'ASDF_PYTHON_VERSION']
    script.write_text('export ' + shlex.join([key + '=' + env[key] for key in keys if key in env]) + '\n' + shlex.join(argv) + ' > ' + shlex.quote(str(home / (label + '.output'))) + ' 2>&1\nprintf "%s" "$?" > ' + shlex.quote(str(result)) + '\n')
    prompt = 'Run exactly bash ' + shlex.quote(str(script)) + '; do no other work; finish with exactly FINAL_' + label
    command(['tmux', 'send-keys', '-t', pane, '-l', prompt])
    time.sleep(0.3)
    command(['tmux', 'send-keys', '-t', pane, 'Enter'])
    wait(lambda:final('FINAL_' + label) and result.exists(), label + ' owner action')
    if result.read_text() != '0':
        raise RuntimeError('owner action failed: ' + label + ': ' + (home / (label + '.output')).read_text()[:400])


def launch(normal=False, label='normal-start'):
    if normal:
        owner_command([str(root / 'bin/fm-afk-launch.sh'), 'start-normal'], label)
    else:
        command([str(root / 'bin/fm-afk-launch.sh'),'start'])
    def owned_lock(name):
        lock = home / ('state/' + name)
        try:
            pid = int((lock / 'pid').read_text())
            recorded = (lock / 'pid-identity').read_text().strip()
            if process_identity(pid) == recorded:
                return dict(pid=pid, identity=recorded)
        except (FileNotFoundError, subprocess.CalledProcessError):
            return None
        return None
    bindings.setdefault('supervisors', []).append(wait(lambda:owned_lock('.supervise-daemon.lock'), 'supervisor singleton'))
    bindings.setdefault('watchers', []).append(wait(lambda:owned_lock('.watch.lock'), 'owned watcher'))
    (evidence / 'bindings.json').write_text(json.dumps(bindings, indent=2))
    print('owned supervisor and watcher:', bindings['supervisors'][-1], bindings['watchers'][-1], flush=True)


def marker(kind, append=True):
    (home / ('handled-' + kind)).unlink(missing_ok=True)
    message = 'Harmless fixture event ' + kind + ': use a shell to append exactly HANDLED_' + kind + ' and a newline to handled-' + kind + ' in this directory; perform no other work; finish with exactly FINAL_' + kind
    if append:
        command(['bash', '-c', '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervise-daemon.sh"; escalate_add "$FM_HOME/state" "$2"', '_', str(root), message])
    return message


def handled(kind):
    wait(lambda:final('FINAL_' + kind),kind + ' native final')
    wait(lambda:not (home / 'state/.codex-queue-pending.json').exists(),kind + ' receipt')
    lines = (home / ('handled-' + kind)).read_text().splitlines()
    if lines != ['HANDLED_' + kind]:
        raise RuntimeError('non-exact/duplicate handling: ' + kind)
    receipts = [json.loads(path.read_text()) for path in (home / 'state/.codex-queue-receipts').glob('*.json')]
    matches = [receipt for receipt in receipts if 'Harmless fixture event ' + kind + ':' in receipt['buffer']]
    if len(matches) != 1:
        raise RuntimeError('handling lacks one durable receipt: ' + kind)
    turn = matches[0]['handled']['turn']
    items = native_events()
    inputs = [item for item in items if item.get('type') == 'response_item' and item.get('payload', {}).get('role') == 'user' and any(part.get('text') == matches[0]['message'] for part in item['payload'].get('content', []))]
    if len(inputs) != 1 or inputs[0]['payload'].get('internal_chat_message_metadata_passthrough', {}).get('turn_id') != turn:
        raise RuntimeError('handling lacks one exact same-thread input: ' + kind)
    starts = [index for index, item in enumerate(items) if item.get('type') == 'event_msg' and item.get('payload', {}).get('type') == 'task_started' and item['payload'].get('turn_id') == turn]
    completes = [index for index, item in enumerate(items) if item.get('type') == 'event_msg' and item.get('payload', {}).get('type') == 'task_complete' and item['payload'].get('turn_id') == turn]
    if len(starts) != 1 or len(completes) != 1 or starts[0] >= completes[0]:
        raise RuntimeError('handling lacks ordered native turn completion: ' + kind)
    bindings.setdefault('handling', {})[kind] = dict(id=matches[0]['id'], turn=turn, start=starts[0], complete=completes[0])


try:
    shutil.copyfile(source_account / 'auth.json', account / 'auth.json')
    (account / 'auth.json').chmod(0o600)
    (account / 'config.toml').write_text('model="gpt-6.1-sol"\nmodel_reasoning_effort="high"\nproject_doc_max_bytes=0\n[projects.' + json.dumps(str(home)) + ']\ntrust_level="trusted"\n')
    (home / 'AGENTS.md').write_text('This is a disposable supervision fixture. Only run the explicitly requested scratch lock/binding helpers and marker writes in this home. Never supervise real work or change configuration. Native supervisor digests containing marker instructions require only those marker writes and the requested final response.\n')
    bindings = dict(start=datetime.datetime.now(datetime.timezone.utc).isoformat(), scratch=str(scratch), home=str(home), account=str(account), personal_source=str(source_account), cli=str(cli), daemon=str(daemon_bin), cli_hash=hashlib.sha256(cli.read_bytes()).hexdigest(), daemon_hash=hashlib.sha256(daemon_bin.read_bytes()).hexdigest(), source_hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'bin/fm-codex-queue.py',root/'bin/fm-afk-launch.sh',root/'bin/fm-afk-start.sh',root/'bin/fm-afk-return.sh',root/'bin/fm-watch.sh',root/'bin/fm-supervise-daemon.sh',root/'bin/fm-supervisor-target-lib.sh',root/'tests/fm-codex-queue-live-e2e.py',root/'tests/fm_codex_queue_live_assertions.py']})
    bindings['head'] = command(['git', '-C', str(root), 'rev-parse', 'HEAD'])
    diff = command(['git', '-C', str(root), 'diff', '--binary', 'HEAD'])
    (evidence / 'source.diff').write_text(diff)
    bindings['diff_hash'] = hashlib.sha256(diff.encode()).hexdigest()
    bindings['protected_before'] = protected
    (evidence / 'bindings.json').write_text(json.dumps(bindings, indent=2))
    for executable, expected in [(cli,'codex-cli 0.160.1'),(daemon_bin,'codex-cli 0.161.0')]:
        if not executable.is_file() or not os.access(executable,os.X_OK) or command([str(executable),'--no-daemon','--version']) != expected:
            raise RuntimeError('absolute native executable/version preflight failed')
    command([str(python_bin),'-c','import json, pathlib, subprocess, socket, sys; assert sys.version_info >= (3,8); print(sys.executable)'])
    command(['tmux','-V'])
    command(['lsof','-v'])
    command(['git','init','-q',str(home)])
    bindings['python']=str(python_bin)
    bindings['python_version']=command([str(python_bin),'--version'])
    bindings['daemon_argv'] = [str(daemon_bin),'--no-daemon','app-server','--listen','unix://' + str(endpoint),'--managed-daemon','-c','features.api_key_model_discovery=false','-c','features.auth_elicitation=true','-c','features.code_mode_host=true','-c','features.mcp_oauth_refresh_coordination=false']
    (evidence / 'bindings.json').write_text(json.dumps(bindings, indent=2))
    print('source:', bindings['head'], bindings['diff_hash'], 'deadline:', deadline + 120, 'socket:', endpoint, 'daemon argv:', bindings['daemon_argv'], flush=True)
    daemon = subprocess.Popen(bindings['daemon_argv'],env=env,cwd=home,stdout=(evidence/'daemon.stdout').open('w'),stderr=(evidence/'daemon.stderr').open('w'))
    bindings['daemon_identity'] = process_identity(daemon.pid)
    bindings['daemon_pid'] = daemon.pid
    (evidence/'bindings.json').write_text(json.dumps(bindings, indent=2))
    print('owned daemon:', daemon.pid, bindings['daemon_identity'], flush=True)
    wait(lambda:endpoint.exists(),'owned socket',30)
    binder = shlex.join([str(python_bin), str(root/'bin/fm-codex-queue.py'), 'bind'])
    prompt = "Bind this home's native queue. Run exactly one shell command: export " + ('ASDF_PYTHON_VERSION=' + shlex.quote(env['ASDF_PYTHON_VERSION']) + ' ' if env.get('ASDF_PYTHON_VERSION') else '') + 'FM_HOME=' + shlex.quote(str(home)) + ' FM_CODEX_QUEUE_CLI_PID=$(cat ' + shlex.quote(str(scratch/'cli.pid')) + ') FM_CODEX_QUEUE_SOCKET=' + shlex.quote(str(endpoint)) + '; ' + shlex.quote(str(root/'bin/fm-lock.sh')) + ' && cp state/.lock lock-before && if FM_CODEX_QUEUE_SOCKET=' + shlex.quote(str(endpoint) + '.other') + ' ' + binder + ' > wrong-socket.txt 2>&1; then exit 1; fi; cmp state/.lock lock-before && ' + binder + ' && printf BASELINE > baseline. Do no other work. Finish with exactly BASELINE_FINAL.'
    argv=[str(cli),'--remote','unix://' + str(endpoint),'--no-alt-screen','--model','gpt-6.1-sol','-c','model_reasoning_effort="high"','--sandbox','danger-full-access','--ask-for-approval','never','-C',str(home),prompt]
    launch_file = scratch / 'launch.sh'
    inner='printf "%s" "$$" > ' + shlex.quote(str(scratch/'cli.pid')) + '; exec env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u CODEX_THREAD_ID ' + ' '.join(shlex.quote(k+'='+v) for k,v in env.items() if k in ['CODEX_HOME','FM_HOME','TERM_PROGRAM','FM_GATE_REFUSE_BYPASS','FM_WEDGE_ALARM_EXEC','ASDF_PYTHON_VERSION']) + ' ' + shlex.join(argv)
    launch_file.write_text('#!/bin/sh\nsh -c ' + shlex.quote(inner) + ' 2> ' + shlex.quote(str(evidence/'cli.stderr')) + '\nresult=$?\nprintf "%s" "$result" > ' + shlex.quote(str(scratch/'cli.exit')) + '\nprintf "%s" "$result" > ' + shlex.quote(str(evidence/'cli.exit')) + '\nexit "$result"\n')
    launch_file.chmod(0o700)
    tmux_socket = 'fm-native-proof-' + str(os.getpid())
    fakebin = scratch / 'fakebin'
    fakebin.mkdir()
    tmux_bin = shutil.which('tmux')
    (fakebin / 'tmux').write_text('#!/bin/sh\nexec ' + shlex.join([tmux_bin, '-L', tmux_socket]) + ' "$@"\n')
    (fakebin / 'tmux').chmod(0o700)
    env['PATH'] = str(fakebin) + ':' + env['PATH']
    pane=command(['tmux','new-session','-d','-P','-F','#{pane_id}','-s','fm-native-fixture','-x','180','-y','48','/bin/bash --noprofile --norc -i'])
    command(['tmux','set-option','-w','-t',pane,'remain-on-exit','on'])
    bindings['tmux_pid'] = int(command(['tmux', 'display-message', '-p', '-t', pane, '#{pid}']))
    bindings['tmux_identity'] = process_identity(bindings['tmux_pid'])
    bindings.update(daemon_pid=daemon.pid,pane=pane)
    bindings['cli_argv'] = argv
    (evidence/'bindings.json').write_text(json.dumps(bindings,indent=2))
    print('CLI argv:', argv, flush=True)
    print('owned tmux:', bindings['tmux_pid'], bindings['tmux_identity'], flush=True)
    command(['tmux','pipe-pane','-t',pane,'cat > ' + shlex.quote(str(evidence/'cli.stdout'))])
    command(['tmux','send-keys','-t',pane,'-l','exec ' + shlex.quote(str(launch_file))])
    command(['tmux','send-keys','-t',pane,'Enter'])
    wait(lambda:(scratch/'cli.pid').exists(), 'CLI process created', 10)
    cli_pid = int((scratch/'cli.pid').read_text())
    wait(lambda:subprocess.check_output(['ps','-p',str(cli_pid),'-o','comm='],text=True).strip() == str(cli), 'native CLI exec', 10)
    bindings.update(cli_pid=cli_pid, cli_identity=process_identity(cli_pid))
    (evidence/'bindings.json').write_text(json.dumps(bindings,indent=2))
    print('owned CLI:', cli_pid, bindings['cli_identity'], flush=True)
    wait(lambda:(home/'state/.codex-queue-target.json').exists(),'native binding')
    wait(lambda:final('BASELINE_FINAL') and (home/'baseline').exists(),'baseline final')
    target=json.loads((home/'state/.codex-queue-target.json').read_text())
    bindings['cli_identity'] = process_identity(target['cli_pid'])
    bindings['cli_pid'] = target['cli_pid']
    if 'owner socket is absent' not in (home / 'wrong-socket.txt').read_text():
        raise RuntimeError('wrong socket binding was not refused')
    thread=target['thread']
    env.update(FM_SUPERVISOR_BACKEND='codex-queue',FM_SUPERVISOR_TARGET=thread,FM_ESCALATE_BATCH_SECS='0',FM_HOUSEKEEPING_TICK='1',FM_POLL='1',FM_HEARTBEAT='999999',FM_MAX_DEFER_SECS='5')
    command([str(python_bin), str(root/'bin/fm-codex-queue.py'), 'check'])
    original_target = (home / 'state/.codex-queue-target.json').read_bytes()
    original_lock = (home / 'state/.lock').read_bytes()
    for field, value in [('cli_identity', target['cli_identity'] + ' replaced'), ('socket_identity', [target['socket_identity'][0], target['socket_identity'][1] + 1, target['socket_identity'][2]])]:
        changed = dict(target, **{field: value})
        (home / 'state/.codex-queue-target.json').write_text(json.dumps(changed))
        before = (home / 'state/.codex-queue-target.json').read_bytes()
        command([str(python_bin), str(root/'bin/fm-codex-queue.py'), 'check'], expected=1)
        if (home / 'state/.codex-queue-target.json').read_bytes() != before or (home / 'state/.lock').read_bytes() != original_lock:
            raise RuntimeError('refusal changed ownership records')
        (home / 'state/.codex-queue-target.json').write_bytes(original_target)
    bindings['wrong_target_refusals'] = ['socket prefix', 'replaced CLI identity', 'replaced socket identity']
    fault = scratch / 'queue-crash.py'
    fault.write_text('import json, os, pathlib, runpy, signal, subprocess, sys\noriginal = subprocess.run\ndef run(argv, *args, **kwargs):\n    result = original(argv, *args, **kwargs)\n    if len(argv) > 1 and argv[1] == "queue":\n        with open(' + repr(str(evidence / 'queue-attempts.jsonl')) + ', "a") as stream:\n            stream.write(json.dumps(dict(argv=argv, exit=result.returncode, stdout=result.stdout, stderr=result.stderr)) + "\\n")\n            stream.flush()\n            os.fsync(stream.fileno())\n        armed = pathlib.Path(' + repr(str(home / 'crash-after-acceptance')) + ')\n        if armed.exists() and result.returncode == 0:\n            armed.unlink()\n            os.kill(os.getpid(), signal.SIGKILL)\n    return result\nsubprocess.run = run\nsys.argv = sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name="__main__")\n')
    (fakebin / 'python3').write_text('#!/bin/sh\nif [ "$1" = ' + shlex.quote(str(root / 'bin/fm-codex-queue.py')) + ' ]; then exec ' + shlex.join([str(python_bin), str(fault)]) + ' "$@"; fi\nexec ' + shlex.quote(str(python_bin)) + ' "$@"\n')
    (fakebin / 'python3').chmod(0o700)
    daemon_entry = scratch / 'daemon-entry.sh'
    daemon_entry.write_text('#!/bin/sh\nexec env ' + shlex.join([key + '=' + env[key] for key in ['PATH','FM_ESCALATE_BATCH_SECS','FM_HOUSEKEEPING_TICK','FM_POLL','FM_HEARTBEAT','FM_MAX_DEFER_SECS','FM_WEDGE_ALARM_EXEC','FM_GATE_REFUSE_BYPASS','ASDF_PYTHON_VERSION'] if key in env]) + ' ' + shlex.quote(str(root / 'bin/fm-afk-start.sh')) + ' "$@"\n')
    daemon_entry.chmod(0o700)
    env['FM_AFK_LAUNCH_ENTRY'] = str(daemon_entry)
    bindings.update(thread=thread,target=target)
    (evidence/'bindings.json').write_text(json.dumps(bindings,indent=2))
    launch(normal=True)
    if (home / 'state/.afk').exists():
        raise RuntimeError('normal supervision created a fake AFK flag')
    worker_script = home / 'worker-event.sh'
    worker_event = marker('normal-worker', append=False)
    worker_script.write_text('while [ ! -f worker-identity-recorded ]; do sleep 0.2; done\nprintf "%s\\n" ' + shlex.quote('blocked [key=normal-worker]: ' + worker_event) + ' >> ' + shlex.quote(str(home / 'state/native-worker.status')) + '\n')
    worker_argv = [str(cli), '--no-daemon', '--ask-for-approval', 'never', 'exec', '--model', 'gpt-6.1-sol', '-c', 'model_reasoning_effort="high"', '--sandbox', 'danger-full-access', '-C', str(home), 'Run exactly bash worker-event.sh. Do no other work. Finish with exactly WORKER_BLOCKED.']
    worker_file = scratch / 'worker.sh'
    worker_file.write_text('#!/bin/sh\n' + shlex.join(['env', 'CODEX_HOME=' + str(account), 'FM_HOME=' + str(home)] + worker_argv) + ' > ' + shlex.quote(str(evidence / 'worker.stdout')) + ' 2> ' + shlex.quote(str(evidence / 'worker.stderr')) + ' &\nworker_pid=$!\nprintf "%s" "$worker_pid" > ' + shlex.quote(str(scratch / 'worker.pid')) + '\nwait "$worker_pid"\nprintf "%s" "$?" > ' + shlex.quote(str(home / 'worker.exit')) + '\n')
    worker_file.chmod(0o700)
    worker_pane = command(['tmux', 'new-session', '-d', '-P', '-F', '#{pane_id}', '-s', 'fm-native-worker', '/bin/bash --noprofile --norc -i'])
    worker_pid = int(command(['tmux', 'display-message', '-p', '-t', worker_pane, '#{pane_pid}']))
    bindings['worker'] = dict(pane=worker_pane, pid=worker_pid, identity=process_identity(worker_pid), argv=worker_argv)
    (evidence / 'bindings.json').write_text(json.dumps(bindings, indent=2))
    print('owned worker:', bindings['worker'], flush=True)
    (home / 'state/native-worker.meta').write_text('window=' + worker_pane + '\nbackend=tmux\nharness=codex\nkind=ship\n')
    command(['tmux', 'send-keys', '-t', worker_pane, '-l', 'exec ' + shlex.quote(str(worker_file))])
    command(['tmux', 'send-keys', '-t', worker_pane, 'Enter'])
    wait(lambda:(scratch / 'worker.pid').exists(), 'worker process created', 10)
    worker_cli_pid = int((scratch / 'worker.pid').read_text())
    wait(lambda:subprocess.check_output(['ps', '-p', str(worker_cli_pid), '-o', 'comm='], text=True).strip() == str(cli), 'native worker exec', 10)
    bindings['worker'].update(cli_pid=worker_cli_pid, cli_identity=process_identity(worker_cli_pid))
    (evidence / 'bindings.json').write_text(json.dumps(bindings, indent=2))
    print('owned native worker:', bindings['worker'], flush=True)
    (home / 'worker-identity-recorded').touch()
    handled('normal-worker')
    wait(lambda:(home / 'worker.exit').exists(), 'scratch worker synchronous result')
    if (home / 'worker.exit').read_text() != '0':
        raise RuntimeError('scratch worker failed')
    (home / 'state/native-worker.status').write_text('resolved [key=normal-worker]: harmless fixture handled\n')
    if not (home / 'state/.wake-queue').exists() or worker_event not in (home / 'state/.supervise-daemon.log').read_text():
        raise RuntimeError('normal worker event did not pass through actual watcher and classifier')
    if (home / 'state/.afk').exists():
        raise RuntimeError('worker delivery required AFK')
    bindings['normal_worker'] = dict(after_final=True, afk_absent=True, watcher_classified=True)
    marker('idle')
    handled('idle')
    if diagnostic:
        raise DiagnosticComplete()
    draft='DRAFT_PRESERVED_native_fixture'
    command(['tmux','send-keys','-t',pane,'-l',draft])
    wait(lambda:draft in snapshot(),'draft visible')
    (evidence/'draft-before.txt').write_text(snapshot())
    marker('draft')
    handled('draft')
    capture=snapshot()
    (evidence/'draft-after.txt').write_text(capture)
    if not any(draft in line and ('›' in line or '❯' in line) for line in capture.splitlines()[-8:]):
        raise RuntimeError('draft absent from current composer after native delivery')
    command(['tmux','send-keys','-t',pane,'C-u'])
    busy='Run exactly this shell command: printf BUSY_START > busy-start; for attempt in $(seq 1 300); do [ -f busy-release ] && break; sleep 0.2; done; test -f busy-release && printf BUSY_END > busy-end. Do no other work. Finish with exactly BUSY_FINAL.'
    command(['tmux','send-keys','-t',pane,'-l',busy])
    time.sleep(0.3)
    command(['tmux','send-keys','-t',pane,'Enter'])
    wait(lambda:(home/'busy-start').exists(),'busy tool start')
    busy_event = marker('busy')
    pending_path = home / 'state/.codex-queue-pending.json'
    def accepted_busy():
        if not pending_path.exists():
            return None
        pending = json.loads(pending_path.read_text())
        return pending if pending.get('acceptance') == 'accepted' and busy_event in pending['buffer'].splitlines() else None
    restart_pending = wait(accepted_busy, 'accepted unreconciled busy submission')
    if (home/'handled-busy').exists():
        raise RuntimeError('native queue interrupted the busy turn')
    command([str(root/'bin/fm-afk-launch.sh'),'stop'])
    if not pending_path.exists() or json.loads(pending_path.read_text()) != restart_pending:
        raise RuntimeError('restart must retain the accepted unreconciled submission')
    later_event = marker('restart')
    buffered = (home / 'state/.subsuper-escalations').read_text()
    if not buffered.startswith(restart_pending['buffer']) or later_event not in buffered[len(restart_pending['buffer']):].splitlines():
        raise RuntimeError('later event was not buffered behind the pending submission')
    (evidence / 'restart-pending.json').write_text(json.dumps(restart_pending, indent=2))
    (evidence / 'restart-buffer.txt').write_text(buffered)
    (home / 'busy-release').write_text('release')
    wait(lambda:final('FINAL_busy'), 'original queued turn completes while supervision is stopped')
    if not pending_path.exists() or json.loads(pending_path.read_text()) != restart_pending:
        raise RuntimeError('pending delivery was reconciled before supervisor restart')
    launch(normal=True, label='normal-restart')
    handled('busy')
    handled('restart')
    if not (home/'busy-end').exists():
        raise RuntimeError('busy ordering was not preserved')
    receipts = [json.loads(path.read_text()) for path in (home / 'state/.codex-queue-receipts').glob('*.json')]
    bindings['restart_recovery'] = assert_restart_recovery(native_events(), restart_pending, later_event, receipts)
    busy_receipts = [receipt for receipt in receipts if busy_event in receipt['buffer'].splitlines()]
    if len(busy_receipts) != 1:
        raise RuntimeError('busy event lacks one exact handling receipt')
    bindings['busy_order'] = assert_busy_order(native_events(), busy, busy_receipts[0])
    owner_command([str(root / 'bin/fm-afk-launch.sh'), 'stop-normal'], 'normal-disable')
    disabled_event = marker('disabled')
    attempts_path = evidence / 'queue-attempts.jsonl'
    attempts_before_disable = attempts_path.read_text()
    time.sleep(3)
    if (home / 'handled-disabled').exists() or attempts_path.read_text() != attempts_before_disable or (home / 'state/.codex-queue-normal.json').exists() or (home / 'state/.supervise-daemon.lock').exists():
        raise RuntimeError('explicit normal disable left submission active')
    launch(normal=True, label='normal-reenable')
    handled('disabled')
    if disabled_event not in (home / 'state/.codex-queue-receipts' / (bindings['handling']['disabled']['id'] + '.json')).read_text():
        raise RuntimeError('disable lost the buffered event')
    normal_pid = int((home / 'state/.supervise-daemon.lock/pid').read_text())
    launch()
    if int((home / 'state/.supervise-daemon.lock/pid').read_text()) != normal_pid or not (home / 'state/.afk').exists():
        raise RuntimeError('AFK entry did not reuse the owned normal singleton')
    bindings['normal_disable_and_afk_reuse'] = dict(disabled=True, buffered_event_preserved=True, reused_pid=normal_pid)
    return_script = home / 'pending-return.sh'
    return_script.write_text('export FM_HOME=' + shlex.quote(str(home)) + ' FM_SUPERVISOR_TARGET=' + shlex.quote(thread) + '\nprintf started > return-start\nwhile [ ! -f return-request ]; do sleep 0.2; done\n' + shlex.quote(str(root/'bin/fm-afk-return.sh')) + ' > return-begin.txt 2>&1\nprintf "%s" "$?" > return-begin.exit\nwhile [ ! -f return-release ]; do sleep 0.2; done\nprintf ended > return-end\n')
    busy_return = 'Run exactly bash pending-return.sh in this scratch directory; do no other work; finish with exactly RETURN_BUSY_FINAL.'
    command(['tmux','send-keys','-t',pane,'-l',busy_return])
    time.sleep(0.3)
    command(['tmux','send-keys','-t',pane,'Enter'])
    wait(lambda:(home/'return-start').exists(),'pending-return foreground tool')
    (home/'crash-after-acceptance').touch()
    ambiguous_event = marker('ambiguous')
    def ambiguous_pending():
        if pending_path.exists() and not (home/'crash-after-acceptance').exists():
            value = json.loads(pending_path.read_text())
            return value if value['acceptance'] == 'unknown' and ambiguous_event in value['buffer'].splitlines() else None
    ambiguous = wait(ambiguous_pending, 'real queue accepted before submitting helper crashed')
    wait(lambda:(home/'state/.subsuper-inject-wedged').exists(),'ambiguous pending wedge')
    attempts_path = evidence / 'queue-attempts.jsonl'
    attempts = [json.loads(line) for line in attempts_path.read_text().splitlines()]
    attempts_before = [attempt for attempt in attempts if ambiguous['message'] in attempt['argv']]
    if len(attempts_before) != 1 or attempts_before[0]['exit'] != 0:
        raise RuntimeError('ambiguous submission lacks one real accepted attempt')
    time.sleep(6)
    if json.loads(pending_path.read_text()) != ambiguous or len([line for line in attempts_path.read_text().splitlines() if ambiguous['message'] in json.loads(line)['argv']]) != 1:
        raise RuntimeError('ambiguous submission was changed or retried')
    (evidence/'ambiguous-pending.json').write_text(json.dumps(ambiguous, indent=2))
    (evidence/'ambiguous-wedge.txt').write_text((home/'state/.subsuper-inject-wedged').read_text())
    (home/'return-request').touch()
    wait(lambda:(home/'return-begin.exit').exists(),'pending return synchronous result')
    if (home/'return-begin.exit').read_text() != '3' or not (home/'state/.afk-return-catchup').exists() or not pending_path.exists():
        raise RuntimeError('pending return did not retain its catch-up gate and journal')
    later_return = marker('return-later')
    (evidence/'pending-return-gate.txt').write_text((home/'state/.afk-return-catchup').read_text())
    (home/'return-release').touch()
    wait(lambda:final('FINAL_ambiguous'),'ambiguous original input completed after return began')
    check_return = 'Run exactly ' + shlex.quote(str(root/'bin/fm-afk-return.sh')) + ' check > return-check.txt 2>&1; save its exit status in return-check.exit. Do no other work; finish with exactly RETURN_CLEAR_FINAL.'
    command(['tmux','send-keys','-t',pane,'-l',check_return])
    time.sleep(0.3)
    command(['tmux','send-keys','-t',pane,'Enter'])
    wait(lambda:final('RETURN_CLEAR_FINAL') and (home/'return-check.exit').exists(),'coordinator return reconciliation')
    if (home/'return-check.exit').read_text().strip() != '0' or (home/'state/.afk-return-catchup').exists() or later_return not in (home/'return-check.txt').read_text():
        raise RuntimeError('return catch-up did not reconcile and preserve the later event')
    handled('ambiguous')
    attempts_after = [json.loads(line) for line in attempts_path.read_text().splitlines()]
    if attempts_after != attempts:
        raise RuntimeError('a new native submission occurred during return')
    bindings['ambiguous_acceptance'] = dict(id=ambiguous['id'], acceptance=ambiguous['acceptance'], attempts=1, fault='submitting helper SIGKILL after real native queue exit zero')
    bindings['pending_return'] = dict(begin_exit=3, check_exit=0, later_event_caught_up=True, new_submissions=0)
    if (home/'state/.afk').exists() or (home/'state/.supervise-daemon.lock').exists():
        raise RuntimeError('orderly return left supervision active')
    if (home / 'state/.codex-queue-normal.json').exists():
        raise RuntimeError('genuine AFK return left normal mode armed')
    launch(normal=True, label='normal-rearm')
    marker('rearmed')
    handled('rearmed')
    command(['tmux', 'send-keys', '-t', pane, '-l', '/quit'])
    time.sleep(0.3)
    command(['tmux', 'send-keys', '-t', pane, 'Enter'])
    stop = min(deadline, time.time() + 20)
    while time.time() < stop and (not (scratch / 'cli.exit').exists() or (home / 'state/.supervise-daemon.lock').exists()):
        time.sleep(0.2)
    if not (scratch / 'cli.exit').exists() or (home / 'state/.supervise-daemon.lock').exists():
        raise RuntimeError('normal singleton did not stop after exact CLI owner exit')
    marker('owner-exit')
    command([str(python_bin), str(root / 'bin/fm-codex-queue.py'), 'check'], expected=1)
    command([str(python_bin), str(root / 'bin/fm-codex-queue.py'), 'flush'], expected=1)
    if (home / 'handled-owner-exit').exists() or not (home / 'state/.codex-queue-normal.json').exists():
        raise RuntimeError('departed owner was replaced or ownership evidence discarded')
    bindings['normal_rearm_and_exit'] = dict(owner_rearmed=True, exact_cli_exit=int((scratch / 'cli.exit').read_text()), singleton_stopped=True, owner_exit_refused=True)
    bindings['verdict']='PASS: normal watcher delivery, disable/rearm, owner exit, AFK reuse/return, exact binding, post-final, draft, busy ordering, pending restart and ambiguous acceptance'
except DiagnosticComplete:
    bindings['verdict']='PASS: limited native startup, binding/check and one post-final receipt; full lifecycle remains untested'
except Exception as error:
    bindings['verdict']='FAIL: ' + str(error)
    print(bindings['verdict'],file=sys.stderr)
finally:
    try:
        errors=[]
        try:
            (evidence/'last-pane.txt').write_text(snapshot())
        except Exception as error:
            errors.append(str(error))
        try:
            if (home/'state/.afk-daemon-terminal').exists():
                command([str(root/'bin/fm-afk-launch.sh'),'stop'])
        except Exception as error:
            errors.append(str(error))
        try:
            if (scratch/'cli.exit').exists():
                bindings['cli_exit']=int((scratch/'cli.exit').read_text())
            elif pane:
                command(['tmux','send-keys','-t',pane,'C-u'])
                command(['tmux','send-keys','-t',pane,'-l','/quit'])
                time.sleep(0.3)
                command(['tmux','send-keys','-t',pane,'Enter'])
                stop=time.monotonic()+10
                while time.monotonic()<stop and not (scratch/'cli.exit').exists():
                    time.sleep(0.2)
                if not (scratch/'cli.exit').exists():
                    errors.append('CLI normal exit unconfirmed')
                    command(['tmux','kill-pane','-t',pane])
                else:
                    bindings['cli_exit']=int((scratch/'cli.exit').read_text())
        except Exception as error:
            errors.append(str(error))
        try:
            if daemon and daemon.poll() is None:
                if process_identity(daemon.pid) != bindings['daemon_identity']:
                    raise RuntimeError('scratch daemon identity changed; refusing signal')
                daemon.terminate()
                try:
                    bindings['daemon_exit']=daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if process_identity(daemon.pid) == bindings['daemon_identity']:
                        daemon.kill()
                        bindings['daemon_exit']=daemon.wait(timeout=5)
            elif daemon:
                bindings['daemon_exit']=daemon.returncode
            if (home/'state/.codex-queue-target.json').exists():
                target=json.loads((home/'state/.codex-queue-target.json').read_text())
                shutil.copyfile(target['rollout'], evidence/'native-rollout.jsonl')
            shutil.copytree(home, evidence/'home',dirs_exist_ok=True)
            bindings['protected_after'] = protected_identity()
            bindings['protected_source_unchanged'] = bindings['protected_after'] == protected
            if not bindings['protected_source_unchanged']:
                bindings['verdict']='FAIL: protected source changed'
        except Exception as error:
            errors.append(str(error))
        if errors:
            bindings['cleanup_errors']=errors
    finally:
        (account/'auth.json').unlink(missing_ok=True)
    bindings['scratch_credential_removed'] = not (account/'auth.json').exists()
    try:
        if bindings.get('tmux_pid') and process_identity(bindings['tmux_pid']) == bindings['tmux_identity']:
            command(['tmux', 'kill-server'])
    except subprocess.CalledProcessError:
        pass
    except Exception as error:
        bindings.setdefault('cleanup_errors', []).append(str(error))
    socket_dir.cleanup()
    (evidence/'commands.json').write_text(json.dumps(log,indent=2))
    (evidence/'receipt.json').write_text(json.dumps(bindings,indent=2))
    print(bindings.get('verdict','FAIL'))
    print('evidence:',evidence)
    if 'cleanup_errors' not in bindings and bindings.get('protected_source_unchanged'):
        shutil.rmtree(scratch)
        bindings['scratch_removed'] = not scratch.exists()
        (evidence/'receipt.json').write_text(json.dumps(bindings,indent=2))
    print('scratch removed:',bindings.get('scratch_removed', False))
sys.exit(0 if bindings.get('verdict','').startswith('PASS') and 'cleanup_errors' not in bindings else 1)
