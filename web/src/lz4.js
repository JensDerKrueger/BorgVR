export function decodeAppleLZ4(data, expectedLength) {
  if (data.byteLength >= 8 &&
      data[0] === 0x62 &&
      data[1] === 0x76 &&
      data[2] === 0x34 &&
      (data[3] === 0x31 || data[3] === 0x2d)) {
    return decodeAppleLZ4Stream(data, expectedLength);
  }

  return decodeLZ4Block(data, expectedLength);
}

export function encodeLZ4Block(data) {
  const source = data instanceof Uint8Array ? data : new Uint8Array(data);
  const output = [];
  const table = new Map();
  let anchor = 0;
  let position = 0;

  while (position + 4 <= source.byteLength) {
    const sequence = readUInt32LE(source, position);
    const reference = table.get(sequence);
    table.set(sequence, position);

    if (reference !== undefined &&
        position - reference <= 65535 &&
        source[reference] === source[position] &&
        source[reference + 1] === source[position + 1] &&
        source[reference + 2] === source[position + 2] &&
        source[reference + 3] === source[position + 3]) {
      let matchLength = 4;
      while (position + matchLength < source.byteLength &&
             source[reference + matchLength] === source[position + matchLength]) {
        matchLength += 1;
      }

      emitLZ4Sequence(output, source, anchor, position, position - reference, matchLength);
      const matchEnd = position + matchLength;
      for (let fill = position + 1; fill + 4 <= matchEnd; fill += 1) {
        table.set(readUInt32LE(source, fill), fill);
      }
      position = matchEnd;
      anchor = position;
      continue;
    }

    position += 1;
  }

  emitLZ4Sequence(output, source, anchor, source.byteLength, 0, 0);
  return new Uint8Array(output);
}

function decodeAppleLZ4Stream(data, expectedLength) {
  const output = new Uint8Array(expectedLength);
  let sourceOffset = 0;
  let outputOffset = 0;

  while (sourceOffset < data.byteLength) {
    if (sourceOffset + 4 <= data.byteLength &&
        data[sourceOffset] === 0x62 &&
        data[sourceOffset + 1] === 0x76 &&
        data[sourceOffset + 2] === 0x34 &&
        data[sourceOffset + 3] === 0x24) {
      sourceOffset += 4;
      break;
    }

    if (sourceOffset + 8 > data.byteLength ||
        data[sourceOffset] !== 0x62 ||
        data[sourceOffset + 1] !== 0x76 ||
        data[sourceOffset + 2] !== 0x34) {
      throw new Error("Invalid Apple LZ4 block header");
    }

    const blockType = data[sourceOffset + 3];
    const uncompressedLength = readUInt32LE(data, sourceOffset + 4);
    if (outputOffset + uncompressedLength > expectedLength) {
      throw new Error(`Apple LZ4 stream exceeds expected output size ${expectedLength}`);
    }

    if (blockType === 0x31) {
      if (sourceOffset + 12 > data.byteLength) {
        throw new Error("Apple LZ4 compressed block header is incomplete");
      }
      const compressedLength = readUInt32LE(data, sourceOffset + 8);
      sourceOffset += 12;

      if (sourceOffset + compressedLength > data.byteLength) {
        throw new Error("Apple LZ4 compressed block exceeds source size");
      }

      const decodedLength = decodeLZ4BlockInto(
        data.subarray(sourceOffset, sourceOffset + compressedLength),
        output,
        outputOffset,
        uncompressedLength
      );
      outputOffset += decodedLength;
      sourceOffset += compressedLength;
    } else if (blockType === 0x2d) {
      sourceOffset += 8;

      if (sourceOffset + uncompressedLength > data.byteLength) {
        throw new Error("Apple LZ4 raw block exceeds source size");
      }

      output.set(data.subarray(sourceOffset, sourceOffset + uncompressedLength), outputOffset);
      outputOffset += uncompressedLength;
      sourceOffset += uncompressedLength;
    } else {
      throw new Error("Invalid Apple LZ4 block type");
    }
  }

  if (outputOffset !== expectedLength) {
    throw new Error(`Apple LZ4 stream decoded ${outputOffset} bytes, expected ${expectedLength}`);
  }
  return output;
}

function decodeLZ4Block(source, expectedLength) {
  const output = new Uint8Array(expectedLength);
  decodeLZ4BlockInto(source, output, 0, expectedLength);
  return output;
}

function decodeLZ4BlockInto(source, output, startOffset, expectedLength) {
  let inputOffset = 0;
  let outputOffset = startOffset;
  const outputEnd = startOffset + expectedLength;

  const readLength = (initialLength) => {
    let length = initialLength;
    if (initialLength === 15) {
      while (inputOffset < source.byteLength) {
        const value = source[inputOffset];
        inputOffset += 1;
        length += value;
        if (value !== 255) {
          break;
        }
      }
    }
    return length;
  };

  while (inputOffset < source.byteLength && outputOffset < outputEnd) {
    const token = source[inputOffset];
    inputOffset += 1;

    const literalLength = readLength(token >> 4);
    if (inputOffset + literalLength > source.byteLength) {
      throw new Error("LZ4 literal run exceeds source size");
    }
    if (outputOffset + literalLength > outputEnd) {
      throw new Error("LZ4 literal run exceeds output size");
    }
    output.set(source.subarray(inputOffset, inputOffset + literalLength), outputOffset);
    inputOffset += literalLength;
    outputOffset += literalLength;

    if (inputOffset >= source.byteLength || outputOffset >= outputEnd) {
      break;
    }
    if (inputOffset + 2 > source.byteLength) {
      throw new Error("LZ4 block ends before match offset");
    }

    const offset = source[inputOffset] | (source[inputOffset + 1] << 8);
    inputOffset += 2;
    if (offset === 0 || offset > outputOffset) {
      throw new Error("LZ4 match offset is invalid");
    }

    const matchLength = readLength(token & 0x0f) + 4;
    if (outputOffset + matchLength > outputEnd) {
      throw new Error("LZ4 match exceeds output size");
    }

    let matchOffset = outputOffset - offset;
    for (let index = 0; index < matchLength; index += 1) {
      output[outputOffset] = output[matchOffset];
      outputOffset += 1;
      matchOffset += 1;
    }
  }

  if (outputOffset !== outputEnd) {
    throw new Error(`LZ4 decoded ${outputOffset - startOffset} bytes, expected ${expectedLength}`);
  }
  return expectedLength;
}

function readUInt32LE(data, offset) {
  return (data[offset] |
    (data[offset + 1] << 8) |
    (data[offset + 2] << 16) |
    (data[offset + 3] << 24)) >>> 0;
}

function emitLZ4Sequence(output, source, literalStart, literalEnd, matchOffset, matchLength) {
  const literalLength = literalEnd - literalStart;
  const matchTokenLength = matchLength > 0 ? matchLength - 4 : 0;
  output.push((Math.min(literalLength, 15) << 4) | Math.min(matchTokenLength, 15));

  if (literalLength >= 15) {
    emitLZ4Length(output, literalLength - 15);
  }

  for (let index = literalStart; index < literalEnd; index += 1) {
    output.push(source[index]);
  }

  if (matchLength <= 0) {
    return;
  }

  output.push(matchOffset & 0xff, (matchOffset >> 8) & 0xff);
  if (matchTokenLength >= 15) {
    emitLZ4Length(output, matchTokenLength - 15);
  }
}

function emitLZ4Length(output, length) {
  let remaining = length;
  while (remaining >= 255) {
    output.push(255);
    remaining -= 255;
  }
  output.push(remaining);
}

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
