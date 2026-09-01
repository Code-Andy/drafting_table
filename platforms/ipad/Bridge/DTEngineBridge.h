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

typedef NS_OPTIONS(uint32_t, DTPencilSampleFlags) {
    DTPencilSampleFlagReal = 1u << 0,
    DTPencilSampleFlagPredicted = 1u << 1,
    DTPencilSampleFlagCoalesced = 1u << 2,
    DTPencilSampleFlagPressureEstimated = 1u << 3,
    DTPencilSampleFlagAltitudeEstimated = 1u << 4,
    DTPencilSampleFlagAzimuthEstimated = 1u << 5,
    DTPencilSampleFlagRollEstimated = 1u << 6,
};

typedef struct {
    float x;
    float y;
    float pressure;
    float altitude;
    float azimuth;
    float roll;
    float hoverDistance;
    double timestamp;
    uint64_t sampleID;
    uint64_t estimationUpdateIndex;
    DTPencilSampleFlags flags;
} DTPencilSample;

typedef NS_ENUM(uint8_t, DTTool) {
    DTToolBrush = 0,
    DTToolEraser = 1,
};

/// Immutable render snapshot carrying the stroke's style as well as its
/// points.  Points are NSValue-wrapped DTRenderPoint values.
@interface DTRenderStroke : NSObject
@property(nonatomic, readonly) NSArray<NSValue *> *points;
@property(nonatomic, readonly) DTTool tool;
@property(nonatomic, readonly) CGFloat brushSize;
@property(nonatomic, readonly) CGFloat brushOpacity;
- (instancetype)initWithPoints:(NSArray<NSValue *> *)points
                           tool:(DTTool)tool
                      brushSize:(CGFloat)brushSize
                    brushOpacity:(CGFloat)brushOpacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Objective-C ownership boundary around the platform-neutral C++ engine.
/// Swift only sees this small API; no C++ types leak into the application.
@interface DTEngineBridge : NSObject

@property(nonatomic, readonly) NSUInteger strokeCount;
@property(nonatomic, readonly) NSUInteger sampleCount;
@property(nonatomic, readonly) uint64_t revision;
@property(nonatomic) DTTool tool;
@property(nonatomic) CGFloat brushSize;
@property(nonatomic) CGFloat brushOpacity;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;

- (void)beginStroke;
- (void)appendSamples:(const DTPencilSample *_Nullable)samples
                count:(NSUInteger)count
            realCount:(NSUInteger)realCount;
- (BOOL)updateEstimatedSampleAtIndex:(uint64_t)estimationUpdateIndex
                              sample:(DTPencilSample)sample;
- (void)endStroke;
- (void)cancelStroke;
- (void)clearCanvas;
- (BOOL)undoLastStroke;
- (BOOL)redoLastStroke;

- (NSData *)archiveData;
- (BOOL)loadArchiveData:(NSData *)data;

/// Snapshot entries are immutable DTRenderStroke instances and are safe to
/// retain while the engine receives input.
- (NSArray<DTRenderStroke *> *)renderableStrokes;

@end

NS_ASSUME_NONNULL_END
