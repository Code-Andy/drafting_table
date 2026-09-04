#include "DTDocument.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>

namespace drafting_table {
namespace {

std::atomic<std::uint64_t> gNextPageID{1};
std::atomic<std::uint64_t> gNextLayerID{1};

template <typename ID>
ID allocateID(std::atomic<std::uint64_t>& counter) noexcept {
    // IDs are process-local allocations until a package decoder supplies an
    // explicit persisted value.  The zero value is reserved as "unassigned".
    auto candidate = counter.fetch_add(1, std::memory_order_relaxed);
    if (candidate == 0) {
        candidate = counter.fetch_add(1, std::memory_order_relaxed);
    }
    return ID{candidate};
}

template <typename ID>
void observeID(std::atomic<std::uint64_t>& counter, ID id) noexcept {
    if (!id.valid()) return;
    auto next = counter.load(std::memory_order_relaxed);
    while (next <= id.value &&
           !counter.compare_exchange_weak(next, id.value + 1,
                                           std::memory_order_relaxed,
                                           std::memory_order_relaxed)) {
    }
}

bool validOpacity(float opacity) noexcept {
    return std::isfinite(opacity) && opacity >= 0.0f && opacity <= 1.0f;
}

} // namespace

Layer::Layer(LayerType type, std::string name, LayerID id)
    : id_(id.valid() ? id : allocateID<LayerID>(gNextLayerID)),
      type_(type),
      name_(std::move(name)) {
    observeID(gNextLayerID, id_);
}

Layer::Layer(LayerID id, LayerType type, std::string name)
    : Layer(type, std::move(name), id) {}

void Layer::setID(LayerID id) noexcept {
    if (!id.valid()) return;
    id_ = id;
    observeID(gNextLayerID, id_);
}

void Layer::setType(LayerType type) noexcept {
    if (type_ == type) return;
    type_ = type;
    if (type_ == LayerType::Raster) {
        clearVectorShapes();
    } else {
        // Neither pixel representation is meaningful for a vector layer.
        // Keep the legacy and live stores isolated and clear both explicitly.
        clearTiles();
        clearTileVersions();
    }
}

void Layer::setOpacity(float opacity) noexcept {
    if (!std::isfinite(opacity)) opacity = 1.0f;
    opacity_ = std::clamp(opacity, 0.0f, 1.0f);
}

LayerMetadata Layer::metadata() const {
    return LayerMetadata{id_, type_, name_, visible_, opacity_};
}

bool Layer::applyMetadata(const LayerMetadata& metadataValue) {
    if (!metadataValue.id.valid()) return false;
    if (id_.valid() && metadataValue.id != id_) return false;
    if (!validOpacity(metadataValue.opacity)) return false;
    setID(metadataValue.id);
    setType(metadataValue.type);
    name_ = metadataValue.name;
    visible_ = metadataValue.visible;
    opacity_ = metadataValue.opacity;
    return true;
}

RasterTile* Layer::findTile(TileAddress address) noexcept {
    auto it = tiles_.find(address.key());
    return it == tiles_.end() ? nullptr : &it->second;
}

const RasterTile* Layer::findTile(TileAddress address) const noexcept {
    auto it = tiles_.find(address.key());
    return it == tiles_.end() ? nullptr : &it->second;
}

RasterTile& Layer::ensureTile(TileAddress address) {
    return tiles_[address.key()];
}

bool Layer::eraseTile(TileAddress address) noexcept {
    return tiles_.erase(address.key()) != 0;
}

TileVersionRef* Layer::findTileVersion(TileAddress address) noexcept {
    auto it = tileVersions_.find(address.key());
    return it == tileVersions_.end() ? nullptr : &it->second;
}

const TileVersionRef* Layer::findTileVersion(TileAddress address) const noexcept {
    auto it = tileVersions_.find(address.key());
    return it == tileVersions_.end() ? nullptr : &it->second;
}

TileVersionRef& Layer::ensureTileVersion(TileAddress address) {
    auto& version = tileVersions_[address.key()];
    version.address = address;
    return version;
}

bool Layer::setTileVersion(const TileVersionRef& version) {
    if (!version.valid()) return false;
    tileVersions_[version.address.key()] = version;
    return true;
}

bool Layer::eraseTileVersion(TileAddress address) noexcept {
    return tileVersions_.erase(address.key()) != 0;
}

void Layer::addLine(const Line& shape) {
    if (type_ == LayerType::Vector) lines_.push_back(shape);
}

void Layer::addRect(const Rect& shape) {
    if (type_ == LayerType::Vector) rects_.push_back(shape);
}

void Layer::addEllipse(const Ellipse& shape) {
    if (type_ == LayerType::Vector) ellipses_.push_back(shape);
}

void Layer::addCircle(const Circle& shape) {
    if (type_ == LayerType::Vector) circles_.push_back(shape);
}

void Layer::clearVectorShapes() noexcept {
    lines_.clear();
    rects_.clear();
    ellipses_.clear();
    circles_.clear();
}

Page::Page(PageBounds bounds, PageID id)
    : id_(id.valid() ? id : allocateID<PageID>(gNextPageID)), bounds_(bounds) {
    observeID(gNextPageID, id_);
    layers_.emplace_back(LayerType::Raster, "Raster");
}

Page::Page(PageID id, PageBounds bounds) : Page(bounds, id) {}

void Page::setID(PageID id) noexcept {
    if (!id.valid()) return;
    id_ = id;
    observeID(gNextPageID, id_);
}

Layer* Page::layer(std::size_t index) noexcept {
    return index < layers_.size() ? &layers_[index] : nullptr;
}

const Layer* Page::layer(std::size_t index) const noexcept {
    return index < layers_.size() ? &layers_[index] : nullptr;
}

Layer* Page::activeLayer() noexcept { return layer(activeLayer_); }

const Layer* Page::activeLayer() const noexcept { return layer(activeLayer_); }

bool Page::setActiveLayer(std::size_t index) noexcept {
    if (index >= layers_.size()) return false;
    activeLayer_ = index;
    return true;
}

std::size_t Page::addLayer(LayerType type, std::string name) {
    layers_.emplace_back(type, std::move(name));
    activeLayer_ = layers_.size() - 1;
    return activeLayer_;
}

std::size_t Page::addLayer(LayerType type, std::string name, LayerID id) {
    layers_.emplace_back(type, std::move(name), id);
    activeLayer_ = layers_.size() - 1;
    return activeLayer_;
}

bool Page::removeLayer(std::size_t index) noexcept {
    if (index >= layers_.size() || layers_.size() <= 1) return false;
    layers_.erase(layers_.begin() + static_cast<std::ptrdiff_t>(index));
    if (activeLayer_ > index) {
        --activeLayer_;
    } else if (activeLayer_ >= layers_.size()) {
        activeLayer_ = layers_.size() - 1;
    }
    return true;
}

bool Page::moveLayer(std::size_t from, std::size_t to) noexcept {
    if (from >= layers_.size() || to >= layers_.size() || from == to) return false;
    Layer moved = std::move(layers_[from]);
    layers_.erase(layers_.begin() + static_cast<std::ptrdiff_t>(from));
    layers_.insert(layers_.begin() + static_cast<std::ptrdiff_t>(to),
                   std::move(moved));
    if (activeLayer_ == from) {
        activeLayer_ = to;
    } else if (from < activeLayer_ && activeLayer_ <= to) {
        --activeLayer_;
    } else if (to <= activeLayer_ && activeLayer_ < from) {
        ++activeLayer_;
    }
    return true;
}

Layer* Page::layerByID(LayerID id) noexcept {
    for (auto& candidate : layers_) {
        if (candidate.id() == id) return &candidate;
    }
    return nullptr;
}

const Layer* Page::layerByID(LayerID id) const noexcept {
    for (const auto& candidate : layers_) {
        if (candidate.id() == id) return &candidate;
    }
    return nullptr;
}

RenderMetadataSnapshot Page::renderMetadataSnapshot(
    std::uint64_t documentGeneration) const {
    RenderMetadataSnapshot snapshot;
    snapshot.pageID = id_;
    snapshot.bounds = bounds_;
    snapshot.documentGeneration = documentGeneration;
    snapshot.activeLayerIndex = activeLayer_;
    snapshot.activeLayerID = activeLayer() ? activeLayer()->id() : LayerID{};
    snapshot.layers.reserve(layers_.size());
    for (const auto& layerValue : layers_) {
        RenderLayerSnapshot layerSnapshot;
        layerSnapshot.id = layerValue.id();
        layerSnapshot.type = layerValue.type();
        layerSnapshot.name = layerValue.name();
        layerSnapshot.visible = layerValue.visible();
        layerSnapshot.opacity = layerValue.opacity();
        layerSnapshot.tileVersions.reserve(layerValue.tileVersions().size());
        for (const auto& [key, version] : layerValue.tileVersions()) {
            (void)key;
            layerSnapshot.tileVersions.push_back(version);
        }
        std::sort(layerSnapshot.tileVersions.begin(),
                  layerSnapshot.tileVersions.end(),
                  [](const TileVersionRef& lhs, const TileVersionRef& rhs) {
                      if (lhs.address.y != rhs.address.y) {
                          return lhs.address.y < rhs.address.y;
                      }
                      return lhs.address.x < rhs.address.x;
                  });
        snapshot.layers.push_back(std::move(layerSnapshot));
    }
    return snapshot;
}

Document::Document(std::string name) : name_(std::move(name)) {
    pages_.emplace_back();
}

void Document::setGeneration(std::uint64_t generation) noexcept {
    generation_ = generation == 0 ? 1 : generation;
}

std::uint64_t Document::advanceGeneration() noexcept {
    if (generation_ != std::numeric_limits<std::uint64_t>::max()) ++generation_;
    return generation_;
}

Page* Document::page(std::size_t index) noexcept {
    return index < pages_.size() ? &pages_[index] : nullptr;
}

const Page* Document::page(std::size_t index) const noexcept {
    return index < pages_.size() ? &pages_[index] : nullptr;
}

Page* Document::activePage() noexcept { return page(activePage_); }

const Page* Document::activePage() const noexcept { return page(activePage_); }

bool Document::setActivePage(std::size_t index) noexcept {
    if (index >= pages_.size()) return false;
    activePage_ = index;
    return true;
}

std::size_t Document::addPage(PageBounds bounds) {
    pages_.emplace_back(bounds);
    activePage_ = pages_.size() - 1;
    return activePage_;
}

std::size_t Document::addPage(PageBounds bounds, PageID id) {
    pages_.emplace_back(bounds, id);
    activePage_ = pages_.size() - 1;
    return activePage_;
}

bool Document::removePage(std::size_t index) noexcept {
    if (index >= pages_.size() || pages_.size() <= 1) return false;
    pages_.erase(pages_.begin() + static_cast<std::ptrdiff_t>(index));
    if (activePage_ > index) {
        --activePage_;
    } else if (activePage_ >= pages_.size()) {
        activePage_ = pages_.size() - 1;
    }
    return true;
}

bool Document::movePage(std::size_t from, std::size_t to) noexcept {
    if (from >= pages_.size() || to >= pages_.size() || from == to) return false;
    Page moved = std::move(pages_[from]);
    pages_.erase(pages_.begin() + static_cast<std::ptrdiff_t>(from));
    pages_.insert(pages_.begin() + static_cast<std::ptrdiff_t>(to),
                  std::move(moved));
    if (activePage_ == from) {
        activePage_ = to;
    } else if (from < activePage_ && activePage_ <= to) {
        --activePage_;
    } else if (to <= activePage_ && activePage_ < from) {
        ++activePage_;
    }
    return true;
}

Page* Document::pageByID(PageID id) noexcept {
    for (auto& candidate : pages_) {
        if (candidate.id() == id) return &candidate;
    }
    return nullptr;
}

const Page* Document::pageByID(PageID id) const noexcept {
    for (const auto& candidate : pages_) {
        if (candidate.id() == id) return &candidate;
    }
    return nullptr;
}

RenderMetadataSnapshot Document::renderMetadataSnapshot(std::size_t pageIndex) const {
    if (pageIndex == static_cast<std::size_t>(-1)) pageIndex = activePage_;
    const auto* selected = page(pageIndex);
    return selected ? selected->renderMetadataSnapshot(generation_)
                    : RenderMetadataSnapshot{};
}

} // namespace drafting_table
