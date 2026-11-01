import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import subprocess
import sys
import hashlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('library', ROOT / 'Scripts/download-volume-library.py')
library = importlib.util.module_from_spec(spec)
spec.loader.exec_module(library)
verify_download = library.verify_download


class VolumeLibraryTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(library, 'verify_download')
        patch.start()
        self.addCleanup(patch.stop)

    def test_catalog_selection(self):
        catalog = library.load_catalog(ROOT / 'Scripts/volume-library-datasets.json')
        rows = catalog['datasets']
        self.assertEqual(len(rows), 85)
        self.assertEqual(sum(r['action'] == 'variant' for r in rows), 7)
        backpack = next(r for r in rows if r['file'] == 'Backpack.pvm')
        self.assertEqual(backpack['action'], 'keep-existing')
        self.assertIn('16-bit', backpack['decision'])
        bucky = next(r for r in rows if r['file'] == 'Bucky.pvm')
        self.assertEqual(bucky['name'], 'bucky_32')
        bucky_entries = library.source_entries(catalog, bucky, '2026-11-01')
        self.assertTrue(any('AVS International Center' in text and 'calculation method are not specified' in text for _, text in bucky_entries))
        self.assertTrue(any('earlier assignment to his Gaussian model is withdrawn' in text for _, text in bucky_entries))
        self.assertNotIn('Gaussian', bucky['description'])
        self.assertEqual(bucky['size_mode'], 'estimate')
        self.assertEqual(bucky['size_x'], 1e-9)
        self.assertTrue(any('Estimated X extent:' in text and 'not an acquisition measurement' in text for _, text in bucky_entries))
        for row in rows:
            self.assertLessEqual(len(row['description'].split()), 10)
            entries = library.source_entries(catalog, row, '2026-11-01')
            self.assertIn(row['file'], entries[-1][1])
            self.assertIn('Commercial use is prohibited', '\n'.join(text for _, text in entries))
            if row['size_mode'] != 'force':
                self.assertTrue(any('X extent:' in text for _, text in entries))

    def test_converter_arguments_preserve_source_text(self):
        row = {'description': 'A volume', 'size_x': 0.2}
        entries = [('2026-11-01T00:00:00Z', 'Credit: a; $(not-a-command)')]
        command = library.converter_command(Path('/a b/converter'), row, Path('/a b/input.pvm'), Path('/output.data'), entries, 32, 2)
        self.assertEqual(command[0], '/a b/converter')
        self.assertIn(entries[0][1], command)
        self.assertEqual(command[-2:], ['--force-size-x', '0.2'])

    def test_download_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'fixture.pvm'
            source.write_bytes(b'checked download')
            verify_download(source, hashlib.sha256(b'checked download').hexdigest())
            with self.assertRaises(ValueError):
                verify_download(source, '0' * 64)

    def test_failure_does_not_replace_existing_volume(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            old = output / 'foot.data'
            old.write_bytes(b'previous volume')
            cache = output / '.volume-library-downloads'
            cache.mkdir()
            (cache / 'Foot.pvm').write_bytes(b'cached PVM')
            args = ['import', '--only', 'Foot', '--converter', sys.executable, '--output', str(output), '--replace']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(library.subprocess, 'check_output', return_value='--source-info --force-size-x'), mock.patch.object(library.subprocess, 'run', side_effect=subprocess.CalledProcessError(9, 'converter')):
                self.assertEqual(library.main(), 1)
            self.assertEqual(old.read_bytes(), b'previous volume')

    def test_success_backs_up_then_replaces(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            old = output / 'foot.data'
            old.write_bytes(b'previous volume')
            cache = output / '.volume-library-downloads'
            cache.mkdir()
            (cache / 'Foot.pvm').write_bytes(b'cached PVM')
            def convert(command, **kwargs):
                Path(command[3]).write_bytes(b'new volume')
            args = ['import', '--only', 'Foot', '--converter', sys.executable, '--output', str(output), '--replace']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(library.subprocess, 'check_output', return_value='--source-info --force-size-x'), mock.patch.object(library.subprocess, 'run', side_effect=convert):
                self.assertEqual(library.main(), 0)
            self.assertEqual(old.read_bytes(), b'new volume')
            backups = list((output / '.volume-library-logs').glob('run-*/*.previous-data'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), b'previous volume')

    def test_rejects_symlink_target(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            real = output / 'real'
            real.write_bytes(b'keep')
            (output / 'foot.data').symlink_to(real)
            cache = output / '.volume-library-downloads'
            cache.mkdir()
            (cache / 'Foot.pvm').write_bytes(b'cached PVM')
            args = ['import', '--only', 'Foot', '--converter', sys.executable, '--output', str(output), '--replace']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(library.subprocess, 'check_output', return_value='--source-info --force-size-x'), mock.patch.object(library.subprocess, 'run') as convert:
                self.assertEqual(library.main(), 1)
                convert.assert_not_called()
            self.assertEqual(real.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
