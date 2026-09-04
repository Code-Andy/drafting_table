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
/// thread; the renderer takes one coherent snapshot for each frame.
- (void)updateCanvasScale:(CGFloat)scale
                 rotation:(CGFloat)rotation
             translationX:(CGFloat)x
             translationY:(CGFloat)y;

/// Enables the document-space square grid. Spacing is expressed in document
/// points and is clamped by the renderer to a practical positive range.
- (void)updateGridVisible:(BOOL)visible spacing:(CGFloat)spacing;
- (void)updatePixelGridVisible:(BOOL)visible;
- (void)updateCenterMode:(BOOL)centerMode;
- (void)updatePaperWidth:(CGFloat)width height:(CGFloat)height;

@property(nonatomic, readonly) NSUInteger frameCount;

@end

NS_ASSUME_NONNULL_END
