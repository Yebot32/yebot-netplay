/**
 ******************************************************************************
 * Xenra : iOS shell                                                          *
 ******************************************************************************
 */

#ifndef XENRA_IOS_METAL_VIEW_H_
#define XENRA_IOS_METAL_VIEW_H_

#import <UIKit/UIKit.h>

// A UIView whose backing layer IS a CAMetalLayer.
//
// This is the case IosUIViewSurface::GetOrCreateMetalLayer() takes its fast
// path on: overriding +layerClass means UIKit creates the metal layer as the
// view's own layer, so there is no extra sublayer and no extra compositing
// pass. The sublayer fallback in that function exists for views we do not
// control; this one we do.
@interface XenraMetalView : UIView
// The xemu presenter draws at whatever size the layer says, so the layer has to
// follow the view. The 360 presenter manages its own drawable.
@property(nonatomic, assign) BOOL tracksBounds;
@end

#endif  // XENRA_IOS_METAL_VIEW_H_
