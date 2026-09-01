#import "DTEngineBridge.h"

#include "DTEngine.hpp"
#include <memory>

using drafting_table::Engine;
using drafting_table::Stroke;
using drafting_table::PencilSample;

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

- (NSArray<NSArray<NSValue *> *> *)renderableStrokes {
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
        [result addObject:polyline];
    }
    return result;
}

@end
