#pragma once

// Platform-neutral document model.  This file intentionally contains no
// graphics, file-system, UIKit, Android or Objective-C types.

#include "DTCore.hpp"

#include <array>
#include <compare>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace drafting_table {

constexpr std::size_t kRasterTileBytes = static_cast<std::size_t>(kDefaultTileSize) *
                                          static_cast<std::size_t>(kDefaultTileSize) * 4u;

// Stable identities are deliberately separate types even though they are
// represented by a 64-bit integer.  A zero value means "not assigned" and is
// never handed out by the document model.  IDs are stable across moves and
// reordering; index positions are not identities.
struct PageID {
    std::uint64_t value = 0;

    constexpr PageID() = default;
    constexpr PageID(std::uint64_t raw) : value(raw) {}
    constexpr bool valid() const noexcept { return value != 0; }
    constexpr explicit operator bool() const noexcept { return valid(); }
    constexpr bool operator==(const PageID&) const = default;
    constexpr auto operator<=>(const PageID&) const = default;
};

struct LayerID {
    std::uint64_t value = 0;

    constexpr LayerID() = default;
    constexpr LayerID(std::uint64_t raw) : value(raw) {}
    constexpr bool valid() const noexcept { return value != 0; }
    constexpr explicit operator bool() const noexcept { return valid(); }
    constexpr bool operator==(const LayerID&) const = default;
    constexpr auto operator<=>(const LayerID&) const = default;
};

// RGBA8, premultiplied-alpha tile.  This is retained solely as a compatibility
// representation for the legacy DTAR/archive importer.  The live renderer
// must not write this map; it exchanges immutable TileVersionRef records and
// owns writable pixels in its Metal tile cache.  The explicit array (rather
// than a packed GL texture object) keeps the importer type-safe and portable.
struct RasterTile {
    std::array<std::uint8_t, kRasterTileBytes> pixels{};
    bool operator==(const RasterTile&) const = default;
};

enum class LayerType : std::uint8_t { Raster = 0, Vector = 1 };

struct PageBounds {
    float x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    constexpr bool valid() const noexcept { return x1 > x0 && y1 > y0; }
    constexpr bool operator==(const PageBounds&) const = default;
};

// Metadata is intentionally free of pixels.  It is copied into renderer
// snapshots and transaction records, so changing a layer's UI properties does
// not require copying its raster content.
struct LayerMetadata {
    LayerID id{};
    LayerType type = LayerType::Raster;
    std::string name;
    bool visible = true;
    float opacity = 1.0f;

    bool operator==(const LayerMetadata&) const = default;
};

// A version reference is the live raster model.  payloadID names an
// immutable object in the package/object store when one has been assigned;
// versionID identifies the renderer version that produced it.  A GPU commit
// may leave payloadID empty while persistedGeneration is zero; the I/O service
// attaches the payload identity when it acknowledges that exact generation.
struct TileVersionRef {
    TileAddress address{};
    std::uint64_t versionID = 0;
    std::uint64_t contentGeneration = 0;
    std::uint64_t persistedGeneration = 0;
    std::string payloadID;

    constexpr bool hasVersion() const noexcept { return versionID != 0; }
    // Valid in the live renderer.  An empty payload is intentional while an
    // asynchronous readback/compression job is pending.
    bool valid() const noexcept {
        return versionID != 0 && contentGeneration != 0 &&
               persistedGeneration <= contentGeneration &&
               (persistedGeneration == 0 || !payloadID.empty());
    }
    bool durable() const noexcept {
        return valid() && persistedGeneration != 0 && !payloadID.empty();
    }
    bool operator==(const TileVersionRef&) const = default;
};

// Lightweight metadata snapshot used by render submissions.  Tile pixels are
// represented only by immutable references, so taking a snapshot is O(number
// of layers + referenced tiles), not a full-page pixel copy.
struct RenderLayerSnapshot {
    LayerID id{};
    LayerType type = LayerType::Raster;
    std::string name;
    bool visible = true;
    float opacity = 1.0f;
    std::vector<TileVersionRef> tileVersions;

    bool operator==(const RenderLayerSnapshot&) const = default;
};

struct RenderMetadataSnapshot {
    PageID pageID{};
    PageBounds bounds{};
    std::uint64_t documentGeneration = 0;
    std::size_t activeLayerIndex = 0;
    LayerID activeLayerID{};
    std::vector<RenderLayerSnapshot> layers;

    bool operator==(const RenderMetadataSnapshot&) const = default;
};

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

class Layer {
public:
    explicit Layer(LayerType type = LayerType::Raster,
                   std::string name = {},
                   LayerID id = {});
    Layer(LayerID id, LayerType type, std::string name = {});

    LayerID id() const noexcept { return id_; }
    // IDs are normally assigned by the model.  This setter exists for a
    // package decoder/import bridge that has already validated an ID.
    void setID(LayerID id) noexcept;

    LayerType type() const noexcept { return type_; }
    void setType(LayerType type) noexcept;
    const std::string& name() const noexcept { return name_; }
    void setName(std::string name) { name_ = std::move(name); }
    bool visible() const noexcept { return visible_; }
    void setVisible(bool visible) noexcept { visible_ = visible; }
    float opacity() const noexcept { return opacity_; }
    void setOpacity(float opacity) noexcept;

    LayerMetadata metadata() const;
    bool applyMetadata(const LayerMetadata& metadata);

    // Legacy raster storage is sparse: asking for a tile does not allocate it.
    // These accessors are importer-only; live rendering uses tileVersions().
    const std::unordered_map<std::int64_t, RasterTile>& tiles() const noexcept { return tiles_; }
    std::unordered_map<std::int64_t, RasterTile>& tiles() noexcept { return tiles_; }
    const std::unordered_map<std::int64_t, RasterTile>& legacyTiles() const noexcept { return tiles_; }
    std::unordered_map<std::int64_t, RasterTile>& legacyTiles() noexcept { return tiles_; }
    RasterTile* findTile(TileAddress address) noexcept;
    const RasterTile* findTile(TileAddress address) const noexcept;
    RasterTile& ensureTile(TileAddress address);
    bool eraseTile(TileAddress address) noexcept;
    void clearTiles() noexcept { tiles_.clear(); }

    // Live raster state is a sparse map of immutable version references.  It
    // is deliberately separate from the legacy pixel map above.
    const std::unordered_map<std::int64_t, TileVersionRef>& tileVersions() const noexcept {
        return tileVersions_;
    }
    std::unordered_map<std::int64_t, TileVersionRef>& tileVersions() noexcept {
        return tileVersions_;
    }
    TileVersionRef* findTileVersion(TileAddress address) noexcept;
    const TileVersionRef* findTileVersion(TileAddress address) const noexcept;
    TileVersionRef& ensureTileVersion(TileAddress address);
    bool setTileVersion(const TileVersionRef& version);
    bool eraseTileVersion(TileAddress address) noexcept;
    void clearTileVersions() noexcept { tileVersions_.clear(); }

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
    LayerID id_{};
    LayerType type_ = LayerType::Raster;
    std::string name_;
    bool visible_ = true;
    float opacity_ = 1.0f;
    std::unordered_map<std::int64_t, RasterTile> tiles_;
    std::unordered_map<std::int64_t, TileVersionRef> tileVersions_;
    std::vector<Line> lines_;
    std::vector<Rect> rects_;
    std::vector<Ellipse> ellipses_;
    std::vector<Circle> circles_;
};

class Page {
public:
    explicit Page(PageBounds bounds = {}, PageID id = {});
    Page(PageID id, PageBounds bounds = {});
    PageID id() const noexcept { return id_; }
    void setID(PageID id) noexcept;
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
    std::size_t addLayer(LayerType type, std::string name, LayerID id);
    bool removeLayer(std::size_t index) noexcept;
    bool moveLayer(std::size_t from, std::size_t to) noexcept;
    Layer* layerByID(LayerID id) noexcept;
    const Layer* layerByID(LayerID id) const noexcept;
    RenderMetadataSnapshot renderMetadataSnapshot(
        std::uint64_t documentGeneration = 0) const;

private:
    PageID id_{};
    PageBounds bounds_{};
    std::vector<Layer> layers_;
    std::size_t activeLayer_ = 0;
};

class Document {
public:
    explicit Document(std::string name = {});
    const std::string& name() const noexcept { return name_; }
    void setName(std::string name) { name_ = std::move(name); }
    std::uint64_t generation() const noexcept { return generation_; }
    void setGeneration(std::uint64_t generation) noexcept;
    std::uint64_t advanceGeneration() noexcept;
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
    std::size_t addPage(PageBounds bounds, PageID id);
    bool removePage(std::size_t index) noexcept;
    bool movePage(std::size_t from, std::size_t to) noexcept;
    Page* pageByID(PageID id) noexcept;
    const Page* pageByID(PageID id) const noexcept;
    RenderMetadataSnapshot renderMetadataSnapshot(
        std::size_t pageIndex = static_cast<std::size_t>(-1)) const;

private:
    std::string name_;
    std::uint64_t generation_ = 1;
    std::vector<Page> pages_;
    std::size_t activePage_ = 0;
};

} // namespace drafting_table

namespace dt = drafting_table;

// Strong IDs are useful as unordered-map keys in platform bridges and tests.
// The specializations are intentionally based only on the stable numeric
// value; zero remains a valid hash input for an unassigned ID.
namespace std {
template <>
struct hash<drafting_table::PageID> {
    std::size_t operator()(drafting_table::PageID id) const noexcept {
        return std::hash<std::uint64_t>{}(id.value);
    }
};

template <>
struct hash<drafting_table::LayerID> {
    std::size_t operator()(drafting_table::LayerID id) const noexcept {
        return std::hash<std::uint64_t>{}(id.value);
    }
};
} // namespace std
