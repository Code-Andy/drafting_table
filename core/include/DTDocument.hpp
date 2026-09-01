#pragma once

// Platform-neutral document model.  This file intentionally contains no
// graphics, file-system, UIKit, Android or Objective-C types.

#include "DTCore.hpp"

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace drafting_table {

constexpr std::size_t kRasterTileBytes = static_cast<std::size_t>(kDefaultTileSize) *
                                          static_cast<std::size_t>(kDefaultTileSize) * 4u;

// RGBA8, premultiplied-alpha tile.  A tile is value initialized to transparent
// pixels.  The explicit array (rather than a packed GL texture object) keeps
// this type safe to copy and usable by non-graphics clients.
struct RasterTile {
    std::array<std::uint8_t, kRasterTileBytes> pixels{};
    bool operator==(const RasterTile&) const = default;
};

enum class LayerType : std::uint8_t { Raster = 0, Vector = 1 };

// Geometry records intentionally mirror the Android renderer's stable fields.
// They are standard-layout aggregates and all coordinates are document pixels.
struct Line {
    float x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    std::uint32_t color = 0;
    float width = 1;
};
struct Rect {
    float x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    float rotation = 0;
    std::uint32_t color = 0;
    float width = 1;
};
struct Ellipse {
    float cx = 0, cy = 0, rx = 0, ry = 0;
    float rotation = 0;
    std::uint32_t color = 0;
    float width = 1;
};
struct Circle {
    float cx = 0, cy = 0, radius = 0;
    std::uint32_t color = 0;
    float width = 1;
};

struct PageBounds {
    float x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    constexpr bool valid() const noexcept { return x1 > x0 && y1 > y0; }
};

class Layer {
public:
    explicit Layer(LayerType type = LayerType::Raster, std::string name = {});

    LayerType type() const noexcept { return type_; }
    void setType(LayerType type) noexcept;
    const std::string& name() const noexcept { return name_; }
    void setName(std::string name) { name_ = std::move(name); }
    bool visible() const noexcept { return visible_; }
    void setVisible(bool visible) noexcept { visible_ = visible; }
    float opacity() const noexcept { return opacity_; }
    void setOpacity(float opacity) noexcept;

    // Raster storage is sparse: asking for a tile does not allocate it.
    const std::unordered_map<std::int64_t, RasterTile>& tiles() const noexcept { return tiles_; }
    std::unordered_map<std::int64_t, RasterTile>& tiles() noexcept { return tiles_; }
    RasterTile* findTile(TileAddress address) noexcept;
    const RasterTile* findTile(TileAddress address) const noexcept;
    RasterTile& ensureTile(TileAddress address);
    bool eraseTile(TileAddress address) noexcept;
    void clearTiles() noexcept { tiles_.clear(); }

    const std::vector<Line>& lines() const noexcept { return lines_; }
    const std::vector<Rect>& rects() const noexcept { return rects_; }
    const std::vector<Ellipse>& ellipses() const noexcept { return ellipses_; }
    const std::vector<Circle>& circles() const noexcept { return circles_; }
    std::vector<Line>& lines() noexcept { return lines_; }
    std::vector<Rect>& rects() noexcept { return rects_; }
    std::vector<Ellipse>& ellipses() noexcept { return ellipses_; }
    std::vector<Circle>& circles() noexcept { return circles_; }
    void addLine(const Line& shape);
    void addRect(const Rect& shape);
    void addEllipse(const Ellipse& shape);
    void addCircle(const Circle& shape);
    void clearVectorShapes() noexcept;

private:
    LayerType type_ = LayerType::Raster;
    std::string name_;
    bool visible_ = true;
    float opacity_ = 1.0f;
    std::unordered_map<std::int64_t, RasterTile> tiles_;
    std::vector<Line> lines_;
    std::vector<Rect> rects_;
    std::vector<Ellipse> ellipses_;
    std::vector<Circle> circles_;
};

class Page {
public:
    explicit Page(PageBounds bounds = {});
    const PageBounds& bounds() const noexcept { return bounds_; }
    void setBounds(PageBounds bounds) noexcept { bounds_ = bounds; }

    std::size_t layerCount() const noexcept { return layers_.size(); }
    const std::vector<Layer>& layers() const noexcept { return layers_; }
    std::vector<Layer>& layers() noexcept { return layers_; }
    Layer* layer(std::size_t index) noexcept;
    const Layer* layer(std::size_t index) const noexcept;
    std::size_t activeLayerIndex() const noexcept { return activeLayer_; }
    Layer* activeLayer() noexcept;
    const Layer* activeLayer() const noexcept;
    bool setActiveLayer(std::size_t index) noexcept;
    std::size_t addLayer(LayerType type, std::string name = {});
    bool removeLayer(std::size_t index) noexcept;
    bool moveLayer(std::size_t from, std::size_t to) noexcept;

private:
    PageBounds bounds_{};
    std::vector<Layer> layers_;
    std::size_t activeLayer_ = 0;
};

class Document {
public:
    explicit Document(std::string name = {});
    const std::string& name() const noexcept { return name_; }
    void setName(std::string name) { name_ = std::move(name); }
    std::size_t pageCount() const noexcept { return pages_.size(); }
    const std::vector<Page>& pages() const noexcept { return pages_; }
    std::vector<Page>& pages() noexcept { return pages_; }
    Page* page(std::size_t index) noexcept;
    const Page* page(std::size_t index) const noexcept;
    std::size_t activePageIndex() const noexcept { return activePage_; }
    Page* activePage() noexcept;
    const Page* activePage() const noexcept;
    bool setActivePage(std::size_t index) noexcept;
    std::size_t addPage(PageBounds bounds = {});
    bool removePage(std::size_t index) noexcept;
    bool movePage(std::size_t from, std::size_t to) noexcept;

private:
    std::string name_;
    std::vector<Page> pages_;
    std::size_t activePage_ = 0;
};

} // namespace drafting_table

namespace dt = drafting_table;
