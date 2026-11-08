import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tools/shader_batch_sim.py'


class BatchSimulationTest(unittest.TestCase):
    def run_csv(self, data, *args):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'times.csv'
            path.write_text(data, encoding='utf-8')
            return subprocess.run([sys.executable, str(SCRIPT), str(path), *args],
                                  capture_output=True, text=True)

    def test_eight_workers_and_batch_overhead(self):
        data = 'shader,seconds\n' + ''.join(f's{i},1\n' for i in range(16))
        result = self.run_csv(data, '--overhead', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        # Eight batches of two cost 3 seconds; 16 single batches cost 4.
        self.assertEqual(output['best']['batch_count'], 8)
        self.assertEqual(output['best']['makespan_seconds'], 3)
        self.assertEqual(len(output['best']['assignments']), 8)
        groups = output['best']['batch_shaders']
        self.assertEqual(len(groups), 8)
        self.assertEqual(sorted(name for group in groups for name in group),
                         sorted(f's{i}' for i in range(16)))

    def test_balancing_reduces_tail(self):
        data = 'shader,seconds\na,9\nb,8\nc,1\nd,1\n'
        result = self.run_csv(data, '--workers', '2', '--max-batches', '2')
        output = json.loads(result.stdout)
        by_strategy = {c['strategy']: c['makespan_seconds'] for c in output['candidates'] if c['batch_count'] == 2}
        self.assertEqual(by_strategy, {'contiguous': 17, 'balanced': 10})

    def test_invalid_input_rejected(self):
        for data in ('shader,seconds\na,nan\n', 'shader,seconds\na,-1\n',
                     'shader,seconds\na,1\na,2\n', 'shader,seconds\n',
                     'seconds,shader\n1\n'):
            result = self.run_csv(data)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Traceback', result.stderr)

    def test_finite_values_that_overflow_are_rejected(self):
        result = self.run_csv('shader,seconds\na,1e308\nb,1e308\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('超出可表示范围', result.stderr)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
