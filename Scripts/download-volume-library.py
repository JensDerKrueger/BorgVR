#!/usr/bin/env python3
"""Download the Volume Library and import its selected, nonredundant PVM scans."""

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent


def load_catalog(path):
    catalog = json.loads(path.read_text())
    files = set()
    names = set()
    for row in catalog['datasets']:
        if not re.fullmatch(r'[A-Za-z0-9_-]+\.pvm', row['file']) or row['file'] in files:
            raise ValueError('Invalid or duplicate PVM filename')
        files.add(row['file'])
        if not re.fullmatch(r'[a-z0-9_]+', row['name']):
            raise ValueError('Invalid output name')
        if row['action'] not in ('import', 'variant', 'keep-existing'):
            raise ValueError('Invalid selection action')
        if row['action'] != 'variant':
            if row['name'] in names:
                raise ValueError('Duplicate selected output name')
            names.add(row['name'])
        if row['size_mode'] not in ('force', 'estimate', 'literature', 'display'):
            raise ValueError('Invalid size mode')
        if not math.isfinite(row['size_x']) or row['size_x'] <= 0:
            raise ValueError('Invalid X extent')
        if len(row['dimensions']) != 3 or min(row['dimensions']) < 1 or row['bits'] not in (8, 16, 24):
            raise ValueError('Invalid sample layout')
        if not re.fullmatch(r'[0-9a-f]{64}', row['download_sha256']):
            raise ValueError('Invalid download checksum')
    return catalog


def source_entries(catalog, row, day):
    date = day + 'T00:00:00Z'
    entries = []
    for label, key in [('Credits', 'credits'), ('Acquisition parameters', 'parameters'), ('Comments', 'comments')]:
        if row[key]:
            timestamp = date
            if key == 'parameters':
                if '16.Oct.1999' in row[key]:
                    timestamp = '1999-10-16T00:00:00Z'
                elif '28.Jan.2000' in row[key]:
                    timestamp = '2000-01-28T00:00:00Z'
            entries.append((timestamp, f'{label}: {row[key]}'))
    for text in row.get('source_notes', []):
        entries.append((date, text))
    entries.append((date, f'Volume Library use conditions: {catalog["terms"]} Source: {catalog["source"]}'))
    entries.append((date, f'Representation selection: {row["decision"]}'))
    if row['size_mode'] in ('estimate', 'literature'):
        entries.append((date, f'Estimated X extent: {row["size_x"]:g} m. {row["size_basis"]}'))
    elif row['size_mode'] == 'display':
        entries.append((date, f'Display X extent: {row["size_x"]:g} m; not a physical calibration. {row["size_basis"]}'))
    url = catalog['source'] + row['file']
    entries.append((date, f'Downloaded on {day} as PVM from {url}'))
    return entries


def regular_file(path):
    return path.is_file() and not path.is_symlink() and path.stat().st_size > 0


def verify_download(target, expected):
    digest = hashlib.sha256()
    with target.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise ValueError(f'Download checksum mismatch: {target}')


def download(url, target, expected):
    if regular_file(target):
        verify_download(target, expected)
        return
    if target.exists() or target.is_symlink():
        raise ValueError(f'Unsafe or empty cached input: {target}')
    partial = target.with_suffix('.pvm.part')
    if partial.is_symlink() or (partial.exists() and not partial.is_file()):
        raise ValueError(f'Unsafe partial download: {partial}')
    # The operator only offers working HTTP; do not disable HTTPS certificate checks.
    subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '20',
                    '--max-time', '900', '--continue-at', '-', '--output', str(partial), url], check=True)
    if not regular_file(partial):
        raise ValueError('Download was empty')
    verify_download(partial, expected)
    os.replace(partial, target)


def converter_command(converter, row, source, destination, entries, brick_size, overlap):
    command = [str(converter), 'P', str(source), str(destination), row['description'], str(brick_size), str(overlap)]
    for date, text in entries:
        command += ['--source-info', date, text]
    command += ['--force-size-x', str(row['size_x'])]
    return command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--converter', default='TerminalConverterApp')
    parser.add_argument('--output', type=Path, default=Path.cwd())
    parser.add_argument('--manifest', type=Path, default=HERE / 'volume-library-datasets.json')
    parser.add_argument('--brick-size', type=int, default=32)
    parser.add_argument('--overlap', type=int, default=2)
    parser.add_argument('--download-date', default=datetime.date.today().isoformat())
    parser.add_argument('--only', help='One PVM filename (without extension also accepted)')
    parser.add_argument('--download-only', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--replace', action='store_true', help='Replace selected outputs after successful conversion; retain old files in hidden backups')
    args = parser.parse_args()
    datetime.date.fromisoformat(args.download_date)
    if args.overlap < 1 or args.brick_size <= 2 * args.overlap or args.brick_size > 9999:
        parser.error('Invalid brick size or overlap')
    catalog = load_catalog(args.manifest)
    rows = catalog['datasets']
    if args.only:
        rows = [r for r in rows if r['file'].removesuffix('.pvm') == args.only.removesuffix('.pvm')]
        if not rows:
            parser.error('Unknown PVM filename')
    if args.dry_run:
        for row in rows:
            print(f'{row["file"]}\t{row["action"]}\t{row["name"]}.data\t{row["decision"]}')
        return 0
    if not shutil.which('curl'):
        parser.error('curl is required')
    converter = None
    if not args.download_only:
        executable = shutil.which(args.converter)
        if executable is None or not Path(executable).is_file():
            parser.error('Converter must be an executable file; use --converter ./TerminalConverterApp')
        converter = Path(executable).resolve()
        help_text = subprocess.check_output([str(converter), '--help'], text=True)
        if '--source-info' not in help_text or '--force-size-x' not in help_text:
            parser.error('Converter lacks provenance or physical size support')
    output = args.output.resolve()
    cache = output / '.volume-library-downloads'
    logs = output / '.volume-library-logs'
    cache.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run-', dir=logs))
    shutil.copyfile(args.manifest, run / 'manifest.json')
    report = []
    errors = 0
    for index, row in enumerate(rows, 1):
        name = row['name']
        print(f'[{index}/{len(rows)}] {row["file"]} -> {name}: {row["action"]}', flush=True)
        status = 'failed'
        try:
            source = cache / row['file']
            download(catalog['source'] + row['file'], source, row['download_sha256'])
            if args.download_only:
                status = 'downloaded'
            elif row['action'] == 'variant':
                status = 'redundant-variant'
            elif row['action'] == 'keep-existing':
                if not regular_file(output / f'{name}.data'):
                    raise ValueError(f'Preferred existing {name}.data is missing; import OME-Zarr first')
                status = 'kept-existing-original'
            else:
                target = output / f'{name}.data'
                if target.exists() or target.is_symlink():
                    if not regular_file(target):
                        raise ValueError(f'Unsafe or empty output: {target}')
                    if not args.replace:
                        status = 'existing-output'
                        continue
                with tempfile.TemporaryDirectory(prefix=f'.library-{name}-', dir=output) as work:
                    destination = Path(work) / f'{name}.data'
                    entries = source_entries(catalog, row, args.download_date)
                    command = converter_command(converter, row, source, destination, entries, args.brick_size, args.overlap)
                    with (run / f'{name}.log').open('w') as log:
                        subprocess.run(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, check=True)
                    if not regular_file(destination):
                        raise ValueError('Converter produced no volume')
                    if target.exists():
                        # Hard links retain the old data without copying large volumes.
                        os.link(target, run / f'{name}.previous-data')
                    if args.replace:
                        os.replace(destination, target)
                    else:
                        os.link(destination, target)
                    status = 'converted'
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f'FAILED {row["file"]}: {error}', file=sys.stderr, flush=True)
            errors += 1
        finally:
            report.append({'file': row['file'], 'name': name, 'status': status})
            (run / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    counts = {status: sum(r['status'] == status for r in report) for status in sorted({r['status'] for r in report})}
    print(f'Finished: {json.dumps(counts)}; report: {run / "report.json"}', flush=True)
    return int(errors > 0)


if __name__ == '__main__':
    sys.exit(main())
