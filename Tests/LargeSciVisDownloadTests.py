import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServerDownloadTests(unittest.TestCase):
    def test_manifest_matches_catalog(self):
        catalog = json.loads((ROOT / 'Scripts/scivis-raw-datasets.json').read_text())
        text = (ROOT / 'Scripts/download-large-scivis-datasets.sh').read_text()
        rows = text.split("done <<'DATASETS'\n")[1].split('\nDATASETS')[0].splitlines()
        self.assertEqual(len(rows), 3)
        for line in rows:
            name, size, checksum, kind, dimensions, url = line.split('\t')
            row = catalog[name]
            expected = (4 if kind == 'float32' else 8)
            for n in row['size']:
                expected *= n
            self.assertEqual(int(size), expected)
            self.assertEqual(checksum, row['sha512sum'])
            self.assertEqual(url, row['url'])

    def test_download_verify_resume_and_sidecars(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'bin'
            binary.mkdir()
            curl = binary / 'curl'
            curl.write_text('#!/bin/bash\nwhile [[ $# -gt 0 ]]; do\n if [[ "$1" == --output ]]; then printf 12345678 > "$2"; exit 0; fi\n shift\ndone\nexit 1\n')
            curl.chmod(0o755)
            text = (ROOT / 'Scripts/download-large-scivis-datasets.sh').read_text()
            before, rows = text.split("done <<'DATASETS'\n")
            rows, after = rows.split('\nDATASETS')
            fixtures = []
            for line in rows.splitlines():
                fields = line.split('\t')
                fields[1] = '8'
                fields[2] = hashlib.sha512(b'12345678').hexdigest()
                fixtures.append('\t'.join(fields))
            script = root / 'download.sh'
            script.write_text(before + "done <<'DATASETS'\n" + '\n'.join(fixtures) + '\nDATASETS' + after)
            output = root / 'data with spaces'
            env = {**os.environ, 'PATH': str(binary) + os.pathsep + os.environ['PATH']}
            command = ['bash', str(script), '--output', str(output)]
            subprocess.run(command, env=env, check=True, capture_output=True)
            self.assertEqual(len(list(output.glob('*.raw'))), 3)
            self.assertEqual(len(list(output.glob('*.nhdr'))), 3)
            self.assertEqual(len(list(output.glob('*.sources.tsv'))), 3)
            curl.write_text('#!/bin/bash\nexit 99\n')
            subprocess.run(command, env=env, check=True, capture_output=True)
            raw = next(output.glob('*.raw'))
            partial = Path(str(raw) + '.part')
            raw.rename(partial)
            subprocess.run(command, env=env, check=True, capture_output=True)
            self.assertTrue(raw.is_file())
            raw.write_bytes(b'bad data')
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Checksum mismatch', result.stderr)
            self.assertEqual(raw.read_bytes(), b'bad data')


if __name__ == '__main__':
    unittest.main()
