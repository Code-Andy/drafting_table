#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Value type used when passing a render snapshot from C++ to Metal.
typedef struct {
    float x;
    float y;
    float pressure;
    uint8_t predicted;
} DTRenderPoint;

/// Objective-C ownership boundary around the platform-neutral C++ engine.
/// Swift only sees this small API; no C++ types leak into the application.
@interface DTEngineBridge : NSObject

@property(nonatomic, readonly) NSUInteger strokeCount;
@property(nonatomic, readonly) NSUInteger sampleCount;

- (void)beginStroke;
- (void)appendPointAtX:(CGFloat)x
                     y:(CGFloat)y
              pressure:(CGFloat)pressure
             timestamp:(NSTimeInterval)timestamp
             predicted:(BOOL)predicted;
- (void)endStroke;
- (void)clearCanvas;

/// Snapshot is an array of polylines. Each polyline contains NSValue-wrapped
/// DTRenderPoint values and is safe to retain while the engine receives input.
- (NSArray<NSArray<NSValue *> *> *)renderableStrokes;

@end

NS_ASSUME_NONNULL_END
