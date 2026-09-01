#pragma once

#include "BrushEmitter.hpp"

#include <span>

namespace drafting_table::renderer {

// The same quartic edge falloff as the upstream dab shader. hardness=1 is a
// hard disc; hardness=0 is a full gradient. Inputs and output are clamped.
float radialCoverage(float normalizedDistance, float hardness);
float dabCoverage(const Dab& dab, Vec2 point, float hardness = 1.0f,
                  float alpha = 1.0f);

// Uniform-alpha mode combines overlapping dab contributions with MAX rather
// than OVER, avoiding darker intersections inside one stroke.
float maxCoverage(float current, float contribution);
float uniformAlphaCoverage(std::span<const Dab> dabs, Vec2 point,
                           float hardness = 1.0f, float alpha = 1.0f);

} // namespace drafting_table::renderer
