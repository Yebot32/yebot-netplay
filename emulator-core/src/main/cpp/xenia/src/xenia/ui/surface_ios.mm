/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/ui/surface_ios.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

namespace xe {
namespace ui {

bool IosUIViewSurface::GetSizeImpl(uint32_t& width_out,
                                   uint32_t& height_out) const {
  if (!view_) {
    width_out = 0;
    height_out = 0;
    return false;
  }

  // Logical (point) coordinates, matching what MacNSViewSurface reports and
  // what Window expects. The caller multiplies by the contents scale to get
  // physical pixels for the drawable.
  CGRect bounds = [view_ bounds];
  width_out = static_cast<uint32_t>(bounds.size.width);
  height_out = static_cast<uint32_t>(bounds.size.height);
  return true;
}

double IosUIViewSurface::GetBackingScale() const {
  if (!view_) {
    return 1.0;
  }

  // Prefer the scale of the screen this view is actually on. A view that is
  // not in a window yet has no screen, and contentScaleFactor is the value
  // UIKit has already resolved for it, so it is the better fallback than
  // assuming the main screen.
  UIWindow* window = [view_ window];
  if (window) {
    UIWindowScene* scene = window.windowScene;
    if (scene && scene.screen) {
      return scene.screen.scale;
    }
    if (window.screen) {
      return window.screen.scale;
    }
  }
  CGFloat content_scale = [view_ contentScaleFactor];
  return content_scale > 0.0 ? content_scale : 1.0;
}

void IosUIViewSurface::ConfigureMetalLayer(uint32_t drawable_width,
                                           uint32_t drawable_height,
                                           double contents_scale) const {
  CAMetalLayer* metal_layer = GetOrCreateMetalLayer();
  if (!metal_layer) {
    return;
  }

  CALayer* main_layer = [view_ layer];
  // Unlike the Mac path, this frame assignment is load-bearing on every
  // resize: CALayer::autoresizingMask does not exist on iOS, so nothing tracks
  // the parent's bounds for us. Rotation and split-view both land here.
  metal_layer.frame = main_layer.bounds;
  metal_layer.contentsScale = contents_scale;
  metal_layer.drawableSize =
      CGSizeMake(drawable_width * contents_scale,
                 drawable_height * contents_scale);
}

CAMetalLayer* IosUIViewSurface::GetOrCreateMetalLayer() const {
  if (!view_) {
    return nullptr;
  }

  // The cheap and correct case: a UIView subclass that overrides +layerClass
  // to return CAMetalLayer, so the view's own backing layer is the drawable
  // target and there is no extra compositing step. The iOS app shell does
  // exactly this.
  CALayer* main_layer = [view_ layer];
  if ([main_layer isKindOfClass:[CAMetalLayer class]]) {
    return static_cast<CAMetalLayer*>(main_layer);
  }
  for (CALayer* sub in main_layer.sublayers) {
    if ([sub isKindOfClass:[CAMetalLayer class]]) {
      return static_cast<CAMetalLayer*>(sub);
    }
  }

  // Fallback for a plain UIView we do not control. Attaching a sublayer is the
  // only option: a UIView's backing layer is created by UIKit and cannot be
  // replaced after the fact.
  CAMetalLayer* metal_layer = [CAMetalLayer layer];
  metal_layer.framebufferOnly = YES;
  metal_layer.opaque = YES;
  metal_layer.frame = main_layer.bounds;
  [main_layer addSublayer:metal_layer];
  return metal_layer;
}

}  // namespace ui
}  // namespace xe
