#import "DTEngineBridge.h"

#include "DTEngine.hpp"
#include <memory>
#include <limits>
#include <span>

using drafting_table::ipad::Engine;
using drafting_table::ipad::Stroke;
using drafting_table::PencilSample;

@implementation DTRenderStroke {
    NSArray<NSValue *> *_points;
    DTTool _tool;
    CGFloat _brushSize;
    CGFloat _brushOpacity;
    uint32_t _brushColorRGBA;
    CGFloat _brushHardness;
}

- (instancetype)initWithPoints:(NSArray<NSValue *> *)points
                           tool:(DTTool)tool
                      brushSize:(CGFloat)brushSize
                    brushOpacity:(CGFloat)brushOpacity
                 brushColorRGBA:(uint32_t)brushColorRGBA
                  brushHardness:(CGFloat)brushHardness {
    self = [super init];
    if (self) {
        _points = [points copy];
        _tool = tool;
        _brushSize = brushSize;
        _brushOpacity = brushOpacity;
        _brushColorRGBA = brushColorRGBA;
        _brushHardness = brushHardness;
    }
    return self;
}
- (NSArray<NSValue *> *)points { return _points; }
- (DTTool)tool { return _tool; }
- (CGFloat)brushSize { return _brushSize; }
- (CGFloat)brushOpacity { return _brushOpacity; }
- (uint32_t)brushColorRGBA { return _brushColorRGBA; }
- (CGFloat)brushHardness { return _brushHardness; }
@end

@implementation DTPageInfo {
    NSUInteger _index; NSString *_name; BOOL _selected;
}
- (instancetype)initWithIndex:(NSUInteger)index name:(NSString *)name selected:(BOOL)selected { if ((self=[super init])) { _index=index; _name=[name copy]; _selected=selected; } return self; }
- (NSUInteger)index{return _index;} - (NSString *)name{return _name;} - (BOOL)selected{return _selected;}
@end

@implementation DTLayerInfo {
    NSUInteger _index; NSString *_name; BOOL _selected; BOOL _visible; CGFloat _opacity;
}
- (instancetype)initWithIndex:(NSUInteger)index name:(NSString *)name selected:(BOOL)selected visible:(BOOL)visible opacity:(CGFloat)opacity { if ((self=[super init])) { _index=index; _name=[name copy]; _selected=selected; _visible=visible; _opacity=opacity; } return self; }
- (NSUInteger)index{return _index;} - (NSString *)name{return _name;} - (BOOL)selected{return _selected;} - (BOOL)visible{return _visible;} - (CGFloat)opacity{return _opacity;}
@end

namespace {
PencilSample toCoreSample(const DTPencilSample& input) {
    PencilSample sample;
    sample.x = input.x;
    sample.y = input.y;
    sample.pressure = input.pressure;
    sample.altitude = input.altitude;
    sample.azimuth = input.azimuth;
    sample.roll = input.roll;
    sample.hoverDistance = input.hoverDistance;
    sample.timestamp = input.timestamp;
    sample.id = input.sampleID;
    sample.estimationUpdateIndex = input.estimationUpdateIndex;
    sample.flags = static_cast<drafting_table::SampleFlags>(input.flags);
    return sample;
}
}

@implementation DTEngineBridge {
    std::unique_ptr<Engine> _engine;
}

- (instancetype)init {
    self = [super init];
    if (self) _engine = std::make_unique<Engine>();
    return self;
}

- (NSUInteger)strokeCount { return _engine ? _engine->strokeCount() : 0; }
- (NSUInteger)sampleCount { return _engine ? _engine->sampleCount() : 0; }
- (uint64_t)revision { return _engine ? _engine->revision() : 0; }
- (DTTool)tool {
    if (!_engine) return DTToolBrush;
    return static_cast<DTTool>(_engine->tool());
}
- (void)setTool:(DTTool)tool {
    if (_engine) _engine->setTool(static_cast<drafting_table::ipad::DTTool>(tool));
}
- (CGFloat)brushSize { return _engine ? _engine->brushSize() : 8.0; }
- (void)setBrushSize:(CGFloat)size { if (_engine) _engine->setBrushSize((float)size); }
- (CGFloat)brushOpacity { return _engine ? _engine->brushOpacity() : 1.0; }
- (void)setBrushOpacity:(CGFloat)opacity { if (_engine) _engine->setBrushOpacity((float)opacity); }
- (uint32_t)brushColorRGBA { return _engine ? _engine->brushColorRGBA() : drafting_table::ipad::kDefaultBrushColorRGBA; }
- (void)setBrushColorRGBA:(uint32_t)color { if (_engine) _engine->setBrushColorRGBA(color); }
- (CGFloat)brushHardness { return _engine ? _engine->brushHardness() : drafting_table::ipad::kDefaultBrushHardness; }
- (void)setBrushHardness:(CGFloat)hardness { if (_engine) _engine->setBrushHardness((float)hardness); }
- (BOOL)canUndo { return _engine && _engine->canUndo(); }
- (BOOL)canRedo { return _engine && _engine->canRedo(); }
- (NSArray<DTPageInfo *> *)pageInfos {
    if (!_engine) return @[]; auto names=_engine->pageNames(); NSUInteger selected=_engine->activePageIndex(); NSMutableArray *r=[NSMutableArray arrayWithCapacity:names.size()];
    for (NSUInteger i=0;i<names.size();++i) [r addObject:[[DTPageInfo alloc] initWithIndex:i name:[NSString stringWithUTF8String:names[i].c_str()] ?: @"" selected:i==selected]]; return r;
}
- (NSArray<DTLayerInfo *> *)layerInfos {
    if (!_engine) return @[]; auto names=_engine->layerNames(); NSUInteger selected=_engine->activeLayerIndex(); NSMutableArray *r=[NSMutableArray arrayWithCapacity:names.size()];
    for (NSUInteger i=0;i<names.size();++i) [r addObject:[[DTLayerInfo alloc] initWithIndex:i name:[NSString stringWithUTF8String:names[i].c_str()] ?: @"" selected:i==selected visible:_engine->layerVisible(i) opacity:_engine->layerOpacity(i)]]; return r;
}

- (void)beginStroke { if (_engine) _engine->beginStroke(); }

- (void)appendSamples:(const DTPencilSample *)samples
                count:(NSUInteger)count
            realCount:(NSUInteger)realCount {
    if (!_engine || !samples || count == 0 || realCount > count) return;
    std::vector<PencilSample> converted;
    converted.reserve(count);
    for (NSUInteger index = 0; index < count; ++index) {
        converted.push_back(toCoreSample(samples[index]));
    }
    _engine->appendSamples(
        std::span<const PencilSample>(converted.data(), realCount),
        std::span<const PencilSample>(converted.data() + realCount, count - realCount));
}

- (BOOL)updateEstimatedSampleAtIndex:(uint64_t)estimationUpdateIndex
                              sample:(DTPencilSample)sample {
    return _engine && _engine->updateEstimatedSample(estimationUpdateIndex,
                                                      toCoreSample(sample));
}

- (void)endStroke { if (_engine) _engine->endStroke(); }
- (void)cancelStroke { if (_engine) _engine->cancelStroke(); }
- (void)clearCanvas { if (_engine) _engine->clear(); }
- (BOOL)undoLastStroke { return _engine && _engine->undoLastStroke(); }
- (BOOL)redoLastStroke { return _engine && _engine->redoLastStroke(); }
- (BOOL)addPageWithName:(NSString *)name { return _engine && _engine->addPage(name.UTF8String ? std::string(name.UTF8String) : std::string()); }
- (BOOL)selectPageAtIndex:(NSUInteger)index { return _engine && _engine->selectPage(index); }
- (BOOL)renamePageAtIndex:(NSUInteger)index toName:(NSString *)name { return _engine && name && _engine->renamePage(index, std::string(name.UTF8String ?: "")); }
- (BOOL)addLayerWithName:(NSString *)name { return _engine && _engine->addLayer(name.UTF8String ? std::string(name.UTF8String) : std::string()); }
- (BOOL)selectLayerAtIndex:(NSUInteger)index { return _engine && _engine->selectLayer(index); }
- (BOOL)renameLayerAtIndex:(NSUInteger)index toName:(NSString *)name { return _engine && name && _engine->renameLayer(index, std::string(name.UTF8String ?: "")); }
- (BOOL)setActiveLayerVisible:(BOOL)visible { return _engine && _engine->setActiveLayerVisible(visible); }
- (BOOL)setActiveLayerOpacity:(CGFloat)opacity { return _engine && _engine->setActiveLayerOpacity((float)opacity); }
- (NSUInteger)addPage { if (!_engine) return NSNotFound; const auto before=_engine->pageCount(); if (!_engine->addPage()) return NSNotFound; return before; }
- (BOOL)setActivePageIndex:(NSUInteger)index { return _engine && _engine->selectPage(index); }
- (BOOL)deletePageAtIndex:(NSUInteger)index { return _engine && _engine->deletePage(index); }
- (BOOL)renamePageAtIndex:(NSUInteger)index name:(NSString *)name { return _engine && name && _engine->renamePage(index, std::string(name.UTF8String ?: "")); }
- (NSUInteger)addLayer { if (!_engine) return NSNotFound; const auto before=_engine->layerNames().size(); if (!_engine->addLayer()) return NSNotFound; return before; }
- (BOOL)setActiveLayerIndex:(NSUInteger)index { return _engine && _engine->selectLayer(index); }
- (BOOL)deleteLayerAtIndex:(NSUInteger)index { return _engine && _engine->deleteLayer(index); }
- (BOOL)renameLayerAtIndex:(NSUInteger)index name:(NSString *)name { return _engine && name && _engine->renameLayer(index, std::string(name.UTF8String ?: "")); }
- (BOOL)setLayerVisible:(BOOL)visible atIndex:(NSUInteger)index { return _engine && _engine->setLayerVisible(index, visible); }
- (BOOL)setLayerOpacity:(CGFloat)opacity atIndex:(NSUInteger)index { return _engine && _engine->setLayerOpacity(index, (float)opacity); }
- (NSUInteger)duplicatePageAtIndex:(NSUInteger)index { if (!_engine) return NSNotFound; const auto value = _engine->duplicatePage(index); return value == std::numeric_limits<std::size_t>::max() ? NSNotFound : value; }
- (BOOL)movePageAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex { return _engine && _engine->movePage(fromIndex, toIndex); }
- (NSUInteger)duplicateLayerAtIndex:(NSUInteger)index { if (!_engine) return NSNotFound; const auto value = _engine->duplicateLayer(index); return value == std::numeric_limits<std::size_t>::max() ? NSNotFound : value; }
- (BOOL)moveLayerAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex { return _engine && _engine->moveLayer(fromIndex, toIndex); }

- (NSData *)archiveData {
    if (!_engine) return [NSData data];
    const auto bytes = _engine->archive();
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

- (BOOL)loadArchiveData:(NSData *)data {
    if (!data || !_engine) return NO;
    const auto *bytes = static_cast<const std::uint8_t *>(data.bytes);
    return _engine->loadArchive(
        std::span<const std::uint8_t>(bytes, data.length));
}

- (NSArray<DTRenderStroke *> *)renderableStrokes {
    if (!_engine) return @[];
    // The retained archive can contain millions of samples, but a display
    // frame must remain bounded. Decimation preserves first/last points for
    // shape tools and prevents launch-time deep-copy/NSValue allocation spikes.
    const auto strokes = _engine->snapshotForDisplay(_engine->activePageIndex(), 1024, 65536);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:strokes.size()];
    for (const Stroke& stroke : strokes) {
        NSMutableArray *polyline = [NSMutableArray arrayWithCapacity:stroke.points.size()];
        for (const PencilSample& point : stroke.points) {
            DTRenderPoint renderPoint = {point.x, point.y, point.pressure,
                                         static_cast<uint8_t>(point.isPredicted() ? 1 : 0)};
            [polyline addObject:[NSValue valueWithBytes:&renderPoint
                                              objCType:@encode(DTRenderPoint)]];
        }
        const DTTool tool = static_cast<DTTool>(stroke.tool);
        [result addObject:[[DTRenderStroke alloc] initWithPoints:polyline
                                                            tool:tool
                                                       brushSize:stroke.brushSize
                                                     brushOpacity:stroke.brushOpacity
                                                  brushColorRGBA:stroke.brushColorRGBA
                                                   brushHardness:stroke.brushHardness]];
    }
    return result;
}

- (NSArray<DTRenderStroke *> *)renderableStrokesForPageAtIndex:(NSUInteger)index {
    if (!_engine) return @[];
    const auto strokes = _engine->snapshotForDisplay(index, 1024, 65536);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:strokes.size()];
    for (const Stroke& stroke : strokes) {
        NSMutableArray *polyline = [NSMutableArray arrayWithCapacity:stroke.points.size()];
        for (const PencilSample& point : stroke.points) {
            DTRenderPoint renderPoint = {point.x, point.y, point.pressure, static_cast<uint8_t>(point.isPredicted() ? 1 : 0)};
            [polyline addObject:[NSValue valueWithBytes:&renderPoint objCType:@encode(DTRenderPoint)]];
        }
        [result addObject:[[DTRenderStroke alloc] initWithPoints:polyline tool:static_cast<DTTool>(stroke.tool) brushSize:stroke.brushSize brushOpacity:stroke.brushOpacity brushColorRGBA:stroke.brushColorRGBA brushHardness:stroke.brushHardness]];
    }
    return result;
}

@end
