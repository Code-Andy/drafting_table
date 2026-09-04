#include "DTMetalTileRenderer.hpp"

#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

int failures = 0;

#define CHECK(expression)                                                        \
    do {                                                                         \
        if (!(expression)) {                                                     \
            std::cerr << "FAIL line " << __LINE__ << ": " << #expression      \
                      << '\n';                                                   \
            ++failures;                                                          \
        }                                                                        \
    } while (false)

void testPortableVersionState() {
    using namespace drafting_table::metal;
    TileVersionLedger ledger;
    const std::vector<TileAddress> touched{{0, 0}, {1, 0}};

    CHECK(ledger.begin(41));
    CHECK(ledger.extend(41, touched)); // tiles can be discovered lazily
    const auto before = ledger.state(touched[0]);
    CHECK(before.has_value());
    CHECK(before->contentGeneration == 0 && before->persistedGeneration == 0);
    CHECK(before->hasWorkingVersion && !before->hasCommittedVersion);
    CHECK(!ledger.begin(42, touched)); // one serial owner at a time

    CHECK(ledger.replacePreview(41));
    CHECK(ledger.state(touched[0])->hasPreviewVersion);
    CHECK(ledger.discardPreview(41));
    CHECK(!ledger.state(touched[0])->hasPreviewVersion);

    CHECK(ledger.markCommitEncoded(41));
    CHECK(ledger.state(touched[0])->inFlight);
    CHECK(ledger.purgeSafe() == 0); // in-flight/dirty versions are retained

    const auto completed = ledger.complete(41, 1);
    CHECK(completed.has_value() && completed->succeeded);
    CHECK(completed->before.tiles.size() == 2 && completed->after.tiles.size() == 2);
    CHECK(completed->after.generation == 1);
    CHECK(ledger.state(touched[0])->contentGeneration == 1);
    CHECK(ledger.state(touched[0])->persistedGeneration == 0);
    CHECK(ledger.purgeSafe() == 0); // content is newer than durable storage

    CHECK(ledger.markPersisted(touched[0], 1));
    CHECK(ledger.markPersisted(touched[1], 1));
    CHECK(ledger.setApronDirty(touched[0]));
    CHECK(ledger.purgeSafe() == 1); // only the clean second tile is discardable
    CHECK(ledger.setApronDirty(touched[0], false));
    CHECK(ledger.purgeSafe() == 1);
    CHECK(ledger.size() == 0);

    const std::vector<TileAddress> cancelled{{9, 9}};
    CHECK(ledger.begin(42, cancelled));
    CHECK(ledger.replacePreview(42));
    CHECK(ledger.cancel(42));
    CHECK(!ledger.state(cancelled[0])->hasWorkingVersion);
    CHECK(!ledger.state(cancelled[0])->hasPreviewVersion);
}

void testBlendAndCheckpointAbi() {
    using namespace drafting_table::metal;
    CHECK(static_cast<std::uint8_t>(DabBlendMode::SourceOver) == 0);
    CHECK(static_cast<std::uint8_t>(DabBlendMode::DestinationOut) == 1);
    CHECK(DabBlendMode::sourceOver == DabBlendMode::SourceOver);
    CHECK(DabBlendMode::destinationOut == DabBlendMode::DestinationOut);
    CHECK(kTileInteriorRGBABytes == 256u * 256u * 4u);
    CHECK(CheckpointTicket{}.byteCount == kTileInteriorRGBABytes);
    CHECK(sizeof(TileVersionRef) >= sizeof(TileAddress) + sizeof(std::uint64_t));
}

} // namespace

int main() {
    using namespace drafting_table::metal;
    static_assert(kTileTextureExtent == 258);
    static_assert(sizeof(DabInstance) == 48);

    const auto address = TileLayout::addressFor({-0.25f, 256.0f});
    if (address != drafting_table::TileAddress{-1, 1}) {
        std::cerr << "Metal tile addressing mismatch\n";
        return EXIT_FAILURE;
    }

    const DabInstance dab({10.0f, 20.0f}, {4.0f, 2.0f}, 0.5f, 0.8f,
                          0.7f, {0.4f, 0.2f, 0.1f, 0.5f});
    if (dab.radii.x != 4.0f || dab.radii.y != 2.0f ||
        dab.rotationRadians != 0.5f) {
        std::cerr << "Metal dab layout mismatch\n";
        return EXIT_FAILURE;
    }

    testPortableVersionState();
    testBlendAndCheckpointAbi();
    if (failures != 0) {
        std::cerr << failures << " assertion(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all Metal layout/state tests passed\n";
    return EXIT_SUCCESS;
}
