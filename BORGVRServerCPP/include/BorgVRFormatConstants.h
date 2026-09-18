#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace BorgVRFormat {

inline constexpr std::array<uint8_t, 4> kTransferFunctionMagic = {
  'B', 'T', 'F', '1'
};
inline constexpr uint32_t kTransferFunctionVersion = 2;
inline constexpr size_t kTransferFunctionExtendedHeaderBytes = 16;
inline constexpr size_t kTransferFunctionBytesPerEntry = 4;
inline constexpr size_t kMaximumTransferFunctionEntryCount = 1u << 16;
inline constexpr size_t kMaximumTransferFunctionDescriptionBytes = 64u * 1024u;
inline constexpr size_t kMaximumTransferFunctionFileBytes =
  kTransferFunctionExtendedHeaderBytes +
  kMaximumTransferFunctionDescriptionBytes +
  kMaximumTransferFunctionEntryCount * kTransferFunctionBytesPerEntry;

inline constexpr std::array<uint8_t, 8> kMarkerMagic = {
  'B', 'V', 'R', 'M', 'A', 'R', 'K', 'R'
};
inline constexpr uint16_t kMarkerVersion = 1;
inline constexpr size_t kMarkerHeaderBytes = 32;
inline constexpr uintmax_t kMaximumMarkerFileBytes = 64u * 1024u * 1024u;
inline constexpr uint32_t kMaximumMarkerCount = 100000;

inline constexpr const char* kServerProtocolVersionName = "4";

} // namespace BorgVRFormat
