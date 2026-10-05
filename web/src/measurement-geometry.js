const COLORS = {
  length: [1.0, 0.72, 0.12, 1],
  area: [0.10, 0.78, 0.92, 1],
  volume: [0.82, 0.30, 0.95, 1]
};

export function buildMeasurementGeometry(measurements, physicalExtent) {
  const extent = safeExtent(physicalExtent);
  return measurements.map((measurement) => geometryForMeasurement(measurement, extent));
}

export function formatMeasurementValue(kind, value) {
  if (!Number.isFinite(value)) {
    return "Incomplete";
  }
  const dimensions = kind === "length" ? 1 : kind === "area" ? 2 : 3;
  const choices = dimensions === 1
    ? [[1e12, "pm"], [1e9, "nm"], [1e6, "µm"], [1e3, "mm"], [1e2, "cm"], [1, "m"], [1e-3, "km"]]
    : dimensions === 2
      ? [[1e24, "pm²"], [1e18, "nm²"], [1e12, "µm²"], [1e6, "mm²"], [1e4, "cm²"], [1, "m²"], [1e-6, "km²"]]
      : [[1e36, "pm³"], [1e27, "nm³"], [1e18, "µm³"], [1e9, "mm³"], [1e6, "cm³"], [1e3, "L"], [1, "m³"], [1e-9, "km³"]];
  const absolute = Math.abs(value);
  let choice = choices.find(([factor]) => absolute * factor >= 0.01 && absolute * factor < 1000);
  choice ??= absolute === 0 ? choices[choices.length - 2] : choices[absolute < 1 ? 0 : choices.length - 1];
  const scaled = value * choice[0];
  return `${new Intl.NumberFormat(undefined, { maximumSignificantDigits: 4 }).format(scaled)} ${choice[1]}`;
}

function geometryForMeasurement(measurement, extent) {
  const color = COLORS[measurement.kind] ?? COLORS.length;
  if (measurement.kind === "area") {
    return areaGeometry(measurement, extent, color);
  }
  if (measurement.kind === "volume") {
    return volumeGeometry(measurement, extent, color);
  }
  return lengthGeometry(measurement, extent, color);
}

function lengthGeometry(measurement, extent, color) {
  const edges = [];
  let value = 0;
  for (let index = 1; index < measurement.points.length; index += 1) {
    const start = measurement.points[index - 1].position;
    const end = measurement.points[index].position;
    edges.push({ start, end });
    value += distance(multiplyComponents(subtract(end, start), extent));
  }
  return baseGeometry(measurement, color, edges, [], edges.length > 0 ? value : null);
}

function areaGeometry(measurement, extent, color) {
  const points = measurement.points;
  if (points.length < 3) {
    const edges = points.length === 2 ? [{ start: points[0].position, end: points[1].position }] : [];
    return baseGeometry(measurement, color, edges, [], null);
  }
  const physical = points.map((point) => multiplyComponents(point.position, extent));
  const characteristic = Math.max(...extent);
  const firstEdge = scale(subtract(physical[1], physical[0]), 1 / characteristic);
  const secondEdge = scale(subtract(physical[2], physical[0]), 1 / characteristic);
  const normal = normalize(cross(firstEdge, secondEdge));
  const u = normalize(firstEdge);
  const v = normalize(cross(normal, u));
  if (!normal || !u || !v) {
    return baseGeometry(measurement, color, [], [], null);
  }
  const projectedPhysical = physical.map((point) => {
    const offset = subtract(point, physical[0]);
    return subtract(point, scale(normal, dot(offset, normal)));
  });
  const projected2D = projectedPhysical.map((point) => {
    const offset = subtract(point, physical[0]);
    return [dot(offset, u), dot(offset, v)];
  });
  const hull = convexHull2D(projected2D.map((point) => point.map((value) => value / characteristic)));
  if (hull.length < 3) {
    return baseGeometry(measurement, color, [], [], null);
  }
  const displayPoints = projectedPhysical.map((point, index) => ({
    id: points[index].id,
    position: divideComponents(point, extent)
  }));
  const edges = hull.map((pointIndex, index) => ({
    start: displayPoints[pointIndex].position,
    end: displayPoints[hull[(index + 1) % hull.length]].position
  }));
  const triangles = [];
  for (let index = 1; index < hull.length - 1; index += 1) {
    triangles.push(
      displayPoints[hull[0]].position,
      displayPoints[hull[index]].position,
      displayPoints[hull[index + 1]].position
    );
  }
  let signedArea = 0;
  for (let index = 0; index < hull.length; index += 1) {
    const a = projected2D[hull[index]];
    const b = projected2D[hull[(index + 1) % hull.length]];
    signedArea += a[0] * b[1] - b[0] * a[1];
  }
  return {
    ...baseGeometry(measurement, color, edges, triangles, Math.abs(signedArea) * 0.5),
    points: displayPoints
  };
}

function volumeGeometry(measurement, extent, color) {
  const points = measurement.points;
  const physical = points.map((point) => multiplyComponents(point.position, extent));
  const characteristic = Math.max(...extent);
  const faces = convexHull3D(physical.map((point) => scale(point, 1 / characteristic)));
  if (!faces) {
    const edges = points.slice(1).map((point, index) => ({
      start: points[index].position,
      end: point.position
    }));
    if (points.length >= 3) {
      edges.push({ start: points[points.length - 1].position, end: points[0].position });
    }
    return baseGeometry(measurement, color, edges, [], null);
  }
  const edgeKeys = new Set();
  const edges = [];
  const triangles = [];
  let signedVolume = 0;
  for (const face of faces) {
    const indices = [face.a, face.b, face.c];
    triangles.push(...indices.map((index) => points[index].position));
    const [a, b, c] = indices.map((index) => physical[index]);
    signedVolume += dot(a, cross(b, c)) / 6;
    for (const [start, end] of [[face.a, face.b], [face.b, face.c], [face.c, face.a]]) {
      const low = Math.min(start, end);
      const high = Math.max(start, end);
      const key = `${low}:${high}`;
      if (!edgeKeys.has(key)) {
        edgeKeys.add(key);
        edges.push({ start: points[low].position, end: points[high].position });
      }
    }
  }
  return baseGeometry(measurement, color, edges, triangles, Math.abs(signedVolume));
}

function baseGeometry(measurement, color, edges, triangles, value) {
  return {
    id: measurement.id,
    name: measurement.name,
    kind: measurement.kind,
    color,
    points: measurement.points,
    edges,
    triangles,
    value
  };
}

function convexHull2D(points) {
  if (points.length < 3) {
    return [];
  }
  const sorted = points.map((_, index) => index).sort((a, b) =>
    points[a][0] === points[b][0] ? points[a][1] - points[b][1] : points[a][0] - points[b][0]
  );
  const turn = (o, a, b) => {
    const oa = subtract2(points[a], points[o]);
    const ob = subtract2(points[b], points[o]);
    return oa[0] * ob[1] - oa[1] * ob[0];
  };
  const half = (indices) => {
    const result = [];
    for (const index of indices) {
      while (result.length >= 2 && turn(result[result.length - 2], result[result.length - 1], index) <= 1e-10) {
        result.pop();
      }
      result.push(index);
    }
    result.pop();
    return result;
  };
  return [...half(sorted), ...half([...sorted].reverse())];
}

function convexHull3D(points) {
  if (points.length < 4 || points.some((point) => !point.every(Number.isFinite))) {
    return null;
  }
  const minimum = [Infinity, Infinity, Infinity];
  const maximum = [-Infinity, -Infinity, -Infinity];
  for (const point of points) {
    for (let axis = 0; axis < 3; axis += 1) {
      minimum[axis] = Math.min(minimum[axis], point[axis]);
      maximum[axis] = Math.max(maximum[axis], point[axis]);
    }
  }
  const diagonal = distance(subtract(maximum, minimum));
  if (!Number.isFinite(diagonal) || diagonal <= Number.MIN_VALUE) {
    return null;
  }
  const epsilon = Math.max(diagonal * 1e-6, 1e-7);
  let first = 0;
  for (let index = 1; index < points.length; index += 1) {
    if (points[index][0] < points[first][0]) first = index;
  }
  let second = first;
  for (let index = 0; index < points.length; index += 1) {
    if (distanceSquared(points[index], points[first]) > distanceSquared(points[second], points[first])) second = index;
  }
  if (first === second) return null;
  const baseline = subtract(points[second], points[first]);
  const baselineLength = distance(baseline);
  let third = -1;
  let thirdScore = -1;
  for (let index = 0; index < points.length; index += 1) {
    if (index === first || index === second) continue;
    const score = distanceSquared(cross(baseline, subtract(points[index], points[first])), [0, 0, 0]);
    if (score > thirdScore) {
      thirdScore = score;
      third = index;
    }
  }
  if (third < 0) return null;
  const initialNormal = cross(subtract(points[second], points[first]), subtract(points[third], points[first]));
  const normalLength = distance(initialNormal);
  if (!Number.isFinite(normalLength) || normalLength / baselineLength <= epsilon) return null;
  let fourth = -1;
  let fourthScore = -1;
  for (let index = 0; index < points.length; index += 1) {
    if (index === first || index === second || index === third) continue;
    const score = Math.abs(dot(initialNormal, subtract(points[index], points[first])));
    if (score > fourthScore) {
      fourthScore = score;
      fourth = index;
    }
  }
  if (fourth < 0 || fourthScore / normalLength <= epsilon) return null;

  const interior = scale(add(add(points[first], points[second]), add(points[third], points[fourth])), 0.25);
  const oriented = (a, b, c) => dot(cross(subtract(points[b], points[a]), subtract(points[c], points[a])), subtract(interior, points[a])) > 0
    ? { a, b: c, c: b }
    : { a, b, c };
  let faces = [
    oriented(first, second, third),
    oriented(first, fourth, second),
    oriented(second, fourth, third),
    oriented(third, fourth, first)
  ];
  const initial = new Set([first, second, third, fourth]);
  for (let pointIndex = 0; pointIndex < points.length; pointIndex += 1) {
    if (initial.has(pointIndex)) continue;
    const visible = new Set();
    faces.forEach((face, faceIndex) => {
      const normal = cross(subtract(points[face.b], points[face.a]), subtract(points[face.c], points[face.a]));
      const normalLength = distance(normal);
      const signedDistance = normalLength > epsilon
        ? dot(normal, subtract(points[pointIndex], points[face.a])) / normalLength
        : -Infinity;
      if (Number.isFinite(signedDistance) && signedDistance > epsilon) visible.add(faceIndex);
    });
    if (visible.size === 0) continue;
    const boundary = new Map();
    for (const faceIndex of visible) {
      const face = faces[faceIndex];
      for (const [a, b] of [[face.a, face.b], [face.b, face.c], [face.c, face.a]]) {
        const key = `${Math.min(a, b)}:${Math.max(a, b)}`;
        const value = boundary.get(key);
        boundary.set(key, value ? { ...value, count: value.count + 1 } : { a, b, count: 1 });
      }
    }
    faces = faces.filter((_, index) => !visible.has(index));
    for (const edge of boundary.values()) {
      if (edge.count === 1) faces.push(oriented(edge.a, edge.b, pointIndex));
    }
  }
  faces = faces.filter((face) => distance(cross(
    subtract(points[face.b], points[face.a]),
    subtract(points[face.c], points[face.a])
  )) > epsilon);
  return faces.length > 0 ? faces : null;
}

function safeExtent(extent) {
  return Array.from({ length: 3 }, (_, index) => Math.max(Math.abs(Number(extent?.[index]) || 0), 1e-12));
}

function add(a, b) { return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]; }
function subtract(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
function subtract2(a, b) { return [a[0] - b[0], a[1] - b[1]]; }
function scale(a, value) { return [a[0] * value, a[1] * value, a[2] * value]; }
function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
function cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
function distance(a) { return Math.hypot(a[0], a[1], a[2]); }
function distanceSquared(a, b) { const delta = subtract(a, b); return dot(delta, delta); }
function normalize(a) { const value = distance(a); return Number.isFinite(value) && value > 1e-12 ? scale(a, 1 / value) : null; }
function multiplyComponents(a, b) { return [a[0] * b[0], a[1] * b[1], a[2] * b[2]]; }
function divideComponents(a, b) { return [a[0] / b[0], a[1] / b[1], a[2] / b[2]]; }
