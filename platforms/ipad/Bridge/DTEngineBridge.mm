#import "DTEngineBridge.h"

#include "DTEngine.hpp"
#include <memory>

using drafting_table::Engine;
using drafting_table::Stroke;
using drafting_table::StrokePoint;

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

- (void)appendPointAtX:(CGFloat)x
                     y:(CGFloat)y
              pressure:(CGFloat)pressure
             timestamp:(NSTimeInterval)timestamp
             predicted:(BOOL)predicted {
    if (!_engine) return;
    StrokePoint point;
    point.x = static_cast<float>(x);
    point.y = static_cast<float>(y);
    point.pressure = static_cast<float>(pressure);
    point.timestamp = timestamp;
    point.predicted = predicted;
    _engine->appendPoint(point);
}

- (void)endStroke { if (_engine) _engine->endStroke(); }
- (void)clearCanvas { if (_engine) _engine->clear(); }

- (NSArray<NSArray<NSValue *> *> *)renderableStrokes {
    if (!_engine) return @[];
    const auto strokes = _engine->snapshot();
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:strokes.size()];
    for (const Stroke& stroke : strokes) {
        NSMutableArray *polyline = [NSMutableArray arrayWithCapacity:stroke.points.size()];
        for (const StrokePoint& point : stroke.points) {
            DTRenderPoint renderPoint = {point.x, point.y, point.pressure,
                                         static_cast<uint8_t>(point.predicted ? 1 : 0)};
            [polyline addObject:[NSValue valueWithBytes:&renderPoint
                                              objCType:@encode(DTRenderPoint)]];
        }
        [result addObject:polyline];
    }
    return result;
}

@end
