import Foundation
import Security

enum HTTPWebServerTLSIdentity {
  static func create(pkcs12Data: Data = Data(), password: String = "") throws -> SecIdentity {
    if !pkcs12Data.isEmpty {
      return try identity(fromPKCS12: pkcs12Data, password: password)
    }
    return try createSelfSigned()
  }

  private static func identity(fromPKCS12 data: Data, password: String) throws -> SecIdentity {
    let options: [String: Any] = [
      kSecImportExportPassphrase as String: password
    ]
    var importedItems: CFArray?
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &importedItems)
    guard status == errSecSuccess,
          let items = importedItems as? [[String: Any]],
          let identityItem = items.first?[kSecImportItemIdentity as String]
    else {
      throw TLSIdentityError.pkcs12ImportFailed(status)
    }
    let identity = identityItem as! SecIdentity
    return identity
  }

  private static func createSelfSigned() throws -> SecIdentity {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
      kSecAttrIsPermanent as String: false
    ]

    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw TLSIdentityError.keyGenerationFailed(error?.takeRetainedValue())
    }
    guard let publicKey = SecKeyCopyPublicKey(privateKey),
          let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
    else {
      throw TLSIdentityError.publicKeyExportFailed(error?.takeRetainedValue())
    }

    let now = Date()
    let serial = randomSerialNumber()
    let tbsCertificate = DER.sequence([
      DER.explicit(0, DER.integer([0x02])),
      DER.integer(serial),
      DER.rsaSHA256AlgorithmIdentifier,
      subjectName(),
      DER.sequence([
        DER.generalizedTime(now.addingTimeInterval(-300)),
        DER.generalizedTime(now.addingTimeInterval(10 * 365 * 24 * 60 * 60))
      ]),
      subjectName(),
      subjectPublicKeyInfo(publicKeyData),
      DER.explicit(3, extensions())
    ])

    guard let signature = SecKeyCreateSignature(
      privateKey,
      .rsaSignatureMessagePKCS1v15SHA256,
      tbsCertificate as CFData,
      &error
    ) as Data? else {
      throw TLSIdentityError.signingFailed(error?.takeRetainedValue())
    }

    let certificateData = DER.sequence([
      tbsCertificate,
      DER.rsaSHA256AlgorithmIdentifier,
      DER.bitString(signature)
    ])
    guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
      throw TLSIdentityError.certificateCreationFailed
    }
    guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
      throw TLSIdentityError.identityCreationFailed
    }
    return identity
  }

  private static func subjectName() -> Data {
    DER.sequence([
      DER.set([
        DER.sequence([
          DER.oid("2.5.4.3"),
          DER.utf8String("BorgVR Local WebGPU Server")
        ])
      ])
    ])
  }

  private static func subjectPublicKeyInfo(_ publicKeyData: Data) -> Data {
    DER.sequence([
      DER.sequence([
        DER.oid("1.2.840.113549.1.1.1"),
        DER.null()
      ]),
      DER.bitString(publicKeyData)
    ])
  }

  private static func extensions() -> Data {
    let subjectAlternativeNames = localSubjectAlternativeNames()
    return DER.sequence([
      DER.sequence([
        DER.oid("2.5.29.19"),
        DER.boolean(true),
        DER.octetString(DER.sequence([]))
      ]),
      DER.sequence([
        DER.oid("2.5.29.15"),
        DER.boolean(true),
        DER.octetString(DER.bitString(Data([0xa0]), unusedBits: 5))
      ]),
      DER.sequence([
        DER.oid("2.5.29.37"),
        DER.octetString(DER.sequence([
          DER.oid("1.3.6.1.5.5.7.3.1")
        ]))
      ]),
      DER.sequence([
        DER.oid("2.5.29.17"),
        DER.octetString(DER.sequence(subjectAlternativeNames))
      ])
    ])
  }

  private static func localSubjectAlternativeNames() -> [Data] {
    var names: [Data] = [
      DER.contextSpecificPrimitive(2, Data("localhost".utf8)),
      DER.contextSpecificPrimitive(7, Data([127, 0, 0, 1])),
      DER.contextSpecificPrimitive(7, Data(repeating: 0, count: 15) + Data([1]))
    ]
    for address in localIPAddressBytes() {
      names.append(DER.contextSpecificPrimitive(7, address))
    }
    return names
  }

  private static func localIPAddressBytes() -> [Data] {
    var addresses: [Data] = []
    var seen = Set<Data>()
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddr) == 0, let firstAddress = ifaddr else {
      return []
    }
    defer { freeifaddrs(ifaddr) }

    var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let current = pointer {
      defer { pointer = current.pointee.ifa_next }
      guard let socketAddress = current.pointee.ifa_addr else { continue }

      switch Int32(socketAddress.pointee.sa_family) {
        case AF_INET:
          let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin_addr) { Data($0) }
          }
          if address != Data([127, 0, 0, 1]), seen.insert(address).inserted {
            addresses.append(address)
          }
        case AF_INET6:
          let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin6_addr) { Data($0) }
          }
          if address != Data(repeating: 0, count: 15) + Data([1]), seen.insert(address).inserted {
            addresses.append(address)
          }
        default:
          continue
      }
    }
    return addresses
  }

  private static func randomSerialNumber() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      bytes = Array(UUID().uuidString.utf8.prefix(16))
    }
    bytes[0] &= 0x7f
    if bytes.allSatisfy({ $0 == 0 }) {
      bytes[15] = 1
    }
    return bytes
  }
}

private enum TLSIdentityError: LocalizedError {
  case keyGenerationFailed(CFError?)
  case publicKeyExportFailed(CFError?)
  case signingFailed(CFError?)
  case certificateCreationFailed
  case identityCreationFailed
  case pkcs12ImportFailed(OSStatus)

  var errorDescription: String? {
    switch self {
      case .keyGenerationFailed(let error):
        return "Could not create HTTPS key: \(error?.localizedDescription ?? "unknown error")"
      case .publicKeyExportFailed(let error):
        return "Could not export HTTPS public key: \(error?.localizedDescription ?? "unknown error")"
      case .signingFailed(let error):
        return "Could not sign HTTPS certificate: \(error?.localizedDescription ?? "unknown error")"
      case .certificateCreationFailed:
        return "Could not create HTTPS certificate."
      case .identityCreationFailed:
        return "Could not create HTTPS identity."
      case .pkcs12ImportFailed(let status):
        return "Could not import HTTPS PKCS#12 identity (OSStatus \(status))."
    }
  }
}

private enum DER {
  static let rsaSHA256AlgorithmIdentifier = sequence([
    oid("1.2.840.113549.1.1.11"),
    null()
  ])

  static func sequence(_ values: [Data]) -> Data {
    tagged(0x30, values.reduce(Data(), +))
  }

  static func set(_ values: [Data]) -> Data {
    tagged(0x31, values.reduce(Data(), +))
  }

  static func explicit(_ tagNumber: UInt8, _ value: Data) -> Data {
    tagged(0xa0 + tagNumber, value)
  }

  static func contextSpecificPrimitive(_ tagNumber: UInt8, _ value: Data) -> Data {
    tagged(0x80 + tagNumber, value)
  }

  static func integer(_ bytes: [UInt8]) -> Data {
    var normalized = Array(bytes.drop(while: { $0 == 0 }))
    if normalized.isEmpty {
      normalized = [0]
    }
    if let first = normalized.first, first & 0x80 != 0 {
      normalized.insert(0, at: 0)
    }
    return tagged(0x02, Data(normalized))
  }

  static func boolean(_ value: Bool) -> Data {
    tagged(0x01, Data([value ? 0xff : 0x00]))
  }

  static func bitString(_ value: Data) -> Data {
    bitString(value, unusedBits: 0)
  }

  static func bitString(_ value: Data, unusedBits: UInt8) -> Data {
    tagged(0x03, Data([unusedBits]) + value)
  }

  static func octetString(_ value: Data) -> Data {
    tagged(0x04, value)
  }

  static func null() -> Data {
    tagged(0x05, Data())
  }

  static func oid(_ dotted: String) -> Data {
    let parts = dotted.split(separator: ".").compactMap { Int($0) }
    guard parts.count >= 2 else { return tagged(0x06, Data()) }

    var body = Data([UInt8(parts[0] * 40 + parts[1])])
    for value in parts.dropFirst(2) {
      body.append(base128(value))
    }
    return tagged(0x06, body)
  }

  static func utf8String(_ string: String) -> Data {
    tagged(0x0c, Data(string.utf8))
  }

  static func generalizedTime(_ date: Date) -> Data {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss'Z'"
    return tagged(0x18, Data(formatter.string(from: date).utf8))
  }

  private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
    Data([tag]) + length(value.count) + value
  }

  private static func length(_ count: Int) -> Data {
    if count < 0x80 {
      return Data([UInt8(count)])
    }
    var bytes: [UInt8] = []
    var value = count
    while value > 0 {
      bytes.insert(UInt8(value & 0xff), at: 0)
      value >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
  }

  private static func base128(_ value: Int) -> Data {
    var parts = [UInt8(value & 0x7f)]
    var shifted = value >> 7
    while shifted > 0 {
      parts.insert(UInt8(shifted & 0x7f) | 0x80, at: 0)
      shifted >>= 7
    }
    return Data(parts)
  }
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
