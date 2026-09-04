#pragma once

// A platform-neutral description of the Metal tile renderer.  This header is
// intentionally free of Objective-C, UIKit, Metal, and OpenGL types.  The
// implementation accepts opaque native handles so callers can keep those
// framework types at the iPad bridge boundary.

#include "DTCore.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace drafting_table::metal {

inline constexpr std::int32_t kTileSize = kDefaultTileSize;
inline constexpr std::int32_t kTileApron = 1;
inline constexpr std::int32_t kTileTextureExtent = kTileSize + 2 * kTileApron;
inline constexpr std::size_t kTileInteriorPixelCount =
    static_cast<std::size_t>(kTileSize) * static_cast<std::size_t>(kTileSize);
inline constexpr std::size_t kTileInteriorRGBABytes = kTileInteriorPixelCount * 4u;

struct TileLayout {
    static constexpr std::int32_t tileSize = kTileSize;
    static constexpr std::int32_t apron = kTileApron;
    static constexpr std::int32_t textureExtent = kTileTextureExtent;

    static TileAddress addressFor(Vec2 documentPoint) {
        return TileAddress::fromDocument(documentPoint, tileSize);
    }
    static constexpr Vec2 localPoint(TileAddress tile, Vec2 documentPoint) {
        return {documentPoint.x - static_cast<float>(tile.x) * tileSize,
                documentPoint.y - static_cast<float>(tile.y) * tileSize};
    }
    // Texture-space coordinates include the one-pixel apron.  Dabs may be
    // supplied just outside [0, tileSize] so neighboring tiles can be baked
    // without a separate edge primitive.
    static constexpr Vec2 texturePoint(Vec2 tileLocalPoint) {
        return {tileLocalPoint.x + apron, tileLocalPoint.y + apron};
    }
};

struct PremultipliedColor {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;
    float a = 0.0f;
};

// GPU instance layout: 48 bytes, matching the DTMetalDabInstance struct in
// DTMetalShaders.metal.  Color is premultiplied; the color pass uses OVER.
struct alignas(16) DabInstance {
    Vec2 center{};       // tile-local pixels; [0, 256] is the interior
    Vec2 radii{};        // oriented ellipse semi-axes; equal for round dabs
    float rotationRadians = 0.0f;
    float opacity = 1.0f;
    float hardness = 0.85f;
    float reserved = 0.0f;
    std::array<float, 4> colorPremultiplied{};

    constexpr DabInstance() = default;
    constexpr DabInstance(Vec2 centerPoint,
                          float radiusPixels,
                          float opacityValue,
                          float hardnessValue,
                          PremultipliedColor color)
        : center(centerPoint),
          radii{radiusPixels, radiusPixels},
          opacity(opacityValue),
          hardness(hardnessValue),
          colorPremultiplied{color.r, color.g, color.b, color.a} {}

    constexpr DabInstance(Vec2 centerPoint,
                          Vec2 radiusPixels,
                          float rotation,
                          float opacityValue,
                          float hardnessValue,
                          PremultipliedColor color)
        : center(centerPoint),
          radii(radiusPixels),
          rotationRadians(rotation),
          opacity(opacityValue),
          hardness(hardnessValue),
          colorPremultiplied{color.r, color.g, color.b, color.a} {}
};
static_assert(sizeof(DabInstance) == 48, "Metal dab instance layout changed");
static_assert(alignof(DabInstance) == 16, "Metal dab instance alignment changed");

struct TileDabBatch {
    TileAddress tile{};
    std::span<const DabInstance> dabs{};
};

// Blend modes are explicit at the renderer boundary.  The lower-case aliases
// preserve the naming used by the original Android code while the upper-case
// spellings are convenient for Swift/Objective-C++ bridges.
enum class DabBlendMode : std::uint8_t {
    SourceOver = 0,
    sourceOver = SourceOver,
    DestinationOut = 1,
    destinationOut = DestinationOut,
};
using BlendMode = DabBlendMode;

enum class TileResidency : std::uint8_t {
    Unloaded = 0,
    unloaded = Unloaded,
    Loading = 1,
    loading = Loading,
    ResidentClean = 2,
    residentClean = ResidentClean,
    ResidentDirty = 3,
    residentDirty = ResidentDirty,
    CheckpointPending = 4,
    checkpointPending = CheckpointPending,
    Evictable = 5,
    evictable = Evictable,
};

// A version reference is metadata only.  Pixel ownership remains inside the
// Metal implementation; callers retain the reference for undo, persistence,
// and export without receiving a second writable pixel store.
struct TileVersionRef {
    TileAddress tile{};
    std::uint64_t generation = 0;
    bool exists = false;

    constexpr bool operator==(const TileVersionRef&) const = default;
};

struct TileVersionSet {
    std::uint64_t operationId = 0;
    std::uint64_t generation = 0;
    std::vector<TileVersionRef> tiles;

    bool empty() const noexcept { return tiles.empty(); }
};

struct TileCommitVersions {
    TileVersionSet before;
    TileVersionSet after;
    bool succeeded = false;
};

enum class CheckpointStatus : std::uint8_t {
    Pending = 0,
    Ready = 1,
    Failed = 2,
};

// CheckpointTicket is an opaque identity for an asynchronous shared-buffer
// readback.  The 256x256 interior is always exactly kTileInteriorRGBABytes
// bytes of premultiplied RGBA8; the apron is intentionally excluded.
struct CheckpointTicket {
    std::uint64_t id = 0;
    TileAddress tile{};
    std::uint64_t generation = 0;
    std::size_t byteCount = kTileInteriorRGBABytes;

    constexpr explicit operator bool() const noexcept { return id != 0; }
    constexpr bool operator==(const CheckpointTicket&) const = default;
};

struct TileStateInfo {
    TileAddress tile{};
    std::uint64_t contentGeneration = 0;
    std::uint64_t persistedGeneration = 0;
    TileResidency residency = TileResidency::Unloaded;
    bool hasCommittedVersion = false;
    bool hasWorkingVersion = false;
    bool hasPreviewVersion = false;
    bool dirtyApron = false;
    bool inFlight = false;
};

// Portable state ledger used by ABI tests and by bridges that need to inspect
// ownership without importing Objective-C/Metal types.  The Obj-C++ Backend
// maintains the same invariants for actual textures.  This class stores only
// metadata and never pixel bytes.
class TileVersionLedger final {
public:
    explicit TileVersionLedger(std::size_t maxTiles = 0) noexcept
        : maxTiles_(maxTiles) {}

    TileVersionLedger(const TileVersionLedger&) = delete;
    TileVersionLedger& operator=(const TileVersionLedger&) = delete;

    bool begin(std::uint64_t operationId,
               std::span<const TileAddress> touchedTiles) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || activeOperation_ != 0) return false;
        if (maxTiles_ != 0) {
            std::unordered_set<std::int64_t> incoming;
            for (const TileAddress tile : touchedTiles) {
                if (entries_.find(tile.key()) == entries_.end()) incoming.insert(tile.key());
            }
            if (entries_.size() + incoming.size() > maxTiles_) return false;
        }
        for (const TileAddress tile : touchedTiles) {
            const auto found = entries_.find(tile.key());
            if (found != entries_.end() && found->second.info.inFlight) return false;
        }
        activeOperation_ = operationId;
        activeTiles_.clear();
        before_.clear();
        for (const TileAddress tile : touchedTiles) {
            const auto key = tile.key();
            if (!activeTiles_.insert(key).second) continue;
            auto found = entries_.find(key);
            if (found == entries_.end()) {
                Entry entry;
                entry.info.tile = tile;
                found = entries_.emplace(key, std::move(entry)).first;
            }
            Entry& entry = found->second;
            entry.info.hasWorkingVersion = true;
            entry.info.hasPreviewVersion = false;
            entry.info.residency = entry.info.hasCommittedVersion
                ? TileResidency::ResidentDirty
                : TileResidency::ResidentDirty;
            before_.push_back({tile, entry.info.contentGeneration,
                               entry.info.hasCommittedVersion});
        }
        // Empty begin is intentional: a stroke can enlist tiles lazily as
        // input batches expand.  A caller may use extend() before committing.
        return true;
    }

    bool begin(std::uint64_t operationId) {
        return begin(operationId, std::span<const TileAddress>{});
    }

    bool begin(std::uint64_t operationId,
               const std::vector<TileAddress>& touchedTiles) {
        return begin(operationId,
                     std::span<const TileAddress>(touchedTiles.data(), touchedTiles.size()));
    }

    bool extend(std::uint64_t operationId,
                std::span<const TileAddress> touchedTiles) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || operationId != activeOperation_) return false;
        if (maxTiles_ != 0) {
            std::unordered_set<std::int64_t> incoming;
            for (const TileAddress tile : touchedTiles) {
                if (activeTiles_.find(tile.key()) == activeTiles_.end() &&
                    entries_.find(tile.key()) == entries_.end()) {
                    incoming.insert(tile.key());
                }
            }
            if (entries_.size() + incoming.size() > maxTiles_) return false;
        }
        for (const TileAddress tile : touchedTiles) {
            const auto found = entries_.find(tile.key());
            if (found != entries_.end() && found->second.info.inFlight) return false;
        }
        for (const TileAddress tile : touchedTiles) {
            const auto key = tile.key();
            if (!activeTiles_.insert(key).second) continue;
            auto found = entries_.find(key);
            if (found == entries_.end()) {
                Entry entry;
                entry.info.tile = tile;
                found = entries_.emplace(key, std::move(entry)).first;
            }
            Entry& entry = found->second;
            entry.info.hasWorkingVersion = true;
            entry.info.hasPreviewVersion = false;
            entry.info.residency = TileResidency::ResidentDirty;
            before_.push_back({tile, entry.info.contentGeneration,
                               entry.info.hasCommittedVersion});
        }
        return true;
    }

    bool replacePreview(std::uint64_t operationId) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || operationId != activeOperation_) return false;
        for (const auto key : activeTiles_) {
            auto found = entries_.find(key);
            if (found == entries_.end()) return false;
            found->second.info.hasPreviewVersion = true;
        }
        return true;
    }

    bool discardPreview(std::uint64_t operationId) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || operationId != activeOperation_) return false;
        for (const auto key : activeTiles_) {
            auto found = entries_.find(key);
            if (found != entries_.end()) found->second.info.hasPreviewVersion = false;
        }
        return true;
    }

    // Restore is copy-on-write: the requested historical generation becomes
    // the working source for the active operation, while the currently
    // committed generation remains untouched until complete().
    bool restore(std::uint64_t operationId,
                 std::span<const TileVersionRef> versions) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || operationId != activeOperation_ || versions.empty()) return false;
        for (const TileVersionRef& version : versions) {
            const auto key = version.tile.key();
            if (activeTiles_.find(key) == activeTiles_.end()) return false;
            auto found = entries_.find(key);
            if (found == entries_.end() || found->second.info.inFlight) return false;
            found->second.info.hasWorkingVersion = true;
            found->second.info.hasPreviewVersion = false;
            found->second.info.dirtyApron = true;
        }
        return true;
    }

    // Marks an encoded transaction as in-flight.  Nothing becomes a new
    // committed generation until complete() is called.
    bool markCommitEncoded(std::uint64_t operationId) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || operationId != activeOperation_ || activeTiles_.empty()) return false;
        for (const auto key : activeTiles_) {
            auto found = entries_.find(key);
            if (found == entries_.end() || found->second.info.inFlight) return false;
        }
        for (const auto key : activeTiles_) {
            Entry& entry = entries_.at(key);
            entry.info.inFlight = true;
            entry.info.residency = TileResidency::CheckpointPending;
        }
        return true;
    }

    std::optional<TileCommitVersions> complete(std::uint64_t operationId,
                                               std::uint64_t generation,
                                               bool gpuSucceeded = true) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || generation == 0 || generation <= nextGeneration_ ||
            operationId != activeOperation_ || activeTiles_.empty()) {
            return std::nullopt;
        }
        for (const auto key : activeTiles_) {
            const auto found = entries_.find(key);
            if (found == entries_.end() || !found->second.info.inFlight) return std::nullopt;
        }
        TileCommitVersions result;
        result.before.operationId = operationId;
        result.before.tiles = before_;
        result.after.operationId = operationId;
        result.after.generation = generation;
        result.after.tiles.reserve(activeTiles_.size());
        if (gpuSucceeded) nextGeneration_ = generation;
        for (const auto key : activeTiles_) {
            Entry& entry = entries_.at(key);
            entry.info.inFlight = false;
            if (gpuSucceeded) {
                entry.info.contentGeneration = generation;
                entry.info.hasCommittedVersion = true;
                entry.info.hasWorkingVersion = false;
                entry.info.hasPreviewVersion = false;
                entry.info.residency = (entry.info.persistedGeneration == generation)
                    ? TileResidency::ResidentClean : TileResidency::ResidentDirty;
                result.after.tiles.push_back({entry.info.tile, generation, true});
            } else {
                entry.info.residency = TileResidency::ResidentDirty;
                result.after.tiles.push_back({entry.info.tile,
                                              entry.info.contentGeneration,
                                              entry.info.hasCommittedVersion});
            }
        }
        result.succeeded = gpuSucceeded;
        activeOperation_ = 0;
        activeTiles_.clear();
        before_.clear();
        return result;
    }

    bool cancel(std::uint64_t operationId) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (operationId == 0 || operationId != activeOperation_) return false;
        for (const auto key : activeTiles_) {
            auto found = entries_.find(key);
            if (found == entries_.end() || found->second.info.inFlight) return false;
            found->second.info.hasWorkingVersion = false;
            found->second.info.hasPreviewVersion = false;
            found->second.info.residency = found->second.info.hasCommittedVersion
                ? (found->second.info.contentGeneration == found->second.info.persistedGeneration
                    ? TileResidency::ResidentClean : TileResidency::ResidentDirty)
                : TileResidency::Unloaded;
            found->second.info.dirtyApron = false;
        }
        activeOperation_ = 0;
        activeTiles_.clear();
        before_.clear();
        return true;
    }

    bool markPersisted(TileAddress tile, std::uint64_t generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(tile.key());
        if (found == entries_.end() || !found->second.info.hasCommittedVersion ||
            generation != found->second.info.contentGeneration) return false;
        found->second.info.persistedGeneration = generation;
        found->second.info.residency = TileResidency::ResidentClean;
        return true;
    }

    bool setApronDirty(TileAddress tile, bool dirty = true) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(tile.key());
        if (found == entries_.end()) return false;
        found->second.info.dirtyApron = dirty;
        return true;
    }

    std::optional<TileStateInfo> state(TileAddress tile) const {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto found = entries_.find(tile.key());
        return found == entries_.end() ? std::nullopt
                                       : std::optional<TileStateInfo>(found->second.info);
    }

    // Purging is deliberately conservative: dirty, in-flight, or previewed
    // entries are retained.  The return value is the number removed.
    std::size_t purgeSafe() {
        std::lock_guard<std::mutex> lock(mutex_);
        std::size_t removed = 0;
        for (auto it = entries_.begin(); it != entries_.end();) {
            const auto& info = it->second.info;
            const bool safe = !info.inFlight && !info.hasWorkingVersion &&
                              !info.hasPreviewVersion && !info.dirtyApron &&
                              (!info.hasCommittedVersion ||
                               info.contentGeneration == info.persistedGeneration);
            if (safe) {
                it = entries_.erase(it);
                ++removed;
            } else {
                ++it;
            }
        }
        return removed;
    }

    std::size_t size() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return entries_.size();
    }

private:
    struct Entry {
        TileStateInfo info{};
    };

    mutable std::mutex mutex_;
    std::unordered_map<std::int64_t, Entry> entries_;
    std::unordered_set<std::int64_t> activeTiles_;
    std::vector<TileVersionRef> before_;
    std::size_t maxTiles_ = 0;
    std::uint64_t activeOperation_ = 0;
    std::uint64_t nextGeneration_ = 0;
};

struct CompositeParameters {
    // Document-to-view transform in the same form as CanvasTransform.  The
    // viewport is in drawable pixels, not UIKit points.
    float scale = 1.0f;
    float rotationRadians = 0.0f;
    Vec2 translation{};
    Vec2 viewportSize{};
    float opacity = 1.0f;
    // Optional document-space page clip. This avoids full-page intermediate
    // textures while keeping edge tiles from drawing outside the paper.
    Vec2 clipMin{};
    Vec2 clipMax{};
    bool clipEnabled = false;
};

enum class BackendResult : std::uint8_t {
    ok = 0,
    invalidArgument,
    unsupported,
    resourceFailure,
    encodingFailure,
    // An asynchronous checkpoint/readback has not reached its command-buffer
    // completion handler yet.  Callers should poll and retry.
    pending,
};

struct BackendOptions {
    // Zero means unlimited. A positive limit fails new allocation instead of
    // silently evicting dirty GPU state; persistence/restore hooks must exist
    // before an eviction policy can be safe.
    std::size_t maxResidentTiles = 0;
};

/// Objective-C++ implementation of a sparse tile backend.
///
/// `nativeDevice`, command buffers, and target textures are opaque pointers to
/// their corresponding Metal objects.  Under ARC, pass them as
/// `(__bridge void *)object`.  The C++ API can therefore remain usable by a
/// portable renderer boundary and does not force Metal headers into core.
class Backend final {
public:
    static std::unique_ptr<Backend> create(void* nativeDevice,
                                           BackendOptions options = {},
                                           std::string* error = nullptr);
    ~Backend();

    Backend(Backend&&) noexcept;
    Backend& operator=(Backend&&) noexcept;
    Backend(const Backend&) = delete;
    Backend& operator=(const Backend&) = delete;

    BackendResult encodeDabs(void* nativeCommandBuffer,
                             const TileDabBatch& batch);
    BackendResult encodeDabs(void* nativeCommandBuffer,
                             std::span<const TileDabBatch> batches);

    // Explicit blend mode overload.  The legacy overloads above are
    // equivalent to SourceOver for both color and coverage targets.
    BackendResult encodeDabs(void* nativeCommandBuffer,
                             const TileDabBatch& batch,
                             DabBlendMode blendMode);
    BackendResult encodeDabs(void* nativeCommandBuffer,
                             std::span<const TileDabBatch> batches,
                             DabBlendMode blendMode);

    // Begin a renderer transaction for the supplied tiles.  The command
    // buffer receives copy-on-write committed -> working copies.  A single
    // transaction is active at a time; the document coordinator is expected
    // to serialize calls.
    BackendResult beginTransaction(void* nativeCommandBuffer,
                                   std::uint64_t operationId,
                                   std::span<const TileAddress> touchedTiles);
    // Strokes may discover additional tiles as coalesced samples arrive.  An
    // empty-tile begin reserves ownership; extendTransactionTiles enlists
    // newly touched tiles on the same serial command stream.
    BackendResult beginTransaction(void* nativeCommandBuffer,
                                   std::uint64_t operationId);
    BackendResult extendTransactionTiles(void* nativeCommandBuffer,
                                         std::uint64_t operationId,
                                         std::span<const TileAddress> touchedTiles);

    // Replaces (never accumulates) the preview texture for the active
    // transaction.  Preview writes are isolated from committed and working
    // pixels and may be discarded at any time before commit.
    BackendResult encodePredictedDabs(void* nativeCommandBuffer,
                                      std::span<const TileDabBatch> batches,
                                      DabBlendMode blendMode = DabBlendMode::SourceOver);
    BackendResult discardPrediction(void* nativeCommandBuffer);

    // Enqueue an atomic transaction commit.  The before/after sets become
    // observable only after the caller commits the command buffer and Metal
    // invokes its completion handler.  Generation is reserved by the
    // document coordinator; the legacy overload is retained only to produce a
    // deterministic invalidArgument result instead of allocating one here.
    BackendResult encodeCommit(void* nativeCommandBuffer,
                               std::uint64_t operationId);
    BackendResult encodeCommit(void* nativeCommandBuffer,
                               std::uint64_t operationId,
                               std::uint64_t generation);
    BackendResult commitStroke(void* nativeCommandBuffer,
                               std::uint64_t operationId,
                               std::uint64_t generation) {
        return encodeCommit(nativeCommandBuffer, operationId, generation);
    }
    std::optional<TileCommitVersions> takeCompletedCommit(
        std::uint64_t operationId);
    // Cancel a not-yet-completed transaction.  This releases COW working and
    // preview resources and relinquishes serial ownership.  An already
    // encoded commit must be allowed to complete and is not cancellable.
    BackendResult cancelTransaction(std::uint64_t operationId) noexcept;

    // Restore a previously captured version set into copy-on-write working
    // textures.  The caller may then commit the restore as a normal
    // transaction.  No CPU pixel buffer is accepted here, avoiding a second
    // writable source of truth.
    BackendResult encodeRestoreVersions(
        void* nativeCommandBuffer,
        const TileVersionSet& versions);
    BackendResult restoreVersions(void* nativeCommandBuffer,
                                  const TileVersionSet& versions) {
        return encodeRestoreVersions(nativeCommandBuffer, versions);
    }

    // Capture exact interior pixels asynchronously into MTLStorageModeShared
    // buffers.  A ticket is ready only after command-buffer completion; use
    // readCheckpoint() to copy bytes into caller-owned storage.
    BackendResult encodeCheckpoint(
        void* nativeCommandBuffer,
        std::span<const TileVersionRef> versions,
        std::vector<CheckpointTicket>& tickets);
    CheckpointStatus checkpointStatus(CheckpointTicket ticket) const noexcept;
    BackendResult readCheckpoint(CheckpointTicket ticket,
                                 std::span<std::uint8_t> destination) const;
    void releaseCheckpoint(CheckpointTicket ticket) noexcept;

    // Upload one persisted, premultiplied RGBA8 interior.  The bytes are
    // copied into a private committed texture through the supplied command
    // buffer and become available at `generation` only after completion.
    BackendResult uploadPersistedTileBytes(void* nativeCommandBuffer,
                                           TileAddress tile,
                                           std::uint64_t generation,
                                           std::span<const std::uint8_t> bytes);

    // Drop historical GPU versions that the document coordinator has removed
    // from undo/persistence reachability.  Current committed/working/preview
    // and in-flight versions are never pruned by this call.
    std::size_t releaseHistoricalVersions(
        std::span<const TileVersionRef> versions) noexcept;
    std::size_t pruneHistoricalVersions(
        std::span<const TileVersionRef> versions) noexcept {
        return releaseHistoricalVersions(versions);
    }

    std::optional<TileStateInfo> tileState(TileAddress tile) const noexcept;

    // Composite resident tile interiors into a drawable or offscreen target.
    // The target must be an MTLTexture with a color format supported by the
    // backend's composite pipeline cache.
    BackendResult encodeComposite(void* nativeCommandBuffer,
                                   void* nativeTargetTexture,
                                   std::span<const TileAddress> visibleTiles,
                                   const CompositeParameters& parameters);

    // Convenience aliases used by bridges that model the operation as a
    // transaction object.  They intentionally retain the same serial rules
    // as begin/extend/commit above.
    BackendResult beginStroke(void* nativeCommandBuffer,
                              std::uint64_t operationId) {
        return beginTransaction(nativeCommandBuffer, operationId);
    }
    BackendResult extendStrokeTiles(void* nativeCommandBuffer,
                                    std::uint64_t operationId,
                                    std::span<const TileAddress> touchedTiles) {
        return extendTransactionTiles(nativeCommandBuffer, operationId, touchedTiles);
    }

    // Pulls edge/corner pixels from resident neighboring tiles into each
    // tile's one-pixel apron. Missing neighbors remain transparent. Call after
    // baking dabs and before linear-filtered or rotated compositing.
    BackendResult encodeApronResolve(void* nativeCommandBuffer);

    std::size_t residentTileCount() const noexcept;
    // Returns an unretained opaque MTLTexture pointer for read-only sampling
    // in a caller-owned pass.  The backend must outlive that pass.
    void* nativeCoverageTexture(TileAddress tile) const noexcept;
    // Removes only clean tiles with no in-flight command/checkpoint and no
    // active preview. Dirty or in-flight versions are intentionally retained.
    void purgeTiles() noexcept;
    const std::string& lastError() const noexcept;

private:
    struct Impl;
    explicit Backend(std::unique_ptr<Impl> implementation) noexcept;
    std::unique_ptr<Impl> impl_;
};

} // namespace drafting_table::metal
