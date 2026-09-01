#include "DTMetalTileRenderer.hpp"

#include <cstdlib>
#include <iostream>

int main() {
    using namespace drafting_table::metal;
    static_assert(kTileTextureExtent == 258);
    static_assert(sizeof(DabInstance) == 48);

    const auto address = TileLayout::addressFor({-0.25f, 256.0f});
    if (address != dt::TileAddress{-1, 1}) {
        std::cerr << "Metal tile addressing mismatch\n";
        return EXIT_FAILURE;
    }

    const DabInstance dab({10.0f, 20.0f}, {4.0f, 2.0f}, 0.5f, 0.8f,
                          0.7f, {0.4f, 0.2f, 0.1f, 0.5f});
    if (dab.radii.x != 4.0f || dab.radii.y != 2.0f ||
        dab.rotationRadians != 0.5f) {
        std::cerr << "Metal dab layout mismatch\n";
        return EXIT_FAILURE;
    }

    std::cout << "all Metal layout tests passed\n";
    return EXIT_SUCCESS;
}
