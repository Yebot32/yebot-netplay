/**
 ******************************************************************************
 * Xenra : iOS theme - the Android palette, byte for byte                     *
 ******************************************************************************
 *
 * Mirrors main/res/values/colors.xml (the original-Xbox gold skin) so the iOS
 * shell renders the same screens as the Android app. Every constant here is
 * the Android literal, with the source name in the comment. If Android changes
 * a colour, change it here too - a divergence is a UI-parity bug.
 *
 * Deliberately functions, not +getColor class methods: the shell compiles
 * with -fno-objc-arc (see ios/CMakeLists.txt) and UIColor class methods
 * return autoreleased objects. These return retained objects; callers own
 * them (or use the convenience that leaks nothing: constants are cheap to
 * re-create, and screens are built once).
 */

#import <UIKit/UIKit.h>

static inline UIColor* XenraColor(uint8_t r, uint8_t g, uint8_t b,
                                  uint8_t a) {
  return [[UIColor alloc] initWithRed:r / 255.0
                                green:g / 255.0
                                 blue:b / 255.0
                                alpha:a / 255.0];
}

// xaniteog_black - the dashboard base.
static inline UIColor* XenraBlack(void) {
  return XenraColor(0x0B, 0x08, 0x08, 0xFF);
}
// xaniteog_charcoal.
static inline UIColor* XenraCharcoal(void) {
  return XenraColor(0x0D, 0x0B, 0x08, 0xFF);
}
// xaniteog_surface.
static inline UIColor* XenraSurface(void) {
  return XenraColor(0x14, 0x12, 0x0D, 0xFF);
}
// xaniteog_surface_variant.
static inline UIColor* XenraSurfaceVariant(void) {
  return XenraColor(0x1D, 0x19, 0x15, 0xFF);
}
// xaniteog_surface_container.
static inline UIColor* XenraSurfaceContainer(void) {
  return XenraColor(0x26, 0x1F, 0x1A, 0xFF);
}
// xaniteog_surface_container_high.
static inline UIColor* XenraSurfaceContainerHigh(void) {
  return XenraColor(0x2E, 0x25, 0x1E, 0xFF);
}
// xaniteog_card_fill - game-list blade fill for cards.
static inline UIColor* XenraCardFill(void) {
  return XenraColor(0x1A, 0x17, 0x0D, 0xFF);
}
// xaniteog_blade_fill.
static inline UIColor* XenraBladeFill(void) {
  return XenraColor(0x24, 0x1D, 0x0B, 0xFF);
}
// xaniteog_panel_fill (alpha 0xE6 of #0D0A04).
static inline UIColor* XenraPanelFill(void) {
  return XenraColor(0x0D, 0x0A, 0x04, 0xE6);
}

// xanite_accent_og - the gold everything is drawn with.
static inline UIColor* XenraAccent(void) {
  return XenraColor(0xFF, 0xD7, 0x00, 0xFF);
}
// xanite_accent_og_55 - the unselected blade stroke.
static inline UIColor* XenraAccent55(void) {
  return XenraColor(0xFF, 0xD7, 0x00, 0x55);
}
// xanite_accent_og_33.
static inline UIColor* XenraAccent33(void) {
  return XenraColor(0xFF, 0xD7, 0x00, 0x33);
}
// xanite_accent_og_22.
static inline UIColor* XenraAccent22(void) {
  return XenraColor(0xFF, 0xD7, 0x00, 0x22);
}
// xaniteog_blade_selected_end - selected blade gradient end.
static inline UIColor* XenraBladeSelectedEnd(void) {
  return XenraColor(0xA6, 0x6B, 0x00, 0xFF);
}
// xaniteog_blade_selected_stroke.
static inline UIColor* XenraBladeSelectedStroke(void) {
  return XenraColor(0xFF, 0xF0, 0xA0, 0xFF);
}
// xaniteog_blade_selected_text - dark text on a selected blade.
static inline UIColor* XenraBladeSelectedText(void) {
  return XenraColor(0x12, 0x0D, 0x00, 0xFF);
}
// xaniteog_text.
static inline UIColor* XenraText(void) {
  return XenraColor(0xFF, 0xF6, 0xEB, 0xFF);
}
// xaniteog_text_muted.
static inline UIColor* XenraTextMuted(void) {
  return XenraColor(0xBF, 0xA8, 0x98, 0xFF);
}
// xaniteog_success.
static inline UIColor* XenraSuccess(void) {
  return XenraColor(0x7C, 0xFF, 0x6B, 0xFF);
}
// xaniteog_error.
static inline UIColor* XenraError(void) {
  return XenraColor(0xFF, 0x52, 0x52, 0xFF);
}
// xaniteog_warning (Material colorError shade).
static inline UIColor* XenraWarning(void) {
  return XenraColor(0xFF, 0x6B, 0x6B, 0xFF);
}

// xanite_bg_grad_og_* - the dashboard background gradient, top to bottom.
static inline UIColor* XenraBgGradStart(void) {
  return XenraColor(0x03, 0x03, 0x03, 0xFF);
}
static inline UIColor* XenraBgGradCenter(void) {
  return XenraColor(0x18, 0x12, 0x04, 0xFF);
}
static inline UIColor* XenraBgGradEnd(void) {
  return XenraColor(0x5A, 0x41, 0x00, 0xFF);
}

// xaniteog_glow_* - the radial dashboard glow.
static inline UIColor* XenraGlowStrong(void) {
  return XenraColor(0xFF, 0xD7, 0x00, 0x4D);
}
static inline UIColor* XenraGlowSoft(void) {
  return XenraColor(0xFF, 0xD7, 0x00, 0x1A);
}
static inline UIColor* XenraGlowFloor(void) {
  return XenraColor(0xFF, 0xD7, 0x00, 0x14);
}

/// The Android blade octagon (GameBladeView.buildBladePath, 10dp chamfer at
/// the density of the device). Fills `rect` of `layer`; chamfer is inset.
static inline void XenraPathBlade(UIBezierPath* path, CGRect rect,
                                  CGFloat chamfer) {
  [path removeAllPoints];
  CGFloat x = rect.origin.x, y = rect.origin.y;
  CGFloat w = rect.size.width, h = rect.size.height;
  [path moveToPoint:CGPointMake(x + chamfer, y)];
  [path addLineToPoint:CGPointMake(x + w - chamfer, y)];
  [path addLineToPoint:CGPointMake(x + w, y + chamfer)];
  [path addLineToPoint:CGPointMake(x + w, y + h - chamfer)];
  [path addLineToPoint:CGPointMake(x + w - chamfer, y + h)];
  [path addLineToPoint:CGPointMake(x + chamfer, y + h)];
  [path addLineToPoint:CGPointMake(x, y + h - chamfer)];
  [path addLineToPoint:CGPointMake(x, y + chamfer)];
  [path closePath];
}
