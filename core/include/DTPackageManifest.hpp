#pragma once

// Logical manifest codec for the package-backed document store.
//
// A manifest describes an immutable set of object payloads and the tile
// generations that make up a document revision.  This module deliberately
// knows nothing about files, iCloud, Files.app, SQLite, or Metal.  Callers
// write object payloads first, then encode and publish a manifest as the last
// operation.  On recovery, a manifest is usable only when every object it
// references is available in the object store.

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace drafting_table::package {

inline constexpr std::uint32_t kManifestFormatVersion = 1;
inline constexpr char kManifestMagic[8] = {'D', 'T', 'M', 'A', 'N', '1', 0, 0};

// Bounds are intentionally finite.  They protect decoders from allocating
// based on untrusted counts and make the format suitable for a provider that
// may hand us a partially downloaded package.
inline constexpr std::uint32_t kMaxManifestObjects = 1u << 20;
inline constexpr std::uint32_t kMaxManifestTileBindings = 1u << 20;
inline constexpr std::uint32_t kMaxManifestStringBytes = 1u << 20;
inline constexpr std::uint64_t kMaxManifestObjectBytes = 1ull << 40;
inline constexpr std::uint32_t kMaxManifestPageIndex = 1u << 20;
inline constexpr std::uint32_t kMaxManifestLayerIndex = 1u << 20;

enum class ManifestError : std::uint8_t {
    None = 0,
    InvalidArgument,
    UnsupportedVersion,
    BoundsExceeded,
    Truncated,
    Corrupt,
    ValidationFailed,
    NoRecoverableCandidate,
};

struct ManifestResult {
    bool ok = false;
    ManifestError error = ManifestError::None;
    std::string message;

    explicit constexpr operator bool() const noexcept { return ok; }
};

// ObjectKind is descriptive metadata for an immutable object payload.  The
// codec accepts Other (255) so a newer producer can preserve an object kind
// that an older reader does not interpret.  Tile and TilePack are the only
// kinds currently valid as tile binding targets.
enum class ObjectKind : std::uint8_t {
    Tile = 1,
    TilePack = 2,
    DocumentMetadata = 3,
    Vector = 4,
    Thumbnail = 5,
    Other = 255,
};

struct ObjectDescriptor {
    // Stable object identity within a package generation.  IDs are compared
    // byte-for-byte and must be unique in one manifest.
    std::string id;
    // Relative provider-safe path.  It may be empty when the object store is
    // content addressed and `hash` is populated.
    std::string path;
    // Optional content hash/identity supplied by the storage layer.  The
    // manifest treats it as opaque text; checksum below is the quick numeric
    // integrity value used by the caller's object reader.
    std::string hash;
    ObjectKind kind = ObjectKind::Other;
    std::uint64_t size = 0;
    std::uint64_t checksum = 0;

    bool operator==(const ObjectDescriptor&) const = default;
};

struct TileBinding {
    std::uint32_t page = 0;
    std::uint32_t layer = 0;
    std::int32_t tileX = 0;
    std::int32_t tileY = 0;
    // Generation of the tile payload, not merely the manifest that references
    // it.  This lets undo/readback/persistence associate an exact tile image
    // with a renderer transaction.
    std::uint64_t contentGeneration = 0;
    std::string objectId;

    bool operator==(const TileBinding&) const = default;
};

struct PackageManifest {
    std::uint32_t formatVersion = kManifestFormatVersion;
    // Generations start at one.  previousGeneration is zero when this is the
    // first published revision; otherwise it names the prior manifest.
    std::uint64_t documentGeneration = 1;
    std::uint64_t previousGeneration = 0;
    std::vector<ObjectDescriptor> objects;
    std::vector<TileBinding> tiles;

    bool operator==(const PackageManifest&) const = default;
};

// A candidate owns or otherwise keeps `encoded` alive for the duration of a
// selectRecovery call.  `name` is a diagnostic/provider key and is also the
// deterministic tie-breaker for equal generations.
struct ManifestCandidate {
    std::string name;
    std::span<const std::uint8_t> encoded;
};

struct RecoverySelection {
    bool found = false;
    std::size_t candidateIndex = static_cast<std::size_t>(-1);
    std::string candidateName;
    PackageManifest manifest;
};

// Validate an in-memory manifest without encoding it.  Validation does not
// require object payloads to be present; use selectRecovery to check those
// references against an object-store inventory.
ManifestResult validate(const PackageManifest& manifest);

// Deterministic little-endian binary codec.  Records are canonicalized by ID
// and tile address while encoding, so equivalent manifests with different
// vector insertion order produce identical bytes.
std::vector<std::uint8_t> encode(const PackageManifest& manifest);
ManifestResult encode(const PackageManifest& manifest,
                      std::vector<std::uint8_t>& output);
ManifestResult decode(std::span<const std::uint8_t> bytes,
                      PackageManifest& manifest);

// Decode all candidates, discard malformed/incomplete ones, and select the
// highest document generation.  Equal generations are resolved by candidate
// name, encoded bytes, then input index to make recovery deterministic.
ManifestResult selectRecovery(std::span<const ManifestCandidate> candidates,
                              std::span<const std::string> availableObjectIds,
                              RecoverySelection& selection);

// Human-readable names are useful to platform bridges and tests without
// exposing implementation-specific numeric values in their diagnostics.
const char* toString(ManifestError error) noexcept;
const char* toString(ObjectKind kind) noexcept;

} // namespace drafting_table::package
