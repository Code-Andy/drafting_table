#import <MetalKit/MetalKit.h>

#import "DTEngineBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Minimal Metal renderer. It intentionally renders the engine's polyline
/// snapshot directly; tile baking and document persistence can be introduced
/// behind DTEngineBridge without changing UIKit input handling.
@interface DTMetalRenderer : NSObject <MTKViewDelegate>

- (instancetype)initWithView:(MTKView *)view engine:(DTEngineBridge *)engine;

/// Sets the document-to-view transform used by the vertex shader. Translation
/// is in view points and rotation is in radians (around the document origin).
/// Values may be supplied from the UI thread while Metal renders on its own
/// thread; the renderer snapshots them atomically for each frame.
- (void)updateCanvasScale:(CGFloat)scale
                 rotation:(CGFloat)rotation
             translationX:(CGFloat)x
             translationY:(CGFloat)y;

@property(nonatomic, readonly) NSUInteger frameCount;

@end

NS_ASSUME_NONNULL_END
