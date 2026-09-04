#pragma once

// Serial transaction protocol shared by the document actor, Metal renderer,
// and package I/O service.  The coordinator owns no GPU resources and never
// stores pixels.  It validates immutable before/after references, assigns
// monotonic operation/generation IDs, and exposes exact restore plans for
// undo/redo.

#include "DTDocument.hpp"

#include <cstdint>
#include <deque>
#include <optional>
#include <span>
#include <string>
#include <unordered_map>
#include <vector>

namespace drafting_table {

using OperationID = std::uint64_t;
using TransactionGeneration = std::uint64_t;

enum class TransactionKind : std::uint8_t {
    Raster = 0,
    LayerMetadata = 1,
    Composite = 2,
    Undo = 3,
    Redo = 4,
};

struct OperationToken {
    OperationID operationID = 0;
    TransactionGeneration generation = 0;
    TransactionKind kind = TransactionKind::Raster;

    constexpr bool valid() const noexcept {
        return operationID != 0 && generation != 0;
    }
    constexpr explicit operator bool() const noexcept { return valid(); }
    bool operator==(const OperationToken&) const = default;
};

// One tile mutation.  Both references use the same address and the `after`
// reference must carry the reservation's generation when a renderer commits.
// A zero-version `before` means a transparent/unmaterialized tile.  A zero-
// version `after` is reserved for a restore plan that removes that tile.
struct RasterVersionSwap {
    PageID pageID{};
    LayerID layerID{};
    TileVersionRef before{};
    TileVersionRef after{};

    bool operator==(const RasterVersionSwap&) const = default;
};

struct LayerMetadataSwap {
    PageID pageID{};
    LayerID layerID{};
    LayerMetadata before{};
    LayerMetadata after{};

    bool operator==(const LayerMetadataSwap&) const = default;
};

// A normal renderer completion may contain raster and metadata changes from
// one user action.  The convenience aliases/methods below cover the common
// raster-only and metadata-only paths without introducing a second history.
struct CompletedRasterOperation {
    OperationToken token{};
    std::vector<RasterVersionSwap> tileSwaps;
    std::vector<LayerMetadataSwap> metadataSwaps;

    bool operator==(const CompletedRasterOperation&) const = default;
};
using CompletedOperation = CompletedRasterOperation;
using RasterTransaction = CompletedRasterOperation;

enum class UndoDirection : std::uint8_t { Undo = 0, Redo = 1 };

enum class UndoStatus : std::uint8_t {
    Applied = 0,     // A restore plan is returned and awaits completion.
    Queued = 1,      // An operation is in flight; request is retained in order.
    Unavailable = 2, // No history exists in the requested direction.
    Rejected = 3,    // The caller supplied a stale/invalid completion.
};

// The renderer applies this plan by copying immutable payloads into new GPU
// tile versions.  Non-empty `after` refs have a new versionID and the plan's
// generation.  If the source was already durable its payloadID can be reused;
// otherwise the renderer/I/O path must create a new payload asynchronously. An
// empty `after` means erase.
struct RestorePlan {
    OperationToken token{}; // kind is Undo or Redo
    OperationID sourceOperationID = 0;
    TransactionGeneration sourceGeneration = 0;
    UndoDirection direction = UndoDirection::Undo;
    std::vector<RasterVersionSwap> tileSwaps;
    std::vector<LayerMetadataSwap> metadataSwaps;

    bool valid() const noexcept { return token.valid() && sourceOperationID != 0; }
    bool operator==(const RestorePlan&) const = default;
};

struct UndoRequestResult {
    UndoStatus status = UndoStatus::Unavailable;
    std::optional<RestorePlan> plan;
    std::size_t pendingRequestCount = 0;

    explicit operator bool() const noexcept { return status == UndoStatus::Applied; }
};

// I/O returns one binding for each tile whose immutable payload has completed
// readback/compression.  The acknowledgement generation is supplied by the
// operation token, so a stale writer cannot mark a newer tile durable.
struct PersistedTileBinding {
    PageID pageID{};
    LayerID layerID{};
    TileAddress address{};
    std::uint64_t versionID = 0;
    std::string payloadID;

    bool operator==(const PersistedTileBinding&) const = default;
};

class RasterTransactionCoordinator {
public:
    // IDs start at firstGeneration (normally one).  The initial document
    // state is generation firstGeneration - 1 and has no operation history.
    explicit RasterTransactionCoordinator(
        TransactionGeneration firstGeneration = 1) noexcept;

    bool idle() const noexcept { return !inFlight_.has_value(); }
    bool hasInFlightOperation() const noexcept { return inFlight_.has_value(); }
    const std::optional<OperationToken>& inFlight() const noexcept { return inFlight_; }
    OperationID nextOperationID() const noexcept { return nextOperationID_; }
    TransactionGeneration nextGeneration() const noexcept { return nextGeneration_; }
    TransactionGeneration currentGeneration() const noexcept { return currentGeneration_; }
    std::size_t historySize() const noexcept { return history_.size(); }
    std::size_t historyCursor() const noexcept { return historyCursor_; }
    std::size_t pendingUndoCount() const noexcept { return pendingRequests_.size(); }
    const std::string& lastError() const noexcept { return lastError_; }

    // All callers must invoke these methods on the document/transaction
    // serial queue.  A second reservation is rejected until the first one is
    // committed or aborted; no shared writable state is exposed.
    std::optional<OperationToken> reserve(
        TransactionKind kind = TransactionKind::Raster);
    std::optional<OperationToken> reserveRasterOperation() {
        return reserve(TransactionKind::Raster);
    }
    std::optional<OperationToken> beginRasterOperation() {
        return reserveRasterOperation();
    }
    std::optional<OperationToken> reserveLayerMetadataOperation() {
        return reserve(TransactionKind::LayerMetadata);
    }
    std::optional<OperationToken> reserveCompositeOperation() {
        return reserve(TransactionKind::Composite);
    }

    bool commit(const CompletedRasterOperation& completion);
    bool commitRasterOperation(const CompletedRasterOperation& completion) {
        return commit(completion);
    }
    bool completeRasterOperation(const CompletedRasterOperation& completion) {
        return commit(completion);
    }
    bool commitRasterOperation(
        const OperationToken& token,
        std::span<const RasterVersionSwap> tileSwaps,
        std::span<const LayerMetadataSwap> metadataSwaps = {});
    bool commitLayerMetadataOperation(
        const OperationToken& token,
        std::span<const LayerMetadataSwap> metadataSwaps);
    bool abort(const OperationToken& token);

    // Undo/redo are renderer transactions.  If a brush command is still
    // in-flight, the request is queued and no history cursor is changed.
    UndoRequestResult requestUndo();
    UndoRequestResult requestRedo();
    UndoRequestResult processQueuedUndo();
    bool completeRestore(const RestorePlan& plan, bool success = true);
    bool finishRestore(const RestorePlan& plan, bool success = true) {
        return completeRestore(plan, success);
    }
    bool cancelRestore(const RestorePlan& plan) { return completeRestore(plan, false); }
    bool canUndo() const noexcept;
    bool canRedo() const noexcept;

    // Seed the coordinator with the package/document state before accepting
    // the first renderer operation.  These methods do not create history.
    bool seedTileVersion(PageID pageID, LayerID layerID,
                         const TileVersionRef& version);
    bool seedLayerMetadata(PageID pageID, const LayerMetadata& metadata);
    const TileVersionRef* currentTileVersion(PageID pageID, LayerID layerID,
                                             TileAddress address) const noexcept;
    const LayerMetadata* currentLayerMetadata(PageID pageID,
                                              LayerID layerID) const noexcept;

    // Persistence acknowledges an immutable operation generation after its
    // payloads and manifest are durable.  Acknowledging an old operation is
    // valid even after undo; current tile refs are updated only when they
    // still point at that exact version.
    bool acknowledgePersistence(const OperationToken& token);
    bool acknowledgePersistence(
        const OperationToken& token,
        std::span<const PersistedTileBinding> bindings);
    bool acknowledgePersistence(OperationID operationID,
                                TransactionGeneration generation);
    bool acknowledgePersistence(
        OperationID operationID,
        TransactionGeneration generation,
        std::span<const PersistedTileBinding> bindings);
    bool acknowledgePersistence(TransactionGeneration generation);
    bool isPersistenceAcknowledged(OperationID operationID) const noexcept;
    std::vector<OperationToken> pendingPersistence() const;

private:
    struct TileKey {
        PageID pageID{};
        LayerID layerID{};
        std::int64_t addressKey = 0;
        bool operator==(const TileKey&) const = default;
    };
    struct MetadataKey {
        PageID pageID{};
        LayerID layerID{};
        bool operator==(const MetadataKey&) const = default;
    };
    struct TileKeyHash {
        std::size_t operator()(const TileKey& key) const noexcept;
    };
    struct MetadataKeyHash {
        std::size_t operator()(const MetadataKey& key) const noexcept;
    };
    struct OperationRecord {
        OperationToken token{};
        std::vector<RasterVersionSwap> tileSwaps;
        std::vector<LayerMetadataSwap> metadataSwaps;
        bool persistenceAcknowledged = false;
        bool restore = false;
    };

    bool fail(const char* message);
    bool validateToken(const OperationToken& token) const;
    bool validateMetadataSwap(const LayerMetadataSwap& swap) const;
    bool validateRasterSwap(const RasterVersionSwap& swap,
                            TransactionGeneration generation) const;
    bool commitInternal(const CompletedRasterOperation& completion,
                        bool appendToHistory);
    UndoRequestResult requestRestore(UndoDirection direction);
    RestorePlan makeRestorePlan(UndoDirection direction);
    bool validateRestorePlan(const RestorePlan& plan) const;
    void applyTileSwaps(std::span<const RasterVersionSwap> swaps);
    void applyMetadataSwaps(std::span<const LayerMetadataSwap> swaps);
    std::size_t appendOperation(OperationRecord record, bool appendToHistory);
    void clearInFlight() noexcept;
    static TileVersionRef emptyTile(TileAddress address) noexcept;
    static TileVersionRef restoreTarget(const TileVersionRef& source,
                                        TileAddress address,
                                        TransactionGeneration generation,
                                        std::uint64_t versionID);

    OperationID nextOperationID_ = 1;
    TransactionGeneration nextGeneration_ = 1;
    std::uint64_t nextVersionID_ = 1;
    TransactionGeneration currentGeneration_ = 0;
    OperationID currentOperationID_ = 0;
    std::optional<OperationToken> inFlight_;
    std::optional<RestorePlan> inFlightRestore_;
    std::deque<UndoDirection> pendingRequests_;

    std::unordered_map<TileKey, TileVersionRef, TileKeyHash> currentTiles_;
    std::unordered_map<MetadataKey, LayerMetadata, MetadataKeyHash> currentMetadata_;
    std::vector<OperationRecord> operations_;
    std::unordered_map<OperationID, std::size_t> operationIndices_;
    std::vector<std::size_t> history_;
    std::size_t historyCursor_ = 0;
    std::string lastError_;
};

// Short alias for clients that do not need the implementation's raster name.
using TransactionCoordinator = RasterTransactionCoordinator;

} // namespace drafting_table
