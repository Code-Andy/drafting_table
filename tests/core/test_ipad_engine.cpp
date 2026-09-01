#include "DTEngine.hpp"

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
}

int main() {
    dt::Engine engine;
    const auto initialRevision = engine.revision();
    dt::PencilSample sample{10.0f, 20.0f, 0.5f};

    engine.beginStroke();
    engine.appendSamples(std::span<const dt::PencilSample>(&sample, 1), {});
    engine.endStroke();
    CHECK(engine.strokeCount() == 1);
    CHECK(engine.sampleCount() == 1);
    CHECK(engine.revision() > initialRevision);

    CHECK(engine.undoLastStroke());
    CHECK(engine.strokeCount() == 0);
    CHECK(!engine.undoLastStroke());

    engine.beginStroke();
    engine.appendSamples(std::span<const dt::PencilSample>(&sample, 1), {});
    CHECK(engine.strokeCount() == 1);
    CHECK(engine.undoLastStroke());
    CHECK(engine.strokeCount() == 0);

    if (failures != 0) return EXIT_FAILURE;
    std::cout << "all iPad engine tests passed\n";
    return EXIT_SUCCESS;
}
