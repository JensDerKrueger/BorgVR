#!/usr/bin/env python3
"""Generate transformed scalar volume fixtures and JSON ground truth using mode T."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import subprocess
import tempfile


def identity():
    return [[float(i == j) for j in range(4)] for i in range(4)]


def multiply(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def translation(offset):
    result = identity()
    for i in range(3):
        result[i][3] = offset[i]
    return result


def scale(values):
    result = identity()
    for i in range(3):
        result[i][i] = values[i]
    return result


def inverse(matrix):
    rows = [list(row) + unit for row, unit in zip(matrix, identity())]
    for i in range(4):
        pivot = max(range(i, 4), key=lambda j: abs(rows[j][i]))
        rows[i], rows[pivot] = rows[pivot], rows[i]
        divisor = rows[i][i]
        if abs(divisor) < 1e-15:
            raise ValueError("Singular transform")
        rows[i] = [v / divisor for v in rows[i]]
        for j in range(4):
            if j != i:
                factor = rows[j][i]
                rows[j] = [a - factor * b for a, b in zip(rows[j], rows[i])]
    return [row[4:] for row in rows]


def rotation(degrees):
    result = identity()
    for axis, angle in enumerate(degrees):
        c, s = math.cos(math.radians(angle)), math.sin(math.radians(angle))
        r = identity()
        a, b = (axis + 1) % 3, (axis + 2) % 3
        r[a][a], r[a][b], r[b][a], r[b][b] = c, -s, s, c
        result = multiply(r, result)
    return result


def run(command, log):
    with log.open("w") as stream:
        subprocess.run([str(v) for v in command], stdout=stream, stderr=subprocess.STDOUT, check=True)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def geometry(converter, source, folder):
    volume = folder / "geometry.nrrd"
    run([converter, "E", source, volume, "0"], folder / "export.log")
    fields = {}
    with volume.open("rb") as stream:
        while line := stream.readline():
            if not line.strip():
                break
            text = line.decode("ascii").strip()
            if ":" in text and not text.startswith("#"):
                key, value = text.split(":", 1)
                fields[key] = value.strip()
    if fields["dimension"] != "3":
        raise ValueError("Fixtures require a scalar 3D reference volume")
    size = [int(v) for v in fields["sizes"].split()]
    spacing = [float(v) for v in fields["spacings"].split()]
    if not all(math.isfinite(v) and v > 0 for v in spacing):
        raise ValueError("Reference spacing must be positive and finite")
    return size, spacing


def generate(converter, source, output, random_count=0, seed=20261110, translation_fraction=None):
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite existing fixture directory: {output}")
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="borgvr-fixture-geometry-") as temp:
        size, spacing = geometry(converter, source, Path(temp))
    shutil.copy2(source, output / "reference.data")
    s = scale(spacing)
    inv_s = inverse(s)
    center = [(n - 1) * d / 2 for n, d in zip(size, spacing)]
    origin = [int(n * f) for n, f in zip(size, [0.12, 0.08, 0.10])]
    cropped_size = [int(n * f) for n, f in zip(size, [0.76, 0.84, 0.80])]
    cases = [
        ("identity", [0, 0, 0], [0, 0, 0], False),
        ("translated", [0, 0, 0], [12, -8, 6], False),
        ("rotated", [0, 0, 12], [0, 0, 0], False),
        ("rigid", [8, -6, 10], [10, -6, 4], False),
        ("cropped", [0, 0, 0], [0, 0, 0], True),
        ("rigid_cropped", [-10, 7, -14], [-8, 12, -5], True),
    ]
    cases = [(name, angles, delta, origin if crop else [0, 0, 0],
              cropped_size if crop else size) for name, angles, delta, crop in cases]
    if random_count:
        rng = random.Random(seed)
        cases = []
        translation_limits = ([n * d * 1000 * translation_fraction for n, d in zip(size, spacing)]
                              if translation_fraction is not None else [20, 20, 20])
        for index in range(random_count):
            angles = [round(rng.uniform(-20, 20), 6) for _ in range(3)]
            delta = [rng.uniform(-limit, limit) for limit in translation_limits]
            counts = [max(1, int(n * rng.uniform(0.65, 0.90))) for n in size]
            offsets = [rng.randint(0, n - count) for n, count in zip(size, counts)]
            cases.append((f"random_{index + 1:02d}", angles, delta, offsets, counts))
    manifest = {
        "schema_version": 1,
        "reference": "reference.data",
        "reference_sha256": sha256(source),
        "reference_size_xyz": size,
        "voxel_spacing_m_xyz": spacing,
        "conventions": {
            "matrices": "4x4 row-major nested arrays, multiplied by column vectors [x,y,z,1]",
            "voxel_coordinates": "integer coordinates are voxel centers, first voxel is (0,0,0)",
            "rotation": "physical rigid rotation about reference center; R = Rz * Ry * Rx",
            "translation": "millimeters along reference axes, applied after center-pivot rotation",
            "crop": "crop AFTER transformation; moving voxel origin resets to zero",
            "resampling": "moving(q) = reference(moving_to_reference_voxel * q), trilinear, zero outside",
            "registration": "reference-to-moving is the pull-sampling matrix used by BorgVR registration",
            "accuracy": "ground truth is geometric; interpolation and cropping may shift the numerical optimum",
        },
        "cases": [],
    }
    if random_count:
        manifest["random_generation"] = {
            "seed": seed, "count": random_count,
            "rotation_degrees_per_axis": [-20, 20],
            "translation_mm_ranges_xyz": [[-v, v] for v in translation_limits],
            "translation_fraction_per_axis": translation_fraction,
            "retained_fraction_per_axis": [0.65, 0.90],
        }
    for name, angles, delta_mm, crop_origin, target_size in cases:
        physical = multiply(translation([v / 1000 for v in delta_mm]),
                    multiply(translation(center), multiply(rotation(angles), translation([-v for v in center]))))
        forward = multiply(inv_s, multiply(physical, s))
        effective = multiply(translation([-v for v in crop_origin]), forward)
        backward = inverse(effective)
        for product in [multiply(effective, backward), multiply(backward, effective)]:
            assert max(abs(product[i][j] - (i == j)) for i in range(4) for j in range(4)) < 1e-9
        command = [converter, "T", source, output / f"{name}.data", "32", "2",
                   "--matrix", " ".join(format(v, ".17g") for row in forward for v in row), "--filter", "linear"]
        if crop_origin != [0, 0, 0] or target_size != size:
            command += ["--crop", " ".join(str(v) for v in crop_origin + target_size)]
        print(f"Generating {name}: rotation={angles} degrees, translation={delta_mm} mm, size={target_size}", flush=True)
        run(command, output / f"{name}.log")
        manifest["cases"].append({
            "name": name, "moving": f"{name}.data", "size_xyz": target_size,
            "euler_degrees_xyz": angles, "translation_mm_xyz": delta_mm,
            "pivot_reference_m_xyz": center, "crop_origin_transformed_voxel_xyz": crop_origin,
            "source_to_uncropped_target_voxel": forward,
            "reference_to_moving_voxel": effective, "moving_to_reference_voxel": backward,
            "reference_to_moving_meters": multiply(s, multiply(effective, inv_s)),
            "moving_to_reference_meters": multiply(s, multiply(backward, inv_s)),
        })
        (output / "transforms.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    print(f"Created {len(cases)} fixtures and {output / 'transforms.json'}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--converter", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--random-count", type=int, default=0,
                        help="Generate this many random rigid/cropped cases instead of the six fixed cases")
    parser.add_argument("--seed", type=int, default=20261110)
    parser.add_argument("--translation-fraction", type=float,
                        help="Maximum shift as a fraction of each physical axis extent instead of 20 mm")
    args = parser.parse_args()
    if args.random_count < 0:
        parser.error("--random-count must be nonnegative")
    if args.translation_fraction is not None and not (0 < args.translation_fraction < 1):
        parser.error("--translation-fraction must be between zero and one")
    generate(args.converter.resolve(), args.source.resolve(), args.output.resolve(), args.random_count,
             args.seed, args.translation_fraction)
