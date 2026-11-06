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

// The accent as words. On the light console the accent itself is a mid green that
// pale panels wash out, so text and small labels take a darker step of it.
static inline UIColor* XenraAccentText(void) {
  return XenraThemeMode == XenraThemeX360 ? XenraHex(0xFF3F6410) : XenraAccent();
}

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
  return XenraPick(0xF20A0805, 0xF2E8F4C2, 0xF20A0A0B);
}
static inline UIColor* XenraAccentContainer(void) {
  return XenraPick(0xFF1E4A1E, 0x3374A81A, 0xFF2A2F32);
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
  return XenraPick(0xFF0B0808, 0xFF1B2408, 0xFF0A0A0B);
}
static inline UIColor* XenraSuccess(void) {
  return XenraThemeMode == XenraThemeX360 ? XenraHex(0xFF3F6410)
                                          : XenraHex(0xFF7CFF6B);
}
static inline UIColor* XenraError(void) {
  return XenraPick(0xFFFF5252, 0xFFB3261E, 0xFFFF5252);
}
// Text of a destructive row: xaniteog_warning, x360_warning.
static inline UIColor* XenraWarning(void) {
  return XenraPick(0xFFFF6B6B, 0xFF8A4B0B, 0xFFFF6B6B);
}

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
// The ring the vignette paints, centre clear: xenraVignetteMid, xenraVignetteEdge.
static inline UIColor* XenraVignetteMid(void) {
  return XenraPick(0x26000000, 0x0A3F5C14, 0x26000000);
}
static inline UIColor* XenraVignetteEdge(void) {
  return XenraPick(0x8C000000, 0x2E3F5C14, 0x8C000000);
}

// xenraTextPrimary / Secondary / Tertiary. Blades use secondary, hints and
// meta lines tertiary. These are the neutral tokens; XenraText and
// XenraTextMuted are the warmer xenraText and xenraTextMuted, which is what
// dropdown values and field helpers use.
static inline UIColor* XenraTextPrimary(void) {
  return XenraPick(0xFFFFFFFF, 0xDE000000, 0xFFF4F5F6);
}
static inline UIColor* XenraTextSecondary(void) {
  return XenraPick(0xD6FFFFFF, 0xC2000000, 0xFFF4F5F6);
}
static inline UIColor* XenraTextTertiary(void) {
  return XenraPick(0x8AFFFFFF, 0xA3000000, 0xFFA9ACB0);
}

// xenraAccentLight as words, by the same reasoning as XenraAccentText.
static inline UIColor* XenraAccentLightText(void) {
  return XenraThemeMode == XenraThemeX360 ? XenraHex(0xFF3F6410) : XenraAccentLight();
}

// xenraBg: also the label colour on a filled accent pill.
static inline UIColor* XenraBg(void) {
  return XenraPick(0xFF0B0808, 0xFFD6E8AC, 0xFF0A0A0B);
}
static inline UIColor* XenraSurface(void) {
  return XenraPick(0xFF14120D, 0xFFDFEEB6, 0xFF131314);
}
static inline UIColor* XenraSurfaceVariant(void) {
  return XenraPick(0xFF1D1915, 0xFFD2E4A0, 0xFF1A1A1C);
}
static inline UIColor* XenraAccentLight(void) {
  return XenraPick(0xFF7FE07F, 0xCC74A81A, 0xFFDCE1E4);
}
static inline UIColor* XenraAccentDark(void) {
  return XenraPick(0xFF3FA33F, 0xFF74A81A, 0xFF7E868B);
}
// xenraSettingsCardFill: what a XenraCardView is filled with.
static inline UIColor* XenraCardFill(void) {
  return XenraPick(0xFF1A170D, 0x0F000000, 0xFF171719);
}
static inline UIColor* XenraFocus(void) {
  return XenraPick(0xFFFFFFFF, 0xFF0E140D, 0xFFFFFFFF);
}
static inline UIColor* XenraFocus38(void) {
  return XenraPick(0x38FFFFFF, 0x380E140D, 0x38FFFFFF);
}
static inline UIColor* XenraFocus1F(void) {
  return XenraPick(0x1FFFFFFF, 0x1F0E140D, 0x1FFFFFFF);
}
// xenraShadowSpot. Tinted on the light console: black over pale green is grey.
static inline UIColor* XenraShadow(void) {
  return XenraPick(0xFF000000, 0x33313D14, 0xFF000000);
}

// Whether this palette is the light one, for anything that follows the
// interface style: switches, spinners, scroll indicators, system pickers.
static inline UIUserInterfaceStyle XenraInterfaceStyle(void) {
  return XenraThemeMode == XenraThemeX360 ? UIUserInterfaceStyleLight
                                          : UIUserInterfaceStyleDark;
}
