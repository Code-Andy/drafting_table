#pragma once

#include "DTCore.hpp"

#include <cstddef>
#include <mutex>
#include <span>
#include <vector>

namespace drafting_table {

struct Stroke {
    std::vector<PencilSample> points;
};

/// Thread-safe ownership boundary around the portable DrawingEngine. The
/// retained stroke list is temporary renderer state; document/layer storage
/// will replace it as the Android model is extracted into core/.
class Engine final {
public:
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

    std::vector<Stroke> snapshot() const;
    std::size_t strokeCount() const;
    std::size_t sampleCount() const;
    /// Monotonically increasing mutation counter for render/snapshot clients.
    std::uint64_t revision() const;

private:
    void rebuildActiveStroke();

    mutable std::mutex mutex_;
    std::vector<Stroke> strokes_;
    Stroke activeStroke_;
    DrawingEngine inputEngine_;
    bool strokeInProgress_ = false;
    std::uint64_t revision_ = 0;
};

} // namespace drafting_table
