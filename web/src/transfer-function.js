export function createDefaultTransferFunction(binCount = 256) {
  const tf = new TransferFunction1D(binCount);
  tf.smoothStep(0.1, 0.3, [0, 1, 2, 3]);
  return tf;
}

export class TransferFunction1D {
  constructor(binCount = 256) {
    this.width = binCount;
    this.data = new Uint8Array(binCount * 4);
    this.minVisibleIndex = -1;
    this.maxVisibleIndex = -1;
  }

  setSmoothStep(start, shift, channels, reverse = false) {
    this.smoothStep(start, shift, channels, reverse);
  }

  reset() {
    this.data.fill(0);
    this.setSmoothStep(0.1, 0.3, [0, 1, 2, 3]);
  }

  slicingPreset() {
    this.data.fill(0);
    this.smoothStep(0, 1, [0, 1, 2]);
    this.smoothStep(-1, 0.3, [3]);
  }

  smoothStep(start, shift, channels, reverse = false) {
    const invFactor1 = reverse ? -1 : 1;
    const invFactor2 = reverse ? 1 : 0;
    for (let index = 0; index < this.width; index += 1) {
      const position = index / Math.max(1, this.width - 1);
      const linearValue = shift === 0 ? 1 : clamp((position - start) / shift, 0, 1);
      const smoothValue = linearValue * linearValue * (3 - 2 * linearValue);
      const byteValue = Math.round(clamp(invFactor1 * (smoothValue - invFactor2), 0, 1) * 255);
      for (const channel of channels) {
        if (channel >= 0 && channel < 4) {
          this.data[index * 4 + channel] = byteValue;
        }
      }
    }
    this.updateVisibilityRange();
  }

  paintValue(position, value, channels, radius = 1) {
    if (channels.length === 0 || this.width === 0) {
      return;
    }
    const center = Math.round(clamp(position, 0, 1) * (this.width - 1));
    const byteValue = Math.round(clamp(value, 0, 1) * 255);
    const start = Math.max(0, center - radius);
    const end = Math.min(this.width - 1, center + radius);
    for (let index = start; index <= end; index += 1) {
      for (const channel of channels) {
        if (channel >= 0 && channel < 4) {
          this.data[index * 4 + channel] = byteValue;
        }
      }
    }
    this.updateVisibilityRange();
  }

  paintLine(startPosition, startValue, endPosition, endValue, channels, radius = 1) {
    if (channels.length === 0 || this.width === 0) {
      return;
    }
    const startIndex = Math.round(clamp(startPosition, 0, 1) * (this.width - 1));
    const endIndex = Math.round(clamp(endPosition, 0, 1) * (this.width - 1));
    const steps = Math.max(Math.abs(endIndex - startIndex), 1);
    for (let step = 0; step <= steps; step += 1) {
      const t = step / steps;
      this.paintValue(
        startPosition + (endPosition - startPosition) * t,
        startValue + (endValue - startValue) * t,
        channels,
        radius
      );
    }
  }

  updateVisibilityRange() {
    this.minVisibleIndex = -1;
    this.maxVisibleIndex = -1;
    for (let index = 0; index < this.width; index += 1) {
      if (this.data[index * 4 + 3] > 0) {
        if (this.minVisibleIndex < 0) {
          this.minVisibleIndex = index;
        }
        this.maxVisibleIndex = index;
      }
    }
  }

  isRangeEmpty(minValue, maxValue, rangeMax = 255) {
    if (this.minVisibleIndex < 0 || this.maxVisibleIndex < 0) {
      return true;
    }
    const maxVisibleValue = Math.ceil(this.maxVisibleIndex * rangeMax / Math.max(1, this.width - 1));
    const minVisibleValue = Math.floor(this.minVisibleIndex * rangeMax / Math.max(1, this.width - 1));
    return minValue > maxVisibleValue || maxValue < minVisibleValue;
  }

  isRangeFullyOpaque(minValue, maxValue, rangeMax = 255) {
    const minIndex = valueToIndex(minValue, rangeMax, this.width);
    const maxIndex = valueToIndex(maxValue, rangeMax, this.width);
    for (let index = minIndex; index <= maxIndex; index += 1) {
      if (this.data[index * 4 + 3] < 255) {
        return false;
      }
    }
    return true;
  }

  serializeNative() {
    const buffer = new ArrayBuffer(4 + this.data.byteLength);
    const view = new DataView(buffer);
    view.setUint32(0, this.width, true);
    new Uint8Array(buffer, 4).set(this.data);
    return buffer;
  }

  loadNative(buffer) {
    const source = buffer instanceof ArrayBuffer
      ? buffer
      : buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
    if (source.byteLength < 4) {
      throw new Error("Transfer function file is too small.");
    }

    const view = new DataView(source);
    const count = view.getUint32(0, true);
    if (count === 0) {
      throw new Error("Transfer function file contains no entries.");
    }
    const expectedSize = 4 + count * 4;
    if (source.byteLength < expectedSize) {
      throw new Error(`Transfer function file is incomplete: expected ${expectedSize} bytes, found ${source.byteLength}.`);
    }

    this.width = count;
    this.data = new Uint8Array(count * 4);
    this.data.set(new Uint8Array(source, 4, count * 4));
    this.updateVisibilityRange();
  }
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function valueToIndex(value, rangeMax, width) {
  return Math.min(width - 1, Math.max(0, Math.round(value * (width - 1) / Math.max(1, rangeMax))));
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
