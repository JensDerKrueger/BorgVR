#!/usr/bin/env python3
"""Display metadata stored in VolRen PVM, PVM2, and PVM3 volumes."""

from __future__ import annotations

import argparse
import dataclasses
import sys
from pathlib import Path


DDS_V3D = b"DDS v3d\n"
DDS_V3E = b"DDS v3e\n"
DDS_INTERLEAVE = 1 << 24
MAX_TEXT_LENGTH = 256


class PVMError(ValueError):
    pass


@dataclasses.dataclass(frozen=True)
class PVMMetadata:
    version: int
    width: int
    height: int
    depth: int
    components: int
    voxel_spacing: tuple[float, float, float]
    header_bytes: int
    payload_bytes: int
    description: str | None
    courtesy: str | None
    parameters: str | None
    comment: str | None


class BitReader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.bit_offset = 0

    def read(self, count: int) -> int:
        if count == 0:
            return 0
        if self.bit_offset + count > len(self.data) * 8:
            raise PVMError("Unexpected end of DDS-compressed data")

        value = 0
        while count:
            byte_index = self.bit_offset // 8
            bit_index = self.bit_offset % 8
            available = 8 - bit_index
            take = min(count, available)
            shift = available - take
            mask = (1 << take) - 1
            value = (value << take) | ((self.data[byte_index] >> shift) & mask)
            self.bit_offset += take
            count -= take
        return value


def deinterleave(data: bytearray, skip: int, block: int) -> None:
    if skip <= 1:
        return

    block_bytes = len(data) if block == 0 else skip * block
    for start in range(0, len(data), block_bytes):
        source = data[start : start + block_bytes]
        restored = bytearray(len(source))
        source_index = 0
        for component in range(skip):
            for destination in range(component, len(source), skip):
                restored[destination] = source[source_index]
                source_index += 1
        data[start : start + len(source)] = restored


def decompress_dds(data: bytes, max_output_bytes: int) -> tuple[bytes, str]:
    if data.startswith(DDS_V3D):
        wrapper = "DDS v3d"
        block = 0
        compressed = data[len(DDS_V3D) :]
    elif data.startswith(DDS_V3E):
        wrapper = "DDS v3e"
        block = DDS_INTERLEAVE
        compressed = data[len(DDS_V3E) :]
    else:
        return data, "none"

    # The reference decoder appends one zero-filled word so the final bit group
    # can cross the physical end of the compressed stream.
    reader = BitReader(compressed + b"\0\0\0\0")
    skip = reader.read(2) + 1
    strip = reader.read(16) + 1
    output = bytearray()
    previous = 0

    while True:
        run_length = reader.read(7)
        if run_length == 0:
            break
        encoded_bits = reader.read(3)
        bits = encoded_bits + 1 if encoded_bits >= 1 else 0

        for _ in range(run_length):
            index = len(output)
            delta = reader.read(bits) - ((1 << bits) // 2)
            if strip == 1 or index <= strip:
                value = previous + delta
            else:
                value = previous + output[index - strip] - output[index - strip - 1] + delta
            value &= 0xFF
            output.append(value)
            previous = value
            if len(output) > max_output_bytes:
                raise PVMError(
                    f"DDS output exceeds the safety limit of {format_bytes(max_output_bytes)}"
                )

    deinterleave(output, skip, block)
    return bytes(output), wrapper


def read_line(data: bytes, offset: int) -> tuple[str, int]:
    end = data.find(b"\n", offset)
    if end < 0:
        raise PVMError("Incomplete PVM header")
    try:
        return data[offset:end].decode("ascii"), end + 1
    except UnicodeDecodeError as error:
        raise PVMError("PVM header is not ASCII") from error


def parse_numbers(line: str, count: int, converter, label: str):
    fields = line.split()
    if len(fields) != count:
        raise PVMError(f"Expected {count} {label} values, found {len(fields)}")
    try:
        return tuple(converter(field) for field in fields)
    except ValueError as error:
        raise PVMError(f"Invalid {label}: {line!r}") from error


def decode_text(data: bytes) -> str | None:
    if not data:
        return None
    return data.decode("utf-8", errors="replace")


def parse_pvm(data: bytes) -> PVMMetadata:
    if data.startswith(b"PVM\n"):
        version = 1
        offset = 4
        while offset < len(data) and data[offset : offset + 1] == b"#":
            _, offset = read_line(data, offset)
    elif data.startswith(b"PVM2\n"):
        version = 2
        offset = 5
    elif data.startswith(b"PVM3\n"):
        version = 3
        offset = 5
    else:
        raise PVMError("File does not contain a PVM, PVM2, or PVM3 stream")

    dimensions_line, offset = read_line(data, offset)
    width, height, depth = parse_numbers(dimensions_line, 3, int, "dimension")
    if min(width, height, depth) < 1:
        raise PVMError("PVM dimensions must be positive")

    if version >= 2:
        spacing_line, offset = read_line(data, offset)
        voxel_spacing = parse_numbers(spacing_line, 3, float, "voxel-spacing")
        if min(voxel_spacing) <= 0:
            raise PVMError("PVM voxel spacing must be positive")
    else:
        voxel_spacing = (1.0, 1.0, 1.0)

    components_line, offset = read_line(data, offset)
    (components,) = parse_numbers(components_line, 1, int, "component")
    if components < 1:
        raise PVMError("PVM component count must be positive")

    payload_bytes = width * height * depth * components
    payload_end = offset + payload_bytes
    if payload_end > len(data):
        raise PVMError(
            f"Voxel payload is truncated: expected {format_bytes(payload_bytes)}, "
            f"found {format_bytes(max(0, len(data) - offset))}"
        )

    texts: list[str | None] = [None, None, None, None]
    trailing_offset = payload_end
    if version == 3:
        for index in range(4):
            end = data.find(b"\0", trailing_offset)
            if end < 0:
                raise PVMError(f"PVM3 metadata field {index + 1} is not NUL-terminated")
            if end - trailing_offset >= MAX_TEXT_LENGTH:
                raise PVMError(f"PVM3 metadata field {index + 1} exceeds 255 bytes")
            texts[index] = decode_text(data[trailing_offset:end])
            trailing_offset = end + 1

    if trailing_offset != len(data):
        raise PVMError(
            f"Unexpected trailing data: {format_bytes(len(data) - trailing_offset)}"
        )

    return PVMMetadata(
        version=version,
        width=width,
        height=height,
        depth=depth,
        components=components,
        voxel_spacing=voxel_spacing,
        header_bytes=offset,
        payload_bytes=payload_bytes,
        description=texts[0],
        courtesy=texts[1],
        parameters=texts[2],
        comment=texts[3],
    )


def format_bytes(value: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    amount = float(value)
    for unit in units:
        if abs(amount) < 1024 or unit == units[-1]:
            return f"{int(amount)} {unit}" if unit == "B" else f"{amount:.2f} {unit}"
        amount /= 1024
    return f"{value} B"


def print_metadata(path: Path, file_size: int, wrapper: str, metadata: PVMMetadata) -> None:
    sx, sy, sz = metadata.voxel_spacing
    physical = (
        metadata.width * sx,
        metadata.height * sy,
        metadata.depth * sz,
    )
    print(f"File:             {path}")
    print(f"File size:        {format_bytes(file_size)} ({file_size} bytes)")
    print(f"Compression:      {wrapper}")
    print(f"PVM version:      PVM{metadata.version if metadata.version > 1 else ''}")
    print(f"Dimensions:       {metadata.width} x {metadata.height} x {metadata.depth}")
    print(f"Components:       {metadata.components} byte(s) per voxel")
    print(f"Voxel spacing:    {sx:g} x {sy:g} x {sz:g}")
    print(f"Relative extent:  {physical[0]:g} x {physical[1]:g} x {physical[2]:g}")
    print(f"Header size:      {metadata.header_bytes} B")
    print(f"Voxel data size:  {format_bytes(metadata.payload_bytes)} ({metadata.payload_bytes} bytes)")

    fields = (
        ("Description", metadata.description),
        ("Courtesy", metadata.courtesy),
        ("Parameters", metadata.parameters),
        ("Comment", metadata.comment),
    )
    for label, value in fields:
        if value is not None:
            print(f"{label + ':':18}{value}")


def parse_size(value: str) -> int:
    suffixes = {"": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30}
    normalized = value.strip().lower()
    suffix = normalized[-1:] if normalized[-1:] in suffixes and not normalized[-1:].isdigit() else ""
    number = normalized[:-1] if suffix else normalized
    try:
        result = int(float(number) * suffixes[suffix])
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid size: {value}") from error
    if result < 1:
        raise argparse.ArgumentTypeError("size must be positive")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Display metadata from uncompressed or DDS-compressed VolRen PVM files."
    )
    parser.add_argument("file", type=Path, help="PVM volume to inspect")
    parser.add_argument(
        "--max-decompressed-size",
        type=parse_size,
        default=8 << 30,
        metavar="SIZE",
        help="DDS decompression safety limit (default: 8G; suffixes K, M, G)",
    )
    arguments = parser.parse_args()

    try:
        file_size = arguments.file.stat().st_size
        raw = arguments.file.read_bytes()
        data, wrapper = decompress_dds(raw, arguments.max_decompressed_size)
        metadata = parse_pvm(data)
        print_metadata(arguments.file, file_size, wrapper, metadata)
    except (OSError, PVMError) as error:
        print(f"pvm_info: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
