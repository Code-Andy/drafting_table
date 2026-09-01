#pragma once

#include "DTDocument.hpp"

#include <cstdint>
#include <span>
#include <string>
#include <vector>
#include <iosfwd>

namespace drafting_table::persistence {

inline constexpr std::uint32_t kFormatVersion = 1;
inline constexpr char kFormatMagic[8] = {'D','T','D','O','C','2',0,0};

struct Result {
    bool ok = false;
    std::string error;
    explicit constexpr operator bool() const noexcept { return ok; }
};

// The codec is deterministic: all integers/floats are little-endian and all
// records carry bounded counts.  It is a byte codec, so callers can store the
// result in a package, database, or iOS document provider without this module
// knowing about paths or platform APIs.
std::vector<std::uint8_t> encode(const Document& document);
Result encode(const Document& document, std::vector<std::uint8_t>& output);
Result decode(std::span<const std::uint8_t> bytes, Document& document);
Result write(std::ostream& stream, const Document& document);
Result read(std::istream& stream, Document& document);

// Parse the Android renderer's tagged vector stream.  VEC0 is the historical
// pre-rotation format; VEC1 adds rotation to Rect and Ellipse.  This parser is
// intentionally separate from the DTDC document codec and never writes POD
// object representations.
Result decodeVectorShapes(std::span<const std::uint8_t> bytes, Layer& layer);
std::vector<std::uint8_t> encodeVectorShapes(const Layer& layer);

struct PersistenceCodec {
    static std::vector<std::uint8_t> encode(const Document& d) { return persistence::encode(d); }
    static Result decode(std::span<const std::uint8_t> b, Document& d) { return persistence::decode(b, d); }
    static Result write(std::ostream& s, const Document& d) { return persistence::write(s, d); }
    static Result read(std::istream& s, Document& d) { return persistence::read(s, d); }
};

} // namespace drafting_table::persistence

namespace drafting_table {
using persistence::PersistenceCodec;
}
