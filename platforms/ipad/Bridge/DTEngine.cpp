#include "DTEngine.hpp"

namespace drafting_table {

void Engine::beginStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (strokeInProgress_) inputEngine_.cancelStroke();
    activeStroke_.points.clear();
    inputEngine_.beginStroke();
    strokeInProgress_ = true;
    ++revision_;
}

void Engine::appendSamples(std::span<const PencilSample> real,
                           std::span<const PencilSample> predicted) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!strokeInProgress_) return;
    inputEngine_.appendSamples(real, predicted);
    rebuildActiveStroke();
    ++revision_;
}

bool Engine::updateEstimatedSample(std::uint64_t estimationUpdateIndex,
                                   const PencilSample& replacement) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!strokeInProgress_) return false;
    const bool updated = inputEngine_.updateEstimatedSampleByIndex(
        estimationUpdateIndex, replacement);
    if (updated) rebuildActiveStroke();
    if (updated) ++revision_;
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
    ++revision_;
}

void Engine::cancelStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    inputEngine_.cancelStroke();
    activeStroke_.points.clear();
    strokeInProgress_ = false;
    ++revision_;
}

void Engine::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    inputEngine_.cancelStroke();
    inputEngine_.clearCommittedSamples();
    strokes_.clear();
    activeStroke_.points.clear();
    strokeInProgress_ = false;
    ++revision_;
}

bool Engine::undoLastStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    // An in-flight stroke is never committed; cancel it before undoing the
    // last finished stroke so a toolbar undo is deterministic.
    bool changed = false;
    if (strokeInProgress_) {
        inputEngine_.cancelStroke();
        activeStroke_.points.clear();
        strokeInProgress_ = false;
        changed = true;
    }
    if (!strokes_.empty()) {
        strokes_.pop_back();
        changed = true;
    }
    if (!changed) return false;
    ++revision_;
    return true;
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

std::uint64_t Engine::revision() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return revision_;
}

} // namespace drafting_table
