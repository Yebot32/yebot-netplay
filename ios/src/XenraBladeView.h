/**
 ******************************************************************************
 * Xenra : iOS shell - blade surface + backgrounds                            *
 ******************************************************************************
 *
 * XenraBladeView paints the blade drawables: a rail on the leading edge and a
 * gradient that falls away from it. Dark palettes use xbox_menu_item_bg,
 * blade_bg_primary and blade_bg_destructive; compact blades on the light console
 * use the *_light set, a raised white row, because an accent wash disappears on a
 * pale panel. XenraDashboardBackground paints xanite_gold_dashboard_background,
 * or setup_wizard_background for every other screen.
 */

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, XenraBladeState) {
  XenraBladeResting,
  XenraBladeFocused,  // the controller cursor
  XenraBladeChosen,
  XenraBladePressed,
};

typedef NS_ENUM(NSInteger, XenraBladeKind) {
  XenraBladeKindPlain,
  XenraBladeKindPrimary,      // blade_bg_primary: the default action, filled
  XenraBladeKindDestructive,  // blade_bg_destructive
};

@interface XenraBladeView : UIView
@property(nonatomic, assign) XenraBladeState state;
@property(nonatomic, assign) XenraBladeKind kind;
// xenraBladeCompactBg: the row of a menu rather than of the dashboard.
@property(nonatomic, assign) BOOL compact;
// Shorthand for kind, kept for callers that only need the filled blade.
@property(nonatomic, assign) BOOL primary;
@end

@interface XenraDashboardBackground : UIView
// The base under settings, library and setup: charcoal and a radial bloom.
- (instancetype)initWithFrame:(CGRect)frame;
// The dashboard's own: a gradient across the screen, then dashboard_vignette.
- (instancetype)initForDashboardWithFrame:(CGRect)frame;
@end
