#import "DTMetalRenderer.h"

#import <simd/simd.h>
#include <cmath>
#include <vector>

typedef struct {
    vector_float2 position;
    float pressure;
    float predicted;
} DTMetalVertex;

namespace {
constexpr float kPi = 3.14159265358979323846f;

static float strokeRadius(float pressure) {
    // A legible pencil at zero force still needs a couple of screen points;
    // pressure then grows the mark smoothly instead of changing its color.
    const float p = fmaxf(0.0f, fminf(1.0f, pressure));
    return 1.15f + 4.25f * sqrtf(p);
}

static void addTriangle(std::vector<DTMetalVertex>& out,
                        vector_float2 a, vector_float2 b, vector_float2 c,
                        float pressure, float predicted) {
    out.push_back({a, pressure, predicted});
    out.push_back({b, pressure, predicted});
    out.push_back({c, pressure, predicted});
}

static void addRoundCap(std::vector<DTMetalVertex>& out,
                        vector_float2 center, float radius,
                        float pressure, float predicted) {
    constexpr int kSlices = 12;
    for (int i = 0; i < kSlices; ++i) {
        const float a0 = (2.0f * kPi * static_cast<float>(i)) / kSlices;
        const float a1 = (2.0f * kPi * static_cast<float>(i + 1)) / kSlices;
        const vector_float2 p0 = center + (vector_float2){cosf(a0) * radius, sinf(a0) * radius};
        const vector_float2 p1 = center + (vector_float2){cosf(a1) * radius, sinf(a1) * radius};
        addTriangle(out, center, p0, p1, pressure, predicted);
    }
}
}

@interface DTMetalRenderer ()
@property(nonatomic, weak) MTKView *view;
@property(nonatomic, weak) DTEngineBridge *engine;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, readwrite) NSUInteger frameCount;
@end

@implementation DTMetalRenderer

- (instancetype)initWithView:(MTKView *)view engine:(DTEngineBridge *)engine {
    self = [super init];
    if (!self) return nil;
    _view = view;
    _engine = engine;
    view.clearColor = MTLClearColorMake(0.965, 0.945, 0.900, 1.0);

    id<MTLDevice> device = view.device;
    if (!device) return self;
    _commandQueue = [device newCommandQueue];

    NSError *libraryError = nil;
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (!library) return self;
    id<MTLFunction> vertex = [library newFunctionWithName:@"dt_vertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"dt_fragment"];
    if (!vertex || !fragment) return self;

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&libraryError];
    if (libraryError) NSLog(@"DraftingTable Metal pipeline: %@", libraryError);
    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view {
    self.frameCount += 1;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable || !self.commandQueue) return;

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!pass) return;
    // Keep the canvas useful even before a document has any strokes. This is
    // intentionally set here (rather than relying on the Swift default) so
    // every device gets the same warm-paper surface.
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.965, 0.945, 0.900, 1.0);
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    // A shader/library failure must still leave a usable paper canvas rather
    // than the opaque black MTKView default; ending this encoder commits the
    // clear operation without attempting to draw.
    if (!self.pipeline) {
        [encoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        return;
    }
    [encoder setRenderPipelineState:self.pipeline];

    vector_float2 viewport = {(float)view.bounds.size.width, (float)view.bounds.size.height};
    [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:1];

    NSArray<NSArray<NSValue *> *> *strokes = [self.engine renderableStrokes];
    for (NSArray<NSValue *> *stroke in strokes) {
        if (stroke.count == 0) continue;
        NSUInteger count = stroke.count;
        struct Point {
            vector_float2 position;
            float pressure;
            float predicted;
        };
        std::vector<Point> points;
        points.reserve(count);
        for (NSUInteger index = 0; index < count; ++index) {
            DTRenderPoint point = {0, 0, 1, 0};
            [stroke[index] getValue:&point size:sizeof(point)];
            points.push_back({(vector_float2){point.x, point.y},
                              fmaxf(0.1f, fminf(1.0f, point.pressure)),
                              point.predicted ? 1.0f : 0.0f});
        }

        std::vector<DTMetalVertex> geometry;
        geometry.reserve(count * 24);
        if (count == 1) {
            addRoundCap(geometry, points[0].position,
                        strokeRadius(points[0].pressure), points[0].pressure,
                        points[0].predicted);
        } else {
            for (NSUInteger index = 1; index < count; ++index) {
                const Point& p0 = points[index - 1];
                const Point& p1 = points[index];
                const vector_float2 delta = p1.position - p0.position;
                const float length = simd_length(delta);
                if (length < 0.001f) continue;
                const vector_float2 normal = (vector_float2){-delta.y / length,
                                                               delta.x / length};
                const float r0 = strokeRadius(p0.pressure);
                const float r1 = strokeRadius(p1.pressure);
                const vector_float2 a0 = p0.position + normal * r0;
                const vector_float2 b0 = p0.position - normal * r0;
                const vector_float2 a1 = p1.position + normal * r1;
                const vector_float2 b1 = p1.position - normal * r1;
                // Two triangles form a pressure-varying segment quad. The
                // interpolated prediction flag makes the tail visibly fade.
                addTriangle(geometry, a0, b0, a1, p0.pressure, p0.predicted);
                addTriangle(geometry, a1, b0, b1, p1.pressure, p1.predicted);
            }
            const Point& first = points.front();
            const Point& last = points.back();
            addRoundCap(geometry, first.position, strokeRadius(first.pressure),
                        first.pressure, first.predicted);
            addRoundCap(geometry, last.position, strokeRadius(last.pressure),
                        last.pressure, last.predicted);
        }
        if (geometry.empty()) continue;
        id<MTLBuffer> buffer = [view.device newBufferWithBytes:geometry.data()
                                                           length:sizeof(DTMetalVertex) * geometry.size()
                                                           options:MTLResourceStorageModeShared];
        [encoder setVertexBuffer:buffer offset:0 atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                     vertexCount:geometry.size()];
    }
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
