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
    DTToolLine = 2,
    DTToolRectangle = 3,
    DTToolEllipse = 4,
    DTToolCircle = 5,
    DTToolShade = 6,
    DTToolBucket = 7,
    DTToolSelect = 8,
    DTToolLasso = 9,
};

typedef NS_ENUM(uint8_t, DTLayerKind) {
    DTLayerKindRaster = 0,
    DTLayerKindVector = 1,
};

/// Legacy retained-stroke value kept only so the pre-v0.1 selection/export UI
/// remains source compatible while it is removed. The live renderer never
/// creates these objects.
@interface DTRenderStroke : NSObject
@property(nonatomic, readonly) NSArray<NSValue *> *points;
@property(nonatomic, readonly) DTTool tool;
@property(nonatomic, readonly) CGFloat brushSize;
@property(nonatomic, readonly) CGFloat brushOpacity;
@property(nonatomic, readonly) uint32_t brushColorRGBA;
@property(nonatomic, readonly) CGFloat brushHardness;
- (instancetype)initWithPoints:(NSArray<NSValue *> *)points
                           tool:(DTTool)tool
                      brushSize:(CGFloat)brushSize
                    brushOpacity:(CGFloat)brushOpacity
                 brushColorRGBA:(uint32_t)brushColorRGBA
                 brushHardness:(CGFloat)brushHardness NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTPageInfo : NSObject
@property(nonatomic, readonly) NSUInteger index;
@property(nonatomic, readonly) uint64_t pageID;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly) BOOL selected;
- (instancetype)initWithIndex:(NSUInteger)index pageID:(uint64_t)pageID name:(NSString *)name selected:(BOOL)selected NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTLayerInfo : NSObject
@property(nonatomic, readonly) NSUInteger index;
@property(nonatomic, readonly) uint64_t layerID;
@property(nonatomic, readonly) DTLayerKind kind;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly) BOOL selected;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) CGFloat opacity;
- (instancetype)initWithIndex:(NSUInteger)index layerID:(uint64_t)layerID kind:(DTLayerKind)kind name:(NSString *)name selected:(BOOL)selected visible:(BOOL)visible opacity:(CGFloat)opacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Swift-visible immutable checkpoint payload. Materialized pixel data is
/// exactly one 256x256 premultiplied RGBA8 tile and is created only after
/// Metal completion; an undo removal is represented by an empty tombstone.
@interface DTTileCheckpointPayload : NSObject
@property(nonatomic, readonly) uint64_t pageID;
@property(nonatomic, readonly) uint64_t layerID;
@property(nonatomic, readonly) int32_t tileX;
@property(nonatomic, readonly) int32_t tileY;
/// NO is an undo tombstone: versionID is zero and pixel data is empty. The
/// package writer removes that tile reference when publishing its manifest.
@property(nonatomic, readonly) BOOL exists;
@property(nonatomic, readonly) uint64_t versionID;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly, copy) NSData *premultipliedRGBA8;
- (instancetype)initWithPageID:(uint64_t)pageID
                        layerID:(uint64_t)layerID
                          tileX:(int32_t)tileX
                          tileY:(int32_t)tileY
                         exists:(BOOL)exists
                      versionID:(uint64_t)versionID
                     generation:(uint64_t)generation
            premultipliedRGBA8:(NSData *)premultipliedRGBA8 NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithPageID:(uint64_t)pageID
                        layerID:(uint64_t)layerID
                          tileX:(int32_t)tileX
                          tileY:(int32_t)tileY
                      versionID:(uint64_t)versionID
                     generation:(uint64_t)generation
            premultipliedRGBA8:(NSData *)premultipliedRGBA8;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTCheckpointPayloadBatch : NSObject
@property(nonatomic, readonly) uint64_t operationID;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly, copy) NSArray<DTTileCheckpointPayload *> *tiles;
- (instancetype)initWithOperationID:(uint64_t)operationID
                         generation:(uint64_t)generation
                              tiles:(NSArray<DTTileCheckpointPayload *> *)tiles NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTPersistedLayerDescriptor : NSObject
@property(nonatomic, readonly) uint64_t layerID;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) CGFloat opacity;
- (instancetype)initWithLayerID:(uint64_t)layerID
                            name:(NSString *)name
                         visible:(BOOL)visible
                         opacity:(CGFloat)opacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTPersistedTileAcknowledgement : NSObject
@property(nonatomic, readonly) uint64_t pageID;
@property(nonatomic, readonly) uint64_t layerID;
@property(nonatomic, readonly) int32_t tileX;
@property(nonatomic, readonly) int32_t tileY;
@property(nonatomic, readonly) uint64_t versionID;
@property(nonatomic, readonly, copy) NSString *payloadID;
- (instancetype)initWithPageID:(uint64_t)pageID
                        layerID:(uint64_t)layerID
                          tileX:(int32_t)tileX
                          tileY:(int32_t)tileY
                      versionID:(uint64_t)versionID
                      payloadID:(NSString *)payloadID NS_DESIGNATED_INITIALIZER;
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
@property(nonatomic) uint32_t brushColorRGBA;
@property(nonatomic) CGFloat brushHardness;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
@property(nonatomic, readonly) BOOL isStrokeInProgress;
@property(nonatomic, readonly) NSArray<DTPageInfo *> *pageInfos;
@property(nonatomic, readonly) NSArray<DTLayerInfo *> *layerInfos;

/// Fired on the main queue only after a Metal command buffer has completed and
/// the matching renderer transaction has been published by the core
/// coordinator. Autosave and undo UI must observe this callback instead of
/// treating endStroke as an immediate document commit.
@property(nonatomic, copy, nullable) void (^documentCommitHandler)(uint64_t generation);

/// Fired on the main queue after the matching commit callback and after every
/// shared readback buffer has completed and been copied into immutable NSData.
@property(nonatomic, copy, nullable) void (^checkpointPayloadHandler)(DTCheckpointPayloadBatch *batch);

/// Non-fatal renderer failures are surfaced on the main queue. A failed GPU
/// transaction is rolled back and never advances the document generation.
@property(nonatomic, copy, nullable) void (^rendererErrorHandler)(NSString *message);

/// Marks exactly the checkpointed tile versions durable after the package
/// store has published CURRENT. Partial/stale acknowledgements are rejected.
- (BOOL)acknowledgePersistedOperationID:(uint64_t)operationID
                              generation:(uint64_t)generation
                                   tiles:(NSArray<DTPersistedTileAcknowledgement *> *)tiles;

/// Narrow v0.1 reopen path. The caller supplies one page, exactly two raster
/// layers, and immutable 256x256 RGBA8 payloads recovered from the last valid
/// package manifest. Completion is delivered on the main queue.
- (void)loadPackagePageWithID:(uint64_t)pageID
                    generation:(uint64_t)generation
                         width:(CGFloat)width
                        height:(CGFloat)height
                        layers:(NSArray<DTPersistedLayerDescriptor *> *)layers
                         tiles:(NSArray<DTTileCheckpointPayload *> *)tiles
                    completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

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

- (BOOL)addPageWithName:(NSString *)name;
- (BOOL)selectPageAtIndex:(NSUInteger)index;
- (BOOL)renamePageAtIndex:(NSUInteger)index toName:(NSString *)name;
- (BOOL)addLayerWithName:(NSString *)name;
- (BOOL)selectLayerAtIndex:(NSUInteger)index;
- (BOOL)renameLayerAtIndex:(NSUInteger)index toName:(NSString *)name;
- (BOOL)setActiveLayerVisible:(BOOL)visible;
- (BOOL)setActiveLayerOpacity:(CGFloat)opacity;
// Swift-facing document controls return NO/NSNotFound for invalid mutations.
- (NSUInteger)addPage;
- (BOOL)setActivePageIndex:(NSUInteger)index;
- (BOOL)deletePageAtIndex:(NSUInteger)index NS_SWIFT_NAME(deletePage(at:));
- (BOOL)renamePageAtIndex:(NSUInteger)index name:(NSString *)name NS_SWIFT_NAME(renamePage(at:name:));
- (NSUInteger)addLayer;
- (BOOL)setActiveLayerIndex:(NSUInteger)index;
- (BOOL)deleteLayerAtIndex:(NSUInteger)index NS_SWIFT_NAME(deleteLayer(at:));
- (BOOL)renameLayerAtIndex:(NSUInteger)index name:(NSString *)name NS_SWIFT_NAME(renameLayer(at:name:));
- (BOOL)setLayerVisible:(BOOL)visible atIndex:(NSUInteger)index NS_SWIFT_NAME(setLayerVisible(_:at:));
- (BOOL)setLayerOpacity:(CGFloat)opacity atIndex:(NSUInteger)index NS_SWIFT_NAME(setLayerOpacity(_:at:));
- (NSUInteger)duplicatePageAtIndex:(NSUInteger)index NS_SWIFT_NAME(duplicatePage(at:));
- (BOOL)movePageAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex NS_SWIFT_NAME(movePage(from:to:));
- (NSUInteger)duplicateLayerAtIndex:(NSUInteger)index NS_SWIFT_NAME(duplicateLayer(at:));
- (BOOL)moveLayerAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex NS_SWIFT_NAME(moveLayer(from:to:));

@property(nonatomic, readonly) NSUInteger activeLayerStrokeCount;
- (BOOL)moveStrokesWithIndices:(NSArray<NSNumber *> *)indices dx:(CGFloat)dx dy:(CGFloat)dy NS_SWIFT_NAME(moveStrokes(at:dx:dy:));
- (BOOL)scaleStrokesWithIndices:(NSArray<NSNumber *> *)indices sx:(CGFloat)sx sy:(CGFloat)sy originX:(CGFloat)originX originY:(CGFloat)originY NS_SWIFT_NAME(scaleStrokes(at:sx:sy:originX:originY:));
- (BOOL)rotateStrokesWithIndices:(NSArray<NSNumber *> *)indices angle:(CGFloat)angle originX:(CGFloat)originX originY:(CGFloat)originY NS_SWIFT_NAME(rotateStrokes(at:angle:originX:originY:));
- (BOOL)deleteStrokesWithIndices:(NSArray<NSNumber *> *)indices NS_SWIFT_NAME(deleteStrokes(at:));
- (BOOL)duplicateStrokesWithIndices:(NSArray<NSNumber *> *)indices dx:(CGFloat)dx dy:(CGFloat)dy NS_SWIFT_NAME(duplicateStrokes(at:dx:dy:));
- (NSInteger)hitTestStrokeAtX:(CGFloat)x y:(CGFloat)y tolerance:(CGFloat)tolerance NS_SWIFT_NAME(hitTestStroke(atX:y:tolerance:));
- (BOOL)insertPoints:(NSArray<NSValue *> *)points tool:(DTTool)tool brushSize:(CGFloat)brushSize brushOpacity:(CGFloat)brushOpacity brushColorRGBA:(uint32_t)brushColorRGBA brushHardness:(CGFloat)brushHardness NS_SWIFT_NAME(insertStroke(points:tool:brushSize:brushOpacity:brushColorRGBA:brushHardness:));

- (NSData *)archiveData __attribute__((deprecated("Live DTAR writing is disabled; persist immutable tile checkpoints")));
- (BOOL)loadArchiveData:(NSData *)data __attribute__((deprecated("DTAR is a one-way importer only")));

/// Snapshot entries are immutable DTRenderStroke instances and are safe to
/// retain while the engine receives input.
- (NSArray<DTRenderStroke *> *)renderableStrokes __attribute__((deprecated("The v0.1 live renderer has no retained-stroke snapshot")));
- (NSArray<DTRenderStroke *> *)renderableStrokesForPageAtIndex:(NSUInteger)index NS_SWIFT_NAME(renderableStrokes(forPageAt:)) __attribute__((deprecated("The v0.1 live renderer has no retained-stroke snapshot")));

@end

NS_ASSUME_NONNULL_END
