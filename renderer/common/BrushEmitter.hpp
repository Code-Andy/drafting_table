#pragma once

// Platform-neutral stroke geometry.  This file intentionally has no graphics
// API dependencies; a renderer can consume Dab values and rasterise them in
// Metal, OpenGL, or a CPU test harness.

#include "DTCore.hpp"

#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <utility>
#include <vector>

namespace drafting_table::renderer {

enum class BrushShape : std::uint8_t {
    Round,
    Pencil,
    Marker,
};

struct BrushSettings {
    BrushShape shape = BrushShape::Round;
    float minRadius = 0.0f;
    float maxRadius = 18.0f;
    float sizeScale = 1.0f;
    float spacingFraction = 0.18f;
    float minimumSpacing = 0.5f;
    float minimumDabRadius = 0.05f;
    // Pencil and marker use tilt to turn a circular contact into an ellipse.
    // The marker has a slightly wider nib at the same tilt.
    float pencilAspect = 1.0f;
    float markerAspect = 1.35f;
};

struct BrushFootprint {
    Vec2 center{};
    float radiusX = 0.0f;
    float radiusY = 0.0f;
    float rotationRadians = 0.0f;
    float pressure = 0.0f;
    BrushShape shape = BrushShape::Round;

    bool valid() const;
};

// A dab is the complete geometry and input metadata needed by a backend.
struct Dab {
    BrushFootprint footprint{};
    bool predicted = false;

    Vec2 center() const { return footprint.center; }
    float radius() const;
};

struct StrokeBounds {
    Vec2 min{};
    Vec2 max{};
    bool valid = false;

    void reset();
    void include(const BrushFootprint& footprint);
    void include(const Dab& dab) { include(dab.footprint); }
    void include(Vec2 point);
    bool intersects(Vec2 point) const;
};

// Pressure is clamped and linearly mapped to the configured radius range.
float radiusForPressure(float pressure, const BrushSettings& settings = {});
float spacingForPressure(float pressure, const BrushSettings& settings = {});

BrushFootprint makeFootprint(const PencilSample& sample,
                             const BrushSettings& settings = {});
BrushFootprint makeFootprint(Vec2 center, float pressure,
                             float altitude, float azimuth, float roll,
                             const BrushSettings& settings = {});

class DabEmitter {
public:
    struct Snapshot {
        bool active = false;
        Vec2 lastPosition{};
        float lastPressure = 0.0f;
        float lastAltitude = 0.0f;
        float lastAzimuth = 0.0f;
        float lastRoll = 0.0f;
        float distanceToNextDab = 0.0f;
        StrokeBounds bounds{};
    };

    using Sink = std::function<void(const Dab&)>;

    explicit DabEmitter(BrushSettings settings = {}, Sink sink = {});

    void reset();
    void setSettings(BrushSettings settings);
    const BrushSettings& settings() const { return settings_; }
    void setSink(Sink sink) { sink_ = std::move(sink); }

    void setClipBounds(const StrokeBounds& bounds) { clipBounds_ = bounds; }
    void clearClipBounds() { clipBounds_.reset(); }
    const std::optional<StrokeBounds>& clipBounds() const { return clipBounds_; }

    void extend(const PencilSample& sample, bool predicted = false);
    void extend(Vec2 position, float pressure, float altitude = 0.0f,
                float azimuth = 0.0f, float roll = 0.0f,
                bool predicted = false);

    Snapshot snapshot() const;
    void restore(const Snapshot& snapshot);
    bool active() const { return active_; }
    const StrokeBounds& bounds() const { return bounds_; }

private:
    void emit(const PencilSample& sample, bool predicted);
    BrushSettings settings_{};
    Sink sink_{};
    bool active_ = false;
    Vec2 lastPosition_{};
    float lastPressure_ = 0.0f;
    float lastAltitude_ = 0.0f;
    float lastAzimuth_ = 0.0f;
    float lastRoll_ = 0.0f;
    float distanceToNextDab_ = 0.0f;
    std::optional<StrokeBounds> clipBounds_{};
    StrokeBounds bounds_{};
};

// Owns the replaceable predicted tail.  Each batch restores the emitter to
// the state after the previous real samples, then appends the new real path
// and snapshots it before appending prediction.  Consequently predictions
// affect only the live tail and never bend real-sample interpolation.
class BrushEmitter {
public:
    using Sink = DabEmitter::Sink;
    using PredictionResetSink = std::function<void()>;

    explicit BrushEmitter(BrushSettings settings = {}, Sink sink = {},
                          PredictionResetSink predictionResetSink = {});

    void reset();
    void setSettings(BrushSettings settings);
    const BrushSettings& settings() const { return emitter_.settings(); }
    void setSink(Sink sink);
    void setPredictionResetSink(PredictionResetSink sink) {
        predictionResetSink_ = std::move(sink);
    }

    void append(std::span<const PencilSample> real,
                std::span<const PencilSample> predicted = {});
    void appendReal(std::span<const PencilSample> real);
    void appendPredicted(std::span<const PencilSample> predicted);

    bool hasRealSnapshot() const { return hasRealSnapshot_; }
    const StrokeBounds& bounds() const { return emitter_.bounds(); }
    const DabEmitter& emitter() const { return emitter_; }
    DabEmitter& emitter() { return emitter_; }

private:
    DabEmitter emitter_{};
    DabEmitter::Snapshot realSnapshot_{};
    bool hasRealSnapshot_ = false;
    bool predictionEmitted_ = false;
    PredictionResetSink predictionResetSink_{};
};

std::vector<TileAddress> touchedTiles(const StrokeBounds& bounds,
                                      std::int32_t tileSize = kDefaultTileSize);
std::vector<TileAddress> touchedTiles(std::span<const Dab> dabs,
                                      std::int32_t tileSize = kDefaultTileSize);

inline std::vector<TileAddress> enumerateTouchedTiles(
    const StrokeBounds& bounds, std::int32_t tileSize = kDefaultTileSize) {
    return touchedTiles(bounds, tileSize);
}

} // namespace drafting_table::renderer
