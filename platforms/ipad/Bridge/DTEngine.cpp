#include "DTEngine.hpp"

#include <algorithm>

namespace drafting_table {

void Engine::beginStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    // Start a new stroke immediately. An empty stroke is removed by
    // endStroke, which makes cancelled/palm touches harmless.
    strokes_.emplace_back();
    strokeInProgress_ = true;
}

void Engine::appendPoint(const StrokePoint& point) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!strokeInProgress_ || strokes_.empty()) return;
    // Predicted points form a replaceable tail. Drop that tail as soon as a
    // new real/coalesced sample arrives so predictions never get baked into
    // the committed stroke.
    if (!point.predicted) {
        auto& points = strokes_.back().points;
        points.erase(std::remove_if(points.begin(), points.end(),
                                    [](const StrokePoint& sample) { return sample.predicted; }),
                     points.end());
    }
    strokes_.back().points.push_back(point);
}

void Engine::endStroke() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!strokes_.empty()) {
        auto& points = strokes_.back().points;
        points.erase(std::remove_if(points.begin(), points.end(),
                                    [](const StrokePoint& sample) { return sample.predicted; }),
                     points.end());
        if (points.empty()) strokes_.pop_back();
    }
    strokeInProgress_ = false;
}

void Engine::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    strokes_.clear();
    strokeInProgress_ = false;
}

std::vector<Stroke> Engine::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return strokes_;
}

std::size_t Engine::strokeCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return strokes_.size();
}

std::size_t Engine::sampleCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::size_t count = 0;
    for (const Stroke& stroke : strokes_) count += stroke.points.size();
    return count;
}

} // namespace drafting_table
