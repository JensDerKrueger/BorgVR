import {
  MARKER_FILE_HEADER_BYTES,
  MARKER_FILE_MAGIC,
  MARKER_FILE_VERSION,
  MARKER_POSITION_FALLBACK,
  MARKER_POSITION_MAXIMUM,
  MARKER_POSITION_MINIMUM,
  MAX_MARKER_COUNT,
  MAX_MARKER_FILE_BYTES,
  MAX_MARKER_NAME_BYTES,
  MAX_MARKER_NAME_CHARACTERS,
  MAX_MARKER_POINT_COUNT,
  MAX_MESH_DESCRIPTION_BYTES,
  MAX_MESH_FILE_BYTES,
  MAX_MESH_INDEX_COUNT,
  MAX_MESH_INSTANCE_COUNT,
  MAX_MESH_NAME_BYTES,
  MAX_MESH_TEXTURE_BYTES,
  MAX_MESH_VERTEX_COUNT,
  MAX_MEASUREMENT_COUNT,
  MAX_MEASUREMENT_FILE_BYTES,
  MAX_MEASUREMENT_NAME_BYTES,
  MAX_MEASUREMENT_NAME_CHARACTERS,
  MAX_MEASUREMENT_POINT_COUNT,
  MEASUREMENT_FILE_MAGIC,
  MEASUREMENT_FILE_VERSION,
  MESH_FILE_MAGIC,
  MESH_FILE_VERSION,
  SPHERE_RADIUS_DEFAULT,
  SPHERE_RADIUS_MAXIMUM,
  SPHERE_RADIUS_MINIMUM,
  STROKE_RADIUS_DEFAULT,
  STROKE_RADIUS_MAXIMUM,
  STROKE_RADIUS_MINIMUM
} from "./format-constants.js?v=20261005-annotations";

const textDecoder = new TextDecoder("utf-8", { fatal: true });
const asciiDecoder = new TextDecoder("ascii", { fatal: true });

class BinaryReader {
  constructor(buffer, maximumByteCount, label) {
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength <= 0 || buffer.byteLength > maximumByteCount) {
      throw new Error(`${label} exceeds the supported size limit.`);
    }
    this.buffer = buffer;
    this.bytes = new Uint8Array(buffer);
    this.view = new DataView(buffer);
    this.offset = 0;
    this.label = label;
  }

  require(count) {
    if (!Number.isInteger(count) || count < 0 || this.offset + count > this.buffer.byteLength) {
      throw new Error(`${this.label} is incomplete.`);
    }
  }

  uint8() {
    this.require(1);
    return this.view.getUint8(this.offset++);
  }

  uint16() {
    this.require(2);
    const value = this.view.getUint16(this.offset, true);
    this.offset += 2;
    return value;
  }

  uint32() {
    this.require(4);
    const value = this.view.getUint32(this.offset, true);
    this.offset += 4;
    return value;
  }

  float32() {
    this.require(4);
    const value = this.view.getFloat32(this.offset, true);
    this.offset += 4;
    return value;
  }

  vector(count) {
    return Array.from({ length: count }, () => this.float32());
  }

  uuid() {
    const data = this.data(16);
    const hex = Array.from(data, (value) => value.toString(16).padStart(2, "0"));
    return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10).join("")}`;
  }

  data(count) {
    this.require(count);
    const value = this.bytes.slice(this.offset, this.offset + count);
    this.offset += count;
    return value;
  }

  string(maximumByteCount) {
    const byteCount = this.uint16();
    if (byteCount > maximumByteCount) {
      throw new Error(`${this.label} contains text that exceeds the supported length.`);
    }
    return textDecoder.decode(this.data(byteCount));
  }

  magic(expected) {
    const actual = asciiDecoder.decode(this.data(expected.length));
    if (actual !== expected) {
      throw new Error(`${this.label} has an invalid file signature.`);
    }
  }

  finish() {
    if (this.offset !== this.buffer.byteLength) {
      throw new Error(`${this.label} contains unexpected trailing data.`);
    }
  }
}

export function parseMarkerFile(buffer) {
  const reader = new BinaryReader(buffer, MAX_MARKER_FILE_BYTES, "The marker file");
  reader.require(MARKER_FILE_HEADER_BYTES);
  reader.magic(MARKER_FILE_MAGIC);
  const version = reader.uint16();
  reader.uint16();
  if (version !== MARKER_FILE_VERSION) {
    throw new Error(`Unsupported marker file version ${version}.`);
  }
  const datasetID = reader.uuid();
  const markerCount = reader.uint32();
  if (markerCount > MAX_MARKER_COUNT) {
    throw new Error("The marker file contains too many markers.");
  }

  const markers = [];
  let totalPointCount = 0;
  for (let markerIndex = 0; markerIndex < markerCount; markerIndex += 1) {
    const typeValue = reader.uint8();
    const flags = reader.uint8();
    reader.uint16();
    if (typeValue !== 1 && typeValue !== 2) {
      throw new Error(`Marker ${markerIndex + 1} has an unsupported geometry type.`);
    }
    const id = reader.uuid();
    const rawName = reader.string(MAX_MARKER_NAME_BYTES).trim();
    const color = reader.vector(4).map((value, index) => finiteClamped(value, index === 0 || index === 3 ? 1 : 0, 0, 1));
    const pointCount = reader.uint32();
    totalPointCount += pointCount;
    if (pointCount === 0 || (typeValue === 1 && pointCount !== 1) || totalPointCount > MAX_MARKER_POINT_COUNT) {
      throw new Error(`Marker ${markerIndex + 1} has invalid or excessive geometry.`);
    }
    const radiusFallback = typeValue === 1 ? SPHERE_RADIUS_DEFAULT : STROKE_RADIUS_DEFAULT;
    const radiusMinimum = typeValue === 1 ? SPHERE_RADIUS_MINIMUM : STROKE_RADIUS_MINIMUM;
    const radiusMaximum = typeValue === 1 ? SPHERE_RADIUS_MAXIMUM : STROKE_RADIUS_MAXIMUM;
    const points = Array.from({ length: pointCount }, () => ({
      position: reader.vector(3).map((value) => finiteClamped(
        value,
        MARKER_POSITION_FALLBACK,
        MARKER_POSITION_MINIMUM,
        MARKER_POSITION_MAXIMUM
      )),
      radius: finiteClamped(reader.float32(), radiusFallback, radiusMinimum, radiusMaximum)
    }));
    const directionOrigin = typeValue === 1
      ? reader.vector(3).map((value) => finiteClamped(
          value,
          MARKER_POSITION_FALLBACK,
          MARKER_POSITION_MINIMUM,
          MARKER_POSITION_MAXIMUM
        ))
      : null;
    markers.push({
      id,
      name: (rawName || `Marker ${markerIndex + 1}`).slice(0, MAX_MARKER_NAME_CHARACTERS),
      type: typeValue === 1 ? "sphere" : "stroke",
      color,
      points,
      directionOrigin,
      showsDirection: typeValue === 1 && (flags & 1) !== 0
    });
  }

  const instanceCount = reader.uint32();
  if (instanceCount > MAX_MESH_INSTANCE_COUNT) {
    throw new Error("The marker file contains too many object instances.");
  }
  const meshInstances = [];
  for (let index = 0; index < instanceCount; index += 1) {
    const id = reader.uuid();
    const assetID = reader.uuid();
    const name = reader.string(MAX_MESH_NAME_BYTES).trim();
    const assetName = reader.string(MAX_MESH_NAME_BYTES).trim();
    const assetDescription = reader.string(MAX_MESH_DESCRIPTION_BYTES).trim();
    const boundsMinimum = finiteVector(reader.vector(3), `Object ${index + 1} has invalid bounds.`);
    const boundsMaximum = finiteVector(reader.vector(3), `Object ${index + 1} has invalid bounds.`);
    const translationMeters = finiteVector(reader.vector(3), `Object ${index + 1} has an invalid translation.`);
    const rotation = normalizedQuaternion(
      finiteVector(reader.vector(4), `Object ${index + 1} has an invalid rotation.`)
    );
    const scale = finiteVector(reader.vector(3), `Object ${index + 1} has an invalid scale.`)
      .map((value) => Math.min(1_000_000, Math.max(0.000001, Math.abs(value))));
    const flags = reader.uint8();
    reader.uint8();
    reader.uint16();
    meshInstances.push({
      id,
      assetID,
      name: name || `Object ${index + 1}`,
      assetName: assetName || "Object",
      assetDescription,
      boundsMinimum,
      boundsMaximum,
      translationMeters,
      rotation,
      scale,
      visible: (flags & 1) !== 0
    });
  }
  reader.finish();
  return { datasetID, markers, meshInstances };
}

export function parseMeshFile(buffer) {
  const reader = new BinaryReader(buffer, MAX_MESH_FILE_BYTES, "The object file");
  reader.magic(MESH_FILE_MAGIC);
  const version = reader.uint16();
  reader.uint16();
  if (version !== MESH_FILE_VERSION) {
    throw new Error(`Unsupported object file version ${version}.`);
  }
  const id = reader.uuid();
  const nameByteCount = reader.uint16();
  const descriptionByteCount = reader.uint16();
  if (nameByteCount > MAX_MESH_NAME_BYTES || descriptionByteCount > MAX_MESH_DESCRIPTION_BYTES) {
    throw new Error("The object metadata exceeds the supported length.");
  }
  const name = textDecoder.decode(reader.data(nameByteCount)).trim() || "Object";
  const description = textDecoder.decode(reader.data(descriptionByteCount)).trim();
  const baseColor = finiteVector(reader.vector(3), "The object has an invalid base color.")
    .map((value) => Math.min(1, Math.max(0, value)));
  const boundsMinimum = finiteVector(reader.vector(3), "The object has invalid bounds.");
  const boundsMaximum = finiteVector(reader.vector(3), "The object has invalid bounds.");
  const vertexCount = reader.uint32();
  const indexCount = reader.uint32();
  const textureEncoding = reader.uint8();
  reader.uint8();
  reader.uint16();
  const textureByteCount = reader.uint32();
  if (vertexCount === 0 || vertexCount > MAX_MESH_VERTEX_COUNT ||
      indexCount < 3 || indexCount > MAX_MESH_INDEX_COUNT || indexCount % 3 !== 0 ||
      textureByteCount > MAX_MESH_TEXTURE_BYTES || ![0, 1, 2].includes(textureEncoding)) {
    throw new Error("The object file contains invalid or excessive geometry.");
  }

  const vertices = new Float32Array(vertexCount * 11);
  for (let index = 0; index < vertices.length; index += 1) {
    const value = reader.float32();
    if (!Number.isFinite(value)) {
      throw new Error("The object file contains a non-finite vertex attribute.");
    }
    vertices[index] = value;
  }
  const indices = new Uint32Array(indexCount);
  for (let index = 0; index < indexCount; index += 1) {
    const value = reader.uint32();
    if (value >= vertexCount) {
      throw new Error("The object file contains an invalid vertex index.");
    }
    indices[index] = value;
  }
  const textureData = reader.data(textureByteCount);
  if ((textureEncoding === 0) !== (textureData.length === 0)) {
    throw new Error("The object file contains an invalid texture.");
  }
  reader.finish();
  return {
    id,
    name,
    description,
    baseColor,
    boundsMinimum,
    boundsMaximum,
    vertices,
    indices,
    textureEncoding,
    textureData
  };
}

export function parseMeasurementFile(buffer) {
  const reader = new BinaryReader(buffer, MAX_MEASUREMENT_FILE_BYTES, "The measurement file");
  reader.magic(MEASUREMENT_FILE_MAGIC);
  const version = reader.uint16();
  reader.uint16();
  if (version !== MEASUREMENT_FILE_VERSION) {
    throw new Error(`Unsupported measurement file version ${version}.`);
  }
  const datasetID = reader.uuid();
  const count = reader.uint32();
  if (count > MAX_MEASUREMENT_COUNT) {
    throw new Error("The measurement file contains too many measurements.");
  }
  const measurements = [];
  let totalPointCount = 0;
  for (let index = 0; index < count; index += 1) {
    const id = reader.uuid();
    const kindValue = reader.uint8();
    reader.uint8();
    reader.uint16();
    const kinds = new Map([[1, "length"], [2, "area"], [3, "volume"]]);
    const kind = kinds.get(kindValue);
    if (!kind) {
      throw new Error(`Measurement ${index + 1} has an unsupported type.`);
    }
    const rawName = reader.string(MAX_MEASUREMENT_NAME_BYTES).trim();
    const pointCount = reader.uint32();
    totalPointCount += pointCount;
    if (totalPointCount > MAX_MEASUREMENT_POINT_COUNT) {
      throw new Error("The measurement file contains too many points.");
    }
    const points = Array.from({ length: pointCount }, () => ({
      id: reader.uuid(),
      position: finiteVector(reader.vector(3), `Measurement ${index + 1} has an invalid point.`)
    }));
    if (points.length > 0) {
      measurements.push({
        id,
        kind,
        name: (rawName || `Measurement ${index + 1}`).slice(0, MAX_MEASUREMENT_NAME_CHARACTERS),
        points
      });
    }
  }
  reader.finish();
  return { datasetID, measurements };
}

function finiteVector(value, message) {
  if (!value.every(Number.isFinite)) {
    throw new Error(message);
  }
  return value;
}

function normalizedQuaternion(value) {
  const length = Math.hypot(...value);
  if (!Number.isFinite(length) || length < 0.000001) {
    return [0, 0, 0, 1];
  }
  return value.map((component) => component / length);
}

function finiteClamped(value, fallback, minimum, maximum) {
  return Number.isFinite(value) ? Math.min(maximum, Math.max(minimum, value)) : fallback;
}
