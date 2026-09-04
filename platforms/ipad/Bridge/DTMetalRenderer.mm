#import "DTMetalRenderer.h"
#import "DTRendererContract.h"

#import <Metal/Metal.h>
#import <simd/simd.h>

#include "BrushEmitter.hpp"
#include "DTMetalTileRenderer.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <optional>
#include <span>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

using drafting_table::PencilSample;
using drafting_table::SampleFlags;
using drafting_table::TileAddress;
using drafting_table::Vec2;
using drafting_table::metal::Backend;
using drafting_table::metal::BackendResult;
using drafting_table::metal::CheckpointTicket;
using drafting_table::metal::DabBlendMode;
using drafting_table::metal::DabInstance;
using drafting_table::metal::PremultipliedColor;
using drafting_table::metal::TileDabBatch;
using drafting_table::metal::TileVersionRef;
using drafting_table::renderer::BrushEmitter;
using drafting_table::renderer::BrushSettings;
using drafting_table::renderer::Dab;

namespace {

constexpr NSUInteger kMaxResidentTilesPerLayer = 512;
constexpr NSUInteger kTileBytes = drafting_table::metal::kTileInteriorRGBABytes;
const void *kRenderQueueSpecific = &kRenderQueueSpecific;

struct DTOverlayVertex {
    vector_float2 documentPosition;
    vector_float4 premultipliedColor;
};

struct DTOverlayUniforms {
    vector_float2 viewportSize;
    float scale;
    float rotation;
    vector_float2 translation;
    vector_float2 reserved;
};

struct LayerMetadataValue {
    uint64_t layerID = 0;
    bool visible = true;
    float opacity = 1.0f;
};

struct MetadataValue {
    uint64_t pageID = 0;
    uint64_t generation = 0;
    uint64_t activeLayerID = 0;
    float pageWidth = 1536.0f;
    float pageHeight = 2048.0f;
    std::vector<LayerMetadataValue> layers;
};

struct LayerGPUState {
    std::unique_ptr<Backend> backend;
    std::unordered_set<std::int64_t> resident;
};

struct ActiveStroke {
    DTStrokeOperationDescriptor descriptor{};
    BrushEmitter emitter{};
    std::unordered_set<std::int64_t> touched;
    bool transactionBegun = false;

    ActiveStroke(DTStrokeOperationDescriptor value, float pageWidth, float pageHeight)
        : descriptor(value) {
        BrushSettings settings;
        const float radius = std::max(0.25f, value.brushSize * 0.5f);
        settings.minRadius = std::max(0.15f, radius * 0.20f);
        settings.maxRadius = radius;
        settings.spacingFraction = 0.18f;
        settings.minimumSpacing = 0.40f;
        emitter.setSettings(settings);
        drafting_table::renderer::StrokeBounds clip;
        clip.valid = true;
        clip.min = {0.0f, 0.0f};
        clip.max = {std::max(1.0f, pageWidth), std::max(1.0f, pageHeight)};
        emitter.emitter().setClipBounds(clip);
    }
};

struct RendererState {
    MetadataValue metadata;
    std::unordered_map<uint64_t, LayerGPUState> layers;
    std::optional<ActiveStroke> stroke;
    uint64_t nextVersionID = 1;
    float scale = 1.0f;
    float rotation = 0.0f;
    float translationX = 0.0f;
    float translationY = 0.0f;
    bool gridVisible = false;
    float gridSpacing = 32.0f;
    bool pixelGridVisible = false;
    bool centerMode = false;
    std::atomic<NSUInteger> frameCount{0};
};

struct PreparedBatches {
    std::unordered_map<std::int64_t, std::vector<DabInstance>> instances;
    std::vector<TileAddress> addresses;
    std::vector<TileDabBatch> batches;

    void finalize() {
        addresses.clear();
        batches.clear();
        addresses.reserve(instances.size());
        batches.reserve(instances.size());
        for (auto& entry : instances) {
            const TileAddress address = TileAddress::fromKey(entry.first);
            addresses.push_back(address);
            batches.push_back({address, std::span<const DabInstance>(entry.second)});
        }
    }
};

struct RestoreItemValue {
    uint64_t layerID = 0;
    TileAddress tile{};
    bool sourceExists = false;
    uint64_t sourceGeneration = 0;
    bool targetExists = false;
    uint64_t targetVersionID = 0;
};

struct RestoreLayerWork {
    uint64_t layerID = 0;
    std::vector<RestoreItemValue> items;
    std::vector<CheckpointTicket> tickets;
};

static NSError *DTMakeRendererError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:DTRendererErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Metal renderer error"}];
}

static float DTClamp01(float value) {
    return std::isfinite(value) ? std::clamp(value, 0.0f, 1.0f) : 0.0f;
}

static PremultipliedColor DTPremultipliedColor(uint32_t rgba, bool eraser) {
    if (eraser) return {0.0f, 0.0f, 0.0f, 1.0f};
    const float alpha = ((rgba & 0xffu) / 255.0f);
    const float red = ((rgba >> 24) & 0xffu) / 255.0f;
    const float green = ((rgba >> 16) & 0xffu) / 255.0f;
    const float blue = ((rgba >> 8) & 0xffu) / 255.0f;
    return {red * alpha, green * alpha, blue * alpha, alpha};
}

static PencilSample DTCoreSample(DTPencilSample sample) {
    PencilSample result;
    result.x = sample.x;
    result.y = sample.y;
    result.pressure = sample.pressure;
    result.altitude = sample.altitude;
    result.azimuth = sample.azimuth;
    result.roll = sample.roll;
    result.hoverDistance = sample.hoverDistance;
    result.timestamp = sample.timestamp;
    result.id = sample.sampleID;
    result.estimationUpdateIndex = sample.estimationUpdateIndex;
    result.flags = static_cast<SampleFlags>(sample.flags);
    return result;
}

static PreparedBatches DTPrepareBatches(std::span<const Dab> dabs,
                                        DTStrokeOperationDescriptor descriptor) {
    PreparedBatches prepared;
    const bool eraser = descriptor.tool == DTToolEraser;
    const PremultipliedColor color = DTPremultipliedColor(descriptor.brushColorRGBA,
                                                          eraser);
    for (const Dab& dab : dabs) {
        drafting_table::renderer::StrokeBounds bounds;
        bounds.include(dab);
        const auto tiles = drafting_table::renderer::touchedTiles(bounds);
        for (const TileAddress tile : tiles) {
            const Vec2 local = drafting_table::metal::TileLayout::localPoint(
                tile, dab.footprint.center);
            prepared.instances[tile.key()].emplace_back(
                local,
                Vec2{dab.footprint.radiusX, dab.footprint.radiusY},
                dab.footprint.rotationRadians,
                DTClamp01(descriptor.brushOpacity),
                DTClamp01(descriptor.brushHardness),
                color);
        }
    }
    prepared.finalize();
    return prepared;
}

static void DTAppendQuad(std::vector<DTOverlayVertex>& vertices,
                         float x0, float y0, float x1, float y1,
                         vector_float4 color) {
    vertices.push_back({{x0, y0}, color});
    vertices.push_back({{x1, y0}, color});
    vertices.push_back({{x0, y1}, color});
    vertices.push_back({{x0, y1}, color});
    vertices.push_back({{x1, y0}, color});
    vertices.push_back({{x1, y1}, color});
}

static void DTAppendLine(std::vector<DTOverlayVertex>& vertices,
                         float x0, float y0, float x1, float y1,
                         float width, vector_float4 color) {
    if (std::fabs(x1 - x0) < std::fabs(y1 - y0)) {
        DTAppendQuad(vertices, x0 - width * 0.5f, y0,
                     x0 + width * 0.5f, y1, color);
    } else {
        DTAppendQuad(vertices, x0, y0 - width * 0.5f,
                     x1, y0 + width * 0.5f, color);
    }
}

static MetadataValue DTMetadataValue(DTRenderMetadataDescriptor *descriptor) {
    MetadataValue result;
    if (!descriptor) return result;
    result.pageID = descriptor.pageID;
    result.generation = descriptor.generation;
    result.activeLayerID = descriptor.activeLayerID;
    result.pageWidth = std::max(1.0f, descriptor.pageWidth);
    result.pageHeight = std::max(1.0f, descriptor.pageHeight);
    result.layers.reserve(descriptor.layers.count);
    for (DTLayerRenderDescriptor *layer in descriptor.layers) {
        result.layers.push_back({layer.layerID, (bool)layer.visible,
                                 DTClamp01(layer.opacity)});
    }
    return result;
}

static bool DTTileVisible(TileAddress tile,
                          float scale,
                          float rotation,
                          Vec2 translation,
                          Vec2 viewport) {
    if (scale <= 0.0f || viewport.x <= 0.0f || viewport.y <= 0.0f) return true;
    const float c = std::cos(rotation);
    const float s = std::sin(rotation);
    const Vec2 corners[4] = {{0, 0}, {viewport.x, 0},
                             {0, viewport.y}, {viewport.x, viewport.y}};
    Vec2 minimum{INFINITY, INFINITY};
    Vec2 maximum{-INFINITY, -INFINITY};
    for (Vec2 corner : corners) {
        const Vec2 rotated{(corner.x - translation.x) / scale,
                           (corner.y - translation.y) / scale};
        const Vec2 document{c * rotated.x + s * rotated.y,
                            -s * rotated.x + c * rotated.y};
        minimum.x = std::min(minimum.x, document.x);
        minimum.y = std::min(minimum.y, document.y);
        maximum.x = std::max(maximum.x, document.x);
        maximum.y = std::max(maximum.y, document.y);
    }
    const Vec2 origin = tile.origin();
    const float extent = (float)drafting_table::metal::kTileSize;
    return origin.x + extent >= minimum.x && origin.x <= maximum.x &&
           origin.y + extent >= minimum.y && origin.y <= maximum.y;
}

} // namespace

@interface DTMetalRenderer () <DTRasterRenderSink> {
    dispatch_queue_t _renderQueue;
    std::unique_ptr<RendererState> _state;
}
@property(nonatomic, weak) MTKView *view;
@property(nonatomic, weak) DTEngineBridge *engine;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> overlayPipeline;
@end

@implementation DTMetalRenderer

- (NSUInteger)frameCount {
    return _state ? _state->frameCount.load(std::memory_order_relaxed) : 0;
}

- (instancetype)initWithView:(MTKView *)view engine:(DTEngineBridge *)engine {
    self = [super init];
    if (!self) return nil;
    _view = view;
    _engine = engine;
    _renderQueue = dispatch_queue_create("com.local.draftingtable.renderer", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_renderQueue, kRenderQueueSpecific,
                                (__bridge void *)self, nullptr);
    _state = std::make_unique<RendererState>();

    view.clearColor = MTLClearColorMake(0.102, 0.090, 0.078, 1.0);
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    view.framebufferOnly = NO;
    view.paused = YES;
    view.enableSetNeedsDisplay = YES;
    view.preferredFramesPerSecond = UIScreen.mainScreen.maximumFramesPerSecond;

    id<MTLDevice> device = view.device;
    if (device) {
        _commandQueue = [device newCommandQueue];
        id<MTLLibrary> library = [device newDefaultLibrary];
        id<MTLFunction> vertex = [library newFunctionWithName:@"dt_overlay_vertex"];
        id<MTLFunction> fragment = [library newFunctionWithName:@"dt_overlay_fragment"];
        if (vertex && fragment) {
            MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = vertex;
            descriptor.fragmentFunction = fragment;
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
            descriptor.colorAttachments[0].blendingEnabled = YES;
            descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            NSError *error = nil;
            _overlayPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
            if (!_overlayPipeline) NSLog(@"DraftingTable overlay pipeline: %@", error);
        }
    }
    view.delegate = self;
    [engine dt_installRenderSink:self];
    [self enqueueMetadataSnapshot:[engine dt_renderMetadataSnapshot]];
    return self;
}

- (LayerGPUState *)dt_layerForID:(uint64_t)layerID create:(BOOL)create {
    if (!layerID || !_state || !self.view.device) return nullptr;
    auto found = _state->layers.find(layerID);
    if (found != _state->layers.end()) return &found->second;
    if (!create) return nullptr;
    std::string error;
    auto backend = Backend::create((__bridge void *)self.view.device,
                                   {kMaxResidentTilesPerLayer}, &error);
    if (!backend) {
        NSLog(@"DraftingTable tile backend: %s", error.c_str());
        return nullptr;
    }
    LayerGPUState layer;
    layer.backend = std::move(backend);
    return &_state->layers.emplace(layerID, std::move(layer)).first->second;
}

- (void)dt_requestFrame {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.view setNeedsDisplay]; });
}

- (void)updateCanvasScale:(CGFloat)scale
                 rotation:(CGFloat)rotation
             translationX:(CGFloat)x
             translationY:(CGFloat)y {
    dispatch_async(_renderQueue, ^{
        self->_state->scale = std::max(0.01f, (float)scale);
        self->_state->rotation = std::isfinite((double)rotation) ? (float)rotation : 0.0f;
        self->_state->translationX = std::isfinite((double)x) ? (float)x : 0.0f;
        self->_state->translationY = std::isfinite((double)y) ? (float)y : 0.0f;
    });
}

- (void)updateGridVisible:(BOOL)visible spacing:(CGFloat)spacing {
    dispatch_async(_renderQueue, ^{
        self->_state->gridVisible = visible;
        self->_state->gridSpacing = std::clamp((float)spacing, 2.0f, 512.0f);
    });
}

- (void)updatePixelGridVisible:(BOOL)visible {
    dispatch_async(_renderQueue, ^{ self->_state->pixelGridVisible = visible; });
}

- (void)updateCenterMode:(BOOL)centerMode {
    dispatch_async(_renderQueue, ^{ self->_state->centerMode = centerMode; });
}

- (void)updatePaperWidth:(CGFloat)width height:(CGFloat)height {
    dispatch_async(_renderQueue, ^{
        self->_state->metadata.pageWidth = std::max(1.0f, (float)width);
        self->_state->metadata.pageHeight = std::max(1.0f, (float)height);
    });
}

- (void)enqueueMetadataSnapshot:(DTRenderMetadataDescriptor *)metadata {
    MetadataValue value = DTMetadataValue(metadata);
    dispatch_async(_renderQueue, ^{
        self->_state->metadata = value;
        for (const auto& layer : value.layers) [self dt_layerForID:layer.layerID create:YES];
        [self dt_requestFrame];
    });
}

- (void)enqueueBeginStroke:(DTStrokeOperationDescriptor)operation {
    dispatch_async(_renderQueue, ^{
        if (self->_state->stroke) return;
        if (operation.tool != DTToolBrush && operation.tool != DTToolEraser) return;
        self->_state->stroke.emplace(operation,
                                     self->_state->metadata.pageWidth,
                                     self->_state->metadata.pageHeight);
    });
}

- (void)enqueueSampleBatch:(DTSampleBatchDescriptor *)batch {
    NSData *owned = [batch.sampleBytes copy];
    const uint64_t operationID = batch.operationID;
    const NSUInteger realCount = batch.realCount;
    dispatch_async(_renderQueue, ^{
        if (!self->_state->stroke ||
            self->_state->stroke->descriptor.operationID != operationID) return;
        if (owned.length % sizeof(DTPencilSample) != 0) return;
        const NSUInteger count = owned.length / sizeof(DTPencilSample);
        if (realCount > count) return;

        std::vector<DTPencilSample> bridgeSamples(count);
        if (count) std::memcpy(bridgeSamples.data(), owned.bytes, owned.length);
        std::vector<PencilSample> real;
        std::vector<PencilSample> predicted;
        real.reserve(realCount);
        predicted.reserve(count - realCount);
        for (NSUInteger index = 0; index < count; ++index) {
            PencilSample sample = DTCoreSample(bridgeSamples[index]);
            if (index < realCount) real.push_back(sample);
            else predicted.push_back(sample);
        }

        ActiveStroke& stroke = *self->_state->stroke;
        LayerGPUState *layer = [self dt_layerForID:stroke.descriptor.layerID create:YES];
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        if (!layer || !commandBuffer) return;
        if (!stroke.transactionBegun) {
            if (layer->backend->beginTransaction((__bridge void *)commandBuffer,
                                                  operationID) != BackendResult::ok) return;
            stroke.transactionBegun = true;
        }
        (void)layer->backend->discardPrediction((__bridge void *)commandBuffer);

        std::vector<Dab> emitted;
        stroke.emitter.setSink([&](const Dab& dab) { emitted.push_back(dab); });
        stroke.emitter.append(real, predicted);
        stroke.emitter.setSink({});
        std::vector<Dab> realDabs;
        std::vector<Dab> predictedDabs;
        for (const Dab& dab : emitted) {
            (dab.predicted ? predictedDabs : realDabs).push_back(dab);
        }

        PreparedBatches realBatches = DTPrepareBatches(realDabs, stroke.descriptor);
        if (!realBatches.batches.empty()) {
            const DabBlendMode mode = stroke.descriptor.tool == DTToolEraser
                ? DabBlendMode::DestinationOut : DabBlendMode::SourceOver;
            if (layer->backend->encodeDabs((__bridge void *)commandBuffer,
                                            realBatches.batches, mode) != BackendResult::ok) {
                layer->backend->cancelTransaction(operationID);
                self->_state->stroke.reset();
                return;
            }
            for (TileAddress address : realBatches.addresses) {
                stroke.touched.insert(address.key());
                layer->resident.insert(address.key());
            }
        }

        PreparedBatches predictedBatches = DTPrepareBatches(predictedDabs, stroke.descriptor);
        const DabBlendMode mode = stroke.descriptor.tool == DTToolEraser
            ? DabBlendMode::DestinationOut : DabBlendMode::SourceOver;
        if (layer->backend->encodePredictedDabs((__bridge void *)commandBuffer,
                                                 predictedBatches.batches,
                                                 mode) != BackendResult::ok) {
            layer->backend->cancelTransaction(operationID);
            self->_state->stroke.reset();
            return;
        }
        for (TileAddress address : predictedBatches.addresses) layer->resident.insert(address.key());
        [commandBuffer commit];
        [self dt_requestFrame];
    });
}

- (void)enqueueEstimatedSample:(DTPencilSample)sample
                         index:(uint64_t)estimationUpdateIndex
                     operation:(DTOperationIdentifier)operationID {
    // Estimated-value corrections are retained by UIKit/core for a later
    // rebake path. v0.1 never mutates an already committed GPU generation.
    (void)sample;
    (void)estimationUpdateIndex;
    (void)operationID;
}

- (void)enqueueEndStroke:(DTOperationIdentifier)operationID
               completion:(DTRasterCommitCompletion)completion
                checkpoint:(DTCheckpointCompletion)checkpoint {
    DTRasterCommitCompletion commitBlock = [completion copy];
    DTCheckpointCompletion checkpointBlock = [checkpoint copy];
    dispatch_async(_renderQueue, ^{
        if (!self->_state->stroke ||
            self->_state->stroke->descriptor.operationID != operationID ||
            !self->_state->stroke->transactionBegun ||
            self->_state->stroke->touched.empty()) {
            if (self->_state->stroke && self->_state->stroke->transactionBegun) {
                LayerGPUState *activeLayer = [self dt_layerForID:
                    self->_state->stroke->descriptor.layerID create:NO];
                if (activeLayer) activeLayer->backend->cancelTransaction(operationID);
            }
            NSError *error = DTMakeRendererError(10, @"Stroke produced no raster tiles");
            if (commitBlock) commitBlock(nil, error);
            if (checkpointBlock) checkpointBlock(nil, error);
            self->_state->stroke.reset();
            return;
        }
        ActiveStroke stroke = std::move(*self->_state->stroke);
        self->_state->stroke.reset();
        LayerGPUState *layer = [self dt_layerForID:stroke.descriptor.layerID create:NO];
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        if (!layer || !commandBuffer) {
            NSError *error = DTMakeRendererError(11, @"Missing raster layer backend");
            if (commitBlock) commitBlock(nil, error);
            if (checkpointBlock) checkpointBlock(nil, error);
            return;
        }
        const uint64_t generation = stroke.descriptor.generation;
        if (self->_state->nextVersionID == 0 ||
            self->_state->nextVersionID == UINT64_MAX ||
            stroke.touched.size() > UINT64_MAX - self->_state->nextVersionID) {
            layer->backend->cancelTransaction(operationID);
            NSError *error = DTMakeRendererError(12, @"Tile version ID space is exhausted");
            if (commitBlock) commitBlock(nil, error);
            if (checkpointBlock) checkpointBlock(nil, error);
            return;
        }
        std::vector<TileVersionRef> afterRefs;
        std::unordered_map<std::int64_t, uint64_t> versionIDs;
        afterRefs.reserve(stroke.touched.size());
        for (std::int64_t key : stroke.touched) {
            versionIDs.emplace(key, self->_state->nextVersionID++);
            afterRefs.push_back({TileAddress::fromKey(key), generation, true});
        }
        layer->backend->discardPrediction((__bridge void *)commandBuffer);
        layer->backend->encodeApronResolve((__bridge void *)commandBuffer);
        if (layer->backend->encodeCommit((__bridge void *)commandBuffer,
                                          operationID, generation) != BackendResult::ok) {
            layer->backend->cancelTransaction(operationID);
            NSError *error = DTMakeRendererError(12, @"Unable to encode raster commit");
            if (commitBlock) commitBlock(nil, error);
            if (checkpointBlock) checkpointBlock(nil, error);
            return;
        }
        std::vector<CheckpointTicket> tickets;
        NSError *checkpointEncodingError = nil;
        if (layer->backend->encodeCheckpoint((__bridge void *)commandBuffer,
                                              afterRefs, tickets) != BackendResult::ok) {
            checkpointEncodingError = DTMakeRendererError(
                13, @"Raster commit succeeded but its persistence checkpoint could not be encoded");
            tickets.clear();
        }
        __weak DTMetalRenderer *weakSelf = self;
        [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
            DTMetalRenderer *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf->_renderQueue, ^{
                LayerGPUState *finishedLayer = [strongSelf dt_layerForID:stroke.descriptor.layerID create:NO];
                auto versions = finishedLayer ? finishedLayer->backend->takeCompletedCommit(operationID)
                                              : std::nullopt;
                if (!versions || !versions->succeeded) {
                    NSError *error = DTMakeRendererError(14, @"Metal rejected raster commit");
                    if (commitBlock) commitBlock(nil, error);
                    if (checkpointBlock) checkpointBlock(nil, error);
                    return;
                }
                NSMutableArray<DTTileCommitDescriptor *> *commitTiles = [NSMutableArray array];
                for (const TileVersionRef& after : versions->after.tiles) {
                    const auto before = std::find_if(
                        versions->before.tiles.begin(), versions->before.tiles.end(),
                        [&](const TileVersionRef& value) { return value.tile == after.tile; });
                    const BOOL beforeExists = before != versions->before.tiles.end() && before->exists;
                    const uint64_t beforeGeneration = beforeExists ? before->generation : 0;
                    [commitTiles addObject:[[DTTileCommitDescriptor alloc]
                        initWithLayerID:stroke.descriptor.layerID
                        coordinate:(DTTileCoordinate){after.tile.x, after.tile.y}
                        beforeExists:beforeExists
                        beforeGeneration:beforeGeneration
                        afterExists:after.exists
                        afterGeneration:after.exists ? generation : 0
                        afterVersionID:after.exists ? versionIDs.at(after.tile.key()) : 0]];
                }
                DTRasterCommitDescriptor *commit = [[DTRasterCommitDescriptor alloc]
                    initWithOperationID:operationID generation:generation
                    pageID:stroke.descriptor.pageID tiles:commitTiles];

                NSMutableArray<DTTileCheckpointPayload *> *payloads = [NSMutableArray array];
                NSError *checkpointError = checkpointEncodingError;
                for (NSUInteger index = 0; index < tickets.size(); ++index) {
                    std::vector<uint8_t> bytes(kTileBytes);
                    if (finishedLayer->backend->readCheckpoint(tickets[index], bytes) != BackendResult::ok) {
                        checkpointError = DTMakeRendererError(15, @"Tile checkpoint was not readable after completion");
                        break;
                    }
                    NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                    const TileAddress address = tickets[index].tile;
                    [payloads addObject:[[DTTileCheckpointPayload alloc]
                        initWithPageID:stroke.descriptor.pageID
                        layerID:stroke.descriptor.layerID tileX:address.x tileY:address.y
                        exists:YES versionID:versionIDs.at(address.key()) generation:generation
                        premultipliedRGBA8:data]];
                    finishedLayer->backend->releaseCheckpoint(tickets[index]);
                }
                if (commitBlock) commitBlock(commit, nil);
                if (checkpointBlock) {
                    if (checkpointError) checkpointBlock(nil, checkpointError);
                    else checkpointBlock([[DTCheckpointPayloadBatch alloc]
                        initWithOperationID:operationID generation:generation tiles:payloads], nil);
                }
                [strongSelf dt_requestFrame];
            });
        }];
        [commandBuffer commit];
    });
}

- (void)enqueueCancelStroke:(DTOperationIdentifier)operationID
                  completion:(DTRenderCommandCompletion)completion {
    DTRenderCommandCompletion block = [completion copy];
    dispatch_async(_renderQueue, ^{
        NSError *error = nil;
        if (self->_state->stroke && self->_state->stroke->descriptor.operationID == operationID) {
            LayerGPUState *layer = [self dt_layerForID:self->_state->stroke->descriptor.layerID create:NO];
            if (layer && self->_state->stroke->transactionBegun &&
                layer->backend->cancelTransaction(operationID) != BackendResult::ok) {
                error = DTMakeRendererError(20, @"Unable to cancel raster transaction");
            }
            self->_state->stroke.reset();
        }
        if (block) block(error);
        [self dt_requestFrame];
    });
}

- (void)enqueueRestore:(DTRestoreOperationDescriptor *)restore
             completion:(DTRasterCommitCompletion)completion
              checkpoint:(DTCheckpointCompletion)checkpoint {
    const uint64_t operationID = restore.operationID;
    const uint64_t generation = restore.generation;
    const uint64_t pageID = restore.pageID;
    std::vector<RestoreItemValue> values;
    values.reserve(restore.tiles.count);
    for (DTTileRestoreDescriptor *tile in restore.tiles) {
        values.push_back({tile.layerID,
                          {tile.coordinate.x, tile.coordinate.y},
                          (bool)tile.sourceExists, tile.sourceGeneration,
                          (bool)tile.targetExists, tile.targetVersionID});
    }
    DTRasterCommitCompletion commitBlock = [completion copy];
    DTCheckpointCompletion checkpointBlock = [checkpoint copy];
    dispatch_async(_renderQueue, ^{
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        if (!commandBuffer || values.empty()) {
            NSError *error = DTMakeRendererError(30, @"Undo restore has no tiles");
            if (commitBlock) commitBlock(nil, error);
            if (checkpointBlock) checkpointBlock(nil, error);
            return;
        }
        std::unordered_map<uint64_t, RestoreLayerWork> grouped;
        for (const auto& value : values) {
            if (value.targetExists && value.targetVersionID < UINT64_MAX) {
                self->_state->nextVersionID = std::max(
                    self->_state->nextVersionID, value.targetVersionID + 1);
            }
            auto& work = grouped[value.layerID];
            work.layerID = value.layerID;
            work.items.push_back(value);
        }
        NSError *encodingError = nil;
        for (auto& entry : grouped) {
            LayerGPUState *layer = [self dt_layerForID:entry.first create:YES];
            if (!layer) { encodingError = DTMakeRendererError(31, @"Undo layer is unavailable"); break; }
            std::vector<TileAddress> addresses;
            drafting_table::metal::TileVersionSet sources;
            sources.operationId = operationID;
            for (const auto& item : entry.second.items) {
                addresses.push_back(item.tile);
                sources.tiles.push_back({item.tile, item.sourceGeneration, item.sourceExists});
            }
            if (layer->backend->beginTransaction((__bridge void *)commandBuffer,
                                                  operationID, addresses) != BackendResult::ok ||
                layer->backend->encodeRestoreVersions((__bridge void *)commandBuffer,
                                                       sources) != BackendResult::ok ||
                layer->backend->encodeApronResolve((__bridge void *)commandBuffer) != BackendResult::ok ||
                layer->backend->encodeCommit((__bridge void *)commandBuffer,
                                              operationID, generation) != BackendResult::ok) {
                layer->backend->cancelTransaction(operationID);
                encodingError = DTMakeRendererError(32, @"Unable to encode undo restore");
                break;
            }
            std::vector<TileVersionRef> materialized;
            for (const auto& item : entry.second.items) {
                if (item.targetExists) materialized.push_back({item.tile, generation, true});
            }
            if (!materialized.empty() &&
                layer->backend->encodeCheckpoint((__bridge void *)commandBuffer,
                                                  materialized,
                                                  entry.second.tickets) != BackendResult::ok) {
                encodingError = DTMakeRendererError(33, @"Unable to checkpoint undo restore");
                break;
            }
        }
        if (encodingError) {
            for (auto& entry : grouped) if (LayerGPUState *layer = [self dt_layerForID:entry.first create:NO]) layer->backend->cancelTransaction(operationID);
            if (commitBlock) commitBlock(nil, encodingError);
            if (checkpointBlock) checkpointBlock(nil, encodingError);
            return;
        }
        __weak DTMetalRenderer *weakSelf = self;
        [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
            DTMetalRenderer *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf->_renderQueue, ^{
                NSMutableArray<DTTileCommitDescriptor *> *commitTiles = [NSMutableArray array];
                NSMutableArray<DTTileCheckpointPayload *> *payloads = [NSMutableArray array];
                NSError *error = nil;
                for (auto& entry : grouped) {
                    LayerGPUState *layer = [strongSelf dt_layerForID:entry.first create:NO];
                    auto result = layer ? layer->backend->takeCompletedCommit(operationID) : std::nullopt;
                    if (!result || !result->succeeded) { error = DTMakeRendererError(34, @"Metal undo restore failed"); break; }
                    for (const auto& item : entry.second.items) {
                        const auto before = std::find_if(result->before.tiles.begin(), result->before.tiles.end(), [&](const TileVersionRef& ref){ return ref.tile == item.tile; });
                        const BOOL beforeExists = before != result->before.tiles.end() && before->exists;
                        [commitTiles addObject:[[DTTileCommitDescriptor alloc]
                            initWithLayerID:item.layerID
                            coordinate:(DTTileCoordinate){item.tile.x, item.tile.y}
                            beforeExists:beforeExists
                            beforeGeneration:beforeExists ? before->generation : 0
                            afterExists:item.targetExists
                            afterGeneration:item.targetExists ? generation : 0
                            afterVersionID:item.targetExists ? item.targetVersionID : 0]];
                        if (item.targetExists) layer->resident.insert(item.tile.key());
                        else layer->resident.erase(item.tile.key());
                    }
                    NSUInteger ticketIndex = 0;
                    for (const auto& item : entry.second.items) {
                        if (!item.targetExists) {
                            [payloads addObject:[[DTTileCheckpointPayload alloc]
                                initWithPageID:pageID layerID:item.layerID
                                tileX:item.tile.x tileY:item.tile.y exists:NO
                                versionID:0 generation:generation
                                premultipliedRGBA8:[NSData data]]];
                            continue;
                        }
                        if (ticketIndex >= entry.second.tickets.size()) { error = DTMakeRendererError(35, @"Undo checkpoint ticket mismatch"); break; }
                        const CheckpointTicket ticket = entry.second.tickets[ticketIndex++];
                        std::vector<uint8_t> bytes(kTileBytes);
                        if (layer->backend->readCheckpoint(ticket, bytes) != BackendResult::ok) { error = DTMakeRendererError(36, @"Undo checkpoint is unreadable"); break; }
                        NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                        [payloads addObject:[[DTTileCheckpointPayload alloc]
                            initWithPageID:pageID layerID:item.layerID
                            tileX:item.tile.x tileY:item.tile.y exists:YES
                            versionID:item.targetVersionID generation:generation
                            premultipliedRGBA8:data]];
                        layer->backend->releaseCheckpoint(ticket);
                    }
                    if (error) break;
                }
                if (error) {
                    if (commitBlock) commitBlock(nil, error);
                    if (checkpointBlock) checkpointBlock(nil, error);
                    return;
                }
                if (commitBlock) commitBlock([[DTRasterCommitDescriptor alloc]
                    initWithOperationID:operationID generation:generation
                    pageID:pageID tiles:commitTiles], nil);
                if (checkpointBlock) checkpointBlock([[DTCheckpointPayloadBatch alloc]
                    initWithOperationID:operationID generation:generation tiles:payloads], nil);
                [strongSelf dt_requestFrame];
            });
        }];
        [commandBuffer commit];
    });
}

- (void)enqueueDocumentLoad:(DTDocumentLoadDescriptor *)load
                  completion:(DTRenderCommandCompletion)completion {
    DTRenderMetadataDescriptor *metadata = load.metadata;
    NSArray<DTTileUploadDescriptor *> *uploads = [load.tiles copy];
    DTRenderCommandCompletion block = [completion copy];
    dispatch_async(_renderQueue, ^{
        self->_state->stroke.reset();
        self->_state->layers.clear();
        self->_state->nextVersionID = 1;
        self->_state->metadata = DTMetadataValue(metadata);
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        NSError *error = nil;
        for (const auto& layerMetadata : self->_state->metadata.layers) {
            if (![self dt_layerForID:layerMetadata.layerID create:YES]) {
                error = DTMakeRendererError(40, @"Unable to create package layer backend");
                break;
            }
        }
        if (!commandBuffer) error = DTMakeRendererError(41, @"Unable to create package upload command buffer");
        if (!error) {
            for (DTTileUploadDescriptor *upload in uploads) {
                if (upload.versionID < UINT64_MAX) {
                    self->_state->nextVersionID = std::max(
                        self->_state->nextVersionID, upload.versionID + 1);
                }
                LayerGPUState *layer = [self dt_layerForID:upload.layerID create:NO];
                NSData *bytes = upload.premultipliedRGBA8;
                if (!layer || bytes.length != kTileBytes ||
                    layer->backend->uploadPersistedTileBytes(
                        (__bridge void *)commandBuffer,
                        {upload.coordinate.x, upload.coordinate.y}, upload.generation,
                        std::span<const uint8_t>((const uint8_t *)bytes.bytes,
                                                 bytes.length)) != BackendResult::ok) {
                    error = DTMakeRendererError(42, @"Package tile upload failed");
                    break;
                }
                layer->resident.insert(TileAddress{upload.coordinate.x, upload.coordinate.y}.key());
            }
        }
        if (error) { if (block) block(error); return; }
        __weak DTMetalRenderer *weakSelf = self;
        [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
            DTMetalRenderer *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf->_renderQueue, ^{
                NSError *validationError = nil;
                for (DTTileUploadDescriptor *upload in uploads) {
                    LayerGPUState *layer = [strongSelf dt_layerForID:upload.layerID create:NO];
                    auto state = layer ? layer->backend->tileState({upload.coordinate.x, upload.coordinate.y}) : std::nullopt;
                    if (!state || state->contentGeneration != upload.generation) {
                        validationError = DTMakeRendererError(43, @"Package tile upload did not complete");
                        break;
                    }
                }
                if (block) block(validationError);
                [strongSelf dt_requestFrame];
            });
        }];
        [commandBuffer commit];
    });
}

- (void)enqueueReleaseVersions:(NSArray<DTTileVersionDescriptor *> *)versions {
    NSArray<DTTileVersionDescriptor *> *owned = [versions copy];
    dispatch_async(_renderQueue, ^{
        std::unordered_map<uint64_t, std::vector<TileVersionRef>> grouped;
        for (DTTileVersionDescriptor *version in owned) {
            if (version.exists) grouped[version.layerID].push_back(
                {{version.coordinate.x, version.coordinate.y}, version.generation, true});
        }
        for (auto& entry : grouped) {
            if (LayerGPUState *layer = [self dt_layerForID:entry.first create:NO]) {
                layer->backend->releaseHistoricalVersions(entry.second);
            }
        }
    });
}

- (void)drawInMTKView:(MTKView *)view {
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!drawable || !pass || !self.commandQueue) return;
    dispatch_block_t encodeFrame = ^{
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        if (!commandBuffer) return;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = view.clearColor;

        const CGSize drawableSize = view.drawableSize;
        const float displayScale = view.bounds.size.width > 0
            ? (float)(drawableSize.width / view.bounds.size.width) : 1.0f;
        const float renderScale = self->_state->scale * displayScale;
        const float width = self->_state->metadata.pageWidth;
        const float height = self->_state->metadata.pageHeight;

        std::vector<DTOverlayVertex> overlay;
        DTAppendQuad(overlay, 0.0f, 0.0f, width, height,
                     (vector_float4){0.965f, 0.941f, 0.875f, 1.0f});
        if (self->_state->gridVisible) {
            const float spacing = std::max(2.0f, self->_state->gridSpacing);
            const float lineWidth = std::max(0.35f, 0.75f / std::max(self->_state->scale, 0.01f));
            const vector_float4 grid = {0.16f * 0.22f, 0.20f * 0.22f,
                                        0.22f * 0.22f, 0.22f};
            NSUInteger count = 0;
            for (float x = 0.0f; x <= width && count < 1024; x += spacing, ++count)
                DTAppendLine(overlay, x, 0.0f, x, height, lineWidth, grid);
            count = 0;
            for (float y = 0.0f; y <= height && count < 1024; y += spacing, ++count)
                DTAppendLine(overlay, 0.0f, y, width, y, lineWidth, grid);
        }
        if (self->_state->centerMode) {
            const float lineWidth = std::max(0.5f, 1.0f / std::max(self->_state->scale, 0.01f));
            const vector_float4 center = {0.32f, 0.10f, 0.08f, 0.42f};
            DTAppendLine(overlay, width * 0.5f, 0.0f, width * 0.5f, height,
                         lineWidth, center);
            DTAppendLine(overlay, 0.0f, height * 0.5f, width, height * 0.5f,
                         lineWidth, center);
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (encoder) {
            if (self.overlayPipeline && !overlay.empty()) {
                id<MTLBuffer> buffer = [view.device newBufferWithBytes:overlay.data()
                                                                length:overlay.size() * sizeof(DTOverlayVertex)
                                                               options:MTLResourceStorageModeShared];
                DTOverlayUniforms uniforms{{(float)drawableSize.width, (float)drawableSize.height},
                                           renderScale, self->_state->rotation,
                                           {self->_state->translationX * displayScale,
                                            self->_state->translationY * displayScale},
                                           {0.0f, 0.0f}};
                [encoder setRenderPipelineState:self.overlayPipeline];
                [encoder setVertexBuffer:buffer offset:0 atIndex:0];
                [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                             vertexCount:overlay.size()];
            }
            [encoder endEncoding];
        }

        for (const LayerMetadataValue& metadata : self->_state->metadata.layers) {
            if (!metadata.visible || metadata.opacity <= 0.0f) continue;
            LayerGPUState *layer = [self dt_layerForID:metadata.layerID create:NO];
            if (!layer || layer->resident.empty()) continue;
            std::vector<TileAddress> visible;
            visible.reserve(layer->resident.size());
            const Vec2 viewport{(float)drawableSize.width, (float)drawableSize.height};
            const Vec2 translation{self->_state->translationX * displayScale,
                                   self->_state->translationY * displayScale};
            for (std::int64_t key : layer->resident) {
                const TileAddress address = TileAddress::fromKey(key);
                if (DTTileVisible(address, renderScale, self->_state->rotation,
                                  translation, viewport)) {
                    visible.push_back(address);
                }
            }
            if (visible.empty()) continue;
            drafting_table::metal::CompositeParameters parameters;
            parameters.scale = renderScale;
            parameters.rotationRadians = self->_state->rotation;
            parameters.translation = translation;
            parameters.viewportSize = viewport;
            parameters.opacity = metadata.opacity;
            parameters.clipMin = {0.0f, 0.0f};
            parameters.clipMax = {width, height};
            parameters.clipEnabled = true;
            layer->backend->encodeComposite((__bridge void *)commandBuffer,
                                             (__bridge void *)drawable.texture,
                                             visible, parameters);
        }
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        self->_state->frameCount.fetch_add(1, std::memory_order_relaxed);
    };
    if (dispatch_get_specific(kRenderQueueSpecific) == (__bridge void *)self) {
        encodeFrame();
    } else {
        dispatch_sync(_renderQueue, encodeFrame);
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)size;
    [view setNeedsDisplay];
}

@end
