#include "DTDocument.hpp"

#include <algorithm>
#include <cmath>

namespace drafting_table {

Layer::Layer(LayerType type, std::string name) : type_(type), name_(std::move(name)) {}

void Layer::setType(LayerType type) noexcept {
    if (type_ == type) return;
    type_ = type;
    if (type_ == LayerType::Raster) {
        clearVectorShapes();
    } else {
        clearTiles();
    }
}

void Layer::setOpacity(float opacity) noexcept {
    if (!std::isfinite(opacity)) opacity = 1.0f;
    opacity_ = std::clamp(opacity, 0.0f, 1.0f);
}

RasterTile* Layer::findTile(TileAddress address) noexcept {
    auto it = tiles_.find(address.key());
    return it == tiles_.end() ? nullptr : &it->second;
}
const RasterTile* Layer::findTile(TileAddress address) const noexcept {
    auto it = tiles_.find(address.key());
    return it == tiles_.end() ? nullptr : &it->second;
}
RasterTile& Layer::ensureTile(TileAddress address) { return tiles_[address.key()]; }
bool Layer::eraseTile(TileAddress address) noexcept { return tiles_.erase(address.key()) != 0; }

void Layer::addLine(const Line& shape) { if (type_ == LayerType::Vector) lines_.push_back(shape); }
void Layer::addRect(const Rect& shape) { if (type_ == LayerType::Vector) rects_.push_back(shape); }
void Layer::addEllipse(const Ellipse& shape) { if (type_ == LayerType::Vector) ellipses_.push_back(shape); }
void Layer::addCircle(const Circle& shape) { if (type_ == LayerType::Vector) circles_.push_back(shape); }
void Layer::clearVectorShapes() noexcept {
    lines_.clear(); rects_.clear(); ellipses_.clear(); circles_.clear();
}

Page::Page(PageBounds bounds) : bounds_(bounds) {
    layers_.emplace_back(LayerType::Raster, "Raster");
}
Layer* Page::layer(std::size_t index) noexcept { return index < layers_.size() ? &layers_[index] : nullptr; }
const Layer* Page::layer(std::size_t index) const noexcept { return index < layers_.size() ? &layers_[index] : nullptr; }
Layer* Page::activeLayer() noexcept { return layer(activeLayer_); }
const Layer* Page::activeLayer() const noexcept { return layer(activeLayer_); }
bool Page::setActiveLayer(std::size_t index) noexcept {
    if (index >= layers_.size()) return false;
    activeLayer_ = index; return true;
}
std::size_t Page::addLayer(LayerType type, std::string name) {
    layers_.emplace_back(type, std::move(name));
    activeLayer_ = layers_.size() - 1;
    return activeLayer_;
}
bool Page::removeLayer(std::size_t index) noexcept {
    if (index >= layers_.size() || layers_.size() <= 1) return false;
    layers_.erase(layers_.begin() + static_cast<std::ptrdiff_t>(index));
    if (activeLayer_ > index) --activeLayer_;
    else if (activeLayer_ >= layers_.size()) activeLayer_ = layers_.size() - 1;
    return true;
}
bool Page::moveLayer(std::size_t from, std::size_t to) noexcept {
    if (from >= layers_.size() || to >= layers_.size() || from == to) return false;
    Layer moved = std::move(layers_[from]);
    layers_.erase(layers_.begin() + static_cast<std::ptrdiff_t>(from));
    layers_.insert(layers_.begin() + static_cast<std::ptrdiff_t>(to), std::move(moved));
    if (activeLayer_ == from) activeLayer_ = to;
    else if (from < activeLayer_ && activeLayer_ <= to) --activeLayer_;
    else if (to <= activeLayer_ && activeLayer_ < from) ++activeLayer_;
    return true;
}

Document::Document(std::string name) : name_(std::move(name)) {
    pages_.emplace_back();
}
Page* Document::page(std::size_t index) noexcept { return index < pages_.size() ? &pages_[index] : nullptr; }
const Page* Document::page(std::size_t index) const noexcept { return index < pages_.size() ? &pages_[index] : nullptr; }
Page* Document::activePage() noexcept { return page(activePage_); }
const Page* Document::activePage() const noexcept { return page(activePage_); }
bool Document::setActivePage(std::size_t index) noexcept {
    if (index >= pages_.size()) return false;
    activePage_ = index; return true;
}
std::size_t Document::addPage(PageBounds bounds) {
    pages_.emplace_back(bounds); activePage_ = pages_.size() - 1; return activePage_;
}
bool Document::removePage(std::size_t index) noexcept {
    if (index >= pages_.size() || pages_.size() <= 1) return false;
    pages_.erase(pages_.begin() + static_cast<std::ptrdiff_t>(index));
    if (activePage_ > index) --activePage_;
    else if (activePage_ >= pages_.size()) activePage_ = pages_.size() - 1;
    return true;
}
bool Document::movePage(std::size_t from, std::size_t to) noexcept {
    if (from >= pages_.size() || to >= pages_.size() || from == to) return false;
    Page moved = std::move(pages_[from]);
    pages_.erase(pages_.begin() + static_cast<std::ptrdiff_t>(from));
    pages_.insert(pages_.begin() + static_cast<std::ptrdiff_t>(to), std::move(moved));
    if (activePage_ == from) activePage_ = to;
    else if (from < activePage_ && activePage_ <= to) --activePage_;
    else if (to <= activePage_ && activePage_ < from) ++activePage_;
    return true;
}

} // namespace drafting_table
