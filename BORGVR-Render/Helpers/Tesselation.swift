/**
 A structure representing a tessellated mesh.

 The `Tesselation` structure contains vertex data including positions, normals, tangents,
 texture coordinates, and indices that define the mesh topology. It also provides several
 static methods to generate common 3D geometries.
 */
struct Tesselation {
  /// An array of vertex positions.
  var vertices: [SIMD3<Float>] = []
  /// An array of vertex normals.
  var normals: [SIMD3<Float>] = []
  /// An array of vertex tangents.
  var tangents: [SIMD3<Float>] = []
  /// An array of texture coordinates.
  var texCoords: [SIMD2<Float>] = []
  /// An array of indices defining the mesh connectivity.
  var indices: [UInt32] = []

  /// The mathematical constant π.
  static let PI: Float = 3.14159265358979323846

  /**
   Generates a tessellated sphere.

   The sphere is defined by its center and radius, and is approximated using a specified number
   of sectors (longitude) and stacks (latitude).

   - Parameters:
   - center: The center point of the sphere.
   - radius: The radius of the sphere.
   - sectorCount: The number of sectors (longitudinal divisions).
   - stackCount: The number of stacks (latitudinal divisions).
   - Returns: A `Tesselation` containing the vertex data for the generated sphere.
   */
  static func genSphere(center: SIMD3<Float>, radius: Float,
                        sectorCount: UInt32, stackCount: UInt32) -> Tesselation {
    var tess = Tesselation()

    let lengthInv: Float = 1.0 / radius
    let sectorStep: Float = 2.0 * PI / Float(sectorCount)
    let stackStep: Float = PI / Float(stackCount)

    for i in 0...stackCount {
      let stackAngle = PI / 2.0 - Float(i) * stackStep
      let xy = radius * cosf(stackAngle)
      let z = radius * sinf(stackAngle)

      for j in 0...sectorCount {
        let sectorAngle = Float(j) * sectorStep

        let x = xy * cosf(sectorAngle)
        let y = xy * sinf(sectorAngle)

        tess.vertices.append(SIMD3<Float>(x: center.x + x,
                                          y: center.y + y,
                                          z: center.z + z))
        tess.normals.append(SIMD3<Float>(x: x * lengthInv,
                                         y: y * lengthInv,
                                         z: z * lengthInv))

        let nextSectorAngle = Float(j + 1) * sectorStep
        let nx = xy * cosf(nextSectorAngle)
        let ny = xy * sinf(nextSectorAngle)

        let n = SIMD3<Float>(x: x * lengthInv, y: y * lengthInv, z: z * lengthInv)
        let t = normalize(SIMD3<Float>(x: nx, y: ny, z: z) - SIMD3<Float>(x: x, y: y, z: z))
        let b = cross(n, t)
        let tCorr = cross(b, n)

        tess.normals.append(tCorr)
        tess.texCoords.append(SIMD2<Float>(x: Float(j) / Float(sectorCount),
                                           y: 1.0 - Float(i) / Float(stackCount)))
      }
    }

    for i in 0..<stackCount {
      var k1 = i * (sectorCount + 1)
      var k2 = k1 + sectorCount + 1

      for _ in 0..<sectorCount {
        if i != 0 {
          tess.indices.append(k1)
          tess.indices.append(k2)
          tess.indices.append(k1 + 1)
        }

        if i != (stackCount - 1) {
          tess.indices.append(k1 + 1)
          tess.indices.append(k2)
          tess.indices.append(k2 + 1)
        }

        k1 += 1
        k2 += 1
      }
    }

    return tess
  }

  /**
   Generates a tessellated rectangle.

   The rectangle is centered at a specified point with a given width and height.

   - Parameters:
   - center: The center point of the rectangle.
   - width: The width of the rectangle.
   - height: The height of the rectangle.
   - Returns: A `Tesselation` containing the vertex data for the generated rectangle.
   */
  static func genRectangle(center: SIMD3<Float>, width: Float, height: Float) -> Tesselation {
    let u = SIMD3<Float>(x: width / 2.0, y: 0.0, z: 0.0)
    let v = SIMD3<Float>(x: 0.0, y: height / 2.0, z: 0.0)
    return genRectangle(a: center - u - v, b: center + u - v,
                        c: center + u + v, d: center - u + v)
  }

  /**
   Generates a tessellated rectangle given its four corner vertices.

   The vertices should be specified in order so that they form a quadrilateral.

   - Parameters:
   - a: The first corner of the rectangle.
   - b: The second corner of the rectangle.
   - c: The third corner of the rectangle.
   - d: The fourth corner of the rectangle.
   - Returns: A `Tesselation` containing the vertex data for the generated rectangle.
   */
  static func genRectangle(a: SIMD3<Float>, b: SIMD3<Float>,
                           c: SIMD3<Float>, d: SIMD3<Float>) -> Tesselation {
    var tess = Tesselation()

    let u = b - a
    let v = c - a

    tess.vertices = [a, b, c, d]

    let normal = normalize(cross(u, v))

    tess.normals = [normal, normal, normal, normal]

    let tangent = normalize(u)
    tess.tangents = [tangent, tangent, tangent, tangent]

    tess.texCoords = [
      SIMD2<Float>(x: 0.0, y: 0.0),
      SIMD2<Float>(x: 1.0, y: 0.0),
      SIMD2<Float>(x: 1.0, y: 1.0),
      SIMD2<Float>(x: 0.0, y: 1.0)
    ]

    tess.indices = [0, 1, 2, 0, 2, 3]

    return tess
  }

  /**
   Generates a tessellated brick (box).

   The brick is defined by its center and size. Texture coordinates are scaled by the provided
   `texScale` values.

   - Parameters:
   - center: The center point of the brick.
   - size: A vector representing the brick's width, height, and depth.
   - texScale: A vector containing the texture scale factors for each corresponding face.
   - Returns: A `Tesselation` containing the vertex data for the generated brick.
   */
  static func genBrick(center: SIMD3<Float>, size: SIMD3<Float>,
                       texScale: SIMD3<Float>) -> Tesselation {
    var tess = Tesselation()

    let E = center - size / 2.0
    let C = center + size / 2.0

    let A = SIMD3<Float>(x: E.x, y: E.y, z: C.z)
    let B = SIMD3<Float>(x: C.x, y: E.y, z: C.z)
    let D = SIMD3<Float>(x: E.x, y: C.y, z: C.z)
    let F = SIMD3<Float>(x: C.x, y: E.y, z: E.z)
    let G = SIMD3<Float>(x: C.x, y: C.y, z: E.z)
    let H = SIMD3<Float>(x: E.x, y: C.y, z: E.z)

    tess.vertices = [
      // front
      A, B, C, D,

      // back
      F, E, H, G,

      // left
      E, A, D, H,

      // right
      B, F, G, C,

      // top
      D, C, G, H,

      // bottom
      B, A, E, F
    ]

    tess.normals = [
      // front
      SIMD3<Float>(0.0, 0.0, 1.0),
      SIMD3<Float>(0.0, 0.0, 1.0),
      SIMD3<Float>(0.0, 0.0, 1.0),
      SIMD3<Float>(0.0, 0.0, 1.0),

      // back
      SIMD3<Float>(0.0, 0.0, -1.0),
      SIMD3<Float>(0.0, 0.0, -1.0),
      SIMD3<Float>(0.0, 0.0, -1.0),
      SIMD3<Float>(0.0, 0.0, -1.0),

      // left
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),

      // right
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),

      // top
      SIMD3<Float>(0.0, 1.0, 0.0),
      SIMD3<Float>(0.0, 1.0, 0.0),
      SIMD3<Float>(0.0, 1.0, 0.0),
      SIMD3<Float>(0.0, 1.0, 0.0),

      // bottom
      SIMD3<Float>(0.0, -1.0, 0.0),
      SIMD3<Float>(0.0, -1.0, 0.0),
      SIMD3<Float>(0.0, -1.0, 0.0),
      SIMD3<Float>(0.0, -1.0, 0.0)
    ]

    tess.tangents = [
      // front
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),

      // back
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),

      // left
      SIMD3<Float>(0.0, 0.0, 1.0),
      SIMD3<Float>(0.0, 0.0, 1.0),
      SIMD3<Float>(0.0, 0.0, 1.0),
      SIMD3<Float>(0.0, 0.0, 1.0),

      // right
      SIMD3<Float>(0.0, 0.0, -1.0),
      SIMD3<Float>(0.0, 0.0, -1.0),
      SIMD3<Float>(0.0, 0.0, -1.0),
      SIMD3<Float>(0.0, 0.0, -1.0),

      // top
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),
      SIMD3<Float>(1.0, 0.0, 0.0),

      // bottom
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0),
      SIMD3<Float>(-1.0, 0.0, 0.0)
    ]

    tess.texCoords = [
      // front
      SIMD2<Float>(0.0, 0.0),
      SIMD2<Float>(texScale.x, 0.0),
      SIMD2<Float>(texScale.x, texScale.y),
      SIMD2<Float>(0.0, texScale.y),

      // back
      SIMD2<Float>(0.0, 0.0),
      SIMD2<Float>(texScale.x, 0.0),
      SIMD2<Float>(texScale.x, texScale.y),
      SIMD2<Float>(0.0, texScale.y),

      // left
      SIMD2<Float>(0.0, 0.0),
      SIMD2<Float>(texScale.z, 0.0),
      SIMD2<Float>(texScale.z, texScale.y),
      SIMD2<Float>(0.0, texScale.y),

      // right
      SIMD2<Float>(0.0, 0.0),
      SIMD2<Float>(texScale.z, 0.0),
      SIMD2<Float>(texScale.z, texScale.y),
      SIMD2<Float>(0.0, texScale.y),

      // top
      SIMD2<Float>(0.0, 0.0),
      SIMD2<Float>(texScale.x, 0.0),
      SIMD2<Float>(texScale.x, texScale.z),
      SIMD2<Float>(0.0, texScale.z),

      // bottom
      SIMD2<Float>(0.0, 0.0),
      SIMD2<Float>(texScale.x, 0.0),
      SIMD2<Float>(texScale.x, texScale.z),
      SIMD2<Float>(0.0, texScale.z)
    ]

    tess.indices = [
      0, 1, 2, 0, 2, 3,
      4, 5, 6, 4, 6, 7,

      8, 9, 10, 8, 10, 11,
      12, 13, 14, 12, 14, 15,

      16, 17, 18, 16, 18, 19,
      20, 21, 22, 20, 22, 23
    ]
    return tess
  }

  /**
   Generates a tessellated torus.

   The torus is defined by its center, a major radius (distance from the center of the torus to the center
   of the tube) and a minor radius (radius of the tube). The torus is subdivided into `majorSteps`
   segments around the major circle and `minorSteps` segments along the tube.

   - Parameters:
   - center: The center point of the torus.
   - majorRadius: The major radius of the torus.
   - minorRadius: The minor radius of the torus.
   - majorSteps: The number of segments around the major circle.
   - minorSteps: The number of segments along the tube.
   - Returns: A `Tesselation` containing the vertex data for the generated torus.
   */
  static func genTorus(center: SIMD3<Float>, majorRadius: Float,
                       minorRadius: Float, majorSteps: UInt32,
                       minorSteps: UInt32) -> Tesselation {
    var tess = Tesselation()

    for x in 0...majorSteps {
      let phi = (2.0 * PI * Float(x)) / Float(majorSteps)

      for y in 0...minorSteps {
        let theta = (2.0 * PI * Float(y)) / Float(minorSteps)

        let vertex = SIMD3<Float>(
          x: (majorRadius + minorRadius * cos(theta)) * cos(phi),
          y: (majorRadius + minorRadius * cos(theta)) * sin(phi),
          z: minorRadius * sin(theta)
        )

        let normal = normalize(vertex -
                               SIMD3<Float>(x: majorRadius * cos(phi), y: majorRadius * sin(phi), z: 0))

        let tangent = SIMD3<Float>(x: -majorRadius * sin(phi),
                                   y: majorRadius * cos(phi), z: 0)
        let texture = SIMD2<Float>(
          x: Float(x) / Float(majorSteps),
          y: Float(y) / Float(minorSteps)
        )

        tess.vertices.append(vertex + center)
        tess.normals.append(normal)
        tess.tangents.append(tangent)
        tess.texCoords.append(texture)
      }
    }

    for x in 0..<majorSteps {
      for y in 0..<minorSteps {
        // Push 2 triangles per quad
        tess.indices.append((x + 0) * (minorSteps + 1) + (y + 0))
        tess.indices.append((x + 1) * (minorSteps + 1) + (y + 0))
        tess.indices.append((x + 1) * (minorSteps + 1) + (y + 1))

        tess.indices.append((x + 0) * (minorSteps + 1) + (y + 0))
        tess.indices.append((x + 1) * (minorSteps + 1) + (y + 1))
        tess.indices.append((x + 0) * (minorSteps + 1) + (y + 1))
      }
    }

    return tess
  }

  /**
   Unpacks the indexed mesh data into a non-indexed format.

   This method creates a new `Tesselation` where the vertex attributes (positions, normals, tangents,
   and texture coordinates) are rearranged in the order specified by the indices. This is useful when a
   non-indexed mesh is required.

   - Returns: A new `Tesselation` instance with unpacked (non-indexed) vertex data.
   */
  func unpack() -> Tesselation {
    var t = Tesselation()

    var i: UInt32 = 0
    for index in indices {
      t.indices.append(i)
      t.vertices.append(vertices[Int(index)])
      t.normals.append(normals[Int(index)])
      t.tangents.append(tangents[Int(index)])
      t.texCoords.append(texCoords[Int(index)])
      i += 1
    }

    return t
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-Essen

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
