#include "DTPackageManifest.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <span>
#include <string>
#include <vector>

namespace {

int failures = 0;

namespace dt = drafting_table;

#define CHECK(expression)                                                          \
    do {                                                                            \
        if (!(expression)) {                                                        \
            std::cerr << "FAIL line " << __LINE__ << ": " << #expression << '\n'; \
            ++failures;                                                            \
        }                                                                           \
    } while (false)

using dt::package::ManifestError;
using dt::package::ManifestCandidate;
using dt::package::ObjectDescriptor;
using dt::package::ObjectKind;
using dt::package::PackageManifest;
using dt::package::RecoverySelection;
using dt::package::TileBinding;

PackageManifest sampleManifest(std::uint64_t generation = 7,
                               std::uint64_t previous = 6) {
    PackageManifest manifest;
    manifest.documentGeneration = generation;
    manifest.previousGeneration = previous;
    // Deliberately insert records out of canonical order.  encode() must sort
    // these records so provider retries produce byte-identical manifests.
    manifest.objects = {
        ObjectDescriptor{"tile-b", "objects/tile-b.rgba", "", ObjectKind::Tile, 128, 0x2222},
        ObjectDescriptor{"meta", "", "sha256:meta", ObjectKind::DocumentMetadata, 42, 0xaaaa},
        ObjectDescriptor{"tile-a", "objects/tile-a.rgba", "", ObjectKind::Tile, 256, 0x1111},
    };
    manifest.tiles = {
        TileBinding{0x123456789abcdef0ULL, 0xfedcba9876543210ULL,
                    -1, 3, generation, "tile-b"},
        TileBinding{0x100000000ULL, 0x200000000ULL, 0, 0, generation, "tile-a"},
    };
    return manifest;
}

void putU32(std::vector<std::uint8_t>& bytes, std::size_t offset, std::uint32_t value) {
    CHECK(offset + 4u <= bytes.size());
    if (offset + 4u > bytes.size()) {
        return;
    }
    for (unsigned shift = 0; shift < 32u; shift += 8u) {
        bytes[offset + shift / 8u] = static_cast<std::uint8_t>(value >> shift);
    }
}

void testRoundTripAndCanonicalEncoding() {
    const PackageManifest manifest = sampleManifest();
    CHECK(dt::package::validate(manifest).ok);

    const auto bytes = dt::package::encode(manifest);
    CHECK(!bytes.empty());
    CHECK(bytes == dt::package::encode(manifest));

    PackageManifest reordered = manifest;
    std::reverse(reordered.objects.begin(), reordered.objects.end());
    std::reverse(reordered.tiles.begin(), reordered.tiles.end());
    CHECK(bytes == dt::package::encode(reordered));

    PackageManifest decoded;
    const auto result = dt::package::decode(bytes, decoded);
    CHECK(result.ok);
    CHECK(decoded.documentGeneration == 7 && decoded.previousGeneration == 6);
    CHECK(decoded.objects.size() == 3 && decoded.tiles.size() == 2);
    CHECK(decoded.objects[0].id == "meta");
    CHECK(decoded.objects[1].id == "tile-a");
    CHECK(decoded.objects[2].id == "tile-b");
    CHECK(decoded.tiles[0].pageID == 0x100000000ULL &&
          decoded.tiles[0].layerID == 0x200000000ULL);
    CHECK(decoded.tiles[1].tileX == -1 && decoded.tiles[1].objectId == "tile-b");
    CHECK(dt::package::encode(decoded) == bytes);
}

void testValidationRules() {
    auto invalid = sampleManifest();
    invalid.documentGeneration = 0;
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest(4, 4);
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest();
    invalid.objects[0].id = invalid.objects[1].id;
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest();
    invalid.objects[0].path = "../escape.rgba";
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest();
    invalid.objects[0].path = "objects\\..\\escape.rgba";
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest();
    invalid.objects[0].path.clear();
    invalid.objects[0].hash.clear();
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest();
    invalid.tiles[0].objectId = "missing";
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest();
    invalid.tiles.push_back(invalid.tiles[0]);
    CHECK(dt::package::validate(invalid).error == ManifestError::ValidationFailed);

    invalid = sampleManifest();
    invalid.objects[0].kind = static_cast<ObjectKind>(99);
    CHECK(dt::package::validate(invalid).error == ManifestError::Corrupt);
}

void testStrictDecodeFailures() {
    const auto bytes = dt::package::encode(sampleManifest());
    CHECK(bytes.size() > 36u);

    PackageManifest target = sampleManifest();
    for (std::size_t size = 0; size < bytes.size(); ++size) {
        auto result = dt::package::decode(
            std::span<const std::uint8_t>(bytes.data(), size), target);
        CHECK(!result.ok);
        CHECK(target.documentGeneration == 7); // failure must not mutate output
    }

    auto badMagic = bytes;
    badMagic[0] ^= 0x80u;
    CHECK(dt::package::decode(badMagic, target).error == ManifestError::Corrupt);

    auto badVersion = bytes;
    putU32(badVersion, 8u, 99u);
    CHECK(dt::package::decode(badVersion, target).error == ManifestError::UnsupportedVersion);

    auto hugeObjects = bytes;
    putU32(hugeObjects, 28u, 0xffffffffu);
    CHECK(dt::package::decode(hugeObjects, target).error == ManifestError::BoundsExceeded);

    auto hugeString = bytes;
    // Header is 36 bytes; the first object starts with kind then id length.
    putU32(hugeString, 37u, dt::package::kMaxManifestStringBytes + 1u);
    CHECK(dt::package::decode(hugeString, target).error == ManifestError::Truncated);

    auto trailing = bytes;
    trailing.push_back(0);
    CHECK(dt::package::decode(trailing, target).error == ManifestError::Corrupt);
}

void testRecoverySelection() {
    const auto oldBytes = dt::package::encode(sampleManifest(8, 7));
    auto newestManifest = sampleManifest(9, 8);
    newestManifest.objects.push_back(
        ObjectDescriptor{"tile-c", "objects/tile-c.rgba", "", ObjectKind::Tile, 64, 0x3333});
    newestManifest.tiles.push_back(TileBinding{0, 1, 4, 5, 9, "tile-c"});
    const auto newestBytes = dt::package::encode(newestManifest);
    const auto malformedBytes = std::vector<std::uint8_t>{'n', 'o', 'p', 'e'};

    std::vector<std::string> available{"meta", "tile-a", "tile-b"};
    std::vector<ManifestCandidate> candidates{
        ManifestCandidate{"manifest-new", newestBytes},
        ManifestCandidate{"manifest-old", oldBytes},
        ManifestCandidate{"manifest-bad", malformedBytes},
    };
    RecoverySelection selection;
    auto result = dt::package::selectRecovery(candidates, available, selection);
    CHECK(result.ok && selection.found);
    CHECK(selection.candidateIndex == 1 && selection.manifest.documentGeneration == 8);

    available.push_back("tile-c");
    result = dt::package::selectRecovery(candidates, available, selection);
    CHECK(result.ok && selection.candidateIndex == 0);

    // Equal generations use the candidate name as the stable tie-breaker.
    auto tieA = dt::package::encode(sampleManifest(12, 11));
    auto tieB = dt::package::encode(sampleManifest(12, 11));
    std::vector<ManifestCandidate> ties{
        ManifestCandidate{"z-manifest", tieA},
        ManifestCandidate{"a-manifest", tieB},
    };
    result = dt::package::selectRecovery(ties, available, selection);
    CHECK(result.ok && selection.candidateIndex == 1 && selection.candidateName == "a-manifest");

    std::vector<std::string> missing{"meta", "tile-a"};
    result = dt::package::selectRecovery(candidates, missing, selection);
    CHECK(!result.ok && result.error == ManifestError::NoRecoverableCandidate);
}

} // namespace

int main() {
    testRoundTripAndCanonicalEncoding();
    testValidationRules();
    testStrictDecodeFailures();
    testRecoverySelection();
    if (failures != 0) {
        std::cerr << failures << " assertion(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all package manifest tests passed\n";
    return EXIT_SUCCESS;
}
