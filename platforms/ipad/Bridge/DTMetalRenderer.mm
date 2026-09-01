#import "DTMetalRenderer.h"

#import <simd/simd.h>
#include <cmath>

typedef struct {
    vector_float2 position;
    float pressure;
    float predicted;
} DTMetalVertex;

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
    if (!self.commandQueue || !self.pipeline || !drawable) return;

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!pass) return;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipeline];

    vector_float2 viewport = {(float)view.bounds.size.width, (float)view.bounds.size.height};
    [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:1];

    NSArray<NSArray<NSValue *> *> *strokes = [self.engine renderableStrokes];
    for (NSArray<NSValue *> *stroke in strokes) {
        if (stroke.count < 2) continue;
        NSUInteger count = stroke.count;
        NSMutableData *data = [NSMutableData dataWithLength:sizeof(DTMetalVertex) * count];
        DTMetalVertex *vertices = (DTMetalVertex *)data.mutableBytes;
        for (NSUInteger index = 0; index < count; ++index) {
            DTRenderPoint point = {0, 0, 1, 0};
            [stroke[index] getValue:&point size:sizeof(point)];
            vertices[index].position = (vector_float2){point.x, point.y};
            vertices[index].pressure = fmaxf(0.1f, fminf(1.0f, point.pressure));
            vertices[index].predicted = point.predicted ? 1.0f : 0.0f;
        }
        id<MTLBuffer> buffer = [view.device newBufferWithBytes:data.bytes
                                                           length:data.length
                                                          options:MTLResourceStorageModeShared];
        [encoder setVertexBuffer:buffer offset:0 atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeLineStrip vertexStart:0 vertexCount:count];
    }
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
