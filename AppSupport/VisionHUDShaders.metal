struct TFHUDVaryings {
  float4 position [[position]];
  float2 uv;
};

vertex TFHUDVaryings vertexShaderTFPanel(uint vid [[vertex_id]],
                                           ushort ampId [[amplification_id]],
                                           constant float4x4 *mvpPerView [[buffer(20)]],
                                           constant float2 &panelSizeMeters [[buffer(21)]])
{
  TFHUDVaryings out;

  float w = panelSizeMeters.x;
  float h = panelSizeMeters.y;

  // Local quad in meters, centered at origin, lying on z=0 plane.
  float3 p;
  float2 uv;

  // Two triangles (6 verts)
  switch (vid) {
    case 0: p = float3(-0.5*w, -0.5*h, 0.1); uv = float2(0.0, 0.0); break;
    case 1: p = float3( 0.5*w, -0.5*h, 0.1); uv = float2(1.0, 0.0); break;
    case 2: p = float3(-0.5*w,  0.5*h, 0.0); uv = float2(0.0, 1.0); break;
    case 3: p = float3( 0.5*w, -0.5*h, 0.1); uv = float2(1.0, 0.0); break;
    case 4: p = float3( 0.5*w,  0.5*h, 0.0); uv = float2(1.0, 1.0); break;
    default: p = float3(-0.5*w, 0.5*h, 0.0); uv = float2(0.0, 1.0); break;
  }

  float4 localPos = float4(p.x, p.y, p.z, 1.0);

  // Apply correct per-eye MVP (ampId selects view)
  out.position = mvpPerView[ampId] * localPos;
  out.uv = uv;

  return out;
}

static inline float gridLine(float x, float cells, float thickness) {
  float gx = fabs(fract(x * cells) - 0.5);
  float w  = fwidth(x * cells) * thickness;
  return 1.0 - smoothstep(0.0, w, gx);
}

fragment float4 fragmentShaderTFHUD(TFHUDVaryings in [[stage_in]],
                                    texture1d<float> tfTex [[texture(TextureIndexTransferFunction)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);

  float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
  float4 tf = tfTex.sample(s, uv.x);

  // Panel style (tune as needed)
  constexpr float panelAlpha = 0.85;
  constexpr float ribbonFrac = 0.14; // top ribbon height fraction
  constexpr float minBorder  = 0.01;

  // Border mask (anti-aliased)
  float2 edge = min(uv, 1.0 - uv);
  float edgeDist = min(edge.x, edge.y);
  float edgeWidth = max(fwidth(edgeDist) * 2.0, minBorder);
  float borderMask = 1.0 - smoothstep(0.0, edgeWidth, edgeDist);

  // Ribbon region (top): show TF colors over checkerboard using TF alpha
  if (uv.y > 1.0 - (ribbonFrac-0.01)) {
    float2 ruv = float2(uv.x, (uv.y - (1.0 - ribbonFrac)) / ribbonFrac);

    float cx = floor(ruv.x * 24.0);
    float cy = floor(ruv.y * 2.0);
    float check = fmod(cx + cy, 2.0);

    float3 bgA = float3(0.20);
    float3 bgB = float3(0.12);
    float3 bg  = mix(bgA, bgB, check);

    float3 col = mix(bg, tf.rgb, tf.a);

    // Dark border
    col = mix(col, float3(0.0), borderMask);

    return float4(col, panelAlpha);
  }

  // Curve area (below ribbon)
  float curveY = uv.y / (1.0 - ribbonFrac); // normalize to [0..1] within curve area

  float3 bg = float3(0.06);
  float  gx = gridLine(uv.x,    10.0, 1.0);
  float  gy = gridLine(curveY,  10.0, 1.0);
  bg += (gx + gy) * 0.06;

  float lw = fwidth(curveY) * 5.0;

  float ar = 1.0 - smoothstep(0.0, lw, fabs(curveY - tf.r));
  float ag = 1.0 - smoothstep(0.0, lw, fabs(curveY - tf.g));
  float ab = 1.0 - smoothstep(0.0, lw, fabs(curveY - tf.b));
  float aa = 1.0 - smoothstep(0.0, lw, fabs(curveY - tf.a));

  float3 col = bg;

  // Draw curves (simple mixing)
  col = mix(col, float3(1.0, 0.2, 0.2), ar); // R
  col = mix(col, float3(0.2, 1.0, 0.2), ag); // G
  col = mix(col, float3(0.2, 0.2, 1.0), ab); // B
  col = mix(col, float3(1.0),          aa);  // A (white)


  // Dark border
  col = mix(col, float3(0.0), borderMask);

  return float4(col, panelAlpha);
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
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
