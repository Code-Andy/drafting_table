#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <simd/simd.h>

#include "DTMetalTileRenderer.hpp"

#include <algorithm>
#include <cmath>
#include <unordered_map>
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

struct TileResource {
    id<MTLTexture> color = nil;
    id<MTLTexture> coverage = nil;
    bool colorInitialized = false;
    bool coverageInitialized = false;
    std::uint64_t lastUse = 0;
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

static void configureOverAttachment(
    MTLRenderPipelineColorAttachmentDescriptor* attachment,
    MTLPixelFormat format) {
    attachment.pixelFormat = format;
    attachment.blendingEnabled = YES;
    // Color values are premultiplied.  This is the Porter-Duff OVER equation:
    // out = src + dst * (1 - src.a).
    attachment.rgbBlendOperation = MTLBlendOperationAdd;
    attachment.alphaBlendOperation = MTLBlendOperationAdd;
    attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
    attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
    attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
}

static void configureMaxCoverageAttachment(
    MTLRenderPipelineColorAttachmentDescriptor* attachment) {
    attachment.pixelFormat = MTLPixelFormatR8Unorm;
    attachment.blendingEnabled = YES;
    // R8's red channel is coverage.  MAX makes overlapping dabs idempotent,
    // avoiding darkening when a dab is emitted to more than one batch.
    attachment.rgbBlendOperation = MTLBlendOperationMax;
    attachment.alphaBlendOperation = MTLBlendOperationMax;
    attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
    attachment.destinationRGBBlendFactor = MTLBlendFactorOne;
    attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
    attachment.destinationAlphaBlendFactor = MTLBlendFactorOne;
}

} // namespace

struct Backend::Impl {
    id<MTLDevice> device = nil;
    id<MTLLibrary> library = nil;
    id<MTLRenderPipelineState> dabColorPipeline = nil;
    id<MTLRenderPipelineState> dabCoveragePipeline = nil;
    id<MTLSamplerState> tileSampler = nil;
    NSMutableDictionary<NSNumber*, id<MTLRenderPipelineState>>* compositePipelines = nil;
    std::unordered_map<std::int64_t, TileResource> tiles;
    BackendOptions options{};
    std::uint64_t clock = 0;
    std::string error;

    explicit Impl(id<MTLDevice> selectedDevice, BackendOptions configured)
        : device(selectedDevice), options(configured) {
        compositePipelines = [NSMutableDictionary dictionary];
    }

    void fail(NSString* message) {
        error = message ? std::string([message UTF8String]) : "Metal backend error";
    }

    bool buildPipelines() {
        library = [device newDefaultLibrary];
        if (!library) {
            fail(@"newDefaultLibrary returned nil; add DTMetalShaders.metal to the iPad target");
            return false;
        }
        id<MTLFunction> dabVertex = [library newFunctionWithName:@"dt_metal_dab_vertex"];
        id<MTLFunction> colorFragment = [library newFunctionWithName:@"dt_metal_dab_color"];
        id<MTLFunction> coverageFragment = [library newFunctionWithName:@"dt_metal_dab_coverage"];
        if (!dabVertex || !colorFragment || !coverageFragment) {
            fail(@"Metal dab functions are missing from the default library");
            return false;
        }

        NSError* pipelineError = nil;
        MTLRenderPipelineDescriptor* colorDescriptor = [MTLRenderPipelineDescriptor new];
        colorDescriptor.vertexFunction = dabVertex;
        colorDescriptor.fragmentFunction = colorFragment;
        configureOverAttachment(colorDescriptor.colorAttachments[0],
                                MTLPixelFormatRGBA8Unorm);
        dabColorPipeline = [device newRenderPipelineStateWithDescriptor:colorDescriptor
                                                                   error:&pipelineError];
        if (!dabColorPipeline) {
            fail(pipelineError.localizedDescription ?: @"Unable to create dab color pipeline");
            return false;
        }

        pipelineError = nil;
        MTLRenderPipelineDescriptor* coverageDescriptor = [MTLRenderPipelineDescriptor new];
        coverageDescriptor.vertexFunction = dabVertex;
        coverageDescriptor.fragmentFunction = coverageFragment;
        configureMaxCoverageAttachment(coverageDescriptor.colorAttachments[0]);
        dabCoveragePipeline = [device newRenderPipelineStateWithDescriptor:coverageDescriptor
                                                                       error:&pipelineError];
        if (!dabCoveragePipeline) {
            fail(pipelineError.localizedDescription ?: @"Unable to create coverage pipeline");
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

    TileResource* ensureTile(TileAddress address) {
        const auto key = address.key();
        auto found = tiles.find(key);
        if (found != tiles.end()) {
            found->second.lastUse = ++clock;
            return &found->second;
        }
        if (options.maxResidentTiles != 0 &&
            tiles.size() >= options.maxResidentTiles) {
            fail(@"Resident tile limit reached; persist or purge before allocating another tile");
            return nullptr;
        }

        MTLTextureDescriptor* colorDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                 width:kTileTextureExtent
                                                                height:kTileTextureExtent
                                                             mipmapped:NO];
        colorDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        colorDescriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> color = [device newTextureWithDescriptor:colorDescriptor];

        MTLTextureDescriptor* coverageDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                 width:kTileTextureExtent
                                                                height:kTileTextureExtent
                                                             mipmapped:NO];
        coverageDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        coverageDescriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> coverage = [device newTextureWithDescriptor:coverageDescriptor];
        if (!color || !coverage) {
            fail(@"Unable to allocate 258x258 sparse tile textures");
            return nullptr;
        }

        TileResource resource;
        resource.color = color;
        resource.coverage = coverage;
        resource.lastUse = ++clock;
        auto [inserted, ok] = tiles.emplace(key, std::move(resource));
        return ok ? &inserted->second : nullptr;
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
        configureOverAttachment(descriptor.colorAttachments[0], format);
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

BackendResult Backend::encodeDabs(void* nativeCommandBuffer,
                                  const TileDabBatch& batch) {
    if (!impl_ || !nativeCommandBuffer || batch.dabs.empty()) return BackendResult::invalidArgument;
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;
    TileResource* tile = impl_->ensureTile(batch.tile);
    if (!tile) return BackendResult::resourceFailure;
    id<MTLBuffer> instances = [impl_->device newBufferWithBytes:batch.dabs.data()
                                                           length:batch.dabs.size_bytes()
                                                          options:MTLResourceStorageModeShared];
    if (!instances) {
        impl_->fail(@"Unable to allocate dab instance buffer");
        return BackendResult::resourceFailure;
    }
    DabUniforms uniforms{{static_cast<float>(kTileTextureExtent),
                          static_cast<float>(kTileTextureExtent)},
                         static_cast<float>(kTileApron), 0.0f};

    // Color pass: premultiplied OVER into the sparse tile.
    MTLRenderPassDescriptor* colorPass = tilePass(tile->color, tile->colorInitialized);
    id<MTLRenderCommandEncoder> colorEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:colorPass];
    if (!colorEncoder) return BackendResult::encodingFailure;
    [colorEncoder setRenderPipelineState:impl_->dabColorPipeline];
    [colorEncoder setVertexBuffer:instances offset:0 atIndex:0];
    [colorEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [colorEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                      vertexCount:6 instanceCount:static_cast<NSUInteger>(batch.dabs.size())];
    [colorEncoder endEncoding];
    tile->colorInitialized = true;

    // Coverage pass: independent max blend into R8 for hit-testing/selection.
    MTLRenderPassDescriptor* coveragePass = tilePass(tile->coverage, tile->coverageInitialized);
    id<MTLRenderCommandEncoder> coverageEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:coveragePass];
    if (!coverageEncoder) return BackendResult::encodingFailure;
    [coverageEncoder setRenderPipelineState:impl_->dabCoveragePipeline];
    [coverageEncoder setVertexBuffer:instances offset:0 atIndex:0];
    [coverageEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [coverageEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                        vertexCount:6 instanceCount:static_cast<NSUInteger>(batch.dabs.size())];
    [coverageEncoder endEncoding];
    tile->coverageInitialized = true;
    return BackendResult::ok;
}

BackendResult Backend::encodeDabs(void* nativeCommandBuffer,
                                  std::span<const TileDabBatch> batches) {
    if (!impl_ || !nativeCommandBuffer) return BackendResult::invalidArgument;
    for (const TileDabBatch& batch : batches) {
        const BackendResult result = encodeDabs(nativeCommandBuffer, batch);
        if (result != BackendResult::ok) return result;
    }
    return BackendResult::ok;
}

BackendResult Backend::encodeComposite(void* nativeCommandBuffer,
                                       void* nativeTargetTexture,
                                       std::span<const TileAddress> visibleTiles,
                                       const CompositeParameters& parameters) {
    if (!impl_ || !nativeCommandBuffer || !nativeTargetTexture ||
        parameters.viewportSize.x <= 0.0f || parameters.viewportSize.y <= 0.0f) {
        return BackendResult::invalidArgument;
    }
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
                               std::clamp(parameters.opacity, 0.0f, 1.0f)};
    for (const TileAddress address : visibleTiles) {
        auto found = impl_->tiles.find(address.key());
        if (found == impl_->tiles.end() || !found->second.colorInitialized) continue;
        found->second.lastUse = ++impl_->clock;
        const Vec2 origin = address.origin(kTileSize);
        uniforms.tileOrigin = {origin.x, origin.y};
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentTexture:found->second.color atIndex:0];
        [encoder setFragmentSamplerState:impl_->tileSampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
    return BackendResult::ok;
}

BackendResult Backend::encodeApronResolve(void* nativeCommandBuffer) {
    if (!impl_ || !nativeCommandBuffer) return BackendResult::invalidArgument;
    id<MTLCommandBuffer> commandBuffer = commandBufferFrom(nativeCommandBuffer);
    if (!commandBuffer) return BackendResult::invalidArgument;
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) return BackendResult::encodingFailure;
    for (auto& entry : impl_->tiles) {
        const TileAddress address = TileAddress::fromKey(entry.first);
        TileResource& destination = entry.second;
        if (!destination.colorInitialized && !destination.coverageInitialized) continue;
        const NSUInteger edge = static_cast<NSUInteger>(kTileApron);
        const NSUInteger last = edge + static_cast<NSUInteger>(kTileSize) - 1;
        const NSUInteger farApron = static_cast<NSUInteger>(kTileTextureExtent) - 1;

        auto copyFromNeighbor = [&](int dx, int dy,
                                    MTLOrigin sourceOrigin,
                                    MTLOrigin destinationOrigin,
                                    MTLSize size) {
            const auto neighbor = impl_->tiles.find(
                TileAddress{address.x + dx, address.y + dy}.key());
            if (neighbor == impl_->tiles.end()) return;
            auto copyTexture = [&](id<MTLTexture> source,
                                   bool sourceInitialized,
                                   id<MTLTexture> target,
                                   bool targetInitialized) {
                if (!sourceInitialized || !targetInitialized) return;
                [blit copyFromTexture:source sourceSlice:0 sourceLevel:0
                           sourceOrigin:sourceOrigin sourceSize:size
                              toTexture:target destinationSlice:0 destinationLevel:0
                      destinationOrigin:destinationOrigin];
            };
            copyTexture(neighbor->second.color, neighbor->second.colorInitialized,
                        destination.color, destination.colorInitialized);
            copyTexture(neighbor->second.coverage, neighbor->second.coverageInitialized,
                        destination.coverage, destination.coverageInitialized);
        };

        const MTLSize vertical = MTLSizeMake(1, kTileSize, 1);
        const MTLSize horizontal = MTLSizeMake(kTileSize, 1, 1);
        const MTLSize corner = MTLSizeMake(1, 1, 1);
        copyFromNeighbor(-1, 0, MTLOriginMake(last, edge, 0),
                         MTLOriginMake(0, edge, 0), vertical);
        copyFromNeighbor(1, 0, MTLOriginMake(edge, edge, 0),
                         MTLOriginMake(farApron, edge, 0), vertical);
        copyFromNeighbor(0, -1, MTLOriginMake(edge, last, 0),
                         MTLOriginMake(edge, 0, 0), horizontal);
        copyFromNeighbor(0, 1, MTLOriginMake(edge, edge, 0),
                         MTLOriginMake(edge, farApron, 0), horizontal);
        copyFromNeighbor(-1, -1, MTLOriginMake(last, last, 0),
                         MTLOriginMake(0, 0, 0), corner);
        copyFromNeighbor(1, -1, MTLOriginMake(edge, last, 0),
                         MTLOriginMake(farApron, 0, 0), corner);
        copyFromNeighbor(-1, 1, MTLOriginMake(last, edge, 0),
                         MTLOriginMake(0, farApron, 0), corner);
        copyFromNeighbor(1, 1, MTLOriginMake(edge, edge, 0),
                         MTLOriginMake(farApron, farApron, 0), corner);
    }
    [blit endEncoding];
    return BackendResult::ok;
}

std::size_t Backend::residentTileCount() const noexcept {
    return impl_ ? impl_->tiles.size() : 0;
}

void* Backend::nativeCoverageTexture(TileAddress tile) const noexcept {
    if (!impl_) return nullptr;
    const auto found = impl_->tiles.find(tile.key());
    if (found == impl_->tiles.end() || !found->second.coverageInitialized) return nullptr;
    return (__bridge void*)found->second.coverage;
}

void Backend::purgeTiles() noexcept {
    if (impl_) impl_->tiles.clear();
}

const std::string& Backend::lastError() const noexcept {
    static const std::string empty;
    return impl_ ? impl_->error : empty;
}

} // namespace drafting_table::metal
