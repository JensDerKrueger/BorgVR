#!/usr/bin/env python3
"""Import missing Open SciVis RAW datasets without replacing existing collection choices."""

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
from urllib.parse import urlparse


HERE = Path(__file__).resolve().parent
TYPES = {'uint8': 1, 'uint16': 2, 'uint32': 4, 'int16': 2, 'float32': 4, 'float64': 8}
NEW = {'3d_neurons_15_sept_2016', 'dns', 'isotropic_pressure', 'rotstrat_temperature'}
NEURON_X = 2048 * 0.267345e-6


def source_bytes(row):
    return math.prod(row['size']) * TYPES[row['type']]


def validate_catalog(catalog):
    for name, row in catalog.items():
        url = urlparse(row['url'])
        if not re.fullmatch(r'[a-z0-9_]+', name) or row['type'] not in TYPES:
            raise ValueError('Invalid dataset name or scalar type')
        if url.scheme != 'http' or url.netloc != 'klacansky.com' or url.path != f'/open-scivis-datasets/{name}/{name}_{"x".join(map(str, row["size"]))}_{row["type"]}.raw':
            raise ValueError('Unexpected download URL')
        if len(row['size']) != 3 or any(not isinstance(n, int) or n < 1 for n in row['size']):
            raise ValueError('Invalid voxel dimensions')
        if len(row['spacing']) != 3 or any(not math.isfinite(n) or n <= 0 for n in row['spacing']):
            raise ValueError('Invalid voxel aspect')
        if not re.fullmatch(r'[0-9a-f]{128}', row['sha512sum']):
            raise ValueError('Invalid raw SHA-512')


def regular(path):
    return path.is_file() and not path.is_symlink() and path.stat().st_size > 0


def checked_download(row, target):
    expected = source_bytes(row)
    if not regular(target):
        if target.exists() or target.is_symlink():
            raise ValueError(f'Unsafe cached input: {target}')
        partial = Path(str(target) + '.part')
        if partial.is_symlink() or (partial.exists() and not partial.is_file()):
            raise ValueError('Unsafe partial download')
        if not partial.exists() or partial.stat().st_size != expected:
            subprocess.run(['curl', '--fail', '--location', '--retry', '4', '--connect-timeout', '20',
                            '--speed-time', '120', '--speed-limit', '1024', '--continue-at', '-',
                            '--output', str(partial), row['url']], check=True)
        source = partial
    else:
        source = target
    if source.stat().st_size != expected:
        raise ValueError(f'Incorrect RAW byte count for {target.name}')
    digest = hashlib.sha512()
    with source.open('rb') as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != row['sha512sum']:
        raise ValueError(f'RAW SHA-512 mismatch for {target.name}; original retained for inspection')
    if source != target:
        os.replace(source, target)


def description(name, row):
    return {
        '3d_neurons_15_sept_2016': 'Macaque visual cortical neurons labeled with TdTomato fluorescent proteins.',
        'dns': 'Pressure field from turbulent channel flow at high Reynolds number.',
        'isotropic_pressure': 'Pressure field from forced isotropic turbulence simulation.',
        'rotstrat_temperature': 'Temperature field from rotating stratified turbulence simulation.',
    }.get(name, ' '.join((row['description'] or row['name']).split()[:10]))


def sources(name, row, day, stats=None):
    date = day + 'T00:00:00Z'
    entries = []
    if row.get('acknowledgement'):
        entries.append((date, 'Original source and acknowledgements: ' + row['acknowledgement']))
    if row.get('bibtex'):
        entries.append((date, 'Related publication: ' + json.dumps(row['bibtex'], sort_keys=True, ensure_ascii=True)))
    if name == '3d_neurons_15_sept_2016':
        entries.append((date, f'Estimated X extent: {NEURON_X:.12g} m. Catalog spacing 0.267345/0.267345/0.5 interpreted as micrometers for fluorescence microscopy; physical units are not explicitly specified.'))
    else:
        entries.append((date, 'Display X extent: 1 m; not a physical calibration. Simulation coordinate units are not established in meters.'))
    if stats is not None:
        entries.append((date, f'RAW {row["type"]} quantized linearly to UInt16 using finite source range [{stats["minimum"]}, {stats["maximum"]}]; nonfinite samples mapped to zero: {stats["nonfiniteCount"]}.'))
    entries.append((date, f'Downloaded on {day} as little-endian RAW from {row["url"]}; SHA-512 {row["sha512sum"]}; catalog http://klacansky.com/open-scivis-datasets/ .'))
    return entries


def write_qvis(path, raw, row, x_extent):
    spacing = [x_extent / row['size'][0] * s / row['spacing'][0] for s in row['spacing']]
    path.write_text('objectFileName: ' + os.path.relpath(raw, path.parent) + '\nResolution: ' + ' '.join(map(str, row['size'])) +
                    '\nSliceThickness: ' + ' '.join(f'{v:.12g}' for v in spacing) +
                    '\nFormat: USHORT\nEndianess: LITTLE\n', encoding='ascii')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--converter', default='TerminalConverterApp')
    parser.add_argument('--quantizer', type=Path, default=HERE / 'scivis-raw-quantizer')
    parser.add_argument('--auditor', type=Path, default=HERE / 'scivis-raw-auditor')
    parser.add_argument('--manifest', type=Path, default=HERE / 'scivis-raw-datasets.json')
    parser.add_argument('--output', type=Path, default=Path.cwd())
    parser.add_argument('--only', choices=sorted(NEW))
    parser.add_argument('--include-large', action='store_true', help='Include 256/256/900 GiB RAW datasets (otherwise deferred)')
    parser.add_argument('--download-date', default=datetime.date.today().isoformat())
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    datetime.date.fromisoformat(args.download_date)
    catalog = json.loads(args.manifest.read_text())
    validate_catalog(catalog)
    unknown = set(catalog) - NEW
    output = args.output.resolve()
    if args.dry_run:
        for name, row in sorted(catalog.items(), key=lambda item: source_bytes(item[1])):
            if args.only and name != args.only:
                continue
            status = 'existing-collection-choice' if name in unknown else ('import' if args.include_large or source_bytes(row) <= 32 * 1024**3 else 'deferred-large')
            print(f'{name}\t{status}\t{source_bytes(row) / 1024**3:.3f} GiB RAW')
        return 0
    executable = shutil.which(args.converter)
    if executable is None or not Path(executable).is_file():
        parser.error('Converter must be an executable file')
    converter = str(Path(executable).resolve())
    help_text = subprocess.check_output([converter, '--help'], text=True)
    if '--source-info' not in help_text or '--force-size-x' not in help_text:
        parser.error('Converter lacks provenance/size support')
    if args.include_large and (not args.quantizer.is_file() or not os.access(args.quantizer, os.X_OK)):
        parser.error('Build SciVisRawQuantizer.swift and pass --quantizer PATH')
    if not args.auditor.is_file() or not os.access(args.auditor, os.X_OK):
        parser.error('Build SciVisRawMetadataTests.swift and pass --auditor PATH')
    cache = output / '.scivis-raw-downloads'
    logs = output / '.scivis-raw-logs'
    cache.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run-', dir=logs))
    shutil.copyfile(args.manifest, run / 'catalog.json')
    report = {'pid': os.getpid(), 'started': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'datasets': []}
    def save():
        staging = run / 'state.json.tmp'
        staging.write_text(json.dumps(report, indent=2) + '\n')
        os.replace(staging, run / 'state.json')
    print(f'Run report: {run / "state.json"}', flush=True)
    errors = 0
    rows = sorted(catalog.items(), key=lambda item: source_bytes(item[1]))
    for name, row in rows:
        if args.only and args.only != name:
            continue
        item = {'name': name, 'status': 'pending', 'sourceBytes': source_bytes(row)}
        report['datasets'].append(item)
        save()
        def stage(status):
            item['status'] = status
            save()
            print(f'{name}: {status}', flush=True)
        try:
            target = output / (name + '.data')
            if name in unknown:
                if not regular(target):
                    raise ValueError('Expected existing dataset is missing; import the OZX/PVM collections first')
                stage('existing-collection-choice')
                continue
            if target.exists() or target.is_symlink():
                if not regular(target):
                    raise ValueError('Unsafe existing output')
                stage('already-imported')
                continue
            if not args.include_large and source_bytes(row) > 32 * 1024**3:
                stage('deferred-large')
                continue
            raw = cache / Path(urlparse(row['url']).path).name
            scalar_bytes = math.prod(row['size']) * 2
            required = (0 if regular(raw) else source_bytes(row)) + scalar_bytes * 4
            if shutil.disk_usage(output).free < required:
                raise ValueError(f'Insufficient workspace: need approximately {required / 1024**3:.1f} GiB free')
            stage('downloading-and-checking-sha512')
            checked_download(row, raw)
            with tempfile.TemporaryDirectory(prefix=f'.raw-import-{name}-', dir=output) as work_path:
                work = Path(work_path)
                volume_raw = raw
                stats = None
                if row['type'].startswith('float'):
                    stage('quantizing-to-uint16')
                    volume_raw = work / 'quantized.raw'
                    with (run / (name + '-quantization.log')).open('w') as log:
                        result = subprocess.run([str(args.quantizer.resolve()), row['type'], str(raw), str(volume_raw)], stdout=subprocess.PIPE, stderr=log, text=True, check=True)
                    stats = json.loads(result.stdout)
                    item['quantization'] = stats
                    print(f'{name}: original finite range {stats["minimum"]} ... {stats["maximum"]}', flush=True)
                elif row['type'] != 'uint16':
                    raise ValueError('Unexpected new scalar type; add explicit renderer-compatible conversion')
                x_extent = NEURON_X if name == '3d_neurons_15_sept_2016' else 1.0
                header = work / 'input.dat'
                write_qvis(header, volume_raw, row, x_extent)
                destination = work / (name + '.data')
                command = [converter, 'Q', str(header), str(destination), description(name, row), '32', '2']
                for date, text in sources(name, row, args.download_date, stats):
                    command += ['--source-info', date, text]
                command += ['--force-size-x', str(x_extent)]
                stage('bricking')
                with (run / (name + '.log')).open('w') as log:
                    subprocess.run(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                   env={**os.environ, 'TMPDIR': str(work) + '/'}, check=True)
                if not regular(destination):
                    raise ValueError('Converter produced no volume')
                stage('validating-output-metadata')
                subprocess.run([str(args.auditor.resolve()), str(args.manifest.resolve()), str(destination), name, args.download_date], check=True)
                os.link(destination, target)
                stage('converted')
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            item['error'] = str(error)
            print(f'{name}: {error}; details in {run}', file=sys.stderr, flush=True)
            stage('failed')
            errors += 1
    report['finished'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()
    counts = {status: sum(item['status'] == status for item in report['datasets']) for status in sorted({item['status'] for item in report['datasets']})}
    print('Finished: ' + json.dumps(counts), flush=True)
    return int(errors > 0)


if __name__ == '__main__':
    sys.exit(main())
