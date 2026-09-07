#!/usr/bin/env python3
import argparse
import pathlib
import textwrap


CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}

COPYRIGHT_BLOCK_COMMENT = textwrap.dedent("""\
    /*
     Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

     Permission is hereby granted, free of charge, to any person obtaining a copy of this
     software and associated documentation files (the "Software"), to deal in the Software
     without restriction, including without limitation the rights to use, copy, modify,
     merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
     permit persons to whom the Software is furnished to do so, subject to the following
     conditions:

     The above copyright notice and this permission notice shall be included in all copies or
     substantial portions of the Software.

     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
     INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
     PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
     BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
     OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
     IN THE SOFTWARE.
     */
    """)


def symbol_name(path):
    text = "_".join(path.parts)
    return "kWebAsset_" + "".join(ch if ch.isalnum() else "_" for ch in text)


def byte_array(data):
    if not data:
        return ""
    rows = []
    for index in range(0, len(data), 16):
        rows.append(", ".join(f"0x{byte:02x}" for byte in data[index:index + 16]))
    return ",\n".join("    " + row for row in rows)


def main():
    parser = argparse.ArgumentParser(description="Embed BorgVR WebGPU frontend files as C++ byte arrays.")
    parser.add_argument("--web-dir", required=True, type=pathlib.Path)
    parser.add_argument("--out-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()

    web_dir = args.web_dir.resolve()
    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    files = [
        path for path in sorted(web_dir.rglob("*"))
        if path.is_file() and not path.name.startswith(".")
    ]

    header = out_dir / "GeneratedWebAssets.h"
    source = out_dir / "GeneratedWebAssets.cpp"

    header.write_text(textwrap.dedent("""\
        #pragma once

        #include <cstddef>
        #include <cstdint>

        struct EmbeddedWebAsset {
          const char* path;
          const char* contentType;
          const uint8_t* data;
          size_t size;
        };

        const EmbeddedWebAsset* findEmbeddedWebAsset(const char* path);
        const EmbeddedWebAsset* embeddedWebAssets();
        size_t embeddedWebAssetCount();
        """) + "\n" + COPYRIGHT_BLOCK_COMMENT, encoding="utf-8")

    source_lines = [
        '#include "GeneratedWebAssets.h"',
        "",
        "#include <cstring>",
        "",
        "namespace {",
        "",
    ]

    assets = []
    for file_path in files:
        relative = file_path.relative_to(web_dir)
        route_path = "/" + relative.as_posix()
        data = file_path.read_bytes()
        symbol = symbol_name(relative)
        content_type = CONTENT_TYPES.get(file_path.suffix.lower(), "application/octet-stream")
        source_lines.append(f"const uint8_t {symbol}[] = {{")
        source_lines.append(byte_array(data))
        source_lines.append("};")
        source_lines.append("")
        assets.append((route_path, content_type, symbol, len(data)))

    source_lines.append("const EmbeddedWebAsset kEmbeddedWebAssets[] = {")
    for route_path, content_type, symbol, size in assets:
        source_lines.append(f'  {{"{route_path}", "{content_type}", {symbol}, {size}}},')
    source_lines.append("};")
    source_lines.append("")
    source_lines.append("} // namespace")
    source_lines.append("")
    source_lines.append("const EmbeddedWebAsset* findEmbeddedWebAsset(const char* path) {")
    source_lines.append("  if (!path) return nullptr;")
    source_lines.append("  const char* lookupPath = (std::strcmp(path, \"/\") == 0) ? \"/index.html\" : path;")
    source_lines.append("  for (const auto& asset : kEmbeddedWebAssets) {")
    source_lines.append("    if (std::strcmp(asset.path, lookupPath) == 0) {")
    source_lines.append("      return &asset;")
    source_lines.append("    }")
    source_lines.append("  }")
    source_lines.append("  return nullptr;")
    source_lines.append("}")
    source_lines.append("")
    source_lines.append("const EmbeddedWebAsset* embeddedWebAssets() {")
    source_lines.append("  return kEmbeddedWebAssets;")
    source_lines.append("}")
    source_lines.append("")
    source_lines.append("size_t embeddedWebAssetCount() {")
    source_lines.append("  return sizeof(kEmbeddedWebAssets) / sizeof(kEmbeddedWebAssets[0]);")
    source_lines.append("}")
    source_lines.append("")
    source_lines.append(COPYRIGHT_BLOCK_COMMENT.rstrip())
    source.write_text("\n".join(source_lines), encoding="utf-8")


if __name__ == "__main__":
    main()

# Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
