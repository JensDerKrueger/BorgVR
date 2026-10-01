#!/usr/bin/env python3
"""Read or change the physical dimensions of a BorgVR .data file in place."""

from __future__ import annotations

import argparse
import math
import os
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


MAGIC = b"BORGVR"
SUPPORTED_VERSION = 3
METADATA_OFFSET_FORMAT = "<Q"
FIXED_HEADER_FORMAT = "<6s6q3f"
FIXED_HEADER_SIZE = struct.calcsize(FIXED_HEADER_FORMAT)
SPACING_OFFSET_IN_METADATA = struct.calcsize("<6s6q")
SPACING_FORMAT = "<3f"


@dataclass(frozen=True)
class DatasetGeometry:
    metadata_offset: int
    width: int
    height: int
    depth: int
    spacing_x: float
    spacing_y: float
    spacing_z: float

    @property
    def physical_dimensions(self) -> tuple[float, float, float]:
        return (
            self.width * self.spacing_x,
            self.height * self.spacing_y,
            self.depth * self.spacing_z,
        )


def read_geometry(path: Path) -> DatasetGeometry:
    file_size = path.stat().st_size
    with path.open("rb") as file:
        offset_data = file.read(struct.calcsize(METADATA_OFFSET_FORMAT))
        if len(offset_data) != struct.calcsize(METADATA_OFFSET_FORMAT):
            raise ValueError("File is too short to contain a BorgVR metadata offset.")

        (metadata_offset,) = struct.unpack(METADATA_OFFSET_FORMAT, offset_data)
        if metadata_offset + FIXED_HEADER_SIZE > file_size:
            raise ValueError("The BorgVR metadata header lies outside the file.")

        file.seek(metadata_offset)
        header = file.read(FIXED_HEADER_SIZE)

    (
        magic,
        version,
        width,
        height,
        depth,
        _component_count,
        _bytes_per_component,
        spacing_x,
        spacing_y,
        spacing_z,
    ) = struct.unpack(FIXED_HEADER_FORMAT, header)

    if magic != MAGIC:
        raise ValueError(f"Invalid BorgVR magic bytes at offset {metadata_offset}.")
    if version != SUPPORTED_VERSION:
        raise ValueError(
            f"Unsupported BorgVR format version {version}; expected {SUPPORTED_VERSION}."
        )
    if min(width, height, depth) <= 0:
        raise ValueError(f"Invalid voxel dimensions: {width} x {height} x {depth}.")
    if not all(math.isfinite(value) and value > 0 for value in (spacing_x, spacing_y, spacing_z)):
        raise ValueError(
            f"Invalid voxel spacing: {spacing_x}, {spacing_y}, {spacing_z}."
        )

    return DatasetGeometry(
        metadata_offset=metadata_offset,
        width=width,
        height=height,
        depth=depth,
        spacing_x=spacing_x,
        spacing_y=spacing_y,
        spacing_z=spacing_z,
    )


def parse_length(value: str) -> float:
    match = re.fullmatch(
        r"\s*([+]?(?:\d+(?:[.,]\d*)?|[.,]\d+)(?:[eE][+-]?\d+)?)\s*([a-zA-Zµμ]*)\s*",
        value,
    )
    if match is None:
        raise argparse.ArgumentTypeError(
            "Expected a positive length such as 1.2, 1.2m, 12cm, or 0.5mm."
        )

    number_text, unit_text = match.groups()
    number = float(number_text.replace(",", "."))
    unit = unit_text.lower().replace("μ", "µ")
    factors = {
        "": 1.0,
        "m": 1.0,
        "km": 1e3,
        "cm": 1e-2,
        "mm": 1e-3,
        "µm": 1e-6,
        "um": 1e-6,
        "nm": 1e-9,
    }
    if unit not in factors:
        raise argparse.ArgumentTypeError(f"Unsupported length unit: {unit_text!r}.")

    meters = number * factors[unit]
    if not math.isfinite(meters) or meters <= 0:
        raise argparse.ArgumentTypeError("The physical size must be finite and greater than zero.")
    return meters


def preferred_unit(maximum_meters: float) -> tuple[float, str]:
    if maximum_meters >= 1_000:
        return 1_000, "km"
    if maximum_meters >= 1:
        return 1, "m"
    if maximum_meters >= 1e-2:
        return 1e-2, "cm"
    if maximum_meters >= 1e-3:
        return 1e-3, "mm"
    if maximum_meters >= 1e-6:
        return 1e-6, "µm"
    return 1e-9, "nm"


def format_dimensions(dimensions: tuple[float, float, float]) -> str:
    factor, symbol = preferred_unit(max(dimensions))
    values = " x ".join(f"{value / factor:.6g}" for value in dimensions)
    return f"{values} {symbol}"


def print_geometry(path: Path, geometry: DatasetGeometry) -> None:
    print(f"File: {path}")
    print(f"Voxel dimensions: {geometry.width} x {geometry.height} x {geometry.depth}")
    print(
        "Voxel spacing: "
        f"{geometry.spacing_x:.9g} x {geometry.spacing_y:.9g} x "
        f"{geometry.spacing_z:.9g} m"
    )
    print(f"Physical dimensions: {format_dimensions(geometry.physical_dimensions)}")


def set_first_dimension(path: Path, geometry: DatasetGeometry, size_x_meters: float) -> None:
    current_size_x = geometry.physical_dimensions[0]
    scale = size_x_meters / current_size_x
    new_spacing = (
        geometry.spacing_x * scale,
        geometry.spacing_y * scale,
        geometry.spacing_z * scale,
    )

    if not all(math.isfinite(value) and value > 0 for value in new_spacing):
        raise ValueError("The requested size cannot be represented as valid voxel spacing.")

    spacing_offset = geometry.metadata_offset + SPACING_OFFSET_IN_METADATA
    with path.open("r+b") as file:
        file.seek(spacing_offset)
        file.write(struct.pack(SPACING_FORMAT, *new_spacing))
        file.flush()
        os.fsync(file.fileno())


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Read the physical dimensions of a BorgVR .data file or change its first "
            "dimension in place while preserving the physical aspect ratio."
        )
    )
    parser.add_argument("file", type=Path, help="BorgVR .data file")
    parser.add_argument(
        "size_x",
        nargs="?",
        type=parse_length,
        help="new first physical dimension; defaults to meters (examples: 1.2, 50cm, 1mm)",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    path = arguments.file.expanduser()

    try:
        geometry = read_geometry(path)
        if arguments.size_x is None:
            print_geometry(path, geometry)
            return 0

        print("Before:")
        print_geometry(path, geometry)
        set_first_dimension(path, geometry, arguments.size_x)
        updated_geometry = read_geometry(path)
        print("\nAfter:")
        print_geometry(path, updated_geometry)
        return 0
    except (OSError, ValueError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
