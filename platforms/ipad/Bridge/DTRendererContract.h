#import <Foundation/Foundation.h>

#import "DTEngineBridge.h"

NS_ASSUME_NONNULL_BEGIN

typedef uint64_t DTPageIdentifier;
typedef uint64_t DTLayerIdentifier;
typedef uint64_t DTOperationIdentifier;
typedef uint64_t DTDocumentGeneration;

typedef struct {
    int32_t x;
    int32_t y;
} DTTileCoordinate;

/// Immutable value captured when beginStroke enters the serial document
/// queue. Layer opacity is intentionally absent: it belongs to composition,
/// never to a tile mutation.
typedef struct {
    DTOperationIdentifier operationID;
    DTDocumentGeneration generation;
    DTPageIdentifier pageID;
    DTLayerIdentifier layerID;
    DTTool tool;
    float brushSize;
    float brushOpacity;
    float brushHardness;
    uint32_t brushColorRGBA;
} DTStrokeOperationDescriptor;

@interface DTSampleBatchDescriptor : NSObject
@property(nonatomic, readonly) DTOperationIdentifier operationID;
@property(nonatomic, readonly, copy) NSData *sampleBytes;
@property(nonatomic, readonly) NSUInteger realCount;
- (instancetype)initWithOperationID:(DTOperationIdentifier)operationID
                        sampleBytes:(NSData *)sampleBytes
                          realCount:(NSUInteger)realCount NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTLayerRenderDescriptor : NSObject
@property(nonatomic, readonly) DTLayerIdentifier layerID;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) float opacity;
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID
                            name:(NSString *)name
                         visible:(BOOL)visible
                         opacity:(float)opacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Lightweight metadata only. No raster bytes or mutable GPU handles cross
/// this boundary.
@interface DTRenderMetadataDescriptor : NSObject
@property(nonatomic, readonly) DTPageIdentifier pageID;
@property(nonatomic, readonly) DTDocumentGeneration generation;
@property(nonatomic, readonly) DTLayerIdentifier activeLayerID;
@property(nonatomic, readonly) float pageWidth;
@property(nonatomic, readonly) float pageHeight;
@property(nonatomic, readonly, copy) NSArray<DTLayerRenderDescriptor *> *layers;
- (instancetype)initWithPageID:(DTPageIdentifier)pageID
                     generation:(DTDocumentGeneration)generation
                  activeLayerID:(DTLayerIdentifier)activeLayerID
                      pageWidth:(float)pageWidth
                     pageHeight:(float)pageHeight
                         layers:(NSArray<DTLayerRenderDescriptor *> *)layers NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTTileCommitDescriptor : NSObject
@property(nonatomic, readonly) DTLayerIdentifier layerID;
@property(nonatomic, readonly) DTTileCoordinate coordinate;
@property(nonatomic, readonly) BOOL beforeExists;
@property(nonatomic, readonly) DTDocumentGeneration beforeGeneration;
@property(nonatomic, readonly) BOOL afterExists;
@property(nonatomic, readonly) DTDocumentGeneration afterGeneration;
@property(nonatomic, readonly) uint64_t afterVersionID;
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID
                      coordinate:(DTTileCoordinate)coordinate
                    beforeExists:(BOOL)beforeExists
                beforeGeneration:(DTDocumentGeneration)beforeGeneration
                     afterExists:(BOOL)afterExists
                 afterGeneration:(DTDocumentGeneration)afterGeneration
                   afterVersionID:(uint64_t)afterVersionID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTRasterCommitDescriptor : NSObject
@property(nonatomic, readonly) DTOperationIdentifier operationID;
@property(nonatomic, readonly) DTDocumentGeneration generation;
@property(nonatomic, readonly) DTPageIdentifier pageID;
@property(nonatomic, readonly, copy) NSArray<DTTileCommitDescriptor *> *tiles;
- (instancetype)initWithOperationID:(DTOperationIdentifier)operationID
                         generation:(DTDocumentGeneration)generation
                             pageID:(DTPageIdentifier)pageID
                              tiles:(NSArray<DTTileCommitDescriptor *> *)tiles NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A restore source remains an immutable backend generation. targetExists is
/// separate because restoring an unmaterialized tile commits transparent GPU
/// state but removes the tile reference from the canonical document.
@interface DTTileRestoreDescriptor : NSObject
@property(nonatomic, readonly) DTLayerIdentifier layerID;
@property(nonatomic, readonly) DTTileCoordinate coordinate;
@property(nonatomic, readonly) BOOL sourceExists;
@property(nonatomic, readonly) DTDocumentGeneration sourceGeneration;
@property(nonatomic, readonly) BOOL targetExists;
@property(nonatomic, readonly) uint64_t targetVersionID;
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID
                      coordinate:(DTTileCoordinate)coordinate
                    sourceExists:(BOOL)sourceExists
                sourceGeneration:(DTDocumentGeneration)sourceGeneration
                    targetExists:(BOOL)targetExists
                 targetVersionID:(uint64_t)targetVersionID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTRestoreOperationDescriptor : NSObject
@property(nonatomic, readonly) DTOperationIdentifier operationID;
@property(nonatomic, readonly) DTDocumentGeneration generation;
@property(nonatomic, readonly) DTPageIdentifier pageID;
@property(nonatomic, readonly, copy) NSArray<DTTileRestoreDescriptor *> *tiles;
- (instancetype)initWithOperationID:(DTOperationIdentifier)operationID
                         generation:(DTDocumentGeneration)generation
                             pageID:(DTPageIdentifier)pageID
                              tiles:(NSArray<DTTileRestoreDescriptor *> *)tiles NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTTileVersionDescriptor : NSObject
@property(nonatomic, readonly) DTLayerIdentifier layerID;
@property(nonatomic, readonly) DTTileCoordinate coordinate;
@property(nonatomic, readonly) BOOL exists;
@property(nonatomic, readonly) DTDocumentGeneration generation;
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID
                      coordinate:(DTTileCoordinate)coordinate
                          exists:(BOOL)exists
                      generation:(DTDocumentGeneration)generation NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTTileUploadDescriptor : NSObject
@property(nonatomic, readonly) DTPageIdentifier pageID;
@property(nonatomic, readonly) DTLayerIdentifier layerID;
@property(nonatomic, readonly) DTTileCoordinate coordinate;
@property(nonatomic, readonly) uint64_t versionID;
@property(nonatomic, readonly) DTDocumentGeneration generation;
@property(nonatomic, readonly, copy) NSData *premultipliedRGBA8;
- (instancetype)initWithPageID:(DTPageIdentifier)pageID
                        layerID:(DTLayerIdentifier)layerID
                     coordinate:(DTTileCoordinate)coordinate
                       versionID:(uint64_t)versionID
                      generation:(DTDocumentGeneration)generation
             premultipliedRGBA8:(NSData *)premultipliedRGBA8 NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface DTDocumentLoadDescriptor : NSObject
@property(nonatomic, readonly) DTRenderMetadataDescriptor *metadata;
@property(nonatomic, readonly, copy) NSArray<DTTileUploadDescriptor *> *tiles;
- (instancetype)initWithMetadata:(DTRenderMetadataDescriptor *)metadata
                            tiles:(NSArray<DTTileUploadDescriptor *> *)tiles NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef void (^DTRasterCommitCompletion)(DTRasterCommitDescriptor * _Nullable commit,
                                         NSError * _Nullable error);
typedef void (^DTCheckpointCompletion)(DTCheckpointPayloadBatch * _Nullable payloads,
                                       NSError * _Nullable error);
typedef void (^DTRenderCommandCompletion)(NSError * _Nullable error);

/// Private queue boundary. Every method is enqueue-only; implementations must
/// retain/copy all Objective-C values before returning and must never retain a
/// pointer into Swift's temporary UnsafeBufferPointer storage.
@protocol DTRasterRenderSink <NSObject>
- (void)enqueueBeginStroke:(DTStrokeOperationDescriptor)operation;
- (void)enqueueSampleBatch:(DTSampleBatchDescriptor *)batch;
- (void)enqueueEstimatedSample:(DTPencilSample)sample
                         index:(uint64_t)estimationUpdateIndex
                     operation:(DTOperationIdentifier)operationID;
- (void)enqueueEndStroke:(DTOperationIdentifier)operationID
               completion:(DTRasterCommitCompletion)completion
                checkpoint:(DTCheckpointCompletion)checkpoint;
- (void)enqueueCancelStroke:(DTOperationIdentifier)operationID
                  completion:(DTRenderCommandCompletion)completion;
- (void)enqueueRestore:(DTRestoreOperationDescriptor *)restore
             completion:(DTRasterCommitCompletion)completion
              checkpoint:(DTCheckpointCompletion)checkpoint;
- (void)enqueueMetadataSnapshot:(DTRenderMetadataDescriptor *)metadata;
- (void)enqueueDocumentLoad:(DTDocumentLoadDescriptor *)load
                  completion:(DTRenderCommandCompletion)completion;
- (void)enqueueReleaseVersions:(NSArray<DTTileVersionDescriptor *> *)versions;
@end

/// Kept out of the public Swift-facing bridge API: renderer installation is an
/// implementation detail of DTMetalRenderer's existing initializer.
@interface DTEngineBridge (DTRendererContract)
- (void)dt_installRenderSink:(id<DTRasterRenderSink>)sink;
- (DTRenderMetadataDescriptor *)dt_renderMetadataSnapshot;
@end

FOUNDATION_EXPORT NSErrorDomain const DTRendererErrorDomain;

NS_ASSUME_NONNULL_END
