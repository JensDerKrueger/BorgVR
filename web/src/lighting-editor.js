const DEFAULT_LIGHTING = Object.freeze({
  direction: [0, 0, 1],
  ambientColor: [0.15, 0.15, 0.15],
  diffuseColor: [0.8, 0.8, 0.8],
  specularColor: [1, 1, 1]
});

export function installLightingEditor({
  canvas,
  ambientInput,
  diffuseInput,
  specularInput,
  resetButton,
  onChange
}) {
  let lighting = cloneLighting(DEFAULT_LIGHTING);
  let dragStartVector = null;
  let dragStartDirection = null;

  ambientInput.value = colorToHex(lighting.ambientColor);
  diffuseInput.value = colorToHex(lighting.diffuseColor);
  specularInput.value = colorToHex(lighting.specularColor);

  function publish() {
    drawLightingSphere(canvas, lighting);
    onChange?.(cloneLighting(lighting));
  }

  function updateColors() {
    lighting.ambientColor = colorFromHex(ambientInput.value);
    lighting.diffuseColor = colorFromHex(diffuseInput.value);
    lighting.specularColor = colorFromHex(specularInput.value);
    publish();
  }

  [ambientInput, diffuseInput, specularInput].forEach((input) => {
    input.addEventListener("input", updateColors);
  });

  canvas.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    canvas.setPointerCapture(event.pointerId);
    dragStartVector = arcballVector(event, canvas);
    dragStartDirection = [...lighting.direction];
  });

  canvas.addEventListener("pointermove", (event) => {
    if (!dragStartVector || !dragStartDirection) {
      return;
    }
    event.preventDefault();
    const current = arcballVector(event, canvas);
    lighting.direction = rotateBetween(dragStartDirection, dragStartVector, current);
    publish();
  });

  function endDrag(event) {
    if (canvas.hasPointerCapture(event.pointerId)) {
      canvas.releasePointerCapture(event.pointerId);
    }
    dragStartVector = null;
    dragStartDirection = null;
  }
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);

  resetButton.addEventListener("click", () => {
    lighting = cloneLighting(DEFAULT_LIGHTING);
    ambientInput.value = colorToHex(lighting.ambientColor);
    diffuseInput.value = colorToHex(lighting.diffuseColor);
    specularInput.value = colorToHex(lighting.specularColor);
    publish();
  });

  publish();
  return {
    getLighting: () => cloneLighting(lighting)
  };
}

function drawLightingSphere(canvas, lighting) {
  const context = canvas.getContext("2d", { alpha: true });
  const width = canvas.width;
  const height = canvas.height;
  const image = context.createImageData(width, height);
  const direction = normalize(lighting.direction);

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const nx = (x + 0.5) / width * 2 - 1;
      const ny = 1 - (y + 0.5) / height * 2;
      const radiusSquared = nx * nx + ny * ny;
      const offset = (y * width + x) * 4;
      if (radiusSquared > 1) {
        image.data[offset + 3] = 0;
        continue;
      }

      const normal = [nx, ny, Math.sqrt(Math.max(0, 1 - radiusSquared))];
      const normalLightDot = dot(normal, direction);
      const diffuse = Math.abs(normalLightDot);
      const reflection = normal.map((value, index) => 2 * normalLightDot * value - direction[index]);
      const specular = Math.pow(Math.max(reflection[2], 0), 8);
      for (let channel = 0; channel < 3; channel += 1) {
        const value = lighting.ambientColor[channel] +
          lighting.diffuseColor[channel] * diffuse +
          lighting.specularColor[channel] * specular;
        image.data[offset + channel] = Math.round(clamp(value, 0, 1) * 255);
      }
      image.data[offset + 3] = 255;
    }
  }
  context.clearRect(0, 0, width, height);
  context.putImageData(image, 0, 0);
}

function arcballVector(event, canvas) {
  const rect = canvas.getBoundingClientRect();
  const diameter = Math.max(1, Math.min(rect.width, rect.height));
  let x = (2 * (event.clientX - rect.left) - rect.width) / diameter;
  let y = (rect.height - 2 * (event.clientY - rect.top)) / diameter;
  const radiusSquared = x * x + y * y;
  if (radiusSquared <= 1) {
    return [x, y, Math.sqrt(1 - radiusSquared)];
  }
  const inverseLength = 1 / Math.sqrt(radiusSquared);
  x *= inverseLength;
  y *= inverseLength;
  return [x, y, 0];
}

function rotateBetween(vector, from, to) {
  const axis = cross(from, to);
  const axisLength = Math.hypot(...axis);
  if (axisLength < 1e-7) {
    return [...vector];
  }
  const normalizedAxis = axis.map((value) => value / axisLength);
  const angle = Math.atan2(axisLength, clamp(dot(from, to), -1, 1));
  const cosine = Math.cos(angle);
  const sine = Math.sin(angle);
  const axisDot = dot(normalizedAxis, vector);
  return normalize(vector.map((value, index) =>
    value * cosine +
    cross(normalizedAxis, vector)[index] * sine +
    normalizedAxis[index] * axisDot * (1 - cosine)
  ));
}

function colorFromHex(hex) {
  const value = Number.parseInt(hex.slice(1), 16);
  return [((value >> 16) & 255) / 255, ((value >> 8) & 255) / 255, (value & 255) / 255];
}

function colorToHex(color) {
  return `#${color.map((value) => Math.round(clamp(value, 0, 1) * 255).toString(16).padStart(2, "0")).join("")}`;
}

function cloneLighting(lighting) {
  return {
    direction: [...lighting.direction],
    ambientColor: [...lighting.ambientColor],
    diffuseColor: [...lighting.diffuseColor],
    specularColor: [...lighting.specularColor]
  };
}

function normalize(vector) {
  const length = Math.hypot(...vector);
  return length > 1e-7 ? vector.map((value) => value / length) : [0, 0, 1];
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

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}
