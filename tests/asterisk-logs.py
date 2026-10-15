#!/usr/bin/env python3
"""Asterisk translation of the PABX server Logs tab, with a fake asterisk -rx."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('astlogs', ROOT / 'scripts/asterisk-logs.py')
ast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ast)
BASE = {'managed': True, 'logEnabled': True, 'logLevel': 'notice', 'logRetentionDays': 7,
        'logDebugUntil': None}


class AsteriskLogs(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.calls = []
        self.pid = '10'
        for patch in [
            mock.patch.object(ast, 'CONFIG', self.dir / 'logger.conf'),
            mock.patch.object(ast, 'LOG_DIR', self.dir),
            mock.patch.object(ast, 'ast', side_effect=lambda command: self.calls.append(command) or ''),
            mock.patch.object(ast, 'main_pid', side_effect=lambda: self.pid),
            mock.patch.object(ast, 'owner', return_value=None),
        ]:
            patch.start()
            self.addCleanup(patch.stop)

    def test_rendered_logger_keeps_security_and_disables_native_rotation(self):
        for level in ('error', 'warning', 'notice', 'info', 'debug'):
            text = ast.render(level)
            self.assertTrue(text.startswith(ast.MANAGED_MARKER))
            self.assertIn('security => security', text)
            self.assertIn('rotatestrategy=none', text)
        self.assertIn('full => error\n', ast.render('error'))
        self.assertIn('debug', ast.render('debug'))
        self.assertNotIn('debug', ast.render('info').split('[logfiles]')[1])

    def test_debug_enables_pjsip_logger_and_off_disables_it(self):
        marker = ast.apply(dict(BASE, logLevel='debug'), None)
        self.assertEqual(self.calls, ['logger reload', 'core set verbose 5', 'core set debug 5',
                                      'pjsip set logger on'])
        self.calls.clear()
        ast.apply(dict(BASE, logLevel='notice'), marker)
        self.assertEqual(self.calls, ['logger reload', 'core set verbose 1', 'core set debug off',
                                      'pjsip set logger off'])

    def test_unchanged_settings_are_not_reapplied_until_restart(self):
        marker = ast.apply(BASE, None)
        self.calls.clear()
        ast.apply(BASE, marker)
        self.assertEqual(self.calls, [])
        self.pid = '11'
        ast.apply(BASE, marker)
        self.assertIn('logger reload', self.calls)

    def test_installer_default_matches_the_managed_notice_file(self):
        installer = (ROOT / 'scripts/install-asterisk.sh').read_text()
        default = ast.render('notice')
        for line in default.splitlines()[1:]:
            self.assertIn(line, installer, line)


if __name__ == '__main__':
    unittest.main()
