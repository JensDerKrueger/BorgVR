import Foundation

// MARK: - Vec3

/**
 A generic three-dimensional vector type.

 - Type Parameters:
 - T: The scalar type for each component. Must conform to `Codable` and `Numeric`.
 */
public struct Vec3<T: Codable & Numeric>: Codable {
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
}

// MARK: - Convenience Initializers and Static Properties

extension Vec3 where T: ExpressibleByIntegerLiteral {
  /// A vector with all components equal to zero.
  public static var zero: Vec3<T> {
    return Vec3(x: 0, y: 0, z: 0)
  }

  /**
   Creates a vector where each component has the same value.

   - Parameter value: The value to assign to x, y, and z.
   */
  public init(repeating value: T) {
    self.init(x: value, y: value, z: value)
  }
}

// MARK: - CustomStringConvertible

extension Vec3: CustomStringConvertible {
  /// A textual representation of the vector in the form `Vec3(x: x, y: y, z: z)`.
  public var description: String {
    return "Vec3(x: \(x), y: \(y), z: \(z))"
  }
}

// MARK: - Equatable

extension Vec3: Equatable where T: Equatable { }

// MARK: - Arithmetic Operations

extension Vec3 where T: AdditiveArithmetic {
  /**
   Adds two vectors component-wise.

   - Parameters:
   - lhs: The left-hand side vector.
   - rhs: The right-hand side vector.
   - Returns: A new vector equal to `lhs + rhs`.
   */
  public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
    return Vec3(x: lhs.x + rhs.x,
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
  public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
    return Vec3(x: lhs.x - rhs.x,
                y: lhs.y - rhs.y,
                z: lhs.z - rhs.z)
  }
}

// MARK: - Dot Product

extension Vec3 where T: Numeric {
  /**
   Computes the dot product of this vector with another.

   - Parameter other: The other vector.
   - Returns: The scalar dot product.
   */
  public func dot(_ other: Vec3) -> T {
    return x * other.x + y * other.y + z * other.z
  }
}

// MARK: - Magnitude (for Floating Point Types)

extension Vec3 where T: BinaryFloatingPoint {
  /// The Euclidean length (magnitude) of the vector.
  public var magnitude: T {
    return (x * x + y * y + z * z).squareRoot()
  }
}

// MARK: - Typealiases

/// A three-dimensional vector of `Int` components.
public typealias IVec3 = Vec3<Int>
/// A three-dimensional vector of `Float` components.
public typealias FVec3 = Vec3<Float>

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
