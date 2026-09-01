#import "DTMetalRenderer.h"

#import <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <vector>

// Immediate retained-snapshot renderer. Eraser strokes are warm-paper geometry
// replayed in document order until the sparse tile backend supports
// destination-out blending.
typedef struct {
    vector_float2 position;
    float pressure;
    float predicted;
    float opacity;
    float eraser;
} DTMetalVertex;

namespace {
constexpr float kPi = 3.14159265358979323846f;

static float clamp01(float value) { return fmaxf(0.0f, fminf(1.0f, value)); }

static float strokeRadius(float pressure, float brushSize) {
    // brushSize is nominal diameter in points; force provides a smooth,
    // pressure-aware width while preserving a visible feather-light mark.
    const float size = brushSize > 0.0f ? brushSize : 5.4f;
    const float diameter = size * (0.20f + 0.80f * sqrtf(clamp01(pressure)));
    return fmaxf(0.45f, diameter * 0.5f);
}

static void addTriangle(std::vector<DTMetalVertex>& out,
                        vector_float2 a, vector_float2 b, vector_float2 c,
                        float pressure, float predicted,
                        float opacity, float eraser) {
    out.push_back({a, pressure, predicted, opacity, eraser});
    out.push_back({b, pressure, predicted, opacity, eraser});
    out.push_back({c, pressure, predicted, opacity, eraser});
}

static void addRoundCap(std::vector<DTMetalVertex>& out,
                        vector_float2 center, float radius,
                        float pressure, float predicted,
                        float opacity, float eraser) {
    constexpr int kSlices = 14;
    for (int i = 0; i < kSlices; ++i) {
        const float a0 = (2.0f * kPi * static_cast<float>(i)) / kSlices;
        const float a1 = (2.0f * kPi * static_cast<float>(i + 1)) / kSlices;
        const vector_float2 p0 = center + (vector_float2){cosf(a0) * radius, sinf(a0) * radius};
        const vector_float2 p1 = center + (vector_float2){cosf(a1) * radius, sinf(a1) * radius};
        addTriangle(out, center, p0, p1, pressure, predicted, opacity, eraser);
    }
}

struct DTSampledPoint {
    vector_float2 position;
    float pressure;
    float predicted;
};

static DTSampledPoint catmullRom(const DTSampledPoint& p0,
                                 const DTSampledPoint& p1,
                                 const DTSampledPoint& p2,
                                 const DTSampledPoint& p3, float t) {
    const float t2 = t * t;
    const float t3 = t2 * t;
    const vector_float2 position = 0.5f * ((2.0f * p1.position) +
        (-p0.position + p2.position) * t +
        (2.0f * p0.position - 5.0f * p1.position + 4.0f * p2.position - p3.position) * t2 +
        (-p0.position + 3.0f * p1.position - 3.0f * p2.position + p3.position) * t3);
    const float pressure = clamp01(0.5f * ((2.0f * p1.pressure) +
        (-p0.pressure + p2.pressure) * t +
        (2.0f * p0.pressure - 5.0f * p1.pressure + 4.0f * p2.pressure - p3.pressure) * t2 +
        (-p0.pressure + 3.0f * p1.pressure - 3.0f * p2.pressure + p3.pressure) * t3));
    // Prediction is a confidence value, allowing a soft real-to-tail seam.
    const float predicted = clamp01(p1.predicted + (p2.predicted - p1.predicted) * t);
    return {position, pressure, predicted};
}

static std::vector<DTSampledPoint> smoothedPoints(
    const std::vector<DTSampledPoint>& input) {
    if (input.size() < 3) return input;
    std::vector<DTSampledPoint> output;
    output.reserve(input.size() * 3);
    for (size_t i = 0; i + 1 < input.size(); ++i) {
        const DTSampledPoint& p0 = input[i == 0 ? i : i - 1];
        const DTSampledPoint& p1 = input[i];
        const DTSampledPoint& p2 = input[i + 1];
        const DTSampledPoint& p3 = input[(i + 2 < input.size()) ? i + 2 : i + 1];
        const float length = simd_length(p2.position - p1.position);
        const int subdivisions = std::max(1, std::min(12, static_cast<int>(ceilf(length / 3.0f))));
        for (int step = 0; step < subdivisions; ++step) {
            const float t = static_cast<float>(step) / static_cast<float>(subdivisions);
            output.push_back(catmullRom(p0, p1, p2, p3, t));
        }
    }
    output.push_back(input.back());
    return output;
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
    (void)view; (void)size;
}

- (void)drawInMTKView:(MTKView *)view {
    self.frameCount += 1;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable || !self.commandQueue) return;
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!pass) return;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.965, 0.945, 0.900, 1.0);
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!self.pipeline) {
        [encoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        return;
    }
    [encoder setRenderPipelineState:self.pipeline];
    vector_float2 viewport = {(float)view.bounds.size.width, (float)view.bounds.size.height};
    [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:1];

    NSArray<DTRenderStroke *> *strokes = [self.engine renderableStrokes];
    for (DTRenderStroke *stroke in strokes) {
        NSArray<NSValue *> *strokeValues = stroke.points;
        if (strokeValues.count == 0) continue;
        const BOOL eraser = stroke.tool == DTToolEraser;
        const float opacity = clamp01(stroke.brushOpacity);
        const float brushSize = stroke.brushSize;
        std::vector<DTSampledPoint> points;
        points.reserve(strokeValues.count);
        for (NSValue *value in strokeValues) {
            DTRenderPoint point = {0, 0, 1, 0};
            [value getValue:&point size:sizeof(point)];
            points.push_back({(vector_float2){point.x, point.y},
                              clamp01(fmaxf(0.1f, point.pressure)),
                              point.predicted ? 1.0f : 0.0f});
        }
        points = smoothedPoints(points);
        std::vector<DTMetalVertex> geometry;
        geometry.reserve(points.size() * 96);
        const float eraseFlag = eraser ? 1.0f : 0.0f;
        if (points.size() == 1) {
            addRoundCap(geometry, points[0].position,
                        strokeRadius(points[0].pressure, brushSize), points[0].pressure,
                        points[0].predicted, opacity, eraseFlag);
        } else {
            for (size_t index = 1; index < points.size(); ++index) {
                const DTSampledPoint& p0 = points[index - 1];
                const DTSampledPoint& p1 = points[index];
                const vector_float2 delta = p1.position - p0.position;
                const float length = simd_length(delta);
                if (length < 0.001f) continue;
                const vector_float2 normal = (vector_float2){-delta.y / length, delta.x / length};
                const float r0 = strokeRadius(p0.pressure, brushSize);
                const float r1 = strokeRadius(p1.pressure, brushSize);
                const vector_float2 a0 = p0.position + normal * r0;
                const vector_float2 b0 = p0.position - normal * r0;
                const vector_float2 a1 = p1.position + normal * r1;
                const vector_float2 b1 = p1.position - normal * r1;
                addTriangle(geometry, a0, b0, a1, p0.pressure, p0.predicted, opacity, eraseFlag);
                addTriangle(geometry, a1, b0, b1, p1.pressure, p1.predicted, opacity, eraseFlag);
            }
            for (const DTSampledPoint& point : points) {
                addRoundCap(geometry, point.position,
                            strokeRadius(point.pressure, brushSize), point.pressure,
                            point.predicted, opacity, eraseFlag);
            }
        }
        if (geometry.empty()) continue;
        id<MTLBuffer> buffer = [view.device newBufferWithBytes:geometry.data()
                                                          length:sizeof(DTMetalVertex) * geometry.size()
                                                         options:MTLResourceStorageModeShared];
        [encoder setVertexBuffer:buffer offset:0 atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:geometry.size()];
    }
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
