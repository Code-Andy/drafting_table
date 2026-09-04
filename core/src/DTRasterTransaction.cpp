#include "DTRasterTransaction.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <unordered_set>

namespace drafting_table {
namespace {

bool validLayerType(LayerType type) noexcept {
    return type == LayerType::Raster || type == LayerType::Vector;
}

bool validOpacity(float opacity) noexcept {
    return std::isfinite(opacity) && opacity >= 0.0f && opacity <= 1.0f;
}

std::size_t mixHash(std::size_t seed, std::size_t value) noexcept {
    // The constant is the usual 64-bit hash-combine increment; truncation on
    // 32-bit targets is intentional and still leaves all fields represented.
    return seed ^ (value + static_cast<std::size_t>(0x9e3779b97f4a7c15ull) +
                   (seed << 6u) + (seed >> 2u));
}

} // namespace

std::size_t RasterTransactionCoordinator::TileKeyHash::operator()(
    const TileKey& key) const noexcept {
    auto result = std::hash<std::uint64_t>{}(key.pageID.value);
    result = mixHash(result, std::hash<std::uint64_t>{}(key.layerID.value));
    result = mixHash(result, std::hash<std::int64_t>{}(key.addressKey));
    return result;
}

std::size_t RasterTransactionCoordinator::MetadataKeyHash::operator()(
    const MetadataKey& key) const noexcept {
    auto result = std::hash<std::uint64_t>{}(key.pageID.value);
    return mixHash(result, std::hash<std::uint64_t>{}(key.layerID.value));
}

RasterTransactionCoordinator::RasterTransactionCoordinator(
    TransactionGeneration firstGeneration) noexcept
    : nextGeneration_(firstGeneration == 0 ? 1 : firstGeneration),
      currentGeneration_(nextGeneration_ - 1) {}

bool RasterTransactionCoordinator::fail(const char* message) {
    lastError_ = message ? message : "transaction rejected";
    return false;
}

std::optional<OperationToken> RasterTransactionCoordinator::reserve(
    TransactionKind kind) {
    if (inFlight_) {
        fail("an operation is already in flight");
        return std::nullopt;
    }
    if (nextOperationID_ == 0 || nextGeneration_ == 0) {
        fail("operation or generation ID space is exhausted");
        return std::nullopt;
    }
    const OperationToken token{nextOperationID_, nextGeneration_, kind};
    ++nextOperationID_;
    ++nextGeneration_;
    inFlight_ = token;
    inFlightRestore_.reset();
    lastError_.clear();
    return token;
}

bool RasterTransactionCoordinator::validateToken(
    const OperationToken& token) const {
    return inFlight_.has_value() && inFlight_.value() == token;
}

bool RasterTransactionCoordinator::validateRasterSwap(
    const RasterVersionSwap& swap,
    TransactionGeneration generation) const {
    if (!swap.pageID.valid() || !swap.layerID.valid()) return false;
    if (swap.before.address != swap.after.address) return false;

    const auto validEmpty = [](const TileVersionRef& ref) {
        return !ref.hasVersion() && ref.contentGeneration == 0 &&
               ref.persistedGeneration == 0 && ref.payloadID.empty();
    };
    if (swap.before.hasVersion()) {
        if (!swap.before.valid()) return false;
    } else if (!validEmpty(swap.before)) {
        return false;
    }

    // A normal renderer completion must always materialize a new immutable
    // version.  Erases are represented only in generated undo/redo plans.
    if (!swap.after.valid() || swap.after.contentGeneration != generation) {
        return false;
    }
    if (swap.after.address != swap.before.address) return false;
    return true;
}

bool RasterTransactionCoordinator::validateMetadataSwap(
    const LayerMetadataSwap& swap) const {
    if (!swap.pageID.valid() || !swap.layerID.valid()) return false;
    if (!swap.before.id.valid() || !swap.after.id.valid()) return false;
    if (swap.before.id != swap.layerID || swap.after.id != swap.layerID) return false;
    if (!validLayerType(swap.before.type) || !validLayerType(swap.after.type)) {
        return false;
    }
    return validOpacity(swap.before.opacity) && validOpacity(swap.after.opacity);
}

bool RasterTransactionCoordinator::commit(
    const CompletedRasterOperation& completion) {
    return commitInternal(completion, true);
}

bool RasterTransactionCoordinator::commitRasterOperation(
    const OperationToken& token,
    std::span<const RasterVersionSwap> tileSwaps,
    std::span<const LayerMetadataSwap> metadataSwaps) {
    CompletedRasterOperation completion;
    completion.token = token;
    completion.tileSwaps.assign(tileSwaps.begin(), tileSwaps.end());
    completion.metadataSwaps.assign(metadataSwaps.begin(), metadataSwaps.end());
    return commit(completion);
}

bool RasterTransactionCoordinator::commitLayerMetadataOperation(
    const OperationToken& token,
    std::span<const LayerMetadataSwap> metadataSwaps) {
    if (token.kind != TransactionKind::LayerMetadata) {
        return fail("metadata completion has the wrong operation kind");
    }
    CompletedRasterOperation completion;
    completion.token = token;
    completion.metadataSwaps.assign(metadataSwaps.begin(), metadataSwaps.end());
    return commit(completion);
}

bool RasterTransactionCoordinator::commitInternal(
    const CompletedRasterOperation& completion,
    bool appendToHistory) {
    if (!validateToken(completion.token)) {
        return fail("completion token is stale or no operation is in flight");
    }
    if (completion.token.kind == TransactionKind::Undo ||
        completion.token.kind == TransactionKind::Redo) {
        return fail("undo and redo must complete through completeRestore");
    }
    if (completion.tileSwaps.empty() && completion.metadataSwaps.empty()) {
        return fail("an operation must contain a tile or metadata change");
    }

    std::unordered_set<TileKey, TileKeyHash> tileKeys;
    std::uint64_t nextVersionID = nextVersionID_;
    for (const auto& swap : completion.tileSwaps) {
        if (!validateRasterSwap(swap, completion.token.generation)) {
            return fail("invalid raster before/after version swap");
        }
        const TileKey key{swap.pageID, swap.layerID, swap.after.address.key()};
        if (!tileKeys.insert(key).second) {
            return fail("an operation contains a duplicate tile address");
        }
        if (swap.after.versionID == std::numeric_limits<std::uint64_t>::max()) {
            return fail("tile version ID space is exhausted");
        }
        nextVersionID = std::max(nextVersionID, swap.after.versionID + 1);
        const auto current = currentTiles_.find(key);
        if (current != currentTiles_.end() && current->second != swap.before) {
            return fail("raster before version does not match the current tile");
        }
    }

    std::unordered_set<MetadataKey, MetadataKeyHash> metadataKeys;
    for (const auto& swap : completion.metadataSwaps) {
        if (!validateMetadataSwap(swap)) {
            return fail("invalid layer metadata swap");
        }
        const MetadataKey key{swap.pageID, swap.layerID};
        if (!metadataKeys.insert(key).second) {
            return fail("an operation contains a duplicate layer metadata swap");
        }
        const auto current = currentMetadata_.find(key);
        if (current != currentMetadata_.end() && current->second != swap.before) {
            return fail("metadata before value does not match the current layer");
        }
    }

    nextVersionID_ = nextVersionID;
    OperationRecord record;
    record.token = completion.token;
    record.tileSwaps = completion.tileSwaps;
    record.metadataSwaps = completion.metadataSwaps;
    appendOperation(std::move(record), appendToHistory);
    applyTileSwaps(completion.tileSwaps);
    applyMetadataSwaps(completion.metadataSwaps);
    currentGeneration_ = completion.token.generation;
    currentOperationID_ = completion.token.operationID;
    clearInFlight();
    lastError_.clear();
    return true;
}

bool RasterTransactionCoordinator::abort(const OperationToken& token) {
    if (!validateToken(token)) return fail("abort token is stale");
    clearInFlight();
    lastError_.clear();
    return true;
}

std::size_t RasterTransactionCoordinator::appendOperation(
    OperationRecord record,
    bool appendToHistory) {
    const auto index = operations_.size();
    operationIndices_[record.token.operationID] = index;
    operations_.push_back(std::move(record));
    if (appendToHistory) {
        // A new edit after undo creates a new branch and drops only the redo
        // cursor.  Old operation records remain available for persistence
        // acknowledgements and diagnostics.
        if (historyCursor_ < history_.size()) history_.resize(historyCursor_);
        history_.push_back(index);
        historyCursor_ = history_.size();
    }
    return index;
}

void RasterTransactionCoordinator::applyTileSwaps(
    std::span<const RasterVersionSwap> swaps) {
    for (const auto& swap : swaps) {
        const TileKey key{swap.pageID, swap.layerID, swap.after.address.key()};
        if (swap.after.hasVersion()) {
            currentTiles_[key] = swap.after;
        } else {
            currentTiles_.erase(key);
        }
    }
}

void RasterTransactionCoordinator::applyMetadataSwaps(
    std::span<const LayerMetadataSwap> swaps) {
    for (const auto& swap : swaps) {
        currentMetadata_[MetadataKey{swap.pageID, swap.layerID}] = swap.after;
    }
}

bool RasterTransactionCoordinator::canUndo() const noexcept {
    return !inFlight_ && historyCursor_ != 0;
}

bool RasterTransactionCoordinator::canRedo() const noexcept {
    return !inFlight_ && historyCursor_ < history_.size();
}

UndoRequestResult RasterTransactionCoordinator::requestUndo() {
    return requestRestore(UndoDirection::Undo);
}

UndoRequestResult RasterTransactionCoordinator::requestRedo() {
    return requestRestore(UndoDirection::Redo);
}

UndoRequestResult RasterTransactionCoordinator::requestRestore(
    UndoDirection direction) {
    if (inFlight_) {
        pendingRequests_.push_back(direction);
        return {UndoStatus::Queued, std::nullopt, pendingRequests_.size()};
    }
    const bool available = direction == UndoDirection::Undo ? historyCursor_ != 0
                                                             : historyCursor_ < history_.size();
    if (!available) {
        return {UndoStatus::Unavailable, std::nullopt, pendingRequests_.size()};
    }
    const auto token = reserve(direction == UndoDirection::Undo
                                   ? TransactionKind::Undo
                                   : TransactionKind::Redo);
    if (!token) {
        return {UndoStatus::Rejected, std::nullopt, pendingRequests_.size()};
    }
    auto plan = makeRestorePlan(direction);
    if (!plan.valid()) {
        clearInFlight();
        fail("unable to build an exact restore plan");
        return {UndoStatus::Rejected, std::nullopt, pendingRequests_.size()};
    }
    inFlightRestore_ = plan;
    return {UndoStatus::Applied, std::move(plan), pendingRequests_.size()};
}

UndoRequestResult RasterTransactionCoordinator::processQueuedUndo() {
    if (inFlight_) {
        return {UndoStatus::Queued, std::nullopt, pendingRequests_.size()};
    }
    if (pendingRequests_.empty()) {
        return {UndoStatus::Unavailable, std::nullopt, 0};
    }
    const auto direction = pendingRequests_.front();
    pendingRequests_.pop_front();
    auto result = requestRestore(direction);
    result.pendingRequestCount = pendingRequests_.size();
    return result;
}

TileVersionRef RasterTransactionCoordinator::emptyTile(TileAddress address) noexcept {
    TileVersionRef empty;
    empty.address = address;
    return empty;
}

TileVersionRef RasterTransactionCoordinator::restoreTarget(
    const TileVersionRef& source,
    TileAddress address,
    TransactionGeneration generation,
    std::uint64_t versionID) {
    if (!source.hasVersion()) return emptyTile(address);
    TileVersionRef target = source;
    target.address = address;
    target.versionID = versionID;
    target.contentGeneration = generation;
    target.persistedGeneration = 0;
    // A restore is a new renderer generation.  Even when the source payload
    // was durable, its object/header identity belongs to the old version; the
    // I/O service must checkpoint this restored version independently.
    target.payloadID.clear();
    return target;
}

RestorePlan RasterTransactionCoordinator::makeRestorePlan(
    UndoDirection direction) {
    RestorePlan plan;
    plan.direction = direction;
    plan.token = *inFlight_;
    const auto historyIndex = direction == UndoDirection::Undo
                                  ? historyCursor_ - 1
                                  : historyCursor_;
    if (historyIndex >= history_.size()) return plan;
    const auto& source = operations_[history_[historyIndex]];
    plan.sourceOperationID = source.token.operationID;
    plan.sourceGeneration = source.token.generation;

    plan.tileSwaps.reserve(source.tileSwaps.size());
    for (const auto& sourceSwap : source.tileSwaps) {
        const auto targetSource = direction == UndoDirection::Undo
                                      ? sourceSwap.before
                                      : sourceSwap.after;
        const auto currentSource = direction == UndoDirection::Undo
                                        ? sourceSwap.after
                                        : sourceSwap.before;
        const TileKey key{sourceSwap.pageID, sourceSwap.layerID,
                          sourceSwap.after.address.key()};
        TileVersionRef current = currentSource;
        if (const auto it = currentTiles_.find(key); it != currentTiles_.end()) {
            current = it->second;
        }
        if (targetSource.hasVersion() && nextVersionID_ == 0) {
            // A wrapped version ID would make two immutable payloads
            // indistinguishable to the renderer/I/O service.
            return RestorePlan{};
        }
        const auto versionID = targetSource.hasVersion() ? nextVersionID_++ : 0;
        const auto target = restoreTarget(targetSource, sourceSwap.after.address,
                                          plan.token.generation, versionID);
        plan.tileSwaps.push_back(
            RasterVersionSwap{sourceSwap.pageID, sourceSwap.layerID, current, target});
    }

    plan.metadataSwaps.reserve(source.metadataSwaps.size());
    for (const auto& sourceSwap : source.metadataSwaps) {
        const auto target = direction == UndoDirection::Undo ? sourceSwap.before
                                                              : sourceSwap.after;
        const auto currentFallback = direction == UndoDirection::Undo
                                         ? sourceSwap.after
                                         : sourceSwap.before;
        LayerMetadata current = currentFallback;
        const MetadataKey key{sourceSwap.pageID, sourceSwap.layerID};
        if (const auto it = currentMetadata_.find(key); it != currentMetadata_.end()) {
            current = it->second;
        }
        plan.metadataSwaps.push_back(LayerMetadataSwap{
            sourceSwap.pageID, sourceSwap.layerID, current, target});
    }
    return plan;
}

bool RasterTransactionCoordinator::validateRestorePlan(
    const RestorePlan& plan) const {
    if (!inFlightRestore_ || *inFlightRestore_ != plan || !plan.valid()) return false;
    if (plan.token.kind != TransactionKind::Undo &&
        plan.token.kind != TransactionKind::Redo) return false;
    std::unordered_set<TileKey, TileKeyHash> tileKeys;
    for (const auto& swap : plan.tileSwaps) {
        if (!swap.pageID.valid() || !swap.layerID.valid() ||
            swap.before.address != swap.after.address) {
            return false;
        }
        const auto current = currentTiles_.find(
            TileKey{swap.pageID, swap.layerID, swap.before.address.key()});
        if (current != currentTiles_.end()) {
            if (current->second != swap.before) return false;
        } else if (swap.before.hasVersion()) {
            return false;
        }
        if (swap.after.hasVersion()) {
            if (!swap.after.valid() ||
                swap.after.contentGeneration != plan.token.generation) {
                return false;
            }
        } else if (swap.after.contentGeneration != 0 ||
                   swap.after.persistedGeneration != 0 ||
                   !swap.after.payloadID.empty()) {
            return false;
        }
        if (!tileKeys.insert(TileKey{swap.pageID, swap.layerID,
                                     swap.before.address.key()})
                 .second) {
            return false;
        }
    }
    std::unordered_set<MetadataKey, MetadataKeyHash> metadataKeys;
    for (const auto& swap : plan.metadataSwaps) {
        if (!validateMetadataSwap(swap)) return false;
        const auto current = currentMetadata_.find(MetadataKey{swap.pageID, swap.layerID});
        if (current != currentMetadata_.end() && current->second != swap.before) {
            return false;
        }
        if (!metadataKeys.insert(MetadataKey{swap.pageID, swap.layerID}).second) {
            return false;
        }
    }
    return !plan.tileSwaps.empty() || !plan.metadataSwaps.empty();
}

bool RasterTransactionCoordinator::completeRestore(const RestorePlan& plan,
                                                   bool success) {
    if (!inFlightRestore_ || !validateToken(plan.token) ||
        inFlightRestore_->token != plan.token) {
        return fail("restore completion token is stale");
    }
    if (!success) {
        clearInFlight();
        lastError_.clear();
        return true;
    }
    if (!validateRestorePlan(plan)) {
        return fail("restore plan no longer matches current document state");
    }
    if (plan.direction == UndoDirection::Undo) {
        if (historyCursor_ == 0) return fail("undo history cursor underflow");
        --historyCursor_;
    } else {
        if (historyCursor_ >= history_.size()) return fail("redo history cursor overflow");
        ++historyCursor_;
    }
    OperationRecord record;
    record.token = plan.token;
    record.tileSwaps = plan.tileSwaps;
    record.metadataSwaps = plan.metadataSwaps;
    record.restore = true;
    appendOperation(std::move(record), false);
    applyTileSwaps(plan.tileSwaps);
    applyMetadataSwaps(plan.metadataSwaps);
    currentGeneration_ = plan.token.generation;
    currentOperationID_ = plan.token.operationID;
    clearInFlight();
    lastError_.clear();
    return true;
}

void RasterTransactionCoordinator::clearInFlight() noexcept {
    inFlight_.reset();
    inFlightRestore_.reset();
}

bool RasterTransactionCoordinator::seedTileVersion(
    PageID pageID,
    LayerID layerID,
    const TileVersionRef& version) {
    if (inFlight_) return fail("cannot seed while an operation is in flight");
    if (!pageID.valid() || !layerID.valid() || !version.valid()) {
        return fail("invalid initial tile version");
    }
    if (version.contentGeneration >= nextGeneration_ && nextGeneration_ != 0) {
        nextGeneration_ = version.contentGeneration ==
                                  std::numeric_limits<TransactionGeneration>::max()
                              ? 0
                              : version.contentGeneration + 1;
    }
    if (version.versionID >= nextVersionID_ && version.versionID != std::numeric_limits<std::uint64_t>::max()) {
        nextVersionID_ = version.versionID + 1;
    }
    currentGeneration_ = std::max(currentGeneration_, version.contentGeneration);
    currentTiles_[TileKey{pageID, layerID, version.address.key()}] = version;
    lastError_.clear();
    return true;
}

bool RasterTransactionCoordinator::seedLayerMetadata(
    PageID pageID,
    const LayerMetadata& metadata) {
    if (inFlight_) return fail("cannot seed while an operation is in flight");
    if (!pageID.valid() || !metadata.id.valid() ||
        !validLayerType(metadata.type) || !validOpacity(metadata.opacity)) {
        return fail("invalid initial layer metadata");
    }
    currentMetadata_[MetadataKey{pageID, metadata.id}] = metadata;
    lastError_.clear();
    return true;
}

const TileVersionRef* RasterTransactionCoordinator::currentTileVersion(
    PageID pageID,
    LayerID layerID,
    TileAddress address) const noexcept {
    const auto it = currentTiles_.find(TileKey{pageID, layerID, address.key()});
    return it == currentTiles_.end() ? nullptr : &it->second;
}

const LayerMetadata* RasterTransactionCoordinator::currentLayerMetadata(
    PageID pageID,
    LayerID layerID) const noexcept {
    const auto it = currentMetadata_.find(MetadataKey{pageID, layerID});
    return it == currentMetadata_.end() ? nullptr : &it->second;
}

bool RasterTransactionCoordinator::acknowledgePersistence(
    const OperationToken& token) {
    return acknowledgePersistence(token.operationID, token.generation);
}

bool RasterTransactionCoordinator::acknowledgePersistence(
    const OperationToken& token,
    std::span<const PersistedTileBinding> bindings) {
    return acknowledgePersistence(token.operationID, token.generation, bindings);
}

bool RasterTransactionCoordinator::acknowledgePersistence(
    OperationID operationID,
    TransactionGeneration generation) {
    if (operationID == 0 || generation == 0) {
        return fail("invalid persistence acknowledgement");
    }
    const auto index = operationIndices_.find(operationID);
    if (index == operationIndices_.end()) return fail("unknown operation ID");
    auto& record = operations_[index->second];
    if (record.token.generation != generation) {
        return fail("persistence generation does not match operation");
    }
    // A payload-less live version cannot be called durable until the I/O
    // service supplies its immutable object identity.  Erases have no payload
    // and therefore do not participate in this check.
    for (const auto& swap : record.tileSwaps) {
        if (swap.after.hasVersion() && swap.after.payloadID.empty()) {
            return fail("persistence acknowledgement is missing a tile payload ID");
        }
    }
    if (!record.persistenceAcknowledged) {
        record.persistenceAcknowledged = true;
        for (auto& swap : record.tileSwaps) {
            if (!swap.after.hasVersion()) continue;
            const TileKey key{swap.pageID, swap.layerID, swap.after.address.key()};
            const auto current = currentTiles_.find(key);
            if (current == currentTiles_.end() ||
                current->second.versionID != swap.after.versionID ||
                current->second.contentGeneration != generation) {
                continue;
            }
            auto acknowledged = current->second;
            acknowledged.persistedGeneration = generation;
            current->second = acknowledged;
            swap.after.persistedGeneration = generation;
        }
    }
    lastError_.clear();
    return true;
}

bool RasterTransactionCoordinator::acknowledgePersistence(
    OperationID operationID,
    TransactionGeneration generation,
    std::span<const PersistedTileBinding> bindings) {
    if (operationID == 0 || generation == 0) {
        return fail("invalid persistence acknowledgement");
    }
    const auto index = operationIndices_.find(operationID);
    if (index == operationIndices_.end()) return fail("unknown operation ID");
    const auto& record = operations_[index->second];
    if (record.token.generation != generation) {
        return fail("persistence generation does not match operation");
    }

    std::unordered_set<std::size_t> matched;
    std::vector<std::pair<std::size_t, std::string>> updates;
    updates.reserve(bindings.size());
    for (const auto& binding : bindings) {
        if (!binding.pageID.valid() || !binding.layerID.valid() ||
            binding.versionID == 0 || binding.payloadID.empty()) {
            return fail("invalid persisted tile binding");
        }
        std::size_t match = record.tileSwaps.size();
        for (std::size_t i = 0; i < record.tileSwaps.size(); ++i) {
            const auto& swap = record.tileSwaps[i];
            if (swap.pageID == binding.pageID && swap.layerID == binding.layerID &&
                swap.after.address == binding.address &&
                swap.after.versionID == binding.versionID) {
                match = i;
                break;
            }
        }
        if (match == record.tileSwaps.size() || !matched.insert(match).second) {
            return fail("persisted tile binding does not match the operation");
        }
        const auto& after = record.tileSwaps[match].after;
        if (!after.payloadID.empty() && after.payloadID != binding.payloadID) {
            return fail("persisted tile binding changes an existing payload ID");
        }
        updates.emplace_back(match, binding.payloadID);
    }

    // Validate completeness before mutating the operation record.  This is
    // important when a provider returns a partial callback: no subset may be
    // published as durable if a later binding turns out to be stale.
    for (std::size_t i = 0; i < record.tileSwaps.size(); ++i) {
        const auto& after = record.tileSwaps[i].after;
        if (after.hasVersion() && after.payloadID.empty() &&
            matched.find(i) == matched.end()) {
            return fail("persistence acknowledgement is missing a tile payload ID");
        }
    }

    if (!updates.empty()) {
        auto& mutableRecord = operations_[index->second];
        for (const auto& [match, payloadID] : updates) {
            mutableRecord.tileSwaps[match].after.payloadID = payloadID;
        }
    }
    return acknowledgePersistence(operationID, generation);
}

bool RasterTransactionCoordinator::acknowledgePersistence(
    TransactionGeneration generation) {
    if (generation == 0) return fail("invalid persistence generation");
    for (auto it = operations_.rbegin(); it != operations_.rend(); ++it) {
        if (it->token.generation == generation) {
            return acknowledgePersistence(it->token.operationID, generation);
        }
    }
    return fail("unknown persistence generation");
}

bool RasterTransactionCoordinator::isPersistenceAcknowledged(
    OperationID operationID) const noexcept {
    const auto it = operationIndices_.find(operationID);
    return it != operationIndices_.end() &&
           operations_[it->second].persistenceAcknowledged;
}

std::vector<OperationToken> RasterTransactionCoordinator::pendingPersistence() const {
    std::vector<OperationToken> pending;
    for (const auto& operation : operations_) {
        if (!operation.persistenceAcknowledged) pending.push_back(operation.token);
    }
    return pending;
}

} // namespace drafting_table
