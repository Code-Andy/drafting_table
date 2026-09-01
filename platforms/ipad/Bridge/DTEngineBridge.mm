#import "DTEngineBridge.h"

#include "DTEngine.hpp"
#include <memory>
#include <span>

using drafting_table::Engine;
using drafting_table::Stroke;
using drafting_table::PencilSample;

@implementation DTRenderStroke {
    NSArray<NSValue *> *_points;
    DTTool _tool;
    CGFloat _brushSize;
    CGFloat _brushOpacity;
}

- (instancetype)initWithPoints:(NSArray<NSValue *> *)points
                           tool:(DTTool)tool
                      brushSize:(CGFloat)brushSize
                    brushOpacity:(CGFloat)brushOpacity {
    self = [super init];
    if (self) {
        _points = [points copy];
        _tool = tool;
        _brushSize = brushSize;
        _brushOpacity = brushOpacity;
    }
    return self;
}
- (NSArray<NSValue *> *)points { return _points; }
- (DTTool)tool { return _tool; }
- (CGFloat)brushSize { return _brushSize; }
- (CGFloat)brushOpacity { return _brushOpacity; }
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
    if (!_engine || _engine->tool() == drafting_table::DTTool::Brush) return DTToolBrush;
    return DTToolEraser;
}
- (void)setTool:(DTTool)tool {
    if (_engine) _engine->setTool(tool == DTToolEraser ? drafting_table::DTTool::Eraser : drafting_table::DTTool::Brush);
}
- (CGFloat)brushSize { return _engine ? _engine->brushSize() : 8.0; }
- (void)setBrushSize:(CGFloat)size { if (_engine) _engine->setBrushSize((float)size); }
- (CGFloat)brushOpacity { return _engine ? _engine->brushOpacity() : 1.0; }
- (void)setBrushOpacity:(CGFloat)opacity { if (_engine) _engine->setBrushOpacity((float)opacity); }
- (BOOL)canUndo { return _engine && _engine->canUndo(); }
- (BOOL)canRedo { return _engine && _engine->canRedo(); }

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
    const auto strokes = _engine->snapshot();
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:strokes.size()];
    for (const Stroke& stroke : strokes) {
        NSMutableArray *polyline = [NSMutableArray arrayWithCapacity:stroke.points.size()];
        for (const PencilSample& point : stroke.points) {
            DTRenderPoint renderPoint = {point.x, point.y, point.pressure,
                                         static_cast<uint8_t>(point.isPredicted() ? 1 : 0)};
            [polyline addObject:[NSValue valueWithBytes:&renderPoint
                                              objCType:@encode(DTRenderPoint)]];
        }
        const DTTool tool = stroke.tool == drafting_table::DTTool::Eraser ? DTToolEraser : DTToolBrush;
        [result addObject:[[DTRenderStroke alloc] initWithPoints:polyline
                                                            tool:tool
                                                       brushSize:stroke.brushSize
                                                     brushOpacity:stroke.brushOpacity]];
    }
    return result;
}

@end
