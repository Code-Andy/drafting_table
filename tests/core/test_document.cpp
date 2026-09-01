#include "DTDocument.hpp"
#include "DTPersistence.hpp"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <span>
#include <vector>

namespace {
int failures = 0;
#define CHECK(e) do { if (!(e)) { std::cerr << "FAIL line " << __LINE__ << ": " << #e << '\n'; ++failures; } } while (false)

void testModel() {
    dt::Document d("sketch");
    CHECK(d.pageCount() == 1);
    auto* p = d.activePage();
    CHECK(p && p->layerCount() == 1);
    p->setBounds({-10, -20, 640, 480});
    const auto vi = p->addLayer(dt::LayerType::Vector, "Construction");
    CHECK(vi == 1 && p->activeLayerIndex() == 1);
    auto* v = p->activeLayer();
    v->setOpacity(2.0f); CHECK(v->opacity() == 1.0f);
    v->setVisible(false);
    v->addLine({1,2,3,4,0xff00ff,2});
    v->addRect({0,0,10,20,.25f,0xabcdef,1});
    v->addEllipse({5,6,3,2,.5f,0x123456,1});
    v->addCircle({7,8,4,0xffffff,1});
    CHECK(v->lines().size() == 1 && v->rects().size() == 1);
    CHECK(v->ellipses().size() == 1 && v->circles().size() == 1);
    CHECK(p->setActiveLayer(0));
    auto* r = p->activeLayer();
    auto& tile = r->ensureTile({-1,2}); tile.pixels[0] = 7; tile.pixels[4] = 128;
    CHECK(r->findTile({-1,2}) && r->findTile({-1,2})->pixels[0] == 7);
    CHECK(p->moveLayer(1,0) && p->layer(0)->name() == "Construction");
    CHECK(p->activeLayerIndex() == 1); // active raster moved with its layer
}

void testPersistence() {
    dt::Document d("roundtrip");
    d.activePage()->setBounds({0,0,100,200});
    auto* raster = d.activePage()->layer(0);
    raster->ensureTile({3,-2}).pixels[42] = 99;
    d.activePage()->addLayer(dt::LayerType::Vector, "vectors");
    d.activePage()->activeLayer()->addCircle({10,11,12,0x10203040,3});
    d.addPage({1,2,3,4});
    CHECK(d.setActivePage(0));
    auto bytes = dt::persistence::encode(d);
    CHECK(!bytes.empty());
    CHECK(bytes == dt::persistence::encode(d));
    dt::Document loaded;
    auto result = dt::persistence::decode(bytes, loaded);
    CHECK(result.ok && loaded.name() == "roundtrip" && loaded.pageCount() == 2);
    CHECK(loaded.page(0)->layer(0)->findTile({3,-2})->pixels[42] == 99);
    CHECK(loaded.page(0)->layer(1)->circles().size() == 1);
    CHECK(loaded.page(0)->layer(1)->circles()[0].radius == 12);
    auto malformed = bytes; malformed[0] ^= 0x1;
    CHECK(!dt::persistence::decode(malformed, loaded).ok);
    auto trailing = bytes; trailing.push_back(0);
    CHECK(!dt::persistence::decode(trailing, loaded).ok);
    CHECK(dt::persistence::decode(std::span<const std::uint8_t>(bytes.data(), 5), loaded).ok == false);
}

void testLegacyVectors() {
    // VEC0 stream uses explicit little-endian fields and has no rotation.
    std::vector<std::uint8_t> b{'V','E','C','0', 2,0,0,0};
    auto put32=[&](std::uint32_t x){for(int i=0;i<4;++i)b.push_back(static_cast<std::uint8_t>(x>>(8*i)));};
    auto putf=[&](float x){std::uint32_t u; std::memcpy(&u,&x,4);put32(u);};
    b.push_back(1); putf(1);putf(2);putf(3);putf(4);put32(0xaabbccdd);putf(5); // line
    b.push_back(2); putf(0);putf(0);putf(10);putf(20);put32(0x11);putf(2); // rect V0
    dt::Layer layer(dt::LayerType::Vector);
    auto r = dt::persistence::decodeVectorShapes(b, layer);
    CHECK(r.ok && layer.lines().size() == 1 && layer.rects().size() == 1);
    CHECK(layer.rects()[0].rotation == 0.0f);
}
}

int main() {
    testModel(); testPersistence(); testLegacyVectors();
    if (failures) { std::cerr << failures << " assertion(s) failed\n"; return EXIT_FAILURE; }
    std::cout << "all document tests passed\n"; return EXIT_SUCCESS;
}
