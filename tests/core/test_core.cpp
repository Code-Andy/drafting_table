#include "DTCore.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <span>

namespace {
int failures = 0;

void check(bool condition, const char* expression, int line) {
    if (!condition) {
        std::cerr << "FAIL line " << line << ": " << expression << '\n';
        ++failures;
    }
}

#define CHECK(...) check((__VA_ARGS__), #__VA_ARGS__, __LINE__)

void testPressure() {
    dt::PressureMapper mapper({0.1f, 0.9f, 2.0f});
    CHECK(mapper(-1.0f) == 0.0f);
    CHECK(mapper(0.1f) == 0.0f);
    CHECK(std::fabs(mapper(0.5f) - 0.25f) < 1.0e-5f);
    CHECK(mapper(0.9f) == 1.0f);
    CHECK(mapper(2.0f) == 1.0f);
    CHECK(mapper(std::numeric_limits<float>::quiet_NaN()) == 0.0f);
}

void testTiles() {
    CHECK(dt::TileAddress::fromDocument({0.0f, 0.0f}) == dt::TileAddress{0, 0});
    CHECK(dt::TileAddress::fromDocument({255.99f, 0.0f}) == dt::TileAddress{0, 0});
    CHECK(dt::TileAddress::fromDocument({256.0f, 0.0f}) == dt::TileAddress{1, 0});
    CHECK(dt::TileAddress::fromDocument({-0.001f, -256.0f}) == dt::TileAddress{-1, -1});
    const auto tile = dt::TileAddress{-42, 17};
    CHECK(dt::TileAddress::fromKey(tile.key()) == tile);
    CHECK(dt::tileAddressFromKey(dt::tileKey(-1, -2)) == dt::TileAddress{-1, -2});
    CHECK(std::fabs(tile.localPoint({-10751.5f, 4353.25f}).x - 0.5f) < 1.0e-5f);
}

void testTransform() {
    constexpr float halfPi = 1.5707963267948966f;
    const dt::CanvasTransform transform{2.0f, halfPi, {10.0f, -4.0f}};
    const dt::Vec2 point{3.0f, 2.0f};
    const dt::Vec2 view = transform.documentToView(point);
    CHECK(dt::nearlyEqual(view, {6.0f, 2.0f}, 1.0e-5f));
    CHECK(dt::nearlyEqual(transform.viewToDocument(view), point, 1.0e-5f));
    CHECK(dt::nearlyEqual(transform.inverse().documentToView(view), point, 1.0e-5f));
}

void testStrokeLifecycle() {
    dt::DrawingEngine engine;
    dt::PencilSample real{1, 2, .5f};
    real.id = 11;
    real.estimationUpdateIndex = 101;
    real.flags = dt::PRESSURE_ESTIMATED;
    dt::PencilSample predicted{3, 4, .7f};
    predicted.id = 12;
    engine.beginStroke();
    engine.appendSamples(std::span<const dt::PencilSample>(&real, 1),
                         std::span<const dt::PencilSample>(&predicted, 1));
    CHECK(engine.strokeActive());
    CHECK(engine.realSamples().size() == 1);
    CHECK(engine.predictedSamples().size() == 1);
    CHECK(engine.realSamples()[0].isReal());
    CHECK(engine.predictedSamples()[0].isPredicted());

    dt::PencilSample corrected = real;
    corrected.pressure = .9f;
    corrected.flags = dt::SampleFlags::None;
    CHECK(engine.updateEstimatedSampleByIndex(101, corrected));
    CHECK(std::fabs(engine.realSamples()[0].pressure - .9f) < 1.0e-6f);
    CHECK(engine.realSamples()[0].isReal());

    // A real event replaces the temporary prediction tail.
    dt::PencilSample next{5, 6, .4f};
    next.id = 13;
    engine.appendSamples(std::span<const dt::PencilSample>(&next, 1));
    CHECK(engine.predictedSamples().empty());
    CHECK(engine.realSamples().size() == 2);
    engine.endStroke();
    CHECK(!engine.strokeActive());
    CHECK(engine.realSamples().empty());
    CHECK(engine.committedSamples().size() == 2);
    engine.cancelStroke();
    CHECK(engine.committedSamples().size() == 2);
}
} // namespace

int main() {
    testPressure();
    testTiles();
    testTransform();
    testStrokeLifecycle();
    if (failures != 0) {
        std::cerr << failures << " test assertion(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all core tests passed\n";
    return EXIT_SUCCESS;
}
