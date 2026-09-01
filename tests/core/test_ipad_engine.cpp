#include "DTEngine.hpp"

#include <cstdlib>
#include <iostream>
#include <span>
#include <vector>

namespace { int failures = 0;
void check(bool condition,const char* expression,int line){if(!condition){std::cerr<<"FAIL line "<<line<<": "<<expression<<'\n';++failures;}}
#define CHECK(...) check((__VA_ARGS__),#__VA_ARGS__,__LINE__)
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
    auto badVersion=archive; badVersion[4]=2; CHECK(!restored.loadArchive(badVersion));
    CHECK(restored.strokeCount()==1);
    auto trailing=archive; trailing.push_back(0); CHECK(!restored.loadArchive(trailing));
    CHECK(restored.strokeCount()==1);
    restored.clear(); CHECK(!restored.canUndo()); CHECK(!restored.canRedo());

    engine.beginStroke(); engine.appendSamples(std::span<const dt::PencilSample>(&sample,1),{});
    CHECK(engine.canUndo()); CHECK(engine.undoLastStroke()); CHECK(engine.strokeCount()==0); CHECK(engine.canRedo());
    if(failures!=0)return EXIT_FAILURE; std::cout<<"all iPad engine tests passed\n"; return EXIT_SUCCESS;
}
