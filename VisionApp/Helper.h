#ifndef Helper_h
#define Helper_h

#include <metal_stdlib>
#import "ShaderTypes.h"

using namespace metal;

#ifndef MAX_RETRIES
#define MAX_RETRIES 10
#endif

/**
 Performs under compositing of two RGBA colors.

 Applies the “under” blending mode where `current` is drawn under `last`.

 - Parameters:
 - current: The foreground color (rgba).
 - last: The background color (rgba).
 - Returns: The composited color with pre-multiplied alpha.
 */
half4 under(half4 current, half4 last) {
  // Blend RGB: last.rgb + (1 − last.a) × current.a × current.rgb
  last.rgb = clamp(last.rgb + (1.0 - last.a) * current.a * current.rgb, 0.0, 1.0);
  // Blend alpha: last.a + (1 − last.a) × current.a
  last.a   = min(1.0, last.a + (1.0 - last.a) * current.a);
  return last;
}

/**
 Swaps two floating-point values in thread-local memory.

 - Parameters:
 - a: The first float to swap.
 - b: The second float to swap.
 */
inline void swap(thread float &a, thread float &b) {
  float temp = a;
  a = b;
  b = temp;
}

/**
 Computes the entry point of a ray into an axis-aligned unit cube.

 - Parameters:
 - P: The ray origin in volume space.
 - Q: The ray end point (origin + direction).
 - params: FragmentUniforms containing `cubeBounds` (min and max corners).
 - Returns: The point where the ray first enters the cube, or `P` if it starts inside or misses.
 */
inline float3 computeEntryPoint(float3 P, float3 Q, FragmentUniforms params) {
  const float3 minB = params.cubeBounds[0];
  const float3 maxB = params.cubeBounds[1];

  // If the origin is already inside the cube, return it directly.
  if ((P.x >= minB.x && P.x <= maxB.x) &&
      (P.y >= minB.y && P.y <= maxB.y) &&
      (P.z >= minB.z && P.z <= maxB.z)) {
    return P;
  }

  float3 d = Q - P;
  const float eps = 1e-6;

  // Compute intersection t-values along each axis, avoiding division by zero.
  float tx1 = (minB.x - P.x) / (abs(d.x) > eps ? d.x : copysign(eps, d.x));
  float tx2 = (maxB.x - P.x) / (abs(d.x) > eps ? d.x : copysign(eps, d.x));
  if (d.x < 0.0) swap(tx1, tx2);

  float ty1 = (minB.y - P.y) / (abs(d.y) > eps ? d.y : copysign(eps, d.y));
  float ty2 = (maxB.y - P.y) / (abs(d.y) > eps ? d.y : copysign(eps, d.y));
  if (d.y < 0.0) swap(ty1, ty2);

  float tz1 = (minB.z - P.z) / (abs(d.z) > eps ? d.z : copysign(eps, d.z));
  float tz2 = (maxB.z - P.z) / (abs(d.z) > eps ? d.z : copysign(eps, d.z));
  if (d.z < 0.0) swap(tz1, tz2);

  // Compute overall entry and exit t-values.
  float tEntry = max(tx1, max(ty1, tz1));
  float tExit  = min(tx2, min(ty2, tz2));

  // If there is a valid intersection in front of the origin, return entry point.
  if (tEntry <= tExit && tExit >= 0.0) {
    return P + tEntry * d;
  }

  // No intersection; return original point as sentinel.
  return P;
}

/**
 Computes Blinn-Phong lighting for a point on the isosurface.

 - Parameters:
 - position: The point position in view space.
 - normal: The surface normal at the point.
 - color: The base color of the material.
 - Returns: The shaded color after ambient, diffuse, and specular contributions.
 */
inline half3 lighting(half3 position, half3 normal, half3 color) {
  const half3 ambientLight  = half3(0.1, 0.1, 0.1);
  const half3 diffuseLight  = half3(0.5, 0.5, 0.5);
  const half3 specularLight = half3(0.8, 0.8, 0.8);
  const half  shininess     = 8.0;

  half3 viewDir    = normalize(-position);
  half3 lightDir   = viewDir; // light at camera for simplicity
  half3 reflection = reflect(-lightDir, normal);

  // Two-sided diffuse
  half diffuse  = fmax(abs(dot(normal, lightDir)), 0);
  // One-sided specular
  half specular = pow(fmax(dot(viewDir, reflection), 0), shininess);

  half3 shaded =
  color * ambientLight +
  color * diffuseLight * diffuse +
  specularLight * specular;
  return clamp(shaded, 0.0, 1.0);
}

/**
 Computes the central difference gradient at a point in the volume.

 - Parameters:
 - vCenter: The texture coordinate in [0,1]³.
 - sampleDelta: The delta in texture coordinates per axis.
 - volume: The 3D volume texture to sample.
 - s: The sampler state.
 - Returns: The gradient vector (dI/dx, dI/dy, dI/dz).
 */
float3 computeGradient(
                       float3 vCenter,
                       float3 sampleDelta,
                       texture3d<half, access::sample> volume [[texture(0)]],
                       sampler s
                       ) {
  float fVolumValXp = volume.sample(s, vCenter + float3(+sampleDelta.x, 0, 0)).r;
  float fVolumValXm = volume.sample(s, vCenter + float3(-sampleDelta.x, 0, 0)).r;
  float fVolumValYp = volume.sample(s, vCenter + float3(0, +sampleDelta.y, 0)).r;
  float fVolumValYm = volume.sample(s, vCenter + float3(0, -sampleDelta.y, 0)).r;
  float fVolumValZp = volume.sample(s, vCenter + float3(0, 0, +sampleDelta.z)).r;
  float fVolumValZm = volume.sample(s, vCenter + float3(0, 0, -sampleDelta.z)).r;

  return float3(
                fVolumValXp - fVolumValXm,
                fVolumValYp - fVolumValYm,
                fVolumValZp - fVolumValZm
                ) / 2.0;
}

/**
 Safely normalizes a vector, returning zero if the length is zero.

 - Parameter v: The input vector.
 - Returns: The normalized vector, or (0,0,0) if `v` has zero length.
 */
inline float3 safeNormalize(float3 v) {
  float len = length(v);
  return (len > 0.0) ? (v / len) : float3(0);
}

/**
 Computes a surface normal at a point in the volume by sampling gradients and scaling.

 - Parameters:
 - vCenter: The texture coordinate in [0,1]³.
 - volSize: The volume dimensions in voxels.
 - DomainScale: The physical scaling applied to the gradient.
 - volume: The 3D volume texture.
 - s: The sampler state.
 - Returns: A unit-length normal vector.
 */
float3 computeNormal(
                     float3 vCenter,
                     float3 volSize,
                     float3 DomainScale,
                     texture3d<half, access::sample> volume [[texture(0)]],
                     sampler s
                     ) {
  float3 vGradient = computeGradient(vCenter, 1/volSize, volume, s);
  float3 vNormal   = vGradient * DomainScale;
  return safeNormalize(vNormal);
}

/**
 Refines the isosurface intersection point using successive bisection.

 - Parameters:
 - vRayDir: The ray direction vector.
 - vCurrentPos: The current intersection estimate.
 - fIsoval: The isovalue threshold.
 - volume: The 3D volume texture.
 - s: The sampler state.
 - Returns: A refined intersection point closer to the isosurface.
 */
inline float3 refineIsosurface(
                               float3 vRayDir,
                               float3 vCurrentPos,
                               float fIsoval,
                               texture3d<half, access::sample> volume [[texture(0)]],
                               sampler s
                               ) {
  vRayDir    /= 2.0;
  vCurrentPos -= vRayDir;
  for (int i = 0; i < 5; i++) {
    vRayDir /= 2.0;
    float voxel = volume.sample(s, vCurrentPos).x;
    if (voxel >= fIsoval) {
      vCurrentPos -= vRayDir;
    } else {
      vCurrentPos += vRayDir;
    }
    if (abs(voxel - fIsoval) < 0.001) break;
  }
  return vCurrentPos;
}

#endif // Helper_h

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
