#include "BrushEmitter.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace drafting_table::renderer {
namespace {

constexpr float kPi = 3.14159265358979323846f;

float finiteOr(float value, float fallback) {
    return std::isfinite(value) ? value : fallback;
}

BrushSettings sanitize(BrushSettings value) {
    value.minRadius = std::max(0.0f, finiteOr(value.minRadius, 0.0f));
    value.maxRadius = std::max(value.minRadius,
                               finiteOr(value.maxRadius, 18.0f));
    value.sizeScale = std::max(0.0f, finiteOr(value.sizeScale, 1.0f));
    value.spacingFraction = std::max(0.0f,
                                     finiteOr(value.spacingFraction, 0.18f));
    value.minimumSpacing = std::max(1.0e-4f,
                                    finiteOr(value.minimumSpacing, 0.5f));
    value.minimumDabRadius = std::max(0.0f,
                                      finiteOr(value.minimumDabRadius, 0.05f));
    value.pencilAspect = std::max(1.0f, finiteOr(value.pencilAspect, 1.0f));
    value.markerAspect = std::max(1.0f, finiteOr(value.markerAspect, 1.35f));
    return value;
}

float clamp01(float value) {
    if (!std::isfinite(value)) return 0.0f;
    return std::clamp(value, 0.0f, 1.0f);
}

float interpolateAngle(float from, float to, float t) {
    const float delta = std::remainder(to - from, 2.0f * kPi);
    return from + delta * t;
}

float tiltAspect(float altitude, float nibAspect) {
    // altitudeAngle is measured from the screen plane.  Keep the eccentricity
    // bounded at a perfectly flat/invalid sample (sin(angle) -> 0).
    altitude = finiteOr(altitude, kPi * 0.5f);
    const float sine = std::clamp(std::sin(std::clamp(altitude, 0.0f,
                                                       kPi * 0.5f)),
                                  0.2f, 1.0f);
    return std::clamp(nibAspect / sine, 1.0f, 8.0f);
}

} // namespace

bool BrushFootprint::valid() const {
    return std::isfinite(center.x) && std::isfinite(center.y) &&
           std::isfinite(radiusX) && std::isfinite(radiusY) &&
           radiusX >= 0.0f && radiusY >= 0.0f;
}

float Dab::radius() const {
    return std::max(footprint.radiusX, footprint.radiusY);
}

void StrokeBounds::reset() {
    min = {};
    max = {};
    valid = false;
}

void StrokeBounds::include(Vec2 point) {
    if (!std::isfinite(point.x) || !std::isfinite(point.y)) return;
    if (!valid) {
        min = max = point;
        valid = true;
        return;
    }
    min.x = std::min(min.x, point.x);
    min.y = std::min(min.y, point.y);
    max.x = std::max(max.x, point.x);
    max.y = std::max(max.y, point.y);
}

void StrokeBounds::include(const BrushFootprint& footprint) {
    if (!footprint.valid()) return;
    const float c = std::cos(footprint.rotationRadians);
    const float s = std::sin(footprint.rotationRadians);
    const float ex = std::sqrt((footprint.radiusX * c) *
                                   (footprint.radiusX * c) +
                               (footprint.radiusY * s) *
                                   (footprint.radiusY * s));
    const float ey = std::sqrt((footprint.radiusX * s) *
                                   (footprint.radiusX * s) +
                               (footprint.radiusY * c) *
                                   (footprint.radiusY * c));
    include({footprint.center.x - ex, footprint.center.y - ey});
    include({footprint.center.x + ex, footprint.center.y + ey});
}

bool StrokeBounds::intersects(Vec2 point) const {
    return valid && point.x >= min.x && point.x <= max.x &&
           point.y >= min.y && point.y <= max.y;
}

float radiusForPressure(float pressure, const BrushSettings& rawSettings) {
    const auto settings = sanitize(rawSettings);
    const float p = clamp01(pressure);
    return (settings.minRadius +
            p * (settings.maxRadius - settings.minRadius)) * settings.sizeScale;
}

float spacingForPressure(float pressure, const BrushSettings& rawSettings) {
    const auto settings = sanitize(rawSettings);
    return std::max(settings.spacingFraction * radiusForPressure(pressure, settings),
                    settings.minimumSpacing);
}

BrushFootprint makeFootprint(const PencilSample& sample,
                             const BrushSettings& settings) {
    return makeFootprint(sample.position(), sample.pressure, sample.altitude,
                         sample.azimuth, sample.roll, settings);
}

BrushFootprint makeFootprint(Vec2 center, float pressure, float altitude,
                             float azimuth, float roll,
                             const BrushSettings& rawSettings) {
    const auto settings = sanitize(rawSettings);
    const float radius = radiusForPressure(pressure, settings);
    BrushFootprint result;
    result.center = center;
    result.pressure = clamp01(pressure);
    result.shape = settings.shape;
    result.radiusX = result.radiusY = radius;
    result.rotationRadians = 0.0f;
    if (settings.shape != BrushShape::Round) {
        const float nibAspect = settings.shape == BrushShape::Pencil
                                    ? settings.pencilAspect
                                    : settings.markerAspect;
        const float aspect = tiltAspect(altitude, nibAspect);
        result.radiusX = radius * aspect;
        result.radiusY = radius;
        // Azimuth points along the pen's major axis. Roll rotates a Pencil
        // Pro nib around that axis; including both keeps the footprint stable
        // for ordinary Pencil samples (roll is generally zero).
        result.rotationRadians = finiteOr(azimuth, 0.0f) +
                                 finiteOr(roll, 0.0f);
    }
    return result;
}

DabEmitter::DabEmitter(BrushSettings settings, Sink sink)
    : settings_(sanitize(settings)), sink_(std::move(sink)) {
    reset();
}

void DabEmitter::reset() {
    active_ = false;
    lastPosition_ = {};
    lastPressure_ = 0.0f;
    lastAltitude_ = 0.0f;
    lastAzimuth_ = 0.0f;
    lastRoll_ = 0.0f;
    distanceToNextDab_ = 0.0f;
    clipBounds_.reset();
    bounds_.reset();
}

void DabEmitter::setSettings(BrushSettings settings) {
    settings_ = sanitize(settings);
    reset();
}

void DabEmitter::emit(const PencilSample& sample, bool predicted) {
    const auto footprint = makeFootprint(sample, settings_);
    if (!footprint.valid() || footprint.radiusX < settings_.minimumDabRadius &&
        footprint.radiusY < settings_.minimumDabRadius) {
        return;
    }
    Dab dab{footprint, predicted};
    if (clipBounds_.has_value()) {
        StrokeBounds dabBounds;
        dabBounds.include(dab);
        if (!dabBounds.valid || dabBounds.max.x < clipBounds_->min.x ||
            dabBounds.min.x > clipBounds_->max.x ||
            dabBounds.max.y < clipBounds_->min.y ||
            dabBounds.min.y > clipBounds_->max.y) {
            return;
        }
    }
    bounds_.include(dab);
    if (sink_) sink_(dab);
}

void DabEmitter::extend(const PencilSample& sample, bool predicted) {
    extend(sample.position(), sample.pressure, sample.altitude, sample.azimuth,
           sample.roll, predicted);
}

void DabEmitter::extend(Vec2 position, float pressure, float altitude,
                        float azimuth, float roll, bool predicted) {
    if (!std::isfinite(position.x) || !std::isfinite(position.y)) return;
    PencilSample sample;
    sample.x = position.x;
    sample.y = position.y;
    sample.pressure = pressure;
    sample.altitude = altitude;
    sample.azimuth = azimuth;
    sample.roll = roll;
    const float p = clamp01(pressure);
    if (!active_) {
        emit(sample, predicted);
        active_ = true;
        lastPosition_ = position;
        lastPressure_ = p;
        lastAltitude_ = finiteOr(altitude, kPi * 0.5f);
        lastAzimuth_ = finiteOr(azimuth, 0.0f);
        lastRoll_ = finiteOr(roll, 0.0f);
        distanceToNextDab_ = spacingForPressure(p, settings_);
        return;
    }
    const Vec2 delta = position - lastPosition_;
    const float distance = delta.length();
    if (!std::isfinite(distance) || distance < 1.0e-4f) return;
    const Vec2 direction = delta / distance;
    float travelled = 0.0f;
    while (travelled + distanceToNextDab_ <= distance) {
        travelled += distanceToNextDab_;
        const float t = travelled / distance;
        PencilSample dabSample = sample;
        dabSample.x = lastPosition_.x + direction.x * travelled;
        dabSample.y = lastPosition_.y + direction.y * travelled;
        dabSample.pressure = lastPressure_ + (p - lastPressure_) * t;
        dabSample.altitude = lastAltitude_ +
            (finiteOr(altitude, lastAltitude_) - lastAltitude_) * t;
        dabSample.azimuth = interpolateAngle(lastAzimuth_,
                                             finiteOr(azimuth, lastAzimuth_), t);
        dabSample.roll = interpolateAngle(lastRoll_,
                                          finiteOr(roll, lastRoll_), t);
        emit(dabSample, predicted);
        distanceToNextDab_ = spacingForPressure(dabSample.pressure, settings_);
    }
    distanceToNextDab_ -= (distance - travelled);
    lastPosition_ = position;
    lastPressure_ = p;
    lastAltitude_ = finiteOr(altitude, lastAltitude_);
    lastAzimuth_ = finiteOr(azimuth, lastAzimuth_);
    lastRoll_ = finiteOr(roll, lastRoll_);
}

DabEmitter::Snapshot DabEmitter::snapshot() const {
    return {active_, lastPosition_, lastPressure_, lastAltitude_, lastAzimuth_,
            lastRoll_, distanceToNextDab_, bounds_};
}

void DabEmitter::restore(const Snapshot& snapshot) {
    active_ = snapshot.active;
    lastPosition_ = snapshot.lastPosition;
    lastPressure_ = snapshot.lastPressure;
    lastAltitude_ = snapshot.lastAltitude;
    lastAzimuth_ = snapshot.lastAzimuth;
    lastRoll_ = snapshot.lastRoll;
    distanceToNextDab_ = snapshot.distanceToNextDab;
    bounds_ = snapshot.bounds;
}

BrushEmitter::BrushEmitter(BrushSettings settings, Sink sink,
                           PredictionResetSink predictionResetSink)
    : emitter_(settings, std::move(sink)),
      predictionResetSink_(std::move(predictionResetSink)) {}

void BrushEmitter::reset() {
    emitter_.reset();
    realSnapshot_ = {};
    hasRealSnapshot_ = false;
    predictionEmitted_ = false;
}

void BrushEmitter::setSettings(BrushSettings settings) {
    emitter_.setSettings(settings);
    realSnapshot_ = {};
    hasRealSnapshot_ = false;
    predictionEmitted_ = false;
}

void BrushEmitter::setSink(Sink sink) { emitter_.setSink(std::move(sink)); }

void BrushEmitter::appendReal(std::span<const PencilSample> real) {
    if (hasRealSnapshot_) {
        if (predictionEmitted_ && predictionResetSink_) predictionResetSink_();
        emitter_.restore(realSnapshot_);
    }
    predictionEmitted_ = false;
    for (const auto& sample : real) emitter_.extend(sample, false);
    realSnapshot_ = emitter_.snapshot();
    hasRealSnapshot_ = true;
}

void BrushEmitter::appendPredicted(std::span<const PencilSample> predicted) {
    for (const auto& sample : predicted) emitter_.extend(sample, true);
    predictionEmitted_ = !predicted.empty();
}

void BrushEmitter::append(std::span<const PencilSample> real,
                          std::span<const PencilSample> predicted) {
    appendReal(real);
    appendPredicted(predicted);
}

std::vector<TileAddress> touchedTiles(const StrokeBounds& bounds,
                                      std::int32_t tileSize) {
    std::vector<TileAddress> result;
    if (!bounds.valid || tileSize <= 0) return result;
    const auto tx0 = static_cast<std::int32_t>(std::floor(bounds.min.x / tileSize));
    const auto ty0 = static_cast<std::int32_t>(std::floor(bounds.min.y / tileSize));
    const auto tx1 = static_cast<std::int32_t>(std::floor(bounds.max.x / tileSize));
    const auto ty1 = static_cast<std::int32_t>(std::floor(bounds.max.y / tileSize));
    for (std::int32_t ty = ty0; ty <= ty1; ++ty)
        for (std::int32_t tx = tx0; tx <= tx1; ++tx)
            result.push_back({tx, ty});
    return result;
}

std::vector<TileAddress> touchedTiles(std::span<const Dab> dabs,
                                      std::int32_t tileSize) {
    StrokeBounds bounds;
    for (const auto& dab : dabs) bounds.include(dab);
    return touchedTiles(bounds, tileSize);
}

} // namespace drafting_table::renderer
