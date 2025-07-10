#ifndef GPUHashtable_h
#define GPUHashtable_h

#include <metal_stdlib>
#import "ShaderTypes.h"

using namespace metal;


/**
 A simple hash function using Knuth’s multiplicative method.

 - Parameter value: The input value to hash.
 - Returns: A hashed unsigned integer.
 */
uint simpleHash(uint value) {
  return (value * 2654435761u);
}

/**
 Reports a missing brick by inserting its index into a GPU-side atomic hash table.

 Uses atomic compare-and-swap with linear probing to handle collisions,
 retrying up to MAX_PROBING_ATTEMPTS times.

 - Parameters:
 - brickIndex: The index of the missing brick to record.
 - atomicBuffer: A device pointer to an array of `atomic_uint` representing the hash table.
 */
void reportMissingBrick(uint brickIndex, device atomic_uint* atomicBuffer) {
  // Compute the initial hash slot index using modulo table size.
  uint hashIndex = simpleHash(brickIndex) % HASHTABLE_SIZE;

  // Perform linear probing to resolve collisions.
  for (uint i = 0; i < MAX_PROBING_ATTEMPTS; ++i) {
    uint slot = (hashIndex + i) % HASHTABLE_SIZE;
    // Expect an empty slot marked by 0xFFFFFFFFu.
    uint expected = 0xFFFFFFFFu;
    // Attempt to atomically replace the empty marker with brickIndex.
    if (atomic_compare_exchange_weak_explicit(&atomicBuffer[slot],
                                              &expected,
                                              brickIndex,
                                              memory_order_relaxed,
                                              memory_order_relaxed)) {
      // Successfully stored the brickIndex.
      break;
    } else if (expected == brickIndex) {
      // The brickIndex is already present in this slot; no further action needed.
      break;
    }
    // Otherwise, continue probing the next slot.
  }
}

#endif  // GPUHashtable_h

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
