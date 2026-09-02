#pragma once
#include "DTCore.hpp"
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <span>
#include <string>
#include <vector>
namespace drafting_table {
enum class DTTool : std::uint8_t { Brush = 0, Eraser = 1 };
struct Stroke { std::vector<PencilSample> points; DTTool tool=DTTool::Brush; float brushSize=8.0f; float brushOpacity=1.0f; };
struct Layer { std::string name="Ink"; bool visible=true; float opacity=1.0f; std::vector<Stroke> strokes; std::vector<Stroke> redoStrokes; };
struct Page { std::string name="Page 1"; std::vector<Layer> layers; std::size_t activeLayer=0; };
class Engine final {
public:
 Engine();
 DTTool tool() const; void setTool(DTTool); float brushSize() const; void setBrushSize(float); float brushOpacity() const; void setBrushOpacity(float);
 void beginStroke(); void appendSamples(std::span<const PencilSample> real,std::span<const PencilSample> predicted={}); bool updateEstimatedSample(std::uint64_t,const PencilSample&); void endStroke(); void cancelStroke(); void clear(); bool undoLastStroke(); bool redoLastStroke(); bool canUndo() const; bool canRedo() const;
 std::size_t pageCount() const; std::size_t activePageIndex() const; std::size_t activeLayerIndex() const; std::vector<std::string> pageNames() const; std::vector<std::string> layerNames() const;
 bool addPage(const std::string& name={}); bool selectPage(std::size_t); bool deletePage(std::size_t); bool renamePage(std::size_t,const std::string&);
 bool addLayer(const std::string& name={}); bool selectLayer(std::size_t); bool deleteLayer(std::size_t); bool renameLayer(std::size_t,const std::string&);
 bool activeLayerVisible() const; bool setActiveLayerVisible(bool); float activeLayerOpacity() const; bool setActiveLayerOpacity(float);
 bool layerVisible(std::size_t index) const; float layerOpacity(std::size_t index) const;
 bool setLayerVisible(std::size_t index, bool visible); bool setLayerOpacity(std::size_t index, float opacity);
 std::vector<std::uint8_t> archive() const; bool loadArchive(std::span<const std::uint8_t>); std::vector<std::uint8_t> encodeArchive() const{return archive();} bool decodeArchive(std::span<const std::uint8_t> d){return loadArchive(d);}
 std::vector<Stroke> snapshot() const; std::size_t strokeCount() const; std::size_t sampleCount() const; std::uint64_t revision() const;
private:
 void rebuildActiveStroke(); void cancelStrokeUnlocked(); Page& activePageUnlocked(){return pages_[activePage_];} const Page& activePageUnlocked()const{return pages_[activePage_];} Layer& activeLayerUnlocked(){auto&p=activePageUnlocked();return p.layers[p.activeLayer];} const Layer& activeLayerUnlocked()const{auto&p=activePageUnlocked();return p.layers[p.activeLayer];}
 mutable std::mutex mutex_; std::vector<Page> pages_; std::size_t activePage_=0; Stroke activeStroke_; DrawingEngine inputEngine_; bool strokeInProgress_=false; DTTool tool_=DTTool::Brush; float brushSize_=8.0f; float brushOpacity_=1.0f; std::uint64_t revision_=0;
};
}
