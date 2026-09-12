import { CoordinateCubeRenderer } from "./cube-renderer.js?v=20260911-worker";
import { decodeAppleLZ4, encodeLZ4Block } from "./lz4.js?v=20260911-urltf";
import { transferFunctionRGBAData } from "./transfer-function.js?v=20260912-btf1";

const catalogStatus = document.querySelector("#catalog-status");
const datasetList = document.querySelector("#dataset-list");
const canvas = document.querySelector("#render-canvas");
const viewerEmpty = document.querySelector("#viewer-empty");
const infoButton = document.querySelector("#info-button");
const statusButton = document.querySelector("#status-button");
const datasetInfo = document.querySelector("#dataset-info");
const statusLine = document.querySelector("#status-line");
const renderControls = document.querySelector("#render-controls");
const controlsCollapseButton = document.querySelector("#controls-collapse-button");
const renderModeButtons = Array.from(document.querySelectorAll("[data-render-mode]"));
const editorPanels = Array.from(document.querySelectorAll("[data-editor-mode]"));
const transferEditorCanvas = document.querySelector("#tf-editor-canvas");
const tfChannelButtons = Array.from(document.querySelectorAll("[data-tf-channel]"));
const tfSave = document.querySelector("#tf-save");
const tfLoad = document.querySelector("#tf-load");
const tfLoadInput = document.querySelector("#tf-load-input");
const tfCatalogSelect = document.querySelector("#tf-catalog-select");
const tfReset = document.querySelector("#tf-reset");
const isoValue = document.querySelector("#iso-value");
const clipInputs = Array.from(document.querySelectorAll("[data-clip-axis]"));
const clipReset = document.querySelector("#clip-reset");
const MINIMUM_TRANSFER_SMOOTH_WIDTH = 0.02;
const MAXIMUM_TRANSFER_SMOOTH_WIDTH = 1.0;
const TRANSFER_FUNCTION_URL_PARAMETER = "TF";
const RENDER_MODE_URL_PARAMETER = "mode";
const ISO_VALUE_URL_PARAMETER = "iso";
const VALID_RENDER_MODES = new Set(["tf", "tf-lighting", "iso"]);
const MAX_TRANSFER_FUNCTION_ENTRIES = 1 << 16;
const MAX_TRANSFER_FUNCTION_RGBA_BYTES = MAX_TRANSFER_FUNCTION_ENTRIES * 4;
const MAX_TRANSFER_FUNCTION_METADATA_BYTES = 64 * 1024;
const MAX_TRANSFER_FUNCTION_URL_BYTES = MAX_TRANSFER_FUNCTION_RGBA_BYTES + MAX_TRANSFER_FUNCTION_METADATA_BYTES;
const MAX_TRANSFER_FUNCTION_FILE_BYTES = MAX_TRANSFER_FUNCTION_RGBA_BYTES + MAX_TRANSFER_FUNCTION_METADATA_BYTES;

let renderer = null;
let currentManifest = null;
let transferFunctionCatalog = [];
let transferFunctionCatalogBuffers = new Map();
let rendererStatus = "Initializing WebGPU...";
let statusVisible = false;
let controlsCollapsed = false;
let currentRenderMode = "tf";
let lastTransferPaintPoint = null;
let transferPointerMode = null;
let rendererReadyPromise = null;
let profilingEnabled = false;

main().catch((error) => {
  setStatus(error.message ?? String(error));
});

async function main() {
  profilingEnabled = profilingRequested();
  renderer = new CoordinateCubeRenderer(canvas);
  window.borgvrProfileSnapshot = () => renderer?.profileSnapshot();
  window.borgvrProfileSummary = () => renderer?.profileSummaryText();
  renderer.setProfiling(profilingEnabled);
  renderer.setStatusReporting(statusVisible);
  rendererReadyPromise = renderer.initialize((message) => {
    setStatus(message);
  }).then(() => {
    drawTransferFunctionEditor();
  });
  rendererReadyPromise.catch((error) => {
    setStatus(error.message ?? String(error));
  });

  infoButton.addEventListener("click", () => {
    datasetInfo.hidden = !datasetInfo.hidden;
    infoButton.setAttribute("aria-label", datasetInfo.hidden ? "Show dataset information" : "Hide dataset information");
  });

  statusButton.addEventListener("click", () => {
    statusVisible = !statusVisible;
    renderer?.setStatusReporting(statusVisible);
    statusLine.hidden = !statusVisible;
    statusButton.classList.toggle("active", statusVisible);
    statusButton.setAttribute("aria-label", statusVisible ? "Hide renderer status" : "Show renderer status");
    if (statusVisible) {
      statusLine.textContent = rendererStatus;
    }
  });

  installRenderControls();
  window.addEventListener("resize", drawTransferFunctionEditor);
  if (profilingEnabled) {
    showStatusLine();
    setInterval(reportProfile, 2000);
  }

  const catalog = await fetchJSON("./web-data/datasets.json", "catalog");
  await loadTransferFunctionCatalog();
  catalogStatus.textContent = `${catalog.datasets.length} datasets available`;
  if (rendererStatus === "Initializing WebGPU...") {
    setStatus(`${catalog.datasets.length} datasets available`);
  }
  datasetList.replaceChildren(...catalog.datasets.map((dataset) => datasetButton(dataset)));
  await openDatasetFromURL(catalog.datasets);
}

async function loadTransferFunctionCatalog() {
  try {
    const catalog = await fetchJSON("./web-data/transfer-functions.json", "transfer functions");
    transferFunctionCatalog = groupTransferFunctionCatalog(
      Array.isArray(catalog.transferFunctions) ? catalog.transferFunctions : []
    );
  } catch {
    transferFunctionCatalog = [];
  }
  transferFunctionCatalogBuffers = new Map();

  const options = [
    new Option("Server Presets", ""),
    ...transferFunctionCatalog.map((entry) => new Option(displayTransferFunctionName(entry), entry.id)),
  ];
  options[0].disabled = true;
  options[0].selected = true;
  tfCatalogSelect.replaceChildren(...options);
  tfCatalogSelect.hidden = transferFunctionCatalog.length === 0;
}

async function loadCatalogTransferFunction(id) {
  if (!id) {
    return;
  }

  const entry = transferFunctionCatalog.find((candidate) => candidate.id === id);
  if (!entry) {
    setStatus("Transfer function not found.");
    return;
  }

  try {
    renderer?.loadTransferFunction(await fetchCatalogTransferFunction(entry));
    drawTransferFunctionEditor();
    updateTransferFunctionURL();
    tfCatalogSelect.value = id;
    setStatus(`Transfer function loaded: ${displayTransferFunctionName(entry)}`);
  } catch (error) {
    setStatus(`Transfer function load failed: ${error.message ?? String(error)}`);
  }
}

function displayTransferFunctionName(entry) {
  if (entry.displayName) {
    return entry.displayName;
  }
  return entry.description?.trim() || entry.id;
}

function groupTransferFunctionCatalog(entries) {
  const groups = new Map();
  for (const entry of entries) {
    if (!entry?.id) {
      continue;
    }

    const name = displayTransferFunctionName(entry);
    let group = groups.get(entry.id);
    if (!group) {
      group = {
        ...entry,
        displayNames: [],
      };
      groups.set(entry.id, group);
    }
    if (!group.displayNames.includes(name)) {
      group.displayNames.push(name);
    }
  }

  return Array.from(groups.values()).map((group) => ({
    ...group,
    displayName: group.displayNames.join(" / "),
  }));
}

function datasetButton(dataset) {
  const button = document.createElement("button");
  button.className = "dataset-button";
  button.type = "button";
  button.innerHTML = `
    <span class="dataset-title"></span>
    <span class="dataset-meta"></span>
    <span class="dataset-id"></span>
  `;
  button.querySelector(".dataset-title").textContent = displayDatasetName(dataset);
  button.querySelector(".dataset-meta").textContent = dataset.description || "BorgVR dataset";
  button.querySelector(".dataset-id").textContent = dataset.id;
  button.dataset.datasetId = dataset.id;
  button.addEventListener("click", async () => {
    await selectDataset(dataset, button, true);
  });
  return button;
}

async function openDatasetFromURL(datasets) {
  const datasetID = requestedDatasetID();
  if (!datasetID) {
    return;
  }

  const normalizedID = datasetID.toLowerCase();
  const dataset = datasets.find((candidate) => candidate.id?.toLowerCase() === normalizedID);
  if (!dataset) {
    setStatus(`Dataset ${datasetID} is not available on this server.`);
    return;
  }

  const button = datasetList.querySelector(`[data-dataset-id="${CSS.escape(dataset.id)}"]`);
  await selectDataset(dataset, button, false);
}

function requestedDatasetID() {
  const params = new URLSearchParams(window.location.search);
  return params.get("ID") || params.get("id") || params.get("dataset") || "";
}

async function selectDataset(dataset, button, updateURL) {
  document.querySelectorAll(".dataset-button.active").forEach((element) => {
    element.classList.remove("active");
  });
  button?.classList.add("active");
  if (updateURL) {
    updateDatasetURL(dataset.id);
  }
  try {
    await showDataset(dataset);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    setStatus(`Could not open ${dataset.name}: ${message}`);
    console.error("BorgVR dataset loading failed", error);
  }
}

function updateDatasetURL(datasetID) {
  const url = new URL(window.location.href);
  url.searchParams.delete("id");
  url.searchParams.delete("dataset");
  url.searchParams.set("ID", datasetID);
  window.history.replaceState(null, "", url);
}

async function showDataset(dataset) {
  setStatus(`Loading ${dataset.name}...`);
  await rendererReadyPromise;
  const manifestURL = new URL(`./web-data/${dataset.metadata}`, window.location.href);
  currentManifest = await fetchLZ4JSON(manifestURL, "manifest");
  currentManifest.baseURL = new URL(".", manifestURL).href;
  if (!renderer?.ready) {
    setStatus(rendererStatus);
    return;
  }
  renderer?.setDataset(currentManifest);
  isoValue.value = String(renderer.getNormalizedIsoValue());
  applyRenderStateFromURL();
  const transferFunctionStatus = await applyTransferFunctionFromURL();
  viewerEmpty.hidden = true;
  infoButton.disabled = false;
  renderControls.hidden = false;
  datasetInfo.hidden = true;
  renderDatasetInfo(currentManifest);
  updateVisibleEditor();
  drawTransferFunctionEditor();
  updateURLState();
  setStatus(transferFunctionStatus || `Rendering ${currentManifest.name}`);
}

function setStatus(message) {
  rendererStatus = message;
  if (statusVisible) {
    statusLine.textContent = message;
  }
}

function showStatusLine() {
  statusVisible = true;
  renderer?.setStatusReporting(true);
  statusLine.hidden = false;
  statusButton.classList.add("active");
  statusButton.setAttribute("aria-label", "Hide renderer status");
  statusLine.textContent = rendererStatus;
}

function reportProfile() {
  if (!renderer) {
    return;
  }
  const snapshot = renderer.profileSnapshot();
  const rows = flattenProfileSnapshot(snapshot);
  document.documentElement.dataset.borgvrProfile = JSON.stringify(snapshot);
  console.info("BorgVR profile", JSON.stringify(rows));
  console.table(rows);
  setStatus(renderer.profileSummaryText());
}

function installRenderControls() {
  controlsCollapseButton.addEventListener("click", () => {
    setControlsCollapsed(!controlsCollapsed);
  });

  renderModeButtons.forEach((button) => {
    button.addEventListener("click", () => {
      const mode = button.dataset.renderMode;
      if (!VALID_RENDER_MODES.has(mode)) {
        return;
      }
      selectRenderMode(mode);
      updateURLState();
    });
  });

  tfChannelButtons.forEach((button) => {
    button.addEventListener("click", () => {
      button.classList.toggle("active");
      button.setAttribute("aria-pressed", button.classList.contains("active") ? "true" : "false");
      drawTransferFunctionEditor();
    });
  });

  tfSave.addEventListener("click", () => {
    saveTransferFunction();
  });

  tfLoad.addEventListener("click", () => {
    tfLoadInput.value = "";
    tfLoadInput.click();
  });

  tfLoadInput.addEventListener("change", async () => {
    await loadTransferFunction(tfLoadInput.files?.[0]);
  });

  tfCatalogSelect.addEventListener("change", async () => {
    await loadCatalogTransferFunction(tfCatalogSelect.value);
  });

  tfReset.addEventListener("click", () => {
    renderer?.resetTransferFunction();
    drawTransferFunctionEditor();
    clearTransferFunctionURL();
    clearTransferFunctionSelection();
  });

  transferEditorCanvas.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    if (event.button === 2 || event.ctrlKey) {
      lastTransferPaintPoint = null;
      transferPointerMode = "smoothstep";
      transferEditorCanvas.setPointerCapture(event.pointerId);
      setSmoothStepFromTransferEditorPoint(transferEditorPoint(event));
      return;
    }
    transferPointerMode = "paint";
    transferEditorCanvas.setPointerCapture(event.pointerId);
    lastTransferPaintPoint = transferEditorPoint(event);
    renderer?.paintTransferFunction(lastTransferPaintPoint, lastTransferPaintPoint, selectedTransferChannels());
    drawTransferFunctionEditor();
  });

  transferEditorCanvas.addEventListener("pointermove", (event) => {
    if (!transferPointerMode) {
      return;
    }
    event.preventDefault();
    const point = transferEditorPoint(event);
    if (transferPointerMode === "smoothstep") {
      setSmoothStepFromTransferEditorPoint(point);
      return;
    }
    if (!lastTransferPaintPoint) {
      return;
    }
    renderer?.paintTransferFunction(lastTransferPaintPoint, point, selectedTransferChannels());
    lastTransferPaintPoint = point;
    drawTransferFunctionEditor();
  });

  transferEditorCanvas.addEventListener("pointerup", () => {
    lastTransferPaintPoint = null;
    transferPointerMode = null;
    updateTransferFunctionURL();
    clearTransferFunctionSelection();
  });

  transferEditorCanvas.addEventListener("pointercancel", () => {
    lastTransferPaintPoint = null;
    transferPointerMode = null;
    updateTransferFunctionURL();
    clearTransferFunctionSelection();
  });

  transferEditorCanvas.addEventListener("contextmenu", (event) => {
    event.preventDefault();
  });

  isoValue.addEventListener("input", () => {
    renderer?.setIsoValue(Number(isoValue.value));
    updateURLState();
  });

  clipInputs.forEach((input) => {
    input.addEventListener("input", () => {
      renderer?.setClipBound(
        Number(input.dataset.clipAxis),
        input.dataset.clipBound,
        Number(input.value)
      );
    });
  });

  clipReset.addEventListener("click", () => {
    clipInputs.forEach((input) => {
      input.value = input.dataset.clipBound === "min" ? "0" : "1";
    });
    renderer?.resetClipping();
  });

  updateVisibleEditor();
  drawTransferFunctionEditor();
}

function updateVisibleEditor() {
  const activeEditor = currentRenderMode === "iso" ? "iso" : "transfer";
  editorPanels.forEach((panel) => {
    panel.hidden = panel.dataset.editorMode !== activeEditor;
  });
}

function selectRenderMode(mode) {
  if (!VALID_RENDER_MODES.has(mode)) {
    return;
  }
  currentRenderMode = mode;
  renderModeButtons.forEach((button) => {
    const active = button.dataset.renderMode === mode;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", active ? "true" : "false");
  });
  updateVisibleEditor();
  renderer?.setRenderMode(mode);
}

function setControlsCollapsed(collapsed) {
  controlsCollapsed = collapsed;
  renderControls.classList.toggle("collapsed", controlsCollapsed);
  controlsCollapseButton.textContent = controlsCollapsed ? "UI" : "x";
  controlsCollapseButton.setAttribute("aria-label", controlsCollapsed ? "Show render controls" : "Hide render controls");
  controlsCollapseButton.title = controlsCollapsed ? "Show render controls" : "Hide render controls";
  if (!controlsCollapsed) {
    drawTransferFunctionEditor();
  }
}

function saveTransferFunction() {
  const buffer = renderer?.serializeTransferFunction();
  if (!buffer?.byteLength) {
    setStatus("No transfer function is available.");
    return;
  }

  const blob = new Blob([buffer], { type: "application/octet-stream" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `${safeFilename(currentManifest?.name ?? "BorgVR-TransferFunction")}.tf1d`;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
  setStatus("Transfer function saved.");
}

async function loadTransferFunction(file) {
  if (!file) {
    return;
  }

  try {
    renderer?.loadTransferFunction(await file.arrayBuffer());
    drawTransferFunctionEditor();
    updateTransferFunctionURL();
    await selectMatchingCatalogTransferFunction(renderer?.serializeTransferFunction());
    setStatus(`Transfer function loaded: ${file.name}`);
  } catch (error) {
    setStatus(`Transfer function load failed: ${error.message ?? String(error)}`);
  }
}

async function applyTransferFunctionFromURL() {
  if (currentRenderMode === "iso") {
    return "";
  }

  const encoded = requestedTransferFunction();
  if (!encoded) {
    return "";
  }

  try {
    const transferFunction = decodeTransferFunctionURLValue(encoded);
    renderer?.loadTransferFunction(transferFunction);
    const matchingEntry = await selectMatchingCatalogTransferFunction(transferFunction);
    if (matchingEntry) {
      return `Transfer function loaded from URL: ${displayTransferFunctionName(matchingEntry)}.`;
    }
    return "Transfer function loaded from URL.";
  } catch (error) {
    return `Transfer function URL parameter ignored: ${error.message ?? String(error)}`;
  }
}

function requestedTransferFunction() {
  const params = new URLSearchParams(window.location.search);
  return params.get(TRANSFER_FUNCTION_URL_PARAMETER) || params.get("tf") || "";
}

function applyRenderStateFromURL() {
  const normalizedIsoValue = requestedIsoValue();
  if (normalizedIsoValue !== null) {
    isoValue.value = String(normalizedIsoValue);
    renderer?.setIsoValue(normalizedIsoValue);
  }

  const renderMode = requestedRenderMode();
  if (renderMode) {
    selectRenderMode(renderMode);
  }
}

function requestedRenderMode() {
  const params = new URLSearchParams(window.location.search);
  const mode = (params.get(RENDER_MODE_URL_PARAMETER) || params.get("renderMode") || "").toLowerCase();
  return VALID_RENDER_MODES.has(mode) ? mode : "";
}

function requestedIsoValue() {
  const params = new URLSearchParams(window.location.search);
  const value = params.get(ISO_VALUE_URL_PARAMETER) || params.get("isoValue") || params.get("isovalue");
  if (value === null) {
    return null;
  }
  const numberValue = Number(value);
  return Number.isFinite(numberValue) ? clamp(numberValue, 0, 1) : null;
}

function updateURLState() {
  const url = new URL(window.location.href);
  url.searchParams.delete("tf");
  url.searchParams.delete("renderMode");
  url.searchParams.delete("isoValue");
  url.searchParams.delete("isovalue");
  url.searchParams.set(RENDER_MODE_URL_PARAMETER, currentRenderMode);

  if (currentRenderMode === "iso") {
    url.searchParams.delete(TRANSFER_FUNCTION_URL_PARAMETER);
    url.searchParams.set(ISO_VALUE_URL_PARAMETER, normalizedIsoValueForURL());
  } else {
    url.searchParams.delete(ISO_VALUE_URL_PARAMETER);
    const buffer = renderer?.serializeTransferFunction();
    if (buffer?.byteLength) {
      url.searchParams.set(TRANSFER_FUNCTION_URL_PARAMETER, encodeTransferFunctionURLValue(buffer));
    } else {
      url.searchParams.delete(TRANSFER_FUNCTION_URL_PARAMETER);
    }
  }

  window.history.replaceState(null, "", url);
}

function normalizedIsoValueForURL() {
  const value = clamp(Number(isoValue.value), 0, 1);
  return Number.isFinite(value) ? value.toPrecision(6).replace(/(?:\.0+|(\.\d+?)0+)$/, "$1") : "0";
}

function updateTransferFunctionURL() {
  updateURLState();
}

function clearTransferFunctionURL() {
  const url = new URL(window.location.href);
  url.searchParams.delete(TRANSFER_FUNCTION_URL_PARAMETER);
  url.searchParams.delete("tf");
  window.history.replaceState(null, "", url);
}

function clearTransferFunctionSelection() {
  if (tfCatalogSelect) {
    tfCatalogSelect.value = "";
  }
}

async function selectMatchingCatalogTransferFunction(buffer) {
  if (!buffer?.byteLength || transferFunctionCatalog.length === 0) {
    clearTransferFunctionSelection();
    return null;
  }

  const bytes = transferFunctionRGBAData(buffer);
  for (const entry of transferFunctionCatalog) {
    try {
      if (bytesEqual(bytes, transferFunctionRGBAData(await fetchCatalogTransferFunction(entry)))) {
        tfCatalogSelect.value = entry.id;
        return entry;
      }
    } catch {
      // Ignore broken catalog entries; loading the transfer function itself already succeeded.
    }
  }

  clearTransferFunctionSelection();
  return null;
}

async function fetchCatalogTransferFunction(entry) {
  if (!entry?.id || !entry?.url) {
    throw new Error("Transfer function catalog entry is incomplete.");
  }
  const declaredByteCount = transferFunctionByteCount(entry);

  if (transferFunctionCatalogBuffers.has(entry.id)) {
    return transferFunctionCatalogBuffers.get(entry.id);
  }

  const url = new URL(`./web-data/${entry.url}`, window.location.href);
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  validateResponseContentLength(response, MAX_TRANSFER_FUNCTION_FILE_BYTES, "transfer function");
  const buffer = await responseArrayBufferWithLimit(
    response,
    MAX_TRANSFER_FUNCTION_FILE_BYTES,
    "transfer function"
  );
  if (declaredByteCount !== null && buffer.byteLength !== declaredByteCount) {
    throw new Error(
      `Transfer function byte count mismatch: expected ${declaredByteCount}, received ${buffer.byteLength}.`
    );
  }
  transferFunctionCatalogBuffers.set(entry.id, buffer);
  return buffer;
}

function transferFunctionByteCount(entry) {
  if (entry.byteCount === undefined || entry.byteCount === null) {
    return null;
  }
  const byteCount = Number(entry.byteCount);
  if (!Number.isInteger(byteCount) || byteCount <= 0 || byteCount > MAX_TRANSFER_FUNCTION_FILE_BYTES) {
    throw new Error("Transfer function catalog entry exceeds the supported size limit.");
  }
  return byteCount;
}

function validateResponseContentLength(response, maxBytes, label) {
  const contentLength = response.headers.get("content-length");
  if (!contentLength) {
    return;
  }
  const byteCount = Number(contentLength);
  if (!Number.isInteger(byteCount) || byteCount < 0) {
    throw new Error(`Invalid ${label} Content-Length.`);
  }
  if (byteCount > maxBytes) {
    throw new Error(`${capitalize(label)} exceeds the supported size limit.`);
  }
}

async function responseArrayBufferWithLimit(response, maxBytes, label) {
  if (!response.body?.getReader) {
    throw new Error(`Cannot safely load ${label}: streaming response bodies are not available.`);
  }

  const reader = response.body.getReader();
  const chunks = [];
  let totalBytes = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        throw new Error(`${capitalize(label)} exceeds the supported size limit.`);
      }
      chunks.push(value);
    }
  } catch (error) {
    try {
      await reader.cancel();
    } catch {
      // Ignore cancellation failures; the original read error is more useful.
    }
    throw error;
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes.buffer;
}

function capitalize(text) {
  return text.length === 0 ? text : text[0].toUpperCase() + text.slice(1);
}

function bytesEqual(left, right) {
  if (left.byteLength !== right.byteLength) {
    return false;
  }
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function encodeTransferFunctionURLValue(buffer) {
  const bytes = buffer instanceof ArrayBuffer
    ? new Uint8Array(buffer)
    : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  const nativeCompressed = encodeLZ4Block(bytes);
  const nativeToken = `l.${bytes.byteLength}.${bytesToBase64URL(nativeCompressed)}`;

  const rgba = transferFunctionRGBAData(bytes);
  const deltaCompressed = encodeLZ4Block(deltaEncodeRGBA(rgba));
  const deltaToken = `d.${rgba.byteLength / 4}.${bytesToBase64URL(deltaCompressed)}`;
  return deltaToken.length < nativeToken.length ? deltaToken : nativeToken;
}

function decodeTransferFunctionURLValue(value) {
  const parts = value.split(".");
  if (parts.length !== 3) {
    throw new Error("Unsupported transfer function encoding.");
  }

  if (parts[0] === "lz4" || parts[0] === "l") {
    const byteLength = Number(parts[1]);
    if (!Number.isInteger(byteLength) || byteLength <= 0 || byteLength > MAX_TRANSFER_FUNCTION_URL_BYTES) {
      throw new Error("Invalid transfer function byte length.");
    }

    const compressed = base64URLToBytes(parts[2]);
    return decodeAppleLZ4(compressed, byteLength).buffer;
  }

  if (parts[0] === "d") {
    const count = Number(parts[1]);
    if (!Number.isInteger(count) || count <= 0 || count * 4 > MAX_TRANSFER_FUNCTION_URL_BYTES) {
      throw new Error("Invalid transfer function entry count.");
    }

    const compressed = base64URLToBytes(parts[2]);
    const deltaRGBA = decodeAppleLZ4(compressed, count * 4);
    return nativeTransferFunctionBuffer(deltaDecodeRGBA(deltaRGBA));
  }

  throw new Error("Unsupported transfer function encoding.");
}

function nativeTransferFunctionBuffer(rgba) {
  const bytes = new Uint8Array(4 + rgba.byteLength);
  new DataView(bytes.buffer).setUint32(0, rgba.byteLength / 4, true);
  bytes.set(rgba, 4);
  return bytes.buffer;
}

function deltaEncodeRGBA(rgba) {
  const result = new Uint8Array(rgba.byteLength);
  for (let index = 0; index < rgba.byteLength; index += 1) {
    result[index] = index < 4 ? rgba[index] : (rgba[index] - rgba[index - 4]) & 0xff;
  }
  return result;
}

function deltaDecodeRGBA(deltaRGBA) {
  const result = new Uint8Array(deltaRGBA.byteLength);
  for (let index = 0; index < deltaRGBA.byteLength; index += 1) {
    result[index] = index < 4 ? deltaRGBA[index] : (deltaRGBA[index] + result[index - 4]) & 0xff;
  }
  return result;
}

function bytesToBase64URL(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.byteLength; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function base64URLToBytes(value) {
  const padded = value
    .replaceAll("-", "+")
    .replaceAll("_", "/")
    .padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function selectedTransferChannels() {
  const channels = tfChannelButtons
    .filter((button) => button.classList.contains("active"))
    .map((button) => Number(button.dataset.tfChannel));
  return channels.length > 0 ? channels : [3];
}

function setSmoothStepFromTransferEditorPoint(point) {
  const steepness = 1 - point.y;
  const width = MAXIMUM_TRANSFER_SMOOTH_WIDTH -
    steepness * (MAXIMUM_TRANSFER_SMOOTH_WIDTH - MINIMUM_TRANSFER_SMOOTH_WIDTH);
  renderer?.setTransferFunctionSmoothStep({
    start: point.x - width * 0.5,
    shift: width,
    channels: selectedTransferChannels()
  });
  drawTransferFunctionEditor();
}

function transferEditorPoint(event) {
  const rect = transferEditorCanvas.getBoundingClientRect();
  return {
    x: clamp((event.clientX - rect.left) / Math.max(1, rect.width), 0, 1),
    y: clamp(1 - (event.clientY - rect.top) / Math.max(1, rect.height), 0, 1)
  };
}

function drawTransferFunctionEditor() {
  if (!transferEditorCanvas || !renderer) {
    return;
  }
  const rect = transferEditorCanvas.getBoundingClientRect();
  const scale = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.round((rect.width || 320) * scale));
  const height = Math.max(1, Math.round((rect.height || 120) * scale));
  if (transferEditorCanvas.width !== width || transferEditorCanvas.height !== height) {
    transferEditorCanvas.width = width;
    transferEditorCanvas.height = height;
  }

  const context = transferEditorCanvas.getContext("2d");
  const data = renderer.getTransferFunctionData();
  if (!context || !data.length) {
    return;
  }
  context.clearRect(0, 0, width, height);
  drawCheckerboard(context, width, height, scale);
  drawTransferRibbon(context, data, width, height);
  drawTransferGrid(context, width, height, scale);
  drawTransferCurves(context, data, width, height);
}

function drawCheckerboard(context, width, height, scale) {
  const cell = Math.max(6, Math.round(8 * scale));
  for (let y = 0; y < height; y += cell) {
    for (let x = 0; x < width; x += cell) {
      context.fillStyle = ((x / cell + y / cell) % 2) < 1 ? "#20282d" : "#0b1218";
      context.fillRect(x, y, cell, cell);
    }
  }
}

function drawTransferRibbon(context, data, width, height) {
  const top = Math.round(height * 0.38);
  const ribbonHeight = Math.max(1, Math.round(height * 0.24));
  const bins = data.length / 4;
  for (let x = 0; x < width; x += 1) {
    const index = Math.min(bins - 1, Math.floor(x * bins / Math.max(1, width)));
    const offset = index * 4;
    const alpha = data[offset + 3] / 255;
    context.fillStyle = `rgba(${data[offset]}, ${data[offset + 1]}, ${data[offset + 2]}, ${Math.max(0.08, alpha)})`;
    context.fillRect(x, top, 1, ribbonHeight);
  }
}

function drawTransferGrid(context, width, height, scale) {
  context.strokeStyle = "rgba(190, 249, 255, 0.16)";
  context.lineWidth = Math.max(1, scale);
  context.beginPath();
  for (let i = 0; i <= 4; i += 1) {
    const x = Math.round(i * width / 4) + 0.5;
    const y = Math.round(i * height / 4) + 0.5;
    context.moveTo(x, 0);
    context.lineTo(x, height);
    context.moveTo(0, y);
    context.lineTo(width, y);
  }
  context.stroke();
}

function drawTransferCurves(context, data, width, height) {
  const colors = ["#ff5b5b", "#41e884", "#5ca9ff", "#ffffff"];
  const bins = data.length / 4;
  const activeChannels = new Set(selectedTransferChannels());
  for (let channel = 0; channel < 4; channel += 1) {
    context.globalAlpha = activeChannels.has(channel) ? 1 : 0.26;
    context.strokeStyle = colors[channel];
    context.lineWidth = activeChannels.has(channel) ? 2 : 1;
    context.beginPath();
    for (let index = 0; index < bins; index += 1) {
      const x = index * (width - 1) / Math.max(1, bins - 1);
      const y = height - 1 - data[index * 4 + channel] * (height - 1) / 255;
      if (index === 0) {
        context.moveTo(x, y);
      } else {
        context.lineTo(x, y);
      }
    }
    context.stroke();
  }
  context.globalAlpha = 1;
}

function renderDatasetInfo(manifest) {
  datasetInfo.innerHTML = `
    <div class="details-header">
      <div>
        <h2></h2>
        <p></p>
      </div>
      <span class="variant-badge"></span>
    </div>
    <dl class="manifest-grid">
      <div><dt>Dataset ID</dt><dd class="dataset-uuid"></dd></div>
      <div><dt>Volume</dt><dd class="volume-size"></dd></div>
      <div><dt>Components</dt><dd class="components"></dd></div>
      <div><dt>Brick layout</dt><dd class="brick-layout"></dd></div>
      <div><dt>LOD levels</dt><dd class="lod-levels"></dd></div>
      <div><dt>Bricks</dt><dd class="brick-count"></dd></div>
    </dl>
  `;

  datasetInfo.querySelector("h2").textContent = displayDatasetName(manifest);
  datasetInfo.querySelector("p").textContent = manifest.description;
  datasetInfo.querySelector(".variant-badge").textContent = variantLabel(manifest.variant);
  datasetInfo.querySelector(".dataset-uuid").textContent = manifest.id;
  datasetInfo.querySelector(".volume-size").textContent = manifest.volume.size.join(" x ");
  datasetInfo.querySelector(".components").textContent = `${manifest.volume.componentCount} x ${manifest.volume.bytesPerComponent * 8}-bit`;
  datasetInfo.querySelector(".brick-layout").textContent = `${manifest.bricking.brickSize}³, overlap ${manifest.bricking.overlap}`;
  datasetInfo.querySelector(".lod-levels").textContent = String(manifest.levels.length);
  datasetInfo.querySelector(".brick-count").textContent = String(brickCountForManifest(manifest));
}

function brickCountForManifest(manifest) {
  if (Array.isArray(manifest.bricks)) {
    return manifest.bricks.length;
  }
  if (Array.isArray(manifest.brickMetadata?.values)) {
    return Math.floor(manifest.brickMetadata.values.length / 3);
  }
  return (manifest.levels ?? []).reduce((sum, level) => sum + (level.brickTotal ?? 0), 0);
}

async function fetchJSON(url, label = "json") {
  const requestURL = new URL(url, window.location.href);
  requestURL.searchParams.set("cacheBust", String(Date.now()));
  const fetchStart = performance.now();
  const response = await fetch(requestURL, {
    cache: "no-store",
    credentials: "same-origin"
  });
  const fetchMs = performance.now() - fetchStart;
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} while loading ${requestURL}`);
  }
  const bodyStart = performance.now();
  const text = await response.text();
  const bodyMs = performance.now() - bodyStart;
  const parseStart = performance.now();
  const json = JSON.parse(text);
  const parseMs = performance.now() - parseStart;
  logProfileRow(`${label} JSON`, {
    fetchMs,
    bodyMs,
    parseMs,
    bytes: text.length
  });
  return json;
}

async function fetchLZ4JSON(url, label = "lz4-json") {
  const requestURL = new URL(url, window.location.href);
  requestURL.searchParams.set("cacheBust", String(Date.now()));
  const fetchStart = performance.now();
  const response = await fetch(requestURL, {
    cache: "no-store",
    credentials: "same-origin"
  });
  const fetchMs = performance.now() - fetchStart;
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} while loading ${requestURL}`);
  }

  const expectedLength = Number(response.headers.get("X-BorgVR-Uncompressed-Length"));
  if (!Number.isFinite(expectedLength) || expectedLength <= 0) {
    throw new Error("Compressed manifest is missing its uncompressed length.");
  }

  const bodyStart = performance.now();
  const compressed = new Uint8Array(await response.arrayBuffer());
  const bodyMs = performance.now() - bodyStart;
  const decodeStart = performance.now();
  const jsonBytes = decodeAppleLZ4(compressed, expectedLength);
  const decodeMs = performance.now() - decodeStart;
  const parseStart = performance.now();
  const json = JSON.parse(new TextDecoder().decode(jsonBytes));
  const parseMs = performance.now() - parseStart;
  logProfileRow(`${label} LZ4 JSON`, {
    fetchMs,
    bodyMs,
    decodeMs,
    parseMs,
    compressedBytes: compressed.byteLength,
    decodedBytes: jsonBytes.byteLength
  });
  return json;
}

function profilingRequested() {
  const params = new URLSearchParams(window.location.search);
  return params.get("profile") === "1" || params.get("profile") === "true";
}

function logProfileRow(label, values) {
  if (!profilingEnabled) {
    return;
  }
  console.table([{ label, ...values }]);
}

function flattenProfileSnapshot(snapshot) {
  const renderer = snapshot.renderer ?? {};
  const atlas = snapshot.atlas ?? {};
  return [
    {
      section: "network",
      totalMs: atlas.fetchHeaderMs + atlas.fetchBodyMs,
      avgMs: atlas.avgFetchHeaderMsPerBatch + atlas.avgFetchBodyMsPerBatch,
      detail: `${atlas.batchRequests ?? 0} batches, ${atlas.compressedMiB?.toFixed?.(1) ?? "0.0"} MiB compressed`
    },
    {
      section: "lz4 decode",
      totalMs: atlas.lz4DecodeMs,
      avgMs: atlas.avgLZ4DecodeMs,
      detail: `${atlas.lz4Bricks ?? 0} bricks`
    },
    {
      section: "upload prepare",
      totalMs: atlas.uploadPrepareMs,
      avgMs: atlas.avgUploadPrepareMs,
      detail: `${atlas.uploadedMiB?.toFixed?.(1) ?? "0.0"} MiB upload data`
    },
    {
      section: "writeTexture",
      totalMs: atlas.uploadSubmitMs,
      avgMs: atlas.avgUploadSubmitMs,
      detail: `${atlas.loads ?? 0} bricks`
    },
    {
      section: "draw CPU",
      totalMs: renderer.drawCpuMs,
      avgMs: renderer.avgDrawCpuMs,
      detail: `${renderer.frames ?? 0} frames`
    },
    {
      section: "readback wait",
      totalMs: renderer.readbackMapMs,
      avgMs: renderer.avgReadbackMapMs,
      detail: `${renderer.requestedBricks ?? 0} requests, ${renderer.readbackOverflows ?? 0} overflows`
    },
    {
      section: "readback process",
      totalMs: renderer.readbackProcessMs,
      avgMs: renderer.avgReadbackProcessMs,
      detail: `${renderer.requestedBricks ?? 0} request ids filtered/enqueued`
    }
  ].map((row) => ({
    section: row.section,
    totalMs: Number(row.totalMs ?? 0).toFixed(2),
    avgMs: Number(row.avgMs ?? 0).toFixed(3),
    detail: row.detail
  }));
}

function variantLabel(variant) {
  switch (variant) {
  case "compressed":
    return "LZ4";
  case "decompressed":
    return "Raw";
  case "stored":
    return "Stored";
  default:
    return variant || "Dataset";
  }
}

function displayDatasetName(dataset) {
  return (dataset.name || dataset.id).replace(/\s+\((LZ4|Raw|Stored)\)$/i, "");
}

function safeFilename(name) {
  const safe = String(name)
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return safe || "BorgVR-TransferFunction";
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
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
