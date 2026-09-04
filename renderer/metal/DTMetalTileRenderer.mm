#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <simd/simd.h>

#include "DTMetalTileRenderer.hpp"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <unordered_set>
#include <utility>

namespace drafting_table::metal {
namespace {

struct DabUniforms {
    vector_float2 textureExtent;
    float apron;
    float reserved = 0.0f;
};

struct CompositeUniforms {
    float scale;
    float rotationRadians;
    vector_float2 translation;
    vector_float2 viewportSize;
    float opacity;
    vector_float2 tileOrigin;
};

struct VersionTextures {
    id<MTLTexture> color = nil;
    id<MTLTexture> coverage = nil;
    bool colorInitialized = false;
    bool coverageInitialized = false;
    std::uint64_t generation = 0;
};

struct TileResource {
    TileAddress address{};
    VersionTextures committed{};
    VersionTextures working{};
    VersionTextures preview{};
    std::unordered_map<std::uint64_t, VersionTextures> history;
    std::uint64_t contentGeneration = 0;
    std::uint64_t persistedGeneration = 0;
    std::uint64_t lastUse = 0;
    bool hasCommitted = false;
    bool hasWorking = false;
    bool hasPreview = false;
    bool dirtyApron = false;
    bool inFlight = false;
    bool apronInFlight = false;
};

enum class AsyncStatus : std::uint8_t { Pending = 0, Ready = 1, Failed = 2 };

struct CommitState {
    std::uint64_t operationId = 0;
    std::uint64_t generation = 0;
    TileCommitVersions versions{};
    std::unordered_map<std::int64_t, VersionTextures> working;
    std::atomic<AsyncStatus> status{AsyncStatus::Pending};
};

struct CheckpointState {
    CheckpointTicket ticket{};
    id<MTLBuffer> buffer = nil;
    std::atomic<AsyncStatus> status{AsyncStatus::Pending};
};

struct UploadState {
    TileAddress tile{};
    std::uint64_t generation = 0;
    VersionTextures version{};
    std::atomic<AsyncStatus> status{AsyncStatus::Pending};
};

struct ApronState {
    std::vector<std::int64_t> tiles;
    std::atomic<AsyncStatus> status{AsyncStatus::Pending};
};

static id<MTLCommandBuffer> commandBufferFrom(void* handle) {
    return handle ? (__bridge id<MTLCommandBuffer>)handle : nil;
}

static id<MTLTexture> textureFrom(void* handle) {
    return handle ? (__bridge id<MTLTexture>)handle : nil;
}

static MTLRenderPassDescriptor* tilePass(id<MTLTexture> texture,
                                          bool initialized) {
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor* attachment = pass.colorAttachments[0];
    attachment.texture = texture;
    attachment.loadAction = initialized ? MTLLoadActionLoad : MTLLoadActionClear;
    attachment.storeAction = MTLStoreActionStore;
    attachment.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    return pass;
}

static void configureBlendAttachment(
    MTLRenderPipelineColorAttachmentDescriptor* attachment,
    MTLPixelFormat format,
    DabBlendMode mode) {
    attachment.pixelFormat = format;
    attachment.blendingEnabled = YES;
    // Coverage is a hit-test mask.  Preserve the Android/reference MAX
    // accumulation for a normal dab; erasing still uses scalar
    // destination-out so partial-pressure erasers remove proportionally.
    if (format == MTLPixelFormatR8Unorm && mode == DabBlendMode::SourceOver) {
        attachment.rgbBlendOperation = MTLBlendOperationMax;
        attachment.alphaBlendOperation = MTLBlendOperationMax;
        attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOne;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOne;
        return;
    }
    attachment.rgbBlendOperation = MTLBlendOperationAdd;
    attachment.alphaBlendOperation = MTLBlendOperationAdd;
    if (mode == DabBlendMode::DestinationOut) {
        // out = dst * (1 - src.a), with no source contribution.
        attachment.sourceRGBBlendFactor = MTLBlendFactorZero;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorZero;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    } else {
        // Premultiplied Porter-Duff OVER: out = src + dst * (1 - src.a).
        attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
}

static bool isCompleted(id<MTLCommandBuffer> commandBuffer) {
    return commandBuffer && commandBuffer.status == MTLCommandBufferStatusCompleted;
}

static bool copyTexture(id<MTLBlitCommandEncoder> blit,
                        id<MTLTexture> source,
                        id<MTLTexture> destination,
                        MTLOrigin sourceOrigin = MTLOriginMake(0, 0, 0),
                        MTLOrigin destinationOrigin = MTLOriginMake(0, 0, 0),
                        MTLSize size = MTLSizeMake(kTileTextureExtent,
                                                   kTileTextureExtent, 1)) {
    if (!blit || !source || !destination) return false;
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0
            sourceOrigin:sourceOrigin sourceSize:size
               toTexture:destination destinationSlice:0 destinationLevel:0
       destinationOrigin:destinationOrigin];
    return true;
}

} // namespace

struct Backend::Impl {
    id<MTLDevice> device = nil;
    id<MTLLibrary> library = nil;
    id<MTLRenderPipelineState> dabColorSourceOver = nil;
    id<MTLRenderPipelineState> dabColorDestinationOut = nil;
    id<MTLRenderPipelineState> dabCoverageSourceOver = nil;
    id<MTLRenderPipelineState> dabCoverageDestinationOut = nil;
    id<MTLSamplerState> tileSampler = nil;
    // Shared zero-filled sources used to reset only apron rectangles before
    // copying valid neighbor edges.  Clearing an apron is necessary after a
    // neighbor is erased or unloaded; otherwise stale edge texels survive.
    id<MTLTexture> transparentColor = nil;
    id<MTLTexture> transparentCoverage = nil;
    NSMutableDictionary<NSNumber*, id<MTLRenderPipelineState>>* compositePipelines = nil;

    std::unordered_map<std::int64_t, TileResource> tiles;
    std::unordered_map<std::uint64_t, std::shared_ptr<CommitState>> commits;
    std::unordered_map<std::uint64_t, std::shared_ptr<CheckpointState>> checkpoints;
    std::vector<std::shared_ptr<UploadState>> uploads;
    std::vector<std::shared_ptr<ApronState>> aprons;
    BackendOptions options{};
    std::uint64_t clock = 0;
    std::uint64_t nextGeneration = 0;
    std::uint64_t nextCheckpoint = 1;
    std::uint64_t activeOperation = 0;
    std::unordered_map<std::int64_t, TileVersionRef> activeBefore;
    std::unordered_set<std::int64_t> activeTiles;
    bool activeCommitPending = false;
    std::string error;

    explicit Impl(id<MTLDevice> selectedDevice, BackendOptions configured)
        : device(selectedDevice), options(configured) {
        compositePipelines = [NSMutableDictionary dictionary];
    }

    void fail(NSString* message) {
        error = message ? std::string([message UTF8String]) : "Metal backend error";
    }

    bool buildDabPipeline(MTLPixelFormat format,
                          DabBlendMode mode,
                          id<MTLRenderPipelineState> __strong *output) {
        if (!output) return false;
        id<MTLFunction> vertex = [library newFunctionWithName:@"dt_metal_dab_vertex"];
        NSString* fragmentName = format == MTLPixelFormatR8Unorm
            ? @"dt_metal_dab_coverage" : @"dt_metal_dab_color";
        id<MTLFunction> fragment = [library newFunctionWithName:fragmentName];
        if (!vertex || !fragment) {
            fail(@"Metal dab functions are missing from the default library");
            return false;
        }
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        configureBlendAttachment(descriptor.colorAttachments[0], format, mode);
        NSError* pipelineError = nil;
        *output = [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
        if (!*output) {
            fail(pipelineError.localizedDescription ?: @"Unable to create Metal dab pipeline");
            return false;
        }
        return true;
    }

    bool buildPipelines() {
        library = [device newDefaultLibrary];
        if (!library) {
            fail(@"newDefaultLibrary returned nil; add DTMetalShaders.metal to the iPad target");
            return false;
        }
        if (!buildDabPipeline(MTLPixelFormatRGBA8Unorm, DabBlendMode::SourceOver,
                              &dabColorSourceOver) ||
            !buildDabPipeline(MTLPixelFormatRGBA8Unorm, DabBlendMode::DestinationOut,
                              &dabColorDestinationOut) ||
            !buildDabPipeline(MTLPixelFormatR8Unorm, DabBlendMode::SourceOver,
                              &dabCoverageSourceOver) ||
            !buildDabPipeline(MTLPixelFormatR8Unorm, DabBlendMode::DestinationOut,
                              &dabCoverageDestinationOut)) {
            return false;
        }

        MTLSamplerDescriptor* samplerDescriptor = [MTLSamplerDescriptor new];
        samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
        samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
        tileSampler = [device newSamplerStateWithDescriptor:samplerDescriptor];
        if (!tileSampler) {
            fail(@"Unable to create tile sampler");
            return false;
        }
        return true;
    }

    id<MTLTexture> makeTexture(MTLPixelFormat format) {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                 width:kTileTextureExtent
                                                                height:kTileTextureExtent
                                                             mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        return [device newTextureWithDescriptor:descriptor];
    }

    id<MTLTexture> makeTransparentTexture(MTLPixelFormat format) {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                 width:kTileTextureExtent
                                                                height:kTileTextureExtent
                                                             mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (!texture) return nil;
        const std::size_t channels = format == MTLPixelFormatR8Unorm ? 1u : 4u;
        std::vector<std::uint8_t> zero(static_cast<std::size_t>(kTileTextureExtent) *
                                       static_cast<std::size_t>(kTileTextureExtent) * channels, 0u);
        [texture replaceRegion:MTLRegionMake2D(0, 0, kTileTextureExtent,
                                                kTileTextureExtent)
                   mipmapLevel:0 withBytes:zero.data()
                   bytesPerRow:static_cast<NSUInteger>(kTileTextureExtent) * channels];
        return texture;
    }

    bool ensureTransparentTextures() {
        if (!transparentColor) transparentColor = makeTransparentTexture(MTLPixelFormatRGBA8Unorm);
        if (!transparentCoverage) transparentCoverage = makeTransparentTexture(MTLPixelFormatR8Unorm);
        if (!transparentColor || !transparentCoverage) {
            fail(@"Unable to allocate transparent apron source textures");
            return false;
        }
        return true;
    }

    bool allocateVersion(VersionTextures& version) {
        if (!version.color) version.color = makeTexture(MTLPixelFormatRGBA8Unorm);
        if (!version.coverage) version.coverage = makeTexture(MTLPixelFormatR8Unorm);
        if (!version.color || !version.coverage) {
            fail(@"Unable to allocate 258x258 sparse tile textures");
            return false;
        }
        return true;
    }

    TileResource* ensureTile(TileAddress address) {
        const auto key = address.key();
        auto found = tiles.find(key);
        if (found != tiles.end()) {
            found->second.lastUse = ++clock;
            return &found->second;
        }
        if (options.maxResidentTiles != 0 && tiles.size() >= options.maxResidentTiles) {
            for (auto it = tiles.begin(); it != tiles.end() &&
                 tiles.size() >= options.maxResidentTiles;) {
                const TileResource& candidate = it->second;
                const bool safe = !candidate.inFlight && !candidate.apronInFlight &&
                                  !candidate.hasWorking && !candidate.hasPreview &&
                                  !candidate.dirtyApron &&
                                  (!candidate.hasCommitted ||
                                   candidate.contentGeneration == candidate.persistedGeneration);
                if (safe) it = tiles.erase(it);
                else ++it;
            }
            if (tiles.size() >= options.maxResidentTiles) {
                fail(@"Resident tile limit reached; persist or purge before allocating another tile");
                return nullptr;
            }
        }
        TileResource resource;
        resource.address = address;
        resource.lastUse = ++clock;
        auto [inserted, ok] = tiles.emplace(key, std::move(resource));
        return ok ? &inserted->second : nullptr;
    }

    static VersionTextures* findVersion(TileResource& tile, std::uint64_t generation) {
        if (generation == 0) return nullptr;
        if (tile.hasCommitted && tile.committed.generation == generation) return &tile.committed;
        if (tile.hasWorking && tile.working.generation == generation) return &tile.working;
        if (tile.hasPreview && tile.preview.generation == generation) return &tile.preview;
        const auto found = tile.history.find(generation);
        return found == tile.history.end() ? nullptr : &found->second;
    }

    VersionTextures* compositeVersion(TileResource& tile) {
        if (tile.hasPreview) return &tile.preview;
        if (tile.hasWorking) return &tile.working;
        return tile.hasCommitted ? &tile.committed : nullptr;
    }

    void markDirtyNeighborhood(TileAddress address) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                const auto found = tiles.find(
                    TileAddress{address.x + dx, address.y + dy}.key());
                if (found != tiles.end()) found->second.dirtyApron = true;
            }
        }
    }

    id<MTLRenderPipelineState> dabPipeline(MTLPixelFormat format,
                                           DabBlendMode mode) const {
        if (format == MTLPixelFormatR8Unorm) {
            return mode == DabBlendMode::DestinationOut ? dabCoverageDestinationOut
                                                         : dabCoverageSourceOver;
        }
        return mode == DabBlendMode::DestinationOut ? dabColorDestinationOut
                                                     : dabColorSourceOver;
    }

    bool copyVersionToWorking(id<MTLCommandBuffer> commandBuffer,
                              TileResource& tile) {
        if (!allocateVersion(tile.working)) return false;
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        if (!blit) return false;
        if (tile.hasCommitted) {
            copyTexture(blit, tile.committed.color, tile.working.color);
            copyTexture(blit, tile.committed.coverage, tile.working.coverage);
            tile.working.colorInitialized = tile.committed.colorInitialized;
            tile.working.coverageInitialized = tile.committed.coverageInitialized;
        } else {
            tile.working.colorInitialized = false;
            tile.working.coverageInitialized = false;
        }
        tile.working.generation = tile.contentGeneration;
        [blit endEncoding];
        tile.hasWorking = true;
        return true;
    }

    void reconcileAsync() {
        for (auto it = uploads.begin(); it != uploads.end();) {
            const AsyncStatus status = (*it)->status.load(std::memory_order_acquire);
            if (status == AsyncStatus::Pending) { ++it; continue; }
            TileResource* tile = nullptr;
            const auto found = tiles.find((*it)->tile.key());
            if (found != tiles.end()) tile = &found->second;
            if (tile) {
                tile->inFlight = false;
                if (status == AsyncStatus::Ready) {
                    if (tile->hasCommitted) tile->history[tile->committed.generation] = tile->committed;
                    tile->committed = (*it)->version;
                    tile->committed.generation = (*it)->generation;
                    tile->hasCommitted = true;
                    tile->contentGeneration = (*it)->generation;
                    tile->persistedGeneration = (*it)->generation;
                    tile->hasWorking = false;
                    tile->hasPreview = false;
                    tile->working = {};
                    tile->preview = {};
                    tile->dirtyApron = true;
                    markDirtyNeighborhood((*it)->tile);
                    nextGeneration = std::max(nextGeneration, (*it)->generation);
                }
            }
            it = uploads.erase(it);
        }
        for (auto it = aprons.begin(); it != aprons.end();) {
            const AsyncStatus status = (*it)->status.load(std::memory_order_acquire);
            if (status == AsyncStatus::Pending) { ++it; continue; }
            for (const auto key : (*it)->tiles) {
                const auto found = tiles.find(key);
                if (found == tiles.end()) continue;
                found->second.apronInFlight = false;
                if (status == AsyncStatus::Ready) found->second.dirtyApron = false;
            }
            it = aprons.erase(it);
        }
    }

    id<MTLRenderPipelineState> compositePipelineForFormat(MTLPixelFormat format) {
        NSNumber* key = @(static_cast<NSUInteger>(format));
        id<MTLRenderPipelineState> pipeline = compositePipelines[key];
        if (pipeline) return pipeline;
        id<MTLFunction> vertex = [library newFunctionWithName:@"dt_metal_tile_vertex"];
        id<MTLFunction> fragment = [library newFunctionWithName:@"dt_metal_tile_fragment"];
        if (!vertex || !fragment) {
            fail(@"Metal tile composite functions are missing from the default library");
            return nil;
        }
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        configureBlendAttachment(descriptor.colorAttachments[0], format,
                                  DabBlendMode::SourceOver);
        NSError* pipelineError = nil;
        pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
        if (!pipeline) {
            fail(pipelineError.localizedDescription ?: @"Unable to create tile composite pipeline");
            return nil;
        }
        compositePipelines[key] = pipeline;
        return pipeline;
    }
};

Backend::Backend(std::unique_ptr<Impl> implementation) noexcept
    : impl_(std::move(implementation)) {}

Backend::~Backend() = default;
Backend::Backend(Backend&&) noexcept = default;
Backend& Backend::operator=(Backend&&) noexcept = default;

std::unique_ptr<Backend> Backend::create(void* nativeDevice,
                                         BackendOptions options,
                                         std::string* error) {
    id<MTLDevice> device = nativeDevice ? (__bridge id<MTLDevice>)nativeDevice : nil;
    if (!device) {
        if (error) *error = "A valid MTLDevice is required";
        return nullptr;
    }
    auto implementation = std::make_unique<Impl>(device, options);
    if (!implementation->buildPipelines()) {
        if (error) *error = implementation->error;
        return nullptr;
    }
    return std::unique_ptr<Backend>(new Backend(std::move(implementation)));
}

BackendResult Backend::beginTransaction(void* nativeCommandBuffer,
                                         std::uint64_t operationId,
                                         std::span<const TileAddress> touchedTiles) {
    const BackendResult started = beginTransaction(nativeCommandBuffer, operationId);
    if (started != BackendResult::ok) return started;
    if (touchedTiles.empty()) return BackendResult::ok;
    const BackendResult extended = extendTransactionTiles(nativeCommandBuffer, operationId, touchedTiles);
    if (extended != BackendResult::ok) (void)cancelTransaction(operationId);
    return extended;
}

BackendResult Backend::beginTransaction(void* nativeCommandBuffer,
                                         std::uint64_t operationId) {
    if (!impl_ || !nativeCommandBuffer || operationId == 0) {
        return BackendResult::invalidArgument;
    }
    impl_->reconcileAsync();
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer || impl_->activeOperation != 0) return BackendResult::invalidArgument;
    impl_->activeTiles.clear();
    impl_->activeBefore.clear();
    impl_->activeOperation = operationId;
    impl_->activeCommitPending = false;
    return BackendResult::ok;
}

BackendResult Backend::extendTransactionTiles(void* nativeCommandBuffer,
                                              std::uint64_t operationId,
                                              std::span<const TileAddress> touchedTiles) {
    if (!impl_ || !nativeCommandBuffer || operationId == 0 ||
        impl_->activeOperation != operationId || impl_->activeCommitPending ||
        touchedTiles.empty()) {
        return BackendResult::invalidArgument;
    }
    impl_->reconcileAsync();
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;
    for (const TileAddress address : touchedTiles) {
        const auto key = address.key();
        if (!impl_->activeTiles.insert(key).second) continue;
        TileResource* tile = impl_->ensureTile(address);
        if (!tile || tile->inFlight || tile->apronInFlight) {
            impl_->activeTiles.erase(key);
            impl_->activeBefore.erase(key);
            return BackendResult::resourceFailure;
        }
        impl_->activeBefore.emplace(key, TileVersionRef{
            address, tile->contentGeneration, tile->hasCommitted});
        // A caller can append a tile to a live stroke after previous batches
        // have already been encoded.  Preserve an existing working copy (for
        // the rare legacy implicit-stroke path), otherwise clone committed.
        if (!tile->hasWorking && !impl_->copyVersionToWorking(commandBuffer, *tile)) {
            impl_->activeTiles.erase(key);
            impl_->activeBefore.erase(key);
            return BackendResult::encodingFailure;
        }
        tile->dirtyApron = true;
    }
    return BackendResult::ok;
}

BackendResult Backend::encodeDabs(void* nativeCommandBuffer,
                                  const TileDabBatch& batch) {
    return encodeDabs(nativeCommandBuffer, batch, DabBlendMode::SourceOver);
}

BackendResult Backend::encodeDabs(void* nativeCommandBuffer,
                                  std::span<const TileDabBatch> batches) {
    return encodeDabs(nativeCommandBuffer, batches, DabBlendMode::SourceOver);
}

BackendResult Backend::encodeDabs(void* nativeCommandBuffer,
                                  const TileDabBatch& batch,
                                  DabBlendMode blendMode) {
    return encodeDabs(nativeCommandBuffer,
                      std::span<const TileDabBatch>(&batch, 1), blendMode);
}

BackendResult Backend::encodeDabs(void* nativeCommandBuffer,
                                  std::span<const TileDabBatch> batches,
                                  DabBlendMode blendMode) {
    if (!impl_ || !nativeCommandBuffer || batches.empty()) return BackendResult::invalidArgument;
    const auto abortTransactionOnError = [&](BackendResult result) {
        if (impl_->activeOperation != 0) (void)cancelTransaction(impl_->activeOperation);
        return result;
    };
    impl_->reconcileAsync();
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;

    // A real sample supersedes any prediction.  Invalidate previews before
    // writing working pixels so stale predicted tails can never be selected
    // by the composite pass.
    if (impl_->activeOperation != 0) {
        for (const auto activeKey : impl_->activeTiles) {
            auto found = impl_->tiles.find(activeKey);
            if (found != impl_->tiles.end()) {
                found->second.hasPreview = false;
                found->second.preview = {};
            }
        }
    }

    for (const TileDabBatch& batch : batches) {
        if (batch.dabs.empty()) continue;
        const auto key = batch.tile.key();
        TileResource* tile = impl_->ensureTile(batch.tile);
        if (!tile || tile->inFlight || tile->apronInFlight) {
            return abortTransactionOnError(BackendResult::resourceFailure);
        }
        if (impl_->activeOperation != 0 &&
            impl_->activeTiles.find(key) == impl_->activeTiles.end()) {
            const TileAddress discovered = batch.tile;
            const BackendResult enlisted = extendTransactionTiles(
                nativeCommandBuffer, impl_->activeOperation,
                std::span<const TileAddress>(&discovered, 1));
            if (enlisted != BackendResult::ok) return abortTransactionOnError(enlisted);
        }
        if (!tile->hasWorking && !impl_->copyVersionToWorking(commandBuffer, *tile)) {
            return abortTransactionOnError(BackendResult::encodingFailure);
        }
        if (!impl_->allocateVersion(tile->working)) {
            return abortTransactionOnError(BackendResult::resourceFailure);
        }
        id<MTLBuffer> instances = [impl_->device newBufferWithBytes:batch.dabs.data()
                                                               length:batch.dabs.size_bytes()
                                                              options:MTLResourceStorageModeShared];
        if (!instances) {
            impl_->fail(@"Unable to allocate dab instance buffer");
            return abortTransactionOnError(BackendResult::resourceFailure);
        }
        DabUniforms uniforms{{static_cast<float>(kTileTextureExtent),
                              static_cast<float>(kTileTextureExtent)},
                             static_cast<float>(kTileApron), 0.0f};
        MTLRenderPassDescriptor* colorPass = tilePass(tile->working.color,
                                                        tile->working.colorInitialized);
        id<MTLRenderCommandEncoder> colorEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:colorPass];
        if (!colorEncoder) return abortTransactionOnError(BackendResult::encodingFailure);
        [colorEncoder setRenderPipelineState:impl_->dabPipeline(
            MTLPixelFormatRGBA8Unorm, blendMode)];
        [colorEncoder setVertexBuffer:instances offset:0 atIndex:0];
        [colorEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [colorEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                          vertexCount:6 instanceCount:static_cast<NSUInteger>(batch.dabs.size())];
        [colorEncoder endEncoding];
        tile->working.colorInitialized = true;

        MTLRenderPassDescriptor* coveragePass = tilePass(tile->working.coverage,
                                                           tile->working.coverageInitialized);
        id<MTLRenderCommandEncoder> coverageEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:coveragePass];
        if (!coverageEncoder) return abortTransactionOnError(BackendResult::encodingFailure);
        [coverageEncoder setRenderPipelineState:impl_->dabPipeline(
            MTLPixelFormatR8Unorm, blendMode)];
        [coverageEncoder setVertexBuffer:instances offset:0 atIndex:0];
        [coverageEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [coverageEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                              vertexCount:6 instanceCount:static_cast<NSUInteger>(batch.dabs.size())];
        [coverageEncoder endEncoding];
        tile->working.coverageInitialized = true;
        tile->working.generation = tile->contentGeneration;
        tile->hasWorking = true;
        tile->dirtyApron = true;
        impl_->markDirtyNeighborhood(batch.tile);
    }
    return BackendResult::ok;
}

BackendResult Backend::encodePredictedDabs(void* nativeCommandBuffer,
                                           std::span<const TileDabBatch> batches,
                                           DabBlendMode blendMode) {
    if (!impl_ || !nativeCommandBuffer || impl_->activeOperation == 0) {
        return BackendResult::invalidArgument;
    }
    const auto abortTransactionOnError = [&](BackendResult result) {
        if (impl_->activeOperation != 0) (void)cancelTransaction(impl_->activeOperation);
        return result;
    };
    impl_->reconcileAsync();
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;

    // Start each prediction from working, replacing the previous preview.
    for (const auto key : impl_->activeTiles) {
        auto found = impl_->tiles.find(key);
        if (found != impl_->tiles.end()) {
            found->second.hasPreview = false;
            // Allocate a fresh preview resource for each prediction so a
            // previous command buffer may still sample its old texture.
            found->second.preview = {};
        }
    }
    std::unordered_set<std::int64_t> copied;
    for (const TileDabBatch& batch : batches) {
        const auto key = batch.tile.key();
        if (impl_->activeTiles.find(key) == impl_->activeTiles.end()) {
            const TileAddress discovered = batch.tile;
            const BackendResult enlisted = extendTransactionTiles(
                nativeCommandBuffer, impl_->activeOperation,
                std::span<const TileAddress>(&discovered, 1));
            if (enlisted != BackendResult::ok) return abortTransactionOnError(enlisted);
        }
        TileResource& tile = impl_->tiles.at(key);
        if (!tile.hasWorking) return abortTransactionOnError(BackendResult::resourceFailure);
        if (copied.insert(key).second) {
            if (!impl_->allocateVersion(tile.preview)) {
                return abortTransactionOnError(BackendResult::resourceFailure);
            }
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            if (!blit) return abortTransactionOnError(BackendResult::encodingFailure);
            copyTexture(blit, tile.working.color, tile.preview.color);
            copyTexture(blit, tile.working.coverage, tile.preview.coverage);
            [blit endEncoding];
            tile.preview.colorInitialized = tile.working.colorInitialized;
            tile.preview.coverageInitialized = tile.working.coverageInitialized;
            tile.preview.generation = tile.working.generation;
            tile.hasPreview = true;
        }
    }
    if (batches.empty()) {
        for (const auto key : impl_->activeTiles) {
            auto found = impl_->tiles.find(key);
            if (found != impl_->tiles.end()) found->second.hasPreview = false;
        }
        return BackendResult::ok;
    }

    for (const TileDabBatch& batch : batches) {
        if (batch.dabs.empty()) continue;
        TileResource& tile = impl_->tiles.at(batch.tile.key());
        id<MTLBuffer> instances = [impl_->device newBufferWithBytes:batch.dabs.data()
                                                               length:batch.dabs.size_bytes()
                                                              options:MTLResourceStorageModeShared];
        if (!instances) return abortTransactionOnError(BackendResult::resourceFailure);
        DabUniforms uniforms{{static_cast<float>(kTileTextureExtent),
                              static_cast<float>(kTileTextureExtent)},
                             static_cast<float>(kTileApron), 0.0f};
        MTLRenderPassDescriptor* colorPass = tilePass(tile.preview.color,
                                                        tile.preview.colorInitialized);
        id<MTLRenderCommandEncoder> colorEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:colorPass];
        if (!colorEncoder) return abortTransactionOnError(BackendResult::encodingFailure);
        [colorEncoder setRenderPipelineState:impl_->dabPipeline(
            MTLPixelFormatRGBA8Unorm, blendMode)];
        [colorEncoder setVertexBuffer:instances offset:0 atIndex:0];
        [colorEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [colorEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
                           instanceCount:static_cast<NSUInteger>(batch.dabs.size())];
        [colorEncoder endEncoding];
        tile.preview.colorInitialized = true;

        MTLRenderPassDescriptor* coveragePass = tilePass(tile.preview.coverage,
                                                           tile.preview.coverageInitialized);
        id<MTLRenderCommandEncoder> coverageEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:coveragePass];
        if (!coverageEncoder) return abortTransactionOnError(BackendResult::encodingFailure);
        [coverageEncoder setRenderPipelineState:impl_->dabPipeline(
            MTLPixelFormatR8Unorm, blendMode)];
        [coverageEncoder setVertexBuffer:instances offset:0 atIndex:0];
        [coverageEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [coverageEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
                           instanceCount:static_cast<NSUInteger>(batch.dabs.size())];
        [coverageEncoder endEncoding];
        tile.preview.coverageInitialized = true;
    }
    return BackendResult::ok;
}

BackendResult Backend::discardPrediction(void* nativeCommandBuffer) {
    if (!impl_ || !nativeCommandBuffer || impl_->activeOperation == 0) {
        return BackendResult::invalidArgument;
    }
    if (!commandBufferFrom(nativeCommandBuffer)) return BackendResult::invalidArgument;
    for (const auto key : impl_->activeTiles) {
        const auto found = impl_->tiles.find(key);
        if (found != impl_->tiles.end()) {
            found->second.hasPreview = false;
            found->second.preview = {};
        }
    }
    return BackendResult::ok;
}

BackendResult Backend::encodeCommit(void* nativeCommandBuffer,
                                    std::uint64_t operationId) {
    // Generation assignment belongs to the document coordinator.  Keep the
    // legacy overload source-compatible, but reject it instead of inventing
    // a renderer-local generation that could race persistence/undo.
    if (impl_) impl_->fail(@"encodeCommit requires the coordinator-assigned generation");
    (void)nativeCommandBuffer;
    (void)operationId;
    return BackendResult::invalidArgument;
}

BackendResult Backend::encodeCommit(void* nativeCommandBuffer,
                                    std::uint64_t operationId,
                                    std::uint64_t generation) {
    if (!impl_ || !nativeCommandBuffer || operationId == 0 ||
        generation == 0 ||
        generation <= impl_->nextGeneration ||
        impl_->activeOperation != operationId || impl_->activeCommitPending) {
        return BackendResult::invalidArgument;
    }
    impl_->reconcileAsync();
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;

    auto state = std::make_shared<CommitState>();
    state->operationId = operationId;
    state->generation = generation;
    state->versions.before.operationId = operationId;
    state->versions.after.operationId = operationId;
    state->versions.after.generation = state->generation;
    state->versions.before.tiles.reserve(impl_->activeTiles.size());
    state->versions.after.tiles.reserve(impl_->activeTiles.size());

    // Preflight all tiles before changing any in-flight flags; an allocation
    // or stale tile on one entry must not leave earlier entries half-committed.
    for (const auto key : impl_->activeTiles) {
        const auto tileFound = impl_->tiles.find(key);
        if (tileFound == impl_->tiles.end() || tileFound->second.inFlight ||
            !tileFound->second.hasWorking) return BackendResult::resourceFailure;
    }
    for (const auto key : impl_->activeTiles) {
        TileResource& tile = impl_->tiles.at(key);
        tile.inFlight = true;
        state->versions.before.tiles.push_back(impl_->activeBefore.at(key));
        state->versions.after.tiles.push_back({tile.address, state->generation, true});
        tile.working.generation = state->generation;
        state->working.emplace(key, tile.working);
    }
    impl_->activeCommitPending = true;
    impl_->commits[operationId] = state;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        state->status.store(isCompleted(completed) ? AsyncStatus::Ready : AsyncStatus::Failed,
                            std::memory_order_release);
    }];
    return BackendResult::ok;
}

std::optional<TileCommitVersions> Backend::takeCompletedCommit(
    std::uint64_t operationId) {
    if (!impl_ || operationId == 0) return std::nullopt;
    impl_->reconcileAsync();
    const auto found = impl_->commits.find(operationId);
    if (found == impl_->commits.end()) return std::nullopt;
    const auto& state = found->second;
    const AsyncStatus status = state->status.load(std::memory_order_acquire);
    if (status == AsyncStatus::Pending) return std::nullopt;

    const bool success = status == AsyncStatus::Ready;
    if (success) impl_->nextGeneration = std::max(impl_->nextGeneration, state->generation);
    for (const auto key : impl_->activeTiles) {
        auto tileFound = impl_->tiles.find(key);
        if (tileFound == impl_->tiles.end()) continue;
        TileResource& tile = tileFound->second;
        tile.inFlight = false;
        if (success) {
            if (tile.hasCommitted) tile.history[tile.committed.generation] = tile.committed;
            tile.committed = state->working.at(key);
            tile.committed.generation = state->generation;
            tile.hasCommitted = true;
            tile.contentGeneration = state->generation;
            tile.hasWorking = false;
            tile.hasPreview = false;
            // Do not leave working aliased to committed: the next
            // transaction must allocate/copy a distinct COW resource.
            tile.working = {};
            tile.preview = {};
            tile.dirtyApron = true;
            impl_->markDirtyNeighborhood(tile.address);
        } else {
            // A failed command buffer never publishes its working generation;
            // discard both transient resources so a later transaction cannot
            // accidentally commit pixels from a failed GPU submission.
            tile.hasWorking = false;
            tile.hasPreview = false;
            tile.working = {};
            tile.preview = {};
            tile.dirtyApron = false;
        }
    }
    TileCommitVersions result = state->versions;
    result.succeeded = success;
    impl_->commits.erase(found);
    impl_->activeOperation = 0;
    impl_->activeCommitPending = false;
    impl_->activeTiles.clear();
    impl_->activeBefore.clear();
    return result;
}

BackendResult Backend::cancelTransaction(std::uint64_t operationId) noexcept {
    if (!impl_ || operationId == 0 || impl_->activeOperation != operationId) {
        return BackendResult::invalidArgument;
    }
    if (impl_->activeCommitPending) return BackendResult::resourceFailure;
    for (const auto key : impl_->activeTiles) {
        const auto found = impl_->tiles.find(key);
        if (found == impl_->tiles.end()) continue;
        TileResource& tile = found->second;
        if (tile.inFlight || tile.apronInFlight) return BackendResult::resourceFailure;
        tile.hasWorking = false;
        tile.hasPreview = false;
        tile.working = {};
        tile.preview = {};
        tile.dirtyApron = false;
    }
    impl_->activeTiles.clear();
    impl_->activeBefore.clear();
    impl_->activeOperation = 0;
    impl_->activeCommitPending = false;
    return BackendResult::ok;
}

BackendResult Backend::encodeRestoreVersions(void* nativeCommandBuffer,
                                             const TileVersionSet& versions) {
    if (!impl_ || !nativeCommandBuffer || versions.tiles.empty() ||
        impl_->activeOperation == 0) return BackendResult::invalidArgument;
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;
    for (const TileVersionRef& reference : versions.tiles) {
        const auto key = reference.tile.key();
        if (impl_->activeTiles.find(key) == impl_->activeTiles.end()) {
            return BackendResult::invalidArgument;
        }
        TileResource& tile = impl_->tiles.at(key);
        if (tile.inFlight) return BackendResult::resourceFailure;
        if (!tile.hasWorking && !impl_->copyVersionToWorking(commandBuffer, tile)) {
            return BackendResult::encodingFailure;
        }
        if (!reference.exists || reference.generation == 0) {
            tile.working.colorInitialized = false;
            tile.working.coverageInitialized = false;
            tile.dirtyApron = true;
            impl_->markDirtyNeighborhood(reference.tile);
            continue;
        }
        VersionTextures* source = Impl::findVersion(tile, reference.generation);
        if (!source || !source->color || !source->coverage) return BackendResult::resourceFailure;
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        if (!blit) return BackendResult::encodingFailure;
        copyTexture(blit, source->color, tile.working.color);
        copyTexture(blit, source->coverage, tile.working.coverage);
        [blit endEncoding];
        tile.working.colorInitialized = source->colorInitialized;
        tile.working.coverageInitialized = source->coverageInitialized;
        tile.working.generation = reference.generation;
        tile.dirtyApron = true;
        impl_->markDirtyNeighborhood(reference.tile);
    }
    return BackendResult::ok;
}

BackendResult Backend::encodeCheckpoint(void* nativeCommandBuffer,
                                        std::span<const TileVersionRef> versions,
                                        std::vector<CheckpointTicket>& tickets) {
    if (!impl_ || !nativeCommandBuffer || versions.empty()) return BackendResult::invalidArgument;
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;
    tickets.clear();
    for (const TileVersionRef& reference : versions) {
        CheckpointTicket ticket{impl_->nextCheckpoint++, reference.tile,
                                reference.generation, kTileInteriorRGBABytes};
        auto state = std::make_shared<CheckpointState>();
        state->ticket = ticket;
        state->buffer = [impl_->device newBufferWithLength:kTileInteriorRGBABytes
                                                   options:MTLResourceStorageModeShared];
        if (!state->buffer) return BackendResult::resourceFailure;
        const auto found = impl_->tiles.find(reference.tile.key());
        VersionTextures* source = nullptr;
        if (found != impl_->tiles.end() && reference.exists) {
            if (found->second.inFlight) return BackendResult::resourceFailure;
            source = Impl::findVersion(found->second, reference.generation);
            // Working/preview resources are writable and therefore cannot be
            // handed to persistence as an immutable checkpoint.  Callers must
            // request the last completed committed/history generation.
            if (source && impl_->activeOperation != 0 &&
                (source == &found->second.working || source == &found->second.preview)) {
                return BackendResult::resourceFailure;
            }
        }
        if (source && source->colorInitialized) {
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            if (!blit) return BackendResult::encodingFailure;
            [blit copyFromTexture:source->color sourceSlice:0 sourceLevel:0
                      sourceOrigin:MTLOriginMake(kTileApron, kTileApron, 0)
                        sourceSize:MTLSizeMake(kTileSize, kTileSize, 1)
                         toBuffer:state->buffer destinationOffset:0
                    destinationBytesPerRow:kTileSize * 4
                  destinationBytesPerImage:kTileInteriorRGBABytes];
            [blit endEncoding];
        } else {
            std::memset([state->buffer contents], 0, kTileInteriorRGBABytes);
        }
        impl_->checkpoints.emplace(ticket.id, state);
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            state->status.store(isCompleted(completed) ? AsyncStatus::Ready : AsyncStatus::Failed,
                                std::memory_order_release);
        }];
        tickets.push_back(ticket);
    }
    return BackendResult::ok;
}

CheckpointStatus Backend::checkpointStatus(CheckpointTicket ticket) const noexcept {
    if (!impl_ || !ticket) return CheckpointStatus::Failed;
    const auto found = impl_->checkpoints.find(ticket.id);
    if (found == impl_->checkpoints.end()) return CheckpointStatus::Failed;
    switch (found->second->status.load(std::memory_order_acquire)) {
    case AsyncStatus::Pending: return CheckpointStatus::Pending;
    case AsyncStatus::Ready: return CheckpointStatus::Ready;
    case AsyncStatus::Failed: return CheckpointStatus::Failed;
    }
    return CheckpointStatus::Failed;
}

BackendResult Backend::readCheckpoint(CheckpointTicket ticket,
                                      std::span<std::uint8_t> destination) const {
    if (!impl_ || !ticket || destination.size() < kTileInteriorRGBABytes) {
        return BackendResult::invalidArgument;
    }
    const auto found = impl_->checkpoints.find(ticket.id);
    if (found == impl_->checkpoints.end()) return BackendResult::invalidArgument;
    const AsyncStatus status = found->second->status.load(std::memory_order_acquire);
    if (status == AsyncStatus::Pending) return BackendResult::pending;
    if (status == AsyncStatus::Failed || !found->second->buffer) return BackendResult::resourceFailure;
    std::memcpy(destination.data(), [found->second->buffer contents], kTileInteriorRGBABytes);
    return BackendResult::ok;
}

void Backend::releaseCheckpoint(CheckpointTicket ticket) noexcept {
    if (!impl_ || !ticket) return;
    const auto found = impl_->checkpoints.find(ticket.id);
    if (found == impl_->checkpoints.end()) return;
    if (found->second->status.load(std::memory_order_acquire) == AsyncStatus::Pending) return;
    impl_->checkpoints.erase(found);
}

BackendResult Backend::uploadPersistedTileBytes(void* nativeCommandBuffer,
                                                TileAddress address,
                                                std::uint64_t generation,
                                                std::span<const std::uint8_t> bytes) {
    if (!impl_ || !nativeCommandBuffer || generation == 0 ||
        bytes.size() != kTileInteriorRGBABytes) return BackendResult::invalidArgument;
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;
    TileResource* tile = impl_->ensureTile(address);
    if (!tile || tile->inFlight || tile->apronInFlight || impl_->activeOperation != 0) {
        return BackendResult::resourceFailure;
    }
    auto state = std::make_shared<UploadState>();
    state->tile = address;
    state->generation = generation;
    if (!impl_->allocateVersion(state->version)) return BackendResult::resourceFailure;
    id<MTLBuffer> staging = [impl_->device newBufferWithBytes:bytes.data()
                                                        length:bytes.size()
                                                       options:MTLResourceStorageModeShared];
    if (!staging) return BackendResult::resourceFailure;
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) return BackendResult::encodingFailure;
    [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:kTileSize * 4
          sourceBytesPerImage:kTileInteriorRGBABytes sourceSize:MTLSizeMake(kTileSize, kTileSize, 1)
                 toTexture:state->version.color destinationSlice:0 destinationLevel:0
             destinationOrigin:MTLOriginMake(kTileApron, kTileApron, 0)];
    [blit endEncoding];
    state->version.colorInitialized = true;
    state->version.coverageInitialized = false;
    tile->inFlight = true;
    impl_->uploads.push_back(state);
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        state->status.store(isCompleted(completed) ? AsyncStatus::Ready : AsyncStatus::Failed,
                            std::memory_order_release);
    }];
    return BackendResult::ok;
}

std::size_t Backend::releaseHistoricalVersions(
    std::span<const TileVersionRef> versions) noexcept {
    if (!impl_) return 0;
    impl_->reconcileAsync();
    std::size_t released = 0;
    for (const TileVersionRef& reference : versions) {
        const auto tileFound = impl_->tiles.find(reference.tile.key());
        if (tileFound == impl_->tiles.end()) continue;
        TileResource& tile = tileFound->second;
        if (tile.inFlight || tile.apronInFlight || tile.hasWorking || tile.hasPreview) continue;
        if (tile.hasCommitted && tile.committed.generation == reference.generation) continue;
        const auto versionFound = tile.history.find(reference.generation);
        if (versionFound != tile.history.end()) {
            tile.history.erase(versionFound);
            ++released;
        }
    }
    return released;
}

BackendResult Backend::encodeComposite(void* nativeCommandBuffer,
                                       void* nativeTargetTexture,
                                       std::span<const TileAddress> visibleTiles,
                                       const CompositeParameters& parameters) {
    if (!impl_ || !nativeCommandBuffer || !nativeTargetTexture ||
        parameters.viewportSize.x <= 0.0f || parameters.viewportSize.y <= 0.0f) {
        return BackendResult::invalidArgument;
    }
    impl_->reconcileAsync();
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    id<MTLTexture> target = textureFrom(nativeTargetTexture);
    if (!commandBuffer || !target) return BackendResult::invalidArgument;
    id<MTLRenderPipelineState> pipeline = impl_->compositePipelineForFormat(target.pixelFormat);
    if (!pipeline) return BackendResult::resourceFailure;

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return BackendResult::encodingFailure;
    [encoder setRenderPipelineState:pipeline];
    CompositeUniforms uniforms{parameters.scale,
                               parameters.rotationRadians,
                               {parameters.translation.x, parameters.translation.y},
                               {parameters.viewportSize.x, parameters.viewportSize.y},
                               std::clamp(parameters.opacity, 0.0f, 1.0f),
                               {0.0f, 0.0f}};
    for (const TileAddress address : visibleTiles) {
        const auto found = impl_->tiles.find(address.key());
        if (found == impl_->tiles.end()) continue;
        TileResource& tile = found->second;
        VersionTextures* version = impl_->compositeVersion(tile);
        if (!version || !version->colorInitialized) continue;
        tile.lastUse = ++impl_->clock;
        const Vec2 origin = address.origin(kTileSize);
        uniforms.tileOrigin = {origin.x, origin.y};
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentTexture:version->color atIndex:0];
        [encoder setFragmentSamplerState:impl_->tileSampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
    return BackendResult::ok;
}

BackendResult Backend::encodeApronResolve(void* nativeCommandBuffer) {
    if (!impl_ || !nativeCommandBuffer) return BackendResult::invalidArgument;
    impl_->reconcileAsync();
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;
    if (!impl_->ensureTransparentTextures()) return BackendResult::resourceFailure;
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) return BackendResult::encodingFailure;
    auto state = std::make_shared<ApronState>();
    const NSUInteger edge = static_cast<NSUInteger>(kTileApron);
    const NSUInteger last = edge + static_cast<NSUInteger>(kTileSize) - 1;
    const NSUInteger farApron = static_cast<NSUInteger>(kTileTextureExtent) - 1;
    for (auto& entry : impl_->tiles) {
        TileResource& destination = entry.second;
        if (!destination.dirtyApron || destination.inFlight || destination.apronInFlight) continue;
        VersionTextures* target = impl_->compositeVersion(destination);
        if (!target) continue;
        bool touched = false;
        const TileAddress address = destination.address;
        auto clearApron = [&](id<MTLTexture> source,
                              id<MTLTexture> destinationTexture) {
            if (!source || !destinationTexture) return;
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(0, edge, 0),
                        MTLSizeMake(1, kTileSize, 1));
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(farApron, edge, 0),
                        MTLSizeMake(1, kTileSize, 1));
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(edge, 0, 0),
                        MTLSizeMake(kTileSize, 1, 1));
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(edge, farApron, 0),
                        MTLSizeMake(kTileSize, 1, 1));
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(0, 0, 0),
                        MTLSizeMake(1, 1, 1));
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(farApron, 0, 0),
                        MTLSizeMake(1, 1, 1));
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(0, farApron, 0),
                        MTLSizeMake(1, 1, 1));
            copyTexture(blit, source, destinationTexture,
                        MTLOriginMake(0, 0, 0), MTLOriginMake(farApron, farApron, 0),
                        MTLSizeMake(1, 1, 1));
        };
        // Reset every apron texel first.  Present neighbor edges below then
        // overwrite the corresponding strips; missing neighbors remain
        // transparent rather than retaining stale pixels.
        clearApron(impl_->transparentColor, target->color);
        clearApron(impl_->transparentCoverage, target->coverage);
        auto copyFromNeighbor = [&](int dx, int dy,
                                    MTLOrigin sourceOrigin,
                                    MTLOrigin destinationOrigin,
                                    MTLSize size) {
            const auto neighborFound = impl_->tiles.find(
                TileAddress{address.x + dx, address.y + dy}.key());
            if (neighborFound == impl_->tiles.end()) return;
            VersionTextures* source = impl_->compositeVersion(neighborFound->second);
            if (!source) return;
            if (source->colorInitialized && target->color) {
                copyTexture(blit, source->color, target->color, sourceOrigin,
                            destinationOrigin, size);
                target->colorInitialized = true;
                touched = true;
            }
            if (source->coverageInitialized && target->coverage) {
                copyTexture(blit, source->coverage, target->coverage, sourceOrigin,
                            destinationOrigin, size);
                target->coverageInitialized = true;
                touched = true;
            }
        };
        copyFromNeighbor(-1, 0, MTLOriginMake(last, edge, 0),
                         MTLOriginMake(0, edge, 0), MTLSizeMake(1, kTileSize, 1));
        copyFromNeighbor(1, 0, MTLOriginMake(edge, edge, 0),
                         MTLOriginMake(farApron, edge, 0), MTLSizeMake(1, kTileSize, 1));
        copyFromNeighbor(0, -1, MTLOriginMake(edge, last, 0),
                         MTLOriginMake(edge, 0, 0), MTLSizeMake(kTileSize, 1, 1));
        copyFromNeighbor(0, 1, MTLOriginMake(edge, edge, 0),
                         MTLOriginMake(edge, farApron, 0), MTLSizeMake(kTileSize, 1, 1));
        copyFromNeighbor(-1, -1, MTLOriginMake(last, last, 0),
                         MTLOriginMake(0, 0, 0), MTLSizeMake(1, 1, 1));
        copyFromNeighbor(1, -1, MTLOriginMake(edge, last, 0),
                         MTLOriginMake(farApron, 0, 0), MTLSizeMake(1, 1, 1));
        copyFromNeighbor(-1, 1, MTLOriginMake(last, edge, 0),
                         MTLOriginMake(0, farApron, 0), MTLSizeMake(1, 1, 1));
        copyFromNeighbor(1, 1, MTLOriginMake(edge, edge, 0),
                         MTLOriginMake(farApron, farApron, 0), MTLSizeMake(1, 1, 1));
        // Even when all neighbors are missing, the command establishes that
        // transparent apron texels were considered.  Future neighbor uploads
        // mark this tile dirty again; keeping it dirty forever would make a
        // clean zero-apron tile impossible to evict.
        (void)touched;
        destination.apronInFlight = true;
        state->tiles.push_back(entry.first);
    }
    [blit endEncoding];
    if (state->tiles.empty()) return BackendResult::ok;
    impl_->aprons.push_back(state);
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        state->status.store(isCompleted(completed) ? AsyncStatus::Ready : AsyncStatus::Failed,
                            std::memory_order_release);
    }];
    return BackendResult::ok;
}

std::optional<TileStateInfo> Backend::tileState(TileAddress address) const noexcept {
    if (!impl_) return std::nullopt;
    const_cast<Impl*>(impl_.get())->reconcileAsync();
    const auto found = impl_->tiles.find(address.key());
    if (found == impl_->tiles.end()) return std::nullopt;
    const TileResource& tile = found->second;
    TileStateInfo info;
    info.tile = address;
    info.contentGeneration = tile.contentGeneration;
    info.persistedGeneration = tile.persistedGeneration;
    info.residency = tile.inFlight || tile.apronInFlight
        ? TileResidency::CheckpointPending
        : (tile.hasCommitted && tile.contentGeneration == tile.persistedGeneration
            ? TileResidency::ResidentClean : TileResidency::ResidentDirty);
    info.hasCommittedVersion = tile.hasCommitted;
    info.hasWorkingVersion = tile.hasWorking;
    info.hasPreviewVersion = tile.hasPreview;
    info.dirtyApron = tile.dirtyApron;
    info.inFlight = tile.inFlight || tile.apronInFlight;
    return info;
}

std::size_t Backend::residentTileCount() const noexcept {
    if (!impl_) return 0;
    const_cast<Impl*>(impl_.get())->reconcileAsync();
    return impl_->tiles.size();
}

void* Backend::nativeCoverageTexture(TileAddress address) const noexcept {
    if (!impl_) return nullptr;
    const_cast<Impl*>(impl_.get())->reconcileAsync();
    const auto found = impl_->tiles.find(address.key());
    if (found == impl_->tiles.end()) return nullptr;
    VersionTextures* version = const_cast<Impl*>(impl_.get())->compositeVersion(found->second);
    if (!version || !version->coverageInitialized) return nullptr;
    return (__bridge void*)version->coverage;
}

void Backend::purgeTiles() noexcept {
    if (!impl_) return;
    impl_->reconcileAsync();
    for (auto it = impl_->tiles.begin(); it != impl_->tiles.end();) {
        const TileResource& tile = it->second;
        const bool safe = !tile.inFlight && !tile.apronInFlight &&
                          !tile.hasWorking && !tile.hasPreview && !tile.dirtyApron &&
                          (!tile.hasCommitted || tile.contentGeneration == tile.persistedGeneration);
        if (safe) it = impl_->tiles.erase(it);
        else ++it;
    }
}

const std::string& Backend::lastError() const noexcept {
    static const std::string empty;
    return impl_ ? impl_->error : empty;
}

} // namespace drafting_table::metal
