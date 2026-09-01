#include "DTEngine.hpp"

namespace drafting_table {

void Engine::beginStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (strokeInProgress_) inputEngine_.cancelStroke();
    activeStroke_.points.clear();
    inputEngine_.beginStroke();
    strokeInProgress_ = true;
}

void Engine::appendSamples(std::span<const PencilSample> real,
                           std::span<const PencilSample> predicted) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!strokeInProgress_) return;
    inputEngine_.appendSamples(real, predicted);
    rebuildActiveStroke();
}

bool Engine::updateEstimatedSample(std::uint64_t estimationUpdateIndex,
                                   const PencilSample& replacement) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!strokeInProgress_) return false;
    const bool updated = inputEngine_.updateEstimatedSampleByIndex(
        estimationUpdateIndex, replacement);
    if (updated) rebuildActiveStroke();
    return updated;
}

void Engine::rebuildActiveStroke() {
    activeStroke_.points = inputEngine_.realSamples();
    activeStroke_.points.insert(activeStroke_.points.end(),
                                inputEngine_.predictedSamples().begin(),
                                inputEngine_.predictedSamples().end());
}

void Engine::endStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!strokeInProgress_) return;
    if (!inputEngine_.realSamples().empty()) {
        strokes_.push_back({inputEngine_.realSamples()});
    }
    inputEngine_.endStroke();
    inputEngine_.clearCommittedSamples();
    activeStroke_.points.clear();
    strokeInProgress_ = false;
}

void Engine::cancelStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    inputEngine_.cancelStroke();
    activeStroke_.points.clear();
    strokeInProgress_ = false;
}

void Engine::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    inputEngine_.cancelStroke();
    inputEngine_.clearCommittedSamples();
    strokes_.clear();
    activeStroke_.points.clear();
    strokeInProgress_ = false;
}

std::vector<Stroke> Engine::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto result = strokes_;
    if (strokeInProgress_ && !activeStroke_.points.empty()) {
        result.push_back(activeStroke_);
    }
    return result;
}

std::size_t Engine::strokeCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return strokes_.size() + (strokeInProgress_ && !activeStroke_.points.empty() ? 1u : 0u);
}

std::size_t Engine::sampleCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::size_t count = 0;
    for (const Stroke& stroke : strokes_) count += stroke.points.size();
    if (strokeInProgress_) count += activeStroke_.points.size();
    return count;
}

} // namespace drafting_table
