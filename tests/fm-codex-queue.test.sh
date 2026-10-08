#!/usr/bin/env bash
# Native queue acceptance, exact-turn receipts, type-once recovery and refusal.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('queue_helper', Path(sys.argv[1]) / 'bin/fm-codex-queue.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
root = Path(sys.argv.pop())

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

unittest.main()
PY
