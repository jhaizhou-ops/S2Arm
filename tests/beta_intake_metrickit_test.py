import csv
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MetricKitIntakeTests(unittest.TestCase):
    def intake(self, payload, log='running\n', extra_logs=None, existing=False, manifest=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        inbox = Path(temporary.name)
        if existing:
            header = ['入库时刻', '测试者', '组', '款', '机型', 'iOS', '包提交', '会话', '结局', 'MARK', '帧数', '热状态最高', '实占峰值MB', '崩溃签名', '红行', '首遇现编', '玩家备注', '诊断包']
            (inbox / 'summary.tsv').write_text('\t'.join(header) + '\n')
        with zipfile.ZipFile(inbox / 'synthetic.zip', 'w') as archive:
            archive.writestr('manifest.json', json.dumps(manifest or {}))
            archive.writestr('logs/host.log', log)
            for name, content in (extra_logs or {}).items(): archive.writestr('logs/' + name, content)
            archive.writestr('metrickit/20261028-093000-0-hang.json', payload if isinstance(payload, str) else json.dumps(payload))
        subprocess.run([sys.executable, str(ROOT / 'tools/beta_intake.py'), '--inbox', str(inbox)], check=True, capture_output=True)
        with (inbox / 'summary.tsv').open() as stream: rows = list(csv.DictReader(stream, delimiter='\t'))
        return rows, (inbox / 'summary.tsv').read_text()

    def test_categories_and_privacy(self):
        cases = [
            ({'crashDiagnostics': [{'terminationReason': 'Namespace SPRINGBOARD, watchdog'}]}, '被看门狗杀'),
            ({'crashDiagnostics': [{'signal': 6}]}, '崩溃:6'),
            ({'crashDiagnostics': [{'diagnosticMetaData': {'signal': 11}}]}, '崩溃:11'),
            ({'crashDiagnostics': [{'diagnosticMetaData': {'terminationReason': '0x8badf00d'}}]}, '被看门狗杀'),
            ({'hangDiagnostics': [{'hangDuration': {'value': 2500, 'unit': 'ms'}}]}, '挂起 2.5 秒'),
            ({'cpuExceptionDiagnostics': [{}]}, '资源超限:CPU'),
            ({'diskWriteExceptionDiagnostics': [{}]}, '资源超限:磁盘写入'),
            ({}, 'unknown'),
        ]
        for payload, expected in cases:
            with self.subTest(expected=expected):
                payload['deviceIdentifier'] = 'PRIVATE_SENTINEL'
                rows, text = self.intake(payload)
                self.assertEqual(rows[0]['结局'], 'unknown')
                if expected != 'unknown': self.assertIn(expected, rows[0]['诊断备注'])
                self.assertNotIn('PRIVATE_SENTINEL', text)

    def test_malformed_and_conflict(self):
        rows, _ = self.intake('{bad json')
        self.assertEqual(rows[0]['结局'], 'unknown')
        self.assertIn('MetricKit 读不了', rows[0]['诊断备注'])
        rows, _ = self.intake({'crashDiagnostics': [{'signal': 6}]}, '[s2a] 优雅退出完成\n')
        self.assertEqual(rows[0]['结局'], 'exit')
        self.assertIn('崩溃:6', rows[0]['诊断备注'])

    def test_multiple_sessions_are_not_attributed(self):
        rows, _ = self.intake({'crashDiagnostics': [{'signal': 6}]}, extra_logs={'host.prev.log': 'unknown\n'})
        self.assertEqual([row['结局'] for row in rows], ['unknown', 'unknown'])
        self.assertTrue(all('未确认对应本会话' in row['诊断备注'] for row in rows))

    def test_existing_summary_header(self):
        rows, _ = self.intake({'crashDiagnostics': [{'signal': 6}]}, existing=True)
        self.assertEqual(rows[0]['结局'], 'unknown')
        self.assertIn('未确认对应本会话', rows[0]['玩家备注'])
        self.assertEqual(rows[0]['诊断包'], 'synthetic.zip')

    def test_time_attribution_and_nested_hang(self):
        manifest = {'sessions': [
            {'log': 'logs/host.prev.log', 'started': '2026-10-28T09:00:00+08:00', 'end': 'unknown'},
            {'log': 'logs/host.log', 'started': '2026-10-28T10:00:00+08:00', 'end': 'running'},
        ]}
        payload = {'timeStampBegin': '2026-10-28T01:10:00Z', 'timeStampEnd': '2026-10-28T01:20:00Z',
                   'hangDiagnostics': [{'diagnosticMetaData': {'hangDuration': '20 sec'}}]}
        rows, _ = self.intake(payload, extra_logs={'host.prev.log': 'unknown\n'}, manifest=manifest)
        by_name = {row['会话']: row for row in rows}
        self.assertEqual(by_name['host.prev.log']['结局'], '挂起 20 秒')
        self.assertEqual(by_name['host.log']['结局'], 'unknown')
        rows, _ = self.intake(payload, extra_logs={'host.prev.log': '优雅退出完成\n'}, manifest=manifest)
        previous = next(row for row in rows if row['会话'] == 'host.prev.log')
        self.assertEqual(previous['结局'], 'exit')
        self.assertIn('需核对', previous['诊断备注'])
        payload['timeStampEnd'] = '2026-10-28T03:00:00Z'
        rows, _ = self.intake(payload, extra_logs={'host.prev.log': 'unknown\n'}, manifest=manifest)
        self.assertTrue(all(row['结局'] == 'unknown' and '未确认' in row['诊断备注'] for row in rows))
        payload['timeStampBegin'] = '2026-10-28T02:10:00Z'
        rows, _ = self.intake(payload, extra_logs={'host.prev.log': 'unknown\n'}, manifest=manifest)
        self.assertTrue(all(row['结局'] == 'unknown' for row in rows))

    def test_invalid_payload_does_not_keep_partial_evidence(self):
        rows, _ = self.intake({'crashDiagnostics': [{'signal': 6}, 'invalid']})
        self.assertEqual(rows[0]['结局'], 'unknown')
        self.assertIn('MetricKit 读不了', rows[0]['诊断备注'])
        self.assertNotIn('崩溃:6', rows[0]['诊断备注'])

    def test_device_local_timestamps_and_point_boundaries(self):
        sessions = [
            {'log': 'logs/host.prev.log', 'started': '2026-10-28T09:00:00+08:00'},
            {'log': 'logs/host.log', 'started': '2026-10-28T10:00:00+08:00'},
        ]
        manifest = {'exported_at': '2026-10-28T11:00:00+08:00', 'sessions': sessions}
        payload = {'timeStampBegin': '2026-10-28 09:30:00', 'timeStampEnd': '2026-10-28 09:30:00',
                   'hangDiagnostics': [{'diagnosticMetaData': {'hangDuration': '20 sec'}}]}
        def check(expected, note=False):
            rows, _ = self.intake(payload, extra_logs={'host.prev.log': 'unknown\n'}, manifest=manifest)
            previous = next(row for row in rows if row['会话'] == 'host.prev.log')
            self.assertEqual(previous['结局'], expected)
            if note: self.assertIn('未确认', previous['诊断备注'])
        check('挂起 20 秒')
        del manifest['exported_at']
        check('挂起 20 秒')
        payload['timeStampEnd'] = '2026-10-28 09:45:00'
        check('挂起 20 秒')
        payload['timeStampBegin'] = payload['timeStampEnd'] = '2026-10-28T01:30:00Z'
        check('挂起 20 秒')
        payload['timeStampBegin'] = payload['timeStampEnd'] = '2026-10-28 10:00:00'
        check('unknown', note=True)
        payload['timeStampBegin'] = '2026-10-28 09:30:00'
        payload['timeStampEnd'] = '2026-10-28 09:20:00'
        check('unknown', note=True)
        for session in sessions: session['started'] = session['started'].replace('+08:00', '')
        payload['timeStampEnd'] = payload['timeStampBegin']
        check('unknown', note=True)


if __name__ == '__main__':
    unittest.main()
