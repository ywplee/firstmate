#!/usr/bin/env bash
# Native queue acceptance, exact-turn receipts, type-once recovery and refusal.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$@" "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

root = Path(sys.argv.pop())
spec = importlib.util.spec_from_file_location('queue_helper', root / 'bin/fm-codex-queue.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
sys.path.insert(0, str(root / 'tests'))
from fm_codex_queue_live_assertions import assert_busy_order, assert_restart_recovery

class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.rollout = self.state / 'rollout.jsonl'
        self.rollout.write_text('')
        self.data = {'rollout': str(self.rollout), 'binary': '/unused', 'socket': '/unused', 'thread': 'thread', 'account': str(self.state), 'owner': 42}
        env = patch.dict(os.environ, FM_HOME=str(self.state), FM_STATE_OVERRIDE=str(self.state))
        env.start()
        self.addCleanup(env.stop)
        (self.state / '.afk').touch()
        (self.state / '.supervise-daemon.lock').mkdir()
        (self.state / '.supervise-daemon.lock/pid').write_text('42')
        (self.state / '.supervise-daemon.lock/pid-identity').write_text('identity')
        (self.state / '.subsuper-escalations').write_text('decision event\n')
        for name, value in [('ancestor', True), ('identity', 'identity')]:
            p = patch.object(helper, name, return_value=value)
            p.start()
            self.addCleanup(p.stop)

    def record(self, event):
        with self.rollout.open('a') as stream:
            stream.write(json.dumps(event) + '\n')

    def handle(self, message, turn='next'):
        self.record({'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': turn}})
        self.record({'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'text': message}], 'internal_chat_message_metadata_passthrough': {'turn_id': turn}}})
        self.record({'type': 'event_msg', 'timestamp': 'complete', 'payload': {'type': 'task_complete', 'turn_id': turn}})

    def accepted(self):
        return patch.object(helper.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'Queued message id', ''))

    def test_normal_delivery_survives_final_and_supervisor_restart_without_afk(self):
        (self.state / '.afk').unlink()
        helper.save(self.state / '.codex-queue-normal.json', self.data)
        with self.accepted() as command:
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 1)
        pending = json.loads((self.state / '.codex-queue-pending.json').read_text())
        self.handle(pending['message'])
        with self.accepted() as command:
            self.assertTrue(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 0)
        with (self.state / '.subsuper-escalations').open('a') as stream:
            stream.write('later blocked event\n')
        with self.accepted() as command:
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 1)
        self.assertFalse((self.state / '.afk').exists())

    def test_normal_delivery_stops_for_return_disable_or_changed_binding(self):
        (self.state / '.afk').unlink()
        normal = self.state / '.codex-queue-normal.json'
        helper.save(normal, self.data)
        gate = self.state / '.afk-return-catchup'
        gate.touch()
        with self.accepted() as command:
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 0)
        gate.unlink()
        for value in [dict(self.data, thread='other'), None]:
            if value is None:
                normal.unlink()
            else:
                helper.save(normal, value)
            with self.accepted() as command:
                self.assertFalse(helper.flush(self.state, self.data))
                self.assertEqual(command.call_count, 0)

    def test_only_owner_can_enable_normal_after_catchup(self):
        (self.state / '.afk').unlink()
        with patch.object(helper, 'ancestor', return_value=False):
            with self.assertRaisesRegex(ValueError, 'owning coordinator'):
                helper.normal_control(self.state, self.data, True)
        gate = self.state / '.afk-return-catchup'
        gate.touch()
        with self.assertRaisesRegex(ValueError, 'catch-up'):
            helper.normal_control(self.state, self.data, True)
        gate.unlink()
        helper.normal_control(self.state, self.data, True)
        self.assertEqual(json.loads((self.state / '.codex-queue-normal.json').read_text()), self.data)
        (self.state / '.afk').touch()
        with self.assertRaisesRegex(ValueError, 'away mode'):
            helper.normal_control(self.state, self.data, True)
        (self.state / '.afk').unlink()
        helper.normal_control(self.state, self.data, False)
        self.assertFalse((self.state / '.codex-queue-normal.json').exists())

    def test_normal_launcher_reuses_singleton_without_fake_afk(self):
        (self.state / '.afk').unlink()
        script = '''
. "$1/bin/fm-afk-launch.sh"
discover_supervisor_target() { printf '%s' exact-test-target; }
discover_supervisor_backend() { printf '%s' codex-queue; }
python3() { printf '%s\\n' "$2" >> "$FM_HOME/commands"; }
daemon_lock_held_by_live_daemon() { return 0; }
fm_afk_launch_record_validate_if_present() { return 0; }
fm_afk_launch_create_tmux() { exit 9; }
fm_afk_launch_start normal || exit 1
test ! -e "$FM_AFK_LAUNCH_STATE/.afk" || exit 2
fm_afk_launch_start || exit 3
test -f "$FM_AFK_LAUNCH_STATE/.afk" || exit 4
'''
        target = self.state / '.codex-queue-target.json'
        helper.save(target, self.data)
        result = subprocess.run(['bash', '-c', script, '_', str(root)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.state / 'commands').read_text().splitlines(), ['check', 'enable', 'check'])
        self.assertEqual((self.state / '.supervise-daemon.lock/pid').read_text(), '42')

    def test_normal_native_defer_surfaces_wedge_without_afk(self):
        (self.state / '.afk').unlink()
        (self.state / '.subsuper-escalations.since').write_text('1')
        script = '''
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-supervise-daemon.sh"
python3() { [ "$2" = active ]; }
FM_SUPERVISOR_BACKEND=codex-queue
FM_MAX_DEFER_SECS=1
FM_ESCALATE_BATCH_SECS=0
housekeeping "$2"
'''
        result = subprocess.run(['bash', '-c', script, '_', str(root), str(self.state)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state / '.subsuper-inject-wedged').exists())
        self.assertEqual((self.state / '.subsuper-escalations').read_text(), 'decision event\n')
        self.assertFalse((self.state / '.afk').exists())

    def test_default_signal_grace_is_interruptible_for_supervisor_shutdown(self):
        (self.state / '.afk').unlink()
        fakebin = self.state / 'fakebin'
        fakebin.mkdir()
        tmux = fakebin / 'tmux'
        tmux.write_text('#!/bin/sh\nexit 0\n')
        tmux.chmod(0o700)
        (self.state / 'worker.status').write_text('blocked: harmless fixture event\n')
        env = dict(os.environ, PATH=str(fakebin) + ':' + os.environ['PATH'], FM_POLL='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_WEDGE_ALARM_EXEC='discard')
        env.pop('FM_SIGNAL_GRACE', None)
        child = None
        with subprocess.Popen(['bash', str(root / 'bin/fm-watch.sh')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as watcher:
            try:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline and child is None:
                    children = subprocess.run(['pgrep', '-P', str(watcher.pid)], capture_output=True, text=True).stdout.split()
                    for value in children:
                        try:
                            args = helper.process_args(int(value))
                        except OSError:
                            continue
                        if len(args) == 2 and Path(args[0]).name == 'sleep' and args[1] == '30':
                            child = int(value)
                            break
                    time.sleep(0.02)
                self.assertIsNotNone(child, 'watcher did not enter the default signal grace')
                watcher.terminate()
                self.assertNotEqual(watcher.wait(timeout=2), 0)
                self.assertFalse((self.state / '.watch.lock').exists())
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
                self.assertFalse((self.state / '.wake-queue').exists())
            finally:
                if watcher.poll() is None:
                    watcher.terminate()
                    if child:
                        try:
                            os.kill(child, 15)
                        except ProcessLookupError:
                            pass
                    watcher.wait(timeout=3)
                watcher.communicate()
        env['FM_SIGNAL_GRACE'] = '1'
        recovery = subprocess.run(['bash', str(root / 'bin/fm-watch.sh')], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(recovery.returncode, 0, recovery.stderr)
        self.assertTrue(recovery.stdout.startswith('signal:'))
        records = (self.state / '.wake-queue').read_text().splitlines()
        self.assertTrue(records)
        for record in records:
            self.assertIn('\tsignal\tworker.status\t', record)

    def test_acceptance_is_pending_and_restart_does_not_resend(self):
        with self.accepted() as command:
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 1)
        self.assertEqual((self.state / '.subsuper-escalations').read_text(), 'decision event\n')
        pending = json.loads((self.state / '.codex-queue-pending.json').read_text())
        self.assertEqual(pending['acceptance'], 'accepted')
        self.handle(pending['message'])
        with self.accepted() as command:
            self.assertTrue(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 0)
        self.assertFalse((self.state / '.codex-queue-pending.json').exists())
        self.assertEqual((self.state / '.subsuper-escalations').read_text(), '')
        self.assertEqual(len(list((self.state / '.codex-queue-receipts').glob('*.json'))), 1)

    def test_unrelated_turn_is_not_handling_and_new_events_survive(self):
        with self.accepted():
            helper.flush(self.state, self.data)
        pending = json.loads((self.state / '.codex-queue-pending.json').read_text())
        self.handle('a different input')
        self.assertFalse(helper.flush(self.state, self.data))
        (self.state / '.subsuper-escalations').write_text('decision event\nnew event\n')
        self.handle(pending['message'])
        self.assertTrue(helper.flush(self.state, self.data))
        self.assertEqual((self.state / '.subsuper-escalations').read_text(), 'new event\n')

    def test_ambiguous_timeout_never_resends(self):
        with patch.object(helper.subprocess, 'run', side_effect=subprocess.TimeoutExpired('queue', 10)) as command:
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 1)
        self.assertEqual(json.loads((self.state / '.codex-queue-pending.json').read_text())['acceptance'], 'unknown-timeout')

    def test_restart_preserves_native_buffer_before_submission(self):
        artifacts = {'.subsuper-escalations': 'decision event\n', '.subsuper-escalations.since': '123', '.subsuper-inject-wedged': 'wedge'}
        for name, value in artifacts.items():
            (self.state / name).write_text(value)
        target = self.state / '.codex-queue-target.json'
        helper.save(target, self.data)
        argv = ['bash', '-c', '. "$1/bin/fm-afk-start.sh"; fm_afk_clear_stale_artifacts "$2"', '_', str(root), str(self.state)]
        subprocess.run(argv, check=True)
        self.assertFalse((self.state / '.codex-queue-pending.json').exists())
        for name, value in artifacts.items():
            self.assertEqual((self.state / name).read_text(), value)
        with self.accepted():
            self.assertFalse(helper.flush(self.state, self.data))
        target.unlink()
        subprocess.run(argv, check=True)
        for name, value in artifacts.items():
            self.assertEqual((self.state / name).read_text(), value)
        (self.state / '.codex-queue-pending.json').unlink()
        subprocess.run(argv, check=True)
        self.assertTrue(all(not (self.state / name).exists() for name in artifacts))

    def test_buffer_replacement_failure_preserves_later_events(self):
        with self.accepted():
            helper.flush(self.state, self.data)
        pending = json.loads((self.state / '.codex-queue-pending.json').read_text())
        buf = self.state / '.subsuper-escalations'
        buf.write_text('decision event\nnew event\n')
        self.handle(pending['message'])
        replace = os.replace
        def interrupted(source, destination):
            if destination == buf:
                raise OSError('interrupted before buffer replacement')
            return replace(source, destination)
        with patch.object(helper.os, 'replace', side_effect=interrupted):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                helper.flush(self.state, self.data)
        self.assertEqual(buf.read_text(), 'decision event\nnew event\n')
        self.assertTrue((self.state / '.codex-queue-pending.json').exists())
        self.assertTrue(helper.flush(self.state, self.data))
        self.assertEqual(buf.read_text(), 'new event\n')

    def retirement_crash(self, phase):
        with self.accepted():
            helper.flush(self.state, self.data)
        path = self.state / '.codex-queue-pending.json'
        pending = json.loads(path.read_text())
        buf = self.state / '.subsuper-escalations'
        with buf.open('a') as stream:
            stream.write('decision event\n')
        self.handle(pending['message'])
        save, unlink = helper.save, Path.unlink
        receipts = self.state / '.codex-queue-receipts'
        def interrupted_save(destination, value):
            if phase == 'receipt' and destination.parent == receipts:
                raise OSError('crashed before receipt')
            return save(destination, value)
        def interrupted_unlink(destination, *args, **kwargs):
            if phase == 'pending' and destination == path:
                raise OSError('crashed before pending retirement')
            return unlink(destination, *args, **kwargs)
        with patch.object(helper, 'save', side_effect=interrupted_save), patch.object(Path, 'unlink', autospec=True, side_effect=interrupted_unlink):
            with self.assertRaisesRegex(OSError, 'crashed'):
                helper.flush(self.state, self.data)
        self.assertTrue(path.exists())
        self.assertEqual(buf.read_text(), 'decision event\n')
        with buf.open('a') as stream:
            stream.write('decision event\nnew event\n')
        with self.accepted() as command:
            self.assertTrue(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 0)
        self.assertEqual(buf.read_text(), 'decision event\ndecision event\nnew event\n')
        self.assertFalse(path.exists())
        self.assertEqual(len(list(receipts.glob('*.json'))), 1)
        self.assertEqual(json.loads((receipts / (pending['id'] + '.json')).read_text())['handled']['turn'], 'next')
        with self.accepted() as command:
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 1)
        next_pending = json.loads(path.read_text())
        self.assertNotEqual(next_pending['id'], pending['id'])
        self.assertEqual(next_pending['buffer'], 'decision event\ndecision event\nnew event\n')

    def test_repeated_events_survive_crash_before_receipt(self):
        self.retirement_crash('receipt')

    def test_repeated_events_survive_crash_before_pending_retirement(self):
        self.retirement_crash('pending')

    def test_legacy_pending_without_retirement_identity_preserves_evidence(self):
        with self.accepted():
            helper.flush(self.state, self.data)
        path = self.state / '.codex-queue-pending.json'
        pending = json.loads(path.read_text())
        (self.state / '.codex-queue-receipts' / (pending['id'] + '.buffer')).unlink()
        self.handle(pending['message'])
        with self.accepted() as command:
            with self.assertRaisesRegex(ValueError, 'manual reconciliation required'):
                helper.flush(self.state, self.data)
            self.assertEqual(command.call_count, 0)
        self.assertEqual(json.loads(path.read_text()), pending)
        self.assertEqual((self.state / '.subsuper-escalations').read_text(), pending['buffer'])

    def test_unexplained_buffer_identity_change_preserves_pending(self):
        with self.accepted():
            helper.flush(self.state, self.data)
        path = self.state / '.codex-queue-pending.json'
        pending = json.loads(path.read_text())
        self.handle(pending['message'])
        buf = self.state / '.subsuper-escalations'
        helper.replace_text(buf, pending['buffer'])
        with self.accepted() as command:
            with self.assertRaisesRegex(ValueError, 'buffer identity changed'):
                helper.flush(self.state, self.data)
            self.assertEqual(command.call_count, 0)
        self.assertEqual(json.loads(path.read_text()), pending)
        self.assertEqual(buf.read_text(), pending['buffer'])
        buf.unlink()
        with self.assertRaisesRegex(ValueError, 'buffer identity changed'):
            helper.flush(self.state, self.data)
        self.assertEqual(json.loads(path.read_text()), pending)

    def failed_launch_preserves_identity(self, mode):
        with self.accepted():
            helper.flush(self.state, self.data)
        path = self.state / '.codex-queue-pending.json'
        pending = json.loads(path.read_text())
        helper.save(self.state / '.codex-queue-target.json', self.data)
        buf = self.state / '.subsuper-escalations'
        (self.state / '.subsuper-escalations.since').write_text('123')
        (self.state / '.subsuper-inject-wedged').write_text('wedge')
        before = {name: (self.state / name).stat().st_ino for name in ['.subsuper-escalations', '.subsuper-escalations.since', '.subsuper-inject-wedged']}
        script = '''
. "$1/bin/fm-afk-launch.sh"
. "$1/bin/fm-supervise-daemon.sh"
discover_supervisor_target() { printf '%s' exact-test-target; }
discover_supervisor_backend() { printf '%s' codex-queue; }
python3() { return 0; }
daemon_lock_held_by_live_daemon() { return 1; }
fm_afk_launch_reconcile() { return 0; }
fail_launch() { escalate_add "$FM_AFK_LAUNCH_STATE" 'new event'; return 1; }
fm_afk_launch_create_tmux() { fail_launch; }
fm_afk_launch_record_write() { fail_launch; }
FM_SUPERVISOR_BACKEND=codex-queue
if "$2"; then exit 1; fi
'''
        subprocess.run(['bash', '-c', script, '_', str(root), mode], check=True)
        self.assertEqual({name: (self.state / name).stat().st_ino for name in before}, before)
        self.assertEqual(buf.read_text(), 'decision event\nnew event\n')
        self.assertEqual((self.state / '.subsuper-escalations.since').read_text(), '123')
        self.assertEqual((self.state / '.subsuper-inject-wedged').read_text(), 'wedge')
        self.assertEqual(json.loads(path.read_text()), pending)
        self.handle(pending['message'])
        with self.accepted() as command:
            self.assertTrue(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 0)
        self.assertEqual(buf.read_text(), 'new event\n')

    def test_failed_native_queue_launch_preserves_delivery_identity(self):
        self.failed_launch_preserves_identity('fm_afk_launch_start')

    def test_failed_tracked_native_launch_preserves_delivery_identity(self):
        self.failed_launch_preserves_identity('fm_afk_launch_start_native')

    def test_supervisor_append_waits_for_coordinator_retirement(self):
        with self.accepted():
            helper.flush(self.state, self.data)
        pending = json.loads((self.state / '.codex-queue-pending.json').read_text())
        self.handle(pending['message'])
        buf = self.state / '.subsuper-escalations'
        replace = helper.replace_text
        appenders = []
        def concurrent_append(destination, text, retirement=None):
            if destination == buf:
                script = '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervise-daemon.sh"; printf "ready\\n"; escalate_add "$2" "new event"'
                appender = subprocess.Popen(['bash', '-c', script, '_', str(root), str(self.state)], env=dict(os.environ, FM_SUPERVISOR_BACKEND='codex-queue'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                appenders.append(appender)
                self.assertEqual(appender.stdout.readline(), 'ready\n')
                with self.assertRaises(subprocess.TimeoutExpired):
                    appender.wait(timeout=0.3)
            return replace(destination, text, retirement)
        try:
            with patch.object(helper, 'replace_text', side_effect=concurrent_append):
                self.assertTrue(helper.flush(self.state, self.data))
            self.assertEqual(len(appenders), 1)
            out, err = appenders[0].communicate(timeout=5)
            self.assertEqual(appenders[0].returncode, 0, err)
            self.assertEqual(buf.read_text(), 'new event\n')
            self.assertTrue((self.state / '.subsuper-escalations.since').exists())
        finally:
            for appender in appenders:
                if appender.poll() is None:
                    appender.terminate()
                appender.communicate(timeout=5)

    def test_return_cannot_begin_between_journal_and_submission(self):
        real_run = subprocess.run
        gate = self.state / '.afk-return-catchup'
        def begin_return():
            script = '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 3; trap \'fm_lock_release "$2"\' EXIT; touch "$3"'
            return real_run(['bash', '-c', script, '_', str(root), str(self.state / '.afk-return-catchup.lock'), str(gate)]).returncode
        save = helper.save
        def journal(path, value):
            save(path, value)
            self.assertEqual(begin_return(), 3)
            self.assertFalse(gate.exists())
        def queue(*args, **kwargs):
            self.assertEqual(begin_return(), 3)
            return subprocess.CompletedProcess(args[0], 0, '', '')
        with patch.object(helper, 'save', side_effect=journal), patch.object(helper.subprocess, 'run', side_effect=queue):
            self.assertFalse(helper.flush(self.state, self.data))
        self.assertEqual(begin_return(), 0)
        pending = json.loads((self.state / '.codex-queue-pending.json').read_text())
        self.handle(pending['message'])
        with self.accepted() as command:
            self.assertTrue(helper.flush(self.state, self.data))
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 0)

    def test_return_lock_prevents_submission_before_gate_publication(self):
        script = '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; printf "locked\\n"; read -r release'
        with subprocess.Popen(['bash', '-c', script, '_', str(root), str(self.state / '.afk-return-catchup.lock')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as returning:
            try:
                self.assertEqual(returning.stdout.readline(), 'locked\n')
                with self.accepted() as command:
                    self.assertFalse(helper.flush(self.state, self.data))
                    self.assertEqual(command.call_count, 0)
                self.assertFalse((self.state / '.codex-queue-pending.json').exists())
            finally:
                returning.stdin.close()
                returning.wait(timeout=5)

    def test_live_fixture_emits_canonical_skip_without_opt_in(self):
        with patch.dict(os.environ, FM_CODEX_QUEUE_LIVE_E2E='0'):
            result = subprocess.run(['bash', str(root / 'tests/fm-codex-queue-live-e2e.test.sh')], text=True, capture_output=True, check=True)
        self.assertTrue(result.stdout.startswith('skip:'))

    def test_return_reconciles_but_cannot_submit(self):
        with self.accepted():
            helper.flush(self.state, self.data)
        pending = json.loads((self.state / '.codex-queue-pending.json').read_text())
        (self.state / '.afk').unlink()
        self.assertFalse(helper.flush(self.state, self.data))
        self.handle(pending['message'])
        self.assertTrue(helper.flush(self.state, self.data))
        with self.accepted() as command:
            self.assertFalse(helper.flush(self.state, self.data))
            self.assertEqual(command.call_count, 0)

    def test_pending_owner_change_refuses_without_clearing(self):
        with self.accepted():
            helper.flush(self.state, self.data)
        changed = dict(self.data, thread='replacement')
        with self.assertRaisesRegex(ValueError, 'earlier owner'):
            helper.flush(self.state, changed)
        self.assertTrue((self.state / '.codex-queue-pending.json').exists())

    def test_stale_lock_and_cross_home_refuse(self):
        (self.state / '.lock').write_text('42\nidentity=other\n')
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            helper.lock_owner(self.state)
        helper.save(self.state / '.codex-queue-target.json', {'home': '/different', 'thread': 'thread'})
        with self.assertRaisesRegex(ValueError, 'different home'):
            helper.check(self.state, self.state, 'thread')

    def test_socket_replacement_and_permissions_refuse(self):
        import socket
        endpoint = self.state / 'control.sock'
        with socket.socket(socket.AF_UNIX) as sock:
            sock.bind(str(endpoint))
            endpoint.chmod(0o600)
            original = helper.socket_identity(endpoint)
            endpoint.chmod(0o666)
            with self.assertRaisesRegex(ValueError, 'private'):
                helper.socket_identity(endpoint)
        endpoint.unlink()
        with socket.socket(socket.AF_UNIX) as sock:
            sock.bind(str(endpoint))
            endpoint.chmod(0o600)
            self.assertNotEqual(original, helper.socket_identity(endpoint))

class RemoteBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.account = self.home / 'account'
        self.state = self.home / 'state'
        self.state.mkdir()
        (self.account / 'sessions').mkdir(parents=True)
        self.thread = '12345678-1234-1234-1234-123456789abc'
        records = [
            {'type': 'session_meta', 'payload': {'id': self.thread, 'cwd': str(self.home)}},
            {'type': 'turn_context', 'payload': {'approval_policy': 'never', 'sandbox_policy': {'type': 'danger-full-access'}}},
        ]
        (self.account / 'sessions' / (self.thread + '.jsonl')).write_text(''.join(json.dumps(item) + '\n' for item in records))
        self.cli = self.home / 'cli'
        self.daemon = self.home / 'daemon'
        self.cli.write_text('cli')
        self.daemon.write_text('daemon')
        self.endpoint = self.home / 's'
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(self.endpoint))
        self.endpoint.chmod(0o600)
        (self.state / '.lock').write_text('11\nidentity=identity\n')
        env = patch.dict(os.environ, CODEX_THREAD_ID=self.thread, FM_CODEX_QUEUE_CLI_PID='22')
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop('FM_CODEX_QUEUE_SOCKET', None)
        for name, value in [('identity', 'identity'), ('ancestor', True), ('parent', 33), ('sockets', [str(self.endpoint)])]:
            mock = patch.object(helper, name, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)

    def bind(self, arguments):
        argv = [sys.executable, '-c', 'import sys; print("ready", flush=True); sys.stdin.read()'] + arguments
        with subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process:
            try:
                self.assertEqual(process.stdout.readline(), 'ready\n')
                self.assertEqual(helper.process_args(process.pid)[-len(arguments):], arguments)
                cli_pid = str(process.pid)
                responses = {
                    ('ps', '-p', '11', '-o', 'comm='): str(self.daemon),
                    ('ps', '-p', '11', '-o', 'command='): str(self.daemon) + ' app-server --managed-daemon',
                    ('ps', '-p', cli_pid, '-o', 'comm='): str(self.cli),
                    ('ps', '-p', cli_pid, '-o', 'command='): subprocess.check_output(['ps', '-p', cli_pid, '-o', 'command='], text=True),
                    (str(self.cli), '--no-daemon', '--version'): 'codex-cli 0.160.1',
                    (str(self.daemon), '--no-daemon', '--version'): 'codex-cli 0.161.0',
                }
                with patch.dict(os.environ, FM_CODEX_QUEUE_CLI_PID=cli_pid), patch.object(helper, 'run', side_effect=lambda argv: responses[tuple(argv)]):
                    return helper.bind(self.home, self.account, self.state, self.thread)
            finally:
                process.stdin.close()
                process.wait(timeout=5)

    def test_wrong_complete_remote_refuses_with_or_without_socket_selection(self):
        for selected in ['', str(self.endpoint)]:
            for remote in ['unix://', 'unix://' + str(self.endpoint) + '.other', 'unix://' + str(self.home / 'other')]:
                with self.subTest(selected=selected, remote=remote), patch.dict(os.environ, FM_CODEX_QUEUE_SOCKET=selected):
                    with self.assertRaisesRegex(ValueError, 'exact daemon socket'):
                        self.bind(['--remote', remote])
                    self.assertFalse((self.state / '.codex-queue-target.json').exists())

    def test_exact_remote_binds_discovered_socket_and_canonical_alias(self):
        alias = self.home / 'alias'
        alias.symlink_to(self.endpoint)
        for remote in [self.endpoint, alias]:
            with self.subTest(remote=remote):
                data = self.bind(['--remote', 'unix://' + str(remote), "Bind this home's native queue", '', '--remote unix://prompt-only'])
                self.assertEqual(data['socket'], str(self.endpoint))
                self.assertGreater(data['cli_pid'], 0)
                self.assertEqual(json.loads((self.state / '.codex-queue-target.json').read_text()), data)
                (self.state / '.codex-queue-target.json').unlink()

    def test_remote_text_inside_prompt_cannot_bind_wrong_cli(self):
        arguments = ['--remote', 'unix://' + str(self.home / 'other'), '--', '--remote unix://' + str(self.endpoint)]
        with self.assertRaisesRegex(ValueError, 'exact daemon socket'):
            self.bind(arguments)
        self.assertFalse((self.state / '.codex-queue-target.json').exists())

class LiveDeadlineTests(unittest.TestCase):
    def test_expired_outer_deadline_refuses_before_credentials_or_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            account = scratch / 'account'
            account.mkdir()
            auth = account / 'auth.json'
            auth.write_text('credential must remain here')
            evidence = scratch / 'evidence'
            env = dict(os.environ, FM_CODEX_QUEUE_LIVE_E2E='1', FM_CODEX_QUEUE_LIVE_CLI='/missing-cli', FM_CODEX_QUEUE_LIVE_DAEMON='/missing-daemon', CODEX_HOME=str(account), FM_CODEX_QUEUE_LIVE_EVIDENCE=str(evidence), FM_CODEX_LIVE_DEADLINE='0')
            for diagnostic in ['0', '1']:
                with self.subTest(diagnostic=diagnostic):
                    evidence = scratch / ('evidence-' + diagnostic)
                    env.update(FM_CODEX_QUEUE_STARTUP_DIAGNOSTIC=diagnostic, FM_CODEX_QUEUE_LIVE_EVIDENCE=str(evidence))
                    result = subprocess.run(['bash', str(root / 'tests/fm-codex-queue-live-e2e.test.sh')], env=env, text=True, capture_output=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('outer deadline leaves no execution time', result.stderr)
                    self.assertEqual(auth.read_text(), 'credential must remain here')
                    self.assertEqual(list(evidence.iterdir()), [])

class RestartRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.pending = {'id': 'original', 'message': 'exact original input', 'buffer': 'original event\n', 'acceptance': 'accepted'}
        self.original = dict(self.pending, handled={'turn': 'original-turn'})
        self.later = {'id': 'later', 'message': 'exact later input', 'buffer': 'later event\n', 'handled': {'turn': 'later-turn'}}
        self.items = []
        for receipt in [self.original, self.later]:
            turn = receipt['handled']['turn']
            self.items.extend([
                {'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': turn}},
                {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'text': receipt['message']}], 'internal_chat_message_metadata_passthrough': {'turn_id': turn}}},
                {'type': 'event_msg', 'payload': {'type': 'task_complete', 'turn_id': turn}},
            ])

    def assert_recovery(self, receipts=None, items=None):
        return assert_restart_recovery(self.items if items is None else items, self.pending, 'later event', [self.original, self.later] if receipts is None else receipts)

    def test_original_acknowledgement_and_later_event_survive_restart(self):
        proof = self.assert_recovery()
        self.assertEqual(proof, {'pending_id': 'original', 'original_turn': 'original-turn', 'later_id': 'later', 'later_turn': 'later-turn'})

    def test_blind_resubmission_or_replaced_original_receipt_refuses(self):
        retry = dict(self.original, id='retry', message='retried original input')
        for receipts in [[self.original, retry, self.later], [retry, self.later]]:
            with self.subTest(receipts=receipts), self.assertRaisesRegex(ValueError, 'one exact acknowledgement'):
                self.assert_recovery(receipts=receipts)

    def test_duplicate_native_input_refuses(self):
        with self.assertRaisesRegex(ValueError, 'one exact native input'):
            self.assert_recovery(items=self.items + [self.items[1]])

    def test_missing_later_event_or_original_completion_refuses(self):
        with self.assertRaisesRegex(ValueError, 'later buffered event'):
            self.assert_recovery(receipts=[self.original])
        with self.assertRaisesRegex(ValueError, 'started and completed'):
            self.assert_recovery(items=[item for index, item in enumerate(self.items) if index != 2])

class TurnOrderTests(unittest.TestCase):
    def setUp(self):
        self.busy_input = 'busy foreground work'
        self.receipt = {'message': 'exact queued message', 'handled': {'turn': 'queued-turn'}}
        self.busy_user = {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'text': self.busy_input}], 'internal_chat_message_metadata_passthrough': {'turn_id': 'busy-turn'}}}
        self.queued_user = {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'text': self.receipt['message']}], 'internal_chat_message_metadata_passthrough': {'turn_id': 'queued-turn'}}}
        self.busy_start = {'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': 'busy-turn'}}
        self.busy_complete = {'type': 'event_msg', 'payload': {'type': 'task_complete', 'turn_id': 'busy-turn', 'last_agent_message': 'BUSY_FINAL'}}
        self.queued_start = {'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': 'queued-turn'}}
        self.queued_complete = {'type': 'event_msg', 'payload': {'type': 'task_complete', 'turn_id': 'queued-turn', 'last_agent_message': 'FINAL_busy'}}

    def test_native_turn_order_accepts_serial_handling(self):
        items = [self.busy_start, self.busy_user, self.busy_complete, self.queued_start, self.queued_user, self.queued_complete]
        proof = assert_busy_order(items, self.busy_input, self.receipt)
        self.assertEqual(proof['busy_turn'], 'busy-turn')
        self.assertEqual(proof['queued_turn'], 'queued-turn')
        self.assertLess(proof['busy_complete'], proof['queued_start'])

    def test_late_final_cannot_mask_overlapping_turns(self):
        items = [self.busy_start, self.busy_user, self.queued_start, self.queued_user, self.busy_complete, self.queued_complete]
        with self.assertRaisesRegex(ValueError, 'before the busy turn completed'):
            assert_busy_order(items, self.busy_input, self.receipt)

    def test_missing_or_wrong_turn_evidence_refuses(self):
        items = [self.busy_start, self.busy_user, self.busy_complete, self.queued_start, self.queued_user, self.queued_complete]
        for removed in [self.busy_user, self.busy_start, self.busy_complete, self.queued_start, self.queued_user]:
            with self.subTest(removed=removed):
                with self.assertRaises(ValueError):
                    assert_busy_order([item for item in items if item != removed], self.busy_input, self.receipt)
        with self.assertRaisesRegex(ValueError, 'exact native input'):
            assert_busy_order(items, self.busy_input, dict(self.receipt, message='unrelated input'))

unittest.main()
PY
