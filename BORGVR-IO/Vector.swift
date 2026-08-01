import Foundation

// MARK: - Vec3

/**
 A generic three-dimensional vector type.

 - Type Parameters:
 - T: The scalar type for each component. Must conform to `Codable` and `Numeric`.
 */
public struct Vec3<T: Codable & Numeric> : Codable, CustomStringConvertible {
  /// The x-component of the vector.
  public var x: T
  /// The y-component of the vector.
  public var y: T
  /// The z-component of the vector.
  public var z: T

  /**
   Creates a new vector with the specified components.

   - Parameters:
   - x: The x-component.
   - y: The y-component.
   - z: The z-component.
   */
  public init(x: T, y: T, z: T) {
    self.x = x
    self.y = y
    self.z = z
  }

  public init(_ x: T, _ y: T, _ z: T) {
    self.x = x
    self.y = y
    self.z = z
  }

  public init(repeating value: T) {
    self.x = value
    self.y = value
    self.z = value
  }

  @inlinable
  public func dot(_ other: Vec3) -> T {
    x * other.x + y * other.y + z * other.z
  }

  @inlinable
  public func cross(_ other: Vec3) -> Vec3 {
    Vec3(
      x: y * other.z - z * other.y,
      y: z * other.x - x * other.z,
      z: x * other.y - y * other.x
    )
  }

  public var description: String {
    "Vec3(x: \(x), y: \(y), z: \(z))"
  }

  @inlinable
  public static func * (lhs: Vec3, rhs: T) -> Vec3 {
    Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
  }

  @inlinable
  public static func * (lhs: T, rhs: Vec3) -> Vec3 {
    Vec3(lhs * rhs.x, lhs * rhs.y, lhs * rhs.z)
  }

  @inlinable
  public static func - (lhs: Vec3, rhs: T) -> Vec3 {
    Vec3(lhs.x - rhs, lhs.y - rhs, lhs.z - rhs)
  }

}

// MARK: - Equatable, Hashable, Sendable

extension Vec3: Equatable { }
extension Vec3: Hashable where T: Hashable { }
extension Vec3: Sendable where T: Sendable { }

extension Vec3: AdditiveArithmetic {
  public static var zero: Vec3<T> {
    Vec3(x: 0, y: 0, z: 0)
  }

  /**
   Adds two vectors component-wise.

   - Parameters:
   - lhs: The left-hand side vector.
   - rhs: The right-hand side vector.
   - Returns: A new vector equal to `lhs + rhs`.
   */
  @inlinable
  public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
    Vec3(x: lhs.x + rhs.x,
         y: lhs.y + rhs.y,
         z: lhs.z + rhs.z)
  }

  /**
   Subtracts two vectors component-wise.

   - Parameters:
   - lhs: The left-hand side vector.
   - rhs: The right-hand side vector.
   - Returns: A new vector equal to `lhs - rhs`.
   */
  @inlinable
  public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
    Vec3(x: lhs.x - rhs.x,
         y: lhs.y - rhs.y,
         z: lhs.z - rhs.z)
  }
}

// MARK: - Magnitude (for Floating Point Types)
extension Vec3 where T: BinaryFloatingPoint {
  /// The Euclidean length (magnitude) of the vector.
  @inlinable
  public var magnitude: T {
    magnitudeSquared.squareRoot()
  }

  @inlinable
  public var magnitudeSquared: T {
    x * x + y * y + z * z
  }

  @inlinable
  public static func / (lhs: Vec3, rhs: T) -> Vec3 {
    Vec3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
  }
}

// MARK: - Typealiases

/// A three-dimensional vector of `Int` components.
public typealias IVec3 = Vec3<Int>
/// A three-dimensional vector of `Float` components.
public typealias FVec3 = Vec3<Float>

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
