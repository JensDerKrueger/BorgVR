const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

async function main() {
  const root = path.resolve(__dirname, "../web");
  const volume = Buffer.alloc(32 ** 3);
  for (let z = 0; z < 32; z++) for (let y = 0; y < 32; y++) for (let x = 0; x < 32; x++) {
    if ((x - 9) ** 2 + (y - 9) ** 2 + (z - 9) ** 2 < 6 ** 2) volume[x + 32 * (y + 32 * z)] = 255;
  }
  const manifest = {
    id: "A726EA76-CE70-4BFC-9974-9CF3541080D0", name: "Subbrick test", description: "Synthetic sphere", variant: "raw",
    volume: { size: [28, 28, 28], voxelSpacing: [1 / 28, 1 / 28, 1 / 28], componentCount: 1,
      bytesPerComponent: 1, valueType: "uint", dataRange: [0, 255], valueRange: [0, 255], componentRanges: [[0, 255]] },
    bricking: { brickSize: 32, overlap: 2, compression: "none" },
    levels: [{ level: 0, size: [28, 28, 28], brickCount: [1, 1, 1], firstBrick: 0 }],
    bricks: [{ index: 0, min: 0, max: 255, byteLength: 32768, componentRanges: [[0, 255]], url: "/brick.bin" }],
    provenance: [
      { timestampMilliseconds: 1793529045123, text: "Downloaded from https://example.org/" + "long-source-path/".repeat(15) },
      { timestampMilliseconds: 1793532645123, text: "converted by BorgVR Converter 3.5" }
    ]
  };
  const server = http.createServer((request, response) => {
    const name = new URL(request.url, "http://localhost").pathname;
    if (name === "/favicon.ico") { response.writeHead(204); response.end(); return; }
    if (name === "/brick.bin") { response.setHeader("Content-Type", "application/octet-stream"); response.end(volume); return; }
    if (name === "/web-data/test.lz4") {
      const json = Buffer.from(JSON.stringify(manifest));
      const header = [0xf0];
      let length = json.length - 15;
      while (length >= 255) { header.push(255); length -= 255; }
      header.push(length);
      response.setHeader("X-BorgVR-Uncompressed-Length", json.length);
      response.end(Buffer.concat([Buffer.from(header), json])); return;
    }
    if (name.startsWith("/web-data/") && name.endsWith(".json")) {
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify(name.endsWith("/datasets.json") ? { datasets: [{
        id: manifest.id, name: manifest.name, description: manifest.description, metadata: "test.lz4",
        size: manifest.volume.size, voxelSpacing: manifest.volume.voxelSpacing
      }] } : {})); return;
    }
    if (name === "/gpu-tests") { response.setHeader("Content-Type", "text/html"); response.end('<!doctype html><canvas id="canvas" style="width:640px;height:480px"></canvas><div id="provenance"></div>'); return; }
    const file = path.resolve(root, name === "/" ? "index.html" : `.${decodeURIComponent(name)}`);
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { response.writeHead(404); response.end(); return; }
    response.setHeader("Content-Type", file.endsWith(".js") ? "text/javascript" : file.endsWith(".css") ? "text/css" : "text/html");
    if (file.endsWith("index.html")) { response.end(fs.readFileSync(file, "utf8").replaceAll("__BORGVR_APPLICATION_VERSION__", "test")); return; }
    fs.createReadStream(file).pipe(response);
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  let browser;
  try {
    browser = await chromium.launch({ channel: process.env.WEBGPU_TEST_BROWSER || "msedge", headless: true, args: ["--enable-unsafe-webgpu", "--use-angle=metal"] });
    const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
    page.on("console", message => { if (message.type() === "error") console.error(message.text()); });
    await page.goto(`http://127.0.0.1:${server.address().port}/gpu-tests`);
    const result = await page.evaluate(async () => {
      const { CoordinateCubeRenderer } = await import("/src/cube-renderer.js");
      const { SubbrickCache, subbrickDivisions } = await import("/src/subbrick-cache.js");
      const { TransferFunction1D } = await import("/src/transfer-function.js");
      const { renderDatasetProvenance } = await import("/src/dataset-provenance.js");
      const check = (ok, text) => { if (!ok) throw new Error(text); };
      const renderer = new CoordinateCubeRenderer(document.querySelector("canvas"));
      const errors = [];
      await renderer.initialize(message => { if (message.startsWith("WebGPU error:")) errors.push(message); });
      renderer.device.addEventListener("uncapturederror", event => errors.push(event.error.message));
      const device = renderer.device;
      const sizes = [16, 32, 64, 128];
      check(sizes.map(n => subbrickDivisions(n, 2)).join() === "1,2,4,8", "Wrong automatic subdivision");
      const reports = [];
      for (const [width, channels, size] of [[1, 1, 32], [1, 4, 32], [2, 2, 32], [2, 4, 32], [4, 1, 32], [1, 1, 64], [1, 1, 128]]) {
        const overlap = 2;
        const format = width === 1 && channels === 1 ? "r8unorm" : width === 2 && channels === 1 ? "rg8unorm" : "rgba8unorm";
        const atlas = {
          brickSize: size, componentCount: channels, bytesPerComponent: width, slotCapacity: 1,
          atlasBricksPerAxis: 1, loadedBricks: new Map([[0, 0]]), manifest: { bricking: { overlap } },
          texture: device.createTexture({ size: [size, size, size], dimension: "3d", format, usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST })
        };
        if (width === 2 && channels > 2) atlas.secondaryTexture = device.createTexture({ size: [size, size, size], dimension: "3d", format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
        const bytesPerVoxel = format === "r8unorm" ? 1 : format === "rg8unorm" ? 2 : 4;
        const bytesPerRow = Math.ceil(size * bytesPerVoxel / 256) * 256;
        const input = new Uint8Array(bytesPerRow * size * size);
        // Only the last cell is nonzero, with a complete interpolation halo.
        const divisions = subbrickDivisions(size, overlap);
        const lastCellStart = overlap + Math.floor((divisions - 1) * (size - 2 * overlap) / divisions) + 2;
        for (let z = lastCellStart; z < size; z++) for (let y = lastCellStart; y < size; y++) for (let x = lastCellStart; x < size; x++) {
          input.fill(255, (z * size + y) * bytesPerRow + x * bytesPerVoxel, (z * size + y) * bytesPerRow + (x + 1) * bytesPerVoxel);
        }
        device.queue.writeTexture({ texture: atlas.texture }, input, { bytesPerRow, rowsPerImage: size }, [size, size, size]);
        if (atlas.secondaryTexture) device.queue.writeTexture({ texture: atlas.secondaryTexture }, input, { bytesPerRow, rowsPerImage: size }, [size, size, size]);
        const cache = new SubbrickCache(device, atlas);
        cache.invalidate(0);
        const tf = new TransferFunction1D(256);
        tf.data.fill(0); tf.data[tf.data.length - 1] = 255; tf.updateVisibilityRange();
        async function readMask(mode = 0, threshold = 0.5) {
          const encoder = device.createCommandEncoder();
          cache.prepare(encoder, atlas, Array(channels).fill(tf), [1, 1, 1, 1], mode, threshold);
          const readback = device.createBuffer({ size: cache.maskStride * 4, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
          encoder.copyBufferToBuffer(cache.masks, 0, readback, 0, cache.maskStride * 4);
          device.queue.submit([encoder.finish()]);
          await readback.mapAsync(GPUMapMode.READ);
          const mask = Array.from(new Uint32Array(readback.getMappedRange()));
          readback.unmap(); readback.destroy();
          return mask;
        }
        // Reading masks is test-only; production keeps them on the GPU.
        const mask = await readMask();
        const lastCell = divisions ** 3 - 1;
        const expectedBits = (1 << (lastCell & 31)) >>> 0;
        check(mask[0] === 1 && mask[1 + Math.floor(lastCell / 32)] === expectedBits, `Wrong sparse mask (${width}/${channels}/${size}): ${mask}; GPU: ${errors.join("; ")}`);
        check((await readMask(2))[1 + Math.floor(lastCell / 32)] === expectedBits, "ISO occupancy differs");
        tf.data.fill(255); tf.updateVisibilityRange();
        check((await readMask())[0] === 2, "TF change did not reclassify cached ranges");
        tf.data.fill(0); tf.updateVisibilityRange();
        check((await readMask())[0] === 0, "Transparent TF did not empty subbricks");
        tf.data[tf.data.length - 1] = 255; tf.updateVisibilityRange();
        input.fill(0);
        const boundary = overlap + Math.floor((size - 2 * overlap) / divisions);
        const byte = (boundary * size + boundary) * bytesPerRow + boundary * bytesPerVoxel;
        input.fill(255, byte, byte + bytesPerVoxel);
        function replaceSlot() {
          device.queue.writeTexture({ texture: atlas.texture }, input, { bytesPerRow, rowsPerImage: size }, [size, size, size]);
          if (atlas.secondaryTexture) device.queue.writeTexture({ texture: atlas.secondaryTexture }, input, { bytesPerRow, rowsPerImage: size }, [size, size, size]);
          cache.invalidate(0);
        }
        replaceSlot();
        const haloMask = await readMask();
        let occupied = 0;
        for (let bits of haloMask.slice(1)) { while (bits) { occupied++; bits = (bits & (bits - 1)) >>> 0; } }
        check(occupied === 8, "Interpolation halo lost a boundary sample");
        input.fill(0); replaceSlot();
        check((await readMask())[0] === 0, "Reused atlas slot retained stale occupancy");
        cache.destroy(); atlas.texture.destroy(); atlas.secondaryTexture?.destroy();
        reports.push(`${width}-byte/${channels}-channel/${size}³`);
      }
      const container = document.querySelector("#provenance");
      renderDatasetProvenance(container, [{ timestampMilliseconds: 1793529045123, text: '<script>unsafe()</script> source' }]);
      check(container.querySelectorAll("script").length === 0 && container.textContent.includes("<script>"), "Unsafe provenance markup");
      check(container.querySelector("time").dateTime === "2026-11-01T10:30:45.123Z", "Wrong provenance timestamp");
      renderDatasetProvenance(container, []);
      check(container.textContent === "No provenance recorded.", "Empty provenance state missing");
      const manifest = {
        id: "A726EA76-CE70-4BFC-9974-9CF3541080D0", baseURL: location.origin + "/",
        volume: { size: [28, 28, 28], voxelSpacing: [1 / 28, 1 / 28, 1 / 28], componentCount: 1,
          bytesPerComponent: 1, valueType: "uint", dataRange: [0, 255], valueRange: [0, 255], componentRanges: [[0, 255]] },
        bricking: { brickSize: 32, overlap: 2, compression: "none" },
        levels: [{ level: 0, size: [28, 28, 28], brickCount: [1, 1, 1], firstBrick: 0 }],
        bricks: [{ index: 0, min: 0, max: 255, byteLength: 32768, componentRanges: [[0, 255]], url: location.origin + "/brick.bin" }]
      };
      renderer.setPersistentBrickCacheEnabled(false);
      renderer.setDataset(manifest);
      const deadline = performance.now() + 10000;
      while (renderer.brickAtlas.loadedBricks.size < 1 && performance.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
      check(renderer.brickAtlas.loadedBricks.size === 1, "Fixture brick did not load");
      window.testRenderer = renderer;
      window.testErrors = errors;
      await device.queue.onSubmittedWorkDone();
      check(errors.length === 0, errors.join("\n"));
      return { reports, errors };
    });
    assert.equal(result.errors.length, 0);
    const screenshots = process.env.WEBGPU_SCREENSHOTS || "/private/tmp/borgvr-web-optimizations";
    fs.mkdirSync(screenshots, { recursive: true });
    for (const mode of ["tf", "tf-lighting", "iso"]) {
      const images = [];
      for (const enabled of [false, true]) {
        await page.evaluate(async ({ mode, enabled }) => {
          const renderer = window.testRenderer;
          renderer.setRenderMode(mode);
          renderer.setRenderOptimizations({ subbrickSkipping: enabled, opacityAdaptiveSampling: false });
          renderer.draw();
          await renderer.device.queue.onSubmittedWorkDone();
        }, { mode, enabled });
        images.push(await page.locator("canvas").screenshot({ path: path.join(screenshots, `${mode}-${enabled}.png`) }));
      }
      assert.deepEqual(images[1], images[0], `${mode}: subbrick skipping shifted the sampling lattice`);
    }
    await page.evaluate(async () => {
      testRenderer.setRenderMode("tf");
      testRenderer.setRenderOptimizations({ subbrickSkipping: true, opacityAdaptiveSampling: true });
      testRenderer.draw();
      await testRenderer.device.queue.onSubmittedWorkDone();
      if (testErrors.length) throw new Error(testErrors.join("\n"));
    });
    await page.locator("canvas").screenshot({ path: path.join(screenshots, "adaptive.png") });
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.locator(".dataset-button").click();
    await page.locator("#info-button:not([disabled])").waitFor();
    await page.locator("#info-button").click();
    await page.locator(".provenance-list li").last().waitFor();
    assert.equal(await page.locator(".provenance-list li").count(), 2);
    await page.locator("#info-button").click();
    const performancePanel = page.locator('[data-ui-panel="render-performance"]');
    if (!await performancePanel.evaluate(element => element.open)) await performancePanel.locator("summary").click();
    const toggle = page.locator('[data-render-optimization="subbrickSkipping"]');
    assert.ok(await toggle.isChecked());
    await toggle.uncheck();
    assert.equal(await page.evaluate(() => localStorage.getItem("borgvr.subbrickSkipping")), "0");
    await toggle.check();
    await page.locator("#controls-collapse-button").click();
    await page.locator("#info-button").click();
    await page.locator(".provenance-list").scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(screenshots, "desktop-info.png") });
    await page.setViewportSize({ width: 393, height: 852 });
    await page.locator("#dataset-panel-toggle").click();
    await page.locator(".provenance-list").scrollIntoViewIfNeeded();
    assert.ok(await page.locator("#dataset-info").evaluate(element => element.scrollWidth <= element.clientWidth + 1), "Provenance overflows on mobile");
    await page.screenshot({ path: path.join(screenshots, "mobile-info.png") });
    console.log("WebGPU pipeline, GPU subbrick occupancy and provenance tests passed:", result.reports.join(", "));
  } finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
