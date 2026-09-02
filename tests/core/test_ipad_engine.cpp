#include "DTEngine.hpp"

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

std::vector<std::uint8_t> makeVersion1Archive(const dt::PencilSample& sample) {
    std::vector<std::uint8_t> out{'D', 'T', 'A', 'R'};
    appendU32(out, 1); // version
    appendU32(out, 1); // stroke count
    out.push_back(static_cast<std::uint8_t>(dt::DTTool::Eraser));
    out.insert(out.end(), 3, 0);
    appendFloat(out, 12.5f);
    appendFloat(out, 0.4f);
    appendU32(out, 1); // point count
    appendFloat(out, sample.x); appendFloat(out, sample.y);
    appendFloat(out, sample.pressure); appendFloat(out, sample.altitude);
    appendFloat(out, sample.azimuth); appendFloat(out, sample.roll);
    appendFloat(out, sample.hoverDistance); appendDouble(out, sample.timestamp);
    appendU64(out, sample.id); appendU64(out, sample.estimationUpdateIndex);
    appendU64(out, sample.estimationId);
    appendU32(out, static_cast<std::uint32_t>(sample.flags));
    return out;
}
}

int main() {
    dt::Engine engine;
    const auto initialRevision = engine.revision();
    dt::PencilSample sample{10.0f,20.0f,0.5f};
    engine.setBrushSize(-100.0f);
    engine.setBrushOpacity(0.0f);
    CHECK(engine.brushSize()==1.0f);
    CHECK(engine.brushOpacity()==0.05f);
    engine.setTool(dt::DTTool::Eraser);
    engine.setBrushSize(12.5f);
    engine.setBrushOpacity(0.4f);
    engine.beginStroke();
    engine.appendSamples(std::span<const dt::PencilSample>(&sample,1),{});
    engine.endStroke();
    CHECK(engine.strokeCount()==1); CHECK(engine.sampleCount()==1); CHECK(engine.revision()>initialRevision);
    auto snapshot=engine.snapshot();
    CHECK(snapshot.size()==1); CHECK(snapshot[0].tool==dt::DTTool::Eraser); CHECK(snapshot[0].brushSize==12.5f); CHECK(snapshot[0].brushOpacity==0.4f);

    CHECK(engine.canUndo()); CHECK(!engine.canRedo()); CHECK(engine.undoLastStroke());
    CHECK(engine.strokeCount()==0); CHECK(!engine.canUndo()); CHECK(engine.canRedo()); CHECK(engine.redoLastStroke());
    CHECK(engine.strokeCount()==1); CHECK(engine.canUndo()); CHECK(!engine.canRedo());

    const auto archive=engine.archive();
    CHECK(archive.size()>12);
    dt::Engine restored;
    CHECK(restored.loadArchive(archive));
    auto restoredSnapshot=restored.snapshot();
    CHECK(restoredSnapshot.size()==1); CHECK(restoredSnapshot[0].points.size()==1);
    CHECK(restoredSnapshot[0].tool==dt::DTTool::Eraser); CHECK(restoredSnapshot[0].brushSize==12.5f); CHECK(restoredSnapshot[0].brushOpacity==0.4f);
    CHECK(restoredSnapshot[0].points[0].x==sample.x);
    CHECK(!restored.loadArchive(std::span<const std::uint8_t>(archive.data(),archive.size()-1)));
    CHECK(restored.strokeCount()==1);
    auto badVersion=archive; badVersion[4]=3; CHECK(!restored.loadArchive(badVersion));
    CHECK(restored.strokeCount()==1);
    auto trailing=archive; trailing.push_back(0); CHECK(!restored.loadArchive(trailing));
    CHECK(restored.strokeCount()==1);
    restored.clear(); CHECK(!restored.canUndo()); CHECK(!restored.canRedo());

    // Retained pages and layers keep independent undo stacks and flatten
    // visible layers with their opacity applied to each style.
    dt::Engine document;
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
    dt::Engine roundTrip; CHECK(roundTrip.loadArchive(v2));
    CHECK(roundTrip.pageCount() == document.pageCount());
    CHECK(roundTrip.layerNames() == document.layerNames());

    const auto v1 = makeVersion1Archive(sample);
    dt::Engine migrated;
    CHECK(migrated.loadArchive(v1));
    CHECK(migrated.pageCount() == 1);
    CHECK(migrated.layerNames().size() == 1);
    CHECK(migrated.snapshot().size() == 1);
    CHECK(migrated.snapshot()[0].tool == dt::DTTool::Eraser);
    CHECK(migrated.snapshot()[0].brushSize == 12.5f);

    engine.beginStroke(); engine.appendSamples(std::span<const dt::PencilSample>(&sample,1),{});
    CHECK(engine.canUndo()); CHECK(engine.undoLastStroke()); CHECK(engine.strokeCount()==0); CHECK(engine.canRedo());
    if(failures!=0)return EXIT_FAILURE; std::cout<<"all iPad engine tests passed\n"; return EXIT_SUCCESS;
}
