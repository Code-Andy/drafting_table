#include "DTCore.hpp"

#include <cassert>

namespace drafting_table {

PressureCurve PressureMapper::sanitize(PressureCurve curve) {
    if (!std::isfinite(curve.deadZone)) curve.deadZone = 0.0f;
    if (!std::isfinite(curve.saturation)) curve.saturation = 1.0f;
    if (!std::isfinite(curve.gamma) || curve.gamma <= 0.0f) curve.gamma = 1.0f;
    curve.deadZone = std::clamp(curve.deadZone, 0.0f, 1.0f);
    curve.saturation = std::clamp(curve.saturation, 0.0f, 1.0f);
    // A zero-width range has no useful normalization.  Treat saturation as
    // one in this invalid configuration rather than dividing by zero.
    if (curve.saturation <= curve.deadZone) {
        curve.saturation = std::min(1.0f, curve.deadZone + 1.0e-6f);
        if (curve.saturation <= curve.deadZone) curve.deadZone = 0.0f;
    }
    return curve;
}

float PressureMapper::map(float rawPressure) const {
    if (!std::isfinite(rawPressure)) return 0.0f;
    const float normalized = std::clamp(
        (rawPressure - curve_.deadZone) /
            (curve_.saturation - curve_.deadZone),
        0.0f, 1.0f);
    return std::clamp(std::pow(normalized, curve_.gamma), 0.0f, 1.0f);
}

TileAddress TileAddress::fromDocument(Vec2 documentPoint,
                                      std::int32_t tileSize) {
    if (tileSize <= 0) tileSize = kDefaultTileSize;
    // floor (rather than truncation) is essential for points left/above the
    // origin: [-256, 0) belongs to tile -1, not tile 0.
    return {static_cast<std::int32_t>(std::floor(documentPoint.x / tileSize)),
            static_cast<std::int32_t>(std::floor(documentPoint.y / tileSize))};
}

Vec2 TileAddress::localPoint(Vec2 documentPoint, std::int32_t tileSize) const {
    if (tileSize <= 0) tileSize = kDefaultTileSize;
    const Vec2 local = documentPoint - origin(tileSize);
    // Floating point input can be a tiny epsilon below a tile boundary.  Do
    // not clamp: local coordinates are useful for diagnosing transform and
    // addressing errors, and the canonical tile is determined by floor().
    return local;
}

Vec2 CanvasTransform::documentToView(Vec2 documentPoint) const {
    const float c = std::cos(rotationRadians);
    const float s = std::sin(rotationRadians);
    const Vec2 rotated{c * documentPoint.x - s * documentPoint.y,
                       s * documentPoint.x + c * documentPoint.y};
    return rotated * scale + translation;
}

Vec2 CanvasTransform::viewToDocument(Vec2 viewPoint) const {
    if (!std::isfinite(scale) || std::fabs(scale) <= 1.0e-8f) {
        return {std::numeric_limits<float>::quiet_NaN(),
                std::numeric_limits<float>::quiet_NaN()};
    }
    const Vec2 unscaled = (viewPoint - translation) / scale;
    const float c = std::cos(rotationRadians);
    const float s = std::sin(rotationRadians);
    return {c * unscaled.x + s * unscaled.y,
            -s * unscaled.x + c * unscaled.y};
}

CanvasTransform CanvasTransform::inverse() const {
    CanvasTransform result;
    if (!std::isfinite(scale) || std::fabs(scale) <= 1.0e-8f) {
        result.scale = 0.0f;
        result.rotationRadians = -rotationRadians;
        result.translation = {};
        return result;
    }
    result.scale = 1.0f / scale;
    result.rotationRadians = -rotationRadians;
    // Inverse's translation is represented in the same scale/rotation form:
    // p' = R(-r) * (p - t) / s.
    const Vec2 shifted = -translation;
    result.translation = {std::cos(rotationRadians) * shifted.x +
                              std::sin(rotationRadians) * shifted.y,
                          -std::sin(rotationRadians) * shifted.x +
                              std::cos(rotationRadians) * shifted.y};
    result.translation *= 1.0f / scale;
    return result;
}

std::array<float, 9> CanvasTransform::matrix() const {
    const float c = std::cos(rotationRadians) * scale;
    const float s = std::sin(rotationRadians) * scale;
    return {c, -s, translation.x,
            s,  c, translation.y,
            0.0f, 0.0f, 1.0f};
}

void DrawingEngine::beginStroke(const StrokeConfig& config) {
    config_ = config;
    strokeActive_ = true;
    realSamples_.clear();
    predictedSamples_.clear();
    estimationToSample_.clear();
}

void DrawingEngine::indexSample(const PencilSample& sample) {
    if (sample.estimationUpdateIndex != 0 && sample.id != 0) {
        estimationToSample_[sample.estimationUpdateIndex] = sample.id;
    }
    if (sample.estimationId != 0 && sample.id != 0) {
        estimationToSample_[sample.estimationId] = sample.id;
    }
}

void DrawingEngine::appendSamples(std::span<const PencilSample> real,
                                  std::span<const PencilSample> predicted) {
    if (!strokeActive_) beginStroke();

    // UIKit predictions are a replaceable tail.  They must never survive
    // once their corresponding real event arrives or become committed data.
    for (const auto& sample : predictedSamples_) {
        if (sample.estimationUpdateIndex != 0) {
            estimationToSample_.erase(sample.estimationUpdateIndex);
        }
        if (sample.estimationId != 0) {
            estimationToSample_.erase(sample.estimationId);
        }
    }
    predictedSamples_.clear();
    for (const auto& input : real) {
        PencilSample sample = input;
        sample.flags |= SampleFlags::Real;
        sample.flags = static_cast<SampleFlags>(
            static_cast<std::uint32_t>(sample.flags) &
            ~static_cast<std::uint32_t>(SampleFlags::Predicted));
        realSamples_.push_back(sample);
        indexSample(sample);
    }
    for (const auto& input : predicted) {
        PencilSample sample = input;
        sample.flags |= SampleFlags::Predicted;
        sample.flags = static_cast<SampleFlags>(
            static_cast<std::uint32_t>(sample.flags) &
            ~static_cast<std::uint32_t>(SampleFlags::Real));
        predictedSamples_.push_back(sample);
        indexSample(sample);
    }
}

bool DrawingEngine::replaceIn(std::vector<PencilSample>& samples,
                              std::uint64_t sampleId,
                              const PencilSample& replacement) {
    for (auto& sample : samples) {
        if (sample.id != sampleId) continue;
        const auto lifecycle = sample.flags &
            (SampleFlags::Real | SampleFlags::Predicted | SampleFlags::Coalesced);
        sample = replacement;
        sample.id = sampleId;
        sample.flags = static_cast<SampleFlags>(
            (static_cast<std::uint32_t>(sample.flags) &
             ~static_cast<std::uint32_t>(SampleFlags::Real | SampleFlags::Predicted |
                                         SampleFlags::Coalesced)) |
            static_cast<std::uint32_t>(lifecycle));
        indexSample(sample);
        return true;
    }
    return false;
}

bool DrawingEngine::updateEstimatedSample(std::uint64_t sampleId,
                                          const PencilSample& replacement) {
    if (!strokeActive_ || sampleId == 0) return false;
    if (replaceIn(realSamples_, sampleId, replacement) ||
        replaceIn(predictedSamples_, sampleId, replacement)) {
        return true;
    }
    // UIKit callers sometimes pass estimationUpdateIndex as the lookup key
    // rather than the app-assigned sample ID.  Accept both forms.
    const auto it = estimationToSample_.find(sampleId);
    return it != estimationToSample_.end() &&
           (replaceIn(realSamples_, it->second, replacement) ||
            replaceIn(predictedSamples_, it->second, replacement));
}

bool DrawingEngine::updateEstimatedSampleByIndex(
    std::uint64_t estimationUpdateIndex, const PencilSample& replacement) {
    if (!strokeActive_ || estimationUpdateIndex == 0) return false;
    const auto it = estimationToSample_.find(estimationUpdateIndex);
    return it != estimationToSample_.end() &&
           updateEstimatedSample(it->second, replacement);
}

void DrawingEngine::endStroke() {
    if (!strokeActive_) return;
    committedSamples_.insert(committedSamples_.end(),
                             realSamples_.begin(), realSamples_.end());
    realSamples_.clear();
    predictedSamples_.clear();
    estimationToSample_.clear();
    strokeActive_ = false;
}

void DrawingEngine::cancelStroke() {
    realSamples_.clear();
    predictedSamples_.clear();
    estimationToSample_.clear();
    strokeActive_ = false;
}

} // namespace drafting_table
