/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_UI_SURFACE_IOS_H_
#define XENIA_UI_SURFACE_IOS_H_

#include <cstdint>

#include "xenia/ui/surface.h"

#ifdef __OBJC__
@class UIView;
@class CAMetalLayer;
#else
// Same forward-declaration dance as surface_mac.h: non-Obj-C translation units
// include this too, and CAMetalLayer may already have been declared by
// vulkan_metal.h.
struct UIView;
#ifndef VULKAN_METAL_H_
struct CAMetalLayer;
#endif
#endif

namespace xe {
namespace ui {

// The iOS counterpart of MacNSViewSurface.
//
// Deliberately kept as a sibling class rather than folded into the Mac one
// behind #ifdefs. The two look similar and differ in every detail that
// matters: a UIView always has a backing layer (there is no wantsLayer step),
// CALayer::autoresizingMask is macOS-only so the metal layer has to be resized
// explicitly, and the backing scale comes from the window's screen scale
// rather than from NSScreen::backingScaleFactor.
class IosUIViewSurface final : public Surface {
 public:
  explicit IosUIViewSurface(UIView* view) : view_(view) {}
  TypeIndex GetType() const override { return kTypeIndex_IosUIView; }
  UIView* view() const { return view_; }
  double GetBackingScale() const;
  void ConfigureMetalLayer(uint32_t drawable_width, uint32_t drawable_height,
                           double contents_scale) const;
  CAMetalLayer* GetOrCreateMetalLayer() const;

 protected:
  bool GetSizeImpl(uint32_t& width_out, uint32_t& height_out) const override;

 private:
  UIView* view_;
};

}  // namespace ui
}  // namespace xe

#endif  // XENIA_UI_SURFACE_IOS_H_
