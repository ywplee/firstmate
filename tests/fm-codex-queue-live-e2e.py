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
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve()
evidence = Path(os.environ['FM_CODEX_QUEUE_LIVE_EVIDENCE']).resolve()
evidence.mkdir(parents=True, exist_ok=False)
scratch = Path(tempfile.mkdtemp(prefix='fm-native-queue-', dir='/private/tmp' if sys.platform == 'darwin' else None)).resolve()
home = scratch / 'home'
account = scratch / 'account'
home.mkdir()
(home / 'state').mkdir()
account.mkdir(mode=0o700)
python_bin = Path(sys.executable).resolve()
cli = Path(os.environ['FM_CODEX_QUEUE_LIVE_CLI']).resolve()
daemon_bin = Path(os.environ['FM_CODEX_QUEUE_LIVE_DAEMON']).resolve()
source_account = Path(os.environ['CODEX_HOME']).resolve()
protected = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in [source_account / 'auth.json', source_account / 'config.toml'] if p.exists()}
shutil.copyfile(source_account / 'auth.json', account / 'auth.json')
(account / 'auth.json').chmod(0o600)
(account / 'config.toml').write_text('model="gpt-6.1-sol"\nmodel_reasoning_effort="high"\n[projects.' + json.dumps(str(home)) + ']\ntrust_level="trusted"\n')
(home / 'AGENTS.md').write_text('This is a disposable supervision fixture. Only run the explicitly requested scratch lock/binding helpers and marker writes in this home. Never supervise real work or change configuration. Native supervisor digests containing marker instructions require only those marker writes and the requested final response.\n')
endpoint = scratch / 'control.sock'
env = os.environ.copy()
for key in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','FM_HOME','CODEX_THREAD_ID','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','NO_MISTAKES_GATE']:
    env.pop(key, None)
env.update(CODEX_HOME=str(account),TERM_PROGRAM='WarpTerminal',FM_HOME=str(home),FM_WEDGE_ALARM_EXEC='discard',FM_GATE_REFUSE_BYPASS='1')
if os.environ.get('ASDF_PYTHON_VERSION'):
    env['ASDF_PYTHON_VERSION']=os.environ['ASDF_PYTHON_VERSION']
deadline = time.monotonic() + 570
pane = None
daemon = None
thread = None
log = []


def command(argv, timeout=15, **kwargs):
    result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=timeout, **kwargs)
    log.append(dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), argv=argv, exit=result.returncode, stdout=result.stdout, stderr=result.stderr))
    if result.returncode:
        raise RuntimeError('command failed: ' + result.stderr[:400])
    return result.stdout.strip()


def snapshot():
    if pane:
        value = command(['tmux','capture-pane','-p','-t',pane,'-S','-100'])
        if re.search(r'trust this (directory|folder)|sign in|log in', value, re.I):
            raise RuntimeError('new trust/login prompt; fixture stops')
        return value
    return ''


def wait(predicate, label, seconds=90):
    stop = min(deadline, time.monotonic() + seconds)
    while time.monotonic() < stop:
        if daemon and daemon.poll() is not None:
            raise RuntimeError('daemon exited before ' + label)
        snapshot()
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


def launch():
    command([str(root / 'bin/fm-afk-launch.sh'),'start'])
    wait(lambda:(home / 'state/.supervise-daemon.lock/pid').exists(),'supervisor singleton')


def marker(kind):
    (home / ('handled-' + kind)).unlink(missing_ok=True)
    message = 'Harmless fixture event ' + kind + ': use a shell to append exactly HANDLED_' + kind + ' and a newline to handled-' + kind + ' in this directory; perform no other work; finish with exactly FINAL_' + kind
    with (home / 'state/.subsuper-escalations').open('a') as stream:
        stream.write(message + '\n')
    (home / 'state/.subsuper-escalations.since').write_text(str(int(time.time())))


def handled(kind):
    wait(lambda:final('FINAL_' + kind),kind + ' native final')
    wait(lambda:not (home / 'state/.codex-queue-pending.json').exists(),kind + ' receipt')
    lines = (home / ('handled-' + kind)).read_text().splitlines()
    if lines != ['HANDLED_' + kind]:
        raise RuntimeError('non-exact/duplicate handling: ' + kind)


try:
    bindings = dict(start=datetime.datetime.now(datetime.timezone.utc).isoformat(), scratch=str(scratch), home=str(home), account=str(account), personal_source=str(source_account), cli=str(cli), daemon=str(daemon_bin), cli_hash=hashlib.sha256(cli.read_bytes()).hexdigest(), daemon_hash=hashlib.sha256(daemon_bin.read_bytes()).hexdigest(), source_hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'bin/fm-codex-queue.py',root/'bin/fm-afk-launch.sh',root/'bin/fm-supervise-daemon.sh',root/'bin/fm-supervisor-target-lib.sh']})
    (evidence / 'bindings.json').write_text(json.dumps(bindings, indent=2))
    for executable, expected in [(cli,'codex-cli 0.160.1'),(daemon_bin,'codex-cli 0.161.0')]:
        if not executable.is_file() or not os.access(executable,os.X_OK) or command([str(executable),'--no-daemon','--version']) != expected:
            raise RuntimeError('absolute native executable/version preflight failed')
    command([str(python_bin),'-c','import json, pathlib, subprocess, socket, sys; assert sys.version_info >= (3,8); print(sys.executable)'])
    command(['tmux','-V'])
    command(['lsof','-v'])
    bindings['python']=str(python_bin)
    bindings['python_version']=command([str(python_bin),'--version'])
    daemon = subprocess.Popen([str(daemon_bin),'app-server','--listen','unix://' + str(endpoint),'--managed-daemon','-c','features.api_key_model_discovery=false','-c','features.auth_elicitation=true','-c','features.code_mode_host=true','-c','features.mcp_oauth_refresh_coordination=false'],env=env,cwd=home,stdout=(evidence/'daemon.stdout').open('w'),stderr=(evidence/'daemon.stderr').open('w'))
    wait(lambda:endpoint.exists(),'owned socket',30)
    prompt = 'Run exactly one shell command: export ' + ('ASDF_PYTHON_VERSION=' + shlex.quote(env['ASDF_PYTHON_VERSION']) + ' ' if env.get('ASDF_PYTHON_VERSION') else '') + 'FM_HOME=' + shlex.quote(str(home)) + ' FM_CODEX_QUEUE_CLI_PID=$(cat ' + shlex.quote(str(scratch/'cli.pid')) + ') FM_CODEX_QUEUE_SOCKET=' + shlex.quote(str(endpoint)) + '; ' + shlex.quote(str(root/'bin/fm-lock.sh')) + ' && ' + shlex.quote(str(python_bin)) + ' ' + shlex.quote(str(root/'bin/fm-codex-queue.py')) + ' bind && printf BASELINE > baseline. Do no other work. Finish with exactly BASELINE_FINAL.'
    argv=[str(cli),'--remote','unix://' + str(endpoint),'--no-alt-screen','--model','gpt-6.1-sol','-c','model_reasoning_effort="high"','--sandbox','danger-full-access','--ask-for-approval','never','-C',str(home),prompt]
    launch_file = scratch / 'launch.sh'
    inner='printf "%s" "$$" > ' + shlex.quote(str(scratch/'cli.pid')) + '; exec env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u CODEX_THREAD_ID ' + ' '.join(shlex.quote(k+'='+v) for k,v in env.items() if k in ['CODEX_HOME','FM_HOME','TERM_PROGRAM','FM_GATE_REFUSE_BYPASS','FM_WEDGE_ALARM_EXEC','ASDF_PYTHON_VERSION']) + ' ' + shlex.join(argv)
    launch_file.write_text('#!/bin/sh\nsh -c ' + shlex.quote(inner) + '\nresult=$?\nprintf "%s" "$result" > ' + shlex.quote(str(scratch/'cli.exit')) + '\nexit "$result"\n')
    launch_file.chmod(0o700)
    pane=command(['tmux','new-window','-d','-P','-F','#{pane_id}','-n','fm-native-fixture',str(launch_file)])
    bindings.update(daemon_pid=daemon.pid,pane=pane)
    (evidence/'bindings.json').write_text(json.dumps(bindings,indent=2))
    wait(lambda:(home/'state/.codex-queue-target.json').exists(),'native binding')
    wait(lambda:final('BASELINE_FINAL') and (home/'baseline').exists(),'baseline final')
    target=json.loads((home/'state/.codex-queue-target.json').read_text())
    thread=target['thread']
    env.update(FM_SUPERVISOR_BACKEND='codex-queue',FM_SUPERVISOR_TARGET=thread,FM_ESCALATE_BATCH_SECS='0',FM_HOUSEKEEPING_TICK='1',FM_POLL='1',FM_HEARTBEAT='999999',FM_MAX_DEFER_SECS='5')
    bindings.update(thread=thread,target=target)
    (evidence/'bindings.json').write_text(json.dumps(bindings,indent=2))
    launch()
    marker('idle')
    handled('idle')
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
    busy='Use one shell command to write BUSY_START to busy-start, sleep 8, then write BUSY_END to busy-end. Do no other work. Finish with exactly BUSY_FINAL.'
    command(['tmux','send-keys','-t',pane,'-l',busy])
    time.sleep(0.3)
    command(['tmux','send-keys','-t',pane,'Enter'])
    wait(lambda:(home/'busy-start').exists(),'busy tool start')
    marker('busy')
    time.sleep(1)
    if (home/'handled-busy').exists():
        raise RuntimeError('native queue interrupted the busy turn')
    handled('busy')
    if not (home/'busy-end').exists():
        raise RuntimeError('busy ordering was not preserved')
    command([str(root/'bin/fm-afk-launch.sh'),'stop'])
    marker('restart')
    launch()
    handled('restart')
    command([str(root/'bin/fm-afk-return.sh')])
    if (home/'state/.afk').exists() or (home/'state/.supervise-daemon.lock').exists():
        raise RuntimeError('orderly return left supervision active')
    bindings['verdict']='PASS: real post-final, pending draft, busy ordering, restart and orderly return'
except Exception as error:
    bindings['verdict']='FAIL: ' + str(error)
    print(bindings['verdict'],file=sys.stderr)
finally:
    errors=[]
    try:
        (evidence/'last-pane.txt').write_text(snapshot())
        if (home/'state/.afk-daemon-terminal').exists():
            command([str(root/'bin/fm-afk-launch.sh'),'stop'])
    except Exception as error:
        errors.append(str(error))
    try:
        if pane:
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
        if daemon:
            daemon.terminate()
            bindings['daemon_exit']=daemon.wait(timeout=10)
        if (home/'state/.codex-queue-target.json').exists():
            target=json.loads((home/'state/.codex-queue-target.json').read_text())
            shutil.copyfile(target['rollout'], evidence/'native-rollout.jsonl')
        shutil.copytree(home, evidence/'home',dirs_exist_ok=True)
        bindings['protected_source_unchanged']=all(p.exists() and hashlib.sha256(p.read_bytes()).hexdigest()==value for p,value in protected.items())
        if not bindings['protected_source_unchanged']:
            bindings['verdict']='FAIL: protected source changed'
    except Exception as error:
        errors.append(str(error))
    if errors:
        bindings['cleanup_errors']=errors
    (account/'auth.json').unlink(missing_ok=True)
    (evidence/'commands.json').write_text(json.dumps(log,indent=2))
    (evidence/'receipt.json').write_text(json.dumps(bindings,indent=2))
    print(bindings.get('verdict','FAIL'))
    print('evidence:',evidence)
    print('scratch retained without credential:',scratch)
sys.exit(0 if bindings.get('verdict','').startswith('PASS') and 'cleanup_errors' not in bindings else 1)
