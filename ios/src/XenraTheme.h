/**
 ******************************************************************************
 * Xenra : iOS theme - the Android green skin                                 *
 ******************************************************************************
 *
 * Mirrors main/res-green/values/colors.xml over main/res/values/colors.xml.
 * Three palettes, as on Android: Xbox is dark green, Xbox 360 is LIGHT green,
 * and the setup wizard is silver (colors_setup_gray.xml). Every colour is read
 * when a screen is built, so changing the mode means rebuilding the screens;
 * Android's recreate() works the same way.
 */

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, XenraThemeModeValue) {
  XenraThemeOG,
  XenraThemeX360,
  XenraThemeSetup,
};

extern NSInteger XenraThemeMode;

static inline UIColor* XenraColor(uint8_t r, uint8_t g, uint8_t b,
                                  uint8_t a) {
  return [[UIColor alloc] initWithRed:r / 255.0
                                green:g / 255.0
                                 blue:b / 255.0
                                alpha:a / 255.0];
}

// Android's #AARRGGBB.
static inline UIColor* XenraHex(uint32_t argb) {
  return XenraColor((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF,
                    argb >> 24);
}

static inline UIColor* XenraPick(uint32_t og, uint32_t x360, uint32_t setup) {
  return XenraHex(XenraThemeMode == XenraThemeX360    ? x360
                  : XenraThemeMode == XenraThemeSetup ? setup
                                                      : og);
}

static inline uint32_t XenraAccentRGB(void) {
  return XenraThemeMode == XenraThemeX360    ? 0x74A81A
         : XenraThemeMode == XenraThemeSetup ? 0xB9C0C4
                                             : 0x5FD35F;
}

// xanite_accent_*_NN: the accent at any step of the alpha ramp.
static inline UIColor* XenraAccentAlpha(uint8_t alpha) {
  return XenraHex(uint32_t(alpha) << 24 | XenraAccentRGB());
}
static inline UIColor* XenraAccent(void) { return XenraAccentAlpha(0xFF); }

static inline UIColor* XenraCharcoal(void) {
  return XenraPick(0xFF0D0B08, 0xFFCBE09A, 0xFF0B0B0C);
}
static inline UIColor* XenraBladeFill(void) {
  return XenraPick(0xFF241D0B, 0xA0D8E8A4, 0xFF171719);
}
// The panel as it lands on screen: xaniteog_panel_fill over the green bloom.
static inline UIColor* XenraPanelFill(void) {
  return XenraPick(0xFF1F2B1A, 0xC4E2EFB4, 0xFF232427);
}
static inline UIColor* XenraDialogFill(void) {
  return XenraPick(0xF20A0F08, 0xF2E8F4C2, 0xF20A0A0B);
}
static inline UIColor* XenraAccentContainer(void) {
  return XenraPick(0xFF1E4A1E, 0xFFB0CE70, 0xFF2A2F32);
}
static inline UIColor* XenraOutlineVariant(void) {
  return XenraPick(0xFF2E251E, 0xA67E9E48, 0xFF333437);
}
static inline UIColor* XenraText(void) {
  return XenraPick(0xFFFFF6EB, 0xFF1B2408, 0xFFF4F5F6);
}
static inline UIColor* XenraTextMuted(void) {
  return XenraPick(0xFFBFA898, 0xFF4C5A2E, 0xFFA9ACB0);
}
// Text on a filled accent blade or badge.
static inline UIColor* XenraOnAccent(void) {
  return XenraPick(0xFF0B1A0B, 0xFFFBFEF4, 0xFF0B0B0C);
}
static inline UIColor* XenraSuccess(void) {
  return XenraThemeMode == XenraThemeX360 ? XenraHex(0xFF3F6410)
                                          : XenraHex(0xFF7CFF6B);
}
static inline UIColor* XenraError(void) { return XenraHex(0xFFFF5252); }
static inline UIColor* XenraWarning(void) { return XenraHex(0xFFFF6B6B); }

// xanite_bg_grad_*: the dashboard, left to right.
static inline UIColor* XenraBgGradStart(void) {
  return XenraPick(0xFF030503, 0xFFDCEAB8, 0xFF030503);
}
static inline UIColor* XenraBgGradCenter(void) {
  return XenraPick(0xFF0A1A0C, 0xFFAFD26F, 0xFF0A1A0C);
}
static inline UIColor* XenraBgGradEnd(void) {
  return XenraPick(0xFF145A22, 0xFF6DA524, 0xFF145A22);
}
static inline UIColor* XenraVignetteTop(void) {
  return XenraPick(0x66000000, 0x1A3F5C14, 0x66000000);
}
static inline UIColor* XenraVignetteBottom(void) {
  return XenraPick(0x55000000, 0x143F5C14, 0x55000000);
}
