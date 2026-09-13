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
  float w  = max(fwidth(x * cells) * thickness, 0.025);
  return 1.0 - smoothstep(0.0, w, gx);
}

static inline float markerMask(float2 uv, float4 hitUVState, float2 panelSizeMeters) {
  if (hitUVState.z <= 0.001) {
    return 0.0;
  }

  float minPanelSize = min(panelSizeMeters.x, panelSizeMeters.y);
  float2 markerDelta = abs(uv - hitUVState.xy) * panelSizeMeters;
  float lineWidth = max(minPanelSize * 0.006, min(fwidth(uv.x) * panelSizeMeters.x,
                                                  fwidth(uv.y) * panelSizeMeters.y) * 2.0);
  float markerRadius = minPanelSize * 0.018;
  float marker = 1.0 - smoothstep(markerRadius, markerRadius + lineWidth, length(markerDelta));
  float cross = max(
    1.0 - smoothstep(0.0, lineWidth, markerDelta.x),
    1.0 - smoothstep(0.0, lineWidth, markerDelta.y)
  );
  float crossExtent = 1.0 - smoothstep(minPanelSize * 0.04, minPanelSize * 0.055,
                                       max(markerDelta.x, markerDelta.y));
  return max(marker, cross * crossExtent) * saturate(hitUVState.z);
}

fragment float4 fragmentShaderTFHUD(TFHUDVaryings in [[stage_in]],
                                    texture1d<float> tfTex [[texture(TextureIndexTransferFunction)]],
                                    constant float2 &panelSizeMeters [[buffer(21)]],
                                    constant uint &isFocused [[buffer(22)]],
                                    constant float4 &hitUVState [[buffer(23)]],
                                    constant uint &channelMask [[buffer(24)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);

  float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
  float4 tf = tfTex.sample(s, uv.x);

  // Panel style (tune as needed)
  constexpr float panelAlpha = 0.85;
  constexpr float ribbonFrac = 0.14; // top ribbon height fraction
  constexpr float minBorder = 0.018;
  float curveHeight = 1.0 - ribbonFrac;

  // Border mask (anti-aliased)
  float2 edge = min(uv, 1.0 - uv);
  float edgeDist = min(edge.x, edge.y);
  float edgeWidth = max(fwidth(edgeDist) * 2.0, minBorder);
  float borderMask = 1.0 - smoothstep(0.0, edgeWidth, edgeDist);

  // Curve area (below ribbon)
  float curveY = clamp(uv.y / curveHeight, 0.0, 1.0); // normalize to [0..1] within curve area

  float3 bg = float3(0.06);
  float  gx = gridLine(uv.x,    10.0, 1.6);
  float  gy = gridLine(curveY,  10.0, 1.6);
  bg += (gx + gy) * 0.035;

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

  float2 ruv = float2(uv.x, clamp((uv.y - curveHeight) / ribbonFrac, 0.0, 1.0));
  float cx = floor(ruv.x * 24.0);
  float cy = floor(ruv.y * 2.0);
  float check = fmod(cx + cy, 2.0);
  float3 ribbonBgA = float3(0.20);
  float3 ribbonBgB = float3(0.12);
  float3 ribbonBg = mix(ribbonBgA, ribbonBgB, check);
  float3 ribbonCol = mix(ribbonBg, tf.rgb, tf.a);

  int channelIndex = min(3, int(floor(uv.x * 4.0)));
  uint channelBit = 1u << uint(channelIndex);
  bool channelActive = (channelMask & channelBit) != 0u;
  float3 channelColor = channelIndex == 0 ? float3(1.0, 0.12, 0.10)
                       : channelIndex == 1 ? float3(0.10, 0.95, 0.18)
                       : channelIndex == 2 ? float3(0.20, 0.32, 1.0)
                                           : float3(1.0);
  float segmentX = fract(uv.x * 4.0);
  float segmentFill = smoothstep(0.08, 0.20, segmentX)
                    * (1.0 - smoothstep(0.80, 0.92, segmentX));
  float stripeY = clamp((uv.y - curveHeight) / ribbonFrac, 0.0, 1.0);
  float stripeMask = segmentFill
                   * smoothstep(0.08, 0.24, stripeY)
                   * (1.0 - smoothstep(0.46, 0.68, stripeY));
  float3 inactiveColor = mix(ribbonCol, float3(0.04), 0.55);
  float3 activeColor = mix(ribbonCol, channelColor, 0.72);
  ribbonCol = mix(ribbonCol, channelActive ? activeColor : inactiveColor, stripeMask);

  float ribbonBlendWidth = max(fwidth(uv.y) * 4.0, 0.025);
  float ribbonMask = smoothstep(curveHeight - ribbonBlendWidth,
                                curveHeight + ribbonBlendWidth,
                                uv.y);
  col = mix(col, ribbonCol, ribbonMask);

  col = mix(col, float3(0.0), borderMask);
  col = mix(col, float3(1.0, 0.9, 0.05), markerMask(uv, hitUVState, panelSizeMeters));

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
