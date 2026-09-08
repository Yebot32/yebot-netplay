/**
 ******************************************************************************
 * Xenra : iOS shell - blade surface + dashboard background                   *
 ******************************************************************************
 *
 * XenraBladeView paints the Android GameBladeView octagon (fill + stroke, or
 * the selected gradient). XenraDashboardBackground paints the Android
 * dashboard base: the vertical background gradient stops plus the radial
 * gold glow (xanite_bg_grad_og_* / xaniteog_glow_*).
 */

#import <UIKit/UIKit.h>

@interface XenraBladeView : UIView
/// NO = unselected (blade fill + accent55 stroke); YES = the selected
/// gradient with the bright stroke treatment.
@property(nonatomic, assign) BOOL bladeSelected;
@end

@interface XenraDashboardBackground : UIView
@end
