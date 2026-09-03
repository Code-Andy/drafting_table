#include "DTEngine.hpp"

// Bridge engine types live in drafting_table::ipad (see DTEngine.hpp):
namespace dt_ipad = drafting_table::ipad;

#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <iostream>
#include <span>
#include <vector>

namespace { int failures = 0;
void check(bool condition,const char* expression,int line){if(!condition){std::cerr<<"FAIL line "<<line<<": "<<expression<<'\n';++failures;}}
#define CHECK(...) check((__VA_ARGS__),#__VA_ARGS__,__LINE__)

void appendU32(std::vector<std::uint8_t>& out, std::uint32_t value) {
    for (int index = 0; index < 4; ++index) out.push_back((value >> (index * 8)) & 0xff);
}

void appendU64(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (int index = 0; index < 8; ++index) out.push_back((value >> (index * 8)) & 0xff);
}

void appendFloat(std::vector<std::uint8_t>& out, float value) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(value));
    appendU32(out, bits);
}

void appendDouble(std::vector<std::uint8_t>& out, double value) {
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(value));
    appendU64(out, bits);
}

void appendString(std::vector<std::uint8_t>& out, const char* value) {
    const auto length = static_cast<std::uint32_t>(std::strlen(value));
    appendU32(out, length);
    out.insert(out.end(), value, value + length);
}

void appendLegacyStroke(std::vector<std::uint8_t>& out, const dt::PencilSample& sample) {
    out.push_back(static_cast<std::uint8_t>(dt_ipad::DTTool::Eraser));
    out.insert(out.end(), 3, 0);
    appendFloat(out, 12.5f);
    appendFloat(out, 0.4f);
    appendU32(out, 1);
    appendFloat(out, sample.x); appendFloat(out, sample.y);
    appendFloat(out, sample.pressure); appendFloat(out, sample.altitude);
    appendFloat(out, sample.azimuth); appendFloat(out, sample.roll);
    appendFloat(out, sample.hoverDistance); appendDouble(out, sample.timestamp);
    appendU64(out, sample.id); appendU64(out, sample.estimationUpdateIndex);
    appendU64(out, sample.estimationId);
    appendU32(out, static_cast<std::uint32_t>(sample.flags));
}

std::vector<std::uint8_t> makeVersion1Archive(const dt::PencilSample& sample) {
    std::vector<std::uint8_t> out{'D', 'T', 'A', 'R'};
    appendU32(out, 1); // version
    appendU32(out, 1); // stroke count
    appendLegacyStroke(out, sample);
    return out;
}

std::vector<std::uint8_t> makeVersion2Archive(const dt::PencilSample& sample) {
    std::vector<std::uint8_t> out{'D', 'T', 'A', 'R'};
    appendU32(out, 2); // version
    appendU32(out, 0); // active page
    appendU32(out, 1); // page count
    out.push_back(static_cast<std::uint8_t>(dt_ipad::DTTool::Eraser));
    out.insert(out.end(), 3, 0);
    appendFloat(out, 12.5f);
    appendFloat(out, 0.4f);
    appendString(out, "Legacy Page");
    appendU32(out, 0); // active layer
    appendU32(out, 1); // layer count
    appendString(out, "Legacy Ink");
    out.push_back(1); // visible
    appendFloat(out, 1.0f);
    appendU32(out, 1); // stroke count
    appendLegacyStroke(out, sample);
    return out;
}
}

int main() {
    dt_ipad::Engine engine;
    const auto initialRevision = engine.revision();
    dt::PencilSample sample{10.0f,20.0f,0.5f};
    engine.setBrushSize(-100.0f);
    engine.setBrushOpacity(0.0f);
    CHECK(engine.brushSize()==1.0f);
    CHECK(engine.brushOpacity()==0.05f);
    engine.setTool(dt_ipad::DTTool::Eraser);
    engine.setBrushSize(12.5f);
    engine.setBrushOpacity(0.4f);
    engine.beginStroke();
    engine.appendSamples(std::span<const dt::PencilSample>(&sample,1),{});
    engine.endStroke();
    CHECK(engine.strokeCount()==1); CHECK(engine.sampleCount()==1); CHECK(engine.revision()>initialRevision);
    auto snapshot=engine.snapshot();
    CHECK(snapshot.size()==1); CHECK(snapshot[0].tool==dt_ipad::DTTool::Eraser); CHECK(snapshot[0].brushSize==12.5f); CHECK(snapshot[0].brushOpacity==0.4f);
    engine.setBrushColorRGBA(0x12345600u); engine.setBrushHardness(-2.0f);
    CHECK(engine.brushColorRGBA()==0x12345600u); CHECK(engine.brushHardness()==0.0f);
    engine.setBrushHardness(0.35f); engine.setBrushColorRGBA(0xAABBCCDDu);
    engine.beginStroke(); engine.appendSamples(std::span<const dt::PencilSample>(&sample,1),{}); engine.endStroke();
    auto styled = engine.snapshot(); CHECK(styled.back().brushColorRGBA==0xAABBCCDDu); CHECK(styled.back().brushHardness==0.35f);
    engine.setBrushColorRGBA(0x01020304u); engine.setBrushHardness(0.9f);
    CHECK(engine.snapshot().back().brushColorRGBA==0xAABBCCDDu); CHECK(engine.snapshot().back().brushHardness==0.35f);

    CHECK(engine.canUndo()); CHECK(!engine.canRedo()); CHECK(engine.undoLastStroke());
    CHECK(engine.strokeCount()==1); CHECK(engine.canUndo()); CHECK(engine.canRedo()); CHECK(engine.redoLastStroke());
    CHECK(engine.strokeCount()==2); CHECK(engine.canUndo()); CHECK(!engine.canRedo());

    const auto archive=engine.archive();
    CHECK(archive.size()>12);
    dt_ipad::Engine restored;
    CHECK(restored.loadArchive(archive));
    auto restoredSnapshot=restored.snapshot();
    CHECK(restoredSnapshot.size()==2); CHECK(restoredSnapshot[0].points.size()==1);
    CHECK(restoredSnapshot[0].tool==dt_ipad::DTTool::Eraser); CHECK(restoredSnapshot[0].brushSize==12.5f); CHECK(restoredSnapshot[0].brushOpacity==0.4f);
    CHECK(restoredSnapshot[0].points[0].x==sample.x);
    CHECK(restoredSnapshot[0].brushColorRGBA==dt_ipad::kDefaultBrushColorRGBA); CHECK(restoredSnapshot[0].brushHardness==dt_ipad::kDefaultBrushHardness);
    CHECK(!restored.loadArchive(std::span<const std::uint8_t>(archive.data(),archive.size()-1)));
    CHECK(restored.strokeCount()==2);
    auto badVersion=archive; badVersion[4]=4; CHECK(!restored.loadArchive(badVersion));
    CHECK(restored.strokeCount()==2);
    auto trailing=archive; trailing.push_back(0); CHECK(!restored.loadArchive(trailing));
    CHECK(restored.strokeCount()==2);
    restored.clear(); CHECK(!restored.canUndo()); CHECK(!restored.canRedo());

    // Retained pages and layers keep independent undo stacks and flatten
    // visible layers with their opacity applied to each style.
    dt_ipad::Engine document;
    CHECK(document.pageCount() == 1);
    CHECK(document.layerNames().size() == 1);
    document.beginStroke(); document.appendSamples(std::span<const dt::PencilSample>(&sample, 1), {}); document.endStroke();
    CHECK(document.addLayer("Highlights"));
    CHECK(document.activeLayerIndex() == 1);
    document.setActiveLayerOpacity(0.25f);
    document.beginStroke(); document.appendSamples(std::span<const dt::PencilSample>(&sample, 1), {}); document.endStroke();
    CHECK(document.snapshot().size() == 2);
    CHECK(document.snapshot()[1].brushOpacity < 0.26f);
    CHECK(document.setActiveLayerVisible(false));
    CHECK(document.snapshot().size() == 1);
    CHECK(document.deleteLayer(1));
    CHECK(document.layerNames().size() == 1);
    CHECK(!document.deleteLayer(0)); // cannot remove the final layer
    CHECK(document.addPage("Page 2"));
    CHECK(document.pageCount() == 2 && document.activePageIndex() == 1);
    CHECK(document.deletePage(0));
    CHECK(document.pageCount() == 1);
    CHECK(!document.deletePage(0));
    const auto v2 = document.archive();
    dt_ipad::Engine roundTrip; CHECK(roundTrip.loadArchive(v2));
    CHECK(roundTrip.pageCount() == document.pageCount());
    CHECK(roundTrip.layerNames() == document.layerNames());

    for (auto shape : {dt_ipad::DTTool::Line, dt_ipad::DTTool::Rectangle, dt_ipad::DTTool::Ellipse, dt_ipad::DTTool::Circle}) {
        document.setTool(shape); document.beginStroke(); document.appendSamples(std::span<const dt::PencilSample>(&sample, 1), {}); document.endStroke();
    }
    auto shapedArchive = document.archive(); dt_ipad::Engine shapedRoundTrip; CHECK(shapedRoundTrip.loadArchive(shapedArchive));
    auto shaped = shapedRoundTrip.snapshot(); CHECK(shaped.size() >= 4);
    CHECK(shaped[shaped.size()-4].tool == dt_ipad::DTTool::Line); CHECK(shaped[shaped.size()-3].tool == dt_ipad::DTTool::Rectangle); CHECK(shaped[shaped.size()-2].tool == dt_ipad::DTTool::Ellipse); CHECK(shaped.back().tool == dt_ipad::DTTool::Circle);

    const auto originalPages = document.pageCount(); CHECK(document.duplicatePage(0) == 1); CHECK(document.pageCount() == originalPages + 1);
    CHECK(document.snapshotForPage(0).size() > 0); CHECK(document.movePage(1, 0)); CHECK(document.activePageIndex() == 0);
    CHECK(document.duplicateLayer(0) == 1); CHECK(document.layerNames().size() >= 2); CHECK(document.moveLayer(1, 0)); CHECK(document.activeLayerIndex() == 0);

    const auto v1 = makeVersion1Archive(sample);
    dt_ipad::Engine migrated;
    CHECK(migrated.loadArchive(v1));
    CHECK(migrated.pageCount() == 1);
    CHECK(migrated.layerNames().size() == 1);
    CHECK(migrated.snapshot().size() == 1);
    CHECK(migrated.snapshot()[0].tool == dt_ipad::DTTool::Eraser);
    CHECK(migrated.snapshot()[0].brushSize == 12.5f);
    CHECK(migrated.snapshot()[0].brushColorRGBA == dt_ipad::kDefaultBrushColorRGBA);
    CHECK(migrated.snapshot()[0].brushHardness == dt_ipad::kDefaultBrushHardness);

    const auto legacyV2 = makeVersion2Archive(sample);
    dt_ipad::Engine migratedV2;
    CHECK(migratedV2.loadArchive(legacyV2));
    CHECK(migratedV2.pageNames()[0] == "Legacy Page");
    CHECK(migratedV2.layerNames()[0] == "Legacy Ink");
    CHECK(migratedV2.snapshot()[0].brushColorRGBA == dt_ipad::kDefaultBrushColorRGBA);
    CHECK(migratedV2.snapshot()[0].brushHardness == dt_ipad::kDefaultBrushHardness);

    dt_ipad::Engine bounded;
    std::vector<dt::PencilSample> longStroke(2'000, sample);
    for (std::size_t index = 0; index < longStroke.size(); ++index) longStroke[index].x = static_cast<float>(index);
    bounded.beginStroke(); bounded.appendSamples(longStroke, {}); bounded.endStroke();
    const auto display = bounded.snapshotForDisplay(0, 128, 128);
    CHECK(display.size() == 1); CHECK(display[0].points.size() == 128);
    CHECK(display[0].points.front().x == 0.0f);
    CHECK(display[0].points.back().x == 1'999.0f);

    engine.beginStroke(); engine.appendSamples(std::span<const dt::PencilSample>(&sample,1),{});
    CHECK(engine.canUndo()); CHECK(engine.undoLastStroke()); CHECK(engine.strokeCount()==1); CHECK(engine.canRedo());
    if(failures!=0)return EXIT_FAILURE; std::cout<<"all iPad engine tests passed\n"; return EXIT_SUCCESS;
}
