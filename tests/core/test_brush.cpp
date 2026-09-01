#include "BrushEmitter.hpp"
#include "Coverage.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <span>
#include <vector>

namespace {
int failures = 0;
void check(bool condition, const char* expression, int line) {
    if (!condition) {
        std::cerr << "FAIL line " << line << ": " << expression << '\n';
        ++failures;
    }
}
#define CHECK(...) check((__VA_ARGS__), #__VA_ARGS__, __LINE__)

void testSpacingAndPressure() {
    using namespace drafting_table::renderer;
    BrushSettings settings;
    settings.minRadius = 0.0f;
    settings.maxRadius = 18.0f;
    std::vector<Dab> dabs;
    DabEmitter emitter(settings, [&](const Dab& dab) { dabs.push_back(dab); });
    emitter.extend({0, 0, 0.25f}, false);
    emitter.extend({20, 0, 1.0f}, false);
    CHECK(dabs.size() > 2);
    CHECK(std::fabs(dabs.front().footprint.pressure - 0.25f) < 1e-5f);
    CHECK(dabs.back().footprint.pressure <= 1.0f);
    const float spacing = dabs[1].center().x - dabs[0].center().x;
    CHECK(spacing > 0.0f && spacing < 4.0f); // approximately .18 * radius
}

void testPredictionRestore() {
    using namespace drafting_table::renderer;
    std::vector<Dab> first, second;
    int predictionResets = 0;
    BrushEmitter emitter({}, [&](const Dab& dab) { first.push_back(dab); },
                         [&] { ++predictionResets; });
    dt::PencilSample start{0, 0, 1};
    dt::PencilSample real{10, 0, 1};
    dt::PencilSample prediction{30, 0, 1};
    emitter.append(std::span<const dt::PencilSample>(&start, 1));
    emitter.append(std::span<const dt::PencilSample>(&real, 1),
                   std::span<const dt::PencilSample>(&prediction, 1));
    emitter.setSink([&](const Dab& dab) { second.push_back(dab); });
    dt::PencilSample nextReal{20, 0, 1};
    emitter.append(std::span<const dt::PencilSample>(&nextReal, 1));
    CHECK(!first.empty() && !second.empty());
    CHECK(second.front().center().x < 25.0f);
    CHECK(!second.front().predicted);
    CHECK(predictionResets == 1);
}

void testFootprintsBoundsTiles() {
    using namespace drafting_table::renderer;
    BrushSettings pencil;
    pencil.shape = BrushShape::Pencil;
    const auto round = makeFootprint({-1, -1}, 0.7f, 1.5707963f, 0, 0, {});
    const auto tilted = makeFootprint({-1, -1}, 0.7f, 0.3f, 0.5f, 0.2f, pencil);
    CHECK(tilted.radiusX > tilted.radiusY);
    CHECK(tilted.rotationRadians > 0.6f);
    StrokeBounds bounds;
    bounds.include(round);
    bounds.include(tilted);
    const auto tiles = touchedTiles(bounds, 256);
    CHECK(!tiles.empty());
    CHECK(tiles.front().x <= 0 && tiles.front().y <= 0);
}

void testUniformCoverage() {
    using namespace drafting_table::renderer;
    Dab dab;
    dab.footprint = makeFootprint({0, 0}, 1.0f, 1.5707963f, 0, 0, {});
    Dab overlap = dab;
    overlap.footprint.center.x = 1.0f;
    const Dab dabs[] = {dab, overlap};
    const float c = uniformAlphaCoverage(dabs, {0, 0}, 0.0f, 0.5f);
    CHECK(std::fabs(c - 0.5f) < 1e-5f);
    CHECK(std::fabs(radialCoverage(0.5f, 1.0f) - 1.0f) < 1e-5f);
    CHECK(radialCoverage(1.0f, 0.0f) == 0.0f);
}

void testInvalidSamplesDoNotPoisonEmitter() {
    using namespace drafting_table::renderer;
    std::vector<Dab> dabs;
    DabEmitter emitter({}, [&](const Dab& dab) { dabs.push_back(dab); });
    emitter.extend({std::numeric_limits<float>::quiet_NaN(), 0}, 1.0f);
    CHECK(!emitter.active());
    emitter.extend({0, 0}, 1.0f);
    CHECK(emitter.active() && dabs.size() == 1);
}
} // namespace

int main() {
    testSpacingAndPressure();
    testPredictionRestore();
    testFootprintsBoundsTiles();
    testUniformCoverage();
    testInvalidSamplesDoNotPoisonEmitter();
    if (failures != 0) return EXIT_FAILURE;
    std::cout << "all brush tests passed\n";
    return EXIT_SUCCESS;
}
