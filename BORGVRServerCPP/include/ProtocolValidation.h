#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace BorgVRProtocolValidation {

inline bool isHexIdentifier(std::string_view text, size_t expectedLength) {
  if (text.size() != expectedLength) return false;
  for (const char character : text) {
    const bool decimal = character >= '0' && character <= '9';
    const bool lower = character >= 'a' && character <= 'f';
    const bool upper = character >= 'A' && character <= 'F';
    if (!decimal && !lower && !upper) return false;
  }
  return true;
}

inline bool isCanonicalUUID(std::string_view text) {
  if (text.size() != 36) return false;
  for (size_t index = 0; index < text.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (text[index] != '-') return false;
      continue;
    }
    const char character = text[index];
    const bool decimal = character >= '0' && character <= '9';
    const bool lower = character >= 'a' && character <= 'f';
    const bool upper = character >= 'A' && character <= 'F';
    if (!decimal && !lower && !upper) return false;
  }
  return true;
}

inline std::string lowercaseIdentifier(std::string text) {
  for (char& character : text) {
    if (character >= 'A' && character <= 'Z') {
      character = static_cast<char>(character - 'A' + 'a');
    }
  }
  return text;
}

inline bool identifiersEqual(std::string_view lhs, std::string_view rhs) {
  if (lhs.size() != rhs.size()) return false;
  for (size_t index = 0; index < lhs.size(); ++index) {
    char left = lhs[index];
    char right = rhs[index];
    if (left >= 'A' && left <= 'Z') left = static_cast<char>(left - 'A' + 'a');
    if (right >= 'A' && right <= 'Z') right = static_cast<char>(right - 'A' + 'a');
    if (left != right) return false;
  }
  return true;
}

} // namespace BorgVRProtocolValidation
