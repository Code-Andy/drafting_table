#import "DTMetalRenderer.h"

#import <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <mutex>
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
    vector_float4 color;
    float hardness;
} DTMetalVertex;

namespace {
constexpr float kPi = 3.14159265358979323846f;

// Keep the transform behind one small lock so a frame always sees one coherent
// scale/rotation/translation snapshot rather than a mixture of gesture states.
struct DTCanvasTransformState {
    std::mutex mutex;
    float scale = 1.0f;
    float rotation = 0.0f;
    float translationX = 0.0f;
    float translationY = 0.0f;
    bool gridVisible = false;
    float gridSpacing = 32.0f;
};

static DTCanvasTransformState gCanvasTransform;

static float finiteOr(float value, float fallback) {
    return std::isfinite(value) ? value : fallback;
}

static float clamp01(float value) { return fmaxf(0.0f, fminf(1.0f, value)); }

static vector_float4 graphiteColor() {
    return (vector_float4){0.075f, 0.080f, 0.082f, 1.0f};
}

static vector_float4 colorFromRGBA(uint32_t rgba) {
    return (vector_float4){
        ((rgba >> 24) & 0xffu) / 255.0f,
        ((rgba >> 16) & 0xffu) / 255.0f,
        ((rgba >> 8) & 0xffu) / 255.0f,
        (rgba & 0xffu) / 255.0f
    };
}

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
    const vector_float4 color = eraser > 0.5f
        ? (vector_float4){0.965f, 0.945f, 0.900f, 1.0f} : graphiteColor();
    out.push_back({a, pressure, predicted, opacity, eraser, color, 1.0f});
    out.push_back({b, pressure, predicted, opacity, eraser, color, 1.0f});
    out.push_back({c, pressure, predicted, opacity, eraser, color, 1.0f});
}

static void addTriangleStyled(std::vector<DTMetalVertex>& out,
                              vector_float2 a, vector_float2 b, vector_float2 c,
                              float pressure, float predicted, float opacity,
                              float eraser, vector_float4 color, float hardness) {
    out.push_back({a, pressure, predicted, opacity, eraser, color, hardness});
    out.push_back({b, pressure, predicted, opacity, eraser, color, hardness});
    out.push_back({c, pressure, predicted, opacity, eraser, color, hardness});
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

static void addRoundCapStyled(std::vector<DTMetalVertex>& out,
                              vector_float2 center, float radius,
                              float pressure, float predicted, float opacity,
                              float eraser, vector_float4 color, float hardness) {
    constexpr int kSlices = 8;
    for (int i = 0; i < kSlices; ++i) {
        const float a0 = (2.0f * kPi * static_cast<float>(i)) / kSlices;
        const float a1 = (2.0f * kPi * static_cast<float>(i + 1)) / kSlices;
        const vector_float2 p0 = center + (vector_float2){cosf(a0) * radius, sinf(a0) * radius};
        const vector_float2 p1 = center + (vector_float2){cosf(a1) * radius, sinf(a1) * radius};
        addTriangleStyled(out, center, p0, p1, pressure, predicted, opacity,
                          eraser, color, hardness);
    }
}

static void addSegmentStyled(std::vector<DTMetalVertex>& out,
                             vector_float2 p0, vector_float2 p1, float radius,
                             float opacity, float eraser, vector_float4 color,
                             float hardness, bool caps = true) {
    const vector_float2 delta = p1 - p0;
    const float length = simd_length(delta);
    if (length < 0.001f) return;
    const vector_float2 normal = (vector_float2){-delta.y / length, delta.x / length};
    const vector_float2 a0 = p0 + normal * radius;
    const vector_float2 b0 = p0 - normal * radius;
    const vector_float2 a1 = p1 + normal * radius;
    const vector_float2 b1 = p1 - normal * radius;
    addTriangleStyled(out, a0, b0, a1, 1.0f, 0.0f, opacity, eraser, color, hardness);
    addTriangleStyled(out, a1, b0, b1, 1.0f, 0.0f, opacity, eraser, color, hardness);
    if (caps) {
        addRoundCapStyled(out, p0, radius, 1.0f, 0.0f, opacity, eraser, color, hardness);
        addRoundCapStyled(out, p1, radius, 1.0f, 0.0f, opacity, eraser, color, hardness);
    }
}

static void addShapeOutline(std::vector<DTMetalVertex>& out,
                            uint32_t tool, vector_float2 first, vector_float2 last,
                            float radius, float opacity, vector_float4 color,
                            float hardness) {
    if (tool == 2u) { // line
        addSegmentStyled(out, first, last, radius, opacity, 0.0f, color, hardness);
        return;
    }
    if (tool == 3u) { // rectangle
        const vector_float2 a = first;
        const vector_float2 b = (vector_float2){last.x, first.y};
        const vector_float2 c = last;
        const vector_float2 d = (vector_float2){first.x, last.y};
        addSegmentStyled(out, a, b, radius, opacity, 0.0f, color, hardness, false);
        addSegmentStyled(out, b, c, radius, opacity, 0.0f, color, hardness, false);
        addSegmentStyled(out, c, d, radius, opacity, 0.0f, color, hardness, false);
        addSegmentStyled(out, d, a, radius, opacity, 0.0f, color, hardness, false);
        addRoundCapStyled(out, a, radius, 1.0f, 0.0f, opacity, 0.0f, color, hardness);
        addRoundCapStyled(out, c, radius, 1.0f, 0.0f, opacity, 0.0f, color, hardness);
        return;
    }
    if (tool == 4u) { // ellipse
        const vector_float2 center = (first + last) * 0.5f;
        const vector_float2 radii = (vector_float2){
            fmaxf(0.5f, fabsf(last.x - first.x) * 0.5f),
            fmaxf(0.5f, fabsf(last.y - first.y) * 0.5f)};
        constexpr int kSegments = 64;
        for (int i = 0; i < kSegments; ++i) {
            const float t0 = (2.0f * kPi * i) / kSegments;
            const float t1 = (2.0f * kPi * (i + 1)) / kSegments;
            const vector_float2 p0 = center + (vector_float2){cosf(t0) * radii.x, sinf(t0) * radii.y};
            const vector_float2 p1 = center + (vector_float2){cosf(t1) * radii.x, sinf(t1) * radii.y};
            addSegmentStyled(out, p0, p1, radius, opacity, 0.0f, color, hardness, false);
        }
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
    constexpr size_t kMaximumSmoothedPoints = 1024;
    std::vector<DTSampledPoint> output;
    output.reserve(std::min(kMaximumSmoothedPoints, input.size() * 3));
    for (size_t i = 0; i + 1 < input.size(); ++i) {
        const DTSampledPoint& p0 = input[i == 0 ? i : i - 1];
        const DTSampledPoint& p1 = input[i];
        const DTSampledPoint& p2 = input[i + 1];
        const DTSampledPoint& p3 = input[(i + 2 < input.size()) ? i + 2 : i + 1];
        const float length = simd_length(p2.position - p1.position);
        const int subdivisions = std::max(1, std::min(12, static_cast<int>(ceilf(length / 3.0f))));
        for (int step = 0; step < subdivisions; ++step) {
            if (output.size() + 1 >= kMaximumSmoothedPoints) break;
            const float t = static_cast<float>(step) / static_cast<float>(subdivisions);
            output.push_back(catmullRom(p0, p1, p2, p3, t));
        }
        if (output.size() + 1 >= kMaximumSmoothedPoints) break;
    }
    output.push_back(input.back());
    return output;
}

static std::vector<DTSampledPoint> boundedInputPoints(
    const std::vector<DTSampledPoint>& input) {
    constexpr size_t kMaximumInputPoints = 512;
    if (input.size() <= kMaximumInputPoints) return input;
    std::vector<DTSampledPoint> output;
    output.reserve(kMaximumInputPoints);
    output.push_back(input.front());
    const double stride = static_cast<double>(input.size() - 1) /
        static_cast<double>(kMaximumInputPoints - 1);
    for (size_t index = 1; index + 1 < kMaximumInputPoints; ++index) {
        const size_t source = std::min(input.size() - 2,
            static_cast<size_t>(llround(static_cast<double>(index) * stride)));
        output.push_back(input[source]);
    }
    output.push_back(input.back());
    return output;
}

// This layout intentionally contains only float4 values. float4 alignment is
// identical in C++/simd and Metal, making the uniform safe for setVertexBytes
// without relying on compiler-specific padding between scalar fields.
typedef struct {
    vector_float4 viewportScaleRotation;
    vector_float4 translation;
} DTMetalUniforms;
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

- (void)updateCanvasScale:(CGFloat)scale
                 rotation:(CGFloat)rotation
             translationX:(CGFloat)x
             translationY:(CGFloat)y {
    // A zero/negative/NaN scale would invert or collapse the canvas. Keep a
    // small positive minimum and a practical upper bound for gesture input;
    // invalid values fall back to identity rather than poisoning the frame.
    const float requestedScale = static_cast<float>(scale);
    const float safeScale = std::isfinite(requestedScale)
        ? std::max(0.01f, std::min(100.0f, requestedScale))
        : 1.0f;
    const float safeRotation = finiteOr(static_cast<float>(rotation), 0.0f);
    const float safeX = finiteOr(static_cast<float>(x), 0.0f);
    const float safeY = finiteOr(static_cast<float>(y), 0.0f);
    std::lock_guard<std::mutex> lock(gCanvasTransform.mutex);
    gCanvasTransform.scale = safeScale;
    gCanvasTransform.rotation = safeRotation;
    gCanvasTransform.translationX = safeX;
    gCanvasTransform.translationY = safeY;
}

- (void)updateGridVisible:(BOOL)visible spacing:(CGFloat)spacing {
    const float requestedSpacing = static_cast<float>(spacing);
    const float safeSpacing = std::isfinite(requestedSpacing)
        ? std::max(4.0f, std::min(2048.0f, requestedSpacing)) : 32.0f;
    std::lock_guard<std::mutex> lock(gCanvasTransform.mutex);
    gCanvasTransform.gridVisible = visible;
    gCanvasTransform.gridSpacing = safeSpacing;
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
    float transformScale = 1.0f;
    float transformRotation = 0.0f;
    float transformX = 0.0f;
    float transformY = 0.0f;
    bool gridVisible = false;
    float gridSpacing = 32.0f;
    {
        std::lock_guard<std::mutex> lock(gCanvasTransform.mutex);
        transformScale = gCanvasTransform.scale;
        transformRotation = gCanvasTransform.rotation;
        transformX = gCanvasTransform.translationX;
        transformY = gCanvasTransform.translationY;
        gridVisible = gCanvasTransform.gridVisible;
        gridSpacing = gCanvasTransform.gridSpacing;
    }
    DTMetalUniforms uniforms{};
    uniforms.viewportScaleRotation = (vector_float4){
        (float)view.bounds.size.width,
        (float)view.bounds.size.height,
        transformScale,
        transformRotation
    };
    uniforms.translation = (vector_float4){
        transformX,
        transformY,
        0.0f,
        0.0f
    };
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];

    // Draw the optional document-space grid first. Lines are generated in
    // document coordinates and therefore rotate/scale with the canvas.
    if (gridVisible) {
        const float inverseScale = 1.0f / std::max(0.01f, transformScale);
        const float extentX = static_cast<float>(view.bounds.size.width) * inverseScale + gridSpacing * 2.0f;
        const float extentY = static_cast<float>(view.bounds.size.height) * inverseScale + gridSpacing * 2.0f;
        const int maxColumns = 256;
        const int columns = std::min(maxColumns, static_cast<int>(ceilf(extentX / gridSpacing)) + 1);
        const int rows = std::min(maxColumns, static_cast<int>(ceilf(extentY / gridSpacing)) + 1);
        const vector_float4 gridColor = (vector_float4){0.52f, 0.56f, 0.55f, 0.20f};
        std::vector<DTMetalVertex> grid;
        grid.reserve(static_cast<size_t>(columns + rows) * 6);
        const float halfX = columns * gridSpacing;
        const float halfY = rows * gridSpacing;
        const float width = std::max(0.35f, 0.75f * inverseScale);
        for (int i = -columns; i <= columns; ++i) {
            const float x = static_cast<float>(i) * gridSpacing;
            addSegmentStyled(grid, (vector_float2){x, -halfY}, (vector_float2){x, halfY},
                             width, 1.0f, 0.0f, gridColor, 1.0f, false);
        }
        for (int i = -rows; i <= rows; ++i) {
            const float y = static_cast<float>(i) * gridSpacing;
            addSegmentStyled(grid, (vector_float2){-halfX, y}, (vector_float2){halfX, y},
                             width, 1.0f, 0.0f, gridColor, 1.0f, false);
        }
        if (!grid.empty()) {
            id<MTLBuffer> gridBuffer = [view.device newBufferWithBytes:grid.data()
                                                                  length:sizeof(DTMetalVertex) * grid.size()
                                                                 options:MTLResourceStorageModeShared];
            if (gridBuffer) {
                [encoder setVertexBuffer:gridBuffer offset:0 atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:grid.size()];
            }
        }
    }

    NSArray<DTRenderStroke *> *strokes = [self.engine renderableStrokes];
    for (DTRenderStroke *stroke in strokes) {
        NSArray<NSValue *> *strokeValues = stroke.points;
        if (strokeValues.count == 0) continue;
        const uint32_t tool = static_cast<uint32_t>(stroke.tool);
        const BOOL eraser = tool == 1u;
        const float opacity = clamp01(stroke.brushOpacity);
        const float brushSize = std::max(0.5f, static_cast<float>(stroke.brushSize));
        const float hardness = clamp01(static_cast<float>(stroke.brushHardness));
        const vector_float4 strokeColor = colorFromRGBA(static_cast<uint32_t>(stroke.brushColorRGBA));
        std::vector<DTSampledPoint> points;
        points.reserve(strokeValues.count);
        for (NSValue *value in strokeValues) {
            DTRenderPoint point = {0, 0, 1, 0};
            [value getValue:&point size:sizeof(point)];
            points.push_back({(vector_float2){point.x, point.y},
                              clamp01(fmaxf(0.1f, point.pressure)),
                              point.predicted ? 1.0f : 0.0f});
        }
        const float eraseFlag = eraser ? 1.0f : 0.0f;
        // Shape tools use first/last real samples, excluding predicted tail
        // points so a transient prediction never reaches the retained result.
        if (tool >= 2u && tool <= 4u) {
            size_t firstReal = 0;
            while (firstReal + 1 < points.size() && points[firstReal].predicted > 0.5f) ++firstReal;
            size_t lastReal = points.size() - 1;
            while (lastReal > firstReal && points[lastReal].predicted > 0.5f) --lastReal;
            const float radius = fmaxf(0.5f, brushSize * 0.5f);
            std::vector<DTMetalVertex> geometry;
            addShapeOutline(geometry, tool, points[firstReal].position, points[lastReal].position,
                            radius, opacity * (0.22f + 0.78f * hardness), strokeColor, hardness);
            if (!geometry.empty()) {
                id<MTLBuffer> buffer = [view.device newBufferWithBytes:geometry.data()
                                                                      length:sizeof(DTMetalVertex) * geometry.size()
                                                                     options:MTLResourceStorageModeShared];
                if (buffer) {
                    [encoder setVertexBuffer:buffer offset:0 atIndex:0];
                    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:geometry.size()];
                }
            }
            continue;
        }

        points = smoothedPoints(boundedInputPoints(points));
        const vector_float4 color = eraser
            ? (vector_float4){0.965f, 0.945f, 0.900f, 1.0f} : strokeColor;
        // A low-hardness fringe plus a full-opacity core gives the control a
        // visible effect while retaining the existing smooth curve geometry.
        const float fringeRadiusScale = 1.08f + 0.24f * (1.0f - hardness);
        const float fringeOpacity = opacity * (0.12f + 0.30f * (1.0f - hardness));
        for (int pass = 0; pass < (eraser ? 1 : 2); ++pass) {
            const bool fringe = pass == 0 && !eraser;
            const float passScale = fringe ? fringeRadiusScale : 1.0f;
            const float passOpacity = fringe ? fringeOpacity : opacity;
            std::vector<DTMetalVertex> geometry;
            geometry.reserve(points.size() * 24);
            if (points.size() == 1) {
                addRoundCapStyled(geometry, points[0].position,
                                  strokeRadius(points[0].pressure, brushSize) * passScale,
                                  points[0].pressure, points[0].predicted, passOpacity,
                                  eraseFlag, color, hardness);
            } else {
                for (size_t index = 1; index < points.size(); ++index) {
                    const DTSampledPoint& p0 = points[index - 1];
                    const DTSampledPoint& p1 = points[index];
                    const vector_float2 delta = p1.position - p0.position;
                    const float length = simd_length(delta);
                    if (length < 0.001f) continue;
                    const vector_float2 normal = (vector_float2){-delta.y / length, delta.x / length};
                    const float r0 = strokeRadius(p0.pressure, brushSize) * passScale;
                    const float r1 = strokeRadius(p1.pressure, brushSize) * passScale;
                    const vector_float2 a0 = p0.position + normal * r0;
                    const vector_float2 b0 = p0.position - normal * r0;
                    const vector_float2 a1 = p1.position + normal * r1;
                    const vector_float2 b1 = p1.position - normal * r1;
                    addTriangleStyled(geometry, a0, b0, a1, p0.pressure, p0.predicted,
                                      passOpacity, eraseFlag, color, hardness);
                    addTriangleStyled(geometry, a1, b0, b1, p1.pressure, p1.predicted,
                                      passOpacity, eraseFlag, color, hardness);
                }
                for (size_t index = 0; index < points.size(); ++index) {
                    // Dense smoothed quads overlap naturally. Periodic caps
                    // preserve curved joins without allocating a fan at every
                    // interpolated point on long retained strokes.
                    if (index != 0 && index + 1 != points.size() && index % 4 != 0) continue;
                    const DTSampledPoint& point = points[index];
                    addRoundCapStyled(geometry, point.position,
                                      strokeRadius(point.pressure, brushSize) * passScale,
                                      point.pressure, point.predicted, passOpacity,
                                      eraseFlag, color, hardness);
                }
            }
            if (geometry.empty()) continue;
            id<MTLBuffer> buffer = [view.device newBufferWithBytes:geometry.data()
                                                              length:sizeof(DTMetalVertex) * geometry.size()
                                                             options:MTLResourceStorageModeShared];
            if (buffer) {
                [encoder setVertexBuffer:buffer offset:0 atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:geometry.size()];
            }
        }
    }
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
