#import "DTEngineBridge.h"
#import "DTRendererContract.h"

#import <dispatch/dispatch.h>

#include "DTEngine.hpp"
#include "DTDocument.hpp"
#include "DTRasterTransaction.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

NSErrorDomain const DTRendererErrorDomain = @"com.local.draftingtable.renderer";

using drafting_table::CompletedRasterOperation;
using drafting_table::Document;
using drafting_table::Layer;
using drafting_table::LayerID;
using drafting_table::LayerMetadata;
using drafting_table::LayerMetadataSwap;
using drafting_table::LayerType;
using drafting_table::OperationID;
using drafting_table::OperationToken;
using drafting_table::Page;
using drafting_table::PageID;
using drafting_table::PencilSample;
using drafting_table::RasterTransactionCoordinator;
using drafting_table::RasterVersionSwap;
using drafting_table::RestorePlan;
using drafting_table::TileAddress;
using drafting_table::TileVersionRef;
using drafting_table::UndoDirection;
using drafting_table::UndoStatus;
using drafting_table::ipad::Engine;
using drafting_table::ipad::Stroke;

@implementation DTRenderStroke
- (instancetype)initWithPoints:(NSArray<NSValue *> *)points
                           tool:(DTTool)tool
                      brushSize:(CGFloat)brushSize
                    brushOpacity:(CGFloat)brushOpacity
                 brushColorRGBA:(uint32_t)brushColorRGBA
                  brushHardness:(CGFloat)brushHardness {
    if ((self = [super init])) {
        _points = [points copy]; _tool = tool; _brushSize = brushSize;
        _brushOpacity = brushOpacity; _brushColorRGBA = brushColorRGBA;
        _brushHardness = brushHardness;
    }
    return self;
}
@end

@implementation DTPageInfo
- (instancetype)initWithIndex:(NSUInteger)index pageID:(uint64_t)pageID name:(NSString *)name selected:(BOOL)selected {
    if ((self = [super init])) { _index = index; _pageID = pageID; _name = [name copy]; _selected = selected; }
    return self;
}
@end

@implementation DTLayerInfo
- (instancetype)initWithIndex:(NSUInteger)index layerID:(uint64_t)layerID kind:(DTLayerKind)kind name:(NSString *)name selected:(BOOL)selected visible:(BOOL)visible opacity:(CGFloat)opacity {
    if ((self = [super init])) {
        _index = index; _layerID = layerID; _kind = kind; _name = [name copy]; _selected = selected;
        _visible = visible; _opacity = opacity;
    }
    return self;
}
@end

@implementation DTSampleBatchDescriptor
- (instancetype)initWithOperationID:(DTOperationIdentifier)operationID sampleBytes:(NSData *)sampleBytes realCount:(NSUInteger)realCount {
    if ((self = [super init])) { _operationID = operationID; _sampleBytes = [sampleBytes copy]; _realCount = realCount; }
    return self;
}
@end

@implementation DTLayerRenderDescriptor
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID name:(NSString *)name visible:(BOOL)visible opacity:(float)opacity {
    if ((self = [super init])) { _layerID = layerID; _name = [name copy]; _visible = visible; _opacity = opacity; }
    return self;
}
@end

@implementation DTRenderMetadataDescriptor
- (instancetype)initWithPageID:(DTPageIdentifier)pageID generation:(DTDocumentGeneration)generation activeLayerID:(DTLayerIdentifier)activeLayerID pageWidth:(float)pageWidth pageHeight:(float)pageHeight layers:(NSArray<DTLayerRenderDescriptor *> *)layers {
    if ((self = [super init])) {
        _pageID = pageID; _generation = generation; _activeLayerID = activeLayerID;
        _pageWidth = pageWidth; _pageHeight = pageHeight; _layers = [layers copy];
    }
    return self;
}
@end

@implementation DTTileCommitDescriptor
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID coordinate:(DTTileCoordinate)coordinate beforeExists:(BOOL)beforeExists beforeGeneration:(DTDocumentGeneration)beforeGeneration afterExists:(BOOL)afterExists afterGeneration:(DTDocumentGeneration)afterGeneration afterVersionID:(uint64_t)afterVersionID {
    if ((self = [super init])) {
        _layerID = layerID; _coordinate = coordinate; _beforeExists = beforeExists;
        _beforeGeneration = beforeGeneration; _afterExists = afterExists;
        _afterGeneration = afterGeneration;
        _afterVersionID = afterVersionID;
    }
    return self;
}
@end

@implementation DTRasterCommitDescriptor
- (instancetype)initWithOperationID:(DTOperationIdentifier)operationID generation:(DTDocumentGeneration)generation pageID:(DTPageIdentifier)pageID tiles:(NSArray<DTTileCommitDescriptor *> *)tiles {
    if ((self = [super init])) { _operationID = operationID; _generation = generation; _pageID = pageID; _tiles = [tiles copy]; }
    return self;
}
@end

@implementation DTTileCheckpointPayload
- (instancetype)initWithPageID:(uint64_t)pageID layerID:(uint64_t)layerID tileX:(int32_t)tileX tileY:(int32_t)tileY exists:(BOOL)exists versionID:(uint64_t)versionID generation:(uint64_t)generation premultipliedRGBA8:(NSData *)premultipliedRGBA8 {
    if ((self = [super init])) {
        _pageID = pageID; _layerID = layerID; _tileX = tileX; _tileY = tileY;
        _exists = exists; _versionID = versionID; _generation = generation;
        _premultipliedRGBA8 = [premultipliedRGBA8 copy];
    }
    return self;
}
- (instancetype)initWithPageID:(uint64_t)pageID layerID:(uint64_t)layerID tileX:(int32_t)tileX tileY:(int32_t)tileY versionID:(uint64_t)versionID generation:(uint64_t)generation premultipliedRGBA8:(NSData *)premultipliedRGBA8 {
    return [self initWithPageID:pageID layerID:layerID tileX:tileX tileY:tileY exists:YES versionID:versionID generation:generation premultipliedRGBA8:premultipliedRGBA8];
}
@end

@implementation DTCheckpointPayloadBatch
- (instancetype)initWithOperationID:(DTOperationIdentifier)operationID generation:(DTDocumentGeneration)generation tiles:(NSArray<DTTileCheckpointPayload *> *)tiles {
    if ((self = [super init])) { _operationID = operationID; _generation = generation; _tiles = [tiles copy]; }
    return self;
}
@end

@implementation DTPersistedLayerDescriptor
- (instancetype)initWithLayerID:(uint64_t)layerID name:(NSString *)name visible:(BOOL)visible opacity:(CGFloat)opacity {
    if ((self = [super init])) { _layerID = layerID; _name = [name copy]; _visible = visible; _opacity = opacity; }
    return self;
}
@end

@implementation DTPersistedTileAcknowledgement
- (instancetype)initWithPageID:(uint64_t)pageID layerID:(uint64_t)layerID tileX:(int32_t)tileX tileY:(int32_t)tileY versionID:(uint64_t)versionID payloadID:(NSString *)payloadID {
    if ((self = [super init])) {
        _pageID = pageID; _layerID = layerID; _tileX = tileX; _tileY = tileY;
        _versionID = versionID; _payloadID = [payloadID copy];
    }
    return self;
}
@end

@implementation DTTileRestoreDescriptor
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID coordinate:(DTTileCoordinate)coordinate sourceExists:(BOOL)sourceExists sourceGeneration:(DTDocumentGeneration)sourceGeneration targetExists:(BOOL)targetExists targetVersionID:(uint64_t)targetVersionID {
    if ((self = [super init])) {
        _layerID = layerID; _coordinate = coordinate; _sourceExists = sourceExists;
        _sourceGeneration = sourceGeneration; _targetExists = targetExists;
        _targetVersionID = targetVersionID;
    }
    return self;
}
@end

@implementation DTRestoreOperationDescriptor
- (instancetype)initWithOperationID:(DTOperationIdentifier)operationID generation:(DTDocumentGeneration)generation pageID:(DTPageIdentifier)pageID tiles:(NSArray<DTTileRestoreDescriptor *> *)tiles {
    if ((self = [super init])) { _operationID = operationID; _generation = generation; _pageID = pageID; _tiles = [tiles copy]; }
    return self;
}
@end

@implementation DTTileVersionDescriptor
- (instancetype)initWithLayerID:(DTLayerIdentifier)layerID coordinate:(DTTileCoordinate)coordinate exists:(BOOL)exists generation:(DTDocumentGeneration)generation {
    if ((self = [super init])) { _layerID = layerID; _coordinate = coordinate; _exists = exists; _generation = generation; }
    return self;
}
@end

@implementation DTTileUploadDescriptor
- (instancetype)initWithPageID:(DTPageIdentifier)pageID layerID:(DTLayerIdentifier)layerID coordinate:(DTTileCoordinate)coordinate versionID:(uint64_t)versionID generation:(DTDocumentGeneration)generation premultipliedRGBA8:(NSData *)premultipliedRGBA8 {
    if ((self = [super init])) {
        _pageID = pageID; _layerID = layerID; _coordinate = coordinate;
        _versionID = versionID; _generation = generation;
        _premultipliedRGBA8 = [premultipliedRGBA8 copy];
    }
    return self;
}
@end

@implementation DTDocumentLoadDescriptor
- (instancetype)initWithMetadata:(DTRenderMetadataDescriptor *)metadata tiles:(NSArray<DTTileUploadDescriptor *> *)tiles {
    if ((self = [super init])) { _metadata = metadata; _tiles = [tiles copy]; }
    return self;
}
@end

namespace {
constexpr float kDefaultPageWidth = 1536.0f;
constexpr float kDefaultPageHeight = 2048.0f;
constexpr uint32_t kDefaultBrushColor = 0x2B2926FFu;
constexpr float kDefaultBrushHardness = 0.8f;
const void *kDocumentQueueSpecific = &kDocumentQueueSpecific;

DTPencilSample toBridgeSample(const PencilSample& input) {
    DTPencilSample sample{};
    sample.x = input.x; sample.y = input.y; sample.pressure = input.pressure;
    sample.altitude = input.altitude; sample.azimuth = input.azimuth;
    sample.roll = input.roll; sample.hoverDistance = input.hoverDistance;
    sample.timestamp = input.timestamp; sample.sampleID = input.id;
    sample.estimationUpdateIndex = input.estimationUpdateIndex;
    sample.flags = DTPencilSampleFlagReal;
    return sample;
}

struct RendererVersionSwap {
    PageID pageID{}; LayerID layerID{}; TileAddress tile{};
    bool beforeExists = false; uint64_t beforeGeneration = 0;
    bool afterExists = true; uint64_t afterGeneration = 0;
};

NSString *stringFromStd(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()] ?: @"";
}
} // namespace

@interface DTPendingSampleBatch : NSObject
@property(nonatomic, copy) NSData *bytes;
@property(nonatomic) NSUInteger realCount;
@end
@implementation DTPendingSampleBatch
@end

@interface DTPendingStrokeRequest : NSObject
@property(nonatomic) DTTool tool;
@property(nonatomic) float brushSize;
@property(nonatomic) float brushOpacity;
@property(nonatomic) float brushHardness;
@property(nonatomic) uint32_t brushColorRGBA;
@property(nonatomic) DTPageIdentifier pageID;
@property(nonatomic) DTLayerIdentifier layerID;
@property(nonatomic) DTStrokeOperationDescriptor operation;
@property(nonatomic) BOOL submitted;
@property(nonatomic) BOOL ended;
@property(nonatomic) BOOL endSent;
@property(nonatomic) NSUInteger realSampleCount;
@property(nonatomic, strong) NSMutableArray<DTPendingSampleBatch *> *batches;
@end
@implementation DTPendingStrokeRequest
- (instancetype)init { if ((self = [super init])) _batches = [NSMutableArray array]; return self; }
@end

typedef void (^DTLayerMetadataMutation)(LayerMetadata *metadata);

@interface DTEngineBridge ()
- (void)dt_syncDocument:(dispatch_block_t)block;
- (DTRenderMetadataDescriptor *)dt_renderMetadataSnapshotLocked;
- (void)dt_publishMetadataLocked;
- (void)dt_drainStrokeQueueLocked;
- (void)dt_sendEndForRequestLocked:(DTPendingStrokeRequest *)request;
- (void)dt_acceptRasterCommit:(DTRasterCommitDescriptor * _Nullable)commit error:(NSError * _Nullable)error;
- (void)dt_acceptRestoreCommit:(DTRasterCommitDescriptor * _Nullable)commit error:(NSError * _Nullable)error;
- (void)dt_acceptCheckpoint:(DTCheckpointPayloadBatch * _Nullable)payloads error:(NSError * _Nullable)error;
- (void)dt_submitRestorePlanLocked:(const RestorePlan&)plan;
- (void)dt_finishMetadataOnlyRestoreLocked:(const RestorePlan&)plan;
- (BOOL)dt_mutateLayerAtIndex:(NSUInteger)index mutate:(DTLayerMetadataMutation)mutation;
- (void)dt_notifyCommitLocked:(uint64_t)generation;
- (void)dt_notifyEmptyCheckpointLocked:(uint64_t)operationID generation:(uint64_t)generation;
- (void)dt_reportErrorLocked:(NSString *)message;
@end

@implementation DTEngineBridge {
    dispatch_queue_t _documentQueue;
    std::unique_ptr<Document> _document;
    std::unique_ptr<RasterTransactionCoordinator> _transactions;
    __weak id<DTRasterRenderSink> _renderSink;
    NSMutableArray<DTPendingStrokeRequest *> *_strokeQueue;
    DTPendingStrokeRequest *_inputStroke;
    DTCheckpointPayloadBatch *_lastCheckpointBatch;
    std::optional<RestorePlan> _activeRestore;
    std::unordered_map<OperationID, std::vector<RendererVersionSwap>> _rendererHistory;
    std::vector<OperationID> _historyOrder;
    std::size_t _historyCursor;
    NSUInteger _committedStrokeCount;
    NSUInteger _committedSampleCount;
    NSUInteger _layerOperationCounts[2];
    DTTool _tool;
    float _brushSize;
    float _brushOpacity;
    float _brushHardness;
    uint32_t _brushColorRGBA;
}

- (instancetype)init {
    if ((self = [super init])) {
        _documentQueue = dispatch_queue_create("com.local.draftingtable.document", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_documentQueue, kDocumentQueueSpecific, (__bridge void *)self, nullptr);
        _document = std::make_unique<Document>("Drafting Table");
        _transactions = std::make_unique<RasterTransactionCoordinator>();
        _strokeQueue = [NSMutableArray array];
        _tool = DTToolBrush; _brushSize = 8.0f; _brushOpacity = 1.0f;
        _brushHardness = kDefaultBrushHardness; _brushColorRGBA = kDefaultBrushColor;
        Page *page = _document->activePage();
        if (page) {
            page->setBounds({0.0f, 0.0f, kDefaultPageWidth, kDefaultPageHeight});
            if (Layer *base = page->layer(0)) base->setName("Raster 1");
            page->addLayer(LayerType::Raster, "Raster 2");
            for (const Layer& layer : page->layers())
                _transactions->seedLayerMetadata(page->id(), layer.metadata());
        }
    }
    return self;
}

- (void)dt_syncDocument:(dispatch_block_t)block {
    if (!block) return;
    if (dispatch_get_specific(kDocumentQueueSpecific) == (__bridge void *)self) block();
    else dispatch_sync(_documentQueue, block);
}

- (NSUInteger)strokeCount { __block NSUInteger v=0; [self dt_syncDocument:^{v=self->_committedStrokeCount;}]; return v; }
- (NSUInteger)sampleCount { __block NSUInteger v=0; [self dt_syncDocument:^{v=self->_committedSampleCount+(self->_inputStroke?self->_inputStroke.realSampleCount:0);}]; return v; }
- (uint64_t)revision { __block uint64_t v=0; [self dt_syncDocument:^{v=self->_transactions->currentGeneration();}]; return v; }
- (DTTool)tool { __block DTTool v=DTToolBrush; [self dt_syncDocument:^{v=self->_tool;}]; return v; }
- (void)setTool:(DTTool)tool { [self dt_syncDocument:^{self->_tool=tool;}]; }
- (CGFloat)brushSize { __block float v=8; [self dt_syncDocument:^{v=self->_brushSize;}]; return v; }
- (void)setBrushSize:(CGFloat)value { const float v=(float)value; [self dt_syncDocument:^{if(std::isfinite(v))self->_brushSize=std::clamp(v,.5f,512.f);}]; }
- (CGFloat)brushOpacity { __block float v=1; [self dt_syncDocument:^{v=self->_brushOpacity;}]; return v; }
- (void)setBrushOpacity:(CGFloat)value { const float v=(float)value; [self dt_syncDocument:^{if(std::isfinite(v))self->_brushOpacity=std::clamp(v,0.f,1.f);}]; }
- (uint32_t)brushColorRGBA { __block uint32_t v=kDefaultBrushColor; [self dt_syncDocument:^{v=self->_brushColorRGBA;}]; return v; }
- (void)setBrushColorRGBA:(uint32_t)value { [self dt_syncDocument:^{self->_brushColorRGBA=value;}]; }
- (CGFloat)brushHardness { __block float v=kDefaultBrushHardness; [self dt_syncDocument:^{v=self->_brushHardness;}]; return v; }
- (void)setBrushHardness:(CGFloat)value { const float v=(float)value; [self dt_syncDocument:^{if(std::isfinite(v))self->_brushHardness=std::clamp(v,0.f,1.f);}]; }

- (BOOL)canUndo { __block BOOL v=NO; [self dt_syncDocument:^{v=self->_inputStroke==nil&&self->_strokeQueue.count==0&&self->_transactions->canUndo();}]; return v; }
- (BOOL)canRedo { __block BOOL v=NO; [self dt_syncDocument:^{v=self->_inputStroke==nil&&self->_strokeQueue.count==0&&self->_transactions->canRedo();}]; return v; }
- (BOOL)isStrokeInProgress { __block BOOL v=NO; [self dt_syncDocument:^{v=self->_inputStroke!=nil;}]; return v; }
- (NSUInteger)activeLayerStrokeCount {
    __block NSUInteger v=0; [self dt_syncDocument:^{ Page *p=self->_document->activePage(); std::size_t i=p?p->activeLayerIndex():0; v=i<2?self->_layerOperationCounts[i]:0;}]; return v;
}
- (NSArray<DTPageInfo *> *)pageInfos { __block uint64_t pageID=0;[self dt_syncDocument:^{Page*p=self->_document->activePage();if(p)pageID=p->id().value;}];return @[[[DTPageInfo alloc] initWithIndex:0 pageID:pageID name:@"Page 1" selected:YES]]; }
- (NSArray<DTLayerInfo *> *)layerInfos {
    __block NSArray<DTLayerInfo *> *result=@[];
    [self dt_syncDocument:^{
        Page *page=self->_document->activePage(); if(!page)return;
        NSMutableArray *items=[NSMutableArray arrayWithCapacity:page->layerCount()];
        for(std::size_t i=0;i<page->layerCount();++i){const Layer *layer=page->layer(i);if(!layer)continue;
            [items addObject:[[DTLayerInfo alloc] initWithIndex:i layerID:layer->id().value kind:DTLayerKindRaster name:stringFromStd(layer->name()) selected:i==page->activeLayerIndex() visible:layer->visible() opacity:layer->opacity()]];}
        result=[items copy];
    }]; return result;
}

- (DTRenderMetadataDescriptor *)dt_renderMetadataSnapshotLocked {
    Page *page=_document->activePage();
    if(!page)return [[DTRenderMetadataDescriptor alloc] initWithPageID:0 generation:_transactions->currentGeneration() activeLayerID:0 pageWidth:kDefaultPageWidth pageHeight:kDefaultPageHeight layers:@[]];
    NSMutableArray *layers=[NSMutableArray arrayWithCapacity:page->layerCount()];
    for(const Layer& layer:page->layers()) [layers addObject:[[DTLayerRenderDescriptor alloc] initWithLayerID:layer.id().value name:stringFromStd(layer.name()) visible:layer.visible() opacity:layer.opacity()]];
    auto b=page->bounds();
    return [[DTRenderMetadataDescriptor alloc] initWithPageID:page->id().value generation:_transactions->currentGeneration() activeLayerID:page->activeLayer()?page->activeLayer()->id().value:0 pageWidth:std::max(1.f,b.x1-b.x0) pageHeight:std::max(1.f,b.y1-b.y0) layers:layers];
}
- (DTRenderMetadataDescriptor *)dt_renderMetadataSnapshot { __block DTRenderMetadataDescriptor *v=nil; [self dt_syncDocument:^{v=[self dt_renderMetadataSnapshotLocked];}]; return v; }
- (void)dt_publishMetadataLocked { id<DTRasterRenderSink>s=_renderSink;if(s)[s enqueueMetadataSnapshot:[self dt_renderMetadataSnapshotLocked]]; }
- (void)dt_installRenderSink:(id<DTRasterRenderSink>)sink { [self dt_syncDocument:^{self->_renderSink=sink;[sink enqueueMetadataSnapshot:[self dt_renderMetadataSnapshotLocked]];[self dt_drainStrokeQueueLocked];}]; }

- (void)beginStroke {
    [self dt_syncDocument:^{
        if(self->_tool!=DTToolBrush&&self->_tool!=DTToolEraser){self->_inputStroke=nil;return;}
        if(self->_inputStroke)[self cancelStroke];
        Page *page=self->_document->activePage();Layer *layer=page?page->activeLayer():nullptr;if(!page||!layer)return;
        DTPendingStrokeRequest *r=[DTPendingStrokeRequest new];r.tool=self->_tool;r.brushSize=self->_brushSize;r.brushOpacity=self->_brushOpacity;r.brushHardness=self->_brushHardness;r.brushColorRGBA=self->_brushColorRGBA;r.pageID=page->id().value;r.layerID=layer->id().value;
        [self->_strokeQueue addObject:r];self->_inputStroke=r;[self dt_drainStrokeQueueLocked];
    }];
}

- (void)appendSamples:(const DTPencilSample *)samples count:(NSUInteger)count realCount:(NSUInteger)realCount {
    if(!samples||count==0||realCount>count||count>NSUIntegerMax/sizeof(DTPencilSample))return;
    NSData *owned=[NSData dataWithBytes:samples length:count*sizeof(DTPencilSample)];
    [self dt_syncDocument:^{DTPendingStrokeRequest*r=self->_inputStroke;if(!r||r.ended)return;r.realSampleCount+=realCount;
        if(r.submitted){[self->_renderSink enqueueSampleBatch:[[DTSampleBatchDescriptor alloc] initWithOperationID:r.operation.operationID sampleBytes:owned realCount:realCount]];}
        else{DTPendingSampleBatch*b=[DTPendingSampleBatch new];b.bytes=owned;b.realCount=realCount;[r.batches addObject:b];}}];
}
- (BOOL)updateEstimatedSampleAtIndex:(uint64_t)index sample:(DTPencilSample)sample {
    __block BOOL ok=NO;[self dt_syncDocument:^{DTPendingStrokeRequest*r=self->_inputStroke;id<DTRasterRenderSink>s=self->_renderSink;if(r&&r.submitted&&!r.ended&&s){[s enqueueEstimatedSample:sample index:index operation:r.operation.operationID];ok=YES;}}];return ok;
}
- (void)endStroke { [self dt_syncDocument:^{DTPendingStrokeRequest*r=self->_inputStroke;if(!r||r.ended)return;r.ended=YES;self->_inputStroke=nil;[self dt_drainStrokeQueueLocked];}]; }
- (void)cancelStroke {
    [self dt_syncDocument:^{DTPendingStrokeRequest*r=self->_inputStroke;if(!r)return;self->_inputStroke=nil;NSUInteger i=[self->_strokeQueue indexOfObjectIdenticalTo:r];
        if(r.submitted){OperationToken token=r.operation.operationID&&self->_transactions->inFlight()?*self->_transactions->inFlight():OperationToken{};id<DTRasterRenderSink>s=self->_renderSink;__weak DTEngineBridge*w=self;[s enqueueCancelStroke:r.operation.operationID completion:^(NSError*e){if(e)[w dt_acceptRasterCommit:nil error:e];}];if(token.operationID==r.operation.operationID)self->_transactions->abort(token);}
        if(i!=NSNotFound)[self->_strokeQueue removeObjectAtIndex:i];[self dt_drainStrokeQueueLocked];}];
}

- (void)dt_drainStrokeQueueLocked {
    if(_strokeQueue.count==0||!_renderSink)return;
    DTPendingStrokeRequest*r=_strokeQueue.firstObject;
    if(!r.submitted){if(_transactions->hasInFlightOperation())return;auto token=_transactions->reserveRasterOperation();if(!token)return;r.operation={token->operationID,token->generation,r.pageID,r.layerID,r.tool,r.brushSize,r.brushOpacity,r.brushHardness,r.brushColorRGBA};r.submitted=YES;[_renderSink enqueueBeginStroke:r.operation];for(DTPendingSampleBatch*b in r.batches)[_renderSink enqueueSampleBatch:[[DTSampleBatchDescriptor alloc] initWithOperationID:token->operationID sampleBytes:b.bytes realCount:b.realCount]];[r.batches removeAllObjects];}
    if(r.ended&&!r.endSent)[self dt_sendEndForRequestLocked:r];
}
- (void)dt_sendEndForRequestLocked:(DTPendingStrokeRequest *)r {
    r.endSent=YES;DTOperationIdentifier op=r.operation.operationID;__weak DTEngineBridge*w=self;
    [_renderSink enqueueEndStroke:op completion:^(DTRasterCommitDescriptor*c,NSError*e){[w dt_acceptRasterCommit:c error:e];} checkpoint:^(DTCheckpointPayloadBatch*p,NSError*e){[w dt_acceptCheckpoint:p error:e];}];
}

- (void)dt_acceptRasterCommit:(DTRasterCommitDescriptor *)commit error:(NSError *)error {
    dispatch_async(_documentQueue,^{
        DTPendingStrokeRequest*r=self->_strokeQueue.firstObject;if(!r||!r.submitted){if(error)[self dt_reportErrorLocked:error.localizedDescription];return;}
        OperationToken token=r.operation.operationID&&self->_transactions->inFlight()?*self->_transactions->inFlight():OperationToken{};
        if(error||!commit||commit.operationID!=token.operationID||commit.generation!=token.generation||commit.tiles.count==0){if(token)self->_transactions->abort(token);[self->_strokeQueue removeObjectAtIndex:0];[self dt_reportErrorLocked:error.localizedDescription?:@"Metal stroke transaction failed"];[self dt_drainStrokeQueueLocked];return;}
        CompletedRasterOperation completion;completion.token=token;std::vector<RendererVersionSwap> versions;versions.reserve(commit.tiles.count);bool valid=true;
        for(DTTileCommitDescriptor*t in commit.tiles){TileAddress address{t.coordinate.x,t.coordinate.y};PageID pageID{commit.pageID};LayerID layerID{t.layerID};TileVersionRef before;before.address=address;
            if(const TileVersionRef*current=self->_transactions->currentTileVersion(pageID,layerID,address)){before=*current;valid=valid&&t.beforeExists&&t.beforeGeneration==current->contentGeneration;}else valid=valid&&!t.beforeExists;
            if(!t.afterExists||t.afterGeneration!=token.generation||t.afterVersionID==0)valid=false;TileVersionRef after;after.address=address;after.versionID=t.afterVersionID;after.contentGeneration=token.generation;completion.tileSwaps.push_back({pageID,layerID,before,after});versions.push_back({pageID,layerID,address,(bool)t.beforeExists,t.beforeGeneration,true,t.afterGeneration});}
        if(!valid||!self->_transactions->commit(completion)){[self->_strokeQueue removeObjectAtIndex:0];[self dt_reportErrorLocked:@"Renderer completion did not match the reserved document transaction"];[self dt_drainStrokeQueueLocked];return;}
        NSMutableArray*release=[NSMutableArray array];if(self->_historyCursor<self->_historyOrder.size()){for(std::size_t i=self->_historyCursor;i<self->_historyOrder.size();++i){auto found=self->_rendererHistory.find(self->_historyOrder[i]);if(found==self->_rendererHistory.end())continue;for(const auto&old:found->second)if(old.afterExists)[release addObject:[[DTTileVersionDescriptor alloc] initWithLayerID:old.layerID.value coordinate:(DTTileCoordinate){old.tile.x,old.tile.y} exists:YES generation:old.afterGeneration]];self->_rendererHistory.erase(found);}self->_historyOrder.resize(self->_historyCursor);}if([release count]) [self->_renderSink enqueueReleaseVersions:release];
        self->_rendererHistory[token.operationID]=std::move(versions);self->_historyOrder.push_back(token.operationID);self->_historyCursor=self->_historyOrder.size();Page*page=self->_document->pageByID(PageID{commit.pageID});for(const auto&swap:completion.tileSwaps)if(page)if(Layer*layer=page->layerByID(swap.layerID))layer->setTileVersion(swap.after);self->_document->setGeneration(token.generation);self->_committedStrokeCount++;self->_committedSampleCount+=r.realSampleCount;
        if(page)for(std::size_t i=0;i<page->layerCount()&&i<2;++i)if(page->layer(i)&&page->layer(i)->id().value==r.layerID)self->_layerOperationCounts[i]++;
        [self->_strokeQueue removeObjectAtIndex:0];[self dt_notifyCommitLocked:token.generation];auto queued=self->_transactions->processQueuedUndo();if(queued.status==UndoStatus::Applied&&queued.plan)[self dt_submitRestorePlanLocked:*queued.plan];else[self dt_drainStrokeQueueLocked];
    });
}
- (void)dt_acceptCheckpoint:(DTCheckpointPayloadBatch *)payloads error:(NSError *)error { dispatch_async(_documentQueue,^{if(error){[self dt_reportErrorLocked:error.localizedDescription];return;}self->_lastCheckpointBatch=payloads;void(^handler)(DTCheckpointPayloadBatch*)=self.checkpointPayloadHandler;if(handler&&payloads)dispatch_async(dispatch_get_main_queue(),^{handler(payloads);});}); }

- (BOOL)undoLastStroke { __block BOOL ok=NO;[self dt_syncDocument:^{auto r=self->_transactions->requestUndo();ok=r.status==UndoStatus::Applied||r.status==UndoStatus::Queued;if(r.status==UndoStatus::Applied&&r.plan)[self dt_submitRestorePlanLocked:*r.plan];}];return ok; }
- (BOOL)redoLastStroke { __block BOOL ok=NO;[self dt_syncDocument:^{auto r=self->_transactions->requestRedo();ok=r.status==UndoStatus::Applied||r.status==UndoStatus::Queued;if(r.status==UndoStatus::Applied&&r.plan)[self dt_submitRestorePlanLocked:*r.plan];}];return ok; }

- (void)dt_submitRestorePlanLocked:(const RestorePlan&)plan {
    _activeRestore=plan;if(plan.tileSwaps.empty()){[self dt_finishMetadataOnlyRestoreLocked:plan];return;}auto history=_rendererHistory.find(plan.sourceOperationID);
    if(history==_rendererHistory.end()||!_renderSink){_transactions->completeRestore(plan,false);_activeRestore.reset();[self dt_reportErrorLocked:@"Undo source is no longer resident in renderer history"];[self dt_drainStrokeQueueLocked];return;}
    NSMutableArray*tiles=[NSMutableArray arrayWithCapacity:plan.tileSwaps.size()];
    for(const auto&swap:plan.tileSwaps){auto match=std::find_if(history->second.begin(),history->second.end(),[&](const RendererVersionSwap&v){return v.layerID==swap.layerID&&v.tile==swap.before.address;});if(match==history->second.end()){_transactions->completeRestore(plan,false);_activeRestore.reset();[self dt_reportErrorLocked:@"Undo tile does not match renderer history"];return;}bool undo=plan.direction==UndoDirection::Undo;bool exists=undo?match->beforeExists:match->afterExists;uint64_t generation=undo?match->beforeGeneration:match->afterGeneration;[tiles addObject:[[DTTileRestoreDescriptor alloc] initWithLayerID:swap.layerID.value coordinate:(DTTileCoordinate){swap.before.address.x,swap.before.address.y} sourceExists:exists sourceGeneration:generation targetExists:swap.after.hasVersion() targetVersionID:swap.after.versionID]];}
    DTRestoreOperationDescriptor*d=[[DTRestoreOperationDescriptor alloc] initWithOperationID:plan.token.operationID generation:plan.token.generation pageID:plan.tileSwaps.front().pageID.value tiles:tiles];__weak DTEngineBridge*w=self;[_renderSink enqueueRestore:d completion:^(DTRasterCommitDescriptor*c,NSError*e){[w dt_acceptRestoreCommit:c error:e];} checkpoint:^(DTCheckpointPayloadBatch*p,NSError*e){[w dt_acceptCheckpoint:p error:e];}];
}
- (void)dt_acceptRestoreCommit:(DTRasterCommitDescriptor *)commit error:(NSError *)error {
    dispatch_async(_documentQueue,^{if(!self->_activeRestore)return;RestorePlan plan=*self->_activeRestore;bool success=!error&&commit&&commit.operationID==plan.token.operationID&&commit.generation==plan.token.generation;
        if(!self->_transactions->completeRestore(plan,success))[self dt_reportErrorLocked:@"Core rejected completed undo/redo"];else if(success){for(const auto&swap:plan.tileSwaps)if(Page*p=self->_document->pageByID(swap.pageID))if(Layer*l=p->layerByID(swap.layerID)){if(swap.after.hasVersion())l->setTileVersion(swap.after);else l->eraseTileVersion(swap.after.address);}for(const auto&swap:plan.metadataSwaps)if(Page*p=self->_document->pageByID(swap.pageID))if(Layer*l=p->layerByID(swap.layerID))l->applyMetadata(swap.after);self->_document->setGeneration(plan.token.generation);if(plan.direction==UndoDirection::Undo){if(self->_historyCursor)--self->_historyCursor;if(self->_committedStrokeCount)--self->_committedStrokeCount;}else{self->_historyCursor=std::min(self->_historyCursor+1,self->_historyOrder.size());self->_committedStrokeCount++;}[self dt_publishMetadataLocked];[self dt_notifyCommitLocked:plan.token.generation];}else [self dt_reportErrorLocked:error.localizedDescription?:@"Metal undo/redo failed"];
        self->_activeRestore.reset();auto queued=self->_transactions->processQueuedUndo();if(queued.status==UndoStatus::Applied&&queued.plan)[self dt_submitRestorePlanLocked:*queued.plan];else[self dt_drainStrokeQueueLocked];});
}
- (void)dt_finishMetadataOnlyRestoreLocked:(const RestorePlan&)plan {
    if(!_transactions->completeRestore(plan,true)){[self dt_reportErrorLocked:@"Core rejected metadata undo/redo"];_activeRestore.reset();return;}for(const auto&swap:plan.metadataSwaps)if(Page*p=_document->pageByID(swap.pageID))if(Layer*l=p->layerByID(swap.layerID))l->applyMetadata(swap.after);_document->setGeneration(plan.token.generation);if(plan.direction==UndoDirection::Undo){if(_historyCursor)--_historyCursor;}else _historyCursor=std::min(_historyCursor+1,_historyOrder.size());[self dt_publishMetadataLocked];[self dt_notifyCommitLocked:plan.token.generation];[self dt_notifyEmptyCheckpointLocked:plan.token.operationID generation:plan.token.generation];_activeRestore.reset();[self dt_drainStrokeQueueLocked];
}

- (BOOL)dt_mutateLayerAtIndex:(NSUInteger)index mutate:(DTLayerMetadataMutation)mutation {
    __block BOOL result=NO;[self dt_syncDocument:^{if(!mutation||!self->_transactions->idle())return;Page*p=self->_document->activePage();Layer*l=p?p->layer(index):nullptr;if(!p||!l)return;LayerMetadata before=l->metadata(),after=before;mutation(&after);after.opacity=std::clamp(after.opacity,0.f,1.f);if(after==before){result=YES;return;}auto token=self->_transactions->reserveLayerMetadataOperation();if(!token)return;LayerMetadataSwap swap{p->id(),l->id(),before,after};if(!self->_transactions->commitLayerMetadataOperation(*token,std::span<const LayerMetadataSwap>(&swap,1))||!l->applyMetadata(after)){if(self->_transactions->inFlight())self->_transactions->abort(*token);return;}self->_document->setGeneration(token->generation);if(self->_historyCursor<self->_historyOrder.size())self->_historyOrder.resize(self->_historyCursor);self->_historyOrder.push_back(token->operationID);self->_historyCursor=self->_historyOrder.size();[self dt_publishMetadataLocked];[self dt_notifyCommitLocked:token->generation];[self dt_notifyEmptyCheckpointLocked:token->operationID generation:token->generation];result=YES;}];return result;
}

- (BOOL)setActivePageIndex:(NSUInteger)i{return i==0;}- (BOOL)selectPageAtIndex:(NSUInteger)i{return [self setActivePageIndex:i];}
- (BOOL)addPageWithName:(NSString*)n{(void)n;return NO;}- (NSUInteger)addPage{return NSNotFound;}- (BOOL)deletePageAtIndex:(NSUInteger)i{(void)i;return NO;}- (NSUInteger)duplicatePageAtIndex:(NSUInteger)i{(void)i;return NSNotFound;}- (BOOL)movePageAtIndex:(NSUInteger)a toIndex:(NSUInteger)b{(void)a;(void)b;return NO;}- (BOOL)renamePageAtIndex:(NSUInteger)i toName:(NSString*)n{(void)i;(void)n;return NO;}- (BOOL)renamePageAtIndex:(NSUInteger)i name:(NSString*)n{(void)i;(void)n;return NO;}
- (BOOL)setActiveLayerIndex:(NSUInteger)i{__block BOOL ok=NO;[self dt_syncDocument:^{Page*p=self->_document->activePage();ok=p&&i<2&&p->setActiveLayer(i);if(ok)[self dt_publishMetadataLocked];}];return ok;}- (BOOL)selectLayerAtIndex:(NSUInteger)i{return [self setActiveLayerIndex:i];}
- (BOOL)addLayerWithName:(NSString*)n{(void)n;return NO;}- (NSUInteger)addLayer{return NSNotFound;}- (BOOL)deleteLayerAtIndex:(NSUInteger)i{(void)i;return NO;}- (NSUInteger)duplicateLayerAtIndex:(NSUInteger)i{(void)i;return NSNotFound;}- (BOOL)moveLayerAtIndex:(NSUInteger)a toIndex:(NSUInteger)b{(void)a;(void)b;return NO;}
- (BOOL)renameLayerAtIndex:(NSUInteger)i toName:(NSString*)n{return [self renameLayerAtIndex:i name:n];}
- (BOOL)renameLayerAtIndex:(NSUInteger)i name:(NSString*)n{if(!n.length)return NO;std::string value(n.UTF8String?:"");return[self dt_mutateLayerAtIndex:i mutate:^(LayerMetadata*m){m->name=value;}];}
- (BOOL)setLayerVisible:(BOOL)v atIndex:(NSUInteger)i{return[self dt_mutateLayerAtIndex:i mutate:^(LayerMetadata*m){m->visible=v;}];}
- (BOOL)setLayerOpacity:(CGFloat)o atIndex:(NSUInteger)i{if(!std::isfinite((double)o))return NO;float v=std::clamp((float)o,0.f,1.f);return[self dt_mutateLayerAtIndex:i mutate:^(LayerMetadata*m){m->opacity=v;}];}
- (BOOL)setActiveLayerVisible:(BOOL)v{__block NSUInteger i=NSNotFound;[self dt_syncDocument:^{Page*p=self->_document->activePage();if(p)i=p->activeLayerIndex();}];return i!=NSNotFound&&[self setLayerVisible:v atIndex:i];}
- (BOOL)setActiveLayerOpacity:(CGFloat)o{__block NSUInteger i=NSNotFound;[self dt_syncDocument:^{Page*p=self->_document->activePage();if(p)i=p->activeLayerIndex();}];return i!=NSNotFound&&[self setLayerOpacity:o atIndex:i];}

- (BOOL)acknowledgePersistedOperationID:(uint64_t)operationID generation:(uint64_t)generation tiles:(NSArray<DTPersistedTileAcknowledgement *> *)tiles {
    __block BOOL accepted=NO;
    [self dt_syncDocument:^{
        if(!operationID||!generation)return;
        std::vector<drafting_table::PersistedTileBinding> bindings;bindings.reserve(tiles.count);
        for(DTPersistedTileAcknowledgement*item in tiles){if(!item.pageID||!item.layerID||!item.versionID||!item.payloadID.length)return;drafting_table::PersistedTileBinding b;b.pageID=PageID{item.pageID};b.layerID=LayerID{item.layerID};b.address={item.tileX,item.tileY};b.versionID=item.versionID;b.payloadID=std::string(item.payloadID.UTF8String?:"");bindings.push_back(std::move(b));}
        const std::span<const drafting_table::PersistedTileBinding> bindingSpan(bindings.data(),bindings.size());
        if(!self->_transactions->acknowledgePersistence(operationID,generation,bindingSpan))return;
        for(DTPersistedTileAcknowledgement*item in tiles){Page*p=self->_document->pageByID(PageID{item.pageID});Layer*l=p?p->layerByID(LayerID{item.layerID}):nullptr;TileVersionRef*v=l?l->findTileVersion({item.tileX,item.tileY}):nullptr;if(v&&v->versionID==item.versionID&&v->contentGeneration==generation){v->persistedGeneration=generation;v->payloadID=std::string(item.payloadID.UTF8String?:"");}}
        if(self->_lastCheckpointBatch.operationID==operationID)self->_lastCheckpointBatch=nil;accepted=YES;
    }];return accepted;
}

- (void)loadPackagePageWithID:(uint64_t)pageID generation:(uint64_t)generation width:(CGFloat)width height:(CGFloat)height layers:(NSArray<DTPersistedLayerDescriptor *> *)layers tiles:(NSArray<DTTileCheckpointPayload *> *)tiles completion:(void (^)(BOOL, NSString * _Nullable))completion {
    void(^done)(BOOL,NSString*)=[completion copy];
    dispatch_async(_documentQueue,^{
        NSString*validation=nil;
        if(!pageID||!generation||generation==UINT64_MAX||layers.count!=2||!std::isfinite((double)width)||!std::isfinite((double)height)||width<1||height<1)validation=@"A package page requires valid dimensions, generation, and exactly two raster layers";
        if(self->_transactions->hasInFlightOperation()||self->_strokeQueue.count)validation=@"Cannot load a package while a renderer transaction is active";
        if(layers.count==2&&(layers[0].layerID==0||layers[1].layerID==0||layers[0].layerID==layers[1].layerID))validation=@"Persisted layer IDs must be nonzero and distinct";
        for(DTTileCheckpointPayload*t in tiles){if(!t.exists||t.pageID!=pageID||!t.layerID||!t.versionID||!t.generation||t.generation>generation||t.premultipliedRGBA8.length!=drafting_table::kRasterTileBytes){validation=@"Persisted tile metadata or RGBA8 byte length is invalid";break;}if(t.layerID!=layers[0].layerID&&t.layerID!=layers[1].layerID){validation=@"Persisted tile references an unknown v0.1 layer";break;}}
        if(validation||!self->_renderSink){NSString*message=validation?:@"Metal renderer is not installed";if(done)dispatch_async(dispatch_get_main_queue(),^{done(NO,message);});return;}
        NSMutableArray*renderLayers=[NSMutableArray arrayWithCapacity:2];for(DTPersistedLayerDescriptor*l in layers)[renderLayers addObject:[[DTLayerRenderDescriptor alloc] initWithLayerID:l.layerID name:l.name visible:l.visible opacity:std::clamp((float)l.opacity,0.f,1.f)]];
        DTRenderMetadataDescriptor*metadata=[[DTRenderMetadataDescriptor alloc] initWithPageID:pageID generation:generation activeLayerID:layers[1].layerID pageWidth:(float)width pageHeight:(float)height layers:renderLayers];
        NSMutableArray*uploads=[NSMutableArray arrayWithCapacity:tiles.count];for(DTTileCheckpointPayload*t in tiles)[uploads addObject:[[DTTileUploadDescriptor alloc] initWithPageID:t.pageID layerID:t.layerID coordinate:(DTTileCoordinate){t.tileX,t.tileY} versionID:t.versionID generation:t.generation premultipliedRGBA8:t.premultipliedRGBA8]];
        DTDocumentLoadDescriptor*load=[[DTDocumentLoadDescriptor alloc] initWithMetadata:metadata tiles:uploads];__weak DTEngineBridge*w=self;
        [self->_renderSink enqueueDocumentLoad:load completion:^(NSError*error){DTEngineBridge*s=w;if(!s)return;dispatch_async(s->_documentQueue,^{if(error){[s dt_reportErrorLocked:error.localizedDescription];if(done)dispatch_async(dispatch_get_main_queue(),^{done(NO,error.localizedDescription);});return;}
                auto document=std::make_unique<Document>("Drafting Table");Page*p=document->activePage();p->setID(PageID{pageID});p->setBounds({0,0,(float)width,(float)height});Layer*first=p->layer(0);first->setID(LayerID{layers[0].layerID});first->setName(std::string(layers[0].name.UTF8String?:"Raster 1"));first->setVisible(layers[0].visible);first->setOpacity((float)layers[0].opacity);p->addLayer(LayerType::Raster,std::string(layers[1].name.UTF8String?:"Raster 2"),LayerID{layers[1].layerID});first=p->layer(0);Layer*second=p->layer(1);second->setVisible(layers[1].visible);second->setOpacity((float)layers[1].opacity);document->setGeneration(generation);
                auto coordinator=std::make_unique<RasterTransactionCoordinator>(generation+1);coordinator->seedLayerMetadata(p->id(),first->metadata());coordinator->seedLayerMetadata(p->id(),second->metadata());bool seeded=true;for(DTTileCheckpointPayload*t in tiles){TileVersionRef ref;ref.address={t.tileX,t.tileY};ref.versionID=t.versionID;ref.contentGeneration=t.generation;ref.persistedGeneration=t.generation;ref.payloadID="package:"+std::to_string(t.versionID);Layer*l=p->layerByID(LayerID{t.layerID});seeded=seeded&&l&&l->setTileVersion(ref)&&coordinator->seedTileVersion(p->id(),l->id(),ref);}if(!seeded){if(done)dispatch_async(dispatch_get_main_queue(),^{done(NO,@"Core rejected persisted tile metadata");});return;}
                s->_document=std::move(document);s->_transactions=std::move(coordinator);s->_rendererHistory.clear();s->_historyOrder.clear();s->_historyCursor=0;s->_committedStrokeCount=tiles.count?1:0;s->_committedSampleCount=0;s->_layerOperationCounts[0]=s->_layerOperationCounts[1]=0;s->_lastCheckpointBatch=nil;[s dt_publishMetadataLocked];if(done)dispatch_async(dispatch_get_main_queue(),^{done(YES,nil);});});}];
    });
}

- (void)clearCanvas{[self dt_syncDocument:^{[self dt_reportErrorLocked:@"Clear is disabled in the narrow v0.1 renderer; use undo"];}];}
- (BOOL)moveStrokesWithIndices:(NSArray<NSNumber*>*)a dx:(CGFloat)b dy:(CGFloat)c{(void)a;(void)b;(void)c;return NO;}
- (BOOL)scaleStrokesWithIndices:(NSArray<NSNumber*>*)a sx:(CGFloat)b sy:(CGFloat)c originX:(CGFloat)d originY:(CGFloat)e{(void)a;(void)b;(void)c;(void)d;(void)e;return NO;}
- (BOOL)rotateStrokesWithIndices:(NSArray<NSNumber*>*)a angle:(CGFloat)b originX:(CGFloat)c originY:(CGFloat)d{(void)a;(void)b;(void)c;(void)d;return NO;}
- (BOOL)deleteStrokesWithIndices:(NSArray<NSNumber*>*)a{(void)a;return NO;}- (BOOL)duplicateStrokesWithIndices:(NSArray<NSNumber*>*)a dx:(CGFloat)b dy:(CGFloat)c{(void)a;(void)b;(void)c;return NO;}
- (NSInteger)hitTestStrokeAtX:(CGFloat)a y:(CGFloat)b tolerance:(CGFloat)c{(void)a;(void)b;(void)c;return -1;}
- (BOOL)insertPoints:(NSArray<NSValue*>*)a tool:(DTTool)b brushSize:(CGFloat)c brushOpacity:(CGFloat)d brushColorRGBA:(uint32_t)e brushHardness:(CGFloat)f{(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;return NO;}

- (NSData*)archiveData{return [NSData data];}
- (BOOL)loadArchiveData:(NSData*)data {
    if(!data.length)return NO;Engine importer;const auto*bytes=(const uint8_t*)data.bytes;if(!importer.loadArchive(std::span<const uint8_t>(bytes,data.length)))return NO;auto strokes=importer.snapshotForPage(importer.activePageIndex());__block BOOL accepted=NO;
    [self dt_syncDocument:^{if(self->_committedStrokeCount||!self->_transactions->idle())return;Page*p=self->_document->activePage();Layer*l=p?p->activeLayer():nullptr;if(!p||!l)return;for(const Stroke&s:strokes){if(s.tool!=drafting_table::ipad::DTTool::Brush&&s.tool!=drafting_table::ipad::DTTool::Eraser)continue;DTPendingStrokeRequest*r=[DTPendingStrokeRequest new];r.tool=s.tool==drafting_table::ipad::DTTool::Eraser?DTToolEraser:DTToolBrush;r.brushSize=s.brushSize;r.brushOpacity=s.brushOpacity;r.brushHardness=s.brushHardness;r.brushColorRGBA=s.brushColorRGBA;r.pageID=p->id().value;r.layerID=l->id().value;r.ended=YES;r.realSampleCount=s.points.size();std::vector<DTPencilSample> converted;converted.reserve(s.points.size());for(const auto&point:s.points)converted.push_back(toBridgeSample(point));if(!converted.empty()){DTPendingSampleBatch*b=[DTPendingSampleBatch new];b.bytes=[NSData dataWithBytes:converted.data() length:converted.size()*sizeof(DTPencilSample)];b.realCount=converted.size();[r.batches addObject:b];[self->_strokeQueue addObject:r];}}accepted=self->_strokeQueue.count!=0;[self dt_drainStrokeQueueLocked];}];return accepted;
}
- (NSArray<DTRenderStroke*>*)renderableStrokes{return @[];}- (NSArray<DTRenderStroke*>*)renderableStrokesForPageAtIndex:(NSUInteger)i{(void)i;return @[];}

- (void)dt_notifyCommitLocked:(uint64_t)generation{void(^h)(uint64_t)=self.documentCommitHandler;if(h)dispatch_async(dispatch_get_main_queue(),^{h(generation);});}
- (void)dt_notifyEmptyCheckpointLocked:(uint64_t)operationID generation:(uint64_t)generation{void(^h)(DTCheckpointPayloadBatch*)=self.checkpointPayloadHandler;if(!h)return;DTCheckpointPayloadBatch*batch=[[DTCheckpointPayloadBatch alloc] initWithOperationID:operationID generation:generation tiles:@[]];self->_lastCheckpointBatch=batch;dispatch_async(dispatch_get_main_queue(),^{h(batch);});}
- (void)dt_reportErrorLocked:(NSString*)message{if(!message.length)return;NSLog(@"DraftingTable renderer: %@",message);void(^h)(NSString*)=self.rendererErrorHandler;if(h){NSString*owned=[message copy];dispatch_async(dispatch_get_main_queue(),^{h(owned);});}}
@end
