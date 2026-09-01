#pragma once

#include "DTCore.hpp"

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <span>
#include <vector>

namespace drafting_table {

enum class DTTool : std::uint8_t {
    Brush = 0,
    Eraser = 1,
};

struct Stroke {
    std::vector<PencilSample> points;
    DTTool tool = DTTool::Brush;
    float brushSize = 8.0f;
    float brushOpacity = 1.0f;
};

/// Thread-safe ownership boundary around the portable DrawingEngine. The
/// retained stroke list is temporary renderer state; document/layer storage
/// will replace it as the Android model is extracted into core/.
class Engine final {
public:
    DTTool tool() const;
    void setTool(DTTool tool);
    float brushSize() const;
    void setBrushSize(float points);
    float brushOpacity() const;
    void setBrushOpacity(float opacity);

    void beginStroke();
    void appendSamples(std::span<const PencilSample> real,
                       std::span<const PencilSample> predicted);
    bool updateEstimatedSample(std::uint64_t estimationUpdateIndex,
                               const PencilSample& replacement);
    void endStroke();
    void cancelStroke();
    void clear();
    /// Remove the most recently committed stroke. Returns false when empty.
    bool undoLastStroke();
    /// Restore the most recently undone stroke. Returns false when empty.
    bool redoLastStroke();
    bool canUndo() const;
    bool canRedo() const;

    // Versioned, little-endian archive of committed strokes.  These methods
    // intentionally use only standard C++ types so the engine remains
    // portable and has no dependency on Foundation/UIKit.
    std::vector<std::uint8_t> archive() const;
    bool loadArchive(std::span<const std::uint8_t> data);
    std::vector<std::uint8_t> encodeArchive() const { return archive(); }
    bool decodeArchive(std::span<const std::uint8_t> data) { return loadArchive(data); }

    std::vector<Stroke> snapshot() const;
    std::size_t strokeCount() const;
    std::size_t sampleCount() const;
    /// Monotonically increasing mutation counter for render/snapshot clients.
    std::uint64_t revision() const;

private:
    void rebuildActiveStroke();

    mutable std::mutex mutex_;
    std::vector<Stroke> strokes_;
    std::vector<Stroke> redoStrokes_;
    Stroke activeStroke_;
    DrawingEngine inputEngine_;
    bool strokeInProgress_ = false;
    DTTool tool_ = DTTool::Brush;
    float brushSize_ = 8.0f;
    float brushOpacity_ = 1.0f;
    std::uint64_t revision_ = 0;
};

} // namespace drafting_table
