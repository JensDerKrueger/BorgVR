import array
import contextlib
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('raw_import', ROOT / 'Scripts/download-scivis-raw.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
TOOLS = Path(os.environ.get('SCIVIS_RAW_TEST_TOOLS', '/private/tmp/borgvr-scivis-raw-tools'))
QUANTIZER = TOOLS / 'scivis-raw-quantizer'


class RawImportTests(unittest.TestCase):
    def test_catalog_and_deduplication(self):
        catalog = json.loads((ROOT / 'Scripts/scivis-raw-datasets.json').read_text())
        module.validate_catalog(catalog)
        self.assertEqual(len(catalog), 55)
        known = {line.split('\t')[0] for line in (ROOT / 'Scripts/scivis-datasets.tsv').read_text().splitlines() if line and not line.startswith('#')}
        self.assertEqual(set(catalog) - known, module.NEW)
        self.assertEqual(module.source_bytes(catalog['dns']), 900 * 1024**3)

    def test_complete_partial_is_verified_without_redownload(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'input.raw'
            partial = Path(str(target) + '.part')
            payload = struct.pack('<3H', 0, 1, 2)
            partial.write_bytes(payload)
            row = {'size': [3, 1, 1], 'type': 'uint16', 'sha512sum': hashlib.sha512(payload).hexdigest(), 'url': 'http://example.invalid/input.raw'}
            with mock.patch.object(module.subprocess, 'run') as curl:
                module.checked_download(row, target)
                curl.assert_not_called()
            self.assertEqual(target.read_bytes(), payload)
            self.assertFalse(partial.exists())

    def quantize(self, kind, values):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / 'input.raw', Path(directory) / 'output.raw'
            code = 'f' if kind == 'float32' else 'd'
            source.write_bytes(b''.join(struct.pack('<' + code, v) for v in values))
            result = subprocess.run([str(QUANTIZER), kind, str(source), str(target)], check=True, capture_output=True, text=True)
            output = array.array('H')
            output.frombytes(target.read_bytes())
            if sys.byteorder != 'little':
                output.byteswap()
            return list(output), json.loads(result.stdout)

    def test_quantization_and_nonfinite(self):
        for kind in ('float32', 'float64'):
            values, stats = self.quantize(kind, [-1, 0, 1, math.nan, math.inf, -math.inf])
            self.assertEqual(values, [0, 32768, 65535, 0, 0, 0])
            self.assertEqual(stats['nonfiniteCount'], 3)
            self.assertEqual((stats['minimum'], stats['maximum']), (-1, 1))

    def test_constant_and_extreme_ranges(self):
        self.assertEqual(self.quantize('float32', [42, 42])[0], [0, 0])
        self.assertEqual(self.quantize('float64', [-1e308, 0, 1e308])[0], [0, 32768, 65535])
        self.assertEqual(self.quantize('float64', [-1e-310, 0, 1e-310])[0], [0, 32768, 65535])

    def test_actual_converter_and_auditor(self):
        converter = os.environ.get('SCIVIS_RAW_TEST_CONVERTER')
        if not converter:
            self.skipTest('Set SCIVIS_RAW_TEST_CONVERTER for the real converter integration test')
        base = json.loads((ROOT / 'Scripts/scivis-raw-datasets.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            catalog, payloads = {}, {}
            for name in module.NEW:
                row = dict(base[name], size=[2, 3, 4])
                code = {'uint16': 'H', 'float32': 'f', 'float64': 'd'}[row['type']]
                payload = b''.join(struct.pack('<' + code, n) for n in range(24))
                row['url'] = f'http://klacansky.com/open-scivis-datasets/{name}/{name}_2x3x4_{row["type"]}.raw'
                row['sha512sum'] = hashlib.sha512(payload).hexdigest()
                catalog[name] = row
                payloads[row['url']] = payload
            manifest = output / 'manifest.json'
            manifest.write_text(json.dumps(catalog))
            def download(row, target):
                target.write_bytes(payloads[row['url']])
            args = ['import', '--converter', converter, '--quantizer', str(QUANTIZER), '--auditor', str(TOOLS / 'scivis-raw-auditor'), '--output', str(output), '--manifest', str(manifest), '--include-large', '--download-date', '2026-11-01']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(module, 'checked_download', side_effect=download):
                status = module.main()
                if status:
                    for log in (output / '.scivis-raw-logs').glob('run-*/*.log'):
                        print(log.name, log.read_text())
                self.assertEqual(status, 0)
            self.assertEqual(len(list(output.glob('*.data'))), 4)
            previous = {p.name: p.stat().st_ino for p in output.glob('*.data')}
            with mock.patch.object(sys, 'argv', args), mock.patch.object(module, 'checked_download') as download:
                self.assertEqual(module.main(), 0)
                download.assert_not_called()
            self.assertEqual(previous, {p.name: p.stat().st_ino for p in output.glob('*.data')})


if __name__ == '__main__':
    unittest.main()
