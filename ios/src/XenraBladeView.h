/**
 ******************************************************************************
 * Xenra : iOS shell - blade surface + backgrounds                            *
 ******************************************************************************
 *
 * XenraBladeView paints xbox_menu_item_bg: a rail on the leading edge and a
 * gradient that falls away from it. XenraDashboardBackground paints
 * xanite_gold_dashboard_background, or setup_wizard_background for every other
 * screen.
 */

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, XenraBladeState) {
  XenraBladeResting,
  XenraBladeChosen,
  XenraBladePressed,
};

@interface XenraBladeView : UIView
@property(nonatomic, assign) XenraBladeState state;
// blade_bg_primary: filled in the accent, for the default action.
@property(nonatomic, assign) BOOL primary;
@end

@interface XenraDashboardBackground : UIView
// The base under settings, library and setup: charcoal and a radial bloom.
- (instancetype)initWithFrame:(CGRect)frame;
// The dashboard's own: a gradient across the screen.
- (instancetype)initForDashboardWithFrame:(CGRect)frame;
@end
