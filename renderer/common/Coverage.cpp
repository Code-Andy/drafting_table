#include "Coverage.hpp"

#include <algorithm>
#include <cmath>

namespace drafting_table::renderer {
namespace {
float clamp01(float value) {
    if (!std::isfinite(value)) return 0.0f;
    return std::clamp(value, 0.0f, 1.0f);
}
}

float radialCoverage(float normalizedDistance, float hardness) {
    const float r = normalizedDistance;
    if (!std::isfinite(r) || r >= 1.0f) return 0.0f;
    const float h = clamp01(hardness);
    if (r <= h || h >= 1.0f) return 1.0f;
    const float t = (1.0f - r) / (1.0f - h);
    const float t2 = t * t;
    return clamp01(t2 * t2);
}

float dabCoverage(const Dab& dab, Vec2 point, float hardness, float alpha) {
    const auto& f = dab.footprint;
    if (!f.valid() || f.radiusX <= 0.0f || f.radiusY <= 0.0f) return 0.0f;
    const Vec2 delta = point - f.center;
    const float c = std::cos(f.rotationRadians);
    const float s = std::sin(f.rotationRadians);
    const float localX = c * delta.x + s * delta.y;
    const float localY = -s * delta.x + c * delta.y;
    const float normalized = std::sqrt((localX / f.radiusX) *
                                           (localX / f.radiusX) +
                                       (localY / f.radiusY) *
                                           (localY / f.radiusY));
    return clamp01(alpha) * radialCoverage(normalized, hardness);
}

float maxCoverage(float current, float contribution) {
    return std::max(clamp01(current), clamp01(contribution));
}

float uniformAlphaCoverage(std::span<const Dab> dabs, Vec2 point,
                           float hardness, float alpha) {
    float coverage = 0.0f;
    for (const auto& dab : dabs)
        coverage = maxCoverage(coverage, dabCoverage(dab, point, hardness, alpha));
    return coverage;
}

} // namespace drafting_table::renderer
