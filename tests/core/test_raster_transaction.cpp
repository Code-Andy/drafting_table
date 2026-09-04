#include "DTRasterTransaction.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

int failures = 0;
#define CHECK(expression)                                                          \
    do {                                                                            \
        if (!(expression)) {                                                        \
            std::cerr << "FAIL line " << __LINE__ << ": " << #expression << '\n'; \
            ++failures;                                                            \
        }                                                                               \
    } while (false)

namespace dt = drafting_table;

dt::TileVersionRef version(dt::TileAddress address,
                           std::uint64_t versionID,
                           std::uint64_t generation,
                           std::string payload) {
    return dt::TileVersionRef{address, versionID, generation, 0,
                              std::move(payload)};
}

void testDocumentIdentityAndSnapshot() {
    dt::Document document("snapshot");
    const auto pageID = document.activePage()->id();
    const auto layerID = document.activePage()->activeLayer()->id();
    CHECK(pageID.valid() && layerID.valid());

    auto* page = document.activePage();
    page->activeLayer()->setTileVersion(version({1, 0}, 3, 1, "tile-b"));
    page->activeLayer()->setTileVersion(version({-1, 0}, 2, 1, "tile-a"));
    page->addLayer(dt::LayerType::Vector, "vectors");
    const auto snapshot = document.renderMetadataSnapshot();
    CHECK(snapshot.layers.size() == 2);
    const auto& refs = snapshot.layers[0].tileVersions;
    CHECK(refs.size() == 2 && refs[0].address.x == -1 && refs[1].address.x == 1);

    CHECK(page->moveLayer(1, 0));
    CHECK(page->layerByID(layerID) != nullptr);
    CHECK(page->layerByID(layerID)->id() == layerID);
    CHECK(document.pageByID(pageID) == page);
}

void testRasterUndoRedoAndPersistence() {
    const dt::PageID page{17};
    const dt::LayerID layer{23};
    const dt::TileAddress address{0, 0};
    dt::RasterTransactionCoordinator coordinator;

    const auto token = coordinator.reserveRasterOperation();
    CHECK(token.has_value() && token->operationID == 1 && token->generation == 1);
    // Metal can commit before asynchronous readback has assigned a package
    // payload ID.  The coordinator keeps this live version valid but refuses
    // to call it durable until I/O supplies the binding below.
    const auto after = version(address, 100, token->generation, "");
    const dt::RasterVersionSwap swap{page, layer, dt::TileVersionRef{address}, after};
    CHECK(coordinator.commitRasterOperation(*token, std::span(&swap, 1)));
    CHECK(coordinator.currentGeneration() == 1 && coordinator.canUndo());
    CHECK(coordinator.currentTileVersion(page, layer, address)->versionID == 100);
    CHECK(!coordinator.acknowledgePersistence(*token));
    const dt::PersistedTileBinding binding{page, layer, address, 100,
                                           "payload-a"};
    CHECK(coordinator.acknowledgePersistence(*token, std::span(&binding, 1)));

    const auto undo = coordinator.requestUndo();
    CHECK(undo.status == dt::UndoStatus::Applied && undo.plan.has_value());
    CHECK(undo.plan->token.generation == 2);
    CHECK(undo.plan->tileSwaps.size() == 1);
    CHECK(undo.plan->tileSwaps[0].after.versionID != after.versionID);
    CHECK(undo.plan->tileSwaps[0].after.payloadID.empty());
    CHECK(coordinator.completeRestore(*undo.plan));
    CHECK(coordinator.currentGeneration() == 2 && coordinator.canRedo());
    CHECK(coordinator.currentTileVersion(page, layer, address) == nullptr);

    const auto redo = coordinator.requestRedo();
    CHECK(redo.status == dt::UndoStatus::Applied && redo.plan.has_value());
    CHECK(redo.plan->token.generation == 3);
    CHECK(redo.plan->tileSwaps[0].after.payloadID.empty());
    CHECK(coordinator.completeRestore(*redo.plan));
    CHECK(coordinator.currentGeneration() == 3 && coordinator.canUndo());
    CHECK(coordinator.currentTileVersion(page, layer, address) != nullptr);

    CHECK(coordinator.acknowledgePersistence(token->operationID,
                                             token->generation));
    CHECK(coordinator.isPersistenceAcknowledged(token->operationID));
}

void testPartialPersistenceAckIsAtomic() {
    const dt::PageID page{91};
    const dt::LayerID layer{92};
    const dt::TileAddress firstAddress{0, 0};
    const dt::TileAddress secondAddress{1, 0};
    dt::RasterTransactionCoordinator coordinator;
    const auto token = coordinator.reserveRasterOperation();
    CHECK(token.has_value());
    const dt::TileVersionRef first =
        version(firstAddress, 201, token->generation, "");
    const dt::TileVersionRef second =
        version(secondAddress, 202, token->generation, "");
    const dt::RasterVersionSwap swaps[] = {
        {page, layer, dt::TileVersionRef{firstAddress}, first},
        {page, layer, dt::TileVersionRef{secondAddress}, second},
    };
    CHECK(coordinator.commitRasterOperation(*token, std::span(swaps)));
    const dt::PersistedTileBinding valid{page, layer, firstAddress, 201,
                                         "payload-first"};
    const dt::PersistedTileBinding invalid{page, layer, {99, 99}, 202,
                                           "payload-second"};
    const dt::PersistedTileBinding partial[] = {valid, invalid};
    CHECK(!coordinator.acknowledgePersistence(*token, std::span(partial)));
    CHECK(!coordinator.isPersistenceAcknowledged(token->operationID));
    CHECK(coordinator.currentTileVersion(page, layer, firstAddress)
              ->payloadID.empty());
    CHECK(coordinator.currentTileVersion(page, layer, secondAddress)
              ->payloadID.empty());

    const dt::PersistedTileBinding secondBinding{page, layer, secondAddress,
                                                 202, "payload-second"};
    const dt::PersistedTileBinding complete[] = {valid, secondBinding};
    CHECK(coordinator.acknowledgePersistence(*token, std::span(complete)));
    CHECK(coordinator.isPersistenceAcknowledged(token->operationID));
}

void testQueuedUndoAndMetadataHistory() {
    const dt::PageID page{71};
    const dt::LayerID layer{72};
    dt::RasterTransactionCoordinator coordinator;
    const auto token = coordinator.reserveRasterOperation();
    CHECK(token.has_value());
    const auto queued = coordinator.requestUndo();
    CHECK(queued.status == dt::UndoStatus::Queued && queued.pendingRequestCount == 1);
    const dt::TileAddress address{2, -3};
    const auto after = version(address, 11, token->generation, "payload");
    const dt::RasterVersionSwap swap{page, layer, dt::TileVersionRef{address}, after};
    CHECK(coordinator.commitRasterOperation(*token, std::span(&swap, 1)));
    const auto plan = coordinator.processQueuedUndo();
    CHECK(plan.status == dt::UndoStatus::Applied && plan.plan.has_value());
    CHECK(coordinator.completeRestore(*plan.plan));

    const auto metadataToken = coordinator.reserveLayerMetadataOperation();
    CHECK(metadataToken.has_value());
    const dt::LayerMetadata before{layer, dt::LayerType::Raster, "Ink", true, 1.0f};
    const dt::LayerMetadata afterMetadata{layer, dt::LayerType::Raster, "Ink", false, 0.5f};
    const dt::LayerMetadataSwap metadataSwap{page, layer, before, afterMetadata};
    CHECK(coordinator.commitLayerMetadataOperation(*metadataToken,
                                                   std::span(&metadataSwap, 1)));
    CHECK(coordinator.canUndo());
    const auto metadataUndo = coordinator.requestUndo();
    CHECK(metadataUndo.status == dt::UndoStatus::Applied &&
          metadataUndo.plan->metadataSwaps.size() == 1);
    CHECK(metadataUndo.plan->metadataSwaps[0].after.visible);
    CHECK(coordinator.completeRestore(*metadataUndo.plan));
    CHECK(coordinator.currentLayerMetadata(page, layer)->visible);
}

} // namespace

int main() {
    testDocumentIdentityAndSnapshot();
    testRasterUndoRedoAndPersistence();
    testPartialPersistenceAckIsAtomic();
    testQueuedUndoAndMetadataHistory();
    if (failures != 0) {
        std::cerr << failures << " assertion(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all raster transaction tests passed\n";
    return EXIT_SUCCESS;
}
