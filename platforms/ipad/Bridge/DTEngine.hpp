#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace drafting_table {

/// A platform-neutral sample. Coordinates are in CanvasView points.
struct StrokePoint {
    float x = 0.0f;
    float y = 0.0f;
    float pressure = 1.0f;
    double timestamp = 0.0;
    bool predicted = false;
};

struct Stroke {
    std::vector<StrokePoint> points;
};

/// Small, deterministic drawing model used by the iPad shell. The Android
/// renderer remains the production engine; this class gives the UIKit port a
/// real ownership/lifetime boundary until that engine is shared.
class Engine final {
public:
    void beginStroke();
    void appendPoint(const StrokePoint& point);
    void endStroke();
    void clear();

    std::vector<Stroke> snapshot() const;
    std::size_t strokeCount() const;
    std::size_t sampleCount() const;

private:
    mutable std::mutex mutex_;
    std::vector<Stroke> strokes_;
    bool strokeInProgress_ = false;
};

} // namespace drafting_table
