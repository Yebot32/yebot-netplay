/**
 ******************************************************************************
 * Xenra : iOS shell - shared widgets                                         *
 ******************************************************************************
 *
 * The pieces every screen is made of, each one the iOS twin of an Android
 * widget: ChamferedPanelView, the blade row, the blade dialog, the B/A hints.
 */

#import <UIKit/UIKit.h>

// A framed panel with cut corners, Android's ChamferedPanelView.
@interface XenraPanelView : UIView
@end

// One tappable blade, Android's Widget.Xaniteog.Blade.
@interface XenraBladeButton : UIControl
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* subtitle;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, assign) BOOL dimmed;  // shown, but says it is unavailable
@property(nonatomic, assign) BOOL chosen;  // the current settings tab
@property(nonatomic, assign) BOOL primary;  // the default action, filled
@property(nonatomic, copy) void (^action)(void);
- (instancetype)initWithTitle:(NSString*)title action:(void (^)(void))action;
@end

// A row of a blade dialog.
@interface XenraBladeItem : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* subtitle;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, assign) BOOL dimmed;
@property(nonatomic, copy) void (^action)(void);
+ (instancetype)title:(NSString*)title action:(void (^)(void))action;
@end

// Android's dialog_blade_menu: a dimmed screen, a panel, a column of blades.
// Tapping outside dismisses, tapping a blade dismisses and then acts.
@interface XenraBladeSheet : UIView
+ (void)showIn:(UIView*)host
         title:(NSString*)title
       message:(NSString*)message
         items:(NSArray<XenraBladeItem*>*)items;
@end

// The B BACK / A SELECT row along the bottom of every Android screen.
@interface XenraHintBar : UIView
@property(nonatomic, copy) void (^onBack)(void);
@end

// Bundled image by file name, wherever the bundle layout put it.
UIImage* XenraBundleImage(NSString* name);

UILabel* XenraMakeLabel(NSString* text, CGFloat size, UIFontWeight weight,
                        UIColor* color);

// Android's ScreenTitle text appearance: tracked capitals.
NSAttributedString* XenraTracked(NSString* text, CGFloat size, UIColor* color);
