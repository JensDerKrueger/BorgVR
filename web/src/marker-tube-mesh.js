const RADIAL_SEGMENT_COUNT = 12;
const MARKER_RADIUS_SCALE = 1.36;
const MAXIMUM_TUBE_VERTEX_COUNT = 500_000;

export function buildMarkerRenderGeometry(markers, volumeHalfExtent) {
  const sphereInstances = [];
  const tubeSources = [];

  for (const marker of markers) {
    const points = Array.isArray(marker.points) ? marker.points : [];
    if (marker.type !== "stroke") {
      if (points[0]) {
        sphereInstances.push(sphereInstance(points[0], marker.color, volumeHalfExtent));
      }
      continue;
    }

    if (points[0]) {
      sphereInstances.push(sphereInstance(points[0], marker.color, volumeHalfExtent));
    }
    if (points.length > 1) {
      sphereInstances.push(sphereInstance(points[points.length - 1], marker.color, volumeHalfExtent));
      const preparedCurve = prepareCurve(points, volumeHalfExtent);
      tubeSources.push({
        color: marker.color,
        preparedCurve,
        desiredRingCount: desiredRingCount(preparedCurve)
      });
    }
  }

  const maximumRingCount = Math.floor(MAXIMUM_TUBE_VERTEX_COUNT / RADIAL_SEGMENT_COUNT);
  let remainingRings = maximumRingCount;
  let remainingDesiredRings = tubeSources.reduce(
    (sum, source) => sum + source.desiredRingCount,
    0
  );
  const tubes = [];

  for (let index = 0; index < tubeSources.length; index += 1) {
    const source = tubeSources[index];
    const remainingSourceCount = tubeSources.length - index;
    const reservedForLater = Math.min(
      remainingRings,
      Math.max(0, remainingSourceCount - 1) * 2
    );
    const proportionalRingCount = remainingDesiredRings > 0
      ? Math.floor(remainingRings * source.desiredRingCount / remainingDesiredRings)
      : 0;
    const ringBudget = Math.min(
      source.desiredRingCount,
      Math.max(2, proportionalRingCount),
      Math.max(0, remainingRings - reservedForLater)
    );
    remainingDesiredRings -= source.desiredRingCount;
    if (ringBudget < 2) {
      continue;
    }

    const curve = smoothCurve(source.preparedCurve, ringBudget);
    const mesh = generateTube(curve);
    if (mesh.vertexCount === 0) {
      continue;
    }
    tubes.push({ ...mesh, color: source.color });
    remainingRings -= mesh.vertexCount / RADIAL_SEGMENT_COUNT;
  }

  const totalVertexCount = tubes.reduce((sum, tube) => sum + tube.vertexCount, 0);
  const totalIndexCount = tubes.reduce((sum, tube) => sum + tube.indexCount, 0);
  const tubeVertices = new Float32Array(totalVertexCount * 6);
  const tubeIndices = new Uint32Array(totalIndexCount);
  const tubeDraws = [];
  let vertexFloatOffset = 0;
  let vertexOffset = 0;
  let indexOffset = 0;

  for (const tube of tubes) {
    tubeVertices.set(tube.vertices, vertexFloatOffset);
    for (let index = 0; index < tube.indices.length; index += 1) {
      tubeIndices[indexOffset + index] = tube.indices[index] + vertexOffset;
    }
    tubeDraws.push({
      firstIndex: indexOffset,
      indexCount: tube.indexCount,
      color: tube.color
    });
    vertexFloatOffset += tube.vertices.length;
    vertexOffset += tube.vertexCount;
    indexOffset += tube.indexCount;
  }

  return { sphereInstances, tubeVertices, tubeIndices, tubeDraws };
}

function sphereInstance(point, color, volumeHalfExtent) {
  return {
    centerRadius: [
      (point.position[0] - 0.5) * 2 * volumeHalfExtent[0],
      (point.position[1] - 0.5) * 2 * volumeHalfExtent[1],
      (point.position[2] - 0.5) * 2 * volumeHalfExtent[2],
      point.radius * MARKER_RADIUS_SCALE
    ],
    color
  };
}

function prepareCurve(points, volumeHalfExtent) {
  return points.map((point) => ({
    position: [
      (point.position[0] - 0.5) * 2 * volumeHalfExtent[0],
      (point.position[1] - 0.5) * 2 * volumeHalfExtent[1],
      (point.position[2] - 0.5) * 2 * volumeHalfExtent[2]
    ],
    radius: Math.max(point.radius * MARKER_RADIUS_SCALE, 0.0001)
  }));
}

function desiredRingCount(points) {
  let count = 1;
  for (let index = 0; index < points.length - 1; index += 1) {
    const segmentLength = distance(points[index].position, points[index + 1].position);
    const averageRadius = Math.max(
      (points[index].radius + points[index + 1].radius) * 0.5,
      0.0001
    );
    count += Math.min(8, Math.max(2, Math.ceil(segmentLength / (averageRadius * 0.4))));
  }
  return count;
}

function smoothCurve(points, maximumRingCount) {
  const desiredCount = desiredRingCount(points);
  const sampleStride = Math.max(1, desiredCount / maximumRingCount);
  let nextSample = 0;
  let sampleIndex = 0;
  const result = [];

  for (let index = 0; index < points.length - 1; index += 1) {
    const p1 = points[index];
    const p2 = points[index + 1];
    const p0 = index > 0
      ? points[index - 1]
      : curvePoint(
        subtract(scale(p1.position, 2), p2.position),
        p1.radius
      );
    const p3 = index + 2 < points.length
      ? points[index + 2]
      : curvePoint(
        subtract(scale(p2.position, 2), p1.position),
        p2.radius
      );
    const segmentLength = distance(p1.position, p2.position);
    const averageRadius = Math.max((p1.radius + p2.radius) * 0.5, 0.0001);
    const subdivisions = Math.min(
      8,
      Math.max(2, Math.ceil(segmentLength / (averageRadius * 0.4)))
    );

    for (let step = 0; step < subdivisions; step += 1) {
      if (sampleIndex + 0.000001 >= nextSample) {
        const t = step / subdivisions;
        result.push(curvePoint(
          centripetalCatmullRom(p0.position, p1.position, p2.position, p3.position, t),
          p1.radius + (p2.radius - p1.radius) * t
        ));
        nextSample += sampleStride;
      }
      sampleIndex += 1;
    }
  }

  const last = points[points.length - 1];
  const previous = result[result.length - 1];
  if (!previous || distance(previous.position, last.position) > 0.000001) {
    result.push(last);
  } else {
    result[result.length - 1] = last;
  }
  if (result.length > maximumRingCount) {
    result.splice(maximumRingCount - 1, result.length - maximumRingCount, last);
  }
  return result;
}

function generateTube(curve) {
  if (curve.length < 2) {
    return emptyTube();
  }

  const tangents = curve.map((point, index) => {
    const previous = curve[Math.max(0, index - 1)].position;
    const next = curve[Math.min(curve.length - 1, index + 1)].position;
    return normalize(subtract(next, previous), [0, 0, 1]);
  });

  const ringNormals = [];
  let frameNormal = initialNormal(tangents[0]);
  let previousTangent = tangents[0];
  for (const tangent of tangents) {
    frameNormal = transportedNormal(frameNormal, previousTangent, tangent);
    const frameBinormal = normalize(cross(tangent, frameNormal), [1, 0, 0]);
    frameNormal = normalize(cross(frameBinormal, tangent), frameNormal);
    const normals = [];
    for (let segment = 0; segment < RADIAL_SEGMENT_COUNT; segment += 1) {
      const angle = segment * 2 * Math.PI / RADIAL_SEGMENT_COUNT;
      normals.push(add(
        scale(frameNormal, Math.cos(angle)),
        scale(frameBinormal, Math.sin(angle))
      ));
    }
    ringNormals.push(normals);
    previousTangent = tangent;
  }

  const vertexCount = curve.length * RADIAL_SEGMENT_COUNT;
  const vertices = new Float32Array(vertexCount * 6);
  let vertexOffset = 0;
  for (let ring = 0; ring < curve.length; ring += 1) {
    for (let segment = 0; segment < RADIAL_SEGMENT_COUNT; segment += 1) {
      const normal = ringNormals[ring][segment];
      const position = add(curve[ring].position, scale(normal, curve[ring].radius));
      vertices.set(position, vertexOffset);
      vertices.set(normal, vertexOffset + 3);
      vertexOffset += 6;
    }
  }

  const indexCount = (curve.length - 1) * RADIAL_SEGMENT_COUNT * 6;
  const indices = new Uint32Array(indexCount);
  let indexOffset = 0;
  for (let ring = 0; ring < curve.length - 1; ring += 1) {
    for (let segment = 0; segment < RADIAL_SEGMENT_COUNT; segment += 1) {
      const nextSegment = (segment + 1) % RADIAL_SEGMENT_COUNT;
      const current = ring * RADIAL_SEGMENT_COUNT + segment;
      const currentNext = ring * RADIAL_SEGMENT_COUNT + nextSegment;
      const next = (ring + 1) * RADIAL_SEGMENT_COUNT + segment;
      const nextNext = (ring + 1) * RADIAL_SEGMENT_COUNT + nextSegment;
      indices.set([current, nextNext, next, current, currentNext, nextNext], indexOffset);
      indexOffset += 6;
    }
  }
  return { vertices, indices, vertexCount, indexCount };
}

function emptyTube() {
  return {
    vertices: new Float32Array(0),
    indices: new Uint32Array(0),
    vertexCount: 0,
    indexCount: 0
  };
}

function curvePoint(position, radius) {
  return { position, radius };
}

function centripetalCatmullRom(p0, p1, p2, p3, t) {
  if (distance(p1, p2) <= 0.000001) {
    return p1;
  }
  const t0 = 0;
  const t1 = nextKnot(t0, p0, p1);
  const t2 = nextKnot(t1, p1, p2);
  const t3 = nextKnot(t2, p2, p3);
  const value = t1 + (t2 - t1) * t;
  const a1 = interpolate(p0, p1, t0, t1, value);
  const a2 = interpolate(p1, p2, t1, t2, value);
  const a3 = interpolate(p2, p3, t2, t3, value);
  const b1 = interpolate(a1, a2, t0, t2, value);
  const b2 = interpolate(a2, a3, t1, t3, value);
  return interpolate(b1, b2, t1, t2, value);
}

function nextKnot(knot, a, b) {
  return knot + Math.sqrt(Math.max(distance(a, b), 0.000001));
}

function interpolate(a, b, start, end, value) {
  const span = Math.max(end - start, 0.000001);
  return add(scale(a, (end - value) / span), scale(b, (value - start) / span));
}

function initialNormal(tangent) {
  const reference = Math.abs(tangent[1]) < 0.9 ? [0, 1, 0] : [1, 0, 0];
  return normalize(cross(reference, tangent), [1, 0, 0]);
}

function transportedNormal(normal, oldTangent, newTangent) {
  const rotationAxis = cross(oldTangent, newTangent);
  const axisLength = length(rotationAxis);
  if (axisLength <= 0.00001) {
    return normalize(
      subtract(normal, scale(newTangent, dot(normal, newTangent))),
      normal
    );
  }
  const axis = scale(rotationAxis, 1 / axisLength);
  const angle = Math.atan2(axisLength, dot(oldTangent, newTangent));
  const cosine = Math.cos(angle);
  const sine = Math.sin(angle);
  return add(
    add(scale(normal, cosine), scale(cross(axis, normal), sine)),
    scale(axis, dot(axis, normal) * (1 - cosine))
  );
}

function add(a, b) {
  return [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
}

function subtract(a, b) {
  return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

function scale(value, factor) {
  return [value[0] * factor, value[1] * factor, value[2] * factor];
}

function dot(a, b) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

function cross(a, b) {
  return [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0]
  ];
}

function length(value) {
  return Math.hypot(value[0], value[1], value[2]);
}

function distance(a, b) {
  return length(subtract(a, b));
}

function normalize(value, fallback) {
  const magnitude = length(value);
  return magnitude > 0.000001 ? scale(value, 1 / magnitude) : [...fallback];
}
