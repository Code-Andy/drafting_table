#pragma once
#include "DTCore.hpp"
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <span>
#include <string>
#include <vector>
// NOTE: these types deliberately live in drafting_table::ipad, not
// drafting_table. core/include/DTDocument.hpp already defines
// drafting_table::Page and drafting_table::Layer with different layouts;
// sharing those names caused an ODR violation where the linker folded
// vector<Page> across translation units and Engine::Engine() overflowed
// the heap on first launch (v0.7/v0.7.1 beige-screen SIGABRT).
namespace drafting_table::ipad {
// Tool values match the Android toolset order (brush, eraser, line,
// rectangle, ellipse) plus circle. Bucket, shade, and selection tools have
// no retained-stroke representation yet and intentionally have no values:
// unknown raw values fail archive decode, so placeholders must never be
// persisted.
enum class DTTool : std::uint8_t { Brush = 0, Eraser = 1, Line = 2, Rectangle = 3, Ellipse = 4, Circle = 5, Shade = 6, Bucket = 7 };
constexpr std::uint32_t kDefaultBrushColorRGBA = 0x2B2926FFu;
constexpr float kDefaultBrushHardness = 0.8f;
struct Stroke {
 std::vector<PencilSample> points;
 DTTool tool=DTTool::Brush;
 float brushSize=8.0f;
 float brushOpacity=1.0f;
 std::uint32_t brushColorRGBA=kDefaultBrushColorRGBA;
 float brushHardness=kDefaultBrushHardness;
};
struct Layer { std::string name="Ink"; bool visible=true; float opacity=1.0f; std::vector<Stroke> strokes; std::vector<Stroke> redoStrokes; };
struct Page { std::string name="Page 1"; std::vector<Layer> layers; std::size_t activeLayer=0; };
class Engine final {
public:
 Engine();
 DTTool tool() const; void setTool(DTTool); float brushSize() const; void setBrushSize(float); float brushOpacity() const; void setBrushOpacity(float); std::uint32_t brushColorRGBA() const; void setBrushColorRGBA(std::uint32_t); float brushHardness() const; void setBrushHardness(float);
 void beginStroke(); void appendSamples(std::span<const PencilSample> real,std::span<const PencilSample> predicted={}); bool updateEstimatedSample(std::uint64_t,const PencilSample&); void endStroke(); void cancelStroke(); void clear(); bool undoLastStroke(); bool redoLastStroke(); bool canUndo() const; bool canRedo() const;
 bool moveStrokes(std::span<const std::size_t> indices, float dx, float dy);
 bool scaleStrokes(std::span<const std::size_t> indices, float sx, float sy, float originX, float originY);
 bool rotateStrokes(std::span<const std::size_t> indices, float angleRad, float originX, float originY);
 bool deleteStrokes(std::span<const std::size_t> indices);
 bool duplicateStrokes(std::span<const std::size_t> indices, float dx=0.0f, float dy=0.0f);
 std::size_t hitTestStroke(float x, float y, float tolerance) const;
 bool addStroke(const Stroke& stroke);
 std::size_t activeLayerStrokeCount() const;
 std::size_t pageCount() const; std::size_t activePageIndex() const; std::size_t activeLayerIndex() const; std::vector<std::string> pageNames() const; std::vector<std::string> layerNames() const;
 bool addPage(const std::string& name={}); bool selectPage(std::size_t); bool deletePage(std::size_t); bool renamePage(std::size_t,const std::string&);
 std::size_t duplicatePage(std::size_t); bool movePage(std::size_t from,std::size_t to);
 bool addLayer(const std::string& name={}); bool selectLayer(std::size_t); bool deleteLayer(std::size_t); bool renameLayer(std::size_t,const std::string&);
 std::size_t duplicateLayer(std::size_t); bool moveLayer(std::size_t from,std::size_t to);
 bool activeLayerVisible() const; bool setActiveLayerVisible(bool); float activeLayerOpacity() const; bool setActiveLayerOpacity(float);
 bool layerVisible(std::size_t index) const; float layerOpacity(std::size_t index) const;
 bool setLayerVisible(std::size_t index, bool visible); bool setLayerOpacity(std::size_t index, float opacity);
 std::vector<std::uint8_t> archive() const; bool loadArchive(std::span<const std::uint8_t>); std::vector<std::uint8_t> encodeArchive() const{return archive();} bool decodeArchive(std::span<const std::uint8_t> d){return loadArchive(d);}
 std::vector<Stroke> snapshot() const; std::vector<Stroke> snapshotForPage(std::size_t pageIndex) const; std::vector<Stroke> snapshotForDisplay(std::size_t pageIndex,std::size_t maxPointsPerStroke,std::size_t maxTotalPoints) const; std::size_t strokeCount() const; std::size_t sampleCount() const; std::uint64_t revision() const;
private:
 void rebuildActiveStroke(); void cancelStrokeUnlocked(); std::vector<Stroke> snapshotForPageUnlocked(std::size_t pageIndex) const; Page& activePageUnlocked(){return pages_[activePage_];} const Page& activePageUnlocked()const{return pages_[activePage_];} Layer& activeLayerUnlocked(){auto&p=activePageUnlocked();return p.layers[p.activeLayer];} const Layer& activeLayerUnlocked()const{auto&p=activePageUnlocked();return p.layers[p.activeLayer];}
 mutable std::mutex mutex_; std::vector<Page> pages_; std::size_t activePage_=0; Stroke activeStroke_; DrawingEngine inputEngine_; bool strokeInProgress_=false; DTTool tool_=DTTool::Brush; float brushSize_=8.0f; float brushOpacity_=1.0f; std::uint32_t brushColorRGBA_=kDefaultBrushColorRGBA; float brushHardness_=kDefaultBrushHardness; std::uint64_t revision_=0;
};
} // namespace drafting_table::ipad
