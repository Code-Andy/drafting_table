#import <MetalKit/MetalKit.h>

#import "DTEngineBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Minimal Metal renderer. It intentionally renders the engine's polyline
/// snapshot directly; tile baking and document persistence can be introduced
/// behind DTEngineBridge without changing UIKit input handling.
@interface DTMetalRenderer : NSObject <MTKViewDelegate>

- (instancetype)initWithView:(MTKView *)view engine:(DTEngineBridge *)engine;

@property(nonatomic, readonly) NSUInteger frameCount;

@end

NS_ASSUME_NONNULL_END
