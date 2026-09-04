#include "DTPackageManifest.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <tuple>
#include <unordered_set>

namespace drafting_table::package {
namespace {

constexpr std::size_t kObjectRecordMinimumBytes = 1u + 4u + 4u + 4u + 8u + 8u;
constexpr std::size_t kTileRecordMinimumBytes = 4u + 4u + 4u + 4u + 8u + 4u;

ManifestResult success() {
    return {true, ManifestError::None, {}};
}

ManifestResult failure(ManifestError error, const char* message) {
    return {false, error, message};
}

bool hasNul(const std::string& value) {
    return value.find('\0') != std::string::npos;
}

bool safeRelativePath(const std::string& path) {
    if (path.empty() || hasNul(path) || path.front() == '/' || path.front() == '\\' ||
        (path.size() >= 2u && path[1] == ':')) {
        return false;
    }

    // Paths in a package are provider-neutral and use '/'.  Reject empty,
    // current-directory, and parent-directory segments so a platform bridge
    // cannot accidentally turn a descriptor into a path traversal request.
    std::size_t begin = 0;
    while (begin <= path.size()) {
        const std::size_t end = path.find('/', begin);
        const std::size_t length = end == std::string::npos ? path.size() - begin
                                                            : end - begin;
        if (length == 0u || (length == 1u && path[begin] == '.') ||
            (length == 2u && path[begin] == '.' && path[begin + 1u] == '.')) {
            return false;
        }
        if (end == std::string::npos) {
            break;
        }
        begin = end + 1u;
    }
    return true;
}

bool validObjectKind(ObjectKind kind) {
    switch (kind) {
    case ObjectKind::Tile:
    case ObjectKind::TilePack:
    case ObjectKind::DocumentMetadata:
    case ObjectKind::Vector:
    case ObjectKind::Thumbnail:
    case ObjectKind::Other:
        return true;
    }
    return false;
}

bool tileObjectKind(ObjectKind kind) {
    return kind == ObjectKind::Tile || kind == ObjectKind::TilePack;
}

struct Writer {
    std::vector<std::uint8_t> bytes;

    void u8(std::uint8_t value) { bytes.push_back(value); }

    void u32(std::uint32_t value) {
        for (unsigned shift = 0; shift < 32u; shift += 8u) {
            bytes.push_back(static_cast<std::uint8_t>(value >> shift));
        }
    }

    void i32(std::int32_t value) {
        u32(static_cast<std::uint32_t>(value));
    }

    void u64(std::uint64_t value) {
        for (unsigned shift = 0; shift < 64u; shift += 8u) {
            bytes.push_back(static_cast<std::uint8_t>(value >> shift));
        }
    }

    void string(const std::string& value) {
        u32(static_cast<std::uint32_t>(value.size()));
        bytes.insert(bytes.end(), value.begin(), value.end());
    }

    void raw(const char* data, std::size_t size) {
        bytes.insert(bytes.end(), reinterpret_cast<const std::uint8_t*>(data),
                     reinterpret_cast<const std::uint8_t*>(data) + size);
    }
};

struct Reader {
    std::span<const std::uint8_t> bytes;
    std::size_t position = 0;

    std::size_t remaining() const noexcept {
        return position <= bytes.size() ? bytes.size() - position : 0u;
    }

    bool take(std::size_t size, const std::uint8_t*& result) {
        if (size > remaining()) {
            return false;
        }
        if (size == 0u) {
            result = nullptr;
            return true;
        }
        result = bytes.data() + position;
        position += size;
        return true;
    }

    bool u8(std::uint8_t& value) {
        const std::uint8_t* data = nullptr;
        if (!take(1u, data)) {
            return false;
        }
        value = *data;
        return true;
    }

    bool u32(std::uint32_t& value) {
        const std::uint8_t* data = nullptr;
        if (!take(4u, data)) {
            return false;
        }
        value = static_cast<std::uint32_t>(data[0]) |
                (static_cast<std::uint32_t>(data[1]) << 8u) |
                (static_cast<std::uint32_t>(data[2]) << 16u) |
                (static_cast<std::uint32_t>(data[3]) << 24u);
        return true;
    }

    bool i32(std::int32_t& value) {
        std::uint32_t bits = 0;
        if (!u32(bits)) {
            return false;
        }
        value = static_cast<std::int32_t>(bits);
        return true;
    }

    bool u64(std::uint64_t& value) {
        const std::uint8_t* data = nullptr;
        if (!take(8u, data)) {
            return false;
        }
        value = 0;
        for (unsigned shift = 0; shift < 64u; shift += 8u) {
            value |= static_cast<std::uint64_t>(data[shift / 8u]) << shift;
        }
        return true;
    }

    bool string(std::string& value) {
        std::uint32_t size = 0;
        if (!u32(size)) {
            return false;
        }
        if (size > kMaxManifestStringBytes) {
            return false;
        }
        const std::uint8_t* data = nullptr;
        if (!take(size, data)) {
            return false;
        }
        if (size == 0u) {
            value.clear();
        } else {
            value.assign(reinterpret_cast<const char*>(data), size);
        }
        return true;
    }
};

struct TileKey {
    std::uint32_t page = 0;
    std::uint32_t layer = 0;
    std::int32_t x = 0;
    std::int32_t y = 0;

    bool operator==(const TileKey&) const = default;
};

struct TileKeyHash {
    std::size_t operator()(const TileKey& key) const noexcept {
        std::size_t result = static_cast<std::size_t>(key.page);
        result = result * 31u + static_cast<std::size_t>(key.layer);
        result = result * 31u + static_cast<std::size_t>(
            static_cast<std::uint32_t>(key.x));
        result = result * 31u + static_cast<std::size_t>(
            static_cast<std::uint32_t>(key.y));
        return result;
    }
};

bool descriptorLess(const ObjectDescriptor& lhs, const ObjectDescriptor& rhs) {
    return std::tie(lhs.id, lhs.kind, lhs.path, lhs.hash, lhs.size, lhs.checksum) <
           std::tie(rhs.id, rhs.kind, rhs.path, rhs.hash, rhs.size, rhs.checksum);
}

bool tileLess(const TileBinding& lhs, const TileBinding& rhs) {
    return std::tie(lhs.page, lhs.layer, lhs.tileX, lhs.tileY,
                    lhs.contentGeneration, lhs.objectId) <
           std::tie(rhs.page, rhs.layer, rhs.tileX, rhs.tileY,
                    rhs.contentGeneration, rhs.objectId);
}

bool byteLexicographicalLess(std::span<const std::uint8_t> lhs,
                             std::span<const std::uint8_t> rhs) {
    return std::lexicographical_compare(lhs.begin(), lhs.end(), rhs.begin(), rhs.end());
}

} // namespace

ManifestResult validate(const PackageManifest& manifest) {
    if (manifest.formatVersion != kManifestFormatVersion) {
        return failure(ManifestError::UnsupportedVersion, "unsupported manifest version");
    }
    if (manifest.documentGeneration == 0u) {
        return failure(ManifestError::ValidationFailed,
                       "document generation must start at one");
    }
    if (manifest.previousGeneration >= manifest.documentGeneration &&
        manifest.previousGeneration != 0u) {
        return failure(ManifestError::ValidationFailed,
                       "previous generation must precede document generation");
    }
    if (manifest.objects.size() > kMaxManifestObjects ||
        manifest.tiles.size() > kMaxManifestTileBindings) {
        return failure(ManifestError::BoundsExceeded, "manifest record count exceeds limits");
    }

    std::unordered_set<std::string> objectIds;
    objectIds.reserve(manifest.objects.size());
    for (const auto& object : manifest.objects) {
        if (object.id.empty() || object.id.size() > kMaxManifestStringBytes ||
            object.path.size() > kMaxManifestStringBytes ||
            object.hash.size() > kMaxManifestStringBytes) {
            return failure(ManifestError::BoundsExceeded,
                           "object descriptor string exceeds limits");
        }
        if (hasNul(object.id) || hasNul(object.hash) ||
            (!object.path.empty() && !safeRelativePath(object.path))) {
            return failure(ManifestError::ValidationFailed,
                           "object descriptor contains an invalid identity or path");
        }
        if (object.path.empty() && object.hash.empty()) {
            return failure(ManifestError::ValidationFailed,
                           "object descriptor needs a path or content hash");
        }
        if (object.size > kMaxManifestObjectBytes) {
            return failure(ManifestError::BoundsExceeded, "object size exceeds limits");
        }
        if (!validObjectKind(object.kind)) {
            return failure(ManifestError::Corrupt, "unknown object kind");
        }
        if (!objectIds.insert(object.id).second) {
            return failure(ManifestError::ValidationFailed,
                           "manifest contains duplicate object IDs");
        }
    }

    std::unordered_set<TileKey, TileKeyHash> tileKeys;
    tileKeys.reserve(manifest.tiles.size());
    for (const auto& tile : manifest.tiles) {
        if (tile.page >= kMaxManifestPageIndex || tile.layer >= kMaxManifestLayerIndex) {
            return failure(ManifestError::BoundsExceeded,
                           "tile page or layer index exceeds limits");
        }
        if (tile.contentGeneration == 0u ||
            tile.contentGeneration > manifest.documentGeneration) {
            return failure(ManifestError::ValidationFailed,
                           "tile content generation is outside the document revision");
        }
        if (tile.objectId.empty() || tile.objectId.size() > kMaxManifestStringBytes ||
            hasNul(tile.objectId)) {
            return failure(ManifestError::BoundsExceeded,
                           "tile object ID exceeds limits");
        }
        const auto object = std::find_if(manifest.objects.begin(), manifest.objects.end(),
                                         [&](const ObjectDescriptor& descriptor) {
                                             return descriptor.id == tile.objectId;
                                         });
        if (object == manifest.objects.end()) {
            return failure(ManifestError::ValidationFailed,
                           "tile binding refers to an unknown object ID");
        }
        if (!tileObjectKind(object->kind)) {
            return failure(ManifestError::ValidationFailed,
                           "tile binding refers to a non-tile object");
        }
        if (!tileKeys.insert({tile.page, tile.layer, tile.tileX, tile.tileY}).second) {
            return failure(ManifestError::ValidationFailed,
                           "manifest contains duplicate tile bindings");
        }
    }
    return success();
}

std::vector<std::uint8_t> encode(const PackageManifest& manifest) {
    std::vector<std::uint8_t> output;
    if (!encode(manifest, output)) {
        return {};
    }
    return output;
}

ManifestResult encode(const PackageManifest& manifest,
                      std::vector<std::uint8_t>& output) {
    const ManifestResult validity = validate(manifest);
    if (!validity) {
        return validity;
    }

    // Reserve only after validating all untrusted sizes and checking the
    // addition for overflow.  This is a hint, not a format requirement.
    std::size_t estimate = 36u;
    for (const auto& object : manifest.objects) {
        const auto add = kObjectRecordMinimumBytes + object.id.size() +
                         object.path.size() + object.hash.size();
        if (add > std::numeric_limits<std::size_t>::max() - estimate) {
            return failure(ManifestError::BoundsExceeded, "manifest is too large to encode");
        }
        estimate += add;
    }
    for (const auto& tile : manifest.tiles) {
        const auto add = kTileRecordMinimumBytes + tile.objectId.size();
        if (add > std::numeric_limits<std::size_t>::max() - estimate) {
            return failure(ManifestError::BoundsExceeded, "manifest is too large to encode");
        }
        estimate += add;
    }

    Writer writer;
    writer.bytes.reserve(estimate);
    writer.raw(kManifestMagic, sizeof(kManifestMagic));
    writer.u32(manifest.formatVersion);
    writer.u64(manifest.documentGeneration);
    writer.u64(manifest.previousGeneration);
    writer.u32(static_cast<std::uint32_t>(manifest.objects.size()));
    writer.u32(static_cast<std::uint32_t>(manifest.tiles.size()));

    std::vector<const ObjectDescriptor*> objects;
    objects.reserve(manifest.objects.size());
    for (const auto& object : manifest.objects) {
        objects.push_back(&object);
    }
    std::sort(objects.begin(), objects.end(),
              [](const ObjectDescriptor* lhs, const ObjectDescriptor* rhs) {
                  return descriptorLess(*lhs, *rhs);
              });
    for (const auto* object : objects) {
        writer.u8(static_cast<std::uint8_t>(object->kind));
        writer.string(object->id);
        writer.string(object->path);
        writer.string(object->hash);
        writer.u64(object->size);
        writer.u64(object->checksum);
    }

    std::vector<const TileBinding*> tiles;
    tiles.reserve(manifest.tiles.size());
    for (const auto& tile : manifest.tiles) {
        tiles.push_back(&tile);
    }
    std::sort(tiles.begin(), tiles.end(),
              [](const TileBinding* lhs, const TileBinding* rhs) {
                  return tileLess(*lhs, *rhs);
              });
    for (const auto* tile : tiles) {
        writer.u32(tile->page);
        writer.u32(tile->layer);
        writer.i32(tile->tileX);
        writer.i32(tile->tileY);
        writer.u64(tile->contentGeneration);
        writer.string(tile->objectId);
    }

    output = std::move(writer.bytes);
    return success();
}

ManifestResult decode(std::span<const std::uint8_t> bytes,
                      PackageManifest& manifest) {
    Reader reader{bytes};
    const std::uint8_t* magic = nullptr;
    if (!reader.take(sizeof(kManifestMagic), magic)) {
        return failure(ManifestError::Truncated, "truncated manifest magic");
    }
    if (std::memcmp(magic, kManifestMagic, sizeof(kManifestMagic)) != 0) {
        return failure(ManifestError::Corrupt, "invalid manifest magic");
    }

    std::uint32_t version = 0;
    if (!reader.u32(version)) {
        return failure(ManifestError::Truncated, "truncated manifest version");
    }
    if (version != kManifestFormatVersion) {
        return failure(ManifestError::UnsupportedVersion, "unsupported manifest version");
    }

    PackageManifest parsed;
    parsed.formatVersion = version;
    if (!reader.u64(parsed.documentGeneration) || !reader.u64(parsed.previousGeneration)) {
        return failure(ManifestError::Truncated, "truncated manifest generations");
    }
    std::uint32_t objectCount = 0;
    std::uint32_t tileCount = 0;
    if (!reader.u32(objectCount) || !reader.u32(tileCount)) {
        return failure(ManifestError::Truncated, "truncated manifest record counts");
    }
    if (objectCount > kMaxManifestObjects || tileCount > kMaxManifestTileBindings) {
        return failure(ManifestError::BoundsExceeded, "manifest record count exceeds limits");
    }
    if (objectCount > reader.remaining() / kObjectRecordMinimumBytes ||
        tileCount > reader.remaining() / kTileRecordMinimumBytes) {
        return failure(ManifestError::Truncated, "manifest records are truncated");
    }

    parsed.objects.reserve(objectCount);
    for (std::uint32_t index = 0; index < objectCount; ++index) {
        std::uint8_t kind = 0;
        ObjectDescriptor object;
        if (!reader.u8(kind) || !reader.string(object.id) || !reader.string(object.path) ||
            !reader.string(object.hash) || !reader.u64(object.size) ||
            !reader.u64(object.checksum)) {
            return failure(ManifestError::Truncated, "truncated object descriptor");
        }
        object.kind = static_cast<ObjectKind>(kind);
        parsed.objects.push_back(std::move(object));
    }

    parsed.tiles.reserve(tileCount);
    for (std::uint32_t index = 0; index < tileCount; ++index) {
        TileBinding tile;
        if (!reader.u32(tile.page) || !reader.u32(tile.layer) || !reader.i32(tile.tileX) ||
            !reader.i32(tile.tileY) || !reader.u64(tile.contentGeneration) ||
            !reader.string(tile.objectId)) {
            return failure(ManifestError::Truncated, "truncated tile binding");
        }
        parsed.tiles.push_back(std::move(tile));
    }
    if (reader.position != bytes.size()) {
        return failure(ManifestError::Corrupt, "trailing manifest data");
    }

    const ManifestResult validity = validate(parsed);
    if (!validity) {
        return validity;
    }
    manifest = std::move(parsed);
    return success();
}

ManifestResult selectRecovery(std::span<const ManifestCandidate> candidates,
                              std::span<const std::string> availableObjectIds,
                              RecoverySelection& selection) {
    if (availableObjectIds.size() > kMaxManifestObjects * 2ull) {
        return failure(ManifestError::BoundsExceeded,
                       "object inventory exceeds recovery limits");
    }

    std::unordered_set<std::string> available;
    available.reserve(availableObjectIds.size());
    for (const auto& id : availableObjectIds) {
        if (id.empty() || id.size() > kMaxManifestStringBytes || hasNul(id)) {
            return failure(ManifestError::InvalidArgument,
                           "object inventory contains an invalid ID");
        }
        available.insert(id);
    }

    RecoverySelection best;
    std::span<const std::uint8_t> bestBytes;
    for (std::size_t index = 0; index < candidates.size(); ++index) {
        PackageManifest parsed;
        if (!decode(candidates[index].encoded, parsed)) {
            continue;
        }
        bool complete = true;
        for (const auto& object : parsed.objects) {
            if (available.find(object.id) == available.end()) {
                complete = false;
                break;
            }
        }
        if (!complete) {
            continue;
        }

        const auto& candidate = candidates[index];
        const bool better = !best.found ||
            parsed.documentGeneration > best.manifest.documentGeneration ||
            (parsed.documentGeneration == best.manifest.documentGeneration &&
             (candidate.name < best.candidateName ||
              (candidate.name == best.candidateName &&
               (byteLexicographicalLess(candidate.encoded, bestBytes) ||
                (candidate.encoded.size() == bestBytes.size() && index < best.candidateIndex)))));
        if (better) {
            best.found = true;
            best.candidateIndex = index;
            best.candidateName = candidate.name;
            best.manifest = std::move(parsed);
            bestBytes = candidate.encoded;
        }
    }

    if (!best.found) {
        return failure(ManifestError::NoRecoverableCandidate,
                       "no complete manifest candidate is recoverable");
    }
    selection = std::move(best);
    return success();
}

const char* toString(ManifestError error) noexcept {
    switch (error) {
    case ManifestError::None: return "none";
    case ManifestError::InvalidArgument: return "invalid argument";
    case ManifestError::UnsupportedVersion: return "unsupported version";
    case ManifestError::BoundsExceeded: return "bounds exceeded";
    case ManifestError::Truncated: return "truncated";
    case ManifestError::Corrupt: return "corrupt";
    case ManifestError::ValidationFailed: return "validation failed";
    case ManifestError::NoRecoverableCandidate: return "no recoverable candidate";
    }
    return "unknown";
}

const char* toString(ObjectKind kind) noexcept {
    switch (kind) {
    case ObjectKind::Tile: return "tile";
    case ObjectKind::TilePack: return "tile pack";
    case ObjectKind::DocumentMetadata: return "document metadata";
    case ObjectKind::Vector: return "vector";
    case ObjectKind::Thumbnail: return "thumbnail";
    case ObjectKind::Other: return "other";
    }
    return "unknown";
}

} // namespace drafting_table::package
